#!/usr/bin/env node
// Manual end-to-end check of the ADS type conversion through the MCP server (real runtime needed):
// TIME read/write (literal, integer, numeric string, restore), enum read/write (integer, member name),
// DT text, Watch samples, GetSymbols enumValues and the TYPE_MISMATCH path for a STRUCT.
//
//   node scripts/ads-types-client.mjs --netid 199.5.42.250.1.1 --prefix MAIN_GantryCylinder \
//        --time DwellTime --enum SensorType --struct stPar
//
// Env: TWINCAT_MODULE_PATH (psm1 to load; default = this checkout's module), TWINCAT_MCP_POWERSHELL.
// The time variable is written three times and restored to its original value at the end.
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
const netId = arg('netid', '');
const prefix = arg('prefix', 'MAIN');
const timeVar = `${prefix}.${arg('time', 'DwellTime')}`;
const enumVar = `${prefix}.${arg('enum', 'SensorType')}`;
const structVar = `${prefix}.${arg('struct', 'stPar')}`;
const dtVar = arg('dt', 'TwinCAT_SystemInfoVarList._AppInfo.AppTimestamp');

const transport = new StdioClientTransport({
  command: process.execPath,
  args: [INDEX],
  env: { ...process.env, TWINCAT_MCP_MODAL_PROBE: '0' },
  stderr: 'inherit'
});
const client = new Client({ name: 'ads-types-client', version: '0.0.0' }, { capabilities: {} });
await client.connect(transport);

const rows = [];
let restore = null;   // { path, value } of the time variable, written back in finally
async function call(name, args, label) {
  const res = await client.callTool({ name, arguments: args }, undefined, { timeout: 180000 });
  const body = JSON.parse(res.content[0].text);
  const d = body.success ? body.data : body.error;
  const summary = body.success
    ? Object.entries(d).filter(([k]) => ['value', 'ms', 'ns', 'unix', 'name', 'written', 'type', 'size', 'code', 'sampleCount', 'enumValues'].includes(k))
      .map(([k, v]) => `${k}=${JSON.stringify(v)}`).join(' ')
    : `${d.code}: ${d.message}`;
  rows.push({ step: label || name, ok: body.success, summary });
  console.log(`${body.success ? 'OK  ' : 'FAIL'} ${label || name}: ${summary}`);
  return body;
}

try {
  await call('ConnectAds', netId ? { AmsNetId: netId } : {}, 'ConnectAds');
  const first = await call('ReadVariable', { Path: [timeVar, enumVar, dtVar] }, 'ReadVariable x3');
  if (!first.success || !Array.isArray(first.data)) throw new Error(`ReadVariable failed: ${JSON.stringify(first.error)}`);
  const orig = first.data.find((e) => e.path === timeVar);
  if (!orig || orig.error) throw new Error(`${timeVar}: ${orig ? orig.error : 'not in the result'}`);
  restore = { path: timeVar, value: orig.value };
  console.log(`  ${timeVar} = ${orig.value} (${orig.ms} ms); ${enumVar} = ${first.data[1].value} (${first.data[1].name}); ${dtVar} = ${first.data[2].value}`);

  await call('WriteVariable', { Path: timeVar, Value: 'T#2s500ms' }, `WriteVariable ${timeVar} "T#2s500ms"`);
  await call('ReadVariable', { Path: [timeVar] }, 'ReadVariable after literal');
  await call('WriteVariable', { Path: timeVar, Value: 3000 }, `WriteVariable ${timeVar} 3000`);
  await call('ReadVariable', { Path: [timeVar] }, 'ReadVariable after integer');
  await call('WriteVariable', { Path: timeVar, Value: '3000' }, `WriteVariable ${timeVar} "3000" (numeric string)`);
  await call('WriteVariable', { Path: timeVar, Value: 'T#6000ms' }, `WriteVariable ${timeVar} "T#6000ms" (normalized to T#6s)`);
  await call('WriteVariable', { Path: timeVar, Value: orig.value }, `WriteVariable ${timeVar} restore ${orig.value}`);
  const back = await call('ReadVariable', { Path: [timeVar] }, 'ReadVariable after restore');
  if (back.success && back.data.value !== orig.value) console.log(`  !! restore mismatch: ${back.data.value} != ${orig.value}`);
  restore = null;

  const en = first.data[1];
  await call('WriteVariable', { Path: enumVar, Value: en.value }, `WriteVariable ${enumVar} ${en.value} (same value)`);
  if (en.name) await call('WriteVariable', { Path: enumVar, Value: en.name }, `WriteVariable ${enumVar} "${en.name}" (member name)`);
  await call('WriteVariable', { Path: enumVar, Value: 'NOT_A_MEMBER' }, `WriteVariable ${enumVar} bad member name`);
  await call('WriteVariable', { Path: structVar, Value: 5 }, `WriteVariable ${structVar} (STRUCT)`);
  await call('WriteVariable', { Path: timeVar, Value: 'DT#2026-01-01-00:00:00' }, `WriteVariable ${timeVar} DT literal`);

  const w = await call('WatchVariable', { Path: timeVar, IntervalMs: 200, DurationMs: 500 }, 'WatchVariable TIME');
  if (w.success) console.log(`  samples[0] = ${JSON.stringify(w.data.samples[0])}`);
  const w2 = await call('WatchVariable', { Path: enumVar, IntervalMs: 200, DurationMs: 500 }, 'WatchVariable enum');
  if (w2.success) console.log(`  samples[0] = ${JSON.stringify(w2.data.samples[0])}`);
  await call('GetSymbols', { Filter: enumVar }, 'GetSymbols enum');
  await call('DisconnectAds', {}, 'DisconnectAds');
} finally {
  if (restore) {
    try { await call('WriteVariable', { Path: restore.path, Value: restore.value }, `restore ${restore.path} after error`); } catch (e) { console.log(`  !! restore failed: ${e.message}`); }
  }
  await client.close();
}

console.log('\n| Step | Result | Detail |\n|---|---|---|');
for (const r of rows) console.log(`| ${r.step} | ${r.ok ? 'success' : 'error'} | ${r.summary.replace(/\|/g, '\\|')} |`);
process.exit(rows.some((r) => r.summary.startsWith('BRIDGE') || r.summary.startsWith('NOT_CONNECTED')) ? 1 : 0);
