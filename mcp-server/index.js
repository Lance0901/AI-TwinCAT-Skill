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
  // Forget the previous IDE as soon as a new ConnectIde starts: if it fails (or times out) the
  // BRIDGE_* hint must not point at the IDE of an earlier session.
  if (name === 'ConnectIde') lastIde = null;
  const result = await bridge.call('call', { cmdlet: tool.cmdlet, params: validation.params, timeoutMs, signal });
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
console.error(`[tcauto-mcp] ${pkg.name} ${pkg.version}: ${catalog.size} catalog tools + ${composites.length} composite tools (tools.json: ${config.toolsJsonPath})`);

if (config.eager) {
  bridge.start().then(
    (ready) => console.error(`[tcauto-mcp] bridge ready (${ready?.cmdlets?.length ?? '?'} cmdlets, PS ${ready?.psVersion ?? '?'})`),
    (err) => console.error(`[tcauto-mcp] eager bridge start failed: ${err.code ?? ''} ${err.message}`)
  );
}
