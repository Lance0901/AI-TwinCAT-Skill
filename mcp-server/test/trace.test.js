// lib/trace.js: opt-in JSONL tool-call trace (TCAUTO_TRACE_FILE). End-to-end checks are in server.test.js.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createTracer, truncateArgs, MAX_ARG_CHARS } from '../lib/trace.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const TRACE_JS = pathToFileURL(path.join(__dirname, '..', 'lib', 'trace.js')).href;

test('unset / empty TCAUTO_TRACE_FILE -> disabled, begin/end write nothing', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tcauto-trace-off-'));
  try {
    for (const v of [undefined, '', '   ']) {
      const t = createTracer(v, { warn: () => assert.fail('no warning when off') });
      assert.equal(t.enabled, false);
      const span = t.begin('ConnectIde', {});
      assert.equal(span.seq, null);
      span.end({ success: true, data: {} });
    }
    assert.deepEqual(fs.readdirSync(dir), []);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('truncateArgs cuts nested strings over 4,000 characters and keeps the rest', () => {
  const long = 'y'.repeat(MAX_ARG_CHARS + 1);
  const { args, truncated } = truncateArgs({ a: 'short', b: [long, 1], c: { d: long, e: null } });
  assert.equal(truncated, true);
  assert.equal(args.a, 'short');
  assert.equal(args.b[1], 1);
  assert.equal(args.c.e, null);
  for (const s of [args.b[0], args.c.d]) assert.equal(s, `${'y'.repeat(MAX_ARG_CHARS)}...[truncated, ${MAX_ARG_CHARS + 1} chars]`);
  assert.equal(truncateArgs({ x: 'y'.repeat(MAX_ARG_CHARS) }).truncated, false);
});

test('array data -> dataKeys null; a call ended twice writes one line', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tcauto-trace-'));
  const file = path.join(dir, 't.jsonl');
  try {
    const t = createTracer(file);
    const span = t.begin('GetSymbols', { Filter: 'MAIN' }, 7);
    span.end({ success: true, data: [{ path: 'MAIN.a' }] });
    span.end({ success: true, data: [] });
    const recs = fs.readFileSync(file, 'utf8').trim().split('\n').map((l) => JSON.parse(l));
    assert.equal(recs.length, 1);
    assert.equal(recs[0].dataKeys, null);
    assert.equal(recs[0].parentSeq, 7);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('several processes appending to one file: every line is whole JSON', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tcauto-trace-mp-'));
  const file = path.join(dir, 't.jsonl');
  const PROCS = 4;
  const N = 200;
  const script = `import { createTracer } from ${JSON.stringify(TRACE_JS)};
const t = createTracer(process.argv[1]);
for (let i = 0; i < ${N}; i++) t.begin('WritePouCode', { Code: 'x'.repeat(3000 + i) }).end({ success: true, data: { i } });`;
  try {
    await Promise.all(
      Array.from({ length: PROCS }, () => new Promise((resolve, reject) => {
        const p = spawn(process.execPath, ['--input-type=module', '-e', script, file], { stdio: 'inherit' });
        p.on('error', reject);
        p.on('exit', (code) => (code === 0 ? resolve() : reject(new Error(`exit ${code}`))));
      }))
    );
    const lines = fs.readFileSync(file, 'utf8').split('\n').filter(Boolean);
    assert.equal(lines.length, PROCS * N);
    const recs = lines.map((l) => JSON.parse(l));
    assert.equal(new Set(recs.map((r) => r.sessionId)).size, PROCS);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
