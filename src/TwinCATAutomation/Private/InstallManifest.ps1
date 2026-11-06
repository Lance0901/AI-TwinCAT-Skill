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
#      .git file + commondir) by Read-TcGitCommit, the one .git reader of the module (#148).
#      git itself is never started.
#   2. tcauto-source.json in the source root. RESERVED for the release zip of #20: a build-time
#      stamp {"sourceUrl", "commit", "ref", "release"} so no git is needed at install time. Only
#      read when there is no .git; the format is fixed by #20.
#   3. neither: commit = null, commitSource = 'unknown'.

$script:TcInstallManifestName = 'tcauto-install-manifest.json'
$script:TcSourceStampName = 'tcauto-source.json'
$script:TcInstallManifestSchemaVersion = 1
$script:TcInstallManifestInstallers = @('claude-code', 'codex', 'antigravity')

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
        path written into SKILL.md is the same at install and at -Verify. A drive / share root is
        returned as is ('C:\', not the drive-relative 'C:'). Throws for a path of another provider
        (HKCU:\..., Cert:\...) and for wildcards (* ?), which a folder name cannot hold.
    #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$SessionState)
    if ($Path.IndexOfAny([char[]]@('*', '?')) -ge 0) { throw "wildcards are not allowed in an install folder path: $Path" }
    $provider = $null
    $drive = $null
    $resolved = $SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path, [ref]$provider, [ref]$drive)
    if ($null -eq $provider -or $provider.Name -ne 'FileSystem') { throw "not a file system path: $Path (provider $(if ($provider) { $provider.Name } else { 'unknown' }))" }
    $full = [System.IO.Path]::GetFullPath($resolved)
    $root = [System.IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrEmpty($root)) { return $full.TrimEnd('\', '/') }
    if ($full.Length -le $root.Length) { return $root }
    $full = $full.TrimEnd('\', '/')
    if ($full.Length -le $root.Length) { return $root }
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

function Test-TcGitRefName {
    # A ref name git itself would accept (https://git-scm.com/docs/git-check-ref-format), and that
    # is safe as a path below the gitdir: refs/<name>, no '..', '\', ':', '~', '^', '?', '*', '[',
    # blank, control character or '@{'; no empty component, no component starting with '.' or
    # ending with '.lock'; not ending with '.' or '/'. Windows drops a trailing '.' of a path
    # component, so "refs/heads/foo." would otherwise read refs/heads/foo. Same rule as
    # isGitRefName in mcp-server/lib/module-source.js (#148).
    param([AllowEmptyString()][string]$Ref)
    if (-not $Ref.StartsWith('refs/', [System.StringComparison]::Ordinal)) { return $false }
    # Ordinal everywhere: .NET Framework compares by culture by default, which skips soft hyphens /
    # zero-width characters and folds a combining mark into the previous character (#154); JS is code unit exact.
    $ord = [System.StringComparison]::Ordinal
    if ($Ref.EndsWith('.', $ord) -or $Ref.EndsWith('/', $ord) -or $Ref.IndexOf('..', $ord) -ge 0 -or $Ref.IndexOf('@{', $ord) -ge 0) { return $false }
    foreach ($ch in $Ref.ToCharArray()) {
        if ([int]$ch -lt 0x20 -or [int]$ch -eq 0x7F -or ' ~^:?*[\'.IndexOf($ch) -ge 0) { return $false }
    }
    foreach ($part in $Ref.Split('/')) {
        if ($part.Length -eq 0 -or $part.StartsWith('.', $ord) -or $part.EndsWith('.lock', $ord)) { return $false }
    }
    return $true
}

function Read-TcGitCommit {
    <#
    .SYNOPSIS
        The one reader of the checked-out commit of a git working tree (#148), from its .git files:
        git.exe is never started. Used by Get-TcSourceInfo (install manifest, #30) and
        Get-TcModuleCommit (ReportIssue, #78 / #140); mcp-server/lib/module-source.js readGitHead
        follows the same rules and both run tests/fixtures/git-commit-148.json.
        Returns $null when RepoRoot has no usable .git (none, a .git file without a "gitdir:" line,
        a gitdir that is not a directory, no HEAD, a file that exists but cannot be read; the reason
        of a read failure goes to -Failure). Otherwise @{ commit; ref; note }: commit is the
        lower-case 40 (SHA-1) or 64 (SHA-256) hex object name, or $null with a note (unborn branch,
        symbolic ref chain, refused ref name, reftable repository, not an object name).
        Rules: every file is decoded as UTF-8 (a UTF-8 BOM is dropped, nothing else is detected:
        a UTF-16 file is garbage, as for git), first line, only ASCII blanks trimmed; ".git" may be
        a directory or a file "gitdir: <path>" (relative to RepoRoot; "gitdir:" and "ref:" are
        case-sensitive, as git reads them, https://git-scm.com/docs/gitrepository-layout);
        "commondir" (relative to the gitdir) holds refs and packed-refs of a linked worktree; HEAD
        is a detached object name or "ref: <name>" with a name git-check-ref-format accepts
        (Test-TcGitRefName; non-ASCII branch names work); the loose ref (gitdir, then common dir)
        wins over packed-refs, whose names are compared case-sensitively; hex is accepted in either
        case. Never throws.
    #>
    param([Parameter(Mandatory)][string]$RepoRoot, [ref]$Failure)

    $blank = [char[]]@(' ', "`t", "`r", "`n")
    $readText = {
        param([string]$File)
        $text = (New-Object System.Text.UTF8Encoding($false)).GetString([System.IO.File]::ReadAllBytes($File))
        if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
        return $text
    }
    $firstLine = {
        param([string]$File)
        if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return $null }
        return ((& $readText $File) -split "`r?`n", 2)[0].Trim($blank)
    }
    $objectName = '^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})$'
    $result = { param($Commit, $Ref, $Note) [ordered]@{ commit = $Commit; ref = $Ref; note = $Note } }

    try {
        $dotGit = Join-Path $RepoRoot '.git'
        $gitDir = $null
        if (Test-Path -LiteralPath $dotGit -PathType Container) {
            $gitDir = $dotGit
        }
        elseif (Test-Path -LiteralPath $dotGit -PathType Leaf) {
            # linked worktree / submodule: ".git" is a file "gitdir: <path>"
            $line = & $firstLine $dotGit
            if ($line -cmatch '^gitdir:[ \t]*(.+)$') {
                $p = $Matches[1].Trim($blank)
                if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path $RepoRoot $p }
                $gitDir = [System.IO.Path]::GetFullPath($p)
            }
        }
        if ($null -eq $gitDir -or -not (Test-Path -LiteralPath $gitDir -PathType Container)) { return $null }
        $head = & $firstLine (Join-Path $gitDir 'HEAD')
        if ($null -eq $head) { return $null }

        # a linked worktree keeps HEAD in its own dir, branches and packed-refs in the common dir
        $commonDir = $gitDir
        $c = & $firstLine (Join-Path $gitDir 'commondir')
        if (-not [string]::IsNullOrEmpty($c)) {
            if (-not [System.IO.Path]::IsPathRooted($c)) { $c = Join-Path $gitDir $c }
            $commonDir = [System.IO.Path]::GetFullPath($c)
        }

        if ($head -match $objectName) { return (& $result $head.ToLowerInvariant() $null $null) }   # detached HEAD
        if ($head -cnotmatch '^ref:[ \t]*([^ \t]+)$') { return (& $result $null $null 'HEAD does not hold a 40 / 64 hex object name or a ref') }
        $ref = $Matches[1]
        # reftable (extensions.refStorage = reftable, https://git-scm.com/docs/reftable): HEAD points
        # at refs/heads/.invalid, the real refs are binary tables in <common dir>\reftable
        if ($ref -cmatch '(^|/)\.invalid$' -or (Test-Path -LiteralPath (Join-Path $commonDir 'reftable') -PathType Container)) {
            return (& $result $null $null 'reftable repository: refs are not plain files, commit not read (git is not started)')
        }
        if (-not (Test-TcGitRefName $ref)) {
            return (& $result $null $null "HEAD ref '$ref' is refused (not a ref name git-check-ref-format accepts below refs/)")
        }

        $dirs = @($gitDir)
        if ($commonDir -ine $gitDir) { $dirs += $commonDir }
        $commit = $null
        $found = $false
        foreach ($d in $dirs) {
            $v = & $firstLine (Join-Path $d ($ref -replace '/', '\'))
            if ($null -ne $v) { $commit = $v; $found = $true; break }
        }
        if (-not $found) {
            foreach ($d in $dirs) {
                $packed = Join-Path $d 'packed-refs'
                if (-not (Test-Path -LiteralPath $packed -PathType Leaf)) { continue }
                foreach ($l in ((& $readText $packed) -split "`r?`n")) {
                    if ($l -cmatch '^([0-9a-fA-F]{40}|[0-9a-fA-F]{64}) (.+)$' -and $Matches[2] -ceq $ref) { $commit = $Matches[1]; $found = $true; break }
                }
                if ($found) { break }
            }
        }
        if (-not $found) { return (& $result $null $ref "unborn branch: $ref has no commit") }
        if ($commit -cmatch '^ref:') { return (& $result $null $ref "symbolic ref chain ($ref -> another ref) is not followed") }
        if ($commit -notmatch $objectName) { return (& $result $null $ref 'HEAD / ref does not hold a 40 / 64 hex object name') }
        return (& $result $commit.ToLowerInvariant() $ref $null)
    }
    catch {
        # the inner exception names the file; the outer one is the localized "Exception calling ReadAllBytes" wrapper
        if ($PSBoundParameters.ContainsKey('Failure')) { $Failure.Value = if ($null -ne $_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message } }
        return $null
    }
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

    # Read-TcGitCommit never throws: a .git that is there but cannot be used (garbage .git file,
    # gitdir gone, unreadable file) is $null, reported here and the release stamp is tried next
    $gitFailure = $null
    $git = Read-TcGitCommit -RepoRoot $SourceRoot -Failure ([ref]$gitFailure)
    if ($null -eq $git -and (Test-Path -LiteralPath (Join-Path $SourceRoot '.git'))) {
        if ($gitFailure) { $warnings.Add(".git cannot be read: $gitFailure; commit not taken from git") }
        else { $warnings.Add('.git cannot be read (no gitdir: line, gitdir is not a folder, or no HEAD); commit not taken from git') }
    }
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
        warnings      = @($src.warnings)
        files         = $files
    }
    $path = Join-Path $InstallRoot $script:TcInstallManifestName
    if (Test-Path -LiteralPath $path -PathType Leaf) { (Get-Item -LiteralPath $path -Force).IsReadOnly = $false }
    Write-TcInstallText -Path $path -Content ($manifest | ConvertTo-Json -Depth 6)
    (Get-Item -LiteralPath $path -Force).IsReadOnly = $true
    # informational only: -WarningAction Continue so a caller's $WarningPreference = 'Stop' cannot
    # turn a finished install into a failure (the warnings are also stored in the manifest)
    foreach ($w in $src.warnings) { Write-Warning "install manifest: $w" -WarningAction Continue }
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
    # True when Dir is a skill folder one of the installers wrote: SKILL.md plus either a readable
    # install manifest written by a known installer, or TwinCATAutomation\TwinCATAutomation.psd1 (also
    # an install from before #30). A bare or bogus manifest next to other files is not enough.
    # -Uninstall deletes nothing else.
    param([Parameter(Mandatory)][string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $Dir 'SKILL.md') -PathType Leaf)) { return $false }
    $mf = Join-Path $Dir $script:TcInstallManifestName
    if (Test-Path -LiteralPath $mf -PathType Leaf) {
        try {
            $m = Read-TcInstallManifest -Path $mf
            if ($script:TcInstallManifestInstallers -contains [string]$m.installer) { return $true }
        } catch { }
    }
    return (Test-Path -LiteralPath (Join-Path $Dir 'TwinCATAutomation\TwinCATAutomation.psd1') -PathType Leaf)
}

function Compare-TcInstallFiles {
    <#
    .SYNOPSIS
        Compares the files below InstallRoot with Expected (items with path + sha256). Returns
        [ordered]@{ ok; checked; matched; mismatched [{path, expected, actual}]; missing [path];
        extra [path]; unreadable [{path, error}] }. extra = files in a folder that Expected covers (e.g. TwinCATAutomation/)
        that Expected does not list; loose files next to SKILL.md are not reported. Throws on a path
        that would leave InstallRoot (see Test-TcInstallRelPath).
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Expected
    )
    # unreadable [{path, error}]: a file that exists but cannot be hashed (locked, no access) is a
    # difference, not an exception
    foreach ($e in $Expected) {
        if (-not (Test-TcInstallRelPath ([string]$e.path))) { throw "invalid install file path '$($e.path)' (must be relative, '/'-separated, without '..', ':' or '\')" }
    }
    $root = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\', '/')
    $mismatched = [System.Collections.Generic.List[object]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()
    $extra = [System.Collections.Generic.List[string]]::new()
    $unreadable = [System.Collections.Generic.List[object]]::new()
    $known = @{}   # case-insensitive, like the file system
    $dirs = @{}
    $matched = 0
    foreach ($e in $Expected) {
        $rel = [string]$e.path
        $known[$rel] = $true
        if ($rel.Contains('/')) { $dirs[$rel.Split('/')[0]] = $true }
        $full = Join-Path $root ($rel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { $missing.Add($rel); continue }
        try { $actual = Get-TcInstallFileSha256 $full }
        catch { $unreadable.Add([ordered]@{ path = $rel; error = $_.Exception.Message }); continue }
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
        ok         = ($mismatched.Count -eq 0 -and $missing.Count -eq 0 -and $extra.Count -eq 0 -and $unreadable.Count -eq 0)
        checked    = @($Expected).Count
        matched    = $matched
        mismatched = @($mismatched)
        missing    = @($missing | Sort-Object)
        extra      = @($extra | Sort-Object)
        unreadable = @($unreadable)
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
    # .NET, not New-Item -Path: a folder name may contain [ ] (wildcard characters for -Path)
    $null = [System.IO.Directory]::CreateDirectory($SkillDir)
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
    foreach ($m in $Result.unreadable) { Write-Host "  [MISMATCH] $($m.path)  (cannot be read: $($m.error))" -ForegroundColor Red }
    if ($Result.ok) { Write-Host "  [MATCH]    $($Result.matched) file(s)" -ForegroundColor Green }
}
