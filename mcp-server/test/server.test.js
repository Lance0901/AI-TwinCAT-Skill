// End-to-end: real MCP client over stdio -> index.js -> mock bridge.
import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { LoggingMessageNotificationSchema } from '@modelcontextprotocol/sdk/types.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const INDEX = path.join(__dirname, '..', 'index.js');
const FIXTURE = path.join(__dirname, 'fixtures', 'tools.fixture.json');
const FIXTURE_EXT = path.join(__dirname, 'fixtures', 'tools.fixture.ext.json');
const MOCK = path.join(__dirname, 'fixtures', 'mock-bridge.js');
const MOCK_PROBE = path.join(__dirname, 'fixtures', 'mock-modal-probe.js');

// The modal-dialog probe is enabled by default. Without TWINCAT_MCP_PROBE_COMMAND the server would
// spawn the real powershell.exe modal-probe.ps1 against the mock IDE pid 4242 after every ConnectIde
// (it exits 3, "process not found": harmless but slow and noisy), so it is switched off here unless
// a describe is about the probe and passes TWINCAT_MCP_MODAL_PROBE itself.
async function startServer(toolsJson, extraEnv = {}) {
  const logs = [];
  const stderr = [];
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [INDEX],
    env: {
      ...process.env,
      TWINCAT_MCP_TOOLS_JSON: toolsJson,
      TWINCAT_MCP_BRIDGE_COMMAND: process.execPath,
      TWINCAT_MCP_BRIDGE_ARGS: JSON.stringify([MOCK]),
      TWINCAT_MCP_MODAL_PROBE: '0',
      ...extraEnv
    },
    stderr: 'pipe'
  });
  if (transport.stderr) readline.createInterface({ input: transport.stderr, crlfDelay: Infinity }).on('line', (l) => stderr.push(l));
  const client = new Client({ name: 'test-client', version: '0.0.0' }, { capabilities: {} });
  client.setNotificationHandler(LoggingMessageNotificationSchema, (n) => logs.push(n.params));
  await client.connect(transport);
  return { client, logs, stderr };
}

function parse(result) {
  assert.equal(result.content[0].type, 'text');
  return JSON.parse(result.content[0].text);
}

// The mock IDE pid 4242 is not a real TcXaeShell.exe: skip the tasklist liveness check so the
// lastIde hints can be asserted. The last describe runs with the check enabled.
const SKIP_PID_CHECK = { TWINCAT_MCP_SKIP_PID_CHECK: '1' };

describe('index.js over stdio (3-tool fixture)', () => {
  let client;
  let logs;
  // progress interval shortened so the progress test sees notifications within a 2.5 s call
  before(async () => ({ client, logs } = await startServer(FIXTURE, { ...SKIP_PID_CHECK, TWINCAT_MCP_PROGRESS_INTERVAL_MS: '500' })));
  after(async () => client?.close());

  test('server info and capabilities', () => {
    const info = client.getServerVersion();
    assert.equal(info.name, 'tcauto');
    assert.equal(info.version, '0.1.0');
    const caps = client.getServerCapabilities();
    assert.ok(caps.tools);
    assert.ok(caps.logging);
  });

  test('listTools returns 3 catalog + 4 composite tools with JSON schemas', async () => {
    const { tools } = await client.listTools();
    const names = tools.map((t) => t.name).sort();
    assert.deepEqual(names, ['BuildProject', 'ConnectIde', 'GetIdeModalDialog', 'GetStatus', 'QuickRead', 'ReadVariable', 'RunLifecycle']);
    const read = tools.find((t) => t.name === 'ReadVariable');
    assert.equal(read.inputSchema.type, 'object');
    assert.deepEqual(read.inputSchema.required, ['Path']);
    assert.equal(read.inputSchema.additionalProperties, false);
    const modal = tools.find((t) => t.name === 'GetIdeModalDialog');
    assert.match(modal.description, /modal dialog/i);
    assert.match(modal.description, /ConnectIde/);
    assert.equal(modal.inputSchema.properties.ProcessId.type, 'integer');
    assert.equal(modal.inputSchema.properties.ProcessId.minimum, 1);
  });

  test('listTools carries annotations: composites hard-coded, catalog tools from tools.json', async () => {
    const { tools } = await client.listTools();
    const byName = Object.fromEntries(tools.map((t) => [t.name, t]));
    assert.equal(byName.RunLifecycle.annotations.destructiveHint, true);
    assert.equal(byName.RunLifecycle.annotations.readOnlyHint, false);
    assert.match(byName.RunLifecycle.description, /confirm with the user first/);
    assert.deepEqual(byName.GetStatus.annotations, { readOnlyHint: true });
    assert.deepEqual(byName.QuickRead.annotations, { readOnlyHint: true });
    assert.deepEqual(byName.GetIdeModalDialog.annotations, { readOnlyHint: true });
    assert.deepEqual(byName.ReadVariable.annotations, { readOnlyHint: true }, 'annotations from tools.json pass through');
    assert.equal('annotations' in byName.ConnectIde, false, 'no annotations field when tools.json has none');
  });

  test('RunLifecycle TimeoutSec outside 10..3600 -> INVALID_PARAMS before any step runs', async () => {
    const low = parse(await client.callTool({ name: 'RunLifecycle', arguments: { TimeoutSec: 5 } }));
    assert.equal(low.error.code, 'INVALID_PARAMS');
    assert.match(low.error.message, />= 10/);
    const high = parse(await client.callTool({ name: 'RunLifecycle', arguments: { TimeoutSec: 99999 } }));
    assert.equal(high.error.code, 'INVALID_PARAMS');
    assert.match(high.error.message, /<= 3600/);
    assert.equal(low.data, undefined, 'no steps ran');
  });

  test('ReadVariable TimeoutMs above the schema maximum -> INVALID_PARAMS (not a bridge call)', async () => {
    const res = parse(await client.callTool({ name: 'ReadVariable', arguments: { Path: ['MAIN.x'], TimeoutMs: 99999999 } }));
    assert.equal(res.error.code, 'INVALID_PARAMS');
    assert.match(res.error.message, /TimeoutMs.*<= 600000/);
  });

  test('GetStatus before ConnectIde -> isError, NOT_CONNECTED with hint and bridge state', async () => {
    const res = await client.callTool({ name: 'GetStatus', arguments: {} });
    assert.equal(res.isError, true);
    assert.match(res.content[0].text, /NOT_CONNECTED/);
    assert.match(res.content[0].text, /Run ConnectIde first/);
    const body = parse(res);
    assert.equal(body.success, false);
    assert.equal(body.data.bridge.ideConnected, false);
    assert.deepEqual(res.structuredContent, body);
  });

  test('GetIdeModalDialog before ConnectIde -> NOT_CONNECTED from the modal op', async () => {
    const res = await client.callTool({ name: 'GetIdeModalDialog', arguments: { TimeoutSec: 2 } });
    assert.equal(res.isError, true);
    assert.equal(parse(res).error.code, 'NOT_CONNECTED');
  });

  test('unknown parameter -> INVALID_PARAMS', async () => {
    const res = await client.callTool({ name: 'ConnectIde', arguments: { Bogus: 1 } });
    assert.equal(res.isError, true);
    const body = parse(res);
    assert.equal(body.error.code, 'INVALID_PARAMS');
    assert.equal(body.error.message, "Unknown parameter 'Bogus' for ConnectIde");
    assert.match(body.error.hint, /Allowed: ProgId, SolutionPath, NoLaunch/);
  });

  test('unknown tool -> UNKNOWN_TOOL', async () => {
    const res = await client.callTool({ name: 'Nope', arguments: {} });
    assert.equal(res.isError, true);
    assert.equal(parse(res).error.code, 'UNKNOWN_TOOL');
  });

  test('BuildProject Hang -> BRIDGE_TIMEOUT (tool timeoutMs 4000), then ConnectIde works again', async () => {
    const t0 = Date.now();
    const res = await client.callTool({ name: 'BuildProject', arguments: { Hang: true } });
    const elapsed = Date.now() - t0;
    assert.equal(res.isError, true);
    const body = parse(res);
    assert.equal(body.error.code, 'BRIDGE_TIMEOUT');
    assert.match(body.error.hint, /GetIdeModalDialog/, 'generic hint while no IDE is known');
    assert.equal(body.data.lastIde, null, 'no ConnectIde yet -> lastIde null');
    assert.equal(body.data.bridgeRestarted, true);
    assert.ok(elapsed >= 3900 && elapsed < 15000, `timed out after ${elapsed} ms`);

    const again = await client.callTool({ name: 'ConnectIde', arguments: { ProgId: 'Test.DTE' } });
    assert.equal(again.isError, false);
    const ok = parse(again);
    assert.equal(ok.success, true);
    assert.equal(ok.data.progId, 'Test.DTE');
    assert.ok(Number.isInteger(ok.data.seq) && ok.data.seq > 0);
    assert.ok(!Number.isNaN(Date.parse(ok.data.startedAt)));
    assert.ok(!Number.isNaN(Date.parse(ok.data.finishedAt)));
  });

  test('GetIdeModalDialog after ConnectIde -> success, dialog null', async () => {
    const res = await client.callTool({ name: 'GetIdeModalDialog', arguments: {} });
    assert.equal(res.isError, false);
    const body = parse(res);
    assert.equal(body.data.dialog, null);
    assert.equal(body.data.ideProcessId, 4242);
  });

  test('BuildProject Hang after ConnectIde -> BRIDGE_TIMEOUT carries data.lastIde (pid 4242, launched) and a taskkill hint', async () => {
    const connect = parse(await client.callTool({ name: 'ConnectIde', arguments: { SolutionPath: 'C:\\x\\Demo.sln' } }));
    assert.equal(connect.success, true);
    assert.equal(connect.data.ideProcessId, 4242);
    assert.equal(connect.data.selectedBy, 'launched');

    const res = await client.callTool({ name: 'BuildProject', arguments: { Hang: true } });
    assert.equal(res.isError, true);
    const body = parse(res);
    assert.equal(body.error.code, 'BRIDGE_TIMEOUT');
    assert.deepEqual(body.data.lastIde, { ideProcessId: 4242, selectedBy: 'launched', solution: 'C:\\x\\Demo.sln', ideMainHwnd: 16962 });
    assert.equal(body.data.bridgeRestarted, true);
    assert.match(body.error.hint, /4242/);
    assert.match(body.error.hint, /taskkill \/PID 4242 \/T \/F/);
    assert.match(body.error.hint, /launched by this server/);
    assert.match(body.error.hint, /Unsaved changes in that IDE will be lost; ask the user before killing it\./);
    assert.deepEqual(res.structuredContent, body);
  });

  test('GetIdeModalDialog after the bridge restart falls back to lastIde.ideProcessId (4242); explicit ProcessId wins; ProcessId 0 -> INVALID_PARAMS', async () => {
    // the restarted mock bridge knows no IDE (state.ideProcessId 0) but the server remembers 4242
    const status = parse(await client.callTool({ name: 'GetStatus', arguments: {} }));
    assert.equal(status.error.code, 'NOT_CONNECTED', 'restarted bridge has no IDE');

    const fallback = parse(await client.callTool({ name: 'GetIdeModalDialog', arguments: {} }));
    assert.equal(fallback.success, true, JSON.stringify(fallback));
    assert.equal(fallback.data.ideProcessId, 4242);
    assert.equal(fallback.data.dialog, null);

    const explicit = parse(await client.callTool({ name: 'GetIdeModalDialog', arguments: { ProcessId: 777, TimeoutSec: 1 } }));
    assert.equal(explicit.success, true);
    assert.equal(explicit.data.ideProcessId, 777);
    assert.equal(explicit.data.timeoutSec, 1);

    const bad = parse(await client.callTool({ name: 'GetIdeModalDialog', arguments: { ProcessId: 0 } }));
    assert.equal(bad.error.code, 'INVALID_PARAMS');
  });

  test('BuildProject DelayMs 1500 with a progressToken -> notifications/progress received (interval 500 ms)', async () => {
    // fixture BuildProject timeoutMs is 4000, so the delay must stay below that
    const progress = [];
    const res = await client.callTool(
      { name: 'BuildProject', arguments: { DelayMs: 1500 } },
      undefined,
      { onprogress: (p) => progress.push(p), timeout: 10000, resetTimeoutOnProgress: true }
    );
    assert.equal(res.isError, false);
    assert.equal(parse(res).success, true);
    assert.ok(progress.length >= 1, `expected at least one progress notification, got ${progress.length}`);
    const last = progress[progress.length - 1];
    assert.equal(typeof last.progress, 'number');
    assert.ok(last.progress >= 400, `progress is elapsed milliseconds, got ${last.progress}`);
    assert.match(last.message, /^BuildProject running \d+s$/);
    for (let i = 1; i < progress.length; i++) assert.ok(progress[i].progress > progress[i - 1].progress, 'progress is strictly increasing');
  });

  test('composite steps that are not in the catalog fail with UNKNOWN_TOOL (no crash)', async () => {
    const res = await client.callTool({ name: 'RunLifecycle', arguments: { SkipBuild: true } });
    const body = parse(res);
    assert.equal(body.success, false);
    assert.equal(body.data.failedStep, 'EnableConfig');
    assert.equal(body.error.code, 'UNKNOWN_TOOL');
    assert.equal(logs.filter((l) => l.level === 'error').length, 0, 'no stderr-level logs expected');
  });

  test('ConnectIde NoLaunch then BuildProject Crash -> BRIDGE_DIED hint says the IDE was opened by the user', async () => {
    const connect = parse(await client.callTool({ name: 'ConnectIde', arguments: { NoLaunch: true } }));
    assert.equal(connect.data.selectedBy, 'first-instance');

    const res = await client.callTool({ name: 'BuildProject', arguments: { Crash: true } });
    const body = parse(res);
    assert.equal(body.error.code, 'BRIDGE_DIED');
    assert.equal(body.data.lastIde.ideProcessId, 4242);
    assert.equal(body.data.lastIde.selectedBy, 'first-instance');
    assert.equal(body.data.bridgeRestarted, true);
    assert.match(body.error.hint, /pid 4242\) was opened by the user/);
    assert.doesNotMatch(body.error.hint, /taskkill/);
  });
});

describe('index.js over stdio (extended fixture, composites)', () => {
  let client;
  let logs;
  before(async () => ({ client, logs } = await startServer(FIXTURE_EXT, SKIP_PID_CHECK)));
  after(async () => client?.close());

  test('RunLifecycle: ConnectIde -> BuildProject -> EnableConfig -> ConnectAds, all success', async () => {
    const res = await client.callTool({ name: 'RunLifecycle', arguments: { ProgId: 'X.DTE', TimeoutSec: 30 } });
    assert.equal(res.isError, false);
    const body = parse(res);
    assert.equal(body.success, true);
    assert.deepEqual(body.data.steps.map((s) => s.name), ['ConnectIde', 'BuildProject', 'EnableConfig', 'ConnectAds']);
    assert.ok(body.data.steps.every((s) => s.success && typeof s.durationMs === 'number'));
    assert.deepEqual(body.data.steps[2].result.data.params, { Force: true, TimeoutSec: 30 });
    assert.equal(body.data.failedStep, undefined);
  });

  test('GetStatus after lifecycle -> ide error in place, system + plc filled, warning log forwarded', async () => {
    const res = await client.callTool({ name: 'GetStatus', arguments: {} });
    assert.equal(res.isError, false);
    const body = parse(res);
    assert.equal(body.data.bridge.ideConnected, true);
    assert.equal(body.data.bridge.adsConnected, true);
    assert.equal(body.data.ide.success, false, 'mock Get-TcIdeInfo fails but does not abort GetStatus');
    assert.equal(body.data.ide.error.code, 'NOT_CONNECTED');
    assert.equal(body.data.system.success, true);
    assert.equal(body.data.system.data.amsNetId, '5.1.2.3.1.1', 'AmsNetId taken from bridge state');
    assert.equal(body.data.plc.success, true);

    await new Promise((r) => setTimeout(r, 100));
    const warn = logs.find((l) => l.level === 'warning' && l.logger === 'tcauto');
    assert.ok(warn, 'warning log notification received');
    assert.equal(warn.data.message, 'mock: IDE not connected');
    assert.equal(warn.data.cmdlet, 'Get-TcIdeInfo');
  });

  test('RunLifecycle stops at the first failing step', async () => {
    const res = await client.callTool({ name: 'RunLifecycle', arguments: { SkipBuild: true, NoLogin: true } });
    assert.equal(parse(res).success, true);
    // crash the bridge inside BuildProject through a direct call, then a lifecycle sees fresh state
    const crash = parse(await client.callTool({ name: 'BuildProject', arguments: { Crash: true } }));
    assert.equal(crash.error.code, 'BRIDGE_DIED');
    // the ConnectIde inside RunLifecycle went through callCatalogTool, so lastIde is known here too
    assert.equal(crash.data.lastIde.ideProcessId, 4242, 'lastIde recorded by the ConnectIde step of RunLifecycle');
    assert.match(crash.error.hint, /4242/);
    const status = parse(await client.callTool({ name: 'GetStatus', arguments: {} }));
    assert.equal(status.error.code, 'NOT_CONNECTED', 'restarted bridge has no IDE connection');
  });

  test('DisconnectIde clears lastIde -> next BRIDGE_DIED has lastIde null and the generic hint', async () => {
    const connect = parse(await client.callTool({ name: 'ConnectIde', arguments: {} }));
    assert.equal(connect.success, true);
    const disconnect = parse(await client.callTool({ name: 'DisconnectIde', arguments: {} }));
    assert.equal(disconnect.success, true);
    const crash = parse(await client.callTool({ name: 'BuildProject', arguments: { Crash: true } }));
    assert.equal(crash.error.code, 'BRIDGE_DIED');
    assert.equal(crash.data.lastIde, null);
    assert.equal(crash.data.bridgeRestarted, true);
    assert.doesNotMatch(crash.error.hint, /4242/);
    assert.match(crash.error.hint, /ConnectIde again/);
  });

  test('QuickRead connects ADS on demand', async () => {
    const res = await client.callTool({ name: 'QuickRead', arguments: { Path: ['MAIN.a', 'MAIN.b'] } });
    assert.equal(res.isError, false);
    const body = parse(res);
    assert.equal(body.data.connectedOnDemand, true);
    assert.deepEqual(body.data.values, { 'MAIN.a': 0, 'MAIN.b': 0 });

    const second = parse(await client.callTool({ name: 'QuickRead', arguments: { Path: ['MAIN.a'] } }));
    assert.equal(second.data.connectedOnDemand, false);

    const bad = await client.callTool({ name: 'QuickRead', arguments: {} });
    assert.equal(parse(bad).error.code, 'INVALID_PARAMS');
  });
});

describe('index.js over stdio (lastIde liveness check enabled)', () => {
  let client;
  before(async () => ({ client } = await startServer(FIXTURE)));
  after(async () => client?.close());

  test('BRIDGE_TIMEOUT with a lastIde pid that is not a running XAE -> lastIde cleared, generic hint, no taskkill', async () => {
    const connect = parse(await client.callTool({ name: 'ConnectIde', arguments: { SolutionPath: 'C:\\x\\Demo.sln' } }));
    assert.equal(connect.data.ideProcessId, 4242, 'mock pid; no TcXaeShell.exe/devenv.exe has this pid on the test machine');

    const body = parse(await client.callTool({ name: 'BuildProject', arguments: { Hang: true } }));
    assert.equal(body.error.code, 'BRIDGE_TIMEOUT');
    assert.equal(body.data.bridgeRestarted, true);
    assert.equal(body.data.lastIde, null, 'stale pid is forgotten');
    assert.doesNotMatch(body.error.hint, /4242/);
    assert.doesNotMatch(body.error.hint, /taskkill/);
    assert.match(body.error.hint, /GetIdeModalDialog after ConnectIde/, 'generic hint');

    // forgotten for good: the next loss does not resurrect it either
    const again = parse(await client.callTool({ name: 'BuildProject', arguments: { Crash: true } }));
    assert.equal(again.error.code, 'BRIDGE_DIED');
    assert.equal(again.data.lastIde, null);
  });
});

// ---------------------------------------------------------------- modal-dialog probe
//
// The probe is replaced by test/fixtures/mock-modal-probe.js, which polls MOCK_PROBE_TRIGGER_FILE
// every 50 ms (no initial interval wait) and appends its pid to MOCK_PROBE_PID_FILE on start.

function alive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function waitFor(cond, timeoutMs, stepMs = 25) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) {
    if (cond()) return true;
    await new Promise((r) => setTimeout(r, stepMs));
  }
  return cond();
}

function probeFiles(dir, name) {
  const trigger = path.join(dir, `${name}.trigger`);
  const pidFile = path.join(dir, `${name}.pids`);
  return {
    trigger,
    pidFile,
    env: {
      ...SKIP_PID_CHECK,
      TWINCAT_MCP_MODAL_PROBE: '1',
      TWINCAT_MCP_MODAL_PROBE_INTERVAL_SEC: '1',
      TWINCAT_MCP_PROBE_COMMAND: process.execPath,
      TWINCAT_MCP_PROBE_ARGS: JSON.stringify([MOCK_PROBE]),
      MOCK_PROBE_TRIGGER_FILE: trigger,
      MOCK_PROBE_PID_FILE: pidFile
    },
    /** atomic write (temp + rename) so the mock never reads a partial file */
    setTrigger(content) {
      const tmp = `${trigger}.tmp`;
      fs.writeFileSync(tmp, typeof content === 'string' ? content : JSON.stringify(content));
      fs.renameSync(tmp, trigger);
    },
    clearTrigger() {
      fs.rmSync(trigger, { force: true });
    },
    clearPids() {
      fs.rmSync(pidFile, { force: true });
    },
    pids() {
      if (!fs.existsSync(pidFile)) return [];
      return fs.readFileSync(pidFile, 'utf8').split(/\r?\n/).filter(Boolean).map(Number);
    }
  };
}

describe('index.js over stdio (modal probe)', () => {
  let client;
  let stderr;
  let dir;
  let pf;
  before(async () => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'twincat-mcp-probe-'));
    pf = probeFiles(dir, 'main');
    ({ client, stderr } = await startServer(FIXTURE, pf.env));
  });
  after(async () => {
    await client?.close();
    try {
      fs.rmSync(dir, { recursive: true, force: true });
    } catch {
      /* ignore */
    }
  });

  const PLC_TEXT = 'The project could not be loaded because the library Tc2_Standard is missing. ' + 'x'.repeat(300);

  test('startup log line says the probe is on', async () => {
    assert.ok(await waitFor(() => stderr.some((l) => /modal probe on \(1 s\)/.test(l)), 2000), stderr.join('\n'));
  });

  test('BuildProject Hang before any ConnectIde -> BRIDGE_TIMEOUT (no IDE pid known, no probe spawned)', async () => {
    pf.setTrigger({ title: 'TwinCAT PLC Control', text: 'never seen' });
    const body = parse(await client.callTool({ name: 'BuildProject', arguments: { Hang: true } }));
    assert.equal(body.error.code, 'BRIDGE_TIMEOUT');
    assert.deepEqual(pf.pids(), []);
    pf.clearTrigger();
  });

  test('ConnectIde, dialog up, BuildProject Hang -> IDE_MODAL_DIALOG well before the 4000 ms timeout; bridge restarted', async () => {
    const connect = parse(await client.callTool({ name: 'ConnectIde', arguments: { SolutionPath: 'C:\\x\\Demo.sln' } }));
    assert.equal(connect.success, true);
    pf.setTrigger({ title: 'TwinCAT PLC Control', text: PLC_TEXT });

    const t0 = Date.now();
    const res = await client.callTool({ name: 'BuildProject', arguments: { Hang: true } });
    const elapsed = Date.now() - t0;
    assert.equal(res.isError, true);
    const body = parse(res);
    assert.equal(body.error.code, 'IDE_MODAL_DIALOG');
    assert.equal(body.error.message, `TwinCAT PLC Control | ${PLC_TEXT.slice(0, 200)}`);
    assert.match(body.error.hint, /taskkill \/PID 4242 \/T \/F/);
    assert.match(body.error.hint, /launched by this server/);
    assert.match(body.error.hint, /'TwinCAT PLC Control'/);
    assert.match(body.error.hint, /bridge was killed/);
    assert.doesNotMatch(body.error.hint, /probably blocked/, 'decorateBridgeLoss left the modal result alone');
    assert.equal(body.data.dialogTitle, 'TwinCAT PLC Control');
    assert.equal(body.data.dialogText, PLC_TEXT);
    assert.equal(body.data.ideProcessId, 4242);
    assert.deepEqual(body.data.lastIde, { ideProcessId: 4242, selectedBy: 'launched', solution: 'C:\\x\\Demo.sln', ideMainHwnd: 16962 });
    assert.equal(body.data.bridgeRestarted, true);
    assert.ok(elapsed < 3500, `probe beat the 4000 ms tool timeout (took ${elapsed} ms)`);
    assert.ok(stderr.some((l) => /modal dialog detected on IDE pid 4242 during BuildProject: TwinCAT PLC Control/.test(l)));
    pf.clearTrigger();

    const status = parse(await client.callTool({ name: 'GetStatus', arguments: {} }));
    assert.equal(status.error.code, 'NOT_CONNECTED', 'bridge was restarted');
    const again = parse(await client.callTool({ name: 'ConnectIde', arguments: { SolutionPath: 'C:\\x\\Demo.sln' } }));
    assert.equal(again.success, true);
  });

  test('no dialog: BuildProject DelayMs 2500 succeeds and the probe is killed when the call ends', async () => {
    pf.clearPids();
    const body = parse(await client.callTool({ name: 'BuildProject', arguments: { DelayMs: 2500 } }));
    assert.equal(body.success, true);
    const pids = pf.pids();
    assert.equal(pids.length, 1, 'one probe spawned');
    assert.ok(await waitFor(() => !alive(pids[0]), 2000), `probe pid ${pids[0]} is dead`);
  });

  test('a crashing probe is only logged; the call succeeds', async () => {
    pf.setTrigger('CRASH');
    const body = parse(await client.callTool({ name: 'BuildProject', arguments: { DelayMs: 2500 } }));
    assert.equal(body.success, true);
    assert.ok(await waitFor(() => stderr.some((l) => /modal-probe.*mock probe crash/.test(l)), 1000), stderr.join('\n'));
    pf.clearTrigger();
  });

  test('tools outside PROBED_TOOLS (ReadVariable) get no probe', async () => {
    pf.clearPids();
    pf.setTrigger({ title: 'TwinCAT PLC Control', text: 'x' });
    const body = parse(await client.callTool({ name: 'ReadVariable', arguments: { Path: ['MAIN.x'] } }));
    assert.equal(body.error.code, 'NOT_CONNECTED');
    await new Promise((r) => setTimeout(r, 200));
    assert.deepEqual(pf.pids(), []);
    pf.clearTrigger();
  });

  test('IDE opened by the user (NoLaunch): hint says dismiss it, no taskkill', async () => {
    const connect = parse(await client.callTool({ name: 'ConnectIde', arguments: { NoLaunch: true } }));
    assert.equal(connect.data.selectedBy, 'first-instance');
    pf.setTrigger({ title: 'Assertion Failed', text: '' });
    const body = parse(await client.callTool({ name: 'BuildProject', arguments: { Hang: true } }));
    assert.equal(body.error.code, 'IDE_MODAL_DIALOG');
    assert.equal(body.error.message, 'Assertion Failed', 'empty text -> title only');
    assert.match(body.error.hint, /pid 4242\) shows the modal dialog 'Assertion Failed' and was opened by the user/);
    assert.doesNotMatch(body.error.hint, /taskkill/);
    assert.equal(body.data.lastIde.selectedBy, 'first-instance');
    pf.clearTrigger();
  });

  test('ConnectIde while the previous IDE still shows the dialog -> probed with the previous pid; lastIde cleared', async () => {
    // lastIde is still 4242 / first-instance from the previous test, whose kill left the bridge down.
    // Bring it up first: a call queued while the bridge restarts would be 'dequeued' by the probe
    // (bridgeRestarted false) instead of killed in flight, which is what this test is about.
    assert.equal(parse(await client.callTool({ name: 'GetStatus', arguments: {} })).error.code, 'NOT_CONNECTED');
    pf.setTrigger({ title: 'TwinCAT PLC Control', text: 'still up' });
    const body = parse(await client.callTool({ name: 'ConnectIde', arguments: { DelayMs: 2500 } }));
    assert.equal(body.error.code, 'IDE_MODAL_DIALOG');
    assert.equal(body.data.ideProcessId, 4242);
    assert.equal(body.data.lastIde, null, 'cleared when ConnectIde started');
    assert.equal(body.data.bridgeRestarted, true);
    assert.match(body.error.hint, /opened by the user/, 'hint uses the identity of the previous IDE');
  });

  test('no lastIde (cleared by the failed ConnectIde) -> BuildProject Hang ends in BRIDGE_TIMEOUT, no probe', async () => {
    pf.clearPids();
    // trigger is still present from the previous test
    const body = parse(await client.callTool({ name: 'BuildProject', arguments: { Hang: true } }));
    assert.equal(body.error.code, 'BRIDGE_TIMEOUT');
    assert.deepEqual(pf.pids(), []);
    pf.clearTrigger();
  });
});

describe('index.js over stdio (modal probe, extended fixture)', () => {
  let client;
  let dir;
  let pf;
  before(async () => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'twincat-mcp-probe-ext-'));
    pf = probeFiles(dir, 'ext');
    ({ client } = await startServer(FIXTURE_EXT, pf.env));
  });
  after(async () => {
    await client?.close();
    try {
      fs.rmSync(dir, { recursive: true, force: true });
    } catch {
      /* ignore */
    }
  });

  test('DisconnectIde clears lastIde -> no probe for the next BuildProject', async () => {
    assert.equal(parse(await client.callTool({ name: 'ConnectIde', arguments: {} })).success, true);
    assert.equal(parse(await client.callTool({ name: 'DisconnectIde', arguments: {} })).success, true);
    pf.clearPids();
    pf.setTrigger({ title: 'TwinCAT PLC Control', text: 'x' });
    const body = parse(await client.callTool({ name: 'BuildProject', arguments: { DelayMs: 400 } }));
    assert.equal(body.success, true, 'not aborted');
    assert.deepEqual(pf.pids(), []);
    pf.clearTrigger();
  });
});

describe('index.js over stdio (modal probe: ConnectIde policy, late hits, probe argv)', () => {
  let client;
  let stderr;
  let dir;
  let pf;
  before(async () => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'twincat-mcp-probe-pol-'));
    pf = probeFiles(dir, 'pol');
    ({ client, stderr } = await startServer(FIXTURE, { ...pf.env, MOCK_PROBE_ECHO: '1' }));
  });
  after(async () => {
    await client?.close();
    try {
      fs.rmSync(dir, { recursive: true, force: true });
    } catch {
      /* ignore */
    }
  });

  const DIALOG = { title: 'TwinCAT PLC Control', text: 'still up' };

  /** No dialog, ConnectIde to Demo.sln: lastIde = 4242 / launched / Demo.sln / hwnd 16962. */
  async function connectDemo() {
    pf.clearTrigger();
    const r = parse(await client.callTool({ name: 'ConnectIde', arguments: { SolutionPath: 'C:\\x\\Demo.sln' } }));
    assert.equal(r.success, true, JSON.stringify(r));
  }

  test('lastIde.ideMainHwnd (16962 from op state) and the call timeout reach the probe argv', async () => {
    await connectDemo();
    const from = stderr.length;
    const body = parse(await client.callTool({ name: 'BuildProject', arguments: { DelayMs: 500 } }));
    assert.equal(body.success, true);
    const argvLine = () => stderr.slice(from).find((l) => /\[modal-probe\] argv /.test(l));
    assert.ok(await waitFor(() => argvLine() !== undefined, 2000), stderr.slice(from).join('\n'));
    const line = argvLine();
    assert.match(line, /"-MainHwnd","16962"/);
    assert.match(line, /"-ConfirmScans","2"/);
    assert.match(line, /"-MaxLifetimeSec","64"/, 'ceil(4000 ms / 1000) + 60');
    assert.match(line, /"-ScanScript","[^"]*Get-TcIdeModalDialog\.ps1"/);
  });

  test('ConnectIde to a DIFFERENT solution: probe of the previous IDE is log-only, call not aborted', async () => {
    await connectDemo();
    pf.setTrigger(DIALOG);
    const from = stderr.length;
    const body = parse(await client.callTool({ name: 'ConnectIde', arguments: { SolutionPath: 'C:\\x\\Other.sln', DelayMs: 1500 } }));
    assert.equal(body.success, true, JSON.stringify(body));
    assert.equal(body.data.solution, 'C:\\x\\Other.sln');
    assert.ok(
      stderr.slice(from).some((l) => /previous IDE \(pid 4242\) shows dialog 'TwinCAT PLC Control'.*not aborted/.test(l)),
      stderr.slice(from).join('\n')
    );
  });

  test('ConnectIde to the SAME solution (case / path normalised) -> IDE_MODAL_DIALOG', async () => {
    await connectDemo();
    pf.setTrigger(DIALOG);
    const body = parse(await client.callTool({ name: 'ConnectIde', arguments: { SolutionPath: 'c:\\X\\.\\demo.SLN', DelayMs: 1500 } }));
    assert.equal(body.error?.code, 'IDE_MODAL_DIALOG', JSON.stringify(body));
    assert.equal(body.data.ideProcessId, 4242);
  });

  test('ConnectIde NoLaunch -> IDE_MODAL_DIALOG (kill mode)', async () => {
    await connectDemo();
    pf.setTrigger(DIALOG);
    const body = parse(await client.callTool({ name: 'ConnectIde', arguments: { NoLaunch: true, DelayMs: 1500 } }));
    assert.equal(body.error?.code, 'IDE_MODAL_DIALOG', JSON.stringify(body));
  });

  test('ConnectIde without SolutionPath / NoLaunch -> IDE_MODAL_DIALOG (kill mode)', async () => {
    await connectDemo();
    pf.setTrigger(DIALOG);
    const body = parse(await client.callTool({ name: 'ConnectIde', arguments: { DelayMs: 1500 } }));
    assert.equal(body.error?.code, 'IDE_MODAL_DIALOG', JSON.stringify(body));
  });

  test('late hit racing the end of the call -> success or IDE_MODAL_DIALOG, never a crash; the server keeps answering', async () => {
    await connectDemo();
    pf.setTrigger({ ...DIALOG, delayMs: 1200 });
    const body = parse(await client.callTool({ name: 'BuildProject', arguments: { DelayMs: 1200 } }));
    assert.ok(body.success === true || body.error?.code === 'IDE_MODAL_DIALOG', JSON.stringify(body));
    pf.clearTrigger();
    const status = parse(await client.callTool({ name: 'GetStatus', arguments: {} }));
    assert.equal(typeof status.success, 'boolean');
    assert.ok(!['BRIDGE_TIMEOUT', 'BRIDGE_DIED', 'INTERNAL_ERROR'].includes(status.error?.code), JSON.stringify(status));
  });

  test('a hit that would come after the call ended: call succeeds, probe killed before it can report', async () => {
    await connectDemo();
    pf.clearPids();
    pf.setTrigger({ ...DIALOG, delayMs: 3000 });
    const from = stderr.length;
    const body = parse(await client.callTool({ name: 'BuildProject', arguments: { DelayMs: 300 } }));
    assert.equal(body.success, true, JSON.stringify(body));
    const pids = pf.pids();
    assert.equal(pids.length, 1, 'one probe spawned');
    assert.ok(await waitFor(() => !alive(pids[0]), 2000), `probe pid ${pids[0]} is dead`);
    assert.ok(!stderr.slice(from).some((l) => /modal dialog/.test(l)), 'nothing reported');
    pf.clearTrigger();
  });
});
