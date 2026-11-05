# Unit: scripts/lib/ExecutionPolicy.ps1 (#144). No IDE / runtime. The advice of the check.ps1
# preflight: a Restricted / AllSigned policy set by a group policy (MachinePolicy / UserPolicy)
# says "ask IT" (Set-ExecutionPolicy -Scope CurrentUser cannot override it), otherwise the command.
#   powershell.exe -NoProfile -File tests/Unit/execution-policy.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
. (Join-Path $PSScriptRoot '..\..\scripts\lib\ExecutionPolicy.ps1')
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 400) { $Detail = $Detail.Substring(0, 400) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}

$base = @('MachinePolicy=Undefined', 'UserPolicy=Undefined', 'Process=Undefined', 'CurrentUser=Undefined', 'LocalMachine=Restricted')

foreach ($ok in 'RemoteSigned', 'Bypass', 'Unrestricted', 'Undefined', '') {
    Check "no-advice-for-$ok" ($null -eq (Get-TcPolicyAdvice -Effective $ok -ListLines $base)) $ok
}

$m = Get-TcPolicyAdvice -Effective 'Restricted' -ListLines $base
Check 'restricted-user-settable' ($m -match 'Set-ExecutionPolicy -Scope CurrentUser RemoteSigned' -and $m -notmatch 'IT administrator') $m

$m = Get-TcPolicyAdvice -Effective 'AllSigned' -ListLines @('MachinePolicy=AllSigned', 'UserPolicy=Undefined', 'LocalMachine=Restricted')
Check 'machinepolicy-group-policy' ($m -match 'group policy \(MachinePolicy=AllSigned\)' -and $m -match 'IT administrator' -and $m -notmatch 'Run once') $m

$m = Get-TcPolicyAdvice -Effective 'Restricted' -ListLines @('MachinePolicy=Undefined', 'UserPolicy=Restricted')
Check 'userpolicy-group-policy' ($m -match 'UserPolicy=Restricted' -and $m -match 'IT administrator') $m

$m = Get-TcPolicyAdvice -Effective 'Restricted' -ListLines @('MachinePolicy=AllSigned', 'UserPolicy=Restricted')
Check 'both-policies-listed' ($m -match 'MachinePolicy=AllSigned' -and $m -match 'UserPolicy=Restricted') $m

$m = Get-TcPolicyAdvice -Effective 'Restricted' -ListLines @()
Check 'empty-list-falls-back-to-command' ($m -match 'Run once') $m

# the child command really emits the effective policy first, then Scope=Policy lines
$lines = @((& powershell.exe -NoProfile -Command $script:TcPolicyCommand) | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
Check 'child-command-format' ($lines.Count -ge 6 -and $lines[1] -match '^MachinePolicy=\w+$' -and $lines[2] -match '^UserPolicy=\w+$') ($lines -join ' | ')

"failed: $fail"
exit $fail
