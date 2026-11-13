# #287: port 10000 (TwinCAT system service) state as seen by Set-TcPlcState / Get-TcPlcState.
#
# AdsState 19 = Exception. Measured 2026-11-13 (XAE 4026.22 / VS2022, local UmRT): after a PLC exception
# (integer divide by zero 0xc0000094, FPU zero divide 0xc000008e, page fault 0xc0000005) port 851
# reads Stop and port 10000 reads AdsState 19 'Exception' and stays there; a PLC-level Run / Reset
# does not recover it (TwinCAT shuts itself down to Config about one second after WriteControl
# Run), only a new Activate (Enable-TcConfig -Force) does. Source:
# openspec/changes/add-semantic-linter/verification/runtime-semantics-measured.md section 7.
# The value is compared as an integer: an older TwinCAT.Ads.dll whose AdsState enum has no member
# 19 prints it as '19', so the name is taken from $script:TcAdsStateNames, not from ToString().
$script:TcAdsStateRun = 5
$script:TcAdsStateException = 19
$script:TcAdsStateNames = @{
    0 = 'Invalid'; 1 = 'Idle'; 2 = 'Reset'; 3 = 'Init'; 4 = 'Start'; 5 = 'Run'; 6 = 'Stop'
    7 = 'SaveCfg'; 8 = 'LoadCfg'; 9 = 'PowerFailure'; 10 = 'PowerGood'; 11 = 'Error'; 12 = 'Shutdown'
    13 = 'Suspend'; 14 = 'Resume'; 15 = 'Config'; 16 = 'Reconfig'; 17 = 'Stopping'; 18 = 'Incompatible'
    19 = 'Exception'
}

function Read-TcSystemAdsState {
    <#
    .SYNOPSIS
        Reads the AdsState of the TwinCAT system service (port 10000) of one target once (#287).
    .DESCRIPTION
        Opens a temporary client (New-TcAdsClient, port 10000), calls ReadState() once and disposes
        the client. Never throws and never writes anything. The module ADS session is not touched.
    .PARAMETER AmsNetId
        Target AMS Net ID (the module ADS session's NetId in Set-TcPlcState / Get-TcPlcState).
    .OUTPUTS
        PSCustomObject { ok = [bool]; state = [string] ('Run', 'Config', 'Exception', ... ; $null when
        the read failed); adsState = [int] ($null when the read failed); readAt = ISO 8601 local time
        of the read; error = [string] ($null when ok); errorCode = mapped module code of the error
        (ConvertTo-TcAdsErrorCode, e.g. ADS_TARGET_NOT_FOUND; $null when ok or not mapped) }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$AmsNetId)

    $client = $null
    try {
        if ([string]::IsNullOrWhiteSpace($AmsNetId)) { throw 'No AmsNetId for the system state read (port 10000).' }
        $client = New-TcAdsClient -AmsNetId $AmsNetId -Port 10000
        $info = $client.ReadState()
        $n = [int]$info.AdsState
        $name = if ($script:TcAdsStateNames.ContainsKey($n)) { [string]$script:TcAdsStateNames[$n] } else { "Unknown($n)" }
        return [PSCustomObject]@{ ok = $true; state = $name; adsState = $n; readAt = (Get-Date).ToString('o'); error = $null; errorCode = $null }
    }
    catch {
        $err = $_
        $mapped = $null
        try { $mapped = ConvertTo-TcAdsErrorCode -InputObject $err } catch { }
        $msg = [string]$err.Exception.Message
        $inner = $err.Exception
        while ($null -ne $inner.InnerException) { $inner = $inner.InnerException }
        if ($null -ne $inner -and -not [string]::IsNullOrWhiteSpace([string]$inner.Message)) { $msg = [string]$inner.Message }
        return [PSCustomObject]@{
            ok        = $false
            state     = $null
            adsState  = $null
            readAt    = (Get-Date).ToString('o')
            error     = $msg
            errorCode = $(if ($null -ne $mapped) { [string]$mapped.Code } else { $null })
        }
    }
    finally {
        if ($null -ne $client) { try { $client.Dispose() } catch { } }
    }
}

# #287 Run postcondition: after port 851 reached Run, both ports must keep reading Run for a short
# window before Set-TcPlcState returns success. Measured 2026-11-13 (XAE 4026.22 / VS2022, local
# UmRT, runtime-semantics-measured.md section 7.1): with port 10000 in Exception, WriteControl Run
# on 851 read back Run after 26 ms, then TwinCAT shut itself down (851 unreachable within ~0.5 s,
# 10000 = Config from ~1.5 s). 1500 ms covers that observation; a healthy PLC pays 1.5 s once.
# The window is bounded and polled (no blind wait): the first read that is not Run on either port
# ends it at once. At least $script:TcPlcRunConfirmMinSamples rounds are read even when one round
# is slow, so a single read is never taken as proof. Scaled by $script:TcAdsWaitTimeScale like
# Wait-TcAdsState (only unit tests lower it, #241).
$script:TcPlcRunConfirmMs = 1500
$script:TcPlcRunConfirmIntervalMs = 250
$script:TcPlcRunConfirmMinSamples = 3

function Confirm-TcPlcRunStable {
    <#
    .SYNOPSIS
        #287: checks that the PLC port AND port 10000 keep reading Run for a short window.
    .DESCRIPTION
        Reads port 10000 (Read-TcSystemAdsState) and the PLC port (temporary client from
        New-TcAdsClient) every $script:TcPlcRunConfirmIntervalMs until $script:TcPlcRunConfirmMs
        passed and at least $script:TcPlcRunConfirmMinSamples rounds were read. Ends at the first
        round where either port is not Run or cannot be read. Read-only; never throws.
    .PARAMETER AmsNetId
        Target AMS Net ID.
    .PARAMETER Port
        PLC ADS port (851, 852, ...).
    .OUTPUTS
        PSCustomObject { ok; failedPort (10000 / the PLC port / $null); systemState; systemAdsState;
        systemStateReadAt; plcState ('Unreachable' when the last PLC read failed); error; samples;
        elapsedMs; windowMs; minSamples }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AmsNetId, [Parameter(Mandatory)][int]$Port)

    $scale = Get-TcTimeScale -Value $script:TcAdsWaitTimeScale
    $windowEff = [double]$script:TcPlcRunConfirmMs * $scale
    $intervalEff = [int][Math]::Max(1, [Math]::Round([double]$script:TcPlcRunConfirmIntervalMs * $scale))
    $out = [PSCustomObject]@{
        ok                = $false
        failedPort        = $null
        systemState       = $null
        systemAdsState    = $null
        systemStateReadAt = $null
        plcState          = $null
        error             = $null
        samples           = 0
        elapsedMs         = 0
        windowMs          = [int]$script:TcPlcRunConfirmMs
        minSamples        = [int]$script:TcPlcRunConfirmMinSamples
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $client = $null
    try {
        while ($true) {
            $sys = Read-TcSystemAdsState -AmsNetId $AmsNetId
            $out.systemState = $sys.state; $out.systemAdsState = $sys.adsState; $out.systemStateReadAt = $sys.readAt
            if (-not $sys.ok) { $out.failedPort = 10000; $out.error = "port 10000 unreadable: $($sys.error)"; break }
            if ($sys.adsState -ne $script:TcAdsStateRun) { $out.failedPort = 10000; $out.error = "port 10000 reads $($sys.state) (adsState $($sys.adsState)), expected Run"; break }
            try {
                if ($null -eq $client) { $client = New-TcAdsClient -AmsNetId $AmsNetId -Port $Port }
                $n = [int]$client.ReadState().AdsState
                $out.plcState = if ($script:TcAdsStateNames.ContainsKey($n)) { [string]$script:TcAdsStateNames[$n] } else { "Unknown($n)" }
            }
            catch {
                $out.plcState = 'Unreachable'; $out.failedPort = $Port
                $out.error = "port $Port unreadable: $($_.Exception.Message)"
                break
            }
            if ($n -ne $script:TcAdsStateRun) { $out.failedPort = $Port; $out.error = "port $Port reads $($out.plcState), expected Run"; break }
            $out.samples++
            if ($out.samples -ge $out.minSamples -and $sw.Elapsed.TotalMilliseconds -ge $windowEff) { $out.ok = $true; break }
            Start-Sleep -Milliseconds $intervalEff   # bounded poll interval inside the window, not a blind wait
        }
    }
    finally {
        if ($null -ne $client) { try { $client.Dispose() } catch { } }
        $sw.Stop()
        $out.elapsedMs = [int]$sw.ElapsedMilliseconds
    }
    $out
}
