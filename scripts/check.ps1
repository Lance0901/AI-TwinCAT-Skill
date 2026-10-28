<#
.SYNOPSIS
    Repository guardrails: the mechanical checks every commit and every CI run must pass.

.DESCRIPTION
    Runs, in this order, and prints one PASS / FAIL / SKIP line per check:
      parse       Every *.ps1 / *.psm1 / *.psd1 in the repository (except node_modules, .git,
                  tests/Integration/logs, .claude/worktrees) parses with the Windows PowerShell
                  5.1 parser. PowerShell 7 only syntax (??, ?., ternary, ...) is a parse error
                  there, so this also blocks it.
      encoding    Those files are ASCII or UTF-8 with BOM (5.1 reads BOM-less files in the ANSI
                  code page, so the parse result would depend on the machine).
      generics    No "New-Object System.Collections.Generic.*" in src/ and mcp-server/ *.ps1:
                  @() on a New-Object List[object] throws ArgumentException in Windows
                  PowerShell 5.1.26100; use [System.Collections.Generic.List[...]]::new() (#75).
      cmdlets     The module imports (it must not depend on TwinCAT being installed) and the
                  number of exported cmdlets equals the number written in CLAUDE.md / AGENTS.md
                  "Available Commands (N)", README.md "All Commands (N)" and
                  adapters/claude-code/SKILL.md "Cmdlet ... (N)".
      wording     No banned wording in *.md / *.ps1 / *.psm1 / *.psd1 / *.js / *.json / *.yaml:
                  a UmRT has no version of its own (it is the user-mode instance of the local
                  TwinCAT runtime, there is only one), so "UmRT 4026", "UmRT (4026)",
                  "UmRT v4026", "UmRT 3.1.4026", "4026 UmRT" ... are rejected. A hit whose
                  version is part of a "TcSystemServiceUm.exe file version x.y.z" phrase is
                  allowed (only that hit, not the whole line).
      help        Every exported cmdlet has comment-based help that PowerShell can read: a
                  non-empty Synopsis (not the generated syntax line) and a description for each
                  of its parameters. A help line that starts with "." (e.g. ".sln to reopen")
                  is read as an unknown keyword and silently drops the whole help block; the
                  MCP tool descriptions in tools.json come from this help.
      errorcodes  Every key of $script:TcErrorHints (ConvertTo-TcAdsErrorCode.ps1) appears in a
                  heading of docs/troubleshooting.md.
      tools.json  mcp-server/tools.json equals a fresh Export-ToolSchema.ps1 output
                  (generatedAt and line endings ignored).
      unit        every tests/Unit/*.ps1 in its own powershell.exe (no IDE / runtime needed):
                  PASS when each exits 0 (and its "failed: N" line, if any, says 0); a script
                  that runs longer than 300 s is killed and fails. Skipped with -Fast (#43).
      npm test    mcp-server unit tests (npm ci first when node_modules is missing).
                  Skipped with -Fast.
    Exit code 0 when nothing failed, 1 otherwise. SKIP never counts as PASS; with -Strict a
    SKIP fails the run as well.

    The checks read the WORKING TREE, not the git index.

.PARAMETER Fast
    Skip unit and npm test (used by the pre-commit hook).
.PARAMETER Strict
    Treat SKIP as a failure (used by CI).

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/check.ps1 -Strict
#>
[CmdletBinding()]
param(
    [switch]$Fast,
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# The parse check is only meaningful with the 5.1 parser: re-run under Windows PowerShell.
if ($PSVersionTable.PSEdition -eq 'Core') {
    $argsList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    if ($Fast) { $argsList += '-Fast' }
    if ($Strict) { $argsList += '-Strict' }
    & powershell.exe @argsList
    exit $LASTEXITCODE
}

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $scriptDir '..')).ProviderPath
$utf8 = New-Object System.Text.UTF8Encoding($false)

$results = [System.Collections.Generic.List[object]]::new()
function Add-CheckResult {
    param([string]$Name, [ValidateSet('PASS', 'FAIL', 'SKIP')][string]$Status, [string]$Detail, [string[]]$Lines)
    $results.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail })
    $color = @{ PASS = 'Green'; FAIL = 'Red'; SKIP = 'Yellow' }[$Status]
    Write-Host ('{0,-5} {1,-11} {2}' -f $Status, $Name, $Detail) -ForegroundColor $color
    foreach ($l in $Lines) { Write-Host "      $l" }
}

function Get-RelativePath([string]$Path) {
    if ($Path.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $Path.Substring($repoRoot.Length).TrimStart('\', '/').Replace('\', '/')
    }
    return $Path
}

# Recursive file walk that never descends into excluded directories (node_modules is large).
function Get-RepoFiles {
    param([string]$Root, [string[]]$Extensions)
    $excludedNames = @('node_modules', '.git', '.vs')
    $excludedRel = @('tests/Integration/logs', '.claude/worktrees')
    # Skip files git ignores (local temp_*.ps1, logs): CI never sees them, and the pre-commit hook
    # must not block a commit because of an untracked scratch file. Tracked and new (untracked,
    # not ignored) files are still checked.
    $keep = $null
    try {
        $listed = @(& git -C $Root ls-files --cached --others --exclude-standard 2>$null)
        if ($LASTEXITCODE -eq 0 -and $listed.Count -gt 0) {
            $keep = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            foreach ($l in $listed) { [void]$keep.Add(($l -replace '\\', '/')) }
        }
    } catch { $keep = $null }
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        foreach ($d in [System.IO.Directory]::GetDirectories($dir)) {
            $name = [System.IO.Path]::GetFileName($d)
            if ($excludedNames -contains $name) { continue }
            if ($excludedRel -contains (Get-RelativePath $d)) { continue }
            $stack.Push($d)
        }
        foreach ($f in [System.IO.Directory]::GetFiles($dir)) {
            if ($Extensions -notcontains [System.IO.Path]::GetExtension($f).ToLowerInvariant()) { continue }
            if ($null -ne $keep -and -not $keep.Contains((Get-RelativePath $f))) { continue }
            $f
        }
    }
}

# Runs a native command with $ErrorActionPreference = 'Continue': under 'Stop' a single
# stderr line (npm warn, Write-Error of a child script) would throw. Success is judged by the
# exit code only. Returns @{ Code; Output (string[]) }.
function Invoke-Native {
    param([string]$FilePath, [string[]]$Arguments)
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = @(& $FilePath @Arguments 2>&1 | ForEach-Object { "$_" })
        return @{ Code = $LASTEXITCODE; Output = $out }
    }
    finally {
        $ErrorActionPreference = $saved
    }
}

# ---------------------------------------------------------------------------
# parse (Windows PowerShell 5.1 parser)
# ---------------------------------------------------------------------------
$psFiles = @()
try {
    $psFiles = @(Get-RepoFiles -Root $repoRoot -Extensions @('.ps1', '.psm1', '.psd1') | Sort-Object)
    $parseErrors = New-Object System.Collections.Generic.List[string]
    foreach ($f in $psFiles) {
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tokens, [ref]$errors)
        foreach ($e in $errors) {
            $parseErrors.Add(('{0}:{1} {2}' -f (Get-RelativePath $f), $e.Extent.StartLineNumber, $e.Message))
        }
    }
    if ($parseErrors.Count -eq 0) {
        Add-CheckResult 'parse' 'PASS' ("$($psFiles.Count) files, PowerShell $($PSVersionTable.PSVersion) parser")
    }
    else {
        Add-CheckResult 'parse' 'FAIL' ("$($parseErrors.Count) parse error(s) (PowerShell 7 only syntax is not allowed)") $parseErrors
    }
}
catch {
    Add-CheckResult 'parse' 'FAIL' "check crashed: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# encoding: Windows PowerShell 5.1 reads a script without BOM in the ANSI code page of the
# machine, so a non-ASCII character (even an em dash in a comment) parses on one PC and
# breaks on another (cp1252: the UTF-8 bytes of an em dash end in 0x94, a "smart quote").
# ---------------------------------------------------------------------------
try {
    $noBom = New-Object System.Collections.Generic.List[string]
    foreach ($f in $psFiles) {
        $bytes = [System.IO.File]::ReadAllBytes($f)
        $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        if ($hasBom) { continue }
        foreach ($b in $bytes) {
            if ($b -gt 127) { $noBom.Add((Get-RelativePath $f)); break }
        }
    }
    if ($noBom.Count -eq 0) {
        Add-CheckResult 'encoding' 'PASS' "$($psFiles.Count) files: ASCII or UTF-8 with BOM"
    }
    else {
        Add-CheckResult 'encoding' 'FAIL' "$($noBom.Count) file(s) with non-ASCII characters but no UTF-8 BOM (save as UTF-8 with BOM, or use ASCII)" $noBom
    }
}
catch {
    Add-CheckResult 'encoding' 'FAIL' "check crashed: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# generics: no New-Object System.Collections.Generic.* in src/ and mcp-server/ (#75).
# In Windows PowerShell 5.1.26100, @() on a List[object] built with New-Object throws
# ArgumentException ("Argument types do not match"); [List[object]]::new() does not.
# ---------------------------------------------------------------------------
try {
    $genericPattern = New-Object System.Text.RegularExpressions.Regex('New-Object\s+(-TypeName\s+)?[''"]?System\.Collections\.Generic\.', 'IgnoreCase')
    $genericHits = [System.Collections.Generic.List[string]]::new()
    $genericFiles = @($psFiles | Where-Object { (Get-RelativePath $_) -match '^(src|mcp-server)/' -and $_ -like '*.ps1' })
    foreach ($f in $genericFiles) {
        $lines = [System.IO.File]::ReadAllLines($f, $utf8)
        for ($i = 0; $i -lt $lines.Length; $i++) {
            if ($genericPattern.IsMatch($lines[$i])) { $genericHits.Add(('{0}:{1} {2}' -f (Get-RelativePath $f), ($i + 1), $lines[$i].Trim())) }
        }
    }
    if ($genericHits.Count -eq 0) {
        Add-CheckResult 'generics' 'PASS' "$($genericFiles.Count) src/ + mcp-server/ .ps1 files, no New-Object System.Collections.Generic.*"
    }
    else {
        $n = $genericHits.Count
        $genericHits.Add('use [System.Collections.Generic.List[object]]::new() instead: @() on a New-Object List[object] throws ArgumentException in Windows PowerShell 5.1.26100 and broke Get-TcBuildErrors permanently (#75)')
        Add-CheckResult 'generics' 'FAIL' "$n New-Object System.Collections.Generic.* hit(s)" $genericHits
    }
}
catch {
    Add-CheckResult 'generics' 'FAIL' "check crashed: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# cmdlet count vs documentation
# ---------------------------------------------------------------------------
try {
    $docCounts = @(
        @{ File = 'CLAUDE.md'; Pattern = 'Available Commands \((\d+)\)' },
        @{ File = 'AGENTS.md'; Pattern = 'Available Commands \((\d+)\)' },
        @{ File = 'README.md'; Pattern = 'All Commands \((\d+)\)' },
        @{ File = 'adapters/claude-code/SKILL.md'; Pattern = 'Cmdlet \S*\((\d+)\)' }
    )
    $moduleCount = $null
    $importError = $null
    try {
        $module = Import-Module (Join-Path $repoRoot 'src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -PassThru -DisableNameChecking -ErrorAction Stop
        $moduleCount = @(Get-Command -Module $module.Name -CommandType Function).Count
        Remove-Module $module.Name -Force -ErrorAction SilentlyContinue
    }
    catch {
        $importError = $_.Exception.Message
    }

    if ($null -eq $moduleCount) {
        # Importing loads no TwinCAT DLL (TwinCAT.Ads.dll is loaded lazily), so a failed import
        # is a real defect on any machine, with or without TwinCAT.
        Add-CheckResult 'cmdlets' 'FAIL' "module import failed: $importError"
    }
    else {
        $mismatch = New-Object System.Collections.Generic.List[string]
        $seen = New-Object System.Collections.Generic.List[string]
        foreach ($d in $docCounts) {
            $path = Join-Path $repoRoot $d.File
            if (-not (Test-Path -LiteralPath $path)) { $mismatch.Add("$($d.File): file missing"); continue }
            $text = [System.IO.File]::ReadAllText($path, $utf8)
            $m = [regex]::Match($text, $d.Pattern)
            if (-not $m.Success) { $mismatch.Add("$($d.File): pattern '$($d.Pattern)' not found"); continue }
            $n = [int]$m.Groups[1].Value
            $seen.Add("$($d.File)=$n")
            if ($n -ne $moduleCount) { $mismatch.Add("$($d.File) says $n, module exports $moduleCount") }
        }
        if ($mismatch.Count -eq 0) {
            Add-CheckResult 'cmdlets' 'PASS' "$moduleCount exported; $($seen -join ', ')"
        }
        else {
            Add-CheckResult 'cmdlets' 'FAIL' "documented cmdlet count differs from the module ($moduleCount)" $mismatch
        }
    }
}
catch {
    Add-CheckResult 'cmdlets' 'FAIL' "check crashed: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# banned wording: a UmRT has no version of its own
# ---------------------------------------------------------------------------
try {
    # Built from char codes so that this script stays ASCII.
    $fwOpen = [string][char]0xFF08; $fwClose = [string][char]0xFF09
    $zhFileVersion = -join [char[]](0x6A94, 0x6848, 0x7248, 0x672C)   # zh-TW "file version"
    $bannedPatterns = @(
        # UmRT 4026 / UmRT (4026) / UmRT v4026 / UmRT 3.1.4026 / UmRT-4026
        "UmRT[\s(\[${fwOpen}_\-]*v?(?:3\.1\.)?40\d\d",
        # 4026 UmRT / 3.1.4026.21 UmRT / (4026) UmRT / a 4026 UmRT
        "40\d\d(?:\.\d+)*[)\]$fwClose]?\s*UmRT"
    )
    $banned = New-Object System.Text.RegularExpressions.Regex(($bannedPatterns -join '|'), 'IgnoreCase')
    # The file version of TcSystemServiceUm.exe may be written; a hit is allowed only when it
    # overlaps such a phrase, e.g. "TcSystemServiceUm.exe file version 3.1.4026.21".
    $allowed = New-Object System.Text.RegularExpressions.Regex(
        "TcSystemServiceUm\.exe\s*(?:file\s*version|FileVersion|ProductVersion|$zhFileVersion)\s*v?[\d.]+", 'IgnoreCase')
    $selfPath = (Resolve-Path -LiteralPath $PSCommandPath).ProviderPath
    $textFiles = @(Get-RepoFiles -Root $repoRoot -Extensions @('.md', '.ps1', '.psm1', '.psd1', '.js', '.mjs', '.json', '.yaml', '.yml'))
    $hits = New-Object System.Collections.Generic.List[string]
    foreach ($f in $textFiles) {
        if ($f -eq $selfPath) { continue }
        $lines = [System.IO.File]::ReadAllLines($f, $utf8)
        for ($i = 0; $i -lt $lines.Length; $i++) {
            $line = $lines[$i]
            $okSpans = @($allowed.Matches($line))
            foreach ($m in $banned.Matches($line)) {
                $covered = $false
                foreach ($a in $okSpans) {
                    if ($m.Index -lt ($a.Index + $a.Length) -and $a.Index -lt ($m.Index + $m.Length)) { $covered = $true; break }
                }
                if (-not $covered) { $hits.Add(('{0}:{1} "{2}"' -f (Get-RelativePath $f), ($i + 1), $m.Value)) }
            }
        }
    }
    if ($hits.Count -eq 0) {
        Add-CheckResult 'wording' 'PASS' "$($textFiles.Count) files, no UmRT version wording"
    }
    else {
        $n = $hits.Count
        $hits.Add('UmRT has no version of its own (user-mode instance of the local TwinCAT runtime); write the TwinCAT / XAE version or "TcSystemServiceUm.exe file version x.y.z" instead')
        Add-CheckResult 'wording' 'FAIL' "$n banned wording hit(s)" $hits
    }
}
catch {
    Add-CheckResult 'wording' 'FAIL' "check crashed: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# help: every exported cmdlet has readable comment-based help (Synopsis + parameter descriptions)
# ---------------------------------------------------------------------------
try {
    $helpModule = Import-Module (Join-Path $repoRoot 'src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -PassThru -DisableNameChecking -ErrorAction Stop
    $common = @([System.Management.Automation.PSCmdlet]::CommonParameters) + @([System.Management.Automation.PSCmdlet]::OptionalCommonParameters)
    $helpProblems = New-Object System.Collections.Generic.List[string]
    $helpCommands = @(Get-Command -Module $helpModule.Name -CommandType Function)
    foreach ($cmd in $helpCommands) {
        $help = Get-Help $cmd.Name -Full -ErrorAction Stop
        $synopsis = ([string]$help.Synopsis).Trim()
        # without readable help, Get-Help puts the syntax line ("Name [-Param] ...") into Synopsis
        if ([string]::IsNullOrWhiteSpace($synopsis) -or $synopsis.StartsWith($cmd.Name)) {
            $helpProblems.Add("$($cmd.Name): no readable comment-based help (Synopsis empty; a help line starting with '.' breaks the whole block)")
            continue
        }
        foreach ($pn in @($cmd.Parameters.Keys | Where-Object { $common -notcontains $_ })) {
            $ph = @($help.parameters.parameter) | Where-Object { $_.name -eq $pn } | Select-Object -First 1
            $desc = if ($null -ne $ph) { (@($ph.description) | ForEach-Object { $_.Text }) -join '' } else { '' }
            if ([string]::IsNullOrWhiteSpace($desc)) { $helpProblems.Add("$($cmd.Name) -$($pn): no .PARAMETER description") }
        }
    }
    Remove-Module $helpModule.Name -Force -ErrorAction SilentlyContinue
    if ($helpProblems.Count -eq 0) {
        Add-CheckResult 'help' 'PASS' "$($helpCommands.Count) cmdlets, each with a Synopsis and parameter descriptions"
    }
    else {
        Add-CheckResult 'help' 'FAIL' "$($helpProblems.Count) comment-based help problem(s)" $helpProblems
    }
}
catch {
    Add-CheckResult 'help' 'FAIL' "check crashed: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# error codes: every $script:TcErrorHints key has a heading in docs/troubleshooting.md
# ---------------------------------------------------------------------------
try {
    $hintFile = Join-Path $repoRoot 'src\TwinCATAutomation\Private\ConvertTo-TcAdsErrorCode.ps1'
    $tsFile = Join-Path $repoRoot 'docs\troubleshooting.md'
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($hintFile, [ref]$tokens, [ref]$errors)
    $keys = New-Object System.Collections.Generic.List[string]
    $assignments = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)
    foreach ($as in $assignments) {
        $left = $as.Left.Extent.Text
        if ($left -eq '$script:TcErrorHints' -and $as.Right.Expression -is [System.Management.Automation.Language.HashtableAst]) {
            foreach ($kv in $as.Right.Expression.KeyValuePairs) { $keys.Add($kv.Item1.Extent.Text.Trim("'", '"')) }
        }
        elseif ($left -match "^\`$script:TcErrorHints\[\s*['""]([A-Z0-9_]+)['""]\s*\]") {
            $keys.Add($Matches[1])
        }
    }
    $keys = @($keys | Sort-Object -Unique)
    if ($keys.Count -eq 0) { throw "no `$script:TcErrorHints keys found in $(Get-RelativePath $hintFile)" }
    $headings = @([System.IO.File]::ReadAllLines($tsFile, $utf8) | Where-Object { $_ -match '^#{2,4}\s' }) -join "`n"
    $missing = @($keys | Where-Object { $headings -notmatch ('(?<![A-Z0-9_])' + [regex]::Escape($_) + '(?![A-Z0-9_])') })
    if ($missing.Count -eq 0) {
        Add-CheckResult 'errorcodes' 'PASS' "$($keys.Count) hint keys, each has a heading in docs/troubleshooting.md"
    }
    else {
        Add-CheckResult 'errorcodes' 'FAIL' "$($missing.Count) `$script:TcErrorHints key(s) without a docs/troubleshooting.md heading (add a ### section)" $missing
    }
}
catch {
    Add-CheckResult 'errorcodes' 'FAIL' "check crashed: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# mcp-server/tools.json in sync with Export-ToolSchema.ps1
# ---------------------------------------------------------------------------
try {
    $toolsJson = Join-Path $repoRoot 'mcp-server\tools.json'
    $exportScript = Join-Path $repoRoot 'mcp-server\scripts\Export-ToolSchema.ps1'
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("tools-check-{0}.json" -f [guid]::NewGuid().ToString('N'))
    try {
        $r = Invoke-Native 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $exportScript, '-OutPath', $tmp)
        if ($r.Code -ne 0 -or -not (Test-Path -LiteralPath $tmp)) {
            Add-CheckResult 'tools.json' 'FAIL' "Export-ToolSchema.ps1 failed (exit $($r.Code))" @($r.Output | Select-Object -Last 15)
        }
        else {
            $normalize = {
                param([string]$s)
                ($s -replace '"generatedAt"\s*:\s*"[^"]*"', '' -replace "`r`n", "`n").TrimEnd()
            }
            $fresh = & $normalize ([System.IO.File]::ReadAllText($tmp, $utf8))
            $committed = & $normalize ([System.IO.File]::ReadAllText($toolsJson, $utf8))
            if ($fresh -ceq $committed) {
                Add-CheckResult 'tools.json' 'PASS' 'matches Export-ToolSchema.ps1 output'
            }
            else {
                $fl = $fresh -split "`n"; $cl = $committed -split "`n"
                $first = 0
                while ($first -lt [Math]::Min($fl.Length, $cl.Length) -and $fl[$first] -ceq $cl[$first]) { $first++ }
                Add-CheckResult 'tools.json' 'FAIL' 'mcp-server/tools.json is stale: run "npm run generate-tools" in mcp-server and commit tools.json' @(
                    "first difference at line $($first + 1)",
                    ("  committed: " + $(if ($first -lt $cl.Length) { $cl[$first].Trim() } else { '<eof>' })),
                    ("  generated: " + $(if ($first -lt $fl.Length) { $fl[$first].Trim() } else { '<eof>' }))
                )
            }
        }
    }
    finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}
catch {
    Add-CheckResult 'tools.json' 'FAIL' "check crashed: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# unit: tests/Unit/*.ps1 (no IDE / runtime; exit code = number of failed checks, #43)
# ---------------------------------------------------------------------------
if ($Fast) {
    Add-CheckResult 'unit' 'SKIP' '-Fast'
}
else {
    try {
        $unitFiles = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'tests\Unit') -Filter '*.ps1' | Sort-Object Name)
        if ($unitFiles.Count -eq 0) { throw 'no tests/Unit/*.ps1 found' }
        $unitTimeoutMs = 300000
        $unitFailed = New-Object System.Collections.Generic.List[string]
        $unitLines = New-Object System.Collections.Generic.List[string]
        foreach ($uf in $unitFiles) {
            # Own process per file (each imports the module with its own mocks). Output goes to
            # files: reading redirected pipes synchronously can dead-lock on a full buffer.
            $outFile = Join-Path ([IO.Path]::GetTempPath()) ("unit-{0}.out" -f [guid]::NewGuid().ToString('N'))
            $errFile = "$outFile.err"
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $p = Start-Process -FilePath 'powershell.exe' -PassThru -NoNewWindow -WorkingDirectory $repoRoot `
                -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
                -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$($uf.FullName)`"")
            # Windows PowerShell 5.1: without a handle taken while the process runs, ExitCode of a
            # Start-Process -PassThru object reads back as $null after the exit.
            $null = $p.Handle
            try {
                $done = $p.WaitForExit($unitTimeoutMs)
                $killed = $true
                if (-not $done) {
                    try { $p.Kill() } catch { }
                    # bounded: a process that does not die after Kill must not hang the check
                    $killed = $p.WaitForExit(10000)
                }
                $code = if ($done) { $p.ExitCode } else { -1 }
                if (-not $killed) { $unitLines.Add("$($uf.Name): still running 10 s after Kill (pid $($p.Id))") }
                $out = @()
                foreach ($f in @($outFile, $errFile)) { if (Test-Path -LiteralPath $f) { $out += @(Get-Content -LiteralPath $f) } }
                # "failed: N" is printed by most of them; exit 0 is what counts
                $failLine = @($out | Where-Object { $_ -match '^failed:\s*\d+' } | Select-Object -Last 1)
                $secs = [int]$sw.Elapsed.TotalSeconds
                if ($code -eq 0 -and -not ($failLine.Count -gt 0 -and $failLine[0] -notmatch '^failed:\s*0\s*$')) {
                    $unitLines.Add("$($uf.Name): ok ($secs s)")
                }
                else {
                    $why = if (-not $done) { "timeout after $($unitTimeoutMs / 1000) s" } else { "exit $code" }
                    $unitFailed.Add($uf.Name)
                    $unitLines.Add("$($uf.Name): $why ($secs s)")
                    foreach ($l in @($out | Where-Object { $_ -match '^\s*FAIL\b' } | Select-Object -First 10)) { $unitLines.Add("  $l") }
                    foreach ($l in @($out | Select-Object -Last 5)) { $unitLines.Add("  | $l") }
                }
            }
            finally {
                $p.Dispose()
                Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
            }
        }
        if ($unitFailed.Count -eq 0) {
            Add-CheckResult 'unit' 'PASS' "$($unitFiles.Count) tests/Unit scripts, exit 0" @($unitLines)
        }
        else {
            Add-CheckResult 'unit' 'FAIL' "$($unitFailed.Count) of $($unitFiles.Count) tests/Unit scripts failed: $($unitFailed -join ', ')" @($unitLines)
        }
    }
    catch {
        Add-CheckResult 'unit' 'FAIL' "check crashed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# npm test (mcp-server)
# ---------------------------------------------------------------------------
if ($Fast) {
    Add-CheckResult 'npm test' 'SKIP' '-Fast'
}
else {
    $mcpDir = Join-Path $repoRoot 'mcp-server'
    $npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if (-not $npm) {
        Add-CheckResult 'npm test' 'FAIL' 'npm not found on PATH (install Node.js >= 22 (package.json engines), or run with -Fast)'
    }
    else {
        Push-Location $mcpDir
        try {
            $installed = ''
            $ok = $true
            if (-not (Test-Path -LiteralPath (Join-Path $mcpDir 'node_modules'))) {
                $ci = Invoke-Native $npm.Source @('ci', '--no-audit', '--no-fund')
                if ($ci.Code -ne 0) {
                    $ok = $false
                    Add-CheckResult 'npm test' 'FAIL' "npm ci failed (exit $($ci.Code))" @($ci.Output | Select-Object -Last 15)
                }
                $installed = ' (after npm ci)'
            }
            if ($ok) {
                $t = Invoke-Native $npm.Source @('test')
                $summary = @($t.Output | Where-Object { $_ -match '^# (tests|pass|fail|skipped|todo) \d+' } | ForEach-Object { $_.TrimStart('#', ' ') }) -join ', '
                if ($t.Code -eq 0) {
                    Add-CheckResult 'npm test' 'PASS' "$summary$installed"
                }
                else {
                    $failing = @($t.Output | Where-Object { $_ -match '^\s*not ok ' } | Select-Object -First 20)
                    Add-CheckResult 'npm test' 'FAIL' "exit $($t.Code); $summary" ($failing + @('--- last 15 lines ---') + @($t.Output | Select-Object -Last 15))
                }
            }
        }
        catch {
            Add-CheckResult 'npm test' 'FAIL' "check crashed: $($_.Exception.Message)"
        }
        finally {
            Pop-Location
        }
    }
}

# ---------------------------------------------------------------------------
$failed = @($results | Where-Object { $_.Status -eq 'FAIL' })
$passed = @($results | Where-Object { $_.Status -eq 'PASS' })
$skipped = @($results | Where-Object { $_.Status -eq 'SKIP' })
Write-Host ''
$mode = if ($Strict) { ' (strict: SKIP fails)' } else { '' }
$line = "check: $($passed.Count) passed, $($failed.Count) failed, $($skipped.Count) skipped$mode"
$bad = @($failed)
if ($Strict) { $bad += $skipped }
if ($bad.Count -gt 0) {
    Write-Host "$line -> FAIL ($(@($bad | ForEach-Object { $_.Name }) -join ', '))" -ForegroundColor Red
    exit 1
}
Write-Host "$line -> OK" -ForegroundColor Green
exit 0
