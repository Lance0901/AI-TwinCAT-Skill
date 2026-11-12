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

        Check at the deadline (#114, CrashDetectedBy = 'deadline'). Measured 2026-11-04 (4026
        VS2022, local UmRT, TcSystemServiceUm.exe 3.1.0.2649): the process vanished 46 s into a
        60 s wait, the last error was ADS 0x7, and the result was SYSTEM_STATE_TIMEOUT. WHY the
        early check above did not fire is NOT confirmed (no per-probe record of that run). Possible
        causes in this code: (a) the streak counts from the first 0x7 PROBE and restarts on any
        other result, so it can still be shorter than -CrashUnreachableSec at the deadline;
        (b) a failure that ConvertTo-TcAdsErrorCode does not map to ADS_TARGET_NOT_FOUND never
        starts the streak; (c) Test-TcProcessAlive still finds a start pid. So when the wait
        times out with the LAST probe failed (any error), RuntimeCrashed is set when
        Get-TcLocalUmRtProcess can read the process list (ProcessListReadable) and finds no
        TcSystemServiceUm process of that runtime at all (not a restart under a new pid); the
        start-pid check (c) is not required there, its result is reported in DeadlineCheck.
        ProbeErrors (#114 S1, diagnosis): failed probes as RUNS - consecutive failures with the same
        code, adsCode, hresult and pidAlive are one entry { fromMs, toMs (since the wait started),
        count, code (mapped module code, $null = not mapped), adsCode (first ErrorCode in the
        exception chain), hresult and message (of the INNERMOST exception, not the localized
        "Exception calling ..." wrapper; message cut to 160 chars, from the first probe of the run),
        pidAlive (any start pid alive per Test-TcProcessAlive; $null without crash detection) }.
        At most 50 runs: the first 10 and the last 40; runs removed in between are counted in
        ProbeErrorsDropped (so a long 0x502 / unreachable phase stays a few hundred bytes).
        AnyProbeFailed: at least one probe failed during the wait.
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
        StatesSeen = [string[]]; AnyProbeFailed = [bool]; ProbeErrors = [object[]];
        ProbeErrorsDropped = [int]; DeadlineCheck = $null | @{ startPidsAlive; pidsNow;
        processListReadable; lastProbeCode } }
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

    # #241: $script:TcAdsWaitTimeScale (1.0 = real seconds; only unit tests lower it) scales the
    # deadline, the poll interval and the 0x7 window together, so a test sees the same sequence of
    # probes in less wall-clock time. Elapsed / unreachable times are still reported in real ms.
    $timeScale = Get-TcTimeScale -Value $script:TcAdsWaitTimeScale
    $timeoutEff = $TimeoutSec * $timeScale
    $crashWindowEff = $CrashUnreachableSec * $timeScale
    $intervalEff = if ($timeScale -eq 1.0) { $IntervalMs } else { [int][Math]::Max(1, [Math]::Round($IntervalMs * $timeScale)) }

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
    $probeErrors = [System.Collections.Generic.List[object]]::new()
    $probeCap = 50          # runs kept: the first $probeKeepFirst and the last ($probeCap - $probeKeepFirst)
    $probeKeepFirst = 10
    $probeDropped = 0
    $anyFailed = $false
    $lastCode = $null
    $deadlineCheck = $null

    $loaded = Find-TcAdsAssembly
    if (-not $loaded) {
        return @{
            Reached            = $false
            State              = $null
            ElapsedMs          = 0
            LastError          = 'TwinCAT.Ads.dll not found.'
            RuntimeCrashed     = $false
            CrashDetectedBy    = $null
            RuntimeName        = $null
            ServicePidAtStart  = [int[]]@()
            UnreachableMs      = 0
            StatesSeen         = [string[]]@()
            AnyProbeFailed     = $false
            ProbeErrors        = [object[]]@()
            ProbeErrorsDropped = 0
            DeadlineCheck      = $null
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
                $err = $_
                $lastError = $err.Exception.Message
                $anyFailed = $true
                if ($null -ne $client) {
                    try { $client.Dispose() } catch { }
                    $client = $null
                }
                $mapped = ConvertTo-TcAdsErrorCode -InputObject $err
                $lastCode = if ($null -ne $mapped) { [string]$mapped.Code } else { $null }
                # #114 S1: bounded probe log (diagnosis of a missed crash verdict)
                $adsCode = $null; $hres = $null
                $ex = $err.Exception
                $inner = $ex
                while ($null -ne $ex) {
                    $ep = $ex.PSObject.Properties['ErrorCode']
                    if ($null -eq $adsCode -and $null -ne $ep -and $null -ne $ep.Value) { try { $adsCode = '0x{0:X}' -f [int]$ep.Value } catch { } }
                    $inner = $ex
                    $ex = $ex.InnerException
                }
                # R2-S2: HResult / message of the innermost exception (the outer one is PowerShell's
                # MethodInvocationException with a localized prefix and its own HResult)
                try { $hres = '0x{0:X8}' -f [int]$inner.HResult } catch { }   # X8 of an Int32 = its 32-bit pattern
                $pidAlive = $null
                if ($null -ne $umrt) { $pidAlive = (@($umrt.Pids | Where-Object { Test-TcProcessAlive -Id $_ }).Count -gt 0) }
                $nowMs = [int]$stopwatch.ElapsedMilliseconds
                $lastRun = if ($probeErrors.Count -gt 0) { $probeErrors[$probeErrors.Count - 1] } else { $null }
                if ($null -ne $lastRun -and $lastRun.code -eq $lastCode -and $lastRun.adsCode -eq $adsCode -and $lastRun.hresult -eq $hres -and $lastRun.pidAlive -eq $pidAlive) {
                    $lastRun.toMs = $nowMs; $lastRun.count++
                }
                else {
                    $msgShort = [string]$inner.Message
                    if ($msgShort.Length -gt 160) { $msgShort = $msgShort.Substring(0, 160) }
                    if ($probeErrors.Count -ge $probeCap) { $probeErrors.RemoveAt($probeKeepFirst); $probeDropped++ }
                    $probeErrors.Add([PSCustomObject]@{ fromMs = $nowMs; toMs = $nowMs; count = 1; code = $lastCode; adsCode = $adsCode; hresult = $hres; pidAlive = $pidAlive; message = $msgShort })
                }
                if ($null -ne $umrt) {
                    if ($null -ne $mapped -and $mapped.Code -eq 'ADS_TARGET_NOT_FOUND') {
                        if ($null -eq $unreachSince) { $unreachSince = $stopwatch.Elapsed.TotalSeconds }
                    }
                    else { $unreachSince = $null }
                    if ($null -ne $unreachSince -and ($stopwatch.Elapsed.TotalSeconds - $unreachSince) -ge $crashWindowEff) {
                        if (-not $pidAlive) { $crashed = $true; $crashBy = 'streak'; break }
                    }
                }
            }

            if ($stopwatch.Elapsed.TotalSeconds -ge $timeoutEff) { break }
            Start-Sleep -Milliseconds $intervalEff
        }
        # #114: timed out with the last probe failed (any error, causes (a)-(c) in .DESCRIPTION):
        # the runtime counts as gone when the process list is readable and no TcSystemServiceUm of
        # that runtime runs now (a restart under a new pid is not a crash).
        if (-not $reached -and -not $crashed -and $null -ne $umrt -and $null -ne $lastError) {
            $alive = @($umrt.Pids | Where-Object { Test-TcProcessAlive -Id $_ })
            $now = Get-TcLocalUmRtProcess -AmsNetId $AmsNetId
            # S7: an unreadable process list (empty Pids) is no evidence that the runtime is gone
            $readable = ($null -ne $now) -and -not ($null -ne $now.PSObject.Properties['ProcessListReadable'] -and $now.ProcessListReadable -eq $false)
            $deadlineCheck = [PSCustomObject]@{
                startPidsAlive      = [int[]]$alive
                pidsNow             = $(if ($null -ne $now) { [int[]]@($now.Pids) } else { $null })
                processListReadable = $readable
                lastProbeCode       = $lastCode
            }
            if ($readable -and @($now.Pids).Count -eq 0) { $crashed = $true; $crashBy = 'deadline' }
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
        AnyProbeFailed    = $anyFailed
        ProbeErrors       = [object[]]$probeErrors.ToArray()
        ProbeErrorsDropped = $probeDropped
        DeadlineCheck     = $deadlineCheck
    }
}
