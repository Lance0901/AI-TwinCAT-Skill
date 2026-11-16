<#
.SYNOPSIS
    Seeded-bug run of the Phase 3a rules (#252: SCAN-REF-001, SCAN-SM-001, SCAN-FLOAT-001, SCAN-INTDIV-001, SCAN-FBVAL-001)
    on the 4024 corpus project, through LintCandidate (in memory) and LintProject (on a COPY).
.DESCRIPTION
    Same mechanics as lint-seeded-2a.ps1: each case adds declarations to MAIN of <CorpusRoot>fh and appends code; the NEW
    findings must be exactly the expected rule. Positive cases: unassigned REFERENCE / POINTER dereference, state value without
    CASE label, REAL = literal, integer division into REAL; FBVAL through a new FUNCTION candidate. Negative cases (legal
    look-alikes, no finding allowed): __ISVALIDREF guard, REF= / ADR before the use, CASE with ELSE, return to the idle
    initial value, comparison with 0.0 / >=, INT_TO_REAL before dividing, FB input only read.
    Not in CI (corpus not in the repository). Exit code = number of failed checks.
.PARAMETER CorpusRoot
    Folder with bfh\ (default C:\Temp\lint-corpus).
.EXAMPLE
    powershell.exe -NoProfile -File tests/Integration/lint-seeded-3a.ps1
#>
[CmdletBinding()]
param([string]$CorpusRoot = 'C:\Temp\lint-corpus')
$ErrorActionPreference = 'Stop'
$ownStateDir = $null   # second review N6: only the state directory this script created is removed at the end
if ([string]::IsNullOrEmpty($env:TCAUTO_STATE_DIR)) {
    $env:TCAUTO_STATE_DIR = Join-Path $env:TEMP ('tcauto-lint-seeded3a-' + [guid]::NewGuid().ToString('N'))
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
$work = Join-Path $env:TEMP ('tcauto-lint-seeded3a-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
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
    # ---- positives (rule expected)
    @{ n = 'REFERENCE read without REF= / guard'; want = 'SCAN-REF-001'; v = "    refSeed : REFERENCE TO INT;`n    nSeedR : INT;`n"; c = "nSeedR := refSeed;" },
    @{ n = 'POINTER without ADR dereferenced'; want = 'SCAN-REF-001'; v = "    pSeed : POINTER TO INT;`n    nSeedR : INT;`n"; c = "nSeedR := pSeed^;" },
    @{ n = 'state 30 without CASE label, no ELSE'; want = 'SCAN-SM-001'; v = "    nSeedSt : INT;`n"; c = "CASE nSeedSt OF`n0:`n    nSeedSt := 10;`n10:`n    nSeedSt := 30;`nEND_CASE" },
    @{ n = 'REAL = 100.5'; want = 'SCAN-FLOAT-001'; v = "    rSeed : REAL;`n    bSeed : BOOL;`n"; c = "bSeed := rSeed = 100.5;" },
    @{ n = 'REAL := INT / INT'; want = 'SCAN-INTDIV-001'; v = "    rSeed : REAL;`n    nSeedA : INT;`n    nSeedB : INT;`n"; c = "rSeed := nSeedA / 4;" },
    # ---- negatives (legal look-alikes)
    @{ n = 'NEG REFERENCE guarded by __ISVALIDREF'; want = ''; v = "    refSeed : REFERENCE TO INT;`n    nSeedR : INT;`n"; c = "IF __ISVALIDREF(refSeed) THEN`n    nSeedR := refSeed;`nEND_IF" },
    @{ n = 'NEG REF= before the use'; want = ''; v = "    refSeed : REFERENCE TO INT;`n    nSeedR : INT;`n    nSeedX : INT;`n"; c = "refSeed REF= nSeedX;`nnSeedR := refSeed;" },
    @{ n = 'NEG pointer := ADR before p^'; want = ''; v = "    pSeed : POINTER TO INT;`n    nSeedR : INT;`n    nSeedX : INT;`n"; c = "pSeed := ADR(nSeedX);`nnSeedR := pSeed^;" },
    @{ n = 'NEG CASE with ELSE'; want = ''; v = "    nSeedSt : INT;`n"; c = "CASE nSeedSt OF`n0:`n    nSeedSt := 10;`n10:`n    nSeedSt := 30;`nELSE`n    nSeedSt := 0;`nEND_CASE" },
    @{ n = 'NEG state back to idle 0 (initial value)'; want = ''; v = "    nSeedSt : INT;`n    bSeed : BOOL;`n"; c = "IF bSeed THEN`n    nSeedSt := 10;`nEND_IF`nCASE nSeedSt OF`n10:`n    nSeedSt := 0;`nEND_CASE" },
    @{ n = 'NEG REAL compared with 0.0 and with >='; want = ''; v = "    rSeed : REAL;`n    bSeed : BOOL;`n"; c = "bSeed := rSeed = 0.0 OR rSeed >= 100.5;" },
    @{ n = 'NEG INT_TO_REAL before the division'; want = ''; v = "    rSeed : REAL;`n    nSeedA : INT;`n    nSeedB : INT;`n"; c = "rSeed := INT_TO_REAL(nSeedA) / 4;" }
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

# FB passed by value (new FUNCTION object): calling the copy is reported, reading its output is not
$r = Invoke-TcLintCandidate -ObjectKind Function -ObjectName F_SeedVal -PlcProjectPath $plcproj -Declaration "FUNCTION F_SeedVal : BOOL`r`nVAR_INPUT`r`n    tonIn : TON;`r`nEND_VAR`r`n" -Implementation "tonIn(IN := TRUE, PT := T#1S);`r`nF_SeedVal := tonIn.Q;"
Check 'candidate: FUNCTION VAR_INPUT TON called -> SCAN-FBVAL-001' ((@($r.data.diagnostics | Where-Object { $_.ruleId -like 'SCAN-*' }) | ForEach-Object { $_.ruleId }) -join ',' -eq 'SCAN-FBVAL-001') "code=$($r.error.code) $((@($r.data.diagnostics | ForEach-Object { $_.ruleId }) -join ','))"
$r = Invoke-TcLintCandidate -ObjectKind Function -ObjectName F_SeedVal -PlcProjectPath $plcproj -Declaration "FUNCTION F_SeedVal : BOOL`r`nVAR_INPUT`r`n    tonIn : TON;`r`nEND_VAR`r`n" -Implementation "F_SeedVal := tonIn.Q;"
Check 'candidate: NEG FUNCTION VAR_INPUT TON only read' (@($r.data.diagnostics | Where-Object { $_.ruleId -like 'SCAN-*' }).Count -eq 0 -and $r.success) "code=$($r.error.code) $((@($r.data.diagnostics | ForEach-Object { $_.ruleId }) -join ','))"
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
"lint-seeded-3a: $fail failed"
Exit-Script $fail
