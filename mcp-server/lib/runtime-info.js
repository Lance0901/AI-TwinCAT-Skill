// Where this MCP server process runs from and who started it (#162).
//
// Two ways to run index.js:
//   - from a git checkout (development; `node <repo>\mcp-server\index.js`): runtime.source
//     'git-checkout', commit read from the .git files (module-source.js), dirty null;
//   - from an installed runtime, copied by scripts/Install-TcAutoRuntime.ps1 to
//     <install root>\runtime\<version>\ and started by the launcher
//     (<install root>\launcher\tcauto-launcher.mjs): runtime.source 'installed', commit / branch /
//     dirty / installedAt / sourcePath from <runtime dir>\tcauto-source.json.
//
// Launcher owner id (#152 N1 across ReloadRuntime): the launcher creates ONE GUID for its own
// lifetime and passes it to every runtime child it starts as TCAUTO_LAUNCHER_OWNER_ID, together
// with its own pid as TCAUTO_LAUNCHER_PID. index.js uses that GUID as the TCAUTO_OWNER_ID of its
// PowerShell bridges only when TCAUTO_LAUNCHER_PID equals the pid of the process that started it
// (process.ppid): a value left in a user / system environment or set in a console does not match
// and is ignored (index.js then creates its own GUID, as before). The launcher never reads an owner
// id from its own environment, so the id still changes with every MCP client connection; only a
// ReloadRuntime (same launcher) keeps it.
import fs from 'node:fs';
import path from 'node:path';
import { readGitHead, readSourceStamp, SOURCE_STAMP_NAME } from './module-source.js';

export const LAUNCHER_ENV = Object.freeze({ ownerId: 'TCAUTO_LAUNCHER_OWNER_ID', pid: 'TCAUTO_LAUNCHER_PID' });

const GUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * The launcher that started this process, from env + process.ppid:
 *   null                         no launcher variables (direct start, e.g. from a checkout)
 *   { ok: true, ownerId, pid }   started by a launcher: use ownerId for the bridges
 *   { ok: false, reason }        variables present but not valid for this process: ignored
 */
export function launcherContextFrom(env, ppid) {
  const rawId = env?.[LAUNCHER_ENV.ownerId];
  const rawPid = env?.[LAUNCHER_ENV.pid];
  if ((rawId === undefined || rawId === '') && (rawPid === undefined || rawPid === '')) return null;
  const id = String(rawId ?? '').trim();
  const pid = String(rawPid ?? '').trim();
  if (!GUID_RE.test(id)) return { ok: false, reason: `${LAUNCHER_ENV.ownerId} is not a GUID` };
  if (!/^[1-9][0-9]*$/.test(pid) || Number(pid) !== Number(ppid)) {
    return { ok: false, reason: `${LAUNCHER_ENV.pid} (${pid || 'empty'}) is not the parent process (${ppid})` };
  }
  return { ok: true, ownerId: id.toLowerCase(), pid: Number(pid) };
}

function exists(p) {
  try {
    fs.statSync(p);
    return true;
  } catch {
    return false;
  }
}

/**
 * Runtime of the index.js in `mcpServerDir`:
 *   { source: 'installed' | 'git-checkout' | 'unknown', runtimeDir, runtimeRoot, version, commit,
 *     branch, dirty, installedAt, sourcePath }
 * runtimeRoot is the install root (the folder holding runtime\ and launcher\) of an installed
 * runtime, else null. Never throws.
 */
export function runtimeInfoOf(mcpServerDir) {
  const runtimeDir = path.win32.resolve(mcpServerDir, '..');
  const base = { runtimeDir, runtimeRoot: null, version: null, commit: null, branch: null, dirty: null, installedAt: null, sourcePath: null };
  try {
    const stamp = readSourceStamp(runtimeDir);
    if (stamp) {
      const parent = path.win32.dirname(runtimeDir);
      const inRuntimeFolder = path.win32.basename(parent).toLowerCase() === 'runtime';
      return {
        ...base,
        source: 'installed',
        runtimeRoot: inRuntimeFolder ? path.win32.dirname(parent) : null,
        version: stamp.version ?? path.win32.basename(runtimeDir),
        commit: stamp.commit,
        branch: stamp.branch,
        dirty: stamp.dirty,
        installedAt: stamp.installedAt,
        sourcePath: stamp.sourcePath
      };
    }
    if (exists(path.win32.join(runtimeDir, '.git'))) {
      const head = readGitHead(runtimeDir);
      const ref = head?.ref ?? null;
      return {
        ...base,
        source: 'git-checkout',
        commit: head?.commit ?? null,
        branch: ref && ref.startsWith('refs/heads/') ? ref.slice('refs/heads/'.length) : null,
        sourcePath: runtimeDir
      };
    }
  } catch {
    /* fall through: unknown */
  }
  return { ...base, source: 'unknown' };
}

export { SOURCE_STAMP_NAME };
