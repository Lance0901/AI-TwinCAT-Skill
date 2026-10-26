// RunLifecycle optional SetTarget step, over stdio against the mock bridge.
import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { QuickRead } from '../lib/composites.js';

// #57: QuickRead adds connectedOnDemand without changing the shape of data (same rule as stampOrder).
describe('QuickRead data shape (no bridge)', () => {
  const run = (data) => QuickRead.run({ callTool: async () => (data === undefined ? { success: true } : { success: true, data }) }, { Path: ['MAIN.a', 'MAIN.b'] });

  test('array data stays an array, connectedOnDemand at the top level', async () => {
    const r = await run([{ path: 'MAIN.a', value: 1 }, { path: 'MAIN.b', error: 'x', code: 'SYMBOL_NOT_FOUND' }]);
    assert.ok(Array.isArray(r.data));
    assert.equal(r.data.length, 2);
    assert.equal(r.connectedOnDemand, false);
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

describe('RunLifecycle TargetAmsNetId', () => {
  let client;
  before(async () => {
    client = await startServer();
  });
  after(async () => client?.close());

  test('with TargetAmsNetId: SetTarget runs between ConnectIde and BuildProject', async () => {
    const body = parse(await client.callTool({ name: 'RunLifecycle', arguments: { TargetAmsNetId: '5.1.2.3.1.1', TimeoutSec: 30 } }));
    assert.equal(body.success, true);
    assert.deepEqual(body.data.steps.map((s) => s.name), ['ConnectIde', 'SetTarget', 'BuildProject', 'EnableConfig', 'ConnectAds']);
    // NetId only: no PLATFORM_UNKNOWN on runtimes without TARGETINFO, EnableConfig checks the platform
    assert.deepEqual(body.data.steps[1].result.data.params, { AmsNetId: '5.1.2.3.1.1', NoPlatformSwitch: true });
    assert.equal(body.data.steps[3].result.data.params.Platform, undefined);
  });

  test('AllowUnresolvedLibrary is passed to BuildProject and EnableConfig only when true (#45)', async () => {
    const on = parse(await client.callTool({ name: 'RunLifecycle', arguments: { AllowUnresolvedLibrary: true } }));
    assert.equal(on.success, true);
    const byName = Object.fromEntries(on.data.steps.map((s) => [s.name, s]));
    assert.equal(byName.BuildProject.result.data.params.AllowUnresolvedLibrary, true);
    assert.equal(byName.EnableConfig.result.data.params.AllowUnresolvedLibrary, true);
    const off = parse(await client.callTool({ name: 'RunLifecycle', arguments: {} }));
    const offBy = Object.fromEntries(off.data.steps.map((s) => [s.name, s]));
    assert.equal(offBy.BuildProject.result.data.params.AllowUnresolvedLibrary, undefined);
    assert.equal(offBy.EnableConfig.result.data.params.AllowUnresolvedLibrary, undefined);
  });

  test('without TargetAmsNetId (or empty): no SetTarget step', async () => {
    for (const args of [{}, { TargetAmsNetId: '' }]) {
      const body = parse(await client.callTool({ name: 'RunLifecycle', arguments: args }));
      assert.equal(body.success, true);
      assert.deepEqual(body.data.steps.map((s) => s.name), ['ConnectIde', 'BuildProject', 'EnableConfig', 'ConnectAds']);
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
    assert.deepEqual(body.data.steps.map((s) => s.name), ['ConnectIde', 'SetTarget', 'BuildProject', 'EnableConfig', 'ConnectAds']);
    assert.deepEqual(body.data.steps[1].result.data.params, { AmsNetId: '5.1.2.3.1.1', Platform: 'TwinCAT OS (x64)' });
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
