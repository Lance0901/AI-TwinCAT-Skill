function ConvertFrom-TcIoScanXml {
    <#
    .SYNOPSIS
        Parses the XML of ITcSmTreeItem.ProduceXml($false) on TIID into found devices.
    .DESCRIPTION
        TE1000 Automation Interface manual v1.7.0, 6.6.2 "Performing a device scan" (p.247):
        found devices are under TreeItem/DeviceGrpDef/FoundDevices/Device, each with
        ItemSubType and AddressInfo. Returns one object per device:
        @{ index; name; itemSubType; addressInfoXml }. An empty FoundDevices returns @().
    .PARAMETER Xml
        The XML string returned by ProduceXml($false).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Xml
    )
    if ([string]::IsNullOrWhiteSpace($Xml)) { throw 'ProduceXml returned no XML' }
    $doc = New-Object System.Xml.XmlDocument
    $doc.LoadXml($Xml)
    if ($null -eq $doc.SelectSingleNode('TreeItem/DeviceGrpDef')) {
        throw 'ProduceXml XML has no TreeItem/DeviceGrpDef node (not the I/O devices node?)'
    }
    $list = @()
    $i = 0
    foreach ($node in $doc.SelectNodes('TreeItem/DeviceGrpDef/FoundDevices/Device')) {
        $i++
        $subNode = $node.SelectSingleNode('ItemSubType')
        $addr = $node.SelectSingleNode('AddressInfo')
        $nameNode = $node.SelectSingleNode('ItemName')
        if ($null -eq $nameNode) { $nameNode = $node.SelectSingleNode('Name') }
        $list += [PSCustomObject]@{
            index          = $i
            name           = if ($null -ne $nameNode) { $nameNode.InnerText } else { $null }
            itemSubType    = if ($null -ne $subNode) { [int]$subNode.InnerText } else { $null }
            addressInfoXml = if ($null -ne $addr) { $addr.OuterXml } else { $null }
        }
    }
    $list
}

function ConvertFrom-TcMappingInfo {
    <#
    .SYNOPSIS
        Parses ITcSysManager3.ProduceMappingInfo() XML into full-path link pairs.
    .DESCRIPTION
        Format (TE1000 v1.7.0, 6.3.14 "Managing variable mappings", p.218):
        <VarLinks><OwnerA Name="..."><OwnerB Name="..."><Link VarA="..." VarB="..."/>.
        VarA / VarB are relative to OwnerA / OwnerB; the full tree path is Owner + '^' + Var.
        Returns @{ a; b } objects with full tree paths.
    .PARAMETER Xml
        The XML string returned by ProduceMappingInfo().
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Xml
    )
    if ([string]::IsNullOrWhiteSpace($Xml)) { return @() }
    $doc = New-Object System.Xml.XmlDocument
    $doc.LoadXml($Xml)
    $links = @()
    foreach ($ownerA in $doc.SelectNodes('VarLinks/OwnerA')) {
        foreach ($ownerB in $ownerA.SelectNodes('OwnerB')) {
            foreach ($link in $ownerB.SelectNodes('Link')) {
                $links += [PSCustomObject]@{
                    a = $ownerA.GetAttribute('Name') + '^' + $link.GetAttribute('VarA')
                    b = $ownerB.GetAttribute('Name') + '^' + $link.GetAttribute('VarB')
                }
            }
        }
    }
    $links
}

function Test-TcMappingHasLink {
    <#
    .SYNOPSIS
        True when the parsed mapping contains a link between the two full tree paths (either direction, case-insensitive).
    .PARAMETER Links
        Output of ConvertFrom-TcMappingInfo.
    .PARAMETER PathA
        One end (full tree path).
    .PARAMETER PathB
        Other end (full tree path).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Links,
        [Parameter(Mandatory)][string]$PathA,
        [Parameter(Mandatory)][string]$PathB
    )
    foreach ($l in $Links) {
        if (($l.a -ieq $PathA -and $l.b -ieq $PathB) -or ($l.a -ieq $PathB -and $l.b -ieq $PathA)) { return $true }
    }
    return $false
}

function ConvertTo-TcTsmErrorCode {
    <#
    .SYNOPSIS
        Maps a TwinCAT System Manager COM exception (TSM_E_*) to a module error code.
    .DESCRIPTION
        TE1000 v1.7.0 5.1.1.2 LinkVariables (p.38) lists TSM_E_ITEMNOTFOUND, TSM_E_INVALIDITEMTYPE
        and TSM_E_MISMATCHINGITEMS. The manual gives no numeric values; 0x98510001 =
        TSM_E_ITEMNOTFOUND is 實測 2026-10-28 (4026 XAE in VS2022, LookupTreeItem on a missing
        path: "Item '...' not found"). The other two are matched by HRESULT name / message text.
        Returns 'TREEITEM_NOT_FOUND', 'LINK_INVALID_ITEM_TYPE', 'LINK_TYPE_MISMATCH' or $DefaultCode.
    .PARAMETER InputObject
        ErrorRecord or Exception.
    .PARAMETER DefaultCode
        Code returned when nothing matches.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$InputObject,
        [Parameter()][string]$DefaultCode = 'LINK_FAILED'
    )
    $ex = if ($InputObject -is [System.Management.Automation.ErrorRecord]) { $InputObject.Exception } else { $InputObject }
    $hr = 0
    $msg = ''
    while ($null -ne $ex -and $ex -is [System.Exception]) {
        if ($ex.HResult -ne 0 -and $hr -eq 0 -and $ex.HResult -ne -2146233087 -and $ex.HResult -ne -2146233088) { $hr = $ex.HResult }
        $msg += ' ' + $ex.Message
        $ex = $ex.InnerException
    }
    if ($null -eq $InputObject -or $InputObject -is [string]) { $msg = [string]$InputObject }
    if ($hr -eq [int]0x98510001 -or $msg -match 'ITEMNOTFOUND|Item .* not found') { return 'TREEITEM_NOT_FOUND' }
    if ($msg -match 'INVALIDITEMTYPE|not a variable|invalid item type') { return 'LINK_INVALID_ITEM_TYPE' }
    if ($msg -match 'MISMATCHINGITEMS|not compatible|mismatch') { return 'LINK_TYPE_MISMATCH' }
    return $DefaultCode
}

function Test-TcTreeItemExists {
    <#
    .SYNOPSIS
        Returns $null when the tree path exists (ITcSysManager.LookupTreeItem), else the exception message.
    .PARAMETER SysManager
        ITcSysManager.
    .PARAMETER Path
        Full tree path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$SysManager,
        [Parameter(Mandatory)][string]$Path
    )
    try {
        $item = $SysManager.LookupTreeItem($Path)
        if ($null -eq $item) { return "LookupTreeItem('$Path') returned null" }
        return $null
    }
    catch {
        $code = ConvertTo-TcTsmErrorCode -InputObject $_ -DefaultCode 'OTHER'
        if ($code -eq 'TREEITEM_NOT_FOUND') { return $_.Exception.Message }
        throw
    }
}

function Get-TcMappingLinks {
    <#
    .SYNOPSIS
        Reads ProduceMappingInfo() (TE1000 v1.7.0 5.1.3.4, p.45) and returns parsed links.
    .PARAMETER SysManager
        ITcSysManager (late bound; ProduceMappingInfo is on ITcSysManager3).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$SysManager)
    $xml = Invoke-TcComRetry -OperationName 'ProduceMappingInfo' -ScriptBlock { $SysManager.ProduceMappingInfo() }
    ConvertFrom-TcMappingInfo -Xml ([string]$xml)
}
