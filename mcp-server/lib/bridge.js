// PowerShellBridge: owns the single long-lived powershell.exe child described in PROTOCOL.md.
// All calls are serialised FIFO; every call() resolves to a result object and never rejects.
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import readline from 'node:readline';
import { DEFAULT_BRIDGE_SCRIPT, DEFAULT_MODULE_PATH, MAX_CALL_TIMEOUT_MS, defaultPowershellPath } from './config.js';

export const START_TIMEOUT_MS = 60000;
export const STOP_TIMEOUT_MS = 5000;
const KILL_ESCALATE_MS = 1000;

export const HINTS = {
  BRIDGE_TIMEOUT:
    'PowerShell bridge was restarted and all IDE/ADS state is lost. Check for a modal dialog in the XAE window (GetIdeModalDialog after ConnectIde), then ConnectIde again. An IDE bound with ProcessId must be reconnected with the same ProcessId (ConnectIde ProcessId=<pid>): that consent is not kept across a bridge restart (#281). If the interrupted call had already sent its runtime-changing request (EnableConfig, SetSystemState, SetPlcState; also inside RunLifecycle / RunTestCycle), it is recorded as a lifecycle block (errorCode INTERRUPTED, #236) at the next lifecycle check and the next runtime-changing call returns LIFECYCLE_BLOCKED: report it to the user, only read-only diagnosis, ClearLifecycleBlock only after the user agreed.',
  // #249: ConnectIde ran out of time. A cold IDE start (launch, first modal-dialog scan, Solution.Open) can
  // take long on a loaded machine; launching again would leave a second IDE (#235).
  BRIDGE_TIMEOUT_CONNECT_IDE:
    'ConnectIde did not finish in time and the PowerShell bridge was restarted (IDE/ADS state of this server is lost). ' +
    'The IDE it was starting may still be starting, or may already be up: do NOT launch an IDE yourself and do not taskkill it. ' +
    'Call ConnectIde again with the SAME parameters: it attaches the IDE this server launched for that SolutionPath (selectedBy session-launched, ownedBySession=true; waits up to 60 s while it is still starting), ' +
    'or reuses the empty IDE that an ended session left for that SolutionPath (#235, data.reusedEmptyOrphan=true). ' +
    'If that call answers IDE_MODAL_DIALOG / MODAL_SCAN_INCOMPLETE / IDE_LAUNCH_PENDING, follow its hint (GetIdeModalDialog ProcessId=<data.ideProcessId>). ' +
    'If it launched another IDE anyway, tell the user that the IDE this call was starting may still be running: it was cut off before it was recorded, it is not owned by this server and must not be closed by you (data.candidates alone cannot tell which IDE that is).',
  BRIDGE_DIED:
    'PowerShell bridge process exited and all IDE/ADS state is lost. It restarts on the next call; run ConnectIde again. An IDE bound with ProcessId must be reconnected with the same ProcessId (ConnectIde ProcessId=<pid>): that consent is not kept across a bridge restart (#281).',
  MODULE_IMPORT_FAILED:
    'The PowerShell bridge could not start. Check TWINCAT_MODULE_PATH / TWINCAT_MCP_POWERSHELL and the bridge stderr output.'
};

/** Message of the CANCELLED result a queued call gets when its AbortSignal fires before dispatch. */
export const CANCELLED_MESSAGE = 'Request cancelled before it was sent to PowerShell; nothing was executed.';

/** Suffix for BRIDGE_DIED results of calls that were still queued (never reached PowerShell). */
const NOT_EXECUTED = 'this call was not executed; safe to retry after reconnecting';

/**
 * #249: the BRIDGE_TIMEOUT of a ConnectIde call gets the ConnectIde hint (call it again with the same
 * parameters, never launch an IDE yourself). Any other tool / result is returned unchanged.
 */
export function decorateConnectIdeTimeout(name, result) {
  if (name !== 'ConnectIde' || !result || result.success === true || result.error?.code !== 'BRIDGE_TIMEOUT') return result;
  return { ...result, error: { ...result.error, hint: HINTS.BRIDGE_TIMEOUT_CONNECT_IDE } };
}

export function errorResult(code, message, hint) {
  const error = { code, message };
  if (hint) error.hint = hint;
  return { success: false, error };
}

/**
 * Add the execution order (seq/startedAt/finishedAt) to the result of a dispatched call (#57).
 * Always as result.order; also merged into data when data is a plain object (the historical
 * data.seq) and as data when the result has no data at all. Any other data (an array such as
 * GetSymbols / multi-path ReadVariable / GetProjectTree, a scalar, null) is returned unchanged:
 * replacing it would turn a list into an empty success.
 */
export function stampOrder(item, result) {
  if (!result || typeof result !== 'object' || Array.isArray(result)) return result;
  const order = { seq: item.seq, startedAt: item.startedAt, finishedAt: new Date().toISOString() };
  const out = { ...result, order };
  const data = result.data;
  if (data === undefined) out.data = { ...order };
  else if (isPlainObject(data)) out.data = { ...data, ...order };
  return out;
}

/** true for a non-null, non-array object (a JSON object). */
function isPlainObject(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

class BridgeStartError extends Error {
  constructor(code, message, hint, cause) {
    super(message);
    this.name = 'BridgeStartError';
    this.code = code;
    this.hint = hint;
    if (cause) this.cause = cause;
  }
}

function isAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

export class PowerShellBridge {
  /**
   * @param {object} [options]
   * @param {string} [options.modulePath]
   * @param {string} [options.powershellPath]
   * @param {string} [options.bridgeScript]
   * @param {object} [options.env]           extra environment for the child (merged over process.env)
   * @param {string} [options.ownerId]       launch-record owner id passed to every child as TCAUTO_OWNER_ID
   *   (#152 N1); default: a new GUID per bridge object, i.e. per MCP server process
   * @param {number} [options.ownerPid]      pid of the process that owns ownerId, passed to every child as
   *   TCAUTO_OWNER_PID (#196 review B1); default: process.pid (this MCP server). index.js passes the
   *   launcher pid when the owner id is the launcher's (it outlives a ReloadRuntime of index.js)
   * @param {{command:string,args:string[]}} [options.spawnSpec]  replaces the powershell.exe command line entirely (tests)
   * @param {(level:string,message:string,meta:object)=>void} [options.onLog]
   * @param {(line:string)=>void} [options.onStderr]
   * @param {(ready:object, info:{modulePath:string, loadedAt:string})=>void} [options.onReady]
   *   called once per child that became ready (first start, restart, ReloadModule)
   */
  constructor(options = {}) {
    this.modulePath = options.modulePath ?? process.env.TWINCAT_MODULE_PATH ?? DEFAULT_MODULE_PATH;
    this.powershellPath = options.powershellPath ?? defaultPowershellPath();
    this.bridgeScript = options.bridgeScript ?? DEFAULT_BRIDGE_SCRIPT;
    this.env = options.env ?? {};
    // #152 N1: one id for this MCP server. Every child (first start, restart after BRIDGE_TIMEOUT /
    // IDE_MODAL_DIALOG, ReloadModule) gets the same TCAUTO_OWNER_ID, so the module can take over
    // the IDEs its earlier child launched - and never those of another MCP server / conversation.
    this.ownerId = options.ownerId ?? randomUUID();
    // #196 review B1: a new bridge pid does not mean the session ended (BRIDGE_TIMEOUT / modal
    // restart / ReloadModule keep the server). The module records this pid (and reads its start
    // time) as ownerPid / ownerStartTime; Connect-TcIde -TakeOverOrphan needs it gone as well.
    this.ownerPid = Number.isInteger(options.ownerPid) && options.ownerPid > 0 ? options.ownerPid : process.pid;
    this.spawnSpec = options.spawnSpec ?? null;
    this.onLog = typeof options.onLog === 'function' ? options.onLog : () => {};
    this.onStderr = typeof options.onStderr === 'function' ? options.onStderr : () => {};
    this.onReady = typeof options.onReady === 'function' ? options.onReady : () => {};
    this.loadedAt = null; // ISO time the current child reported ready

    this.child = null;
    this.ready = null; // ready payload from the child
    this.lastStartError = null;
    this._starting = null; // Promise while start() is in flight
    this._stopping = false; // true while stop() is in flight
    this._queue = [];
    this._current = null;
    this._nextId = 1;
    this._seq = 0; // execution order of op:'call' requests actually written to PowerShell
    this._lastExit = Promise.resolve();
  }

  get isRunning() {
    return this.child !== null && this.ready !== null;
  }

  get pid() {
    return this.child?.pid ?? null;
  }

  /** Resolves when the most recently torn-down child has actually exited (tests). */
  lastChildExit() {
    return this._lastExit;
  }

  buildSpawnSpec() {
    if (this.spawnSpec) return { command: this.spawnSpec.command, args: [...(this.spawnSpec.args ?? [])] };
    return {
      command: this.powershellPath,
      args: [
        '-NoProfile',
        '-NonInteractive',
        '-STA',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        this.bridgeScript,
        '-ModulePath',
        this.modulePath
      ]
    };
  }

  /**
   * Spawn the child and wait for its ready line. Throws BridgeStartError on failure.
   * Whoever triggered the start (eager start in index.js or a queued call), the queue is
   * served once the child is ready, or failed with the start error when it is not.
   */
  start() {
    if (this.isRunning) return Promise.resolve(this.ready);
    if (this._starting) return this._starting;
    this._starting = this._doStart().then(
      (ready) => {
        this._starting = null;
        this._pump();
        return ready;
      },
      (err) => {
        this._starting = null;
        this._failQueue(err.code ?? 'MODULE_IMPORT_FAILED', err.message, err.hint ?? HINTS.MODULE_IMPORT_FAILED);
        throw err;
      }
    );
    return this._starting;
  }

  async _doStart() {
    const { command, args } = this.buildSpawnSpec();
    let child;
    try {
      child = spawn(command, args, {
        stdio: ['pipe', 'pipe', 'pipe'],
        windowsHide: true,
        // TWINCAT_MCP_BRIDGE_MODULE_PATH: the module path of this child also for a spawnSpec override
        // (the mock bridge reports it as ready.modulePath); bridge.ps1 reads -ModulePath instead.
        env: { ...process.env, ...this.env, TWINCAT_MCP_BRIDGE_MODULE_PATH: this.modulePath, TCAUTO_OWNER_ID: this.ownerId, TCAUTO_OWNER_PID: String(this.ownerPid) }
      });
    } catch (err) {
      this.lastStartError = new BridgeStartError('MODULE_IMPORT_FAILED', `Failed to spawn bridge: ${err.message}`, HINTS.MODULE_IMPORT_FAILED, err);
      throw this.lastStartError;
    }

    child.stdin.on('error', () => {}); // EPIPE after the child died; handled via exit
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');

    // 'close' (not 'exit'): fires once the process has exited AND its stdio streams are drained,
    // so a result line written just before the exit is still parsed before death is handled.
    const exited = new Promise((resolve) => {
      child.once('close', (code, signal) => resolve({ code, signal }));
    });
    this._lastExit = exited;

    const stderrRl = readline.createInterface({ input: child.stderr, crlfDelay: Infinity });
    stderrRl.on('line', (line) => {
      if (line.length) this._safe(() => this.onStderr(line));
    });

    const stdoutRl = readline.createInterface({ input: child.stdout, crlfDelay: Infinity });
    // Lines that arrive between the ready line and the steady-state wiring below.
    const early = [];
    let firstLineSeen = false;
    let adopted = false;
    stdoutRl.on('line', (line) => {
      if (!firstLineSeen) {
        firstLineSeen = true; // the ready line; handled by onFirstLine below
        return;
      }
      if (!adopted) {
        early.push(line);
        return;
      }
      if (this.child === child) this._onLine(line);
    });

    const ready = await new Promise((resolve, reject) => {
      let settled = false;
      const finish = (fn, value) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        fn(value);
      };
      const timer = setTimeout(() => {
        finish(reject, new BridgeStartError('BRIDGE_START_TIMEOUT', `Bridge did not become ready within ${START_TIMEOUT_MS} ms`, HINTS.MODULE_IMPORT_FAILED));
      }, START_TIMEOUT_MS);

      const onFirstLine = (line) => {
        stdoutRl.off('line', onFirstLine);
        let msg;
        try {
          msg = JSON.parse(line);
        } catch {
          finish(reject, new BridgeStartError('MODULE_IMPORT_FAILED', `Bridge wrote a non-JSON first line: ${line.slice(0, 200)}`, HINTS.MODULE_IMPORT_FAILED));
          return;
        }
        if (!msg || msg.event !== 'ready') {
          finish(reject, new BridgeStartError('MODULE_IMPORT_FAILED', `Bridge first line was not a ready event: ${line.slice(0, 200)}`, HINTS.MODULE_IMPORT_FAILED));
          return;
        }
        if (msg.ok !== true) {
          const e = msg.error ?? {};
          finish(reject, new BridgeStartError(e.code ?? 'MODULE_IMPORT_FAILED', e.message ?? 'Bridge reported ok:false', e.hint ?? HINTS.MODULE_IMPORT_FAILED));
          return;
        }
        finish(resolve, msg);
      };
      stdoutRl.prependListener('line', onFirstLine);

      child.once('error', (err) => {
        finish(reject, new BridgeStartError('MODULE_IMPORT_FAILED', `Failed to spawn bridge: ${err.message}`, HINTS.MODULE_IMPORT_FAILED, err));
      });
      exited.then(({ code, signal }) => {
        finish(reject, new BridgeStartError('MODULE_IMPORT_FAILED', `Bridge exited before ready (code ${code}, signal ${signal})`, HINTS.MODULE_IMPORT_FAILED));
      });
    }).catch((err) => {
      this.lastStartError = err;
      this._killChild(child);
      throw err;
    });

    // Ready: wire up steady-state handlers.
    this.child = child;
    this.ready = ready;
    this.loadedAt = new Date().toISOString();
    this.lastStartError = null;
    adopted = true;
    const loaded = { modulePath: this.modulePath, loadedAt: this.loadedAt };
    this._safe(() => this.onReady(ready, loaded));
    for (const line of early.splice(0)) this._onLine(line);

    child.on('error', (err) => {
      if (this.child !== child) return;
      this._safe(() => this.onStderr(`[bridge] child error: ${err.message}`));
      this._handleDeath(child, `bridge process error: ${err.message}`);
    });
    exited.then(({ code, signal }) => {
      if (this.child !== child) return;
      this._handleDeath(child, `bridge process exited (code ${code}, signal ${signal})`);
    });
    return ready;
  }

  _safe(fn) {
    try {
      fn();
    } catch {
      /* callbacks must never take the bridge down */
    }
  }

  _onLine(line) {
    if (!line.trim()) return;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      this._safe(() => this.onStderr(`[bridge] non-JSON stdout line: ${line}`));
      return;
    }
    if (!msg || typeof msg !== 'object') {
      this._safe(() => this.onStderr(`[bridge] unexpected stdout line: ${line}`));
      return;
    }
    const current = this._current;
    const cmdlet = current && current.id === msg.id ? current.cmdlet : undefined;

    if (msg.event === 'log') {
      this._safe(() => this.onLog(msg.level ?? 'info', msg.message ?? '', { id: msg.id, cmdlet }));
      return;
    }
    if (msg.event === 'result') {
      // id:null = the bridge could not parse / identify the request line (INVALID_REQUEST). The child
      // handles one request at a time, so that reply belongs to the call in flight: finish it instead
      // of leaving it to run into BRIDGE_TIMEOUT.
      const unaddressed = msg.id === null || msg.id === undefined;
      if (!current || (!unaddressed && current.id !== msg.id)) {
        this._safe(() => this.onStderr(`[bridge] result for unknown request id ${msg.id}: ${line.slice(0, 200)}`));
        return;
      }
      if (unaddressed) this._safe(() => this.onStderr(`[bridge] result without id attributed to request ${current.id}: ${line.slice(0, 200)}`));
      const { id: _id, event: _event, ...result } = msg;
      this._finishCurrent(result);
      return;
    }
    this._safe(() => this.onStderr(`[bridge] unknown event on stdout: ${line.slice(0, 200)}`));
  }

  _finishCurrent(result) {
    const current = this._current;
    if (!current) return;
    this._current = null;
    clearTimeout(current.timer);
    if (current.op === 'retire' && result?.success === true) this._detachRetired(current);
    this._settle(current, result);
    this._pump();
  }

  /**
   * op:'retire' succeeded (#41 ReloadModule): the child released IDE/ADS and exits by itself. It is
   * detached BEFORE the queue is pumped, so no further request reaches it: the next call (the
   * ReloadModule start or any queued call) spawns a fresh child with item.nextModulePath.
   */
  _detachRetired(item) {
    const old = this.child;
    this._reset();
    if (typeof item.nextModulePath === 'string' && item.nextModulePath) this.modulePath = item.nextModulePath;
    if (old) {
      const t = setTimeout(() => this._killChild(old), STOP_TIMEOUT_MS);
      t.unref();
    }
  }

  /**
   * #41: ask the child to retire (bridge.ps1 op:'retire': refused with RELOAD_LIFECYCLE_BLOCKED while
   * the module holds a lifecycle block in memory; otherwise Disconnect-TcAds + Disconnect-TcIde, reply,
   * exit) and switch to `nextModulePath` for the next child. Queued FIFO like every call, so it never
   * interrupts a call in flight. Resolves to the retire result; never rejects.
   * No child running and none starting (never started, or the last start failed, e.g. after a
   * RELOAD_FAILED that could not restore): there is no process and so no in-memory state to lose;
   * the path is switched right away and no retire is sent. Sending it would start the current
   * (possibly broken) path first and never get past MODULE_IMPORT_FAILED.
   */
  retire(nextModulePath, opts = {}) {
    if (!this.isRunning && !this._starting && !this._stopping) {
      if (opts.signal?.aborted) return Promise.resolve(errorResult('CANCELLED', CANCELLED_MESSAGE));
      if (typeof nextModulePath === 'string' && nextModulePath) this.modulePath = nextModulePath;
      return Promise.resolve({
        success: true,
        data: { retired: false, noBridge: true, modulePath: null, ideWasConnected: false, adsWasConnected: false, buildRequiredPersisted: [] }
      });
    }
    return this.call('retire', { ...opts, nextModulePath });
  }

  /** Resolve an item exactly once and drop its abort listener. */
  _settle(item, result) {
    if (item.settled) return;
    item.settled = true;
    if (item.seq !== undefined && item.op === 'call') result = stampOrder(item, result);
    if (item.signal && item.onAbort) item.signal.removeEventListener('abort', item.onAbort);
    item.resolve(result);
  }

  /**
   * Send one request to the child. Resolves to the result object (id/event removed). Never rejects.
   * @param {'call'|'modal'|'state'|'ping'|'retire'|'shutdown'} op
   * @param {{cmdlet?:string, params?:object, timeoutMs?:number, signal?:AbortSignal, token?:object}} [opts]
   *   signal: while the call is still queued, an abort removes it from the queue and resolves it with
   *   CANCELLED (nothing was executed). Once the request has been written to PowerShell it cannot be
   *   interrupted: the abort is ignored and the real result is returned when the cmdlet finishes.
   *   token: any object identifying this call for abortCall() (the modal-dialog probe in index.js).
   */
  call(op = 'call', opts = {}) {
    const { cmdlet, params, timeoutMs, signal, token, nextModulePath } = opts;
    return new Promise((resolve) => {
      const item = {
        id: String(this._nextId++),
        op,
        cmdlet,
        params,
        timeoutMs: Number.isFinite(timeoutMs) && timeoutMs > 0 ? Math.min(timeoutMs, MAX_CALL_TIMEOUT_MS) : 120000,
        resolve,
        timer: null,
        signal: signal ?? null,
        onAbort: null,
        settled: false,
        token: token ?? null,
        nextModulePath: nextModulePath ?? null
      };
      if (signal?.aborted) {
        this._settle(item, errorResult('CANCELLED', CANCELLED_MESSAGE));
        return;
      }
      if (this._stopping) {
        // Calls that arrive while stop() is in flight are not queued for a child that is going away
        // and are not allowed to spawn a new one underneath the shutdown: they fail right away.
        // After stop() has completed, the next call lazily starts a fresh child as usual.
        this._settle(item, errorResult('BRIDGE_DIED', `bridge is stopping; ${NOT_EXECUTED}`, HINTS.BRIDGE_DIED));
        return;
      }
      if (signal) {
        item.onAbort = () => {
          const idx = this._queue.indexOf(item);
          if (idx === -1) return; // already dispatched (or settled): cannot be interrupted
          this._queue.splice(idx, 1);
          this._settle(item, errorResult('CANCELLED', CANCELLED_MESSAGE));
        };
        signal.addEventListener('abort', item.onAbort, { once: true });
      }
      this._queue.push(item);
      this._pump();
    });
  }

  _pump() {
    if (this._current || this._queue.length === 0) return;
    if (!this.isRunning) {
      // start() pumps the queue when the child is ready and fails it when the start fails,
      // whoever initiated the start (an earlier eager start() included).
      if (!this._starting) this.start().catch(() => {});
      return;
    }
    const item = this._queue.shift();
    this._current = item;
    if (item.op === 'call') {
      item.seq = ++this._seq;
      item.startedAt = new Date().toISOString();
    }
    const request = { id: item.id, op: item.op };
    if (item.op === 'call') request.cmdlet = item.cmdlet;
    if (item.params !== undefined) request.params = item.params;

    item.timer = setTimeout(() => this._onTimeout(item), item.timeoutMs);
    try {
      this.child.stdin.write(JSON.stringify(request) + '\n');
    } catch (err) {
      this._handleDeath(this.child, `failed to write to bridge stdin: ${err.message}`);
    }
  }

  _onTimeout(item) {
    if (this._current !== item) return;
    const label = item.op === 'call' ? item.cmdlet : `op:${item.op}`;
    this._killCurrent(
      item,
      errorResult('BRIDGE_TIMEOUT', `${label} did not finish within ${item.timeoutMs} ms; PowerShell bridge killed`, HINTS.BRIDGE_TIMEOUT),
      `${label} timed out`
    );
  }

  /**
   * The call in flight cannot finish (timeout, modal dialog): settle it with `result`, kill the
   * child (restarted lazily by the next call) and fail the queue with BRIDGE_DIED / not executed.
   */
  _killCurrent(item, result, reason) {
    const child = this.child;
    this._current = null;
    clearTimeout(item.timer);
    this._settle(item, result);
    this._reset();
    this._failQueue('BRIDGE_DIED', `PowerShell bridge was killed because ${reason}; ${NOT_EXECUTED}`);
    this._killChild(child);
  }

  /**
   * Abort the call identified by `token` (passed as opts.token to call()) with the caller's result.
   * `result` is the result object, or a function `(outcome) => result` when the result depends on
   * what happens to the call.
   *   - in flight (written to PowerShell, blocked): settled with the result, the child is killed
   *     exactly like on BRIDGE_TIMEOUT (queued calls get BRIDGE_DIED / not executed) -> 'killed'
   *   - still queued: removed and settled, the child is untouched -> 'dequeued'
   *   - unknown / already finished: no-op -> null
   * @param {object} token
   * @param {object|((outcome:'killed'|'dequeued')=>object)} result
   * @param {string} reason  completes "PowerShell bridge was killed because <reason>"
   * @returns {'killed'|'dequeued'|null}
   */
  abortCall(token, result, reason = 'the call was aborted') {
    if (token === null || token === undefined) return null;
    const resolveResult = (outcome) => (typeof result === 'function' ? result(outcome) : result);
    const current = this._current;
    if (current && current.token === token && !current.settled) {
      this._killCurrent(current, resolveResult('killed'), reason);
      return 'killed';
    }
    const idx = this._queue.findIndex((it) => it.token === token);
    if (idx !== -1) {
      const [item] = this._queue.splice(idx, 1);
      this._settle(item, resolveResult('dequeued'));
      return 'dequeued';
    }
    return null;
  }

  _handleDeath(child, reason) {
    if (this.child !== child) return;
    const current = this._current;
    this._current = null;
    this._reset();
    if (current) {
      clearTimeout(current.timer);
      this._settle(current, errorResult('BRIDGE_DIED', `${reason} while running ${current.op === 'call' ? current.cmdlet : current.op}`, HINTS.BRIDGE_DIED));
    }
    this._failQueue('BRIDGE_DIED', `${reason}; ${NOT_EXECUTED}`);
    this._killChild(child);
  }

  /** Resolve every queued (not yet dispatched) call with the same error. */
  _failQueue(code, message, hint = HINTS.BRIDGE_DIED) {
    const waiting = this._queue.splice(0);
    for (const item of waiting) this._settle(item, errorResult(code, message, hint));
  }

  _reset() {
    this.child = null;
    this.ready = null;
  }

  _killChild(child) {
    if (!child || child.exitCode !== null || child.signalCode !== null) return;
    const pid = child.pid;
    try {
      child.stdin.end();
    } catch {
      /* ignore */
    }
    try {
      child.kill();
    } catch {
      /* ignore */
    }
    if (process.platform === 'win32' && pid) {
      const t = setTimeout(() => {
        if (child.exitCode === null && child.signalCode === null && isAlive(pid)) {
          try {
            spawn('taskkill', ['/PID', String(pid), '/T', '/F'], { stdio: 'ignore', windowsHide: true }).on('error', () => {});
          } catch {
            /* ignore */
          }
        }
      }, KILL_ESCALATE_MS);
      t.unref();
    }
  }

  /**
   * Graceful shutdown: ask the child to exit, kill it after STOP_TIMEOUT_MS. Never throws.
   * Calls that arrive while this runs get BRIDGE_DIED immediately (see call()); calls made after it
   * has returned start a fresh child.
   */
  async stop() {
    if (this._stopping) return;
    this._stopping = true;
    try {
      if (this._starting) {
        try {
          await this._starting;
        } catch {
          /* start failed; nothing to stop */
        }
      }
      const child = this.child;
      if (!child) {
        this._failQueue('BRIDGE_DIED', `bridge stopped; ${NOT_EXECUTED}`);
        return;
      }
      const exited = this._lastExit;
      this._reset();
      const current = this._current;
      this._current = null;
      if (current) {
        clearTimeout(current.timer);
        this._settle(current, errorResult('BRIDGE_DIED', 'bridge stopped while the call was running', HINTS.BRIDGE_DIED));
      }
      this._failQueue('BRIDGE_DIED', `bridge stopped; ${NOT_EXECUTED}`);

      try {
        child.stdin.write(JSON.stringify({ id: String(this._nextId++), op: 'shutdown' }) + '\n');
      } catch {
        /* ignore */
      }
      const timedOut = await Promise.race([
        exited.then(() => false),
        new Promise((resolve) => setTimeout(() => resolve(true), STOP_TIMEOUT_MS))
      ]);
      if (timedOut) this._killChild(child);
    } finally {
      this._stopping = false;
    }
  }
}
