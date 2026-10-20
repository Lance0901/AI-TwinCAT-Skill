// Unit tests: lib/modal-probe.js with the mock probe, the real bridge/modal-probe.ps1 (win32 only),
// and PowerShellBridge.abortCall with the mock bridge.
import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import readline from 'node:readline';
import { ModalProbe, PROBED_TOOLS, buildProbeSpawnSpec, DEFAULT_PROBE_SCRIPT, DEFAULT_PROBE_INTERVAL_SEC, DEFAULT_SCAN_SCRIPT } from '../lib/modal-probe.js';
import { PowerShellBridge, errorResult } from '../lib/bridge.js';
import { loadConfig, defaultPowershellPath, scanScriptFor } from '../lib/config.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const MOCK_PROBE = path.join(__dirname, 'fixtures', 'mock-modal-probe.js');
const MOCK_BRIDGE = path.join(__dirname, 'fixtures', 'mock-bridge.js');
const REAL_PROBE = path.join(__dirname, '..', 'bridge', 'modal-probe.ps1');
const PROBE_PARENT = path.join(__dirname, 'fixtures', 'probe-parent.js');
const HOST_WINDOW = path.join(__dirname, 'fixtures', 'host-window.ps1');
const HOST_WINDOW_WPF = path.join(__dirname, 'fixtures', 'host-window-wpf.ps1');
const DIALOG_ANSWER = path.join(__dirname, 'fixtures', 'dialog-answer.ps1');
const MODULE_PATH = path.join(__dirname, '..', '..', 'src', 'TwinCATAutomation', 'TwinCATAutomation.psm1');
const isWin = process.platform === 'win32';

function alive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function waitFor(cond, timeoutMs, stepMs = 25) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) {
    if (cond()) return true;
    await new Promise((r) => setTimeout(r, stepMs));
  }
  return cond();
}

let tmp;
before(() => {
  tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'twincat-probe-unit-'));
});
after(() => {
  try {
    fs.rmSync(tmp, { recursive: true, force: true });
  } catch {
    /* ignore */
  }
});

/** Mock probe with its own trigger file; resolves events into arrays. */
function mockProbe(triggerContent, extraEnv = {}) {
  const trigger = path.join(tmp, `trigger-${Math.random().toString(36).slice(2)}`);
  if (triggerContent !== undefined) fs.writeFileSync(trigger, triggerContent);
  const dialogs = [];
  const errors = [];
  let exitResolve;
  const probe = new ModalProbe({
    pid: 4242,
    intervalSec: 1,
    spawnSpec: { command: process.execPath, args: [MOCK_PROBE] },
    env: { MOCK_PROBE_TRIGGER_FILE: trigger, ...extraEnv },
    onDialog: (d) => dialogs.push(d),
    onError: (m) => errors.push(m)
  });
  probe.start();
  const exited = new Promise((r) => (exitResolve = r));
  probe.child.once('close', (code) => exitResolve(code));
  return { probe, dialogs, errors, exited, trigger };
}

describe('lib/modal-probe.js', () => {
  test('PROBED_TOOLS and defaults', () => {
    assert.deepEqual([...PROBED_TOOLS].sort(), ['BuildProject', 'ConnectIde', 'EnableConfig', 'OpenProject', 'PlcLogin', 'RunTestCycle', 'SendPlcProgram']);
    assert.equal(PROBED_TOOLS.has('RunLifecycle'), false, 'covered through its steps');
    assert.equal(DEFAULT_PROBE_INTERVAL_SEC, 5);
    assert.match(DEFAULT_PROBE_SCRIPT, /bridge[\\/]modal-probe\.ps1$/);
  });

  test('buildProbeSpawnSpec: default powershell.exe command line and override shape', () => {
    const def = buildProbeSpawnSpec({ powershellPath: 'P:\\ps.exe', probeScript: 'B:\\probe.ps1', pid: 1234, intervalSec: 5, confirmScans: 3, scanScript: 'S:\\scan.ps1' });
    assert.deepEqual(def, {
      command: 'P:\\ps.exe',
      args: ['-NoProfile', '-NonInteractive', '-STA', '-ExecutionPolicy', 'Bypass', '-File', 'B:\\probe.ps1', '-ProcessId', '1234', '-IntervalSec', '5', '-ConfirmScans', '3', '-ScanScript', 'S:\\scan.ps1']
    });
    const ovr = buildProbeSpawnSpec({ powershellPath: 'P:\\ps.exe', spawnSpec: { command: 'node', args: ['mock.js'] }, pid: 7, intervalSec: 2, scanScript: 'S:\\scan.ps1', mainHwnd: 16962, maxLifetimeSec: 64 });
    assert.deepEqual(ovr, {
      command: 'node',
      args: ['mock.js', '-ProcessId', '7', '-IntervalSec', '2', '-ConfirmScans', '2', '-ScanScript', 'S:\\scan.ps1', '-MainHwnd', '16962', '-MaxLifetimeSec', '64']
    });
    const fallback = buildProbeSpawnSpec({ pid: 9, mainHwnd: 0 });
    assert.equal(fallback.command, defaultPowershellPath());
    assert.ok(fallback.args.includes(DEFAULT_PROBE_SCRIPT));
    assert.deepEqual(fallback.args.slice(-8), ['-ProcessId', '9', '-IntervalSec', '5', '-ConfirmScans', '2', '-ScanScript', DEFAULT_SCAN_SCRIPT]);
    assert.ok(!fallback.args.includes('-MainHwnd'), 'no -MainHwnd for an unknown (0) handle');
    assert.ok(!fallback.args.includes('-MaxLifetimeSec'));
    assert.match(DEFAULT_SCAN_SCRIPT, /src[\\/]TwinCATAutomation[\\/]Private[\\/]Get-TcIdeModalDialog\.ps1$/);
    assert.ok(fs.existsSync(DEFAULT_SCAN_SCRIPT), 'default scan script exists');
  });

  test('config: probe on by default, off with 0/false/off, interval clamped, test spawn override', () => {
    const def = loadConfig({});
    assert.equal(def.modalProbe.enabled, true);
    assert.equal(def.modalProbe.intervalSec, 5);
    assert.equal(def.modalProbe.spawnSpec, null);
    assert.equal(def.modalProbe.probeScript, DEFAULT_PROBE_SCRIPT);
    assert.equal(def.modalProbe.confirmScans, 2);
    assert.equal(def.modalProbe.scanScript, DEFAULT_SCAN_SCRIPT);
    for (const v of ['0', 'false', 'OFF', 'no']) assert.equal(loadConfig({ TWINCAT_MCP_MODAL_PROBE: v }).modalProbe.enabled, false, v);
    for (const v of ['1', 'true', 'on', '']) assert.equal(loadConfig({ TWINCAT_MCP_MODAL_PROBE: v }).modalProbe.enabled, true, v);
    assert.equal(loadConfig({ TWINCAT_MCP_MODAL_PROBE_INTERVAL_SEC: '999' }).modalProbe.intervalSec, 60);
    assert.equal(loadConfig({ TWINCAT_MCP_MODAL_PROBE_INTERVAL_SEC: '2' }).modalProbe.intervalSec, 2);
    assert.equal(loadConfig({ TWINCAT_MCP_MODAL_PROBE_INTERVAL_SEC: 'x' }).modalProbe.intervalSec, 5);
    const ovr = loadConfig({ TWINCAT_MCP_PROBE_COMMAND: 'node', TWINCAT_MCP_PROBE_ARGS: '["a.js"]' });
    assert.deepEqual(ovr.modalProbe.spawnSpec, { command: 'node', args: ['a.js'] });
    assert.equal(ovr.spawnSpec, null, 'bridge override untouched');
    assert.throws(() => loadConfig({ TWINCAT_MCP_PROBE_COMMAND: 'node', TWINCAT_MCP_PROBE_ARGS: '{}' }), /TWINCAT_MCP_PROBE_ARGS must be a JSON array/);
  });

  test('config: TWINCAT_MCP_PROBE_CONFIRM_SCANS (default 2, clamp 1..10) and TWINCAT_MCP_PROBE_SCAN_SCRIPT', () => {
    const cs = (v) => loadConfig({ TWINCAT_MCP_PROBE_CONFIRM_SCANS: v }).modalProbe.confirmScans;
    assert.equal(cs('3'), 3);
    assert.equal(cs('1'), 1);
    assert.equal(cs('99'), 10);
    assert.equal(cs('0'), 2, 'not positive -> default');
    assert.equal(cs('x'), 2);
    assert.equal(cs(''), 2);
    assert.equal(loadConfig({ TWINCAT_MCP_PROBE_SCAN_SCRIPT: 'X:\\scan.ps1' }).modalProbe.scanScript, 'X:\\scan.ps1');
    // follows TWINCAT_MODULE_PATH when not overridden
    const fromModule = loadConfig({ TWINCAT_MODULE_PATH: path.join('M:', 'mod', 'TwinCATAutomation.psm1') }).modalProbe.scanScript;
    assert.equal(fromModule, path.join('M:', 'mod', 'Private', 'Get-TcIdeModalDialog.ps1'));
    assert.equal(scanScriptFor(path.join('A:', 'b', 'x.psm1')), path.join('A:', 'b', 'Private', 'Get-TcIdeModalDialog.ps1'));
  });

  test('stderr "debug:" lines go to onDebug, other lines to onError', async () => {
    const debug = [];
    const { probe, errors } = mockProbe(undefined, { MOCK_PROBE_DEBUG: '1', MOCK_PROBE_ECHO: '1' });
    probe.onDebug = (m) => debug.push(m);
    await waitFor(() => debug.length > 0 && errors.length > 0, 2000);
    probe.stop();
    assert.deepEqual(debug, ['[modal-probe] debug: mock routine line']);
    assert.equal(errors.length, 1, JSON.stringify(errors));
    assert.match(errors[0], /^\[modal-probe\] argv /);
  });

  test('dialog line -> onDialog exactly once with the parsed fields, probe exits', async () => {
    const { probe, dialogs, errors, exited } = mockProbe(JSON.stringify({ title: 'Assertion Failed', text: 'boom' }));
    assert.equal(probe.running, true);
    assert.ok(Number.isInteger(probe.pid));
    await exited;
    await waitFor(() => dialogs.length > 0, 1000);
    assert.equal(dialogs.length, 1);
    assert.deepEqual(dialogs[0], { title: 'Assertion Failed', text: 'boom', className: '#32770', isModal: true, processId: 4242, mainWindowBlocked: true, reason: 'win32-dialog' });
    assert.deepEqual(errors, []);
    assert.equal(probe.running, false);
  });

  test('BADJSON -> onError, no onDialog', async () => {
    const { dialogs, errors, exited } = mockProbe('BADJSON');
    assert.equal(await exited, 0);
    assert.equal(dialogs.length, 0);
    assert.ok(errors.some((e) => /non-JSON stdout line: not json/.test(e)), JSON.stringify(errors));
  });

  test('CRASH -> onError with the stderr line and the non-zero exit, no onDialog', async () => {
    const { dialogs, errors, exited } = mockProbe('CRASH');
    assert.equal(await exited, 2);
    await waitFor(() => errors.length >= 2, 1000);
    assert.equal(dialogs.length, 0);
    assert.ok(errors.includes('[modal-probe] mock probe crash'), JSON.stringify(errors));
    assert.ok(errors.includes('[modal-probe] probe exited with code 2'), JSON.stringify(errors));
  });

  test('stop() kills an idle probe and is idempotent; spawn failure only reports onError', async () => {
    const { probe, errors } = mockProbe(undefined, { MOCK_PROBE_ECHO: '1' });
    await waitFor(() => errors.length > 0, 2000);
    assert.match(errors[0], /argv .*"-ProcessId","4242","-IntervalSec","1"/);
    const pid = probe.pid;
    assert.equal(alive(pid), true);
    probe.stop();
    probe.stop();
    assert.ok(await waitFor(() => !alive(pid), 2000), 'probe process is dead');
    assert.equal(errors.filter((e) => /exited with code/.test(e)).length, 0, 'a stopped probe does not report its exit');

    const bad = [];
    const p = new ModalProbe({ pid: 1, spawnSpec: { command: path.join(tmp, 'does-not-exist.exe'), args: [] }, onError: (m) => bad.push(m) });
    p.start();
    await waitFor(() => bad.length > 0, 2000);
    assert.match(bad[0], /\[modal-probe\]/);
    p.stop();
  });
});

describe('bridge/modal-probe.ps1 (real script)', { skip: !isWin && 'Windows only' }, () => {
  test('parses as a PowerShell 5.1 script and is ASCII without BOM', () => {
    const r = spawnSync(
      defaultPowershellPath(),
      ['-NoProfile', '-NonInteractive', '-Command', `[scriptblock]::Create((Get-Content -Raw '${REAL_PROBE.replace(/'/g, "''")}')) | Out-Null`],
      { encoding: 'utf8', windowsHide: true, timeout: 60000 }
    );
    assert.equal(r.status, 0, r.stderr);
    const bytes = fs.readFileSync(REAL_PROBE);
    assert.ok(!(bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf), 'no BOM');
    assert.ok(bytes.every((b) => b < 0x80), 'ASCII only');
  });

  test('non-existent pid -> exit 3 with "not found" on stderr', async () => {
    const errors = [];
    const probe = new ModalProbe({ pid: 999999999, intervalSec: 1, onError: (m) => errors.push(m) });
    probe.start();
    const code = await new Promise((r) => probe.child.once('close', r));
    assert.equal(code, 3);
    assert.ok(errors.some((e) => /process 999999999 not found/.test(e)), JSON.stringify(errors));
    assert.ok(errors.some((e) => /probe exited with code 3/.test(e)));
  });

  test('watching a process without windows (node itself) keeps running; stop() kills it', async () => {
    const errors = [];
    const dialogs = [];
    const probe = new ModalProbe({ pid: process.pid, intervalSec: 1, onError: (m) => errors.push(m), onDialog: (d) => dialogs.push(d) });
    probe.start();
    const pid = probe.pid;
    await new Promise((r) => setTimeout(r, 2500));
    assert.equal(probe.running, true, `probe still running (errors: ${JSON.stringify(errors)})`);
    assert.deepEqual(dialogs, []);
    probe.stop();
    assert.ok(await waitFor(() => !alive(pid), 3000), 'real probe killed');
  });

  test('missing -ScanScript file -> exit 2 with an "error:" line', async () => {
    const errors = [];
    const probe = new ModalProbe({ pid: process.pid, intervalSec: 1, scanScript: path.join(tmp, 'nope.ps1'), onError: (m) => errors.push(m) });
    probe.start();
    const code = await new Promise((r) => probe.child.once('close', r));
    assert.equal(code, 2);
    assert.ok(errors.some((e) => /^\[modal-probe\] error: scan script not found: .*nope\.ps1/.test(e)), JSON.stringify(errors));
  });

  test('-MaxLifetimeSec 1 is clamped to 10: the probe is still running after 2 s', async () => {
    const debug = [];
    const probe = new ModalProbe({ pid: process.pid, intervalSec: 1, maxLifetimeSec: 1, onDebug: (m) => debug.push(m) });
    probe.start();
    const pid = probe.pid;
    await new Promise((r) => setTimeout(r, 2000));
    assert.equal(probe.running, true, JSON.stringify(debug));
    assert.ok(debug.some((d) => /watching pid \d+ .*lifetime 10 s/.test(d)), JSON.stringify(debug));
    probe.stop();
    assert.ok(await waitFor(() => !alive(pid), 3000));
  });

  test('stdin EOF -> the probe exits 0 within ~250 ms with "debug: stdin closed; exiting"', async () => {
    const debug = [];
    const probe = new ModalProbe({ pid: process.pid, intervalSec: 60, onDebug: (m) => debug.push(m) });
    probe.start();
    assert.ok(await waitFor(() => debug.some((d) => /watching pid/.test(d)), 20000), 'probe started');
    const closed = new Promise((r) => probe.child.once('close', r));
    const t0 = Date.now();
    probe.child.stdin.end();
    const code = await closed;
    const elapsed = Date.now() - t0;
    assert.equal(code, 0);
    assert.ok(debug.some((d) => /debug: stdin closed; exiting/.test(d)), JSON.stringify(debug));
    assert.ok(elapsed < 1500, `exited ${elapsed} ms after EOF`);
  });

  // End-to-end property. On Windows libuv also puts spawned children in a kill-on-close job, so
  // this passes through either mechanism; the stdin watch itself is covered by the test above.
  test('orphan protection: the probe exits when its parent dies, well before any scan', async () => {
    const parent = spawn(process.execPath, [PROBE_PARENT, String(process.pid)], { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
    const parentErr = [];
    readline.createInterface({ input: parent.stderr }).on('line', (l) => parentErr.push(l));
    const probePid = await new Promise((resolve, reject) => {
      const t = setTimeout(() => reject(new Error(`no probe-pid line (stderr: ${parentErr.join(' | ')})`)), 20000);
      readline.createInterface({ input: parent.stdout }).on('line', (l) => {
        const m = /^probe-pid (\d+)$/.exec(l);
        if (m) {
          clearTimeout(t);
          resolve(Number(m[1]));
        }
      });
    });
    assert.equal(alive(probePid), true, 'probe running before the parent is killed');
    // TerminateProcess of the helper only (no /T): the probe is NOT killed directly.
    parent.kill();
    const dead = await waitFor(() => !alive(probePid), 3000);
    if (!dead) {
      try {
        process.kill(probePid);
      } catch {
        /* ignore */
      }
    }
    assert.ok(dead, `probe pid ${probePid} exited within 3 s of its parent`);
  });

  describe('against a WinForms window titled like XAE (host-window.ps1)', () => {
    const hosts = [];
    after(() => {
      for (const h of hosts) {
        try {
          process.kill(h.pid);
        } catch {
          /* already gone */
        }
      }
    });

    /** Start the fixture and resolve once it printed `waitLine`. */
    async function startHost(args, waitLine, script = HOST_WINDOW) {
      const child = spawn(defaultPowershellPath(), ['-NoProfile', '-NonInteractive', '-STA', '-ExecutionPolicy', 'Bypass', '-File', script, ...args, '-LifetimeSec', '60'], {
        stdio: ['ignore', 'pipe', 'pipe'],
        windowsHide: true
      });
      hosts.push(child);
      await new Promise((resolve, reject) => {
        const t = setTimeout(() => reject(new Error(`host-window did not print '${waitLine}'`)), 20000);
        readline.createInterface({ input: child.stdout }).on('line', (l) => {
          if (l.trim() === waitLine) {
            clearTimeout(t);
            resolve();
          }
        });
      });
      return child;
    }

    function watch(pid) {
      const dialogs = [];
      const debug = [];
      const errors = [];
      const probe = new ModalProbe({ pid, intervalSec: 1, scanScript: DEFAULT_SCAN_SCRIPT, onDialog: (d) => dialogs.push(d), onDebug: (m) => debug.push(m), onError: (m) => errors.push(m) });
      probe.start();
      return { probe, dialogs, debug, errors };
    }

    test('main window only (enabled, excluded by title) -> no report within 3 s', async () => {
      const host = await startHost([], 'ready');
      const { probe, dialogs, debug, errors } = watch(host.pid);
      await new Promise((r) => setTimeout(r, 3000));
      assert.deepEqual(dialogs, []);
      assert.equal(probe.running, true, JSON.stringify({ debug, errors }));
      probe.stop();
      host.kill();
    });

    test('MessageBox owned by the form (form disabled) -> reported: TwinCAT PLC Control, mainWindowBlocked true, win32-dialog', async () => {
      const host = await startHost(['-ShowMessageBox'], 'dialog');
      const t0 = Date.now();
      const { probe, dialogs, debug, errors } = watch(host.pid);
      const seen = await waitFor(() => dialogs.length > 0, 8000);
      const elapsed = Date.now() - t0;
      probe.stop();
      host.kill();
      assert.ok(seen, `reported (debug: ${JSON.stringify(debug)}, errors: ${JSON.stringify(errors)})`);
      assert.equal(dialogs.length, 1);
      assert.equal(dialogs[0].title, 'TwinCAT PLC Control');
      assert.equal(dialogs[0].mainWindowBlocked, true);
      assert.equal(dialogs[0].reason, 'win32-dialog');
      assert.equal(dialogs[0].className, '#32770');
      assert.equal(dialogs[0].processId, host.pid);
      assert.ok(debug.some((d) => /seen \(1\/2\)/.test(d)), 'confirmation took two scans');
      assert.ok(elapsed < 8000, `took ${elapsed} ms`);
    });

    /** Run fixtures/dialog-answer.ps1 (module Get-TcIdeModalDialog / Close-TcMessageBox) and parse its JSON line. */
    function dialogAnswer(args) {
      return new Promise((resolve, reject) => {
        const child = spawn(defaultPowershellPath(), ['-NoProfile', '-NonInteractive', '-STA', '-ExecutionPolicy', 'Bypass', '-File', DIALOG_ANSWER, '-ModulePath', MODULE_PATH, ...args], {
          stdio: ['ignore', 'pipe', 'pipe'],
          windowsHide: true
        });
        let out = '';
        let err = '';
        child.stdout.on('data', (d) => (out += d));
        child.stderr.on('data', (d) => (err += d));
        const t = setTimeout(() => (child.kill(), reject(new Error(`dialog-answer.ps1 timed out (stderr: ${err})`))), 60000);
        child.on('close', (code) => {
          clearTimeout(t);
          const line = out.split(/\r?\n/).find((l) => l.startsWith('{'));
          if (code !== 0 || !line) return reject(new Error(`dialog-answer.ps1 exit ${code}: ${out} ${err}`));
          resolve(JSON.parse(line));
        });
      });
    }

    test('module Get-TcModalDialogKind / Get-TcReloadTarget: TcPOU prompt -> reload-prompt/file, plcproj prompt -> reload-prompt/project, other -> unknown/null', async () => {
      const r = await dialogAnswer(['-Classify']);
      assert.deepEqual(r, {
        file: { kind: 'reload-prompt', reloadTarget: 'file' },
        project: { kind: 'reload-prompt', reloadTarget: 'project' },
        other: { kind: 'unknown', reloadTarget: null }
      });
    });

    test('plcproj reload prompt (YesNo #32770): module scan -> reload-prompt/project with buttons 6/7; Close-TcMessageBox -Answer Yes clicks IDYES by control id', async () => {
      const text = String.raw`The project file 'C:\p\plc\plc.plcproj' has been modified outside of TwinCAT XAE.  Do you want to reload the project?`;
      const host = await startHost(['-ShowMessageBox', '-YesNo', '-MessageTitle', 'TwinCAT XAE', '-MessageText', text], 'dialog');
      const hostLines = [];
      readline.createInterface({ input: host.stdout }).on('line', (l) => hostLines.push(l.trim()));
      try {
        await new Promise((r) => setTimeout(r, 500));
        const r = await dialogAnswer(['-ProcessId', String(host.pid), '-Answer', 'Yes']);
        assert.ok(r.dialog, JSON.stringify(r));
        assert.equal(r.dialog.kind, 'reload-prompt');
        assert.equal(r.dialog.reloadTarget, 'project');
        assert.equal(r.dialog.title, 'TwinCAT XAE');
        assert.ok(r.dialog.text.includes(String.raw`C:\p\plc\plc.plcproj`), `path kept in the text: ${r.dialog.text}`);
        assert.deepEqual(r.dialog.buttons.map((b) => b.id).sort(), [6, 7], 'IDYES / IDNO by control id');
        assert.equal(r.send.sent, true, JSON.stringify(r.send));
        assert.equal(r.send.controlId, 6);
        assert.ok(await waitFor(() => hostLines.includes('result Yes'), 5000), `host answered Yes (host: ${JSON.stringify(hostLines)})`);
      } finally {
        host.kill();
      }
    });

    // VS2022 WPF message box (AutomationId Microsoft.VisualStudio.MessageBox, TextBox 'Text',
    // Button 'OKButton', no Win32 control ids), as measured on XAE 4026.22 in VS2022.
    for (const zeroHwnd of [false, true]) {
      test(`VS2022 WPF message box: module scan reads title/text/buttons; Close-TcMessageBox -Answer Ok answers via UIA_INVOKE${zeroHwnd ? ' (hwnd 0: found by AutomationId)' : ''}`, async () => {
        const host = await startHost(['-VsMessageBox'], 'dialog', HOST_WINDOW_WPF);
        const hostLines = [];
        readline.createInterface({ input: host.stdout }).on('line', (l) => hostLines.push(l.trim()));
        try {
          await new Promise((r) => setTimeout(r, 500));
          const args = ['-ProcessId', String(host.pid), '-Answer', 'Ok'];
          if (zeroHwnd) args.push('-ZeroHwnd');
          const r = await dialogAnswer(args);
          assert.ok(r.dialog, JSON.stringify(r));
          assert.equal(r.dialog.title, 'Microsoft Visual Studio');
          assert.match(r.dialog.text, /^Active solution platform 'TwinCAT RT \(x64\)' differs from current target platform 'TwinCAT OS \(x64\)'/);
          assert.equal(r.dialog.kind, 'unknown');
          assert.ok(r.dialog.hwnd > 0, 'native handle of the WPF window');
          assert.deepEqual(r.dialog.buttons, [{ id: 0, name: 'OK', automationId: 'OKButton' }]);
          assert.equal(r.send.sent, true, JSON.stringify(r.send));
          assert.equal(r.send.method, 'UIA_INVOKE');
          assert.ok(await waitFor(() => hostLines.includes('result Ok'), 5000), `host answered Ok (host: ${JSON.stringify(hostLines)})`);
        } finally {
          host.kill();
        }
      });
    }

    // The XAE main window is WPF: behind a modal its IsEnabled stays true and only
    // WindowInteractionState says BlockedByModalWindow. The WPF fixture reproduces that.
    test('WPF main window only -> no report within 3 s', async () => {
      const host = await startHost([], 'ready', HOST_WINDOW_WPF);
      const { probe, dialogs, debug, errors } = watch(host.pid);
      await new Promise((r) => setTimeout(r, 3000));
      assert.deepEqual(dialogs, []);
      assert.equal(probe.running, true, JSON.stringify({ debug, errors }));
      probe.stop();
      host.kill();
    });

    test('WPF modal owned by a WPF main window (owner IsEnabled stays true, state Running) -> reported via the owned modal child: modal, mainWindowBlocked true, caption as title', async () => {
      const host = await startHost(['-ShowModal'], 'dialog', HOST_WINDOW_WPF);
      const t0 = Date.now();
      const { probe, dialogs, debug, errors } = watch(host.pid);
      const seen = await waitFor(() => dialogs.length > 0, 8000);
      const elapsed = Date.now() - t0;
      probe.stop();
      host.kill();
      assert.ok(seen, `reported (debug: ${JSON.stringify(debug)}, errors: ${JSON.stringify(errors)})`);
      assert.equal(dialogs.length, 1);
      assert.equal(dialogs[0].title, 'TwinCAT PLC Control');
      assert.equal(dialogs[0].mainWindowBlocked, true);
      assert.equal(dialogs[0].isModal, true);
      assert.equal(dialogs[0].reason, 'modal');
      assert.equal(dialogs[0].processId, host.pid);
      assert.match(dialogs[0].text, /Internal error in the PLC compiler \(probe test, WPF\)/, 'WPF UIA Name (content text) becomes the text');
      assert.ok(elapsed < 8000, `took ${elapsed} ms`);
    });
  });
});

describe('PowerShellBridge.abortCall', () => {
  const bridges = [];
  after(async () => {
    for (const b of bridges) await b.stop();
  });
  function makeBridge() {
    const b = new PowerShellBridge({ spawnSpec: { command: process.execPath, args: [MOCK_BRIDGE] } });
    bridges.push(b);
    return b;
  }

  test("in-flight call -> 'killed': caller's result delivered, queued call BRIDGE_DIED not executed, child exits", async () => {
    const bridge = makeBridge();
    await bridge.start();
    const childPid = bridge.pid;
    const exited = bridge.lastChildExit();
    const token = {};
    const hung = bridge.call('call', { cmdlet: 'Build-TcProject', params: { Hang: true }, timeoutMs: 60000, token });
    const queued = bridge.call('call', { cmdlet: 'Get-TcPlcState', timeoutMs: 60000 });
    await new Promise((r) => setTimeout(r, 100));
    const mine = errorResult('IDE_MODAL_DIALOG', 'Assertion Failed');
    const seen = [];
    const outcome = bridge.abortCall(token, (o) => (seen.push(o), mine), "Build-TcProject is blocked by the IDE modal dialog 'Assertion Failed'");
    assert.equal(outcome, 'killed');
    assert.deepEqual(seen, ['killed']);
    const killed = await hung;
    assert.deepEqual(killed.error, mine.error);
    assert.equal(killed.success, false);
    assert.equal(killed.data.seq, 1, 'killed call still carries its execution order');
    assert.ok(Date.parse(killed.data.finishedAt) >= Date.parse(killed.data.startedAt));
    const q = await queued;
    assert.equal(q.error.code, 'BRIDGE_DIED');
    assert.match(q.error.message, /killed because Build-TcProject is blocked by the IDE modal dialog 'Assertion Failed'; this call was not executed/);
    assert.equal(bridge.isRunning, false);
    await exited;
    assert.ok(await waitFor(() => !alive(childPid), 2000));
    assert.equal(bridge.abortCall(token, mine, 'again'), null, 'already settled');
    const again = await bridge.call('ping');
    assert.equal(again.success, true, 'bridge restarts lazily');
  });

  test("queued call -> 'dequeued': no kill, the in-flight call still completes", async () => {
    const bridge = makeBridge();
    await bridge.start();
    const childPid = bridge.pid;
    const first = bridge.call('call', { cmdlet: 'Build-TcProject', params: { DelayMs: 300 }, timeoutMs: 60000 });
    const token = {};
    const second = bridge.call('call', { cmdlet: 'Enable-TcConfig', timeoutMs: 60000, token });
    const mine = { success: false, error: { code: 'IDE_MODAL_DIALOG', message: 'x' } };
    assert.equal(bridge.abortCall(token, mine, 'r'), 'dequeued');
    assert.equal(await second, mine);
    const r1 = await first;
    assert.equal(r1.success, true);
    assert.equal(bridge.isRunning, true);
    assert.equal(bridge.pid, childPid, 'same child');
  });

  test('unknown token -> null, nothing happens', async () => {
    const bridge = makeBridge();
    await bridge.start();
    assert.equal(bridge.abortCall({}, errorResult('X', 'y'), 'r'), null);
    assert.equal(bridge.abortCall(undefined, errorResult('X', 'y'), 'r'), null);
    assert.equal(bridge.isRunning, true);
  });
});
