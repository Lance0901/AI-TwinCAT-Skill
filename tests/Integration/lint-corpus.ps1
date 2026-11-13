<#
.SYNOPSIS
    Local corpus regression of the semantic linter (#252 Phase 1a): runs Invoke-TcLintProject on the
    two corpus projects and compares with the expected findings. Read-only. Not in CI (the corpus
    is not in the repository: owner has not decided whether customer files may be published).
.DESCRIPTION
    Corpus (research/tc-xml-schema-observed.md section 0):
      axis  <CorpusRoot>\axis\AxisInterface_Type01_Library\AxisInterface\AxisInterface.plcproj  (4026)
      bfh   <CorpusRoot>\bfh\LangMang260618\PLC1\PLC1.plcproj                                   (4024)
    Checks:
      1. parsing 100 %: no LINT-PARSE-* finding; the only notAnalyzed section is the CFC action
         FB_AxisControl.A90_Cyclic; every Declaration / ST section of the corpus is parsed by the
         engine (status ok, except conditional pragma / unverified syntax, listed);
      2. expected findings (tasks 1a acceptance + manual judgement in PR #274):
         axis: PROJECT-ENC-001 on exactly 11 files, PROJECT-GUID-005 on the hand-written Ids;
         bfh: only PROJECT-LINEIDS-001 on FB_Winder (LineIds 147 lines, code 148: changed outside XAE);
         Phase 1b: axis PROJECT-TASK-001 TestCam; Phase 2a: SAFETY-DIV-001 info axis 47 / bfh 1 (PR #284);
         Phase 2b / 3a: the judged axis list of PR #289 / #304 (bfh none);
         no other PROJECT-* finding, verdict pass for both;
      3. deterministic: two runs byte-identical; en-US and zh-TW processes byte-identical;
      4. performance: analyse time per project (budget <= 2 s, design.md D7).
    Exit code = number of failed checks.
.PARAMETER CorpusRoot
    Folder with axis\ and bfh\ (default C:\Temp\lint-corpus).
.EXAMPLE
    powershell.exe -NoProfile -File tests/Integration/lint-corpus.ps1
#>
[CmdletBinding()]
param(
    [string]$CorpusRoot = 'C:\Temp\lint-corpus'
)
$ErrorActionPreference = 'Stop'
$ownStateDir = $null   # second review N6: only the state directory this script created is removed at the end
if ([string]::IsNullOrEmpty($env:TCAUTO_STATE_DIR)) {
    $env:TCAUTO_STATE_DIR = Join-Path $env:TEMP ('tcauto-lint-corpus-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $env:TCAUTO_STATE_DIR | Out-Null
    $ownStateDir = $env:TCAUTO_STATE_DIR
}
function Exit-Script([int]$Code) {
    if ($script:ownStateDir) { Remove-Item -LiteralPath $script:ownStateDir -Recurse -Force -ErrorAction SilentlyContinue }
    exit $Code
}
$modulePath = (Resolve-Path (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1')).ProviderPath
Import-Module $modulePath -Force -WarningAction SilentlyContinue
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 800) { $Detail = $Detail.Substring(0, 800) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}
$projects = [ordered]@{
    axis = Join-Path $CorpusRoot 'axis\AxisInterface_Type01_Library\AxisInterface\AxisInterface.plcproj'
    bfh  = Join-Path $CorpusRoot 'bfh\LangMang260618\PLC1\PLC1.plcproj'
}
foreach ($k in $projects.Keys) { if (-not (Test-Path -LiteralPath $projects[$k])) { "SKIP corpus $k not found: $($projects[$k])"; Exit-Script 1 } }

# expected findings: file (relative to the .plcproj directory) per rule
$expectedEnc = @('AxisInterface/DUT/Axis_Control/E_SyncProfileEngageMode.TcDUT', 'AxisInterface/DUT/Axis_Control/ST_AXIS_ADMINISTRATION.TcDUT',
    'AxisInterface/DUT/Axis_Status/E_AxisFaultCategory.TcDUT', 'AxisInterface/DUT/Axis_Status/E_AxisFaultSrc.TcDUT',
    'AxisInterface/DUT/Axis_Status/ST_AXIS_DIAGNOSIS.TcDUT', 'AxisInterface/GVL/GVL_Motion.TcGVL', 'AxisInterface/LIB/AxisControl/FB_AxisControl.TcPOU',
    'CorrugatedPrint/FB_ExtendCrossCutter.TcPOU', 'CorrugatedPrint/Feeder/FB_CorrugatedLiftingFixedAccDistance.TcPOU',
    'CorrugatedPrint/Feeder/FB_CorrugatedWheelThreadSlopeCalculate.TcPOU', 'TestCam.TcPOU')
# the 6 hand-written Ids of research/tc-xml-schema-observed.md section 4 + 6 more found by the linter
# (judged in PR #274: sequential / repeated-digit Ids in files that were written outside XAE)
$expectedGuid5 = @('{a1b2c3d4-e5f6-7890-abcd-ef0123456789}', '{c3b2a1d4-1234-4567-8901-aaabbbcccddd}', '{a3f1e2b4-5678-4abc-9def-123456789abc}',
    '{c1a2b3d4-1111-2222-3333-ddddeeeeffff}', '{c1a2b3d4-1111-2222-3333-aaaabbbbcccc}', '{91111111-91a9-91e9-9191-91efabc91111}',
    '{a10ca501-0000-4eca-9a10-000000000001}', '{a10ca501-0000-4eca-9a10-000000000002}',
    '{a1b2c3d4-1111-4111-8111-111111111111}', '{a1b2c3d4-2222-4222-8222-222222222222}', '{a1b2c3d4-3333-4333-8333-333333333333}', '{a1b2c3d4-4444-4444-8444-444444444444}')

$results = @{}
foreach ($k in $projects.Keys) {
    $r = Invoke-TcLintProject -PlcProjectPath $projects[$k] -IncludeTiming
    $null = Invoke-TcLintProject -PlcProjectPath $projects[$k]   # warm
    $r2 = Invoke-TcLintProject -PlcProjectPath $projects[$k] -IncludeTiming
    $results[$k] = $r
    $diags = @($r.data.diagnostics)
    "---- $k : verdict=$($r.data.verdict) objects=$($r.data.coverage.objectsInScope) analysed=$($r.data.coverage.objectsAnalyzed) diagnostics=$($diags.Count) firstRunMs=$($r.data.timing.totalMs) (compile $($r.data.timing.engineLoadMs)) warmAnalyzeMs=$($r2.data.timing.analyzeMs)"
    foreach ($d in $diags) { "     $($d.ruleId) [$($d.severity)$(if ($d.blocking) { ',blocking' })] $($d.file) $($d.objectPath):$($d.line) $($d.message) $($d.evidence)" }
    Check "$k verdict pass" ($r.success -and $r.data.verdict -eq 'pass') "$($r.error.code)"
    Check "$k no LINT-PARSE finding" (@($diags | Where-Object { $_.ruleId -like 'LINT-PARSE-*' }).Count -eq 0) ''
    $na = @($r.data.coverage.notAnalyzed)
    $naWant = if ($k -eq 'axis') { 'FB_AxisControl.A90_Cyclic|language:CFC' } else { '' }
    Check "$k notAnalyzed is only the CFC action" ((($na | ForEach-Object { "$($_.objectPath)|$($_.reason)" }) -join ',') -eq $naWant) (($na | ForEach-Object { "$($_.objectPath)|$($_.reason)" }) -join ',')
    Check "$k no blockingRulesSkipped / rulesNotRun" (@($r.data.coverage.blockingRulesSkipped).Count -eq 0 -and @($r.data.coverage.rulesNotRun).Count -eq 0) ''
    Check "$k performance: warm analyse <= 2000 ms" ($r2.data.timing.analyzeMs -le 2000) "$($r2.data.timing.analyzeMs) ms"
    if ($k -eq 'axis') {
        $enc = @($diags | Where-Object { $_.ruleId -eq 'PROJECT-ENC-001' } | ForEach-Object { $_.file } | Sort-Object)
        Check 'axis PROJECT-ENC-001 = the 11 files written outside XAE' (($enc -join ',') -eq (($expectedEnc | Sort-Object) -join ',')) ($enc -join ',')
        $g5 = @($diags | Where-Object { $_.ruleId -eq 'PROJECT-GUID-005' } | ForEach-Object { $_.evidence } | Sort-Object)
        Check 'axis PROJECT-GUID-005 = the hand-written Ids (6 listed in research + 6 more)' (($g5 -join ',') -eq (($expectedGuid5 | Sort-Object) -join ',')) ($g5 -join ',')
        # Phase 1b: TestCam PROJECT-TASK-001 (kept PoC program, PR #283); Phase 2a: SAFETY-DIV-001 unchecked-variable-divisor
        # info x 47, judged one by one in PR #284 (1 real candidate, 10 input-dependent, 34 configuration-derived, 2 false);
        # 46 -> 47 in the second review (S5): a test in the same expression only counts before AND_THEN / OR_ELSE / in SEL,
        # so FB_CorrugatedLiftingFixedAccDistance.StartAction 'SyncPrintDistance_deg / SyncPrintDistance_deg' (the dividend
        # was taken as a test of the divisor) is now reported: 0 when the input SyncPrintDistance is 0
        $t1 = @($diags | Where-Object { $_.ruleId -eq 'PROJECT-TASK-001' } | ForEach-Object { $_.objectPath })
        Check 'axis PROJECT-TASK-001 only TestCam (Phase 1b)' (($t1 -join ',') -eq 'TestCam') ($t1 -join ',')
        $div = @($diags | Where-Object { $_.ruleId -eq 'SAFETY-DIV-001' })
        Check 'axis SAFETY-DIV-001: 47 unchecked-variable-divisor infos, none blocking (Phase 2a)' ($div.Count -eq 47 -and @($div | Where-Object { $_.variant -ne 'unchecked-variable-divisor' -or $_.severity -ne 'info' -or $_.blocking }).Count -eq 0) "$($div.Count)"
        # Phase 2b (PR #289, judged there): 3 unused FB instances, TestCam.R_14Eng only in IF. Phase 3a (PR #304, judged one by one):
        # SCAN-SM-001 x 6 (FB_AdvancedHoming 10100 = done state without label; A02 error steps 9305 / 9325 / 9335 without handler;
        # A03 900 / A04 20000 abort states only left by a mode change), SCAN-FLOAT-001 x 1 (lrAxisEncoderReferenceSys = 2: an
        # NC parameter code in an LREAL, exact in practice - accepted false positive, needs a suppression); no REF / FBVAL / INTDIV
        $later = @($diags | Where-Object { $_.ruleId -like 'SCAN-FBCALL-*' -or $_.ruleId -like 'SCAN-TIMER-*' -or @('SCAN-SM-001', 'SCAN-FLOAT-001', 'SCAN-REF-001', 'SCAN-FBVAL-001', 'SCAN-INTDIV-001') -contains $_.ruleId } |
            ForEach-Object { "$($_.ruleId)|$($_.objectPath)|$($_.line)" } | Sort-Object)
        $expectedLater = @('SCAN-FBCALL-002|FB_AxisControl|59', 'SCAN-FBCALL-002|FB_AxisControl|165', 'SCAN-FBCALL-002|MC_MoveAbsolute_Continue|30', 'SCAN-TIMER-001|TestCam|711',
            'SCAN-SM-001|FB_AdvancedHoming|197', 'SCAN-SM-001|FB_AxisControl.A02_ModeAdvHoming|191', 'SCAN-SM-001|FB_AxisControl.A02_ModeAdvHoming|238', 'SCAN-SM-001|FB_AxisControl.A02_ModeAdvHoming|248',
            'SCAN-SM-001|FB_AxisControl.A03_ModePosAbs|102', 'SCAN-SM-001|FB_AxisControl.A04_ModePosRel|61', 'SCAN-FLOAT-001|FB_AxisControl.A02_ModeAdvHoming|201') | Sort-Object
        Check 'axis Phase 2b / 3a findings = the judged list (PR #289 / #304)' (($later -join ',') -eq ($expectedLater -join ',')) ($later -join ',')
        $other = @($diags | Where-Object { @('PROJECT-ENC-001', 'PROJECT-GUID-005', 'PROJECT-TASK-001', 'SAFETY-DIV-001') -notcontains $_.ruleId -and $_.ruleId -notlike 'SCAN-FBCALL-*' -and $_.ruleId -notlike 'SCAN-TIMER-*' -and @('SCAN-SM-001', 'SCAN-FLOAT-001', 'SCAN-REF-001', 'SCAN-FBVAL-001', 'SCAN-INTDIV-001') -notcontains $_.ruleId })
        Check 'axis no other finding' ($other.Count -eq 0) (($other | ForEach-Object { "$($_.ruleId) $($_.objectPath) $($_.message)" }) -join ' | ')
    }
    else {
        $ok = $diags.Count -eq 2 -and @($diags | Where-Object { $_.ruleId -eq 'PROJECT-LINEIDS-001' -and $_.objectPath -eq 'FB_Winder' }).Count -eq 1 -and
            @($diags | Where-Object { $_.ruleId -eq 'SAFETY-DIV-001' -and $_.objectPath -eq 'FB_NipAxleControl' -and $_.severity -eq 'info' -and -not $_.blocking }).Count -eq 1
        Check 'bfh only PROJECT-LINEIDS-001 on FB_Winder and the SAFETY-DIV-001 info on FB_NipAxleControl (Phase 2a)' $ok (($diags | ForEach-Object { "$($_.ruleId) $($_.objectPath) $($_.message)" }) -join ' | ')
    }
    $a = Invoke-TcLintProject -PlcProjectPath $projects[$k] | ConvertTo-Json -Depth 30 -Compress
    $b = Invoke-TcLintProject -PlcProjectPath $projects[$k] | ConvertTo-Json -Depth 30 -Compress
    Check "$k two runs byte-identical" ($a -ceq $b) ''
}

# every Declaration / ST of the corpus through the parser directly (statistics for the PR)
$A = & (Get-Module TwinCATAutomation) { Get-TcLintEngineType -Name 'StAnalyzer' }
$stat = [ordered]@{ declOk = 0; declNotAnalyzed = 0; declFailed = 0; implOk = 0; implNotAnalyzed = 0; implFailed = 0; vars = 0; calls = 0 }
$notes = [System.Collections.Generic.List[string]]::new()
foreach ($k in $projects.Keys) {
    $dir = Split-Path $projects[$k]
    foreach ($f in Get-ChildItem -LiteralPath $dir -Recurse -Include *.TcPOU, *.TcDUT, *.TcGVL -File) {
        $xml = New-Object System.Xml.XmlDocument
        $xml.XmlResolver = $null
        $xml.Load($f.FullName)
        foreach ($n in $xml.SelectNodes('//Declaration')) {
            $d = $A::DescribeDeclaration($n.InnerText)
            switch ($d['status']) { 'ok' { $stat.declOk++ } 'not-analyzed' { $stat.declNotAnalyzed++; $notes.Add("decl $($f.Name): $($d['reason'])") } default { $stat.declFailed++; $notes.Add("DECL FAIL $($f.Name): $($d['error'])") } }
            foreach ($b in @($d['varBlocks'])) { $stat.vars += @($b['vars']).Count }
            if ($null -ne $d['type']) { $stat.vars += @($d['type']['members']).Count + @($d['type']['enumMembers']).Count }
        }
        foreach ($n in $xml.SelectNodes('//ST')) {
            $s = $A::DescribeImplementation($n.InnerText)
            switch ($s['status']) { 'ok' { $stat.implOk++ } 'not-analyzed' { $stat.implNotAnalyzed++; $notes.Add("impl $($f.Name): $($s['reason'])") } default { $stat.implFailed++; $notes.Add("IMPL FAIL $($f.Name): $($s['error'])") } }
            $stat.calls += @($s['calls']).Count
        }
    }
}
"---- parser statistics: $($stat | ConvertTo-Json -Compress)"
foreach ($x in $notes) { "     $x" }
Check 'every corpus Declaration / ST parsed (no parse failure)' ($stat.declFailed -eq 0 -and $stat.implFailed -eq 0) ($stat | ConvertTo-Json -Compress)

# en-US vs zh-TW (separate processes)
$helper = Join-Path $env:TCAUTO_STATE_DIR 'corpus-culture.ps1'
@'
param([string]$Module, [string]$Plcproj, [string]$Culture)
[System.Threading.Thread]::CurrentThread.CurrentCulture = $Culture
[System.Threading.Thread]::CurrentThread.CurrentUICulture = $Culture
Import-Module $Module -Force -WarningAction SilentlyContinue
$j = Invoke-TcLintProject -PlcProjectPath $Plcproj | ConvertTo-Json -Depth 30 -Compress
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($j))
'@ | Set-Content -LiteralPath $helper -Encoding ASCII
foreach ($k in $projects.Keys) {
    $en = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $helper -Module $modulePath -Plcproj $projects[$k] -Culture 'en-US') -join ''
    $zh = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $helper -Module $modulePath -Plcproj $projects[$k] -Culture 'zh-TW') -join ''
    Check "$k en-US and zh-TW byte-identical" ($en.Length -gt 100 -and $en -ceq $zh) "en $($en.Length) zh $($zh.Length)"
}
"failed: $fail"
Exit-Script $fail
