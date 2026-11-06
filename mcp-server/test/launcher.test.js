// #162 launcher (launcher/tcauto-launcher.mjs) with mock runtimes (fixtures/mock-runtime-server.mjs):
// forwarding, ReloadRuntime (retire, initialize replay, list_changed), requests during a reload,
// refusal while a tools/call runs, a retire the runtime refuses, a runtime that dies, a new
// runtime that does not start (restore), a missing current.json.
// Everything lives in its own temp install root (name contains 162); at most one runtime child
// runs at a time (the old one has exited before the new one starts).
import { test, describe, before, after, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { PassThrough } from 'node:stream';
import { fileURLToPath } from 'node:url';
import { Launcher, readCurrent, resolveInstallRoot, RELOAD_TOOL, VERSION_RE } from '../launcher/tcauto-launcher.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const MOCK_RUNTIME = path.join(__dirname, 'fixtures', 'mock-runtime-server.mjs');
const SHA_A = 'aaaaaaaaaaaa' + 'a'.repeat(28);
const SHA_B = 'bbbbbbbbbbbb' + 'b'.repeat(28);
const VER_A = SHA_A.slice(0, 12);
const VER_B = SHA_B.slice(0, 12);

const roots = [];
const junctions = [];
after(() => {
  // the node_modules junctions first, so removing a root can never reach the real node_modules
  for (const j of junctions) {
    try {
      fs.unlinkSync(j);
    } catch {
      try {
        fs.rmdirSync(j); // a directory junction: removes the link, never the target
      } catch {
        /* already gone */
      }
    }
  }
  for (const d of roots) {
    try {
      fs.rmSync(d, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
    } catch {
      /* temp */
    }
  }
});

function newRoot() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'tcauto-launcher162-'));
  roots.push(root);
  fs.mkdirSync(path.join(root, 'runtime'), { recursive: true });
  return root;
}

function installMock(root, version, commit, behavior = {}) {
  const dir = path.join(root, 'runtime', version);
  fs.mkdirSync(path.join(dir, 'mcp-server'), { recursive: true });
  fs.copyFileSync(MOCK_RUNTIME, path.join(dir, 'mcp-server', 'index.js'));
  fs.writeFileSync(path.join(dir, 'mcp-server', 'package.json'), JSON.stringify({ type: 'module' }));
  fs.writeFileSync(path.join(dir, 'tcauto-source.json'), JSON.stringify({ commit, dirty: false, version }));
  fs.writeFileSync(path.join(dir, 'behavior.json'), JSON.stringify(behavior));
  return dir;
}

function setCurrent(root, version, commit) {
  fs.writeFileSync(path.join(root, 'runtime', 'current.json'), JSON.stringify({ schema: 1, version, commit, dirty: false }));
}

function received(root, version) {
  const f = path.join(root, 'runtime', version, 'received.jsonl');
  if (!fs.existsSync(f)) return [];
  return fs.readFileSync(f, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
}

/** In-process launcher + a tiny JSON-RPC client over PassThrough streams. */
function harness(root, opts = {}) {
  const input = new PassThrough();
  const output = new PassThrough();
  const stderr = new PassThrough();
  const errText = [];
  stderr.on('data', (d) => errText.push(String(d)));
  const launcher = new Launcher({ input, output, stderr, installRoot: root, env: opts.env, initTimeoutMs: 10000, retireTimeoutMs: opts.retireTimeoutMs ?? 10000, exitTimeoutMs: 5000 }).start();
  const waiters = new Map();
  const notifications = [];
  let buf = '';
  output.setEncoding('utf8');
  output.on('data', (chunk) => {
    buf += chunk;
    let nl;
    while ((nl = buf.indexOf('\n')) !== -1) {
      const msg = JSON.parse(buf.slice(0, nl));
      buf = buf.slice(nl + 1);
      if (msg.method) notifications.push(msg);
      else waiters.get(JSON.stringify(msg.id))?.(msg);
    }
  });
  let nextId = 1;
  const request = (method, params) =>
    new Promise((resolve, reject) => {
      const id = nextId++;
      const t = setTimeout(() => reject(new Error(`${method} not answered`)), 20000);
      waiters.set(JSON.stringify(id), (m) => {
        clearTimeout(t);
        resolve(m);
      });
      input.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
    });
  const notify = (method, params) => input.write(JSON.stringify({ jsonrpc: '2.0', method, params }) + '\n');
  const call = async (name, args = {}) => (await request('tools/call', { name, arguments: args })).result;
  const body = (r) => JSON.parse(r.content[0].text);
  const initParams = { protocolVersion: '2025-06-18', capabilities: { roots: {} }, clientInfo: { name: 'launcher-test-162', version: '1.0.0' } };
  const init = async () => {
    const r = await request('initialize', initParams);
    notify('notifications/initialized');
    return r;
  };
  return { launcher, request, notify, call, body, init, initParams, notifications, errText, close: () => launcher.close('test end') };
}

describe('readCurrent / resolveInstallRoot', () => {
  test('current.json must name a runtime folder (no path, no ..) whose mcp-server\\index.js exists', () => {
    const root = newRoot();
    assert.equal(readCurrent(root).ok, false, 'no current.json');
    installMock(root, VER_A, SHA_A);
    for (const bad of ['..', '..\\x', 'C:\\x', 'abc', `${VER_A}\\..\\x`, '']) {
      fs.writeFileSync(path.join(root, 'runtime', 'current.json'), JSON.stringify({ version: bad }));
      assert.equal(readCurrent(root).ok, false, bad);
    }
    fs.writeFileSync(path.join(root, 'runtime', 'current.json'), '{not json');
    assert.match(readCurrent(root).reason, /not valid JSON/);
    setCurrent(root, VER_B, SHA_B);
    assert.match(readCurrent(root).reason, /does not exist/, 'folder not installed');
    setCurrent(root, VER_A, SHA_A);
    const cur = readCurrent(root);
    assert.equal(cur.ok, true);
    assert.equal(cur.commit, SHA_A);
    assert.equal(cur.entry, path.join(root, 'runtime', VER_A, 'mcp-server', 'index.js'));
    assert.ok(VERSION_RE.test(`${VER_A}-dirty-20261106T101500Z`));
  });

  test('install root: TCAUTO_RUNTIME_ROOT, else the parent of the launcher folder', () => {
    assert.equal(resolveInstallRoot({ TCAUTO_RUNTIME_ROOT: 'C:\\x162' }, 'C:\\a\\launcher\\l.mjs'), path.resolve('C:\\x162'));
    assert.equal(resolveInstallRoot({}, 'C:\\a\\launcher\\l.mjs'), path.resolve('C:\\a'));
  });
});

describe('launcher with mock runtimes', () => {
  let root;
  let h;
  beforeEach(() => {
    root = newRoot();
    installMock(root, VER_A, SHA_A);
    setCurrent(root, VER_A, SHA_A);
    h = harness(root);
  });
  afterEach(async () => {
    await h.close();
  });

  test('forwards initialize (tools.listChanged added), tools/list (+ReloadRuntime), tools/call; owner id reaches the runtime', async () => {
    const init = await h.init();
    assert.equal(init.result.capabilities.tools.listChanged, true);
    assert.deepEqual(init.result.capabilities.logging, {}, 'other capabilities unchanged');
    const list = await h.request('tools/list', {});
    const names = list.result.tools.map((t) => t.name);
    assert.deepEqual(names, ['Echo', 'Slow', 'Crash', RELOAD_TOOL.name]);
    const echo = h.body(await h.call('Echo', { x: 1 }));
    assert.equal(echo.data.commit, SHA_A);
    assert.deepEqual(echo.data.args, { x: 1 });
    assert.equal(echo.data.ownerId, h.launcher.ownerId);
    assert.equal(echo.data.launcherPid, String(process.pid));
    assert.equal(echo.data.ppid, process.pid, 'the runtime is a direct child (index.js checks TCAUTO_LAUNCHER_PID == ppid)');
    const ping = await h.request('ping', {});
    assert.deepEqual(ping.result, {});
    const direct = await h.request('tcauto/retire', {});
    assert.equal(direct.error.code, -32601, 'a client cannot send the launcher-only retire');
  });

  test('ReloadRuntime: retire, new runtime, initialize replayed, list_changed, same owner id', async () => {
    await h.init();
    const before = h.body(await h.call('Echo'));
    installMock(root, VER_B, SHA_B);
    setCurrent(root, VER_B, SHA_B);
    const res = await h.call(RELOAD_TOOL.name);
    const b = h.body(res);
    assert.equal(b.success, true, JSON.stringify(b));
    assert.equal(b.data.previous.commit, SHA_A);
    assert.equal(b.data.current.commit, SHA_B);
    assert.equal(b.data.changed, true);
    assert.equal(b.data.reconnectRequired, true);
    assert.match(b.data.note, /ConnectIde/);
    assert.equal(b.data.retired.retired, true);
    assert.ok(h.notifications.some((n) => n.method === 'notifications/tools/list_changed'), 'list_changed sent');

    const gotB = received(root, VER_B);
    assert.equal(gotB[0].method, 'initialize');
    assert.deepEqual(gotB[0].params, h.initParams, 'the client initialize is replayed unchanged');
    assert.equal(gotB[1].method, 'notifications/initialized');
    assert.ok(received(root, VER_A).some((m) => m.method === 'tcauto/retire'), 'old runtime was asked to retire');

    const after = h.body(await h.call('Echo'));
    assert.equal(after.data.commit, SHA_B);
    assert.equal(after.data.ownerId, before.data.ownerId, 'owner id stable across ReloadRuntime');
    assert.notEqual(after.data.pid, before.data.pid);
    assert.throws(() => process.kill(before.data.pid, 0), 'old runtime process has exited');
  });

  test('a request that arrives while the reload runs gets RUNTIME_RELOADING at once; ping still answered', async () => {
    fs.writeFileSync(path.join(root, 'runtime', VER_A, 'behavior.json'), JSON.stringify({ retireDelayMs: 1500 }));
    await h.init();
    await h.call('Echo');
    installMock(root, VER_B, SHA_B);
    setCurrent(root, VER_B, SHA_B);
    const reload = h.call(RELOAD_TOOL.name);
    await new Promise((r) => setTimeout(r, 200));
    const t0 = Date.now();
    const during = h.body(await h.call('Echo'));
    assert.equal(during.error.code, 'RUNTIME_RELOADING');
    assert.ok(Date.now() - t0 < 1000, 'answered at once, not queued');
    const list = await h.request('tools/list', {});
    assert.match(list.error.message, /RUNTIME_RELOADING/);
    assert.deepEqual((await h.request('ping', {})).result, {});
    const second = h.body(await h.call(RELOAD_TOOL.name));
    assert.equal(second.error.code, 'RUNTIME_RELOADING');
    assert.equal(h.body(await reload).success, true);
    assert.equal(h.body(await h.call('Echo')).data.commit, SHA_B);
  });

  test('ReloadRuntime is refused while a tools/call runs; that call still completes', async () => {
    await h.init();
    installMock(root, VER_B, SHA_B);
    setCurrent(root, VER_B, SHA_B);
    const slow = h.call('Slow', { ms: 1500 });
    await new Promise((r) => setTimeout(r, 200));
    const r = h.body(await h.call(RELOAD_TOOL.name));
    assert.equal(r.error.code, 'RUNTIME_RELOAD_BUSY');
    assert.deepEqual(r.data.running, ['Slow']);
    assert.equal(h.body(await slow).data.slept, 1500);
    assert.equal(h.body(await h.call('Echo')).data.commit, SHA_A, 'nothing switched');
    assert.ok(!received(root, VER_A).some((m) => m.method === 'tcauto/retire'), 'retire never sent');
  });

  test('a retire the runtime refuses (RELOAD_LIFECYCLE_BLOCKED) changes nothing', async () => {
    fs.writeFileSync(path.join(root, 'runtime', VER_A, 'behavior.json'), JSON.stringify({ retire: 'blocked' }));
    await h.init();
    installMock(root, VER_B, SHA_B);
    setCurrent(root, VER_B, SHA_B);
    const r = h.body(await h.call(RELOAD_TOOL.name));
    assert.equal(r.error.code, 'RELOAD_LIFECYCLE_BLOCKED');
    assert.equal(r.data.notRun, true);
    assert.equal(r.data.lifecycleBlocks.length, 1);
    assert.equal(r.data.requested.commit, SHA_B);
    assert.equal(h.body(await h.call('Echo')).data.commit, SHA_A, 'old runtime still serves');
    assert.equal(received(root, VER_B).length, 0, 'new runtime never started');
  });

  test('a runtime without tcauto/retire is not killed: RUNTIME_RETIRE_UNSUPPORTED', async () => {
    fs.writeFileSync(path.join(root, 'runtime', VER_A, 'behavior.json'), JSON.stringify({ retire: 'unsupported' }));
    await h.init();
    installMock(root, VER_B, SHA_B);
    setCurrent(root, VER_B, SHA_B);
    assert.equal(h.body(await h.call(RELOAD_TOOL.name)).error.code, 'RUNTIME_RETIRE_UNSUPPORTED');
    assert.equal(h.body(await h.call('Echo')).data.commit, SHA_A);
  });

  test('a runtime that dies: RUNTIME_DIED for its open call, the next call restarts it (initialize replayed)', async () => {
    await h.init();
    const first = h.body(await h.call('Echo'));
    const died = h.body(await h.call('Crash'));
    assert.equal(died.error.code, 'RUNTIME_DIED');
    assert.match(died.error.hint, /ConnectIde/);
    const again = h.body(await h.call('Echo'));
    assert.equal(again.success, true);
    assert.equal(again.data.commit, SHA_A, 'same version restarted');
    assert.notEqual(again.data.pid, first.data.pid);
    assert.equal(again.data.ownerId, first.data.ownerId);
    const inits = received(root, VER_A).filter((m) => m.method === 'initialize');
    assert.equal(inits.length, 2, 'initialize replayed for the restarted runtime');
  });

  test('a new runtime that does not start: RUNTIME_START_FAILED and the previous one runs again', async () => {
    await h.init();
    installMock(root, VER_B, SHA_B, { initFail: true });
    setCurrent(root, VER_B, SHA_B);
    const r = h.body(await h.call(RELOAD_TOOL.name));
    assert.equal(r.error.code, 'RUNTIME_START_FAILED');
    assert.equal(r.data.restored, true);
    assert.equal(r.data.current.commit, SHA_A);
    assert.equal(h.body(await h.call('Echo')).data.commit, SHA_A);
  });

  test('current.json missing or broken: RUNTIME_NOT_INSTALLED, the running runtime is untouched', async () => {
    await h.init();
    fs.rmSync(path.join(root, 'runtime', 'current.json'));
    const r = h.body(await h.call(RELOAD_TOOL.name));
    assert.equal(r.error.code, 'RUNTIME_NOT_INSTALLED');
    assert.match(r.error.hint, /Install-TcAutoRuntime/);
    assert.equal(h.body(await h.call('Echo')).data.commit, SHA_A);
  });
});

// ---------------------------------------------------------------- launcher + the REAL index.js
//
// Two copies of this mcp-server (without node_modules / test; node_modules is a junction to the real
// one) laid out like Install-TcAutoRuntime.ps1 does it, with the mock PowerShell bridge. Proves the
// real tcauto/retire path (bridge retire, fail closed on an in-memory lifecycle block), GetStatus
// data.bridge.runtime of an installed runtime and the owner id across a ReloadRuntime.
const MCP_DIR = path.join(__dirname, '..');
const MOCK_BRIDGE = path.join(__dirname, 'fixtures', 'mock-bridge.js');
const TOOLS_FIXTURE = path.join(__dirname, 'fixtures', 'tools.fixture.json');

function installRealCopy(root, version, commit) {
  const dir = path.join(root, 'runtime', version);
  const dest = path.join(dir, 'mcp-server');
  const skip = new Set(['node_modules', 'test'].map((n) => path.join(MCP_DIR, n).toLowerCase()));
  fs.cpSync(MCP_DIR, dest, { recursive: true, filter: (src) => !skip.has(path.resolve(src).toLowerCase()) });
  fs.symlinkSync(path.join(MCP_DIR, 'node_modules'), path.join(dest, 'node_modules'), 'junction');
  junctions.push(path.join(dest, 'node_modules'));
  fs.mkdirSync(path.join(dir, 'src', 'TwinCATAutomation'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'src', 'TwinCATAutomation', 'TwinCATAutomation.psm1'), '# fixture\n');
  fs.writeFileSync(
    path.join(dir, 'tcauto-source.json'),
    JSON.stringify({ schema: 1, commit, ref: 'refs/heads/feat/162-test', branch: 'feat/162-test', dirty: false, installedAt: '2026-11-06T00:00:00.000Z', sourcePath: 'C:\\src162', version })
  );
  return dir;
}

function toolsWithBlock(dir) {
  const doc = JSON.parse(fs.readFileSync(TOOLS_FIXTURE, 'utf8'));
  doc.tools.push({
    name: 'SetSystemState',
    cmdlet: 'Set-TcSystemState',
    description: 'fixture',
    inputSchema: { type: 'object', properties: { AmsNetId: { type: 'string' }, Fail: { type: 'boolean' } }, required: [], additionalProperties: false }
  });
  const file = path.join(dir, 'tools-162.json');
  fs.writeFileSync(file, JSON.stringify(doc));
  return file;
}

describe('launcher + real index.js copies (mock PowerShell bridge)', { skip: process.platform !== 'win32' && 'junction + win32 paths' }, () => {
  let root;
  let h;
  let ownerFile;
  before(() => {
    root = newRoot();
    installRealCopy(root, VER_A, SHA_A);
    installRealCopy(root, VER_B, SHA_B);
    setCurrent(root, VER_A, SHA_A);
    const stateDir = path.join(root, 'state-162');
    fs.mkdirSync(stateDir);
    ownerFile = path.join(root, 'owners-162.txt');
    const env = {
      ...process.env,
      TWINCAT_MCP_TOOLS_JSON: toolsWithBlock(root),
      TWINCAT_MCP_BRIDGE_COMMAND: process.execPath,
      TWINCAT_MCP_BRIDGE_ARGS: JSON.stringify([MOCK_BRIDGE]),
      TWINCAT_MCP_MODAL_PROBE: '0',
      TWINCAT_MCP_SKIP_PID_CHECK: '1',
      MOCK_BRIDGE_OWNER_FILE: ownerFile,
      TCAUTO_STATE_DIR: stateDir,
      TCAUTO_TEST_FORBID_REAL_STATE: '1'
    };
    delete env.TWINCAT_MODULE_PATH; // the runtime's own src\TwinCATAutomation module
    h = harness(root, { env });
  });
  after(async () => {
    await h?.close();
  });

  test('GetStatus names the installed runtime; ReloadRuntime switches it and keeps the owner id', async () => {
    await h.init();
    const list = await h.request('tools/list', {});
    const names = list.result.tools.map((t) => t.name);
    assert.ok(names.includes('GetStatus') && names.includes('ReloadModule') && names.includes(RELOAD_TOOL.name));

    assert.equal(h.body(await h.call('ConnectIde')).success, true);
    const s = h.body(await h.call('GetStatus'));
    const b = s.data.bridge;
    assert.equal(b.runtime.source, 'installed');
    assert.equal(b.runtime.version, VER_A);
    assert.equal(b.runtime.commit, SHA_A);
    assert.equal(b.runtime.dirty, false);
    assert.equal(b.runtime.branch, 'feat/162-test');
    assert.equal(b.runtime.runtimeRoot.toLowerCase(), root.toLowerCase());
    assert.equal(b.runtime.launcherPid, process.pid);
    assert.equal(b.runtime.ownerIdFrom, 'launcher');
    assert.equal(b.moduleSource, 'installed');
    assert.equal(b.moduleCommit, SHA_A);
    assert.equal(b.moduleDirty, false);

    // ReloadModule with another ModulePath is refused in an installed runtime and names ReloadRuntime
    const rm = h.body(await h.call('ReloadModule', { ModulePath: path.join(root, 'runtime', VER_B, 'src', 'TwinCATAutomation', 'TwinCATAutomation.psm1') }));
    assert.equal(rm.error.code, 'RELOAD_PATH_NOT_ALLOWED');
    assert.match(rm.error.message, /ReloadRuntime/);

    setCurrent(root, VER_B, SHA_B);
    const r = h.body(await h.call(RELOAD_TOOL.name));
    assert.equal(r.success, true, JSON.stringify(r));
    assert.equal(r.data.previous.commit, SHA_A);
    assert.equal(r.data.current.commit, SHA_B);
    assert.equal(r.data.retired.retired, true, 'the bridge took the retire path');
    assert.equal(r.data.retired.ideWasConnected, true);

    const s2 = h.body(await h.call('GetStatus'));
    assert.equal(s2.error.code, 'NOT_CONNECTED', 'IDE connection released by the reload');
    assert.equal(s2.data.bridge.runtime.commit, SHA_B);
    assert.equal(s2.data.bridge.moduleCommit, SHA_B);

    const owners = fs.readFileSync(ownerFile, 'utf8').split(/\r?\n/).filter(Boolean);
    assert.ok(owners.length >= 2, 'a bridge of each runtime started');
    assert.deepEqual(new Set(owners), new Set([h.launcher.ownerId]), 'every bridge got the launcher owner id');
  });

  test('an in-memory lifecycle block makes ReloadRuntime fail closed (RELOAD_LIFECYCLE_BLOCKED, nothing switched)', async () => {
    const fail = h.body(await h.call('SetSystemState', { AmsNetId: '5.1.2.3.1.1', Fail: true }));
    assert.equal(fail.success, false);
    setCurrent(root, VER_A, SHA_A);
    const r = h.body(await h.call(RELOAD_TOOL.name));
    assert.equal(r.error.code, 'RELOAD_LIFECYCLE_BLOCKED');
    assert.equal(r.data.notRun, true);
    const s = h.body(await h.call('GetStatus'));
    assert.equal(s.data.bridge.runtime.commit, SHA_B, 'still the runtime that holds the block');
  });
});

describe('launcher without an installed runtime', () => {
  test('the first request gets RUNTIME_NOT_INSTALLED with the install hint', async () => {
    const root = newRoot();
    const h = harness(root);
    try {
      const r = await h.request('initialize', h.initParams);
      assert.match(r.error.message, /RUNTIME_NOT_INSTALLED/);
      assert.match(r.error.message, /Install-TcAutoRuntime/);
    } finally {
      await h.close();
    }
  });
});
