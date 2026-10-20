#!/usr/bin/env node
// Manual end-to-end lifecycle through the MCP server (real IDE + runtime needed):
//   RunLifecycle -> GetSystemState -> ReadVariable (task cycle counter twice, must increase) -> DisconnectIde Quit=true
//
//   node scripts/lifecycle-client.mjs --sln C:\Temp\RobustDemo-b\RobustSolutionFrameworkDemo.sln \
//        --progid VisualStudio.DTE.17.0 --netid 199.5.42.250.1.1 --platform "TwinCAT OS (x64)"
//
// --expect-fail <CODE> [--fail-platform <platform>]: run RunLifecycle once first with Platform=<fail-platform>
//   (omitted = no Platform) and require that error code, e.g. --expect-fail ACTIVATE_FAILED
//   --fail-platform "TwinCAT RT (x64)" against a 4026 UmRT (target platform TwinCAT OS (x64)).
// --read <path>: variable to read (default TwinCAT_SystemInfoVarList._TaskInfo[1].CycleCount).
// Env: TWINCAT_MODULE_PATH (psm1 to load; default = this checkout's module), TWINCAT_MCP_POWERSHELL.
// Exit code = number of failed steps.
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const INDEX = path.join(__dirname, '..', 'index.js');

function arg(name, def) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : def;
}
const sln = arg('sln', '');
const progId = arg('progid', 'VisualStudio.DTE.17.0');
const netId = arg('netid', '199.5.42.250.1.1');
const platform = arg('platform', '');
const expectFail = arg('expect-fail', '');
const readPath = arg('read', 'TwinCAT_SystemInfoVarList._TaskInfo[1].CycleCount');
if (!sln) { console.error('--sln is required'); process.exit(2); }

const transport = new StdioClientTransport({ command: process.execPath, args: [INDEX], env: { ...process.env }, stderr: 'inherit' });
const client = new Client({ name: 'lifecycle-client', version: '0.0.0' }, { capabilities: {} });
await client.connect(transport);

const rows = [];
let failed = 0;
async function call(name, args, label, expectCode = '') {
  const t0 = Date.now();
  const res = await client.callTool({ name, arguments: args }, undefined, { timeout: 900000, resetTimeoutOnProgress: true });
  const body = JSON.parse(res.content[0].text);
  const ms = Date.now() - t0;
  const pass = expectCode ? (!body.success && body.error && body.error.code === expectCode) : body.success;
  if (!pass) failed++;
  const summary = body.success ? JSON.stringify(body.data).slice(0, 400) : `${body.error.code}: ${String(body.error.message).slice(0, 300)}`;
  rows.push({ step: label, pass, ms, code: body.success ? null : body.error.code });
  console.log(`${pass ? 'PASS' : 'FAIL'} ${label} ${ms}ms ${summary}`);
  return body;
}

try {
  const base = { SolutionPath: sln, ProgId: progId, TargetAmsNetId: netId };
  if (expectFail) {
    const fp = arg('fail-platform', '');
    const r = await call('RunLifecycle', fp ? { ...base, Platform: fp } : base, `RunLifecycle (${fp ? `Platform=${fp}` : 'no Platform'}, expect ${expectFail})`, expectFail);
    if (!r.success && r.error) console.log(`     hint: ${String(r.error.hint ?? '').slice(0, 300)}`);
  }
  const lc = await call('RunLifecycle', platform ? { ...base, Platform: platform } : base, `RunLifecycle${platform ? ` Platform=${platform}` : ''}`);
  if (lc.success && Array.isArray(lc.data?.steps)) {
    console.log('     steps: ' + lc.data.steps.map((s) => `${s.name}:${s.success ? 'ok' : 'FAIL'}:${s.durationMs}ms`).join(' '));
  }
  await call('GetSystemState', { AmsNetId: netId }, 'GetSystemState');
  const r1 = await call('ReadVariable', { Path: [readPath] }, `ReadVariable ${readPath} #1`);
  await new Promise((r) => setTimeout(r, 1000));
  const r2 = await call('ReadVariable', { Path: [readPath] }, `ReadVariable ${readPath} #2`);
  const v1 = Number([].concat(r1.data ?? [])[0]?.value);
  const v2 = Number([].concat(r2.data ?? [])[0]?.value);
  const running = Number.isFinite(v1) && Number.isFinite(v2) && v2 > v1;
  if (!running) failed++;
  rows.push({ step: 'cycle counter increases', pass: running, ms: 0, code: null });
  console.log(`${running ? 'PASS' : 'FAIL'} cycle counter increases (${v1} -> ${v2})`);
} catch (e) {
  failed++;
  console.log(`FAIL exception: ${e.message}`);
} finally {
  try { await call('DisconnectIde', { Quit: true }, 'DisconnectIde Quit=true'); } catch (e) { failed++; console.log(`FAIL DisconnectIde: ${e.message}`); }
  await client.close();
}
console.log(`\n${rows.filter((r) => r.pass).length}/${rows.length} PASS`);
process.exit(failed);
