// #144: the execution-policy preflight tells a group-policy block apart from a user-settable one.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { policyAdvice, parsePolicyList } from '../scripts/check-execution-policy.mjs';

const list = (o) => Object.entries(o).map(([k, v]) => `${k}=${v}`).join('\r\n');
const base = { MachinePolicy: 'Undefined', UserPolicy: 'Undefined', Process: 'Undefined', CurrentUser: 'Undefined', LocalMachine: 'Restricted' };

test('RemoteSigned / Bypass / Unrestricted: no advice', () => {
  for (const p of ['RemoteSigned', 'Bypass', 'Unrestricted', 'Undefined']) assert.equal(policyAdvice(p, list(base)), null);
});

test('Restricted without group policy: Set-ExecutionPolicy advice', () => {
  const m = policyAdvice('Restricted', list(base));
  assert.match(m, /Set-ExecutionPolicy -Scope CurrentUser RemoteSigned/);
  assert.doesNotMatch(m, /IT/);
});

test('AllSigned from MachinePolicy: group policy advice, no Set-ExecutionPolicy', () => {
  const m = policyAdvice('AllSigned', list({ ...base, MachinePolicy: 'AllSigned' }));
  assert.match(m, /group policy \(MachinePolicy=AllSigned\)/);
  assert.match(m, /IT administrator/);
  assert.doesNotMatch(m, /Run once/);
});

test('UserPolicy also counts as group policy', () => {
  const m = policyAdvice('Restricted', list({ ...base, UserPolicy: 'Restricted' }));
  assert.match(m, /UserPolicy=Restricted/);
});

test('unparsable list falls back to the Set-ExecutionPolicy advice', () => {
  assert.match(policyAdvice('Restricted', ''), /Run once/);
  assert.deepEqual(parsePolicyList('garbage\nMachinePolicy = Undefined'), { MachinePolicy: 'Undefined' });
});
