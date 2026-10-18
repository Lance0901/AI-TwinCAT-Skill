// Modal-dialog probe: a short-lived powershell.exe (bridge/modal-probe.ps1) that watches the IDE
// process while the bridge is blocked inside a long DTE call. A modal dialog in XAE ("Assertion
// Failed", "TwinCAT PLC Control", license prompt, ...) blocks the synchronous COM call forever; the
// probe sees it via UI Automation from outside and reports it as one JSON line on stdout:
//   {"title":"...","text":"...","className":"...","isModal":true,"processId":1234}
// index.js then kills the bridge (lib/bridge.js abortCall) and returns IDE_MODAL_DIALOG instead of
// waiting for the tools.json timeout (BRIDGE_TIMEOUT). See PROTOCOL.md "Modal-dialog probe".
//
// A probe failure (spawn error, crash, garbage on stdout) is only reported through onError: it never
// affects the tool call it accompanies.
import { spawn } from 'node:child_process';
import readline from 'node:readline';
import { DEFAULT_PROBE_SCRIPT, DEFAULT_PROBE_INTERVAL_SEC, defaultPowershellPath } from './config.js';

export { DEFAULT_PROBE_SCRIPT, DEFAULT_PROBE_INTERVAL_SEC };

/**
 * Catalog tools that run long DTE calls and get a probe. RunLifecycle is not listed: it is a
 * composite whose steps (ConnectIde, BuildProject, EnableConfig, ...) go through callCatalogTool
 * and are probed one by one.
 */
export const PROBED_TOOLS = new Set(['BuildProject', 'EnableConfig', 'PlcLogin', 'SendPlcProgram', 'RunTestCycle', 'OpenProject', 'ConnectIde']);

const KILL_ESCALATE_MS = 1000;

function isAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

/**
 * Command line of the probe. With a spawnSpec override (tests) its args come first and the same
 * -ProcessId / -IntervalSec pair is appended, so a mock parses the same argv as the real script.
 * @returns {{command:string, args:string[]}}
 */
export function buildProbeSpawnSpec({ powershellPath, probeScript, spawnSpec, pid, intervalSec } = {}) {
  const tail = ['-ProcessId', String(pid), '-IntervalSec', String(intervalSec ?? DEFAULT_PROBE_INTERVAL_SEC)];
  if (spawnSpec && spawnSpec.command) return { command: spawnSpec.command, args: [...(spawnSpec.args ?? []), ...tail] };
  return {
    command: powershellPath ?? defaultPowershellPath(),
    args: ['-NoProfile', '-NonInteractive', '-STA', '-ExecutionPolicy', 'Bypass', '-File', probeScript ?? DEFAULT_PROBE_SCRIPT, ...tail]
  };
}

export class ModalProbe {
  /**
   * @param {object} opts
   * @param {number} opts.pid                 IDE process id to watch
   * @param {number} [opts.intervalSec]       scan interval (default 5)
   * @param {string} [opts.powershellPath]
   * @param {string} [opts.probeScript]
   * @param {{command:string,args:string[]}|null} [opts.spawnSpec]  test override
   * @param {object} [opts.env]               extra environment (merged over process.env)
   * @param {(dialog:{title:string,text:string,className:any,isModal:any,processId:any})=>void} [opts.onDialog]
   * @param {(message:string)=>void} [opts.onError]
   * @param {(message:string)=>void} [opts.onDebug]
   */
  constructor(opts = {}) {
    this.opts = opts;
    this.child = null;
    this._stopped = false;
    this._reported = false;
    this._exited = false;
    this._errored = false;
    this.onDialog = typeof opts.onDialog === 'function' ? opts.onDialog : () => {};
    this.onError = typeof opts.onError === 'function' ? opts.onError : () => {};
    this.onDebug = typeof opts.onDebug === 'function' ? opts.onDebug : () => {};
  }

  get pid() {
    return this.child?.pid ?? null;
  }

  get running() {
    return this.child !== null && !this._exited;
  }

  _safe(fn) {
    try {
      fn();
    } catch {
      /* callbacks must never break the probe or the tool call */
    }
  }

  /** Spawn the probe. Returns this. Never throws. */
  start() {
    if (this.child || this._stopped) return this;
    const { command, args } = buildProbeSpawnSpec({ ...this.opts, pid: this.opts.pid, intervalSec: this.opts.intervalSec });
    let child;
    try {
      child = spawn(command, args, {
        stdio: ['ignore', 'pipe', 'pipe'],
        windowsHide: true,
        env: { ...process.env, ...(this.opts.env ?? {}) }
      });
    } catch (err) {
      this._safe(() => this.onError(`[modal-probe] spawn failed: ${err.message}`));
      return this;
    }
    this.child = child;
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');

    child.on('error', (err) => {
      this._exited = true;
      this._errored = true;
      this._safe(() => this.onError(`[modal-probe] ${err.message}`));
    });

    const stderrRl = readline.createInterface({ input: child.stderr, crlfDelay: Infinity });
    stderrRl.on('line', (line) => {
      if (line.trim()) this._safe(() => this.onError(`[modal-probe] ${line}`));
    });

    let firstLine = true;
    const stdoutRl = readline.createInterface({ input: child.stdout, crlfDelay: Infinity });
    stdoutRl.on('line', (line) => {
      const trimmed = line.trim();
      if (!trimmed || !firstLine) return;
      firstLine = false;
      this._onLine(trimmed);
    });

    child.once('close', (code, signal) => {
      this._exited = true;
      if (this._reported || this._stopped || this._errored) return; // a failed spawn was already reported by 'error'
      if (code !== 0 && code !== null) this._safe(() => this.onError(`[modal-probe] probe exited with code ${code}`));
      else this._safe(() => this.onDebug(`[modal-probe] probe exited (code ${code}, signal ${signal})`));
    });
    return this;
  }

  _onLine(line) {
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      this._safe(() => this.onError(`[modal-probe] non-JSON stdout line: ${line.slice(0, 200)}`));
      return;
    }
    if (!msg || typeof msg !== 'object' || Array.isArray(msg) || typeof msg.title !== 'string' || !msg.title.trim()) {
      this._safe(() => this.onError(`[modal-probe] unexpected stdout line: ${line.slice(0, 200)}`));
      return;
    }
    if (this._reported || this._stopped) return;
    this._reported = true;
    const dialog = {
      title: msg.title,
      text: String(msg.text ?? ''),
      className: msg.className ?? null,
      isModal: msg.isModal ?? null,
      processId: msg.processId ?? null
    };
    this._safe(() => this.onDialog(dialog));
    this.stop();
  }

  /** Kill the probe (idempotent, fire-and-forget, never throws). */
  stop() {
    if (this._stopped) return;
    this._stopped = true;
    const child = this.child;
    if (!child || this._exited || child.exitCode !== null || child.signalCode !== null) return;
    const pid = child.pid;
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
}

/** Convenience: new ModalProbe(opts).start(). */
export function startModalProbe(opts) {
  return new ModalProbe(opts).start();
}
