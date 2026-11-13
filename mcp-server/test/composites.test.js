// RunLifecycle optional SetTarget step, over stdio against the mock bridge.
import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { QuickRead, RunLifecycle, GetStatus } from '../lib/composites.js';

// #57: QuickRead adds connectedOnDemand without changing the shape of data (same rule as stampOrder).
describe('QuickRead data shape (no bridge)', () => {
  const run = (data) => QuickRead.run({ callTool: async () => (data === undefined ? { success: true } : { success: true, data }) }, { Path: ['MAIN.a', 'MAIN.b'] });

  test('array data stays an array, connectedOnDemand at the top level', async () => {
    const r = await run([{ path: 'MAIN.a', value: 1 }, { path: 'MAIN.b', error: 'x', code: 'SYMBOL_NOT_FOUND' }]);
    assert.ok(Array.isArray(r.data));
    assert.equal(r.data.length, 2);
    assert.equal(r.connectedOnDemand, false);
  });

  // #60: ReadVariable fails closed on a partial read; QuickRead keeps success=false, the code and the
  // top-level partial / failedPaths, and does not run ConnectAds (not a NOT_CONNECTED code).
  test('PARTIAL_READ_FAILED passes through with partial / failedPaths, no ConnectAds', async () => {
    const calls = [];
    const partial = {
      success: false,
      error: { code: 'PARTIAL_READ_FAILED', message: '1 of 2 paths could not be read: MAIN.b (ADS_SYMBOL_NOT_FOUND).' },
      data: [{ path: 'MAIN.a', value: 1 }, { path: 'MAIN.b', error: 'x', code: 'ADS_SYMBOL_NOT_FOUND' }],
      partial: true,
      failedPaths: ['MAIN.b']
    };
    const r = await QuickRead.run({ callTool: async (name) => { calls.push(name); return partial; } }, { Path: ['MAIN.a', 'MAIN.b'] });
    assert.deepEqual(calls, ['ReadVariable']);
    assert.equal(r.success, false);
    assert.equal(r.error.code, 'PARTIAL_READ_FAILED');
    assert.equal(r.partial, true);
    assert.deepEqual(r.failedPaths, ['MAIN.b']);
    assert.ok(Array.isArray(r.data));
    assert.equal(r.data.length, 2);
    assert.equal(r.connectedOnDemand, false);
  });

  // #141: connectedOnDemand is true only when this call ran ConnectAds; ADS already connected (the
  // first ReadVariable answers) is false for several paths exactly like for one path.
  test('#141 connectedOnDemand follows whether ConnectAds ran, for one path and several', async () => {
    for (const Path of [['MAIN.a', 'MAIN.b'], ['MAIN.a']]) {
      const multi = Path.length > 1;
      const ok = multi ? { success: true, data: Path.map((p) => ({ path: p, value: 1 })), partial: false, failedPaths: [] } : { success: true, data: { path: Path[0], value: 1 } };
      let connected = true;
      const calls = [];
      const ctx = {
        callTool: async (name) => {
          calls.push(name);
          if (name === 'ConnectAds') {
            connected = true;
            return { success: true, data: {} };
          }
          return connected ? ok : { success: false, error: { code: 'NOT_CONNECTED', message: 'ADS not connected' } };
        }
      };
      const already = await QuickRead.run(ctx, { Path });
      assert.deepEqual(calls, ['ReadVariable'], `${Path}: connected -> one ReadVariable, no ConnectAds`);
      assert.equal(already.connectedOnDemand, false, `${Path}: connected -> false`);
      assert.equal(already.success, true);
      if (multi) assert.ok(Array.isArray(already.data));
      else assert.equal(already.data.connectedOnDemand, false);

      connected = false;
      calls.length = 0;
      const onDemand = await QuickRead.run(ctx, { Path });
      assert.deepEqual(calls, ['ReadVariable', 'ConnectAds', 'ReadVariable'], `${Path}: not connected -> connect and read again`);
      assert.equal(onDemand.connectedOnDemand, true);

      calls.length = 0;
      const after = await QuickRead.run(ctx, { Path });
      assert.deepEqual(calls, ['ReadVariable'], `${Path}: the next call reuses the connection`);
      assert.equal(after.connectedOnDemand, false, `${Path}: the call after the on-demand connect -> false`);
    }
  });

  test('null data stays null; missing data becomes {connectedOnDemand}; object data gets it merged', async () => {
    const n = await run(null);
    assert.equal(n.data, null);
    assert.equal(n.connectedOnDemand, false);
    const u = await run(undefined);
    assert.deepEqual(u.data, { connectedOnDemand: false });
    const o = await run({ path: 'MAIN.a', value: 1 });
    assert.deepEqual(o.data, { path: 'MAIN.a', value: 1, connectedOnDemand: false });
  });
});

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const INDEX = path.join(__dirname, '..', 'index.js');
const FIXTURE_EXT = path.join(__dirname, 'fixtures', 'tools.fixture.ext.json');
const MOCK = path.join(__dirname, 'fixtures', 'mock-bridge.js');

async function startServer() {
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [INDEX],
    env: {
      ...process.env,
      TWINCAT_MCP_TOOLS_JSON: FIXTURE_EXT,
      TWINCAT_MCP_BRIDGE_COMMAND: process.execPath,
      TWINCAT_MCP_BRIDGE_ARGS: JSON.stringify([MOCK]),
      TWINCAT_MCP_MODAL_PROBE: '0',
      TWINCAT_MCP_SKIP_PID_CHECK: '1'
    },
    stderr: 'ignore'
  });
  const client = new Client({ name: 'test-client', version: '0.0.0' }, { capabilities: {} });
  await client.connect(transport);
  return client;
}

const parse = (res) => JSON.parse(res.content[0].text);

// #141 (real machine 2026-11-05: after the on-demand connect a second multi-path QuickRead was
// reported with connectedOnDemand=true). Same sequence against the mock bridge, which starts with
// ADS disconnected; order.seq shows how many bridge calls each QuickRead made.
describe('QuickRead connectedOnDemand over the server (#141)', () => {
  let client;
  before(async () => {
    client = await startServer();
  });
  after(async () => client?.close());

  test('on-demand connect once, then several paths and one path both report false', async () => {
    const q = async (Path) => parse(await client.callTool({ name: 'QuickRead', arguments: { Path } }));
    const first = await q(['MAIN.a', 'MAIN.Missing']);
    // the mock fails closed like the real module (#60): the reread after ConnectAds is PARTIAL_READ_FAILED
    assert.equal(first.success, false);
    assert.equal(first.error.code, 'PARTIAL_READ_FAILED', JSON.stringify(first));
    assert.equal(first.connectedOnDemand, true, JSON.stringify(first));
    assert.equal(first.partial, true);
    assert.deepEqual(first.failedPaths, ['MAIN.Missing']);
    const second = await q(['MAIN.a', 'MAIN.b']);
    assert.equal(second.success, true);
    assert.ok(Array.isArray(second.data));
    assert.equal(second.connectedOnDemand, false, `ADS already connected: ${JSON.stringify(second)}`);
    assert.equal(second.order.seq, first.order.seq + 1, 'one bridge call (ReadVariable only, no ConnectAds)');
    const third = await q(['MAIN.b']);
    assert.equal(third.connectedOnDemand, false);
    assert.equal(third.data.connectedOnDemand, false);
    assert.equal(third.order.seq, second.order.seq + 1);
    const fourth = await q(['MAIN.a', 'MAIN.b']);
    assert.equal(fourth.connectedOnDemand, false);
  });
});

describe('RunLifecycle TargetAmsNetId', () => {
  let client;
  before(async () => {
    client = await startServer();
  });
  after(async () => client?.close());

  test('with TargetAmsNetId: SetTarget runs between ConnectIde and BuildProject', async () => {
    const body = parse(await client.callTool({ name: 'RunLifecycle', arguments: { TargetAmsNetId: '5.1.2.3.1.1', TimeoutSec: 30 } }));
    assert.equal(body.success, true);
    assert.deepEqual(body.data.steps.map((s) => s.name), ['ConnectIde', 'SetTarget', 'BuildProject', 'EnableConfig', 'ConnectAds', 'GetPlcState']);
    // NetId only: no PLATFORM_UNKNOWN on runtimes without TARGETINFO, EnableConfig checks the platform
    assert.deepEqual(body.data.steps[1].result.data.params, { AmsNetId: '5.1.2.3.1.1', NoPlatformSwitch: true });
    assert.equal(body.data.steps[3].result.data.params.Platform, undefined);
  });

  test('RunLifecycle has no AllowUnresolvedLibrary and never passes it on (#61)', async () => {
    const tools = await client.listTools();
    const rl = tools.tools.find((t) => t.name === 'RunLifecycle');
    assert.equal(rl.inputSchema.properties.AllowUnresolvedLibrary, undefined);
    const off = parse(await client.callTool({ name: 'RunLifecycle', arguments: {} }));
    const offBy = Object.fromEntries(off.data.steps.map((s) => [s.name, s]));
    assert.equal(offBy.BuildProject.result.data.params.AllowUnresolvedLibrary, undefined);
    assert.equal(offBy.EnableConfig.result.data.params.AllowUnresolvedLibrary, undefined);
  });

  test('without TargetAmsNetId (or empty): no SetTarget step', async () => {
    for (const args of [{}, { TargetAmsNetId: '' }]) {
      const body = parse(await client.callTool({ name: 'RunLifecycle', arguments: args }));
      assert.equal(body.success, true);
      assert.deepEqual(body.data.steps.map((s) => s.name), ['ConnectIde', 'BuildProject', 'EnableConfig', 'ConnectAds', 'GetPlcState']);
    }
  });

  test('SetTarget failure stops the lifecycle before BuildProject', async () => {
    const body = parse(await client.callTool({ name: 'RunLifecycle', arguments: { TargetAmsNetId: '0.0.0.0.0.0' } }));
    assert.equal(body.success, false);
    assert.equal(body.data.failedStep, 'SetTarget');
    assert.equal(body.error.code, 'TARGET_NOT_FOUND');
    assert.deepEqual(body.data.steps.map((s) => s.name), ['ConnectIde', 'SetTarget']);
  });

  test('with TargetAmsNetId and Platform: SetTarget gets both', async () => {
    const body = parse(await client.callTool({ name: 'RunLifecycle', arguments: { TargetAmsNetId: '5.1.2.3.1.1', Platform: 'TwinCAT OS (x64)', TimeoutSec: 30 } }));
    assert.equal(body.success, true);
    assert.deepEqual(body.data.steps.map((s) => s.name), ['ConnectIde', 'SetTarget', 'BuildProject', 'EnableConfig', 'ConnectAds', 'GetPlcState']);
    assert.deepEqual(body.data.steps[1].result.data.params, { AmsNetId: '5.1.2.3.1.1', Platform: 'TwinCAT OS (x64)' });
    // task 1.8: EnableConfig gets the same Platform (no "-Platform was not given" warning)
    assert.equal(body.data.steps[3].name, 'EnableConfig');
    assert.equal(body.data.steps[3].result.data.params.Platform, 'TwinCAT OS (x64)');
    assert.equal(body.data.steps[3].result.data.params.Force, true);
  });

  test('Platform without TargetAmsNetId and no AmsNetId from ConnectIde: AMS_NETID_REQUIRED before BuildProject', async () => {
    const body = parse(await client.callTool({ name: 'RunLifecycle', arguments: { Platform: 'TwinCAT OS (x64)' } }));
    assert.equal(body.success, false);
    assert.equal(body.data.failedStep, 'SetTarget');
    assert.equal(body.error.code, 'AMS_NETID_REQUIRED');
    assert.deepEqual(body.data.steps.map((s) => s.name), ['ConnectIde', 'SetTarget']);
  });

  test('tools/list: RunLifecycle schema has TargetAmsNetId (string)', async () => {
    const { tools } = await client.listTools();
    const rl = tools.find((t) => t.name === 'RunLifecycle');
    assert.equal(rl.inputSchema.properties.TargetAmsNetId.type, 'string');
    assert.equal(rl.inputSchema.properties.Platform.type, 'string');
    assert.equal(rl.inputSchema.additionalProperties, false);
    assert.match(rl.description, /SetTarget/);
    assert.match(rl.description, /NoPlatformSwitch/);
    assert.match(rl.description, /TARGETINFO/);
  });
});

// #27: RunLifecycle = MCP side of Start-TcLifecycle. Fake ctx (no bridge): every step succeeds unless
// overridden; ConnectAds echoes the port it got; calls records each step with its arguments.
describe('RunLifecycle #27 (no bridge): port decision, readback, fail closed', () => {
  const ok = (data) => ({ success: true, data });
  const plc = (name, adsPort) => ({ name, projectPath: `TIPC^${name}^${name} Project`, adsPort, loggedIn: true, state: 'Run' });
  function fakeCtx(over = {}) {
    const calls = [];
    const defaults = {
      ConnectIde: () => ok({ ideProcessId: 4242, amsNetId: '5.1.2.3.1.1' }),
      SetTarget: (a) => ok({ amsNetId: a.AmsNetId }),
      BuildProject: () => ok({ completeBuild: true }),
      EnableConfig: () => ok({ loggedIn: true, plcState: 'Run', plcs: [plc('PLC1', 851)] }),
      ConnectAds: (a) => ok({ amsNetId: '5.1.2.3.1.1', port: a.Port ?? 851 }),
      GetPlcState: () => ok({ state: 'Run', adsState: 5 })
    };
    const ctx = {
      callTool: async (name, args) => {
        calls.push({ name, args });
        return (over[name] ?? defaults[name])(args);
      }
    };
    return { ctx, calls, call: (n) => calls.find((c) => c.name === n) };
  }
  const run = (f, args) => RunLifecycle.run(f.ctx, args);
  const names = (r) => r.data.steps.map((s) => s.name);

  test('all success: six data fields, steps carry code null, ConnectAds on the one PLC port', async () => {
    const f = fakeCtx();
    const r = await run(f, {});
    assert.equal(r.success, true);
    assert.equal(r.error, undefined);
    assert.deepEqual(names(r), ['ConnectIde', 'BuildProject', 'EnableConfig', 'ConnectAds', 'GetPlcState']);
    assert.deepEqual(Object.keys(r.data.steps[0]), ['name', 'success', 'code', 'durationMs', 'result']);
    assert.ok(r.data.steps.every((s) => s.success === true && s.code === null));
    assert.equal(r.data.failedStep, null);
    assert.equal(r.data.plcState, 'Run');
    assert.equal(r.data.adsPort, 851);
    assert.equal(r.data.loggedIn, true);
    assert.deepEqual(r.data.plcProjects, [plc('PLC1', 851)]);
    assert.equal(r.data.lifecycleBlock, null);
    assert.deepEqual(f.call('ConnectAds').args, { Port: 851 });
    assert.deepEqual(f.call('BuildProject').args, {});
    assert.deepEqual(f.call('GetPlcState').args, {});
  });

  test('#307 data.targetKind: SetTarget wins when it ran, else ConnectIde, null when neither reports it', async () => {
    const none = await run(fakeCtx(), {});
    assert.equal(none.data.targetKind, null);
    assert.equal(none.data.targetKindSource, null);
    assert.ok('targetKind' in none.data && 'targetKindSource' in none.data);
    const ide = fakeCtx({ ConnectIde: () => ok({ ideProcessId: 4242, amsNetId: '5.1.2.3.1.1', targetKind: 'remote', targetKindSource: 'no-local-match' }) });
    const r1 = await run(ide, {});
    assert.equal(r1.data.targetKind, 'remote');
    assert.equal(r1.data.targetKindSource, 'no-local-match');
    const both = fakeCtx({
      ConnectIde: () => ok({ ideProcessId: 4242, amsNetId: '5.1.2.3.1.1', targetKind: 'remote', targetKindSource: 'no-local-match' }),
      SetTarget: (a) => ok({ amsNetId: a.AmsNetId, targetKind: 'local-umrt', targetKindSource: 'TcRegistry.xml:UmRT_Default' })
    });
    const r2 = await run(both, { TargetAmsNetId: '199.5.42.250.1.1' });
    assert.equal(r2.data.targetKind, 'local-umrt');
    assert.equal(r2.data.targetKindSource, 'TcRegistry.xml:UmRT_Default');
    // a failing step still reports the kind it saw (the SetTarget data of a PLATFORM_UNKNOWN keeps targetKind)
    const failSet = fakeCtx({
      ConnectIde: () => ok({ ideProcessId: 4242, amsNetId: '5.1.2.3.1.1', targetKind: 'remote', targetKindSource: 'no-local-match' }),
      SetTarget: () => ({ success: false, error: { code: 'PLATFORM_UNKNOWN', message: 'x' }, data: { targetKind: 'local-xar', targetKindSource: 'system-amsnetid' } })
    });
    const r3 = await run(failSet, { TargetAmsNetId: '192.168.1.1.1.1', Platform: 'TwinCAT RT (x64)' });
    assert.equal(r3.success, false);
    assert.equal(r3.data.targetKind, 'local-xar');
  });

  test('ExpectedProject / BuildTimeoutSec go to BuildProject, PlcProjectPath / NoLogin / TimeoutSec to EnableConfig', async () => {
    const f = fakeCtx({ EnableConfig: () => ok({ loggedIn: false, plcs: [plc('FrameworkUnitTest', 852)] }) });
    const r = await run(f, { ExpectedProject: ['FrameworkUnitTest'], BuildTimeoutSec: 900, PlcProjectPath: ['FrameworkUnitTest'], NoLogin: true, TimeoutSec: 300 });
    assert.equal(r.success, true);
    assert.deepEqual(f.call('BuildProject').args, { ExpectedProject: ['FrameworkUnitTest'], TimeoutSec: 900 });
    assert.deepEqual(f.call('EnableConfig').args, { Force: true, TimeoutSec: 300, NoLogin: true, PlcProjectPath: ['FrameworkUnitTest'] });
  });

  test('build failure stops at BuildProject: EnableConfig not called, error as it is', async () => {
    const err = { code: 'PROJECT_SKIPPED_BY_CONFIGURATION', message: 'mock skipped', hint: 'h' };
    const f = fakeCtx({ BuildProject: () => ({ success: false, error: err }) });
    const r = await run(f, { ExpectedProject: ['FrameworkUnitTest'] });
    assert.equal(r.success, false);
    assert.equal(r.error, err);
    assert.equal(r.data.failedStep, 'BuildProject');
    assert.equal(r.data.steps.at(-1).code, 'PROJECT_SKIPPED_BY_CONFIGURATION');
    assert.equal(f.call('EnableConfig'), undefined);
    assert.equal(r.data.plcProjects, null);
    assert.equal(r.data.adsPort, null);
    assert.equal(r.data.plcState, null);
  });

  test('LIFECYCLE_BLOCKED: error and data.lifecycleBlock as they are, no ConnectAds', async () => {
    const block = { amsNetId: '5.1.2.3.1.1', command: 'Set-TcSystemState', errorCode: 'SYSTEM_STATE_TIMEOUT' };
    const err = { code: 'LIFECYCLE_BLOCKED', message: 'blocked', hint: 'stop and report' };
    const f = fakeCtx({ EnableConfig: () => ({ success: false, error: err, data: { lifecycleBlock: block, activated: false } }) });
    const r = await run(f, {});
    assert.equal(r.error, err);
    assert.equal(r.data.lifecycleBlock, block);
    assert.equal(r.data.failedStep, 'EnableConfig');
    assert.equal(f.call('ConnectAds'), undefined);
  });

  test('AdsPort not a port of the selected PLCs -> PLC_PORT_MISMATCH (allowed ports listed), ConnectAds not called', async () => {
    const f = fakeCtx({ EnableConfig: () => ok({ loggedIn: true, plcs: [plc('FrameworkUnitTest', 852)] }) });
    const r = await run(f, { PlcProjectPath: ['FrameworkUnitTest'], AdsPort: 851 });
    assert.equal(r.success, false);
    assert.equal(r.error.code, 'PLC_PORT_MISMATCH');
    assert.match(r.error.message, /AdsPort 851/);
    assert.match(r.error.message, /allowed: 852/);
    assert.match(r.error.message, /FrameworkUnitTest:852/);
    assert.match(r.error.hint, /activated; without NoLogin also logged in \/ Run/);
    assert.equal(r.data.failedStep, 'ConnectAds');
    assert.equal(r.data.steps.at(-1).code, 'PLC_PORT_MISMATCH');
    assert.deepEqual(r.data.steps.at(-1).result.data, { adsPort: 851, allowedPorts: [852], plcs: [{ name: 'FrameworkUnitTest', projectPath: 'TIPC^FrameworkUnitTest^FrameworkUnitTest Project', adsPort: 852 }] });
    assert.equal(f.call('ConnectAds'), undefined);
    assert.equal(r.data.adsPort, null);
    assert.equal(r.data.plcProjects.length, 1);
  });

  test('port: one distinct port is the default (with or without PlcProjectPath); several distinct ports -> no Port', async () => {
    const one = () => ok({ loggedIn: true, plcs: [plc('FrameworkUnitTest', 852)] });
    const two = () => ok({ loggedIn: true, plcs: [plc('PLC1', 851), plc('FrameworkUnitTest', 852)] });
    const dup = () => ok({ loggedIn: true, plcs: [plc('FrameworkUnitTest', 852), plc('FrameworkUnitTest', 852)] });
    let f = fakeCtx({ EnableConfig: one });
    let r = await run(f, { PlcProjectPath: ['FrameworkUnitTest'] });
    assert.deepEqual(f.call('ConnectAds').args, { Port: 852 });
    assert.equal(r.data.adsPort, 852);
    f = fakeCtx({ EnableConfig: one });
    r = await run(f, {});
    assert.equal(r.success, true);
    assert.deepEqual(f.call('ConnectAds').args, { Port: 852 }, 'no PlcProjectPath, plcs=[FrameworkUnitTest:852] -> 852');
    f = fakeCtx({ EnableConfig: dup });
    r = await run(f, { PlcProjectPath: ['FrameworkUnitTest', 'FrameworkUnitTest'] });
    assert.equal(r.success, true);
    assert.deepEqual(f.call('ConnectAds').args, { Port: 852 }, 'same PLC twice = one port');
    f = fakeCtx({ EnableConfig: two });
    r = await run(f, {});
    assert.deepEqual(f.call('ConnectAds').args, {});
    assert.equal(r.data.adsPort, 851);
  });

  test('AdsPort with PlcProjectPath: must be one of the selected ports (duplicates count once)', async () => {
    const one = () => ok({ loggedIn: true, plcs: [plc('FrameworkUnitTest', 852)] });
    const two = () => ok({ loggedIn: true, plcs: [plc('PLC1', 851), plc('FrameworkUnitTest', 852)] });
    const dup = () => ok({ loggedIn: true, plcs: [plc('FrameworkUnitTest', 852), plc('FrameworkUnitTest', 852)] });
    let f = fakeCtx({ EnableConfig: one });
    let r = await run(f, { PlcProjectPath: ['FrameworkUnitTest'], AdsPort: 852 });
    assert.equal(r.success, true);
    assert.deepEqual(f.call('ConnectAds').args, { Port: 852 });
    f = fakeCtx({ EnableConfig: two });
    r = await run(f, { PlcProjectPath: ['PLC1', 'FrameworkUnitTest'], AdsPort: 853 });
    assert.equal(r.error.code, 'PLC_PORT_MISMATCH', 'two selected PLCs, 853 is neither');
    assert.match(r.error.message, /allowed: 851, 852/);
    assert.equal(f.call('ConnectAds'), undefined);
    f = fakeCtx({ EnableConfig: two });
    r = await run(f, { PlcProjectPath: ['PLC1', 'FrameworkUnitTest'], AdsPort: 852 });
    assert.equal(r.success, true);
    assert.deepEqual(f.call('ConnectAds').args, { Port: 852 });
    f = fakeCtx({ EnableConfig: dup });
    r = await run(f, { PlcProjectPath: ['FrameworkUnitTest', 'FrameworkUnitTest'], AdsPort: 851 });
    assert.equal(r.error.code, 'PLC_PORT_MISMATCH');
    assert.deepEqual(r.data.steps.at(-1).result.data.allowedPorts, [852]);
    f = fakeCtx({ EnableConfig: one });
    r = await run(f, { AdsPort: 851 });
    assert.equal(r.success, true, 'no PlcProjectPath: no mismatch check');
    assert.deepEqual(f.call('ConnectAds').args, { Port: 851 });
  });

  test('EnableConfig ordinary failure: its error, plcProjects / loggedIn still reported', async () => {
    const err = { code: 'RUNTIME_STATE_MISMATCH', message: 'verify failed', hint: 'h' };
    const f = fakeCtx({ EnableConfig: () => ({ success: false, error: err, data: { loggedIn: true, plcs: [plc('FrameworkUnitTest', 852)] } }) });
    const r = await run(f, {});
    assert.equal(r.error, err);
    assert.equal(r.data.failedStep, 'EnableConfig');
    assert.deepEqual(r.data.plcProjects, [plc('FrameworkUnitTest', 852)]);
    assert.equal(r.data.loggedIn, true);
    assert.equal(r.data.lifecycleBlock, null);
    assert.equal(f.call('ConnectAds'), undefined);
  });

  test('a step that throws -> INTERNAL_ERROR at that step, later steps not run', async () => {
    const f = fakeCtx({ BuildProject: () => { throw new Error('boom'); } });
    const r = await run(f, {});
    assert.equal(r.success, false);
    assert.equal(r.error.code, 'INTERNAL_ERROR');
    assert.match(r.error.message, /BuildProject threw: boom/);
    assert.equal(r.data.failedStep, 'BuildProject');
    assert.equal(r.data.steps.at(-1).code, 'INTERNAL_ERROR');
    assert.equal(f.call('EnableConfig'), undefined);
  });

  test('EnableConfig data.plcs null -> plcProjects null', async () => {
    const r = await run(fakeCtx({ EnableConfig: () => ok({ loggedIn: true, plcs: null }) }), {});
    assert.equal(r.success, true);
    assert.equal(r.data.plcProjects, null);
  });

  test('readback not Run -> RUNTIME_STATE_MISMATCH at GetPlcState (raw result kept); NoLogin only reports', async () => {
    const stop = () => ok({ state: 'Stop', adsState: 6 });
    let r = await run(fakeCtx({ GetPlcState: stop }), {});
    assert.equal(r.success, false);
    assert.equal(r.error.code, 'RUNTIME_STATE_MISMATCH');
    assert.match(r.error.message, /'Stop'/);
    assert.equal(r.data.failedStep, 'GetPlcState');
    const last = r.data.steps.at(-1);
    assert.equal(last.success, false);
    assert.equal(last.code, 'RUNTIME_STATE_MISMATCH');
    assert.equal(last.result.success, true);
    assert.equal(r.data.plcState, 'Stop');
    r = await run(fakeCtx({ GetPlcState: stop }), { NoLogin: true });
    assert.equal(r.success, true);
    assert.equal(r.data.plcState, 'Stop');
  });

  test('ConnectAds failure: that error, GetPlcState not run', async () => {
    const err = { code: 'ADS_PORT_NOT_FOUND', message: 'no port' };
    const f = fakeCtx({ ConnectAds: () => ({ success: false, error: err }) });
    const r = await run(f, {});
    assert.equal(r.error, err);
    assert.equal(r.data.failedStep, 'ConnectAds');
    assert.equal(f.call('GetPlcState'), undefined);
  });

  test('schema: PlcProjectPath / ExpectedProject arrays (minItems 1), AdsPort 1..65535, BuildTimeoutSec 5..7200; timeoutMs capped', () => {
    const p = RunLifecycle.inputSchema.properties;
    for (const k of ['PlcProjectPath', 'ExpectedProject']) {
      assert.equal(p[k].type, 'array');
      assert.equal(p[k].items.type, 'string');
      assert.equal(p[k].minItems, 1);
    }
    assert.deepEqual([p.AdsPort.type, p.AdsPort.minimum, p.AdsPort.maximum], ['integer', 1, 65535]);
    assert.deepEqual([p.BuildTimeoutSec.type, p.BuildTimeoutSec.minimum, p.BuildTimeoutSec.maximum], ['integer', 5, 7200]);
    assert.match(RunLifecycle.description, /Start-TcLifecycle/);
    assert.match(RunLifecycle.description, /PLC_PORT_MISMATCH/);
    assert.equal(RunLifecycle.timeoutMs, 7200000);
  });
});

describe('RunLifecycle #27 over the server (mock bridge)', () => {
  let client;
  before(async () => {
    client = await startServer();
  });
  after(async () => client?.close());

  test('PlcProjectPath FrameworkUnitTest: ConnectAds on its port 852, readback Run', async () => {
    const body = parse(await client.callTool({ name: 'RunLifecycle', arguments: { PlcProjectPath: ['FrameworkUnitTest'], ExpectedProject: ['FrameworkUnitTest'], BuildTimeoutSec: 900 } }));
    assert.equal(body.success, true, JSON.stringify(body.error));
    assert.deepEqual(body.data.steps.map((s) => s.name), ['ConnectIde', 'BuildProject', 'EnableConfig', 'ConnectAds', 'GetPlcState']);
    assert.equal(body.data.adsPort, 852);
    assert.equal(body.data.plcState, 'Run');
    assert.deepEqual(body.data.steps[1].result.data.params, { ExpectedProject: ['FrameworkUnitTest'], TimeoutSec: 900 });
    assert.deepEqual(body.data.steps[2].result.data.params.PlcProjectPath, ['FrameworkUnitTest']);
  });

  test('AdsPort 851 for FrameworkUnitTest -> PLC_PORT_MISMATCH; invalid AdsPort / BuildTimeoutSec / empty arrays -> INVALID_PARAMS', async () => {
    const mm = parse(await client.callTool({ name: 'RunLifecycle', arguments: { PlcProjectPath: ['FrameworkUnitTest'], AdsPort: 851 } }));
    assert.equal(mm.error.code, 'PLC_PORT_MISMATCH');
    assert.equal(mm.data.failedStep, 'ConnectAds');
    for (const args of [{ AdsPort: 0 }, { AdsPort: 65536 }, { BuildTimeoutSec: 4 }, { BuildTimeoutSec: 7201 }, { PlcProjectPath: [] }, { ExpectedProject: [] }]) {
      const bad = parse(await client.callTool({ name: 'RunLifecycle', arguments: args }));
      assert.equal(bad.error.code, 'INVALID_PARAMS', JSON.stringify(args));
    }
  });
});

describe('#307 GetStatus data.targetKind (no bridge)', () => {
  const ok = (data) => ({ success: true, data });
  function fakeCtx({ state = { ideConnected: true, amsNetId: null, adsConnected: false }, kind } = {}) {
    const ops = [];
    const ctx = {
      bridge: {
        call: async (op, opts) => {
          ops.push({ op, params: opts?.params });
          if (op === 'state') return ok(state);
          if (op === 'targetkind') {
            if (kind instanceof Error) throw kind;
            return kind ?? ok({ amsNetId: opts?.params?.AmsNetId ?? '5.1.2.3.1.1', targetKind: 'remote', targetKindSource: 'no-local-match' });
          }
          throw new Error(`unexpected op ${op}`);
        }
      },
      callTool: async () => ok({})
    };
    return { ctx, ops };
  }

  test('kind of the same target GetSystemState was asked about; AmsNetId passed to the targetkind op', async () => {
    const f = fakeCtx({ kind: ok({ amsNetId: '199.5.42.250.1.1', targetKind: 'local-umrt', targetKindSource: 'TcRegistry.xml:UmRT_Default' }) });
    const r = await GetStatus.run(f.ctx, { AmsNetId: '199.5.42.250.1.1' });
    assert.equal(r.success, true);
    assert.equal(r.data.targetKind, 'local-umrt');
    assert.equal(r.data.targetKindSource, 'TcRegistry.xml:UmRT_Default');
    assert.equal(r.data.targetAmsNetId, '199.5.42.250.1.1');
    assert.deepEqual(f.ops.find((o) => o.op === 'targetkind').params, { AmsNetId: '199.5.42.250.1.1' });
  });

  test('ADS connected to another NetId, no AmsNetId: the op still gets no params (the bridge decides IDE target vs ADS NetId)', async () => {
    const f = fakeCtx({ state: { ideConnected: true, amsNetId: '199.5.42.250.1.1', adsConnected: true } });
    await GetStatus.run(f.ctx, {});
    assert.deepEqual(f.ops.find((o) => o.op === 'targetkind').params, {});
  });

  test('no AmsNetId and no ADS NetId: the op gets no params (the bridge falls back to the IDE target)', async () => {
    const f = fakeCtx();
    const r = await GetStatus.run(f.ctx, {});
    assert.deepEqual(f.ops.find((o) => o.op === 'targetkind').params, {});
    assert.equal(r.data.targetKind, 'remote');
  });

  test('fail safe: op failure or throw -> unknown / unavailable, GetStatus still succeeds', async () => {
    for (const kind of [{ success: false, error: { code: 'INVALID_OP', message: 'old bridge' } }, new Error('boom')]) {
      const r = await GetStatus.run(fakeCtx({ kind }).ctx, {});
      assert.equal(r.success, true);
      assert.equal(r.data.targetKind, 'unknown');
      assert.equal(r.data.targetKindSource, 'unavailable');
      assert.equal(r.data.targetAmsNetId, null);
    }
  });

  test('IDE not connected: NOT_CONNECTED as before, targetkind not asked', async () => {
    const f = fakeCtx({ state: { ideConnected: false } });
    const r = await GetStatus.run(f.ctx, {});
    assert.equal(r.error.code, 'NOT_CONNECTED');
    assert.ok(!f.ops.some((o) => o.op === 'targetkind'));
  });
});
