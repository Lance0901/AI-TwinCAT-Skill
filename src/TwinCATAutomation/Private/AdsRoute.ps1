# ADS route helpers (complete-automation-interface phase 3, task 4.5): Get-TcAdsRoutes, Find-TcAdsTarget,
# Add-TcAdsRoute. Node TIRR (TE1000 Automation Interface manual v1.7.0 6.3.11 p.211-213, 6.3.17 p.220-221,
# 6.4 p.222-225; InfoSys https://infosys.beckhoff.com/content/1033/tc3_automationinterface/21842662155.html).
# Measured 2026-11-01 4026 VS2022 XAE 3.1.4026.22, self-built client
# (openspec/changes/complete-automation-interface/verification/phase3-probe.md questions 22-26):
#   - TIRR: ItemName 'Routes', ItemType 31; ProduceXml <RoutePrj><Target>, <ActualRoutes>,
#     <StaticRoutes> (Name, Address, NetId, Type, Flags), <ProjectRoutes>, <TargetList>; it shows the
#     route table of the CURRENT target (SetTargetNetId); no password element was seen.
#   - BroadcastSearch / Search only work when the target is the local system ("Broadcast search only
#     works on local target system"); then the call is synchronous (about 4.05 s) and the result is in
#     TargetList/Target (empty in the probe).
#   - AddRoute / AddProjectRoute were NOT measured (no second target).

function ConvertFrom-TcRoutePrjXml {
    <#
    .SYNOPSIS
        TIRR ProduceXml -> @{ Ok; target; actualRoutes; staticRoutes; projectRoutes; targets }.
    .DESCRIPTION
        Every Route / Target element becomes an object of its child element texts (Name, NetId,
        Address, Type, Flags, IpAddr, HostName, Version, OS ...); names are lower camel case.
        The text is parsed without DTD and resolver. Ok = $false when there is no RoutePrj.
    .PARAMETER Xml
        ProduceXml text (already masked).
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Xml)
    $out = @{ Ok = $false; target = $null; actualRoutes = @(); staticRoutes = @(); projectRoutes = @(); targets = @() }
    $doc = ConvertFrom-TcTreeItemXmlString -Xml $Xml
    if ($null -eq $doc) { return $out }
    $rp = $doc.SelectSingleNode('TreeItem/RoutePrj')
    if ($null -eq $rp) { return $out }
    $toObj = {
        param($node)
        $h = [ordered]@{}
        foreach ($c in @($node.ChildNodes | Where-Object { $_.NodeType -eq 'Element' })) {
            $k = $c.Name.Substring(0, 1).ToLowerInvariant() + $c.Name.Substring(1)
            $h[$k] = [string]$c.InnerText
        }
        [PSCustomObject]$h
    }
    $out.Ok = $true
    $t = $rp.SelectSingleNode('Target')
    $out.target = if ($null -ne $t) { [string]$t.InnerText } else { $null }
    $out.actualRoutes = @($rp.SelectNodes('ActualRoutes/Route') | ForEach-Object { & $toObj $_ })
    $out.staticRoutes = @($rp.SelectNodes('StaticRoutes/Route') | ForEach-Object { & $toObj $_ })
    $out.projectRoutes = @($rp.SelectNodes('ProjectRoutes/Route') | ForEach-Object { & $toObj $_ })
    $out.targets = @($rp.SelectNodes('TargetList/Target') | ForEach-Object { & $toObj $_ })
    return $out
}

function Get-TcLocalSystemNetId {
    <#
    .SYNOPSIS
        AmsNetId of this PC's TwinCAT system (registry HKLM\SOFTWARE\[WOW6432Node\]Beckhoff\TwinCAT3\System AmsNetId), or $null. Never throws.
    .DESCRIPTION
        The same registry value as Resolve-TcTargetBootDir. A local UmRT has its own NetId and is
        NOT the local system for the broadcast search (measured: target = UmRT -> "only works on
        local target system", phase3-probe.md question 23).
    #>
    [CmdletBinding()]
    param()
    foreach ($key in 'HKLM:\SOFTWARE\WOW6432Node\Beckhoff\TwinCAT3\System', 'HKLM:\SOFTWARE\Beckhoff\TwinCAT3\System') {
        try {
            $v = (Get-ItemProperty -Path $key -Name AmsNetId -ErrorAction Stop).AmsNetId
            if ($null -ne $v -and $v.Length -eq 6) { return (($v | ForEach-Object { [int]$_ }) -join '.') }
        }
        catch { continue }
    }
    return $null
}

function Test-TcAmsNetIdText {
    <#
    .SYNOPSIS
        True for an AmsNetId 'a.b.c.d.e.f' (each 0-255).
    .PARAMETER Value
        Text.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch '^\d{1,3}(\.\d{1,3}){5}$') { return $false }
    return (@($Value.Split('.') | Where-Object { [int]$_ -gt 255 }).Count -eq 0)
}

function Test-TcIpv4Text {
    <#
    .SYNOPSIS
        True for a dotted IPv4 address.
    .PARAMETER Value
        Text.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return $false }
    return (@($Value.Split('.') | Where-Object { [int]$_ -gt 255 }).Count -eq 0)
}

function Test-TcHostNameText {
    <#
    .SYNOPSIS
        True for a host name (letters, digits, '-', '.'; 1-253 characters).
    .PARAMETER Value
        Text.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Value)
    return (-not [string]::IsNullOrWhiteSpace($Value) -and $Value -match '^[A-Za-z0-9]([A-Za-z0-9-]{0,62})(\.[A-Za-z0-9]([A-Za-z0-9-]{0,62}))*$' -and $Value.Length -le 253)
}

function Read-TcRoutePrj {
    <#
    .SYNOPSIS
        Looks up TIRR and parses its (masked) ProduceXml: @{ Result = $null | <failed result>; Item; Xml; Routes }.
    .PARAMETER SysManager
        ITcSysManager.
    .PARAMETER Data
        Data of the cmdlet.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$SysManager, [Parameter(Mandatory)][object]$Data)
    $r = Resolve-TcTreeItem -SysManager $SysManager -Path 'TIRR' -Data $Data
    if ($null -ne $r.Result) { return @{ Result = $r.Result; Item = $null; Xml = $null; Routes = $null } }
    $xml = Get-TcTreeItemXmlText -Item $r.Item -Path 'TIRR'
    $routes = ConvertFrom-TcRoutePrjXml -Xml $xml
    if (-not $routes.Ok) {
        return @{ Item = $r.Item; Xml = $xml; Routes = $routes; Result = (New-TcResult -Success $false -ErrorCode 'ROUTE_READ_FAILED' -Data $Data `
                    -ErrorMessage "The ProduceXml of TIRR has no TreeItem/RoutePrj." -Hint (Get-TcErrorHint -Code 'ROUTE_READ_FAILED')) }
    }
    return @{ Result = $null; Item = $r.Item; Xml = $xml; Routes = $routes }
}

function Protect-TcSecretText {
    <#
    .SYNOPSIS
        A message with every occurrence of -Secret replaced by *** and passwords in XML masked; an XML fragment (<TreeItem>...) is cut out.
    .PARAMETER Text
        Message.
    .PARAMETER Secret
        Plain text that must not appear (may be empty).
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Text, [Parameter()][AllowNull()][AllowEmptyString()][string]$Secret)
    $t = [string]$Text
    if (-not [string]::IsNullOrEmpty($Secret) -and $Secret.Length -ge 1) { $t = $t.Replace($Secret, $script:TcPasswordMask) }
    $t = ConvertTo-TcMaskedXml -Xml $t
    $t = [regex]::Replace($t, '(?is)<TreeItem>.*?</TreeItem>', '<TreeItem>(omitted)</TreeItem>')
    $t = [regex]::Replace($t, '(?is)<(AddRoute|AddProjectRoute|RoutePrj)>.*', '<$1>(omitted)')
    return $t
}
