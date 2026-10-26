// BuildProject result shape (#23) end to end without an IDE: the real index.js with the real
// tools.json, the real bridge/bridge.ps1 and the real Build-TcProject. Only the IDE / DTE / Error
// List access is mocked (fixtures/build-module/TwinCATAutomation.psm1, rows in
// fixtures/build-error-list.json), so what is asserted is what an MCP client receives after the
// bridge serialised the result.
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const INDEX = path.join(__dirname, '..', 'index.js');
const TOOLS_JSON = path.join(__dirname, '..', 'tools.json');
const FIXTURE_MODULE = path.join(__dirname, 'fixtures', 'build-module', 'TwinCATAutomation.psm1');
const isWin = process.platform === 'win32';

// Every server gets its own BUILD_REQUIRED state directory unless the test passes one.
const stateDirs = [];
function newStateDir() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tcauto-state-'));
  stateDirs.push(dir);
  return dir;
}
after(async () => {
  // the shared BuildProject server is closed first (its after hook is registered below)
  if (shared) {
    await shared.close();
    shared = null;
  }
  for (const dir of stateDirs) {
    try {
      fs.rmSync(dir, { recursive: true, force: true });
    } catch {
      /* a bridge that is still exiting may hold the file; it is a temp dir */
    }
  }
});

async function startServer(scenario, extraEnv = {}) {
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [INDEX],
    env: {
      ...process.env,
      TWINCAT_MODULE_PATH: FIXTURE_MODULE,
      TWINCAT_MCP_TOOLS_JSON: TOOLS_JSON,
      TWINCAT_MCP_MODAL_PROBE: '0',
      TCAUTO_TEST_BUILD_SCENARIO: scenario,
      TCAUTO_STATE_DIR: extraEnv.TCAUTO_STATE_DIR ?? newStateDir(),
      ...extraEnv
    },
    stderr: 'pipe'
  });
  const client = new Client({ name: 'build-result-test', version: '0.0.0' }, { capabilities: {} });
  await client.connect(transport);
  return client;
}

// One server for all BuildProject scenarios; the scenario is switched through a file the fixture
// reads at every build (fewer parallel powershell.exe next to the timing-sensitive probe tests).
let shared = null;
let scenarioFile = null;
async function build(scenario, args = {}) {
  if (!shared) {
    scenarioFile = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'tcauto-build-')), 'scenario.txt');
    fs.writeFileSync(scenarioFile, scenario);
    shared = await startServer(scenario, { TCAUTO_TEST_BUILD_SCENARIO_FILE: scenarioFile });
  }
  fs.writeFileSync(scenarioFile, scenario);
  return callShared('BuildProject', args);
}
/** Any tool on the shared server (started by the first build()). */
async function callShared(name, args = {}) {
  if (!shared) await build('clean');
  const res = await shared.callTool({ name, arguments: args });
  return { res, body: JSON.parse(res.content[0].text) };
}
after(async () => {
  if (shared) await shared.close();
  if (scenarioFile) fs.rmSync(path.dirname(scenarioFile), { recursive: true, force: true });
});

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

  // #58: TwinCAT_Festo on VS2022, Release|TwinCAT OS (x64) -> project TwinCAT OS (ARMT2), ShouldBuild false
  test('every PLC project skipped: codeVerified false, warningCodes add CODE_NOT_VERIFIED, solution (not project) platform', async () => {
    const { res, body } = await build('all-skipped');
    assert.notEqual(res.isError, true, JSON.stringify(body));
    assert.equal(body.success, true, 'XAE says Build succeeded; the warnings carry the gap');
    const d = body.data;
    assert.equal(d.codeVerified, false, 'no PLC code was compiled, so it is not verified');
    assert.deepEqual(d.warningCodes, ['PROJECT_SKIPPED_BY_CONFIGURATION', 'CODE_NOT_VERIFIED']);
    assert.equal(d.warningCode, 'PROJECT_SKIPPED_BY_CONFIGURATION');
    assert.equal(d.coverageComplete, false);
    assert.deepEqual(d.skippedProjects, ['plc']);
    assert.equal(d.projects[0].status, 'skipped');
    assert.equal(d.projects[0].platform, 'TwinCAT OS (ARMT2)', 'project platform stays per project');

    const ide = (await callShared('GetIdeInfo')).body;
    assert.equal(ide.success, true, JSON.stringify(ide));
    assert.equal(d.solutionPlatform, ide.data.solutionPlatform, 'same reading as GetIdeInfo');
    assert.equal(d.solutionConfiguration, `${ide.data.solutionConfiguration}|${ide.data.solutionPlatform}`);
    assert.equal(d.solutionConfiguration, 'Release|TwinCAT RT (x64)');
    assert.doesNotMatch(d.solutionConfiguration, /ARMT2/, 'not the project platform');
    assert.equal(d.projectPlatform, 'TwinCAT OS (ARMT2)');
    assert.equal(d.projectPlatform, ide.data.projectPlatform);
    assert.match(d.warning, /active solution configuration 'Release\|TwinCAT RT \(x64\)'/);
  });

  test('one of two PLC projects skipped: codeVerified false and CODE_NOT_VERIFIED as well', async () => {
    const { body } = await build('skipped');
    assert.equal(body.success, true);
    assert.equal(body.data.codeVerified, false);
    assert.deepEqual(body.data.warningCodes, ['PROJECT_SKIPPED_BY_CONFIGURATION', 'CODE_NOT_VERIFIED']);
    assert.deepEqual(body.data.projects.map((p) => [p.name, p.status]), [['plc', 'built'], ['plc2', 'skipped']]);
  });

  test('PLC project list not readable (coverageError): codeVerified null, CODE_NOT_VERIFIED', async () => {
    const { body } = await build('coverage-error');
    assert.equal(body.success, true, JSON.stringify(body));
    assert.equal(body.data.codeVerified, null);
    assert.equal(body.data.coverageComplete, false);
    assert.match(body.data.coverageError, /not readable/);
    assert.deepEqual(body.data.warningCodes, ['CODE_NOT_VERIFIED']);
    assert.match(body.data.warning, /PLC project list of the active solution configuration could not be read/);
  });

  test("solution platform only from a SolutionContext (platformSource 'context'): solutionConfiguration is the name only", async () => {
    const { body } = await build('context-platform');
    assert.equal(body.success, true);
    assert.equal(body.data.platformSource, 'context');
    assert.equal(body.data.solutionConfiguration, 'Release', 'no project platform appended');
    assert.equal(body.data.codeVerified, true);
  });

  test('complete build: codeVerified stays true, solutionConfiguration / solutionPlatform from the solution', async () => {
    const { body } = await build('clean');
    assert.equal(body.data.codeVerified, true);
    assert.equal(body.data.coverageComplete, true);
    assert.equal(body.data.solutionConfiguration, 'Release|TwinCAT RT (x64)');
    assert.equal(body.data.solutionPlatform, 'TwinCAT RT (x64)');
    assert.equal(body.data.platformSource, 'ActiveConfig');
    assert.equal(body.data.completeBuild, true);
    assert.equal(body.data.warningCodes, undefined);
  });
});

// #57 through the real bridge.ps1 and the real Get-TcSymbols / Read-TcVariable (ADS mocked in the
// fixture module): array data must reach the client element for element.
describe('array data through the real bridge (GetSymbols / ReadVariable, #57)', { skip: !isWin && 'Windows only (powershell.exe bridge)' }, () => {
  test('GetSymbols returns every symbol as an array, also for one match and for none', async () => {
    const many = (await callShared('GetSymbols', { Filter: 'MAIN*' })).body;
    assert.equal(many.success, true, JSON.stringify(many));
    assert.ok(Array.isArray(many.data), `data must be an array: ${JSON.stringify(many)}`);
    assert.deepEqual(many.data.map((s) => s.path), ['MAIN.nCounter', 'MAIN.bRun', 'MAIN.fSpeed']);
    assert.deepEqual(many.data[1], { path: 'MAIN.bRun', type: 'BOOL', size: 1, comment: 'run flag' });
    assert.ok(Number.isInteger(many.order.seq) && many.order.seq > 0, 'execution order at the top level');

    const one = (await callShared('GetSymbols', { Filter: 'GVL' })).body;
    assert.ok(Array.isArray(one.data), `one match is still an array: ${JSON.stringify(one)}`);
    assert.deepEqual(one.data.map((s) => s.path), ['GVL.nMode']);

    const none = (await callShared('GetSymbols', { Filter: 'NoSuchSymbol' })).body;
    assert.equal(none.success, true);
    assert.deepEqual(none.data, [], `no match is an empty array: ${JSON.stringify(none)}`);
  });

  test('ReadVariable with several paths returns every entry; the missing one carries its error', async () => {
    const r = (await callShared('ReadVariable', { Path: ['MAIN.nCounter', 'MAIN.nMissing'] })).body;
    assert.equal(r.success, true, JSON.stringify(r));
    assert.ok(Array.isArray(r.data), `data must be an array: ${JSON.stringify(r)}`);
    assert.equal(r.data.length, 2);
    assert.equal(r.data[0].path, 'MAIN.nCounter');
    assert.equal(r.data[0].value, 7);
    assert.equal(r.data[1].path, 'MAIN.nMissing');
    assert.match(r.data[1].error, /not found/);
    assert.ok(Number.isInteger(r.order.seq));

    const single = (await callShared('ReadVariable', { Path: ['MAIN.nCounter'] })).body;
    assert.equal(single.data.path, 'MAIN.nCounter', 'one path: data is the entry object');
    assert.equal(single.data.seq, single.order.seq);
  });
});

describe('EnableConfig after a platform switch whose build stops at LIBRARY_UNRESOLVED (#45)', { skip: !isWin && 'Windows only (powershell.exe bridge)' }, () => {
  test('switch + LIBRARY_UNRESOLVED, then BUILD_REQUIRED until a build succeeds, then the activation is attempted', async () => {
    const stateDir = newStateDir();
    const client = await startServer('library-only', { TCAUTO_STATE_DIR: stateDir });
    const call = async (name, args = {}) => JSON.parse((await client.callTool({ name, arguments: args })).content[0].text);
    try {
      // 1. target says TwinCAT OS (x64), solution is TwinCAT RT (x64): platform-fix, then the build fails
      const first = await call('EnableConfig', { Force: true });
      assert.equal(first.success, false);
      assert.equal(first.error.code, 'LIBRARY_UNRESOLVED', JSON.stringify(first.error));
      assert.match(first.error.message, /platform switch to 'TwinCAT OS \(x64\)' failed \(the solution platform stays switched/);
      assert.match(first.error.hint, /A complete BuildProject \(data\.completeBuild = true: coverageComplete and codeVerified = true, or the AllowUnresolvedLibrary switch with library errors only\) must succeed before EnableConfig activates again.*: BuildProject AllowUnresolvedLibrary=true\)/);
      assert.deepEqual(first.data.steps.map((s) => [s.step, s.ok]), [['platform-fix', true], ['platform-fix-build', false]]);

      // 2. platforms are equal now, so no rebuild would happen: refused instead of activating old output
      const second = await call('EnableConfig', { Force: true });
      assert.equal(second.error.code, 'BUILD_REQUIRED', JSON.stringify(second.error));
      assert.match(second.error.message, /switched from 'Release\|TwinCAT RT \(x64\)' to 'Release\|TwinCAT OS \(x64\)'/);
      assert.ok(!second.data.steps.some((s) => s.step === 'set-config'), 'nothing activated');
      assert.ok(fs.existsSync(path.join(stateDir, 'build-required.json')), 'state is a file');

      // 2b. the state survives a new server / bridge / module import (already switched platform)
      const other = await startServer('library-only', { TCAUTO_STATE_DIR: stateDir, TCAUTO_TEST_PLATFORM: 'TwinCAT OS (x64)' });
      try {
        const again = JSON.parse((await other.callTool({ name: 'EnableConfig', arguments: { Force: true } })).content[0].text);
        assert.equal(again.error.code, 'BUILD_REQUIRED', JSON.stringify(again.error));
      } finally {
        await other.close();
      }

      // 3. an accepted build clears it; EnableConfig then gets to set-config (mock runtime fails there)
      const build = await call('BuildProject', { AllowUnresolvedLibrary: true });
      assert.equal(build.success, true);
      const third = await call('EnableConfig', { Force: true });
      assert.equal(third.error.code, 'FIXTURE_NO_RUNTIME', JSON.stringify(third.error));
      assert.ok(third.data.steps.some((s) => s.step === 'set-config'));
      assert.ok(!fs.existsSync(path.join(stateDir, 'build-required.json')), 'state file removed after the complete build');
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

  test('a build with a PLC project skipped by the configuration does not clear BUILD_REQUIRED', async () => {
    const client = await startServer('skipped');
    try {
      // the platform-fix-build succeeds, but plc2 is skipped: its output is still the old platform's
      const r = JSON.parse((await client.callTool({ name: 'EnableConfig', arguments: { Force: true } })).content[0].text);
      assert.equal(r.error.code, 'BUILD_REQUIRED', JSON.stringify(r.error));
      assert.deepEqual(r.data.steps.map((s) => [s.step, s.ok]), [['platform-fix', true], ['platform-fix-build', true], ['build-required', false]]);
      const b = JSON.parse((await client.callTool({ name: 'BuildProject', arguments: {} })).content[0].text);
      assert.equal(b.success, true);
      assert.equal(b.data.warningCode, 'PROJECT_SKIPPED_BY_CONFIGURATION');
      const again = JSON.parse((await client.callTool({ name: 'EnableConfig', arguments: { Force: true } })).content[0].text);
      assert.equal(again.error.code, 'BUILD_REQUIRED');
    } finally {
      await client.close();
    }
  });

  // A successful build that proves nothing about the PLC code must not clear BUILD_REQUIRED either.
  // The BUILD_REQUIRED message and the platform-fix-build step say why the build did not count.
  const verdict = {
    'coverage-error': /completeBuild=false, codeVerified=null, coverageComplete=false, warningCodes=\[CODE_NOT_VERIFIED\]/,
    'errorlist-unavailable': /completeBuild=false, codeVerified=null, coverageComplete=true, warningCodes=\[CODE_NOT_VERIFIED\]/,
    'unlocated-code': /completeBuild=false, codeVerified=false, coverageComplete=true, warningCodes=\[CODE_NOT_VERIFIED\]/,
    'no-plc': /completeBuild=false, codeVerified=false, coverageComplete=false, warningCodes=\[CODE_NOT_VERIFIED\]/
  };
  for (const scenario of Object.keys(verdict)) {
    test(`a successful build with ${scenario} (codeVerified not true) does not clear BUILD_REQUIRED and says why`, async () => {
      const client = await startServer(scenario);
      try {
        const r = JSON.parse((await client.callTool({ name: 'EnableConfig', arguments: { Force: true } })).content[0].text);
        assert.equal(r.error.code, 'BUILD_REQUIRED', JSON.stringify(r.error));
        assert.deepEqual(r.data.steps.map((s) => [s.step, s.ok]), [['platform-fix', true], ['platform-fix-build', true], ['build-required', false]]);
        assert.match(r.data.steps[1].detail, verdict[scenario], 'platform-fix-build detail');
        assert.match(r.error.message, /did not count as complete/);
        assert.match(r.error.message, verdict[scenario]);
        assert.match(r.error.hint, /data\.completeBuild = true/);
        assert.match(r.error.hint, /build-required\.json/, 'hint names the manual release');
        const b = JSON.parse((await client.callTool({ name: 'BuildProject', arguments: {} })).content[0].text);
        assert.equal(b.success, true);
        assert.notEqual(b.data.codeVerified, true);
        assert.equal(b.data.completeBuild, false);
        assert.ok(b.data.warningCodes.includes('CODE_NOT_VERIFIED'));
        const again = JSON.parse((await client.callTool({ name: 'EnableConfig', arguments: { Force: true } })).content[0].text);
        assert.equal(again.error.code, 'BUILD_REQUIRED');
        assert.match(again.error.message, verdict[scenario], 'a separate BuildProject is reported too');
      } finally {
        await client.close();
      }
    });
  }

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
