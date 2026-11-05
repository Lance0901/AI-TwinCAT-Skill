<#
.SYNOPSIS
    Rewrites the generated parts of the docs (counts and the SKILL.md cmdlet signature table) (#25).

.DESCRIPTION
    Numbers and tables that follow from the code are not written by hand any more: parallel PRs
    that add a cmdlet or a tool used to conflict on every "81 cmdlets" sentence. Sources:
      cmdlet-count      exported functions of src/TwinCATAutomation/TwinCATAutomation.psm1
      mcp-tool-count    "tools" entries of mcp-server/tools.json (cmdlets offered over MCP)
      composite-count   entries of `export const composites = [...]` in mcp-server/lib/composites.js
      cmdlet-signatures SKILL.md table: cmdlet, MCP tool name, parameters (from Get-Command)

    Where the output goes (markers in the target file; everything outside them stays hand-written):
      * inline  <!-- generated:cmdlet-count -->81<!-- /generated -->
      * block   <!-- generated:cmdlet-signatures -->  ...table...  <!-- /generated -->
      * $patternRules below: counts inside a code fence, where an HTML comment would show up
        literally (the number is captured by the regex group `n`).
    Line endings and BOM of every file are kept.

    Default: rewrite the files. -Check: write nothing, list every stale spot, exit 1 when any
    (scripts/check.ps1 runs it that way). Not covered on purpose: adapters/codex/tools.json,
    adapters/antigravity/plugin.yaml and .agents/skills/twincat/SKILL.md (see the PR of #25:
    they describe the CLI actions of Invoke-TwinCATAutomation.ps1 / a hand-written lifecycle
    example, no list that follows from Get-Command).

.PARAMETER Check
    Report only; exit code 1 when a file differs from the generated output.
.PARAMETER DocsRoot
    Folder that holds the target files (default: the repository). For tests only: the sources
    (module, tools.json, composites.js) always come from this repository.
#>
[CmdletBinding()]
param([switch]$Check, [string]$DocsRoot)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $scriptDir '..')).ProviderPath
$utf8 = New-Object System.Text.UTF8Encoding($false)
if ([string]::IsNullOrWhiteSpace($DocsRoot)) { $DocsRoot = $repoRoot }

# Files that carry markers (relative paths). A marker in any other file is ignored.
$targets = @(
    'README.md', 'README.zh-TW.md', 'CLAUDE.md', 'AGENTS.md',
    'adapters/claude-code/SKILL.md', 'docs/setup-mcp.md', 'mcp-server/README.md'
)
# Counts that sit in a code fence: file, regex with named group n, value key.
$patternRules = @(
    @{ File = 'README.md'; Regex = 'Public/\s+# (?<n>\d+) exported cmdlets'; Key = 'cmdlet-count' },
    @{ File = 'README.zh-TW.md'; Regex = 'Public/\s+# (?<n>\d+) 個匯出的 cmdlet'; Key = 'cmdlet-count' }
)

# ---- sources -----------------------------------------------------------------------------------
$module = Import-Module (Join-Path $repoRoot 'src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -PassThru -DisableNameChecking -ErrorAction Stop
$commands = @(Get-Command -Module $module.Name -CommandType Function | Sort-Object Name)
$toolsDoc = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'mcp-server\tools.json'), $utf8) | ConvertFrom-Json
$toolByCmdlet = @{}
foreach ($t in $toolsDoc.tools) { $toolByCmdlet[[string]$t.cmdlet] = [string]$t.name }
$compositesJs = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'mcp-server\lib\composites.js'), $utf8)
$cm = [regex]::Match($compositesJs, 'export const composites = \[([^\]]*)\]')
if (-not $cm.Success) { throw 'composites.js: "export const composites = [...]" not found' }
$compositeConst = @($cm.Groups[1].Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$compositeCount = $compositeConst.Count
# composite tool -> public cmdlet that returns the same data: <Verb>-Tc<Rest> when the module has it
# (GetIdeModalDialog -> Get-TcIdeModalDialog); a composite without such a cmdlet is not listed.
$compositeByCmdlet = @{}
foreach ($cn in $compositeConst) {
    if ($cn -match '^(Get|Set|Add|Remove|Find|Test|Invoke|New|Clear|Enter|Exit|Connect|Disconnect)([A-Z].*)$' -and ($commands.Name -contains ('{0}-Tc{1}' -f $Matches[1], $Matches[2]))) { $compositeByCmdlet['{0}-Tc{1}' -f $Matches[1], $Matches[2]] = $cn }
}

$common = @([System.Management.Automation.PSCmdlet]::CommonParameters) + @([System.Management.Automation.PSCmdlet]::OptionalCommonParameters)
# one spelling per type: lower case, Object -> obj (everything else: the .NET name in lower case)
$typeNames = @{ String = 'string'; Int32 = 'int'; Int64 = 'long'; Double = 'double'; Boolean = 'bool'; Object = 'obj'; 'String[]' = 'string[]'; 'Object[]' = 'obj[]'; 'Int32[]' = 'int[]' }
$rows = New-Object System.Collections.Generic.List[string]
foreach ($c in $commands) {
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($p in $c.Parameters.Values | Where-Object { $common -notcontains $_.Name }) {
        $mandatory = @($p.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory }).Count -gt 0
        $tn = $p.ParameterType.Name
        $item = if ($p.SwitchParameter) { "-$($p.Name)" } else { "-$($p.Name) <$(if ($typeNames.ContainsKey($tn)) { $typeNames[$tn] } else { $tn.ToLowerInvariant() })>" }
        $parts.Add($(if ($mandatory) { $item } else { "[$item]" }))
    }
    $tool = if ($toolByCmdlet.ContainsKey($c.Name)) { '`' + $toolByCmdlet[$c.Name] + '`' } elseif ($compositeByCmdlet.ContainsKey($c.Name)) { '`' + $compositeByCmdlet[$c.Name] + '` (composite)' } else { '-' }
    $sig = if ($parts.Count -gt 0) { '`' + ($parts -join ' ') + '`' } else { '-' }
    $rows.Add("| ``$($c.Name)`` | $tool | $sig |")
}
$signatureBlock = @(
    '',
    '<!-- 由 scripts/Update-GeneratedDocs.ps1 從 Get-Command 與 mcp-server/tools.json 產生,不要手改;上面的表是手寫的用法說明。 -->',
    '',
    '| Cmdlet | MCP tool | 參數(`[ ]` = 選填;切換參數不帶值) |',
    '|---|---|---|'
) + $rows + @('')

$values = @{
    'cmdlet-count'      = [string]$commands.Count
    'mcp-tool-count'    = [string]@($toolsDoc.tools).Count
    'composite-count'   = [string]$compositeCount
    'cmdlet-signatures' = ($signatureBlock -join "`n")
}

# ---- rewrite -----------------------------------------------------------------------------------
$markerRegex = [regex]'(?s)<!-- generated:(?<key>[a-z-]+) -->(?<body>.*?)<!-- /generated -->'
$stale = New-Object System.Collections.Generic.List[string]
$problems = New-Object System.Collections.Generic.List[string]

foreach ($rel in $targets) {
    $path = Join-Path $DocsRoot $rel
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text = $utf8.GetString($bytes, $(if ($hasBom) { 3 } else { 0 }), $bytes.Length - $(if ($hasBom) { 3 } else { 0 }))
    $crlf = $text.Contains("`r`n")
    $orig = $text
    $lf = $text.Replace("`r`n", "`n")

    # Broken markers must never swallow hand-written text: an opening without its closing marker
    # would make the lazy regex run into the next block. Report and leave the file alone.
    $fileProblems = New-Object System.Collections.Generic.List[string]
    $opens = [regex]::Matches($lf, '<!-- generated:').Count
    $closes = [regex]::Matches($lf, '<!-- /generated -->').Count
    if ($opens -ne $closes) { $fileProblems.Add("${rel}: $opens opening and $closes closing generated markers") }
    foreach ($mm in $markerRegex.Matches($lf)) {
        $mk = $mm.Groups['key'].Value
        if ($mm.Groups['body'].Value.Contains('<!-- generated:')) { $fileProblems.Add("${rel}: marker '$mk' has no closing marker before the next opening one") }
        elseif ($mk -match '-count$' -and $mm.Groups['body'].Value -notmatch '^\d*$') { $fileProblems.Add("${rel}: marker '$mk' body is not a number") }
    }
    if ($fileProblems.Count -gt 0) { foreach ($fp in $fileProblems) { $problems.Add($fp) }; continue }

    $lf = $markerRegex.Replace($lf, {
            param($m)
            $key = $m.Groups['key'].Value
            if (-not $values.ContainsKey($key)) { $problems.Add("${rel}: unknown marker '$key'"); return $m.Value }
            "<!-- generated:$key -->$($values[$key])<!-- /generated -->"
        })
    foreach ($r in $patternRules | Where-Object { $_.File -eq $rel }) {
        $re = [regex]$r.Regex
        if (-not $re.IsMatch($lf)) { $problems.Add("${rel}: pattern '$($r.Regex)' not found"); continue }
        $lf = $re.Replace($lf, {
                param($m)
                $g = $m.Groups['n']
                $m.Value.Substring(0, $g.Index - $m.Index) + $values[$r.Key] + $m.Value.Substring($g.Index - $m.Index + $g.Length)
            })
    }
    $result = if ($crlf) { $lf.Replace("`n", "`r`n") } else { $lf }
    if ($result -cne $orig) {
        $stale.Add($rel)
        if (-not $Check) {
            $out = $utf8.GetBytes($result)
            if ($hasBom) { $out = [byte[]](0xEF, 0xBB, 0xBF) + $out }
            [System.IO.File]::WriteAllBytes($path, $out)
        }
    }
}

# every key used in the values table must appear somewhere (a typo'd marker would silently go stale)
$used = @{}
foreach ($rel in $targets) {
    foreach ($m in $markerRegex.Matches([System.IO.File]::ReadAllText((Join-Path $DocsRoot $rel), $utf8))) { $used[$m.Groups['key'].Value] = $true }
}
foreach ($k in $values.Keys) { if (-not $used.ContainsKey($k)) { $problems.Add("marker '$k' is not used in any target file") } }

foreach ($p in $problems) { Write-Host "PROBLEM $p" }
if ($Check) {
    foreach ($s in $stale) { Write-Host "STALE   $s" }
    if ($stale.Count -gt 0 -or $problems.Count -gt 0) { exit 1 }
    Write-Host "generated docs up to date ($($values['cmdlet-count']) cmdlets, $($values['mcp-tool-count']) MCP tools, $($values['composite-count']) composites)"
    exit 0
}
foreach ($s in $stale) { Write-Host "updated $s" }
if ($problems.Count -gt 0) { exit 1 }
Write-Host "done ($($values['cmdlet-count']) cmdlets, $($values['mcp-tool-count']) MCP tools, $($values['composite-count']) composites)"
