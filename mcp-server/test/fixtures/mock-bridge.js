// Mock of bridge/bridge.ps1 speaking the PROTOCOL.md line protocol. Test use only.
//
// Behaviour switches (request params / env):
//   params.Hang        never answer (used to test timeouts)
//   params.Crash       process.exit(3) without answering
//   params.DelayMs     delay the answer by N ms
//   cmdlet Set-TcTarget    echoes data.params; AmsNetId '0.0.0.0.0.0' fails with TARGET_NOT_FOUND
//   cmdlet Read-TcVariable shape of the real cmdlet: one Path -> data {path, value, type}; several -> data
//                          is an ARRAY of entries; a path containing 'Missing' is {path, error, code
//                          SYMBOL_NOT_FOUND} in the array, a SYMBOL_NOT_FOUND failure when it is the only path
//   cmdlet Get-TcSymbols   data is an ARRAY of {path, type, size, comment} whose path contains Filter
//                          (without '*'); requires Connect-TcAds (#57)
//   cmdlet Get-TcIdeInfo   writes a warning log line, then NOT_CONNECTED + hint
//   cmdlet Connect-TcIde   marks the mock IDE as connected (state.ideConnected); returns
//                          ideProcessId 4242, selectedBy 'launched' ('first-instance' when params.NoLaunch);
//                          op state then reports ideMainHwnd 16962 (0x4242) until Disconnect-TcIde
//   op modal + params.ProcessId   probes that pid instead of the connected one (data.ideProcessId echoes it)
//   unparseable request line      answered with {id:null, event:'result', INVALID_REQUEST} like bridge.ps1
//   env MOCK_BRIDGE_READY_FAIL=1   writes ready ok:false and exits 2
//   env MOCK_BRIDGE_ARGS_ECHO=1    includes process.argv in the ready line (spawn arg tests)
//   ready.modulePath               env TWINCAT_MCP_BRIDGE_MODULE_PATH (set by PowerShellBridge), else 'mock'
//   env MOCK_BRIDGE_FAIL_MODULE=x  ready ok:false (MODULE_IMPORT_FAILED) when the module path contains x (#41)
//   cmdlet Set-TcSystemState + params.Fail  records an in-memory lifecycle block (like
//                          $script:TcLifecycleBlockLocal) and fails with SYSTEM_STATE_TIMEOUT (#41)
//   cmdlet Register-TcCodeChange  records an in-memory BUILD_REQUIRED entry for params.SolutionPath;
//                          params.StateUnwritable makes the state file "unwritable" for retire (#41)
//   op retire              like bridge.ps1: RELOAD_LIFECYCLE_BLOCKED while a block is recorded;
//                          in-memory BUILD_REQUIRED entries are written to $TCAUTO_STATE_DIR/build-required.json
//                          (RELOAD_BUILD_REQUIRED when that is not possible); else disconnects, answers
//                          {retired, ideWasConnected, adsWasConnected, buildRequiredKeys, buildRequiredPersisted}, exits 0
import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';

const CMDLETS = [
  'Connect-TcIde', 'Disconnect-TcIde', 'Get-TcIdeInfo', 'Build-TcProject', 'Enable-TcConfig',
  'Connect-TcAds', 'Disconnect-TcAds', 'Read-TcVariable', 'Write-TcVariable',
  'Get-TcSystemState', 'Get-TcPlcState', 'Set-TcTarget', 'Get-TcSymbols', 'Set-TcSystemState',
  'Register-TcCodeChange'
];

const MODULE_PATH = process.env.TWINCAT_MCP_BRIDGE_MODULE_PATH || 'mock';
const lifecycleBlockLocal = {};
const buildRequiredLocal = {}; // like $script:TcBuildRequiredLocal (in memory only until retire)
let buildStateUnwritable = false;

const SYMBOLS = [
  { path: 'MAIN.nCounter', type: 'INT', size: 2, comment: '' },
  { path: 'MAIN.bRun', type: 'BOOL', size: 1, comment: 'run flag' },
  { path: 'MAIN.fSpeed', type: 'LREAL', size: 8, comment: '' },
  { path: 'GVL.nMode', type: 'E_Mode', size: 2, comment: '', enumValues: { Idle: 0, Auto: 1 } }
];

const state = {
  ideConnected: false,
  ideProcessId: 0,
  ideMainHwnd: 0,
  sysManagerAvailable: false,
  adsConnected: false,
  amsNetId: null,
  adsPort: null,
  lastModalDialog: null
};

function write(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}

if (process.env.MOCK_BRIDGE_READY_FAIL === '1') {
  write({ event: 'ready', ok: false, error: { code: 'MODULE_IMPORT_FAILED', message: 'mock import failure', hint: 'fix the module path' } });
  process.exit(2);
}

// MOCK_BRIDGE_FAIL_FILE: a file read at every start; each non-empty line is a substring like
// MOCK_BRIDGE_FAIL_MODULE (lets a test make the restore of a failed reload fail too)
const failMarkers = [];
if (process.env.MOCK_BRIDGE_FAIL_MODULE) failMarkers.push(process.env.MOCK_BRIDGE_FAIL_MODULE);
if (process.env.MOCK_BRIDGE_FAIL_FILE) {
  try {
    for (const l of fs.readFileSync(process.env.MOCK_BRIDGE_FAIL_FILE, 'utf8').split(/\r?\n/)) if (l.trim()) failMarkers.push(l.trim());
  } catch {
    /* no file: nothing fails */
  }
}
if (failMarkers.some((m) => MODULE_PATH.includes(m))) {
  write({ event: 'ready', ok: false, error: { code: 'MODULE_IMPORT_FAILED', message: `mock import failure for ${MODULE_PATH}` } });
  process.exit(2);
}

const readyLine = { event: 'ready', ok: true, cmdlets: CMDLETS, psVersion: 'mock', apartment: 'STA', modulePath: MODULE_PATH };
if (process.env.MOCK_BRIDGE_ARGS_ECHO === '1') readyLine.argv = process.argv.slice(2);
write(readyLine);
if (process.env.MOCK_BRIDGE_EARLY_LOG === '1') {
  // Log line in the same chunk as ready, with no request id (must not crash the parser).
  write({ event: 'log', level: 'info', message: 'early log after ready' });
}

function result(id, body) {
  write({ id, event: 'result', ...body });
}

function handleCall(req) {
  const { id, cmdlet, params = {} } = req;
  if (!CMDLETS.includes(cmdlet)) {
    return result(id, { success: false, error: { code: 'INVALID_CMDLET', message: `${cmdlet} is not exported` } });
  }
  if (params.Hang === true) return; // never answers
  if (params.Crash === true) process.exit(3);

  const respond = () => {
    switch (cmdlet) {
      case 'Connect-TcIde':
        state.ideConnected = true;
        state.ideProcessId = 4242;
        state.ideMainHwnd = 0x4242;
        state.sysManagerAvailable = true;
        return result(id, {
          success: true,
          data: {
            progId: params.ProgId ?? 'TcXaeShell.DTE.15.0',
            processId: 4242,
            ideProcessId: 4242,
            selectedBy: params.NoLaunch === true ? 'first-instance' : 'launched',
            solution: params.SolutionPath ?? '',
            params
          }
        });
      case 'Disconnect-TcIde':
        state.ideConnected = false;
        state.ideProcessId = 0;
        state.ideMainHwnd = 0;
        state.sysManagerAvailable = false;
        return result(id, { success: true, data: {} });
      case 'Get-TcIdeInfo':
        write({ id, event: 'log', level: 'warning', message: 'mock: IDE not connected' });
        return result(id, { success: false, error: { code: 'NOT_CONNECTED', message: 'IDE not connected', hint: 'Run Connect-TcIde first' } });
      case 'Connect-TcAds':
        state.adsConnected = true;
        state.amsNetId = params.AmsNetId ?? '5.1.2.3.1.1';
        state.adsPort = params.Port ?? 851;
        return result(id, { success: true, data: { amsNetId: state.amsNetId, port: state.adsPort } });
      case 'Disconnect-TcAds':
        state.adsConnected = false;
        return result(id, { success: true, data: {} });
      case 'Read-TcVariable': {
        if (!state.adsConnected) {
          return result(id, { success: false, error: { code: 'NOT_CONNECTED', message: 'ADS not connected', hint: 'Run Connect-TcAds first' } });
        }
        const paths = Array.isArray(params.Path) ? params.Path : [params.Path];
        const entries = paths.map((p) =>
          /Missing/.test(p)
            ? { path: p, error: `Symbol '${p}' not found`, code: 'SYMBOL_NOT_FOUND', hint: 'Check the path with GetSymbols' }
            : { path: p, value: 0, type: 'INT', reconnected: false }
        );
        if (entries.length === 1) {
          if (entries[0].error) return result(id, { success: false, error: { code: 'SYMBOL_NOT_FOUND', message: entries[0].error, hint: entries[0].hint } });
          return result(id, { success: true, data: entries[0] });
        }
        return result(id, { success: true, data: entries });
      }
      case 'Get-TcSymbols': {
        if (!state.adsConnected) {
          return result(id, { success: false, error: { code: 'NOT_CONNECTED', message: 'ADS not connected', hint: 'Run Connect-TcAds first' } });
        }
        const f = typeof params.Filter === 'string' ? params.Filter.replace(/\*/g, '') : '';
        return result(id, { success: true, data: SYMBOLS.filter((s) => s.path.includes(f)) });
      }
      case 'Build-TcProject':
        return result(id, { success: true, data: { errors: 0, warnings: 0, params } });
      case 'Enable-TcConfig':
        return result(id, { success: true, data: { plcState: 'Run', params } });
      case 'Get-TcSystemState':
        return result(id, { success: true, data: { state: 'Run', amsNetId: params.AmsNetId ?? null } });
      case 'Set-TcTarget':
        if (params.AmsNetId === '0.0.0.0.0.0') {
          return result(id, { success: false, error: { code: 'TARGET_NOT_FOUND', message: 'mock: unknown target', hint: 'pick a route' } });
        }
        return result(id, { success: true, data: { amsNetId: params.AmsNetId, params } });
      case 'Get-TcPlcState':
        return result(id, { success: true, data: { state: 'Run' } });
      case 'Register-TcCodeChange': {
        const key = String(params.SolutionPath ?? '<unknown>').toLowerCase();
        buildRequiredLocal[key] = { solution: params.SolutionPath ?? '', kind: 'code-changed', reason: 'mock change' };
        if (params.StateUnwritable === true) buildStateUnwritable = true;
        return result(id, { success: true, data: { key } });
      }
      case 'Set-TcSystemState':
        if (params.Fail === true) {
          const key = String(params.AmsNetId ?? '<unknown>').toLowerCase();
          lifecycleBlockLocal[key] = { amsNetId: params.AmsNetId ?? null, command: 'Set-TcSystemState', errorCode: 'SYSTEM_STATE_TIMEOUT' };
          return result(id, { success: false, error: { code: 'SYSTEM_STATE_TIMEOUT', message: 'mock: state not reached' }, data: { lifecycleBlock: lifecycleBlockLocal[key] } });
        }
        return result(id, { success: true, data: { state: params.State ?? 'Run' } });
      default:
        return result(id, { success: true, data: { cmdlet, params } });
    }
  };

  if (Number.isFinite(params.DelayMs) && params.DelayMs > 0) setTimeout(respond, params.DelayMs);
  else respond();
}

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on('line', (line) => {
  if (!line.trim()) return;
  let req;
  try {
    req = JSON.parse(line);
  } catch (err) {
    // Like bridge.ps1: a line that cannot be parsed is answered with id:null so the caller does not hang.
    return result(null, { success: false, error: { code: 'INVALID_REQUEST', message: `bad request line: ${err.message}` } });
  }
  const id = req.id;
  switch (req.op ?? 'call') {
    case 'ping':
      return result(id, { success: true, data: { pong: true } });
    case 'state':
      return result(id, { success: true, data: { ...state } });
    case 'modal': {
      // params.ProcessId overrides the pid the mock knows (like bridge.ps1 after a restart)
      const pid = Number.isInteger(req.params?.ProcessId) && req.params.ProcessId > 0 ? req.params.ProcessId : state.ideConnected ? state.ideProcessId : 0;
      if (!pid) {
        return result(id, { success: false, error: { code: 'NOT_CONNECTED', message: 'No IDE process known', hint: 'Run Connect-TcIde first' } });
      }
      return result(id, { success: true, data: { ideProcessId: pid, dialog: null, timeoutSec: req.params?.TimeoutSec ?? 5 } });
    }
    case 'retire': {
      const keys = Object.keys(lifecycleBlockLocal).sort();
      if (keys.length > 0) {
        return result(id, {
          success: false,
          error: { code: 'RELOAD_LIFECYCLE_BLOCKED', message: `mock: ${keys.length} lifecycle block record(s) in memory`, hint: 'Stop and report data.lifecycleBlocks to the user.' },
          data: { modulePath: MODULE_PATH, lifecycleBlocks: keys.map((key) => ({ key, record: lifecycleBlockLocal[key] })), readable: true, notRun: true }
        });
      }
      // like Save-BridgeLocalBuildRequired: in-memory BUILD_REQUIRED entries go to the state file first
      const buildKeys = Object.keys(buildRequiredLocal).sort();
      let persisted = [];
      if (buildKeys.length > 0) {
        const file = process.env.TCAUTO_STATE_DIR ? path.join(process.env.TCAUTO_STATE_DIR, 'build-required.json') : null;
        let error = null;
        if (!file) error = 'mock: TCAUTO_STATE_DIR is not set';
        else if (buildStateUnwritable) error = 'mock: build-required.json cannot be written';
        if (!error) {
          let doc = {};
          try {
            doc = JSON.parse(fs.readFileSync(file, 'utf8'));
          } catch {
            doc = {};
          }
          persisted = buildKeys.filter((k) => JSON.stringify(doc[k]) !== JSON.stringify(buildRequiredLocal[k]));
          for (const k of persisted) doc[k] = buildRequiredLocal[k];
          if (persisted.length) fs.writeFileSync(file, JSON.stringify(doc));
        }
        if (error) {
          return result(id, {
            success: false,
            error: { code: 'RELOAD_BUILD_REQUIRED', message: `mock: ${error}`, hint: 'Run BuildProject first.' },
            data: { modulePath: MODULE_PATH, buildRequiredKeys: buildKeys, error, notRun: true }
          });
        }
      }
      const was = { ideWasConnected: state.ideConnected, adsWasConnected: state.adsConnected };
      state.ideConnected = false;
      state.adsConnected = false;
      result(id, { success: true, data: { retired: true, modulePath: MODULE_PATH, ...was, buildRequiredKeys: buildKeys, buildRequiredPersisted: persisted } });
      process.exit(0);
      break;
    }
    case 'shutdown':
      result(id, { success: true });
      process.exit(0);
      break;
    case 'call':
      return handleCall(req);
    default:
      return result(id, { success: false, error: { code: 'INVALID_OP', message: `unknown op ${req.op}` } });
  }
});
rl.on('close', () => process.exit(0));
