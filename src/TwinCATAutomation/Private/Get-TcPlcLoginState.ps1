function Get-TcPlcLoginState {
    <#
    .SYNOPSIS
        Reads whether the IDE is logged in to one PLC project (#188).
    .DESCRIPTION
        1st: ITcPlcOnline.IsLoggedIn of the PLC node "TIPC^<Plc>" (TE1000 TC3 Automation Interface
             v1.7.0 §5.21.1 ITcPlcOnline p.108: property IsLoggedIn, VARIANT_BOOL, get, "Returns
             VARIANT_FALSE if not connected";
             https://download.beckhoff.com/download/document/automation/twincat3/TC3_Automation_Interface_EN.pdf).
             On 4026 the online methods (Login / Logoff ...) are exposed by that node (Exit-TcPlcOnline,
             measured 2026-10-18). Only a real bool counts: a COM property that does not exist reads
             back as $null in PowerShell without an exception, so $null (or anything else) falls
             through to the 2nd source.
        2nd: ProduceXml of the "<Plc> Project" item "TIPC^<Plc>^<Plc> Project":
             TreeItem/IECProjectDef/OnlineSettings/LoggedIn = true | false. TE1000 §6.5.13 (p.240)
             documents the OnlineSettings / Commands of the PLC project through ProduceXml /
             ConsumeXml; the LoggedIn element itself is 實測 2026-11-08, 4026 VS2022 (local UmRT,
             next to <PlcAppState>Run</PlcAppState>).
        Neither readable -> loggedIn = $null (unknown, never guessed).
        IDE_MODAL_DIALOG / IDE_TIMEOUT / IDE_BUSY / IDE_CRASHED (Invoke-TcComRetry) are rethrown;
        any other exception is kept in 'error' and the next source is tried.
    .PARAMETER SysManager
        ITcSysManager (Get-TcSysManager).
    .PARAMETER Plc
        One entry of Get-TcPlcProjectList (name, nodePath, projectPath).
    .OUTPUTS
        PSCustomObject @{ plc (name); loggedIn ($true | $false | $null); source ('IsLoggedIn' |
        'ProduceXml' | $null); error ($null, or the reasons '; '-joined when a source failed) }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $SysManager,

        [Parameter(Mandatory)]
        $Plc
    )

    $sm = $SysManager
    $fatal = 'IDE_MODAL_DIALOG|IDE_TIMEOUT|IDE_BUSY|IDE_CRASHED'
    $name = [string]$Plc.name
    $nodePath = [string]$Plc.nodePath
    if ([string]::IsNullOrWhiteSpace($nodePath) -and -not [string]::IsNullOrWhiteSpace($name)) { $nodePath = "TIPC^$name" }
    $projectPath = [string]$Plc.projectPath
    if ([string]::IsNullOrWhiteSpace($projectPath) -and -not [string]::IsNullOrWhiteSpace($nodePath)) {
        $projectPath = "$nodePath^$(($nodePath -split '\^')[-1]) Project"
    }
    $errors = @()

    # --- 1st: ITcPlcOnline.IsLoggedIn on the PLC node ---
    # No scriptblock indirection for the tree item: "& { $x }" unrolls an ITcSmTreeItem (enumerable).
    try {
        $node = Invoke-TcComRetry -OperationName "LookupTreeItem $nodePath" -ScriptBlock { Write-Output -NoEnumerate $sm.LookupTreeItem($nodePath) }
        if ($null -eq $node) { $errors += "IsLoggedIn: tree item '$nodePath' not found" }
        else {
            $v = Invoke-TcComRetry -OperationName "IsLoggedIn $nodePath" -ScriptBlock { $node.IsLoggedIn }
            if ($v -is [bool]) {
                return [PSCustomObject]@{ plc = $name; loggedIn = [bool]$v; source = 'IsLoggedIn'; error = $null }
            }
            $errors += "IsLoggedIn: not readable on '$nodePath' (read back $(if ($null -eq $v) { 'null' } else { "'$v' ($($v.GetType().Name))" }))"
        }
    }
    catch {
        if ($_.Exception.Message -match $fatal) { throw }
        $errors += "IsLoggedIn: $($_.Exception.Message)"
    }

    # --- 2nd: ProduceXml of the "<Plc> Project" item, IECProjectDef/OnlineSettings/LoggedIn ---
    try {
        $proj = Invoke-TcComRetry -OperationName "LookupTreeItem $projectPath" -ScriptBlock { Write-Output -NoEnumerate $sm.LookupTreeItem($projectPath) }
        if ($null -eq $proj) { $errors += "ProduceXml: tree item '$projectPath' not found" }
        else {
            $xmlText = [string](Invoke-TcComRetry -OperationName "ProduceXml $projectPath" -ScriptBlock { $proj.ProduceXml($false) })
            $state = $null
            if (-not [string]::IsNullOrWhiteSpace($xmlText)) {
                $doc = New-Object System.Xml.XmlDocument
                $doc.LoadXml($xmlText)
                $n = $doc.SelectSingleNode('//IECProjectDef/OnlineSettings/LoggedIn')
                if ($null -ne $n) {
                    $t = ([string]$n.InnerText).Trim()
                    if ($t -ieq 'true') { $state = $true } elseif ($t -ieq 'false') { $state = $false }
                }
            }
            if ($null -ne $state) {
                return [PSCustomObject]@{ plc = $name; loggedIn = $state; source = 'ProduceXml'; error = $(if ($errors.Count -gt 0) { $errors -join '; ' } else { $null }) }
            }
            $errors += "ProduceXml: no IECProjectDef/OnlineSettings/LoggedIn true|false in the XML of '$projectPath'"
        }
    }
    catch {
        if ($_.Exception.Message -match $fatal) { throw }
        $errors += "ProduceXml: $($_.Exception.Message)"
    }

    [PSCustomObject]@{ plc = $name; loggedIn = $null; source = $null; error = ($errors -join '; ') }
}
