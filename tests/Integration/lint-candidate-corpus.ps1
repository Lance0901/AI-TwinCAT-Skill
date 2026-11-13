<#
.SYNOPSIS
    Local corpus consistency check of LintCandidate (#252 Phase 2a, tasks 2.1): every top-level object of the two
    corpus projects is laid over its own project unchanged (Declaration / Implementation as on disk) and must give
    the same diagnostics as LintProject -Scope Object for that object. Read-only. Not in CI (the corpus is not in
    the repository).
.DESCRIPTION
    Compared per object: verdict, error code and every diagnostic (ruleId, variant, severity, blocking, file,
    objectPath, section, line, column, message). Known, intended difference: PROJECT-LINEIDS-001 of the candidate's
    own section is not evaluated by LintCandidate (XAE rewrites LineIds when it writes the code) - removed from
    the LintProject side before comparing, and counted.
    Objects whose implementation is not ST (CFC) cannot be a candidate (Implementation must be ST): skipped, listed.
    Exit code = number of objects that differ (plus 1 per project that could not be read).
.PARAMETER CorpusRoot
    Folder with axis\ and bfh\ (default C:\Temp\lint-corpus).
.EXAMPLE
    powershell.exe -NoProfile -File tests/Integration/lint-candidate-corpus.ps1
#>
[CmdletBinding()]
param(
    [string]$CorpusRoot = 'C:\Temp\lint-corpus'
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$projects = [ordered]@{
    axis = Join-Path $CorpusRoot 'axis\AxisInterface_Type01_Library\AxisInterface\AxisInterface.plcproj'
    bfh  = Join-Path $CorpusRoot 'bfh\LangMang260618\PLC1\PLC1.plcproj'
}
$kindByHeader = @{ PROGRAM = 'Program'; FUNCTION_BLOCK = 'FunctionBlock'; FUNCTION = 'Function' }
$fail = 0
function Key($d) { return '{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}' -f $d.ruleId, $d.variant, $d.severity, $d.blocking, $d.file, $d.objectPath, $d.section, $d.line, $d.column, $d.message }

foreach ($name in $projects.Keys) {
    $plc = $projects[$name]
    if (-not (Test-Path -LiteralPath $plc)) { "FAIL $name corpus not found: $plc"; $fail++; continue }
    $dir = [System.IO.Path]::GetDirectoryName($plc)
    [xml]$proj = [System.IO.File]::ReadAllText($plc)
    $files = @($proj.Project.ItemGroup.Compile | Where-Object { $_ -and $_.Include -match '\.(TcPOU|TcDUT|TcGVL|TcIO)$' } | ForEach-Object { $_.Include } | Sort-Object)
    $same = 0; $diff = 0; $skipped = [System.Collections.Generic.List[string]]::new(); $lineIdsRemoved = 0
    foreach ($inc in $files) {
        $full = Join-Path $dir $inc
        if (-not (Test-Path -LiteralPath $full)) { continue }
        [xml]$x = [System.IO.File]::ReadAllText($full)
        $obj = $x.TcPlcObject.ChildNodes | Where-Object { $_.NodeType -eq 'Element' } | Select-Object -First 1
        $objName = $obj.GetAttribute('Name')
        $decl = [string]$obj.Declaration.InnerText
        $impl = ''
        switch ($obj.LocalName) {
            'POU' {
                $hdr = ([regex]::Match($decl, '(?im)^\s*(PROGRAM|FUNCTION_BLOCK|FUNCTION)\b')).Groups[1].Value.ToUpperInvariant()
                $kind = $kindByHeader[$hdr]
                if ($null -eq $obj.Implementation.ST) { $skipped.Add("$objName (implementation not ST)"); continue }
                $impl = [string]$obj.Implementation.ST.InnerText
            }
            'DUT' { $kind = 'DUT' }
            'GVL' { $kind = 'GVL' }
            'Itf' { $kind = 'Interface' }
            default { $skipped.Add("$objName (<$($obj.LocalName)>)"); continue }
        }
        if (-not $kind) { $skipped.Add("$objName (header not found)"); continue }
        $p = Invoke-TcLintProject -PlcProjectPath $plc -Scope Object -ObjectPaths $objName
        $c = Invoke-TcLintCandidate -ObjectKind $kind -ObjectName $objName -Declaration $decl -Implementation $impl -PlcProjectPath $plc
        $pd = @($p.data.diagnostics | Where-Object { -not ($_.ruleId -eq 'PROJECT-LINEIDS-001' -and $_.objectPath -eq $objName) })
        $lineIdsRemoved += @($p.data.diagnostics).Count - $pd.Count
        $pk = @($pd | ForEach-Object { Key $_ }) -join "`n"
        # PR #284 review S3: findings of other objects the disk project already has are in data.preExisting
        $ck = @(@($c.data.diagnostics) + @($c.data.preExisting) | Where-Object { $_ } | Sort-Object { Key $_ } | ForEach-Object { Key $_ }) -join "`n"
        $pk = @($pd | Sort-Object { Key $_ } | ForEach-Object { Key $_ }) -join "`n"
        $pv = "$($p.data.verdict)/$($p.error.code)"; $cv = "$($c.data.verdict)/$($c.error.code)"
        if ($p.data.verdict -eq 'fail' -and $pd.Count -lt @($p.data.diagnostics).Count -and $pd.Count -eq 0) { $pv = 'pass/' }
        if ($pk -ceq $ck -and $pv -eq $cv -and $c.data.candidate.overlay -eq 'replaced') { $same++ }
        else {
            $diff++; $fail++
            "FAIL $name $objName ($kind): LintProject $pv [$pk] / LintCandidate $cv overlay=$($c.data.candidate.overlay) [$ck] $($c.error.message)"
        }
    }
    "{0} {1}: {2} objects identical, {3} differ, {4} skipped ({5}); LINEIDS-001 of the candidate section removed: {6}" -f $(if ($diff -eq 0) { 'PASS' } else { 'FAIL' }), $name, $same, $diff, $skipped.Count, ($skipped -join ', '), $lineIdsRemoved
}
exit $fail
