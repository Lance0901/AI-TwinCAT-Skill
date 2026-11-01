function Get-TcAdsRoutes {
    <#
    .SYNOPSIS
        Lists the ADS routes of the CURRENT target from the TIRR ProduceXml: actual, static and project routes. Read-only.
    .DESCRIPTION
        TIRR (route settings, TE1000 Automation Interface manual v1.7.0 6.3.11 p.211, 6.3.17 p.220-221).
        Measured 2026-11-01 4026 VS2022 XAE 3.1.4026.22, self-built client
        (openspec/changes/complete-automation-interface/verification/phase3-probe.md question 22):
        ItemName 'Routes'; RoutePrj/Target is the NetId of the current target (Set-TcTarget) and the
        lists are ITS route table (the local UmRT had none, the local system two); StaticRoutes holds
        Name, Address, NetId, Type and sometimes Flags (the same as the StaticRoutes.xml of that
        system); no password element. Passwords would be masked anyway (ConvertTo-TcMaskedXml).
        data: target, actualRoutes[] (name, netId), staticRoutes[] (name, address, netId, type,
        flags), projectRoutes[]. Add a route with Add-TcAdsRoute; removing one is not supported by
        the Automation Interface (TE1000 p.220: edit StaticRoutes.xml and restart the TwinCAT
        service), see docs/troubleshooting.md.
        Verified with registered tcauto on 4026 and 4024 (openspec/changes/complete-automation-interface/verification/phase3-4.6.md).
    .EXAMPLE
        Get-TcAdsRoutes
    #>
    [CmdletBinding()]
    param()

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }
    $sm = Get-TcSysManager
    if ($null -eq $sm) { return New-TcNoSysManagerResult }

    $data = [PSCustomObject]@{ path = 'TIRR' }
    try {
        $rp = Read-TcRoutePrj -SysManager $sm -Data $data
        if ($null -ne $rp.Result) { return $rp.Result }
        $data | Add-Member -NotePropertyName target -NotePropertyValue $rp.Routes.target
        $data | Add-Member -NotePropertyName actualRoutes -NotePropertyValue @($rp.Routes.actualRoutes)
        $data | Add-Member -NotePropertyName staticRoutes -NotePropertyValue @($rp.Routes.staticRoutes)
        $data | Add-Member -NotePropertyName projectRoutes -NotePropertyValue @($rp.Routes.projectRoutes)
        return New-TcResult -Success $true -Data $data
    }
    catch {
        New-TcTreeItemErrorResult -ErrorRecord $_ -DefaultCode 'ROUTE_READ_FAILED' -Data $data -Operation 'Get-TcAdsRoutes'
    }
}
