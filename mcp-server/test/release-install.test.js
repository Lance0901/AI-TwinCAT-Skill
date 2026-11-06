// #20 customer release: scripts/Build-TcAutoRelease.ps1 builds a zip of this checkout, the zip's
// Install-TcAuto.ps1 installs it into a temp install root and registers it in three fake client
// configs (each holding another server and an old tcauto), -Verify lists the tools with node removed
// from PATH, -Uninstall takes it out again. Plus unit tests of scripts/lib/tcauto-client-config.mjs.
// Isolation: every folder is below os.tmpdir() and contains "issue20"; every installer run passes
// -InstallRoot and all three config paths, with TCAUTO_TEST_FORBID_REAL_STATE=1, an empty
// TCAUTO_RUNTIME_ROOT and its own TCAUTO_STATE_DIR. The real ~/.claude.json, Claude Desktop / Codex
// configs and %LOCALAPPDATA%\TwinCATAutomation are never read or written. The Claude Desktop
// location test (#165) passes fake -LocalAppDataRoot / -AppDataRoot folders (names hold "issue165").
// node.exe in the zip: a copy of this test's own node plus one byte (never the pinned build,
// -AllowUnverifiedNode); npm is a
// stand-in that copies mcp-server\node_modules of this checkout (no registry access).
// Windows only (powershell.exe, tar.exe).
import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { setJson, removeJson, setToml, removeToml, applyToFile, tomlString, isOwned, usageOf, longPath } from '../../scripts/lib/tcauto-client-config.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(__dirname, '..', '..');
const BUILD = path.join(REPO, 'scripts', 'Build-TcAutoRelease.ps1');
const isWin = process.platform === 'win32';
const SYS = process.env.SystemRoot ?? 'C:\\Windows';
const POWERSHELL = path.join(SYS, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
const TAR = path.join(SYS, 'System32', 'tar.exe');

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
  const d = fs.mkdtempSync(path.join(os.tmpdir(), `tcauto-${prefix}-issue20-`));
  dirs.push(d);
  return d;
}
function put(file, text) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, text);
}
const readJson = (f) => JSON.parse(fs.readFileSync(f, 'utf8'));
const sha256 = (f) => crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex');

function resultOf(r) {
  const line = (r.stdout ?? '').split(/\r?\n/).reverse().find((l) => l.startsWith('TCAUTO_INSTALL_RESULT '));
  assert.ok(line, `no result line; exit ${r.status}\nstdout: ${r.stdout}\nstderr: ${r.stderr}`);
  return { code: r.status, result: JSON.parse(line.slice('TCAUTO_INSTALL_RESULT '.length)), stdout: r.stdout };
}

/** PATH without any folder that holds node.exe (System32 + Windows PowerShell only) */
function pathWithoutNode() {
  const p = [path.join(SYS, 'System32'), SYS, path.join(SYS, 'System32', 'WindowsPowerShell', 'v1.0')];
  for (const d of p) assert.ok(!fs.existsSync(path.join(d, 'node.exe')), `${d} has no node.exe`);
  return p.join(';');
}

describe('release zip + Install-TcAuto.ps1 (#20)', { skip: !isWin && 'Windows only' }, () => {
  let build; // build result data
  let pkg; // extracted zip
  let stateDir;
  let fakeNode; // node.exe put into the zip

  function runInstaller(args, { noNode = false } = {}) {
    const env = { ...process.env, TCAUTO_TEST_FORBID_REAL_STATE: '1', TCAUTO_RUNTIME_ROOT: '', TCAUTO_STATE_DIR: stateDir };
    if (noNode) {
      for (const k of Object.keys(env)) if (k.toUpperCase() === 'PATH') delete env[k];
      env.Path = pathWithoutNode();
    }
    const r = spawnSync(POWERSHELL, ['-NoProfile', '-NonInteractive', '-File', path.join(pkg, 'Install-TcAuto.ps1'), ...args], { encoding: 'utf8', env, timeout: 240000 });
    return resultOf(r);
  }

  /** a fake user profile: three client configs with another server and an old tcauto */
  function fakeClients() {
    const home = tmp('home');
    const files = {
      code: path.join(home, '.claude.json'),
      desktop: path.join(home, 'AppData', 'Roaming', 'Claude', 'claude_desktop_config.json'),
      codex: path.join(home, '.codex', 'config.toml')
    };
    put(
      files.code,
      JSON.stringify(
        {
          numStartups: 7,
          mcpServers: { other: { type: 'stdio', command: 'other.exe', args: ['-x'], env: { A: '1' } }, tcauto: { type: 'stdio', command: 'node', args: ['C:\\dev\\repo\\mcp-server\\index.js'], env: {} } },
          projects: { 'C:/work/p': { mcpServers: { tcauto: { command: 'project-scope-stays' } }, allowedTools: [] } }
        },
        null,
        2
      )
    );
    put(files.desktop, '{\r\n    "mcpServers": {\r\n        "fs": { "command": "npx", "args": ["-y", "fs"] }\r\n    },\r\n    "globalShortcut": "Ctrl+Space"\r\n}\r\n');
    put(files.codex, "model = 'o3'\n\n[mcp_servers.other]\ncommand = 'other.exe'\nargs = ['-x']\n\n[mcp_servers.tcauto]\ncommand = 'node'\nargs = ['C:\\dev\\old.js']\n\n[mcp_servers.tcauto.env]\nA = '1'\n\n[profiles.fast]\nmodel = 'mini'\n");
    const original = Object.fromEntries(Object.entries(files).map(([k, f]) => [k, fs.readFileSync(f, 'utf8')]));
    return { home, files, original, args: ['-ClaudeCodeConfig', files.code, '-ClaudeDesktopConfig', files.desktop, '-CodexConfig', files.codex] };
  }

  before(() => {
    stateDir = tmp('state');
    const out = tmp('dist');
    const npmDir = tmp('npmstub');
    const npm = path.join(npmDir, 'npm-copy.cmd');
    const nm = path.join(REPO, 'mcp-server', 'node_modules');
    assert.ok(fs.existsSync(path.join(nm, '@modelcontextprotocol', 'sdk', 'package.json')), 'run npm ci in mcp-server first');
    // robocopy (xcopy fails with exit 4 when stdin is not a console); exit codes below 8 mean success
    fs.writeFileSync(npm, `@echo off\r\nrobocopy "${nm}" node_modules /E /NFL /NDL /NJH /NJS /NP >nul\r\nif %ERRORLEVEL% GEQ 8 exit /b %ERRORLEVEL%\r\nexit /b 0\r\n`);
    // a node.exe that is certainly not the pinned build (CI may run exactly the pinned version):
    // this node plus one byte at the end (PE overlay, it still runs)
    fakeNode = path.join(tmp('node'), 'node.exe');
    fs.copyFileSync(process.execPath, fakeNode);
    fs.appendFileSync(fakeNode, Buffer.from([0]));
    const r = spawnSync(
      POWERSHELL,
      ['-NoProfile', '-NonInteractive', '-File', BUILD, '-OutputDir', out, '-Version', '0.0.0-issue20.test', '-AllowDirty', '-NodeExePath', fakeNode, '-AllowUnverifiedNode', '-NpmPath', npm],
      { encoding: 'utf8', env: { ...process.env, TCAUTO_TEST_FORBID_REAL_STATE: '1', TCAUTO_STATE_DIR: stateDir }, timeout: 400000 }
    );
    const { code, result } = resultOf(r);
    assert.equal(code, 0, JSON.stringify(result));
    build = result.data;
    pkg = tmp('pkg');
    const x = spawnSync(TAR, ['-xf', build.zip, '-C', pkg], { encoding: 'utf8' });
    assert.equal(x.status, 0, x.stderr);
  });

  test('build: zip + .sha256, layout, manifest, runtime without test\\ and with node_modules', () => {
    assert.equal(path.basename(build.zip), 'TcAuto-0.0.0-issue20.test.zip');
    const shaLine = fs.readFileSync(build.sha256File, 'utf8');
    assert.equal(shaLine, `${sha256(build.zip)}  TcAuto-0.0.0-issue20.test.zip\n`);
    for (const f of ['Install-TcAuto.ps1', 'README.txt', 'tcauto-release.json', 'lib\\TcAutoInstall.ps1', 'lib\\tcauto-client-config.mjs', 'node\\node.exe', 'launcher\\tcauto-launcher.mjs']) {
      assert.ok(fs.existsSync(path.join(pkg, f)), f);
    }
    const manifest = readJson(path.join(pkg, 'tcauto-release.json'));
    assert.equal(manifest.version, '0.0.0-issue20.test');
    assert.equal(manifest.node.verified, false, 'a local node.exe that is not the pinned build is marked');
    assert.equal(manifest.node.sha256, sha256(fakeNode));
    const runtimes = fs.readdirSync(path.join(pkg, 'runtime'));
    assert.deepEqual(runtimes, [build.runtimeVersion]);
    const rt = path.join(pkg, 'runtime', build.runtimeVersion);
    const stamp = readJson(path.join(rt, 'tcauto-source.json'));
    assert.equal(stamp.kind, 'tcauto-runtime');
    assert.equal(stamp.release, '0.0.0-issue20.test');
    assert.equal(stamp.version, build.runtimeVersion);
    assert.equal(stamp.sourcePath, null, 'the build machine path is not in a release');
    assert.ok(fs.existsSync(path.join(rt, 'mcp-server', 'index.js')));
    assert.ok(fs.existsSync(path.join(rt, 'mcp-server', 'node_modules', '@modelcontextprotocol', 'sdk', 'package.json')));
    assert.ok(fs.existsSync(path.join(rt, 'src', 'TwinCATAutomation', 'TwinCATAutomation.psm1')));
    assert.ok(!fs.existsSync(path.join(rt, 'mcp-server', 'test')), 'test\\ is not shipped');
    assert.ok(!fs.existsSync(path.join(rt, 'scripts')), 'only mcp-server and src\\TwinCATAutomation in the runtime');
  });

  test('install: merge into three configs (backup, old value listed), -Verify without node on PATH, reinstall reuses, -Uninstall', () => {
    const root = path.join(tmp('root'), 'TwinCATAutomation');
    const c = fakeClients();
    // the installer writes the long form of the path (TEMP may be 8.3, e.g. C:\Users\RUNNER~1 on CI)
    const longRoot = path.join(longPath(path.dirname(root)), 'TwinCATAutomation');
    const nodeExe = path.join(longRoot, 'node', 'node.exe');
    const launcher = path.join(longRoot, 'launcher', 'tcauto-launcher.mjs');

    const ins = runInstaller(['-InstallRoot', root, ...c.args], { noNode: true });
    assert.equal(ins.code, 0, JSON.stringify(ins.result));
    const d = ins.result.data;
    assert.equal(d.installRoot.toLowerCase(), longRoot.toLowerCase());
    assert.equal(d.version, build.runtimeVersion);
    assert.equal(d.release, '0.0.0-issue20.test');
    assert.equal(sha256(nodeExe), sha256(fakeNode));
    assert.equal(readJson(path.join(root, 'runtime', 'current.json')).version, build.runtimeVersion);
    assert.equal(fs.readFileSync(launcher, 'utf8'), fs.readFileSync(path.join(REPO, 'mcp-server', 'launcher', 'tcauto-launcher.mjs'), 'utf8'));
    assert.ok(d.verify.toolCount > 0, JSON.stringify(d.verify));
    assert.equal(d.verify.hasReloadRuntime, true);
    assert.equal(d.verify.runtime.commit, build.commit);
    assert.ok('found' in d.twincat);

    const byClient = Object.fromEntries(d.clients.map((r) => [r.client, r]));
    assert.equal(byClient.ClaudeCode.action, 'updated');
    assert.deepEqual(byClient.ClaudeCode.previous, { type: 'stdio', command: 'node', args: ['C:\\dev\\repo\\mcp-server\\index.js'], env: {} });
    assert.equal(byClient.ClaudeDesktop.action, 'added');
    assert.equal(byClient.Codex.action, 'updated');
    assert.match(byClient.Codex.previous, /\[mcp_servers\.tcauto\][\s\S]*old\.js[\s\S]*\[mcp_servers\.tcauto\.env\]/);
    for (const [k, r] of [['code', byClient.ClaudeCode], ['desktop', byClient.ClaudeDesktop], ['codex', byClient.Codex]]) {
      assert.match(path.basename(r.backup), /\.bak-\d{8}T\d{6}$/);
      assert.equal(fs.readFileSync(r.backup, 'utf8'), c.original[k], `${k} backup is the original`);
    }

    // Claude Code: user scope, other server + other keys + project scope untouched
    const code = readJson(c.files.code);
    assert.deepEqual(code.mcpServers.tcauto, { type: 'stdio', command: nodeExe, args: [launcher], env: {} });
    assert.deepEqual(code.mcpServers.other, { type: 'stdio', command: 'other.exe', args: ['-x'], env: { A: '1' } });
    assert.equal(code.numStartups, 7);
    assert.deepEqual(code.projects['C:/work/p'].mcpServers.tcauto, { command: 'project-scope-stays' });
    // Claude Desktop: indent 4 and CRLF kept, no BOM
    const deskText = fs.readFileSync(c.files.desktop, 'utf8');
    assert.ok(!deskText.startsWith('\uFEFF'));
    assert.match(deskText, /\r\n {4}"mcpServers"/);
    const desk = JSON.parse(deskText);
    assert.deepEqual(desk.mcpServers.tcauto, { command: nodeExe, args: [launcher] });
    assert.deepEqual(desk.mcpServers.fs, { command: 'npx', args: ['-y', 'fs'] });
    assert.equal(desk.globalShortcut, 'Ctrl+Space');
    // Codex: old tcauto table and its sub-table replaced, the rest kept
    const toml = fs.readFileSync(c.files.codex, 'utf8');
    assert.ok(!/old\.js|\[mcp_servers\.tcauto\.env\]/.test(toml), toml);
    assert.ok(toml.includes(`[mcp_servers.tcauto]\ncommand = '${nodeExe}'\nargs = ['${launcher}']\n`), toml);
    for (const s of ["model = 'o3'", "[mcp_servers.other]\ncommand = 'other.exe'\nargs = ['-x']", "[profiles.fast]\nmodel = 'mini'"]) assert.ok(toml.includes(s), s);

    // reinstall of the same zip: runtime reused, configs unchanged, no new backup
    const backupsBefore = fs.readdirSync(c.home, { recursive: true }).filter((n) => /\.bak-/.test(n)).length;
    const again = runInstaller(['-InstallRoot', root, ...c.args, '-NoVerify']);
    assert.equal(again.code, 0, JSON.stringify(again.result));
    assert.equal(again.result.data.reused, true);
    assert.equal(again.result.data.node.updated, false);
    assert.deepEqual(again.result.data.clients.map((r) => r.action), ['unchanged', 'unchanged', 'unchanged']);
    assert.equal(fs.readdirSync(c.home, { recursive: true }).filter((n) => /\.bak-/.test(n)).length, backupsBefore);

    // -Verify alone, node not on PATH: the installed node.exe runs launcher + runtime
    const v = runInstaller(['-InstallRoot', root, '-Verify'], { noNode: true });
    assert.equal(v.code, 0, JSON.stringify(v.result));
    assert.equal(v.result.data.verify.toolCount, d.verify.toolCount);
    assert.equal(v.result.data.verify.runtime.version, build.runtimeVersion);

    // -Uninstall: a foreign tcauto (Desktop, pointing elsewhere) stays; state files in the root stay
    const deskNow = readJson(c.files.desktop);
    deskNow.mcpServers.tcauto = { command: 'C:\\elsewhere\\node.exe', args: ['x.mjs'] };
    put(c.files.desktop, JSON.stringify(deskNow, null, 2));
    put(path.join(root, 'ide-solutions.json'), '{"keep":true}');
    const un = runInstaller(['-InstallRoot', root, ...c.args, '-Uninstall']);
    assert.equal(un.code, 0, JSON.stringify(un.result));
    const ub = Object.fromEntries(un.result.data.clients.map((r) => [r.client, r]));
    assert.equal(ub.ClaudeCode.action, 'removed');
    assert.equal(ub.ClaudeDesktop.action, 'foreign');
    assert.equal(ub.Codex.action, 'removed');
    assert.ok(fs.existsSync(ub.ClaudeCode.backup) && fs.existsSync(ub.Codex.backup));
    const codeAfter = readJson(c.files.code);
    assert.ok(!('tcauto' in codeAfter.mcpServers));
    assert.ok('other' in codeAfter.mcpServers);
    assert.deepEqual(codeAfter.projects['C:/work/p'].mcpServers.tcauto, { command: 'project-scope-stays' });
    assert.equal(readJson(c.files.desktop).mcpServers.tcauto.command, 'C:\\elsewhere\\node.exe');
    const tomlAfter = fs.readFileSync(c.files.codex, 'utf8');
    assert.ok(!tomlAfter.includes('[mcp_servers.tcauto]'));
    assert.ok(tomlAfter.includes('[mcp_servers.other]') && tomlAfter.includes('[profiles.fast]'));
    for (const f of ['node', 'launcher', 'runtime']) assert.ok(!fs.existsSync(path.join(root, f)), `${f} removed`);
    assert.equal(fs.readFileSync(path.join(root, 'ide-solutions.json'), 'utf8'), '{"keep":true}', 'other files of the install root stay');
    assert.equal(un.result.data.installRootRemoved, false);
  });

  test('-Uninstall with a registration that only passes a file of this install (node <root>\\launcher\\...): INSTALL_SHARED, nothing removed; -Force removes it', () => {
    const root = path.join(tmp('root'), 'TwinCATAutomation');
    const c = fakeClients();
    // as tmp() gives it: on CI an 8.3 path (C:\Users\RUNNER~1\...), while the install root is long
    const launcher = path.join(root, 'launcher', 'tcauto-launcher.mjs');
    const ins = runInstaller(['-InstallRoot', root, ...c.args, '-NoVerify']);
    assert.equal(ins.code, 0, JSON.stringify(ins.result));
    // a developer registration: command 'node' from PATH, the installed launcher as its arg
    const desk = readJson(c.files.desktop);
    desk.mcpServers.tcauto = { command: 'node', args: [launcher] };
    put(c.files.desktop, JSON.stringify(desk, null, 2));

    const un = runInstaller(['-InstallRoot', root, ...c.args, '-Uninstall']);
    assert.equal(un.code, 1, JSON.stringify(un.result));
    assert.equal(un.result.error.code, 'INSTALL_SHARED');
    assert.match(un.result.error.hint, /-Force/);
    const ub = Object.fromEntries(un.result.data.clients.map((r) => [r.client, r]));
    assert.equal(ub.ClaudeDesktop.action, 'shared');
    assert.deepEqual(readJson(c.files.desktop).mcpServers.tcauto, { command: 'node', args: [launcher] }, 'the shared entry is left');
    for (const f of ['node\\node.exe', 'launcher\\tcauto-launcher.mjs', 'runtime\\current.json']) assert.ok(fs.existsSync(path.join(root, f)), `${f} not removed`);

    const forced = runInstaller(['-InstallRoot', root, ...c.args, '-Uninstall', '-Force']);
    assert.equal(forced.code, 0, JSON.stringify(forced.result));
    assert.equal(forced.result.data.clients.find((r) => r.client === 'ClaudeDesktop').action, 'removed');
    assert.ok(!('tcauto' in readJson(c.files.desktop).mcpServers));
    assert.ok('fs' in readJson(c.files.desktop).mcpServers);
    for (const f of ['node', 'launcher', 'runtime']) assert.ok(!fs.existsSync(path.join(root, f)), `${f} removed`);
  });

  test('a client without config file / folder is skipped and reported; -Clients selects', () => {
    const root = path.join(tmp('root'), 'TwinCATAutomation');
    const home = tmp('home');
    const codex = path.join(home, '.codex', 'config.toml');
    fs.mkdirSync(path.dirname(codex));
    const r = runInstaller(['-InstallRoot', root, '-NoVerify', '-Clients', 'ClaudeCode,ClaudeDesktop', '-ClaudeCodeConfig', path.join(home, '.claude.json'), '-ClaudeDesktopConfig', path.join(home, 'nope', 'Claude', 'claude_desktop_config.json'), '-CodexConfig', codex]);
    assert.equal(r.code, 0, JSON.stringify(r.result));
    assert.deepEqual(r.result.data.clients.map((x) => [x.client, x.action]), [['ClaudeCode', 'skipped'], ['ClaudeDesktop', 'skipped']]);
    assert.ok(r.result.data.clients.every((x) => x.reason));
    assert.ok(!fs.existsSync(path.join(home, '.claude.json')), 'no ~/.claude.json created');
    assert.ok(!fs.existsSync(codex), 'Codex not in -Clients: not written');

    const bad = runInstaller(['-InstallRoot', root, '-NoVerify', '-Clients', 'Cursor']);
    assert.equal(bad.code, 1);
    assert.equal(bad.result.error.code, 'BAD_ARGUMENT');
  });

  test('Claude Desktop (#165): MSIX Claude-Data\\claude_*\\ and/or standard %APPDATA%\\Claude\\, one row per file, -Uninstall removes all', () => {
    // fake LOCALAPPDATA / APPDATA roots (names hold "issue165"), passed with -LocalAppDataRoot / -AppDataRoot
    const tmp165 = (prefix) => {
      const d = fs.mkdtempSync(path.join(os.tmpdir(), `tcauto-${prefix}-issue165-`));
      dirs.push(d);
      return d;
    };
    const root = path.join(tmp165('root'), 'TwinCATAutomation');
    const longRoot = path.join(longPath(path.dirname(root)), 'TwinCATAutomation');
    const entry = { command: path.join(longRoot, 'node', 'node.exe'), args: [path.join(longRoot, 'launcher', 'tcauto-launcher.mjs')] };
    const msixConfig = (local) => path.join(local, 'Claude-Data', 'claude_testhash', 'claude_desktop_config.json');
    const putMsix = (local) => {
      const f = msixConfig(local);
      put(f, JSON.stringify({ preferences: { quickEntryShortcut: 'off', sidebarMode: 'chat' }, coworkUserFilesPath: 'C:\\x', mcpServers: { fs: { command: 'npx', args: ['-y', 'fs'] } } }, null, 2));
      return f;
    };
    const desktopRun = (local, roaming, extra = []) => runInstaller(['-InstallRoot', root, '-NoVerify', '-Clients', 'ClaudeDesktop', '-LocalAppDataRoot', local, '-AppDataRoot', roaming, ...extra]);
    // files compared in long form (TEMP may be 8.3 on CI runners)
    const L = (f) => longPath(f).toLowerCase();
    const rowsOf = (r) => r.result.data.clients.map((x) => [x.client, x.variant, x.action, L(x.file)]);

    // MSIX only: written there, other keys kept, no %APPDATA%\Claude created
    let local = tmp165('local');
    let roaming = tmp165('roaming');
    const m1 = putMsix(local);
    let r = desktopRun(local, roaming);
    assert.equal(r.code, 0, JSON.stringify(r.result));
    assert.deepEqual(rowsOf(r), [['ClaudeDesktop', 'msix', 'added', L(m1)]]);
    let cfg = readJson(m1);
    assert.deepEqual(cfg.mcpServers.tcauto, entry);
    assert.deepEqual(cfg.mcpServers.fs, { command: 'npx', args: ['-y', 'fs'] });
    assert.deepEqual(cfg.preferences, { quickEntryShortcut: 'off', sidebarMode: 'chat' });
    assert.equal(cfg.coworkUserFilesPath, 'C:\\x');
    assert.ok(!fs.existsSync(path.join(roaming, 'Claude')), 'no %APPDATA%\\Claude created');

    // standard only (Claude-Data without claude_* does not count): %APPDATA%\Claude written
    local = tmp165('local');
    roaming = tmp165('roaming');
    fs.mkdirSync(path.join(local, 'Claude-Data', 'other'), { recursive: true });
    const s1 = path.join(roaming, 'Claude', 'claude_desktop_config.json');
    put(s1, '{"globalShortcut":"Ctrl+Space"}');
    r = desktopRun(local, roaming);
    assert.equal(r.code, 0, JSON.stringify(r.result));
    assert.deepEqual(rowsOf(r), [['ClaudeDesktop', 'standard', 'added', L(s1)]]);
    assert.deepEqual(readJson(s1), { globalShortcut: 'Ctrl+Space', mcpServers: { tcauto: entry } });

    // neither: the standard row is skipped (folder missing), nothing created
    local = tmp165('local');
    roaming = tmp165('roaming');
    r = desktopRun(local, roaming);
    assert.equal(r.code, 0, JSON.stringify(r.result));
    assert.deepEqual(r.result.data.clients.map((x) => [x.variant, x.action]), [['standard', 'skipped']]);
    assert.deepEqual(fs.readdirSync(roaming), []);

    // both: both written; -ClaudeDesktopConfig overrides; -Uninstall removes both
    local = tmp165('local');
    roaming = tmp165('roaming');
    const m2 = putMsix(local);
    const s2 = path.join(roaming, 'Claude', 'claude_desktop_config.json');
    put(s2, '{"mcpServers":{}}');
    r = desktopRun(local, roaming);
    assert.equal(r.code, 0, JSON.stringify(r.result));
    assert.deepEqual(rowsOf(r), [['ClaudeDesktop', 'msix', 'added', L(m2)], ['ClaudeDesktop', 'standard', 'added', L(s2)]]);
    assert.deepEqual(readJson(m2).mcpServers.tcauto, entry);
    assert.deepEqual(readJson(s2).mcpServers.tcauto, entry);
    const override = path.join(tmp165('override'), 'claude_desktop_config.json');
    r = desktopRun(local, roaming, ['-ClaudeDesktopConfig', override]);
    assert.equal(r.code, 0, JSON.stringify(r.result));
    assert.deepEqual(rowsOf(r), [['ClaudeDesktop', 'override', 'added', L(override)]]);

    const un = desktopRun(local, roaming, ['-Uninstall']);
    assert.equal(un.code, 0, JSON.stringify(un.result));
    assert.deepEqual(rowsOf(un), [['ClaudeDesktop', 'msix', 'removed', L(m2)], ['ClaudeDesktop', 'standard', 'removed', L(s2)]]);
    assert.ok(!('tcauto' in readJson(m2).mcpServers));
    assert.ok('fs' in readJson(m2).mcpServers);
    assert.deepEqual(readJson(m2).preferences, { quickEntryShortcut: 'off', sidebarMode: 'chat' });
    assert.ok(!('tcauto' in readJson(s2).mcpServers));
    for (const f of ['node', 'launcher', 'runtime']) assert.ok(!fs.existsSync(path.join(root, f)), `${f} removed`);
  });

  test('a broken config file is not changed and fails the install (CLIENT_CONFIG_FAILED)', () => {
    const root = path.join(tmp('root'), 'TwinCATAutomation');
    const home = tmp('home');
    const code = path.join(home, '.claude.json');
    put(code, '{ "mcpServers": { broken');
    const r = runInstaller(['-InstallRoot', root, '-NoVerify', '-Clients', 'ClaudeCode', '-ClaudeCodeConfig', code]);
    assert.equal(r.code, 1);
    assert.equal(r.result.error.code, 'CLIENT_CONFIG_FAILED');
    assert.equal(fs.readFileSync(code, 'utf8'), '{ "mcpServers": { broken');
    assert.deepEqual(fs.readdirSync(home), ['.claude.json'], 'no backup, no temp file');
  });

  test('TCAUTO_TEST_FORBID_REAL_STATE=1 refuses the real %LOCALAPPDATA%\\TwinCATAutomation', () => {
    const r = runInstaller(['-InstallRoot', path.join(process.env.LOCALAPPDATA, 'TwinCATAutomation'), '-Verify']);
    assert.equal(r.code, 1);
    assert.equal(r.result.error.code, 'TCAUTO_REAL_STATE_REFUSED');
  });
});

describe('tcauto-client-config.mjs (#20)', () => {
  const CMD = 'C:\\Users\\a\\AppData\\Local\\TwinCATAutomation\\node\\node.exe';
  const ARG = 'C:\\Users\\a\\AppData\\Local\\TwinCATAutomation\\launcher\\tcauto-launcher.mjs';
  const ROOT = 'C:\\Users\\a\\AppData\\Local\\TwinCATAutomation';

  test('JSON: add to an empty file, unchanged on the second run, remove only an owned entry', () => {
    const a = setJson('', 'f', 'claude-desktop', CMD, [ARG]);
    assert.equal(a.action, 'added');
    assert.deepEqual(JSON.parse(a.text), { mcpServers: { tcauto: { command: CMD, args: [ARG] } } });
    assert.equal(setJson(a.text, 'f', 'claude-desktop', CMD, [ARG]).action, 'unchanged');
    const rm = removeJson(a.text, 'f', ROOT);
    assert.equal(rm.action, 'removed');
    assert.deepEqual(JSON.parse(rm.text), { mcpServers: {} });
    assert.equal(removeJson(a.text, 'f', 'D:\\other').action, 'foreign');
    assert.equal(removeJson('{}', 'f', ROOT).action, 'absent');
  });

  test('JSON: invalid text or a non-object mcpServers is refused', () => {
    assert.throws(() => setJson('{x', 'f', 'claude-code', CMD, [ARG]), { code: 'CONFIG_INVALID' });
    assert.throws(() => setJson('[]', 'f', 'claude-code', CMD, [ARG]), { code: 'CONFIG_INVALID' });
    assert.throws(() => setJson('{"mcpServers":[]}', 'f', 'claude-code', CMD, [ARG]), { code: 'CONFIG_INVALID' });
    assert.equal(setJson('\uFEFF{"a":1}', 'f', 'claude-code', CMD, [ARG]).action, 'added', 'a BOM is accepted (and not written back)');
  });

  test('TOML: append, replace with sub-tables, CRLF kept, key-style tcauto refused', () => {
    const a = setToml("model = 'x'\n", 'f', CMD, [ARG]);
    assert.equal(a.action, 'added');
    assert.equal(a.text, `model = 'x'\n\n[mcp_servers.tcauto]\ncommand = '${CMD}'\nargs = ['${ARG}']\n`);
    assert.equal(setToml(a.text, 'f', CMD, [ARG]).action, 'unchanged');
    const crlf = setToml('[mcp_servers."tcauto"]\r\ncommand = "old"\r\n[mcp_servers.tcauto.env]\r\nX = "1"\r\n[other]\r\nk = 1\r\n', 'f', CMD, [ARG]);
    assert.equal(crlf.action, 'updated');
    assert.equal(crlf.text, `[other]\r\nk = 1\r\n\r\n[mcp_servers.tcauto]\r\ncommand = '${CMD}'\r\nargs = ['${ARG}']\r\n`);
    assert.throws(() => setToml('[mcp_servers]\ntcauto = { command = "x" }\n', 'f', CMD, [ARG]), { code: 'CONFIG_UNSUPPORTED' });
    assert.throws(() => setToml('mcp_servers.tcauto.command = "x"\n', 'f', CMD, [ARG]), { code: 'CONFIG_UNSUPPORTED' });
    assert.equal(setToml('[mcp_servers]\nother = { command = "x" }\n', 'f', CMD, [ARG]).action, 'added');
    const rm = removeToml(a.text, 'f', ROOT);
    assert.equal(rm.action, 'removed');
    assert.equal(rm.text, "model = 'x'\n");
    assert.equal(removeToml('[mcp_servers.tcauto]\ncommand = "D:\\\\x\\\\node.exe"\n', 'f', ROOT).action, 'foreign');
  });

  test("remove: an entry that only passes a file of the install in its args is 'shared' (removed with force)", () => {
    const json = JSON.stringify({ mcpServers: { tcauto: { command: 'node', args: [ARG] } } });
    assert.equal(removeJson(json, 'f', ROOT).action, 'shared');
    assert.equal(removeJson(json, 'f', ROOT, true).action, 'removed');
    const toml = `[mcp_servers.tcauto]\ncommand = 'node'\nargs = [\n  '--x',\n  '${ARG}',\n]\n`;
    const r = removeToml(toml, 'f', ROOT);
    assert.equal(r.action, 'shared');
    assert.equal(r.text, toml, 'not changed');
    assert.equal(removeToml(toml, 'f', ROOT, true).action, 'removed');
    assert.equal(removeToml("[mcp_servers.tcauto]\ncommand = 'node'\nargs = ['D:\\\\dev\\\\index.js']\n", 'f', ROOT).action, 'foreign');
    assert.equal(usageOf(CMD, [], ROOT), 'owned');
    assert.equal(usageOf('node', ['-x', ARG], ROOT), 'shared');
    assert.equal(usageOf('node', ['C:\\dev\\x.js'], ROOT), 'foreign');
  });

  test("tomlString / isOwned: literal string for paths, basic string when a ' is in it", () => {
    assert.equal(tomlString('C:\\a b\\x'), "'C:\\a b\\x'");
    assert.equal(tomlString("C:\\O'Brien\\x"), '"C:\\\\O\'Brien\\\\x"');
    assert.ok(isOwned(CMD, ROOT));
    assert.ok(isOwned(CMD.toUpperCase(), ROOT + '\\'));
    assert.ok(!isOwned(ROOT + 'X\\node.exe', ROOT), 'a sibling folder with the same prefix is not owned');
    assert.ok(!isOwned('node', ROOT));
  });

  test('applyToFile: backup before a change, none when unchanged, a new file in an existing folder', () => {
    const d = fs.mkdtempSync(path.join(os.tmpdir(), 'tcauto-cfg-issue20-'));
    try {
      const f = path.join(d, 'claude_desktop_config.json');
      const r1 = applyToFile({ action: 'set', client: 'claude-desktop', file: f, command: CMD, args: [ARG], stamp: 's1' });
      assert.equal(r1.action, 'added');
      assert.equal(r1.backup, null, 'nothing to back up');
      const r2 = applyToFile({ action: 'set', client: 'claude-desktop', file: f, command: CMD, args: [ARG], stamp: 's2' });
      assert.equal(r2.action, 'unchanged');
      assert.equal(r2.backup, null);
      const before = fs.readFileSync(f, 'utf8');
      const r3 = applyToFile({ action: 'remove', client: 'claude-desktop', file: f, ownedRoot: ROOT, stamp: 's3' });
      assert.equal(r3.action, 'removed');
      assert.equal(fs.readFileSync(r3.backup, 'utf8'), before);
      assert.deepEqual(fs.readdirSync(d).sort(), ['claude_desktop_config.json', 'claude_desktop_config.json.bak-s3']);
    } finally {
      fs.rmSync(d, { recursive: true, force: true });
    }
  });
});
