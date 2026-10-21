function Get-TcLicenseDiagnosis {
    <#
    .SYNOPSIS
        Best-effort license inventory of a target, used when the runtime stays in / falls back
        to Config (an expired trial license keeps a runtime in Config). Never throws: any ADS
        error returns $null, so the diagnosis can never become a new failure.
    .DESCRIPTION
        ADS port 30 is the license server ("R0_LicenseServer 30 The License Server", InfoSys
        AmsPort enumeration https://infosys.beckhoff.com/content/1033/tc3_ads.net/9408352011.html).
        The PLC function block FB_GetLicenses reads "the valid and invalid TwinCAT licenses" of a
        target (InfoSys Tc2_Utilities https://infosys.beckhoff.com/content/1031/tcplclib_tc2_utilities/1876715915.html),
        but the index groups are not documented in InfoSys. Used here (measured 2026-10-21 on
        the local UmRT, same layout as the open-source TcKit reader):
          IG 0x01010006 valid licenses, IG 0x0101000A invalid licenses; 48 bytes per entry:
          GUID @0, FILETIME expiry @16 (0 = none), status u32 @24, instance count u32 @28;
          name: ReadWrite IG 0x0101000C with the license GUID as write data.
        Measured: 9 valid trial licenses (TC3 PLC, TC3 IO, TC3 ADS ...) with expiry 2026-10-25,
        status 0 (one 0xA), invalid list empty. The status values are reported raw, not
        interpreted (InfoSys does not document them).
    .OUTPUTS
        @{ licenses = @( @{ name; id; expires; status; valid } ); expired = [names];
           invalid = [names]; text = one-line diagnosis or $null } , or $null when unreadable.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AmsNetId)

    $client = $null
    try {
        if (-not (Find-TcAdsAssembly)) { return $null }
        $client = New-Object TwinCAT.Ads.TcAdsClient
        $client.Timeout = 3000
        $client.Connect($AmsNetId, 30)
        $now = [DateTime]::UtcNow
        $list = @()
        foreach ($src in @(@{ Ig = 0x01010006; Valid = $true }, @{ Ig = 0x0101000A; Valid = $false })) {
            $stream = New-Object TwinCAT.Ads.AdsStream (48 * 256)
            $n = 0
            try { $n = $client.Read([long]$src.Ig, 0, $stream) } catch { continue }
            $buf = $stream.ToArray()
            for ($o = 0; $o + 48 -le $n; $o += 48) {
                $guid = New-Object Guid (, [byte[]]$buf[$o..($o + 15)])
                $ft = [BitConverter]::ToInt64($buf, $o + 16)
                $expires = if ($ft -gt 0) { [DateTime]::FromFileTimeUtc($ft) } else { $null }
                $name = $null
                try {
                    $w = New-Object TwinCAT.Ads.AdsStream (, $guid.ToByteArray())
                    $r = New-Object TwinCAT.Ads.AdsStream 256
                    $rn = $client.ReadWrite(0x0101000C, 0, $r, $w)
                    $name = [Text.Encoding]::ASCII.GetString($r.ToArray(), 0, $rn).TrimEnd([char]0)
                }
                catch { $name = $null }
                $list += [PSCustomObject]@{
                    name    = if ([string]::IsNullOrWhiteSpace($name)) { [string]$guid } else { $name }
                    id      = [string]$guid
                    expires = if ($null -ne $expires) { $expires.ToString('yyyy-MM-ddTHH:mm:ssZ') } else { $null }
                    status  = ('0x{0:X}' -f [BitConverter]::ToUInt32($buf, $o + 24))
                    valid   = $src.Valid
                    expired = ($null -ne $expires -and $expires -le $now)
                }
            }
        }
        $expired = @($list | Where-Object { $_.expired } | ForEach-Object { "$($_.name) (expired $($_.expires))" })
        $invalid = @($list | Where-Object { -not $_.valid -and -not $_.expired } | ForEach-Object { $_.name })
        $text = $null
        if ($expired.Count -gt 0 -or $invalid.Count -gt 0) {
            $parts = @()
            if ($expired.Count -gt 0) { $parts += "expired: $($expired -join ', ')" }
            if ($invalid.Count -gt 0) { $parts += "invalid: $($invalid -join ', ')" }
            $text = "License server (ADS port 30) of $AmsNetId reports $($parts -join '; ') - a missing/expired license keeps the runtime in Config; renew it in XAE (System > License, 7 Days Trial License is an interactive dialog)."
        }
        return [PSCustomObject]@{ licenses = $list; expired = $expired; invalid = $invalid; text = $text }
    }
    catch {
        Write-Verbose "Get-TcLicenseDiagnosis: license server of $AmsNetId not readable ($($_.Exception.Message))"
        return $null
    }
    finally {
        if ($null -ne $client) { try { $client.Dispose() } catch { } }
    }
}
