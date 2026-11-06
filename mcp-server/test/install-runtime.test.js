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
  put(path.join(repo, '.gitignore'), 'node_modules/\n');
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

function install(repo, root, { npm, extra = [] } = {}) {
  const r = spawnSync(POWERSHELL, ['-NoProfile', '-NonInteractive', '-File', path.join(repo, 'scripts', 'Install-TcAutoRuntime.ps1'), '-InstallRoot', root, '-NpmPath', npm, ...extra], {
    encoding: 'utf8',
    env: { ...process.env, TCAUTO_TEST_FORBID_REAL_STATE: '1', TCAUTO_RUNTIME_ROOT: '' },
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
      assert.equal(readJson(curFile).version, dirty.result.data.version);
      assert.equal(readJson(curFile).dirty, true);
    } finally {
      git(repo, 'checkout', '--', 'mcp-server');
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
});
