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
});
