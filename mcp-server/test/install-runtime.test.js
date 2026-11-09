// #162 scripts/Install-TcAutoRuntime.ps1 on a fixture git repository, into an isolated install root
// (temp folders contain 162; the real %LOCALAPPDATA%\TwinCATAutomation is never written: every run
// passes -InstallRoot and TCAUTO_TEST_FORBID_REAL_STATE=1). npm is a stand-in .cmd that only creates
// node_modules\@modelcontextprotocol\sdk\package.json. Windows only (powershell.exe, robocopy).
import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SCRIPT = path.resolve(__dirname, '..', '..', 'scripts', 'Install-TcAutoRuntime.ps1');
const LAUNCHER = path.resolve(__dirname, '..', 'launcher', 'tcauto-launcher.mjs');
const isWin = process.platform === 'win32';
const POWERSHELL = path.join(process.env.SystemRoot ?? 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');

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
function put(file, text) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, text);
}
function git(repo, ...args) {
  const r = spawnSync('git', ['-C', repo, '-c', 'user.name=tcauto-test-162', '-c', 'user.email=test162@example.invalid', '-c', 'core.autocrlf=false', ...args], { encoding: 'utf8' });
  assert.equal(r.status, 0, `git ${args.join(' ')}: ${r.stderr}`);
  return r.stdout.trim();
}

/** Fixture checkout: the real install script and launcher, a tiny mcp-server and module. */
function makeRepo() {
  const repo = tmp('instrepo');
  fs.mkdirSync(path.join(repo, 'scripts'));
  fs.copyFileSync(SCRIPT, path.join(repo, 'scripts', 'Install-TcAutoRuntime.ps1'));
  fs.mkdirSync(path.join(repo, 'scripts', 'lib'));
  fs.copyFileSync(path.join(path.dirname(SCRIPT), 'lib', 'TcAutoInstall.ps1'), path.join(repo, 'scripts', 'lib', 'TcAutoInstall.ps1'));
  put(path.join(repo, 'mcp-server', 'launcher', 'tcauto-launcher.mjs'), fs.readFileSync(LAUNCHER, 'utf8'));
  put(path.join(repo, 'mcp-server', 'index.js'), '// fixture index\n');
  put(path.join(repo, 'mcp-server', 'package.json'), '{"name":"fixture","type":"module"}\n');
  put(path.join(repo, 'mcp-server', 'package-lock.json'), '{}\n');
  put(path.join(repo, 'mcp-server', 'lib', 'a.js'), 'export const a = 1;\n');
  put(path.join(repo, 'mcp-server', 'test', 't.test.js'), '// not installed\n');
  put(path.join(repo, 'mcp-server', 'node_modules', 'junk', 'x.js'), '// ignored, not installed\n');
  put(path.join(repo, 'src', 'TwinCATAutomation', 'TwinCATAutomation.psd1'), "@{ ModuleVersion = '0.0.162' }\n");
  put(path.join(repo, 'src', 'TwinCATAutomation', 'TwinCATAutomation.psm1'), '# fixture\n');
  put(path.join(repo, 'src', 'TwinCATAutomation', 'Private', 'p.ps1'), '# private\n');
  put(path.join(repo, 'README.md'), 'outside the copied folders\n');
  put(path.join(repo, '.gitignore'), 'node_modules/\ntemp_*.ps1\n*.ps1xml\n.env\n');
  // git-ignored files (#162 review): never part of a commit, so never installed (the module would dot-source the .ps1)
  put(path.join(repo, 'src', 'TwinCATAutomation', 'Private', 'temp_stray.ps1'), 'throw "stray"\n');
  put(path.join(repo, 'src', 'TwinCATAutomation', 'Public', 'x.ps1xml'), '<x/>\n');
  put(path.join(repo, 'mcp-server', '.env'), 'SECRET=162\n');
  spawnSync('git', ['init', '-q', '-b', 'feat/162-fixture', repo]);
  git(repo, 'add', '-A');
  git(repo, 'commit', '-q', '-m', 'fixture 1');
  return repo;
}

function npmStub(exitCode = 0) {
  const d = tmp('npmstub');
  const f = path.join(d, exitCode === 0 ? 'npm-ok.cmd' : 'npm-fail.cmd');
  const body =
    exitCode === 0
      ? '@echo off\r\nmkdir node_modules\\@modelcontextprotocol\\sdk 2>nul\r\necho {}> node_modules\\@modelcontextprotocol\\sdk\\package.json\r\necho npm-stub %*\r\nexit /b 0\r\n'
      : '@echo off\r\necho npm-stub failing 1>&2\r\nexit /b 7\r\n';
  fs.writeFileSync(f, body);
  return f;
}

function install(repo, root, { npm, extra = [], env = {} } = {}) {
  const r = spawnSync(POWERSHELL, ['-NoProfile', '-NonInteractive', '-File', path.join(repo, 'scripts', 'Install-TcAutoRuntime.ps1'), '-InstallRoot', root, '-NpmPath', npm, ...extra], {
    encoding: 'utf8',
    env: { ...process.env, ...env, TCAUTO_TEST_FORBID_REAL_STATE: '1', TCAUTO_RUNTIME_ROOT: '' },
    timeout: 120000
  });
  const line = (r.stdout ?? '').split(/\r?\n/).reverse().find((l) => l.startsWith('TCAUTO_INSTALL_RESULT '));
  assert.ok(line, `no result line; exit ${r.status}\nstdout: ${r.stdout}\nstderr: ${r.stderr}`);
  return { code: r.status, result: JSON.parse(line.slice('TCAUTO_INSTALL_RESULT '.length)), stdout: r.stdout };
}

const readJson = (f) => JSON.parse(fs.readFileSync(f, 'utf8'));
const versionsIn = (root) =>
  fs
    .readdirSync(path.join(root, 'runtime'))
    .filter((n) => /^[0-9a-f]{7,64}(-dirty-[0-9]{8}T[0-9]{6}Z)?$/.test(n))
    .sort();
const leftovers = (root) => fs.readdirSync(path.join(root, 'runtime')).filter((n) => n.startsWith('.'));

describe('Install-TcAutoRuntime.ps1 (#162)', { skip: !isWin && 'Windows only' }, () => {
  let repo;
  let npm;
  before(() => {
    repo = makeRepo();
    npm = npmStub(0);
  });

  test('clean install: layout, tcauto-source.json, current.json, launcher; reinstall reuses it', () => {
    const root = tmp('instroot');
    const head = git(repo, 'rev-parse', 'HEAD');
    const { code, result } = install(repo, root, { npm });
    assert.equal(code, 0, JSON.stringify(result));
    assert.equal(result.success, true);
    const ver = head.slice(0, 12);
    assert.equal(result.data.version, ver);
    const dir = path.join(root, 'runtime', ver);
    for (const f of ['mcp-server\\index.js', 'mcp-server\\lib\\a.js', 'mcp-server\\launcher\\tcauto-launcher.mjs', 'mcp-server\\package-lock.json', 'src\\TwinCATAutomation\\TwinCATAutomation.psm1', 'src\\TwinCATAutomation\\Private\\p.ps1']) {
      assert.ok(fs.existsSync(path.join(dir, f)), f);
    }
    assert.ok(!fs.existsSync(path.join(dir, 'mcp-server', 'test')), 'test/ not installed');
    assert.ok(!fs.existsSync(path.join(dir, 'mcp-server', 'node_modules', 'junk')), 'the source node_modules is not copied');
    assert.ok(fs.existsSync(path.join(dir, 'mcp-server', 'node_modules', '@modelcontextprotocol', 'sdk', 'package.json')), 'npm ci ran in the copy');
    assert.ok(!fs.existsSync(path.join(dir, 'README.md')), 'only mcp-server and src\\TwinCATAutomation');
    assert.equal(result.data.dirty, false, 'ignored files do not make the tree dirty');
    for (const f of ['src\\TwinCATAutomation\\Private\\temp_stray.ps1', 'src\\TwinCATAutomation\\Public\\x.ps1xml', 'mcp-server\\.env']) {
      assert.ok(fs.existsSync(path.join(repo, f)), `fixture has ${f}`);
      assert.ok(!fs.existsSync(path.join(dir, f)), `git-ignored ${f} is not installed`);
    }

    const stamp = readJson(path.join(dir, 'tcauto-source.json'));
    assert.equal(stamp.commit, head);
    assert.equal(stamp.ref, 'refs/heads/feat/162-fixture');
    assert.equal(stamp.branch, 'feat/162-fixture');
    assert.equal(stamp.dirty, false);
    assert.equal(stamp.version, ver);
    assert.equal(stamp.sourcePath.toLowerCase(), fs.realpathSync.native(repo).toLowerCase());
    assert.ok(!Number.isNaN(Date.parse(stamp.installedAt)));

    const cur = readJson(path.join(root, 'runtime', 'current.json'));
    assert.equal(cur.version, ver);
    assert.equal(cur.commit, head);
    assert.equal(cur.dirty, false);
    assert.equal(fs.readFileSync(path.join(root, 'launcher', 'tcauto-launcher.mjs'), 'utf8'), fs.readFileSync(LAUNCHER, 'utf8'));
    assert.equal(result.data.launcherUpdated, true);
    assert.deepEqual(leftovers(root), [], 'no staging / temp file left');

    const again = install(repo, root, { npm });
    assert.equal(again.code, 0);
    assert.equal(again.result.data.reused, true);
    assert.equal(again.result.data.launcherUpdated, false, 'launcher only rewritten when its content changed');
    assert.equal(readJson(path.join(root, 'runtime', 'current.json')).version, ver);
    assert.deepEqual(leftovers(root), []);
  });

  test('a dirty working tree is refused (nothing written); -AllowDirty installs it as <sha>-dirty-<time>', () => {
    const root = tmp('instroot');
    assert.equal(install(repo, root, { npm }).code, 0);
    const curFile = path.join(root, 'runtime', 'current.json');

    // a change below mcp-server\test is not installed, so it does not make the install dirty
    fs.appendFileSync(path.join(repo, 'mcp-server', 'test', 't.test.js'), '// edit\n');
    assert.equal(install(repo, root, { npm }).result.data.dirty, false);
    const before = fs.readFileSync(curFile);
    const versionsBefore = versionsIn(root);

    fs.appendFileSync(path.join(repo, 'mcp-server', 'lib', 'a.js'), '// uncommitted\n');
    put(path.join(repo, 'mcp-server', 'lib', 'untracked162.js'), '// untracked, not ignored\n');
    try {
      const refused = install(repo, root, { npm });
      assert.equal(refused.code, 1);
      assert.equal(refused.result.error.code, 'WORKTREE_DIRTY');
      assert.ok(refused.result.data.changes.some((l) => l.includes('mcp-server/lib/a.js')));
      assert.deepEqual(fs.readFileSync(curFile), before, 'current.json unchanged');
      assert.deepEqual(versionsIn(root), versionsBefore, 'no runtime folder added');

      const dirty = install(repo, root, { npm, extra: ['-AllowDirty'] });
      assert.equal(dirty.code, 0, JSON.stringify(dirty.result));
      assert.match(dirty.result.data.version, /^[0-9a-f]{12}-dirty-[0-9]{8}T[0-9]{6}Z$/);
      const stamp = readJson(path.join(root, 'runtime', dirty.result.data.version, 'tcauto-source.json'));
      assert.equal(stamp.dirty, true);
      assert.match(fs.readFileSync(path.join(root, 'runtime', dirty.result.data.version, 'mcp-server', 'lib', 'a.js'), 'utf8'), /uncommitted/);
      assert.ok(fs.existsSync(path.join(root, 'runtime', dirty.result.data.version, 'mcp-server', 'lib', 'untracked162.js')), 'an untracked, not ignored file is installed (and made it dirty)');
      assert.ok(!fs.existsSync(path.join(root, 'runtime', dirty.result.data.version, 'src', 'TwinCATAutomation', 'Private', 'temp_stray.ps1')), 'ignored file not installed with -AllowDirty either');
      assert.equal(readJson(curFile).version, dirty.result.data.version);
      assert.equal(readJson(curFile).dirty, true);
    } finally {
      git(repo, 'checkout', '--', 'mcp-server');
      fs.rmSync(path.join(repo, 'mcp-server', 'lib', 'untracked162.js'), { force: true });
    }
  });

  test('npm ci failure: NPM_CI_FAILED, no runtime folder, no staging left, current.json unchanged', () => {
    const root = tmp('instroot');
    assert.equal(install(repo, root, { npm }).code, 0);
    const curFile = path.join(root, 'runtime', 'current.json');
    const before = fs.readFileSync(curFile);
    put(path.join(repo, 'mcp-server', 'lib', 'b.js'), 'export const b = 2;\n');
    git(repo, 'add', '-A');
    git(repo, 'commit', '-q', '-m', 'fixture npm-fail');
    const r = install(repo, root, { npm: npmStub(7) });
    assert.equal(r.code, 1);
    assert.equal(r.result.error.code, 'NPM_CI_FAILED');
    assert.equal(versionsIn(root).length, 1);
    assert.deepEqual(leftovers(root), []);
    assert.deepEqual(fs.readFileSync(curFile), before);
  });

  test('retention: the 3 newest versions stay, a version in use is skipped, older ones go', async () => {
    const root = tmp('instroot');
    const installed = [];
    for (let i = 0; i < 4; i++) {
      put(path.join(repo, 'mcp-server', 'lib', 'n.js'), `export const n = ${i};\n`);
      git(repo, 'add', '-A');
      git(repo, 'commit', '-q', '-m', `fixture keep ${i}`);
      const r = install(repo, root, { npm });
      assert.equal(r.code, 0, JSON.stringify(r.result));
      installed.push(r.result.data.version);
    }
    assert.deepEqual(versionsIn(root), installed.slice(1).sort(), 'oldest of 4 removed');
    assert.equal(readJson(path.join(root, 'runtime', 'current.json')).version, installed[3]);

    // a process with its working directory in the oldest kept version holds it: rename fails, it is skipped
    const held = path.join(root, 'runtime', installed[1], 'mcp-server');
    const holder = spawn(process.execPath, ['-e', 'setTimeout(() => {}, 60000)'], { cwd: held, stdio: 'ignore' });
    try {
      await new Promise((r) => setTimeout(r, 300));
      put(path.join(repo, 'mcp-server', 'lib', 'n.js'), 'export const n = 99;\n');
      git(repo, 'add', '-A');
      git(repo, 'commit', '-q', '-m', 'fixture keep held');
      const r = install(repo, root, { npm });
      assert.equal(r.code, 0);
      assert.ok(r.result.data.pruneSkipped.some((s) => s.version === installed[1]), JSON.stringify(r.result.data));
      assert.ok(fs.existsSync(path.join(held, 'index.js')), 'the held version is intact');
    } finally {
      holder.kill();
      await new Promise((r) => holder.once('exit', r));
    }

    const one = install(repo, root, { npm, extra: ['-Keep', '1'] });
    assert.equal(one.code, 0);
    assert.deepEqual(versionsIn(root), [one.result.data.version], '-Keep 1 leaves only current');
    assert.deepEqual(leftovers(root), []);
  });

  test('TCAUTO_TEST_FORBID_REAL_STATE=1 refuses the real %LOCALAPPDATA%\\TwinCATAutomation', () => {
    // the working tree is made dirty first: even a broken guard would stop at WORKTREE_DIRTY before writing
    fs.appendFileSync(path.join(repo, 'mcp-server', 'lib', 'a.js'), '// guard\n');
    try {
      const real = path.join(process.env.LOCALAPPDATA, 'TwinCATAutomation');
      const r = install(repo, real, { npm: npmStub(7) });
      assert.equal(r.code, 1);
      assert.equal(r.result.error.code, 'TCAUTO_REAL_STATE_REFUSED');
    } finally {
      git(repo, 'checkout', '--', 'mcp-server');
    }
  });

  test('#170 inside an MSIX package: an install root under %LOCALAPPDATA% or %APPDATA% is refused, nothing written', () => {
    // LOCALAPPDATA / APPDATA point at isolated fixture folders for the child, so the refusal is asserted
    // on every machine (wherever TEMP lives) and the real AppData is never touched
    const lad = tmp('pkglad');
    const appdata = tmp('pkgappdata');
    const package170 = 'Claude_1.0.0.0_x64__pzs8sxrjxfjjc';
    const env = { LOCALAPPDATA: lad, APPDATA: appdata, TCAUTO_TEST_PACKAGE_FULL_NAME: package170 };
    // powershell.exe itself caches under %LOCALAPPDATA%\Microsoft (StartupProfileData): not the install
    const written = (base) => fs.readdirSync(base).filter((n) => n !== 'Microsoft');
    for (const base of [lad, appdata]) {
      // not <base>\TwinCATAutomation: under LOCALAPPDATA that is TCAUTO_REAL_STATE_REFUSED, checked first
      const root = path.join(base, 'tcauto-pkg170');
      const r = install(repo, root, { npm, env });
      assert.equal(r.code, 1, JSON.stringify(r.result));
      assert.equal(r.result.success, false);
      assert.equal(r.result.error.code, 'INSTALL_PACKAGED_CONTEXT');
      assert.match(r.result.error.hint, /normal PowerShell window/);
      assert.equal(r.result.data.packageFullName, package170);
      assert.equal(r.result.data.detectedBy, 'packageIdentity');
      assert.equal(path.basename(r.result.data.installRoot), 'tcauto-pkg170');
      assert.ok(!fs.existsSync(root), `nothing written: ${root}`);
      assert.deepEqual(written(base), [], `nothing written under ${base}`);
    }
    // an explicit root outside AppData is not virtualized: allowed
    const outside = tmp('pkgoutside');
    const r2 = install(repo, outside, { npm, env });
    assert.equal(r2.code, 0, JSON.stringify(r2.result));
    assert.equal(r2.result.success, true);
    assert.deepEqual(written(lad), [], 'the allowed install wrote nothing under LOCALAPPDATA');
  });

  // #170 probe: package identity is not visible in a Claude Desktop "Code" tab shell (real machine
  // 2026-11-08), so the installers also probe whether a write next to the install root is redirected
  // to %LOCALAPPDATA%\Packages\<pkg>\LocalCache\{Local,Roaming}. LOCALAPPDATA / APPDATA are fixture
  // folders; TCAUTO_TEST_PROBE_REDIRECT_PACKAGE makes the script move its probe into that package's
  // LocalCache, as the redirection would. TCAUTO_TEST_PACKAGE_FULL_NAME='' = no package identity.
  const pkgFolder = 'Claude_pzs8sxrjxfjjc';
  /** Every file and folder below base (relative), without powershell.exe's own %LOCALAPPDATA%\Microsoft cache. */
  function tree(base) {
    const out = [];
    const walk = (d, rel) => {
      for (const e of fs.readdirSync(d, { withFileTypes: true })) {
        const r = rel ? `${rel}\\${e.name}` : e.name;
        if (!rel && e.name === 'Microsoft') continue;
        out.push(r);
        if (e.isDirectory()) walk(path.join(d, e.name), r);
      }
    };
    walk(base, '');
    return out.sort();
  }
  function appDataFixture() {
    const lad = tmp('probelad');
    const appdata = tmp('probeappdata');
    for (const kind of ['Local', 'Roaming', 'Local\\sub170']) fs.mkdirSync(path.join(lad, 'Packages', pkgFolder, 'LocalCache', kind), { recursive: true });
    fs.mkdirSync(path.join(lad, 'sub170'));
    return { lad, appdata, env: { LOCALAPPDATA: lad, APPDATA: appdata, TCAUTO_TEST_PACKAGE_FULL_NAME: '' } };
  }

  test('#170 probe: writes next to the install root redirected into a package LocalCache -> INSTALL_PACKAGED_CONTEXT, nothing left behind', () => {
    const { lad, appdata, env } = appDataFixture();
    const before = { lad: tree(lad), appdata: tree(appdata) };
    const cases = [
      { root: path.join(lad, 'tcauto-probe170'), kind: 'Local', rel: '' },
      { root: path.join(lad, 'sub170', 'tcauto-probe170'), kind: 'Local', rel: 'sub170' },
      { root: path.join(appdata, 'tcauto-probe170'), kind: 'Roaming', rel: '' }
    ];
    for (const c of cases) {
      const r = install(repo, c.root, { npm, env: { ...env, TCAUTO_TEST_PROBE_REDIRECT_PACKAGE: pkgFolder } });
      assert.equal(r.code, 1, JSON.stringify(r.result));
      assert.equal(r.result.success, false);
      assert.equal(r.result.error.code, 'INSTALL_PACKAGED_CONTEXT');
      assert.match(r.result.error.hint, /normal PowerShell window/);
      assert.equal(r.result.data.detectedBy, 'probe');
      assert.equal(r.result.data.packageFolder, pkgFolder);
      assert.equal(r.result.data.redirectedTo.toLowerCase(), path.join(lad, 'Packages', pkgFolder, 'LocalCache', c.kind, c.rel).toLowerCase());
      assert.ok(!fs.existsSync(c.root), `nothing installed: ${c.root}`);
    }
    // the probe is gone on both sides and nothing else was created
    assert.deepEqual(tree(lad), before.lad, 'LOCALAPPDATA (incl. Packages\\...\\LocalCache) unchanged');
    assert.deepEqual(tree(appdata), before.appdata, 'APPDATA unchanged');
  });

  test('#170 probe: no redirection -> installs as usual and removes the probe', () => {
    const { lad, env } = appDataFixture();
    const root = path.join(lad, 'tcauto-probe170');
    const r = install(repo, root, { npm, env });
    assert.equal(r.code, 0, JSON.stringify(r.result));
    assert.equal(r.result.success, true);
    assert.ok(fs.existsSync(path.join(root, 'runtime', 'current.json')), 'installed');
    assert.deepEqual(
      tree(lad).filter((n) => n.includes('.tcauto-probe-')),
      [],
      'no probe left'
    );
  });

  test('#170 probe fails closed: probe cannot be written / moved -> INSTALL_PROBE_FAILED, nothing installed, no probe left', () => {
    // LOCALAPPDATA is a file, not a folder: the probe cannot be written
    const notDir = path.join(tmp('probenotdir'), 'localappdata-is-a-file');
    fs.writeFileSync(notDir, 'x');
    const r1 = install(repo, path.join(notDir, 'tcauto-probe170'), { npm, env: { LOCALAPPDATA: notDir, TCAUTO_TEST_PACKAGE_FULL_NAME: '' } });
    assert.equal(r1.code, 1, JSON.stringify(r1.result));
    assert.equal(r1.result.error.code, 'INSTALL_PROBE_FAILED');
    assert.deepEqual(fs.readdirSync(path.dirname(notDir)), ['localappdata-is-a-file'], 'nothing written next to it');
    // the probe is written but the check step fails (the stand-in package has no LocalCache): removed again
    const { lad, env } = appDataFixture();
    const before = tree(lad);
    const root2 = path.join(lad, 'tcauto-probe170');
    const r2 = install(repo, root2, { npm, env: { ...env, TCAUTO_TEST_PROBE_REDIRECT_PACKAGE: 'NoLocalCache_x' } });
    assert.equal(r2.code, 1, JSON.stringify(r2.result));
    assert.equal(r2.result.error.code, 'INSTALL_PROBE_FAILED');
    assert.deepEqual(r2.result.data.leftover, [], 'the probe was removed');
    assert.deepEqual(tree(lad), before, 'nothing left under LOCALAPPDATA');
  });
});

// #208 scripts/lib/TcAutoInstall.ps1 Remove-TcInstallFolder (Install-TcAuto.ps1 -Uninstall): a
// folder that cannot be renamed is retried for a few seconds, then reported 'in-use'. The folders
// are temp folders (names hold 208); the rename is injected (-Move) or held by a real process.
describe('Remove-TcInstallFolder retries an in-use rename (#208)', { skip: !isWin && 'Windows only' }, () => {
  const LIB = path.join(path.dirname(SCRIPT), 'lib', 'TcAutoInstall.ps1');
  /** dot-sources the lib, runs body (it sets $out), returns $out as JSON plus the wall time */
  function runLib(body, env = {}) {
    const ps = `$ErrorActionPreference = 'Stop'; . '${LIB.replace(/'/g, "''")}'; $out = $null; ${body}; Write-Output ('RESULT ' + (ConvertTo-Json -InputObject $out -Depth 5 -Compress))`;
    const t0 = Date.now();
    const r = spawnSync(POWERSHELL, ['-NoProfile', '-NonInteractive', '-Command', ps], { encoding: 'utf8', env: { ...process.env, ...env }, timeout: 60000 });
    const ms = Date.now() - t0;
    const line = (r.stdout ?? '').split(/\r?\n/).find((l) => l.startsWith('RESULT '));
    assert.ok(line, `exit ${r.status}\nstdout: ${r.stdout}\nstderr: ${r.stderr}`);
    return { out: JSON.parse(line.slice(7)), ms };
  }
  function folder() {
    const d = path.join(tmp('rm208'), 'node');
    put(path.join(d, 'node.exe'), 'fake');
    return d;
  }
  // 0x80070005 或 0x80070020,依佔用方式而定(實測 2026-11-09,Win11、PS 5.1)
  const DENIED = "throw [System.IO.IOException]::new('Access to the path is denied.', -2147024891)";

  test('the rename fails twice with access denied, the third try works: removed', () => {
    const d = folder();
    const { out } = runLib(
      `$n = @{ c = 0 }; $out = Remove-TcInstallFolder -Path $env:T208 -Move { param($f, $t) $n.c++; if ($n.c -le 2) { ${DENIED} }; [System.IO.Directory]::Move($f, $t) }`,
      { T208: d }
    );
    assert.equal(out.action, 'removed', JSON.stringify(out));
    assert.equal(out.attempts, 3);
    assert.ok(!fs.existsSync(d), 'folder removed');
    assert.deepEqual(fs.readdirSync(path.dirname(d)), [], 'no .trash-* left');
  });

  test('the rename always fails with access denied: in-use within the 5 s limit, same reason text', () => {
    const d = folder();
    const { out, ms } = runLib(`$out = Remove-TcInstallFolder -Path $env:T208 -Move { param($f, $t) ${DENIED} }`, { T208: d });
    assert.equal(out.action, 'in-use', JSON.stringify(out));
    assert.ok(out.attempts > 2, `retried: ${out.attempts}`);
    assert.ok(out.elapsedMs >= 5000 && out.elapsedMs < 6500, `elapsedMs ${out.elapsedMs}`);
    assert.ok(ms < 15000, `wall time ${ms} ms`);
    assert.match(out.reason, /Access to the path is denied\..*\(close the MCP clients that run TcAuto, then run -Uninstall again\)$/);
    assert.ok(fs.existsSync(path.join(d, 'node.exe')), 'folder untouched');
  });

  test('an error that is not in-use (not found) is not retried', () => {
    const d = folder();
    const { out } = runLib(`$out = Remove-TcInstallFolder -Path $env:T208 -Move { param($f, $t) throw [System.IO.DirectoryNotFoundException]::new('gone') }`, { T208: d });
    assert.equal(out.action, 'in-use');
    assert.equal(out.attempts, 1);
    assert.ok(out.elapsedMs < 1000, `elapsedMs ${out.elapsedMs}`);
  });

  // a node.exe (root, no console window) that starts a child node.exe running for 60 s and prints
  // the child's PID; the root stays until stdin closes. $root, $kid in PowerShell.
  const TREE =
    "$psi = New-Object System.Diagnostics.ProcessStartInfo; $psi.FileName = $env:T208NODE; " +
    "$psi.Arguments = '-e \"const c = require(''child_process'').spawn(process.execPath, [''-e'', ''setTimeout(() => {}, 60000)''], { stdio: ''ignore'', windowsHide: true }); console.log(c.pid); process.stdin.resume(); process.stdin.on(''end'', () => process.exit(0))\"'; " +
    '$psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; ' +
    '$root = [System.Diagnostics.Process]::Start($psi); $kid = [int]$root.StandardOutput.ReadLine(); ';
  const STOP_TREE = "; try { $root.StandardInput.Close(); $null = $root.WaitForExit(5000) } catch { }; try { Stop-Process -Id $kid -Force -ErrorAction Stop } catch { }";

  test('Wait-TcProcessesExit: a child that does not exit is killed through its handle after TimeoutMs, returns 1, writes a warning', () => {
    const { out } = runLib(
      TREE +
        '$tree = Get-TcProcessTree -RootId $root.Id -NotBefore $root.StartTime; $nodes = @($tree | Where-Object { $_.Id -eq $kid }); ' +
        '$h = [System.Diagnostics.Process]::GetProcessById($kid); $sw = [System.Diagnostics.Stopwatch]::StartNew(); ' +
        '$killed = Wait-TcProcessesExit -Processes $nodes -TimeoutMs 300; ' +
        '$out = @{ inTree = $nodes.Count; killed = $killed; exited = $h.WaitForExit(3000); ms = $sw.ElapsedMilliseconds; rootAlive = -not $root.HasExited; warnings = @($script:TcInstallWarnings) }' +
        STOP_TREE,
      { T208NODE: process.execPath }
    );
    assert.equal(out.inTree, 1, JSON.stringify(out));
    assert.equal(out.killed, 1);
    assert.equal(out.exited, true, 'the child was killed');
    assert.ok(out.ms < 5000, `ms ${out.ms}`);
    assert.equal(out.rootAlive, true, 'only the given process is killed, not its parent');
    assert.equal(out.warnings.length, 1);
    assert.match(out.warnings[0], /did not exit within 300 ms and was killed/);
  });

  test('Get-TcProcessTree: a child created before NotBefore is not part of the tree', () => {
    const { out } = runLib(
      TREE +
        '$after = Get-TcProcessTree -RootId $root.Id -NotBefore ([DateTime]::Now.AddSeconds(1)); ' +
        '$before = Get-TcProcessTree -RootId $root.Id -NotBefore $root.StartTime; ' +
        '$out = @{ late = @($after | ForEach-Object { $_.Id }); early = @($before | ForEach-Object { $_.Id }); kid = $kid }' +
        STOP_TREE,
      { T208NODE: process.execPath }
    );
    assert.ok(!out.late.includes(out.kid), JSON.stringify(out));
    assert.ok(out.early.includes(out.kid), `with NotBefore = root start the child is found: ${JSON.stringify(out)}`);
  });

  test('a real process holds the folder (working directory) for about 1 s: retried, then removed', () => {
    const d = folder();
    // started by the PowerShell process itself: the working directory is held from process creation on, before the first rename
    const { out } = runLib(
      `$h = Start-Process -FilePath $env:T208NODE -ArgumentList '-e', 'setTimeout(() => {}, 1200)' -WorkingDirectory $env:T208 -WindowStyle Hidden -PassThru; ` +
        `$out = Remove-TcInstallFolder -Path $env:T208; $h.WaitForExit()`,
      { T208: d, T208NODE: process.execPath }
    );
    assert.equal(out.action, 'removed', JSON.stringify(out));
    assert.ok(out.attempts > 1, `the held folder needed a retry: ${out.attempts}`);
    assert.ok(!fs.existsSync(d));
  });
});
