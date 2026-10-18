// Mock of bridge/bridge.ps1 speaking the PROTOCOL.md line protocol. Test use only.
//
// Behaviour switches (request params / env):
//   params.Hang        never answer (used to test timeouts)
//   params.Crash       process.exit(3) without answering
//   params.DelayMs     delay the answer by N ms
//   cmdlet Get-TcIdeInfo   writes a warning log line, then NOT_CONNECTED + hint
//   cmdlet Connect-TcIde   marks the mock IDE as connected (state.ideConnected); returns
//                          ideProcessId 4242, selectedBy 'launched' ('first-instance' when params.NoLaunch)
//   op modal + params.ProcessId   probes that pid instead of the connected one (data.ideProcessId echoes it)
//   unparseable request line      answered with {id:null, event:'result', INVALID_REQUEST} like bridge.ps1
//   env MOCK_BRIDGE_READY_FAIL=1   writes ready ok:false and exits 2
//   env MOCK_BRIDGE_ARGS_ECHO=1    includes process.argv in the ready line (spawn arg tests)
import readline from 'node:readline';

const CMDLETS = [
  'Connect-TcIde', 'Disconnect-TcIde', 'Get-TcIdeInfo', 'Build-TcProject', 'Enable-TcConfig',
  'Connect-TcAds', 'Disconnect-TcAds', 'Read-TcVariable', 'Write-TcVariable',
  'Get-TcSystemState', 'Get-TcPlcState'
];

const state = {
  ideConnected: false,
  ideProcessId: 0,
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

const readyLine = { event: 'ready', ok: true, cmdlets: CMDLETS, psVersion: 'mock', apartment: 'STA', modulePath: 'mock' };
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
        const values = {};
        for (const p of paths) values[p] = 0;
        return result(id, { success: true, data: { values } });
      }
      case 'Build-TcProject':
        return result(id, { success: true, data: { errors: 0, warnings: 0, params } });
      case 'Enable-TcConfig':
        return result(id, { success: true, data: { plcState: 'Run', params } });
      case 'Get-TcSystemState':
        return result(id, { success: true, data: { state: 'Run', amsNetId: params.AmsNetId ?? null } });
      case 'Get-TcPlcState':
        return result(id, { success: true, data: { state: 'Run' } });
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
