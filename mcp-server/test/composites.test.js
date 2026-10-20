// RunLifecycle optional SetTarget step, over stdio against the mock bridge.
import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

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
    assert.deepEqual(body.data.steps[1].result.data.params, { AmsNetId: '5.1.2.3.1.1' });
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

  test('tools/list: RunLifecycle schema has TargetAmsNetId (string)', async () => {
    const { tools } = await client.listTools();
    const rl = tools.find((t) => t.name === 'RunLifecycle');
    assert.equal(rl.inputSchema.properties.TargetAmsNetId.type, 'string');
    assert.equal(rl.inputSchema.additionalProperties, false);
    assert.match(rl.description, /SetTarget/);
  });
});
