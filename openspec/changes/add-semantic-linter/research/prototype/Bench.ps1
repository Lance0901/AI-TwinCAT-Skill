# Throwaway: compare tokenizer cost C# (Add-Type) vs pure PowerShell vs Node on the same ST text. NOT product code.
param([Parameter(Mandatory)][string]$CorpusRoot, [string]$DumpFile)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Add-Type -Path (Join-Path $here 'StLint.cs'), (Join-Path $here 'Analyzer.cs') -ReferencedAssemblies System.Xml, System.Core
$texts = [System.Collections.Generic.List[string]]::new()
Get-ChildItem $CorpusRoot -Recurse -Include *.TcPOU, *.TcDUT, *.TcGVL | Where-Object { $_.FullName -notmatch '_bak_' } | ForEach-Object {
    $o = [StLintProto.TcXml]::Load($_.FullName)
    foreach ($s in $o.Sections) { if ($s.Decl) { $texts.Add($s.Decl) }; if ($s.Impl) { $texts.Add($s.Impl) } }
}
$all = $texts -join "`n"
if ($DumpFile) { [IO.File]::WriteAllText($DumpFile, $all) }
"chars=$($all.Length) lines=$(($all -split "`n").Count) sections=$($texts.Count)"
$sw = [Diagnostics.Stopwatch]::StartNew(); $n = 0
for ($k = 0; $k -lt 5; $k++) { foreach ($t in $texts) { $n += [StLintProto.Lexer]::Lex($t, $false).Count } }
"csharp tokens/5runs=$n ms_per_run=$([int]($sw.ElapsedMilliseconds / 5))"

function Lex-Ps([string]$s) {
    $toks = [System.Collections.Generic.List[string]]::new(); $i = 0; $n = $s.Length
    while ($i -lt $n) {
        $c = $s[$i]
        if ([char]::IsWhiteSpace($c)) { $i++; continue }
        if ($c -eq '/' -and $i + 1 -lt $n -and $s[$i + 1] -eq '/') { $j = $s.IndexOf("`n", $i); if ($j -lt 0) { $j = $n }; $i = $j; continue }
        if ($c -eq '(' -and $i + 1 -lt $n -and $s[$i + 1] -eq '*') { $d = 1; $i += 2; while ($i -lt $n -and $d -gt 0) { if ($s[$i] -eq '(' -and $s[$i + 1] -eq '*') { $d++; $i += 2 } elseif ($s[$i] -eq '*' -and $s[$i + 1] -eq ')') { $d--; $i += 2 } else { $i++ } }; continue }
        if ($c -eq '{') { $i = $s.IndexOf('}', $i) + 1; $toks.Add('pragma'); continue }
        if ($c -eq "'" -or $c -eq '"') { $q = $c; $i++; while ($i -lt $n -and $s[$i] -ne $q) { if ($s[$i] -eq '$') { $i++ }; $i++ }; $i++; $toks.Add('str'); continue }
        if ([char]::IsLetterOrDigit($c) -or $c -eq '_') { $st = $i; while ($i -lt $n -and ([char]::IsLetterOrDigit($s[$i]) -or $s[$i] -eq '_' -or $s[$i] -eq '#')) { $i++ }; $toks.Add($s.Substring($st, $i - $st)); continue }
        if ($i + 1 -lt $n -and ($s.Substring($i, 2) -in ':=', '=>', '<>', '<=', '>=', '..', '**')) { $toks.Add($s.Substring($i, 2)); $i += 2; continue }
        $toks.Add([string]$c); $i++
    }
    return $toks.Count
}
$sw.Restart(); $n = 0
foreach ($t in $texts) { $n += Lex-Ps $t }
"powershell tokens/1run=$n ms_per_run=$($sw.ElapsedMilliseconds)"
