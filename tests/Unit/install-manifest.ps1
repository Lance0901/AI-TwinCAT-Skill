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
#  Review round 1: .git preferred over the stamp, bad stamp / .psd1 -> warnings (no throw), symbolic
#  ref chain / reftable -> no commit, frontmatter-only skill name, hash helper not shadowed (M1),
#  traversal paths refused (S5), helper / SKILL.md source missing -> exit 1 (M2), relative and
#  case / 8.3 -SkillDir (S3), -Uninstall refuses a foreign folder (S4), copied module folder ->
#  commit unknown (S6).
#  Review round 2: repo markers for the source-tree commit, drive root / UNC / provider / wildcard
#  paths, [ ] in -SkillDir, bogus manifests do not make a folder deletable, locked files (verify ->
#  unreadable, uninstall -> exit 1), Codex AGENTS.md write failure and failed prerequisites -> exit 1,
#  warnings under $WarningPreference = 'Stop' do not fail an install, data.warnings in both modes.
# Never touches the user profile: every install goes to a temp folder whose name contains "30".
#   powershell.exe -NoProfile -File tests/Unit/install-manifest.ps1
# Exit code = number of failed checks.
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).ProviderPath
$modulePath = Join-Path $repoRoot 'src\TwinCATAutomation\TwinCATAutomation.psm1'
$tmpRoot = Join-Path $env:TEMP ("tcauto-unit-30-manifest-{0}" -f [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tmpRoot -Force
# $env:TEMP may hold 8.3 components (GitHub runner: C:\Users\RUNNER~1\...); the installers write the
# long spelling into SKILL.md (Resolve-TcInstallPath), so the expected paths use it too.
if (-not ('TcUnit30.LongPath' -as [type])) {
    Add-Type -Namespace TcUnit30 -Name LongPath -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
public static extern uint GetLongPathName(string shortPath, System.Text.StringBuilder longPath, uint bufferLength);
'@
}
$longBuf = New-Object System.Text.StringBuilder 32768
$longLen = [TcUnit30.LongPath]::GetLongPathName($tmpRoot, $longBuf, [uint32]$longBuf.Capacity)
if ($longLen -gt 0 -and $longLen -lt $longBuf.Capacity) { $tmpRoot = $longBuf.ToString() }
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
    $ErrorActionPreference = 'Continue'   # stderr of the child is output here, not a terminating error
    $out = & powershell.exe -NoProfile -File $File @Arguments 2>&1 | ForEach-Object { "$_" }
    @{ Code = $LASTEXITCODE; Out = ($out -join "`n") }
}
function Invoke-ChildCommand([string]$Command) {
    $ErrorActionPreference = 'Continue'
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
    $g = & $mod { param($p) Read-TcGitCommit -RepoRoot $p } $r1
    Check 'git: branch ref file' ($g.commit -eq $shaA -and $g.ref -eq 'refs/heads/main') "$($g.commit) $($g.ref)"

    $r2 = Join-Path $tmpRoot 'repo-packed'
    Write-File "$r2\.git\HEAD" "ref: refs/heads/feat/x`n"
    Write-File "$r2\.git\packed-refs" "# pack-refs with: peeled fully-peeled sorted`n$shaC refs/heads/other`n$shaB refs/heads/feat/x`n^$shaC`n"
    $g = & $mod { param($p) Read-TcGitCommit -RepoRoot $p } $r2
    Check 'git: packed-refs' ($g.commit -eq $shaB -and $g.ref -eq 'refs/heads/feat/x') "$($g.commit)"

    $r3 = Join-Path $tmpRoot 'repo-detached'
    Write-File "$r3\.git\HEAD" "$($shaB.ToUpperInvariant())`n"
    $g = & $mod { param($p) Read-TcGitCommit -RepoRoot $p } $r3
    Check 'git: detached HEAD (normalized to lower case)' ($g.commit -eq $shaB -and $null -eq $g.ref) "$($g.commit)"

    # linked worktree: <wt>\.git is a file; HEAD in .git\worktrees\wt, the branch in the common dir
    $main = Join-Path $tmpRoot 'repo-main'
    $wt = Join-Path $tmpRoot 'repo-wt'
    Write-File "$main\.git\HEAD" "ref: refs/heads/main`n"
    Write-File "$main\.git\packed-refs" "$shaC refs/heads/wtbranch`n"
    Write-File "$main\.git\worktrees\wt\HEAD" "ref: refs/heads/wtbranch`n"
    Write-File "$main\.git\worktrees\wt\commondir" "../..`n"
    Write-File "$wt\.git" ("gitdir: " + ("$main\.git\worktrees\wt" -replace '\\', '/') + "`n")
    $g = & $mod { param($p) Read-TcGitCommit -RepoRoot $p } $wt
    Check 'git: linked worktree (gitdir file + commondir + packed-refs)' ($g.commit -eq $shaC -and $g.ref -eq 'refs/heads/wtbranch') "$($g.commit) $($g.ref)"

    $r5 = Join-Path $tmpRoot 'repo-unborn'
    Write-File "$r5\.git\HEAD" "ref: refs/heads/main`n"
    $g = & $mod { param($p) Read-TcGitCommit -RepoRoot $p } $r5
    Check 'git: unborn branch -> commit null, ref kept' ($null -ne $g -and $null -eq $g.commit -and $g.ref -eq 'refs/heads/main') ''

    $r6 = Join-Path $tmpRoot 'no-git'
    $null = New-Item -ItemType Directory -Path $r6 -Force
    $g = & $mod { param($p) Read-TcGitCommit -RepoRoot $p } $r6
    Check 'git: no .git -> $null' ($null -eq $g) ''

    $srcModuleDir = Join-Path $repoRoot 'src\TwinCATAutomation'
    $psd1Version = [string](Import-PowerShellDataFile (Join-Path $srcModuleDir 'TwinCATAutomation.psd1')).ModuleVersion
    $s = & $mod { param($p, $m) Get-TcSourceInfo -SourceRoot $p -ModuleDir $m } $r1 $srcModuleDir
    Check 'source info: git' ($s.commitSource -eq 'git' -and $s.commit -eq $shaA -and $s.version -eq $psd1Version -and $s.sourceUrl -like 'https://github.com/*') "$($s.commitSource) $($s.version) $($s.sourceUrl)"
    $stampJson = '{"sourceUrl":"https://example.invalid/repo30","commit":"' + $shaB + '","ref":"refs/tags/v9.9.9","release":"v9.9.9"}'
    Write-File "$r1\tcauto-source.json" $stampJson
    $s = & $mod { param($p, $m) Get-TcSourceInfo -SourceRoot $p -ModuleDir $m } $r1 $srcModuleDir
    Check 'source info: .git wins over a release stamp' ($s.commitSource -eq 'git' -and $s.commit -eq $shaA) "$($s.commitSource) $($s.commit)"
    $r7 = Join-Path $tmpRoot 'release30'
    Write-File "$r7\tcauto-source.json" $stampJson
    $s = & $mod { param($p, $m) Get-TcSourceInfo -SourceRoot $p -ModuleDir $m } $r7 $srcModuleDir
    Check 'source info: release stamp without .git' ($s.commitSource -eq 'release-stamp' -and $s.commit -eq $shaB -and $s.release -eq 'v9.9.9' -and $s.sourceUrl -eq 'https://example.invalid/repo30') "$($s.commitSource) $($s.commit)"
    Write-File "$r7\tcauto-source.json" '{"commit":"not-a-sha30","release":"v1"}'
    $s = & $mod { param($p, $m) Get-TcSourceInfo -SourceRoot $p -ModuleDir $m } $r7 $srcModuleDir
    Check 'source info: stamp commit not 40/64 hex -> null + warning' ($null -eq $s.commit -and @($s.warnings).Count -ge 1 -and $s.version -eq $psd1Version) "$(@($s.warnings) -join '; ')"
    Write-File "$r7\tcauto-source.json" '{ not json 30'
    $threw = $false
    try { $s = & $mod { param($p, $m) Get-TcSourceInfo -SourceRoot $p -ModuleDir $m } $r7 $srcModuleDir } catch { $threw = $true }
    Check 'source info: broken stamp JSON -> warning, no throw' (-not $threw -and $null -eq $s.commit -and @($s.warnings).Count -ge 1) "$(@($s.warnings) -join '; ')"
    $badMod = Join-Path $tmpRoot 'badpsd1-30'
    Write-File "$badMod\TwinCATAutomation.psd1" '@{ ModuleVersion = (Get-Date) }'
    $threw = $false
    try { $s = & $mod { param($p, $m) Get-TcSourceInfo -SourceRoot $p -ModuleDir $m } $r6 $badMod } catch { $threw = $true }
    Check 'source info: unreadable .psd1 -> warning, no throw' (-not $threw -and $null -eq $s.version -and @($s.warnings).Count -ge 1) "$(@($s.warnings) -join '; ')"
    $s = & $mod { param($p, $m) Get-TcSourceInfo -SourceRoot $p -ModuleDir $m } $r6 $srcModuleDir
    Check 'source info: nothing -> unknown' ($s.commitSource -eq 'unknown' -and $null -eq $s.commit -and $s.version -eq $psd1Version) ''

    # symbolic ref chain / reftable: no commit, a note instead
    $r8 = Join-Path $tmpRoot 'repo-symref30'
    Write-File "$r8\.git\HEAD" "ref: refs/heads/alias`n"
    Write-File "$r8\.git\refs\heads\alias" "ref: refs/heads/main`n"
    Write-File "$r8\.git\refs\heads\main" "$shaA`n"
    $g = & $mod { param($p) Read-TcGitCommit -RepoRoot $p } $r8
    Check 'git: symbolic ref chain -> commit null + note' ($null -eq $g.commit -and $g.note -like '*symbolic*') "$($g.note)"
    $r9 = Join-Path $tmpRoot 'repo-reftable30'
    Write-File "$r9\.git\HEAD" "ref: refs/heads/.invalid`n"
    $null = New-Item -ItemType Directory -Path "$r9\.git\reftable" -Force
    $g = & $mod { param($p) Read-TcGitCommit -RepoRoot $p } $r9
    Check 'git: reftable -> commit null + note' ($null -eq $g.commit -and $g.note -like '*reftable*') "$($g.note)"

    # SKILL.md name only from the frontmatter
    $sk = Join-Path $tmpRoot 'skillname30'
    Write-File "$sk\a.md" "---`ndescription: x`n---`n`nname: NotTheName`n"
    Write-File "$sk\b.md" "---`ndescription: x`nname: Real30`n---`nname: Other`n"
    $na = & $mod { param($p) Get-TcSkillName -Path $p } "$sk\a.md"
    $nb = & $mod { param($p) Get-TcSkillName -Path $p } "$sk\b.md"
    Check 'skill name: only inside the frontmatter' ($null -eq $na -and $nb -eq 'Real30') "a=$na b=$nb"

    # M1: the hash helper is not shadowed by another Private file (PlcOpen.ps1 has Get-TcFileSha256)
    $hf = Join-Path $sk 'b.md'
    $h = & $mod { param($p) Get-TcInstallFileSha256 $p } $hf
    Check 'hash helper inside the module: lower-case SHA256' ($h -ceq (Get-FileHash -LiteralPath $hf -Algorithm SHA256).Hash.ToLowerInvariant()) "$h"

    # S5: paths that leave the install folder are refused
    $travRoot = Join-Path $tmpRoot 'trav30\skill'
    $null = New-Item -ItemType Directory -Path $travRoot -Force
    foreach ($bad in @('../../outside30.txt', 'C:/Windows/win.ini', '/abs30', 'TwinCATAutomation\x.ps1', 'a/../b', '')) {
        $threw = $false
        try { $null = & $mod { param($a, $b) Compare-TcInstallFiles -InstallRoot $a -Expected $b } $travRoot @([pscustomobject]@{ path = $bad; sha256 = ('0' * 64) }) } catch { $threw = $true }
        Check "compare: invalid path '$bad' refused" $threw ''
    }
    Write-File "$travRoot\tcauto-install-manifest.json" ('{"schemaVersion":1,"files":[{"path":"../../outside30.txt","sha256":"' + ('0' * 64) + '","size":1}]}')
    $threw = $false
    try { $null = & $mod { param($p) Read-TcInstallManifest -Path $p } "$travRoot\tcauto-install-manifest.json" } catch { $threw = $true }
    Check 'read manifest: traversal path -> throws' $threw ''

    # ------------------------------------------------------------------ 2. installers
    $expectedCommit = (& $mod { param($p) Read-TcGitCommit -RepoRoot $p } $repoRoot)
    $expectedKeys = 'schemaVersion,name,module,sourceUrl,version,release,commit,ref,commitSource,installer,installedAt,sourcePath,hashAlgorithm,warnings,files'
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
    # S5: a manifest pointing outside the install folder is INVALID, nothing outside is read
    Write-File $mf ('{"schemaVersion":1,"files":[{"path":"../../outside30.txt","sha256":"' + ('0' * 64) + '","size":1}]}')
    $c = Invoke-ChildCommand ($verCmd -f '-Verify')
    $res = $null; try { $res = $c.Out | ConvertFrom-Json } catch { $c.Out }
    Check 'traversal manifest: Get-TcAutomationVersion -Verify -> INSTALL_MANIFEST_INVALID' ($null -ne $res -and -not $res.success -and $res.error.code -eq 'INSTALL_MANIFEST_INVALID') "$($res.error.code)"
    $v = Invoke-Child (Join-Path $repoRoot 'TwinCATSetup-Claude.ps1') @('-SkillDir', $dir, '-Verify')
    Check 'traversal manifest: installer -Verify exits 1' ($v.Code -eq 1 -and $v.Out -match 'INVALID') "exit $($v.Code)"

    # ------------------------------------------------------------------ M2: failures are failures
    # a source tree without Private\InstallManifest.ps1, and one without the SKILL.md source
    $partial = Join-Path $tmpRoot 'partial30-src'
    $null = New-Item -ItemType Directory -Path "$partial\src" -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot 'TwinCATSetup-Claude.ps1') -Destination $partial
    Copy-Item -LiteralPath $srcModuleDir -Destination "$partial\src\TwinCATAutomation" -Recurse
    $null = New-Item -ItemType Directory -Path "$partial\adapters\claude-code" -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot 'adapters\claude-code\SKILL.md') -Destination "$partial\adapters\claude-code\SKILL.md"
    Remove-Item -LiteralPath "$partial\src\TwinCATAutomation\Private\InstallManifest.ps1" -Force
    $pdir = Join-Path $tmpRoot 'partial30-skill'
    $v = Invoke-Child "$partial\TwinCATSetup-Claude.ps1" @('-SkillDir', $pdir, '-Verify')
    Check 'helper missing: -Verify exits 1' ($v.Code -eq 1) "exit $($v.Code)"
    $r = Invoke-Child "$partial\TwinCATSetup-Claude.ps1" @('-SkillDir', $pdir, '-SkipPrerequisites')
    Check 'helper missing: install exits 1, no "Installation Complete"' ($r.Code -eq 1 -and $r.Out -notmatch 'Installation Complete' -and -not (Test-Path -LiteralPath $pdir)) "exit $($r.Code)"
    Copy-Item -LiteralPath (Join-Path $srcModuleDir 'Private\InstallManifest.ps1') -Destination "$partial\src\TwinCATAutomation\Private\InstallManifest.ps1"
    Remove-Item -LiteralPath "$partial\adapters\claude-code\SKILL.md" -Force
    $r = Invoke-Child "$partial\TwinCATSetup-Claude.ps1" @('-SkillDir', $pdir, '-SkipPrerequisites')
    Check 'SKILL.md source missing: install exits 1, no "Installation Complete"' ($r.Code -eq 1 -and $r.Out -notmatch 'Installation Complete' -and $r.Out -match 'Install failed') "exit $($r.Code)"
    $v = Invoke-Child "$partial\TwinCATSetup-Claude.ps1" @('-SkillDir', $dir, '-Verify')
    Check 'SKILL.md source missing: -Verify exits 1' ($v.Code -eq 1) "exit $($v.Code)"

    # ------------------------------------------------------------------ S3: relative -SkillDir / -CodexHome
    # the PowerShell location differs from the process working directory in the child
    $work = Join-Path $tmpRoot 'work30'
    $null = New-Item -ItemType Directory -Path $work -Force
    $codexScript = Join-Path $repoRoot 'TwinCATSetup-Codex.ps1'
    $c = Invoke-ChildCommand ("Set-Location -LiteralPath '$work'; & '$codexScript' -SkillDir 'rel30skill' -CodexHome 'rel30home' -SkipPrerequisites *> `$null; exit `$LASTEXITCODE")
    $relSkill = Join-Path $work 'rel30skill\SKILL.md'
    $relText = if (Test-Path -LiteralPath $relSkill) { [System.IO.File]::ReadAllText($relSkill, [System.Text.Encoding]::UTF8) } else { '' }
    Check 'relative -SkillDir / -CodexHome: resolved against the PowerShell location' ($c.Code -eq 0 -and $relText.Contains((Join-Path $work 'rel30skill\TwinCATAutomation\TwinCATAutomation.psm1')) -and (Test-Path -LiteralPath (Join-Path $work 'rel30home\AGENTS.md'))) "exit $($c.Code)"
    $c = Invoke-ChildCommand ("Set-Location -LiteralPath '$work'; & '$codexScript' -SkillDir 'rel30skill' -CodexHome 'rel30home' -Verify *> `$null; exit `$LASTEXITCODE")
    Check 'relative -SkillDir: -Verify exits 0' ($c.Code -eq 0) "exit $($c.Code)"

    # case / 8.3 spelling of -SkillDir does not change the expected SKILL.md
    $caseDir = Join-Path $tmpRoot 'CaseDir30'
    $r = Invoke-Child (Join-Path $repoRoot 'TwinCATSetup-Claude.ps1') @('-SkillDir', $caseDir, '-SkipPrerequisites')
    $v = Invoke-Child (Join-Path $repoRoot 'TwinCATSetup-Claude.ps1') @('-SkillDir', $caseDir.ToLowerInvariant(), '-Verify')
    Check 'other case of -SkillDir: -Verify exits 0' ($r.Code -eq 0 -and $v.Code -eq 0) "install $($r.Code) verify $($v.Code)"
    $short = $null
    try { $short = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($caseDir).ShortPath } catch { $short = $null }
    if ($short -and $short -ne $caseDir) {
        $v = Invoke-Child (Join-Path $repoRoot 'TwinCATSetup-Claude.ps1') @('-SkillDir', $short, '-Verify')
        Check '8.3 -SkillDir: -Verify exits 0' ($v.Code -eq 0) "$short exit $($v.Code)"
    }
    else { "INFO 8.3 -SkillDir: no short name on this volume, not tested" }

    # ------------------------------------------------------------------ S4: -Uninstall only removes a skill folder
    $other = Join-Path $tmpRoot 'other30'
    Write-File "$other\keep30.txt" 'not a skill'
    $u = Invoke-Child (Join-Path $repoRoot 'TwinCATSetup-Claude.ps1') @('-SkillDir', $other, '-Uninstall')
    Check '-Uninstall on a foreign folder: refused (exit 1), files kept' ($u.Code -eq 1 -and (Test-Path -LiteralPath "$other\keep30.txt")) "exit $($u.Code)"
    $u = Invoke-Child (Join-Path $repoRoot 'TwinCATSetup-Antigravity.ps1') @('-SkillDir', $caseDir, '-Uninstall')
    Check '-Uninstall on an installed folder: removed (exit 0)' ($u.Code -eq 0 -and -not (Test-Path -LiteralPath $caseDir)) "exit $($u.Code)"

    # ------------------------------------------------------------------ S6: copied module folder, not <root>\src\TwinCATAutomation
    $fake = Join-Path $tmpRoot 'fake30'
    Write-File "$fake\.git\HEAD" "$shaA`n"
    $null = New-Item -ItemType Directory -Path "$fake\lib" -Force
    Copy-Item -LiteralPath $srcModuleDir -Destination "$fake\lib\TwinCATAutomation" -Recurse
    $c = Invoke-ChildCommand ("Import-Module '$fake\lib\TwinCATAutomation\TwinCATAutomation.psm1' -Force -WarningAction SilentlyContinue; Get-TcAutomationVersion | ConvertTo-Json -Depth 6 -Compress")
    $res = $null; try { $res = $c.Out | ConvertFrom-Json } catch { $c.Out }
    Check 'copied module folder: commit not taken from an unrelated .git' ($null -ne $res -and $res.success -and $res.data.commitSource -eq 'unknown' -and $null -eq $res.data.commit -and $res.data.version -eq $psd1Version) "$($res.data.commitSource) $($res.data.commit)"

    # ------------------------------------------------------------------ review round 2
    # R2-5: <x>\src\TwinCATAutomation with a .git above it is not enough; the repo markers decide
    $fake2 = Join-Path $tmpRoot 'fake30b'
    Write-File "$fake2\.git\HEAD" "$shaA`n"
    $null = New-Item -ItemType Directory -Path "$fake2\src" -Force
    Copy-Item -LiteralPath $srcModuleDir -Destination "$fake2\src\TwinCATAutomation" -Recurse
    $verSrc = "Import-Module '$fake2\src\TwinCATAutomation\TwinCATAutomation.psm1' -Force -WarningAction SilentlyContinue; Get-TcAutomationVersion | ConvertTo-Json -Depth 6 -Compress"
    $c = Invoke-ChildCommand $verSrc
    $res = $null; try { $res = $c.Out | ConvertFrom-Json } catch { $c.Out }
    Check 'src\TwinCATAutomation without repo markers: commit unknown' ($null -ne $res -and $res.data.commitSource -eq 'unknown' -and $null -eq $res.data.commit -and @($res.data.warnings).Count -ge 1) "$($res.data.commitSource)"
    Write-File "$fake2\TwinCATSetup-Claude.ps1" '# marker'
    Write-File "$fake2\adapters\claude-code\SKILL.md" '---'
    $c = Invoke-ChildCommand $verSrc
    $res = $null; try { $res = $c.Out | ConvertFrom-Json } catch { $c.Out }
    Check 'src\TwinCATAutomation with repo markers: commit from <root>\.git' ($null -ne $res -and $res.data.commitSource -eq 'git' -and $res.data.commit -eq $shaA) "$($res.data.commitSource) $($res.data.commit)"

    # R2-3 / nit: path normalization edge cases
    $rp = { param($p) Resolve-TcInstallPath -Path $p -SessionState $ExecutionContext.SessionState }
    $sysDrive = [System.IO.Path]::GetPathRoot($env:SystemRoot)
    $r0 = & $mod $rp $sysDrive
    Check "resolve: drive root stays '$sysDrive'" ($r0 -eq $sysDrive) "$r0"
    $r0 = & $mod $rp ("Microsoft.PowerShell.Core\FileSystem::" + $env:SystemRoot)
    Check 'resolve: FileSystem:: provider path accepted' ($r0 -eq $env:SystemRoot) "$r0"
    foreach ($bad in @('HKCU:\Software', ($sysDrive + 'Win*'), ($sysDrive + 'x?30'))) {
        $threw = $false
        try { $null = & $mod $rp $bad } catch { $threw = $true }
        Check "resolve: '$bad' refused" $threw ''
    }
    $unc = '\\localhost\' + $sysDrive.Substring(0, 1) + '$\Windows'
    $r0 = $null; try { $r0 = & $mod $rp $unc } catch { $r0 = "THROW $($_.Exception.Message)" }
    Check 'resolve: UNC path keeps its share root' ([string]$r0 -like '\\localhost\*$\Windows') "$r0"

    # [ ] in the folder name: install, verify, uninstall
    $br = Join-Path $tmpRoot 'sk[30]'
    $r = Invoke-Child (Join-Path $repoRoot 'TwinCATSetup-Claude.ps1') @('-SkillDir', $br, '-SkipPrerequisites')
    $v = Invoke-Child (Join-Path $repoRoot 'TwinCATSetup-Claude.ps1') @('-SkillDir', $br, '-Verify')
    $u = Invoke-Child (Join-Path $repoRoot 'TwinCATSetup-Claude.ps1') @('-SkillDir', $br, '-Uninstall')
    Check '[ ] in -SkillDir: install / verify / uninstall' ($r.Code -eq 0 -and $v.Code -eq 0 -and $u.Code -eq 0 -and -not (Test-Path -LiteralPath $br)) "install $($r.Code) verify $($v.Code) uninstall $($u.Code)"

    # R2-4: a bogus manifest does not make a folder deletable
    $bogus = Join-Path $tmpRoot 'bogus30'
    Write-File "$bogus\tcauto-install-manifest.json" '{}'
    Write-File "$bogus\SKILL.md" 'user file'
    Write-File "$bogus\user30.txt" 'keep me'
    $u = Invoke-Child (Join-Path $repoRoot 'TwinCATSetup-Claude.ps1') @('-SkillDir', $bogus, '-Uninstall')
    Check '-Uninstall: {} manifest + SKILL.md + user file -> refused, kept' ($u.Code -eq 1 -and (Test-Path -LiteralPath "$bogus\user30.txt")) "exit $($u.Code)"
    Write-File "$bogus\tcauto-install-manifest.json" '{"schemaVersion":1,"installer":"other30","files":[]}'
    $u = Invoke-Child (Join-Path $repoRoot 'TwinCATSetup-Claude.ps1') @('-SkillDir', $bogus, '-Uninstall')
    Check '-Uninstall: manifest of an unknown installer -> refused' ($u.Code -eq 1 -and (Test-Path -LiteralPath "$bogus\user30.txt")) "exit $($u.Code)"
    Remove-Item -LiteralPath "$bogus\SKILL.md" -Force
    Write-File "$bogus\tcauto-install-manifest.json" '{"schemaVersion":1,"installer":"claude-code","files":[]}'
    $u = Invoke-Child (Join-Path $repoRoot 'TwinCATSetup-Claude.ps1') @('-SkillDir', $bogus, '-Uninstall')
    Check '-Uninstall: valid manifest but no SKILL.md -> refused' ($u.Code -eq 1 -and (Test-Path -LiteralPath "$bogus\user30.txt")) "exit $($u.Code)"

    # R2-1 / R2-2: locked files
    $lockDir = Join-Path $tmpRoot 'lock30'
    $r = Invoke-Child (Join-Path $repoRoot 'TwinCATSetup-Claude.ps1') @('-SkillDir', $lockDir, '-SkipPrerequisites')
    $lockFile = Join-Path $lockDir 'SKILL.md'
    $fs = [System.IO.File]::Open($lockFile, 'Open', 'Read', 'None')
    try {
        $c = Invoke-ChildCommand ("Import-Module '$lockDir\TwinCATAutomation\TwinCATAutomation.psm1' -Force -WarningAction SilentlyContinue; Get-TcAutomationVersion -Verify | ConvertTo-Json -Depth 8 -Compress")
        $res = $null; try { $res = $c.Out | ConvertFrom-Json } catch { $c.Out }
        Check 'locked file: Get-TcAutomationVersion -Verify -> MISMATCH with data.verify.unreadable' ($null -ne $res -and $res.error.code -eq 'INSTALL_MANIFEST_MISMATCH' -and (@($res.data.verify.unreadable | ForEach-Object { $_.path }) -contains 'SKILL.md')) "$($res.error.code)"
        $v = Invoke-Child (Join-Path $repoRoot 'TwinCATSetup-Claude.ps1') @('-SkillDir', $lockDir, '-Verify')
        Check 'locked file: installer -Verify exits 1' ($v.Code -eq 1) "exit $($v.Code)"
        $u = Invoke-Child (Join-Path $repoRoot 'TwinCATSetup-Claude.ps1') @('-SkillDir', $lockDir, '-Uninstall')
        Check 'locked file: -Uninstall cannot remove -> exit 1' ($u.Code -eq 1 -and $u.Out -match 'Could not remove') "exit $($u.Code)"
    }
    finally { $fs.Dispose() }
    $c = Invoke-ChildCommand ("Import-Module '$($installs[2].Dir)\TwinCATAutomation\TwinCATAutomation.psm1' -Force -WarningAction SilentlyContinue; Get-TcAutomationVersion | ConvertTo-Json -Depth 8 -Compress")
    $res = $null; try { $res = $c.Out | ConvertFrom-Json } catch { $c.Out }
    Check 'installed mode: data.warnings present (array)' ($null -ne $res -and $res.success -and $null -ne $res.data.PSObject.Properties['warnings']) ''

    # R2-1: Codex AGENTS.md cannot be written -> exit 1, no "Installation Complete"
    $badHome = Join-Path $tmpRoot 'codex30-badhome'
    $null = New-Item -ItemType Directory -Path "$badHome\AGENTS.md" -Force   # a folder where the file should go
    $r = Invoke-Child $codexScript @('-SkillDir', (Join-Path $tmpRoot 'codex30-skill2'), '-CodexHome', $badHome, '-SkipPrerequisites')
    Check 'Codex AGENTS.md not writable: exit 1, no "Installation Complete"' ($r.Code -eq 1 -and $r.Out -notmatch 'Installation Complete' -and $r.Out -match 'Could not write') "exit $($r.Code)"

    # R2-1: failed prerequisites -> exit 1 (module import fails in this copy)
    $broken = Join-Path $tmpRoot 'broken30-src'
    $null = New-Item -ItemType Directory -Path "$broken\src" -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot 'TwinCATSetup-Antigravity.ps1') -Destination $broken
    Copy-Item -LiteralPath $srcModuleDir -Destination "$broken\src\TwinCATAutomation" -Recurse
    Write-File "$broken\src\TwinCATAutomation\TwinCATAutomation.psm1" "throw 'broken module 30'"
    $null = New-Item -ItemType Directory -Path "$broken\.agents\skills\twincat" -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot '.agents\skills\twincat\SKILL.md') -Destination "$broken\.agents\skills\twincat\SKILL.md"
    $bdir = Join-Path $tmpRoot 'broken30-skill'
    $r = Invoke-Child "$broken\TwinCATSetup-Antigravity.ps1" @('-SkillDir', $bdir)
    Check 'prerequisites failed: exit 1, nothing installed' ($r.Code -eq 1 -and $r.Out -notmatch 'Installation Complete' -and -not (Test-Path -LiteralPath $bdir)) "exit $($r.Code)"

    # nit: source warnings under $WarningPreference = 'Stop' do not fail a finished install
    Write-File "$broken\src\TwinCATAutomation\TwinCATAutomation.psm1" ([System.IO.File]::ReadAllText((Join-Path $srcModuleDir 'TwinCATAutomation.psm1')))
    Write-File "$broken\tcauto-source.json" '{"commit":"not-hex-30","release":"v0"}'
    $agScript = Join-Path $broken 'TwinCATSetup-Antigravity.ps1'
    $c = Invoke-ChildCommand ("`$WarningPreference = 'Stop'; & '$agScript' -SkillDir '$bdir' -SkipPrerequisites *> `$null; exit `$LASTEXITCODE")
    $wm = if (Test-Path -LiteralPath "$bdir\tcauto-install-manifest.json") { [System.IO.File]::ReadAllText("$bdir\tcauto-install-manifest.json") | ConvertFrom-Json } else { $null }
    Check 'WarningPreference Stop: install with source warnings still exit 0, warnings in manifest' ($c.Code -eq 0 -and $null -ne $wm -and @($wm.warnings).Count -ge 1 -and $wm.commitSource -eq 'release-stamp') "exit $($c.Code)"

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
