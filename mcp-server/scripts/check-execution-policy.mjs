// Fails with a clear message when Windows PowerShell 5.1 cannot run local scripts (#25 review, #144):
// npm run generate-tools starts powershell.exe WITHOUT -ExecutionPolicy Bypass. Same check as
// scripts/check.ps1 (scripts/lib/ExecutionPolicy.ps1): "Get-ExecutionPolicy" for the effective
// policy, "Get-ExecutionPolicy -List" to see whether a group policy (MachinePolicy / UserPolicy)
// sets it: a group policy wins over Set-ExecutionPolicy -Scope CurrentUser, so that advice would
// not help there.
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

const BLOCKING = ['Restricted', 'AllSigned'];

// listText: one "<Scope>=<Policy>" per line (the format emitted by LIST_COMMAND below).
export function parsePolicyList(listText) {
  const map = {};
  for (const line of String(listText ?? '').split(/\r?\n/)) {
    const m = /^\s*(\w+)\s*=\s*(\w+)\s*$/.exec(line);
    if (m) map[m[1]] = m[2];
  }
  return map;
}

// Returns null when local scripts can run, otherwise the message to show.
export function policyAdvice(effective, listText) {
  if (!BLOCKING.includes(effective)) return null;
  const list = parsePolicyList(listText);
  const gpo = ['MachinePolicy', 'UserPolicy'].filter((s) => list[s] && list[s] !== 'Undefined');
  if (gpo.length > 0) {
    return `PowerShell execution policy is ${effective}, set by group policy (${gpo.map((s) => `${s}=${list[s]}`).join(', ')}): local scripts cannot run and Set-ExecutionPolicy cannot override it. Ask your IT administrator.`;
  }
  return `PowerShell execution policy is ${effective}: local scripts cannot run. Run once: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`;
}

export const LIST_COMMAND = "Get-ExecutionPolicy; Get-ExecutionPolicy -List | ForEach-Object { ('{0}={1}' -f $_.Scope, $_.ExecutionPolicy) }";

function main() {
  const r = spawnSync('powershell.exe', ['-NoProfile', '-Command', LIST_COMMAND], { encoding: 'utf8' });
  const lines = (r.stdout ?? '').split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  const policy = lines[0] ?? '';
  if (r.status !== 0 || !policy) {
    console.error(`could not read the PowerShell execution policy (exit ${r.status}): ${(r.stderr ?? '').trim()}`);
    process.exit(1);
  }
  const advice = policyAdvice(policy, lines.slice(1).join('\n'));
  if (advice) {
    console.error(advice);
    process.exit(1);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main();
