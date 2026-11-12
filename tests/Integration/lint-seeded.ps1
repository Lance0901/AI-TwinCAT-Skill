<#
.SYNOPSIS
    Seeded-bug run of the semantic linter (#252 Phase 1a) on COPIES of the 4024 corpus project:
    one break per PROJECT-* / LINT-PARSE rule, each must be found, with no other new finding.
.DESCRIPTION
    Copies <CorpusRoot>\bfh to a temp folder per case (the corpus itself is only read), applies one
    mutation of the kind an AI editing files on disk produces, runs Invoke-TcLintProject and compares
    with the pristine copy: the NEW findings (rule id + file + object + message not present before)
    must be exactly the expected rule ids, and the error code must match. Not in CI (corpus not in
    the repository). Exit code = number of failed cases.
.PARAMETER CorpusRoot
    Folder with bfh\ (default C:\Temp\lint-corpus).
.EXAMPLE
    powershell.exe -NoProfile -File tests/Integration/lint-seeded.ps1
#>
[CmdletBinding()]
param([string]$CorpusRoot = 'C:\Temp\lint-corpus')
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrEmpty($env:TCAUTO_STATE_DIR)) {
    $env:TCAUTO_STATE_DIR = Join-Path $env:TEMP ('tcauto-lint-seeded-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $env:TCAUTO_STATE_DIR | Out-Null
}
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
. (Join-Path $PSScriptRoot '..\Unit\lib\LintFixture.ps1')   # Edit-LintFxFile / Write-LintFxFile
$src = Join-Path $CorpusRoot 'bfh'
if (-not (Test-Path -LiteralPath $src)) { "SKIP corpus not found: $src"; exit 1 }
$work = Join-Path $env:TEMP ('tcauto-lint-seeded-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work | Out-Null
$fail = 0
$rows = [System.Collections.Generic.List[object]]::new()

function Key($d) { return "$($d.ruleId)|$($d.file)|$($d.objectPath)|$($d.message)" }
function New-Copy([string]$Name) {
    $dst = Join-Path $work $Name
    Copy-Item -LiteralPath $src -Destination $dst -Recurse
    $plc = Join-Path $dst 'LangMang260618\PLC1'
    return @{ Root = $dst; Plc = $plc; Plcproj = (Join-Path $plc 'PLC1.plcproj'); Tsproj = (Join-Path $dst 'LangMang260618\BFH_1650.tsproj')
        Main = (Join-Path $plc 'POUs\MAIN.TcPOU'); Ctrl = (Join-Path $plc '00_Machine\FB_MachineCtrl.TcPOU'); Dut = (Join-Path $plc '00_Machine\01_DUTs\E_MachineMode.TcDUT')
        Gvl = (Join-Path $plc 'GVL_Smoke4024.TcGVL'); Task = (Join-Path $plc 'PlcTask.TcTTO') }
}
function First([string]$Text, [string]$Pattern, [string]$Replacement) {
    $rx = New-Object System.Text.RegularExpressions.Regex($Pattern, 'Singleline')
    if (-not $rx.IsMatch($Text)) { throw "pattern not found: $Pattern" }
    return $rx.Replace($Text, $Replacement, 1)
}

$pristine = New-Copy 'pristine'
$base = Invoke-TcLintProject -PlcProjectPath $pristine.Plcproj
$baseKeys = @{}; foreach ($d in @($base.data.diagnostics)) { $baseKeys[(Key $d)] = $true }
"pristine: verdict=$($base.data.verdict) findings=$(@($base.data.diagnostics).Count)"

$cases = @(
    @{ n = 'XML-001 closing tag removed'; want = 'PROJECT-XML-001'; code = 'LINT_FAILED'; m = { param($c) Edit-LintFxFile $c.Ctrl { param($t) First $t '</Method>' '' } } },
    @{ n = 'XML-002 invalid UTF-8 byte'; want = 'PROJECT-XML-002'; code = 'LINT_FAILED'; m = { param($c) $b = [IO.File]::ReadAllBytes($c.Dut); $i = [Text.Encoding]::ASCII.GetString($b).IndexOf('TYPE'); $b[$i] = 0xFF; [IO.File]::WriteAllBytes($c.Dut, $b) } },
    @{ n = 'XML-003 code outside CDATA'; want = 'PROJECT-XML-003'; code = 'LINT_FAILED'; m = { param($c) Edit-LintFxFile $c.Main { param($t) First $t '<ST><!\[CDATA\[' '<ST>x := 1;<![CDATA[' } } },
    @{ n = 'XML-003 CDATA split by ]]>'; want = 'PROJECT-XML-003'; code = 'LINT_FAILED'; m = { param($c) Edit-LintFxFile $c.Main { param($t) First $t '(<ST><!\[CDATA\[)' '$1// a ]]]]><![CDATA[> b' + "`r`n" } } },
    @{ n = 'XML-004 SpecialFunc removed'; want = 'PROJECT-XML-004'; code = 'LINT_FAILED'; m = { param($c) Edit-LintFxFile $c.Main { param($t) First $t ' SpecialFunc="None"' '' } } },
    @{ n = 'KIND-001 DUT element in a .TcDUT replaced by GVL'; want = 'PROJECT-KIND-001'; code = 'LINT_FAILED'; m = { param($c) Edit-LintFxFile $c.Dut { param($t) $t.Replace('<DUT ', '<GVL ').Replace('</DUT>', '</GVL>') } } },
    @{ n = 'NAME-001 declared name changed'; want = 'PROJECT-NAME-001'; code = 'LINT_FAILED'; m = { param($c) Edit-LintFxFile $c.Main { param($t) First $t 'PROGRAM MAIN' 'PROGRAM MAIN_NEW' } } },
    @{ n = 'NAME-002 file renamed'; want = 'PROJECT-NAME-002'; code = ''; m = { param($c) Rename-Item $c.Gvl 'GVL_Renamed.TcGVL'; Edit-LintFxFile $c.Plcproj { param($t) $t.Replace('"GVL_Smoke4024.TcGVL"', '"GVL_Renamed.TcGVL"') } } },
    @{ n = 'GUID-001 Id removed'; want = 'PROJECT-GUID-001'; code = 'LINT_FAILED'; m = { param($c) Edit-LintFxFile $c.Dut { param($t) First $t ' Id="\{[^}]+\}"' '' } } },
    @{ n = 'GUID-002 Id malformed'; want = 'PROJECT-GUID-002'; code = 'LINT_FAILED'; m = { param($c) Edit-LintFxFile $c.Dut { param($t) First $t ' Id="\{([0-9a-f-]+)\}"' ' Id="$1"' } } },
    @{ n = 'GUID-003 copied POU keeps its Ids'; want = 'PROJECT-GUID-003'; code = 'LINT_FAILED'; m = { param($c)
            $t = [IO.File]::ReadAllText($c.Ctrl, [Text.Encoding]::UTF8).Replace('FB_MachineCtrl', 'FB_MachineCtrl2')
            [IO.File]::WriteAllText((Join-Path $c.Plc '00_Machine\FB_MachineCtrl2.TcPOU'), $t, (New-Object Text.UTF8Encoding($true)))
            Edit-LintFxFile $c.Plcproj { param($t) First $t '(    <Compile Include="00_Machine\\FB_MachineCtrl.TcPOU">)' ("    <Compile Include=`"00_Machine\FB_MachineCtrl2.TcPOU`">`r`n      <SubType>Code</SubType>`r`n    </Compile>`r`n" + '$1') } } },
    @{ n = 'GUID-004 zero Id'; want = 'PROJECT-GUID-004'; code = 'LINT_FAILED'; m = { param($c) Edit-LintFxFile $c.Gvl { param($t) First $t ' Id="\{[^}]+\}"' ' Id="{00000000-0000-0000-0000-000000000000}"' } } },
    @{ n = 'GUID-005 hand-written Id'; want = 'PROJECT-GUID-005'; code = ''; m = { param($c) Edit-LintFxFile $c.Gvl { param($t) First $t ' Id="\{[^}]+\}"' ' Id="{12345678-abcd-4ef0-8123-456789abcdef}"' } } },
    @{ n = 'SUB-001 Method Declaration removed'; want = 'PROJECT-SUB-001'; code = 'LINT_FAILED'; m = { param($c) Edit-LintFxFile $c.Ctrl { param($t) First $t '(<Method Name="M_AssignIO"[^>]*>\r\n)\s*<Declaration>.*?</Declaration>\r\n' '$1' } } },
    @{ n = 'SUB-002 two Methods with one name (LineIds renamed too)'; want = 'PROJECT-LINEIDS-001,PROJECT-SUB-002'; code = 'LINT_FAILED'; m = { param($c) Edit-LintFxFile $c.Ctrl { param($t) $t.Replace('Name="M_GetSystemTime"', 'Name="M_GetSystemDate"').Replace('METHOD M_GetSystemTime', 'METHOD M_GetSystemDate').Replace('FB_MachineCtrl.M_GetSystemTime', 'FB_MachineCtrl.M_GetSystemDate') } } },
    @{ n = 'LINEIDS-001 Count changed'; want = 'PROJECT-LINEIDS-001'; code = ''; m = { param($c) Edit-LintFxFile $c.Ctrl { param($t) First $t '(<LineIds Name="FB_MachineCtrl">\r\n\s*<LineId Id="\d+" Count=")(\d+)' '${1}99' } } },
    @{ n = 'COMPILE-001 item for a missing file'; want = 'PROJECT-COMPILE-001'; code = 'LINT_FAILED'; m = { param($c) Edit-LintFxFile $c.Plcproj { param($t) First $t '(    <Compile Include="PlcTask.TcTTO">)' ("    <Compile Include=`"POUs\FB_New.TcPOU`">`r`n      <SubType>Code</SubType>`r`n    </Compile>`r`n" + '$1') } } },
    @{ n = 'COMPILE-002 item twice'; want = 'PROJECT-COMPILE-002'; code = 'LINT_FAILED'; m = { param($c) Edit-LintFxFile $c.Plcproj { param($t) First $t '(    <Compile Include="PlcTask.TcTTO">)' ("    <Compile Include=`"POUs\MAIN.TcPOU`">`r`n      <SubType>Code</SubType>`r`n    </Compile>`r`n" + '$1') } } },
    @{ n = 'COMPILE-003 new POU not added to the project'; want = 'PROJECT-COMPILE-003'; code = ''; m = { param($c) Copy-Item $c.Main (Join-Path $c.Plc 'POUs\MAIN_Copy.TcPOU') } },
    @{ n = 'COMPILE-004 SubType changed'; want = 'PROJECT-COMPILE-004'; code = 'LINT_FAILED'; m = { param($c) Edit-LintFxFile $c.Plcproj { param($t) First $t '(<Compile Include="PlcTask.TcTTO">\r\n\s*<SubType>)Code' '${1}Content' } } },
    @{ n = 'COMPILE-005 new directory without Folder item'; want = 'PROJECT-COMPILE-005'; code = ''; m = { param($c)
            New-Item -ItemType Directory -Path (Join-Path $c.Plc 'NewDir') | Out-Null; Move-Item $c.Gvl (Join-Path $c.Plc 'NewDir\GVL_Smoke4024.TcGVL')
            Edit-LintFxFile $c.Plcproj { param($t) $t.Replace('"GVL_Smoke4024.TcGVL"', '"NewDir\GVL_Smoke4024.TcGVL"') } } },
    @{ n = 'COMPILE-006 Include case differs'; want = 'PROJECT-COMPILE-006'; code = 'LINT_FAILED'; m = { param($c) Edit-LintFxFile $c.Plcproj { param($t) $t.Replace('"POUs\MAIN.TcPOU"', '"pous\main.TcPOU"') } } },
    @{ n = 'LIB-001 DefaultResolution removed'; want = 'PROJECT-LIB-001'; code = 'LINT_FAILED'; m = { param($c) Edit-LintFxFile $c.Plcproj { param($t) First $t '\s*<DefaultResolution>[^<]*</DefaultResolution>' '' } } },
    @{ n = 'TSPROJ-001 PrjFilePath wrong'; want = 'PROJECT-TSPROJ-001'; code = 'LINT_FAILED'; m = { param($c) Edit-LintFxFile $c.Tsproj { param($t) $t.Replace('PrjFilePath="PLC1\PLC1.plcproj"', 'PrjFilePath="PLC1\PLC_1.plcproj"') } } },
    @{ n = 'TSPROJ-002 GUID in .tsproj changed'; want = 'PROJECT-TSPROJ-002'; code = 'LINT_FAILED'; m = { param($c) Edit-LintFxFile $c.Tsproj { param($t) $t.Replace('GUID="{2CC04917-125B-4C19-BAC8-BF2C10A34957}"', 'GUID="{2CC04917-125B-4C19-BAC8-BF2C10A34958}"') } } },
    @{ n = 'TSPROJ-003 PouCall to a missing PROGRAM'; want = 'PROJECT-TSPROJ-003'; code = 'LINT_FAILED'; m = { param($c) Edit-LintFxFile $c.Task { param($t) $t.Replace('<Name>MAIN</Name>', '<Name>MAIN2</Name>') } } },
    @{ n = 'ENC-001 file rewritten with LF'; want = 'PROJECT-ENC-001'; code = ''; m = { param($c) $t = [IO.File]::ReadAllText($c.Gvl, [Text.Encoding]::UTF8).Replace("`r`n", "`n"); [IO.File]::WriteAllText($c.Gvl, $t, (New-Object Text.UTF8Encoding($false))) } },
    @{ n = 'LINT-PARSE-002 END_IF removed'; want = 'LINT-PARSE-002'; code = 'LINT_PARSE_FAILED'; m = { param($c) Edit-LintFxFile $c.Main { param($t) First $t 'END_IF;?' '' } } },
    @{ n = 'LINT-PARSE-003 END_VAR removed'; want = 'LINT-PARSE-003'; code = 'LINT_PARSE_FAILED'; m = { param($c) Edit-LintFxFile $c.Ctrl { param($t) First $t '(<Method Name="M_AssignIO".*?)END_VAR' '$1' } } }
)
$i = 0
foreach ($case in $cases) {
    $i++
    $c = New-Copy ("s{0:D2}" -f $i)
    & $case.m $c
    $r = Invoke-TcLintProject -PlcProjectPath $c.Plcproj
    $new = @($r.data.diagnostics | Where-Object { -not $baseKeys.ContainsKey((Key $_)) })
    $ids = @($new | ForEach-Object { $_.ruleId } | Sort-Object -Unique)
    $code = if ($r.success) { '' } else { $r.error.code }
    $ok = (($ids -join ',') -eq $case.want) -and ($code -eq $case.code)
    if (-not $ok) { $script:fail++ }
    $rows.Add([ordered]@{ case = $case.n; expected = $case.want; newFindings = ($ids -join ','); count = $new.Count; code = $code; ok = $ok })
    "{0} {1}: new=[{2}] x{3} code={4}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $case.n, ($ids -join ','), $new.Count, $code
    if (-not $ok) { foreach ($d in $new) { "     $($d.ruleId) $($d.file) $($d.objectPath):$($d.line) $($d.message)" } }
    Remove-Item -LiteralPath $c.Root -Recurse -Force
}
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
"| # | 植入 | 預期 | 新增 finding | 筆數 | code | 結果 |"
"|---|---|---|---|---|---|---|"
$k = 0; foreach ($row in $rows) { $k++; "| $k | $($row.case) | $($row.expected) | $($row.newFindings) | $($row.count) | $(if ($row.code) { $row.code } else { 'success' }) | $(if ($row.ok) { 'PASS' } else { 'FAIL' }) |" }
"failed: $fail"
exit $fail
