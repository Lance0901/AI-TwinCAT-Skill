<#
.SYNOPSIS
    Repository guardrails: the mechanical checks every commit and every CI run must pass.

.DESCRIPTION
    Runs, in this order, and prints one PASS / FAIL / SKIP line per check:
      1. parse      Every *.ps1 / *.psm1 under src, tests, scripts, mcp-server/scripts and the
                    repo root parses with the Windows PowerShell 5.1 parser. PowerShell 7 only
                    syntax (??, ?., ternary, ...) is a parse error there, so this also blocks it.
      2. cmdlets    The number of cmdlets exported by the module equals the number written in
                    CLAUDE.md "Available Commands (N)", AGENTS.md "Available Commands (N)",
                    README.md "All Commands (N)" and adapters/claude-code/SKILL.md "Cmdlet ... (N)".
      3. wording    No banned wording in *.md / *.ps1 / *.psm1 / *.js / *.json / *.yaml: a UmRT
                    has no version of its own (it is the user-mode instance of the local TwinCAT
                    runtime, there is only one), so "UmRT <40xx>" / "<40xx> UmRT" are rejected.
                    The file version of TcSystemServiceUm.exe may be written (a line naming
                    "TcSystemServiceUm.exe" followed by "file version" is allowed).
      4. tools.json mcp-server/tools.json equals a fresh Export-ToolSchema.ps1 output
                    (generatedAt and line endings ignored).
      5. npm test   mcp-server unit tests (npm ci first when node_modules is missing).
                    Skipped with -Fast.
    Exit code 0 when nothing failed, 1 otherwise. SKIP never counts as PASS.

.PARAMETER Fast
    Skip npm test (used by the pre-commit hook).

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/check.ps1
#>
[CmdletBinding()]
param(
    [switch]$Fast
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# The parse check is only meaningful with the 5.1 parser: re-run under Windows PowerShell.
if ($PSVersionTable.PSEdition -eq 'Core') {
    $argsList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    if ($Fast) { $argsList += '-Fast' }
    & powershell.exe @argsList
    exit $LASTEXITCODE
}

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $scriptDir '..')).ProviderPath
$utf8 = New-Object System.Text.UTF8Encoding($false)

$results = New-Object System.Collections.Generic.List[object]
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
            if ($Extensions -contains [System.IO.Path]::GetExtension($f).ToLowerInvariant()) { $f }
        }
    }
}

# ---------------------------------------------------------------------------
# 1. parse (Windows PowerShell 5.1 parser)
# ---------------------------------------------------------------------------
try {
    $psFiles = @()
    foreach ($sub in @('src', 'tests', 'scripts', 'mcp-server\scripts')) {
        $p = Join-Path $repoRoot $sub
        if (Test-Path -LiteralPath $p) { $psFiles += @(Get-RepoFiles -Root $p -Extensions @('.ps1', '.psm1')) }
    }
    $psFiles += @([System.IO.Directory]::GetFiles($repoRoot, '*.ps1'))
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
# 2. cmdlet count vs documentation
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
        # Importing must not depend on TwinCAT (all DLL loading is lazy). Only when TwinCAT is
        # really absent is the failure reported as SKIP, never as PASS.
        if ([string]::IsNullOrWhiteSpace($env:TWINCAT3DIR)) {
            Add-CheckResult 'cmdlets' 'SKIP' "module import failed and no TwinCAT installed (TWINCAT3DIR unset): $importError"
        }
        else {
            Add-CheckResult 'cmdlets' 'FAIL' "module import failed: $importError"
        }
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
# 3. banned wording
# ---------------------------------------------------------------------------
try {
    $bannedPatterns = @(
        'UmRT\s*40\d\d',
        '40\d\d\s*UmRT',
        'a 40\d\d UmRT'
    )
    $banned = New-Object System.Text.RegularExpressions.Regex(($bannedPatterns -join '|'), 'IgnoreCase')
    # "TcSystemServiceUm.exe file version 3.1.4026.21" / "TcSystemServiceUm.exe <zh-TW: file version> ..."
    $allowed = New-Object System.Text.RegularExpressions.Regex('TcSystemServiceUm\.exe\s*(file version|檔案版本)', 'IgnoreCase')
    $selfPath = (Resolve-Path -LiteralPath $PSCommandPath).ProviderPath
    $textFiles = @(Get-RepoFiles -Root $repoRoot -Extensions @('.md', '.ps1', '.psm1', '.js', '.json', '.yaml', '.yml'))
    $hits = New-Object System.Collections.Generic.List[string]
    foreach ($f in $textFiles) {
        if ($f -eq $selfPath) { continue }
        $lines = [System.IO.File]::ReadAllLines($f, $utf8)
        for ($i = 0; $i -lt $lines.Length; $i++) {
            $m = $banned.Match($lines[$i])
            if ($m.Success -and -not $allowed.IsMatch($lines[$i])) {
                $hits.Add(('{0}:{1} "{2}"' -f (Get-RelativePath $f), ($i + 1), $m.Value))
            }
        }
    }
    if ($hits.Count -eq 0) {
        Add-CheckResult 'wording' 'PASS' "$($textFiles.Count) files, no UmRT version wording"
    }
    else {
        $hits.Add('UmRT has no version of its own (user-mode instance of the local TwinCAT runtime); write the TwinCAT / XAE version or "TcSystemServiceUm.exe file version x.y.z" instead')
        Add-CheckResult 'wording' 'FAIL' "$($hits.Count - 1) banned wording hit(s)" $hits
    }
}
catch {
    Add-CheckResult 'wording' 'FAIL' "check crashed: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# 4. mcp-server/tools.json in sync with Export-ToolSchema.ps1
# ---------------------------------------------------------------------------
try {
    $toolsJson = Join-Path $repoRoot 'mcp-server\tools.json'
    $exportScript = Join-Path $repoRoot 'mcp-server\scripts\Export-ToolSchema.ps1'
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("tools-check-{0}.json" -f [guid]::NewGuid().ToString('N'))
    try {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $exportScript -OutPath $tmp 2>&1
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tmp)) {
            Add-CheckResult 'tools.json' 'FAIL' "Export-ToolSchema.ps1 failed (exit $LASTEXITCODE)" @($out | ForEach-Object { "$_" } | Select-Object -Last 10)
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
# 5. npm test (mcp-server)
# ---------------------------------------------------------------------------
if ($Fast) {
    Add-CheckResult 'npm test' 'SKIP' '-Fast'
}
else {
    $mcpDir = Join-Path $repoRoot 'mcp-server'
    $npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if (-not $npm) {
        Add-CheckResult 'npm test' 'FAIL' 'npm not found on PATH (install Node.js >= 18, or run with -Fast)'
    }
    else {
        Push-Location $mcpDir
        try {
            $ciOut = $null
            if (-not (Test-Path -LiteralPath (Join-Path $mcpDir 'node_modules'))) {
                $ciOut = & $npm.Source ci --no-audit --no-fund 2>&1
                if ($LASTEXITCODE -ne 0) { throw ("npm ci failed (exit $LASTEXITCODE): " + (($ciOut | Select-Object -Last 5) -join ' | ')) }
            }
            $testOut = @(& $npm.Source test 2>&1 | ForEach-Object { "$_" })
            $code = $LASTEXITCODE
            $summary = @($testOut | Where-Object { $_ -match '^# (tests|pass|fail|skipped|todo) \d+' } | ForEach-Object { $_.TrimStart('#', ' ') }) -join ', '
            $installed = if ($ciOut) { ' (after npm ci)' } else { '' }
            if ($code -eq 0) {
                Add-CheckResult 'npm test' 'PASS' "$summary$installed"
            }
            else {
                $failing = @($testOut | Where-Object { $_ -match '^\s*not ok ' } | Select-Object -First 20)
                Add-CheckResult 'npm test' 'FAIL' "exit $code; $summary" ($failing + @($testOut | Select-Object -Last 15))
            }
        }
        catch {
            Add-CheckResult 'npm test' 'FAIL' $_.Exception.Message
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
$line = "check: $($passed.Count) passed, $($failed.Count) failed, $($skipped.Count) skipped"
if ($failed.Count -gt 0) {
    Write-Host "$line -> FAIL ($(@($failed | ForEach-Object { $_.Name }) -join ', '))" -ForegroundColor Red
    exit 1
}
Write-Host "$line -> OK" -ForegroundColor Green
exit 0
