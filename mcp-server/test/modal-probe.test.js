// Unit tests: lib/modal-probe.js with the mock probe, the real bridge/modal-probe.ps1 (win32 only),
// and PowerShellBridge.abortCall with the mock bridge.
import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { ModalProbe, PROBED_TOOLS, buildProbeSpawnSpec, DEFAULT_PROBE_SCRIPT, DEFAULT_PROBE_INTERVAL_SEC } from '../lib/modal-probe.js';
import { PowerShellBridge, errorResult } from '../lib/bridge.js';
import { loadConfig, defaultPowershellPath } from '../lib/config.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const MOCK_PROBE = path.join(__dirname, 'fixtures', 'mock-modal-probe.js');
const MOCK_BRIDGE = path.join(__dirname, 'fixtures', 'mock-bridge.js');
const REAL_PROBE = path.join(__dirname, '..', 'bridge', 'modal-probe.ps1');
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
    const def = buildProbeSpawnSpec({ powershellPath: 'P:\\ps.exe', probeScript: 'B:\\probe.ps1', pid: 1234, intervalSec: 5 });
    assert.deepEqual(def, {
      command: 'P:\\ps.exe',
      args: ['-NoProfile', '-NonInteractive', '-STA', '-ExecutionPolicy', 'Bypass', '-File', 'B:\\probe.ps1', '-ProcessId', '1234', '-IntervalSec', '5']
    });
    const ovr = buildProbeSpawnSpec({ powershellPath: 'P:\\ps.exe', spawnSpec: { command: 'node', args: ['mock.js'] }, pid: 7, intervalSec: 2 });
    assert.deepEqual(ovr, { command: 'node', args: ['mock.js', '-ProcessId', '7', '-IntervalSec', '2'] });
    const fallback = buildProbeSpawnSpec({ pid: 9 });
    assert.equal(fallback.command, defaultPowershellPath());
    assert.ok(fallback.args.includes(DEFAULT_PROBE_SCRIPT));
    assert.deepEqual(fallback.args.slice(-4), ['-ProcessId', '9', '-IntervalSec', '5']);
  });

  test('config: probe on by default, off with 0/false/off, interval clamped, test spawn override', () => {
    const def = loadConfig({});
    assert.equal(def.modalProbe.enabled, true);
    assert.equal(def.modalProbe.intervalSec, 5);
    assert.equal(def.modalProbe.spawnSpec, null);
    assert.equal(def.modalProbe.probeScript, DEFAULT_PROBE_SCRIPT);
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

  test('dialog line -> onDialog exactly once with the parsed fields, probe exits', async () => {
    const { probe, dialogs, errors, exited } = mockProbe(JSON.stringify({ title: 'Assertion Failed', text: 'boom' }));
    assert.equal(probe.running, true);
    assert.ok(Number.isInteger(probe.pid));
    await exited;
    await waitFor(() => dialogs.length > 0, 1000);
    assert.equal(dialogs.length, 1);
    assert.deepEqual(dialogs[0], { title: 'Assertion Failed', text: 'boom', className: '#32770', isModal: true, processId: 4242 });
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
    assert.equal(await hung, mine);
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
