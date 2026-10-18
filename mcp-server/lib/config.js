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
//   TWINCAT_MCP_MODAL_PROBE    "0"/"false"/"off"/"no" -> disable the modal-dialog probe (default on): during
//                              BuildProject / EnableConfig / PlcLogin / SendPlcProgram / RunTestCycle /
//                              OpenProject / ConnectIde a separate powershell.exe (bridge/modal-probe.ps1)
//                              watches the last known IDE pid and turns a modal dialog into IDE_MODAL_DIALOG
//                              instead of waiting for BRIDGE_TIMEOUT (lib/modal-probe.js)
//   TWINCAT_MCP_MODAL_PROBE_INTERVAL_SEC  probe scan interval in seconds (default 5, clamped 1..60)
//   TWINCAT_MCP_PROBE_CONFIRM_SCANS  consecutive scans that must see the same kill-worthy dialog before the
//                              probe reports it (default 2, clamped 1..10)
//   TWINCAT_MCP_PROBE_SCAN_SCRIPT    file that defines $script:TcUiaDialogScan, dot-sourced by the probe
//                              (default: <dir of TWINCAT_MODULE_PATH>/Private/Get-TcIdeModalDialog.ps1)
//
// Test-only overrides (replace the powershell.exe spawn with any command, e.g. a mock bridge):
//   TWINCAT_MCP_BRIDGE_COMMAND  executable to spawn instead of powershell.exe
//   TWINCAT_MCP_BRIDGE_ARGS     JSON array of arguments for that executable
//   TWINCAT_MCP_PROBE_COMMAND   executable to spawn instead of powershell.exe modal-probe.ps1
//   TWINCAT_MCP_PROBE_ARGS      JSON array of arguments for that executable (the probe argument tail is appended)
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export const MCP_SERVER_DIR = path.resolve(__dirname, '..');
export const REPO_ROOT = path.resolve(MCP_SERVER_DIR, '..');
export const DEFAULT_BRIDGE_SCRIPT = path.join(MCP_SERVER_DIR, 'bridge', 'bridge.ps1');
export const DEFAULT_PROBE_SCRIPT = path.join(MCP_SERVER_DIR, 'bridge', 'modal-probe.ps1');
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

/** Default-on flag: unset/blank -> true; "0"/"false"/"no"/"off" -> false; anything else -> true. */
function flagDefaultOn(value) {
  if (value === undefined || value === null || String(value).trim() === '') return true;
  const v = String(value).trim().toLowerCase();
  return !(v === '0' || v === 'false' || v === 'no' || v === 'off');
}

/** `{command, args}` from <prefix>_COMMAND / <prefix>_ARGS (JSON array), or null when no command is set. */
function parseSpawnOverride(env, prefix = 'TWINCAT_MCP_BRIDGE') {
  const command = env[`${prefix}_COMMAND`];
  if (!command) return null;
  let args = [];
  const rawArgs = env[`${prefix}_ARGS`];
  if (rawArgs) {
    try {
      const parsed = JSON.parse(rawArgs);
      if (!Array.isArray(parsed)) throw new Error('not an array');
      args = parsed.map(String);
    } catch (err) {
      throw new Error(`${prefix}_ARGS must be a JSON array of strings: ${err.message}`);
    }
  }
  return { command, args };
}

export const DEFAULT_PROGRESS_INTERVAL_MS = 10000;
export const DEFAULT_PROBE_INTERVAL_SEC = 5;
export const DEFAULT_PROBE_CONFIRM_SCANS = 2;

/** The module file that defines $script:TcUiaDialogScan, next to the given TwinCATAutomation.psm1. */
export function scanScriptFor(modulePath) {
  return path.join(path.dirname(modulePath), 'Private', 'Get-TcIdeModalDialog.ps1');
}
export const DEFAULT_SCAN_SCRIPT = scanScriptFor(DEFAULT_MODULE_PATH);

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
  const modulePath = env.TWINCAT_MODULE_PATH || DEFAULT_MODULE_PATH;
  return {
    progressIntervalMs: positiveInt(env.TWINCAT_MCP_PROGRESS_INTERVAL_MS, DEFAULT_PROGRESS_INTERVAL_MS),
    modulePath,
    powershellPath: defaultPowershellPath(env),
    bridgeScript: DEFAULT_BRIDGE_SCRIPT,
    toolsJsonPath: env.TWINCAT_MCP_TOOLS_JSON || DEFAULT_TOOLS_JSON,
    verbose: flag(env.TWINCAT_MCP_VERBOSE),
    eager: flag(env.TWINCAT_MCP_EAGER),
    spawnSpec: parseSpawnOverride(env),
    modalProbe: {
      enabled: flagDefaultOn(env.TWINCAT_MCP_MODAL_PROBE),
      intervalSec: Math.min(60, Math.max(1, positiveInt(env.TWINCAT_MCP_MODAL_PROBE_INTERVAL_SEC, DEFAULT_PROBE_INTERVAL_SEC))),
      spawnSpec: parseSpawnOverride(env, 'TWINCAT_MCP_PROBE'),
      probeScript: DEFAULT_PROBE_SCRIPT,
      confirmScans: Math.min(10, Math.max(1, positiveInt(env.TWINCAT_MCP_PROBE_CONFIRM_SCANS, DEFAULT_PROBE_CONFIRM_SCANS))),
      scanScript: env.TWINCAT_MCP_PROBE_SCAN_SCRIPT || scanScriptFor(modulePath)
    }
  };
}
