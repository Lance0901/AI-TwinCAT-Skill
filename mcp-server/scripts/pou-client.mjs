#!/usr/bin/env node
// Manual end-to-end check of the PLC object tools through the MCP server (real IDE needed, no runtime;
// issues #17 / #22). Never activates anything:
//   ConnectIde -> [SetTarget NoPlatformSwitch] -> AddPou FB / PRG / FUNCTION -> AddDut Struct / Enum / Union / Alias
//   -> AddGvl -> GetPouCode (POU, DUT, GVL: objectKind / hasImplementation) -> WritePouCode (DUT with
//   Implementation must be INVALID_PARAMS; FB / PRG / MAIN code) -> BuildProject -> DisconnectIde Quit=true
//
//   node scripts/pou-client.mjs --sln C:\Temp\Pou-A\TwinCAT_Festo.sln --progid TcXaeShell.DTE.15.0 \
//        --suffix M1 --netid 127.0.0.1.1.1
//
// --suffix: appended to every created name (default M); use a fresh one per run on the same solution copy.
// --netid: optional SetTarget AmsNetId (NoPlatformSwitch=true) before building, e.g. 127.0.0.1.1.1 to keep a
//   copy away from a runtime other tests use. --keep: do not quit the IDE at the end.
// MAIN gets "PRG_<suffix>();" appended so the new objects are compiled (unreferenced POUs are not).
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
const progId = arg('progid', '');
const s = arg('suffix', 'M');
const netId = arg('netid', '');
const keep = process.argv.includes('--keep');
if (!sln) { console.error('--sln is required'); process.exit(2); }

const transport = new StdioClientTransport({ command: process.execPath, args: [INDEX], env: { ...process.env }, stderr: 'inherit' });
const client = new Client({ name: 'pou-client', version: '0.0.0' }, { capabilities: {} });
await client.connect(transport);

const rows = [];
let failed = 0;
// check(body) -> true when the step passed; default = success
async function call(name, args, label, check = (b) => b.success) {
  const t0 = Date.now();
  const res = await client.callTool({ name, arguments: args }, undefined, { timeout: 900000, resetTimeoutOnProgress: true });
  const body = JSON.parse(res.content[0].text);
  const ms = Date.now() - t0;
  const pass = Boolean(check(body));
  if (!pass) failed++;
  const summary = body.success ? JSON.stringify(body.data).slice(0, 300) : `${body.error.code}: ${String(body.error.message).slice(0, 300)}`;
  rows.push({ step: label, pass, ms, code: body.success ? null : body.error.code });
  console.log(`${pass ? 'PASS' : 'FAIL'} ${label} ${ms}ms ${summary}`);
  return body;
}
const failsWith = (code) => (b) => !b.success && b.error && b.error.code === code;

try {
  const c = await call('ConnectIde', progId ? { SolutionPath: sln, ProgId: progId } : { SolutionPath: sln }, 'ConnectIde');
  if (!c.success) throw new Error('ConnectIde failed');
  if (netId) await call('SetTarget', { AmsNetId: netId, NoPlatformSwitch: true }, `SetTarget ${netId} NoPlatformSwitch`);

  await call('AddPou', { Name: `FB_${s}`, Type: 'FunctionBlock' }, `AddPou FB_${s}`, (b) => b.success && b.data.objectKind === 'POU' && b.data.itemType === 604 && b.data.language === 'ST');
  await call('AddPou', { Name: `PRG_${s}`, Type: 'Program' }, `AddPou PRG_${s}`, (b) => b.success && b.data.itemType === 602);
  await call('AddPou', { Name: `F_${s}`, Type: 'Function', ReturnType: 'INT' }, `AddPou F_${s}`, (b) => b.success && b.data.itemType === 603 && /:\s*INT/.test(b.data.declaration));
  await call('AddDut', { Name: `ST_${s}`, DutType: 'Struct', Fields: { nA: 'INT', bB: 'BOOL' } }, `AddDut ST_${s}`, (b) => b.success && b.data.objectKind === 'DUT' && b.data.itemType === 606);
  await call('AddDut', { Name: `E_${s}`, DutType: 'Enum', Fields: { eIdle: 0, eRun: 1 } }, `AddDut E_${s}`, (b) => b.success && b.data.itemType === 605);
  await call('AddDut', { Name: `U_${s}`, DutType: 'Union', Fields: { nW: 'WORD', nB: 'BYTE' } }, `AddDut U_${s}`, (b) => b.success && b.data.itemType === 607);
  await call('AddDut', { Name: `A_${s}`, DutType: 'Alias', AliasType: 'DINT' }, `AddDut A_${s}`, (b) => b.success && b.data.itemType === 623);
  await call('AddGvl', { Name: `GVL_${s}`, Variables: { gnX: 'INT' } }, `AddGvl GVL_${s}`, (b) => b.success && b.data.objectKind === 'GVL' && /gnX : INT/.test(b.data.declaration) && !/CDATA/.test(b.data.declaration));
  await call('AddDut', { Name: `ST_${s}`, DutType: 'Struct' }, `AddDut ST_${s} again (expect DUT_CREATE_FAILED)`, (b) => failsWith('DUT_CREATE_FAILED')(b) && Boolean(b.error.hint));
  await call('AddGvl', { Name: `FB_${s}` }, `AddGvl FB_${s}: name used by the FB (expect GVL_CREATE_FAILED with its path)`,
    (b) => failsWith('GVL_CREATE_FAILED')(b) && String(b.error.message).includes(`POUs^FB_${s}`));

  await call('GetPouCode', { PouName: `FB_${s}` }, `GetPouCode FB_${s}`, (b) => b.success && b.data.objectKind === 'POU' && b.data.hasImplementation === true && b.data.implementationReadable === true && b.data.language === 'ST' && typeof b.data.implementation === 'string');
  await call('GetPouCode', { PouName: `ST_${s}` }, `GetPouCode ST_${s}`, (b) => b.success && b.data.objectKind === 'DUT' && b.data.pouType === 'Struct' && b.data.hasImplementation === false && b.data.implementation === null);
  await call('GetPouCode', { PouName: `GVL_${s}` }, `GetPouCode GVL_${s}`, (b) => b.success && b.data.objectKind === 'GVL' && b.data.hasImplementation === false && b.data.implementation === null);

  await call('WritePouCode', { PouName: `ST_${s}`, Declaration: `TYPE ST_${s} :\nSTRUCT\n    nA : INT;\nEND_STRUCT\nEND_TYPE`, Implementation: 'x := 1;' },
    `WritePouCode ST_${s} with Implementation (expect INVALID_PARAMS)`, (b) => failsWith('INVALID_PARAMS')(b) && b.data?.objectKind === 'DUT');
  await call('WritePouCode', { PouName: `ST_${s}`, Declaration: `TYPE ST_${s} :\nSTRUCT\n    nA : INT;\n    bB : BOOL;\n    nC : DINT;\nEND_STRUCT\nEND_TYPE` },
    `WritePouCode ST_${s} Declaration`, (b) => b.success && b.data.objectKind === 'DUT');
  await call('WritePouCode', {
    PouName: `FB_${s}`,
    Declaration: `FUNCTION_BLOCK FB_${s}\nVAR\n    nCount : INT;\n    stData : ST_${s};\n    eState : E_${s};\n    uData : U_${s};\n    aVal : A_${s};\nEND_VAR`,
    Implementation: `nCount := nCount + 1;\nstData.nC := aVal;\nuData.nW := 1;\neState := E_${s}.eRun;`,
  }, `WritePouCode FB_${s}`, (b) => b.success && b.data.updated.length === 2);
  await call('WritePouCode', {
    PouName: `PRG_${s}`,
    Declaration: `PROGRAM PRG_${s}\nVAR\n    fb : FB_${s};\n    n : INT;\nEND_VAR`,
    Implementation: `fb();\nn := F_${s}() + GVL_${s}.gnX;`,
  }, `WritePouCode PRG_${s}`);
  const main = await call('GetPouCode', { PouName: 'MAIN' }, 'GetPouCode MAIN');
  if (main.success && !String(main.data.implementation).includes(`PRG_${s}();`)) {
    await call('WritePouCode', { PouName: 'MAIN', Implementation: `${String(main.data.implementation).trimEnd()}\nPRG_${s}();\n` }, `WritePouCode MAIN += PRG_${s}()`);
  }

  // control: an undeclared identifier in the new FB must fail the build (proves the new objects are compiled)
  const fbImpl = `nCount := nCount + 1;\nstData.nC := aVal;\nuData.nW := 1;\neState := E_${s}.eRun;`;
  await call('WritePouCode', { PouName: `FB_${s}`, Implementation: `${fbImpl}\nnUndeclared_${s} := 1;` }, `WritePouCode FB_${s} + undeclared identifier`);
  await call('BuildProject', { TimeoutSec: 600 }, 'BuildProject with the error (expect BUILD_FAILED)', (b) => {
    const items = b.data?.errorItems ?? [];
    for (const e of items.slice(0, 3)) console.log(`     err: ${e.description} [${e.file}:${e.line}]`);
    return !b.success && items.some((e) => String(e.description).includes(`nUndeclared_${s}`));
  });
  await call('WritePouCode', { PouName: `FB_${s}`, Implementation: fbImpl }, `WritePouCode FB_${s} fixed`);

  await call('BuildProject', { TimeoutSec: 600 }, 'BuildProject', (b) => {
    if (!b.success && b.data?.errorItems) for (const e of b.data.errorItems.slice(0, 10)) console.log(`     err: ${e.description} [${e.file}:${e.line}]`);
    return b.success;
  });
} catch (e) {
  failed++;
  console.log(`FAIL exception: ${e.message}`);
} finally {
  if (!keep) {
    try { await call('DisconnectIde', { Quit: true }, 'DisconnectIde Quit=true'); } catch (e) { failed++; console.log(`FAIL DisconnectIde: ${e.message}`); }
  }
  await client.close();
}
console.log(`\n${rows.filter((r) => r.pass).length}/${rows.length} PASS`);
process.exit(failed);
