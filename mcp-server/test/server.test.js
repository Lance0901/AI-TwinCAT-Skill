// End-to-end: real MCP client over stdio -> index.js -> mock bridge.
import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { LoggingMessageNotificationSchema } from '@modelcontextprotocol/sdk/types.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const INDEX = path.join(__dirname, '..', 'index.js');
const FIXTURE = path.join(__dirname, 'fixtures', 'tools.fixture.json');
const FIXTURE_EXT = path.join(__dirname, 'fixtures', 'tools.fixture.ext.json');
const MOCK = path.join(__dirname, 'fixtures', 'mock-bridge.js');

async function startServer(toolsJson, extraEnv = {}) {
  const logs = [];
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [INDEX],
    env: {
      ...process.env,
      TWINCAT_MCP_TOOLS_JSON: toolsJson,
      TWINCAT_MCP_BRIDGE_COMMAND: process.execPath,
      TWINCAT_MCP_BRIDGE_ARGS: JSON.stringify([MOCK]),
      ...extraEnv
    },
    stderr: 'pipe'
  });
  const client = new Client({ name: 'test-client', version: '0.0.0' }, { capabilities: {} });
  client.setNotificationHandler(LoggingMessageNotificationSchema, (n) => logs.push(n.params));
  await client.connect(transport);
  return { client, logs };
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

  test('BuildProject Hang -> BRIDGE_TIMEOUT (tool timeoutMs 2000), then ConnectIde works again', async () => {
    const t0 = Date.now();
    const res = await client.callTool({ name: 'BuildProject', arguments: { Hang: true } });
    const elapsed = Date.now() - t0;
    assert.equal(res.isError, true);
    const body = parse(res);
    assert.equal(body.error.code, 'BRIDGE_TIMEOUT');
    assert.match(body.error.hint, /GetIdeModalDialog/, 'generic hint while no IDE is known');
    assert.equal(body.data.lastIde, null, 'no ConnectIde yet -> lastIde null');
    assert.equal(body.data.bridgeRestarted, true);
    assert.ok(elapsed >= 1900 && elapsed < 15000, `timed out after ${elapsed} ms`);

    const again = await client.callTool({ name: 'ConnectIde', arguments: { ProgId: 'Test.DTE' } });
    assert.equal(again.isError, false);
    const ok = parse(again);
    assert.equal(ok.success, true);
    assert.equal(ok.data.progId, 'Test.DTE');
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
    assert.deepEqual(body.data.lastIde, { ideProcessId: 4242, selectedBy: 'launched', solution: 'C:\\x\\Demo.sln' });
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
    // fixture BuildProject timeoutMs is 2000, so the delay must stay below that
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
