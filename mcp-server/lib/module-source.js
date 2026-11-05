// Where the PowerShell module the bridge imports comes from (#41): the checkout it belongs to, the
// commit that checkout has checked out, and the module paths ReloadModule may switch to.
//
// Everything is read from the .git files (HEAD, refs, packed-refs, commondir, worktrees/*/gitdir);
// git.exe is never started. A module path counts as a checkout only when it is exactly
// <root>\src\TwinCATAutomation\TwinCATAutomation.psm1 and <root> has a .git directory or file (as
// Get-TcModuleCommit, Private/Get-TcIssueEnvironment.ps1, #78).
//
// The commit is read by readGitHead with the same rules as Read-TcGitCommit
// (Private/InstallManifest.ps1, #148, the one PowerShell reader used by Get-TcModuleCommit and the
// install manifest); both run the shared fixture tests/fixtures/git-commit-148.json
// (test/git-commit.test.js and tests/Unit/git-commit-148.ps1), so a checkout gives the same commit
// on both sides:
//   - every file is UTF-8 with or without BOM, first line, trimmed;
//   - .git is a directory or a file "gitdir: <path>" (relative to the checkout root); commondir
//     (relative to the gitdir) holds refs and packed-refs of a linked worktree;
//   - HEAD is a detached 40 (SHA-1) or 64 (SHA-256) hex object name (either case, returned in lower
//     case) or `ref: refs/<name>` with any non-blank characters (non-ASCII branch names work) but
//     never '..', '\' or ':';
//   - the loose ref (gitdir, then common dir) wins over packed-refs.
// Limits (moduleCommit is then null, never a wrong sha):
//   - a repository using the reftable backend (extensions.refStorage = reftable: HEAD is
//     `ref: refs/heads/.invalid`, a reftable directory) is not read; readGitHead says so in `note`.
//   - a symbolic ref chain (a ref file holding `ref: ...`) is not followed.
//   - HEAD only: uncommitted changes in the working tree are not detected (moduleDirty is null).
//
// Allowed ModulePath values (ReloadModule): <main>\src\TwinCATAutomation\TwinCATAutomation.psm1 of
// the main checkout and the same relative path in every worktree of that repository, i.e. the
// entries `git worktree list` shows: <main>\.git\worktrees\<name>\gitdir names <worktree>\.git, and
// that .git file must point back to the same <main>\.git\worktrees\<name> (a stale or foreign entry
// is not allowed). Every other path is refused.
import fs from 'node:fs';
import path from 'node:path';

export const MODULE_RELATIVE_PATH = path.win32.join('src', 'TwinCATAutomation', 'TwinCATAutomation.psm1');

const OBJECT_NAME_RE = /^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})$/;
const PACKED_RE = /^([0-9a-fA-F]{40}|[0-9a-fA-F]{64}) (.+)$/;

/** First line of a file, trimmed; null when it is not a file (missing / directory). */
function readFirstLine(file) {
  try {
    return readFirstLineStrict(file);
  } catch {
    return null;
  }
}

/** As readFirstLine, but a file that exists and cannot be read throws (Read-TcGitCommit: never a stale sha). */
function readFirstLineStrict(file) {
  if (!isFile(file)) return null;
  return readText(file).split(/\r?\n/, 1)[0].trim();
}

/** UTF-8 text without a leading BOM (like .NET File.ReadAllText with UTF8). */
function readText(file) {
  return fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, '');
}

function isFile(p) {
  try {
    return fs.statSync(p).isFile();
  } catch {
    return false;
  }
}

function isDir(p) {
  try {
    return fs.statSync(p).isDirectory();
  } catch {
    return false;
  }
}

/** Absolute, normalised Windows path (forward slashes accepted), no trailing separator. */
export function normalizePath(p) {
  if (typeof p !== 'string' || !p.trim()) return null;
  let out = path.win32.resolve(p.trim());
  try {
    out = fs.realpathSync.native(out);
  } catch {
    /* a path that does not exist is compared as written */
  }
  return path.win32.normalize(out).replace(/[\\/]+$/, '');
}

/** Case-insensitive comparison key of a Windows path. */
export function pathKey(p) {
  const n = normalizePath(p);
  return n === null ? null : n.toLowerCase();
}

/** <root> when modulePath is <root>\src\TwinCATAutomation\TwinCATAutomation.psm1 and <root>\.git exists, else null. */
export function checkoutRootOf(modulePath) {
  const mp = normalizePath(modulePath);
  if (mp === null) return null;
  const root = path.win32.resolve(mp, '..', '..', '..');
  if (pathKey(path.win32.join(root, MODULE_RELATIVE_PATH)) !== mp.toLowerCase()) return null;
  const dot = path.win32.join(root, '.git');
  if (!isDir(dot) && !isFile(dot)) return null;
  return root;
}

/**
 * { gitDir, commonDir } of a checkout root (main checkout or worktree), or null. strict: a .git /
 * commondir file that exists and cannot be read throws (readGitHead) instead of counting as missing.
 */
export function gitDirsOf(root, strict = false) {
  if (typeof root !== 'string' || !root) return null;
  const first = strict ? readFirstLineStrict : readFirstLine;
  const dot = path.win32.join(root, '.git');
  let gitDir = null;
  if (isDir(dot)) gitDir = dot;
  else if (isFile(dot)) {
    const m = /^gitdir:\s*(.+)$/.exec(first(dot) ?? '');
    if (m) gitDir = path.win32.resolve(root, m[1].trim());
  }
  if (!gitDir || !isDir(gitDir)) return null;
  let commonDir = gitDir;
  const cd = first(path.win32.join(gitDir, 'commondir'));
  if (cd) commonDir = path.win32.resolve(gitDir, cd);
  return { gitDir: path.win32.normalize(gitDir), commonDir: path.win32.normalize(commonDir) };
}

/**
 * What HEAD of the checkout points at, with the rules of Read-TcGitCommit (#148): null when the
 * checkout has no usable .git (none, no "gitdir:" line, gitdir not a directory, no HEAD, a file that
 * cannot be read), else { commit, ref, note }: commit is the lower-case 40 / 64 hex object name or
 * null with a note. Never throws.
 */
export function readGitHead(root) {
  const result = (commit, ref, note) => ({ commit, ref, note });
  try {
    const dirs = gitDirsOf(root, true);
    if (!dirs) return null;
    const head = readFirstLineStrict(path.win32.join(dirs.gitDir, 'HEAD'));
    if (head === null) return null;
    if (OBJECT_NAME_RE.test(head)) return result(head.toLowerCase(), null, null); // detached HEAD
    const m = /^ref:\s*(\S+)$/.exec(head);
    if (!m) return result(null, null, 'HEAD does not hold a 40 / 64 hex object name or a ref');
    const ref = m[1];
    if (/(^|\/)\.invalid$/.test(ref) || isDir(path.win32.join(dirs.commonDir, 'reftable'))) {
      return result(null, null, 'reftable repository: refs are not plain files, commit not read (git is not started)');
    }
    if (!ref.startsWith('refs/') || ref.includes('..') || ref.includes('\\') || ref.includes(':')) {
      return result(null, null, `HEAD ref '${ref}' is refused (must be refs/..., without '..', '\\' or ':')`);
    }
    const search = pathKey(dirs.commonDir) === pathKey(dirs.gitDir) ? [dirs.gitDir] : [dirs.gitDir, dirs.commonDir];
    let commit = null;
    for (const d of search) {
      const v = readFirstLineStrict(path.win32.join(d, ...ref.split('/')));
      if (v !== null) {
        commit = v;
        break;
      }
    }
    if (commit === null) {
      outer: for (const d of search) {
        const packed = path.win32.join(d, 'packed-refs');
        if (!isFile(packed)) continue;
        for (const line of readText(packed).split(/\r?\n/)) {
          const p = PACKED_RE.exec(line);
          if (p && p[2] === ref) {
            commit = p[1];
            break outer;
          }
        }
      }
    }
    if (commit === null) return result(null, ref, `unborn branch: ${ref} has no commit`);
    if (commit.startsWith('ref:')) return result(null, ref, `symbolic ref chain (${ref} -> another ref) is not followed`);
    if (!OBJECT_NAME_RE.test(commit)) return result(null, ref, 'HEAD / ref does not hold a 40 / 64 hex object name');
    return result(commit.toLowerCase(), ref, null);
  } catch {
    return null; /* unreadable repository: no commit */
  }
}

/** Full (40 / 64 character, lower-case) object name HEAD of the checkout points at, or null. */
export function readHeadCommit(root) {
  return readGitHead(root)?.commit ?? null;
}

/** Root of the main checkout of the repository the checkout `root` belongs to, or null (bare / unknown). */
export function mainCheckoutOf(root) {
  const dirs = gitDirsOf(root);
  if (!dirs) return null;
  if (path.win32.basename(dirs.commonDir).toLowerCase() !== '.git') return null;
  const main = path.win32.dirname(dirs.commonDir);
  return isDir(path.win32.join(main, '.git')) ? main : null;
}

/**
 * Checkout roots of the repository: the main checkout first, then every worktree registered in
 * <main>\.git\worktrees whose directory exists and whose .git file points back to that entry.
 */
export function listCheckouts(mainRoot) {
  if (typeof mainRoot !== 'string' || !isDir(path.win32.join(mainRoot, '.git'))) return [];
  const out = [path.win32.normalize(mainRoot)];
  const wtDir = path.win32.join(mainRoot, '.git', 'worktrees');
  let names = [];
  try {
    names = fs.readdirSync(wtDir);
  } catch {
    return out;
  }
  for (const name of names) {
    const entry = path.win32.join(wtDir, name);
    const gitFile = readFirstLine(path.win32.join(entry, 'gitdir'));
    if (!gitFile) continue;
    const dotGit = path.win32.resolve(entry, gitFile);
    if (path.win32.basename(dotGit).toLowerCase() !== '.git' || !isFile(dotGit)) continue;
    const wtRoot = path.win32.dirname(dotGit);
    const back = gitDirsOf(wtRoot);
    if (!back || pathKey(back.gitDir) !== pathKey(entry)) continue;
    out.push(path.win32.normalize(wtRoot));
  }
  return out;
}

/** The module paths ReloadModule accepts, derived from the module path the server was started with. */
export function allowedModulePaths(baseModulePath) {
  const root = checkoutRootOf(baseModulePath);
  if (!root) return [];
  const main = mainCheckoutOf(root);
  if (!main) return [];
  return listCheckouts(main).map((r) => path.win32.join(r, MODULE_RELATIVE_PATH));
}

/**
 * Is `candidate` one of the allowed module paths? -> { ok: true, path } (the allowed spelling) or
 * { ok: false, reason, allowed }.
 */
export function checkModulePath(candidate, baseModulePath) {
  const allowed = allowedModulePaths(baseModulePath);
  if (typeof candidate !== 'string' || !candidate.trim()) return { ok: false, reason: 'ModulePath is empty', allowed };
  if (!path.win32.isAbsolute(candidate.trim()) || /^[\\/](?![\\/])/.test(candidate.trim())) {
    return { ok: false, reason: 'ModulePath must be an absolute path', allowed };
  }
  if (allowed.length === 0) {
    return { ok: false, reason: 'the module the server was started with is not part of a git checkout, so no other ModulePath is allowed', allowed };
  }
  const key = pathKey(candidate);
  const hit = allowed.find((a) => pathKey(a) === key);
  if (!hit) return { ok: false, reason: 'ModulePath is neither the main checkout module nor the same file in one of its git worktrees', allowed };
  if (!isFile(hit)) return { ok: false, reason: `${hit} does not exist`, allowed };
  return { ok: true, path: hit, allowed };
}

/** { modulePath, moduleCommit } for a loaded module path (commit null outside a checkout). */
export function moduleInfoOf(modulePath) {
  const root = checkoutRootOf(modulePath);
  return { modulePath: typeof modulePath === 'string' ? modulePath : null, moduleCommit: root ? readHeadCommit(root) : null };
}
