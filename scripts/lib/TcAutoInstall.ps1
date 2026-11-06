# Install helpers shared by scripts/Install-TcAutoRuntime.ps1 (developer install from a checkout,
# #162), scripts/Build-TcAutoRelease.ps1 (release zip, #20) and Install-TcAuto.ps1 (customer install
# from that zip, #20; in the zip this file is lib\TcAutoInstall.ps1 next to it).
# Dot-source it into a script (it only defines functions and $script: variables). Stop-Install ends
# the calling script (exit 1) after printing "TCAUTO_INSTALL_RESULT <json>".
# Windows PowerShell 5.1; ASCII.

$script:TcInstallWarnings = [System.Collections.Generic.List[string]]::new()
$script:TcInstallStaging = $null
$script:TcUtf8NoBom = New-Object System.Text.UTF8Encoding($false)
# runtime folder names the launcher accepts (VERSION_RE in mcp-server/launcher/tcauto-launcher.mjs)
$script:TcRuntimeVersionPattern = '^[0-9a-f]{7,64}(-dirty-[0-9]{8}T[0-9]{6}Z)?$'
# what a runtime consists of: mcp-server\ (without test\ and node_modules\) and src\TwinCATAutomation\
$script:TcInstallPathspec = @('--', 'mcp-server', 'src/TwinCATAutomation', ':(exclude)mcp-server/test', ':(exclude)mcp-server/node_modules')

function Write-InstallResult {
    param([Parameter(Mandatory)][hashtable]$Result)
    Write-Output ('TCAUTO_INSTALL_RESULT ' + (ConvertTo-Json -InputObject $Result -Depth 8 -Compress))
}

function Stop-Install {
    param([string]$Code, [string]$Message, [string]$Hint, $Data)
    if ($null -ne $script:TcInstallStaging -and (Test-Path -LiteralPath $script:TcInstallStaging)) {
        try { Remove-Item -LiteralPath $script:TcInstallStaging -Recurse -Force -ErrorAction Stop } catch { }
    }
    Write-Host "[FAIL] $Code`: $Message" -ForegroundColor Red
    if ($Hint) { Write-Host "       $Hint" -ForegroundColor Yellow }
    $err = [ordered]@{ code = $Code; message = $Message }
    if ($Hint) { $err.hint = $Hint }
    $r = @{ success = $false; error = $err }
    if ($null -ne $Data) { $r.data = $Data }
    Write-InstallResult $r
    exit 1
}

function Invoke-Native {
    # Runs a native command with EAP Continue (5.1 turns stderr lines into ErrorRecords), returns
    # @{ Code; Lines } with stdout + stderr as strings.
    param([Parameter(Mandatory)][string]$File, [string[]]$Arguments = @())
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = @(& $File @Arguments 2>&1 | ForEach-Object { "$_" })
        return @{ Code = $LASTEXITCODE; Lines = $lines }
    }
    finally { $ErrorActionPreference = $old }
}

function Write-Utf8File {
    # temp file in the same folder, then an atomic replace / move onto Path (UTF-8 without BOM)
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
    $dir = Split-Path -Parent $Path
    $tmp = Join-Path $dir ('.' + (Split-Path -Leaf $Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    [System.IO.File]::WriteAllText($tmp, $Content, $script:TcUtf8NoBom)
    try {
        # [NullString]::Value: a plain $null becomes '' for a .NET string parameter ("no backup" needs null)
        if ([System.IO.File]::Exists($Path)) { [System.IO.File]::Replace($tmp, $Path, [System.Management.Automation.Language.NullString]::Value) }
        else { [System.IO.File]::Move($tmp, $Path) }
    }
    catch {
        try { [System.IO.File]::Delete($tmp) } catch { }
        throw
    }
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop) }
    catch { return $null }
}

function Get-FileSha256 {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-TcLongPath {
    # Full path with every existing component in its real (long) spelling: an 8.3 name such as
    # C:\Users\RUNNER~1 becomes C:\Users\runneradmin (a directory listing matches short names as well
    # and returns the long one). Components that do not exist yet are kept as written. Never throws.
    param([Parameter(Mandatory)][string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $rootPart = [System.IO.Path]::GetPathRoot($full)
    $parts = @($full.Substring($rootPart.Length).Split([char[]]'\', [System.StringSplitOptions]::RemoveEmptyEntries))
    if ($parts.Count -eq 0) { return $full }
    $cur = $rootPart.TrimEnd('\')
    $exists = $true
    foreach ($p in $parts) {
        $next = $p
        if ($exists -and $p.IndexOfAny([char[]]'*?') -lt 0) {
            try {
                $hits = @([System.IO.Directory]::GetFileSystemEntries($cur + '\', $p))
                if ($hits.Count -eq 1) { $next = [System.IO.Path]::GetFileName($hits[0]) } else { $exists = $false }
            }
            catch { $exists = $false }
        }
        $cur = $cur + '\' + $next
    }
    if (-not $cur) { return $full }
    return $cur
}

function Resolve-TcInstallRoot {
    # -InstallRoot, else %TCAUTO_RUNTIME_ROOT%, else %LOCALAPPDATA%\TwinCATAutomation (the launcher
    # finds current.json the same way). TCAUTO_TEST_FORBID_REAL_STATE=1 refuses the real one (#118).
    param([string]$InstallRoot)
    if (-not $InstallRoot) {
        if ($env:TCAUTO_RUNTIME_ROOT) { $InstallRoot = $env:TCAUTO_RUNTIME_ROOT }
        else { $InstallRoot = Join-Path $env:LOCALAPPDATA 'TwinCATAutomation' }
    }
    # long form (no 8.3 names): it is written into the client configs and compared with other paths
    $root = Get-TcLongPath -Path $InstallRoot
    $real = if ($env:LOCALAPPDATA) { Get-TcLongPath -Path (Join-Path $env:LOCALAPPDATA 'TwinCATAutomation') } else { $null }
    if ($env:TCAUTO_TEST_FORBID_REAL_STATE -eq '1' -and $real -and $root -ieq $real) {
        Stop-Install -Code 'TCAUTO_REAL_STATE_REFUSED' -Message "TCAUTO_TEST_FORBID_REAL_STATE=1: refusing to install into the real $real (#118); pass -InstallRoot or TCAUTO_RUNTIME_ROOT."
    }
    return $root
}

function Get-TcGitSource {
    # commit / ref / branch / dirty of a checkout. Pathspec: what counts for "dirty" (default: the
    # runtime files). Refuses a dirty tree (WORKTREE_DIRTY) unless AllowDirty.
    param([Parameter(Mandatory)][string]$RepoRoot, [string[]]$Pathspec = $script:TcInstallPathspec, [switch]$AllowDirty, [string]$DirtyWhat = 'below mcp-server\ or src\TwinCATAutomation\')
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Stop-Install -Code 'GIT_NOT_FOUND' -Message 'git is not on PATH; it is needed to read the commit and whether the working tree is dirty.'
    }
    $r = Invoke-Native -File 'git' -Arguments @('-C', $RepoRoot, 'rev-parse', 'HEAD')
    $commit = (@($r.Lines) | Select-Object -First 1)
    if ($r.Code -ne 0 -or "$commit" -notmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$') {
        Stop-Install -Code 'GIT_FAILED' -Message "git rev-parse HEAD failed in $RepoRoot (exit $($r.Code)): $(@($r.Lines) -join ' | ')"
    }
    $commit = "$commit".Trim().ToLowerInvariant()
    $r = Invoke-Native -File 'git' -Arguments @('-C', $RepoRoot, 'symbolic-ref', '--quiet', 'HEAD')
    $ref = if ($r.Code -eq 0) { "$(@($r.Lines) | Select-Object -First 1)".Trim() } else { $null }
    $branch = if ($ref -and $ref.StartsWith('refs/heads/')) { $ref.Substring(11) } else { $null }
    $r = Invoke-Native -File 'git' -Arguments (@('-C', $RepoRoot, 'status', '--porcelain', '--untracked-files=all') + $Pathspec)
    if ($r.Code -ne 0) { Stop-Install -Code 'GIT_FAILED' -Message "git status failed in $RepoRoot (exit $($r.Code)): $(@($r.Lines) -join ' | ')" }
    $changes = @(@($r.Lines) | Where-Object { "$_".Trim() })
    $dirty = $changes.Count -gt 0
    if ($dirty -and -not $AllowDirty) {
        Stop-Install -Code 'WORKTREE_DIRTY' -Message "$($changes.Count) uncommitted change(s) $DirtyWhat in $RepoRoot; nothing was written." `
            -Hint 'Commit (or stash) them and run again, or pass -AllowDirty (the result is then marked dirty: true).' `
            -Data @{ changes = @($changes | Select-Object -First 20) }
    }
    return [ordered]@{ commit = $commit; ref = $ref; branch = $branch; dirty = $dirty; changes = $changes }
}

function Get-InstallFileList {
    # Repository-relative paths (forward slashes) of the files to install: tracked + untracked that
    # are not git-ignored (git ls-files -co --exclude-standard), below the runtime pathspec. Tracked
    # files deleted in the working tree are left out (only reachable with -AllowDirty).
    param([Parameter(Mandatory)][string]$RepoRoot)
    $oldEnc = $null
    try { $oldEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { $oldEnc = $null }
    try { $r = Invoke-Native -File 'git' -Arguments (@('-C', $RepoRoot, '-c', 'core.quotepath=off', 'ls-files', '-co', '--exclude-standard') + $script:TcInstallPathspec) }
    finally { if ($null -ne $oldEnc) { try { [Console]::OutputEncoding = $oldEnc } catch { } } }
    if ($r.Code -ne 0) { Stop-Install -Code 'GIT_FAILED' -Message "git ls-files failed in $RepoRoot (exit $($r.Code)): $(@($r.Lines) -join ' | ')" }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $files = [System.Collections.Generic.List[string]]::new()
    foreach ($l in @($r.Lines)) {
        $rel = "$l".Trim()
        if (-not $rel -or -not $seen.Add($rel)) { continue }
        if (Test-Path -LiteralPath (Join-Path $RepoRoot ($rel -replace '/', '\')) -PathType Leaf) { $files.Add($rel) }
    }
    return , $files
}

$script:TcOneDriveHint = 'A file in a OneDrive folder that cannot be downloaded (cloud file provider error 383 / "The cloud sync provider failed to validate the downloaded data") cannot be copied: right-click the folder in Explorer -> "Always keep on this device", wait for OneDrive to finish, then run this script again (#162).'

function Copy-InstallFiles {
    # copies each listed file (relative path) to the same relative path below Destination
    param([Parameter(Mandatory)][string]$SourceRoot, [Parameter(Mandatory)][string]$Destination, [Parameter(Mandatory)]$Files)
    foreach ($rel in $Files) {
        $relWin = $rel -replace '/', '\'
        $src = Join-Path $SourceRoot $relWin
        $dst = Join-Path $Destination $relWin
        try {
            $dir = Split-Path -Parent $dst
            if (-not [System.IO.Directory]::Exists($dir)) { $null = [System.IO.Directory]::CreateDirectory($dir) }
            [System.IO.File]::Copy($src, $dst, $true)
        }
        catch {
            Stop-Install -Code 'COPY_FAILED' -Message "cannot copy $src`: $($_.Exception.Message)" -Hint $script:TcOneDriveHint
        }
    }
}

function Copy-TcTree {
    # every file below Source to the same relative path below Destination; returns the file count
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination)
    $base = [System.IO.Path]::GetFullPath($Source).TrimEnd('\') + '\'
    $rels = [System.Collections.Generic.List[string]]::new()
    foreach ($f in [System.IO.Directory]::EnumerateFiles($base, '*', [System.IO.SearchOption]::AllDirectories)) { $rels.Add($f.Substring($base.Length)) }
    Copy-InstallFiles -SourceRoot $base -Destination $Destination -Files $rels
    return $rels.Count
}

function New-TcRuntimeTree {
    # Fills Destination with the runtime of a checkout: the git-listed files below the runtime
    # pathspec, "npm ci --omit=dev" in its mcp-server\, then tcauto-source.json (Stamp). Returns the
    # number of copied files.
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$Destination, [Parameter(Mandatory)][string]$NpmPath, [Parameter(Mandatory)]$Stamp)
    Write-Host '  copying mcp-server and src\TwinCATAutomation ...'
    # only files git lists (tracked + untracked, not ignored): an ignored temp_*.ps1 never reaches the runtime
    $files = Get-InstallFileList -RepoRoot $RepoRoot
    Copy-InstallFiles -SourceRoot $RepoRoot -Destination $Destination -Files $files
    Write-Host "  $($files.Count) files copied"
    Write-Host '  npm ci --omit=dev ...'
    Push-Location -LiteralPath (Join-Path $Destination 'mcp-server')
    try { $npm = Invoke-Native -File $NpmPath -Arguments @('ci', '--omit=dev', '--no-audit', '--no-fund') }
    catch { $npm = @{ Code = -1; Lines = @($_.Exception.Message) } }
    finally { Pop-Location }
    if ($npm.Code -ne 0) {
        Stop-Install -Code 'NPM_CI_FAILED' -Message "npm ci --omit=dev failed in the staging copy (exit $($npm.Code)): $((@($npm.Lines) | Select-Object -Last 8) -join ' | ')" `
            -Hint 'Check that Node.js >= 22 and npm are on PATH and the npm registry (or cache) is reachable, then run this script again.'
    }
    [System.IO.File]::WriteAllText((Join-Path $Destination 'tcauto-source.json'), (ConvertTo-Json -InputObject $Stamp -Depth 3), $script:TcUtf8NoBom)
    return $files.Count
}

function Test-TcRuntimeComplete {
    # a runtime folder of this commit whose stamp names the folder (a dirty version has its own
    # <commit>-dirty-<time> name, so a clean name never holds a dirty copy) and has its node_modules
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Commit)
    $stamp = Read-JsonFile (Join-Path $Path 'tcauto-source.json')
    $name = Split-Path -Leaf $Path
    $dirtyName = $name -match '-dirty-'
    return ($null -ne $stamp -and "$($stamp.commit)" -eq $Commit -and "$($stamp.version)" -eq $name -and $stamp.dirty -eq $dirtyName -and
        (Test-Path -LiteralPath (Join-Path $Path 'mcp-server\index.js')) -and
        (Test-Path -LiteralPath (Join-Path $Path 'mcp-server\node_modules\@modelcontextprotocol\sdk\package.json')))
}

function Get-TcCurrentVersion {
    param([Parameter(Mandatory)][string]$RuntimeFolder)
    $current = Read-JsonFile (Join-Path $RuntimeFolder 'current.json')
    if ($null -ne $current -and "$($current.version)" -match $script:TcRuntimeVersionPattern) { return [string]$current.version }
    return $null
}

function Install-TcRuntimeVersion {
    # Puts runtime <Version> below RuntimeFolder: reused when a complete clean copy of Commit is
    # there already, else Fill (scriptblock, param($staging)) fills a staging folder that is renamed
    # to <Version> when complete. Returns @{ Target; Reused }.
    param([Parameter(Mandatory)][string]$RuntimeFolder, [Parameter(Mandatory)][string]$Version, [Parameter(Mandatory)][string]$Commit,
        [string]$CurrentVersion, [Parameter(Mandatory)][scriptblock]$Fill)
    $target = Join-Path $RuntimeFolder $Version
    $null = New-Item -ItemType Directory -Force -Path $RuntimeFolder
    if (Test-Path -LiteralPath $target) {
        if (Test-TcRuntimeComplete -Path $target -Commit $Commit) {
            Write-Host "  $Version is installed already; reusing it"
            return @{ Target = $target; Reused = $true }
        }
        if ($Version -eq $CurrentVersion) {
            Stop-Install -Code 'RUNTIME_DAMAGED' -Message "$target is the current runtime but incomplete (no valid tcauto-source.json or node_modules); it is not replaced while it may be running." `
                -Hint 'Install another version (commit something, or -AllowDirty) and ReloadRuntime to it, then run this script again.'
        }
        try { Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop }
        catch { Stop-Install -Code 'RUNTIME_IN_USE' -Message "incomplete $target cannot be removed: $($_.Exception.Message)" -Hint 'Close the MCP client that runs it, then run this script again.' }
    }
    $script:TcInstallStaging = Join-Path $RuntimeFolder ('.staging-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Force -Path $script:TcInstallStaging
    $null = & $Fill $script:TcInstallStaging
    try { [System.IO.Directory]::Move($script:TcInstallStaging, $target) }
    catch { Stop-Install -Code 'RENAME_FAILED' -Message "cannot rename the staging copy to $target`: $($_.Exception.Message)" }
    $script:TcInstallStaging = $null
    return @{ Target = $target; Reused = $false }
}

function Set-TcCurrentRuntime {
    # switches <RuntimeFolder>\current.json to Version atomically (values from its tcauto-source.json)
    param([Parameter(Mandatory)][string]$RuntimeFolder, [Parameter(Mandatory)][string]$Version)
    $target = Join-Path $RuntimeFolder $Version
    $stamp = Read-JsonFile (Join-Path $target 'tcauto-source.json')
    $currentJson = Join-Path $RuntimeFolder 'current.json'
    $data = [ordered]@{
        schema      = 1
        version     = $Version
        commit      = if ($null -ne $stamp) { [string]$stamp.commit } else { $null }
        branch      = if ($null -ne $stamp) { $stamp.branch } else { $null }
        dirty       = if ($null -ne $stamp) { $stamp.dirty } else { $null }
        installedAt = if ($null -ne $stamp) { [string]$stamp.installedAt } else { $null }
        updatedAt   = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        runtimeDir  = $target
    }
    if ($null -ne $stamp -and $stamp.release) { $data.release = [string]$stamp.release }
    try { Write-Utf8File -Path $currentJson -Content (ConvertTo-Json -InputObject $data -Depth 3) }
    catch { Stop-Install -Code 'CURRENT_WRITE_FAILED' -Message "cannot write $currentJson`: $($_.Exception.Message)" }
    Write-Host "  current.json -> $Version"
    return $currentJson
}

function Update-TcLauncher {
    # copies the launcher into LauncherFolder only when its content changed; returns @{ Path; Updated }
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$LauncherFolder)
    $null = New-Item -ItemType Directory -Force -Path $LauncherFolder
    $path = Join-Path $LauncherFolder 'tcauto-launcher.mjs'
    $updated = $false
    if ((Get-FileSha256 $Source) -ne (Get-FileSha256 $path)) {
        try { Write-Utf8File -Path $path -Content ([System.IO.File]::ReadAllText($Source, [System.Text.Encoding]::UTF8)) }
        catch { Stop-Install -Code 'LAUNCHER_WRITE_FAILED' -Message "cannot write $path`: $($_.Exception.Message)" }
        $updated = $true
        Write-Host "  launcher updated: $path"
    }
    else { Write-Host "  launcher unchanged: $path" }
    return @{ Path = $path; Updated = $updated }
}

function Remove-TcOldRuntimes {
    # Keeps the Keep newest runtime folders (by installedAt) and never Version. An older one is
    # renamed first and deleted after, so one a running launcher uses (its working directory) cannot
    # be renamed and is left alone. Returns @{ Pruned; Skipped }.
    param([Parameter(Mandatory)][string]$RuntimeFolder, [Parameter(Mandatory)][int]$Keep, [Parameter(Mandatory)][string]$Version)
    $pruned = [System.Collections.Generic.List[string]]::new()
    $skipped = [System.Collections.Generic.List[object]]::new()
    $versions = @(Get-ChildItem -LiteralPath $RuntimeFolder -Directory | Where-Object { $_.Name -match $script:TcRuntimeVersionPattern } | ForEach-Object {
            $dir = $_
            $s = Read-JsonFile (Join-Path $dir.FullName 'tcauto-source.json')
            $at = $dir.CreationTimeUtc
            if ($null -ne $s -and $s.installedAt) {
                try { $at = [DateTime]::Parse([string]$s.installedAt, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal) }
                catch { $at = $dir.CreationTimeUtc }
            }
            [pscustomobject]@{ Name = $dir.Name; Path = $dir.FullName; At = $at }
        } | Sort-Object -Property At -Descending)
    # leftovers of an earlier run: renamed old versions, staging copies older than a day
    Get-ChildItem -LiteralPath $RuntimeFolder -Directory -Force | Where-Object {
        $_.Name -like '.trash-*' -or ($_.Name -like '.staging-*' -and $_.CreationTimeUtc -lt [DateTime]::UtcNow.AddDays(-1))
    } | ForEach-Object {
        $left = $_.FullName
        try { Remove-Item -LiteralPath $left -Recurse -Force -ErrorAction Stop } catch { $script:TcInstallWarnings.Add("leftover $left not removed") }
    }
    $rank = 0
    foreach ($v in $versions) {
        $rank++
        if ($rank -le $Keep -or $v.Name -eq $Version) { continue }
        $trash = Join-Path $RuntimeFolder ('.trash-' + $v.Name + '-' + [guid]::NewGuid().ToString('N'))
        try { [System.IO.Directory]::Move($v.Path, $trash) }
        catch {
            $skipped.Add([ordered]@{ version = $v.Name; reason = "in use or locked: $($_.Exception.Message)" })
            continue
        }
        $pruned.Add($v.Name)
        try { Remove-Item -LiteralPath $trash -Recurse -Force -ErrorAction Stop }
        catch { $script:TcInstallWarnings.Add("$($v.Name) was renamed to $trash but not deleted completely: $($_.Exception.Message)") }
    }
    if ($pruned.Count -gt 0) { Write-Host "  removed old versions: $($pruned -join ', ')" }
    foreach ($s in $skipped) { Write-Host "  kept $($s.version): $($s.reason)" -ForegroundColor Yellow }
    return @{ Pruned = $pruned; Skipped = $skipped }
}
