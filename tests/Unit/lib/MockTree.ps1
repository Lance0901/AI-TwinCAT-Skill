# Shared mock of the XAE tree for the phase 3 unit tests (tests/Unit/nc-axis.ps1, tccom-module.ps1,
# project-variant.ps1, independent-file.ps1, ads-route.ps1). Dot-sourced by those scripts (this folder
# is not run by scripts/check.ps1, which only takes tests/Unit/*.ps1).
# An in-memory tree in $global:T.Nodes (path -> node). Node behaviour can be changed per test:
#   $global:T.OnCreate  = { param($Parent, $Name, $SubType, $Before, $VInfo) <return a node or throw> }
#   $global:T.OnConsume = { param($Node, $Xml) <$true = handled> }   (default: leaf merge like XAE)
#   $global:T.Dialog    = <dialog object> makes Get-TcIdeModalDialog report a modal dialog.
# Every write is logged in $global:T.Mods ("CreateChild <path>/<sub>", "ConsumeXml <path>", ...).

function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 400) { $Detail = $Detail.Substring(0, 400) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}
function J($o) { $o | ConvertTo-Json -Depth 8 -Compress }

$global:T = @{}

function New-ComError([string]$Message, [int]$HResult) {
    [System.Runtime.InteropServices.COMException]::new($Message, $HResult)
}

function Add-MockNode([string]$Path, [int]$ItemType = 0, [string]$Xml = '', [int]$SubType = 0, [string]$SubTypeName = 'TREEITEMTYPE_MOCK') {
    $name = ($Path -split '\^')[-1]
    if ([string]::IsNullOrEmpty($Xml)) { $Xml = "<TreeItem><ItemName>$([System.Security.SecurityElement]::Escape($name))</ItemName><PathName>$([System.Security.SecurityElement]::Escape($Path))</PathName></TreeItem>" }
    $n = [PSCustomObject]@{ Name = $name; PathName = $Path; ItemType = $ItemType; ItemSubType = $SubType; ItemSubTypeName = $SubTypeName; Xml = $Xml; Kids = [System.Collections.ArrayList]::new(); Props = @{} }
    $n | Add-Member ScriptProperty ChildCount { $this.Kids.Count }
    $n | Add-Member ScriptMethod Child { param($i) $global:T.Nodes[$this.Kids[$i - 1]] }
    $n | Add-Member ScriptMethod ProduceXml { param($rec) $this.Xml }
    $n | Add-Member ScriptMethod ConsumeXml {
        param($x)
        $global:T.Mods.Add("ConsumeXml $($this.PathName)") | Out-Null
        $global:T.LastXml = $x
        if ($null -ne $global:T.OnConsume) {
            $handled = & $global:T.OnConsume $this $x
            if ($handled) { return }
        }
        Merge-MockXml -Node $this -Fragment $x
    }
    $n | Add-Member ScriptMethod CreateChild {
        param($cname, $sub, $before, $vinfo)
        $global:T.Mods.Add("CreateChild $($this.PathName)^$cname/$sub") | Out-Null
        if ($null -eq $global:T.OnCreate) { throw (New-ComError 'Not implemented (mock)' -2147467263) }
        $c = & $global:T.OnCreate $this $cname $sub $before $vinfo
        Write-Output -NoEnumerate $c
    }
    $n | Add-Member ScriptMethod DeleteChild {
        param($cname)
        $global:T.Mods.Add("DeleteChild $($this.PathName)^$cname") | Out-Null
        Remove-MockSubtree "$($this.PathName)^$cname"
    }
    $n | Add-Member ScriptMethod ExportChild {
        param($cname, $file)
        [System.IO.File]::WriteAllText($file, "export $cname")
    }
    $global:T.Nodes[$Path] = $n
    $i = $Path.LastIndexOf('^')
    if ($i -gt 0 -and $global:T.Nodes.ContainsKey($Path.Substring(0, $i))) { $null = $global:T.Nodes[$Path.Substring(0, $i)].Kids.Add($Path) }
    Write-Output -NoEnumerate $n
}

function Remove-MockSubtree([string]$Path) {
    foreach ($k in @($global:T.Nodes.Keys | Where-Object { $_ -like "$Path^*" })) { $global:T.Nodes.Remove($k) }
    $i = $Path.LastIndexOf('^')
    if ($i -gt 0 -and $global:T.Nodes.ContainsKey($Path.Substring(0, $i))) { $global:T.Nodes[$Path.Substring(0, $i)].Kids.Remove($Path) }
    $global:T.Nodes.Remove($Path)
}

# ConsumeXml as XAE did it in the probes: every leaf of the fragment that exists in the node XML gets the
# new text; unknown elements are ignored (S_OK).
function Merge-MockXml($Node, [string]$Fragment) {
    $doc = New-Object System.Xml.XmlDocument; $doc.LoadXml($Node.Xml)
    $f = New-Object System.Xml.XmlDocument; $f.LoadXml($Fragment)
    foreach ($leaf in $f.SelectNodes('//*[not(*)]')) {
        $names = @(); $q = $leaf
        while ($null -ne $q -and $q -ne $f.DocumentElement) { $names = @($q.Name) + $names; $q = $q.ParentNode }
        $t = $doc.DocumentElement
        foreach ($nm in $names) { if ($null -ne $t) { $t = $t.SelectSingleNode($nm) } }
        if ($null -ne $t) { $t.InnerText = $leaf.InnerText }
    }
    $Node.Xml = $doc.OuterXml
}

function Reset-MockTree([string]$Root) {
    if (-not [string]::IsNullOrEmpty($Root)) { Remove-Item -LiteralPath (Join-Path $Root '.tcauto-backup') -Recurse -Force -ErrorAction SilentlyContinue }
    $global:T.Nodes = @{}
    $global:T.Mods = [System.Collections.ArrayList]::new()
    $global:T.OnCreate = $null
    $global:T.OnConsume = $null
    $global:T.Dialog = $null
    $global:T.LastXml = $null
    $global:T.Mode = 'ok'
}

function New-MockSysManager {
    $sm = New-Object PSObject
    $sm | Add-Member ScriptMethod LookupTreeItem {
        param($p)
        if (-not $global:T.Nodes.ContainsKey($p)) { throw (New-ComError "Item '$p' not found" ([int]0x98510001)) }
        Write-Output -NoEnumerate $global:T.Nodes[$p]
    }
    Write-Output -NoEnumerate $sm
}

function Install-MockModule($Module, [string]$Sln) {
    & $Module {
        param($s)
        $script:TcIdeProcessId = $null; $script:TcIdeConnected = $true; $script:TcSolutionPath = $s
        function script:Assert-TcConnection { }
        function script:Get-TcSysManager { [CmdletBinding()] param([switch]$Refresh) , $global:T.Sm }
        function script:Get-TcIdeModalDialog { [CmdletBinding()] param([int]$ProcessId = 0, [int]$TimeoutSec = 5) $global:T.Dialog }
        function script:Get-TcPlcProjectList { [CmdletBinding()] param($SysManager) @([PSCustomObject]@{ name = 'plc'; nodePath = 'TIPC^plc'; projectPath = 'TIPC^plc^plc Project'; adsPort = 851 }) }
        function script:Resolve-TcPlcProjectPath { [CmdletBinding()] param($SysManager, [switch]$RequireSingle) 'TIPC^plc^plc Project' }
    } $Sln
}

function Get-MockWrites { @($global:T.Mods | Where-Object { $_ -match '^(CreateChild|ConsumeXml|DeleteChild|Link|Unlink|Set|Property) ' }) }

function New-MockDialog { [PSCustomObject]@{ Title = 'Mock dialog'; Text = 'A modal dialog (mock)'; Kind = 'other'; Hwnd = 1; Buttons = @('OK') } }
