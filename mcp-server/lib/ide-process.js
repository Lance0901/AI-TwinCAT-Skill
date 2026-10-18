// Liveness check for the IDE pid remembered in index.js (data.lastIde). Before a BRIDGE_TIMEOUT /
// BRIDGE_DIED hint tells the user to `taskkill` that pid, make sure the pid still belongs to a
// TcXaeShell.exe / devenv.exe: pids are recycled, and a stale lastIde could otherwise name an
// unrelated process.
import { execFile } from 'node:child_process';

// Complete as is (verified with TwinCAT 3.1.4026): the 32-bit shell
// (C:\Program Files (x86)\Beckhoff\TcXaeShell\Common7\IDE\TcXaeShell.exe, ProgId TcXaeShell.DTE.15.0)
// and the 64-bit shell (C:\Program Files\Beckhoff\TcXaeShell\Common7\IDE\TcXaeShell.exe, ProgId
// TcXaeShell.DTE.17.0) are both TcXaeShell.exe; Visual Studio 2022 is devenv.exe.
export const IDE_IMAGE_NAMES = new Set(['tcxaeshell.exe', 'devenv.exe']);

/** Parse `tasklist /FO CSV /NH` output; returns the image name of the first row, or null. */
export function parseTasklistImageName(output) {
  const m = /^\s*"([^"]*)","(\d+)"/m.exec(String(output ?? ''));
  return m ? m[1] : null;
}

function runTasklist(pid) {
  return new Promise((resolve) => {
    try {
      execFile(
        'tasklist',
        ['/FI', `PID eq ${pid}`, '/FO', 'CSV', '/NH'],
        { windowsHide: true, timeout: 10000, encoding: 'utf8' },
        (err, stdout) => resolve(err ? null : stdout)
      );
    } catch {
      resolve(null);
    }
  });
}

/**
 * Resolves true when `pid` is a running TcXaeShell.exe or devenv.exe.
 * - `env.TWINCAT_MCP_SKIP_PID_CHECK=1` -> always true (tests with a mock IDE pid).
 * - `tasklist` unavailable or failing -> false (a generic hint is safer than a wrong taskkill).
 * - Non-Windows hosts -> false (the IDE only exists on Windows).
 * @param {number} pid
 * @param {{env?:NodeJS.ProcessEnv, platform?:string, tasklist?:(pid:number)=>Promise<string|null>}} [deps]
 */
export async function isIdeProcessAlive(pid, deps = {}) {
  const env = deps.env ?? process.env;
  if (!Number.isInteger(pid) || pid <= 0) return false;
  if (String(env.TWINCAT_MCP_SKIP_PID_CHECK ?? '').trim() === '1') return true;
  const platform = deps.platform ?? process.platform;
  if (platform !== 'win32') return false;
  const output = await (deps.tasklist ?? runTasklist)(pid);
  if (output === null) return false;
  const name = parseTasklistImageName(output);
  return name !== null && IDE_IMAGE_NAMES.has(name.toLowerCase());
}
