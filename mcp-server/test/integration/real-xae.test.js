// Integration test against a REAL TwinCAT XAE through the real PowerShell bridge.
//
// Requirements: Windows, TwinCAT 3 XAE installed, Windows PowerShell 5.1, a solution
// that the IDE can open. Nothing is mocked: this test spawns index.js, which spawns
// powershell.exe bridge/bridge.ps1 importing src/TwinCATAutomation.
//
// It is skipped unless BOTH are set:
//     $env:TWINCAT_MCP_INTEGRATION='1'; $env:TWINCAT_TEST_SOLUTION='C:\path\to\Project.sln'; npm run test:integration
// There is no default solution: the test must never open a project the developer did not pick.
//
// Scope (deliberately read-only for the PLC/runtime): only the tools in ALLOWED_TOOLS may be
// called (ConnectIde, GetIdeInfo, GetStatus, GetIdeModalDialog, BuildProject, GetBuildErrors,
// DisconnectIde). It never activates a configuration, logs in, changes a state or writes a
// variable. Cleanup only touches the bridge.ps1 spawned by THIS test's server process and the
// XAE that ConnectIde launched for it; other bridges / IDEs on the machine are left alone.
//
// The tests in the describe below are ORDER DEPENDENT (one shared client and one
// shared IDE connection). A failed ConnectIde makes the later steps skip rather than
// cascade-fail.
import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { LoggingMessageNotificationSchema } from '@modelcontextprotocol/sdk/types.js';

const ENABLED = process.env.TWINCAT_MCP_INTEGRATION === '1';
const SOLUTION = (process.env.TWINCAT_TEST_SOLUTION ?? '').trim();
const SOLUTION_NAME = SOLUTION ? path.basename(SOLUTION, '.sln') : '';
const SKIP_REASON = !ENABLED
  ? 'set TWINCAT_MCP_INTEGRATION=1 to run against a real XAE'
  : !SOLUTION
    ? 'TWINCAT_MCP_INTEGRATION=1 but TWINCAT_TEST_SOLUTION is not set: point it at a .sln the XAE may open (no default on purpose)'
    : false;
if (ENABLED && !SOLUTION) console.log(`[real-xae] skipped: ${SKIP_REASON}`);

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const INDEX = path.join(__dirname, '..', '..', 'index.js');

const EXPECTED_TOOL_COUNT = 39; // 35 catalog (tools.json) + 4 composites
const CONNECT_TIMEOUT_MS = 300000; // ConnectIde may launch XAE and open the solution
const BUILD_TIMEOUT_MS = 660000; // tools.json BuildProject.timeoutMs 600000 + grace
const SHORT_TIMEOUT_MS = 120000; // GetIdeInfo / GetStatus / GetIdeModalDialog / DisconnectIde
// Whitelist: everything else (EnableConfig, PlcLogin, SetPlcState, WriteVariable, RunLifecycle, ...)
// changes the machine and is refused by callTool() below.
const ALLOWED_TOOLS = new Set(['ConnectIde', 'GetIdeInfo', 'GetStatus', 'GetIdeModalDialog', 'BuildProject', 'GetBuildErrors', 'DisconnectIde']);

// ----------------------------------------------------------------- helpers

function log(...args) {
  console.log('[real-xae]', ...args);
}

function parse(result) {
  assert.ok(Array.isArray(result.content) && result.content.length > 0, 'tool result has content');
  assert.equal(result.content[0].type, 'text');
  return JSON.parse(result.content[0].text);
}

function psJson(script) {
  // Runs a PowerShell one-liner and parses its JSON output (null / object / array).
  const out = execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', script], {
    encoding: 'utf8',
    windowsHide: true,
    timeout: 60000
  }).trim();
  if (!out) return [];
  const parsed = JSON.parse(out);
  return parsed === null ? [] : Array.isArray(parsed) ? parsed : [parsed];
}

/**
 * powershell.exe processes whose command line runs bridge.ps1. With `parentPid` only the ones
 * spawned by that process (our own index.js) are returned; other MCP servers' bridges are not ours.
 */
function findBridgeProcesses(parentPid = null) {
  const parentFilter = Number.isInteger(parentPid) ? ` -and $_.ParentProcessId -eq ${parentPid}` : '';
  return psJson(
    // The real bridge runs as "... -File <dir>\bridge.ps1 -ModulePath ..."; the query process itself
    // (whose command line also mentions bridge.ps1) is excluded via $PID and the -File form.
    `Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match '-File\\s+\\S*bridge\\.ps1'${parentFilter} } | ` +
      'Select-Object ProcessId, ParentProcessId, CreationDate, CommandLine | ConvertTo-Json -Compress'
  );
}

/** TcXaeShell.exe / devenv.exe processes (pid + command line). */
function findIdeProcesses() {
  return psJson(
    "Get-CimInstance Win32_Process | Where-Object { $_.Name -match '^(TcXaeShell|devenv)\\.exe$' } | " +
      'Select-Object ProcessId, Name, CreationDate, CommandLine | ConvertTo-Json -Compress'
  );
}

/**
 * Win32 dump of every visible #32770 dialog owned by the given pid (title + child control
 * texts). Used after a BRIDGE_TIMEOUT, when the bridge is gone and GetIdeModalDialog
 * cannot be asked any more. Read-only: it never sends anything but WM_GETTEXT.
 */
function dumpIdeDialogs(pid) {
  const script = `
$src = @"
using System; using System.Text; using System.Runtime.InteropServices; using System.Collections.Generic;
public static class DlgEnum {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, StringBuilder l);
  public static List<string> Dump(uint target) {
    var r = new List<string>();
    EnumWindows((h,l)=>{ uint p; GetWindowThreadProcessId(h, out p); if (p!=target || !IsWindowVisible(h)) return true;
      var c=new StringBuilder(256); GetClassName(h,c,256); if (c.ToString()!="#32770") return true;
      var t=new StringBuilder(512); GetWindowText(h,t,512); r.Add("DIALOG '"+t+"'");
      EnumChildWindows(h,(ch,cl)=>{ var cc=new StringBuilder(256); GetClassName(ch,cc,256); var sb=new StringBuilder(8192); SendMessage(ch,0x000D,(IntPtr)8192,sb); if (sb.Length>0) r.Add("  "+cc+": "+sb.ToString().Replace("\\r\\n"," | ")); return true; }, IntPtr.Zero);
      return true; }, IntPtr.Zero);
    return r;
  }
}
"@
Add-Type -TypeDefinition $src
[DlgEnum]::Dump([uint32]${pid}) | ConvertTo-Json -Compress`;
  try {
    return psJson(script).map(String);
  } catch (err) {
    return [`dialog dump failed: ${err.message}`];
  }
}

function isAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function taskkill(pid) {
  try {
    execFileSync('taskkill', ['/PID', String(pid), '/T', '/F'], { stdio: 'pipe', windowsHide: true, timeout: 30000 });
    return true;
  } catch (err) {
    log(`taskkill ${pid} failed: ${err.message}`);
    return false;
  }
}

async function waitFor(predicate, timeoutMs, stepMs = 500) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) {
    if (await predicate()) return true;
    await new Promise((r) => setTimeout(r, stepMs));
  }
  return predicate();
}

function summarizeErrorItems(items, max = 20) {
  const list = Array.isArray(items) ? items : [];
  const lines = list.slice(0, max).map((e, i) => `  ${i + 1}. [${e.severity ?? '?'}${e.code ? ' ' + e.code : ''}] ${e.description ?? ''}  (${e.file ?? ''}:${e.line ?? ''})`);
  if (list.length > max) lines.push(`  ... ${list.length - max} more`);
  return lines.join('\n');
}

// ----------------------------------------------------------------- suite

describe('real XAE over stdio (index.js + bridge.ps1 + TwinCATAutomation)', { skip: SKIP_REASON }, () => {
  /** @type {Client} */
  let client;
  /** @type {StdioClientTransport} */
  let transport;
  /** pid of the index.js child this test spawned; only its bridge.ps1 is ours to clean up */
  let serverPid = null;
  const stderrLines = [];
  const logNotifications = [];
  const state = {
    connected: false,
    selectedBy: null,
    ideProcessId: null,
    solution: null,
    buildSkipReason: null,
    modalRetried: false,
    buildSeconds: null
  };

  function callTool(name, args = {}, timeout = SHORT_TIMEOUT_MS) {
    assert.ok(ALLOWED_TOOLS.has(name), `test must never call ${name} (not in ALLOWED_TOOLS)`);
    return client.callTool({ name, arguments: args }, undefined, { timeout });
  }

  function dumpDiagnostics(label) {
    const errs = logNotifications.filter((l) => l.level === 'error' || l.level === 'warning');
    log(`--- ${label}: ${stderrLines.length} server stderr line(s), ${errs.length} warning/error notification(s) ---`);
    for (const line of stderrLines) console.log('  [stderr] ' + line);
    for (const n of errs) console.log(`  [notify:${n.level}] ${JSON.stringify(n.data)}`);
  }

  async function connectIde() {
    const res = await callTool('ConnectIde', { SolutionPath: SOLUTION }, CONNECT_TIMEOUT_MS);
    const body = parse(res);
    log(`ConnectIde -> success=${body.success} selectedBy=${body.data?.selectedBy} pid=${body.data?.ideProcessId} progId=${body.data?.progId} solution=${body.data?.solution}`);
    if (body.success !== true) log('ConnectIde error: ' + JSON.stringify(body.error));
    return { res, body };
  }

  before(async () => {
    // Informational only: other bridges belong to other MCP servers (e.g. a Claude Code session) and are not touched.
    const others = findBridgeProcesses();
    log(`bridge.ps1 processes already running (not ours, left alone): ${others.length}`);
    for (const p of others) log(`  pid=${p.ProcessId} parent=${p.ParentProcessId} ${p.CommandLine}`);

    const ides = findIdeProcesses();
    log(`XAE/VS processes before start: ${ides.length}`);
    for (const p of ides) log(`  ${p.Name} pid=${p.ProcessId} ${p.CommandLine}`);
    log(`solution: ${SOLUTION}`);

    transport = new StdioClientTransport({
      command: process.execPath,
      args: [INDEX],
      env: { ...process.env },
      stderr: 'pipe'
    });
    let partial = '';
    transport.stderr?.on('data', (chunk) => {
      partial += chunk.toString();
      const parts = partial.split(/\r?\n/);
      partial = parts.pop();
      for (const line of parts) if (line.length) stderrLines.push(line);
    });

    client = new Client({ name: 'real-xae-integration', version: '0.0.0' }, { capabilities: {} });
    client.setNotificationHandler(LoggingMessageNotificationSchema, (n) => {
      logNotifications.push(n.params);
      if (n.params.level === 'warning' || n.params.level === 'error') {
        console.warn(`[twincat ${n.params.level}] ${JSON.stringify(n.params.data)}`);
      }
    });
    await client.connect(transport);
    serverPid = transport.pid;
    log(`MCP client connected (server pid ${serverPid})`);
  });

  after(async () => {
    try {
      await client?.close();
    } catch (err) {
      log(`client.close failed: ${err.message}`);
    }
    // index.js reacts to stdin close: bridge.stop() sends "shutdown" and waits <= 5 s.
    // Only the bridge whose parent is OUR server process is ours; never kill other servers' bridges.
    const ours = () => (Number.isInteger(serverPid) ? findBridgeProcesses(serverPid) : []);
    const gone = await waitFor(() => ours().length === 0, 15000, 1000);
    const leftovers = gone ? [] : ours();
    if (leftovers.length) {
      for (const p of leftovers) {
        log(`leftover bridge pid=${p.ProcessId} parent=${p.ParentProcessId} (our server ${serverPid}) ${p.CommandLine} -> killing`);
        taskkill(p.ProcessId);
      }
    }
    // An XAE that ConnectIde launched for us must not outlive the test.
    if (state.selectedBy === 'launched' && Number.isInteger(state.ideProcessId) && state.ideProcessId > 0) {
      const exited = await waitFor(() => !isAlive(state.ideProcessId), 20000, 1000);
      if (!exited) {
        log(`launched XAE pid=${state.ideProcessId} still alive after DisconnectIde Quit -> taskkill`);
        taskkill(state.ideProcessId);
      }
    }
    dumpDiagnostics('after');
    assert.equal(leftovers.length, 0, `our bridge.ps1 (parent ${serverPid}) left behind after client.close(): ${leftovers.map((p) => p.ProcessId).join(', ')}`);
  });

  test('1. listTools: 39 tools (35 catalog + 4 composite), all with object input schemas', async () => {
    const { tools } = await client.listTools();
    const names = tools.map((t) => t.name);
    assert.equal(tools.length, EXPECTED_TOOL_COUNT, `tools: ${names.join(', ')}`);
    for (const required of ['RunLifecycle', 'QuickRead', 'GetStatus', 'GetIdeModalDialog', 'ConnectIde', 'BuildProject', 'GetIdeInfo', 'DisconnectIde', 'GetBuildErrors']) {
      assert.ok(names.includes(required), `tool ${required} listed`);
    }
    for (const t of tools) {
      assert.equal(t.inputSchema?.type, 'object', `${t.name}.inputSchema.type`);
    }
    assert.equal(new Set(names).size, names.length, 'tool names are unique');
  });

  test('2. before ConnectIde: GetStatus and GetIdeInfo -> NOT_CONNECTED with hint', async () => {
    const status = await callTool('GetStatus');
    assert.equal(status.isError, true);
    const sBody = parse(status);
    assert.equal(sBody.success, false);
    assert.equal(sBody.error?.code, 'NOT_CONNECTED');
    assert.ok(typeof sBody.error?.hint === 'string' && sBody.error.hint.length > 0, 'GetStatus hint present');
    assert.equal(sBody.data?.bridge?.ideConnected, false);

    const info = await callTool('GetIdeInfo');
    assert.equal(info.isError, true);
    const iBody = parse(info);
    assert.equal(iBody.success, false);
    assert.equal(iBody.error?.code, 'NOT_CONNECTED');
    assert.ok(typeof iBody.error?.hint === 'string' && iBody.error.hint.length > 0, 'GetIdeInfo hint present (added by the bridge)');
    log(`GetIdeInfo NOT_CONNECTED hint: ${iBody.error.hint}`);
  });

  test('3. ConnectIde {SolutionPath} -> success, records selectedBy / ideProcessId / solution', { timeout: CONNECT_TIMEOUT_MS + 30000 }, async () => {
    const t0 = Date.now();
    const { res, body } = await connectIde();
    log(`ConnectIde took ${((Date.now() - t0) / 1000).toFixed(1)} s`);
    if (body.success !== true) dumpDiagnostics('ConnectIde failed');
    assert.equal(res.isError, false);
    assert.equal(body.success, true);
    assert.ok(typeof body.data.selectedBy === 'string' && body.data.selectedBy.length > 0, 'selectedBy');
    assert.ok(Number.isInteger(body.data.ideProcessId) && body.data.ideProcessId > 0, `ideProcessId: ${body.data.ideProcessId}`);
    assert.ok(typeof body.data.solution === 'string' && body.data.solution.includes(SOLUTION_NAME), `solution '${body.data.solution}' contains ${SOLUTION_NAME}`);
    state.connected = true;
    state.selectedBy = body.data.selectedBy;
    state.ideProcessId = body.data.ideProcessId;
    state.solution = body.data.solution;
    log(`candidates: ${JSON.stringify(body.data.candidates)} amsNetId=${body.data.amsNetId ?? '(none)'} sysManagerAvailable=${body.data.sysManagerAvailable}`);
  });

  test('4. state survives across calls: GetIdeInfo and GetStatus see the connection', async (t) => {
    if (!state.connected) return t.skip('ConnectIde did not succeed');

    const info = await callTool('GetIdeInfo');
    assert.equal(info.isError, false);
    const iBody = parse(info);
    assert.equal(iBody.success, true);
    assert.equal(iBody.data.solution, state.solution, 'same solution as ConnectIde reported');
    log(`GetIdeInfo: version=${iBody.data.version} edition=${iBody.data.edition} sysManagerAvailable=${iBody.data.sysManagerAvailable}`);

    const status = await callTool('GetStatus');
    assert.equal(status.isError, false);
    const sBody = parse(status);
    assert.equal(sBody.success, true);
    assert.equal(sBody.data.bridge.ideConnected, true);
    assert.equal(sBody.data.bridge.ideProcessId, state.ideProcessId);
    assert.ok(sBody.data.ide && typeof sBody.data.ide === 'object', 'data.ide present');
    assert.equal(sBody.data.ide.success, true, 'GetStatus.data.ide succeeded');
    assert.ok('system' in sBody.data, 'data.system present (may be a failure result)');
    log(`GetStatus.system: success=${sBody.data.system?.success} ${sBody.data.system?.success ? JSON.stringify(sBody.data.system.data) : JSON.stringify(sBody.data.system?.error)}`);
    assert.equal(sBody.data.plc, null, 'no ADS connection -> plc null');
  });

  test('5. GetIdeModalDialog -> no blocking dialog (kill + reconnect once if our launched XAE shows one)', { timeout: 2 * CONNECT_TIMEOUT_MS }, async (t) => {
    if (!state.connected) return t.skip('ConnectIde did not succeed');

    let res = await callTool('GetIdeModalDialog', { TimeoutSec: 5 });
    assert.equal(res.isError, false, JSON.stringify(parse(res)));
    let body = parse(res);
    assert.equal(body.success, true);
    assert.equal(body.data.ideProcessId, state.ideProcessId);
    if (body.data.dialog === null) {
      log('no modal dialog');
      return;
    }

    log(`MODAL DIALOG on XAE pid=${state.ideProcessId}: title='${body.data.dialog.title}' text='${body.data.dialog.text}'`);
    if (state.selectedBy !== 'launched') {
      state.buildSkipReason = `XAE pid ${state.ideProcessId} (selectedBy=${state.selectedBy}, not launched by us) shows a modal dialog: ${body.data.dialog.title} - ${body.data.dialog.text}`;
      return t.skip(state.buildSkipReason);
    }

    // Our own XAE: kill it, drop the stale COM refs, connect once more.
    state.modalRetried = true;
    log(`killing launched XAE pid=${state.ideProcessId} and reconnecting once`);
    assert.ok(taskkill(state.ideProcessId), 'taskkill of the launched XAE');
    await waitFor(() => !isAlive(state.ideProcessId), 30000, 500);
    const disc = parse(await callTool('DisconnectIde', {}));
    log(`DisconnectIde after kill: ${JSON.stringify(disc)}`);
    state.connected = false;

    const again = await connectIde();
    assert.equal(again.body.success, true, 'ConnectIde after killing the blocked XAE');
    state.connected = true;
    state.selectedBy = again.body.data.selectedBy;
    state.ideProcessId = again.body.data.ideProcessId;
    state.solution = again.body.data.solution;

    res = await callTool('GetIdeModalDialog', { TimeoutSec: 5 });
    body = parse(res);
    assert.equal(body.success, true);
    if (body.data.dialog !== null) {
      state.buildSkipReason = `modal dialog again after one retry: ${body.data.dialog.title} - ${body.data.dialog.text}`;
    }
    assert.equal(body.data.dialog, null, state.buildSkipReason ?? '');
  });

  test('6. BuildProject -> buildSucceeded, or BUILD_FAILED with errorItems', { timeout: BUILD_TIMEOUT_MS + 30000 }, async (t) => {
    if (!state.connected) return t.skip('ConnectIde did not succeed');
    if (state.buildSkipReason) return t.skip(state.buildSkipReason);

    const t0 = Date.now();
    const res = await callTool('BuildProject', {}, BUILD_TIMEOUT_MS);
    state.buildSeconds = (Date.now() - t0) / 1000;
    const body = parse(res);
    log(`BuildProject took ${state.buildSeconds.toFixed(1)} s: success=${body.success} code=${body.error?.code ?? '-'} buildSucceeded=${body.data?.buildSucceeded} failedProjects=${body.data?.failedProjects} errors=${body.data?.errors} errorItems=${Array.isArray(body.data?.errorItems) ? body.data.errorItems.length : 'n/a'} codeErrors=${Array.isArray(body.data?.codeErrors) ? body.data.codeErrors.length : 'n/a'}`);
    if (Array.isArray(body.data?.errorItems) && body.data.errorItems.length) {
      log('errorItems:\n' + summarizeErrorItems(body.data.errorItems));
    }

    if (body.success === true) {
      assert.equal(res.isError, false);
      assert.equal(body.data.buildSucceeded, true, 'success:true must come with buildSucceeded:true');
      return;
    }

    assert.equal(res.isError, true);
    if (body.error?.code !== 'BUILD_FAILED') {
      log(`BuildProject error: ${JSON.stringify(body.error)}`);
      if (body.data?.dialogTitle || body.data?.dialogText) log(`dialog: ${body.data.dialogTitle} - ${body.data.dialogText}`);
      if (body.error?.code === 'BRIDGE_TIMEOUT' || body.error?.code === 'BRIDGE_DIED') {
        // The bridge (and its IDE connection) is gone; look at the XAE windows directly.
        state.connected = false;
        const dialogs = isAlive(state.ideProcessId) ? dumpIdeDialogs(state.ideProcessId) : ['(XAE process no longer running)'];
        log(`XAE pid=${state.ideProcessId} dialogs after ${body.error.code}:\n  ` + (dialogs.length ? dialogs.join('\n  ') : '(none visible)'));
      }
      dumpDiagnostics('BuildProject failed');
    }
    assert.equal(body.error?.code, 'BUILD_FAILED', `BuildProject must report BUILD_FAILED, not ${body.error?.code}: ${body.error?.message}`);
    assert.equal(body.data?.buildSucceeded, false);
    assert.ok(Array.isArray(body.data?.errorItems), 'BUILD_FAILED carries data.errorItems');
    for (const item of body.data.errorItems) {
      assert.ok(typeof item.description === 'string', 'errorItem.description');
      assert.ok('file' in item && 'line' in item, 'errorItem has file and line');
    }
  });

  test('7. after Build: bridge not restarted, IDE still connected (same ideProcessId)', async (t) => {
    if (!state.connected) return t.skip('ConnectIde did not succeed');

    const info = await callTool('GetIdeInfo');
    assert.equal(info.isError, false, JSON.stringify(parse(info)));
    const iBody = parse(info);
    assert.equal(iBody.success, true);
    assert.equal(iBody.data.solution, state.solution);

    const status = parse(await callTool('GetStatus'));
    assert.equal(status.success, true);
    assert.equal(status.data.bridge.ideConnected, true);
    assert.equal(status.data.bridge.ideProcessId, state.ideProcessId, 'same IDE pid as after ConnectIde -> bridge state survived Build');
    assert.equal(status.data.bridge.lastModalDialog, null, 'no modal dialog was seen during Build');
  });

  test('8. DisconnectIde (Quit only when we launched the XAE) -> success', async (t) => {
    if (!state.connected) return t.skip('IDE connection not available (ConnectIde failed or bridge was restarted); after() kills a launched XAE');

    const quit = state.selectedBy === 'launched';
    const res = await callTool('DisconnectIde', { Quit: quit });
    const body = parse(res);
    log(`DisconnectIde {Quit:${quit}} -> ${JSON.stringify(body)}`);
    assert.equal(res.isError, false);
    assert.equal(body.success, true);
    if (quit) {
      assert.equal(body.data.quit, true, `DTE.Quit succeeded (quitError=${body.data.quitError})`);
    }
    state.connected = false;

    const status = parse(await callTool('GetStatus'));
    assert.equal(status.error?.code, 'NOT_CONNECTED', 'bridge state cleared after DisconnectIde');
  });

  test('summary', (t) => {
    log(`SUMMARY selectedBy=${state.selectedBy} ideProcessId=${state.ideProcessId} modalRetried=${state.modalRetried} buildSeconds=${state.buildSeconds ?? 'n/a'} buildSkip=${state.buildSkipReason ?? 'none'}`);
    t.diagnostic(`selectedBy=${state.selectedBy} modalRetried=${state.modalRetried} buildSeconds=${state.buildSeconds ?? 'n/a'}`);
  });
});
