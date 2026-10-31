function Find-TcAdsTarget {
    <#
    .SYNOPSIS
        Searches the network for ADS targets (TIRR BroadcastSearch, or Search for one IP / host name); only works when the IDE target is the local system. Does not change the configuration.
    .DESCRIPTION
        TE1000 Automation Interface manual v1.7.0 6.3.11 p.211-213, 6.4.2 p.224-225: ConsumeXml
        <TreeItem><RoutePrj><TargetList><BroadcastSearch>true</BroadcastSearch></TargetList></RoutePrj></TreeItem>
        (or <Search>ip | host</Search>, from 4020.10), then ProduceXml TreeItem/RoutePrj/TargetList/Target.
        Measured 2026-11-01 4026 VS2022 XAE 3.1.4026.22, self-built client
        (openspec/changes/complete-automation-interface/verification/phase3-probe.md question 23): with
        the target set to the local UmRT both fail ("Broadcast search only works on local target
        system. Please change target system to local system!"); with the local system the call is
        synchronous (about 4.05 s, also for an address that does not exist) and the probe found no
        target at all (local network / firewall or no answer from the UmRT, not decided).
        So the module does NOT switch the target: when RoutePrj/Target is not the local system
        (registry HKLM\SOFTWARE\[WOW6432Node\]Beckhoff\TwinCAT3\System AmsNetId) it returns
        ROUTE_SEARCH_REQUIRES_LOCAL_TARGET without sending anything; the same code is returned when
        XAE refuses with that message (the local NetId could not be read).
        A modal dialog is checked right before ConsumeXml. The fragment is built with XmlDocument.
        data: target, search, targets[] (name, netId, ipAddr, version, os ...), elapsedMs. An empty
        list is not an error, but it is no proof that there is no target either (data.note).
        Only unit tests so far; registered tcauto verification is task 4.6.
    .PARAMETER Search
        Optional IPv4 address or host name to ask directly; empty = broadcast search.
    .EXAMPLE
        Find-TcAdsTarget
    .EXAMPLE
        Find-TcAdsTarget -Search 192.168.1.20
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Search
    )

    $data = [PSCustomObject]@{ search = $(if ([string]::IsNullOrWhiteSpace($Search)) { $null } else { $Search.Trim() }) }
    if (-not [string]::IsNullOrWhiteSpace($Search) -and -not (Test-TcIpv4Text -Value $Search.Trim()) -and -not (Test-TcHostNameText -Value $Search.Trim())) {
        return New-TcResult -Success $false -ErrorCode 'INVALID_PARAMS' -Data $data -ErrorMessage "-Search must be an IPv4 address or a host name (got '$Search'); nothing was sent."
    }
    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }
    $sm = Get-TcSysManager
    if ($null -eq $sm) { return New-TcNoSysManagerResult }

    try {
        $rp = Read-TcRoutePrj -SysManager $sm -Data $data
        if ($null -ne $rp.Result) { return $rp.Result }
        $data | Add-Member -NotePropertyName target -NotePropertyValue $rp.Routes.target
        $local = Get-TcLocalSystemNetId
        $data | Add-Member -NotePropertyName localNetId -NotePropertyValue $local
        if (-not [string]::IsNullOrWhiteSpace($local) -and -not [string]::IsNullOrWhiteSpace($rp.Routes.target) -and $rp.Routes.target -ne $local) {
            return New-TcResult -Success $false -ErrorCode 'ROUTE_SEARCH_REQUIRES_LOCAL_TARGET' -Data $data `
                -ErrorMessage "The IDE target is $($rp.Routes.target), not the local system $local; XAE searches only from the local system. Nothing was sent (the target is not switched automatically)." -Hint (Get-TcErrorHint -Code 'ROUTE_SEARCH_REQUIRES_LOCAL_TARGET')
        }
        $doc = New-Object System.Xml.XmlDocument
        $ti = $doc.AppendChild($doc.CreateElement('TreeItem'))
        $tl = $ti.AppendChild($doc.CreateElement('RoutePrj')).AppendChild($doc.CreateElement('TargetList'))
        if ($null -eq $data.search) { $e = $tl.AppendChild($doc.CreateElement('BroadcastSearch')); $e.InnerText = 'true' }
        else { $e = $tl.AppendChild($doc.CreateElement('Search')); $e.InnerText = $data.search }
        $xml = $doc.OuterXml
        $item = $rp.Item
        $dlg = Get-TcTreeItemDialogResult -Operation 'ConsumeXml TIRR (search)' -Data $data
        if ($null -ne $dlg) { return $dlg }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        # No deadline (CODING_STANDARDS.md 1): synchronous, about 4.05 s in every probe call
        # (question 23); a dialog was ruled out just above; the MCP tool timeout bounds it.
        try { Invoke-TcComRetry -OperationName 'ConsumeXml TIRR (search)' -ScriptBlock { $item.ConsumeXml($xml) } | Out-Null }
        catch {
            if ($null -ne (Get-TcTreeItemPassThroughError -ErrorRecord $_)) { throw }
            $msg = Get-TcExceptionText -InputObject $_
            $code = if ($msg -match 'only works on local target system') { 'ROUTE_SEARCH_REQUIRES_LOCAL_TARGET' } else { 'ROUTE_SEARCH_FAILED' }
            return New-TcResult -Success $false -ErrorCode $code -Data $data -ErrorMessage "XAE refused the search: $(Protect-TcSecretText -Text $msg)" -Hint (Get-TcErrorHint -Code $code)
        }
        $data | Add-Member -NotePropertyName elapsedMs -NotePropertyValue ([int]$sw.ElapsedMilliseconds)
        $after = ConvertFrom-TcRoutePrjXml -Xml (Get-TcTreeItemXmlText -Item $item -Path 'TIRR')
        $data | Add-Member -NotePropertyName targets -NotePropertyValue @($after.targets)
        if (@($after.targets).Count -eq 0) { $data | Add-Member -NotePropertyName note -NotePropertyValue 'no target answered; this does not prove that there is none (firewall, other subnet, or a runtime that does not answer the broadcast)' }
        return New-TcResult -Success $true -Data $data
    }
    catch {
        New-TcTreeItemErrorResult -ErrorRecord $_ -DefaultCode 'ROUTE_SEARCH_FAILED' -Data $data -Operation 'Find-TcAdsTarget'
    }
}
