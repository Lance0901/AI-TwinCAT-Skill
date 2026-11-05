// #148: module-source.js readGitHead / readHeadCommit / moduleInfoOf on the shared fixture
// tests/fixtures/git-commit-148.json. tests/Unit/git-commit-148.ps1 runs the same fixture against
// Read-TcGitCommit (the PowerShell reader used by Get-TcModuleCommit and the install manifest), so
// both sides give the same commit for every case.
// Fake repositories only, in a temp folder with a non-ASCII name (contains 148); no git process.
import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
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
