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

async function build(scenario, args = {}) {
  const client = await startServer(scenario);
  try {
    const res = await client.callTool({ name: 'BuildProject', arguments: args });
    return { res, body: JSON.parse(res.content[0].text) };
  } finally {
    await client.close();
  }
}

test('tools.json BuildProject description names the #23 / #45 fields and the AllowUnresolvedLibrary input', () => {
  const tools = JSON.parse(fs.readFileSync(TOOLS_JSON, 'utf8'));
  const list = Array.isArray(tools) ? tools : tools.tools;
  const bp = list.find((t) => t.name === 'BuildProject');
  for (const field of ['data.errors', 'data.libraryErrors', 'data.libraryErrorItems', 'category', 'decidedBy', 'LIBRARY_UNRESOLVED', 'codeVerified']) {
    assert.ok(bp.description.includes(field), `BuildProject description mentions ${field}`);
  }
  assert.equal(bp.inputSchema.properties.AllowUnresolvedLibrary.type, 'boolean');
});

describe('BuildProject through the real bridge (mock IDE)', { skip: !isWin && 'Windows only (powershell.exe bridge)' }, () => {
  test('no Error List rows: success, errors 0, libraryErrors 0, codeVerified true', async () => {
    const { res, body } = await build('clean');
    assert.notEqual(res.isError, true, JSON.stringify(body));
    assert.equal(body.success, true);
    assert.equal(body.data.buildSucceeded, true);
    assert.equal(body.data.errors, 0);
    assert.equal(body.data.libraryErrors, 0);
    assert.equal(body.data.codeVerified, true);
    assert.equal(body.data.warningCode, undefined);
  });

  test('library rows only (TwinCAT_Festo shape, #45): LIBRARY_UNRESOLVED, not a success; errors 0, libraryErrors 7, every row category library', async () => {
    const { res, body } = await build('library-only');
    assert.equal(res.isError, true, JSON.stringify(body));
    assert.equal(body.success, false);
    assert.equal(body.error.code, 'LIBRARY_UNRESOLVED');
    assert.match(body.error.message, /7 unresolved library error\(s\), so the PLC code may not have been compiled/);
    assert.match(body.error.hint, /Library Manager/);
    const d = body.data;
    assert.equal(d.buildSucceeded, null, 'never true while the code may not have been compiled');
    assert.equal(d.codeVerified, false);
    assert.equal(d.failedProjects, 0);
    assert.equal(d.decidedBy, 'LastBuildInfo');
    assert.equal(d.projects[0].status, 'unknown');
    assert.equal(d.coverageComplete, false);
    assert.equal(d.errors, 0, 'Library Manager rows are not code errors');
    assert.equal(d.libraryErrors, 7);
    assert.equal(d.libraryErrorItems.length, 7);
    assert.equal(d.errorItems.length, 7, 'errorItems keeps every row');
    assert.deepEqual([...new Set(d.errorItems.map((i) => i.category))], ['library']);
    assert.deepEqual(d.codeErrors, []);
    assert.equal(d.libraryErrorItems[0].file, 'plc.Library Manager');
    assert.match(d.libraryErrorItems[0].description, /Could not open library/);
  });

  test('library rows only + AllowUnresolvedLibrary: success with warningCode LIBRARY_UNRESOLVED, codeVerified false', async () => {
    const { res, body } = await build('library-only', { AllowUnresolvedLibrary: true });
    assert.notEqual(res.isError, true, JSON.stringify(body));
    assert.equal(body.success, true);
    assert.equal(body.data.buildSucceeded, true);
    assert.equal(body.data.codeVerified, false);
    assert.equal(body.data.warningCode, 'LIBRARY_UNRESOLVED');
    assert.match(body.data.libraryWarning, /may not have been compiled/);
    assert.equal(body.data.errors, 0);
    assert.equal(body.data.libraryErrors, 7);
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

  test('LastBuildInfo unreadable + library rows only: decided by the Error List, still LIBRARY_UNRESOLVED', async () => {
    const { body } = await build('no-lbi-library');
    assert.equal(body.success, false);
    assert.equal(body.error.code, 'LIBRARY_UNRESOLVED');
    assert.equal(body.data.failedProjects, null);
    assert.equal(body.data.decidedBy, 'ErrorList');
    assert.equal(body.data.buildSucceeded, null);
  });

  test('Error List unreadable (LastBuildInfo 0): success with warningCode CODE_NOT_VERIFIED, codeVerified null, libraryErrors null', async () => {
    const { res, body } = await build('errorlist-unavailable');
    assert.notEqual(res.isError, true, JSON.stringify(body));
    assert.equal(body.success, true);
    assert.equal(body.data.errorListError, 'ERRORLIST_UNAVAILABLE');
    assert.equal(body.data.codeVerified, null);
    assert.equal(body.data.libraryErrors, null);
    assert.equal(body.data.errors, 0, 'falls back to failedProjects');
    assert.equal(body.data.warningCode, 'CODE_NOT_VERIFIED');
    assert.deepEqual(body.data.warningCodes, ['CODE_NOT_VERIFIED']);
    assert.match(body.data.warning, /Error List could not be read \(ERRORLIST_UNAVAILABLE\)/);
  });

  test('code row with a file but no line (unknown UI language): success with CODE_NOT_VERIFIED, codeVerified false', async () => {
    const { body } = await build('unlocated-code');
    assert.equal(body.success, true);
    assert.equal(body.data.errorItems[0].category, 'code');
    assert.equal(body.data.errors, 1);
    assert.equal(body.data.codeVerified, false);
    assert.equal(body.data.warningCode, 'CODE_NOT_VERIFIED');
    assert.match(body.data.warning, /1 code row\(s\) without a line number/);
  });

  test('build-summary row without file: category other, not counted in errors, shown in the failure message', async () => {
    const { body } = await build('other-row');
    assert.equal(body.error.code, 'BUILD_FAILED');
    assert.equal(body.data.errors, 0);
    assert.equal(body.data.libraryErrors, 7);
    const other = body.data.errorItems.filter((i) => i.category === 'other');
    assert.equal(other.length, 1);
    assert.match(body.error.message, /^Build failed: 0 code error\(s\) \(\+7 library\)\. Build of project 'plc' failed/);
  });

  test('skipped PLC project + library rows + AllowUnresolvedLibrary: warningCodes keep both, warningCode is the skipped one', async () => {
    const { body } = await build('skipped-library', { AllowUnresolvedLibrary: true });
    assert.equal(body.success, true);
    assert.deepEqual(body.data.warningCodes, ['PROJECT_SKIPPED_BY_CONFIGURATION', 'LIBRARY_UNRESOLVED']);
    assert.equal(body.data.warningCode, 'PROJECT_SKIPPED_BY_CONFIGURATION');
    assert.deepEqual(body.data.skippedProjects, ['plc2']);
    assert.match(body.data.libraryWarning, /may not have been compiled/);
  });

  test('ExpectedProject + library rows only: LIBRARY_UNRESOLVED (not BUILD_COVERAGE_UNKNOWN)', async () => {
    const { body } = await build('library-only', { ExpectedProject: ['plc'] });
    assert.equal(body.success, false);
    assert.equal(body.error.code, 'LIBRARY_UNRESOLVED');
    assert.deepEqual(body.data.expectedProjects, ['plc']);
  });
});

describe('EnableConfig after a platform switch whose build stops at LIBRARY_UNRESOLVED (#45)', { skip: !isWin && 'Windows only (powershell.exe bridge)' }, () => {
  test('switch + LIBRARY_UNRESOLVED, then BUILD_REQUIRED until a build succeeds, then the activation is attempted', async () => {
    const client = await startServer('library-only');
    const call = async (name, args = {}) => JSON.parse((await client.callTool({ name, arguments: args })).content[0].text);
    try {
      // 1. target says TwinCAT OS (x64), solution is TwinCAT RT (x64): platform-fix, then the build fails
      const first = await call('EnableConfig', { Force: true });
      assert.equal(first.success, false);
      assert.equal(first.error.code, 'LIBRARY_UNRESOLVED', JSON.stringify(first.error));
      assert.match(first.error.message, /platform switch to 'TwinCAT OS \(x64\)' failed \(the solution platform stays switched/);
      assert.match(first.error.hint, /BuildProject must succeed before EnableConfig activates again.*EnableConfig AllowUnresolvedLibrary=true\)/);
      assert.deepEqual(first.data.steps.map((s) => [s.step, s.ok]), [['platform-fix', true], ['platform-fix-build', false]]);

      // 2. platforms are equal now, so no rebuild would happen: refused instead of activating old output
      const second = await call('EnableConfig', { Force: true });
      assert.equal(second.error.code, 'BUILD_REQUIRED', JSON.stringify(second.error));
      assert.match(second.error.message, /switched from 'Release\|TwinCAT RT \(x64\)' to 'Release\|TwinCAT OS \(x64\)'/);
      assert.ok(!second.data.steps.some((s) => s.step === 'set-config'), 'nothing activated');

      // 3. an accepted build clears it; EnableConfig then gets to set-config (mock runtime fails there)
      const build = await call('BuildProject', { AllowUnresolvedLibrary: true });
      assert.equal(build.success, true);
      const third = await call('EnableConfig', { Force: true });
      assert.equal(third.error.code, 'FIXTURE_NO_RUNTIME', JSON.stringify(third.error));
      assert.ok(third.data.steps.some((s) => s.step === 'set-config'));
    } finally {
      await client.close();
    }
  });

  test('RunLifecycle stops at BuildProject LIBRARY_UNRESOLVED with the AllowUnresolvedLibrary / SkipBuild hint', async () => {
    const client = await startServer('library-only');
    try {
      const r = JSON.parse((await client.callTool({ name: 'RunLifecycle', arguments: {} })).content[0].text);
      assert.equal(r.success, false);
      assert.equal(r.data.failedStep, 'BuildProject');
      assert.equal(r.error.code, 'LIBRARY_UNRESOLVED');
      assert.match(r.error.hint, /Library Manager/);
      assert.match(r.error.hint, /BuildProject AllowUnresolvedLibrary=true and then RunLifecycle SkipBuild=true/);
    } finally {
      await client.close();
    }
  });

  test('EnableConfig AllowUnresolvedLibrary: the platform-fix-build accepts the library rows', async () => {
    const client = await startServer('library-only');
    try {
      const r = JSON.parse((await client.callTool({ name: 'EnableConfig', arguments: { Force: true, AllowUnresolvedLibrary: true } })).content[0].text);
      assert.equal(r.error.code, 'FIXTURE_NO_RUNTIME', JSON.stringify(r.error));
      assert.deepEqual(r.data.steps.slice(0, 2).map((s) => [s.step, s.ok]), [['platform-fix', true], ['platform-fix-build', true]]);
    } finally {
      await client.close();
    }
  });
});
