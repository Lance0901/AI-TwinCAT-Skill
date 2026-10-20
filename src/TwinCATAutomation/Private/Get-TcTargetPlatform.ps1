function Get-TcTargetPlatform {
    <#
    .SYNOPSIS
        Reads the platform of an ADS target ('TwinCAT OS (x64)' for a Usermode Runtime ...)
        from the documented TARGETINFO interface, so the solution platform can follow the
        target. Never throws, never guesses.
    .DESCRIPTION
        TwinCAT 4026 XAE refuses to activate when the active solution platform differs from
        the target platform ("Check config failed!", see Enable-TcConfig ACTIVATE_FAILED).
        Beckhoff InfoSys, TC1700/TC170x Usermode Runtime manual, "Runtime type (ADS)":
        https://infosys.beckhoff.com/content/1033/tc170x_tc3_usermode_runtime/11687997963.html
          ADS port 200, IndexGroup 0x00000700 (SYSTEMSERVICE_TARGETINFO):
            IndexOffset 0x00000004 TARGETINFO_PLATFORM   = string, the platform as selected
                                                            in XAE (e.g. 'TwinCAT OS (x64)'
                                                            for a Usermode Runtime or TwinCAT/BSD)
            IndexOffset 0x00000002 TARGETINFO_TARGETTYPE = ULONG, 1 = Usermode Runtime, 0 = not
        Only this interface is used. The entry is in the manual v1.6.1 (2026-08); the
        minimum runtime build that implements it is not confirmed. Measured 2026-10-21:
        the local UmRT (TcSystemServiceUm.exe 3.1.0.2649, TwinCAT 3.1.4026.21/.22) and the
        local Windows XAR both answer IG 0x700 with ADS error 0x702 (IndexGroup invalid),
        also while in Run -> source 'unavailable'.
        A timeout (0x745) or 'target machine not found' (0x7) on IO 4 ends the probe
        (IO 2 is not tried). Temporary TcAdsClient only (the module ADS session is not
        touched), Timeout = -TimeoutMs, always disposed.
    .PARAMETER AmsNetId
        Target AMS Net ID.
    .PARAMETER TimeoutMs
        ADS timeout per request in ms. Default 2000.
    .OUTPUTS
        [PSCustomObject]@{
            amsNetId; targetPlatform ([string] or $null);
            isUsermodeRuntime ($true/$false from TARGETINFO_TARGETTYPE, $null when not read);
            source ('adsTargetInfo' | 'unavailable');
            adsError (ADS error code(s) seen, e.g. '0x702', '0x745'; $null when none);
            detail }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$AmsNetId,

        [Parameter()]
        [ValidateRange(200, 30000)]
        [int]$TimeoutMs = 2000
    )

    $out = [PSCustomObject]@{
        amsNetId          = $AmsNetId
        targetPlatform    = $null
        isUsermodeRuntime = $null
        source            = 'unavailable'
        adsError          = $null
        detail            = $null
    }
    $notes = New-Object System.Collections.ArrayList
    $codes = New-Object System.Collections.ArrayList

    # ADS error code of an exception chain (AdsErrorException.ErrorCode), $null when none.
    function Get-TcAdsErrNumber {
        param($ErrorRecord)
        $ex = $ErrorRecord.Exception
        while ($null -ne $ex) {
            $p = $ex.PSObject.Properties['ErrorCode']
            if ($null -ne $p -and $null -ne $p.Value) {
                try { return [int]$p.Value } catch { }
            }
            $ex = $ex.InnerException
        }
        return $null
    }

    # "ADS error 0x702 IndexGroup is invalid." (and the code recorded in $codes)
    function Format-TcAdsErr {
        param($ErrorRecord)
        $n = Get-TcAdsErrNumber $ErrorRecord
        $msg = [string]$ErrorRecord.Exception.Message
        if ($null -ne $ErrorRecord.Exception.InnerException) { $msg = [string]$ErrorRecord.Exception.InnerException.Message }
        # "Ads-Error 0x702 : IndexGroup is invalid. (IndexGroup is invalid. (AdsErrorCode: ...))" -> "IndexGroup is invalid."
        if ($msg -match 'Ads-Error\s+0x[0-9A-Fa-f]+\s*:\s*([^(]+)') { $msg = $Matches[1] }
        $msg = $msg.Trim()
        if ($null -ne $n) {
            $hex = '0x{0:X}' -f $n
            if ($codes -notcontains $hex) { $null = $codes.Add($hex) }
            return "ADS error $hex $msg"
        }
        return $msg
    }

    $loaded = $false
    try { $loaded = Find-TcAdsAssembly } catch { $loaded = $false }
    if (-not $loaded) {
        $out.detail = 'TwinCAT.Ads.dll not found; TARGETINFO not read.'
        return $out
    }

    $client = $null
    try {
        $client = New-Object TwinCAT.Ads.TcAdsClient
        $client.Timeout = $TimeoutMs
        $client.Connect($AmsNetId, 200)

        $platform = $null
        $stop = $false
        try {
            $s = New-Object TwinCAT.Ads.AdsStream 512
            $n = [int]$client.Read(0x700, 4, $s)
            $bytes = $s.ToArray()
            if ($n -gt $bytes.Length) { $n = $bytes.Length }
            if ($n -gt 0) {
                $str = [System.Text.Encoding]::ASCII.GetString($bytes, 0, $n)
                $nul = $str.IndexOf([char]0)
                if ($nul -ge 0) { $str = $str.Substring(0, $nul) }
                $str = $str.Trim()
                if (-not [string]::IsNullOrWhiteSpace($str)) { $platform = $str }
            }
            if ($null -eq $platform) { $null = $notes.Add('IO 4 TARGETINFO_PLATFORM: empty string') }
        }
        catch {
            $code = Get-TcAdsErrNumber $_
            if ($code -eq 0x745 -or $code -eq 0x7) { $stop = $true }
            $null = $notes.Add("IO 4 TARGETINFO_PLATFORM: $(Format-TcAdsErr $_)")
        }

        if (-not $stop) {
            try {
                $s2 = New-Object TwinCAT.Ads.AdsStream 4
                $n2 = [int]$client.Read(0x700, 2, $s2)
                if ($n2 -ge 4) {
                    $tt = [BitConverter]::ToUInt32($s2.ToArray(), 0)
                    $out.isUsermodeRuntime = ($tt -eq 1)
                    $null = $notes.Add("IO 2 TARGETINFO_TARGETTYPE: $tt (1 = Usermode Runtime)")
                }
                else {
                    $null = $notes.Add("IO 2 TARGETINFO_TARGETTYPE: $n2 byte(s) returned")
                }
            }
            catch {
                $null = $notes.Add("IO 2 TARGETINFO_TARGETTYPE: $(Format-TcAdsErr $_)")
            }
        }

        if ($null -ne $platform) {
            $out.targetPlatform = $platform
            $out.source = 'adsTargetInfo'
        }
    }
    catch {
        $null = $notes.Add("port 200: $(Format-TcAdsErr $_)")
    }
    finally {
        if ($null -ne $client) { try { $client.Dispose() } catch { } }
    }

    if ($codes.Count -gt 0) { $out.adsError = ($codes -join ', ') }
    $head = if ($out.source -eq 'adsTargetInfo') { "TARGETINFO (port 200 IG 0x700): platform '$($out.targetPlatform)'" } else { 'TARGETINFO (port 200 IG 0x700) not available' }
    $out.detail = $head + $(if ($notes.Count -gt 0) { '; ' + ($notes -join '; ') } else { '' })
    return $out
}
