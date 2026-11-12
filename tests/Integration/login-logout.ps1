<#
.SYNOPSIS
    Manual integration test: Connect-TcIde -> Enter-TcPlcOnline -> Exit-TcPlcOnline -> Enter again.
.DESCRIPTION
    Login / logout round trip. Since #232 both cmdlets read the login state back: check
    data.loggedIn (true after Enter, false after Exit) and data.logoutVia. Logoff() works on the
    "<Plc> Project" tree item (data.logoutVia = treeItem.Logoff); calling it on the PLC node
    TIPC^<Plc> throws (measured 2026-11-13, 4026.22 VS2022 and a 4024 project in the 32-bit
    TcXaeShell, local UmRT). The 2026-10-18 note that the "<Plc> Project" item has no Logoff came
    from Get-Member only and was wrong. Requires a running IDE-capable machine and a target whose PLC
    program is already loaded (local UmRT is fine). Prints one JSON result per step.
.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Integration\login-logout.ps1 `
        -SolutionPath "C:\...\TwinCAT_Festo.sln" -ProgId TcXaeShell.DTE.15.0 -AmsNetId 199.5.42.250.1.1
#>
param(
    [Parameter(Mandatory)][string]$SolutionPath,
    [string]$ProgId = 'TcXaeShell.DTE.15.0',
    [string]$AmsNetId = '199.5.42.250.1.1',  # tcauto-allow(amsnetid): integration default = the local UmRT_Default of the test PC; pass -AmsNetId for any other target
    [string]$LogPath = (Join-Path $PSScriptRoot 'logs\login-logout.log'),
    [switch]$KeepIde
)

Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue

$logDir = Split-Path $LogPath
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
function Log($text) {
    $line = "{0} {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $text
    # Written straight to the file so a hung step still leaves a trace.
    [System.IO.File]::AppendAllText($LogPath, $line + [Environment]::NewLine)
    Write-Output $line
}

function Step($name, $sb) {
    Log "BEGIN $name"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = & $sb
    $sw.Stop()
    $ok = $false; $code = $null
    try { $ok = [bool]$r.success; $code = $r.error.code } catch { }
    $tag = if ($ok) { 'PASS' } else { 'FAIL' }
    Log ("{0} {1} {2}ms {3}" -f $tag, $name, $sw.ElapsedMilliseconds, $(if ($code) { $code } else { '' }))
    Log ("    " + ($r | ConvertTo-Json -Compress -Depth 6))
    return $r
}
Log "=== login-logout start pid=$PID progId=$ProgId ==="

$c = Step 'connect-ide' { Connect-TcIde -SolutionPath $SolutionPath -ProgId $ProgId }
if (-not $c.success) { exit 1 }
$null = Step 'set-target' { Set-TcTarget -AmsNetId $AmsNetId -NoPlatformSwitch }
$null = Step 'login-1'    { Enter-TcPlcOnline }
$x    = Step 'logout'     { Exit-TcPlcOnline }
$null = Step 'login-2'    { Enter-TcPlcOnline }
$null = Step 'plc-state'  { Connect-TcAds | Out-Null; Get-TcPlcState }
$null = Step 'disconnect' { Disconnect-TcAds }

if (-not $KeepIde) {
    $null = Step 'close-ide' { Disconnect-TcIde -Quit }
}
if ($x.success) { exit 0 } else { exit 2 }
