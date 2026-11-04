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

        Check at the deadline (#114, CrashDetectedBy = 'deadline'): the 10 s streak above counts
        from the first 0x7 PROBE, not from the moment the process vanished, and restarts on any
        other result, so a crash late in the wait could reach -TimeoutSec with the streak still
        short and was reported as a timeout (measured 2026-11-04, 4026 VS2022, local UmRT: process
        gone 46 s into a 60 s wait, 0x7 until the deadline, SYSTEM_STATE_TIMEOUT). When the wait
        times out and the LAST probe answered 0x7, the pids seen at the start are gone AND
        Get-TcLocalUmRtProcess finds no TcSystemServiceUm process of that runtime at all (so not a
        restart under a new pid), RuntimeCrashed is set as well.
        StatesSeen: every state that ReadState() returned, in order, consecutive duplicates
        dropped; failed probes are not states (Set-TcSystemState data.leftOriginal).
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
        Hashtable: @{ Reached = [bool]; State = [string] (last state READ, a later failed probe
        keeps it); ElapsedMs = [int]; LastError = [string] ($null when the last probe succeeded);
        RuntimeCrashed = [bool]; CrashDetectedBy = 'streak' | 'deadline' | $null;
        RuntimeName = [string]; ServicePidAtStart = [int[]]; UnreachableMs = [int];
        StatesSeen = [string[]] }
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
    $crashBy = $null
    $unreachSince = $null   # stopwatch seconds of the first ADS 0x7 of the current streak
    $umrt = $null
    $seen = [System.Collections.Generic.List[string]]::new()

    $loaded = Find-TcAdsAssembly
    if (-not $loaded) {
        return @{
            Reached           = $false
            State             = $null
            ElapsedMs         = 0
            LastError         = 'TwinCAT.Ads.dll not found.'
            RuntimeCrashed    = $false
            CrashDetectedBy   = $null
            RuntimeName       = $null
            ServicePidAtStart = [int[]]@()
            UnreachableMs     = 0
            StatesSeen        = [string[]]@()
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
                if ($seen.Count -eq 0 -or $seen[$seen.Count - 1] -ne $lastState) { $seen.Add($lastState) }

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
                        if ($alive.Count -eq 0) { $crashed = $true; $crashBy = 'streak'; break }
                    }
                }
            }

            if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSec) { break }
            Start-Sleep -Milliseconds $IntervalMs
        }
        # #114: timed out while the last probe answered 0x7 (streak shorter than -CrashUnreachableSec):
        # the runtime counts as gone when the start pids no longer exist and no process of that
        # runtime runs now (a restart under a new pid is not a crash). See .DESCRIPTION.
        if (-not $reached -and -not $crashed -and $null -ne $umrt -and $null -ne $unreachSince) {
            $alive = @($umrt.Pids | Where-Object { Test-TcProcessAlive -Id $_ })
            $now = $null
            if ($alive.Count -eq 0) { $now = Get-TcLocalUmRtProcess -AmsNetId $AmsNetId }
            if ($alive.Count -eq 0 -and $null -ne $now -and @($now.Pids).Count -eq 0) { $crashed = $true; $crashBy = 'deadline' }
        }
    }
    finally {
        if ($null -ne $client) {
            try { $client.Dispose() } catch { }
        }
        $stopwatch.Stop()
    }

    $unreachMs = if ($null -ne $unreachSince) { [int](($stopwatch.Elapsed.TotalSeconds - $unreachSince) * 1000) } else { 0 }
    Write-Verbose "Wait-TcAdsState ${AmsNetId}:${Port} target=$TargetState reached=$reached state=$lastState crashed=$crashed ($crashBy) elapsed=$([int]$stopwatch.ElapsedMilliseconds)ms"

    return @{
        Reached           = $reached
        State             = $lastState
        ElapsedMs         = [int]$stopwatch.ElapsedMilliseconds
        LastError         = $lastError
        RuntimeCrashed    = $crashed
        CrashDetectedBy   = $crashBy
        StatesSeen        = [string[]]$seen.ToArray()
        RuntimeName       = $(if ($null -ne $umrt) { [string]$umrt.RuntimeName } else { $null })
        ServicePidAtStart = $(if ($null -ne $umrt) { [int[]]@($umrt.Pids) } else { [int[]]@() })
        UnreachableMs     = $unreachMs
    }
}
