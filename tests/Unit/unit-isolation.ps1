# Unit: the #118 isolation helper (tests/Unit/lib/UnitIsolation.ps1) never leaves its environment in
# the caller's session. A unit test run with "& script.ps1" from a persistent PowerShell must not
# leave TCAUTO_STATE_DIR / TCAUTO_TEST_FORBID_REAL_STATE behind: a later real Enable-TcConfig in that
# session would read the temp state (missing a real lifecycle block, #68) or throw.
# The persistent session is simulated by "powershell.exe -NoProfile -EncodedCommand" that runs a
# short unit test (build-error-category.ps1) with "&" and prints its environment before / after.
# No IDE / runtime, nothing in the real %TEMP%\TwinCATAutomation is used.
#   powershell.exe -NoProfile -File tests/Unit/unit-isolation.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 400) { $Detail = $Detail.Substring(0, 400) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}

$inner = Join-Path $PSScriptRoot 'build-error-category.ps1'
$sentinel = Join-Path $env:TCAUTO_STATE_DIR 'caller-session-state'
$null = New-Item -ItemType Directory -Path $sentinel -Force

# The simulated session points TEMP / TMP / LOCALAPPDATA at folders inside this test's isolated
# TCAUTO_STATE_DIR first: even a future relaunch regression (test running un-isolated in that
# session) cannot reach the machine's real %TEMP% / %LOCALAPPDATA%\TwinCATAutomation.
$sessionEnv = Join-Path $env:TCAUTO_STATE_DIR 'session-env'
foreach ($d in 'temp', 'localappdata') { $null = New-Item -ItemType Directory -Path (Join-Path $sessionEnv $d) -Force }
$redirect = @"
`$env:TEMP = '$((Join-Path $sessionEnv 'temp') -replace "'", "''")'
`$env:TMP = `$env:TEMP
`$env:LOCALAPPDATA = '$((Join-Path $sessionEnv 'localappdata') -replace "'", "''")'
"@

# Runs $Body in a fresh "persistent session" (-EncodedCommand, so the inner test is NOT the -File
# entry of that process) and returns its output lines.
function Invoke-Session([string]$Body) {
    $Body = $redirect + "`r`n" + $Body
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Body))
    $saved = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = @(& powershell.exe -NoProfile -NonInteractive -EncodedCommand $enc 2>&1 | ForEach-Object { "$_" }) }
    finally { $ErrorActionPreference = $saved }
    $out
}
function Get-Value([string[]]$Lines, [string]$Key) {
    $l = @($Lines | Where-Object { $_ -like "$Key=*" } | Select-Object -Last 1)
    if ($l.Count -eq 0) { return '<missing>' }
    $l[0].Substring($Key.Length + 1)
}

# 1. caller session has its own TCAUTO_STATE_DIR and no refusal flag: both unchanged after "&"
$body = @"
`$env:TCAUTO_STATE_DIR = '$($sentinel -replace "'", "''")'
Remove-Item Env:\TCAUTO_TEST_FORBID_REAL_STATE -ErrorAction SilentlyContinue
Remove-Item Env:\TCAUTO_UNIT_RELAUNCHED -ErrorAction SilentlyContinue
`$ErrorActionPreference = 'Continue'
`$o = @(& '$($inner -replace "'", "''")' 2>&1 | ForEach-Object { "`$_" })
"code=`$LASTEXITCODE"
"innerFailed=`$((`$o | Where-Object { `$_ -match '^failed:' }) -join ',')"
"innerPass=`$(@(`$o | Where-Object { `$_ -match '^PASS ' }).Count)"
"dir=`$(`$env:TCAUTO_STATE_DIR)"
"forbid=[`$(`$env:TCAUTO_TEST_FORBID_REAL_STATE)]"
"relaunch=[`$(`$env:TCAUTO_UNIT_RELAUNCHED)]"
"eap=`$ErrorActionPreference"
"module=`$(@(Get-Module TwinCATAutomation).Count)"
"@
$out = Invoke-Session $body
Check 'amp-inner-ran' ((Get-Value $out 'code') -eq '0' -and [int](Get-Value $out 'innerPass') -gt 0) "code=$(Get-Value $out 'code') failed=$(Get-Value $out 'innerFailed') pass=$(Get-Value $out 'innerPass') | $($out -join ' / ')"
Check 'amp-state-dir-unchanged' ((Get-Value $out 'dir') -eq $sentinel) "dir=$(Get-Value $out 'dir')"
Check 'amp-forbid-not-left' ((Get-Value $out 'forbid') -eq '[]') "forbid=$(Get-Value $out 'forbid')"
Check 'amp-relaunch-marker-not-left' ((Get-Value $out 'relaunch') -eq '[]') "relaunch=$(Get-Value $out 'relaunch')"
Check 'amp-eap-unchanged' ((Get-Value $out 'eap') -eq 'Continue') "eap=$(Get-Value $out 'eap')"
Check 'amp-module-not-loaded-in-caller' ((Get-Value $out 'module') -eq '0') "module=$(Get-Value $out 'module')"

# 2. caller session WITHOUT TCAUTO_STATE_DIR: still unset afterwards (the inner run used its own temp folder)
$body = @"
Remove-Item Env:\TCAUTO_STATE_DIR -ErrorAction SilentlyContinue
Remove-Item Env:\TCAUTO_TEST_FORBID_REAL_STATE -ErrorAction SilentlyContinue
Remove-Item Env:\TCAUTO_UNIT_RELAUNCHED -ErrorAction SilentlyContinue
`$o = @(& '$($inner -replace "'", "''")' 2>&1 | ForEach-Object { "`$_" })
"code=`$LASTEXITCODE"
"dir=[`$(`$env:TCAUTO_STATE_DIR)]"
"forbid=[`$(`$env:TCAUTO_TEST_FORBID_REAL_STATE)]"
"@
$out = Invoke-Session $body
Check 'amp-unset-inner-ran' ((Get-Value $out 'code') -eq '0') "code=$(Get-Value $out 'code') | $($out -join ' / ')"
Check 'amp-unset-state-dir-still-unset' ((Get-Value $out 'dir') -eq '[]') "dir=$(Get-Value $out 'dir')"
Check 'amp-unset-forbid-not-left' ((Get-Value $out 'forbid') -eq '[]') "forbid=$(Get-Value $out 'forbid')"

# 3. a failing inner exit code reaches the caller ($LASTEXITCODE of the relaunched child)
$failing = Join-Path $env:TCAUTO_STATE_DIR 'fail118.ps1'
Set-Content -LiteralPath $failing -Encoding ASCII -Value @(
    '$ErrorActionPreference = ''Stop'''
    ". '$((Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -replace "'", "''")' -Caller `$PSCommandPath -CallerArgs `$PSBoundParameters; if (`$null -ne `$TcUnitChildExit) { exit `$TcUnitChildExit }"
    'exit 3'
)
$body = @"
`$null = & '$($failing -replace "'", "''")' 2>&1
"code=`$LASTEXITCODE"
"@
$out = Invoke-Session $body
Check 'amp-exit-code-propagated' ((Get-Value $out 'code') -eq '3') "code=$(Get-Value $out 'code') | $($out -join ' / ')"

# 4. a non-switch parameter is not re-serialised onto a command line: the helper throws, the test
#    body does not run (neither here nor in a child) and the session environment is unchanged
$withArg = Join-Path $env:TCAUTO_STATE_DIR 'arg118.ps1'
Set-Content -LiteralPath $withArg -Encoding ASCII -Value @(
    'param([string]$Name)'
    '$ErrorActionPreference = ''Stop'''
    ". '$((Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -replace "'", "''")' -Caller `$PSCommandPath -CallerArgs `$PSBoundParameters; if (`$null -ne `$TcUnitChildExit) { exit `$TcUnitChildExit }"
    '"body-ran"'
    'exit 0'
)
$body = @"
Remove-Item Env:\TCAUTO_STATE_DIR -ErrorAction SilentlyContinue
Remove-Item Env:\TCAUTO_TEST_FORBID_REAL_STATE -ErrorAction SilentlyContinue
`$o = @(try { & '$($withArg -replace "'", "''")' -Name 'a "b" c\' 2>&1 | ForEach-Object { "`$_" } } catch { "caught=`$(`$_.Exception.Message)" })
`$o
"dir=[`$(`$env:TCAUTO_STATE_DIR)]"
"forbid=[`$(`$env:TCAUTO_TEST_FORBID_REAL_STATE)]"
"@
$out = Invoke-Session $body
Check 'arg-not-forwarded-throws' (@($out | Where-Object { $_ -match 'cannot forward -Name' }).Count -ge 1) "$($out -join ' / ')"
Check 'arg-body-not-run' (@($out | Where-Object { $_ -eq 'body-ran' }).Count -eq 0) "$($out -join ' / ')"
Check 'arg-env-unchanged' ((Get-Value $out 'dir') -eq '[]' -and (Get-Value $out 'forbid') -eq '[]') "dir=$(Get-Value $out 'dir') forbid=$(Get-Value $out 'forbid')"

"failed: $fail"
exit [Math]::Min($fail, 255)
