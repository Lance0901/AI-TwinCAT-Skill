<#
.SYNOPSIS
    Build the customer release zip TcAuto-<version>.zip (+ .sha256) of this checkout (#20).

.DESCRIPTION
    Zip layout (the customer extracts it and runs Install-TcAuto.ps1; no Node.js needed on the PC):
      Install-TcAuto.ps1            scripts\Install-TcAuto.ps1
      lib\TcAutoInstall.ps1         scripts\lib\ (install steps shared with Install-TcAutoRuntime.ps1)
      lib\tcauto-client-config.mjs  scripts\lib\ (merges the tcauto entry into the client configs)
      node\node.exe, node\LICENSE   official Node.js win-x64 build (version pinned below)
      launcher\tcauto-launcher.mjs  mcp-server\launcher\
      runtime\<12-char commit>\     the same files Install-TcAutoRuntime.ps1 installs (git ls-files
                                    -co --exclude-standard below mcp-server\ without test\ and
                                    src\TwinCATAutomation\) + production node_modules
                                    (npm ci --omit=dev) + tcauto-source.json (release = <version>)
      tcauto-release.json           version, commit, node version / SHA256, build time
      README.txt

    node.exe: node-v<NodeVersion>-win-x64.zip is downloaded from https://nodejs.org/dist/v<NodeVersion>/
    and must match the SHA256 pinned in this script AND the line in that release's SHASUMS256.txt;
    node.exe inside must match the pinned SHA256 of win-x64/node.exe. -NodeExePath takes a local
    node.exe instead (same pinned SHA256 check; -AllowUnverifiedNode accepts another build, for tests,
    and writes node.verified = false into tcauto-release.json).

    <version>: -Version, else "git describe --tags --always --match v*" without the leading v. A
    working tree with uncommitted changes (anything "git status --porcelain" lists) is refused
    (WORKTREE_DIRTY) unless -AllowDirty; the version then ends in -dirty and the runtime folder is
    <commit>-dirty-<UTC time>.
    The last stdout line is "TCAUTO_INSTALL_RESULT <json>" ({success, data | error}).

.PARAMETER OutputDir
    Folder for the zip and .sha256 (default <repo>\dist, git-ignored).

.PARAMETER Version
    Release version (default from git describe; characters 0-9 A-Z a-z . _ + -).

.PARAMETER NodeExePath
    Local node.exe to put into the zip instead of downloading the pinned build.

.PARAMETER AllowUnverifiedNode
    With -NodeExePath: accept a node.exe whose SHA256 is not the pinned one (tests only).

.PARAMETER AllowDirty
    Build from a working tree with uncommitted changes (version gets -dirty).

.PARAMETER NpmPath
    npm executable used for "npm ci --omit=dev" in the runtime copy (default npm.cmd from PATH).

.EXAMPLE
    powershell -NoProfile -File scripts\Build-TcAutoRelease.ps1
#>
[CmdletBinding()]
param(
    [string]$OutputDir,
    [string]$Version,
    [string]$NodeExePath,
    [switch]$AllowUnverifiedNode,
    [switch]$AllowDirty,
    [string]$NpmPath = 'npm.cmd'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

. (Join-Path $PSScriptRoot 'lib\TcAutoInstall.ps1')

# anything not handled below still ends with a result line; Stop-Install removes the work folder
# (dist\.build-*, $script:TcInstallStaging once it exists)
trap {
    $msg = "$($_.Exception.Message) (at $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber))"
    Stop-Install -Code 'BUILD_FAILED' -Message $msg -Hint 'No zip was written. Fix the cause and run Build-TcAutoRelease.ps1 again.'
}

# Node.js build in the zip: an LTS line that CI tests (check.yml: Node 22 and 24). Raise all three
# values together, from https://nodejs.org/dist/v<version>/SHASUMS256.txt.
$NodeVersion = '24.22.2'
$NodeZipSha256 = 'ca1bff5d8ead13c9f2ea404a176db46bd430704d5b5113734049fa365e7799e2'  # node-v24.22.2-win-x64.zip
$NodeExeSha256 = '1c331340fa6cac5e4294725959070a143fa0507195a78ad77eed7943f719aac9'  # win-x64/node.exe

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath
$sources = @{
    installer    = Join-Path $repoRoot 'scripts\Install-TcAuto.ps1'
    installLib   = Join-Path $repoRoot 'scripts\lib\TcAutoInstall.ps1'
    clientConfig = Join-Path $repoRoot 'scripts\lib\tcauto-client-config.mjs'
    launcher     = Join-Path $repoRoot 'mcp-server\launcher\tcauto-launcher.mjs'
    index        = Join-Path $repoRoot 'mcp-server\index.js'
    instructions = Join-Path $repoRoot 'mcp-server\instructions.md'   # #307: MCP instructions (flow card)
    lock         = Join-Path $repoRoot 'mcp-server\package-lock.json'
}
foreach ($p in $sources.Values) {
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { Stop-Install -Code 'SOURCE_INCOMPLETE' -Message "$p not found; run this script from a TcAuto checkout." }
}
if (-not $OutputDir) { $OutputDir = Join-Path $repoRoot 'dist' }
$OutputDir = [System.IO.Path]::GetFullPath($OutputDir).TrimEnd('\')

# ------------------------------------------------------------------ commit / dirty / version
$git = Get-TcGitSource -RepoRoot $repoRoot -Pathspec @('--', '.') -AllowDirty:$AllowDirty -DirtyWhat 'in the working tree'
$builtAt = [DateTime]::UtcNow
if (-not $Version) {
    $r = Invoke-Native -File 'git' -Arguments @('-C', $repoRoot, 'describe', '--tags', '--always', '--match', 'v*')
    if ($r.Code -ne 0) { Stop-Install -Code 'GIT_FAILED' -Message "git describe failed (exit $($r.Code)): $(@($r.Lines) -join ' | ')" }
    $Version = "$(@($r.Lines) | Select-Object -First 1)".Trim() -replace '^v', ''
    if ($git.dirty) { $Version += '-dirty' }
}
if ($Version -notmatch '^[0-9A-Za-z._+-]{1,64}$') { Stop-Install -Code 'BAD_ARGUMENT' -Message "version '$Version' has characters a file name should not have (allowed: 0-9 A-Z a-z . _ + -)." }
$short = $git.commit.Substring(0, 12)
$runtimeVersion = if ($git.dirty) { "$short-dirty-$($builtAt.ToString('yyyyMMddTHHmmssZ'))" } else { $short }
$zipName = "TcAuto-$Version.zip"

Write-Host "TcAuto release build (#20): $zipName"
Write-Host "  source:  $repoRoot ($short$(if ($git.dirty) { ', DIRTY' }))"
Write-Host "  output:  $OutputDir"

$null = New-Item -ItemType Directory -Force -Path $OutputDir
$work = Join-Path $OutputDir ('.build-' + [guid]::NewGuid().ToString('N'))
$script:TcInstallStaging = $work   # Stop-Install removes it
$pkg = Join-Path $work 'pkg'
$null = New-Item -ItemType Directory -Force -Path $pkg

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# ------------------------------------------------------------------ node.exe
$nodeDir = Join-Path $pkg 'node'
$null = New-Item -ItemType Directory -Force -Path $nodeDir
$nodeInfo = [ordered]@{ version = $null; sha256 = $null; source = $null; verified = $false }
if ($NodeExePath) {
    if (-not (Test-Path -LiteralPath $NodeExePath -PathType Leaf)) { Stop-Install -Code 'NODE_NOT_FOUND' -Message "-NodeExePath $NodeExePath not found." }
    $hash = (Get-FileSha256 $NodeExePath).ToLowerInvariant()
    $verified = $hash -eq $NodeExeSha256
    if (-not $verified -and -not $AllowUnverifiedNode) {
        Stop-Install -Code 'NODE_HASH_MISMATCH' -Message "$NodeExePath has SHA256 $hash, not the one of Node.js $NodeVersion win-x64/node.exe ($NodeExeSha256)." `
            -Hint "Use node.exe from node-v$NodeVersion-win-x64.zip (https://nodejs.org/dist/v$NodeVersion/), or omit -NodeExePath to download it."
    }
    [System.IO.File]::Copy($NodeExePath, (Join-Path $nodeDir 'node.exe'), $true)
    $r = Invoke-Native -File $NodeExePath -Arguments @('--version')
    $nodeInfo.version = "$(@($r.Lines) | Select-Object -First 1)".Trim() -replace '^v', ''
    $nodeInfo.sha256 = $hash
    $nodeInfo.source = 'local'
    $nodeInfo.verified = $verified
    if (-not $verified) { $script:TcInstallWarnings.Add("node.exe is not the pinned Node.js $NodeVersion build (-AllowUnverifiedNode); do not publish this zip.") }
}
else {
    try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12 } catch { }
    $base = "https://nodejs.org/dist/v$NodeVersion"
    $zipFile = "node-v$NodeVersion-win-x64.zip"
    $dl = Join-Path $work 'download'
    $null = New-Item -ItemType Directory -Force -Path $dl
    Write-Host "  downloading $base/$zipFile ..."
    try {
        Invoke-WebRequest -UseBasicParsing -Uri "$base/SHASUMS256.txt" -OutFile (Join-Path $dl 'SHASUMS256.txt')
        Invoke-WebRequest -UseBasicParsing -Uri "$base/$zipFile" -OutFile (Join-Path $dl $zipFile)
    }
    catch { Stop-Install -Code 'NODE_DOWNLOAD_FAILED' -Message "cannot download Node.js $NodeVersion from $base`: $($_.Exception.Message)" -Hint 'Check the network / proxy, or download the zip yourself and pass its node.exe with -NodeExePath.' }
    $sums = @{}
    foreach ($l in [System.IO.File]::ReadAllLines((Join-Path $dl 'SHASUMS256.txt'))) {
        if ($l -match '^([0-9a-f]{64})\s+\*?(\S+)$') { $sums[$Matches[2]] = $Matches[1] }
    }
    $got = (Get-FileSha256 (Join-Path $dl $zipFile)).ToLowerInvariant()
    if ($sums[$zipFile] -ne $NodeZipSha256 -or $got -ne $NodeZipSha256) {
        Stop-Install -Code 'NODE_HASH_MISMATCH' -Message "$zipFile SHA256 $got; SHASUMS256.txt says $($sums[$zipFile]); pinned $NodeZipSha256. Nothing was built."
    }
    if ($sums['win-x64/node.exe'] -ne $NodeExeSha256) { Stop-Install -Code 'NODE_HASH_MISMATCH' -Message "SHASUMS256.txt win-x64/node.exe is $($sums['win-x64/node.exe']), pinned $NodeExeSha256." }
    $zip = [System.IO.Compression.ZipFile]::OpenRead((Join-Path $dl $zipFile))
    try {
        foreach ($name in @('node.exe', 'LICENSE')) {
            $entry = $zip.GetEntry("node-v$NodeVersion-win-x64/$name")
            if ($null -eq $entry) { Stop-Install -Code 'NODE_DOWNLOAD_FAILED' -Message "$zipFile has no node-v$NodeVersion-win-x64/$name." }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $nodeDir $name), $true)
        }
    }
    finally { $zip.Dispose() }
    $exeHash = (Get-FileSha256 (Join-Path $nodeDir 'node.exe')).ToLowerInvariant()
    if ($exeHash -ne $NodeExeSha256) { Stop-Install -Code 'NODE_HASH_MISMATCH' -Message "extracted node.exe SHA256 $exeHash, pinned $NodeExeSha256." }
    $nodeInfo.version = $NodeVersion
    $nodeInfo.sha256 = $exeHash
    $nodeInfo.source = "$base/$zipFile"
    $nodeInfo.verified = $true
    Remove-Item -LiteralPath $dl -Recurse -Force
}
Write-Host "  node.exe $($nodeInfo.version) ($(if ($nodeInfo.verified) { 'SHA256 verified' } else { 'NOT verified' }))"

# ------------------------------------------------------------------ installer, launcher, runtime
$null = New-Item -ItemType Directory -Force -Path (Join-Path $pkg 'lib'), (Join-Path $pkg 'launcher'), (Join-Path $pkg 'runtime')
[System.IO.File]::Copy($sources.installer, (Join-Path $pkg 'Install-TcAuto.ps1'), $true)
[System.IO.File]::Copy($sources.installLib, (Join-Path $pkg 'lib\TcAutoInstall.ps1'), $true)
[System.IO.File]::Copy($sources.clientConfig, (Join-Path $pkg 'lib\tcauto-client-config.mjs'), $true)
[System.IO.File]::Copy($sources.launcher, (Join-Path $pkg 'launcher\tcauto-launcher.mjs'), $true)

$r = Invoke-Native -File 'git' -Arguments @('-C', $repoRoot, 'remote', 'get-url', 'origin')
$sourceUrl = if ($r.Code -eq 0) { ("$(@($r.Lines) | Select-Object -First 1)".Trim() -replace '^git@github\.com:', 'https://github.com/') } else { $null }
if ($sourceUrl -match '://[^/@]+@') { $sourceUrl = $sourceUrl -replace '://[^/@]+@', '://' }  # no credentials in the stamp
$stamp = [ordered]@{
    schema      = 1
    kind        = 'tcauto-runtime'
    sourceUrl   = $sourceUrl
    release     = $Version
    commit      = $git.commit
    ref         = $git.ref
    branch      = $git.branch
    dirty       = $git.dirty
    installedAt = $builtAt.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    sourcePath  = $null
    version     = $runtimeVersion
}
$runtimeDir = Join-Path $pkg "runtime\$runtimeVersion"
$null = New-Item -ItemType Directory -Force -Path $runtimeDir
$fileCount = New-TcRuntimeTree -RepoRoot $repoRoot -Destination $runtimeDir -NpmPath $NpmPath -Stamp $stamp
if (-not (Test-Path -LiteralPath (Join-Path $runtimeDir 'mcp-server\node_modules\@modelcontextprotocol\sdk\package.json'))) {
    Stop-Install -Code 'NPM_CI_FAILED' -Message "npm ci left no node_modules\@modelcontextprotocol\sdk in $runtimeDir."
}

$manifest = [ordered]@{
    schema         = 1
    kind           = 'tcauto-release'
    version        = $Version
    commit         = $git.commit
    dirty          = $git.dirty
    runtimeVersion = $runtimeVersion
    builtAt        = $builtAt.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    sourceUrl      = $sourceUrl
    node           = $nodeInfo
}
[System.IO.File]::WriteAllText((Join-Path $pkg 'tcauto-release.json'), (ConvertTo-Json -InputObject $manifest -Depth 4), $script:TcUtf8NoBom)
$readme = @(
    "TcAuto $Version - TcAuto MCP server for TwinCAT 3 (commit $short)"
    ''
    '1. Check the SHA256 of the zip against TcAuto-<version>.zip.sha256 (Get-FileHash -Algorithm SHA256).'
    '2. Unblock the zip (Unblock-File, or Properties -> Unblock) and extract it.'
    '3. In the extracted folder: powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-TcAuto.ps1'
    '   (Windows client PCs default to the execution policy Restricted, which runs no script; Bypass'
    '   applies to this one powershell.exe process only and changes no setting.)'
    '4. Restart Claude Code / Claude Desktop / Codex once.'
    ''
    'Later versions: run Install-TcAuto.ps1 of the new zip, then call the MCP tool ReloadRuntime.'
    'Remove: powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-TcAuto.ps1 -Uninstall'
    "Details: docs/setup-mcp.md (customer install) in $(if ($sourceUrl) { $sourceUrl -replace '\.git$', '' } else { 'the TcAuto repository' })"
    "node\node.exe: Node.js $($nodeInfo.version) (official win-x64 build, MIT license: node\LICENSE)"
)
[System.IO.File]::WriteAllText((Join-Path $pkg 'README.txt'), (($readme -join "`r`n") + "`r`n"), $script:TcUtf8NoBom)

# ------------------------------------------------------------------ zip + sha256
$zipPath = Join-Path $OutputDir $zipName
$shaPath = "$zipPath.sha256"
$tmpZip = Join-Path $work $zipName
Write-Host '  zipping ...'
[System.IO.Compression.ZipFile]::CreateFromDirectory($pkg, $tmpZip, [System.IO.Compression.CompressionLevel]::Optimal, $false)
foreach ($old in @($zipPath, $shaPath)) { if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force } }
[System.IO.File]::Move($tmpZip, $zipPath)
$zipHash = (Get-FileSha256 $zipPath).ToLowerInvariant()
[System.IO.File]::WriteAllText($shaPath, "$zipHash  $zipName`n", $script:TcUtf8NoBom)
Remove-Item -LiteralPath $work -Recurse -Force
$script:TcInstallStaging = $null
$size = (Get-Item -LiteralPath $zipPath).Length

Write-Host ''
Write-Host "[OK] $zipPath ($([math]::Round($size / 1MB, 1)) MB)" -ForegroundColor Green
Write-Host "     SHA256 $zipHash"
Write-InstallResult @{
    success = $true
    data    = [ordered]@{
        version        = $Version
        commit         = $git.commit
        dirty          = $git.dirty
        runtimeVersion = $runtimeVersion
        zip            = $zipPath
        sha256File     = $shaPath
        sha256         = $zipHash
        sizeBytes      = $size
        runtimeFiles   = $fileCount
        node           = $nodeInfo
        warnings       = @($script:TcInstallWarnings)
    }
}
exit 0
