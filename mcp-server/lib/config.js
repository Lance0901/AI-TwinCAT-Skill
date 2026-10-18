// Central place for every environment variable the MCP server understands.
//
//   TWINCAT_MODULE_PATH        path to TwinCATAutomation.psm1 (default: <repo>/src/TwinCATAutomation/TwinCATAutomation.psm1)
//   TWINCAT_MCP_POWERSHELL     powershell.exe to use (default: %SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe)
//   TWINCAT_MCP_VERBOSE        "1" -> bridge forwards Write-Verbose as debug log lines
//   TWINCAT_MCP_EAGER          "1" -> start the PowerShell bridge at server start instead of on first tool call
//   TWINCAT_MCP_TOOLS_JSON     path to tools.json (default: <mcp-server>/tools.json)
//   TWINCAT_MCP_PROGRESS_INTERVAL_MS  interval of notifications/progress during a tool call when the
//                              client sent a progressToken (default 10000; tests use a small value)
//   TWINCAT_MCP_SKIP_PID_CHECK "1" -> do not verify with tasklist that data.lastIde.ideProcessId is still a
//                              live TcXaeShell.exe/devenv.exe before naming it in a BRIDGE_TIMEOUT/BRIDGE_DIED
//                              hint (tests with a mock IDE pid)
//
// Test-only overrides (replace the powershell.exe spawn with any command, e.g. a mock bridge):
//   TWINCAT_MCP_BRIDGE_COMMAND  executable to spawn instead of powershell.exe
//   TWINCAT_MCP_BRIDGE_ARGS     JSON array of arguments for that executable
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export const MCP_SERVER_DIR = path.resolve(__dirname, '..');
export const REPO_ROOT = path.resolve(MCP_SERVER_DIR, '..');
export const DEFAULT_BRIDGE_SCRIPT = path.join(MCP_SERVER_DIR, 'bridge', 'bridge.ps1');
export const DEFAULT_TOOLS_JSON = path.join(MCP_SERVER_DIR, 'tools.json');
export const DEFAULT_MODULE_PATH = path.join(REPO_ROOT, 'src', 'TwinCATAutomation', 'TwinCATAutomation.psm1');

export function defaultPowershellPath(env = process.env) {
  if (env.TWINCAT_MCP_POWERSHELL) return env.TWINCAT_MCP_POWERSHELL;
  return path.join(env.SystemRoot ?? 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
}

function flag(value) {
  if (value === undefined || value === null) return false;
  const v = String(value).trim().toLowerCase();
  return v === '1' || v === 'true' || v === 'yes' || v === 'on';
}

function parseSpawnOverride(env) {
  const command = env.TWINCAT_MCP_BRIDGE_COMMAND;
  if (!command) return null;
  let args = [];
  if (env.TWINCAT_MCP_BRIDGE_ARGS) {
    try {
      const parsed = JSON.parse(env.TWINCAT_MCP_BRIDGE_ARGS);
      if (!Array.isArray(parsed)) throw new Error('not an array');
      args = parsed.map(String);
    } catch (err) {
      throw new Error(`TWINCAT_MCP_BRIDGE_ARGS must be a JSON array of strings: ${err.message}`);
    }
  }
  return { command, args };
}

export const DEFAULT_PROGRESS_INTERVAL_MS = 10000;

// Bounds for the per-call bridge timeout. The upper bound keeps setTimeout below its 2^31-1 ms
// limit (a larger delay fires immediately in Node), the lower bound stops a client from asking
// for a timeout that cannot even reach PowerShell.
export const MIN_CALL_TIMEOUT_MS = 1000;
export const MAX_CALL_TIMEOUT_MS = 7_200_000; // 2 h

function positiveInt(value, fallback) {
  if (value === undefined || value === null || String(value).trim() === '') return fallback;
  const n = Number(value);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : fallback;
}

export function loadConfig(env = process.env) {
  return {
    progressIntervalMs: positiveInt(env.TWINCAT_MCP_PROGRESS_INTERVAL_MS, DEFAULT_PROGRESS_INTERVAL_MS),
    modulePath: env.TWINCAT_MODULE_PATH || DEFAULT_MODULE_PATH,
    powershellPath: defaultPowershellPath(env),
    bridgeScript: DEFAULT_BRIDGE_SCRIPT,
    toolsJsonPath: env.TWINCAT_MCP_TOOLS_JSON || DEFAULT_TOOLS_JSON,
    verbose: flag(env.TWINCAT_MCP_VERBOSE),
    eager: flag(env.TWINCAT_MCP_EAGER),
    spawnSpec: parseSpawnOverride(env)
  };
}
