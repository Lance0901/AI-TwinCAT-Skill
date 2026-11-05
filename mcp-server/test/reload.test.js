// #41 ReloadModule + GetStatus data.bridge.modulePath / moduleCommit / loadedAt.
//   1. lib/module-source.js on a fake repository (main checkout + worktrees, .git files only)
//   2. index.js over stdio with the mock bridge: allow list, fail closed on an in-memory lifecycle
//      block, IDE/ADS released, import failure restores the previous module
//   3. the REAL bridge/bridge.ps1 op 'retire' with a fixture module (Windows only)
// Nothing here touches the real %TEMP%\TwinCATAutomation state: the fake repository lives in its own
// temp directory (name contains 41) and the real-bridge test sets its own TCAUTO_STATE_DIR.
import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import {
  MODULE_RELATIVE_PATH,
  checkoutRootOf,
  readHeadCommit,
  mainCheckoutOf,
  listCheckouts,
  allowedModulePaths,
  checkModulePath,
  moduleInfoOf,
  pathKey
} from '../lib/module-source.js';
import { PowerShellBridge } from '../lib/bridge.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const INDEX = path.join(__dirname, '..', 'index.js');
const FIXTURE = path.join(__dirname, 'fixtures', 'tools.fixture.json');
const MOCK = path.join(__dirname, 'fixtures', 'mock-bridge.js');
const RELOAD_MODULE = path.join(__dirname, 'fixtures', 'reload-module', 'TwinCATAutomation.psm1');
const RELOAD_MODULE_OLD = path.join(__dirname, 'fixtures', 'reload-module-old', 'TwinCATAutomation.psm1');
const isWin = process.platform === 'win32';

const SHA_MAIN = '1111111111111111111111111111111111111111';
const SHA_WT = '2222222222222222222222222222222222222222';
const SHA_FEAT = '3333333333333333333333333333333333333333';
const SHA_BAD = '4444444444444444444444444444444444444444';

const tempDirs = [];
after(() => {
  for (const d of tempDirs) {
    try {
      fs.rmSync(d, { recursive: true, force: true });
    } catch {
      /* temp directory */
    }
  }
});

function put(file, text) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, text);
}

/** Main checkout + worktrees, laid out like git does it (forward slashes in gitdir files). */
function makeRepo() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'tcauto-reload41-'));
  tempDirs.push(root);
  const fwd = (p) => p.replace(/\\/g, '/');
  const main = path.join(root, 'main');
  const git = path.join(main, '.git');
  put(path.join(git, 'HEAD'), 'ref: refs/heads/master\n');
  put(path.join(git, 'refs', 'heads', 'master'), `${SHA_MAIN}\n`);
  put(path.join(git, 'packed-refs'), `# pack-refs with: peeled fully-peeled sorted\n${SHA_FEAT} refs/heads/feat\n`);
  put(path.join(main, MODULE_RELATIVE_PATH), '# main\n');
  const worktree = (name, head) => {
    const dir = path.join(root, name);
    const entry = path.join(git, 'worktrees', name);
    put(path.join(entry, 'HEAD'), `${head}\n`);
    put(path.join(entry, 'commondir'), '../..\n');
    put(path.join(entry, 'gitdir'), `${fwd(path.join(dir, '.git'))}\n`);
    put(path.join(dir, '.git'), `gitdir: ${fwd(entry)}\n`);
    put(path.join(dir, MODULE_RELATIVE_PATH), `# ${name}\n`);
    return dir;
  };
  const wt = worktree('wt-a', SHA_WT); // detached HEAD
  const feat = worktree('wt-feat', 'ref: refs/heads/feat'); // branch only in packed-refs
  const bad = worktree('wt-badimport41', SHA_BAD);
  // a stale entry (directory removed): `git worktree list` would call it prunable; not allowed
  const goneEntry = path.join(git, 'worktrees', 'gone');
  put(path.join(goneEntry, 'HEAD'), `${SHA_WT}\n`);
  put(path.join(goneEntry, 'gitdir'), `${fwd(path.join(root, 'gone', '.git'))}\n`);
  // a directory whose .git file claims the wt-a entry but is not registered itself
  const foreign = path.join(root, 'foreign');
  put(path.join(foreign, '.git'), `gitdir: ${fwd(path.join(git, 'worktrees', 'wt-a'))}\n`);
  put(path.join(foreign, MODULE_RELATIVE_PATH), '# foreign\n');
  // an unrelated repository
  const other = path.join(root, 'other');
  put(path.join(other, '.git', 'HEAD'), `${SHA_MAIN}\n`);
  put(path.join(other, MODULE_RELATIVE_PATH), '# other\n');
  const mod = (dir) => path.join(dir, MODULE_RELATIVE_PATH);
  return { root, main, wt, feat, bad, foreign, other, mod };
}

describe('module-source (#41): commit and allow list from the .git files', () => {
  let r;
  before(() => {
    r = makeRepo();
  });

  test('checkoutRootOf: only <root>\\src\\TwinCATAutomation\\TwinCATAutomation.psm1 of a directory with .git', () => {
    assert.equal(pathKey(checkoutRootOf(r.mod(r.main))), pathKey(r.main));
    assert.equal(pathKey(checkoutRootOf(r.mod(r.wt))), pathKey(r.wt));
    assert.equal(checkoutRootOf(path.join(r.main, 'src', 'TwinCATAutomation', 'TwinCATAutomation.psd1')), null);
    assert.equal(checkoutRootOf(path.join(r.root, 'nogit', MODULE_RELATIVE_PATH)), null);
    assert.equal(checkoutRootOf(''), null);
  });

  test('readHeadCommit: loose ref, detached HEAD in a worktree, branch only in packed-refs', () => {
    assert.equal(readHeadCommit(r.main), SHA_MAIN);
    assert.equal(readHeadCommit(r.wt), SHA_WT);
    assert.equal(readHeadCommit(r.feat), SHA_FEAT);
    assert.equal(readHeadCommit(path.join(r.root, 'nogit')), null);
  });

  test('mainCheckoutOf resolves a worktree to the main checkout through commondir', () => {
    assert.equal(pathKey(mainCheckoutOf(r.wt)), pathKey(r.main));
    assert.equal(pathKey(mainCheckoutOf(r.main)), pathKey(r.main));
  });

  test('listCheckouts = main + registered worktrees whose .git points back (stale / foreign excluded)', () => {
    const keys = listCheckouts(r.main).map(pathKey).sort();
    assert.deepEqual(keys, [r.main, r.bad, r.feat, r.wt].map(pathKey).sort());
  });

  test('allowedModulePaths is the same list from the main checkout and from a worktree', () => {
    const fromMain = allowedModulePaths(r.mod(r.main)).map(pathKey).sort();
    const fromWt = allowedModulePaths(r.mod(r.wt)).map(pathKey).sort();
    assert.deepEqual(fromMain, fromWt);
    assert.equal(fromMain.length, 4);
    assert.deepEqual(allowedModulePaths(path.join(r.root, 'x.psm1')), []);
  });

  test('checkModulePath accepts main / worktree modules (any case, forward slashes) and refuses everything else', () => {
    const base = r.mod(r.main);
    assert.equal(checkModulePath(r.mod(r.wt), base).ok, true);
    assert.equal(checkModulePath(r.mod(r.main), base).ok, true);
    assert.equal(checkModulePath(r.mod(r.wt).toUpperCase().replace(/\\/g, '/'), base).ok, true);
    const refused = [
      r.mod(r.foreign), // .git claims a registered entry but is not that worktree
      r.mod(r.other), // another repository
      path.join(r.root, 'gone', MODULE_RELATIVE_PATH), // stale worktree entry
      path.join(r.wt, 'src', 'TwinCATAutomation', 'TwinCATAutomation.psd1'), // other file
      path.join(r.wt, 'src', 'TwinCATAutomation', 'Private', '..', '..', '..', '..', 'other', MODULE_RELATIVE_PATH),
      MODULE_RELATIVE_PATH, // relative
      '\\src\\TwinCATAutomation\\TwinCATAutomation.psm1', // root-relative
      ''
    ];
    for (const p of refused) {
      const c = checkModulePath(p, base);
      assert.equal(c.ok, false, `refused: ${p}`);
      assert.ok(typeof c.reason === 'string' && c.reason.length > 0);
    }
    // a server started from outside a checkout allows no ModulePath at all
    const none = checkModulePath(r.mod(r.wt), path.join(r.root, 'installed', 'TwinCATAutomation.psm1'));
    assert.equal(none.ok, false);
    assert.match(none.reason, /not part of a git checkout/);
  });

  test('a registered worktree whose module file is missing is refused', () => {
    const p = r.mod(r.feat);
    fs.renameSync(p, `${p}.moved`);
    try {
      const c = checkModulePath(p, r.mod(r.main));
      assert.equal(c.ok, false);
      assert.match(c.reason, /does not exist/);
    } finally {
      fs.renameSync(`${p}.moved`, p);
    }
  });

  test('moduleInfoOf gives the commit of the checkout, null outside one', () => {
    assert.deepEqual(moduleInfoOf(r.mod(r.wt)), { modulePath: r.mod(r.wt), moduleCommit: SHA_WT });
    assert.equal(moduleInfoOf('mock').moduleCommit, null);
  });
});

// ---------------------------------------------------------------- MCP server + mock bridge

function parse(result) {
  return JSON.parse(result.content[0].text);
}

function toolsWithSystemState() {
  const doc = JSON.parse(fs.readFileSync(FIXTURE, 'utf8'));
  doc.tools.push({
    name: 'SetSystemState',
    cmdlet: 'Set-TcSystemState',
    description: 'fixture',
    inputSchema: { type: 'object', properties: { AmsNetId: { type: 'string' }, Fail: { type: 'boolean' } }, required: [], additionalProperties: false }
  });
  doc.tools.push({
    name: 'MarkBuildRequired',
    cmdlet: 'Register-TcCodeChange',
    description: 'fixture',
    inputSchema: { type: 'object', properties: { SolutionPath: { type: 'string' }, StateUnwritable: { type: 'boolean' } }, required: [], additionalProperties: false }
  });
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tcauto-reload41-tools-'));
  tempDirs.push(dir);
  const file = path.join(dir, 'tools.json');
  fs.writeFileSync(file, JSON.stringify(doc));
  return file;
}

function newStateDir() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tcauto-state-41-'));
  tempDirs.push(dir);
  return dir;
}

async function startServer(modulePath, extraEnv = {}) {
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [INDEX],
    env: {
      ...process.env,
      TWINCAT_MCP_TOOLS_JSON: toolsWithSystemState(),
      TWINCAT_MCP_BRIDGE_COMMAND: process.execPath,
      TWINCAT_MCP_BRIDGE_ARGS: JSON.stringify([MOCK]),
      TWINCAT_MCP_MODAL_PROBE: '0',
      TWINCAT_MCP_SKIP_PID_CHECK: '1',
      TWINCAT_MODULE_PATH: modulePath,
      MOCK_BRIDGE_FAIL_MODULE: 'badimport41',
      TCAUTO_STATE_DIR: newStateDir(),
      TCAUTO_TEST_FORBID_REAL_STATE: '1',
      ...extraEnv
    },
    stderr: 'pipe'
  });
  const client = new Client({ name: 'reload-test', version: '0.0.0' }, { capabilities: {} });
  await client.connect(transport);
  return client;
}

async function status(client) {
  return parse(await client.callTool({ name: 'GetStatus', arguments: {} }));
}

describe('ReloadModule over stdio (mock bridge, fake repository)', () => {
  let r;
  let client;
  let stateDir;
  before(async () => {
    r = makeRepo();
    stateDir = newStateDir();
    client = await startServer(r.mod(r.main), { TCAUTO_STATE_DIR: stateDir });
  });
  after(async () => client?.close());

  test('tools/list offers ReloadModule with an optional ModulePath', async () => {
    const { tools } = await client.listTools();
    const t = tools.find((x) => x.name === 'ReloadModule');
    assert.ok(t, 'ReloadModule listed');
    assert.equal(t.inputSchema.properties.ModulePath.type, 'string');
    assert.deepEqual(t.inputSchema.required, []);
    assert.equal(t.inputSchema.additionalProperties, false);
    assert.match(t.description, /RELOAD_LIFECYCLE_BLOCKED/);
    assert.match(t.description, /ConnectIde/);
  });

  test('GetStatus data.bridge names modulePath, moduleCommit and loadedAt (also before ConnectIde)', async () => {
    const s = await status(client);
    assert.equal(s.error.code, 'NOT_CONNECTED');
    assert.equal(pathKey(s.data.bridge.modulePath), pathKey(r.mod(r.main)));
    assert.equal(s.data.bridge.moduleCommit, SHA_MAIN);
    assert.equal(s.data.bridge.moduleDirty, null, 'dirty state is not known without git');
    assert.ok(!Number.isNaN(Date.parse(s.data.bridge.loadedAt)), 'loadedAt is an ISO time');
  });

  test('a path outside the allow list -> RELOAD_PATH_NOT_ALLOWED, bridge untouched', async () => {
    const before = (await status(client)).data.bridge;
    for (const p of [r.mod(r.other), r.mod(r.foreign), 'C:\\Windows\\System32\\x.psm1', MODULE_RELATIVE_PATH]) {
      const res = await client.callTool({ name: 'ReloadModule', arguments: { ModulePath: p } });
      assert.equal(res.isError, true);
      const body = parse(res);
      assert.equal(body.error.code, 'RELOAD_PATH_NOT_ALLOWED', p);
      assert.equal(body.data.notRun, true);
      assert.equal(body.data.allowed.length, 4);
    }
    const afterState = (await status(client)).data.bridge;
    assert.equal(afterState.loadedAt, before.loadedAt, 'no restart');
  });

  test('ReloadModule ModulePath=<worktree> -> previous/current with their commits; IDE and ADS released', async () => {
    const c = parse(await client.callTool({ name: 'ConnectIde', arguments: {} }));
    assert.equal(c.success, true);
    const before = (await status(client)).data.bridge;
    assert.equal(before.ideConnected, true);

    const res = parse(await client.callTool({ name: 'ReloadModule', arguments: { ModulePath: r.mod(r.wt) } }));
    assert.equal(res.success, true, JSON.stringify(res));
    assert.equal(res.data.previous.moduleCommit, SHA_MAIN);
    assert.equal(pathKey(res.data.previous.modulePath), pathKey(r.mod(r.main)));
    assert.equal(res.data.current.moduleCommit, SHA_WT);
    assert.equal(pathKey(res.data.current.modulePath), pathKey(r.mod(r.wt)));
    assert.notEqual(res.data.current.loadedAt, res.data.previous.loadedAt);
    assert.equal(res.data.ideDisconnected, true);
    assert.equal(res.data.reconnectRequired, true);
    assert.match(res.data.note, /ConnectIde/);

    const s = await status(client);
    assert.equal(s.error.code, 'NOT_CONNECTED', 'the new bridge has no IDE connection');
    assert.equal(s.data.bridge.ideConnected, false);
    assert.equal(s.data.bridge.moduleCommit, SHA_WT);
    assert.equal(s.data.bridge.loadedAt, res.data.current.loadedAt);
  });

  test('ReloadModule without ModulePath reloads the module loaded now (worktree on a packed branch next)', async () => {
    const res = parse(await client.callTool({ name: 'ReloadModule', arguments: {} }));
    assert.equal(res.success, true);
    assert.equal(pathKey(res.data.current.modulePath), pathKey(res.data.previous.modulePath));
    assert.notEqual(res.data.current.loadedAt, res.data.previous.loadedAt);
    const feat = parse(await client.callTool({ name: 'ReloadModule', arguments: { ModulePath: r.mod(r.feat) } }));
    assert.equal(feat.data.current.moduleCommit, SHA_FEAT);
  });

  test('a module that fails to import -> RELOAD_FAILED and the previous module is loaded again', async () => {
    const before = (await status(client)).data.bridge;
    const res = parse(await client.callTool({ name: 'ReloadModule', arguments: { ModulePath: r.mod(r.bad) } }));
    assert.equal(res.success, false);
    assert.equal(res.error.code, 'RELOAD_FAILED');
    assert.equal(res.data.restored, true);
    assert.equal(res.data.importError.code, 'MODULE_IMPORT_FAILED');
    const s = (await status(client)).data.bridge;
    assert.equal(pathKey(s.modulePath), pathKey(before.modulePath));
    assert.equal(s.moduleCommit, before.moduleCommit);
    assert.notEqual(s.loadedAt, before.loadedAt);
  });

  test('in-memory BUILD_REQUIRED entries are written to build-required.json before the reload', async () => {
    const sln = 'C:\\Proj41\\Demo.sln';
    assert.equal(parse(await client.callTool({ name: 'MarkBuildRequired', arguments: { SolutionPath: sln } })).success, true);
    const res = parse(await client.callTool({ name: 'ReloadModule', arguments: {} }));
    assert.equal(res.success, true, JSON.stringify(res));
    assert.deepEqual(res.data.buildRequiredPersisted, [sln.toLowerCase()]);
    const doc = JSON.parse(fs.readFileSync(path.join(stateDir, 'build-required.json'), 'utf8'));
    assert.ok(doc[sln.toLowerCase()], 'entry is in the state file the new bridge reads');
  });

  test('BUILD_REQUIRED entries that cannot be written -> RELOAD_BUILD_REQUIRED, bridge kept', async () => {
    assert.equal(parse(await client.callTool({ name: 'MarkBuildRequired', arguments: { SolutionPath: 'C:\\Proj41\\B.sln', StateUnwritable: true } })).success, true);
    const before = (await status(client)).data.bridge;
    const res = await client.callTool({ name: 'ReloadModule', arguments: {} });
    assert.equal(res.isError, true);
    const body = parse(res);
    assert.equal(body.error.code, 'RELOAD_BUILD_REQUIRED');
    assert.equal(body.data.notRun, true);
    assert.ok(body.data.buildRequiredKeys.includes('c:\\proj41\\b.sln'));
    assert.equal((await status(client)).data.bridge.loadedAt, before.loadedAt, 'same bridge process');
  });

  test('fail closed (#68): an in-memory lifecycle block refuses the reload and keeps the bridge (and the block)', async () => {
    const fail = parse(await client.callTool({ name: 'SetSystemState', arguments: { AmsNetId: '5.1.2.3.1.1', Fail: true } }));
    assert.equal(fail.success, false);
    const before = (await status(client)).data.bridge;
    for (const args of [{}, { ModulePath: r.mod(r.main) }]) {
      const res = await client.callTool({ name: 'ReloadModule', arguments: args });
      assert.equal(res.isError, true);
      const body = parse(res);
      assert.equal(body.error.code, 'RELOAD_LIFECYCLE_BLOCKED');
      assert.ok(body.error.hint);
      assert.equal(body.data.notRun, true);
      assert.equal(body.data.lifecycleBlocks.length, 1);
      assert.equal(body.data.lifecycleBlocks[0].key, '5.1.2.3.1.1');
    }
    const s = (await status(client)).data.bridge;
    assert.equal(s.loadedAt, before.loadedAt, 'same bridge process');
    assert.equal(pathKey(s.modulePath), pathKey(before.modulePath));
  });
});

describe('ReloadModule after a RELOAD_FAILED that could not restore (#129 review)', () => {
  let r;
  let client;
  let failFile;
  before(async () => {
    r = makeRepo();
    failFile = path.join(r.root, 'fail-markers41.txt');
    fs.writeFileSync(failFile, '');
    client = await startServer(r.mod(r.main), { MOCK_BRIDGE_FAIL_FILE: failFile });
  });
  after(async () => client?.close());

  test('no bridge left: the next ReloadModule to a good allowed path starts it (no retire of the broken path)', async () => {
    assert.equal((await status(client)).data.bridge.moduleCommit, SHA_MAIN);
    // the new path AND the previous one fail to import -> restored false, no child
    fs.writeFileSync(failFile, `${path.basename(r.bad)}\n${path.basename(r.main)}${path.sep}\n`);
    const failed = parse(await client.callTool({ name: 'ReloadModule', arguments: { ModulePath: r.mod(r.bad) } }));
    assert.equal(failed.error.code, 'RELOAD_FAILED');
    assert.equal(failed.data.restored, false);
    const dead = parse(await client.callTool({ name: 'ConnectIde', arguments: {} }));
    assert.equal(dead.error.code, 'MODULE_IMPORT_FAILED', 'no module is loaded now');
    // reloading the same broken path again fails again ...
    const again = parse(await client.callTool({ name: 'ReloadModule', arguments: {} }));
    assert.equal(again.success, false);
    // ... but switching to another allowed path recovers
    const ok = parse(await client.callTool({ name: 'ReloadModule', arguments: { ModulePath: r.mod(r.wt) } }));
    assert.equal(ok.success, true, JSON.stringify(ok));
    assert.equal(ok.data.current.moduleCommit, SHA_WT);
    assert.equal(parse(await client.callTool({ name: 'ConnectIde', arguments: {} })).success, true);
  });
});

// ---------------------------------------------------------------- module source code contract

describe('module state the bridge relies on is defined in src (#129 review)', () => {
  const priv = path.join(__dirname, '..', '..', 'src', 'TwinCATAutomation', 'Private');
  test('LifecycleBlock.ps1 defines $script:TcLifecycleBlockLocal and Get-TcLifecycleBlockLocalForReload', () => {
    const t = fs.readFileSync(path.join(priv, 'LifecycleBlock.ps1'), 'utf8');
    assert.match(t, /^\$script:TcLifecycleBlockLocal = @\{\}/m);
    assert.match(t, /^function Get-TcLifecycleBlockLocalForReload\b/m);
  });
  test('Set-TcBuildRequired.ps1 defines $script:TcBuildRequiredLocal and the helpers retire calls', () => {
    const t = fs.readFileSync(path.join(priv, 'Set-TcBuildRequired.ps1'), 'utf8');
    assert.match(t, /^\$script:TcBuildRequiredLocal = @\{\}/m);
    for (const fn of ['Invoke-TcBuildRequiredLocked', 'Read-TcBuildRequiredState', 'Write-TcBuildRequiredState', 'Merge-TcBuildRequiredEntry', 'Get-TcBuildRequiredReasons', 'Get-TcEntryGuard']) {
      assert.match(t, new RegExp(`^function ${fn}\\b`, 'm'), fn);
    }
  });
  test('bridge.ps1 calls exactly those helpers', () => {
    const t = fs.readFileSync(path.join(__dirname, '..', 'bridge', 'bridge.ps1'), 'utf8');
    for (const name of ['Get-TcLifecycleBlockLocalForReload', 'TcBuildRequiredLocal', 'Invoke-TcBuildRequiredLocked', 'Read-TcBuildRequiredState', 'Write-TcBuildRequiredState', 'Merge-TcBuildRequiredEntry']) {
      assert.ok(t.includes(name), name);
    }
  });
});

// ---------------------------------------------------------------- real bridge.ps1

describe('bridge.ps1 op retire (real PowerShell, fixture module)', { skip: !isWin && 'Windows PowerShell only' }, () => {
  const stateDir = newStateDir();
  const bridges = [];
  after(async () => {
    for (const b of bridges) await b.stop();
  });
  const make = (env = {}) => {
    const b = new PowerShellBridge({ modulePath: RELOAD_MODULE, env: { TCAUTO_STATE_DIR: stateDir, TCAUTO_TEST_FORBID_REAL_STATE: '1', ...env } });
    bridges.push(b);
    return b;
  };
  const readBuildState = (dir) => {
    const f = path.join(dir, 'build-required.json');
    return fs.existsSync(f) ? JSON.parse(fs.readFileSync(f, 'utf8').replace(/^﻿/, '')) : {};
  };

  test('in-memory-only BUILD_REQUIRED entry is written to build-required.json by retire', async () => {
    const dir = newStateDir();
    const b = make({ TCAUTO_STATE_DIR: dir });
    await b.start();
    const sln = path.join(dir, 'Demo41.sln');
    const mark = await b.call('call', { cmdlet: 'Register-TcCodeChange', params: { SolutionPath: sln, LocalOnly: true } });
    assert.equal(mark.success, true, JSON.stringify(mark));
    const key = mark.data.key;
    assert.equal(readBuildState(dir)[key], undefined, 'not in the file yet');
    const res = await b.retire(RELOAD_MODULE, { timeoutMs: 60000 });
    assert.equal(res.success, true, JSON.stringify(res));
    assert.deepEqual(res.data.buildRequiredPersisted, [key]);
    const entry = readBuildState(dir)[key];
    assert.ok(entry, 'written to the file');
    assert.match(JSON.stringify(entry), /PLC code changed by fixture/);
  });

  test('BUILD_REQUIRED entry already in the file: retire does not rewrite it', async () => {
    const dir = newStateDir();
    const b = make({ TCAUTO_STATE_DIR: dir });
    await b.start();
    const mark = await b.call('call', { cmdlet: 'Register-TcCodeChange', params: { SolutionPath: path.join(dir, 'Same41.sln') } });
    assert.equal(mark.success, true, JSON.stringify(mark));
    assert.ok(readBuildState(dir)[mark.data.key], 'Set-TcBuildRequired wrote the file');
    const res = await b.retire(RELOAD_MODULE, { timeoutMs: 60000 });
    assert.equal(res.success, true, JSON.stringify(res));
    assert.deepEqual(res.data.buildRequiredKeys, [mark.data.key]);
    assert.deepEqual(res.data.buildRequiredPersisted, []);
  });

  test('BUILD_REQUIRED entry that cannot be written: RELOAD_BUILD_REQUIRED, same process', async () => {
    const dir = newStateDir();
    const b = make({ TCAUTO_STATE_DIR: dir });
    await b.start();
    const pid1 = b.pid;
    await b.call('call', { cmdlet: 'Register-TcCodeChange', params: { SolutionPath: path.join(dir, 'Locked41.sln'), LocalOnly: true } });
    fs.mkdirSync(path.join(dir, 'build-required.json')); // a directory where the file must go: write fails
    const res = await b.retire(RELOAD_MODULE, { timeoutMs: 60000 });
    assert.equal(res.success, false, JSON.stringify(res));
    assert.equal(res.error.code, 'RELOAD_BUILD_REQUIRED');
    assert.equal(res.data.notRun, true);
    assert.equal(res.data.buildRequiredKeys.length, 1);
    assert.equal(b.pid, pid1, 'bridge not restarted');
  });

  // #41 review round 2: the shas to verify (#42, #114, #119, #120, #122, #127) predate #41: their
  // module has the variables but not the helpers. Reload into such a module and back out of it.
  test('old-format module (variables, no helpers): reload into it and out of it again', async () => {
    const b = make();
    await b.start();
    assert.match(b.ready.modulePath, /reload-module[\\/]/);
    const into = await b.retire(RELOAD_MODULE_OLD, { timeoutMs: 60000 });
    assert.equal(into.success, true, JSON.stringify(into));
    assert.equal((await b.call('state')).success, true);
    assert.match(b.ready.modulePath, /reload-module-old/);
    const out = await b.retire(RELOAD_MODULE, { timeoutMs: 60000 });
    assert.equal(out.success, true, JSON.stringify(out));
    assert.equal((await b.call('state')).success, true);
    assert.doesNotMatch(b.ready.modulePath, /reload-module-old/);
  });

  test('old-format module with an in-memory lifecycle block: still RELOAD_LIFECYCLE_BLOCKED', async () => {
    const b = new PowerShellBridge({ modulePath: RELOAD_MODULE_OLD, env: { TCAUTO_STATE_DIR: newStateDir(), TCAUTO_TEST_FORBID_REAL_STATE: '1' } });
    bridges.push(b);
    await b.start();
    const pid1 = b.pid;
    await b.call('call', { cmdlet: 'Set-TcSystemState', params: { AmsNetId: '5.1.2.3.1.1' } });
    const res = await b.retire(RELOAD_MODULE, { timeoutMs: 60000 });
    assert.equal(res.success, false, JSON.stringify(res));
    assert.equal(res.error.code, 'RELOAD_LIFECYCLE_BLOCKED');
    assert.equal(res.data.lifecycleBlocks[0].key, '5.1.2.3.1.1');
    assert.equal(b.pid, pid1);
  });

  test('old-format module: an in-memory-only BUILD_REQUIRED entry is added to the file by the bridge fallback', async () => {
    const dir = newStateDir();
    const b = new PowerShellBridge({ modulePath: RELOAD_MODULE_OLD, env: { TCAUTO_STATE_DIR: dir, TCAUTO_TEST_FORBID_REAL_STATE: '1' } });
    bridges.push(b);
    await b.start();
    const inFile = await b.call('call', { cmdlet: 'Register-TcCodeChange', params: { SolutionPath: path.join(dir, 'InFile41.sln') } });
    const local = await b.call('call', { cmdlet: 'Register-TcCodeChange', params: { SolutionPath: path.join(dir, 'Old41.sln'), LocalOnly: true } });
    assert.equal(local.success, true, JSON.stringify(local));
    const res = await b.retire(RELOAD_MODULE, { timeoutMs: 60000 });
    assert.equal(res.success, true, JSON.stringify(res));
    assert.deepEqual(res.data.buildRequiredPersisted, [local.data.key], 'only the key missing from the file');
    const doc = readBuildState(dir);
    assert.ok(doc[local.data.key]);
    assert.ok(doc[inFile.data.key]);
  });

  test('old-format module: BUILD_REQUIRED entry that cannot be written -> RELOAD_BUILD_REQUIRED', async () => {
    const dir = newStateDir();
    const b = new PowerShellBridge({ modulePath: RELOAD_MODULE_OLD, env: { TCAUTO_STATE_DIR: dir, TCAUTO_TEST_FORBID_REAL_STATE: '1' } });
    bridges.push(b);
    await b.start();
    await b.call('call', { cmdlet: 'Register-TcCodeChange', params: { SolutionPath: path.join(dir, 'OldLocked41.sln'), LocalOnly: true } });
    fs.mkdirSync(path.join(dir, 'build-required.json'));
    const res = await b.retire(RELOAD_MODULE, { timeoutMs: 60000 });
    assert.equal(res.success, false, JSON.stringify(res));
    assert.equal(res.error.code, 'RELOAD_BUILD_REQUIRED');
    assert.match(res.data.error, /Merge-TcBuildRequiredEntry/);
  });

  test('old-format module without $script:TcLifecycleBlockLocal (older than #68) -> refused', async () => {
    const b = new PowerShellBridge({ modulePath: RELOAD_MODULE_OLD, env: { TCAUTO_STATE_DIR: newStateDir(), TCAUTO_TEST_FORBID_REAL_STATE: '1', TCAUTO_TEST_RELOAD_DROP_VAR: 'lifecycle' } });
    bridges.push(b);
    await b.start();
    const res = await b.retire(RELOAD_MODULE, { timeoutMs: 60000 });
    assert.equal(res.error.code, 'RELOAD_LIFECYCLE_BLOCKED');
    assert.equal(res.data.lifecycleBlocks[0].key, '<missing>');
  });

  for (const [drop, code] of [['lifecycle', 'RELOAD_LIFECYCLE_BLOCKED'], ['build', 'RELOAD_BUILD_REQUIRED']]) {
    test(`module without $script:Tc${drop === 'lifecycle' ? 'LifecycleBlock' : 'BuildRequired'}Local -> ${code} (fail closed)`, async () => {
      const b = make({ TCAUTO_TEST_RELOAD_DROP_VAR: drop });
      await b.start();
      const res = await b.retire(RELOAD_MODULE, { timeoutMs: 60000 });
      assert.equal(res.success, false, JSON.stringify(res));
      assert.equal(res.error.code, code);
      if (drop === 'lifecycle') assert.equal(res.data.lifecycleBlocks[0].key, '<unreadable>');
      else assert.match(res.data.error, /TcBuildRequiredLocal/);
    });
  }


  test('no block: retire releases IDE/ADS, answers, and the next call runs in a new process', async () => {
    const b = make();
    await b.start();
    const pid1 = b.pid;
    assert.equal((await b.call('call', { cmdlet: 'Connect-TcIde', params: {} })).success, true);
    const res = await b.retire(RELOAD_MODULE, { timeoutMs: 60000 });
    assert.equal(res.success, true, JSON.stringify(res));
    assert.equal(res.data.retired, true);
    assert.equal(res.data.ideWasConnected, true);
    assert.match(res.data.modulePath, /reload-module/);
    const st = await b.call('state');
    assert.equal(st.success, true);
    assert.equal(st.data.ideConnected, false);
    assert.notEqual(b.pid, pid1, 'a new bridge process');
  });

  test('in-memory lifecycle block: RELOAD_LIFECYCLE_BLOCKED, same process, block still there', async () => {
    const b = make();
    await b.start();
    const pid1 = b.pid;
    await b.call('call', { cmdlet: 'Set-TcSystemState', params: { AmsNetId: '5.1.2.3.1.1' } });
    const res = await b.retire(RELOAD_MODULE, { timeoutMs: 60000 });
    assert.equal(res.success, false);
    assert.equal(res.error.code, 'RELOAD_LIFECYCLE_BLOCKED');
    assert.match(res.error.hint, /ClearLifecycleBlock/);
    assert.equal(res.data.notRun, true);
    assert.equal(res.data.lifecycleBlocks.length, 1);
    assert.equal(res.data.lifecycleBlocks[0].key, '5.1.2.3.1.1');
    assert.equal(b.pid, pid1, 'bridge not restarted');
    const again = await b.retire(RELOAD_MODULE, { timeoutMs: 60000 });
    assert.equal(again.error.code, 'RELOAD_LIFECYCLE_BLOCKED', 'the block is still in memory');
  });
});
