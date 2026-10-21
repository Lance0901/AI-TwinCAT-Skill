<#
.SYNOPSIS
    Background watcher for the local UmRT during real-machine tests (issue #21 crash hunting).

.DESCRIPTION
    Every -IntervalMs it appends one JSON line to -LogPath:
        {"kind":"sample","time":"...","pid":1234|null,"adsState":5,"adsStateName":"Run"|"unreachable",
         "adsError":null|"...","bootdataBytes":12345|null}
      pid           TcSystemServiceUm process id (null when no such process)
      adsState      AdsState of port 10000 on -AmsNetId (null + adsStateName "unreachable" and
                    adsError when the read fails, TwinCAT.Ads.dll missing included)
      bootdataBytes size of <UmRT>\3.1\Boot\TCNC.bootdata (null when the file does not exist)
    An extra {"kind":"event",...} line is written when the pid changes (start, crash, restart)
    or TCNC.bootdata becomes 0 bytes. Never throws for a missing runtime; read-only (no
    WriteControl, no process is started or stopped).

    Run it in the background for the whole test, e.g.
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass',
            '-File','tests\Integration\Watch-Runtime.ps1','-LogPath','tests\Integration\logs\runtime-watch.jsonl'

.PARAMETER LogPath
    JSON lines output (appended). Default: logs/runtime-watch.jsonl next to this script.
.PARAMETER IntervalMs
    Sampling interval. Default 1000.
.PARAMETER DurationSec
    Stop after this many seconds; 0 (default) = run until the process is stopped.
.PARAMETER AmsNetId
    AmsNetId of the UmRT. Default 199.5.42.250.1.1 (local UmRT_Default).
.PARAMETER RuntimeDir
    UmRT directory. Default C:\ProgramData\Beckhoff\TwinCAT\3.1\Runtimes\UmRT_Default.
#>
[CmdletBinding()]
param(
    [string]$LogPath,
    [ValidateRange(100, 3600000)]
    [int]$IntervalMs = 1000,
    [ValidateRange(0, 2147483)]
    [int]$DurationSec = 0,
    [string]$AmsNetId = '199.5.42.250.1.1',
    [string]$RuntimeDir = 'C:\ProgramData\Beckhoff\TwinCAT\3.1\Runtimes\UmRT_Default'
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $PSCommandPath
if ([string]::IsNullOrWhiteSpace($LogPath)) { $LogPath = Join-Path $scriptDir 'logs\runtime-watch.jsonl' }
if (-not [System.IO.Path]::IsPathRooted($LogPath)) { $LogPath = Join-Path (Get-Location).ProviderPath $LogPath }
$logDir = Split-Path -Parent $LogPath
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$bootdataPath = Join-Path $RuntimeDir '3.1\Boot\TCNC.bootdata'
$utf8 = New-Object System.Text.UTF8Encoding($false)

$module = $null
try {
    $module = Import-Module (Join-Path $scriptDir '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -PassThru -DisableNameChecking
}
catch {
    $module = $null
}

function Write-WatchLine([hashtable]$Entry) {
    # Stable key order: kind, time, event, then the documented fields.
    $order = @('kind', 'time', 'event', 'pid', 'processCount', 'adsState', 'adsStateName', 'adsError', 'bootdataBytes', 'from', 'to', 'error')
    $o = [ordered]@{}
    foreach ($k in $order) { if ($Entry.ContainsKey($k)) { $o[$k] = $Entry[$k] } }
    foreach ($k in $Entry.Keys) { if (-not $o.Contains($k)) { $o[$k] = $Entry[$k] } }
    $json = ConvertTo-Json -InputObject ([pscustomobject]$o) -Compress -Depth 4
    [System.IO.File]::AppendAllText($LogPath, $json + "`r`n", $utf8)
}

function Read-SystemAdsState {
    if (-not $module) { return @{ state = $null; name = 'unreachable'; error = 'TwinCATAutomation module could not be imported' } }
    try {
        # New-TcAdsClient is private: call it inside the module scope.
        $client = & $module { param($id) New-TcAdsClient -AmsNetId $id -Port 10000 } $AmsNetId
        try {
            try { $client.Timeout = 1000 } catch { }
            $info = $client.ReadState()
            return @{ state = [int]$info.AdsState; name = $info.AdsState.ToString(); error = $null }
        }
        finally {
            try { $client.Dispose() } catch { }
        }
    }
    catch {
        return @{ state = $null; name = 'unreachable'; error = $_.Exception.Message }
    }
}

$deadline = if ($DurationSec -gt 0) { (Get-Date).AddSeconds($DurationSec) } else { [datetime]::MaxValue }
$lastPid = 'init'
$lastBytes = 'init'
while ((Get-Date) -lt $deadline) {
    $tick = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $now = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz')
        $proc = @(Get-Process -Name 'TcSystemServiceUm' -ErrorAction SilentlyContinue)
        $procId = if ($proc.Count -gt 0) { $proc[0].Id } else { $null }
        $bytes = $null
        if (Test-Path -LiteralPath $bootdataPath) { $bytes = (Get-Item -LiteralPath $bootdataPath).Length }
        $ads = Read-SystemAdsState

        Write-WatchLine @{
            kind = 'sample'; time = $now; pid = $procId; processCount = $proc.Count
            adsState = $ads.state; adsStateName = $ads.name; adsError = $ads.error
            bootdataBytes = $bytes
        }
        if ($lastPid -ne 'init' -and "$lastPid" -ne "$procId") {
            Write-WatchLine @{ kind = 'event'; time = $now; event = 'pid-changed'; from = $lastPid; to = $procId; adsStateName = $ads.name }
        }
        if ($bytes -eq 0 -and "$lastBytes" -ne '0') {
            Write-WatchLine @{ kind = 'event'; time = $now; event = 'bootdata-empty'; from = $(if ($lastBytes -eq 'init') { $null } else { $lastBytes }); to = 0 }
        }
        $lastPid = $procId
        $lastBytes = $bytes
    }
    catch {
        Write-WatchLine @{ kind = 'error'; time = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz'); error = $_.Exception.Message }
    }
    $wait = $IntervalMs - [int]$tick.ElapsedMilliseconds
    if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }
}
