# Unit: Build-TcProject turns the Visual Studio "show Output window when build starts" / "show Error List after a build with errors"
# options off for the build and puts the user's values back (PR #332 round 3 A-3: the first BuildProject restored a minimized
# VS2022 and gave it the foreground). Mock DTE.Properties objects, no IDE.
#   A  Disable-TcBuildAutoShow / Restore-TcBuildAutoShow: only options that are on are changed, the restore is read back
#   B  a host without the options page (Properties throws): nothing changed, no exception
#   C  the IDE ignores the restore write: restored = $false
#   powershell.exe -NoProfile -File tests/Unit/build-autoshow-332.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
$stateRoot = Join-Path $env:TEMP ("tcauto-unit-autoshow-332-{0}" -f [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $stateRoot -Force
$env:TCAUTO_STATE_DIR = Join-Path $stateRoot 'state'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 600) { $Detail = $Detail.Substring(0, 600) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}
function J($o) { $o | ConvertTo-Json -Compress -Depth 6 }

# a Properties object: Item(name) -> an object with a Value property; IgnoreWrites = the IDE does not take the write
function New-MockDte([hashtable]$Values, [switch]$NoPage, [switch]$IgnoreRestore) {
    $items = @{}
    foreach ($k in $Values.Keys) { $items[$k] = [PSCustomObject]@{ Name = $k; Value = [bool]$Values[$k] } }
    $props = [PSCustomObject]@{ Items = $items; Writes = 0; IgnoreRestore = [bool]$IgnoreRestore }
    $props | Add-Member -MemberType ScriptMethod -Name Item -Value { param($n) $this.Items[$n] }
    $dte = [PSCustomObject]@{ PropsObj = $props; NoPage = [bool]$NoPage }
    $dte | Add-Member -MemberType ScriptMethod -Name Properties -Value { param($a, $b) if ($this.NoPage) { throw 'Invalid index (page not found)' }; $this.PropsObj }
    return $dte
}

try {
    # --- A ---
    $dte = New-MockDte @{ ShowOutputWindowBeforeBuild = $true; ShowTaskListAfterBuild = $true }
    $st = & $mod { param($d) Disable-TcBuildAutoShow -Dte $d } $dte
    Check 'A1 both options on: both turned off, before = true / true' ($st.read -and @($st.changed).Count -eq 2 -and -not $dte.PropsObj.Items['ShowOutputWindowBeforeBuild'].Value -and -not $dte.PropsObj.Items['ShowTaskListAfterBuild'].Value) (J $st)
    $rs = & $mod { param($d, $s) Restore-TcBuildAutoShow -Dte $d -State $s } $dte $st
    Check 'A2 restore: both back to true, read back, restored = true' ($rs.restored -and $dte.PropsObj.Items['ShowOutputWindowBeforeBuild'].Value -and $dte.PropsObj.Items['ShowTaskListAfterBuild'].Value) (J $rs)
    $dte = New-MockDte @{ ShowOutputWindowBeforeBuild = $false; ShowTaskListAfterBuild = $true }
    $st = & $mod { param($d) Disable-TcBuildAutoShow -Dte $d } $dte
    Check 'A3 only the option that is on is changed (the user turned the other one off)' (@($st.changed).Count -eq 1 -and $st.changed[0] -eq 'ShowTaskListAfterBuild') (J $st)
    $rs = & $mod { param($d, $s) Restore-TcBuildAutoShow -Dte $d -State $s } $dte $st
    Check 'A3 restore leaves the user''s off option off' ($rs.restored -and -not $dte.PropsObj.Items['ShowOutputWindowBeforeBuild'].Value -and $dte.PropsObj.Items['ShowTaskListAfterBuild'].Value) (J $rs)
    $rs = & $mod { Restore-TcBuildAutoShow -Dte ([PSCustomObject]@{}) -State $null }
    Check 'A4 nothing was changed (state $null): restored = true, nothing touched' ($rs.restored -and @($rs.changed).Count -eq 0) (J $rs)

    # --- B ---
    $dte = New-MockDte @{} -NoPage
    $st = & $mod { param($d) Disable-TcBuildAutoShow -Dte $d } $dte
    Check 'B1 host without the options page: read = false, nothing changed, the error text kept, no exception' (-not $st.read -and @($st.changed).Count -eq 0 -and $st.error -match 'page not found') (J $st)

    # --- C ---
    $dte = New-MockDte @{ ShowOutputWindowBeforeBuild = $true; ShowTaskListAfterBuild = $true }
    $st = & $mod { param($d) Disable-TcBuildAutoShow -Dte $d } $dte
    # the IDE forgets the restore: Value stays false whatever is written
    foreach ($k in @('ShowOutputWindowBeforeBuild', 'ShowTaskListAfterBuild')) {
        $o = $dte.PropsObj.Items[$k]
        $dte.PropsObj.Items[$k] = [PSCustomObject]@{ Name = $k } | Add-Member -MemberType ScriptProperty -Name Value -Value { $false } -SecondValue { param($v) } -PassThru
    }
    $rs = & $mod { param($d, $s) Restore-TcBuildAutoShow -Dte $d -State $s } $dte $st
    Check 'C1 the write does not take: restored = false (judged by the readback, not by the write)' (-not $rs.restored) (J $rs)

    # --- D: Build-TcProject calls both around the build (source check: the build itself needs an IDE) ---
    $src = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\Public\Build-TcProject.ps1'))
    $iDisable = $src.IndexOf('Disable-TcBuildAutoShow -Dte')
    $iBuild = $src.IndexOf('$sb.Build($false)')
    $iRestore = $src.IndexOf('Restore-TcBuildAutoShow -Dte $script:TcDte -State $autoShow')
    $iFinally = $src.LastIndexOf('finally {')
    Check 'D1 Build-TcProject: options off before SolutionBuild.Build, back after the Error List read, and in a finally block' ($iDisable -gt 0 -and $iDisable -lt $iBuild -and $iRestore -gt $iBuild -and $iFinally -gt $iRestore) "disable=$iDisable build=$iBuild restore=$iRestore finally=$iFinally"
}
finally {
    Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
}
"failed: $fail"
exit [Math]::Min($fail, 255)
