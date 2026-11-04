# Install manifest (#30).
#
# TwinCATSetup-Claude.ps1 / -Codex.ps1 / -Antigravity.ps1 copy the module and a SKILL.md into a skill
# directory that is not a git checkout. They write tcauto-install-manifest.json next to SKILL.md:
# source repository, module version, commit, install time and the SHA256 of every installed file.
# Get-TcAutomationVersion reads it (offline) and -Verify compares the installed files with it.
#
# The installers dot-source this file directly from the source tree (they run before anything is
# installed), so it uses nothing but what it defines itself and plain .NET / built-in cmdlets.
#
# Where the commit comes from (Get-TcSourceInfo), in this order:
#   1. tcauto-source.json in the source root: a build-time stamp a release zip (#20) carries
#      ({"sourceUrl", "commit", "ref", "release"}); no git needed at install time.
#   2. the .git of a source checkout, read as files (HEAD, refs/heads/*, packed-refs; a worktree's
#      .git file + commondir). git itself is never started.
#   3. neither: commit = null, commitSource = 'unknown'.

$script:TcInstallManifestName = 'tcauto-install-manifest.json'
$script:TcSourceStampName = 'tcauto-source.json'
$script:TcInstallManifestSchemaVersion = 1

function Read-TcUtf8Text {
    # UTF-8 text with or without BOM (Windows PowerShell 5.1 Get-Content reads BOM-less files as ANSI).
    param([Parameter(Mandatory)][string]$Path)
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Write-TcUtf8Text {
    # UTF-8 without BOM (5.1 Set-Content -Encoding UTF8 writes a BOM).
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-TcSha256Hex {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-TcFileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-TcGitHeadInfo {
    <#
    .SYNOPSIS
        Reads the checked-out commit of a git working tree from its .git files (no git process).
        Returns @{ commit; ref } ($null commit for an unborn branch) or $null when RepoRoot has no .git.
    #>
    param([Parameter(Mandatory)][string]$RepoRoot)

    $dotGit = Join-Path $RepoRoot '.git'
    $gitDir = $null
    if (Test-Path -LiteralPath $dotGit -PathType Container) {
        $gitDir = $dotGit
    }
    elseif (Test-Path -LiteralPath $dotGit -PathType Leaf) {
        # linked worktree / submodule: ".git" is a file "gitdir: <path>"
        $line = (Read-TcUtf8Text $dotGit).Trim()
        if ($line -match '^gitdir:\s*(.+)$') {
            $p = $Matches[1].Trim()
            if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path $RepoRoot $p }
            $gitDir = [System.IO.Path]::GetFullPath($p)
        }
    }
    if ($null -eq $gitDir) { return $null }
    $headFile = Join-Path $gitDir 'HEAD'
    if (-not (Test-Path -LiteralPath $headFile -PathType Leaf)) { return $null }

    # a linked worktree keeps HEAD in its own dir, branches and packed-refs in the common dir
    $commonDir = $gitDir
    $commonFile = Join-Path $gitDir 'commondir'
    if (Test-Path -LiteralPath $commonFile -PathType Leaf) {
        $c = (Read-TcUtf8Text $commonFile).Trim()
        if (-not [System.IO.Path]::IsPathRooted($c)) { $c = Join-Path $gitDir $c }
        $commonDir = [System.IO.Path]::GetFullPath($c)
    }

    $head = (Read-TcUtf8Text $headFile).Trim()
    $ref = $null
    $commit = $null
    if ($head -match '^ref:\s*(\S+)$') {
        $ref = $Matches[1]
        foreach ($dir in @($gitDir, $commonDir)) {
            $refFile = Join-Path $dir ($ref -replace '/', '\')
            if (Test-Path -LiteralPath $refFile -PathType Leaf) { $commit = (Read-TcUtf8Text $refFile).Trim(); break }
        }
        if ($null -eq $commit) {
            $packed = Join-Path $commonDir 'packed-refs'
            if (Test-Path -LiteralPath $packed -PathType Leaf) {
                foreach ($l in [System.IO.File]::ReadAllLines($packed)) {
                    if ($l -match '^([0-9a-fA-F]{40,64}) (\S+)$' -and $Matches[2] -eq $ref) { $commit = $Matches[1]; break }
                }
            }
        }
    }
    else {
        $commit = $head   # detached HEAD
    }
    if ($null -ne $commit) {
        $commit = $commit.ToLowerInvariant()
        # SHA-1 (40) or SHA-256 (64) object names only
        if ($commit -notmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$') { $commit = $null }
    }
    return [ordered]@{ commit = $commit; ref = $ref }
}

function Get-TcSourceInfo {
    <#
    .SYNOPSIS
        Source repository, module version and commit of a source tree (a checkout or an extracted
        release zip). ModuleDir is the TwinCATAutomation module folder of that tree.
    #>
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$ModuleDir
    )

    $version = $null
    $sourceUrl = $null
    $psd1 = Join-Path $ModuleDir 'TwinCATAutomation.psd1'
    if (Test-Path -LiteralPath $psd1 -PathType Leaf) {
        $data = Import-PowerShellDataFile -LiteralPath $psd1
        $version = [string]$data.ModuleVersion
        if ($data.PrivateData -and $data.PrivateData.PSData) { $sourceUrl = [string]$data.PrivateData.PSData.ProjectUri }
    }

    $info = [ordered]@{
        sourceUrl    = $sourceUrl
        version      = $version
        release      = $null
        commit       = $null
        ref          = $null
        commitSource = 'unknown'
    }

    $stamp = Join-Path $SourceRoot $script:TcSourceStampName
    if (Test-Path -LiteralPath $stamp -PathType Leaf) {
        $s = (Read-TcUtf8Text $stamp) | ConvertFrom-Json
        if ($s.sourceUrl) { $info.sourceUrl = [string]$s.sourceUrl }
        if ($s.release) { $info.release = [string]$s.release }
        if ($s.ref) { $info.ref = [string]$s.ref }
        if ($s.commit) { $info.commit = ([string]$s.commit).ToLowerInvariant() }
        $info.commitSource = 'release-stamp'
        return $info
    }

    $git = Get-TcGitHeadInfo -RepoRoot $SourceRoot
    if ($null -ne $git) {
        $info.commit = $git.commit
        $info.ref = $git.ref
        $info.commitSource = 'git'
    }
    return $info
}

function Get-TcSkillName {
    # "name:" of the SKILL.md frontmatter, $null when there is none
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $m = [regex]::Match((Read-TcUtf8Text $Path), '\A---\r?\n(?:.*\r?\n)*?name:\s*(.+?)\s*\r?\n')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Get-TcInstallFileHashes {
    <#
    .SYNOPSIS
        SHA256 of every file below InstallRoot named by Include (files or folders, recursive), as a
        list of [ordered]@{ path ('/'-separated, relative); sha256; size }, sorted by path.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string[]]$Include
    )
    $root = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\', '/')
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($inc in $Include) {
        $p = Join-Path $root $inc
        if (Test-Path -LiteralPath $p -PathType Leaf) { $files = @(Get-Item -LiteralPath $p -Force) }
        elseif (Test-Path -LiteralPath $p -PathType Container) { $files = @(Get-ChildItem -LiteralPath $p -Recurse -File -Force) }
        else { continue }
        foreach ($f in $files) {
            $rel = $f.FullName.Substring($root.Length).TrimStart('\', '/') -replace '\\', '/'
            if ($rel -eq $script:TcInstallManifestName) { continue }
            $items.Add([ordered]@{ path = $rel; sha256 = (Get-TcFileSha256 $f.FullName); size = [long]$f.Length })
        }
    }
    return @($items | Sort-Object -Property @{ Expression = { $_.path } })
}

function Write-TcInstallManifest {
    <#
    .SYNOPSIS
        Writes tcauto-install-manifest.json into InstallRoot (UTF-8 without BOM, read-only attribute)
        and returns the manifest. An existing manifest is replaced (an update install).
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$ModuleDir,
        [Parameter(Mandatory)][string]$Installer,
        [string[]]$Include = @('SKILL.md', 'TwinCATAutomation')
    )
    $src = Get-TcSourceInfo -SourceRoot $SourceRoot -ModuleDir $ModuleDir
    $files = @(Get-TcInstallFileHashes -InstallRoot $InstallRoot -Include $Include)
    $manifest = [ordered]@{
        schemaVersion = $script:TcInstallManifestSchemaVersion
        name          = (Get-TcSkillName (Join-Path $InstallRoot 'SKILL.md'))
        module        = 'TwinCATAutomation'
        sourceUrl     = $src.sourceUrl
        version       = $src.version
        release       = $src.release
        commit        = $src.commit
        ref           = $src.ref
        commitSource  = $src.commitSource
        installer     = $Installer
        installedAt   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
        sourcePath    = [System.IO.Path]::GetFullPath($SourceRoot)
        hashAlgorithm = 'SHA256'
        files         = $files
    }
    $path = Join-Path $InstallRoot $script:TcInstallManifestName
    if (Test-Path -LiteralPath $path -PathType Leaf) { (Get-Item -LiteralPath $path -Force).IsReadOnly = $false }
    Write-TcUtf8Text -Path $path -Content ($manifest | ConvertTo-Json -Depth 6)
    (Get-Item -LiteralPath $path -Force).IsReadOnly = $true
    return $manifest
}

function Read-TcInstallManifest {
    # Parsed manifest; throws when the file is not a manifest this module understands.
    param([Parameter(Mandatory)][string]$Path)
    $m = (Read-TcUtf8Text $Path) | ConvertFrom-Json
    if ($null -eq $m -or $null -eq $m.schemaVersion -or $null -eq $m.files) {
        throw "$Path is not a TwinCATAutomation install manifest (schemaVersion / files missing)"
    }
    if ([int]$m.schemaVersion -gt $script:TcInstallManifestSchemaVersion) {
        throw "$Path has schemaVersion $($m.schemaVersion); this module reads up to $($script:TcInstallManifestSchemaVersion)"
    }
    return $m
}

function Find-TcInstallManifest {
    # The manifest of an installed module: <skill dir>\tcauto-install-manifest.json, the module folder
    # being <skill dir>\TwinCATAutomation. $null when the module does not run from an installed copy.
    param([Parameter(Mandatory)][string]$ModuleDir)
    $p = Join-Path (Split-Path -Parent ([System.IO.Path]::GetFullPath($ModuleDir).TrimEnd('\', '/'))) $script:TcInstallManifestName
    if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    return $null
}

function Compare-TcInstallFiles {
    <#
    .SYNOPSIS
        Compares the files below InstallRoot with Expected (items with path + sha256). Returns
        [ordered]@{ ok; checked; matched; mismatched [{path, expected, actual}]; missing [path];
        extra [path] }. extra = files in a folder that Expected covers (e.g. TwinCATAutomation/)
        that Expected does not list; loose files next to SKILL.md are not reported.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Expected
    )
    $root = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\', '/')
    $mismatched = [System.Collections.Generic.List[object]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()
    $extra = [System.Collections.Generic.List[string]]::new()
    $known = @{}   # case-insensitive, like the file system
    $dirs = @{}
    $matched = 0
    foreach ($e in $Expected) {
        $rel = [string]$e.path
        $known[$rel] = $true
        if ($rel.Contains('/')) { $dirs[$rel.Split('/')[0]] = $true }
        $full = Join-Path $root ($rel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { $missing.Add($rel); continue }
        $actual = Get-TcFileSha256 $full
        if ($actual -eq ([string]$e.sha256).ToLowerInvariant()) { $matched++ }
        else { $mismatched.Add([ordered]@{ path = $rel; expected = ([string]$e.sha256).ToLowerInvariant(); actual = $actual }) }
    }
    foreach ($d in ($dirs.Keys | Sort-Object)) {
        $dirPath = Join-Path $root $d
        if (-not (Test-Path -LiteralPath $dirPath -PathType Container)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $dirPath -Recurse -File -Force)) {
            $rel = $f.FullName.Substring($root.Length).TrimStart('\', '/') -replace '\\', '/'
            if (-not $known.ContainsKey($rel)) { $extra.Add($rel) }
        }
    }
    return [ordered]@{
        ok         = ($mismatched.Count -eq 0 -and $missing.Count -eq 0 -and $extra.Count -eq 0)
        checked    = @($Expected).Count
        matched    = $matched
        mismatched = @($mismatched)
        missing    = @($missing | Sort-Object)
        extra      = @($extra | Sort-Object)
    }
}

function Get-TcRenderedSkillContent {
    # SKILL.md as installed: the repo file with <module-path> replaced literally (no regex tokens).
    param([Parameter(Mandatory)][string]$SkillSource, [Parameter(Mandatory)][string]$ModulePath)
    return (Read-TcUtf8Text $SkillSource).Replace('<module-path>', $ModulePath)
}

function Get-TcExpectedInstallFiles {
    # What an install from this source writes: SKILL.md (rendered, UTF-8 without BOM) and the module tree.
    param(
        [Parameter(Mandatory)][string]$SourceModuleDir,
        [Parameter(Mandatory)][string]$SkillContent
    )
    $items = [System.Collections.Generic.List[object]]::new()
    $skillBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($SkillContent)
    $items.Add([ordered]@{ path = 'SKILL.md'; sha256 = (Get-TcSha256Hex $skillBytes); size = [long]$skillBytes.Length })
    $root = [System.IO.Path]::GetFullPath($SourceModuleDir).TrimEnd('\', '/')
    foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -File -Force)) {
        $rel = 'TwinCATAutomation/' + ($f.FullName.Substring($root.Length).TrimStart('\', '/') -replace '\\', '/')
        $items.Add([ordered]@{ path = $rel; sha256 = (Get-TcFileSha256 $f.FullName); size = [long]$f.Length })
    }
    return @($items | Sort-Object -Property @{ Expression = { $_.path } })
}

function Install-TcSkillPayload {
    <#
    .SYNOPSIS
        The install step shared by the three installers: copies the module to <SkillDir>\TwinCATAutomation
        (replacing an older copy), writes SKILL.md with the module path filled in, then the manifest.
        Returns the manifest.
    #>
    param(
        [Parameter(Mandatory)][string]$SkillDir,
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$SkillSource,
        [Parameter(Mandatory)][string]$Installer
    )
    $srcModule = Join-Path $SourceRoot 'src\TwinCATAutomation'
    $destModule = Join-Path $SkillDir 'TwinCATAutomation'
    if (-not (Test-Path -LiteralPath $SkillDir)) { New-Item -Path $SkillDir -ItemType Directory -Force | Out-Null }
    if (Test-Path -LiteralPath $destModule) { Remove-Item -LiteralPath $destModule -Recurse -Force }
    Copy-Item -LiteralPath $srcModule -Destination $destModule -Recurse -Force
    $absModulePath = Join-Path $destModule 'TwinCATAutomation.psm1'
    Write-TcUtf8Text -Path (Join-Path $SkillDir 'SKILL.md') -Content (Get-TcRenderedSkillContent -SkillSource $SkillSource -ModulePath $absModulePath)
    return Write-TcInstallManifest -InstallRoot $SkillDir -SourceRoot $SourceRoot -ModuleDir $srcModule -Installer $Installer
}

function Invoke-TcInstallVerify {
    <#
    .SYNOPSIS
        Read-only -Verify of the installers: prints the manifest (source, version, commit, install
        time), checks the installed files against the manifest hashes and against what an install
        from SourceRoot would write. Returns 0 (match) or 1 (mismatch, not installed, no manifest).
        A different commit with identical files is only a warning (e.g. a docs-only commit).
    #>
    param(
        [Parameter(Mandatory)][string]$SkillDir,
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$SkillSource,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$InstallerScript
    )
    $srcModule = Join-Path $SourceRoot 'src\TwinCATAutomation'
    $absModulePath = Join-Path (Join-Path $SkillDir 'TwinCATAutomation') 'TwinCATAutomation.psm1'
    $problems = [System.Collections.Generic.List[string]]::new()

    Write-Host ""
    Write-Host "=== Verify TwinCAT Skill ($Label) ===" -ForegroundColor Cyan
    Write-Host "  Installer source: $SourceRoot" -ForegroundColor DarkGray
    Write-Host "  Installed:        $SkillDir" -ForegroundColor DarkGray
    Write-Host ""
    if (-not (Test-Path -LiteralPath $SkillDir -PathType Container)) {
        Write-Host "  [MISMATCH] Skill not installed: $SkillDir" -ForegroundColor Red
        Write-Host ""
        return 1
    }

    $src = Get-TcSourceInfo -SourceRoot $SourceRoot -ModuleDir $srcModule
    $manifestPath = Join-Path $SkillDir $script:TcInstallManifestName
    $manifest = $null
    Write-Host "--- Manifest ($($script:TcInstallManifestName)) ---" -ForegroundColor Cyan
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        Write-Host "  [MISSING]  no manifest: installed by an older installer" -ForegroundColor Red
        $problems.Add('manifest missing')
    }
    else {
        try {
            $manifest = Read-TcInstallManifest -Path $manifestPath
            Write-Host "  name:        $($manifest.name)"
            Write-Host "  sourceUrl:   $($manifest.sourceUrl)"
            Write-Host "  version:     $($manifest.version)$(if ($manifest.release) { " (release $($manifest.release))" })"
            Write-Host "  commit:      $(if ($manifest.commit) { $manifest.commit } else { '(unknown)' }) [$($manifest.commitSource)]$(if ($manifest.ref) { " $($manifest.ref)" })"
            Write-Host "  installedAt: $($manifest.installedAt) by $($manifest.installer)"
            Write-Host "  files:       $(@($manifest.files).Count)"
        }
        catch {
            Write-Host "  [INVALID]  $($_.Exception.Message)" -ForegroundColor Red
            $problems.Add('manifest invalid')
        }
    }

    Write-Host ""
    Write-Host "--- Integrity (installed files vs manifest) ---" -ForegroundColor Cyan
    if ($null -ne $manifest) {
        $r = Compare-TcInstallFiles -InstallRoot $SkillDir -Expected @($manifest.files)
        Write-TcInstallCompareLines -Result $r -What 'manifest'
        if (-not $r.ok) { $problems.Add('installed files differ from the manifest') }
    }
    else {
        Write-Host "  [SKIP]     no readable manifest" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "--- Source (installed files vs installer source) ---" -ForegroundColor Cyan
    Write-Host "  source version: $($src.version)  commit: $(if ($src.commit) { $src.commit } else { '(unknown)' }) [$($src.commitSource)]"
    $expected = Get-TcExpectedInstallFiles -SourceModuleDir $srcModule -SkillContent (Get-TcRenderedSkillContent -SkillSource $SkillSource -ModulePath $absModulePath)
    $r2 = Compare-TcInstallFiles -InstallRoot $SkillDir -Expected $expected
    Write-TcInstallCompareLines -Result $r2 -What 'source'
    if (-not $r2.ok) { $problems.Add('installed files differ from the installer source') }
    if ($null -ne $manifest) {
        if ([string]$manifest.version -ne [string]$src.version) {
            Write-Host "  [DIFFERENT] version: installed $($manifest.version), source $($src.version)" -ForegroundColor Yellow
        }
        if ($manifest.commit -and $src.commit -and $manifest.commit -ne $src.commit) {
            $sev = if ($r2.ok) { 'files identical' } else { 'files differ' }
            Write-Host "  [DIFFERENT] commit: installed $($manifest.commit), source $($src.commit) ($sev)" -ForegroundColor Yellow
        }
    }

    Write-Host ""
    if ($problems.Count -eq 0) {
        Write-Host "Result: match" -ForegroundColor Green
        Write-Host ""
        return 0
    }
    Write-Host "Result: mismatch ($($problems.Count) item(s))" -ForegroundColor Red
    foreach ($p in $problems) { Write-Host "  - $p" -ForegroundColor Yellow }
    Write-Host ""
    Write-Host "Run '$InstallerScript' to reinstall." -ForegroundColor DarkGray
    Write-Host ""
    return 1
}

function Write-TcInstallCompareLines {
    param([Parameter(Mandatory)]$Result, [Parameter(Mandatory)][string]$What)
    foreach ($m in $Result.mismatched) { Write-Host "  [MISMATCH] $($m.path)  (content differs from $What)" -ForegroundColor Red }
    foreach ($m in $Result.missing) { Write-Host "  [MISMATCH] $m  (missing in install)" -ForegroundColor Red }
    foreach ($m in $Result.extra) { Write-Host "  [MISMATCH] $m  (extra in install, not in $What)" -ForegroundColor Red }
    if ($Result.ok) { Write-Host "  [MATCH]    $($Result.matched) file(s)" -ForegroundColor Green }
}
