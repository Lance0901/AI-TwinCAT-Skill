<#
.SYNOPSIS
    Install the TcAuto MCP runtime of this checkout outside OneDrive and point the launcher at it (#162).

.DESCRIPTION
    Copies mcp-server\ (without node_modules and test) and src\TwinCATAutomation\ of this checkout to
    <InstallRoot>\runtime\<version>\ (same relative layout, so index.js finds its module at the
    default path), runs "npm ci --omit=dev" there, writes <version>\tcauto-source.json (commit, ref,
    branch, dirty, installedAt, sourcePath, version) and then switches <InstallRoot>\runtime\current.json
    to the new version atomically (a temp file in the same folder, then File.Replace).
    The launcher <InstallRoot>\launcher\tcauto-launcher.mjs is copied only when its content changed.
    The MCP client is registered once with "node <InstallRoot>\launcher\tcauto-launcher.mjs"; after a
    new install call the MCP tool ReloadRuntime (or reconnect the client) to switch versions.

    <version> is the 12-character commit; with -AllowDirty and uncommitted changes it is
    <commit>-dirty-<UTC yyyyMMddTHHmmssZ>, so a dirty install never replaces a clean one. A clean
    version that is already installed completely is reused (only current.json is switched).
    Dirty = "git status --porcelain" lists anything below mcp-server\ (except test\) or
    src\TwinCATAutomation\, tracked or untracked.
    Only the files "git ls-files -co --exclude-standard" lists there are copied (tracked + untracked
    that are not ignored): a git-ignored file (temp_*.ps1, *.ps1xml, .env, ...) never reaches the
    runtime, where the module would otherwise dot-source a stray Public\ / Private\ .ps1 that is
    not part of the commit the stamp names (#162 review).

    Retention: the -Keep newest runtime folders (by installedAt) are kept; an older one is removed
    only when it is not the version current.json names. It is renamed first and deleted after, so a
    runtime that is still in use (a running launcher has its folder as working directory) cannot be
    renamed and is left alone (reported in pruneSkipped).

    Writes only below <InstallRoot>\runtime and <InstallRoot>\launcher; ide-solutions.json and the
    other files of %LOCALAPPDATA%\TwinCATAutomation are never touched. The last stdout line is
    "TCAUTO_INSTALL_RESULT <json>" ({success, data | error}); exit code 0 on success, 1 otherwise.

.PARAMETER InstallRoot
    Install root (holds runtime\ and launcher\). Default: %TCAUTO_RUNTIME_ROOT% when set, else
    %LOCALAPPDATA%\TwinCATAutomation. The launcher finds current.json the same way
    (TCAUTO_RUNTIME_ROOT, else the parent of its own folder).

.PARAMETER AllowDirty
    Install even when the working tree has uncommitted changes below mcp-server\ or
    src\TwinCATAutomation\ (tcauto-source.json then says dirty: true). Default: refuse (WORKTREE_DIRTY).

.PARAMETER Keep
    Number of runtime versions to keep (1..20, default 3). The current version is never removed.

.PARAMETER NpmPath
    npm executable used for "npm ci --omit=dev" (default npm.cmd from PATH). Tests pass a stand-in.

.EXAMPLE
    powershell -NoProfile -File scripts\Install-TcAutoRuntime.ps1
#>
[CmdletBinding()]
param(
    [string]$InstallRoot,
    [switch]$AllowDirty,
    [ValidateRange(1, 20)][int]$Keep = 3,
    [string]$NpmPath = 'npm.cmd'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:Warnings = [System.Collections.Generic.List[string]]::new()
$script:Staging = $null
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$versionPattern = '^[0-9a-f]{7,64}(-dirty-[0-9]{8}T[0-9]{6}Z)?$'

function Write-InstallResult {
    param([Parameter(Mandatory)][hashtable]$Result)
    Write-Output ('TCAUTO_INSTALL_RESULT ' + (ConvertTo-Json -InputObject $Result -Depth 6 -Compress))
}

function Stop-Install {
    param([string]$Code, [string]$Message, [string]$Hint, $Data)
    if ($null -ne $script:Staging -and (Test-Path -LiteralPath $script:Staging)) {
        try { Remove-Item -LiteralPath $script:Staging -Recurse -Force -ErrorAction Stop } catch { }
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
    # temp file in the same folder, then an atomic replace / move onto Path
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
    $dir = Split-Path -Parent $Path
    $tmp = Join-Path $dir ('.' + (Split-Path -Leaf $Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    [System.IO.File]::WriteAllText($tmp, $Content, $utf8NoBom)
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

$script:InstallPathspec = @('--', 'mcp-server', 'src/TwinCATAutomation', ':(exclude)mcp-server/test', ':(exclude)mcp-server/node_modules')

function Get-InstallFileList {
    # Repository-relative paths (forward slashes) of the files to install: tracked + untracked that
    # are not git-ignored (git ls-files -co --exclude-standard), below the pathspec above. Tracked
    # files deleted in the working tree are left out (only reachable with -AllowDirty).
    param([Parameter(Mandatory)][string]$RepoRoot)
    $oldEnc = $null
    try { $oldEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { $oldEnc = $null }
    try { $r = Invoke-Native -File 'git' -Arguments (@('-C', $RepoRoot, '-c', 'core.quotepath=off', 'ls-files', '-co', '--exclude-standard') + $script:InstallPathspec) }
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

function Copy-InstallFiles {
    # copies each listed file to the same relative path below Destination
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$Destination, [Parameter(Mandatory)]$Files)
    foreach ($rel in $Files) {
        $relWin = $rel -replace '/', '\'
        $src = Join-Path $RepoRoot $relWin
        $dst = Join-Path $Destination $relWin
        try {
            $dir = Split-Path -Parent $dst
            if (-not [System.IO.Directory]::Exists($dir)) { $null = [System.IO.Directory]::CreateDirectory($dir) }
            [System.IO.File]::Copy($src, $dst, $true)
        }
        catch {
            Stop-Install -Code 'COPY_FAILED' -Message "cannot copy $src`: $($_.Exception.Message)" `
                -Hint 'A file in a OneDrive folder that cannot be downloaded (cloud file provider error 383 / "The cloud sync provider failed to validate the downloaded data") cannot be copied: right-click the checkout folder in Explorer -> "Always keep on this device", wait for OneDrive to finish, then run this script again (#162).'
        }
    }
}

# ------------------------------------------------------------------ source checkout
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath
$srcMcp = Join-Path $repoRoot 'mcp-server'
$srcModule = Join-Path $repoRoot 'src\TwinCATAutomation'
$srcLauncher = Join-Path $srcMcp 'launcher\tcauto-launcher.mjs'
foreach ($p in @((Join-Path $srcMcp 'index.js'), (Join-Path $srcMcp 'package-lock.json'), (Join-Path $srcModule 'TwinCATAutomation.psd1'), $srcLauncher)) {
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { Stop-Install -Code 'SOURCE_INCOMPLETE' -Message "$p not found; run this script from a TcAuto checkout (scripts\Install-TcAutoRuntime.ps1)." }
}

# ------------------------------------------------------------------ install root
if (-not $InstallRoot) {
    if ($env:TCAUTO_RUNTIME_ROOT) { $InstallRoot = $env:TCAUTO_RUNTIME_ROOT }
    else { $InstallRoot = Join-Path $env:LOCALAPPDATA 'TwinCATAutomation' }
}
$InstallRoot = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
$realRoot = if ($env:LOCALAPPDATA) { [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'TwinCATAutomation')).TrimEnd('\') } else { $null }
if ($env:TCAUTO_TEST_FORBID_REAL_STATE -eq '1' -and $realRoot -and $InstallRoot -ieq $realRoot) {
    Stop-Install -Code 'TCAUTO_REAL_STATE_REFUSED' -Message "TCAUTO_TEST_FORBID_REAL_STATE=1: refusing to install into the real $realRoot (#118); pass -InstallRoot or TCAUTO_RUNTIME_ROOT."
}
$runtimeFolder = Join-Path $InstallRoot 'runtime'
$launcherFolder = Join-Path $InstallRoot 'launcher'
$currentJson = Join-Path $runtimeFolder 'current.json'

# ------------------------------------------------------------------ commit / branch / dirty (git)
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Stop-Install -Code 'GIT_NOT_FOUND' -Message 'git is not on PATH; it is needed to read the commit and whether the working tree is dirty.'
}
$r = Invoke-Native -File 'git' -Arguments @('-C', $repoRoot, 'rev-parse', 'HEAD')
$commit = (@($r.Lines) | Select-Object -First 1)
if ($r.Code -ne 0 -or "$commit" -notmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$') {
    Stop-Install -Code 'GIT_FAILED' -Message "git rev-parse HEAD failed in $repoRoot (exit $($r.Code)): $(@($r.Lines) -join ' | ')"
}
$commit = "$commit".Trim().ToLowerInvariant()
$r = Invoke-Native -File 'git' -Arguments @('-C', $repoRoot, 'symbolic-ref', '--quiet', 'HEAD')
$ref = if ($r.Code -eq 0) { "$(@($r.Lines) | Select-Object -First 1)".Trim() } else { $null }
$branch = if ($ref -and $ref.StartsWith('refs/heads/')) { $ref.Substring(11) } else { $null }
$r = Invoke-Native -File 'git' -Arguments (@('-C', $repoRoot, 'status', '--porcelain', '--untracked-files=all') + $script:InstallPathspec)
if ($r.Code -ne 0) { Stop-Install -Code 'GIT_FAILED' -Message "git status failed in $repoRoot (exit $($r.Code)): $(@($r.Lines) -join ' | ')" }
$changes = @(@($r.Lines) | Where-Object { "$_".Trim() })
$dirty = $changes.Count -gt 0
if ($dirty -and -not $AllowDirty) {
    Stop-Install -Code 'WORKTREE_DIRTY' -Message "$($changes.Count) uncommitted change(s) below mcp-server\ or src\TwinCATAutomation\ in $repoRoot; nothing was installed." `
        -Hint 'Commit (or stash) them and run again, or pass -AllowDirty to install them as a dirty version (tcauto-source.json dirty: true).' `
        -Data @{ changes = @($changes | Select-Object -First 20) }
}

$installedAt = [DateTime]::UtcNow
$shortCommit = $commit.Substring(0, 12)
$version = if ($dirty) { "$shortCommit-dirty-$($installedAt.ToString('yyyyMMddTHHmmssZ'))" } else { $shortCommit }
$target = Join-Path $runtimeFolder $version

Write-Host "TcAuto runtime install (#162)"
Write-Host "  source:  $repoRoot ($(if ($branch) { $branch } else { 'detached' }) $shortCommit$(if ($dirty) { ', DIRTY' }))"
Write-Host "  target:  $target"

$null = New-Item -ItemType Directory -Force -Path $runtimeFolder
$null = New-Item -ItemType Directory -Force -Path $launcherFolder
$current = Read-JsonFile $currentJson
$currentVersion = if ($null -ne $current -and "$($current.version)" -match $versionPattern) { [string]$current.version } else { $null }

# ------------------------------------------------------------------ copy + npm ci (staging folder, then rename)
$reused = $false
if (Test-Path -LiteralPath $target) {
    $stamp = Read-JsonFile (Join-Path $target 'tcauto-source.json')
    $complete = $null -ne $stamp -and "$($stamp.commit)" -eq $commit -and $stamp.dirty -eq $false -and
        (Test-Path -LiteralPath (Join-Path $target 'mcp-server\index.js')) -and
        (Test-Path -LiteralPath (Join-Path $target 'mcp-server\node_modules\@modelcontextprotocol\sdk\package.json'))
    if ($complete) {
        $reused = $true
        Write-Host "  $version is installed already; reusing it"
    }
    elseif ($version -eq $currentVersion) {
        Stop-Install -Code 'RUNTIME_DAMAGED' -Message "$target is the current runtime but incomplete (no valid tcauto-source.json or node_modules); it is not replaced while it may be running." `
            -Hint 'Install another version (commit something, or -AllowDirty) and ReloadRuntime to it, then run this script again.'
    }
    else {
        try { Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop }
        catch { Stop-Install -Code 'RUNTIME_IN_USE' -Message "incomplete $target cannot be removed: $($_.Exception.Message)" -Hint 'Close the MCP client that runs it, then run this script again.' }
    }
}

if (-not $reused) {
    $script:Staging = Join-Path $runtimeFolder ('.staging-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Force -Path $script:Staging
    Write-Host '  copying mcp-server and src\TwinCATAutomation ...'
    # only files git lists (tracked + untracked, not ignored): an ignored temp_*.ps1 never reaches the runtime
    $installFiles = Get-InstallFileList -RepoRoot $repoRoot
    Copy-InstallFiles -RepoRoot $repoRoot -Destination $script:Staging -Files $installFiles
    Write-Host "  $($installFiles.Count) files copied"

    Write-Host '  npm ci --omit=dev ...'
    $stageMcp = Join-Path $script:Staging 'mcp-server'
    Push-Location -LiteralPath $stageMcp
    try { $npm = Invoke-Native -File $NpmPath -Arguments @('ci', '--omit=dev', '--no-audit', '--no-fund') }
    catch { $npm = @{ Code = -1; Lines = @($_.Exception.Message) } }
    finally { Pop-Location }
    if ($npm.Code -ne 0) {
        Stop-Install -Code 'NPM_CI_FAILED' -Message "npm ci --omit=dev failed in the staging copy (exit $($npm.Code)): $((@($npm.Lines) | Select-Object -Last 8) -join ' | ')" `
            -Hint 'Check that Node.js >= 22 and npm are on PATH and the npm registry (or cache) is reachable, then run this script again.'
    }

    $stampData = [ordered]@{
        schema      = 1
        kind        = 'tcauto-runtime'
        sourceUrl   = $null
        release     = $null
        commit      = $commit
        ref         = $ref
        branch      = $branch
        dirty       = $dirty
        installedAt = $installedAt.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        sourcePath  = $repoRoot
        version     = $version
    }
    [System.IO.File]::WriteAllText((Join-Path $script:Staging 'tcauto-source.json'), (ConvertTo-Json -InputObject $stampData -Depth 3), $utf8NoBom)
    try { [System.IO.Directory]::Move($script:Staging, $target) }
    catch { Stop-Install -Code 'RENAME_FAILED' -Message "cannot rename the staging copy to $target`: $($_.Exception.Message)" }
    $script:Staging = $null
}

# ------------------------------------------------------------------ current.json (atomic)
$stampNow = Read-JsonFile (Join-Path $target 'tcauto-source.json')
$currentData = [ordered]@{
    schema      = 1
    version     = $version
    commit      = $commit
    branch      = $branch
    dirty       = $dirty
    installedAt = if ($null -ne $stampNow) { [string]$stampNow.installedAt } else { $null }
    updatedAt   = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    runtimeDir  = $target
}
try { Write-Utf8File -Path $currentJson -Content (ConvertTo-Json -InputObject $currentData -Depth 3) }
catch { Stop-Install -Code 'CURRENT_WRITE_FAILED' -Message "cannot write $currentJson`: $($_.Exception.Message)" }
Write-Host "  current.json -> $version"

# ------------------------------------------------------------------ launcher (only when changed)
$launcherPath = Join-Path $launcherFolder 'tcauto-launcher.mjs'
$launcherUpdated = $false
if ((Get-FileSha256 $srcLauncher) -ne (Get-FileSha256 $launcherPath)) {
    try { Write-Utf8File -Path $launcherPath -Content ([System.IO.File]::ReadAllText($srcLauncher, [System.Text.Encoding]::UTF8)) }
    catch { Stop-Install -Code 'LAUNCHER_WRITE_FAILED' -Message "cannot write $launcherPath`: $($_.Exception.Message)" }
    $launcherUpdated = $true
    Write-Host "  launcher updated: $launcherPath"
}
else { Write-Host "  launcher unchanged: $launcherPath" }

# ------------------------------------------------------------------ retention
$pruned = [System.Collections.Generic.List[string]]::new()
$pruneSkipped = [System.Collections.Generic.List[object]]::new()
$versions = @(Get-ChildItem -LiteralPath $runtimeFolder -Directory | Where-Object { $_.Name -match $versionPattern } | ForEach-Object {
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
Get-ChildItem -LiteralPath $runtimeFolder -Directory -Force | Where-Object {
    $_.Name -like '.trash-*' -or ($_.Name -like '.staging-*' -and $_.CreationTimeUtc -lt [DateTime]::UtcNow.AddDays(-1))
} | ForEach-Object {
    $left = $_.FullName
    try { Remove-Item -LiteralPath $left -Recurse -Force -ErrorAction Stop } catch { $script:Warnings.Add("leftover $left not removed") }
}
$rank = 0
foreach ($v in $versions) {
    $rank++
    if ($rank -le $Keep -or $v.Name -eq $version) { continue }
    $trash = Join-Path $runtimeFolder ('.trash-' + $v.Name + '-' + [guid]::NewGuid().ToString('N'))
    try { [System.IO.Directory]::Move($v.Path, $trash) }
    catch {
        $pruneSkipped.Add([ordered]@{ version = $v.Name; reason = "in use or locked: $($_.Exception.Message)" })
        continue
    }
    try {
        Remove-Item -LiteralPath $trash -Recurse -Force -ErrorAction Stop
        $pruned.Add($v.Name)
    }
    catch {
        $pruned.Add($v.Name)
        $script:Warnings.Add("$($v.Name) was renamed to $trash but not deleted completely: $($_.Exception.Message)")
    }
}
if ($pruned.Count -gt 0) { Write-Host "  removed old versions: $($pruned -join ', ')" }
foreach ($s in $pruneSkipped) { Write-Host "  kept $($s.version): $($s.reason)" -ForegroundColor Yellow }

$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
$nodeExe = if ($nodeCmd) { $nodeCmd.Source } else { 'node' }
Write-Host ''
Write-Host "[OK] runtime $version installed." -ForegroundColor Green
Write-Host '  Register once (MCP client -> launcher), see docs/setup-mcp.md:'
Write-Host "    claude mcp add --scope user tcauto -- `"$nodeExe`" `"$launcherPath`""
Write-Host '  Already registered with the launcher: call the MCP tool ReloadRuntime, then ConnectIde again.'

Write-InstallResult @{
    success = $true
    data    = [ordered]@{
        installRoot     = $InstallRoot
        runtimeDir      = $target
        version         = $version
        commit          = $commit
        branch          = $branch
        dirty           = $dirty
        reused          = $reused
        previousCurrent = $currentVersion
        currentJson     = $currentJson
        launcherPath    = $launcherPath
        launcherUpdated = $launcherUpdated
        pruned          = @($pruned)
        pruneSkipped    = @($pruneSkipped)
        warnings        = @($script:Warnings)
    }
}
exit 0
