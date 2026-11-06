#!/usr/bin/env node
// TcAuto launcher (#162): the stable stdio entry point an MCP client registers.
//
//   client  <-- stdio (newline-delimited JSON-RPC) -->  launcher  <-- stdio -->  node <runtime>\mcp-server\index.js
//
// scripts/Install-TcAutoRuntime.ps1 copies this file to <install root>\launcher\tcauto-launcher.mjs
// (only when its content changed) and every runtime to <install root>\runtime\<version>\;
// <install root>\runtime\current.json names the version to run. The install root is
// %TCAUTO_RUNTIME_ROOT% when set, else the parent of the folder this file is in.
//
// The launcher has NO dependencies (node built-ins only) and changes rarely: a new runtime version
// does not need a new client registration. What it does:
//   - starts the runtime named by current.json on the first request (lazily) and forwards every
//     message both ways unchanged, except: the initialize result gets capabilities.tools.listChanged
//     = true and the last tools/list page gets the ReloadRuntime tool appended;
//   - ReloadRuntime (handled here, never forwarded): re-reads current.json, asks the running
//     runtime to retire its PowerShell bridge (request `tcauto/retire`: the same fail-closed retire
//     as ReloadModule, refused while a lifecycle block or unsaved BUILD_REQUIRED entry is held in
//     memory), closes its stdin so it shuts down normally (no kill unless it does not exit in
//     time), starts the new runtime, replays the client's initialize (the answer is swallowed) and
//     notifications/initialized, answers the tool call and sends notifications/tools/list_changed.
//     Refused while a tools/call is still running in the runtime (a lifecycle step must never be
//     cut off). A request that arrives while the reload runs gets an explicit RUNTIME_RELOADING
//     error at once (never queued, never dropped).
//   - a runtime that exits unexpectedly: every request it had not answered gets an error
//     (RUNTIME_DIED); the next request starts the same runtime version again (initialize replayed).
//   - owner id (#152 N1): one GUID per launcher process, passed to every runtime child as
//     TCAUTO_LAUNCHER_OWNER_ID (+ TCAUTO_LAUNCHER_PID = this pid, which index.js checks against its
//     parent pid); index.js uses it as the TCAUTO_OWNER_ID of its PowerShell bridges, so an IDE
//     launched before a ReloadRuntime is still this session's afterwards. It is never read from
//     the environment: a new client connection (new launcher process) gets a new id.
//   - TWINCAT_MODULE_PATH / TWINCAT_MCP_TOOLS_JSON / TWINCAT_MCP_PROBE_SCAN_SCRIPT are removed from
//     the runtime's environment (RUNTIME_OVERRIDE_VARS): a runtime always runs its own copies.
// stdout belongs to the MCP transport: diagnostics go to stderr only.
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const LAUNCHER_VERSION = 1;
const INTERNAL_PREFIX = 'tcauto-launcher:';
// Runtime folder names Install-TcAutoRuntime.ps1 creates: <short sha> or <short sha>-dirty-<UTC stamp>
export const VERSION_RE = /^[0-9a-f]{7,64}(?:-dirty-[0-9]{8}T[0-9]{6}Z)?$/;

export const RELOAD_TOOL = Object.freeze({
  name: 'ReloadRuntime',
  description:
    'Switch the TcAuto MCP server to the runtime version runtime\\current.json names now (#162), without reconnecting the MCP client: ' +
    'install a version first with scripts/Install-TcAutoRuntime.ps1 in the checkout, then call this. ' +
    'The running runtime retires its PowerShell bridge first (same rules as ReloadModule: refused with RELOAD_LIFECYCLE_BLOCKED / RELOAD_BUILD_REQUIRED and nothing changes while the module holds a lifecycle block or unsaved BUILD_REQUIRED entries in memory; report data.lifecycleBlocks to the user, ClearLifecycleBlock only after the user agreed), ' +
    'then the new runtime is started and the tool list is refreshed (notifications/tools/list_changed). ' +
    'Refused with RUNTIME_RELOAD_BUSY while another tool call is still running. Calls made while the reload runs are answered with RUNTIME_RELOADING. ' +
    'The IDE and ADS connections are released (the IDE keeps running): run ConnectIde (and ConnectAds) again afterwards; IDEs this session launched stay owned by it. ' +
    'Returns data.previous and data.current = {version, commit, dirty, branch, installedAt, runtimeDir}; GetStatus data.bridge.runtime shows the version that runs. ' +
    'Within one installed version, ReloadModule (omit ModulePath) reloads only the PowerShell module.',
  inputSchema: { type: 'object', properties: {}, required: [], additionalProperties: false },
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false }
});

/** Install root: %TCAUTO_RUNTIME_ROOT%, else the parent of the folder holding the launcher file. */
export function resolveInstallRoot(env = process.env, launcherFile = fileURLToPath(import.meta.url)) {
  const fromEnv = typeof env.TCAUTO_RUNTIME_ROOT === 'string' ? env.TCAUTO_RUNTIME_ROOT.trim() : '';
  if (fromEnv) return path.resolve(fromEnv);
  return path.resolve(path.dirname(launcherFile), '..');
}

const strOrNull = (v) => (typeof v === 'string' && v.length ? v : null);

/**
 * <install root>\runtime\current.json -> { ok: true, version, runtimeDir, entry, commit, dirty, branch, installedAt }
 * or { ok: false, reason }. The runtime folder is always <install root>\runtime\<version> (a path in
 * the file is never followed), and its mcp-server\index.js must exist.
 */
export function readCurrent(installRoot) {
  const runtimeFolder = path.join(installRoot, 'runtime');
  const file = path.join(runtimeFolder, 'current.json');
  let raw;
  try {
    raw = fs.readFileSync(file, 'utf8').replace(/^﻿/, '');
  } catch (err) {
    return { ok: false, reason: `${file} cannot be read (${err.code ?? err.message})` };
  }
  let cur;
  try {
    cur = JSON.parse(raw);
  } catch (err) {
    return { ok: false, reason: `${file} is not valid JSON (${err.message})` };
  }
  const version = cur && typeof cur === 'object' ? cur.version : undefined;
  if (typeof version !== 'string' || !VERSION_RE.test(version)) {
    return { ok: false, reason: `${file}: version ${JSON.stringify(version)} is not a runtime folder name` };
  }
  const runtimeDir = path.join(runtimeFolder, version);
  const entry = path.join(runtimeDir, 'mcp-server', 'index.js');
  if (!fs.existsSync(entry)) return { ok: false, reason: `${entry} does not exist (runtime ${version} is not installed completely)` };
  return {
    ok: true,
    version,
    runtimeDir,
    entry,
    commit: strOrNull(cur.commit),
    dirty: typeof cur.dirty === 'boolean' ? cur.dirty : null,
    branch: strOrNull(cur.branch),
    installedAt: strOrNull(cur.installedAt)
  };
}

function describe(info) {
  if (!info) return null;
  return {
    version: info.version ?? null,
    commit: info.commit ?? null,
    dirty: info.dirty ?? null,
    branch: info.branch ?? null,
    installedAt: info.installedAt ?? null,
    runtimeDir: info.runtimeDir ?? null
  };
}

function errorBody(code, message, hint, data) {
  const error = { code, message };
  if (hint) error.hint = hint;
  const body = { success: false, error };
  if (data !== undefined) body.data = data;
  return body;
}

/** Same shape as lib/tools.js toToolResult. */
function toolResult(body) {
  return { content: [{ type: 'text', text: JSON.stringify(body, null, 2) }], isError: body.success !== true, structuredContent: body };
}

const idKey = (id) => JSON.stringify(id);
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms).unref?.());

/** Calls onLine for every complete line of a readable stream. */
function readLines(stream, onLine) {
  let buf = '';
  stream.setEncoding('utf8');
  stream.on('data', (chunk) => {
    buf += chunk;
    let nl;
    while ((nl = buf.indexOf('\n')) !== -1) {
      const line = buf.slice(0, nl).replace(/\r$/, '');
      buf = buf.slice(nl + 1);
      if (line.trim()) onLine(line);
    }
  });
}

function killTree(proc) {
  if (!proc || proc.exitCode !== null || proc.signalCode !== null) return;
  if (process.platform === 'win32' && proc.pid) {
    try {
      spawn('taskkill', ['/PID', String(proc.pid), '/T', '/F'], { stdio: 'ignore', windowsHide: true }).on('error', () => {});
      return;
    } catch {
      /* fall back to kill() */
    }
  }
  try {
    proc.kill('SIGKILL');
  } catch {
    /* already gone */
  }
}

// Variables that would make an installed runtime load another module / tool catalog / UIA scan
// script than its own (e.g. a TWINCAT_MODULE_PATH into a OneDrive checkout left in the client
// config): never passed to a runtime child. Compared case-insensitively (Windows environment).
export const RUNTIME_OVERRIDE_VARS = Object.freeze(['TWINCAT_MODULE_PATH', 'TWINCAT_MCP_TOOLS_JSON', 'TWINCAT_MCP_PROBE_SCAN_SCRIPT']);

/** Copy of env without RUNTIME_OVERRIDE_VARS; onDropped(name) for each one that was set. */
export function runtimeEnv(env, onDropped = () => {}) {
  const drop = new Set(RUNTIME_OVERRIDE_VARS.map((n) => n.toUpperCase()));
  const out = {};
  for (const [k, v] of Object.entries(env ?? {})) {
    if (drop.has(k.toUpperCase())) {
      if (v !== undefined && v !== '') onDropped(k);
      continue;
    }
    out[k] = v;
  }
  return out;
}

class StartError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

export class Launcher {
  /**
   * @param {object} [o]
   * @param {import('node:stream').Readable} [o.input]   client -> launcher (default process.stdin)
   * @param {import('node:stream').Writable} [o.output]  launcher -> client (default process.stdout)
   * @param {import('node:stream').Writable} [o.stderr]  runtime stderr and launcher diagnostics (default process.stderr)
   * @param {string} [o.installRoot]   default resolveInstallRoot()
   * @param {object} [o.env]           environment for the runtime child (default process.env)
   * @param {string} [o.nodePath]      node executable for the runtime (default process.execPath)
   * @param {number} [o.initTimeoutMs] replayed initialize must be answered within this (default 60 s)
   * @param {number} [o.retireTimeoutMs] tcauto/retire must be answered within this (default 150 s:
   *   index.js gives the bridge retire 90 s and waits up to 15 s for the PowerShell exit)
   * @param {number} [o.exitTimeoutMs] a retired runtime must exit within this after stdin is closed (default 20 s)
   */
  constructor(o = {}) {
    this.input = o.input ?? process.stdin;
    this.output = o.output ?? process.stdout;
    this.stderr = o.stderr ?? process.stderr;
    this.installRoot = o.installRoot ?? resolveInstallRoot();
    this.env = o.env ?? process.env;
    this.nodePath = o.nodePath ?? process.execPath;
    this.initTimeoutMs = o.initTimeoutMs ?? 60000;
    this.retireTimeoutMs = o.retireTimeoutMs ?? 150000;
    this.exitTimeoutMs = o.exitTimeoutMs ?? 20000;
    this.ownerId = randomUUID();

    this.child = null; // { proc, info, pending: Map, ready, retiring, gone, exited }
    this.runtime = null; // version the next (re)start uses; null = read current.json
    this.clientInit = null; // params of the client's initialize
    this.initForwarded = false;
    this.reloading = false;
    this.starting = null;
    this.waiting = [];
    this.internal = new Map(); // internal request id -> { child, resolve, timer }
    this.childRequests = new Map(); // id of a runtime -> client request -> child
    this.nextInternal = 1;
    this.closed = false;
  }

  log(message) {
    try {
      this.stderr.write(`[tcauto-launcher] ${message}\n`);
    } catch {
      /* stderr gone */
    }
  }

  start() {
    // the owner of the input stream calls close() when it ends (main: stdin 'end' below)
    readLines(this.input, (line) => this.onClientLine(line));
    this.log(`launcher ${LAUNCHER_VERSION}, install root ${this.installRoot}`);
    return this;
  }

  // ------------------------------------------------------------ output

  sendClient(msg) {
    if (this.closed) return;
    try {
      this.output.write(JSON.stringify(msg) + '\n');
    } catch (err) {
      this.log(`cannot write to the client: ${err.message}`);
    }
  }

  replyError(id, code, message, data) {
    const error = { code, message };
    if (data !== undefined) error.data = data;
    this.sendClient({ jsonrpc: '2.0', id, error });
  }

  replyTool(id, body) {
    this.sendClient({ jsonrpc: '2.0', id, result: toolResult(body) });
  }

  writeChild(child, msg) {
    try {
      child.proc.stdin.write(JSON.stringify(msg) + '\n');
      return true;
    } catch (err) {
      this.log(`cannot write to runtime ${child.info.version}: ${err.message}`);
      return false;
    }
  }

  // ------------------------------------------------------------ client -> launcher

  onClientLine(line) {
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      this.log('dropped a client line that is not JSON');
      return;
    }
    if (Array.isArray(msg)) {
      for (const m of msg) this.onClientMessage(m);
    } else {
      this.onClientMessage(msg);
    }
  }

  onClientMessage(msg) {
    if (!msg || typeof msg !== 'object') return;
    const hasId = msg.id !== undefined && msg.id !== null;
    if (typeof msg.method !== 'string') {
      // a response to a request a runtime sent to the client
      if (!hasId) return;
      const child = this.childRequests.get(idKey(msg.id));
      this.childRequests.delete(idKey(msg.id));
      if (child && !child.gone) this.writeChild(child, msg);
      return;
    }
    if (!hasId) {
      this.onClientNotification(msg);
      return;
    }
    const method = msg.method;
    if (method === 'ping') {
      this.sendClient({ jsonrpc: '2.0', id: msg.id, result: {} });
      return;
    }
    if (method.startsWith('tcauto/')) {
      this.replyError(msg.id, -32601, `Method not found: ${method}`);
      return;
    }
    if (method === 'tools/call' && msg.params?.name === RELOAD_TOOL.name) {
      this.reload(msg).catch((err) => {
        this.log(`ReloadRuntime crashed: ${err?.stack ?? err}`);
        this.replyTool(msg.id, errorBody('INTERNAL_ERROR', `ReloadRuntime: ${err?.message ?? String(err)}`));
      });
      return;
    }
    if (method === 'initialize') this.clientInit = msg.params ?? {};
    this.route(msg);
  }

  onClientNotification(msg) {
    if (this.reloading) return; // nothing of the old runtime is waiting for it, the new one replays its own
    if (this.child?.ready) {
      this.writeChild(this.child, msg);
      return;
    }
    if (this.starting) this.waiting.push(msg);
    else if (this.child) this.writeChild(this.child, msg);
  }

  refuseDuringReload(msg) {
    const message = `${msg.method === 'tools/call' ? msg.params?.name ?? 'tools/call' : msg.method} NOT RUN: ReloadRuntime is switching the runtime right now.`;
    if (msg.method === 'tools/call') {
      this.replyTool(msg.id, errorBody('RUNTIME_RELOADING', message, 'Wait until ReloadRuntime has returned, then call again (after ConnectIde: the reload releases the IDE connection).'));
    } else {
      this.replyError(msg.id, -32000, `RUNTIME_RELOADING: ${message}`);
    }
  }

  route(msg) {
    if (this.reloading) {
      this.refuseDuringReload(msg);
      return;
    }
    if (this.child?.ready && !this.child.gone) {
      this.forward(this.child, msg);
      return;
    }
    this.waiting.push(msg);
    this.ensureChild();
  }

  forward(child, msg) {
    child.pending.set(idKey(msg.id), { method: msg.method, name: msg.method === 'tools/call' ? msg.params?.name ?? null : null });
    if (msg.method === 'initialize') this.initForwarded = true;
    if (!this.writeChild(child, msg)) this.onChildGone(child, 'stdin not writable');
  }

  ensureChild() {
    if (this.starting) return;
    const replay = this.initForwarded && this.clientInit !== null;
    this.starting = this.startChild(this.runtime, { replay })
      .then(
        (child) => {
          const items = this.waiting.splice(0);
          for (const m of items) {
            if (m.id !== undefined && m.id !== null) this.forward(child, m);
            else this.writeChild(child, m);
          }
        },
        (err) => {
          const items = this.waiting.splice(0);
          this.log(`runtime start failed: ${err.message}`);
          for (const m of items) {
            if (m.id === undefined || m.id === null) continue;
            const hint =
              err.code === 'RUNTIME_NOT_INSTALLED'
                ? 'Run scripts/Install-TcAutoRuntime.ps1 in the TcAuto checkout, then call again.'
                : 'Check the launcher stderr (MCP client log); run scripts/Install-TcAutoRuntime.ps1 again if the runtime is damaged. The next call tries to start it again.';
            if (m.method === 'tools/call') this.replyTool(m.id, errorBody(err.code, `${m.params?.name ?? 'tools/call'} NOT RUN: ${err.message}`, hint));
            else this.replyError(m.id, -32000, `${err.code}: ${err.message}. ${hint}`);
          }
        }
      )
      .finally(() => {
        this.starting = null;
      });
  }

  // ------------------------------------------------------------ runtime child

  /** Spawn a runtime (info, or current.json when null / gone), optionally replay initialize. */
  async startChild(info, { replay }) {
    let target = info;
    if (!target || !fs.existsSync(target.entry)) {
      const cur = readCurrent(this.installRoot);
      if (!cur.ok) throw new StartError('RUNTIME_NOT_INSTALLED', cur.reason);
      target = cur;
    }
    const env = runtimeEnv(this.env, (name) => this.log(`${name} is not passed to the runtime: it runs its own module and tools.json (#162)`));
    env.TCAUTO_LAUNCHER_OWNER_ID = this.ownerId;
    env.TCAUTO_LAUNCHER_PID = String(process.pid);
    let proc;
    try {
      proc = spawn(this.nodePath, [target.entry], { cwd: path.dirname(target.entry), env, stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
    } catch (err) {
      throw new StartError('RUNTIME_START_FAILED', `cannot start ${target.entry}: ${err.message}`);
    }
    const child = { proc, info: target, pending: new Map(), ready: false, retiring: false, gone: false, exited: null };
    child.exited = new Promise((resolve) => proc.once('exit', (code, signal) => resolve({ code, signal })));
    proc.once('exit', (code, signal) => this.onChildGone(child, `exited with code ${code}${signal ? `, signal ${signal}` : ''}`));
    proc.once('error', (err) => this.onChildGone(child, `process error: ${err.message}`));
    proc.stdin.on('error', () => {});
    readLines(proc.stdout, (line) => this.onChildLine(child, line));
    proc.stderr.on('data', (d) => {
      try {
        this.stderr.write(d);
      } catch {
        /* ignore */
      }
    });
    this.child = child;
    this.log(`runtime ${target.version} (${target.commit ?? 'commit unknown'}${target.dirty ? ', dirty' : ''}) started, pid ${proc.pid}`);

    if (replay) {
      const res = await this.internalRequest(child, 'initialize', this.clientInit ?? {}, this.initTimeoutMs);
      if (res.error || child.gone) {
        killTree(proc);
        this.onChildGone(child, 'initialize replay failed');
        throw new StartError('RUNTIME_START_FAILED', `runtime ${target.version} did not answer initialize: ${res.error?.message ?? 'it exited'}`);
      }
      this.writeChild(child, { jsonrpc: '2.0', method: 'notifications/initialized' });
    }
    child.ready = true;
    this.runtime = target;
    return child;
  }

  internalRequest(child, method, params, timeoutMs) {
    const id = `${INTERNAL_PREFIX}${this.nextInternal++}`;
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.internal.delete(id);
        resolve({ error: { code: -32001, message: `${method} not answered within ${timeoutMs} ms` }, timedOut: true });
      }, timeoutMs);
      this.internal.set(id, { child, resolve, timer });
      if (!this.writeChild(child, { jsonrpc: '2.0', id, method, params })) {
        clearTimeout(timer);
        this.internal.delete(id);
        resolve({ error: { code: -32002, message: 'runtime stdin not writable' }, gone: true });
      }
    });
  }

  onChildLine(child, line) {
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      this.log(`runtime ${child.info.version} wrote a stdout line that is not JSON (dropped)`);
      return;
    }
    if (!msg || typeof msg !== 'object') return;
    const hasId = msg.id !== undefined && msg.id !== null;
    if (typeof msg.method !== 'string') {
      if (!hasId) return;
      if (typeof msg.id === 'string' && msg.id.startsWith(INTERNAL_PREFIX)) {
        const w = this.internal.get(msg.id);
        if (w) {
          this.internal.delete(msg.id);
          clearTimeout(w.timer);
          w.resolve(msg);
        }
        return;
      }
      const meta = child.pending.get(idKey(msg.id));
      child.pending.delete(idKey(msg.id));
      if (meta?.method === 'initialize' && msg.result && typeof msg.result === 'object') {
        const caps = msg.result.capabilities && typeof msg.result.capabilities === 'object' ? msg.result.capabilities : {};
        msg.result.capabilities = { ...caps, tools: { ...(caps.tools ?? {}), listChanged: true } };
      } else if (meta?.method === 'tools/list' && Array.isArray(msg.result?.tools) && !msg.result.nextCursor) {
        if (!msg.result.tools.some((t) => t?.name === RELOAD_TOOL.name)) msg.result.tools.push({ ...RELOAD_TOOL });
      }
      this.sendClient(msg);
      return;
    }
    if (hasId) this.childRequests.set(idKey(msg.id), child); // runtime -> client request
    this.sendClient(msg);
  }

  /** The runtime process is gone (exit, spawn error, retired): answer everything it still owed. */
  onChildGone(child, reason) {
    if (child.gone) return;
    child.gone = true;
    child.ready = false;
    if (this.child === child) this.child = null;
    for (const [id, w] of this.internal) {
      if (w.child !== child) continue;
      this.internal.delete(id);
      clearTimeout(w.timer);
      w.resolve({ error: { code: -32002, message: `runtime ${reason}` }, gone: true });
    }
    for (const [k, c] of this.childRequests) if (c === child) this.childRequests.delete(k);
    const owed = [...child.pending.entries()];
    child.pending.clear();
    if (!child.retiring) this.log(`runtime ${child.info.version} ${reason}; ${owed.length} request(s) unanswered`);
    for (const [k, meta] of owed) {
      const id = JSON.parse(k);
      if (child.retiring) {
        const message = `${meta.name ?? meta.method} was not answered: ReloadRuntime retired the runtime that had it.`;
        if (meta.method === 'tools/call') this.replyTool(id, errorBody('RUNTIME_RELOADING', message, 'Call it again.'));
        else this.replyError(id, -32000, `RUNTIME_RELOADING: ${message}`);
        continue;
      }
      if (meta.method === 'tools/call') {
        this.replyTool(
          id,
          errorBody(
            'RUNTIME_DIED',
            `${meta.name ?? 'tools/call'}: the TcAuto runtime process (node, ${child.info.version}) ${reason} before it answered. The call may or may not have run.`,
            'The next call starts the runtime again (all IDE/ADS state is lost): check GetStatus / GetPlcState before repeating a state-changing call, and run ConnectIde again.'
          )
        );
      } else {
        this.replyError(id, -32000, `RUNTIME_DIED: the TcAuto runtime process ${reason} before it answered ${meta.method}; the next request starts it again.`);
      }
    }
  }

  // ------------------------------------------------------------ ReloadRuntime

  async reload(req) {
    const id = req.id;
    if (this.reloading) {
      this.replyTool(id, errorBody('RUNTIME_RELOADING', 'ReloadRuntime NOT RUN: another ReloadRuntime is running.', 'Wait until it has returned.'));
      return;
    }
    if (this.starting) {
      this.replyTool(id, errorBody('RUNTIME_RELOAD_BUSY', 'ReloadRuntime NOT RUN: the runtime is starting right now. Nothing was changed.', 'Call ReloadRuntime again in a moment.'));
      return;
    }
    if (this.clientInit === null) {
      this.replyTool(id, errorBody('RUNTIME_NOT_INITIALIZED', 'ReloadRuntime NOT RUN: the client has not sent initialize yet.', 'Initialize the MCP session first.'));
      return;
    }
    const running = this.child && !this.child.gone ? [...this.child.pending.values()].filter((p) => p.method === 'tools/call') : [];
    if (running.length > 0) {
      const names = running.map((p) => p.name ?? '?');
      this.replyTool(
        id,
        errorBody(
          'RUNTIME_RELOAD_BUSY',
          `ReloadRuntime NOT RUN: ${running.length} tool call(s) still running (${names.join(', ')}). Nothing was changed.`,
          'Wait until those calls have returned (a lifecycle step such as BuildProject / EnableConfig / RunLifecycle must not be cut off), then ReloadRuntime again.',
          { running: names, notRun: true }
        )
      );
      return;
    }
    const next = readCurrent(this.installRoot);
    const previous = this.child && !this.child.gone ? this.child.info : this.runtime;
    if (!next.ok) {
      this.replyTool(
        id,
        errorBody('RUNTIME_NOT_INSTALLED', `ReloadRuntime NOT RUN: ${next.reason}. Nothing was changed.`, 'Run scripts/Install-TcAutoRuntime.ps1 in the TcAuto checkout, then ReloadRuntime again.', {
          installRoot: this.installRoot,
          previous: describe(previous),
          notRun: true
        })
      );
      return;
    }

    this.reloading = true;
    try {
      let retired = null;
      const old = this.child && !this.child.gone ? this.child : null;
      if (old) {
        const r = await this.internalRequest(old, 'tcauto/retire', {}, this.retireTimeoutMs);
        if (r.timedOut) {
          this.replyTool(
            id,
            errorBody(
              'RUNTIME_RETIRE_TIMEOUT',
              `ReloadRuntime NOT RUN: runtime ${old.info.version} did not answer the retire request within ${this.retireTimeoutMs} ms. It keeps running.`,
              'Call GetStatus; if the runtime still works, ReloadRuntime again later. If it answers RUNTIME_RETIRED, ReloadRuntime again (the retire finished late).',
              { previous: describe(old.info), requested: describe(next), notRun: true }
            )
          );
          return;
        }
        if (r.error && !r.gone) {
          const unsupported = r.error.code === -32601;
          this.replyTool(
            id,
            errorBody(
              unsupported ? 'RUNTIME_RETIRE_UNSUPPORTED' : 'RUNTIME_RETIRE_FAILED',
              `ReloadRuntime NOT RUN: runtime ${old.info.version} ${unsupported ? 'does not support the retire request (older runtime)' : `refused the retire request: ${r.error.message}`}. Nothing was changed.`,
              unsupported
                ? 'Restart the MCP client connection (e.g. /mcp reconnect in Claude Code) to start the new runtime; the PowerShell bridge then shuts down normally.'
                : 'Report the error; GetStatus shows the runtime that still runs.',
              { previous: describe(old.info), requested: describe(next), notRun: true }
            )
          );
          return;
        }
        if (!r.gone) {
          const res = r.result;
          if (!res || res.success !== true) {
            const extra = res?.data && typeof res.data === 'object' && !Array.isArray(res.data) ? res.data : {};
            this.replyTool(id, {
              ...(res && typeof res === 'object' ? res : errorBody('RUNTIME_RETIRE_FAILED', 'ReloadRuntime NOT RUN: the retire request returned no result.')),
              success: false,
              data: { ...extra, previous: describe(old.info), requested: describe(next), notRun: true }
            });
            return;
          }
          retired = res.data ?? null;
        }
        old.retiring = true;
        try {
          old.proc.stdin.end();
        } catch {
          /* already closed */
        }
        const exited = await Promise.race([old.exited.then(() => true), delay(this.exitTimeoutMs).then(() => false)]);
        if (!exited) {
          this.log(`runtime ${old.info.version} did not exit within ${this.exitTimeoutMs} ms after the retire; killing it`);
          killTree(old.proc);
          await Promise.race([old.exited, delay(5000)]);
        }
        this.onChildGone(old, 'retired');
      }

      let startError = null;
      try {
        await this.startChild(next, { replay: true });
      } catch (err) {
        startError = err;
      }
      if (startError) {
        let restored = false;
        let restoreError = null;
        if (previous && previous.version !== next.version && fs.existsSync(previous.entry)) {
          try {
            await this.startChild(previous, { replay: true });
            restored = true;
          } catch (err) {
            restoreError = err.message;
          }
        }
        if (!restored) this.runtime = null;
        this.replyTool(
          id,
          errorBody(
            'RUNTIME_START_FAILED',
            `ReloadRuntime: the old runtime was retired but ${next.version} did not start (${startError.message}).`,
            restored
              ? 'The previous runtime runs again (data.current). Run scripts/Install-TcAutoRuntime.ps1 again, then ReloadRuntime. Run ConnectIde again either way.'
              : 'No runtime runs now: the next call starts the runtime current.json names. Check the launcher stderr (MCP client log) and run scripts/Install-TcAutoRuntime.ps1 again.',
            { previous: describe(previous), requested: describe(next), current: restored ? describe(previous) : null, restored, restoreError, retired }
          )
        );
        if (restored) this.sendClient({ jsonrpc: '2.0', method: 'notifications/tools/list_changed' });
        return;
      }

      const note = 'The IDE and ADS connections were released (the IDE keeps running). Run ConnectIde again (and ConnectAds) before any IDE or ADS tool; IDEs this session launched are still owned by it.';
      this.replyTool(id, {
        success: true,
        data: {
          previous: describe(previous),
          current: describe(next),
          changed: (previous?.version ?? null) !== next.version,
          retired,
          reconnectRequired: true,
          hint: 'Run ConnectIde again.',
          note
        }
      });
      this.sendClient({ jsonrpc: '2.0', method: 'notifications/tools/list_changed' });
    } finally {
      this.reloading = false;
    }
  }

  // ------------------------------------------------------------ shutdown

  /** Client went away: let the runtime shut down normally (stdin closed), kill it only if it hangs. */
  async close(reason = 'close') {
    if (this.closed) return;
    this.closed = true;
    const child = this.child;
    if (child && !child.gone) {
      this.log(`${reason}; stopping runtime ${child.info.version}`);
      child.retiring = true;
      try {
        child.proc.stdin.end();
      } catch {
        /* ignore */
      }
      const exited = await Promise.race([child.exited.then(() => true), delay(this.exitTimeoutMs).then(() => false)]);
      if (!exited) killTree(child.proc);
    }
  }
}

function isMain() {
  if (!process.argv[1]) return false;
  try {
    const me = fs.realpathSync(fileURLToPath(import.meta.url)).toLowerCase();
    const arg = fs.realpathSync(path.resolve(process.argv[1])).toLowerCase();
    return me === arg;
  } catch {
    return false;
  }
}

if (isMain()) {
  const launcher = new Launcher().start();
  const stop = (why) => launcher.close(why).finally(() => process.exit(0));
  process.stdin.on('end', () => stop('stdin closed'));
  process.on('SIGINT', () => stop('SIGINT'));
  process.on('SIGTERM', () => stop('SIGTERM'));
  process.on('uncaughtException', (err) => launcher.log(`uncaught exception: ${err?.stack ?? err}`));
  process.on('unhandledRejection', (err) => launcher.log(`unhandled rejection: ${err?.stack ?? err}`));
}
