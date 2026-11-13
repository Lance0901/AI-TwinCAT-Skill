<#
.SYNOPSIS
    Seeded-bug run of the Phase 2a rules (#252: SCAN-LOOP-001, SCAN-FOR-001, SCAN-ARR-001, SAFETY-ARR-001,
    SAFETY-DIV-001) on the 4024 corpus project, through LintCandidate (in memory) and LintProject (on a COPY).
.DESCRIPTION
    Each case adds declarations to MAIN of <CorpusRoot>\bfh and appends code to its implementation. The NEW
    findings (rule id + variant + object + message not present for the unchanged MAIN) must be exactly the
    expected ones:
      - LintCandidate -ObjectKind Program -ObjectName MAIN -PlcProjectPath <corpus .plcproj> (nothing is written;
        the corpus is only read);
      - LintProject on a copy of the project with the same text written into MAIN.TcPOU (the 4024 file has
        LineIds, so PROJECT-LINEIDS-001 is an expected extra finding there and only there).
    Positive cases: busy-wait, FOR overflow, 0-based loop on a 1-based array, constant index out of bounds,
    division by constant 0, MOD 0. Negative cases (legal look-alikes, no finding allowed): the condition is
    written in the loop, EXIT in the body, WHILE TRUE with EXIT, FOR end below the type maximum, loop bounds from
    LOWER_BOUND / UPPER_BOUND, ARRAY[*] in a function, divisor checked for zero first.
    Not in CI (corpus not in the repository). Exit code = number of failed checks.
.PARAMETER CorpusRoot
    Folder with bfh\ (default C:\Temp\lint-corpus).
.EXAMPLE
    powershell.exe -NoProfile -File tests/Integration/lint-seeded-2a.ps1
#>
[CmdletBinding()]
param([string]$CorpusRoot = 'C:\Temp\lint-corpus')
$ErrorActionPreference = 'Stop'
$ownStateDir = $null   # second review N6: only the state directory this script created is removed at the end
if ([string]::IsNullOrEmpty($env:TCAUTO_STATE_DIR)) {
    $env:TCAUTO_STATE_DIR = Join-Path $env:TEMP ('tcauto-lint-seeded2a-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $env:TCAUTO_STATE_DIR | Out-Null
    $ownStateDir = $env:TCAUTO_STATE_DIR
}
function Exit-Script([int]$Code) {
    if ($script:ownStateDir) { Remove-Item -LiteralPath $script:ownStateDir -Recurse -Force -ErrorAction SilentlyContinue }
    exit $Code
}
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$src = Join-Path $CorpusRoot 'bfh'
if (-not (Test-Path -LiteralPath $src)) { "SKIP corpus not found: $src"; Exit-Script 1 }
$plcproj = Join-Path $src 'LangMang260618\PLC1\PLC1.plcproj'
$mainFile = Join-Path $src 'LangMang260618\PLC1\POUs\MAIN.TcPOU'
# raw CDATA text (an XML parser would turn CRLF into LF and the copy could not be edited by text)
$raw = [System.IO.File]::ReadAllText($mainFile)
$decl0 = ([regex]::Match($raw, '(?s)<Declaration><!\[CDATA\[(.*?)\]\]></Declaration>')).Groups[1].Value
$impl0 = ([regex]::Match($raw, '(?s)<Implementation>\s*<ST><!\[CDATA\[(.*?)\]\]></ST>')).Groups[1].Value
if (-not $decl0 -or -not $impl0) { 'FAIL MAIN.TcPOU layout not as expected'; Exit-Script 1 }
$work = Join-Path $env:TEMP ('tcauto-lint-seeded2a-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work | Out-Null
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) { "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail; if (-not $Ok) { $script:fail++ } }
function Key($d) { return "$($d.ruleId)|$($d.variant)|$($d.objectPath)|$($d.message)" }
function NewOf($r, $baseKeys) { return @($r.data.diagnostics | Where-Object { -not $baseKeys.ContainsKey((Key $_)) }) }
function Seed([string]$Vars, [string]$Code) {
    $d = $decl0 -replace '(?s)^(\s*PROGRAM MAIN\s*\r?\nVAR\r?\n)', ('$1' + ($Vars.Replace("`n", "`r`n")))
    if ($d -eq $decl0 -and $Vars) { throw 'MAIN declaration layout not as expected' }
    return @{ Decl = $d; Impl = ($impl0 + "`r`n" + $Code.Replace("`n", "`r`n")) }
}
function Cand($s) { return (Invoke-TcLintCandidate -ObjectKind Program -ObjectName MAIN -Declaration $s.Decl -Implementation $s.Impl -PlcProjectPath $plcproj) }

# baselines: unchanged MAIN as candidate, pristine copy on disk
$c0 = Cand @{ Decl = $decl0; Impl = $impl0 }
$cBase = @{}; foreach ($d in @($c0.data.diagnostics)) { $cBase[(Key $d)] = $true }
$copy = Join-Path $work 'bfh'
Copy-Item -LiteralPath $src -Destination $copy -Recurse
$copyPlc = Join-Path $copy 'LangMang260618\PLC1\PLC1.plcproj'
$copyMain = Join-Path $copy 'LangMang260618\PLC1\POUs\MAIN.TcPOU'
$mainBytes = [System.IO.File]::ReadAllBytes($copyMain)
$p0 = Invoke-TcLintProject -PlcProjectPath $copyPlc -Scope Object -ObjectPaths MAIN
$pBase = @{}; foreach ($d in @($p0.data.diagnostics)) { $pBase[(Key $d)] = $true }
"baseline: candidate $($c0.data.verdict) $(@($c0.data.diagnostics).Count) findings; copy $($p0.data.verdict) $(@($p0.data.diagnostics).Count) findings"

$cases = @(
    # ---- positives (rule[/variant] expected, code expected)
    @{ n = 'busy-wait WHILE on an input bit'; want = 'SCAN-LOOP-001'; v = "    bSeedReady AT %I* : BOOL;`n"; c = "WHILE NOT bSeedReady DO`nEND_WHILE" },
    @{ n = 'busy-wait REPEAT on an FB output'; want = 'SCAN-LOOP-001'; v = "    tonSeed : TON;`n    nSeed : INT;`n"; c = "tonSeed(IN := TRUE, PT := T#1S);`nREPEAT`n    nSeed := nSeed + 1;`nUNTIL tonSeed.Q`nEND_REPEAT" },
    @{ n = 'FOR BYTE counter to 255 (overflow)'; want = 'SCAN-FOR-001'; v = "    iSeed : BYTE;`n    aSeedB : ARRAY[0..255] OF BOOL;`n"; c = "FOR iSeed := 0 TO 255 DO`n    aSeedB[iSeed] := FALSE;`nEND_FOR" },
    @{ n = 'FOR 0-based loop on ARRAY[1..10]'; want = 'SCAN-ARR-001'; v = "    aSeed : ARRAY[1..10] OF INT;`n    kSeed : INT;`n"; c = "FOR kSeed := 0 TO 9 DO`n    aSeed[kSeed] := 0;`nEND_FOR" },
    @{ n = 'constant index out of bounds'; want = 'SAFETY-ARR-001'; v = "    aSeed : ARRAY[1..10] OF INT;`n"; c = "aSeed[11] := 1;" },
    @{ n = 'division by constant 0'; want = 'SAFETY-DIV-001'; v = "    nSeed : DINT;`n"; c = "nSeed := nSeed / 0;" },
    @{ n = 'MOD 0'; want = 'SAFETY-DIV-001'; v = "    nSeed : DINT;`n"; c = "nSeed := nSeed MOD 0;" },
    # ---- negatives (legal look-alikes)
    @{ n = 'NEG loop condition written in the body'; want = ''; v = "    nSeed : INT;`n"; c = "WHILE nSeed < 10 DO`n    nSeed := nSeed + 1;`nEND_WHILE" },
    @{ n = 'NEG busy-looking loop with EXIT'; want = ''; v = "    bSeedReady AT %I* : BOOL;`n    nSeed : INT;`n"; c = "WHILE NOT bSeedReady DO`n    nSeed := nSeed + 1;`n    IF nSeed > 100 THEN`n        EXIT;`n    END_IF`nEND_WHILE" },
    @{ n = 'NEG WHILE TRUE with EXIT'; want = ''; v = "    nSeed : INT;`n"; c = "WHILE TRUE DO`n    nSeed := nSeed + 1;`n    IF nSeed >= 10 THEN`n        EXIT;`n    END_IF`nEND_WHILE" },
    @{ n = 'NEG FOR end below the type maximum'; want = ''; v = "    iSeed : BYTE;`n    aSeedB : ARRAY[0..254] OF BOOL;`n"; c = "FOR iSeed := 0 TO 254 DO`n    aSeedB[iSeed] := FALSE;`nEND_FOR" },
    @{ n = 'NEG loop bounds from LOWER_BOUND / UPPER_BOUND'; want = ''; v = "    aSeed : ARRAY[1..10] OF INT;`n    kSeed : DINT;`n"; c = "FOR kSeed := LOWER_BOUND(aSeed, 1) TO UPPER_BOUND(aSeed, 1) DO`n    aSeed[kSeed] := 0;`nEND_FOR" },
    @{ n = 'NEG 1-based loop on ARRAY[1..10]'; want = ''; v = "    aSeed : ARRAY[1..10] OF INT;`n    kSeed : INT;`n"; c = "FOR kSeed := 1 TO 10 DO`n    aSeed[kSeed] := 0;`nEND_FOR" },
    @{ n = 'NEG divisor checked before dividing'; want = ''; v = "    nSeed : DINT;`n    nDiv : DINT;`n"; c = "IF nDiv <> 0 THEN`n    nSeed := nSeed / nDiv;`nEND_IF" },
    @{ n = 'NEG constant index inside bounds'; want = ''; v = "    aSeed : ARRAY[1..10] OF INT;`n"; c = "aSeed[10] := 1;" }
)
foreach ($k in $cases) {
    $s = Seed $k.v $k.c
    $r = Cand $s
    $new = NewOf $r $cBase
    $got = (@($new | ForEach-Object { $_.ruleId } | Sort-Object -Unique) -join ',')
    Check "candidate: $($k.n)" ($got -eq $k.want) "new=[$((@($new | ForEach-Object { "$($_.ruleId)/$($_.variant)@$($_.line) b=$($_.blocking)" }) -join '; '))] code=$($r.error.code)"
    # same text on the copy, through LintProject
    [System.IO.File]::WriteAllBytes($copyMain, $mainBytes)
    $t = [System.Text.Encoding]::UTF8.GetString($mainBytes).TrimStart([char]0xFEFF)
    $t = $t.Replace('<![CDATA[' + $decl0 + ']]>', '<![CDATA[' + $s.Decl + ']]>').Replace('<![CDATA[' + $impl0 + ']]>', '<![CDATA[' + $s.Impl + ']]>')
    [System.IO.File]::WriteAllText($copyMain, $t, (New-Object System.Text.UTF8Encoding($true)))
    $p = Invoke-TcLintProject -PlcProjectPath $copyPlc -Scope Object -ObjectPaths MAIN
    $pn = @(NewOf $p $pBase | Where-Object { $_.ruleId -ne 'PROJECT-LINEIDS-001' })
    $pgot = (@($pn | ForEach-Object { $_.ruleId } | Sort-Object -Unique) -join ',')
    Check "project copy: $($k.n)" ($pgot -eq $k.want) "new=[$((@($pn | ForEach-Object { "$($_.ruleId)/$($_.variant)@$($_.line)" }) -join '; '))] code=$($p.error.code)"
}

# ARRAY[*] in a function (new object): no finding
$r = Invoke-TcLintCandidate -ObjectKind Function -ObjectName F_SeedSum -PlcProjectPath $plcproj -Declaration "FUNCTION F_SeedSum : DINT`r`nVAR_IN_OUT`r`n    a : ARRAY[*] OF INT;`r`nEND_VAR`r`nVAR`r`n    i : DINT;`r`nEND_VAR`r`n" -Implementation "FOR i := LOWER_BOUND(a, 1) TO UPPER_BOUND(a, 1) DO`r`n    F_SeedSum := F_SeedSum + a[i];`r`nEND_FOR"
Check 'candidate: NEG ARRAY[*] in a function with LOWER_BOUND / UPPER_BOUND' (@($r.data.diagnostics | Where-Object { $_.ruleId -match '^(SCAN-LOOP|SCAN-FOR|SCAN-ARR|SAFETY-ARR|SAFETY-DIV)' }).Count -eq 0 -and $r.success) "code=$($r.error.code) $((@($r.data.diagnostics | ForEach-Object { $_.ruleId }) -join ','))"
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
"lint-seeded-2a: $fail failed"
Exit-Script $fail
