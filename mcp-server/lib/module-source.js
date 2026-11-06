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
//   - every file is decoded as UTF-8 (a UTF-8 BOM is dropped, nothing else is detected: a UTF-16
//     file is garbage, as for git), first line, only ASCII blanks (space, tab, CR, LF) trimmed;
//   - .git is a directory or a file "gitdir: <path>" (relative to the checkout root); "gitdir:" and
//     "ref:" are case-sensitive, as git reads them (https://git-scm.com/docs/gitrepository-layout);
//     commondir (relative to the gitdir) holds refs and packed-refs of a linked worktree;
//   - HEAD is a detached 40 (SHA-1) or 64 (SHA-256) hex object name (either case, returned in lower
//     case) or `ref: refs/<name>` with a name git-check-ref-format accepts
//     (https://git-scm.com/docs/git-check-ref-format, isGitRefName; non-ASCII branch names work);
//   - the loose ref (gitdir, then common dir) wins over packed-refs, whose names are compared
//     case-sensitively.
// Limits (moduleCommit is then null, never a wrong sha):
//   - a repository using the reftable backend (extensions.refStorage = reftable,
//     https://git-scm.com/docs/reftable: HEAD is `ref: refs/heads/.invalid`, a reftable directory)
//     is not read; readGitHead says so in `note`.
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
// [^\n] like '.' of .NET (a JavaScript '.' also stops at \r, U+2028, U+2029)
const PACKED_RE = /^([0-9a-fA-F]{40}|[0-9a-fA-F]{64}) ([^\n]+)$/;

/** Only ASCII blanks, like Read-TcGitCommit (String.prototype.trim also drops U+FEFF, U+3000, ...). */
function trimBlank(s) {
  return s.replace(/^[ \t\r\n]+|[ \t\r\n]+$/g, '');
}

/**
 * A ref name git itself would accept (https://git-scm.com/docs/git-check-ref-format), and that is
 * safe as a path below the gitdir: refs/<name>, no '..', '\', ':', '~', '^', '?', '*', '[', blank,
 * control character or '@{'; no empty component, no component starting with '.' or ending with
 * '.lock'; not ending with '.' or '/'. Windows drops a trailing '.' of a path component, so
 * "refs/heads/foo." would otherwise read refs/heads/foo. Same rule as Test-TcGitRefName (#148).
 */
export function isGitRefName(ref) {
  if (typeof ref !== 'string' || !ref.startsWith('refs/')) return false;
  if (ref.endsWith('.') || ref.endsWith('/') || ref.includes('..') || ref.includes('@{')) return false;
  for (const ch of ref) {
    const c = ch.codePointAt(0);
    if (c < 0x20 || c === 0x7f || ' ~^:?*[\\'.includes(ch)) return false;
  }
  return ref.split('/').every((part) => part.length > 0 && !part.startsWith('.') && !part.endsWith('.lock'));
}

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
  return trimBlank(readText(file).split(/\r?\n/, 1)[0]);
}

/** UTF-8 text without a leading BOM (Read-TcGitCommit: UTF8Encoding without detection, U+FEFF dropped). */
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
    const m = /^gitdir:[ \t]*([^\n]+)$/.exec(first(dot) ?? '');
    if (m) gitDir = path.win32.resolve(root, trimBlank(m[1]));
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
    const m = /^ref:[ \t]*([^ \t\n]+)$/.exec(head);
    if (!m) return result(null, null, 'HEAD does not hold a 40 / 64 hex object name or a ref');
    const ref = m[1];
    if (/(^|\/)\.invalid$/.test(ref) || isDir(path.win32.join(dirs.commonDir, 'reftable'))) {
      return result(null, null, 'reftable repository: refs are not plain files, commit not read (git is not started)');
    }
    if (!isGitRefName(ref)) {
      return result(null, null, `HEAD ref '${ref}' is refused (not a ref name git-check-ref-format accepts below refs/)`);
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
    const why = installedRootOf(baseModulePath)
      ? 'the server runs an installed runtime (#162), not a git checkout, so no other ModulePath is allowed (switch versions with Install-TcAutoRuntime.ps1 + ReloadRuntime)'
      : 'the module the server was started with is not part of a git checkout, so no other ModulePath is allowed';
    return { ok: false, reason: why, allowed };
  }
  const key = pathKey(candidate);
  const hit = allowed.find((a) => pathKey(a) === key);
  if (!hit) return { ok: false, reason: 'ModulePath is neither the main checkout module nor the same file in one of its git worktrees', allowed };
  if (!isFile(hit)) return { ok: false, reason: `${hit} does not exist`, allowed };
  return { ok: true, path: hit, allowed };
}

/** File name of the runtime stamp scripts/Install-TcAutoRuntime.ps1 writes into an installed runtime (#162). */
export const SOURCE_STAMP_NAME = 'tcauto-source.json';

/**
 * The stamp <root>\tcauto-source.json of an installed runtime (#162), or null when there is none or
 * it is not usable. Same file name and the same commit / ref fields as the release stamp that
 * Get-TcSourceInfo reads (Private/InstallManifest.ps1); Install-TcAutoRuntime.ps1 adds branch,
 * dirty, installedAt, sourcePath and version. A commit that is not a 40 / 64 hex object name is
 * null (never a guess); dirty is true / false only when the stamp says so, else null.
 */
export function readSourceStamp(root) {
  if (typeof root !== 'string' || !root) return null;
  const file = path.win32.join(root, SOURCE_STAMP_NAME);
  if (!isFile(file)) return null;
  let s;
  try {
    s = JSON.parse(readText(file));
  } catch {
    return null;
  }
  if (!s || typeof s !== 'object' || Array.isArray(s)) return null;
  const str = (v) => (typeof v === 'string' && v.length ? v : null);
  return {
    kind: str(s.kind),
    commit: typeof s.commit === 'string' && OBJECT_NAME_RE.test(s.commit) ? s.commit.toLowerCase() : null,
    ref: str(s.ref),
    branch: str(s.branch),
    dirty: typeof s.dirty === 'boolean' ? s.dirty : null,
    installedAt: str(s.installedAt),
    sourcePath: str(s.sourcePath),
    version: str(s.version)
  };
}

/**
 * <root> when modulePath is <root>\src\TwinCATAutomation\TwinCATAutomation.psm1 of an installed
 * runtime (#162: <root> holds a readable tcauto-source.json with kind 'tcauto-runtime'), else null.
 */
export function installedRootOf(modulePath) {
  const mp = normalizePath(modulePath);
  if (mp === null) return null;
  const root = path.win32.resolve(mp, '..', '..', '..');
  if (pathKey(path.win32.join(root, MODULE_RELATIVE_PATH)) !== mp.toLowerCase()) return null;
  return readSourceStamp(root)?.kind === RUNTIME_STAMP_KIND ? root : null;
}

/** `kind` of the stamp Install-TcAutoRuntime.ps1 writes; a release stamp (#20) or anything else is not an installed runtime. */
export const RUNTIME_STAMP_KIND = 'tcauto-runtime';

/**
 * { modulePath, moduleCommit, moduleDirty, moduleSource } for a loaded module path:
 *   - a git checkout: commit read from the .git files, dirty null (not known without running git),
 *     moduleSource 'git-checkout';
 *   - an installed runtime (#162): commit and dirty from its tcauto-source.json, moduleSource 'installed';
 *   - anything else: commit / dirty / moduleSource null.
 */
export function moduleInfoOf(modulePath) {
  const p = typeof modulePath === 'string' ? modulePath : null;
  const root = checkoutRootOf(modulePath);
  if (root) return { modulePath: p, moduleCommit: readHeadCommit(root), moduleDirty: null, moduleSource: 'git-checkout' };
  const inst = installedRootOf(modulePath);
  const stamp = inst ? readSourceStamp(inst) : null;
  if (stamp) return { modulePath: p, moduleCommit: stamp.commit, moduleDirty: stamp.dirty, moduleSource: 'installed' };
  return { modulePath: p, moduleCommit: null, moduleDirty: null, moduleSource: null };
}
