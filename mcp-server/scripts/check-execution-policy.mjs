// Fails with a clear message when Windows PowerShell 5.1 cannot run local scripts (#25 review):
// npm run generate-tools starts powershell.exe WITHOUT -ExecutionPolicy Bypass. Same check as
// scripts/check.ps1 ("powershell.exe -NoProfile -Command Get-ExecutionPolicy").
import { spawnSync } from 'node:child_process';

const r = spawnSync('powershell.exe', ['-NoProfile', '-Command', 'Get-ExecutionPolicy'], { encoding: 'utf8' });
const policy = (r.stdout ?? '').trim();
if (r.status !== 0 || !policy) {
  console.error(`could not read the PowerShell execution policy (exit ${r.status}): ${(r.stderr ?? '').trim()}`);
  process.exit(1);
}
if (policy === 'Restricted' || policy === 'AllSigned') {
  console.error(`PowerShell execution policy is ${policy}: local scripts cannot run. Run once: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`);
  process.exit(1);
}
