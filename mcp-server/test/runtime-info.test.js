// #162: lib/runtime-info.js (launcher owner id, runtime of index.js), module-source.js reading the
// tcauto-source.json of an installed runtime, and index.js over stdio: the launcher owner id is used
// only when TCAUTO_LAUNCHER_PID is the parent pid, and the launcher-only request tcauto/retire.
// Temp folders contain 162; the mock bridge gets its own TCAUTO_STATE_DIR.
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { z } from 'zod';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { launcherContextFrom, runtimeInfoOf } from '../lib/runtime-info.js';
import { moduleInfoOf, readSourceStamp, installedRootOf, checkModulePath, MODULE_RELATIVE_PATH, pathKey } from '../lib/module-source.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const INDEX = path.join(__dirname, '..', 'index.js');
const MOCK = path.join(__dirname, 'fixtures', 'mock-bridge.js');
const FIXTURE = path.join(__dirname, 'fixtures', 'tools.fixture.json');
const SHA = 'c'.repeat(40);

const dirs = [];
after(() => {
  for (const d of dirs) {
    try {
      fs.rmSync(d, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
    } catch {
      /* temp */
    }
  }
});
function tmp(prefix) {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), `tcauto-${prefix}162-`));
  dirs.push(d);
  return d;
}

/** <root>\runtime\<ver>\{tcauto-source.json, src\TwinCATAutomation\TwinCATAutomation.psm1, mcp-server\} */
function installedLayout(stamp) {
  const root = tmp('rtinfo');
  const ver = path.join(root, 'runtime', 'cccccccccccc');
  fs.mkdirSync(path.join(ver, 'src', 'TwinCATAutomation'), { recursive: true });
  fs.mkdirSync(path.join(ver, 'mcp-server'), { recursive: true });
  fs.writeFileSync(path.join(ver, MODULE_RELATIVE_PATH), '# fixture\n');
  if (stamp !== undefined) fs.writeFileSync(path.join(ver, 'tcauto-source.json'), typeof stamp === 'string' ? stamp : JSON.stringify(stamp));
  return { root, ver, mod: path.join(ver, MODULE_RELATIVE_PATH) };
}

describe('launcherContextFrom', () => {
  const id = randomUUID();
  test('no launcher variables -> null (direct start)', () => {
    assert.equal(launcherContextFrom({}, 123), null);
  });
  test('GUID + parent pid -> ok, id lower-cased', () => {
    assert.deepEqual(launcherContextFrom({ TCAUTO_LAUNCHER_OWNER_ID: id.toUpperCase(), TCAUTO_LAUNCHER_PID: '123' }, 123), { ok: true, ownerId: id, pid: 123 });
  });
  test('a pid that is not the parent, a missing pid or a non-GUID id -> ignored', () => {
    assert.equal(launcherContextFrom({ TCAUTO_LAUNCHER_OWNER_ID: id, TCAUTO_LAUNCHER_PID: '124' }, 123).ok, false);
    assert.equal(launcherContextFrom({ TCAUTO_LAUNCHER_OWNER_ID: id }, 123).ok, false);
    assert.equal(launcherContextFrom({ TCAUTO_LAUNCHER_OWNER_ID: 'owner-162', TCAUTO_LAUNCHER_PID: '123' }, 123).ok, false);
    assert.equal(launcherContextFrom({ TCAUTO_LAUNCHER_PID: '123' }, 123).ok, false);
  });
});

describe('installed runtime stamp (tcauto-source.json)', () => {
  test('moduleInfoOf reads commit and dirty of an installed runtime', () => {
    const { mod, ver } = installedLayout({ commit: SHA.toUpperCase(), ref: 'refs/heads/master', branch: 'master', dirty: true, installedAt: '2026-11-06T01:02:03.000Z', sourcePath: 'C:\\src162' });
    assert.deepEqual(moduleInfoOf(mod), { modulePath: mod, moduleCommit: SHA, moduleDirty: true, moduleSource: 'installed' });
    assert.equal(pathKey(installedRootOf(mod)), pathKey(ver));
    assert.equal(readSourceStamp(ver).branch, 'master');
  });
  test('a commit that is not a 40 / 64 hex name is null, dirty only when boolean; a broken stamp is no stamp', () => {
    const a = installedLayout({ commit: 'abc', dirty: 'yes' });
    assert.deepEqual(moduleInfoOf(a.mod), { modulePath: a.mod, moduleCommit: null, moduleDirty: null, moduleSource: 'installed' });
    const b = installedLayout('{broken');
    assert.deepEqual(moduleInfoOf(b.mod), { modulePath: b.mod, moduleCommit: null, moduleDirty: null, moduleSource: null });
    const c = installedLayout(undefined);
    assert.equal(installedRootOf(c.mod), null);
    // another file in the runtime is not the module
    assert.equal(installedRootOf(path.join(a.ver, 'src', 'TwinCATAutomation', 'TwinCATAutomation.psd1')), null);
  });
  test('checkModulePath in an installed runtime names ReloadRuntime', () => {
    const { mod } = installedLayout({ commit: SHA, dirty: false });
    const c = checkModulePath(path.join(os.tmpdir(), 'x162', MODULE_RELATIVE_PATH), mod);
    assert.equal(c.ok, false);
    assert.match(c.reason, /installed runtime/);
    assert.match(c.reason, /ReloadRuntime/);
  });
  test('runtimeInfoOf: installed (runtimeRoot = install root), git checkout, unknown', () => {
    const { root, ver } = installedLayout({ commit: SHA, branch: 'feat/x', dirty: false, installedAt: '2026-11-06T01:02:03.000Z', sourcePath: 'C:\\src162', version: 'cccccccccccc' });
    const i = runtimeInfoOf(path.join(ver, 'mcp-server'));
    assert.equal(i.source, 'installed');
    assert.equal(pathKey(i.runtimeRoot), pathKey(root));
    assert.equal(i.version, 'cccccccccccc');
    assert.equal(i.commit, SHA);
    assert.equal(i.branch, 'feat/x');
    assert.equal(i.dirty, false);
    assert.equal(i.sourcePath, 'C:\\src162');

    const repo = tmp('rtgit');
    fs.mkdirSync(path.join(repo, '.git', 'refs', 'heads'), { recursive: true });
    fs.writeFileSync(path.join(repo, '.git', 'HEAD'), 'ref: refs/heads/feat/162\n');
    fs.mkdirSync(path.join(repo, '.git', 'refs', 'heads', 'feat'));
    fs.writeFileSync(path.join(repo, '.git', 'refs', 'heads', 'feat', '162'), `${SHA}\n`);
    const g = runtimeInfoOf(path.join(repo, 'mcp-server'));
    assert.equal(g.source, 'git-checkout');
    assert.equal(g.commit, SHA);
    assert.equal(g.branch, 'feat/162');
    assert.equal(g.dirty, null);
    assert.equal(g.runtimeRoot, null);

    assert.equal(runtimeInfoOf(path.join(tmp('rtnone'), 'mcp-server')).source, 'unknown');
  });
});

// ---------------------------------------------------------------- index.js over stdio

async function startServer(extraEnv) {
  const stateDir = tmp('rtstate');
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [INDEX],
    env: {
      ...process.env,
      TWINCAT_MCP_TOOLS_JSON: toolsWithBlock(),
      TWINCAT_MCP_BRIDGE_COMMAND: process.execPath,
      TWINCAT_MCP_BRIDGE_ARGS: JSON.stringify([MOCK]),
      TWINCAT_MCP_MODAL_PROBE: '0',
      TWINCAT_MCP_SKIP_PID_CHECK: '1',
      TCAUTO_STATE_DIR: stateDir,
      TCAUTO_TEST_FORBID_REAL_STATE: '1',
      ...extraEnv
    },
    stderr: 'pipe'
  });
  const client = new Client({ name: 'runtime-info-162', version: '0.0.0' }, { capabilities: {} });
  await client.connect(transport);
  return client;
}

function toolsWithBlock() {
  const doc = JSON.parse(fs.readFileSync(FIXTURE, 'utf8'));
  doc.tools.push({
    name: 'SetSystemState',
    cmdlet: 'Set-TcSystemState',
    description: 'fixture',
    inputSchema: { type: 'object', properties: { AmsNetId: { type: 'string' }, Fail: { type: 'boolean' } }, required: [], additionalProperties: false }
  });
  const file = path.join(tmp('rttools'), 'tools.json');
  fs.writeFileSync(file, JSON.stringify(doc));
  return file;
}

const body = (r) => JSON.parse(r.content[0].text);
const owners = (file) => fs.readFileSync(file, 'utf8').split(/\r?\n/).filter(Boolean);
const retire = (client) => client.request({ method: 'tcauto/retire', params: {} }, z.any());

describe('index.js started by a launcher (TCAUTO_LAUNCHER_PID = parent pid)', () => {
  test('bridges get the launcher owner id; GetStatus runtime names launcherPid; tcauto/retire is fail closed, then RUNTIME_RETIRED', async () => {
    const ownerId = randomUUID();
    const ownerFile = path.join(tmp('rtowner'), 'owners.txt');
    const client = await startServer({ TCAUTO_LAUNCHER_OWNER_ID: ownerId, TCAUTO_LAUNCHER_PID: String(process.pid), MOCK_BRIDGE_OWNER_FILE: ownerFile });
    try {
      const s = body(await client.callTool({ name: 'GetStatus', arguments: {} }));
      assert.equal(s.data.bridge.runtime.ownerIdFrom, 'launcher');
      assert.equal(s.data.bridge.runtime.launcherPid, process.pid);
      assert.equal(s.data.bridge.runtime.source, 'git-checkout', 'this test runs the checkout index.js');
      assert.deepEqual(owners(ownerFile), [ownerId]);

      // an in-memory lifecycle block: the retire is refused and the runtime keeps serving
      assert.equal(body(await client.callTool({ name: 'SetSystemState', arguments: { AmsNetId: '5.1.2.3.1.1', Fail: true } })).success, false);
      const refused = await retire(client);
      assert.equal(refused.success, false);
      assert.equal(refused.error.code, 'RELOAD_LIFECYCLE_BLOCKED');
      assert.equal(body(await client.callTool({ name: 'GetStatus', arguments: {} })).data.bridge.runtime.launcherPid, process.pid);
    } finally {
      await client.close();
    }

    // a fresh server without a block: the retire succeeds, later calls are refused
    const client2 = await startServer({ TCAUTO_LAUNCHER_OWNER_ID: ownerId, TCAUTO_LAUNCHER_PID: String(process.pid), MOCK_BRIDGE_OWNER_FILE: ownerFile });
    try {
      assert.equal(body(await client2.callTool({ name: 'ConnectIde', arguments: {} })).success, true);
      const ok = await retire(client2);
      assert.equal(ok.success, true, JSON.stringify(ok));
      assert.equal(ok.data.retired, true);
      assert.equal(ok.data.ideWasConnected, true);
      const after = body(await client2.callTool({ name: 'GetStatus', arguments: {} }));
      assert.equal(after.error.code, 'RUNTIME_RETIRED');
      assert.deepEqual(owners(ownerFile), [ownerId, ownerId], 'same owner id for both servers (same launcher)');
    } finally {
      await client2.close();
    }
  });

  test('a launcher pid that is not the parent: own owner id, ownerIdFrom server, no tcauto/retire', async () => {
    const ownerId = randomUUID();
    const ownerFile = path.join(tmp('rtowner'), 'owners.txt');
    const client = await startServer({ TCAUTO_LAUNCHER_OWNER_ID: ownerId, TCAUTO_LAUNCHER_PID: String(process.pid + 1), MOCK_BRIDGE_OWNER_FILE: ownerFile });
    try {
      const s = body(await client.callTool({ name: 'GetStatus', arguments: {} }));
      assert.equal(s.data.bridge.runtime.ownerIdFrom, 'server');
      assert.equal(s.data.bridge.runtime.launcherPid, null);
      const got = owners(ownerFile);
      assert.equal(got.length, 1);
      assert.notEqual(got[0], ownerId);
      assert.match(got[0], /^[0-9a-f-]{36}$/);
      await assert.rejects(retire(client), /Method not found/);
    } finally {
      await client.close();
    }
  });

  test('a direct start (no launcher variables) is unchanged: ownerIdFrom server, no tcauto/retire', async () => {
    const client = await startServer({});
    try {
      const s = body(await client.callTool({ name: 'GetStatus', arguments: {} }));
      assert.equal(s.data.bridge.runtime.ownerIdFrom, 'server');
      assert.equal(s.data.bridge.moduleSource, 'git-checkout', 'default module path: src\\TwinCATAutomation of this checkout');
      assert.equal(s.data.bridge.runtime.source, 'git-checkout');
      await assert.rejects(retire(client), /Method not found/);
    } finally {
      await client.close();
    }
  });
});
