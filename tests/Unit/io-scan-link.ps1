# Unit: Invoke-TcIoScan / Set-TcVariableLink / Remove-TcVariableLink (complete-automation-interface task 1.3),
# no IDE / runtime needed. A mock ITcSysManager replaces Get-TcSysManager inside the module scope;
# Get-TcSystemState is mocked too.
#   powershell.exe -NoProfile -File tests/Unit/io-scan-link.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}

$global:M = @{}
& $mod {
    $script:TcIdeProcessId = $null
    function script:Assert-TcConnection { }
    function script:Get-TcSysManager { [CmdletBinding()] param([switch]$Force) , $global:M.Sm }
    function script:Get-TcSystemState { [CmdletBinding()] param([string]$AmsNetId) $global:M.State }
}

$emptyScan = '<?xml version="1.0"?><TreeItem><ItemName>Devices</ItemName><PathName>TIID</PathName><ItemType>17</ItemType><ChildCount>0</ChildCount><DeviceGrpDef><FoundDevices/></DeviceGrpDef></TreeItem>'
$oneScan = '<TreeItem><PathName>TIID</PathName><DeviceGrpDef><FoundDevices><Device><ItemName>Device 1 (EtherCAT)</ItemName><ItemSubType>111</ItemSubType><AddressInfo><Pnp><DeviceDesc>Intel NIC</DeviceDesc></Pnp></AddressInfo></Device></FoundDevices></DeviceGrpDef></TreeItem>'
$plc = 'TIPC^P^P Instance^PlcTask Inputs^MAIN.bIn'
$io = 'TIID^EtherCAT Master^Term 1 (EK1100)^Term 2 (EL1004)^Channel 1^Input'
function MapXml([bool]$WithLink) {
    $l = if ($WithLink) { '<OwnerB Name="TIID^EtherCAT Master^Term 1 (EK1100)^Term 2 (EL1004)"><Link VarA="PlcTask Inputs^MAIN.bIn" VarB="Channel 1^Input"/></OwnerB>' } else { '' }
    "<?xml version=`"1.0`"?><VarLinks><OwnerA Name=`"TIPC^P^P Instance`"><OwnerB Name=`"TINC^NC-Task 1 SAF^Axes^Axis 1`"><Link VarA=`"PlcTask Inputs^GVL.ax.NcToPlc`" VarB=`"Outputs^ToPlc`"/></OwnerB>$l</OwnerA></VarLinks>"
}
function New-NotFound([string]$p) {
    $e = New-Object System.Runtime.InteropServices.COMException("Item '$p' not found", [int]0x98510001)
    $e
}

function New-MockSm {
    param([string[]]$Existing = @($plc, $io), [string]$ScanXml = $emptyScan, [bool]$LinkSticks = $true, [bool]$UnlinkSticks = $true, $LinkThrows = $null)
    $global:M.Existing = @($Existing + 'TIID')
    $global:M.ScanXml = $ScanXml
    $global:M.Linked = $false
    $global:M.LinkSticks = $LinkSticks
    $global:M.UnlinkSticks = $UnlinkSticks
    $global:M.LinkThrows = $LinkThrows
    $global:M.Created = @()
    $global:M.Consumed = @()
    $sm = New-Object PSObject
    $sm | Add-Member ScriptMethod LookupTreeItem {
        param($p)
        if ($global:M.Existing -notcontains $p) { throw (New-NotFound $p) }
        $it = [PSCustomObject]@{ PathName = $p; Name = ($p -split '\^')[-1]; ChildCount = 0 }
        if ($p -eq 'TIID') {
            $it | Add-Member ScriptMethod ProduceXml { param($rec) $global:M.ScanXml }
            $it | Add-Member ScriptMethod CreateChild {
                param($n, $sub, $before, $info)
                $global:M.Created += "$n/$sub"
                $path = "TIID^$n"
                $global:M.Existing += $path
                $d = [PSCustomObject]@{ PathName = $path; Name = $n; ChildCount = 0 }
                $d | Add-Member ScriptMethod ConsumeXml { param($x) $global:M.Consumed += $x; if ($x -match 'ScanBoxes' -and $global:M.ScanBoxesThrows) { throw 'no boxes (mock)' } }
                $d
            }
        }
        $it
    }
    $sm | Add-Member ScriptMethod LinkVariables {
        param($a, $b)
        if ($null -ne $global:M.LinkThrows) { throw $global:M.LinkThrows }
        if ($global:M.LinkSticks) { $global:M.Linked = $true }
    }
    $sm | Add-Member ScriptMethod UnlinkVariables { param($a, $b) if ($global:M.UnlinkSticks) { $global:M.Linked = $false } }
    $sm | Add-Member ScriptMethod ProduceMappingInfo { MapXml $global:M.Linked }
    $global:M.Sm = $sm
}
$run = [PSCustomObject]@{ success = $true; data = [PSCustomObject]@{ state = 'Run'; amsNetId = '1.2.3.4.1.1' } }
$cfg = [PSCustomObject]@{ success = $true; data = [PSCustomObject]@{ state = 'Config'; amsNetId = '1.2.3.4.1.1' } }

try {
    # --- XML parsing ---
    $d = & $mod { ConvertFrom-TcIoScanXml -Xml $args[0] } $oneScan
    Check 'scan-xml-one' (@($d).Count -eq 1 -and $d[0].itemSubType -eq 111 -and $d[0].addressInfoXml -match '^<AddressInfo>' -and $d[0].name -eq 'Device 1 (EtherCAT)') "count=$(@($d).Count)"
    $d = & $mod { ConvertFrom-TcIoScanXml -Xml $args[0] } $emptyScan
    Check 'scan-xml-empty' (@($d).Count -eq 0) "count=$(@($d).Count)"
    $threw = $false; try { & $mod { ConvertFrom-TcIoScanXml -Xml '<VarLinks/>' } } catch { $threw = $true }
    Check 'scan-xml-wrong-node-throws' $threw ''
    $links = & $mod { ConvertFrom-TcMappingInfo -Xml $args[0] } (MapXml $true)
    Check 'mapping-parse' (@($links).Count -eq 2 -and @($links)[1].a -eq $plc -and @($links)[1].b -eq $io) "a=$(@($links)[1].a)"
    Check 'mapping-has-link-reversed' (& $mod { Test-TcMappingHasLink -Links $args[0] -PathA $args[1] -PathB $args[2] } $links $io.ToUpper() $plc) ''
    Check 'mapping-empty' (@(& $mod { ConvertFrom-TcMappingInfo -Xml '' }).Count -eq 0) ''

    # --- TSM_E mapping ---
    Check 'tsm-notfound-hresult' ((& $mod { ConvertTo-TcTsmErrorCode -InputObject $args[0] } (New-NotFound 'x')) -eq 'TREEITEM_NOT_FOUND') ''
    Check 'tsm-invalidtype' ((& $mod { ConvertTo-TcTsmErrorCode -InputObject $args[0] } (New-Object System.Exception 'TSM_E_INVALIDITEMTYPE')) -eq 'LINK_INVALID_ITEM_TYPE') ''
    Check 'tsm-mismatch' ((& $mod { ConvertTo-TcTsmErrorCode -InputObject $args[0] } (New-Object System.Exception 'TSM_E_MISMATCHINGITEMS')) -eq 'LINK_TYPE_MISMATCH') ''
    Check 'tsm-default' ((& $mod { ConvertTo-TcTsmErrorCode -InputObject $args[0] -DefaultCode 'UNLINK_FAILED' } (New-Object System.Exception 'E_FAIL')) -eq 'UNLINK_FAILED') ''

    # --- Invoke-TcIoScan ---
    New-MockSm
    $global:M.State = $run
    $r = Invoke-TcIoScan
    Check 'scan-run-mode-refused' (-not $r.success -and $r.error.code -eq 'IO_SCAN_REQUIRES_CONFIG' -and $r.data.state -eq 'Run' -and $r.error.hint) "code=$($r.error.code)"
    $global:M.State = [PSCustomObject]@{ success = $false; error = [PSCustomObject]@{ code = 'ADS_TARGET_NOT_FOUND'; message = 'x' } }
    $r = Invoke-TcIoScan
    Check 'scan-state-unreadable' (-not $r.success -and $r.error.code -eq 'IO_SCAN_REQUIRES_CONFIG' -and $r.data.stateError -eq 'ADS_TARGET_NOT_FOUND') "code=$($r.error.code)"
    $global:M.State = $cfg
    $r = Invoke-TcIoScan
    Check 'scan-empty' ($r.success -and @($r.data.devices).Count -eq 0 -and $r.data.warning -and -not $r.data.applied) "warning=$($r.data.warning)"
    New-MockSm -ScanXml $oneScan
    $r = Invoke-TcIoScan
    Check 'scan-found-no-apply' ($r.success -and @($r.data.devices).Count -eq 1 -and $global:M.Created.Count -eq 0) "created=$($global:M.Created.Count)"
    $global:M.ScanBoxesThrows = $true
    $r = Invoke-TcIoScan -Apply
    $global:M.ScanBoxesThrows = $false
    Check 'scan-apply' ($r.success -and $r.data.applied -and $global:M.Created[0] -eq 'Device_1/111' -and @($global:M.Consumed | Where-Object { $_ -match '<DeviceDef><AddressInfo>' }).Count -eq 1 -and @($r.data.warnings).Count -eq 1 -and $r.data.devices[0].path -eq 'TIID^Device_1') "created=$($global:M.Created -join ',') path=$($r.data.devices[0].path)"
    New-MockSm -ScanXml '<TreeItem><DeviceGrp/></TreeItem>'
    $r = Invoke-TcIoScan
    Check 'scan-bad-xml' (-not $r.success -and $r.error.code -eq 'IO_SCAN_FAILED') "code=$($r.error.code)"

    # --- Set-TcVariableLink ---
    New-MockSm
    $r = Set-TcVariableLink -PlcVariable $plc -IoChannel $io
    Check 'link-ok' ($r.success -and $r.data.linked -eq $true) "linked=$($r.data.linked)"
    New-MockSm -Existing @($io)
    $r = Set-TcVariableLink -PlcVariable $plc -IoChannel $io
    Check 'link-plc-missing' (-not $r.success -and $r.error.code -eq 'TREEITEM_NOT_FOUND' -and $r.data.missingEnd -eq 'PlcVariable' -and $r.error.hint -match 'PlcVariable' -and -not $global:M.Linked) "end=$($r.data.missingEnd)"
    New-MockSm -Existing @($plc)
    $r = Set-TcVariableLink -PlcVariable $plc -IoChannel $io
    Check 'link-io-missing' (-not $r.success -and $r.error.code -eq 'TREEITEM_NOT_FOUND' -and $r.data.missingEnd -eq 'IoChannel' -and $r.error.hint -match 'IoChannel') "end=$($r.data.missingEnd)"
    New-MockSm -LinkSticks $false
    $r = Set-TcVariableLink -PlcVariable $plc -IoChannel $io
    Check 'link-readback-missing' (-not $r.success -and $r.error.code -eq 'LINK_VERIFY_FAILED' -and $r.data.linked -eq $false) "code=$($r.error.code)"
    New-MockSm -LinkThrows (New-Object System.Exception 'TSM_E_MISMATCHINGITEMS (mock)')
    $r = Set-TcVariableLink -PlcVariable $plc -IoChannel $io
    Check 'link-mismatch' (-not $r.success -and $r.error.code -eq 'LINK_TYPE_MISMATCH' -and $r.error.hint) "code=$($r.error.code)"

    # --- Remove-TcVariableLink ---
    New-MockSm; $global:M.Linked = $true
    $r = Remove-TcVariableLink -PlcVariable $plc -IoChannel $io
    Check 'unlink-ok' ($r.success -and $r.data.removed -and $r.data.wasLinked) "removed=$($r.data.removed)"
    New-MockSm -UnlinkSticks $false; $global:M.Linked = $true
    $r = Remove-TcVariableLink -PlcVariable $plc
    Check 'unlink-readback-still-linked' (-not $r.success -and $r.error.code -eq 'LINK_VERIFY_FAILED' -and @($r.data.remainingLinks).Count -eq 1) "code=$($r.error.code)"
    New-MockSm -Existing @($io)
    $r = Remove-TcVariableLink -PlcVariable $plc -IoChannel $io
    Check 'unlink-plc-missing' (-not $r.success -and $r.error.code -eq 'TREEITEM_NOT_FOUND' -and $r.data.missingEnd -eq 'PlcVariable') "code=$($r.error.code)"
}
catch {
    Check 'no-exception' $false "$($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"
}
"failed: $fail"
exit $fail
