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
      generics    No New-Object of a System.Collections.Generic.* type in src/ and mcp-server/ *.ps1 / *.psm1
                  (AST based; "New-Object $type" is rejected too). Measured 2026-10-28, PS 5.1.26100.9711:
                  @() on a New-Object List[object] throws ArgumentException; use [System.Collections.Generic.List[...]]::new() (#75).
      functions   Every top-level function name in src/TwinCATAutomation *.ps1 / *.psm1 is unique
                  (the module dot-sources all files; a later definition silently replaces an earlier one, #30).
      forbidden   #68: no hardcoded AmsNetId literal, StartRestartTwinCAT, ExecuteCommand or
                  WriteControl(Async) in the code (strings included, comments / help ignored) of
                  src/, mcp-server/ (.ps1 .psm1 .js .mjs, not mcp-server/test/) and
                  tests/Integration/*.ps1, except where a marker COMMENT
                  "tcauto-allow(<rule>): <reason>" names the rule
                  (scripts/forbidden-patterns.ps1; tests/Unit/forbidden-lint.ps1 proves it hits).
                  Also lists the tcauto-allow markers added relative to origin/master (for review;
                  skipped without failing when origin/master cannot be diffed).
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
                  (line endings ignored; the file has no timestamp, #25).
      adapters    The action names of adapters/codex/tools.json and adapters/antigravity/plugin.yaml equal the keys of
                  $operationMap in Invoke-TwinCATAutomation.ps1 (the single source of the CLI actions, #144).
      gendocs     scripts/Update-GeneratedDocs.ps1 -Check: the cmdlet / MCP tool / composite counts and the
                  SKILL.md signature table inside <!-- generated:... --> markers (README*, CLAUDE.md,
                  AGENTS.md, SKILL.md, docs/setup-mcp.md, mcp-server/README.md, docs/known-limitations.md) equal what the code gives (#25), and the two adapter files
                  adapters/codex/tools.json, adapters/antigravity/plugin.yaml are the generated output (#144).
      unit        every tests/Unit/*.ps1 in its own powershell.exe (no IDE / runtime needed):
                  PASS when each exits 0 (and its "failed: N" line, if any, says 0); a script
                  that runs longer than 300 s is killed and fails. Skipped with -Fast (#43).
                  #240: up to -UnitParallel scripts run at the same time (default = CPU count, max 4);
                  the timing-sensitive ones (list $unitSerial) run alone afterwards. Each script's
                  output is collected separately and printed as one block, in file order.
                  #118: each script runs with its own empty TCAUTO_STATE_DIR (removed afterwards)
                  and TCAUTO_TEST_FORBID_REAL_STATE=1, must dot-source tests/Unit/lib/UnitIsolation.ps1
                  before its first Import-Module, and fails when the module printed
                  TCAUTO_REAL_STATE_REFUSED (it tried to use the real %TEMP% / %LOCALAPPDATA% state).
      npm test    mcp-server unit tests (npm ci first when node_modules is missing), with an isolated
                  TCAUTO_STATE_DIR and TCAUTO_TEST_FORBID_REAL_STATE=1 (#118). Skipped with -Fast.
    Exit code 0 when nothing failed, 1 otherwise. SKIP never counts as PASS; with -Strict a
    SKIP fails the run as well.

    The checks read the WORKING TREE, not the git index.

.PARAMETER Fast
    Skip unit and npm test (used by the pre-commit hook).
.PARAMETER Strict
    Treat SKIP as a failure (used by CI).
.PARAMETER SkipNpmTest
    #253: leave out the npm test section (no result line, so -Strict does not fail on it). CI runs
    npm test in its own parallel job; the default run (and -Fast) is unchanged.
.PARAMETER UnitParallel
    #240: how many tests/Unit scripts run at the same time. 0 (default) = env TCAUTO_CHECK_UNIT_PARALLEL
    when set, else the CPU count, at most 4. 1 = the old sequential run.

.EXAMPLE
    powershell.exe -NoProfile -File scripts/check.ps1 -Strict

    Prerequisite: Windows PowerShell must be allowed to run local scripts. The checks start
    powershell.exe children WITHOUT -ExecutionPolicy Bypass; when the effective policy is Restricted
    or AllSigned this script stops first with:
        Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
    (or, when a group policy sets it, with a note to ask IT: Set-ExecutionPolicy cannot override it, #144).
#>
[CmdletBinding()]
param(
    [switch]$Fast,
    [switch]$Strict,
    [switch]$SkipNpmTest,
    [int]$UnitParallel = 0
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Preflight (#25): children start without -ExecutionPolicy Bypass, so a Restricted / AllSigned
# Windows PowerShell would fail them with a bare SecurityError. Stop with the fix instead.
# #144: a group policy (MachinePolicy / UserPolicy) wins over Set-ExecutionPolicy -Scope CurrentUser,
# so for it the advice is "ask IT" (scripts/lib/ExecutionPolicy.ps1, unit-tested).
. (Join-Path $PSScriptRoot 'lib\ExecutionPolicy.ps1')
$tcPolicyLines = @((& powershell.exe -NoProfile -Command $script:TcPolicyCommand) | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
$tcPolicy = if ($tcPolicyLines.Count -gt 0) { $tcPolicyLines[0] } else { '' }
$tcPolicyAdvice = Get-TcPolicyAdvice -Effective $tcPolicy -ListLines @($tcPolicyLines | Select-Object -Skip 1)
if (-not $tcPolicy) {
    Write-Host 'FAIL  policy      could not read the Windows PowerShell execution policy (powershell.exe -NoProfile -Command Get-ExecutionPolicy printed nothing)' -ForegroundColor Red
    exit 1
}
if ($tcPolicyAdvice) {
    Write-Host "FAIL  policy      $tcPolicyAdvice" -ForegroundColor Red
    exit 1
}

# The parse check is only meaningful with the 5.1 parser: re-run under Windows PowerShell.
if ($PSVersionTable.PSEdition -eq 'Core') {
    $argsList = @('-NoProfile', '-File', $PSCommandPath)
    if ($Fast) { $argsList += '-Fast' }
    if ($Strict) { $argsList += '-Strict' }
    if ($SkipNpmTest) { $argsList += '-SkipNpmTest' }
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

# Failure details of a failed npm test run (#98 / #64), for the FAIL lines:
#   TAP (Node 22): the YAML block (error, stack) after every 'not ok' of a test (suites that only
#     failed because a subtest did are skipped), then every '[diag]' diagnostic line of the tests;
#   spec (Node 24): everything from the 'failing tests:' summary on (it carries error and stack).
# Bounded (400 lines in all) so a run with many failures stays readable.
# Returns @{ Lines = string[]; HasSpecSummary = bool } (the spec summary already ends the output,
# so the caller then skips its 'last 15 lines').
function Get-NpmTestFailureDetail {
    param([string[]]$Lines)
    $maxLines = 400
    $out = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $Lines.Count -and $out.Count -lt 300; $i++) {
        if ($Lines[$i] -notmatch '^(\s*)not ok ') { continue }
        $block = [System.Collections.Generic.List[string]]::new()
        $block.Add($Lines[$i])
        if ($i + 1 -lt $Lines.Count -and $Lines[$i + 1].Trim() -eq '---') {
            for ($j = $i + 1; $j -lt $Lines.Count -and $block.Count -lt 60; $j++) {
                $block.Add($Lines[$j])
                if ($j -gt $i + 1 -and $Lines[$j].Trim() -eq '...') { break }
            }
        }
        if (@($block | Where-Object { $_ -match "failureType: 'subtestsFailed'" }).Count -gt 0) { continue }
        $out.AddRange($block)
    }
    $diag = @($Lines | Where-Object { $_ -match '\[diag\]' } | Select-Object -First 200)
    foreach ($d in $diag) { $out.Add($d) }
    # The marker glyph before 'failing tests:' is not matched: under a zh-TW console (cp950) it
    # does not survive the native output decoding.
    $specStart = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) { if ($Lines[$i] -match 'failing tests:\s*$') { $specStart = $i; break } }
    # The spec section is cut in the middle (its head and its tail are kept: the tail holds the
    # last failure); the TAP / diag part gets what is left of the 400 lines.
    $spec = @()
    if ($specStart -ge 0) {
        $spec = @($Lines[$specStart..($Lines.Count - 1)])
        if ($spec.Count -gt 200) { $spec = @($spec[0..149]) + @("... ($($spec.Count - 200) spec summary lines cut)") + @($spec[($spec.Count - 50)..($spec.Count - 1)]) }
    }
    $room = $maxLines - $spec.Count
    $head = @($out.ToArray() | Select-Object -First $room)
    if ($out.Count -gt $room) { $head += "... ($($out.Count - $room) more failure-detail lines cut)" }
    return @{ Lines = @($head + $spec); HasSpecSummary = ($specStart -ge 0) }
}

# ---------------------------------------------------------------------------
# parse (Windows PowerShell 5.1 parser)
# ---------------------------------------------------------------------------
$psFiles = @()
$parsedAsts = @{}
try {
    $psFiles = @(Get-RepoFiles -Root $repoRoot -Extensions @('.ps1', '.psm1', '.psd1') | Sort-Object)
    $parseErrors = New-Object System.Collections.Generic.List[string]
    foreach ($f in $psFiles) {
        $tokens = $null; $errors = $null
        $parsedAsts[$f] = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tokens, [ref]$errors)
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
# generics: no New-Object for System.Collections.Generic.* in src/ and mcp-server/ *.ps1 / *.psm1
# (#75). Measured 2026-10-28, Windows PowerShell 5.1.26100.9711: @() around a List[object]
# built with New-Object throws ArgumentException ("Argument types do not match");
# [List[object]]::new() does not. AST based: only real New-Object commands are looked at
# (comments and strings that merely mention the name never hit). Every argument of the command
# is checked for "Collections.Generic." (-TypeName:, -Type, 'System.' omitted, ("..."),
# -ArgumentList first, backtick continuation); in a file with
# "using namespace System.Collections.Generic" the bare names (List[..], Dictionary[..], ...)
# are rejected too; "New-Object $type" cannot be checked and is rejected as well.
# ---------------------------------------------------------------------------
try {
    $genericPattern = New-Object System.Text.RegularExpressions.Regex('Collections\.Generic\.', 'IgnoreCase')
    $genericBarePattern = New-Object System.Text.RegularExpressions.Regex('(^|[^\w.])(List|Dictionary|HashSet|Queue|Stack|SortedDictionary|SortedList|SortedSet|LinkedList|KeyValuePair|SynchronizedCollection)\s*\[', 'IgnoreCase')
    $genericHits = [System.Collections.Generic.List[string]]::new()
    $genericFiles = @($psFiles | Where-Object { (Get-RelativePath $_) -match '^(src|mcp-server)/' -and ($_ -like '*.ps1' -or $_ -like '*.psm1') })
    foreach ($f in $genericFiles) {
        $ast = $parsedAsts[$f]
        if ($null -eq $ast) { continue }
        $usesGenericNs = $false
        foreach ($u in @($ast.UsingStatements)) {
            if ($u.UsingStatementKind -eq 'Namespace' -and [string]$u.Name.Value -eq 'System.Collections.Generic') { $usesGenericNs = $true }
        }
        $commands = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'New-Object' }, $true)
        foreach ($cmd in $commands) {
            $typeArg = $null
            $positional = 0
            $allText = New-Object System.Text.StringBuilder
            $els = @($cmd.CommandElements)
            for ($i = 1; $i -lt $els.Count; $i++) {
                $el = $els[$i]
                [void]$allText.Append(' ').Append($el.Extent.Text)
                if ($el -is [System.Management.Automation.Language.CommandParameterAst]) {
                    $value = $el.Argument
                    if ($null -eq $value -and ($i + 1) -lt $els.Count) { $i++; $value = $els[$i]; [void]$allText.Append(' ').Append($value.Extent.Text) }
                    if ($el.ParameterName.Length -gt 0 -and 'TypeName'.StartsWith($el.ParameterName, [System.StringComparison]::OrdinalIgnoreCase)) { $typeArg = $value }
                }
                else {
                    if ($positional -eq 0 -and $null -eq $typeArg) { $typeArg = $el }
                    $positional++
                }
            }
            $text = $allText.ToString()
            $dynamic = ($typeArg -is [System.Management.Automation.Language.VariableExpressionAst])
            $typeText = if ($null -ne $typeArg) { $typeArg.Extent.Text } else { '' }
            if ($genericPattern.IsMatch($text) -or ($usesGenericNs -and $genericBarePattern.IsMatch($typeText)) -or $dynamic) {
                $why = if ($dynamic) { ' (type is a variable: cannot be checked, rewrite)' } else { '' }
                $genericHits.Add(('{0}:{1} {2}{3}' -f (Get-RelativePath $f), $cmd.Extent.StartLineNumber, ($cmd.Extent.Text -replace '\s+', ' ').Trim(), $why))
            }
        }
    }
    if ($genericHits.Count -eq 0) {
        Add-CheckResult 'generics' 'PASS' "$($genericFiles.Count) src/ + mcp-server/ .ps1/.psm1 files, no New-Object of a System.Collections.Generic type"
    }
    else {
        $n = $genericHits.Count
        $genericHits.Add('use [System.Collections.Generic.List[object]]::new() instead: measured 2026-10-28 (PS 5.1.26100.9711), @() around a New-Object List[object] throws ArgumentException and broke Get-TcBuildErrors permanently (#75)')
        Add-CheckResult 'generics' 'FAIL' "$n New-Object generic collection hit(s)" $genericHits
    }
}
catch {
    Add-CheckResult 'generics' 'FAIL' "check crashed: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# functions: every function name defined at the top level of src/TwinCATAutomation (*.ps1 / *.psm1)
# is unique. The .psm1 dot-sources Private\*.ps1 and Public\*.ps1 one after another, so a second
# definition with the same name silently replaces the first for the whole module (#30 review:
# Get-TcFileSha256 in InstallManifest.ps1 was overridden by the one in PlcOpen.ps1). Function names
# are case-insensitive; nested functions (inside another function) are not counted. Functions
# defined inside a script block that is not itself inside a function (e.g. the body handed to a
# background runspace) ARE counted on purpose: they are top-level in the runspace that runs them and
# the same name rule keeps them from being confused with a module function.
# ---------------------------------------------------------------------------
try {
    $fnFiles = @($psFiles | Where-Object { (Get-RelativePath $_) -match '^src/TwinCATAutomation/' -and ($_ -like '*.ps1' -or $_ -like '*.psm1') })
    $fnDefs = @{}
    foreach ($f in $fnFiles) {
        $ast = $parsedAsts[$f]
        if ($null -eq $ast) { continue }
        $defs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        foreach ($d in $defs) {
            $outer = $d.Parent
            $nested = $false
            while ($null -ne $outer) {
                if ($outer -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $nested = $true; break }
                $outer = $outer.Parent
            }
            if ($nested) { continue }
            $key = $d.Name.ToLowerInvariant()
            if (-not $fnDefs.ContainsKey($key)) { $fnDefs[$key] = [System.Collections.Generic.List[string]]::new() }
            $fnDefs[$key].Add(('{0}:{1}' -f (Get-RelativePath $f), $d.Extent.StartLineNumber))
        }
    }
    $dupHits = [System.Collections.Generic.List[string]]::new()
    foreach ($k in ($fnDefs.Keys | Sort-Object)) {
        if ($fnDefs[$k].Count -gt 1) { $dupHits.Add(('{0}: {1}' -f $k, ($fnDefs[$k] -join ', '))) }
    }
    if ($dupHits.Count -eq 0) {
        Add-CheckResult 'functions' 'PASS' "$($fnDefs.Count) top-level functions in $($fnFiles.Count) src/TwinCATAutomation files, no duplicate name"
    }
    else {
        $n = $dupHits.Count
        $dupHits.Add('rename one of them: the module dot-sources every file, the definition loaded last wins everywhere')
        Add-CheckResult 'functions' 'FAIL' "$n function name(s) defined more than once in src/TwinCATAutomation" $dupHits
    }
}
catch {
    Add-CheckResult 'functions' 'FAIL' "check crashed: $($_.Exception.Message)"
}
# ---------------------------------------------------------------------------
# forbidden: fail-closed fallbacks and hardcoded AmsNetIds (#68), scripts/forbidden-patterns.ps1
# ---------------------------------------------------------------------------
try {
    . (Join-Path $scriptDir 'forbidden-patterns.ps1')
    $fbFiles = @(Get-RepoFiles -Root $repoRoot -Extensions @('.ps1', '.psm1', '.js', '.mjs') | Where-Object { Test-TcForbiddenScope (Get-RelativePath $_) } | Sort-Object)
    $fbHits = @(Find-TcForbiddenPattern -Files $fbFiles -Root $repoRoot)
    $fbBad = @($fbHits | Where-Object { -not $_.Allowed })
    $fbOk = @($fbHits | Where-Object { $_.Allowed })
    # markers added relative to origin/master (information for the reviewer, never a failure)
    $newMarkers = [System.Collections.Generic.List[string]]::new()
    $markerNote = $null
    try {
        $d = Invoke-Native 'git' @('-C', $repoRoot, 'diff', '--unified=0', '--no-color', 'origin/master', '--', 'src', 'mcp-server', 'tests/Integration')
        if ($d.Code -ne 0) { $markerNote = "markers added since origin/master: skipped (git diff exit $($d.Code))" }
        else {
            $curFile = $null
            foreach ($l in $d.Output) {
                if ($l -match '^\+\+\+ b/(.+)$') { $curFile = $Matches[1]; continue }
                if ($l -match '^\+(?!\+\+)' -and $l -match 'tcauto-allow\(') { $newMarkers.Add(("{0}: {1}" -f $curFile, $l.Substring(1).Trim())) }
            }
            $markerNote = "markers added since origin/master: $($newMarkers.Count)"
        }
    }
    catch { $markerNote = "markers added since origin/master: skipped ($($_.Exception.Message))" }
    $markerLines = @($markerNote) + @($newMarkers | ForEach-Object { "  + $_" })
    if ($fbBad.Count -eq 0) {
        Add-CheckResult 'forbidden' 'PASS' "$($fbFiles.Count) files, no forbidden pattern ($($fbOk.Count) allowed by tcauto-allow marker)" $markerLines
    }
    else {
        $lines = @($fbBad | ForEach-Object { '{0}:{1} [{2}] {3}: {4}' -f $_.File, $_.Line, $_.Rule, $_.Why, $(if ($_.Text.Length -gt 120) { $_.Text.Substring(0, 120) } else { $_.Text }) })
        $lines += 'a legitimate use needs "# tcauto-allow(<rule>): <reason>" on the line or on a comment-only line above it (adapters/claude-code/SKILL.md "Failure contract")'
        Add-CheckResult 'forbidden' 'FAIL' "$($fbBad.Count) forbidden pattern hit(s)" $lines
    }
}
catch {
    Add-CheckResult 'forbidden' 'FAIL' "check crashed: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# cmdlet count vs documentation
# ---------------------------------------------------------------------------
try {
    # U+6240 U+6709 U+6307 U+4EE4 U+FF08: the README.zh-TW heading (kept out of the source: this file is ASCII)
    $zhAllCommands = (@(0x6240, 0x6709, 0x6307, 0x4EE4, 0xFF08) | ForEach-Object { [string][char]$_ }) -join ''
    $docCounts = @(
        @{ File = 'CLAUDE.md'; Pattern = 'Available Commands \((?:<!--[^>]*-->)?(\d+)' },
        @{ File = 'AGENTS.md'; Pattern = 'Available Commands \((?:<!--[^>]*-->)?(\d+)' },
        @{ File = 'README.md'; Pattern = 'All Commands \((?:<!--[^>]*-->)?(\d+)' },
        @{ File = 'README.zh-TW.md'; Pattern = ($zhAllCommands + '(?:<!--[^>]*-->)?(\d+)') },
        @{ File = 'adapters/claude-code/SKILL.md'; Pattern = 'Cmdlet \S*\((?:<!--[^>]*-->)?(\d+)' }
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
            Add-CheckResult 'cmdlets' 'FAIL' "documented cmdlet count differs from the module ($moduleCount): run scripts/Update-GeneratedDocs.ps1" $mismatch
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
        $r = Invoke-Native 'powershell.exe' @('-NoProfile', '-File', $exportScript, '-OutPath', $tmp)
        if ($r.Code -ne 0 -or -not (Test-Path -LiteralPath $tmp)) {
            Add-CheckResult 'tools.json' 'FAIL' "Export-ToolSchema.ps1 failed (exit $($r.Code))" @($r.Output | Select-Object -Last 15)
        }
        else {
            $normalize = {
                param([string]$s)
                ($s -replace "`r`n", "`n").TrimEnd()
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
# gendocs: counts and the SKILL.md signature table are generated (#25)
# ---------------------------------------------------------------------------
try {
    $genScript = Join-Path $repoRoot 'scripts\Update-GeneratedDocs.ps1'
    $r = Invoke-Native 'powershell.exe' @('-NoProfile', '-File', $genScript, '-Check')
    $outText = @($r.Output) -join "`n"
    if ($r.Code -eq 0) {
        Add-CheckResult 'gendocs' 'PASS' (@($r.Output | Where-Object { $_ -match 'up to date' } | Select-Object -First 1) -join '')
    }
    elseif ($outText -match '(?m)^(STALE|PROBLEM)\b') {
        Add-CheckResult 'gendocs' 'FAIL' 'generated docs are stale: if a cmdlet parameter changed run "npm run generate-tools" in mcp-server first, then "powershell -NoProfile -File scripts/Update-GeneratedDocs.ps1"; commit the result' @($r.Output | Select-Object -Last 15)
    }
    else {
        Add-CheckResult 'gendocs' 'FAIL' "scripts/Update-GeneratedDocs.ps1 crashed (exit $($r.Code)), this is not a stale-docs result" @($r.Output | Select-Object -Last 15)
    }
}
catch {
    Add-CheckResult 'gendocs' 'FAIL' "check crashed: $($_.Exception.Message)"
}
# ---------------------------------------------------------------------------
# adapters: the action sets of the Codex / Antigravity adapters equal $operationMap (#144)
# ---------------------------------------------------------------------------
try {
    $cliText = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'Invoke-TwinCATAutomation.ps1'), [System.Text.Encoding]::UTF8)
    $mapBody = [regex]::Match($cliText, '\$operationMap\s*=\s*@\{(?<b>.*?)\n\}', 'Singleline').Groups['b'].Value
    $mapOps = @([regex]::Matches($mapBody, "(?m)^\s*'([A-Za-z0-9]+)'\s*=") | ForEach-Object { $_.Groups[1].Value })
    if ($mapOps.Count -eq 0) { throw 'no entries found in $operationMap of Invoke-TwinCATAutomation.ps1' }
    $codexOps = @((([System.IO.File]::ReadAllText((Join-Path $repoRoot 'adapters\codex\tools.json'), [System.Text.Encoding]::UTF8)) | ConvertFrom-Json).tools | ForEach-Object { [string]$_.name })
    $agOps = @([regex]::Matches([System.IO.File]::ReadAllText((Join-Path $repoRoot 'adapters\antigravity\plugin.yaml'), [System.Text.Encoding]::UTF8), '(?m)^  - name: (\S+)\s*$') | ForEach-Object { $_.Groups[1].Value })
    $diffs = New-Object System.Collections.Generic.List[string]
    foreach ($pair in @(@('adapters/codex/tools.json', $codexOps), @('adapters/antigravity/plugin.yaml', $agOps))) {
        foreach ($dup in @($pair[1] | Group-Object | Where-Object { $_.Count -gt 1 })) { $diffs.Add("$($pair[0]): action $($dup.Name) is listed $($dup.Count) times") }
        foreach ($n in @($mapOps | Where-Object { $pair[1] -cnotcontains $_ })) { $diffs.Add("$($pair[0]): missing action $n (in `$operationMap)") }
        foreach ($n in @($pair[1] | Where-Object { $mapOps -cnotcontains $_ })) { $diffs.Add("$($pair[0]): action $n is not in `$operationMap") }
    }
    if ($diffs.Count -eq 0) { Add-CheckResult 'adapters' 'PASS' "$($mapOps.Count) actions in `$operationMap, codex and antigravity" }
    else { Add-CheckResult 'adapters' 'FAIL' 'adapter action sets differ from $operationMap: run scripts/Update-GeneratedDocs.ps1 and commit the result' @($diffs | Select-Object -First 15) }
}
catch {
    Add-CheckResult 'adapters' 'FAIL' "check crashed: $($_.Exception.Message)"
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
        # #118 isolation rule: a script that imports the module dot-sources tests/Unit/lib/UnitIsolation.ps1
        # with -Caller $PSCommandPath and ends on "; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }"
        # BEFORE its first Import-Module (own process, own TCAUTO_STATE_DIR, TCAUTO_TEST_FORBID_REAL_STATE
        # when run directly).
        # Limits (text check, not AST): a line is compared after cutting at the first '#'; an
        # Import-Module inside a string, here-string or runspace script block counts as an import
        # (stricter, never looser); a module loaded another way (New-Module, & $psm1, using module)
        # is not seen. The runtime refusal (TCAUTO_REAL_STATE_REFUSED below) still covers those.
        foreach ($uf in $unitFiles) {
            $ulines = @(Get-Content -LiteralPath $uf.FullName)
            $imp = -1; $iso = -1
            for ($i = 0; $i -lt $ulines.Count; $i++) {
                $code = ($ulines[$i] -replace '#.*$', '')
                if ($iso -lt 0 -and $code -match '^\s*\.\s+\(Join-Path\s+\$PSScriptRoot\s+''lib\\UnitIsolation\.ps1''\)\s+-Caller\s+\$PSCommandPath\b.*;\s*if\s*\(\$null\s+-ne\s+\$TcUnitChildExit\)\s*\{\s*exit\s+\$TcUnitChildExit\s*\}') { $iso = $i }
                if ($imp -lt 0 -and $code -match '\bImport-Module\b') { $imp = $i }
            }
            if ($imp -ge 0 -and ($iso -lt 0 -or $iso -gt $imp)) {
                $unitFailed.Add($uf.Name)
                $unitLines.Add("$($uf.Name): imports the module without dot-sourcing lib\UnitIsolation.ps1 first (#118: its state would be the machine's real %TEMP%\TwinCATAutomation)")
            }
        }
        # #118: every script gets its own empty TCAUTO_STATE_DIR (inherited by the child) and the
        # module refuses the real state folders (TCAUTO_TEST_FORBID_REAL_STATE); removed afterwards.
        $unitStateRoot = Join-Path ([IO.Path]::GetTempPath()) ("tcauto-check-state-{0}" -f [guid]::NewGuid().ToString('N'))
        $savedStateDir = $env:TCAUTO_STATE_DIR
        $savedForbid = $env:TCAUTO_TEST_FORBID_REAL_STATE
        $env:TCAUTO_TEST_FORBID_REAL_STATE = '1'
        try {
            # #240: parallel width. -UnitParallel, else env TCAUTO_CHECK_UNIT_PARALLEL, else CPU count (max 4).
            $unitWidth = $UnitParallel
            if ($unitWidth -le 0 -and $env:TCAUTO_CHECK_UNIT_PARALLEL -match '^\d+$') { $unitWidth = [int]$env:TCAUTO_CHECK_UNIT_PARALLEL }
            if ($unitWidth -le 0) { $unitWidth = [Math]::Min(4, [Environment]::ProcessorCount) }
            $unitWidth = [Math]::Max(1, $unitWidth)
            # #240: scripts that assert a wall-clock bound (elapsed < N s, "answers at once", a real wait
            # >= N s) or poll a real file / process with a short deadline. Under busy siblings they can
            # miss the bound, so they run alone after the parallel group. Found 2026-11-12 by grepping
            # Stopwatch / $sec -lt / ElapsedMs assertions in tests/Unit.
            $unitSerial = @(
                'activate-timeout.ps1'               # timeout-at-deadline 3 s <= t < 14 s, worst-case bound
                'blocked-solution-ide.ps1'           # reset guard times out within 3.25 s / 8.25 s (#241: 1/4 time scale)
                'ide-solutions-lock.ps1'             # held mutex waited >= 1.5 s and < 30 s
                'issue-report-121.ps1'               # 15000-token regex < 2 s
                'launch-record-persist-73.ps1'       # restored record answers in < 5 s
                'lint-contract.ps1'                  # #252: 200 objects analysed in <= 2 s
                'lifecycle-receipt-113.ps1'          # 3000-line history check < 5 s
                'modal-scan-incomplete.ps1'          # UIA scan ms bounds, CLEAN_TIMEOUT < 15 s
                'platform-project-mismatch.ps1'      # waits up to 20 s for a helper process
                'project-save.ps1'                   # PROJECT_SAVE_TIMEOUT < 8 s
                'reset-reload-prompt.ps1'            # "fast" bounds of 5 - 6 s, timeout cases 2.25 - 3.25 s (#241: 1/4 time scale)
                'runtime-crashed.ps1'                # RuntimeCrashed < 1 s, timeout waits >= 0.475 s (#241: 1/4 time scale)
            )
            $unitResult = @{}
            # slowest first inside the parallel group so the long ones do not start last (the printed
            # result stays in file order).
            $unitSlowFirst = @('orphan-takeover-196.ps1', 'issue-report-78.ps1', 'install-manifest.ps1', 'connect-ide-pid-210.ps1', 'generated-docs.ps1', 'systemstate-diagnostics-194.ps1')
            $parallelFiles = @($unitFiles | Where-Object { $unitSerial -cnotcontains $_.Name } | Sort-Object { $i = [array]::IndexOf($unitSlowFirst, $_.Name); if ($i -lt 0) { 99 } else { $i } }, Name)
            $serialFiles = @($unitFiles | Where-Object { $unitSerial -ccontains $_.Name })

            # Starts one script; returns a job. Own process per file (each imports the module with its own
            # mocks). Output goes to files: reading redirected pipes synchronously can dead-lock on a full buffer.
            function Start-UnitJob {
                param($uf)
                $env:TCAUTO_STATE_DIR = Join-Path $unitStateRoot $uf.BaseName
                $null = New-Item -ItemType Directory -Path $env:TCAUTO_STATE_DIR -Force
                $outFile = Join-Path ([IO.Path]::GetTempPath()) ("unit-{0}.out" -f [guid]::NewGuid().ToString('N'))
                $errFile = "$outFile.err"
                $sw = [Diagnostics.Stopwatch]::StartNew()
                $p = Start-Process -FilePath 'powershell.exe' -PassThru -NoNewWindow -WorkingDirectory $repoRoot `
                    -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
                    -ArgumentList @('-NoProfile', '-File', "`"$($uf.FullName)`"")
                # Windows PowerShell 5.1: without a handle taken while the process runs, ExitCode of a
                # Start-Process -PassThru object reads back as $null after the exit.
                $null = $p.Handle
                return @{ File = $uf; Proc = $p; Sw = $sw; Out = $outFile; Err = $errFile }
            }

            # Collects the result of a finished (or timed-out) job into $unitResult[name] (lines) and $unitFailed.
            function Complete-UnitJob {
                param($job, [bool]$done)
                $uf = $job.File; $p = $job.Proc
                $lines = [System.Collections.Generic.List[string]]::new()
                try {
                    $killed = $true
                    if (-not $done) {
                        try { $p.Kill() } catch { }
                        # bounded: a process that does not die after Kill must not hang the check
                        $killed = $p.WaitForExit(10000)
                    }
                    $code = if ($done) { $p.ExitCode } else { -1 }
                    if (-not $killed) { $lines.Add("$($uf.Name): still running 10 s after Kill (pid $($p.Id))") }
                    $out = @()
                    foreach ($f in @($job.Out, $job.Err)) { if (Test-Path -LiteralPath $f) { $out += @(Get-Content -LiteralPath $f) } }
                    # "failed: N" is printed by most of them; exit 0 is what counts
                    $failLine = @($out | Where-Object { $_ -match '^failed:\s*\d+' } | Select-Object -Last 1)
                    $secs = [int]$job.Sw.Elapsed.TotalSeconds
                    # #118: the module printed this when the script tried to use the real state folder
                    $realState = @($out | Where-Object { $_ -match 'TCAUTO_REAL_STATE_REFUSED' } | Select-Object -First 3)
                    if ($realState.Count -gt 0) {
                        $unitFailed.Add($uf.Name)
                        $lines.Add("$($uf.Name): tried to use the real TcAuto state folder (#118)")
                        foreach ($l in $realState) { $lines.Add("  | $l") }
                    }
                    elseif ($code -eq 0 -and -not ($failLine.Count -gt 0 -and $failLine[0] -notmatch '^failed:\s*0\s*$')) {
                        $lines.Add("$($uf.Name): ok ($secs s)")
                    }
                    else {
                        $why = if (-not $done) { "timeout after $($unitTimeoutMs / 1000) s" } else { "exit $code" }
                        $unitFailed.Add($uf.Name)
                        $lines.Add("$($uf.Name): $why ($secs s)")
                        foreach ($l in @($out | Where-Object { $_ -match '^\s*FAIL\b' } | Select-Object -First 10)) { $lines.Add("  $l") }
                        foreach ($l in @($out | Select-Object -Last 5)) { $lines.Add("  | $l") }
                    }
                }
                finally {
                    $p.Dispose()
                    Remove-Item -LiteralPath $job.Out, $job.Err -Force -ErrorAction SilentlyContinue
                }
                $unitResult[$uf.Name] = $lines
            }

            # Runs $files with at most $width processes at once.
            function Invoke-UnitPool {
                param($files, [int]$width)
                $pending = [System.Collections.Generic.Queue[object]]::new()
                foreach ($f in $files) { $pending.Enqueue($f) }
                $running = [System.Collections.Generic.List[object]]::new()
                try {
                    while ($pending.Count -gt 0 -or $running.Count -gt 0) {
                        while ($pending.Count -gt 0 -and $running.Count -lt $width) { $running.Add((Start-UnitJob $pending.Dequeue())) }
                        $progressed = $false
                        foreach ($job in @($running)) {
                            $exited = $job.Proc.HasExited
                            if ($exited -or $job.Sw.ElapsedMilliseconds -gt $unitTimeoutMs) {
                                $null = $running.Remove($job)
                                Complete-UnitJob $job $exited
                                $progressed = $true
                            }
                        }
                        if (-not $progressed) { Start-Sleep -Milliseconds 200 }
                    }
                }
                finally {
                    # a crash of the check itself must not leave test processes behind
                    foreach ($job in @($running)) { try { $job.Proc.Kill() } catch { }; try { $job.Proc.Dispose() } catch { }; Remove-Item -LiteralPath $job.Out, $job.Err -Force -ErrorAction SilentlyContinue }
                }
            }

            Invoke-UnitPool $parallelFiles $unitWidth
            Invoke-UnitPool $serialFiles 1
            # one block per script, in file order (never interleaved)
            foreach ($uf in $unitFiles) { foreach ($l in @($unitResult[$uf.Name])) { $unitLines.Add($l) } }
            $unitLines.Add("(unit: $($parallelFiles.Count) scripts up to $unitWidth at a time, then $($serialFiles.Count) timing-sensitive scripts alone)")
        }
        finally {
            if ($null -eq $savedStateDir) { Remove-Item Env:\TCAUTO_STATE_DIR -ErrorAction SilentlyContinue } else { $env:TCAUTO_STATE_DIR = $savedStateDir }
            if ($null -eq $savedForbid) { Remove-Item Env:\TCAUTO_TEST_FORBID_REAL_STATE -ErrorAction SilentlyContinue } else { $env:TCAUTO_TEST_FORBID_REAL_STATE = $savedForbid }
            Remove-Item -LiteralPath $unitStateRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        $unitFailed = @($unitFailed | Select-Object -Unique)
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
if ($SkipNpmTest) {
    Write-Host 'npm test: left out by -SkipNpmTest (CI runs it in the separate npm-test job, #253)'
}
elseif ($Fast) {
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
        # #118: the bridge / fixture PowerShell children inherit an isolated state folder and the
        # refusal of the real one (a test that sets its own TCAUTO_STATE_DIR keeps it).
        $npmStateDir = Join-Path ([IO.Path]::GetTempPath()) ("tcauto-check-npm-state-{0}" -f [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $npmStateDir -Force
        $savedStateDir = $env:TCAUTO_STATE_DIR
        $savedForbid = $env:TCAUTO_TEST_FORBID_REAL_STATE
        $env:TCAUTO_STATE_DIR = $npmStateDir
        $env:TCAUTO_TEST_FORBID_REAL_STATE = '1'
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
                # TAP (Node 22): "# tests 212"; spec (Node 24): "<info glyph> tests 212" (the glyph is not matched:
                # under cp950 it decodes to "??", possibly without the space); a bare "tests N" line is no summary
                $summary = @($t.Output | ForEach-Object { if ($_ -match '^\S{1,4}\s*((?:tests|pass|fail|skipped|todo) \d+)\s*$') { $Matches[1] } }) -join ', '
                # #118: a bridge / fixture child that tried the real state folder (only lines that
                # reach npm's output: a test that swallows its child's stderr is not seen here)
                $realState = @($t.Output | Where-Object { "$_" -match 'TCAUTO_REAL_STATE_REFUSED' } | Select-Object -First 5)
                if ($realState.Count -gt 0) {
                    Add-CheckResult 'npm test' 'FAIL' "a test tried to use the real TcAuto state folder (#118); $summary" @($realState)
                }
                elseif ($t.Code -eq 0) {
                    Add-CheckResult 'npm test' 'PASS' "$summary$installed"
                }
                else {
                    $failing = @($t.Output | Where-Object { $_ -match '^\s*not ok ' } | Select-Object -First 20)
                    # #98 / #64: the TAP reporter (Node 22) puts the error of a failed test in the
                    # YAML block after its 'not ok' line and the test's own diagnostics in '[diag]'
                    # lines; the last 15 lines alone lost both, so a CI flake had no reason.
                    $details = Get-NpmTestFailureDetail -Lines $t.Output
                    $tail = if ($details.HasSpecSummary) { @() } else { @('--- last 15 lines ---') + @($t.Output | Select-Object -Last 15) }
                    Add-CheckResult 'npm test' 'FAIL' "exit $($t.Code); $summary" ($failing + @('--- failure details ---') + @($details.Lines) + $tail)
                }
            }
        }
        catch {
            Add-CheckResult 'npm test' 'FAIL' "check crashed: $($_.Exception.Message)"
        }
        finally {
            Pop-Location
            if ($null -eq $savedStateDir) { Remove-Item Env:\TCAUTO_STATE_DIR -ErrorAction SilentlyContinue } else { $env:TCAUTO_STATE_DIR = $savedStateDir }
            if ($null -eq $savedForbid) { Remove-Item Env:\TCAUTO_TEST_FORBID_REAL_STATE -ErrorAction SilentlyContinue } else { $env:TCAUTO_TEST_FORBID_REAL_STATE = $savedForbid }
            Remove-Item -LiteralPath $npmStateDir -Recurse -Force -ErrorAction SilentlyContinue
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
