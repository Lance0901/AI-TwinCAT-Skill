# Unit-test state isolation (#118). Dot-source it at the top of every tests/Unit/*.ps1 that loads
# the module, BEFORE the first Import-Module (scripts/check.ps1 "unit" fails a script that does not):
#   . (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1')
# - $env:TCAUTO_STATE_DIR: kept when the caller already set one (scripts/check.ps1 gives every
#   script its own empty folder and removes it afterwards); otherwise a new empty folder
#   %TEMP%\tcauto-unit-state-<guid> (removed when this PowerShell exits). Every module state file
#   follows it: build-required.json, lifecycle-block.json (+ history) and ide-solutions.json, and
#   the mutex names get the hash of that folder.
# - $env:TCAUTO_TEST_FORBID_REAL_STATE = '1': the module refuses the real default folders
#   (%TEMP%\TwinCATAutomation, %LOCALAPPDATA%\TwinCATAutomation) if a test ever clears
#   TCAUTO_STATE_DIR while still calling it: it throws and prints TCAUTO_REAL_STATE_REFUSED on
#   stderr, which scripts/check.ps1 turns into a FAIL.
# Never point TCAUTO_STATE_DIR at a real state folder: this helper throws when it does.

function Get-TcUnitRealStateDirs {
    $dirs = @(Join-Path ([IO.Path]::GetTempPath()) 'TwinCATAutomation')
    if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) { $dirs += Join-Path $env:TEMP 'TwinCATAutomation' }
    if (-not [string]::IsNullOrWhiteSpace($env:TCAUTO_UNIT_REAL_LOCALAPPDATA)) { $dirs += Join-Path $env:TCAUTO_UNIT_REAL_LOCALAPPDATA 'TwinCATAutomation' }
    elseif (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { $dirs += Join-Path $env:LOCALAPPDATA 'TwinCATAutomation' }
    @($dirs | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') })
}

function Test-TcUnitRealStateDir([string]$Dir) {
    if ([string]::IsNullOrWhiteSpace($Dir)) { return $true }
    $full = [IO.Path]::GetFullPath($Dir).TrimEnd('\')
    foreach ($real in Get-TcUnitRealStateDirs) {
        if ([string]::Equals($full, $real, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ($full.StartsWith($real + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    $false
}

# The real %LOCALAPPDATA% as seen when the helper first ran (tests may redirect LOCALAPPDATA later).
if ([string]::IsNullOrWhiteSpace($env:TCAUTO_UNIT_REAL_LOCALAPPDATA)) { $env:TCAUTO_UNIT_REAL_LOCALAPPDATA = $env:LOCALAPPDATA }

if ([string]::IsNullOrWhiteSpace($env:TCAUTO_STATE_DIR)) {
    $env:TCAUTO_STATE_DIR = Join-Path ([IO.Path]::GetTempPath()) ("tcauto-unit-state-{0}" -f [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $env:TCAUTO_STATE_DIR -Force
    $global:TcUnitOwnStateDir = $env:TCAUTO_STATE_DIR
    $null = Register-EngineEvent -SourceIdentifier ([System.Management.Automation.PsEngineEvent]::Exiting) -Action {
        if ($global:TcUnitOwnStateDir) { Remove-Item -LiteralPath $global:TcUnitOwnStateDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
if (Test-TcUnitRealStateDir $env:TCAUTO_STATE_DIR) {
    throw "UnitIsolation: TCAUTO_STATE_DIR '$($env:TCAUTO_STATE_DIR)' is a real TcAuto state folder; unit tests must use a temp folder (#118)"
}
$env:TCAUTO_TEST_FORBID_REAL_STATE = '1'
