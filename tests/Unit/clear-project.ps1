# Unit: Clear-TcProject readback (issue #18), no IDE / runtime needed.
# A mock DTE replaces $script:TcDte; Get-TcIdeModalDialog / Get-TcBuildErrors are replaced inside
# the module scope, and Invoke-TcComRetry is wrapped so that a LastBuildInfo read can fail.
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Unit/clear-project.ps1
# Exit code = number of failed checks. Takes ~25 s (CLEAN_TIMEOUT 5 s, nullReads 15 s).
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}

$global:Mock = @{}
& $mod {
    $script:TcIdeProcessId = $null   # no watchdog
    function script:Get-TcIdeModalDialog { [CmdletBinding()] param([int]$ProcessId = 0, [int]$TimeoutSec = 5) $null }
    function script:Get-TcBuildErrors { [CmdletBinding()] param([int]$TimeoutSec = 30, [switch]$IncludeWarnings, [switch]$IncludeMessages) $global:Mock.ErrorList }
    $script:UnitOrigComRetry = ${function:Invoke-TcComRetry}
    function script:Invoke-TcComRetry {
        [CmdletBinding()] param([Parameter(Position = 0)][scriptblock]$ScriptBlock, [int]$MaxRetries = 5, [string]$OperationName = 'COM call', [int]$TimeoutSec = 120)
        if ($OperationName -eq 'SolutionBuild.LastBuildInfo' -and $global:Mock.LastBuildInfoThrows) { throw 'LastBuildInfo: RPC_S_CALL_FAILED (mock)' }
        & $script:UnitOrigComRetry @PSBoundParameters
    }
}

function Set-MockDte {
    param([object]$LastBuildInfo = 0, [int]$FinalState = 3, [switch]$NullSolution, [switch]$NeverDone)
    $global:Mock.Polls = 0
    $global:Mock.LastBuildInfo = $LastBuildInfo
    $global:Mock.NeverDone = [bool]$NeverDone
    $sb = New-Object PSObject
    $sb | Add-Member -MemberType ScriptMethod -Name Clean -Value { param($wait) $global:Mock.Cleaned = $true }
    $sb | Add-Member -MemberType ScriptProperty -Name BuildState -Value { $global:Mock.Polls++; if ($global:Mock.NeverDone -or $global:Mock.Polls -lt 2) { 2 } else { 3 } }
    $sb | Add-Member -MemberType ScriptProperty -Name LastBuildInfo -Value { $global:Mock.LastBuildInfo }
    $sol = [PSCustomObject]@{ IsOpen = $true; SolutionBuild = $sb }
    $dte = [PSCustomObject]@{ Solution = $(if ($NullSolution) { $null } else { $sol }) }
    & $mod { param($d) $script:TcDte = $d; $script:TcIdeConnected = $true } $dte
}
$libRow = [PSCustomObject]@{ severity = 'Error'; code = $null; description = "Could not open library '#IecSfc'."; project = 'plc'; file = 'plc.Library Manager'; line = 0 }
$codeRow = [PSCustomObject]@{ severity = 'Error'; code = 'C0046'; description = "Identifier 'x' not defined"; project = 'plc'; file = 'MAIN'; line = 'n/a' }

try {
    Set-MockDte -LastBuildInfo 0
    $r = Clear-TcProject -TimeoutSec 30
    Check 'clean-verified' ($r.success -and $r.data.cleanVerified -and $r.data.failedProjects -eq 0 -and $null -eq $r.data.PSObject.Properties['warningCode'] -and $global:Mock.Cleaned) "success=$($r.success) verified=$($r.data.cleanVerified)"

    Set-MockDte -LastBuildInfo 1
    $global:Mock.ErrorList = [PSCustomObject]@{ success = $true; data = [PSCustomObject]@{ errors = @($libRow, $libRow) } }
    $r = Clear-TcProject -TimeoutSec 30
    Check 'library-only-fails' (-not $r.success -and $r.error.code -eq 'LIBRARY_UNRESOLVED' -and $r.error.hint -match 'AllowUnresolvedLibrary' -and @($r.data.libraryErrorItems).Count -eq 2 -and -not $r.data.cleanVerified) "code=$($r.error.code)"
    Set-MockDte -LastBuildInfo 1
    $r = Clear-TcProject -TimeoutSec 30 -AllowUnresolvedLibrary -WarningAction SilentlyContinue
    Check 'library-only-allowed' ($r.success -and -not $r.data.cleanVerified -and $r.data.warningCode -eq 'LIBRARY_UNRESOLVED' -and $r.data.warning -match '#45') "success=$($r.success) code=$($r.data.warningCode)"

    Set-MockDte -LastBuildInfo 1
    $global:Mock.ErrorList = [PSCustomObject]@{ success = $true; data = [PSCustomObject]@{ errors = @($libRow, $codeRow) } }
    $r = Clear-TcProject -TimeoutSec 30
    Check 'other-error-fails' (-not $r.success -and $r.error.code -eq 'CLEAN_FAILED' -and @($r.data.errorItems).Count -eq 2) "code=$($r.error.code)"

    Set-MockDte -LastBuildInfo 1
    $global:Mock.ErrorList = [PSCustomObject]@{ success = $false; error = [PSCustomObject]@{ code = 'ERRORLIST_UNAVAILABLE' } }
    $r = Clear-TcProject -TimeoutSec 30
    Check 'errorlist-unreadable-fails' (-not $r.success -and $r.error.code -eq 'CLEAN_FAILED' -and $r.data.errorListError -eq 'ERRORLIST_UNAVAILABLE') "code=$($r.error.code)"

    Set-MockDte -LastBuildInfo 0
    $global:Mock.LastBuildInfoThrows = $true
    $r = Clear-TcProject -TimeoutSec 30 -WarningAction SilentlyContinue
    $global:Mock.LastBuildInfoThrows = $false
    Check 'lastbuildinfo-unreadable' (-not $r.success -and $r.error.code -eq 'CLEAN_UNVERIFIED' -and $null -eq $r.data.failedProjects -and -not $r.data.cleanVerified) "code=$($r.error.code)"

    Set-MockDte -LastBuildInfo $null
    $r = Clear-TcProject -TimeoutSec 30 -AllowUnresolvedLibrary
    Check 'lastbuildinfo-null-fails-even-allowed' (-not $r.success -and $r.error.code -eq 'CLEAN_UNVERIFIED') "code=$($r.error.code)"

    Set-MockDte -NeverDone
    $r = Clear-TcProject -TimeoutSec 5
    Check 'clean-timeout' (-not $r.success -and $r.error.code -eq 'CLEAN_TIMEOUT' -and $r.data.buildState -eq 2) "code=$($r.error.code) state=$($r.data.buildState)"

    Set-MockDte -NullSolution
    $r = Clear-TcProject -TimeoutSec 30
    Check 'nullreads-timeout' (-not $r.success -and $r.error.code -eq 'CLEAN_FAILED' -and $r.data.nullReads -gt 0) "code=$($r.error.code) nullReads=$($r.data.nullReads)"
}
finally {
    & $mod { $script:TcDte = $null; $script:TcIdeConnected = $false }
    Remove-Variable -Name Mock -Scope Global -ErrorAction SilentlyContinue
}

"failed: $fail"
exit $fail
