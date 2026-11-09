<#
.SYNOPSIS
    Install the TcAuto MCP server from a release zip and register it in Claude Code, Claude Desktop and Codex (#20).

.DESCRIPTION
    Run it from the extracted TcAuto-<version>.zip (scripts\Build-TcAutoRelease.ps1 builds it; this
    file is its Install-TcAuto.ps1). Nothing else is needed on the PC: the zip brings its own
    node.exe (official Node.js win-x64 build), which runs the launcher and the runtime.

    Install (default):
      1. Looks for TwinCAT 3 (TWINCAT3DIR, else registry HKLM\SOFTWARE\[WOW6432Node\]Beckhoff\TwinCAT3
         TwinCATDir); none found = a warning, the install goes on.
      2. Copies node\ to <InstallRoot>\node\ (only when node.exe differs; a node.exe that a running
         client uses is renamed aside, not overwritten), the runtime to <InstallRoot>\runtime\<version>\
         (staging folder, renamed when complete; an installed complete copy of the same version is
         reused), switches runtime\current.json atomically, copies launcher\tcauto-launcher.mjs when it
         changed and keeps the -Keep newest runtimes. Same code as scripts\Install-TcAutoRuntime.ps1
         (lib\TcAutoInstall.ps1).
      3. Registers "<InstallRoot>\node\node.exe <InstallRoot>\launcher\tcauto-launcher.mjs" as the MCP
         server tcauto in each of -Clients (lib\tcauto-client-config.mjs): only the tcauto entry is
         changed, every other server and setting is kept, the file is backed up first
         (<file>.bak-<yyyyMMddTHHmmss>). In an existing tcauto only command / args (Claude Code: also
         type) are set; other keys and sub-tables the user added there are kept (#204,
         data.clients[].keptKeys), except env TCAUTO_RUNTIME_ROOT, which would point the launcher at
         another install root and is removed (data.clients[].removedKeys). A kept cwd or Codex
         enabled = false is reported in data.clients[].warnings and left as it is. Its old value is
         listed in data.clients[].previous. A client whose config file (Claude Code) or config folder (Claude
         Desktop, Codex) does not exist is skipped and reported.
         Claude Desktop (#165): the MSIX package reads
         %LOCALAPPDATA%\Claude-Data\claude_<publisherId>\claude_desktop_config.json, the standard
         install %APPDATA%\Claude\claude_desktop_config.json (measured 2026-11-07, Windows 11, Claude
         Desktop MSIX 4.23118.0.0; Anthropic's documentation names only %APPDATA%\Claude). Every
         existing %LOCALAPPDATA%\Claude-Data\claude_*\ folder is written; %APPDATA%\Claude\ is written
         when that folder exists or when there is no MSIX folder. One data.clients[] row per file, with
         variant 'msix' / 'standard' ('override' for -ClaudeDesktopConfig).
      4. Runs the -Verify check (below) unless -NoVerify.
    Restart each client once afterwards. Later versions: install the new zip the same way and call
    the MCP tool ReloadRuntime (no client restart needed).

    -Verify: starts <InstallRoot>\node\node.exe with the launcher (as a client would; PATH is not
    used), sends MCP initialize + tools/list and reports the tool count and the runtime version /
    commit. It does not connect to an IDE and does not start the PowerShell bridge. Nothing is written.
    It returns only after the launcher and every process it started have exited (#208).

    -Uninstall: removes the tcauto entry from each of -Clients whose command is below InstallRoot
    (backup first), then removes <InstallRoot>\node, launcher and runtime. An entry whose command is
    elsewhere but one of whose args is below InstallRoot (e.g. "node <InstallRoot>\launcher\
    tcauto-launcher.mjs" registered by a developer) still uses this install: it is left ('shared') and
    no folder is removed (INSTALL_SHARED) unless -Force, which removes that entry too. Any other entry
    (e.g. a developer checkout) is left ('foreign'). Other files in InstallRoot (ide-solutions.json,
    ...) stay; InstallRoot itself is removed only when it is empty then. The backups stay next to the
    config files. A folder that cannot be renamed (access denied, sharing violation) is retried for up
    to 5 s before it counts as in use (INSTALL_IN_USE, #208).

    The last stdout line is "TCAUTO_INSTALL_RESULT <json>" ({success, data | error}); exit code 0 on
    success, 1 otherwise.

.PARAMETER InstallRoot
    Install root. Default: %TCAUTO_RUNTIME_ROOT% when set, else %LOCALAPPDATA%\TwinCATAutomation.

.PARAMETER Clients
    MCP clients to register / unregister: ClaudeCode, ClaudeDesktop, Codex (comma separated; default all three).

.PARAMETER ClaudeCodeConfig
    Claude Code user config (default %USERPROFILE%\.claude.json; the server goes to its top-level
    mcpServers, i.e. user scope).

.PARAMETER ClaudeDesktopConfig
    Claude Desktop config. Given: only this file is used. Default: every
    <LocalAppDataRoot>\Claude-Data\claude_*\claude_desktop_config.json (MSIX) plus
    <AppDataRoot>\Claude\claude_desktop_config.json (standard; when that folder exists or no MSIX
    folder was found).

.PARAMETER LocalAppDataRoot
    Where the MSIX Claude Desktop folders (Claude-Data\claude_*) are looked for. Default %LOCALAPPDATA%.

.PARAMETER AppDataRoot
    Where the standard Claude Desktop folder (Claude\) is looked for. Default %APPDATA%.

.PARAMETER CodexConfig
    Codex config (default %CODEX_HOME%\config.toml, else %USERPROFILE%\.codex\config.toml).

.PARAMETER PackageRoot
    Extracted release folder (default: the folder of this script).

.PARAMETER Keep
    Number of runtime versions to keep (1..20, default 3). The current version is never removed.

.PARAMETER Uninstall
    Unregister the clients and remove the installed files (see DESCRIPTION).

.PARAMETER Force
    With -Uninstall: also remove a tcauto entry that only uses this install through its args
    ('shared', e.g. "node <InstallRoot>\launcher\tcauto-launcher.mjs") and remove the files anyway.

.PARAMETER Verify
    Only check the installed server (initialize + tools/list); writes nothing.

.PARAMETER NoVerify
    Install without the final -Verify check.

.PARAMETER VerifyTimeoutSec
    Time limit of the -Verify check (5..600 s, default 90).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-TcAuto.ps1
    (Windows client PCs default to the execution policy Restricted, under which no script runs;
    -ExecutionPolicy Bypass applies to this one powershell.exe process only.)

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-TcAuto.ps1 -Clients ClaudeCode,Codex

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-TcAuto.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$InstallRoot,
    [string[]]$Clients = @('ClaudeCode', 'ClaudeDesktop', 'Codex'),
    [string]$ClaudeCodeConfig,
    [string]$ClaudeDesktopConfig,
    [string]$CodexConfig,
    [string]$LocalAppDataRoot,
    [string]$AppDataRoot,
    [string]$PackageRoot,
    [ValidateRange(1, 20)][int]$Keep = 3,
    [switch]$Uninstall,
    [switch]$Force,
    [switch]$Verify,
    [switch]$NoVerify,
    [ValidateRange(5, 600)][int]$VerifyTimeoutSec = 90
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

. (Join-Path $PSScriptRoot 'lib\TcAutoInstall.ps1')

# anything not handled below still ends with a result line (and no staging folder left behind)
trap {
    $msg = "$($_.Exception.Message) (at $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber))"
    Stop-Install -Code 'INSTALL_FAILED' -Message $msg -Hint 'Nothing after this step was done. Run Install-TcAuto.ps1 again; if it fails the same way, report this message.'
}

$clientConfigScript = Join-Path $PSScriptRoot 'lib\tcauto-client-config.mjs'
$clientIds = @{ ClaudeCode = 'claude-code'; ClaudeDesktop = 'claude-desktop'; Codex = 'codex' }

# -Clients through powershell -File arrives as one string "A,B": split and validate by hand
$wanted = [System.Collections.Generic.List[string]]::new()
foreach ($c in @($Clients)) {
    foreach ($part in ("$c" -split '[,\s]+')) {
        if (-not $part) { continue }
        $name = @($clientIds.Keys | Where-Object { $_ -ieq $part }) | Select-Object -First 1
        if (-not $name) { Stop-Install -Code 'BAD_ARGUMENT' -Message "unknown client '$part' in -Clients" -Hint 'Use ClaudeCode, ClaudeDesktop and/or Codex, comma separated.' }
        if (-not $wanted.Contains($name)) { $wanted.Add($name) }
    }
}
if ($Uninstall -and $Verify) { Stop-Install -Code 'BAD_ARGUMENT' -Message '-Uninstall and -Verify cannot be combined.' }

# ------------------------------------------------------------------ paths
if (-not $PackageRoot) { $PackageRoot = $PSScriptRoot }
$PackageRoot = [System.IO.Path]::GetFullPath($PackageRoot).TrimEnd('\')
$InstallRoot = Resolve-TcInstallRoot -InstallRoot $InstallRoot
$runtimeFolder = Join-Path $InstallRoot 'runtime'
$launcherFolder = Join-Path $InstallRoot 'launcher'
$nodeFolder = Join-Path $InstallRoot 'node'
$installedNode = Join-Path $nodeFolder 'node.exe'
$launcherPath = Join-Path $launcherFolder 'tcauto-launcher.mjs'
$userHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { [Environment]::GetFolderPath('UserProfile') }
if (-not $ClaudeCodeConfig) { $ClaudeCodeConfig = Join-Path $userHome '.claude.json' }
if (-not $CodexConfig) {
    $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $userHome '.codex' }
    $CodexConfig = Join-Path $codexHome 'config.toml'
}
if (-not $LocalAppDataRoot) { $LocalAppDataRoot = $env:LOCALAPPDATA }
if (-not $AppDataRoot) { $AppDataRoot = $env:APPDATA }

function Get-TcDesktopConfigTargets {
    # Claude Desktop config files (#165): -ClaudeDesktopConfig alone when given; else every MSIX folder
    # <LocalAppDataRoot>\Claude-Data\claude_<publisherId>\ plus the standard <AppDataRoot>\Claude\ when
    # that folder exists or no MSIX folder was found (then it is skipped when missing, as before).
    # Measured 2026-11-07 (Windows 11, Claude Desktop MSIX Claude_4.23118.0.0_x64__pzs8sxrjxfjjc): the
    # MSIX app reads Claude-Data\claude_pzs8sxrjxfjjc\claude_desktop_config.json, not %APPDATA%\Claude.
    if ($ClaudeDesktopConfig) { return @([ordered]@{ file = $ClaudeDesktopConfig; variant = 'override' }) }
    $targets = [System.Collections.Generic.List[object]]::new()
    if ($LocalAppDataRoot) {
        $dataDir = Join-Path $LocalAppDataRoot 'Claude-Data'
        if (Test-Path -LiteralPath $dataDir -PathType Container) {
            foreach ($d in @(Get-ChildItem -LiteralPath $dataDir -Directory -Force | Where-Object { $_.Name -like 'claude_*' } | Sort-Object Name)) {
                $targets.Add([ordered]@{ file = (Join-Path $d.FullName 'claude_desktop_config.json'); variant = 'msix' })
            }
        }
    }
    $standardDir = if ($AppDataRoot) { Join-Path $AppDataRoot 'Claude' } else { $null }
    if ($standardDir -and ($targets.Count -eq 0 -or (Test-Path -LiteralPath $standardDir -PathType Container))) {
        $targets.Add([ordered]@{ file = (Join-Path $standardDir 'claude_desktop_config.json'); variant = 'standard' })
    }
    return @($targets)
}

# one entry per config file: name (client), file, variant (Claude Desktop only)
$configTargets = [System.Collections.Generic.List[object]]::new()
foreach ($name in $wanted) {
    if ($name -eq 'ClaudeDesktop') {
        foreach ($t in @(Get-TcDesktopConfigTargets)) { $configTargets.Add([ordered]@{ name = $name; file = $t.file; variant = $t.variant }) }
    }
    elseif ($name -eq 'ClaudeCode') { $configTargets.Add([ordered]@{ name = $name; file = $ClaudeCodeConfig; variant = $null }) }
    else { $configTargets.Add([ordered]@{ name = $name; file = $CodexConfig; variant = $null }) }
}
if ($env:TCAUTO_TEST_FORBID_REAL_STATE -eq '1' -and -not $Verify) {
    # tests never touch the real Claude Desktop configs (#165); the shell folders, not the environment
    $realDirs = @(
        (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Claude-Data'),
        (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Claude')
    ) | ForEach-Object { (Get-TcLongPath -Path $_).TrimEnd('\') + '\' }
    foreach ($t in @($configTargets | Where-Object { $_.name -eq 'ClaudeDesktop' })) {
        $long = Get-TcLongPath -Path $t.file
        foreach ($rd in $realDirs) {
            if ($long.StartsWith($rd, [System.StringComparison]::OrdinalIgnoreCase)) {
                Stop-Install -Code 'TCAUTO_REAL_STATE_REFUSED' -Message "TCAUTO_TEST_FORBID_REAL_STATE=1: refusing to touch the real Claude Desktop config $($t.file) (#165); pass -ClaudeDesktopConfig or -LocalAppDataRoot and -AppDataRoot."
            }
        }
    }
}
$backupStamp = (Get-Date).ToString('yyyyMMddTHHmmss')

if ($env:TCAUTO_RUNTIME_ROOT -and ((Get-TcLongPath -Path $env:TCAUTO_RUNTIME_ROOT) -ine $InstallRoot)) {
    $script:TcInstallWarnings.Add("TCAUTO_RUNTIME_ROOT=$env:TCAUTO_RUNTIME_ROOT is set and differs from $InstallRoot`: a launcher started with it uses that root instead.")
}

function Get-TcTwinCatInstall {
    # TwinCAT 3 install folder: TWINCAT3DIR (e.g. C:\Program Files (x86)\Beckhoff\TwinCAT\3.1\), else
    # registry HKLM\SOFTWARE\[WOW6432Node\]Beckhoff\TwinCAT3 TwinCATDir (e.g. ...\Beckhoff\TwinCAT\).
    # Measured 2026-11-07 (Windows 11, TwinCAT 3.1 XAE 4024 + 4026 on one PC): both set as in these
    # examples; no InfoSys page found that documents them (same lookup as New-TcProject's template search).
    if ($env:TWINCAT3DIR -and (Test-Path -LiteralPath $env:TWINCAT3DIR -PathType Container)) {
        return [ordered]@{ found = $true; dir = $env:TWINCAT3DIR; source = 'TWINCAT3DIR' }
    }
    foreach ($key in 'HKLM:\SOFTWARE\WOW6432Node\Beckhoff\TwinCAT3', 'HKLM:\SOFTWARE\Beckhoff\TwinCAT3') {
        try {
            $dir = (Get-ItemProperty -LiteralPath $key -Name TwinCATDir -ErrorAction Stop).TwinCATDir
            if ($dir -and (Test-Path -LiteralPath $dir -PathType Container)) { return [ordered]@{ found = $true; dir = [string]$dir; source = "$key\TwinCATDir" } }
        }
        catch { }
    }
    return [ordered]@{ found = $false; dir = $null; source = $null }
}

function Invoke-ClientConfig {
    # one client: set / remove through lib\tcauto-client-config.mjs; returns the result row
    param([Parameter(Mandatory)][string]$Node, [Parameter(Mandatory)]$Target, [Parameter(Mandatory)][string]$Action)
    $Name = $Target.name
    $file = $Target.file
    $label = if ($Target.variant) { "$Name ($($Target.variant))" } else { $Name }
    $row = [ordered]@{ client = $Name; variant = $Target.variant; file = $file; action = $null; previous = $null; backup = $null; reason = $null; keptKeys = @(); removedKeys = @(); warnings = @() }
    if ($Name -eq 'ClaudeCode') {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            $row.action = 'skipped'; $row.reason = "$file not found (Claude Code not used by this Windows user yet; start it once, then run this script again)"
            return $row
        }
    }
    elseif (-not (Test-Path -LiteralPath (Split-Path -Parent $file) -PathType Container)) {
        $row.action = 'skipped'; $row.reason = "$(Split-Path -Parent $file) not found ($Name not installed for this Windows user)"
        return $row
    }
    $a = @($clientConfigScript, $Action, '--client', $clientIds[$Name], '--file', $file, '--stamp', $backupStamp)
    if ($Action -eq 'set') { $a += @('--command', $installedNode, '--arg', $launcherPath) }
    else {
        $a += @('--owned-root', $InstallRoot)
        if ($Force) { $a += '--force' }
    }
    $oldEnc = $null
    try { $oldEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { $oldEnc = $null }
    try { $r = Invoke-Native -File $Node -Arguments $a }
    finally { if ($null -ne $oldEnc) { try { [Console]::OutputEncoding = $oldEnc } catch { } } }
    $line = @($r.Lines | Where-Object { "$_".StartsWith('{') }) | Select-Object -Last 1
    $res = $null
    if ($line) { try { $res = $line | ConvertFrom-Json -ErrorAction Stop } catch { $res = $null } }
    if ($null -eq $res) {
        $row.action = 'failed'; $row.reason = "client config helper gave no result (exit $($r.Code)): $(@($r.Lines) -join ' | ')"
    }
    elseif (-not $res.success) {
        $row.action = 'failed'; $row.reason = "$($res.error.code): $($res.error.message)"
    }
    else {
        $row.action = [string]$res.data.action; $row.previous = $res.data.previous; $row.backup = $res.data.backup
        # #204: user keys kept under tcauto, keys removed (env TCAUTO_RUNTIME_ROOT), kept keys that change how tcauto starts
        foreach ($k in @('keptKeys', 'removedKeys', 'warnings')) {
            if ($null -ne $res.data.$k) { $row[$k] = @($res.data.$k | ForEach-Object { [string]$_ }) }
        }
        if ($row.action -eq 'foreign') { $row.reason = "tcauto points outside $InstallRoot; left as it is" }
        if ($row.action -eq 'shared') { $row.reason = "tcauto runs another command but uses files below $InstallRoot (args); left as it is" }
    }
    $color = if ($row.action -eq 'failed') { 'Red' } elseif ($row.action -in @('skipped', 'foreign', 'shared')) { 'Yellow' } else { 'Gray' }
    Write-Host "  $label`: $($row.action)$(if ($row.reason) { " - $($row.reason)" })" -ForegroundColor $color
    if ($row.backup) { Write-Host "    backup: $($row.backup)" }
    if (@($row.removedKeys).Count) { Write-Host "    removed: $(@($row.removedKeys) -join ', ')" }
    foreach ($w in @($row.warnings)) { Write-Host "    warning: $w" -ForegroundColor Yellow }
    return $row
}

function Write-LineBytes {
    param($Stream, [string]$Text)
    $bytes = $script:TcUtf8NoBom.GetBytes($Text + "`n")
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
}

function Invoke-TcVerify {
    # node.exe + launcher as a client starts them (no PATH lookup, no TCAUTO_RUNTIME_ROOT):
    # initialize -> notifications/initialized -> tools/list. Returns @{ Ok; Data; Message }.
    $data = [ordered]@{ node = $installedNode; launcher = $launcherPath; toolCount = $null; hasReloadRuntime = $null; serverInfo = $null; runtime = $null; durationMs = $null }
    foreach ($f in @($installedNode, $launcherPath)) {
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return @{ Ok = $false; Data = $data; Message = "$f not found: TcAuto is not installed in $InstallRoot" } }
    }
    $cur = Read-JsonFile (Join-Path $runtimeFolder 'current.json')
    if ($null -ne $cur) { $data.runtime = [ordered]@{ version = $cur.version; commit = $cur.commit; release = $cur.release; dirty = $cur.dirty } }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $installedNode
    $psi.Arguments = '"' + $launcherPath + '"'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $InstallRoot
    $psi.StandardOutputEncoding = $script:TcUtf8NoBom
    $psi.StandardErrorEncoding = $script:TcUtf8NoBom
    if ($psi.EnvironmentVariables.ContainsKey('TCAUTO_RUNTIME_ROOT')) { $psi.EnvironmentVariables.Remove('TCAUTO_RUNTIME_ROOT') }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $deadline = [DateTime]::UtcNow.AddSeconds($VerifyTimeoutSec)
    $proc = $null
    $errTask = $null
    $tree = $null
    $startedAt = [DateTime]::Now.AddSeconds(-1)
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $errTask = $proc.StandardError.ReadToEndAsync()
        $in = $proc.StandardInput.BaseStream
        # .NET Framework writes the preamble of Console.InputEncoding (a UTF-8 BOM under code page
        # 65001) when Process.Start sets AutoFlush on StandardInput; an empty first line ends that
        # BOM as a line of its own, which the launcher skips (String.trim removes U+FEFF)
        Write-LineBytes $in ''
        $replies = @{}
        $readUntil = {
            param([int]$Id)
            while (-not $replies.ContainsKey($Id)) {
                $left = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
                if ($left -le 0) { throw "no answer to request $Id within $VerifyTimeoutSec s" }
                $t = $proc.StandardOutput.ReadLineAsync()
                if (-not $t.Wait($left)) { throw "no answer to request $Id within $VerifyTimeoutSec s" }
                $line = $t.Result
                if ($null -eq $line) { throw "the launcher exited (code $(if ($proc.HasExited) { $proc.ExitCode } else { '?' })) before it answered request $Id" }
                if (-not $line.Trim().StartsWith('{')) { continue }
                $msg = $line | ConvertFrom-Json
                if ($null -ne $msg.id) { $replies[[int]$msg.id] = $msg }
            }
            return $replies[$Id]
        }
        Write-LineBytes $in '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"tcauto-install-verify","version":"1"}}}'
        $init = & $readUntil 1
        if ($null -ne $init.error) { throw "initialize failed: $($init.error.message)" }
        $data.serverInfo = $init.result.serverInfo
        Write-LineBytes $in '{"jsonrpc":"2.0","method":"notifications/initialized"}'
        Write-LineBytes $in '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
        $list = & $readUntil 2
        if ($null -ne $list.error) { throw "tools/list failed: $($list.error.message)" }
        $names = @($list.result.tools | ForEach-Object { [string]$_.name })
        $data.toolCount = $names.Count
        $data.hasReloadRuntime = $names -contains 'ReloadRuntime'
        $data.durationMs = $sw.ElapsedMilliseconds
        if ($names.Count -eq 0) { return @{ Ok = $false; Data = $data; Message = 'tools/list returned no tools' } }
        if (-not $data.hasReloadRuntime) { return @{ Ok = $false; Data = $data; Message = 'tools/list has no ReloadRuntime: the server that answered is not the launcher' } }
        return @{ Ok = $true; Data = $data; Message = $null }
    }
    catch {
        $data.durationMs = $sw.ElapsedMilliseconds
        $msg = $_.Exception.Message
        if ($null -ne $proc -and $null -eq $tree) { $tree = Get-TcProcessTree -RootId $proc.Id -NotBefore $startedAt }
        if ($null -ne $proc -and $null -ne $errTask) {
            try { $proc.StandardInput.Close() } catch { }
            if ($errTask.Wait(3000)) { $tail = @(($errTask.Result -split "`r?`n") | Where-Object { $_ } | Select-Object -Last 6) -join ' | '; if ($tail) { $msg += " (stderr: $tail)" } }
        }
        return @{ Ok = $false; Data = $data; Message = $msg }
    }
    finally {
        if ($null -ne $proc) {
            # the launcher's children (the runtime node.exe, ...), listed while the launcher still runs
            if ($null -eq $tree) { $tree = Get-TcProcessTree -RootId $proc.Id -NotBefore $startedAt }
            try { $proc.StandardInput.Close() } catch { }
            if (-not $proc.WaitForExit(15000)) {
                # only this check's own launcher and its runtime child
                $null = Invoke-Native -File 'taskkill.exe' -Arguments @('/PID', "$($proc.Id)", '/T', '/F')
                $null = $proc.WaitForExit(5000)
            }
            $proc.Dispose()
            # the whole tree has exited before -Verify returns: a -Uninstall right after it finds no
            # node.exe of this check still holding node\ or runtime\ (#208)
            $null = Wait-TcProcessesExit -Processes @($tree) -TimeoutMs 10000
        }
    }
}

$twincat = Get-TcTwinCatInstall

# ================================================================== -Verify
if ($Verify) {
    Write-Host "TcAuto verify: $InstallRoot"
    $v = Invoke-TcVerify
    if (-not $v.Ok) {
        Stop-Install -Code 'VERIFY_FAILED' -Message $v.Message -Hint 'Run Install-TcAuto.ps1 (without -Verify) from the release zip again; the launcher stderr is in the message.' -Data ([ordered]@{ installRoot = $InstallRoot; verify = $v.Data })
    }
    Write-Host "[OK] $($v.Data.toolCount) tools, runtime $($v.Data.runtime.version) ($($v.Data.runtime.commit))" -ForegroundColor Green
    Write-InstallResult @{ success = $true; data = [ordered]@{ installRoot = $InstallRoot; mode = 'verify'; twincat = $twincat; verify = $v.Data; warnings = @($script:TcInstallWarnings) } }
    exit 0
}

# ================================================================== -Uninstall
if ($Uninstall) {
    Write-Host "TcAuto uninstall: $InstallRoot"
    $packageNode = Join-Path $PackageRoot 'node\node.exe'
    $helperNode = if (Test-Path -LiteralPath $packageNode -PathType Leaf) { $packageNode } elseif (Test-Path -LiteralPath $installedNode -PathType Leaf) { $installedNode } else { $null }
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($t in $configTargets) {
        if ($null -eq $helperNode) { $rows.Add([ordered]@{ client = $t.name; variant = $t.variant; file = $t.file; action = 'failed'; previous = $null; backup = $null; reason = 'no node.exe (neither in the release folder nor installed) to run the client config helper'; keptKeys = @(); removedKeys = @(); warnings = @() }); continue }
        $rows.Add((Invoke-ClientConfig -Node $helperNode -Target $t -Action 'remove'))
    }
    $folders = [System.Collections.Generic.List[object]]::new()
    $shared = @($rows | Where-Object { $_.action -eq 'shared' })
    if ($shared.Count -gt 0) {
        # a registration still starts files of this install: removing them would break that client
        $data = [ordered]@{ installRoot = $InstallRoot; mode = 'uninstall'; clients = @($rows); folders = @(); installRootRemoved = $false; warnings = @($script:TcInstallWarnings) }
        Stop-Install -Code 'INSTALL_SHARED' -Message "$($shared.Count) client registration(s) still use files below $InstallRoot through their args: $(@($shared | ForEach-Object { "$($_.client) ($($_.file))" }) -join '; '); no installed file was removed." `
            -Hint 'Change or remove that tcauto registration first (e.g. claude mcp remove tcauto -s user), then run Install-TcAuto.ps1 -Uninstall again; or run it with -Uninstall -Force to remove that registration and the files too.' -Data $data
    }
    foreach ($f in @($runtimeFolder, $launcherFolder, $nodeFolder)) { $folders.Add((Remove-TcInstallFolder -Path $f)) }
    $rootRemoved = $false
    if ((Test-Path -LiteralPath $InstallRoot) -and @(Get-ChildItem -LiteralPath $InstallRoot -Force).Count -eq 0) {
        try { Remove-Item -LiteralPath $InstallRoot -Force -ErrorAction Stop; $rootRemoved = $true } catch { }
    }
    $data = [ordered]@{ installRoot = $InstallRoot; mode = 'uninstall'; clients = @($rows); folders = @($folders); installRootRemoved = $rootRemoved; warnings = @($script:TcInstallWarnings) }
    $failedClients = @($rows | Where-Object { $_.action -eq 'failed' })
    $busy = @($folders | Where-Object { $_.action -eq 'in-use' })
    if ($failedClients.Count -gt 0) { Stop-Install -Code 'CLIENT_CONFIG_FAILED' -Message "$($failedClients.Count) client config(s) could not be changed: $(@($failedClients | ForEach-Object { "$($_.client): $($_.reason)" }) -join '; ')" -Hint 'Fix or close the named config file, then run Install-TcAuto.ps1 -Uninstall again.' -Data $data }
    if ($busy.Count -gt 0) { Stop-Install -Code 'INSTALL_IN_USE' -Message "$($busy.Count) folder(s) are in use: $(@($busy | ForEach-Object { $_.path }) -join ', ')" -Hint 'Close Claude Code, Claude Desktop and Codex (they run the launcher), then run Install-TcAuto.ps1 -Uninstall again.' -Data $data }
    Write-Host '[OK] TcAuto removed; restart the MCP clients.' -ForegroundColor Green
    Write-InstallResult @{ success = $true; data = $data }
    exit 0
}

# ================================================================== install
$manifest = Read-JsonFile (Join-Path $PackageRoot 'tcauto-release.json')
$pkgNode = Join-Path $PackageRoot 'node\node.exe'
$pkgLauncher = Join-Path $PackageRoot 'launcher\tcauto-launcher.mjs'
$pkgRuntimes = @()
if (Test-Path -LiteralPath (Join-Path $PackageRoot 'runtime') -PathType Container) {
    $pkgRuntimes = @(Get-ChildItem -LiteralPath (Join-Path $PackageRoot 'runtime') -Directory | Where-Object { $_.Name -match $script:TcRuntimeVersionPattern })
}
$missing = @(@((Join-Path $PackageRoot 'tcauto-release.json'), $pkgNode, $pkgLauncher, $clientConfigScript) | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
if ($null -eq $manifest -or $missing.Count -gt 0 -or $pkgRuntimes.Count -ne 1) {
    Stop-Install -Code 'PACKAGE_INCOMPLETE' -Message "$PackageRoot is not a complete TcAuto release folder (missing: $(@($missing) -join ', '); runtime folders: $($pkgRuntimes.Count))." `
        -Hint 'Extract the whole TcAuto-<version>.zip and run Install-TcAuto.ps1 from that folder. In a checkout use scripts\Install-TcAutoRuntime.ps1, or build a zip with scripts\Build-TcAutoRelease.ps1.'
}
$pkgRuntime = $pkgRuntimes[0]
$version = $pkgRuntime.Name
$pkgStamp = Read-JsonFile (Join-Path $pkgRuntime.FullName 'tcauto-source.json')
if ($null -eq $pkgStamp -or "$($pkgStamp.commit)" -notmatch '^[0-9a-f]{40,64}$' -or "$($pkgStamp.version)" -ne $version) {
    Stop-Install -Code 'PACKAGE_INCOMPLETE' -Message "$($pkgRuntime.FullName)\tcauto-source.json is missing or does not name version $version." -Hint 'Download the release zip again and check its SHA256.'
}
$commit = [string]$pkgStamp.commit

Write-Host "TcAuto install (#20): release $($manifest.version) (runtime $version)"
Write-Host "  from:    $PackageRoot"
Write-Host "  to:      $InstallRoot"
if ($twincat.found) { Write-Host "  TwinCAT: $($twincat.dir) ($($twincat.source))" }
else {
    $script:TcInstallWarnings.Add('TwinCAT 3 not found (no TWINCAT3DIR, no registry TwinCATDir): the server installs, but ConnectIde needs TwinCAT 3 XAE on this PC.')
    Write-Host '  TwinCAT: not found (TWINCAT3DIR / registry TwinCATDir); installing anyway, ConnectIde needs TwinCAT 3 XAE' -ForegroundColor Yellow
}

$null = New-Item -ItemType Directory -Force -Path $runtimeFolder

# ------------------------------------------------------------------ node.exe (only when it differs)
$null = New-Item -ItemType Directory -Force -Path $nodeFolder
Get-ChildItem -LiteralPath $nodeFolder -Filter 'node.exe.old-*' -Force -ErrorAction SilentlyContinue | ForEach-Object { try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop } catch { } }
$nodeUpdated = $false
if ((Get-FileSha256 $pkgNode) -ne (Get-FileSha256 $installedNode)) {
    # 1. copy next to it, 2. move the old one aside (a running node.exe cannot be overwritten or
    # deleted, but it can be renamed), 3. move the copy in. A failure puts the old one back.
    $tmpNode = Join-Path $nodeFolder ('.node.exe.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try { [System.IO.File]::Copy($pkgNode, $tmpNode, $true) }
    catch {
        try { [System.IO.File]::Delete($tmpNode) } catch { }
        Stop-Install -Code 'COPY_FAILED' -Message "cannot copy node.exe into $nodeFolder`: $($_.Exception.Message)" -Hint 'Check the free disk space and that the folder is writable, then run Install-TcAuto.ps1 again.'
    }
    $aside = $null
    if (Test-Path -LiteralPath $installedNode) {
        $aside = Join-Path $nodeFolder ('node.exe.old-' + [guid]::NewGuid().ToString('N'))
        try { [System.IO.File]::Move($installedNode, $aside) }
        catch {
            try { [System.IO.File]::Delete($tmpNode) } catch { }
            Stop-Install -Code 'NODE_IN_USE' -Message "cannot replace $installedNode`: $($_.Exception.Message); the old node.exe is unchanged." -Hint 'Close Claude Code, Claude Desktop and Codex, then run Install-TcAuto.ps1 again.'
        }
    }
    try { [System.IO.File]::Move($tmpNode, $installedNode) }
    catch {
        $why = $_.Exception.Message
        $restored = $true
        if ($null -ne $aside) { try { [System.IO.File]::Move($aside, $installedNode) } catch { $restored = $false } }
        try { [System.IO.File]::Delete($tmpNode) } catch { }
        Stop-Install -Code 'COPY_FAILED' -Message "cannot move the new node.exe to $installedNode`: $why; $(if ($null -eq $aside) { 'there was no node.exe before' } elseif ($restored) { 'the old node.exe was put back' } else { "the old node.exe is still at $aside" })." `
            -Hint 'Close Claude Code, Claude Desktop and Codex, then run Install-TcAuto.ps1 again.'
    }
    if ($null -ne $aside) { try { Remove-Item -LiteralPath $aside -Force -ErrorAction Stop } catch { } }
    $nodeUpdated = $true
}
foreach ($extra in @(Get-ChildItem -LiteralPath (Join-Path $PackageRoot 'node') -File | Where-Object { $_.Name -ne 'node.exe' })) {
    try { [System.IO.File]::Copy($extra.FullName, (Join-Path $nodeFolder $extra.Name), $true) } catch { $script:TcInstallWarnings.Add("node\$($extra.Name) not copied: $($_.Exception.Message)") }
}
Write-Host "  node.exe $(if ($nodeUpdated) { 'installed' } else { 'unchanged' }): $installedNode"

# ------------------------------------------------------------------ runtime, current.json, launcher, retention
$currentVersion = Get-TcCurrentVersion -RuntimeFolder $runtimeFolder
$fill = { param($staging) Write-Host '  copying the runtime ...'; $n = Copy-TcTree -Source $pkgRuntime.FullName -Destination $staging; Write-Host "  $n files copied" }
$installed = Install-TcRuntimeVersion -RuntimeFolder $runtimeFolder -Version $version -Commit $commit -CurrentVersion $currentVersion -Fill $fill
if (-not (Test-TcRuntimeComplete -Path $installed.Target -Commit $commit)) {
    Stop-Install -Code 'RUNTIME_DAMAGED' -Message "$($installed.Target) is incomplete after the copy (no node_modules or index.js)." -Hint 'Download the release zip again, check its SHA256 and run Install-TcAuto.ps1 again.'
}
$currentJson = Set-TcCurrentRuntime -RuntimeFolder $runtimeFolder -Version $version
$launcher = Update-TcLauncher -Source $pkgLauncher -LauncherFolder $launcherFolder
$prune = Remove-TcOldRuntimes -RuntimeFolder $runtimeFolder -Keep $Keep -Version $version

# ------------------------------------------------------------------ clients
Write-Host '  MCP clients:'
$rows = [System.Collections.Generic.List[object]]::new()
foreach ($t in $configTargets) { $rows.Add((Invoke-ClientConfig -Node $installedNode -Target $t -Action 'set')) }

$data = [ordered]@{
    installRoot     = $InstallRoot
    mode            = 'install'
    release         = $manifest.version
    version         = $version
    commit          = $commit
    dirty           = $pkgStamp.dirty
    runtimeDir      = $installed.Target
    reused          = $installed.Reused
    previousCurrent = $currentVersion
    currentJson     = $currentJson
    node            = [ordered]@{ path = $installedNode; version = $manifest.node.version; updated = $nodeUpdated }
    launcherPath    = $launcher.Path
    launcherUpdated = $launcher.Updated
    registration    = [ordered]@{ command = $installedNode; args = @($launcherPath) }
    clients         = @($rows)
    pruned          = @($prune.Pruned)
    pruneSkipped    = @($prune.Skipped)
    twincat         = $twincat
    verify          = $null
    warnings        = $null
}

# ------------------------------------------------------------------ verify
if (-not $NoVerify) {
    Write-Host '  verify (initialize + tools/list) ...'
    $v = Invoke-TcVerify
    $data.verify = $v.Data
    if (-not $v.Ok) {
        $data.warnings = @($script:TcInstallWarnings)
        Stop-Install -Code 'VERIFY_FAILED' -Message "installed, but the check failed: $($v.Message)" -Hint 'Run Install-TcAuto.ps1 -Verify again; if it still fails, report the message (it holds the launcher stderr).' -Data $data
    }
    Write-Host "  verify: $($v.Data.toolCount) tools" -ForegroundColor Green
}

$data.warnings = @($script:TcInstallWarnings)
$failedClients = @($rows | Where-Object { $_.action -eq 'failed' })
if ($failedClients.Count -gt 0) {
    Stop-Install -Code 'CLIENT_CONFIG_FAILED' -Message "installed, but $($failedClients.Count) client config(s) could not be changed: $(@($failedClients | ForEach-Object { "$($_.client): $($_.reason)" }) -join '; ')" `
        -Hint 'Fix the named config file (it was not changed), then run Install-TcAuto.ps1 again.' -Data $data
}
Write-Host ''
Write-Host "[OK] TcAuto $($manifest.version) installed. Restart Claude Code / Claude Desktop / Codex once." -ForegroundColor Green
Write-Host '  Next versions: install the new zip the same way, then call the MCP tool ReloadRuntime.'
Write-InstallResult @{ success = $true; data = $data }
exit 0
