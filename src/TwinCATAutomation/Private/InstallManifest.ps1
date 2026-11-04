# Install manifest (#30).
#
# TwinCATSetup-Claude.ps1 / -Codex.ps1 / -Antigravity.ps1 copy the module and a SKILL.md into a skill
# directory that is not a git checkout. They write tcauto-install-manifest.json next to SKILL.md:
# source repository, module version, commit, install time and the SHA256 of every installed file.
# Get-TcAutomationVersion reads it (offline) and -Verify compares the installed files with it.
#
# The installers dot-source this file directly from the source tree (they run before anything is
# installed), so it uses nothing but what it defines itself and plain .NET / built-in cmdlets.
# Every function name here is unique in src/TwinCATAutomation (the module dot-sources all Private
# files, a later definition with the same name silently replaces an earlier one; scripts/check.ps1
# "functions" enforces it).
#
# Where the commit comes from (Get-TcSourceInfo), in this order:
#   1. the .git of a source checkout, read as files (HEAD, refs/heads/*, packed-refs; a worktree's
#      .git file + commondir). git itself is never started.
#   2. tcauto-source.json in the source root. RESERVED for the release zip of #20: a build-time
#      stamp {"sourceUrl", "commit", "ref", "release"} so no git is needed at install time. Only
#      read when there is no .git; the format is fixed by #20.
#   3. neither: commit = null, commitSource = 'unknown'.

$script:TcInstallManifestName = 'tcauto-install-manifest.json'
$script:TcSourceStampName = 'tcauto-source.json'
$script:TcInstallManifestSchemaVersion = 1

function Read-TcInstallText {
    # UTF-8 text with or without BOM (Windows PowerShell 5.1 Get-Content reads BOM-less files as ANSI).
    param([Parameter(Mandatory)][string]$Path)
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Write-TcInstallText {
    # UTF-8 without BOM (5.1 Set-Content -Encoding UTF8 writes a BOM).
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-TcInstallSha256Hex {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-TcInstallFileSha256 {
    # lower-case hex SHA256 of a file; throws when it cannot be read
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Resolve-TcInstallPath {
    <#
    .SYNOPSIS
        Absolute, normalized form of a folder path given to an installer: relative paths are resolved
        against the PowerShell location (not the process working directory), and every component
        that exists on disk gets its real spelling (case, 8.3 short names expanded), so the module
        path written into SKILL.md is the same at install and at -Verify.
    #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$SessionState)
    $full = [System.IO.Path]::GetFullPath($SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)).TrimEnd('\', '/')
    $root = [System.IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrEmpty($root) -or $full.Length -le $root.Length) { return $full }
    $current = $root
    $parts = $full.Substring($root.Length).Split([char[]]@('\', '/'), [System.StringSplitOptions]::RemoveEmptyEntries)
    $exists = $true
    foreach ($part in $parts) {
        $next = $null
        if ($exists -and (Test-Path -LiteralPath $current -PathType Container)) {
            try {
                # the search pattern matches the long and the 8.3 name; the result is the long name
                $hit = @([System.IO.Directory]::GetFileSystemEntries($current, $part))
                if ($hit.Count -eq 1) { $next = $hit[0] }
            } catch { $next = $null }
        }
        if ($null -eq $next) { $exists = $false; $next = Join-Path $current $part }
        $current = $next
    }
    return $current
}

function Test-TcInstallRelPath {
    # A files[].path of a manifest: relative, '/'-separated, no '..', no drive / root / backslash.
    param([AllowNull()][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ($Path.Contains('\') -or $Path.Contains(':') -or $Path.StartsWith('/')) { return $false }
    foreach ($seg in $Path.Split('/')) {
        if ($seg -eq '' -or $seg -eq '.' -or $seg -eq '..') { return $false }
    }
    return $true
}

function Get-TcGitHeadInfo {
    <#
    .SYNOPSIS
        Reads the checked-out commit of a git working tree from its .git files (no git process).
        Returns @{ commit; ref; note } or $null when RepoRoot has no .git. commit is $null (with a
        note) for an unborn branch, a symbolic ref chain or a reftable repository (refs not stored
        as files).
    #>
    param([Parameter(Mandatory)][string]$RepoRoot)

    $dotGit = Join-Path $RepoRoot '.git'
    $gitDir = $null
    if (Test-Path -LiteralPath $dotGit -PathType Container) {
        $gitDir = $dotGit
    }
    elseif (Test-Path -LiteralPath $dotGit -PathType Leaf) {
        # linked worktree / submodule: ".git" is a file "gitdir: <path>"
        $line = (Read-TcInstallText $dotGit).Trim()
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
        $c = (Read-TcInstallText $commonFile).Trim()
        if (-not [System.IO.Path]::IsPathRooted($c)) { $c = Join-Path $gitDir $c }
        $commonDir = [System.IO.Path]::GetFullPath($c)
    }

    $head = (Read-TcInstallText $headFile).Trim()
    $ref = $null
    $commit = $null
    $note = $null
    if ($head -match '^ref:\s*(\S+)$') {
        $ref = $Matches[1]
        if ($ref -match '(^|/)\.invalid$' -or (Test-Path -LiteralPath (Join-Path $commonDir 'reftable') -PathType Container)) {
            # reftable format: HEAD points at refs/heads/.invalid, the real refs are binary tables
            return [ordered]@{ commit = $null; ref = $null; note = 'reftable repository: refs are not plain files, commit not read (git is not started)' }
        }
        foreach ($dir in @($gitDir, $commonDir)) {
            $refFile = Join-Path $dir ($ref -replace '/', '\')
            if (Test-Path -LiteralPath $refFile -PathType Leaf) { $commit = (Read-TcInstallText $refFile).Trim(); break }
        }
        if ($null -eq $commit) {
            $packed = Join-Path $commonDir 'packed-refs'
            if (Test-Path -LiteralPath $packed -PathType Leaf) {
                foreach ($l in [System.IO.File]::ReadAllLines($packed)) {
                    if ($l -match '^([0-9a-fA-F]{40,64}) (\S+)$' -and $Matches[2] -eq $ref) { $commit = $Matches[1]; break }
                }
            }
        }
        if ($null -eq $commit) { $note = "unborn branch: $ref has no commit" }
        elseif ($commit -match '^ref:') { $commit = $null; $note = "symbolic ref chain ($ref -> another ref) is not followed" }
    }
    else {
        $commit = $head   # detached HEAD
    }
    if ($null -ne $commit) {
        $commit = $commit.ToLowerInvariant()
        # SHA-1 (40) or SHA-256 (64) object names only
        if ($commit -notmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$') { $commit = $null; $note = 'HEAD / ref does not hold a 40 / 64 hex object name' }
    }
    return [ordered]@{ commit = $commit; ref = $ref; note = $note }
}

function Get-TcSourceInfo {
    <#
    .SYNOPSIS
        Source repository, module version and commit of a source tree (a checkout or an extracted
        release zip). ModuleDir is the TwinCATAutomation module folder of that tree. Never throws:
        what could not be read is $null and explained in warnings[].
    #>
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$ModuleDir
    )

    $warnings = [System.Collections.Generic.List[string]]::new()
    $info = [ordered]@{
        sourceUrl    = $null
        version      = $null
        release      = $null
        commit       = $null
        ref          = $null
        commitSource = 'unknown'
        warnings     = $null
    }

    $psd1 = Join-Path $ModuleDir 'TwinCATAutomation.psd1'
    if (Test-Path -LiteralPath $psd1 -PathType Leaf) {
        try {
            $data = Import-PowerShellDataFile -LiteralPath $psd1 -ErrorAction Stop
            $info.version = [string]$data.ModuleVersion
            if ($data.PrivateData -and $data.PrivateData.PSData) { $info.sourceUrl = [string]$data.PrivateData.PSData.ProjectUri }
        }
        catch { $warnings.Add("module manifest $psd1 cannot be read: $($_.Exception.Message)") }
    }
    else { $warnings.Add("module manifest not found: $psd1") }

    $git = $null
    try { $git = Get-TcGitHeadInfo -RepoRoot $SourceRoot }
    catch { $warnings.Add(".git cannot be read: $($_.Exception.Message)") }
    if ($null -ne $git) {
        $info.commit = $git.commit
        $info.ref = $git.ref
        $info.commitSource = 'git'
        if ($git.note) { $warnings.Add($git.note) }
    }
    else {
        $stamp = Join-Path $SourceRoot $script:TcSourceStampName
        if (Test-Path -LiteralPath $stamp -PathType Leaf) {
            try {
                $s = (Read-TcInstallText $stamp) | ConvertFrom-Json -ErrorAction Stop
                if ($s.sourceUrl) { $info.sourceUrl = [string]$s.sourceUrl }
                if ($s.release) { $info.release = [string]$s.release }
                if ($s.ref) { $info.ref = [string]$s.ref }
                $c = ([string]$s.commit).ToLowerInvariant()
                if ($c -match '^(?:[0-9a-f]{40}|[0-9a-f]{64})$') { $info.commit = $c }
                else { $warnings.Add("$($script:TcSourceStampName): commit '$($s.commit)' is not a 40 / 64 hex object name, ignored") }
                $info.commitSource = 'release-stamp'
            }
            catch { $warnings.Add("$($script:TcSourceStampName) cannot be read: $($_.Exception.Message)") }
        }
    }
    $info.warnings = @($warnings)
    return $info
}

function Get-TcSkillName {
    # "name:" inside the SKILL.md frontmatter (between the first two '---' lines), $null when there is none
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $m = [regex]::Match((Read-TcInstallText $Path), '\A---\r?\n(?<fm>(?:(?!---\r?\n).*\r?\n)*?)---\r?\n')
    if (-not $m.Success) { return $null }
    $n = [regex]::Match($m.Groups['fm'].Value, '(?m)^name:[ \t]*(.+?)[ \t]*\r?$')
    if ($n.Success) { return $n.Groups[1].Value }
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
            $items.Add([ordered]@{ path = $rel; sha256 = (Get-TcInstallFileSha256 $f.FullName); size = [long]$f.Length })
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
    Write-TcInstallText -Path $path -Content ($manifest | ConvertTo-Json -Depth 6)
    (Get-Item -LiteralPath $path -Force).IsReadOnly = $true
    foreach ($w in $src.warnings) { Write-Warning "install manifest: $w" }
    return $manifest
}

function Read-TcInstallManifest {
    # Parsed manifest; throws when the file is not a manifest this module understands (also when a
    # files[].path leaves the install folder: '..', rooted, drive, backslash).
    param([Parameter(Mandatory)][string]$Path)
    $m = (Read-TcInstallText $Path) | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $m -or $null -eq $m.schemaVersion -or $null -eq $m.files) {
        throw "$Path is not a TwinCATAutomation install manifest (schemaVersion / files missing)"
    }
    if ([int]$m.schemaVersion -gt $script:TcInstallManifestSchemaVersion) {
        throw "$Path has schemaVersion $($m.schemaVersion); this module reads up to $($script:TcInstallManifestSchemaVersion)"
    }
    foreach ($f in @($m.files)) {
        if (-not (Test-TcInstallRelPath ([string]$f.path))) { throw "$Path lists an invalid file path '$($f.path)' (must be relative, '/'-separated, without '..', ':' or '\')" }
        if ([string]$f.sha256 -notmatch '^[0-9a-fA-F]{64}$') { throw "$Path has an invalid sha256 for '$($f.path)'" }
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

function Test-TcInstalledSkillDir {
    # True when Dir looks like a skill folder one of the installers wrote: the install manifest, or
    # SKILL.md + TwinCATAutomation\TwinCATAutomation.psd1 (an install from before #30). -Uninstall
    # deletes nothing else.
    param([Parameter(Mandatory)][string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return $false }
    if (Test-Path -LiteralPath (Join-Path $Dir $script:TcInstallManifestName) -PathType Leaf) { return $true }
    return ((Test-Path -LiteralPath (Join-Path $Dir 'SKILL.md') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Dir 'TwinCATAutomation\TwinCATAutomation.psd1') -PathType Leaf))
}

function Compare-TcInstallFiles {
    <#
    .SYNOPSIS
        Compares the files below InstallRoot with Expected (items with path + sha256). Returns
        [ordered]@{ ok; checked; matched; mismatched [{path, expected, actual}]; missing [path];
        extra [path] }. extra = files in a folder that Expected covers (e.g. TwinCATAutomation/)
        that Expected does not list; loose files next to SKILL.md are not reported. Throws on a path
        that would leave InstallRoot (see Test-TcInstallRelPath).
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Expected
    )
    foreach ($e in $Expected) {
        if (-not (Test-TcInstallRelPath ([string]$e.path))) { throw "invalid install file path '$($e.path)' (must be relative, '/'-separated, without '..', ':' or '\')" }
    }
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
        $actual = Get-TcInstallFileSha256 $full
        $exp = ([string]$e.sha256).ToLowerInvariant()
        if ([string]::Equals($actual, $exp, [System.StringComparison]::Ordinal)) { $matched++ }
        else { $mismatched.Add([ordered]@{ path = $rel; expected = $exp; actual = $actual }) }
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
    return (Read-TcInstallText $SkillSource).Replace('<module-path>', $ModulePath)
}

function Get-TcExpectedInstallFiles {
    # What an install from this source writes: SKILL.md (rendered, UTF-8 without BOM) and the module tree.
    param(
        [Parameter(Mandatory)][string]$SourceModuleDir,
        [Parameter(Mandatory)][string]$SkillContent
    )
    $items = [System.Collections.Generic.List[object]]::new()
    $skillBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($SkillContent)
    $items.Add([ordered]@{ path = 'SKILL.md'; sha256 = (Get-TcInstallSha256Hex $skillBytes); size = [long]$skillBytes.Length })
    $root = [System.IO.Path]::GetFullPath($SourceModuleDir).TrimEnd('\', '/')
    foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -File -Force)) {
        $rel = 'TwinCATAutomation/' + ($f.FullName.Substring($root.Length).TrimStart('\', '/') -replace '\\', '/')
        $items.Add([ordered]@{ path = $rel; sha256 = (Get-TcInstallFileSha256 $f.FullName); size = [long]$f.Length })
    }
    return @($items | Sort-Object -Property @{ Expression = { $_.path } })
}

function Install-TcSkillPayload {
    <#
    .SYNOPSIS
        The install step shared by the three installers: copies the module to <SkillDir>\TwinCATAutomation
        (replacing an older copy), writes SKILL.md with the module path filled in, then the manifest.
        Returns the manifest; throws on the first failure (the caller reports it and exits 1).
    #>
    param(
        [Parameter(Mandatory)][string]$SkillDir,
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$SkillSource,
        [Parameter(Mandatory)][string]$Installer
    )
    $ErrorActionPreference = 'Stop'
    $srcModule = Join-Path $SourceRoot 'src\TwinCATAutomation'
    if (-not (Test-Path -LiteralPath (Join-Path $srcModule 'TwinCATAutomation.psd1') -PathType Leaf)) { throw "module source not found: $srcModule" }
    if (-not (Test-Path -LiteralPath $SkillSource -PathType Leaf)) { throw "SKILL.md source not found: $SkillSource" }
    $destModule = Join-Path $SkillDir 'TwinCATAutomation'
    if (-not (Test-Path -LiteralPath $SkillDir)) { New-Item -Path $SkillDir -ItemType Directory -Force | Out-Null }
    if (Test-Path -LiteralPath $destModule) { Remove-Item -LiteralPath $destModule -Recurse -Force }
    Copy-Item -LiteralPath $srcModule -Destination $destModule -Recurse -Force
    $absModulePath = Join-Path $destModule 'TwinCATAutomation.psm1'
    Write-TcInstallText -Path (Join-Path $SkillDir 'SKILL.md') -Content (Get-TcRenderedSkillContent -SkillSource $SkillSource -ModulePath $absModulePath)
    return Write-TcInstallManifest -InstallRoot $SkillDir -SourceRoot $SourceRoot -ModuleDir $srcModule -Installer $Installer
}

function Invoke-TcInstallVerify {
    <#
    .SYNOPSIS
        Read-only -Verify of the installers: prints the manifest (source, version, commit, install
        time), checks the installed files against the manifest hashes (accidental or partial change)
        and against what an install from SourceRoot would write. Returns 0 (match) or 1 (mismatch,
        not installed, no / invalid manifest, or the check itself failed).
        A different commit with identical files is only a warning (e.g. a docs-only commit).
    #>
    param(
        [Parameter(Mandatory)][string]$SkillDir,
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$SkillSource,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$InstallerScript
    )
    $ErrorActionPreference = 'Stop'
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
            $manifest = $null
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
    foreach ($w in $src.warnings) { Write-Host "  [WARN]     $w" -ForegroundColor Yellow }
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
