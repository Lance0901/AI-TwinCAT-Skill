#!/usr/bin/env node
// TwinCAT Automation MCP server (stdio). stdout belongs to the MCP transport: log only via console.error.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { CallToolRequestSchema, ListToolsRequestSchema } from '@modelcontextprotocol/sdk/types.js';

import { loadConfig } from './lib/config.js';
import { PowerShellBridge, errorResult } from './lib/bridge.js';
import { loadToolCatalog, validateParams, computeTimeoutMs, toToolResult } from './lib/tools.js';
import { composites } from './lib/composites.js';
import { isIdeProcessAlive } from './lib/ide-process.js';
import { ModalProbe, PROBED_TOOLS } from './lib/modal-probe.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const pkg = JSON.parse(fs.readFileSync(path.join(__dirname, 'package.json'), 'utf8'));

const config = loadConfig(process.env);

let catalog;
try {
  catalog = loadToolCatalog(config.toolsJsonPath);
} catch (err) {
  console.error(`[tcauto-mcp] cannot load tools.json (${config.toolsJsonPath}): ${err.message}`);
  console.error('[tcauto-mcp] run "npm run generate-tools" or set TWINCAT_MCP_TOOLS_JSON');
  process.exit(1);
}

const compositeMap = new Map(composites.map((c) => [c.name, c]));
for (const name of compositeMap.keys()) {
  if (catalog.has(name)) console.error(`[tcauto-mcp] composite tool "${name}" shadows a catalog tool of the same name`);
}

// ---------------------------------------------------------------- logging

const server = new Server(
  { name: 'tcauto', version: pkg.version },
  { capabilities: { tools: {}, logging: {} } }
);

const LEVELS = new Set(['debug', 'info', 'notice', 'warning', 'error', 'critical', 'alert', 'emergency']);
let connected = false;
const pendingLogs = [];
const MAX_PENDING_LOGS = 200;

function mapLevel(level) {
  const l = String(level ?? 'info').toLowerCase();
  if (LEVELS.has(l)) return l;
  if (l === 'warn') return 'warning';
  if (l === 'verbose') return 'debug';
  return 'info';
}

function emitLog(level, data) {
  const params = { level: mapLevel(level), logger: 'tcauto', data };
  if (!connected) {
    if (pendingLogs.length < MAX_PENDING_LOGS) pendingLogs.push(params);
    return;
  }
  server.sendLoggingMessage(params).catch(() => {});
}

function flushPendingLogs() {
  const items = pendingLogs.splice(0);
  for (const params of items) server.sendLoggingMessage(params).catch(() => {});
}

const bridge = new PowerShellBridge({
  modulePath: config.modulePath,
  powershellPath: config.powershellPath,
  bridgeScript: config.bridgeScript,
  spawnSpec: config.spawnSpec,
  env: config.verbose ? { TWINCAT_MCP_VERBOSE: '1' } : {},
  onLog: (level, message, meta) => emitLog(level, { message, ...meta }),
  onStderr: (line) => {
    if (config.verbose) console.error(`[bridge] ${line}`);
    emitLog('error', { message: line, source: 'stderr' });
  }
});

// ---------------------------------------------------------------- tools

function listTools() {
  const tools = [];
  const entry = (name, description, inputSchema, annotations) => {
    const t = { name, description, inputSchema };
    // MCP tool annotations (readOnlyHint / destructiveHint / ...) pass through unchanged when present.
    if (annotations && typeof annotations === 'object' && !Array.isArray(annotations)) t.annotations = annotations;
    return t;
  };
  for (const tool of catalog.values()) {
    tools.push(entry(tool.name, tool.description ?? tool.cmdlet, tool.inputSchema, tool.annotations));
  }
  for (const c of composites) {
    tools.push(entry(c.name, c.description, c.inputSchema, c.annotations));
  }
  return tools;
}

// ---------------------------------------------------------------- last known IDE
//
// The bridge loses the IDE pid when it is killed after a BRIDGE_TIMEOUT (a DTE call blocked by a
// modal dialog). Remember the last successful ConnectIde here so the error can still name the IDE.

/** @type {{ideProcessId:number|null, selectedBy:string|null, solution:string|null}|null} */
let lastIde = null;

function rememberIde(name, result) {
  if (result?.success !== true) return;
  if (name === 'ConnectIde') {
    const d = result.data ?? {};
    lastIde = {
      ideProcessId: Number.isInteger(d.ideProcessId) && d.ideProcessId > 0 ? d.ideProcessId : null,
      selectedBy: typeof d.selectedBy === 'string' ? d.selectedBy : null,
      solution: typeof d.solution === 'string' && d.solution.length ? d.solution : null
    };
  } else if (name === 'DisconnectIde') {
    lastIde = null;
  }
}

const BRIDGE_LOST_CODES = new Set(['BRIDGE_TIMEOUT', 'BRIDGE_DIED']);

function ideHint(ide) {
  const pid = ide?.ideProcessId;
  if (!pid) return null;
  if (ide.selectedBy === 'launched') {
    return (
      `The IDE (pid ${pid}, launched by this server) is probably blocked by a modal dialog. ` +
      `Kill it with \`taskkill /PID ${pid} /T /F\`, then ConnectIde again. Unsaved changes in that IDE will be lost; ask the user before killing it.`
    );
  }
  return `The IDE (pid ${pid}) was opened by the user; check its window for a modal dialog, dismiss it, then ConnectIde again.`;
}

/**
 * BRIDGE_TIMEOUT / BRIDGE_DIED: attach the last known IDE and a hint that names it. Idempotent.
 * The pid is verified first (tasklist: alive and TcXaeShell.exe / devenv.exe); a stale lastIde is
 * forgotten and the generic hint kept, so the hint never tells the user to taskkill a recycled pid.
 */
async function decorateBridgeLoss(result) {
  if (!result || result.success === true || !BRIDGE_LOST_CODES.has(result.error?.code)) return result;
  if (result.data && typeof result.data === 'object' && result.data.bridgeRestarted === true) return result;
  if (lastIde?.ideProcessId && !(await isIdeProcessAlive(lastIde.ideProcessId))) {
    console.error(`[tcauto-mcp] lastIde pid ${lastIde.ideProcessId} is not a running XAE/devenv any more; forgetting it`);
    lastIde = null;
  }
  const data = { ...(result.data && typeof result.data === 'object' ? result.data : {}), lastIde: lastIde ? { ...lastIde } : null, bridgeRestarted: true };
  const hint = ideHint(lastIde);
  const error = hint ? { ...result.error, hint } : result.error;
  return { ...result, error, data };
}

// ---------------------------------------------------------------- modal-dialog probe
//
// A modal dialog in XAE blocks the DTE call inside the bridge forever. For the long-running tools
// in PROBED_TOOLS a separate powershell.exe (bridge/modal-probe.ps1, lib/modal-probe.js) watches the
// last known IDE pid; when it reports a dialog, the call is aborted with IDE_MODAL_DIALOG (bridge
// killed exactly like on BRIDGE_TIMEOUT) instead of waiting for the tools.json timeout.

/** @type {Set<ModalProbe>} */
const activeProbes = new Set();

/**
 * @param {number} pid   IDE pid the probe watched
 * @param {{selectedBy?:string|null}|null} ide  IDE identity known for that pid (selectedBy decides the advice)
 * @param {string} title dialog title
 * @param {'killed'|'dequeued'} outcome  what happened to the call (bridge.abortCall)
 */
function modalHint(pid, ide, title, outcome) {
  // Killing PowerShell does not cancel the DTE operation inside the IDE: once the dialog is
  // dismissed, XAE may still finish (or half-apply) the activation / download / PLC start.
  const lost =
    outcome === 'dequeued'
      ? 'the call was not sent to PowerShell (the call running in the bridge ahead of it may stay blocked by the same dialog until its own timeout)'
      : 'the PowerShell bridge was killed and all IDE/ADS state is lost';
  const after = 'The interrupted operation may still complete or partly apply after the dialog closes; check GetStatus / GetPlcState before re-running it.';
  if (ide?.selectedBy === 'launched') {
    return (
      `The IDE (pid ${pid}, launched by this server) shows the modal dialog '${title}'; ${lost}. ` +
      `Dismiss the dialog in the XAE window, or kill the IDE with \`taskkill /PID ${pid} /T /F\` ` +
      `(unsaved changes in that IDE will be lost; ask the user before killing it), then ConnectIde again. ${after}`
    );
  }
  return `The IDE (pid ${pid}) shows the modal dialog '${title}' and was opened by the user; ${lost}. Dismiss it in the XAE window (or ask the user to), then ConnectIde again. ${after}`;
}

/** First `max` chars of `s` without cutting a surrogate pair in half. */
function truncate(s, max) {
  if (s.length <= max) return s;
  let end = max;
  const code = s.charCodeAt(end - 1);
  if (code >= 0xd800 && code <= 0xdbff) end -= 1;
  return s.slice(0, end);
}

/**
 * Start a probe for one catalog call when enabled and an IDE pid is known. The pid is checked
 * first (isIdeProcessAlive: a live TcXaeShell.exe / devenv.exe) so a recycled pid of an unrelated
 * process is never watched; the check runs in parallel with the bridge call and never delays it.
 * Returns a handle whose stop() kills the probe (no-op when none was started).
 */
function startProbeFor(name, tool, token, probePid, prevIde) {
  const handle = { done: false, probe: null, stop() {} };
  if (!config.modalProbe.enabled || !PROBED_TOOLS.has(name) || !Number.isInteger(probePid) || probePid <= 0) return handle;

  const onDialog = (dialog) => {
    const ideSnapshot = lastIde ? { ...lastIde } : null;
    const text = String(dialog.text ?? '');
    const shortText = truncate(text, 200);
    const message = shortText ? `${dialog.title} | ${shortText}` : dialog.title;
    const outcome = bridge.abortCall(
      token,
      (o) => ({
        success: false,
        error: { code: 'IDE_MODAL_DIALOG', message, hint: modalHint(probePid, prevIde ?? ideSnapshot, dialog.title, o) },
        data: { dialogTitle: dialog.title, dialogText: text, ideProcessId: probePid, lastIde: ideSnapshot, bridgeRestarted: o === 'killed' }
      }),
      `${tool.cmdlet} is blocked by the IDE modal dialog '${dialog.title}'`
    );
    if (!outcome) {
      console.error(`[tcauto-mcp] modal dialog '${dialog.title}' on IDE pid ${probePid} reported after ${name} had finished; ignored`);
      return;
    }
    console.error(`[tcauto-mcp] modal dialog detected on IDE pid ${probePid} during ${name}: ${dialog.title} (${outcome})`);
    emitLog('error', { message: `modal dialog detected during ${name}: ${dialog.title}`, tool: name, ideProcessId: probePid, dialogTitle: dialog.title, dialogText: text, outcome });
  };

  const launch = () => {
    if (handle.done || shuttingDown) return;
    const probe = new ModalProbe({
      pid: probePid,
      intervalSec: config.modalProbe.intervalSec,
      powershellPath: config.powershellPath,
      probeScript: config.modalProbe.probeScript,
      spawnSpec: config.modalProbe.spawnSpec,
      onDialog,
      onError: (msg) => {
        console.error(`[tcauto-mcp] ${msg}`);
        emitLog('warning', { message: msg, source: 'modal-probe', tool: name });
      },
      onDebug: (msg) => {
        if (config.verbose) console.error(`[tcauto-mcp] ${msg}`);
      }
    });
    handle.probe = probe;
    activeProbes.add(probe);
    probe.start();
  };

  handle.stop = () => {
    handle.done = true;
    if (handle.probe) {
      handle.probe.stop();
      activeProbes.delete(handle.probe);
    }
  };

  isIdeProcessAlive(probePid).then(
    (alive) => {
      if (alive) launch();
      else if (!handle.done) console.error(`[tcauto-mcp] modal probe skipped for ${name}: pid ${probePid} is not a running XAE/devenv`);
    },
    () => {}
  );
  return handle;
}

/**
 * Run a catalog tool: validate -> timeout -> bridge call. Always returns a result object.
 * `signal` (the MCP request's AbortSignal) cancels the call only while it is still queued.
 */
async function callCatalogTool(name, args, signal) {
  const tool = catalog.get(name);
  if (!tool) return errorResult('UNKNOWN_TOOL', `Unknown tool '${name}'`, 'Use tools/list to see the available tools.');
  const validation = validateParams(tool, args);
  if (!validation.ok) return { success: false, error: validation.error };
  const timeoutMs = computeTimeoutMs(tool, validation.params);
  // Probe target: the last known IDE, captured before ConnectIde forgets it (a reconnect after a
  // BRIDGE_TIMEOUT / IDE_MODAL_DIALOG blocks again on the dialog that is still up in that IDE).
  const prevIde = lastIde ? { ...lastIde } : null;
  const probePid = prevIde?.ideProcessId;
  // Forget the previous IDE as soon as a new ConnectIde starts: if it fails (or times out) the
  // BRIDGE_* hint must not point at the IDE of an earlier session.
  if (name === 'ConnectIde') lastIde = null;
  const token = {};
  const probe = startProbeFor(name, tool, token, probePid, prevIde);
  let result;
  try {
    result = await bridge.call('call', { cmdlet: tool.cmdlet, params: validation.params, timeoutMs, signal, token });
  } finally {
    probe.stop(); // fire-and-forget: the result does not wait for the probe process to exit
  }
  rememberIde(name, result);
  return decorateBridgeLoss(result);
}

/** Per-request context for composite tools (see lib/composites.js header). */
function makeContext(signal) {
  return {
    bridge,
    signal,
    callTool: (name, args) => callCatalogTool(name, args, signal),
    get lastIde() {
      return lastIde ? { ...lastIde } : null;
    }
  };
}

async function callAnyTool(name, args, signal) {
  const composite = compositeMap.get(name);
  if (composite) {
    const validation = validateParams(composite, args);
    if (!validation.ok) return { success: false, error: validation.error };
    return composite.run(makeContext(signal), validation.params);
  }
  return callCatalogTool(name, args, signal);
}

server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: listTools() }));

/**
 * notifications/progress every config.progressIntervalMs while a call runs, only when the client
 * sent a progressToken (SDK 1.32: extra._meta.progressToken, same object as request.params._meta).
 * `progress` is the elapsed time in milliseconds on a monotonic clock and is forced to strictly
 * increase from one notification to the next (MCP requires it to never go backwards).
 * Returns a stop() function.
 */
function startProgress(name, request, extra) {
  const progressToken = extra?._meta?.progressToken ?? request.params?._meta?.progressToken;
  if (progressToken === undefined || progressToken === null || typeof extra?.sendNotification !== 'function') return () => {};
  const t0 = performance.now();
  let last = 0;
  const timer = setInterval(() => {
    const progress = Math.max(last + 1, Math.round(performance.now() - t0));
    last = progress;
    extra
      .sendNotification({
        method: 'notifications/progress',
        params: { progressToken, progress, message: `${name} running ${Math.round(progress / 1000)}s` }
      })
      .catch(() => {});
  }, config.progressIntervalMs);
  return () => clearInterval(timer);
}

server.setRequestHandler(CallToolRequestSchema, async (request, extra) => {
  const name = request.params?.name;
  const args = request.params?.arguments ?? {};
  const stopProgress = startProgress(name, request, extra);
  try {
    // extra.signal fires on notifications/cancelled: a call still waiting in the bridge queue is
    // dropped (CANCELLED); one already handed to PowerShell runs to completion.
    const result = await callAnyTool(name, args, extra?.signal);
    return toToolResult(await decorateBridgeLoss(result));
  } catch (err) {
    console.error(`[tcauto-mcp] ${name} failed: ${err?.stack ?? err}`);
    return toToolResult(errorResult('INTERNAL_ERROR', `${name}: ${err?.message ?? String(err)}`));
  } finally {
    stopProgress();
  }
});

// ---------------------------------------------------------------- lifecycle

let shuttingDown = false;
async function shutdown(reason, code = 0) {
  if (shuttingDown) return;
  shuttingDown = true;
  console.error(`[tcauto-mcp] shutting down (${reason})`);
  for (const probe of activeProbes) probe.stop();
  activeProbes.clear();
  try {
    await bridge.stop();
  } catch {
    /* ignore */
  }
  try {
    await server.close();
  } catch {
    /* ignore */
  }
  process.exit(code);
}

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.stdin.on('end', () => shutdown('stdin closed'));
process.stdin.on('close', () => shutdown('stdin closed'));
process.on('uncaughtException', (err) => {
  console.error(`[tcauto-mcp] uncaught exception: ${err?.stack ?? err}`);
});
process.on('unhandledRejection', (err) => {
  console.error(`[tcauto-mcp] unhandled rejection: ${err?.stack ?? err}`);
});

const transport = new StdioServerTransport();
transport.onclose = () => shutdown('transport closed');

await server.connect(transport);
connected = true;
flushPendingLogs();
console.error(`[tcauto-mcp] ${pkg.name} ${pkg.version}: ${catalog.size} catalog tools + ${composites.length} composite tools (tools.json: ${config.toolsJsonPath}), modal probe ${config.modalProbe.enabled ? 'on' : 'off'} (${config.modalProbe.intervalSec} s)`);

if (config.eager) {
  bridge.start().then(
    (ready) => console.error(`[tcauto-mcp] bridge ready (${ready?.cmdlets?.length ?? '?'} cmdlets, PS ${ready?.psVersion ?? '?'})`),
    (err) => console.error(`[tcauto-mcp] eager bridge start failed: ${err.code ?? ''} ${err.message}`)
  );
}
