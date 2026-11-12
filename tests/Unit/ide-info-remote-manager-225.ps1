# Unit: Get-TcIdeInfo reports the Remote Manager version the IDE uses (#225), read-only, no IDE needed.
# The DTE is a fake object with GetObject('TcRemoteManager'); Assert-TcConnection and
# Get-TcSolutionPlatform are mocked.
# Fake modes: 'ok' (Version '3.1.4024.71') is measured 2026-11-12 (XAE 3.1.4026.22, 32-bit
# TcXaeShell, C:\Temp\Verify-4024-bfh, registered tcauto, GetIdeInfo); 'null' / 'throw' / 'empty'
# are [推論] (not observed): they only check that every other answer ends as remoteManagerError.
#   powershell.exe -NoProfile -File tests/Unit/ide-info-remote-manager-225.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}

# $Mode: 'ok' (Version 3.1.4024.71), 'null' (GetObject returns null), 'throw' (GetObject throws), 'empty' (Version '')
function New-FakeDte([string]$Mode) {
    $o = New-Object PSObject
    $o | Add-Member NoteProperty Version '15.0'
    $o | Add-Member NoteProperty Edition 'TcXaeShell'
    $o | Add-Member NoteProperty Solution ([PSCustomObject]@{ FullName = 'C:\Temp\x.sln' })
    $o | Add-Member NoteProperty Mode $Mode
    $o | Add-Member NoteProperty SetCalls 0
    $o | Add-Member ScriptMethod GetObject {
        param($name)
        if ($name -ne 'TcRemoteManager') { throw "unexpected GetObject('$name')" }
        switch ($this.Mode) {
            'null' { return $null }
            'throw' { throw 'Unknown name (0x80020006)' }
            'empty' { return [PSCustomObject]@{ Version = '' } }
            default { return [PSCustomObject]@{ Version = '3.1.4024.71' } }
        }
    }
    $o
}

& $mod {
    function script:Assert-TcConnection { [CmdletBinding()] param() }
    function script:Get-TcSolutionPlatform { [CmdletBinding()] param() @{ platform = 'TwinCAT RT (x64)'; configuration = 'Release'; projectPlatform = 'TwinCAT RT (x64)' } }
    $script:TcProgId = 'TcXaeShell.DTE.15.0'
}

foreach ($case in @(
        @('ok', '3.1.4024.71', $false),
        @('null', $null, $true),
        @('throw', $null, $true),
        @('empty', $null, $true))) {
    $dte = New-FakeDte $case[0]
    & $mod { param($d) $script:TcDte = $d } $dte
    $r = Get-TcIdeInfo
    $ok = $r.success -and $r.data.remoteManagerVersion -eq $case[1] -and ((-not [string]::IsNullOrWhiteSpace($r.data.remoteManagerError)) -eq $case[2]) -and $r.data.progId -eq 'TcXaeShell.DTE.15.0' -and $r.data.solution -eq 'C:\Temp\x.sln'
    Check "remoteManagerVersion $($case[0])" $ok ($r.data | ConvertTo-Json -Compress)
}

# read-only: Get-TcIdeInfo never assigns TcRemoteManager.Version (that switches the XAE version)
$src = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\Public\Get-TcIdeInfo.ps1')
Check 'never sets TcRemoteManager.Version' ($src -notmatch '\.Version\s*=[^=]') ''

& $mod { $script:TcDte = $null; $script:TcProgId = $null }
"failed: $fail"
exit $fail
