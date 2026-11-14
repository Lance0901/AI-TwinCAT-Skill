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
# #241: runs the generator once per entry of $Runs (@{ Dir; CheckOnly }) in ONE child Windows
# PowerShell (was one child per run): each run is "& <generator> -DocsRoot <dir> [-Check]", its output
# and exit code are framed by marker lines. An exception that escapes a run counts as exit 1 (what
# -File gives for an unhandled error). Returns one @{ Code; Text } per run, in order.
function Invoke-GenBatch([object[]]$Runs) {
    $q = { param($s) "'" + ([string]$s).Replace("'", "''") + "'" }
    $cmd = @(for ($i = 0; $i -lt $Runs.Count; $i++) {
            $flag = if ($Runs[$i].CheckOnly) { ' -Check' } else { '' }
            "'##RUN $i'; `$global:LASTEXITCODE = 0; try { & $(& $q $gen) -DocsRoot $(& $q $Runs[$i].Dir)$flag *>&1 | ForEach-Object { [string]`$_ }; `$code = `$LASTEXITCODE } catch { [string]`$_; `$code = 1 }; '##EXIT $i ' + `$code"
        }) -join '; '
    # -EncodedCommand: Windows PowerShell 5.1 does not escape quotes inside a native argument
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    $out = @(& powershell.exe -NoProfile -EncodedCommand $enc 2>&1 | ForEach-Object { "$_" })
    $res = @()
    for ($i = 0; $i -lt $Runs.Count; $i++) {
        $start = [array]::IndexOf($out, "##RUN $i")
        $endLine = @($out | Where-Object { $_ -like "##EXIT $i *" } | Select-Object -First 1)
        $end = if ($endLine.Count -gt 0) { [array]::IndexOf($out, $endLine[0]) } else { -1 }
        if ($start -lt 0 -or $end -lt $start) { $res += , @{ Code = -1; Text = "run $i not framed: $($out -join "`n")" }; continue }
        $text = if ($end -gt $start + 1) { @($out[($start + 1)..($end - 1)]) -join "`n" } else { '' }
        $res += , @{ Code = [int]($endLine[0] -replace "^##EXIT $i ", ''); Text = $text }
    }
    , $res
}
function Read-Bytes([string]$Path) { [IO.File]::ReadAllBytes($Path) }
function Same([byte[]]$A, [byte[]]$B) { [Convert]::ToBase64String($A) -ceq [Convert]::ToBase64String($B) }
$utf8 = New-Object System.Text.UTF8Encoding($false)

# #241: every case gets its own copy, prepared up front; the generator runs in three batches (one
# child each): 1. the first run of every case, 2. the rewrite runs, 3. the runs after a deleted file.
# Each case's checks follow the batch of its run, so every check sees the same file states as before.

# pristine
$dPristine = New-DocsCopy 'pristine'

# stale count
$dStale = New-DocsCopy 'stale'
$staleReadme = Join-Path $dStale 'README.md'
$staleOrig = Read-Bytes $staleReadme
$stale = [regex]::Replace($utf8.GetString($staleOrig), '(<!-- generated:cmdlet-count -->)\d+', '${1}62', 1)
[IO.File]::WriteAllText($staleReadme, $stale, $utf8)

# missing closing marker: hand-written text after it must survive and the file must not be written
$dUnclosed = New-DocsCopy 'unclosed'
$unclosedReadme = Join-Path $dUnclosed 'README.md'
$text = $utf8.GetString((Read-Bytes $unclosedReadme))
$broken = ([regex]'<!-- /generated -->').Replace($text, '', 1) + "`r`nHAND-WRITTEN-SENTINEL`r`n"
$brokenBytes = $utf8.GetBytes($broken)
[IO.File]::WriteAllBytes($unclosedReadme, $brokenBytes)

# opening marker inside an open block (closing marker of the first one missing, more markers follow)
$dNested = New-DocsCopy 'nested'
$nestedClaude = Join-Path $dNested 'CLAUDE.md'
$text = $utf8.GetString((Read-Bytes $nestedClaude))
$nested = ([regex]'<!-- /generated -->').Replace($text, '<!-- generated:composite-count -->5', 1)
[IO.File]::WriteAllBytes($nestedClaude, $utf8.GetBytes($nested))
$nestedBefore = Read-Bytes $nestedClaude

# count marker whose body is text
$dText = New-DocsCopy 'text-body'
$textReadme = Join-Path $dText 'README.md'
$text = $utf8.GetString((Read-Bytes $textReadme))
$bad = [regex]::Replace($text, '(<!-- generated:cmdlet-count -->)\d+', '${1}many words', 1)
[IO.File]::WriteAllBytes($textReadme, $utf8.GetBytes($bad))
$textBefore = Read-Bytes $textReadme

# adapters (#144): generated as a whole files
$adapterCases = @(foreach ($rel in @('adapters/codex/tools.json', 'adapters/antigravity/plugin.yaml')) {
        $d = New-DocsCopy "adapter-$($rel -replace '[^a-z]', '-')"
        $f = Join-Path $d $rel
        $orig = Read-Bytes $f
        [IO.File]::WriteAllBytes($f, $utf8.GetBytes($utf8.GetString($orig).Replace('AddPou', 'AddPouEdited')))
        @{ Rel = $rel; Dir = $d; File = $f; Orig = $orig }
    })

# .agents SKILL.md signature table edited -> STALE, rewritten back
$dAgents = New-DocsCopy 'agents-skill'
$agentsFile = Join-Path $dAgents '.agents/skills/twincat/SKILL.md'
$agentsOrig = Read-Bytes $agentsFile
[IO.File]::WriteAllBytes($agentsFile, $utf8.GetBytes($utf8.GetString($agentsOrig).Replace('| `Enable-TcConfig` |', '| `Enable-TcConfigX` |')))

# batch 1: the first run of every case
$b1 = Invoke-GenBatch @(
    @{ Dir = $dPristine; CheckOnly = $true }, @{ Dir = $dStale; CheckOnly = $true }, @{ Dir = $dUnclosed; CheckOnly = $false },
    @{ Dir = $dNested; CheckOnly = $false }, @{ Dir = $dText; CheckOnly = $false },
    @{ Dir = $adapterCases[0].Dir; CheckOnly = $true }, @{ Dir = $adapterCases[1].Dir; CheckOnly = $true }, @{ Dir = $dAgents; CheckOnly = $true })
$r = $b1[0]
Check 'pristine-check-passes' ($r.Code -eq 0) "$($r.Code) $($r.Text)"
$r = $b1[1]
Check 'stale-check-fails' ($r.Code -eq 1 -and $r.Text -match 'STALE\s+README\.md') "$($r.Code) $($r.Text)"
Check 'stale-check-wrote-nothing' ($utf8.GetString((Read-Bytes $staleReadme)) -ceq $stale) 'README.md changed by -Check'
$r = $b1[2]
Check 'unclosed-problem-exit1' ($r.Code -eq 1 -and $r.Text -match 'PROBLEM README\.md') "$($r.Code) $($r.Text)"
Check 'unclosed-file-untouched' (Same (Read-Bytes $unclosedReadme) $brokenBytes) 'README.md was rewritten'
Check 'unclosed-sentinel-kept' ($utf8.GetString((Read-Bytes $unclosedReadme)).Contains('HAND-WRITTEN-SENTINEL')) 'hand-written text lost'
$r = $b1[3]
Check 'nested-problem-exit1' ($r.Code -eq 1 -and $r.Text -match 'PROBLEM CLAUDE\.md') "$($r.Code) $($r.Text)"
Check 'nested-file-untouched' (Same (Read-Bytes $nestedClaude) $nestedBefore) 'CLAUDE.md was rewritten'
$r = $b1[4]
Check 'text-body-problem-exit1' ($r.Code -eq 1 -and $r.Text -match 'not a number') "$($r.Code) $($r.Text)"
Check 'text-body-file-untouched' (Same (Read-Bytes $textReadme) $textBefore) 'README.md was rewritten'
for ($i = 0; $i -lt 2; $i++) {
    $r = $b1[5 + $i]; $rel = $adapterCases[$i].Rel
    Check "adapter-edit-stale ($rel)" ($r.Code -eq 1 -and $r.Text -match ('STALE\s+' + [regex]::Escape($rel))) "$($r.Code) $($r.Text)"
}
$r = $b1[7]
Check 'agents-skill-edit-stale' ($r.Code -eq 1 -and $r.Text -match 'STALE\s+\.agents') "$($r.Code) $($r.Text)"

# batch 2: the rewrite runs
$b2 = Invoke-GenBatch @(@{ Dir = $dStale; CheckOnly = $false }, @{ Dir = $adapterCases[0].Dir; CheckOnly = $false }, @{ Dir = $adapterCases[1].Dir; CheckOnly = $false }, @{ Dir = $dAgents; CheckOnly = $false })
$r = $b2[0]
Check 'stale-rewrite-ok' ($r.Code -eq 0 -and (Same (Read-Bytes $staleReadme) $staleOrig)) "$($r.Code) $($r.Text)"
for ($i = 0; $i -lt 2; $i++) {
    $r = $b2[1 + $i]; $c = $adapterCases[$i]
    Check "adapter-edit-rewritten ($($c.Rel))" ($r.Code -eq 0 -and (Same (Read-Bytes $c.File) $c.Orig)) "$($r.Code) $($r.Text)"
}
$r = $b2[3]
Check 'agents-skill-rewritten' ($r.Code -eq 0 -and (Same (Read-Bytes $agentsFile) $agentsOrig)) "$($r.Code) $($r.Text)"

# batch 3: a deleted adapter file is created again
foreach ($c in $adapterCases) { Remove-Item -LiteralPath $c.File }
$b3 = Invoke-GenBatch @(@{ Dir = $adapterCases[0].Dir; CheckOnly = $false }, @{ Dir = $adapterCases[1].Dir; CheckOnly = $false })
for ($i = 0; $i -lt 2; $i++) {
    $r = $b3[$i]; $c = $adapterCases[$i]
    Check "adapter-missing-created ($($c.Rel))" ($r.Code -eq 0 -and (Same (Read-Bytes $c.File) $c.Orig)) "$($r.Code) $($r.Text)"
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
    EnableConfig        = @('= local-umrt -> no need to ask', 'ask once')
    WriteVariable       = @('= local-umrt -> no need to ask', 'ask once')
    RunTestCycle        = @('= local-umrt -> no need to ask', 'ask once')
    SetSystemState      = @('all outputs go to zero', 'call ClearLifecycleBlock only after the user agreed')
    SetPlcState         = @('Reset leaves the PLC in Stop', 'call ClearLifecycleBlock only after the user agreed')
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

"failed: $fail"
exit $fail
