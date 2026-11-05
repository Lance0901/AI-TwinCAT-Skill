// Where the PowerShell module the bridge imports comes from (#41): the checkout it belongs to, the
// commit that checkout has checked out, and the module paths ReloadModule may switch to.
//
// Everything is read from the .git files (HEAD, refs, packed-refs, commondir, worktrees/*/gitdir);
// git.exe is never started. Same rules as Get-TcModuleCommit (Private/Get-TcIssueEnvironment.ps1,
// #78): a module path counts as a checkout only when it is exactly
// <root>\src\TwinCATAutomation\TwinCATAutomation.psm1 and <root> has a .git directory or file.
//
// Allowed ModulePath values (ReloadModule): <main>\src\TwinCATAutomation\TwinCATAutomation.psm1 of
// the main checkout and the same relative path in every worktree of that repository, i.e. the
// entries `git worktree list` shows: <main>\.git\worktrees\<name>\gitdir names <worktree>\.git, and
// that .git file must point back to the same <main>\.git\worktrees\<name> (a stale or foreign entry
// is not allowed). Every other path is refused.
//
// Limits of the commit read (moduleCommit is then null, never a wrong sha):
//   - HEAD must be a 40-character sha (detached) or `ref: refs/...` made of [A-Za-z0-9._/-] only; a
//     branch name with other characters (e.g. non-ASCII, '+', '@{') is not resolved.
//   - only loose refs and packed-refs; a repository using the reftable backend
//     (extensions.refStorage = reftable) has neither, so no commit is found.
//   - SHA-1 repositories only (a SHA-256 repository has 64-character ids).
//   - HEAD only: uncommitted changes in the working tree are not detected (moduleDirty is null).
import fs from 'node:fs';
import path from 'node:path';

export const MODULE_RELATIVE_PATH = path.win32.join('src', 'TwinCATAutomation', 'TwinCATAutomation.psm1');

const SHA_RE = /^[0-9a-f]{40}$/;
const REF_RE = /^ref:\s*(refs\/[A-Za-z0-9._/-]+)$/;

function readFirstLine(file) {
  try {
    return fs.readFileSync(file, 'utf8').split(/\r?\n/, 1)[0].trim();
  } catch {
    return null;
  }
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

/** { gitDir, commonDir } of a checkout root (main checkout or worktree), or null. */
export function gitDirsOf(root) {
  if (typeof root !== 'string' || !root) return null;
  const dot = path.win32.join(root, '.git');
  let gitDir = null;
  if (isDir(dot)) gitDir = dot;
  else if (isFile(dot)) {
    const m = /^gitdir:\s*(.+)$/.exec(readFirstLine(dot) ?? '');
    if (m) gitDir = path.win32.resolve(root, m[1].trim());
  }
  if (!gitDir || !isDir(gitDir)) return null;
  let commonDir = gitDir;
  const cd = readFirstLine(path.win32.join(gitDir, 'commondir'));
  if (cd) commonDir = path.win32.resolve(gitDir, cd);
  return { gitDir: path.win32.normalize(gitDir), commonDir: path.win32.normalize(commonDir) };
}

/** Full 40-character sha HEAD of the checkout points at (loose ref, then packed-refs), or null. */
export function readHeadCommit(root) {
  try {
    const dirs = gitDirsOf(root);
    if (!dirs) return null;
    const head = readFirstLine(path.win32.join(dirs.gitDir, 'HEAD'));
    if (!head) return null;
    if (SHA_RE.test(head)) return head;
    const m = REF_RE.exec(head);
    if (!m || m[1].includes('..')) return null;
    const ref = m[1];
    const search = dirs.commonDir === dirs.gitDir ? [dirs.gitDir] : [dirs.gitDir, dirs.commonDir];
    for (const d of search) {
      const v = readFirstLine(path.win32.join(d, ...ref.split('/')));
      if (v && SHA_RE.test(v)) return v;
    }
    for (const d of search) {
      let text;
      try {
        text = fs.readFileSync(path.win32.join(d, 'packed-refs'), 'utf8');
      } catch {
        continue;
      }
      for (const line of text.split(/\r?\n/)) {
        const sp = line.indexOf(' ');
        if (sp === 40 && line.slice(sp + 1) === ref && SHA_RE.test(line.slice(0, 40))) return line.slice(0, 40);
      }
    }
  } catch {
    /* unreadable repository: no commit */
  }
  return null;
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
