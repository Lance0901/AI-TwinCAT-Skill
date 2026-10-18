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
    .OUTPUTS
        Hashtable: @{ Reached = [bool]; State = [string]; ElapsedMs = [int]; LastError = [string] }
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
        [int]$IntervalMs = 500
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $reached = $false
    $lastState = $null
    $lastError = $null
    $client = $null

    $loaded = Find-TcAdsAssembly
    if (-not $loaded) {
        return @{
            Reached   = $false
            State     = $null
            ElapsedMs = 0
            LastError = 'TwinCAT.Ads.dll not found.'
        }
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

    Write-Verbose "Wait-TcAdsState ${AmsNetId}:${Port} target=$TargetState reached=$reached state=$lastState elapsed=$([int]$stopwatch.ElapsedMilliseconds)ms"

    return @{
        Reached   = $reached
        State     = $lastState
        ElapsedMs = [int]$stopwatch.ElapsedMilliseconds
        LastError = $lastError
    }
}
