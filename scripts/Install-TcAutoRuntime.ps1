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
    The steps are in scripts\lib\TcAutoInstall.ps1, shared with Build-TcAutoRelease.ps1 and the
    customer installer Install-TcAuto.ps1 (#20).

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

. (Join-Path $PSScriptRoot 'lib\TcAutoInstall.ps1')

# ------------------------------------------------------------------ source checkout
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath
$srcMcp = Join-Path $repoRoot 'mcp-server'
$srcModule = Join-Path $repoRoot 'src\TwinCATAutomation'
$srcLauncher = Join-Path $srcMcp 'launcher\tcauto-launcher.mjs'
foreach ($p in @((Join-Path $srcMcp 'index.js'), (Join-Path $srcMcp 'instructions.md'), (Join-Path $srcMcp 'package-lock.json'), (Join-Path $srcModule 'TwinCATAutomation.psd1'), $srcLauncher)) {
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { Stop-Install -Code 'SOURCE_INCOMPLETE' -Message "$p not found; run this script from a TcAuto checkout (scripts\Install-TcAutoRuntime.ps1)." }
}

# ------------------------------------------------------------------ install root
$InstallRoot = Resolve-TcInstallRoot -InstallRoot $InstallRoot
$runtimeFolder = Join-Path $InstallRoot 'runtime'
$launcherFolder = Join-Path $InstallRoot 'launcher'

# ------------------------------------------------------------------ commit / branch / dirty (git)
$git = Get-TcGitSource -RepoRoot $repoRoot -AllowDirty:$AllowDirty
$commit = $git.commit
$branch = $git.branch
$dirty = $git.dirty

$installedAt = [DateTime]::UtcNow
$shortCommit = $commit.Substring(0, 12)
$version = if ($dirty) { "$shortCommit-dirty-$($installedAt.ToString('yyyyMMddTHHmmssZ'))" } else { $shortCommit }

Write-Host "TcAuto runtime install (#162)"
Write-Host "  source:  $repoRoot ($(if ($branch) { $branch } else { 'detached' }) $shortCommit$(if ($dirty) { ', DIRTY' }))"
Write-Host "  target:  $(Join-Path $runtimeFolder $version)"

$null = New-Item -ItemType Directory -Force -Path $runtimeFolder
$currentVersion = Get-TcCurrentVersion -RuntimeFolder $runtimeFolder

# ------------------------------------------------------------------ copy + npm ci (staging folder, then rename)
$stampData = [ordered]@{
    schema      = 1
    kind        = 'tcauto-runtime'
    sourceUrl   = $null
    release     = $null
    commit      = $commit
    ref         = $git.ref
    branch      = $branch
    dirty       = $dirty
    installedAt = $installedAt.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    sourcePath  = $repoRoot
    version     = $version
}
$fill = { param($staging) $null = New-TcRuntimeTree -RepoRoot $repoRoot -Destination $staging -NpmPath $NpmPath -Stamp $stampData }
$installed = Install-TcRuntimeVersion -RuntimeFolder $runtimeFolder -Version $version -Commit $commit -CurrentVersion $currentVersion -Fill $fill
$target = $installed.Target

# ------------------------------------------------------------------ current.json (atomic), launcher (only when changed), retention
$currentJson = Set-TcCurrentRuntime -RuntimeFolder $runtimeFolder -Version $version
$launcher = Update-TcLauncher -Source $srcLauncher -LauncherFolder $launcherFolder
$launcherPath = $launcher.Path
$prune = Remove-TcOldRuntimes -RuntimeFolder $runtimeFolder -Keep $Keep -Version $version

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
        reused          = $installed.Reused
        previousCurrent = $currentVersion
        currentJson     = $currentJson
        launcherPath    = $launcherPath
        launcherUpdated = $launcher.Updated
        pruned          = @($prune.Pruned)
        pruneSkipped    = @($prune.Skipped)
        warnings        = @($script:TcInstallWarnings)
    }
}
exit 0
