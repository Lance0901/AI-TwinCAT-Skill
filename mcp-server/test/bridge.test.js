import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { PowerShellBridge, errorResult, HINTS, CANCELLED_MESSAGE, stampOrder } from '../lib/bridge.js';
import { MAX_CALL_TIMEOUT_MS } from '../lib/config.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const MOCK = path.join(__dirname, 'fixtures', 'mock-bridge.js');

function makeBridge(extra = {}) {
  const logs = [];
  const stderr = [];
  const bridge = new PowerShellBridge({
    spawnSpec: { command: process.execPath, args: [MOCK] },
    onLog: (level, message, meta) => logs.push({ level, message, meta }),
    onStderr: (line) => stderr.push(line),
    ...extra
  });
  return { bridge, logs, stderr };
}

function alive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

const bridges = [];
after(async () => {
  for (const b of bridges) await b.stop();
});

describe('PowerShellBridge', () => {
  test('default spawn spec targets powershell.exe with the protocol arguments', () => {
    const b = new PowerShellBridge({ powershellPath: 'P:\\ps.exe', bridgeScript: 'B:\\bridge.ps1', modulePath: 'M:\\mod.psm1' });
    const spec = b.buildSpawnSpec();
    assert.equal(spec.command, 'P:\\ps.exe');
    assert.deepEqual(spec.args, [
      '-NoProfile', '-NonInteractive', '-STA', '-ExecutionPolicy', 'Bypass',
      '-File', 'B:\\bridge.ps1', '-ModulePath', 'M:\\mod.psm1'
    ]);
    const def = new PowerShellBridge();
    assert.match(def.powershellPath, /powershell\.exe$/i);
    assert.match(def.modulePath, /TwinCATAutomation\.psm1$/);
    assert.match(def.bridgeScript, /bridge[\\/]bridge\.ps1$/);
  });

  test('errorResult helper', () => {
    assert.deepEqual(errorResult('X', 'm'), { success: false, error: { code: 'X', message: 'm' } });
    assert.deepEqual(errorResult('X', 'm', 'h'), { success: false, error: { code: 'X', message: 'm', hint: 'h' } });
  });

  test('ready handshake and ping', async () => {
    const { bridge } = makeBridge();
    bridges.push(bridge);
    const ready = await bridge.start();
    assert.equal(ready.ok, true);
    assert.ok(ready.cmdlets.includes('Connect-TcIde'));
    assert.equal(bridge.isRunning, true);
    const pong = await bridge.call('ping');
    assert.deepEqual(pong, { success: true, data: { pong: true } });
    assert.equal('id' in pong, false);
    assert.equal('event' in pong, false);
  });

  test('lazy start on first call, log lines arriving with ready are not lost', async () => {
    const { bridge, logs } = makeBridge({ env: { MOCK_BRIDGE_EARLY_LOG: '1' } });
    bridges.push(bridge);
    assert.equal(bridge.isRunning, false);
    const state = await bridge.call('state');
    assert.equal(state.success, true);
    assert.equal(state.data.ideConnected, false);
    assert.ok(logs.some((l) => l.message === 'early log after ready'));
  });

  test('eager start: a call made right after start() (not awaited) is dispatched once the child is ready', async () => {
    const { bridge } = makeBridge();
    bridges.push(bridge);
    const starting = bridge.start();
    assert.equal(bridge.isRunning, false);
    const t0 = Date.now();
    const pong = await Promise.race([
      bridge.call('ping'),
      new Promise((resolve) => setTimeout(() => resolve({ success: false, error: { code: 'TEST_TIMEOUT' } }), 2000))
    ]);
    assert.equal(pong.success, true, `call after eager start answered in ${Date.now() - t0} ms: ${JSON.stringify(pong)}`);
    assert.equal(pong.data.pong, true);
    await starting;
  });

  test('eager start failure: calls queued while starting resolve MODULE_IMPORT_FAILED', async () => {
    const { bridge } = makeBridge({ env: { MOCK_BRIDGE_READY_FAIL: '1' } });
    const starting = bridge.start();
    const queued = bridge.call('ping');
    await assert.rejects(starting, (err) => err.code === 'MODULE_IMPORT_FAILED');
    const r = await queued;
    assert.equal(r.success, false);
    assert.equal(r.error.code, 'MODULE_IMPORT_FAILED');
    assert.equal(r.error.message, 'mock import failure');
    assert.equal(r.error.hint, 'fix the module path');
  });

  test('ready ok:false -> start() throws MODULE_IMPORT_FAILED with the child error', async () => {
    const { bridge } = makeBridge({ env: { MOCK_BRIDGE_READY_FAIL: '1' } });
    await assert.rejects(bridge.start(), (err) => {
      assert.equal(err.code, 'MODULE_IMPORT_FAILED');
      assert.equal(err.message, 'mock import failure');
      assert.equal(err.hint, 'fix the module path');
      return true;
    });
    assert.equal(bridge.isRunning, false);
    // call() never rejects: it resolves to the import error
    const r = await bridge.call('ping');
    assert.equal(r.success, false);
    assert.equal(r.error.code, 'MODULE_IMPORT_FAILED');
  });

  test('call results carry seq/startedAt/finishedAt in strict serial order', async () => {
    const { bridge } = makeBridge();
    bridges.push(bridge);
    const results = await Promise.all([
      bridge.call('call', { cmdlet: 'Get-TcPlcState', params: { DelayMs: 150 } }),
      bridge.call('call', { cmdlet: 'Get-TcPlcState', params: {} }),
      bridge.call('call', { cmdlet: 'Get-TcPlcState', params: {} })
    ]);
    const d = results.map((r) => r.data);
    for (const x of d) {
      assert.ok(Number.isInteger(x.seq) && x.seq > 0);
      assert.ok(Date.parse(x.finishedAt) >= Date.parse(x.startedAt));
    }
    assert.equal(d[1].seq, d[0].seq + 1);
    assert.equal(d[2].seq, d[1].seq + 1);
    for (let i = 0; i < 2; i++) {
      assert.ok(Date.parse(d[i + 1].startedAt) >= Date.parse(d[i].finishedAt), `call ${i + 1} started after call ${i} finished`);
    }
    assert.ok(Date.parse(d[0].finishedAt) - Date.parse(d[0].startedAt) >= 100, 'first call took the DelayMs');
    assert.equal(d[0].state, 'Run', 'original data kept');
    const ping = await bridge.call('ping');
    assert.deepEqual(ping, { success: true, data: { pong: true } });
  });

  test('FIFO: two calls are answered in order, one at a time', async () => {
    const { bridge } = makeBridge();
    bridges.push(bridge);
    const order = [];
    const p1 = bridge.call('call', { cmdlet: 'Build-TcProject', params: { DelayMs: 300 }, timeoutMs: 5000 }).then((r) => {
      order.push('build');
      return r;
    });
    const p2 = bridge.call('ping').then((r) => {
      order.push('ping');
      return r;
    });
    const [r1, r2] = await Promise.all([p1, p2]);
    assert.deepEqual(order, ['build', 'ping']);
    assert.equal(r1.success, true);
    assert.equal(r1.data.params.DelayMs, 300);
    assert.equal(r2.data.pong, true);
  });

  test('log lines trigger onLog with id and cmdlet, result carries hint', async () => {
    const { bridge, logs } = makeBridge();
    bridges.push(bridge);
    const r = await bridge.call('call', { cmdlet: 'Get-TcIdeInfo', params: {}, timeoutMs: 5000 });
    assert.equal(r.success, false);
    assert.equal(r.error.code, 'NOT_CONNECTED');
    assert.equal(r.error.hint, 'Run Connect-TcIde first');
    const warn = logs.find((l) => l.level === 'warning');
    assert.ok(warn, 'warning log forwarded');
    assert.equal(warn.message, 'mock: IDE not connected');
    assert.equal(warn.meta.cmdlet, 'Get-TcIdeInfo');
    assert.equal(typeof warn.meta.id, 'string');
  });

  test('unknown cmdlet -> INVALID_CMDLET from the child', async () => {
    const { bridge } = makeBridge();
    bridges.push(bridge);
    const r = await bridge.call('call', { cmdlet: 'Remove-Item', params: {}, timeoutMs: 5000 });
    assert.equal(r.error.code, 'INVALID_CMDLET');
  });

  test('timeout -> BRIDGE_TIMEOUT, child killed, queued call BRIDGE_DIED, next call restarts', async () => {
    const { bridge } = makeBridge();
    bridges.push(bridge);
    await bridge.start();
    const pid = bridge.pid;
    assert.ok(alive(pid));

    const hang = bridge.call('call', { cmdlet: 'Build-TcProject', params: { Hang: true }, timeoutMs: 300 });
    const queued = bridge.call('ping');
    const r = await hang;
    assert.equal(r.success, false);
    assert.equal(r.error.code, 'BRIDGE_TIMEOUT');
    assert.equal(r.error.hint, HINTS.BRIDGE_TIMEOUT);
    const q = await queued;
    assert.equal(q.error.code, 'BRIDGE_DIED');
    assert.match(q.error.message, /Build-TcProject timed out; this call was not executed; safe to retry after reconnecting/);

    await bridge.lastChildExit();
    assert.equal(alive(pid), false, 'hung child was killed');
    assert.equal(bridge.isRunning, false);

    const again = await bridge.call('ping');
    assert.equal(again.success, true, 'auto restart after timeout');
    assert.notEqual(bridge.pid, pid);
  });

  test('child crash mid-call -> BRIDGE_DIED, then auto restart; state is fresh', async () => {
    const { bridge } = makeBridge();
    bridges.push(bridge);
    const connected = await bridge.call('call', { cmdlet: 'Connect-TcIde', params: {}, timeoutMs: 5000 });
    assert.equal(connected.success, true);
    assert.equal((await bridge.call('state')).data.ideConnected, true);

    const r = await bridge.call('call', { cmdlet: 'Build-TcProject', params: { Crash: true }, timeoutMs: 5000 });
    assert.equal(r.success, false);
    assert.equal(r.error.code, 'BRIDGE_DIED');
    assert.equal(r.error.hint, HINTS.BRIDGE_DIED);
    assert.equal(bridge.isRunning, false);

    const state = await bridge.call('state');
    assert.equal(state.success, true);
    assert.equal(state.data.ideConnected, false, 'new child has fresh state');
  });

  test('stop() shuts the child down cleanly and is idempotent', async () => {
    const { bridge } = makeBridge();
    await bridge.start();
    const pid = bridge.pid;
    const exit = bridge.lastChildExit();
    await bridge.stop();
    const { code } = await exit;
    assert.equal(code, 0, 'child exited via shutdown op');
    assert.equal(alive(pid), false);
    assert.equal(bridge.isRunning, false);
    await bridge.stop(); // no-op
  });

  test('calls arriving while stop() is in flight get BRIDGE_DIED (not executed); after stop() the next call restarts', async () => {
    const { bridge } = makeBridge();
    bridges.push(bridge);
    await bridge.start();
    const pid = bridge.pid;
    const stopping = bridge.stop();
    const during = await bridge.call('ping');
    assert.equal(during.error.code, 'BRIDGE_DIED');
    assert.match(during.error.message, /bridge is stopping; this call was not executed; safe to retry after reconnecting/);
    await stopping;
    assert.equal(bridge.isRunning, false);
    const after = await bridge.call('ping');
    assert.equal(after.success, true, 'lazy restart after stop()');
    assert.notEqual(bridge.pid, pid);
  });

  test('result line with id:null (bridge could not parse the request) finishes the call in flight', async () => {
    const { bridge, stderr } = makeBridge();
    bridges.push(bridge);
    await bridge.start();
    // The mock never answers Hang; a garbage line pushed into its stdin makes it reply id:null,
    // exactly like bridge.ps1 does for a request line it cannot parse.
    const hang = bridge.call('call', { cmdlet: 'Build-TcProject', params: { Hang: true }, timeoutMs: 10000 });
    await new Promise((r) => setTimeout(r, 100));
    bridge.child.stdin.write('this is not json\n');
    const r = await hang;
    assert.equal(r.success, false);
    assert.equal(r.error.code, 'INVALID_REQUEST');
    assert.ok(stderr.some((l) => /result without id attributed to request/.test(l)));
    assert.equal(bridge.isRunning, true, 'child not killed');
    assert.equal((await bridge.call('ping')).success, true);
  });

  test('result with id:null while nothing is in flight is only reported', async () => {
    const { bridge, stderr } = makeBridge();
    bridges.push(bridge);
    await bridge.start();
    bridge._onLine(JSON.stringify({ id: null, event: 'result', success: false, error: { code: 'INVALID_REQUEST', message: 'x' } }));
    assert.ok(stderr.some((l) => /result for unknown request id null/.test(l)));
    assert.equal((await bridge.call('ping')).success, true);
  });

  test('AbortSignal: queued call is removed and resolves CANCELLED; the in-flight call is not interrupted', async () => {
    const { bridge } = makeBridge();
    bridges.push(bridge);
    await bridge.start();
    const inFlightAc = new AbortController();
    const queuedAc = new AbortController();
    const inFlight = bridge.call('call', { cmdlet: 'Build-TcProject', params: { DelayMs: 400 }, timeoutMs: 5000, signal: inFlightAc.signal });
    const queued = bridge.call('ping', { signal: queuedAc.signal });
    const untouched = bridge.call('state');
    await new Promise((r) => setTimeout(r, 50));
    inFlightAc.abort(); // already sent to the child: ignored
    queuedAc.abort(); // still in the queue: dropped
    const t0 = Date.now();
    const q = await queued;
    assert.ok(Date.now() - t0 < 100, 'cancelled immediately, not after the in-flight call');
    assert.deepEqual(q, { success: false, error: { code: 'CANCELLED', message: CANCELLED_MESSAGE } });
    const r = await inFlight;
    assert.equal(r.success, true, 'abort after dispatch does not change the result');
    assert.equal(r.data.params.DelayMs, 400);
    assert.equal((await untouched).success, true, 'other queued calls are unaffected');
    assert.equal(bridge._queue.length, 0);
  });

  test('AbortSignal already aborted -> CANCELLED without touching the queue', async () => {
    const { bridge } = makeBridge();
    bridges.push(bridge);
    const ac = new AbortController();
    ac.abort();
    const r = await bridge.call('ping', { signal: ac.signal });
    assert.equal(r.error.code, 'CANCELLED');
    assert.equal(bridge.isRunning, false, 'no child was started for a pre-cancelled call');
  });

  test('timeoutMs above the cap is clamped instead of overflowing setTimeout', async () => {
    const { bridge } = makeBridge();
    bridges.push(bridge);
    // 99999999 s as TimeoutSec would be ~1e11 ms: beyond 2^31-1 setTimeout fires immediately
    const r = await bridge.call('call', { cmdlet: 'Build-TcProject', params: { DelayMs: 200 }, timeoutMs: 99999999 * 1000 + 30000 });
    assert.equal(r.success, true, JSON.stringify(r));
    assert.ok(MAX_CALL_TIMEOUT_MS <= 2147483647);
  });

  test('non-JSON stdout line goes to onStderr without crashing', async () => {
    const { bridge, stderr } = makeBridge();
    bridges.push(bridge);
    await bridge.start();
    bridge._onLine('this is not json');
    assert.ok(stderr.some((l) => /non-JSON stdout line/.test(l)));
    assert.equal((await bridge.call('ping')).success, true);
  });
});

// #57: stampOrder must never drop data that is not a plain object.
describe('stampOrder (execution order on a result)', () => {
  const item = { seq: 7, startedAt: '2026-10-26T00:00:00.000Z' };
  const check = (r) => {
    assert.equal(r.order.seq, 7);
    assert.equal(r.order.startedAt, item.startedAt);
    assert.ok(!Number.isNaN(Date.parse(r.order.finishedAt)));
  };

  test('array data is kept element for element (GetSymbols / multi-path ReadVariable)', () => {
    const data = [{ path: 'MAIN.a', value: 1 }, { path: 'MAIN.b', error: 'not found', code: 'SYMBOL_NOT_FOUND' }];
    const r = stampOrder(item, { success: true, data });
    assert.ok(Array.isArray(r.data));
    assert.deepEqual(r.data, data);
    check(r);
  });

  test('empty array, scalar and null data are kept as they are', () => {
    for (const data of [[], 0, 42, 'text', false, true, null]) {
      const r = stampOrder(item, { success: true, data });
      assert.deepEqual(r.data, data, `data ${JSON.stringify(data)} kept`);
      check(r);
    }
  });

  test('object data gets seq/startedAt/finishedAt merged in as before, plus order', () => {
    const r = stampOrder(item, { success: true, data: { state: 'Run' } });
    assert.equal(r.data.state, 'Run');
    assert.equal(r.data.seq, 7);
    assert.equal(r.data.startedAt, item.startedAt);
    assert.equal(r.data.finishedAt, r.order.finishedAt);
    check(r);
  });

  test('a result without data (error) gets data = the order fields, as before', () => {
    const r = stampOrder(item, { success: false, error: { code: 'X', message: 'm' } });
    assert.equal(r.data.seq, 7);
    assert.equal(r.error.code, 'X');
    check(r);
  });

  test('the input result is not mutated', () => {
    const input = { success: true, data: { a: 1 } };
    stampOrder(item, input);
    assert.deepEqual(input, { success: true, data: { a: 1 } });
  });
});
