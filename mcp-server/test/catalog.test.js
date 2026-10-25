import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadToolCatalog } from '../lib/tools.js';

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
    for (const word of ['objectKind', 'hasImplementation', 'DUT', 'GVL', 'POU_READ_FAILED']) {
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
      AddPou: ['objectKind', '604 FunctionBlock', 'POU_CREATE_FAILED'],
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
});
