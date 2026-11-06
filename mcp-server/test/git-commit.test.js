// #148: module-source.js readGitHead / readHeadCommit / moduleInfoOf on the shared fixture
// tests/fixtures/git-commit-148.json. tests/Unit/git-commit-148.ps1 runs the same fixture against
// Read-TcGitCommit (the PowerShell reader used by Get-TcModuleCommit and the install manifest), so
// both sides give the same commit for every case.
// Fake repositories only, in a temp folder with a non-ASCII name (contains 148); no git process.
// The locked-file test (Windows only) starts powershell.exe -NoProfile -Command only to hold a file
// open without sharing; it loads no module and touches no TcAuto state.
import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import { readGitHead, readHeadCommit, moduleInfoOf, MODULE_RELATIVE_PATH } from '../lib/module-source.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const FIXTURE = path.join(__dirname, '..', '..', 'tests', 'fixtures', 'git-commit-148.json');
const fixture = JSON.parse(fs.readFileSync(FIXTURE, 'utf8'));

let base;
let temp;
before(() => {
  temp = fs.mkdtempSync(path.join(os.tmpdir(), 'tcauto-git148-'));
  base = path.join(temp, '\u6574\u7406');
  fs.mkdirSync(base, { recursive: true });
});
after(() => {
  try {
    fs.rmSync(temp, { recursive: true, force: true });
  } catch {
    /* temp directory */
  }
});

/** Builds case number i (1-based) of the fixture; returns its checkout root. */
function build(c, i) {
  const dir = path.join(base, `c${String(i).padStart(2, '0')}`);
  fs.mkdirSync(dir, { recursive: true });
  const caseFwd = dir.replace(/\\/g, '/');
  for (const d of c.dirs ?? []) fs.mkdirSync(path.join(dir, ...d.split('/')), { recursive: true });
  for (const [rel, v] of Object.entries(c.files ?? {})) {
    const file = path.join(dir, ...rel.split('/'));
    fs.mkdirSync(path.dirname(file), { recursive: true });
    if (typeof v === 'string') fs.writeFileSync(file, v.replaceAll('{case}', caseFwd), 'utf8');
    else if (v.bytes) fs.writeFileSync(file, Buffer.from(v.bytes));
    else if (v.utf16) fs.writeFileSync(file, Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from(v.utf16.replaceAll('{case}', caseFwd), 'utf16le')]));
    else fs.writeFileSync(file, (v.bom ? '\uFEFF' : '') + v.text.replaceAll('{case}', caseFwd), 'utf8');
  }
  return c.root ? path.join(dir, ...c.root.split('/')) : dir;
}

describe('module-source readGitHead (#148): shared fixture with Read-TcGitCommit', () => {
  test('fixture has cases', () => {
    assert.ok(fixture.cases.length >= 20);
  });

  fixture.cases.forEach((c, idx) => {
    const i = idx + 1;
    test(`${i} ${c.name}`, () => {
      const root = build(c, i);
      const g = readGitHead(root);
      const e = c.expect;
      if (e === null) {
        assert.equal(g, null);
      } else {
        assert.ok(g, 'readGitHead returned null');
        assert.equal(g.commit, e.commit);
        assert.equal(g.ref, e.ref);
        if (e.note === null) assert.equal(g.note, null);
        else assert.ok(typeof g.note === 'string' && g.note.includes(e.note), `note ${JSON.stringify(g.note)} does not contain ${JSON.stringify(e.note)}`);
      }
      const want = e && e.commit ? e.commit : null;
      assert.equal(readHeadCommit(root), want);
      // GetStatus moduleCommit: only through <root>\src\TwinCATAutomation\TwinCATAutomation.psm1 of a checkout
      const hasDotGit = fs.existsSync(path.join(root, '.git'));
      assert.equal(moduleInfoOf(path.join(root, MODULE_RELATIVE_PATH)).moduleCommit, hasDotGit ? want : null);
    });
  });
});

/** Holds `file` open with FileShare.None in a child powershell.exe until release() is called. */
function lockFile(file) {
  return new Promise((resolve, reject) => {
    const script =
      "$l = [System.IO.File]::Open($env:TCAUTO_LOCK148, 'Open', 'ReadWrite', 'None'); " +
      "[Console]::Out.WriteLine('locked148'); [Console]::Out.Flush(); [void][Console]::In.ReadLine(); $l.Dispose()";
    const child = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script], {
      env: { ...process.env, TCAUTO_LOCK148: file },
      stdio: ['pipe', 'pipe', 'pipe']
    });
    let out = '';
    let err = '';
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error(`lock helper did not start: ${err}`));
    }, 60000);
    child.stdout.on('data', (d) => {
      out += d;
      if (out.includes('locked148')) {
        clearTimeout(timer);
        resolve({
          release: () =>
            new Promise((done) => {
              child.on('exit', done);
              child.stdin.end('\n');
            })
        });
      }
    });
    child.stderr.on('data', (d) => (err += d));
    child.on('error', (e) => {
      clearTimeout(timer);
      reject(e);
    });
  });
}

describe('module-source readGitHead (#148 review 6): a file that exists but cannot be read', () => {
  const skip = process.platform !== 'win32' ? 'FileShare.None locking needs Windows (powershell.exe)' : false;
  test('locked loose ref -> null, never the packed-refs sha, never throws', { skip }, async () => {
    const dir = path.join(base, 'locked');
    const put = (rel, text) => {
      const f = path.join(dir, ...rel.split('/'));
      fs.mkdirSync(path.dirname(f), { recursive: true });
      fs.writeFileSync(f, text, 'utf8');
      return f;
    };
    put('.git/HEAD', 'ref: refs/heads/main\n');
    const loose = put('.git/refs/heads/main', '1111111111111111111111111111111111111111\n');
    put('.git/packed-refs', '2222222222222222222222222222222222222222 refs/heads/main\n');
    assert.equal(readHeadCommit(dir), '1111111111111111111111111111111111111111');
    const lock = await lockFile(loose);
    try {
      assert.equal(readGitHead(dir), null);
      assert.equal(readHeadCommit(dir), null);
    } finally {
      await lock.release();
    }
    assert.equal(readHeadCommit(dir), '1111111111111111111111111111111111111111');
  });
});
