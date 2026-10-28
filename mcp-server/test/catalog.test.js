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

  // #70: NewProject is not offered over MCP (the cmdlet New-TcProject stays).
  test('NewProject is not in the MCP catalog', () => {
    assert.equal(catalog.get('NewProject'), undefined);
  });
});
