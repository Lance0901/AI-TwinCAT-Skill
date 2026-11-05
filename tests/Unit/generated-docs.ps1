# Unit: scripts/Update-GeneratedDocs.ps1 (#25). No IDE / runtime. The generator runs against a COPY of
# the target docs (-DocsRoot), never the repository files:
#   * pristine copy            -Check passes
#   * stale count              -Check reports STALE (exit 1); a normal run rewrites it back to the repo text
#   * missing closing marker   PROBLEM, exit 1, the file is NOT written (hand-written text is not swallowed)
#   * count marker with text   PROBLEM, exit 1, the file is NOT written
#   * adapters/codex/tools.json, adapters/antigravity/plugin.yaml (#144) are generated as a whole:
#     an edited action name is STALE and is rewritten back; a deleted file is created again;
#     every $operationMap action appears exactly once in both
#   powershell.exe -NoProfile -File tests/Unit/generated-docs.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 400) { $Detail = $Detail.Substring(0, 400) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).ProviderPath
$gen = Join-Path $root 'scripts\Update-GeneratedDocs.ps1'
$targets = @('README.md', 'README.zh-TW.md', 'CLAUDE.md', 'AGENTS.md', 'adapters/claude-code/SKILL.md', 'docs/setup-mcp.md', 'mcp-server/README.md', 'docs/known-limitations.md', '.agents/skills/twincat/SKILL.md', 'adapters/codex/tools.json', 'adapters/antigravity/plugin.yaml')
$work = Join-Path $env:TCAUTO_STATE_DIR 'docs'

function New-DocsCopy([string]$Name) {
    $dir = Join-Path $work $Name
    foreach ($t in $targets) {
        $dst = Join-Path $dir $t
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $dst) -Force
        Copy-Item -LiteralPath (Join-Path $root $t) -Destination $dst
    }
    $dir
}
function Invoke-Gen([string]$Dir, [switch]$CheckOnly) {
    $a = @('-NoProfile', '-File', $gen, '-DocsRoot', $Dir)
    if ($CheckOnly) { $a += '-Check' }
    $out = @(& powershell.exe @a 2>&1 | ForEach-Object { "$_" })
    @{ Code = $LASTEXITCODE; Text = ($out -join "`n") }
}
function Read-Bytes([string]$Path) { [IO.File]::ReadAllBytes($Path) }
function Same([byte[]]$A, [byte[]]$B) { [Convert]::ToBase64String($A) -ceq [Convert]::ToBase64String($B) }
$utf8 = New-Object System.Text.UTF8Encoding($false)

# pristine
$d = New-DocsCopy 'pristine'
$r = Invoke-Gen $d -CheckOnly
Check 'pristine-check-passes' ($r.Code -eq 0) "$($r.Code) $($r.Text)"

# stale count
$d = New-DocsCopy 'stale'
$readme = Join-Path $d 'README.md'
$orig = Read-Bytes $readme
$text = $utf8.GetString($orig)
$stale = [regex]::Replace($text, '(<!-- generated:cmdlet-count -->)\d+', '${1}62', 1)
[IO.File]::WriteAllText($readme, $stale, $utf8)
$r = Invoke-Gen $d -CheckOnly
Check 'stale-check-fails' ($r.Code -eq 1 -and $r.Text -match 'STALE\s+README\.md') "$($r.Code) $($r.Text)"
Check 'stale-check-wrote-nothing' ($utf8.GetString((Read-Bytes $readme)) -ceq $stale) 'README.md changed by -Check'
$r = Invoke-Gen $d
Check 'stale-rewrite-ok' ($r.Code -eq 0 -and (Same (Read-Bytes $readme) $orig)) "$($r.Code) $($r.Text)"

# missing closing marker: hand-written text after it must survive and the file must not be written
$d = New-DocsCopy 'unclosed'
$readme = Join-Path $d 'README.md'
$text = $utf8.GetString((Read-Bytes $readme))
$broken = ([regex]'<!-- /generated -->').Replace($text, '', 1) + "`r`nHAND-WRITTEN-SENTINEL`r`n"
$brokenBytes = $utf8.GetBytes($broken)
[IO.File]::WriteAllBytes($readme, $brokenBytes)
$r = Invoke-Gen $d
Check 'unclosed-problem-exit1' ($r.Code -eq 1 -and $r.Text -match 'PROBLEM README\.md') "$($r.Code) $($r.Text)"
Check 'unclosed-file-untouched' (Same (Read-Bytes $readme) $brokenBytes) 'README.md was rewritten'
Check 'unclosed-sentinel-kept' ($utf8.GetString((Read-Bytes $readme)).Contains('HAND-WRITTEN-SENTINEL')) 'hand-written text lost'

# opening marker inside an open block (closing marker of the first one missing, more markers follow)
$d = New-DocsCopy 'nested'
$claude = Join-Path $d 'CLAUDE.md'
$text = $utf8.GetString((Read-Bytes $claude))
$nested = ([regex]'<!-- /generated -->').Replace($text, '<!-- generated:composite-count -->5', 1)
[IO.File]::WriteAllBytes($claude, $utf8.GetBytes($nested))
$before = Read-Bytes $claude
$r = Invoke-Gen $d
Check 'nested-problem-exit1' ($r.Code -eq 1 -and $r.Text -match 'PROBLEM CLAUDE\.md') "$($r.Code) $($r.Text)"
Check 'nested-file-untouched' (Same (Read-Bytes $claude) $before) 'CLAUDE.md was rewritten'

# count marker whose body is text
$d = New-DocsCopy 'text-body'
$readme = Join-Path $d 'README.md'
$text = $utf8.GetString((Read-Bytes $readme))
$bad = [regex]::Replace($text, '(<!-- generated:cmdlet-count -->)\d+', '${1}many words', 1)
[IO.File]::WriteAllBytes($readme, $utf8.GetBytes($bad))
$before = Read-Bytes $readme
$r = Invoke-Gen $d
Check 'text-body-problem-exit1' ($r.Code -eq 1 -and $r.Text -match 'not a number') "$($r.Code) $($r.Text)"
Check 'text-body-file-untouched' (Same (Read-Bytes $readme) $before) 'README.md was rewritten'

# adapters (#144): generated as a whole files
foreach ($rel in @('adapters/codex/tools.json', 'adapters/antigravity/plugin.yaml')) {
    $tag = ($rel -replace '[^a-z]', '-')
    $d = New-DocsCopy "adapter-$tag"
    $f = Join-Path $d $rel
    $orig = Read-Bytes $f
    $edited = $utf8.GetString($orig).Replace('AddPou', 'AddPouEdited')
    [IO.File]::WriteAllBytes($f, $utf8.GetBytes($edited))
    $r = Invoke-Gen $d -CheckOnly
    Check "adapter-edit-stale ($rel)" ($r.Code -eq 1 -and $r.Text -match ('STALE\s+' + [regex]::Escape($rel))) "$($r.Code) $($r.Text)"
    $r = Invoke-Gen $d
    Check "adapter-edit-rewritten ($rel)" ($r.Code -eq 0 -and (Same (Read-Bytes $f) $orig)) "$($r.Code) $($r.Text)"
    Remove-Item -LiteralPath $f
    $r = Invoke-Gen $d
    Check "adapter-missing-created ($rel)" ($r.Code -eq 0 -and (Same (Read-Bytes $f) $orig)) "$($r.Code) $($r.Text)"
}

# every operationMap action is in both adapters, once
$cli = [IO.File]::ReadAllText((Join-Path $root 'Invoke-TwinCATAutomation.ps1'), $utf8)
$body = [regex]::Match($cli, '\$operationMap\s*=\s*@\{(?<b>.*?)\n\}', 'Singleline').Groups['b'].Value
$ops = @([regex]::Matches($body, "(?m)^\s*'([A-Za-z0-9]+)'\s*=") | ForEach-Object { $_.Groups[1].Value })
$codex = (([IO.File]::ReadAllText((Join-Path $root 'adapters\codex\tools.json'), $utf8)) | ConvertFrom-Json).tools
$yaml = [IO.File]::ReadAllText((Join-Path $root 'adapters\antigravity\plugin.yaml'), $utf8)
$yamlNames = @([regex]::Matches($yaml, '(?m)^  - name: (\S+)\s*$') | ForEach-Object { $_.Groups[1].Value })
Check 'operationMap-not-empty' ($ops.Count -gt 50) "$($ops.Count)"
Check 'codex-actions-equal-operationMap' (($ops -join ',') -ceq (@($codex | ForEach-Object { $_.name }) -join ',')) "codex $(@($codex).Count) vs map $($ops.Count)"
Check 'antigravity-actions-equal-operationMap' (($ops -join ',') -ceq ($yamlNames -join ',')) "yaml $($yamlNames.Count) vs map $($ops.Count)"
Check 'codex-no-stale-enterplconline' (@($codex | Where-Object { $_.name -eq 'EnterPlcOnline' }).Count -eq 0) 'EnterPlcOnline is not an operationMap action (PlcLogin is)'

# safety rules must survive the generation (#146 review): the adapter text is the COMPLETE tool description
$must = [ordered]@{
    ClearLifecycleBlock = @('ONLY after the user has seen the block', 'never call it on your own to get past LIFECYCLE_BLOCKED')
    EnableConfig        = @('Confirm with the user first')
    WriteVariable       = @('Confirm with the user first')
    RunTestCycle        = @('Confirm with the user first')
    SetSystemState      = @('all outputs go to zero', 'call ClearLifecycleBlock only after the user agreed')
    SetPlcState         = @('Reset kills TcSystemServiceUm', 'call ClearLifecycleBlock only after the user agreed')
    ReportIssue         = @('ONLY THE USER opens')
}
$yamlBlocks = @{}
foreach ($blk in ($yaml -split "(?m)^  - name: ") | Select-Object -Skip 1) { $yamlBlocks[($blk -split "\r?\n")[0].Trim()] = $blk }
foreach ($k in $must.Keys) {
    $cd = [string](@($codex | Where-Object { $_.name -eq $k })[0].description)
    foreach ($phrase in $must[$k]) {
        Check "safety-codex-$k ($phrase)" ($cd.Contains($phrase)) $cd.Substring(0, [Math]::Min(120, $cd.Length))
        Check "safety-antigravity-$k ($phrase)" ($yamlBlocks[$k].Contains($phrase)) ''
    }
}

# .agents SKILL.md: failure contract, generated signature table, no blind wait; Codex AGENTS.md template: failure contract
$agentsSkill = [IO.File]::ReadAllText((Join-Path $root '.agents\skills\twincat\SKILL.md'), $utf8)
Check 'agents-skill-failure-contract' ($agentsSkill -match 'Failure contract' -and $agentsSkill -match 'LIFECYCLE_BLOCKED' -and $agentsSkill -match 'Clear-TcLifecycleBlock' -and $agentsSkill -match 'agreed') ''
Check 'agents-skill-signature-table' ($agentsSkill -match '<!-- generated:cmdlet-signatures -->' -and $agentsSkill.Contains('| `Enable-TcConfig` |')) ''
Check 'agents-skill-no-start-sleep' ($agentsSkill -notmatch '(?m)^\s*Start-Sleep') 'a Start-Sleep line is in the lifecycle example'
$codexSetup = [IO.File]::ReadAllText((Join-Path $root 'TwinCATSetup-Codex.ps1'), $utf8)
Check 'codex-setup-failure-contract' ($codexSetup -match 'Failure contract \(fail closed' -and $codexSetup -match 'Clear-TcLifecycleBlock \(MCP ClearLifecycleBlock\) only after the user has seen the block') ''

# .agents SKILL.md signature table edited -> STALE, rewritten back
$d = New-DocsCopy 'agents-skill'
$f = Join-Path $d '.agents/skills/twincat/SKILL.md'
$orig = Read-Bytes $f
[IO.File]::WriteAllBytes($f, $utf8.GetBytes($utf8.GetString($orig).Replace('| `Enable-TcConfig` |', '| `Enable-TcConfigX` |')))
$r = Invoke-Gen $d -CheckOnly
Check 'agents-skill-edit-stale' ($r.Code -eq 1 -and $r.Text -match 'STALE\s+\.agents') "$($r.Code) $($r.Text)"
$r = Invoke-Gen $d
Check 'agents-skill-rewritten' ($r.Code -eq 0 -and (Same (Read-Bytes $f) $orig)) "$($r.Code) $($r.Text)"

"failed: $fail"
exit $fail
