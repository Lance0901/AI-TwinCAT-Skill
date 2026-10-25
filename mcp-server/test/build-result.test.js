// BuildProject result shape (#23) end to end without an IDE: the real index.js with the real
// tools.json, the real bridge/bridge.ps1 and the real Build-TcProject. Only the IDE / DTE / Error
// List access is mocked (fixtures/build-module/TwinCATAutomation.psm1, rows in
// fixtures/build-error-list.json), so what is asserted is what an MCP client receives after the
// bridge serialised the result.
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const INDEX = path.join(__dirname, '..', 'index.js');
const TOOLS_JSON = path.join(__dirname, '..', 'tools.json');
const FIXTURE_MODULE = path.join(__dirname, 'fixtures', 'build-module', 'TwinCATAutomation.psm1');
const isWin = process.platform === 'win32';

async function startServer(scenario) {
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [INDEX],
    env: {
      ...process.env,
      TWINCAT_MODULE_PATH: FIXTURE_MODULE,
      TWINCAT_MCP_TOOLS_JSON: TOOLS_JSON,
      TWINCAT_MCP_MODAL_PROBE: '0',
      TCAUTO_TEST_BUILD_SCENARIO: scenario
    },
    stderr: 'pipe'
  });
  const client = new Client({ name: 'build-result-test', version: '0.0.0' }, { capabilities: {} });
  await client.connect(transport);
  return client;
}

async function build(scenario) {
  const client = await startServer(scenario);
  try {
    const res = await client.callTool({ name: 'BuildProject', arguments: {} });
    return { res, body: JSON.parse(res.content[0].text) };
  } finally {
    await client.close();
  }
}

test('tools.json BuildProject description names the #23 fields', () => {
  const tools = JSON.parse(fs.readFileSync(TOOLS_JSON, 'utf8'));
  const list = Array.isArray(tools) ? tools : tools.tools;
  const bp = list.find((t) => t.name === 'BuildProject');
  for (const field of ['data.errors', 'data.libraryErrors', 'data.libraryErrorItems', 'category', 'decidedBy']) {
    assert.ok(bp.description.includes(field), `BuildProject description mentions ${field}`);
  }
});

describe('BuildProject through the real bridge (mock IDE)', { skip: !isWin && 'Windows only (powershell.exe bridge)' }, () => {
  test('library rows only (TwinCAT_Festo shape): success, errors 0, libraryErrors 7, every row category library', async () => {
    const { res, body } = await build('library-only');
    assert.notEqual(res.isError, true, JSON.stringify(body));
    assert.equal(body.success, true);
    const d = body.data;
    assert.equal(d.buildSucceeded, true);
    assert.equal(d.decidedBy, 'LastBuildInfo');
    assert.equal(d.errors, 0, 'Library Manager rows are not code errors');
    assert.equal(d.libraryErrors, 7);
    assert.equal(d.libraryErrorItems.length, 7);
    assert.equal(d.errorItems.length, 7, 'errorItems keeps every row');
    assert.deepEqual([...new Set(d.errorItems.map((i) => i.category))], ['library']);
    assert.deepEqual(d.codeErrors, []);
    assert.equal(d.libraryErrorItems[0].file, 'plc.Library Manager');
    assert.match(d.libraryErrorItems[0].description, /Could not open library/);
  });

  test('plus one C0046: BUILD_FAILED, errors 1, libraryErrors 7, the C0046 row category code', async () => {
    const { res, body } = await build('c0046');
    assert.equal(res.isError, true);
    assert.equal(body.success, false);
    assert.equal(body.error.code, 'BUILD_FAILED');
    assert.match(body.error.message, /^Build failed: 1 code error\(s\) \(\+7 library\)\. C0046 /);
    const d = body.data;
    assert.equal(d.buildSucceeded, false);
    assert.equal(d.decidedBy, 'LastBuildInfo');
    assert.equal(d.errors, 1);
    assert.equal(d.libraryErrors, 7);
    assert.equal(d.libraryErrorItems.length, 7);
    assert.equal(d.errorItems.length, 8);
    const code = d.errorItems.filter((i) => i.category === 'code');
    assert.equal(code.length, 1);
    assert.equal(code[0].code, 'C0046');
    assert.equal(code[0].line, 12);
    assert.deepEqual(d.codeErrors.map((i) => i.code), ['C0046']);
    assert.equal(d.projects[0].status, 'failed');
  });

  test('LastBuildInfo unreadable: decided by the Error List, library rows do not fail it, the C0046 row does', async () => {
    const { body } = await build('no-lbi');
    assert.equal(body.success, false);
    assert.equal(body.error.code, 'BUILD_FAILED');
    assert.equal(body.data.failedProjects, null);
    assert.equal(body.data.decidedBy, 'ErrorList');
    assert.equal(body.data.errors, 1);
    assert.equal(body.data.libraryErrors, 7);
  });
});
