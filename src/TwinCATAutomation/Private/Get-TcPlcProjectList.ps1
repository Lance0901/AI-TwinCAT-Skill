function Get-TcPlcProjectList {
    <#
    .SYNOPSIS
        Lists every PLC project of the open solution with its tree paths and ADS port.
    .DESCRIPTION
        Enumerates the children of TIPC. For each PLC node "TIPC^<Plc>":
          name         <Plc>
          nodePath     TIPC^<Plc>              (exposes Login / Logoff on 4026)
          projectPath  TIPC^<Plc>^<Plc> Project (exposes Login(nFlags))
          adsPort      <AdsPort> of the PLC node's ProduceXml ($null when not present); the
                       first value in 800..899 wins (PLC runtime ports), else the first one.
          disabled     ITcSmTreeItem.Disabled <> 0 (SMDS_NOT_DISABLED = 0; InfoSys "How to
                       disable/enable a tree item"
                       https://infosys.beckhoff.com/content/1033/tcautomationinterface/12425861515.html).
                       A disabled PLC is not activated, so Enable-TcConfig skips it.
        The "<Plc> Project" child is not always enumerable (on 4026 only "<Plc> Instance"
        is listed), so projectPath is built from the name like Resolve-TcPlcProjectPath.
        The ADS port source was measured on 4026 + VS2022 (2026-10-21): the PLC node XML
        contains <AdsPort>851</AdsPort> / <AdsPort>852</AdsPort> per PLC; the
        "<Plc> Project" XML has none. InfoSys does not document this element (measured).
    .PARAMETER SysManager
        ITcSysManager (Get-TcSysManager).
    .OUTPUTS
        PSCustomObject[] @{ name; nodePath; projectPath; adsPort; disabled }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $SysManager
    )

    $sm = $SysManager
    $tipc = Invoke-TcComRetry -OperationName 'LookupTreeItem TIPC' -ScriptBlock { Write-Output -NoEnumerate $sm.LookupTreeItem('TIPC') }
    if ($null -eq $tipc) { return @() }
    $count = [int](Invoke-TcComRetry -OperationName 'TIPC.ChildCount' -ScriptBlock { $tipc.ChildCount })

    $list = @()
    for ($i = 1; $i -le $count; $i++) {
        $info = Invoke-TcComRetry -OperationName "TIPC.Child($i)" -ScriptBlock {
            $n = $tipc.Child($i)
            $xml = $null
            try { $xml = [string]$n.ProduceXml($false) } catch { $xml = $null }
            $dis = 0
            try { $dis = [int]$n.Disabled } catch { $dis = 0 }
            @{ Name = [string]$n.Name; Path = [string]$n.PathName; Xml = $xml; Disabled = $dis }
        }
        $port = $null
        if (-not [string]::IsNullOrWhiteSpace($info.Xml)) {
            $ports = @([regex]::Matches($info.Xml, '<AdsPort>(\d+)</AdsPort>') | ForEach-Object { [int]$_.Groups[1].Value })
            $plcPorts = @($ports | Where-Object { $_ -ge 800 -and $_ -le 899 })
            if ($plcPorts.Count -gt 0) { $port = $plcPorts[0] } elseif ($ports.Count -gt 0) { $port = $ports[0] }
        }
        $list += [PSCustomObject]@{
            name        = $info.Name
            nodePath    = $info.Path
            projectPath = "$($info.Path)^$($info.Name) Project"
            adsPort     = $port
            disabled    = ($info.Disabled -ne 0)
        }
    }
    return $list
}

function Find-TcPlcProject {
    <#
    .SYNOPSIS
        Picks one entry of Get-TcPlcProjectList by name or tree path.
    .DESCRIPTION
        -Spec may be the PLC name ('FrameworkUnitTest'), the PLC node path
        ('TIPC^FrameworkUnitTest'), the project path ('TIPC^FrameworkUnitTest^FrameworkUnitTest
        Project') or any deeper path below it; compared case-insensitively. Returns $null
        when nothing matches.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$List,
        [Parameter(Mandatory)][string]$Spec
    )
    $s = $Spec.Trim()
    foreach ($p in $List) {
        if ($s -ieq $p.name -or $s -ieq $p.nodePath -or $s -ieq $p.projectPath) { return $p }
    }
    foreach ($p in $List) {
        if ($s.StartsWith("$($p.nodePath)^", [StringComparison]::OrdinalIgnoreCase)) { return $p }
    }
    # The list can be empty right after a restart (TIPC not enumerable yet): a full tree path
    # is then used as given, port unknown (old behaviour).
    if (@($List).Count -eq 0 -and $s -match '^TIPC\^([^\^]+)') {
        $plc = $Matches[1]
        $proj = if ($s -match '^TIPC\^[^\^]+\^') { $s } else { "TIPC^$plc^$plc Project" }
        return [PSCustomObject]@{ name = $plc; nodePath = "TIPC^$plc"; projectPath = $proj; adsPort = $null; disabled = $false }
    }
    return $null
}
