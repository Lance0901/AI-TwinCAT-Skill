# Unit: task 4.1 (complete-automation-interface phase 3): Add-TcNcTask (MCP AddNcTask), Add-TcNcAxis
# (AddNcAxis), Set-TcNcAxisParameter (SetNcAxisParameter), Connect-TcNcAxisToPlc (LinkNcAxis).
# No IDE / runtime: a mock tree that behaves as XAE did in verification/phase3-probe.md questions 1-5
# (one NC task per TINC, 0x98510002 on a second one; duplicate axis names accepted; new axis = Enc
# Simulation encoder / Drive 5 / Ctrl 1; ConsumeXml accepts any value; unknown type numbers leave
# ItemSubTypeName empty; LinkVariables links the whole AXIS_REF struct).
#   powershell.exe -NoProfile -File tests/Unit/nc-axis.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
$env:TCAUTO_STATE_DIR = Join-Path $env:TEMP ("tcauto-unit-state-{0}" -f [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
. (Join-Path $PSScriptRoot 'lib\MockTree.ps1')
$mod = Get-Module TwinCATAutomation
$fail = 0

$Root = Join-Path $env:TEMP ("tcauto-unit-nc-{0}" -f [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $Root -Force
$Sln = Join-Path $Root 'Nc.sln'
[System.IO.File]::WriteAllText($Sln, '')
$Task = 'TINC^NC-Task 1 SAF'
$Axes = "$Task^Axes"

$SubTypeNames = @{ Enc = @{ 0 = 'Simulation encoder'; 1 = 'Simulation encoder'; 4 = 'KL5101' }; Drive = @{ 5 = 'KL4XXX'; 7 = 'Two speed drive' }; Ctrl = @{ 1 = 'Position controller P'; 2 = 'PID' } }
function New-AxisXml([string]$Path, [int]$Id, [int]$Enc = 1, [int]$Drv = 5, [int]$Ctr = 1) {
    $name = ($Path -split '\^')[-1]
    "<TreeItem><ItemName>$name</ItemName><PathName>$Path</PathName><ItemType>22</ItemType><ItemId>$Id</ItemId><NcAxisDef><AxisType>1</AxisType><AxisParam><Dynamic><Acceleration>1500</Acceleration><Deceleration>1500</Deceleration><Jerk>2250</Jerk><AccelerationMaximum>15000</AccelerationMaximum><DecelerationMaximum>15000</DecelerationMaximum></Dynamic><Velo><Fast>2000</Fast><Maximum>2000</Maximum></Velo></AxisParam><Encoder><EncType>$Enc</EncType></Encoder><Drive><DrvType>$Drv</DrvType></Drive><Controller><CtrType>$Ctr</CtrType></Controller></NcAxisDef></TreeItem>"
}
function Add-MockAxis([string]$Path, [int]$Sub = 1, [int]$Id = 1, [int]$Enc = 1) {
    $a = Add-MockNode $Path 22 (New-AxisXml $Path $Id $Enc) $Sub 'Continuous Axis'
    $null = Add-MockNode "$Path^Enc" 23 '' $Enc $SubTypeNames.Enc[$Enc]
    $null = Add-MockNode "$Path^Drive" 24 '' 5 'KL4XXX'
    $null = Add-MockNode "$Path^Ctrl" 25 '' 1 'Position controller P'
    $null = Add-MockNode "$Path^Inputs" 8
    $null = Add-MockNode "$Path^Inputs^FromPlc" 7
    $null = Add-MockNode "$Path^Outputs" 8
    $null = Add-MockNode "$Path^Outputs^ToPlc" 7
    Write-Output -NoEnumerate $a
}
# Type switch as XAE did it: the child's ItemSubType follows, an unknown number gets an empty name
$OnConsumeAxis = {
    param($Node, $Xml)
    if ($global:T.Mode -eq 'consume-ignore') { return $true }
    if ($Node.ItemType -ne 22) { return $false }
    Merge-MockXml -Node $Node -Fragment $Xml
    $d = New-Object System.Xml.XmlDocument; $d.LoadXml($Node.Xml)
    foreach ($pair in @(@('Enc', 'Encoder/EncType'), @('Drive', 'Drive/DrvType'), @('Ctrl', 'Controller/CtrType'))) {
        $v = [int]$d.SelectSingleNode("TreeItem/NcAxisDef/$($pair[1])").InnerText
        $c = $global:T.Nodes["$($Node.PathName)^$($pair[0])"]
        $c.ItemSubType = $v
        $c.ItemSubTypeName = if ($SubTypeNames[$pair[0]].ContainsKey($v)) { $SubTypeNames[$pair[0]][$v] } else { '' }
    }
    if ($global:T.Mode -eq 'consume-zero') { $Node.Xml = $Node.Xml -replace '<Maximum>[^<]*</Maximum>', '<Maximum>0</Maximum>' }
    return $true
}
$OnCreate = {
    param($Parent, $Name, $Sub, $Before, $VInfo)
    if ($Parent.PathName -eq 'TINC') {
        if (@($Parent.Kids).Count -gt 0) { throw (New-ComError 'Item already exists!' ([int]0x98510002)) }
        $p = "TINC^$Name SAF"
        $tt = Add-MockNode $p 1
        if ($global:T.Mode -ne 'task-no-axes') { $null = Add-MockNode "$p^Axes" 20 }
        return $tt
    }
    if ($Parent.PathName -like '*^Axes') {
        if (@(0, 8) -contains [int]$Sub) { throw (New-ComError 'Invalid item sub type' ([int]0x98510003)) }
        $enc = if ($global:T.Mode -eq 'enc-real') { 4 } else { 1 }
        return (Add-MockAxis "$($Parent.PathName)^$Name" ([int]$Sub) (@($Parent.Kids).Count + 1) $enc)
    }
    throw (New-ComError 'Not implemented (mock)' -2147467263)
}
function Reset-Mock([switch]$NoTask, [string]$Instance = 'plc Instance') {
    Reset-MockTree $Root
    $global:T.Links = [System.Collections.ArrayList]::new()
    $global:T.OnCreate = $OnCreate
    $global:T.OnConsume = $OnConsumeAxis
    $null = Add-MockNode 'TINC' 19
    if (-not $NoTask) {
        $null = Add-MockNode $Task 1
        $null = Add-MockNode $Axes 20
        $null = Add-MockAxis "$Axes^Axis 1" 1 1
    }
    $null = Add-MockNode 'TIRT'
    $null = Add-MockNode 'TIRT^OtherTask' 1
    $null = Add-MockNode 'TIRT^PlcTask' 1
    $null = Add-MockNode 'TIPC'
    $null = Add-MockNode 'TIPC^plc' 56
    $null = Add-MockNode 'TIPC^plc^plc Project' 600
    $null = Add-MockNode "TIPC^plc^$Instance" 57
    $null = Add-MockNode "TIPC^plc^$Instance^PlcTask Inputs" 8
    $null = Add-MockNode "TIPC^plc^$Instance^PlcTask Inputs^MAIN.axis.NcToPlc" 7
    $null = Add-MockNode "TIPC^plc^$Instance^PlcTask Outputs" 8
    $null = Add-MockNode "TIPC^plc^$Instance^PlcTask Outputs^MAIN.axis.PlcToNc" 7
}
$sm = New-MockSysManager
$sm | Add-Member ScriptMethod ProduceMappingInfo {
    $x = '<VarLinks>'
    foreach ($l in $global:T.Links) {
        $ia = $l.a.IndexOf('^'); $ib = $l.b.IndexOf('^')
        $x += "<OwnerA Name=`"$($l.a.Substring(0, $ia))`"><OwnerB Name=`"$($l.b.Substring(0, $ib))`"><Link VarA=`"$($l.a.Substring($ia + 1))`" VarB=`"$($l.b.Substring($ib + 1))`"/></OwnerB></OwnerA>"
    }
    $x + '</VarLinks>'
}
$sm | Add-Member ScriptMethod LinkVariables {
    param($a, $b)
    $global:T.Mods.Add("LinkVariables $a|$b") | Out-Null
    if ($global:T.Mode -eq 'link-fail-2' -and @($global:T.Links).Count -ge 1) { throw (New-ComError "'$a' and '$b' do not match" ([int]0x98510004)) }
    if ($global:T.Mode -eq 'link-noop') { return }
    # review S7: a modal dialog shows up after the first link
    if ($global:T.Mode -like 'dialog-after-1*') { $global:T.Dialog = New-MockDialog }
    $null = $global:T.Links.Add([PSCustomObject]@{ a = $a; b = $b })
}
$sm | Add-Member ScriptMethod UnlinkVariables {
    param($a, $b)
    $global:T.Mods.Add("UnlinkVariables $a|$b") | Out-Null
    if ($global:T.Mode -eq 'dialog-after-1-unlink-noop') { return }
    foreach ($l in @($global:T.Links)) { if ($l.a -eq $a -and $l.b -eq $b) { $global:T.Links.Remove($l) } }
}
$global:T.Sm = $sm
Install-MockModule $mod $Sln
function Get-CodeChanged { & $mod { $e = Get-TcBuildRequired; if ($null -eq $e) { return $null }; (Get-TcBuildRequiredReasons $e)['code-changed'] } }
function Reset-BuildRequired { & $mod { $null = Clear-TcBuildRequired } }
$PlcIn = 'TIPC^plc^plc Instance^PlcTask Inputs^MAIN.axis.NcToPlc'
$PlcOut = 'TIPC^plc^plc Instance^PlcTask Outputs^MAIN.axis.PlcToNc'

try {
    # ===== Add-TcNcTask
    Reset-Mock; Reset-BuildRequired
    $r = Add-TcNcTask
    Check 'AddNcTask: a task exists -> NC_TASK_ALREADY_EXISTS, nothing written, hint names Add-TcNcAxis' ($r.error.code -eq 'NC_TASK_ALREADY_EXISTS' -and @($r.data.existingTasks) -contains $Task -and (Get-MockWrites).Count -eq 0 -and $r.error.hint -match 'Add-TcNcAxis') (J $r)
    Reset-Mock -NoTask; Reset-BuildRequired
    $r = Add-TcNcTask
    Check 'AddNcTask dry-run: success, nothing created, no BUILD_REQUIRED' ($r.success -and $r.data.dryRun -and (Get-MockWrites).Count -eq 0 -and $null -eq (Get-CodeChanged)) (J $r)
    $r = Add-TcNcTask -Name 'a^b'
    Check 'AddNcTask name with ^ -> INVALID_PARAMS' ($r.error.code -eq 'INVALID_PARAMS') (J $r.error)
    $r = Add-TcNcTask -DryRun $false
    Check 'AddNcTask live: success, SAF name read back, axesPath, warning about the name' ($r.success -and $r.data.taskPath -eq 'TINC^NC-Task 1 SAF' -and $r.data.axesPath -eq 'TINC^NC-Task 1 SAF^Axes' -and @($r.data.warnings | Where-Object { $_ -like '*NC-Task 1 SAF*' }).Count -eq 1) (J $r)
    Check 'AddNcTask live: backup of TINC written, BUILD_REQUIRED recorded' ((Test-Path -LiteralPath ([string]$r.data.backupPath)) -and (Get-CodeChanged) -match 'Add-TcNcTask') "$($r.data.backupPath) $(Get-CodeChanged)"
    # XAE refusing with 0x98510002 (a task appeared between the check and the call)
    Reset-Mock -NoTask; Reset-BuildRequired
    $global:T.OnCreate = { param($Parent, $Name, $Sub, $Before, $VInfo) throw (New-ComError 'Item already exists!' ([int]0x98510002)) }
    $r = Add-TcNcTask -DryRun $false
    Check 'AddNcTask XAE 0x98510002 -> NC_TASK_ALREADY_EXISTS, recorded (CreateChild was called)' ($r.error.code -eq 'NC_TASK_ALREADY_EXISTS' -and (Get-CodeChanged) -match 'failed') (J $r.error)
    Reset-Mock -NoTask; Reset-BuildRequired; $global:T.Mode = 'task-no-axes'
    $r = Add-TcNcTask -DryRun $false
    Check 'AddNcTask readback without Axes -> NC_TASK_VERIFY_FAILED, rolled back' ($r.error.code -eq 'NC_TASK_VERIFY_FAILED' -and $r.data.rolledBack -and -not $global:T.Nodes.ContainsKey('TINC^NC-Task 1 SAF')) (J $r)
    Reset-Mock -NoTask; Reset-BuildRequired; $global:T.Dialog = New-MockDialog
    $r = Add-TcNcTask -DryRun $false
    Check 'AddNcTask modal dialog -> IDE_MODAL_DIALOG, nothing created, nothing recorded' ($r.error.code -eq 'IDE_MODAL_DIALOG' -and (Get-MockWrites).Count -eq 0 -and $null -eq (Get-CodeChanged)) (J $r.error)

    # ===== Add-TcNcAxis
    Reset-Mock -NoTask; Reset-BuildRequired
    $r = Add-TcNcAxis -Name 'Axis 2'
    Check 'AddNcAxis without NC task -> NC_TASK_NOT_FOUND, hint Add-TcNcTask' ($r.error.code -eq 'NC_TASK_NOT_FOUND' -and $r.error.hint -match 'Add-TcNcTask') (J $r.error)
    Reset-Mock; Reset-BuildRequired
    $r = Add-TcNcAxis -Name 'axis 1'
    Check 'AddNcAxis same name (other case) -> NC_AXIS_ALREADY_EXISTS, nothing created' ($r.error.code -eq 'NC_AXIS_ALREADY_EXISTS' -and (Get-MockWrites).Count -eq 0) (J $r)
    $r = Add-TcNcAxis -Name 'Axis 2'
    Check 'AddNcAxis dry-run: plan, nothing created' ($r.success -and $r.data.dryRun -and $r.data.axesPath -eq $Axes -and (Get-MockWrites).Count -eq 0 -and $r.data.subType -eq 1) (J $r)
    $r = Add-TcNcAxis -Name 'Axis 2' -Task 'NoSuchTask'
    Check 'AddNcAxis unknown -Task -> NC_TASK_NOT_FOUND' ($r.error.code -eq 'NC_TASK_NOT_FOUND') (J $r.error)
    $r = Add-TcNcAxis -Name 'Axis 2' -DryRun $false
    Check 'AddNcAxis live: success, simulation encoder read back, axisId, drive/controller' ($r.success -and $r.data.simulation -and $r.data.axisPath -eq "$Axes^Axis 2" -and $r.data.axisId -eq 2 -and $r.data.encoder.subType -eq 1 -and $r.data.drive.subType -eq 5 -and $r.data.controller.subType -eq 1) (J $r)
    Check 'AddNcAxis live: CreateChild subType 1 on Axes, BUILD_REQUIRED' ((Get-MockWrites) -contains "CreateChild $Axes^Axis 2/1" -and (Get-CodeChanged) -match 'Add-TcNcAxis') ((Get-MockWrites) -join ';')
    Reset-Mock; Reset-BuildRequired
    $r = Add-TcNcAxis -Name 'Axis E' -AxisType Encoder -DryRun $false
    Check 'AddNcAxis -AxisType Encoder -> CreateChild subType 5' ($r.success -and (Get-MockWrites) -contains "CreateChild $Axes^Axis E/5") ((Get-MockWrites) -join ';')
    Reset-Mock; Reset-BuildRequired; $global:T.Mode = 'enc-real'
    $r = Add-TcNcAxis -Name 'Axis 3' -DryRun $false
    Check 'AddNcAxis encoder is not simulation -> NC_AXIS_VERIFY_FAILED, rolled back, recorded' ($r.error.code -eq 'NC_AXIS_VERIFY_FAILED' -and $r.data.rolledBack -and -not $global:T.Nodes.ContainsKey("$Axes^Axis 3") -and @($r.data.mismatches | Where-Object { $_.field -eq 'Enc' }).Count -eq 1 -and (Get-CodeChanged) -match 'verify') (J $r)
    Reset-Mock; Reset-BuildRequired; $global:T.Dialog = New-MockDialog
    $r = Add-TcNcAxis -Name 'Axis 3' -DryRun $false
    Check 'AddNcAxis modal dialog -> IDE_MODAL_DIALOG, nothing recorded' ($r.error.code -eq 'IDE_MODAL_DIALOG' -and $null -eq (Get-CodeChanged)) (J $r.error)

    # ===== Set-TcNcAxisParameter
    Reset-Mock; Reset-BuildRequired
    $r = Set-TcNcAxisParameter -Axis 'Axis 1'
    Check 'SetNcAxisParameter no field -> INVALID_PARAMS' ($r.error.code -eq 'INVALID_PARAMS') (J $r.error)
    $r = Set-TcNcAxisParameter -Axis 'Axis 1' -MaxVelocity 0
    Check 'SetNcAxisParameter MaxVelocity 0 -> INVALID_PARAMS before any IDE call' ($r.error.code -eq 'INVALID_PARAMS' -and (Get-MockWrites).Count -eq 0) (J $r.error)
    $r = Set-TcNcAxisParameter -Axis 'Axis 1' -Acceleration ([double]::NaN)
    Check 'SetNcAxisParameter NaN -> INVALID_PARAMS' ($r.error.code -eq 'INVALID_PARAMS') (J $r.error)
    $r = Set-TcNcAxisParameter -Axis 'Axis 1' -DriveType 19
    Check 'SetNcAxisParameter DriveType 19 (no name in XAE) -> NC_INVALID_SUBTYPE, allowedTypes' ($r.error.code -eq 'NC_INVALID_SUBTYPE' -and @($r.data.allowedTypes) -contains 24 -and (Get-MockWrites).Count -eq 0) (J $r.error)
    $r = Set-TcNcAxisParameter -Axis 'Axis 9' -MaxVelocity 100
    Check 'SetNcAxisParameter unknown axis -> NC_AXIS_NOT_FOUND with ncAxes' ($r.error.code -eq 'NC_AXIS_NOT_FOUND' -and @($r.data.ncAxes) -contains "$Axes^Axis 1") (J $r)
    $r = Set-TcNcAxisParameter -Axis 'Axis 1' -MaxVelocity 1234.5 -Acceleration 77
    Check 'SetNcAxisParameter dry-run: changes with current / planned, fragment, nothing written' ($r.success -and $r.data.dryRun -and (Get-MockWrites).Count -eq 0 -and @($r.data.changes | Where-Object { $_.parameter -eq 'MaxVelocity' -and $_.current -eq '2000' -and $_.planned -eq '1234.5' -and $_.changed }).Count -eq 1 -and $r.data.xml -eq '<TreeItem><NcAxisDef><AxisParam><Velo><Maximum>1234.5</Maximum></Velo><Dynamic><Acceleration>77</Acceleration></Dynamic></AxisParam></NcAxisDef></TreeItem>') (J $r.data)
    $r = Set-TcNcAxisParameter -Axis 'Axis 1' -MaxVelocity 2000
    Check 'SetNcAxisParameter same value -> success written=false' ($r.success -and $r.data.written -eq $false) (J $r.data)
    $r = Set-TcNcAxisParameter -Axis 'Axis 1' -MaxVelocity 1234.5 -Acceleration 77 -DryRun $false
    $x = $global:T.Nodes["$Axes^Axis 1"].Xml
    Check 'SetNcAxisParameter live: success, verified, values in the axis XML, backup' ($r.success -and $r.data.verified -and $x -match '<Maximum>1234.5</Maximum>' -and $x -match '<Acceleration>77</Acceleration>' -and (Test-Path -LiteralPath ([string]$r.data.backupPath))) (J $r.data)
    Check 'SetNcAxisParameter live: BUILD_REQUIRED recorded' ((Get-CodeChanged) -match 'Set-TcNcAxisParameter') "$(Get-CodeChanged)"
    Reset-Mock; Reset-BuildRequired; $global:T.Mode = 'consume-ignore'
    $r = Set-TcNcAxisParameter -Axis 'Axis 1' -MaxVelocity 1500 -DryRun $false
    Check 'SetNcAxisParameter XAE ignores the write (S_OK) -> NC_AXIS_PARAM_VERIFY_FAILED, recorded' ($r.error.code -eq 'NC_AXIS_PARAM_VERIFY_FAILED' -and @($r.data.mismatches)[0].actual -eq '2000' -and (Get-CodeChanged) -match 'verify') (J $r)
    Reset-Mock; Reset-BuildRequired; $global:T.Mode = 'consume-zero'
    $r = Set-TcNcAxisParameter -Axis 'Axis 1' -MaxVelocity 1500 -DryRun $false
    Check 'SetNcAxisParameter readback 0 (like abc -> 0) -> NC_AXIS_PARAM_VERIFY_FAILED' ($r.error.code -eq 'NC_AXIS_PARAM_VERIFY_FAILED') (J $r.error)
    Reset-Mock; Reset-BuildRequired
    $r = Set-TcNcAxisParameter -Axis 'Axis 1' -DriveType 7 -DryRun $false
    Check 'SetNcAxisParameter DriveType 7 -> success, drive subType 7 named' ($r.success -and $r.data.drive.subType -eq 7 -and $r.data.drive.subTypeName -eq 'Two speed drive') (J $r.data)
    Reset-Mock; Reset-BuildRequired
    $r = Set-TcNcAxisParameter -Axis 'Axis 1' -ControllerType 3 -DryRun $false
    $ctr = $global:T.Nodes["$Axes^Axis 1^Ctrl"]
    Check 'SetNcAxisParameter type stored without a name -> NC_INVALID_SUBTYPE, previous type sent back' ($r.error.code -eq 'NC_INVALID_SUBTYPE' -and $r.data.reverted -and $ctr.ItemSubType -eq 1 -and @(Get-MockWrites | Where-Object { $_ -like 'ConsumeXml*' }).Count -eq 2) "$(J $r.data) sub=$($ctr.ItemSubType)"
    Reset-Mock; Reset-BuildRequired
    $global:T.Nodes["$Axes^Axis 1"].Xml = $global:T.Nodes["$Axes^Axis 1"].Xml -replace '<Jerk>2250</Jerk>', ''
    $r = Set-TcNcAxisParameter -Axis 'Axis 1' -Jerk 10 -DryRun $false
    Check 'SetNcAxisParameter field not in ProduceXml -> NC_AXIS_PARAM_NOT_FOUND, nothing written' ($r.error.code -eq 'NC_AXIS_PARAM_NOT_FOUND' -and (Get-MockWrites).Count -eq 0) (J $r)
    Reset-Mock; Reset-BuildRequired
    # duplicate names (XAE allows them): two children named 'Axis 1'
    $dup = Add-MockAxis "$Axes^Axis 1#2" 1 8
    $dup.Name = 'Axis 1'
    $r = Set-TcNcAxisParameter -Axis 'Axis 1' -MaxVelocity 10
    Check 'SetNcAxisParameter two axes with that name -> NC_AXIS_AMBIGUOUS' ($r.error.code -eq 'NC_AXIS_AMBIGUOUS') (J $r.error)
    Reset-Mock; Reset-BuildRequired; $global:T.Dialog = New-MockDialog
    $r = Set-TcNcAxisParameter -Axis "$Axes^Axis 1" -MaxVelocity 10 -DryRun $false
    Check 'SetNcAxisParameter modal dialog -> IDE_MODAL_DIALOG, nothing written / recorded' ($r.error.code -eq 'IDE_MODAL_DIALOG' -and (Get-MockWrites).Count -eq 0 -and $null -eq (Get-CodeChanged)) (J $r.error)

    # ===== Connect-TcNcAxisToPlc
    Reset-Mock; Reset-BuildRequired
    $r = Connect-TcNcAxisToPlc -Axis 'Axis 1' -PlcVariable 'MAIN.axis.NcToPlc'
    Check 'LinkNcAxis -PlcVariable with .NcToPlc -> INVALID_PARAMS' ($r.error.code -eq 'INVALID_PARAMS') (J $r.error)
    $r = Connect-TcNcAxisToPlc -Axis 'Axis 1' -PlcVariable 'MAIN.other'
    Check 'LinkNcAxis AXIS_REF not in the image -> NC_PLC_VARIABLE_NOT_FOUND, hint Build-TcProject' ($r.error.code -eq 'NC_PLC_VARIABLE_NOT_FOUND' -and $r.error.hint -match 'Build-TcProject' -and @($r.data.triedPaths) -contains 'TIPC^plc^plc Instance^PlcTask Inputs^MAIN.other.NcToPlc' -and @($r.data.tasks) -contains 'PlcTask') (J $r)
    $r = Connect-TcNcAxisToPlc -Axis 'Axis 1' -PlcVariable 'MAIN.axis'
    Check 'LinkNcAxis dry-run: both pairs planned, nothing linked' ($r.success -and $r.data.dryRun -and @($r.data.links | Where-Object { $_.state -eq 'missing' }).Count -eq 2 -and @($global:T.Links).Count -eq 0 -and @($r.data.links)[0].plc -eq $PlcIn -and @($r.data.links)[0].nc -eq "$Axes^Axis 1^Outputs^ToPlc") (J $r.data)
    $r = Connect-TcNcAxisToPlc -Axis 'Axis 1' -PlcVariable 'MAIN.axis' -DryRun $false
    Check 'LinkNcAxis live: two LinkVariables, mapping read back, linked, backup, BUILD_REQUIRED' ($r.success -and $r.data.linked -and @($global:T.Links).Count -eq 2 -and (Test-Path -LiteralPath ([string]$r.data.backupPath)) -and (Get-CodeChanged) -match 'Connect-TcNcAxisToPlc') (J $r.data)
    Check 'LinkNcAxis live: PlcToNc linked to Inputs^FromPlc' (@($global:T.Links | Where-Object { $_.a -eq $PlcOut -and $_.b -eq "$Axes^Axis 1^Inputs^FromPlc" }).Count -eq 1) (J $global:T.Links)
    $r = Connect-TcNcAxisToPlc -Axis 'Axis 1' -PlcVariable 'MAIN.axis' -DryRun $false
    Check 'LinkNcAxis again -> alreadyLinked, no LinkVariables' ($r.success -and $r.data.alreadyLinked -and @($global:T.Mods | Where-Object { $_ -like 'LinkVariables*' }).Count -eq 2) (J $r.data)
    Reset-Mock; Reset-BuildRequired
    $null = $global:T.Links.Add([PSCustomObject]@{ a = $PlcIn; b = "$Axes^Axis 7^Outputs^ToPlc" })
    $r = Connect-TcNcAxisToPlc -Axis 'Axis 1' -PlcVariable 'MAIN.axis' -DryRun $false
    Check 'LinkNcAxis PLC end linked to another axis -> NC_AXIS_ALREADY_LINKED, hint Remove-TcVariableLink' ($r.error.code -eq 'NC_AXIS_ALREADY_LINKED' -and @($r.data.existingLinks).Count -ge 1 -and $r.error.hint -match 'Remove-TcVariableLink' -and @($global:T.Mods | Where-Object { $_ -like 'LinkVariables*' }).Count -eq 0) (J $r)
    Reset-Mock; Reset-BuildRequired; $global:T.Mode = 'link-fail-2'
    $r = Connect-TcNcAxisToPlc -Axis 'Axis 1' -PlcVariable 'MAIN.axis' -DryRun $false
    Check 'LinkNcAxis second link refused -> LINK_TYPE_MISMATCH, first link removed again, recorded' ($r.error.code -eq 'LINK_TYPE_MISMATCH' -and $r.data.rolledBack -and @($global:T.Links).Count -eq 0 -and @($global:T.Mods | Where-Object { $_ -like 'UnlinkVariables*' }).Count -eq 1 -and (Get-CodeChanged) -match 'failed') (J $r)
    Reset-Mock; Reset-BuildRequired; $global:T.Mode = 'link-noop'
    $r = Connect-TcNcAxisToPlc -Axis 'Axis 1' -PlcVariable 'MAIN.axis' -DryRun $false
    Check 'LinkNcAxis LinkVariables returns but mapping lacks it -> LINK_VERIFY_FAILED' ($r.error.code -eq 'LINK_VERIFY_FAILED' -and $r.data.linked -eq $false) (J $r.error)
    Reset-Mock; Reset-BuildRequired; $global:T.Dialog = New-MockDialog
    $r = Connect-TcNcAxisToPlc -Axis 'Axis 1' -PlcVariable 'MAIN.axis' -DryRun $false
    Check 'LinkNcAxis modal dialog -> IDE_MODAL_DIALOG, nothing linked / recorded' ($r.error.code -eq 'IDE_MODAL_DIALOG' -and @($global:T.Links).Count -eq 0 -and $null -eq (Get-CodeChanged)) (J $r.error)

    # ===== review fixes
    # N1: the HRESULT decides, not the English text
    Reset-Mock -NoTask; Reset-BuildRequired
    $global:T.OnCreate = { param($Parent, $Name, $Sub, $Before, $VInfo) throw (New-ComError 'localized text without the English words' ([int]0x98510002)) }
    $r = Add-TcNcTask -DryRun $false
    Check 'N1 AddNcTask: 0x98510002 with another text -> NC_TASK_ALREADY_EXISTS, data.hresultHex' ($r.error.code -eq 'NC_TASK_ALREADY_EXISTS' -and $r.data.hresultHex -eq '0x98510002') (J $r)
    # S8: two axes with the same path
    Reset-Mock; Reset-BuildRequired
    $dup = Add-MockAxis "$Axes^Axis 1#2" 1 8
    $dup.Name = 'Axis 1'
    $r = Set-TcNcAxisParameter -Axis "$Axes^Axis 1" -MaxVelocity 10
    Check 'S8 path of a duplicate axis -> NC_AXIS_AMBIGUOUS' ($r.error.code -eq 'NC_AXIS_AMBIGUOUS' -and (Get-MockWrites).Count -eq 0) (J $r.error)
    # S9: contradicting values are warnings, not refusals
    Reset-Mock; Reset-BuildRequired
    $r = Set-TcNcAxisParameter -Axis 'Axis 1' -MaxVelocity 1000 -Acceleration 20000
    Check 'S9 MaxVelocity below Velo/Fast and Acceleration above AccelerationMaximum -> warnings, still planned' ($r.success -and @($r.data.warnings | Where-Object { $_ -like '*Velo/Fast*' }).Count -eq 1 -and @($r.data.warnings | Where-Object { $_ -like '*AccelerationMaximum*' }).Count -eq 1) (J $r.data.warnings)
    $r = Set-TcNcAxisParameter -Axis 'Axis 1' -MaxVelocity 2500
    Check 'S9 consistent values -> no warning' ($r.success -and $null -eq $r.data.PSObject.Properties['warnings']) (J $r.data)
    # S9: the type revert is read back
    Reset-Mock; Reset-BuildRequired
    $global:T.OnConsume = {
        param($Node, $Xml)
        if ($Node.ItemType -ne 22) { return $false }
        $global:T.ConsumeCount = 1 + [int]$global:T.ConsumeCount
        if ($global:T.ConsumeCount -ge 2) { return $true }   # the revert is ignored
        & $OnConsumeAxis $Node $Xml
    }
    $global:T.ConsumeCount = 0
    $r = Set-TcNcAxisParameter -Axis 'Axis 1' -ControllerType 3 -DryRun $false
    Check 'S9 revert ignored by XAE -> reverted false, revertError says it does not read back' ($r.error.code -eq 'NC_INVALID_SUBTYPE' -and $r.data.reverted -eq $false -and $r.data.revertError -match 'does not read back') (J $r.data)
    # S7: modal dialog before the second link -> the first is removed and read back
    Reset-Mock; Reset-BuildRequired; $global:T.Mode = 'dialog-after-1'
    $r = Connect-TcNcAxisToPlc -Axis 'Axis 1' -PlcVariable 'MAIN.axis' -DryRun $false
    Check 'S7 dialog before the 2nd link -> IDE_MODAL_DIALOG, partialLinks, unlinked, rolledBack true' ($r.error.code -eq 'IDE_MODAL_DIALOG' -and @($r.data.partialLinks).Count -eq 1 -and $r.data.rolledBack -eq $true -and @($global:T.Links).Count -eq 0 -and (Get-CodeChanged) -match 'failed') (J $r)
    Reset-Mock; Reset-BuildRequired; $global:T.Mode = 'dialog-after-1-unlink-noop'
    $r = Connect-TcNcAxisToPlc -Axis 'Axis 1' -PlcVariable 'MAIN.axis' -DryRun $false
    Check 'S7 unlink without effect -> rolledBack false (mapping still has the link)' ($r.error.code -eq 'IDE_MODAL_DIALOG' -and $r.data.rolledBack -eq $false -and @($global:T.Links).Count -eq 1) (J $r.data)
    # N5: a member of the struct linked on its own
    Reset-Mock; Reset-BuildRequired
    $null = $global:T.Links.Add([PSCustomObject]@{ a = "$PlcIn.ActPos"; b = 'TIID^Dev^Term^Ch^In' })
    $r = Connect-TcNcAxisToPlc -Axis 'Axis 1' -PlcVariable 'MAIN.axis' -DryRun $false
    Check 'N5 member-level link (NcToPlc.ActPos) -> NC_AXIS_ALREADY_LINKED' ($r.error.code -eq 'NC_AXIS_ALREADY_LINKED') (J $r.error)
    # N6: the PLC instance node is read from the tree
    Reset-Mock -Instance 'MyRenamedInstance'; Reset-BuildRequired
    $r = Connect-TcNcAxisToPlc -Axis 'Axis 1' -PlcVariable 'MAIN.axis'
    Check 'N6 renamed PLC instance is found in the tree' ($r.success -and $r.data.instancePath -eq 'TIPC^plc^MyRenamedInstance' -and @($r.data.links)[0].plc -like 'TIPC^plc^MyRenamedInstance^*') (J $r.data)

    # 4.6 B1: real COM - the PLC instance (ItemType 57) enumerates no children (ChildCount 0), only
    # LookupTreeItem of '<instance>^<task> Inputs' works; the names come from the TIRT tasks
    Reset-Mock; Reset-BuildRequired
    $global:T.Nodes['TIPC^plc^plc Instance'].Kids.Clear()
    $r = Connect-TcNcAxisToPlc -Axis 'Axis 1' -PlcVariable 'MAIN.axis'
    Check 'B1 instance enumerates nothing, lookup of <instance>^PlcTask Inputs works -> success' ($r.success -and @($r.data.links)[0].plc -eq $PlcIn -and @($r.data.links)[1].plc -eq $PlcOut -and $r.data.instancePath -eq 'TIPC^plc^plc Instance' -and $null -eq $r.data.PSObject.Properties['warnings']) (J $r)
    $r = Connect-TcNcAxisToPlc -Axis 'Axis 1' -PlcVariable 'MAIN.axis' -DryRun $false
    Check 'B1 instance enumerates nothing -> live link works, two LinkVariables' ($r.success -and $r.data.linked -and @($global:T.Links).Count -eq 2) (J $r.data)
    # the PLC node enumerates nothing either: '<Plc> Instance' is still tried
    Reset-Mock; Reset-BuildRequired
    $global:T.Nodes['TIPC^plc^plc Instance'].Kids.Clear()
    $global:T.Nodes['TIPC^plc'].Kids.Clear()
    $r = Connect-TcNcAxisToPlc -Axis 'Axis 1' -PlcVariable 'MAIN.axis'
    Check 'B1 PLC node and instance enumerate nothing -> <Plc> Instance by lookup, success' ($r.success -and $r.data.instancePath -eq 'TIPC^plc^plc Instance' -and @($r.data.links)[0].plc -eq $PlcIn) (J $r)
    # renamed instance (found by enumerating TIPC^plc) whose children are not enumerable
    Reset-Mock -Instance 'MyRenamedInstance'; Reset-BuildRequired
    $global:T.Nodes['TIPC^plc^MyRenamedInstance'].Kids.Clear()
    $r = Connect-TcNcAxisToPlc -Axis 'Axis 1' -PlcVariable 'MAIN.axis'
    Check 'B1 renamed instance without enumerable children -> found via the task image lookup' ($r.success -and $r.data.instancePath -eq 'TIPC^plc^MyRenamedInstance') (J $r.data)
    # not built yet: nothing below the images -> NC_PLC_VARIABLE_NOT_FOUND lists every tried path
    Reset-Mock; Reset-BuildRequired
    $global:T.Nodes['TIPC^plc^plc Instance'].Kids.Clear()
    $r = Connect-TcNcAxisToPlc -Axis 'Axis 1' -PlcVariable 'MAIN.notBuilt'
    $tp = @($r.data.triedPaths)
    Check 'B1 not found -> NC_PLC_VARIABLE_NOT_FOUND, triedPaths has both tasks (Inputs and Outputs), no instanceChildren' ($r.error.code -eq 'NC_PLC_VARIABLE_NOT_FOUND' -and $tp -contains 'TIPC^plc^plc Instance^OtherTask Inputs^MAIN.notBuilt.NcToPlc' -and $tp -contains 'TIPC^plc^plc Instance^PlcTask Outputs^MAIN.notBuilt.PlcToNc' -and $null -eq $r.data.PSObject.Properties['instanceChildren'] -and $r.error.hint -match 'Build-TcProject') (J $r)
    # no TIRT task at all (and nothing enumerable) -> not found, the tried list says so
    Reset-Mock; Reset-BuildRequired
    $global:T.Nodes['TIPC^plc^plc Instance'].Kids.Clear()
    Remove-MockSubtree 'TIRT'
    $r = Connect-TcNcAxisToPlc -Axis 'Axis 1' -PlcVariable 'MAIN.axis'
    Check 'B1 no task names and no enumerable image -> NC_PLC_VARIABLE_NOT_FOUND, tasks empty' ($r.error.code -eq 'NC_PLC_VARIABLE_NOT_FOUND' -and @($r.data.tasks).Count -eq 0) (J $r)

    # ===== hints / tools.json
    foreach ($c in @('NC_TASK_NOT_FOUND', 'NC_TASK_AMBIGUOUS', 'NC_TASK_ALREADY_EXISTS', 'NC_TASK_VERIFY_FAILED', 'NC_AXIS_ALREADY_EXISTS', 'NC_AXIS_NOT_FOUND', 'NC_AXIS_AMBIGUOUS', 'NC_AXIS_VERIFY_FAILED', 'NC_INVALID_SUBTYPE', 'NC_AXIS_PARAM_NOT_FOUND', 'NC_AXIS_PARAM_WRITE_FAILED', 'NC_AXIS_PARAM_VERIFY_FAILED', 'NC_PLC_VARIABLE_NOT_FOUND', 'NC_AXIS_ALREADY_LINKED')) {
        $h = & $mod { param($k) Get-TcErrorHint -Code $k } $c
        Check "hint $c" (-not [string]::IsNullOrWhiteSpace($h)) "$h"
    }
    $tools = @((Get-Content -Raw -Encoding UTF8 (Join-Path $PSScriptRoot '..\..\mcp-server\tools.json') | ConvertFrom-Json).tools)
    $byName = @{}; foreach ($tt in $tools) { $byName[$tt.name] = $tt }
    foreach ($pair in @(@('AddNcTask', 'Add-TcNcTask'), @('AddNcAxis', 'Add-TcNcAxis'), @('SetNcAxisParameter', 'Set-TcNcAxisParameter'), @('LinkNcAxis', 'Connect-TcNcAxisToPlc'))) {
        $tt = $byName[$pair[0]]
        Check "tools.json $($pair[0]): $($pair[1]), destructive, DryRun default true" ($null -ne $tt -and $tt.cmdlet -eq $pair[1] -and $tt.annotations.destructiveHint -eq $true -and $tt.inputSchema.properties.DryRun.default -eq $true) (J $tt.annotations)
    }
    Check 'tools.json AddNcAxis AxisType enum' (@($byName['AddNcAxis'].inputSchema.properties.AxisType.enum) -contains 'Encoder') (J $byName['AddNcAxis'].inputSchema.properties.AxisType)
}
catch {
    Check 'unexpected-exception' $false "$($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber)"
}
finally {
    & $mod { $script:TcIdeConnected = $false; $script:TcSolutionPath = $null }
    Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $env:TCAUTO_STATE_DIR -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\TCAUTO_STATE_DIR -ErrorAction SilentlyContinue
}

"failed: $fail"
exit [Math]::Min($fail, 255)
