# Unit: install manifest (#30), no IDE / runtime / TwinCAT needed.
#  1. Commit from .git files without git: branch ref, packed-refs, detached HEAD, linked worktree
#     (.git file + commondir), unborn branch, no .git; tcauto-source.json (release stamp) wins.
#  2. The three installers (-SkillDir <temp> -SkipPrerequisites; Codex also -CodexHome <temp>) write
#     the same manifest schema with the real file hashes; -Verify exits 0.
#  3. Get-TcAutomationVersion from the installed copy reads the manifest; -Verify passes.
#  4. Tampered / deleted / extra file -> installer -Verify exits 1 and Get-TcAutomationVersion -Verify
#     returns INSTALL_MANIFEST_MISMATCH with the file; a re-install rewrites the manifest (read-only
#     attribute handled) and verifies again; a broken manifest -> INSTALL_MANIFEST_INVALID.
#  5. Module loaded from the source tree: installed=false, source=source-tree; -Verify ->
#     INSTALL_MANIFEST_NOT_FOUND.
# Never touches the user profile: every install goes to a temp folder whose name contains "30".
#   powershell.exe -NoProfile -File tests/Unit/install-manifest.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).ProviderPath
$modulePath = Join-Path $repoRoot 'src\TwinCATAutomation\TwinCATAutomation.psm1'
$tmpRoot = Join-Path $env:TEMP ("tcauto-unit-30-manifest-{0}" -f [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tmpRoot -Force
Import-Module $modulePath -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}
function Write-File([string]$Path, [string]$Text) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}
# Runs a script in a child Windows PowerShell; returns @{ Code; Out }.
function Invoke-Child([string]$File, [string[]]$Arguments) {
    $out = & powershell.exe -NoProfile -File $File @Arguments 2>&1 | ForEach-Object { "$_" }
    @{ Code = $LASTEXITCODE; Out = ($out -join "`n") }
}
function Invoke-ChildCommand([string]$Command) {
    $out = & powershell.exe -NoProfile -Command $Command 2>&1 | ForEach-Object { "$_" }
    @{ Code = $LASTEXITCODE; Out = ($out -join "`n") }
}

$shaA = 'a' * 40
$shaB = '0123456789abcdef0123456789abcdef01234567'
$shaC = 'fedcba9876543210fedcba9876543210fedcba98'

try {
    # ------------------------------------------------------------------ 1. .git reading
    $r1 = Join-Path $tmpRoot 'repo-branch'
    Write-File "$r1\.git\HEAD" "ref: refs/heads/main`n"
    Write-File "$r1\.git\refs\heads\main" "$shaA`n"
    $g = & $mod { param($p) Get-TcGitHeadInfo -RepoRoot $p } $r1
    Check 'git: branch ref file' ($g.commit -eq $shaA -and $g.ref -eq 'refs/heads/main') "$($g.commit) $($g.ref)"

    $r2 = Join-Path $tmpRoot 'repo-packed'
    Write-File "$r2\.git\HEAD" "ref: refs/heads/feat/x`n"
    Write-File "$r2\.git\packed-refs" "# pack-refs with: peeled fully-peeled sorted`n$shaC refs/heads/other`n$shaB refs/heads/feat/x`n^$shaC`n"
    $g = & $mod { param($p) Get-TcGitHeadInfo -RepoRoot $p } $r2
    Check 'git: packed-refs' ($g.commit -eq $shaB -and $g.ref -eq 'refs/heads/feat/x') "$($g.commit)"

    $r3 = Join-Path $tmpRoot 'repo-detached'
    Write-File "$r3\.git\HEAD" "$($shaB.ToUpperInvariant())`n"
    $g = & $mod { param($p) Get-TcGitHeadInfo -RepoRoot $p } $r3
    Check 'git: detached HEAD (normalized to lower case)' ($g.commit -eq $shaB -and $null -eq $g.ref) "$($g.commit)"

    # linked worktree: <wt>\.git is a file; HEAD in .git\worktrees\wt, the branch in the common dir
    $main = Join-Path $tmpRoot 'repo-main'
    $wt = Join-Path $tmpRoot 'repo-wt'
    Write-File "$main\.git\HEAD" "ref: refs/heads/main`n"
    Write-File "$main\.git\packed-refs" "$shaC refs/heads/wtbranch`n"
    Write-File "$main\.git\worktrees\wt\HEAD" "ref: refs/heads/wtbranch`n"
    Write-File "$main\.git\worktrees\wt\commondir" "../..`n"
    Write-File "$wt\.git" ("gitdir: " + ("$main\.git\worktrees\wt" -replace '\\', '/') + "`n")
    $g = & $mod { param($p) Get-TcGitHeadInfo -RepoRoot $p } $wt
    Check 'git: linked worktree (gitdir file + commondir + packed-refs)' ($g.commit -eq $shaC -and $g.ref -eq 'refs/heads/wtbranch') "$($g.commit) $($g.ref)"

    $r5 = Join-Path $tmpRoot 'repo-unborn'
    Write-File "$r5\.git\HEAD" "ref: refs/heads/main`n"
    $g = & $mod { param($p) Get-TcGitHeadInfo -RepoRoot $p } $r5
    Check 'git: unborn branch -> commit null, ref kept' ($null -ne $g -and $null -eq $g.commit -and $g.ref -eq 'refs/heads/main') ''

    $r6 = Join-Path $tmpRoot 'no-git'
    $null = New-Item -ItemType Directory -Path $r6 -Force
    $g = & $mod { param($p) Get-TcGitHeadInfo -RepoRoot $p } $r6
    Check 'git: no .git -> $null' ($null -eq $g) ''

    $srcModuleDir = Join-Path $repoRoot 'src\TwinCATAutomation'
    $psd1Version = [string](Import-PowerShellDataFile (Join-Path $srcModuleDir 'TwinCATAutomation.psd1')).ModuleVersion
    $s = & $mod { param($p, $m) Get-TcSourceInfo -SourceRoot $p -ModuleDir $m } $r1 $srcModuleDir
    Check 'source info: git' ($s.commitSource -eq 'git' -and $s.commit -eq $shaA -and $s.version -eq $psd1Version -and $s.sourceUrl -like 'https://github.com/*') "$($s.commitSource) $($s.version) $($s.sourceUrl)"
    Write-File "$r1\tcauto-source.json" ('{"sourceUrl":"https://example.invalid/repo30","commit":"' + $shaB + '","ref":"refs/tags/v9.9.9","release":"v9.9.9"}')
    $s = & $mod { param($p, $m) Get-TcSourceInfo -SourceRoot $p -ModuleDir $m } $r1 $srcModuleDir
    Check 'source info: release stamp wins over .git' ($s.commitSource -eq 'release-stamp' -and $s.commit -eq $shaB -and $s.release -eq 'v9.9.9' -and $s.sourceUrl -eq 'https://example.invalid/repo30') "$($s.commitSource) $($s.commit)"
    $s = & $mod { param($p, $m) Get-TcSourceInfo -SourceRoot $p -ModuleDir $m } $r6 $srcModuleDir
    Check 'source info: nothing -> unknown' ($s.commitSource -eq 'unknown' -and $null -eq $s.commit -and $s.version -eq $psd1Version) ''

    # ------------------------------------------------------------------ 2. installers
    $expectedCommit = (& $mod { param($p) Get-TcGitHeadInfo -RepoRoot $p } $repoRoot)
    $expectedKeys = 'schemaVersion,name,module,sourceUrl,version,release,commit,ref,commitSource,installer,installedAt,sourcePath,hashAlgorithm,files'
    $installs = @(
        @{ Name = 'claude-code'; Script = 'TwinCATSetup-Claude.ps1'; Extra = @() },
        @{ Name = 'codex'; Script = 'TwinCATSetup-Codex.ps1'; Extra = @('-CodexHome', (Join-Path $tmpRoot 'codex30-home')) },
        @{ Name = 'antigravity'; Script = 'TwinCATSetup-Antigravity.ps1'; Extra = @() }
    )
    foreach ($i in $installs) {
        $dir = Join-Path $tmpRoot "skill30-$($i.Name)"
        $i.Dir = $dir
        $script = Join-Path $repoRoot $i.Script
        $r = Invoke-Child $script (@('-SkillDir', $dir, '-SkipPrerequisites') + $i.Extra)
        $mf = Join-Path $dir 'tcauto-install-manifest.json'
        Check "$($i.Name): install exit 0 + manifest written" ($r.Code -eq 0 -and (Test-Path -LiteralPath $mf)) "exit $($r.Code)"
        if (-not (Test-Path -LiteralPath $mf)) { $r.Out; continue }
        $m = [System.IO.File]::ReadAllText($mf, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        $keys = ($m.PSObject.Properties | ForEach-Object { $_.Name }) -join ','
        Check "$($i.Name): manifest schema" ($keys -eq $expectedKeys -and $m.schemaVersion -eq 1) $keys
        Check "$($i.Name): installer / name / version" ($m.installer -eq $i.Name -and $m.name -eq 'TwinCAT-AutomationInterface' -and $m.version -eq $psd1Version -and $m.hashAlgorithm -eq 'SHA256') "$($m.installer) $($m.name) $($m.version)"
        if ($null -ne $expectedCommit -and $null -ne $expectedCommit.commit) {
            Check "$($i.Name): commit from this checkout's .git" ($m.commit -eq $expectedCommit.commit -and $m.commitSource -eq 'git') "$($m.commit)"
        }
        $parsed = [datetime]::MinValue
        $okTime = [datetime]::TryParseExact([string]$m.installedAt, "yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)
        Check "$($i.Name): installedAt ISO-8601 UTC" $okTime "$($m.installedAt)"
        $skillEntry = @($m.files | Where-Object { $_.path -eq 'SKILL.md' })
        $psd1Entry = @($m.files | Where-Object { $_.path -eq 'TwinCATAutomation/TwinCATAutomation.psd1' })
        $realSkill = (Get-FileHash -LiteralPath (Join-Path $dir 'SKILL.md') -Algorithm SHA256).Hash.ToLowerInvariant()
        $srcCount = @(Get-ChildItem -LiteralPath $srcModuleDir -Recurse -File -Force).Count
        Check "$($i.Name): files = SKILL.md + whole module, real hashes" ($skillEntry.Count -eq 1 -and $skillEntry[0].sha256 -eq $realSkill -and $psd1Entry.Count -eq 1 -and @($m.files).Count -eq ($srcCount + 1)) "$(@($m.files).Count) files"
        Check "$($i.Name): manifest is read-only" ((Get-Item -LiteralPath $mf -Force).IsReadOnly) ''
        $skillText = [System.IO.File]::ReadAllText((Join-Path $dir 'SKILL.md'), [System.Text.Encoding]::UTF8)
        Check "$($i.Name): SKILL.md has the installed module path" ($skillText.Contains((Join-Path $dir 'TwinCATAutomation\TwinCATAutomation.psm1')) -and -not $skillText.Contains('<module-path>')) ''
        $v = Invoke-Child $script (@('-SkillDir', $dir, '-Verify') + $i.Extra)
        Check "$($i.Name): -Verify after install exits 0" ($v.Code -eq 0 -and $v.Out -match 'Result: match') "exit $($v.Code)"
        if ($v.Code -ne 0) { $v.Out }
    }
    $codexAgents = Join-Path $tmpRoot 'codex30-home\AGENTS.md'
    Check 'codex: AGENTS.md went to -CodexHome' (Test-Path -LiteralPath $codexAgents) ''

    # ------------------------------------------------------------------ 3-4. installed copy
    $dir = $installs[0].Dir
    $installedPsm1 = Join-Path $dir 'TwinCATAutomation\TwinCATAutomation.psm1'
    $verCmd = "Import-Module '$installedPsm1' -Force -WarningAction SilentlyContinue; Get-TcAutomationVersion {0} | ConvertTo-Json -Depth 8 -Compress"
    $c = Invoke-ChildCommand ($verCmd -f '')
    $res = $null; try { $res = $c.Out | ConvertFrom-Json } catch { $c.Out }
    Check 'Get-TcAutomationVersion (installed): manifest read' ($null -ne $res -and $res.success -and $res.data.installed -and $res.data.source -eq 'install-manifest' -and $res.data.installer -eq 'claude-code' -and $res.data.version -eq $psd1Version) "$($res.data.source)"
    $c = Invoke-ChildCommand ($verCmd -f '-Verify')
    $res = $null; try { $res = $c.Out | ConvertFrom-Json } catch { $c.Out }
    Check 'Get-TcAutomationVersion -Verify (installed, untouched): ok' ($null -ne $res -and $res.success -and $res.data.verify.ok -and $res.data.verify.matched -eq $res.data.fileCount) "$($res.data.verify.matched)/$($res.data.fileCount)"

    # tamper: change one module file, delete another, add an extra one
    $tampered = Join-Path $dir 'TwinCATAutomation\Public\Get-TcIdeInfo.ps1'
    [System.IO.File]::AppendAllText($tampered, "`r`n# tampered 30`r`n")
    Remove-Item -LiteralPath (Join-Path $dir 'TwinCATAutomation\Public\Get-TcPlcState.ps1') -Force
    Write-File (Join-Path $dir 'TwinCATAutomation\Private\extra30.ps1') '# extra'
    $c = Invoke-ChildCommand ($verCmd -f '-Verify')
    $res = $null; try { $res = $c.Out | ConvertFrom-Json } catch { $c.Out }
    $mis = @($res.data.verify.mismatched | ForEach-Object { $_.path })
    Check 'Get-TcAutomationVersion -Verify (tampered): INSTALL_MANIFEST_MISMATCH' ($null -ne $res -and -not $res.success -and $res.error.code -eq 'INSTALL_MANIFEST_MISMATCH' -and -not [string]::IsNullOrWhiteSpace($res.error.hint)) "$($res.error.code)"
    Check 'tampered: mismatched / missing / extra listed' (($mis -contains 'TwinCATAutomation/Public/Get-TcIdeInfo.ps1') -and (@($res.data.verify.missing) -contains 'TwinCATAutomation/Public/Get-TcPlcState.ps1') -and (@($res.data.verify.extra) -contains 'TwinCATAutomation/Private/extra30.ps1')) "mismatched=$($mis -join ',') missing=$(@($res.data.verify.missing) -join ',') extra=$(@($res.data.verify.extra) -join ',')"
    $v = Invoke-Child (Join-Path $repoRoot 'TwinCATSetup-Claude.ps1') @('-SkillDir', $dir, '-Verify')
    Check 'installer -Verify (tampered): exit 1, names the file' ($v.Code -eq 1 -and $v.Out -match 'Get-TcIdeInfo\.ps1' -and $v.Out -match 'Result: mismatch') "exit $($v.Code)"

    # update install: rewrites the read-only manifest and repairs the files
    # (mark the old manifest: installer = stale30, read-only again, so a rewrite is visible)
    $mf = Join-Path $dir 'tcauto-install-manifest.json'
    (Get-Item -LiteralPath $mf -Force).IsReadOnly = $false
    Write-File $mf ([System.IO.File]::ReadAllText($mf).Replace('"claude-code"', '"stale30"'))
    (Get-Item -LiteralPath $mf -Force).IsReadOnly = $true
    $r = Invoke-Child (Join-Path $repoRoot 'TwinCATSetup-Claude.ps1') @('-SkillDir', $dir, '-SkipPrerequisites')
    $after = [System.IO.File]::ReadAllText($mf) | ConvertFrom-Json
    Check 're-install: exit 0, read-only manifest rewritten' ($r.Code -eq 0 -and $after.installer -eq 'claude-code' -and (Get-Item -LiteralPath $mf -Force).IsReadOnly) "installer=$($after.installer)"
    $v = Invoke-Child (Join-Path $repoRoot 'TwinCATSetup-Claude.ps1') @('-SkillDir', $dir, '-Verify')
    Check 're-install: -Verify exits 0 again' ($v.Code -eq 0) "exit $($v.Code)"

    # broken manifest
    $mf = Join-Path $dir 'tcauto-install-manifest.json'
    (Get-Item -LiteralPath $mf -Force).IsReadOnly = $false
    Write-File $mf '{"name":"not a manifest"}'
    $c = Invoke-ChildCommand ($verCmd -f '')
    $res = $null; try { $res = $c.Out | ConvertFrom-Json } catch { $c.Out }
    Check 'broken manifest: INSTALL_MANIFEST_INVALID' ($null -ne $res -and -not $res.success -and $res.error.code -eq 'INSTALL_MANIFEST_INVALID') "$($res.error.code)"
    $v = Invoke-Child (Join-Path $repoRoot 'TwinCATSetup-Claude.ps1') @('-SkillDir', $dir, '-Verify')
    Check 'broken manifest: installer -Verify exits 1' ($v.Code -eq 1) "exit $($v.Code)"

    # ------------------------------------------------------------------ 5. source tree
    $res = Get-TcAutomationVersion
    Check 'Get-TcAutomationVersion (source tree): installed=false' ($res.success -and -not $res.data.installed -and $res.data.source -eq 'source-tree' -and $res.data.moduleVersion -eq $psd1Version) "$($res.data.source) $($res.data.commitSource)"
    if ($null -ne $expectedCommit -and $null -ne $expectedCommit.commit) {
        Check 'Get-TcAutomationVersion (source tree): commit from .git' ($res.data.commit -eq $expectedCommit.commit -and $res.data.commitSource -eq 'git') "$($res.data.commit)"
    }
    $res = Get-TcAutomationVersion -Verify
    Check 'Get-TcAutomationVersion -Verify (source tree): INSTALL_MANIFEST_NOT_FOUND' (-not $res.success -and $res.error.code -eq 'INSTALL_MANIFEST_NOT_FOUND') "$($res.error.code)"
}
catch {
    Check 'unexpected exception' $false "$($_.Exception.Message) at $($_.InvocationInfo.PositionMessage)"
}
finally {
    Get-ChildItem -LiteralPath $tmpRoot -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object { $_.IsReadOnly = $false }
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

""
"failed: $fail"
exit $fail
