function Wait-TcAdsState {
    <#
    .SYNOPSIS
        Polls an ADS port until it is reachable and (optionally) in a target state.
    .DESCRIPTION
        Creates a temporary TcAdsClient and calls ReadState() every -IntervalMs until
        the condition is met or -TimeoutSec elapses. On every failed probe the temporary
        client is disposed and recreated on the next iteration (after a TwinCAT restart
        a stale connection may keep failing). The client is always disposed on exit.
        Does not touch the module ADS session ($script:TcAdsClient).

        -DetectRuntimeCrash (RUNTIME_CRASHED, task 1.8): when the target is the Usermode Runtime
        (UmRT) on THIS PC and its TcSystemServiceUm.exe was running when the wait started
        (Get-TcLocalUmRtProcess: target NetId = AmsNetId in the local
        Runtimes\<name>\3.1\TcRegistry.xml, process matched by its -n "<name>" command line), the
        wait ends early with RuntimeCrashed = $true once BOTH hold:
          - every probe for at least -CrashUnreachableSec (default 10) failed with ADS 0x7
            (ADS_TARGET_NOT_FOUND, "target machine not found"; any other result restarts the count)
          - none of the TcSystemServiceUm.exe pids seen at the start exists any more
        Measured 2026-10-29 (4026 VS2022, local UmRT, phase0-1.7 finding 2): the UmRT process
        crashed ~40 s into set-config, every later probe answered ADS 0x7, and the old code
        waited the full 300 s for SYSTEM_STATE_TIMEOUT. A remote target, the local XAR, or a
        UmRT that was not running at the start keep the old behaviour (wait until -TimeoutSec).
    .PARAMETER AmsNetId
        Target AMS Net ID.
    .PARAMETER Port
        ADS port to probe (851 = PLC runtime, 10000 = TwinCAT system service).
    .PARAMETER TargetState
        Run, Config, Stop, or Any. 'Any' succeeds as soon as ReadState() does not throw.
    .PARAMETER TimeoutSec
        Maximum wait. Default 60.
    .PARAMETER IntervalMs
        Poll interval. Default 500.
    .PARAMETER DetectRuntimeCrash
        End the wait early when the local UmRT process disappeared (see .DESCRIPTION).
    .PARAMETER CrashUnreachableSec
        How long ADS 0x7 must last before a vanished UmRT counts as crashed. Default 10.
    .OUTPUTS
        Hashtable: @{ Reached = [bool]; State = [string]; ElapsedMs = [int]; LastError = [string];
        RuntimeCrashed = [bool]; RuntimeName = [string]; ServicePidAtStart = [int[]];
        UnreachableMs = [int] }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$AmsNetId,

        [Parameter(Mandatory)]
        [int]$Port,

        [Parameter()]
        [ValidateSet('Run', 'Config', 'Stop', 'Any')]
        [string]$TargetState = 'Any',

        [Parameter()]
        [int]$TimeoutSec = 60,

        [Parameter()]
        [int]$IntervalMs = 500,

        [Parameter()]
        [switch]$DetectRuntimeCrash,

        [Parameter()]
        [ValidateRange(1, 600)]
        [int]$CrashUnreachableSec = 10
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $reached = $false
    $lastState = $null
    $lastError = $null
    $client = $null
    $crashed = $false
    $unreachSince = $null   # stopwatch seconds of the first ADS 0x7 of the current streak
    $umrt = $null

    $loaded = Find-TcAdsAssembly
    if (-not $loaded) {
        return @{
            Reached           = $false
            State             = $null
            ElapsedMs         = 0
            LastError         = 'TwinCAT.Ads.dll not found.'
            RuntimeCrashed    = $false
            RuntimeName       = $null
            ServicePidAtStart = [int[]]@()
            UnreachableMs     = 0
        }
    }

    # Local UmRT with a running TcSystemServiceUm at the start, else no crash detection
    if ($DetectRuntimeCrash) {
        $umrt = Get-TcLocalUmRtProcess -AmsNetId $AmsNetId
        if ($null -ne $umrt -and @($umrt.Pids).Count -eq 0) { $umrt = $null }
    }

    try {
        while ($true) {
            try {
                if ($null -eq $client) {
                    $client = New-TcAdsClient -AmsNetId $AmsNetId -Port $Port
                }
                $info = $client.ReadState()
                $lastState = $info.AdsState.ToString()
                $lastError = $null
                $unreachSince = $null

                if ($TargetState -eq 'Any' -or $lastState -eq $TargetState) {
                    $reached = $true
                    break
                }
            }
            catch {
                $lastError = $_.Exception.Message
                if ($null -ne $client) {
                    try { $client.Dispose() } catch { }
                    $client = $null
                }
                if ($null -ne $umrt) {
                    $mapped = ConvertTo-TcAdsErrorCode -InputObject $_
                    if ($null -ne $mapped -and $mapped.Code -eq 'ADS_TARGET_NOT_FOUND') {
                        if ($null -eq $unreachSince) { $unreachSince = $stopwatch.Elapsed.TotalSeconds }
                    }
                    else { $unreachSince = $null }
                    if ($null -ne $unreachSince -and ($stopwatch.Elapsed.TotalSeconds - $unreachSince) -ge $CrashUnreachableSec) {
                        $alive = @($umrt.Pids | Where-Object { Test-TcProcessAlive -Id $_ })
                        if ($alive.Count -eq 0) { $crashed = $true; break }
                    }
                }
            }

            if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSec) { break }
            Start-Sleep -Milliseconds $IntervalMs
        }
    }
    finally {
        if ($null -ne $client) {
            try { $client.Dispose() } catch { }
        }
        $stopwatch.Stop()
    }

    $unreachMs = if ($null -ne $unreachSince) { [int](($stopwatch.Elapsed.TotalSeconds - $unreachSince) * 1000) } else { 0 }
    Write-Verbose "Wait-TcAdsState ${AmsNetId}:${Port} target=$TargetState reached=$reached state=$lastState crashed=$crashed elapsed=$([int]$stopwatch.ElapsedMilliseconds)ms"

    return @{
        Reached           = $reached
        State             = $lastState
        ElapsedMs         = [int]$stopwatch.ElapsedMilliseconds
        LastError         = $lastError
        RuntimeCrashed    = $crashed
        RuntimeName       = $(if ($null -ne $umrt) { [string]$umrt.RuntimeName } else { $null })
        ServicePidAtStart = $(if ($null -ne $umrt) { [int[]]@($umrt.Pids) } else { [int[]]@() })
        UnreachableMs     = $unreachMs
    }
}
