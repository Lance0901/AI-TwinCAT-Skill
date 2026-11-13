import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadToolCatalog, validateParams } from '../lib/tools.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
// The real, generated catalog (npm run generate-tools), not the fixture.
const catalog = loadToolCatalog(path.join(__dirname, '..', 'tools.json'));

describe('tools.json (generated catalog)', () => {
  test('GetProjectTree exposes Depth (integer, default 4) and PlcOnly (boolean)', () => {
    const props = catalog.get('GetProjectTree').inputSchema.properties;
    assert.equal(props.Depth.type, 'integer');
    assert.equal(props.Depth.default, 4);
    assert.equal(props.Depth.minimum, 1);
    assert.equal(props.Depth.maximum, 10);
    assert.equal(props.PlcOnly.type, 'boolean');
  });

  test('GetPouCode / WritePouCode PouPath describe the TIPC^ path format', () => {
    for (const name of ['GetPouCode', 'WritePouCode']) {
      const desc = catalog.get(name).inputSchema.properties.PouPath.description;
      assert.ok(desc.includes('TIPC^'), `${name}.PouPath description: ${desc}`);
    }
  });

  // #22: GetPouCode tells "no implementation part" (DUT / GVL / ITF) apart from a failed read.
  test('GetPouCode describes objectKind / hasImplementation / implementation null', () => {
    const desc = catalog.get('GetPouCode').description;
    for (const word of ['objectKind', 'hasImplementation', 'implementationReadable', 'data.language', 'DUT', 'GVL', 'POU_READ_FAILED']) {
      assert.ok(desc.includes(word), `GetPouCode description lacks ${word}: ${desc}`);
    }
    assert.match(desc, /hasImplementation=false[^.]*implementation is null/);
  });

  test('WritePouCode: Implementation on a DUT / GVL is INVALID_PARAMS', () => {
    const tool = catalog.get('WritePouCode');
    assert.match(tool.description, /DUT \/ GVL[^.]*INVALID_PARAMS/);
    assert.ok(tool.description.includes('objectKind'));
    assert.ok(tool.inputSchema.properties.Implementation, 'WritePouCode keeps the Implementation parameter');
    assert.ok(tool.inputSchema.properties.Declaration, 'WritePouCode keeps the Declaration parameter');
  });

  // #17: AddPou / AddDut / AddGvl report what they created and how a failure is reported.
  test('AddPou / AddDut / AddGvl describe objectKind, itemType and their *_CREATE_FAILED code', () => {
    const expect = {
      AddPou: ['objectKind', '604 FunctionBlock', 'language', 'POU_CREATE_FAILED', 'IDE_MODAL_DIALOG'],
      AddDut: ['objectKind', '606 Struct', '623 Alias', 'DUT_CREATE_FAILED'],
      AddGvl: ['objectKind', '615', 'GVL_CREATE_FAILED'],
    };
    for (const [name, words] of Object.entries(expect)) {
      const desc = catalog.get(name).description;
      for (const word of words) assert.ok(desc.includes(word), `${name} description lacks ${word}: ${desc}`);
    }
    assert.deepEqual(catalog.get('AddDut').inputSchema.properties.DutType.enum, ['Struct', 'Enum', 'Alias', 'Union']);
    assert.deepEqual(catalog.get('AddPou').inputSchema.properties.Type.enum, ['Program', 'FunctionBlock', 'Function']);
  });

  // #47: members are an ordered array; the old object form (key order lost) is rejected.
  test('AddDut.Fields / AddGvl.Variables are arrays; an object is INVALID_PARAMS', () => {
    for (const [tool, param] of [['AddDut', 'Fields'], ['AddGvl', 'Variables']]) {
      const t = catalog.get(tool);
      const schema = t.inputSchema.properties[param];
      assert.equal(schema.type, 'array', `${tool}.${param} type`);
      assert.equal(schema.items.type, 'object');
      assert.ok(schema.items.required.includes('name'));
      assert.ok(t.description.includes('MEMBER_ORDER_MISMATCH'), `${tool} description names MEMBER_ORDER_MISMATCH`);
      const base = tool === 'AddDut' ? { Name: 'ST_X', DutType: 'Struct' } : { Name: 'GVL_X' };
      const bad = validateParams(t, { ...base, [param]: { zLast: 'BOOL', aFirst: 'INT' } });
      assert.equal(bad.ok, false);
      assert.equal(bad.error.code, 'INVALID_PARAMS');
      const members = [{ name: 'zLast', type: 'BOOL' }, { name: 'aFirst', type: 'INT' }, { name: 'mMid', type: 'LREAL' }];
      const good = validateParams(t, { ...base, [param]: members });
      assert.equal(good.ok, true, JSON.stringify(good.error));
      assert.deepEqual(good.params[param].map((m) => m.name), ['zLast', 'aFirst', 'mMid'], 'order kept');
    }
  });

  // #78: ReportIssue only formats a pre-filled GitHub new-issue URL: read-only, no required IDE state.
  test('ReportIssue is read-only; Title is the only required parameter; Parameters / Result accept objects', () => {
    const t = catalog.get('ReportIssue');
    assert.ok(t, 'ReportIssue is in the catalog');
    assert.equal(t.cmdlet, 'New-TcIssueReport');
    assert.deepEqual(t.annotations, { readOnlyHint: true });
    assert.deepEqual(t.inputSchema.required, ['Title']);
    assert.equal(t.inputSchema.properties.MaxUrlLength.default, 7000);
    assert.equal(t.inputSchema.properties.Label.default, 'field-report');
    for (const w of ['NOTHING', 'LIFECYCLE_BLOCKED', 'ONLY THE USER', 'data.body', 'MaxUrlLength']) {
      assert.ok(t.description.includes(w), `ReportIssue description lacks ${w}`);
    }
    const ok = validateParams(t, {
      Title: 'BuildProject times out',
      Tool: 'BuildProject',
      Parameters: { TimeoutSec: 600 },
      Result: { success: false, error: { code: 'BUILD_TIMEOUT', message: 'x' } },
      ExtraMask: ['ACME']
    });
    assert.equal(ok.ok, true, JSON.stringify(ok.error));
    assert.equal(validateParams(t, { Tool: 'BuildProject' }).ok, false, 'Title is required');
    assert.equal(validateParams(t, { Title: 'x', MaxUrlLength: 1999 }).ok, false, 'MaxUrlLength minimum 2000');
  });

  // #214: GetProjectVersion only reads the .sln / .tsproj files: read-only, SolutionPath is the only required parameter.
  test('GetProjectVersion is read-only and needs only SolutionPath', () => {
    const t = catalog.get('GetProjectVersion');
    assert.ok(t, 'GetProjectVersion is in the catalog');
    assert.equal(t.cmdlet, 'Get-TcProjectVersion');
    assert.deepEqual(t.annotations, { readOnlyHint: true });
    assert.deepEqual(t.inputSchema.required, ['SolutionPath']);
    for (const w of ['offline', 'matchingProgIds', 'TSPROJ_NOT_FOUND', 'TCVERSION_UNKNOWN']) {
      assert.ok(t.description.includes(w), `GetProjectVersion description lacks ${w}`);
    }
    assert.equal(validateParams(t, { SolutionPath: 'C:/x/a.sln' }).ok, true);
    assert.equal(validateParams(t, {}).ok, false, 'SolutionPath is required');
  });

  // #252: LintProject only reads project files on disk (no IDE / ADS): read-only, nothing required
  // (PlcProjectPath or SolutionPath, checked by the cmdlet), Scope / FailOn are closed sets, and the
  // description states what passed=true covers.
  test('LintProject is read-only, offline and explains the scope of passed', () => {
    const t = catalog.get('LintProject');
    assert.ok(t, 'LintProject is in the catalog');
    assert.equal(t.cmdlet, 'Invoke-TcLintProject');
    assert.deepEqual(t.annotations, { readOnlyHint: true });
    assert.deepEqual(t.inputSchema.required ?? [], []);
    assert.deepEqual(t.inputSchema.properties.Scope.enum, ['All', 'Object']);
    assert.deepEqual(t.inputSchema.properties.FailOn.enum, ['error', 'warning']);
    for (const w of ['does NOT mean the program is correct', 'ResetSolution', 'LINT_FAILED', 'LINT_PARSE_FAILED',
      'LINT_INCOMPLETE', 'LINT_ENGINE_UNAVAILABLE', 'ideChecked=false', 'blockableBasis']) {
      assert.ok(t.description.includes(w), `LintProject description lacks ${w}`);
    }
    assert.equal(validateParams(t, { PlcProjectPath: 'C:/x/PLC1/PLC1.plcproj' }).ok, true);
    assert.equal(validateParams(t, { PlcProjectPath: 'C:/x/a.plcproj', Scope: 'Some' }).ok, false, 'Scope is All or Object');
    assert.equal(validateParams(t, { PlcProjectPath: 'C:/x/a.plcproj', FailOn: 'never' }).ok, false, 'FailOn has no never');
  });

  // #252 Phase 2a: LintCandidate checks an object before it is written (in memory, no IDE / ADS): read-only,
  // ObjectKind / FailOn are closed sets, and the description states the workflow and what a pass does not cover.
  test('LintCandidate is read-only, offline and states the write workflow', () => {
    const t = catalog.get('LintCandidate');
    assert.ok(t, 'LintCandidate is in the catalog');
    assert.equal(t.cmdlet, 'Invoke-TcLintCandidate');
    assert.deepEqual(t.annotations, { readOnlyHint: true });
    assert.deepEqual(t.inputSchema.properties.FailOn.enum, ['error', 'warning']);
    assert.ok(t.inputSchema.properties.ObjectKind.enum.includes('Method'), 'ObjectKind lists Method');
    for (const w of ['nothing is written', 'WritePouCode', 'BuildProject', 'LintProject', 'NOT a pass of the project',
      'LINT_CONTEXT_REQUIRED', 'LINT_INPUT_INVALID', 'newSuppressions', 'requiresDisposition']) {
      assert.ok(t.description.includes(w), `LintCandidate description lacks ${w}`);
    }
    assert.equal(validateParams(t, { ObjectKind: 'Function', ObjectName: 'F_X', Declaration: 'FUNCTION F_X : INT' }).ok, true);
    assert.equal(validateParams(t, { ObjectKind: 'Pou', ObjectName: 'F_X' }).ok, false, 'ObjectKind is a closed set');
  });

  // #229: GetPackageInfo is a read-only tcpkg query (network); InstallPackage is destructive, plan by
  // default, and only installs the IDE side (no XAR).
  test('GetPackageInfo is read-only, InstallPackage needs PackageId + Version and offers no XAR', () => {
    const g = catalog.get('GetPackageInfo');
    assert.ok(g, 'GetPackageInfo is in the catalog');
    assert.equal(g.cmdlet, 'Get-TcPackageInfo');
    assert.deepEqual(g.annotations, { readOnlyHint: true, openWorldHint: true });
    assert.deepEqual(g.inputSchema.required, []);
    for (const w of ['TCPKG_NOT_FOUND', 'TCPKG_TIMEOUT', 'TCPKG_LIST_FAILED', 'buildFolderExists']) {
      assert.ok(g.description.includes(w), `GetPackageInfo description lacks ${w}`);
    }
    const i = catalog.get('InstallPackage');
    assert.ok(i, 'InstallPackage is in the catalog');
    assert.equal(i.cmdlet, 'Install-TcPackage');
    assert.equal(i.annotations.destructiveHint, true);
    assert.deepEqual([...i.inputSchema.required].sort(), ['PackageId', 'Version']);
    assert.deepEqual(i.inputSchema.properties.PackageId.enum, ['TwinCAT.Standard.XAE', 'TwinCAT.StandardRM.XAE']);
    for (const w of ['ASK THE USER FIRST', 'PlanToken', 'TCPKG_PLAN_REQUIRED', 'TCPKG_SIGNATURE_INVALID', 'TCPKG_RUNNING', 'executed = false', 'TCPKG_ELEVATION_REQUIRED', 'TCPKG_IDE_RUNNING', 'TCPKG_VERSION_NOT_FOUND', 'TCPKG_INSTALL_UNVERIFIED']) {
      assert.ok(i.description.includes(w), `InstallPackage description lacks ${w}`);
    }
    assert.equal(validateParams(i, { PackageId: 'TwinCAT.StandardRM.XAE', Version: '4024.71.5' }).ok, true);
    assert.equal(i.inputSchema.properties.PlanToken.type, 'string');
    assert.ok(!i.inputSchema.required.includes('PlanToken'), 'PlanToken is optional (a plan call has none)');
    assert.equal(validateParams(i, { PackageId: 'TwinCAT.Standard.XAR', Version: '4026.22.0' }).ok, false, 'XAR is not installable');
  });

  // #70: NewProject is not offered over MCP (the cmdlet New-TcProject stays).
  test('NewProject is not in the MCP catalog', () => {
    assert.equal(catalog.get('NewProject'), undefined);
  });
});
