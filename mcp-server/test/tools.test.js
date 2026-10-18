import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadToolCatalog, validateParams, computeTimeoutMs, toToolResult, MAX_CALL_TIMEOUT_MS, MIN_CALL_TIMEOUT_MS } from '../lib/tools.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const catalog = loadToolCatalog(path.join(__dirname, 'fixtures', 'tools.fixture.json'));

describe('loadToolCatalog', () => {
  test('returns a Map keyed by tool name', () => {
    assert.equal(catalog.size, 3);
    assert.equal(catalog.get('ConnectIde').cmdlet, 'Connect-TcIde');
    assert.equal(catalog.meta.moduleVersion, '0.1.0');
  });
});

describe('validateParams', () => {
  const connect = catalog.get('ConnectIde');
  const read = catalog.get('ReadVariable');

  test('accepts known params and drops null/undefined', () => {
    const r = validateParams(connect, { ProgId: 'X', SolutionPath: null, NoLaunch: undefined });
    assert.deepEqual(r, { ok: true, params: { ProgId: 'X' } });
  });

  test('accepts missing args object', () => {
    assert.deepEqual(validateParams(connect, undefined), { ok: true, params: {} });
  });

  test('rejects unknown params with allowed-list hint', () => {
    const r = validateParams(connect, { Bogus: 1 });
    assert.equal(r.ok, false);
    assert.equal(r.error.code, 'INVALID_PARAMS');
    assert.equal(r.error.message, "Unknown parameter 'Bogus' for ConnectIde");
    assert.match(r.error.hint, /Allowed: ProgId, SolutionPath, NoLaunch/);
  });

  test('rejects missing required', () => {
    const r = validateParams(read, {});
    assert.equal(r.ok, false);
    assert.equal(r.error.code, 'INVALID_PARAMS');
    assert.match(r.error.message, /Missing required parameter 'Path'/);
  });

  test('required satisfied by null is still missing', () => {
    const r = validateParams(read, { Path: null });
    assert.equal(r.ok, false);
    assert.match(r.error.message, /Missing required parameter 'Path'/);
  });

  test('checks enum', () => {
    assert.equal(validateParams(read, { Path: ['a'], Mode: 'Raw' }).ok, true);
    const r = validateParams(read, { Path: ['a'], Mode: 'Bogus' });
    assert.equal(r.ok, false);
    assert.match(r.error.message, /must be one of "Value", "Raw"/);
  });

  test('checks basic types', () => {
    assert.equal(validateParams(connect, { ProgId: 5 }).ok, false);
    assert.equal(validateParams(connect, { NoLaunch: 'yes' }).ok, false);
    assert.equal(validateParams(read, { Path: 'MAIN.x' }).ok, false, 'string is not an array');
    assert.equal(validateParams(read, { Path: [1] }).ok, false, 'array items must be strings');
    assert.equal(validateParams(read, { Path: [] }).ok, false, 'minItems 1');
    assert.equal(validateParams(read, { Path: ['a'], TimeoutMs: 1.5 }).ok, false, 'integer');
    assert.equal(validateParams(read, { Path: ['a'], TimeoutMs: 1500 }).ok, true);
  });

  test('{} schema accepts anything', () => {
    const tool = { name: 'T', inputSchema: { type: 'object', properties: { Any: {} } } };
    assert.equal(validateParams(tool, { Any: { nested: [1, 2] } }).ok, true);
    assert.equal(validateParams(tool, { Any: 'str' }).ok, true);
  });

  test('rejects non-object arguments', () => {
    assert.equal(validateParams(connect, 'nope').ok, false);
    assert.equal(validateParams(connect, [1]).ok, false);
  });

  test('checks minimum / maximum on integer and number', () => {
    assert.equal(validateParams(read, { Path: ['a'], TimeoutMs: 1 }).ok, true);
    assert.equal(validateParams(read, { Path: ['a'], TimeoutMs: 600000 }).ok, true);
    const low = validateParams(read, { Path: ['a'], TimeoutMs: 0 });
    assert.equal(low.ok, false);
    assert.equal(low.error.code, 'INVALID_PARAMS');
    assert.match(low.error.message, /TimeoutMs.*>= 1, got 0/);
    const high = validateParams(read, { Path: ['a'], TimeoutMs: 99999999 });
    assert.equal(high.ok, false);
    assert.match(high.error.message, /TimeoutMs.*<= 600000, got 99999999/);

    const tool = { name: 'T', inputSchema: { type: 'object', properties: { Ratio: { type: 'number', minimum: 0, maximum: 1 } } } };
    assert.equal(validateParams(tool, { Ratio: 0.5 }).ok, true);
    assert.equal(validateParams(tool, { Ratio: 1.5 }).ok, false);
    assert.equal(validateParams(tool, { Ratio: -0.1 }).ok, false);
  });

  test('object values: empty key or keys differing only in case -> INVALID_PARAMS (PS 5.1 ConvertFrom-Json)', () => {
    const tool = {
      name: 'T',
      inputSchema: {
        type: 'object',
        properties: { Values: { type: 'object' }, Any: {}, List: { type: 'array', items: { type: 'object' } } }
      }
    };
    assert.equal(validateParams(tool, { Values: { Name: 'x', Age: 1, nested: { Deep: [{ ok: true }] } } }).ok, true);

    const empty = validateParams(tool, { Values: { '': 1 } });
    assert.equal(empty.ok, false);
    assert.equal(empty.error.code, 'INVALID_PARAMS');
    assert.match(empty.error.message, /Parameter 'Values' of T contains an empty property name/);

    const dup = validateParams(tool, { Values: { Name: 'x', name: 'y' } });
    assert.equal(dup.ok, false);
    assert.match(dup.error.message, /properties 'Name' and 'name' that differ only in case/);

    const nested = validateParams(tool, { Any: { outer: { A: 1, a: 2 } } });
    assert.equal(nested.ok, false);
    assert.match(nested.error.message, /Parameter 'Any' of T\.outer contains properties 'A' and 'a'/);

    const inArray = validateParams(tool, { List: [{ ok: 1 }, { '': 2 }] });
    assert.equal(inArray.ok, false);
    assert.match(inArray.error.message, /Parameter 'List' of T\[1\] contains an empty property name/);

    const deepArray = validateParams(tool, { Any: [[{ X: 1, x: 2 }]] });
    assert.equal(deepArray.ok, false);
  });
});

describe('computeTimeoutMs', () => {
  test('uses tool.timeoutMs (or 120000 default) when no timing args', () => {
    assert.equal(computeTimeoutMs({ timeoutMs: 2000 }, {}), 2000);
    assert.equal(computeTimeoutMs({}, {}), 120000);
    assert.equal(computeTimeoutMs({ timeoutMs: 600000 }), 600000);
  });

  test('TimeoutSec*1000 + 30000 wins when larger', () => {
    assert.equal(computeTimeoutMs({ timeoutMs: 120000 }, { TimeoutSec: 300 }), 330000);
    assert.equal(computeTimeoutMs({ timeoutMs: 600000 }, { TimeoutSec: 10 }), 600000);
  });

  test('TimeoutMs + DurationMs + 30000 wins when larger', () => {
    assert.equal(computeTimeoutMs({ timeoutMs: 120000 }, { TimeoutMs: 100000, DurationMs: 50000 }), 180000);
    assert.equal(computeTimeoutMs({ timeoutMs: 120000 }, { DurationMs: 100000 }), 130000);
    assert.equal(computeTimeoutMs({ timeoutMs: 120000 }, { TimeoutMs: 5000 }), 120000);
  });

  test('result is clamped to [1 s, 2 h] so setTimeout never overflows', () => {
    assert.equal(MIN_CALL_TIMEOUT_MS, 1000);
    assert.equal(MAX_CALL_TIMEOUT_MS, 7_200_000);
    assert.equal(computeTimeoutMs({ timeoutMs: 120000 }, { TimeoutSec: 99999999 }), MAX_CALL_TIMEOUT_MS);
    assert.equal(computeTimeoutMs({ timeoutMs: 120000 }, { TimeoutMs: Number.MAX_SAFE_INTEGER }), MAX_CALL_TIMEOUT_MS);
    assert.equal(computeTimeoutMs({ timeoutMs: 120000 }, { TimeoutSec: Infinity }), 120000, 'non-finite values are ignored (cannot come from JSON)');
    assert.equal(computeTimeoutMs({ timeoutMs: 10 }, {}), MIN_CALL_TIMEOUT_MS);
    assert.equal(computeTimeoutMs({ timeoutMs: 7_200_000 }, { TimeoutSec: 7200 }), MAX_CALL_TIMEOUT_MS);
    assert.equal(computeTimeoutMs({ timeoutMs: 600000 }, { TimeoutSec: 3600 }), 3630000, 'inside the range: untouched');
  });
});

describe('toToolResult', () => {
  test('success result is not an error and carries structuredContent', () => {
    const r = toToolResult({ success: true, data: { a: 1 } });
    assert.equal(r.isError, false);
    assert.deepEqual(r.structuredContent, { success: true, data: { a: 1 } });
    assert.equal(r.content[0].type, 'text');
    assert.deepEqual(JSON.parse(r.content[0].text), { success: true, data: { a: 1 } });
  });

  test('failure result is an error', () => {
    const r = toToolResult({ success: false, error: { code: 'X', message: 'm' } });
    assert.equal(r.isError, true);
    assert.match(r.content[0].text, /"code": "X"/);
  });
});
