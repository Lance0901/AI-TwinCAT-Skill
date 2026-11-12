# Throwaway prototype runner for #252 design research. NOT product code.
# Usage: powershell -NoProfile -File Run-Proto.ps1 -PlcProj <path> [-BaselineFrom <plcproj>] [-OutFile <txt>]
param(
    [Parameter(Mandatory)][string[]]$PlcProj,
    [string]$BaselineFrom,
    [string]$OutFile
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$sw = [Diagnostics.Stopwatch]::StartNew()
Add-Type -Path (Join-Path $here 'StLint.cs'), (Join-Path $here 'Analyzer.cs') -ReferencedAssemblies System.Xml, System.Core
$compileMs = $sw.ElapsedMilliseconds
$memBefore = [GC]::GetTotalMemory($true)

$baseline = $null
if ($BaselineFrom) { $baseline = [StLintProto.ProjectResult]::Snapshot([StLintProto.ProjectResult]::Analyze($BaselineFrom, $null)) }

$out = [System.Collections.Generic.List[string]]::new()
$out.Add("compileMs=$compileMs")
foreach ($p in $PlcProj) {
    $sw.Restart()
    $r = [StLintProto.ProjectResult]::Analyze($p, $baseline)
    $ms = $sw.ElapsedMilliseconds
    $sw.Restart()
    $r2 = [StLintProto.ProjectResult]::Analyze($p, $baseline)
    $ms2 = $sw.ElapsedMilliseconds
    $a = ($r.Sorted() | ForEach-Object { $_.Key() }) -join "`n"
    $b = ($r2.Sorted() | ForEach-Object { $_.Key() }) -join "`n"
    $out.Add("=== $p")
    $out.Add("analyzeMs(cold)=$ms analyzeMs(warm)=$ms2 deterministic=$($a -ceq $b)")
    $out.Add("heapDeltaBytes=$([GC]::GetTotalMemory($false) - $memBefore)")
    foreach ($k in ($r.Stats.Keys | Sort-Object)) { $out.Add("stat $k=$($r.Stats[$k])") }
    foreach ($f in $r.Failures) { $out.Add("FAIL $f") }
    foreach ($f in $r.Sorted()) { $out.Add(("FINDING {0} [{1}/{2}] {3} :: {4} L{5} :: {6}" -f $f.RuleId, $f.Severity, $f.Confidence, $f.File, $f.Object, $f.Line, $f.Message)) }
}
if ($OutFile) { $out | Set-Content -Path $OutFile -Encoding utf8 } else { $out }
