# Unit: XAE project load errors in the Error List (#275), no IDE / runtime needed.
# A PLC object file that XAE could not load (root element renamed, <Declaration> missing, a malformed
# Id, ...) leaves an Error row in the Error List while LastBuildInfo says 0 failed projects and the build
# pane says "0 errors" (the object is not referenced, so the compiler never needs it). Build-TcProject
# used to return success / codeVerified / completeBuild = true with data.errors > 0; Test-TcPlcProject
# put the rows into staleErrorItems with passed = true.
# Rows verbatim from the real machine (實測 2026-11-13, VS2022 17.14 zh-TW + XAE 3.1.4026.22, registered
# tcauto master runtime, C:\Temp\b275\axis = copy of Verify-4026-axis, three unreferenced FBs made by
# AddPou and then broken on disk, ResetSolution, BuildProject / CheckAllObjects).
# The DTE / Error List are mocked in the module scope (same mocks as build-runtime-log-66.ps1); the real
# Build-TcProject, Test-TcPlcProject, Get-TcErrorListSummary and Set/Clear-TcBuildRequired run.
#   powershell.exe -NoProfile -File tests/Unit/build-load-errors-275.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
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
$stateRoot = & $mod { param($p) Get-TcLongPath $p } $env:TCAUTO_STATE_DIR
$sln = Join-Path $stateRoot 'Demo275\Demo275.sln'
$null = New-Item -ItemType Directory -Path (Split-Path -Parent $sln) -Force
Set-Content -LiteralPath $sln -Value '' -Encoding ASCII

function Row([string]$Sev, [string]$Desc, [string]$File = $null, $Line = $null, [string]$Code = $null, [string]$Project = 'AxisInterface') {
    [PSCustomObject]@{ severity = $Sev; code = $Code; description = $Desc; project = $Project; file = $File; line = $Line; column = $null }
}
# --- the four load-error rows of the real run (verbatim, 實測 2026-11-13)
function LoadRows {
    @(
        (Row 'Error' 'Parts of the XML data do not conform to the schema:' 'FB_B275A.TcPOU' 1)
        (Row 'Error' "Tag 'Declaration' is missing in 'C:\temp\b275\axis\AxisInterface_Type01_Library\AxisInterface\FB_B275B.TcPOU' at line 7." 'FB_B275B.TcPOU' 1)
        (Row 'Error' "Tag 'Implementation' is missing in 'C:\temp\b275\axis\AxisInterface_Type01_Library\AxisInterface\FB_B275B.TcPOU' at line 8." 'FB_B275B.TcPOU' 1)
        (Row 'Error' "Parts of the XML data do not conform to the schema:`n`r`n`rThe `"Id`" attribute in <POU> element has got a wrong format." 'FB_B275C.TcPOU' 1)
    )
}
# Method Id = Property Id in the same FB (same run, branch runtime dfac4f0, 實測 2026-11-13)
function GuidRow {
    Row 'Error' "Object 'FB_B275D.M_Do' has same GUID '0c61e8b1-e947-0437-2da9-2a27db7047fe' as object 'FB_B275D.P_Ro'. The GUID  per object has to be unique ! " 'FB_B275D.TcPOU' 1
}
# real warnings of the same run (the .plcproj warning has no code and a bare file name: a warning, never a load error)
function RealWarnings {
    @(
        (Row 'Warning' 'The option "Minimize Id changes in TwinCAT files" is incompatible with visualization files.' 'AxisInterface.plcproj' 1)
        (Row 'Warning' "Access to VAR_IN_OUT 'AxisRef' declared in 'FB_AdvancedHoming' from external context 'M_KeepPosBias'" 'FB_AdvancedHoming.TcPOU@M_KeepPosBias (Impl)' 18 'C0371')
    )
}
$c0046 = { Row 'Error' "Identifier 'nUndeclared' not defined" 'MAIN.TcPOU (Impl)' 6 'C0046' }
# a leftover row without file and code (Test-TcPlcProject 'stale', 實測 2026-10-31: after a failed archive)
$stale = { Row 'Error' "'TwinCAT Measurement' (22:30:40.881): Error creating Archive" $null $null $null $null }
# TE1200 Static Analysis Light rows: Error severity, build not failed (實測 2026-11-13 PR #276 te1200-light.md:
# SA0033 x191 + SA0167 'tTmp' in F_SaTemp declaration line 3). The file column text of SA rows was not
# recorded there: 'F_SaTemp.TcPOU (Decl)' is 推論 from the compiler rows; the rule keys on the SA code.
$sa0167 = { Row 'Error' "SA0167: Temporary function block instance: 'tTmp'" 'F_SaTemp.TcPOU (Decl)' 3 'SA0167' }
$sa0033 = { Row 'Error' "SA0033: Unused variable 'nUnused'" 'FB_SaUnused.TcPOU (Decl)' 4 'SA0033' }

& $mod {
    param($s)
    $script:TcSolutionPath = $s
    $script:UtErrors = @(); $script:UtWarnings = @(); $script:UtLastBuildInfo = 0
    function script:Assert-TcConnection { }
    function script:Get-TcSysManager { [PSCustomObject]@{ Mock = $true } }
    function script:Find-TcIdeModalDialog { $null }
    function script:Get-TcSolutionPlatform { [PSCustomObject]@{ platform = 'TwinCAT OS (x64)'; configuration = 'Release'; projectPlatform = 'TwinCAT OS (x64)'; platformSource = 'ActiveConfig' } }
    $script:UtCoverage = $null
    $script:UtPlcList = $null
    function script:Get-TcBuildCoverage {
        if ($null -ne $script:UtCoverage) { return @{ configuration = 'Release|TwinCAT OS (x64)'; error = $null; projects = @($script:UtCoverage | ForEach-Object { $_.PSObject.Copy() }) } }
        @{ configuration = 'Release|TwinCAT OS (x64)'; error = $null; projects = @(
            [PSCustomObject]@{ name = 'AxisInterface'; uniqueName = 'Demo275\AxisInterface\AxisInterface.plcproj'; configuration = 'Release'; platform = 'TwinCAT OS (x64)'; shouldBuild = $true; status = 'pending' }
        ) }
    }
    function script:Get-TcPlcProjectList { param($SysManager) if ($null -ne $script:UtPlcList) { return @($script:UtPlcList) }; @([PSCustomObject]@{ name = 'AxisInterface'; nodePath = 'TIPC^AxisInterface'; projectPath = 'TIPC^AxisInterface^AxisInterface Project'; adsPort = 851; disabled = $false; projectFile = $null }) }
    function script:Get-TcPlcLoginState { param($SysManager, $Plc) [PSCustomObject]@{ plc = [string]$Plc.name; loggedIn = $false; source = 'IsLoggedIn'; error = $null } }
    function script:Get-TcBuildErrors {
        [CmdletBinding()]
        param([switch]$IncludeWarnings, [int]$TimeoutSec = 30)
        $e = @($script:UtErrors | ForEach-Object { $_.PSObject.Copy() })
        $w = @($script:UtWarnings | ForEach-Object { $_.PSObject.Copy() })
        New-TcResult -Success $true -Data ([PSCustomObject]@{ counts = [PSCustomObject]@{ errors = $e.Count; warnings = $w.Count; messages = 0 }; errors = $e; warnings = $w })
    }
    $sb = [PSCustomObject]@{ Mock = $true; Polls = 0 }
    $sb | Add-Member -MemberType ScriptMethod -Name Build -Value { param($wait) $this.Polls = 0 }
    $sb | Add-Member -MemberType ScriptProperty -Name BuildState -Value { $this.Polls++; if ($this.Polls -le 1) { 2 } else { 3 } }
    $sb | Add-Member -MemberType ScriptProperty -Name LastBuildInfo -Value { $script:UtLastBuildInfo }
    function script:Invoke-TcComRetry {
        param([int]$MaxRetries, [string]$OperationName, [int]$TimeoutSec, [scriptblock]$ScriptBlock)
        if ($OperationName -eq 'LastBuildInfo' -and $null -eq $script:UtLastBuildInfo) { throw 'unit: LastBuildInfo not readable' }
        & $ScriptBlock
    }
    $script:TcDte = [PSCustomObject]@{ Solution = [PSCustomObject]@{ SolutionBuild = $sb }; ToolWindows = $null }
} $sln

function Set-Scenario($Errors, $Warnings, $LastBuildInfo) {
    & $mod { param($e, $w, $l) $script:UtErrors = @($e); $script:UtWarnings = @($w); $script:UtLastBuildInfo = $l } $Errors $Warnings $LastBuildInfo
}
function Reset-State {
    & $mod { $script:TcBuildRequiredLocal = @{}; $null = Clear-TcBuildRequired; $script:UtCoverage = $null; $script:UtPlcList = $null }
}
# --- 4024 rows (實測 2026-11-13, TcXaeShell.DTE.15.0 XAE 3.1.4026.22 + Remote Manager 4024.71, registered tcauto
# branch 0771b0f, C:\Temp\b275\bfh = copy of Verify-4024-bfh). The 4024 Error List has no Code column:
# a compiler row is code null, File a bare 'MAIN.TcPOU', Line = the line in the .TcPOU FILE (44; line 1 of
# the file is '<?xml ...>'); a load row is code null, File bare, Line 0, and comes twice (project 'PLC1' with
# the text 'Reading file failed. ...' and project null without it).
function Rows4024Compile { @((Row 'Error' "Expression expected instead of ';'" 'MAIN.TcPOU' 44 $null 'PLC1'), (Row 'Error' "'axisRewind' is no component of 'GVL_AXES'" 'FB_R2RLineControl.TcPOU' 130 $null 'PLC1')) }
function Rows4024Load {
    @(
        (Row 'Error' "Reading file failed. Tag 'Declaration' is missing in 'C:\temp\b275\bfh\LangMang260618\PLC1\POUs\FB_B275B.TcPOU' at line 10." 'FB_B275B.TcPOU' 0 $null 'PLC1')
        (Row 'Error' 'Reading file failed. Parts of the XML data do not conform to the schema: ...' 'FB_B275C.TcPOU' 0 $null 'PLC1')
        (Row 'Error' "Tag 'Declaration' is missing in 'C:\temp\b275\bfh\LangMang260618\PLC1\POUs\FB_B275B.TcPOU' at line 10." 'FB_B275B.TcPOU' 0 $null $null)
        (Row 'Error' 'Parts of the XML data do not conform to the schema: ...' 'FB_B275C.TcPOU' 0 $null $null)
    )
}
function Get-BuildRequiredReason { & $mod { $e = Get-TcBuildRequired; if ($null -eq $e) { return $null }; [string]$e.reason } }
function Has([object]$d, [string]$name) { $null -ne $d.PSObject.Properties[$name] }

try {
    # ===== row classification (Test-TcProjectLoadErrorItem / Test-TcStaticAnalysisItem)
    $cls = @(
        @{ Name = 'root element renamed (bare .TcPOU, no code)'; Item = (LoadRows)[0]; Load = $true }
        @{ Name = 'Tag Declaration missing'; Item = (LoadRows)[1]; Load = $true }
        @{ Name = 'Id wrong format'; Item = (LoadRows)[3]; Load = $true }
        @{ Name = 'sub-object GUID duplicate'; Item = (GuidRow); Load = $true }
        @{ Name = '4024 load row (line 0, project PLC1)'; Item = (Rows4024Load)[0]; Load = $true }
        @{ Name = '4024 load row (line 0, project null)'; Item = (Rows4024Load)[2]; Load = $true }
        @{ Name = '4024 compiler row: bare MAIN.TcPOU, code null, line 44 is no load row (review S1)'; Item = (Rows4024Compile)[0]; Load = $false }
        @{ Name = '4024 compiler row of CheckAllObjects (line 130) is no load row'; Item = (Rows4024Compile)[1]; Load = $false }
        @{ Name = 'bare file, line 2 is no load row (line 1 of a .TcPOU is <?xml>)'; Item = (Row 'Error' 'x' 'FB_A.TcPOU' 2); Load = $false }
        @{ Name = 'bare .TcGVL file, no code (inferred kind)'; Item = (Row 'Error' 'Parts of the XML data do not conform to the schema:' 'GVL_Main.TcGVL' 1); Load = $true }
        @{ Name = 'task row on 4024 whose code was not inferred (PlcTask.TcTTO, line 0) is no load row (review F2)'; Item = (Row 'Error' "Identifier 'MainX' not defined" 'PlcTask.TcTTO' 0); Load = $false }
        @{ Name = 'bare .plcproj / .tsproj error is no load row (not measured)'; Item = (Row 'Error' 'x' 'AxisInterface.plcproj' 1); Load = $false }
        @{ Name = 'category library is no load row (review F6)'; Item = ([PSCustomObject]@{ severity = 'Error'; code = $null; description = "Could not open library 'x'"; project = 'plc'; file = 'FB_A.TcPOU'; line = $null; column = $null; category = 'library' }); Load = $false }
        @{ Name = 'line null still a load row'; Item = (Row 'Error' 'x' 'I_Itf.TcIO' $null); Load = $true }
        @{ Name = 'compiler row (C0046, (Impl))'; Item = (& $c0046); Load = $false }
        @{ Name = 'compiler row whose code was not parsed ((Impl) suffix) is no load row'; Item = (Row 'Error' 'x' 'MAIN.TcPOU (Impl)' 4); Load = $false }
        @{ Name = 'sub-object row (@) is no load row'; Item = (Row 'Error' 'x' 'FB_A.TcPOU@M_Do' 1); Load = $false }
        @{ Name = 'task row with a code'; Item = (Row 'Error' "Identifier 'MainX' not defined" 'PlcTask.TcTTO' 0 'C0046'); Load = $false }
        @{ Name = 'stale row (no file, no code)'; Item = (& $stale); Load = $false }
        @{ Name = 'Library Manager row'; Item = (Row 'Error' "Library 'Tc3_Foo' 1.0.0.0 has not been installed" 'plc.Library Manager' 0); Load = $false }
        @{ Name = 'warning with a bare .plcproj file'; Item = (RealWarnings)[0]; Load = $false }
        @{ Name = 'SA row'; Item = (& $sa0167); Load = $false }
        @{ Name = 'null'; Item = $null; Load = $false }
    )
    foreach ($c in $cls) {
        $got = & $mod { param($i) Test-TcProjectLoadErrorItem -Item $i } $c.Item
        Check "load row: $($c.Name)" ($got -eq $c.Load) "want $($c.Load), got $got"
    }
    $saCases = @(
        @{ Name = 'SA0167'; Item = (& $sa0167); Want = $true }
        @{ Name = 'SA0033'; Item = (& $sa0033); Want = $true }
        @{ Name = 'C0046'; Item = (& $c0046); Want = $false }
        @{ Name = 'load row'; Item = (LoadRows)[0]; Want = $false }
    )
    foreach ($c in $saCases) {
        $got = & $mod { param($i) Test-TcStaticAnalysisItem -Item $i } $c.Item
        Check "SA row: $($c.Name)" ($got -eq $c.Want) "want $($c.Want), got $got"
    }

    # ===== (1) the #275 shape: load rows, LastBuildInfo 0, pane 0 errors -> PROJECT_LOAD_ERRORS, not success
    Reset-State
    Set-Scenario (LoadRows) (RealWarnings) 0
    $r = Build-TcProject -WarningAction SilentlyContinue
    $d = $r.data
    Check '(1) success false, code PROJECT_LOAD_ERRORS' ((-not $r.success) -and $r.error.code -eq 'PROJECT_LOAD_ERRORS') (J $r.error)
    Check '(1) buildSucceeded stays true (the build itself), codeVerified false, completeBuild false' ($d.buildSucceeded -eq $true -and $d.codeVerified -eq $false -and $d.completeBuild -eq $false) (J $d)
    Check '(1) loadErrorItems = the 4 rows, errorItems keeps them, errors 4' (@($d.loadErrorItems).Count -eq 4 -and @($d.errorItems).Count -eq 4 -and $d.errors -eq 4) (J $d.loadErrorItems)
    Check '(1) loadErrorFiles = the 3 files' ((@($d.loadErrorFiles) -join ',') -eq 'FB_B275A.TcPOU,FB_B275B.TcPOU,FB_B275C.TcPOU') (J $d.loadErrorFiles)
    Check '(1) message names the files and a row' ($r.error.message -match 'FB_B275A\.TcPOU' -and $r.error.message -match 'FB_B275C\.TcPOU' -and $r.error.message -match 'XML data do not conform') $r.error.message
    Check '(1) hint: restore / fix the files, ResetSolution, build again (cmdlet names)' ($r.error.hint -match 'Reset-TcSolution' -and $r.error.hint -match 'Build-TcProject') $r.error.hint
    Check '(1) BUILD_REQUIRED recorded (not a complete build)' ($null -ne $d.buildRequired -and $null -ne (Get-BuildRequiredReason)) (J $d)
    Check '(1) staticAnalysisItems present and empty' ((Has $d 'staticAnalysisItems') -and @($d.staticAnalysisItems).Count -eq 0) (J $d)

    # ===== (1b) the same rows with LastBuildInfo unreadable (decided by the Error List): still PROJECT_LOAD_ERRORS, not BUILD_FAILED
    Reset-State
    Set-Scenario (LoadRows) @() $null
    $r = Build-TcProject -WarningAction SilentlyContinue
    Check '(1b) ErrorList-decided: PROJECT_LOAD_ERRORS, buildSucceeded true' ((-not $r.success) -and $r.error.code -eq 'PROJECT_LOAD_ERRORS' -and $r.data.buildSucceeded -eq $true -and $r.data.decidedBy -eq 'ErrorList') (J $r)

    # ===== (2) load rows + a real compiler error, LastBuildInfo 1 -> BUILD_FAILED stays, load rows listed
    Reset-State
    Set-Scenario (@(LoadRows) + (& $c0046)) @() 1
    $r = Build-TcProject -WarningAction SilentlyContinue
    Check '(2) BUILD_FAILED wins, loadErrorItems 4' ((-not $r.success) -and $r.error.code -eq 'BUILD_FAILED' -and @($r.data.loadErrorItems).Count -eq 4) (J $r.error)

    # ===== (3) a stale row only (no file, no code), LastBuildInfo 0 -> success, unchanged
    Reset-State
    Set-Scenario @(& $stale) (RealWarnings) 0
    $r = Build-TcProject -WarningAction SilentlyContinue
    Check '(3) stale row -> success, completeBuild true, loadErrorItems empty' ($r.success -and $r.data.completeBuild -eq $true -and $r.data.codeVerified -eq $true -and @($r.data.loadErrorItems).Count -eq 0) (J $r)

    # ===== (4) TE1200 SA rows (Error, build not failed) -> success unchanged, warningCode STATIC_ANALYSIS_ERRORS
    Reset-State
    Set-Scenario @((& $sa0167), (& $sa0033)) (RealWarnings) 0
    $r = Build-TcProject -WarningAction SilentlyContinue
    $d = $r.data
    Check '(4) SA rows -> success, completeBuild / codeVerified true (behaviour unchanged, owner decides)' ($r.success -and $d.completeBuild -eq $true -and $d.codeVerified -eq $true) (J $r)
    Check '(4) warningCodes has STATIC_ANALYSIS_ERRORS, staticAnalysisItems 2' (@($d.warningCodes) -contains 'STATIC_ANALYSIS_ERRORS' -and @($d.staticAnalysisItems).Count -eq 2) (J $d)
    Check '(4) BUILD_REQUIRED cleared (complete build)' ($null -eq (Get-BuildRequiredReason)) (Get-BuildRequiredReason)

    # ===== (5) normal build with warnings only -> success, no new fields set, no warning code
    Reset-State
    Set-Scenario @() (RealWarnings) 0
    $r = Build-TcProject -WarningAction SilentlyContinue
    $d = $r.data
    Check '(5) clean -> success, completeBuild true, no warningCodes' ($r.success -and $d.completeBuild -eq $true -and -not (Has $d 'warningCodes')) (J $d)
    Check '(5) loadErrorItems / staticAnalysisItems present and empty' ((Has $d 'loadErrorItems') -and @($d.loadErrorItems).Count -eq 0 -and (Has $d 'staticAnalysisItems') -and @($d.staticAnalysisItems).Count -eq 0) (J $d)

    # ===== (6) review S1, 4024: a real compiler error (bare file, code null, line 44)
    Reset-State
    Set-Scenario @((Rows4024Compile)[0]) @() 2
    $r = Build-TcProject -WarningAction SilentlyContinue
    Check '(6) 4024 compile error -> BUILD_FAILED, loadErrorItems empty' ((-not $r.success) -and $r.error.code -eq 'BUILD_FAILED' -and @($r.data.loadErrorItems).Count -eq 0) (J $r.data.loadErrorItems)
    Reset-State
    Set-Scenario @((Rows4024Compile)[0]) @() $null
    $r = Build-TcProject -WarningAction SilentlyContinue
    Check '(6b) 4024 compile error, LastBuildInfo unreadable -> BUILD_FAILED by ErrorList (not PROJECT_LOAD_ERRORS)' ((-not $r.success) -and $r.error.code -eq 'BUILD_FAILED' -and $r.data.decidedBy -eq 'ErrorList') (J $r.error)

    # ===== (7) 4024 load rows (line 0, doubled) -> PROJECT_LOAD_ERRORS, no extra CODE_NOT_VERIFIED
    Reset-State
    Set-Scenario (Rows4024Load) @() 0
    $r = Build-TcProject -WarningAction SilentlyContinue
    Check '(7) 4024 load rows -> PROJECT_LOAD_ERRORS, 2 files' ((-not $r.success) -and $r.error.code -eq 'PROJECT_LOAD_ERRORS' -and @($r.data.loadErrorFiles).Count -eq 2) (J $r.data.loadErrorFiles)
    Check '(7) line-0 load rows do not add CODE_NOT_VERIFIED' (@($r.data.warningCodes) -notcontains 'CODE_NOT_VERIFIED') (J $r.data.warningCodes)

    # ===== (8) review S5: load rows of a DISABLED PLC (#104) only warn; an enabled PLC still blocks
    Reset-State
    & $mod {
        $script:UtCoverage = @(
            [PSCustomObject]@{ name = 'PLC1'; uniqueName = 'D\PLC1\PLC1.plcproj'; configuration = 'Release'; platform = 'TwinCAT OS (x64)'; shouldBuild = $true; status = 'pending' }
            [PSCustomObject]@{ name = 'PLC2'; uniqueName = 'D\PLC2\PLC2.plcproj'; configuration = 'Release'; platform = 'TwinCAT OS (x64)'; shouldBuild = $false; status = 'skipped' }
        )
        $script:UtPlcList = @(
            [PSCustomObject]@{ name = 'PLC1'; nodePath = 'TIPC^PLC1'; projectPath = 'TIPC^PLC1^PLC1 Project'; adsPort = 851; disabled = $false; projectFile = $null }
            [PSCustomObject]@{ name = 'PLC2'; nodePath = 'TIPC^PLC2'; projectPath = 'TIPC^PLC2^PLC2 Project'; adsPort = 852; disabled = $true; projectFile = $null }
        )
    }
    $dis = @(
        (Row 'Error' 'Reading file failed. Parts of the XML data do not conform to the schema: ...' 'FB_Old.TcPOU' 0 $null 'PLC2')
        (Row 'Error' 'Parts of the XML data do not conform to the schema: ...' 'FB_Old.TcPOU' 0 $null $null)
    )
    Set-Scenario $dis @() 0
    $r = Build-TcProject -WarningAction SilentlyContinue
    $d = $r.data
    Check '(8) disabled PLC load rows -> success, completeBuild true' ($r.success -and $d.completeBuild -eq $true -and $d.codeVerified -eq $true) (J $r)
    Check '(8) rows in disabledLoadErrorItems (the null-project twin too), loadErrorItems empty, warningCode PROJECT_LOAD_ERRORS' (@($d.disabledLoadErrorItems).Count -eq 2 -and @($d.loadErrorItems).Count -eq 0 -and @($d.warningCodes) -contains 'PROJECT_LOAD_ERRORS') (J $d)
    Set-Scenario (@($dis) + (Row 'Error' 'Parts of the XML data do not conform to the schema:' 'FB_New.TcPOU' 1 $null 'PLC1')) @() 0
    $r = Build-TcProject -WarningAction SilentlyContinue
    Check '(8b) + a load row of the enabled PLC -> PROJECT_LOAD_ERRORS for FB_New only' ((-not $r.success) -and $r.error.code -eq 'PROJECT_LOAD_ERRORS' -and (@($r.data.loadErrorFiles) -join ',') -eq 'FB_New.TcPOU' -and @($r.data.disabledLoadErrorItems).Count -eq 2) (J $r.data)

    # ===== (9) review N2: BUILD_FAILED with load rows -> the hint names them
    Reset-State
    Set-Scenario (@(LoadRows) + (& $c0046)) @() 1
    $r = Build-TcProject -WarningAction SilentlyContinue
    Check '(9) BUILD_FAILED + load rows -> hint mentions PROJECT_LOAD_ERRORS / loadErrorFiles' ($r.error.code -eq 'BUILD_FAILED' -and $r.error.hint -match 'PROJECT_LOAD_ERRORS' -and $r.error.hint -match 'loadErrorFiles') $r.error.hint

    # ===== hint table
    $h = & $mod { @{ l = (Get-TcErrorHint -Code 'PROJECT_LOAD_ERRORS'); s = (Get-TcErrorHint -Code 'STATIC_ANALYSIS_ERRORS') } }
    Check 'hints exist for PROJECT_LOAD_ERRORS / STATIC_ANALYSIS_ERRORS' (-not [string]::IsNullOrWhiteSpace($h.l) -and -not [string]::IsNullOrWhiteSpace($h.s)) (J $h)
}
catch {
    Check 'unexpected-exception' $false "$($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber)"
}
"failed: $fail"
exit [Math]::Min($fail, 255)
