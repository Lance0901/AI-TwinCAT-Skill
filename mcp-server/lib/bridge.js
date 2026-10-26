// PowerShellBridge: owns the single long-lived powershell.exe child described in PROTOCOL.md.
// All calls are serialised FIFO; every call() resolves to a result object and never rejects.
import { spawn } from 'node:child_process';
import readline from 'node:readline';
import { DEFAULT_BRIDGE_SCRIPT, DEFAULT_MODULE_PATH, MAX_CALL_TIMEOUT_MS, defaultPowershellPath } from './config.js';

export const START_TIMEOUT_MS = 60000;
export const STOP_TIMEOUT_MS = 5000;
const KILL_ESCALATE_MS = 1000;

export const HINTS = {
  BRIDGE_TIMEOUT:
    'PowerShell bridge was restarted and all IDE/ADS state is lost. Check for a modal dialog in the XAE window (GetIdeModalDialog after ConnectIde), then ConnectIde again.',
  BRIDGE_DIED:
    'PowerShell bridge process exited and all IDE/ADS state is lost. It restarts on the next call; run ConnectIde again.',
  MODULE_IMPORT_FAILED:
    'The PowerShell bridge could not start. Check TWINCAT_MODULE_PATH / TWINCAT_MCP_POWERSHELL and the bridge stderr output.'
};

/** Message of the CANCELLED result a queued call gets when its AbortSignal fires before dispatch. */
export const CANCELLED_MESSAGE = 'Request cancelled before it was sent to PowerShell; nothing was executed.';

/** Suffix for BRIDGE_DIED results of calls that were still queued (never reached PowerShell). */
const NOT_EXECUTED = 'this call was not executed; safe to retry after reconnecting';

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
   * @param {{command:string,args:string[]}} [options.spawnSpec]  replaces the powershell.exe command line entirely (tests)
   * @param {(level:string,message:string,meta:object)=>void} [options.onLog]
   * @param {(line:string)=>void} [options.onStderr]
   */
  constructor(options = {}) {
    this.modulePath = options.modulePath ?? process.env.TWINCAT_MODULE_PATH ?? DEFAULT_MODULE_PATH;
    this.powershellPath = options.powershellPath ?? defaultPowershellPath();
    this.bridgeScript = options.bridgeScript ?? DEFAULT_BRIDGE_SCRIPT;
    this.env = options.env ?? {};
    this.spawnSpec = options.spawnSpec ?? null;
    this.onLog = typeof options.onLog === 'function' ? options.onLog : () => {};
    this.onStderr = typeof options.onStderr === 'function' ? options.onStderr : () => {};

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
        env: { ...process.env, ...this.env }
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
    this.lastStartError = null;
    adopted = true;
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
    this._settle(current, result);
    this._pump();
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
   * @param {'call'|'modal'|'state'|'ping'|'shutdown'} op
   * @param {{cmdlet?:string, params?:object, timeoutMs?:number, signal?:AbortSignal, token?:object}} [opts]
   *   signal: while the call is still queued, an abort removes it from the queue and resolves it with
   *   CANCELLED (nothing was executed). Once the request has been written to PowerShell it cannot be
   *   interrupted: the abort is ignored and the real result is returned when the cmdlet finishes.
   *   token: any object identifying this call for abortCall() (the modal-dialog probe in index.js).
   */
  call(op = 'call', opts = {}) {
    const { cmdlet, params, timeoutMs, signal, token } = opts;
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
        token: token ?? null
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
