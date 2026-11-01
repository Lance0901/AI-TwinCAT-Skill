# Unit: task 4.2 (complete-automation-interface phase 3): Add-TcComModule (MCP AddTcComModule),
# Get-TcComModuleParameter (GetTcComParameter), Set-TcComModuleParameter (SetTcComParameter),
# Set-TcComModuleContext (SetTcComContext).
# No IDE / runtime: a mock tree and module manager that behave as XAE did in
# verification/phase3-probe.md questions 9-13 (instance renamed '<name> (<type>)', unknown GUID
# 0x98510009, GetModulePara bytes, size mismatch 0x98110705, context index = TMC Context Id with
# 0x80070057 / E_FAIL, online values separate from the project values, 0x9811071D for an unknown oid).
#   powershell.exe -NoProfile -File tests/Unit/tccom-module.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
$env:TCAUTO_STATE_DIR = Join-Path $env:TEMP ("tcauto-unit-state-{0}" -f [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
. (Join-Path $PSScriptRoot 'lib\MockTree.ps1')
$mod = Get-Module TwinCATAutomation
$fail = 0

$Root = Join-Path $env:TEMP ("tcauto-unit-tccom-{0}" -f [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $Root -Force
$Sln = Join-Path $Root 'TcCom.sln'
[System.IO.File]::WriteAllText($Sln, '')
$Folder = 'TIRC^TcCOM Objects'
$NtpGuid = '{7e6d2fda-2d37-4998-a31f-36958d3a2c8a}'
$Ntp = "$Folder^NtpProbe (TcNtpExternalTimeProvider)"
# name, PTCID, BitSize, BaseType, project value
$NtpParams = @(
    @('TimeType', '#x03150001', 32, 'TimeType', 3),
    @('ClientEnable', '#x03150101', 8, 'BOOL', 1),
    @('PollInterval', '#x03150105', 32, 'UDINT', 4321),
    @('Velocity', '#x0509300a', 64, 'LREAL', 2000),
    @('PollTime', '#x03150106', 32, 'TIME', 1000),
    @('ServerName', '#x03150110', 160, 'STRING(19)', 'ntp.example'),
    @('ServerPara', '#x03150120', 128, 'ST_ServerPara', $null),
    @('ModeWord', '#x03150130', 32, 'ST_ModeWord', $null)
)
function New-ModuleXml([string]$Path, [string]$Oid, [int[]]$ContextIds) {
    $name = ($Path -split '\^')[-1]
    $ps = ($NtpParams | ForEach-Object { "<Parameter><Name>$($_[0])</Name><BitSize>$($_[2])</BitSize><BaseType>$($_[3])</BaseType><PTCID>$($_[1])</PTCID></Parameter>" }) -join ''
    $vs = ($NtpParams | Where-Object { $null -ne $_[4] } | ForEach-Object { "<Value><Name>$($_[0])</Name><Value>$($_[4])</Value></Value>" }) -join ''
    $cs = ($ContextIds | ForEach-Object { "<Context><Id>$_</Id></Context>" }) -join ''
    "<TreeItem><ItemName>$name</ItemName><PathName>$Path</PathName><ItemType>48</ItemType><ObjectId>$Oid</ObjectId><TcModuleInstance><DataTypes><DataType><Name GUID=`"{11111111-0000-0000-0000-000000000001}`">TimeType</Name><BitSize>32</BitSize><BaseType>DINT</BaseType><EnumInfo><Text>Low</Text><Enum>1</Enum></EnumInfo></DataType><DataType><Name>ST_ModeWord</Name><BitSize>32</BitSize><SubItem><Name>a</Name></SubItem></DataType></DataTypes><Module GUID=`"{7E6D2FDA-2D37-4998-A31F-36958D3A2C8A}`"><Name>TcNtpExternalTimeProvider</Name><Contexts>$cs</Contexts><Parameters>$ps</Parameters><ParameterValues>$vs</ParameterValues></Module></TcModuleInstance></TreeItem>"
}
function ConvertTo-MockBytes($p) {
    switch ($p[3]) {
        'BOOL' { return , [byte[]]@([byte]$p[4]) }
        'UDINT' { return , [byte[]][BitConverter]::GetBytes([uint32]$p[4]) }
        'TIME' { return , [byte[]][BitConverter]::GetBytes([uint32]$p[4]) }
        'TimeType' { return , [byte[]][BitConverter]::GetBytes([int32]$p[4]) }
        'LREAL' { return , [byte[]][BitConverter]::GetBytes([double]$p[4]) }
        'STRING(19)' { $b = New-Object byte[] 20; $s = [Text.Encoding]::ASCII.GetBytes([string]$p[4]); [Array]::Copy($s, $b, $s.Length); return , $b }
        default { return , (New-Object byte[] 16) }
    }
}
function Add-MockModule([string]$Path, [string]$Oid = '#x01010010', [int[]]$ContextIds = @(1)) {
    $n = Add-MockNode $Path 48 (New-ModuleXml $Path $Oid $ContextIds) -1 ''
    $n.Props.Params = @{}
    $n.Props.Online = @{}
    $n.Props.Context = @{}
    foreach ($id in $ContextIds) { $n.Props.Context[[int]$id] = [uint32]0 }
    foreach ($p in $NtpParams) {
        $pidv = [uint32]::Parse($p[1].Substring(2), 'HexNumber')
        $n.Props.Params[$pidv] = @{ Bits = [int]$p[2]; Type = $p[3]; Bytes = (ConvertTo-MockBytes $p) }
        $n.Props.Online[$pidv] = (ConvertTo-MockBytes $p)
    }
    $n.Props.Oid = [uint32]::Parse($Oid.Substring(2), 'HexNumber')
    $n | Add-Member ScriptMethod GetModulePara {
        param($id)
        if (-not $this.Props.Params.ContainsKey([uint32]$id)) { throw (New-ComError 'Unspecified error' ([int]0x80004005)) }
        , [byte[]]$this.Props.Params[[uint32]$id].Bytes
    }
    $n | Add-Member ScriptMethod SetModulePara {
        param($id, $v)
        $global:T.Mods.Add("SetModulePara $($this.PathName) $id") | Out-Null
        $e = $this.Props.Params[[uint32]$id]
        if ($null -eq $e) { throw (New-ComError 'Unspecified error' ([int]0x80004005)) }
        $b = [byte[]]@($v)
        if ($b.Length * 8 -ne $e.Bits) { throw (New-ComError 'ADS_E_INVALIDSIZE' ([int]0x98110705)) }
        if ($global:T.Mode -eq 'set-ignore') { return }
        $e.Bytes = $b
    }
    $n | Add-Member ScriptMethod GetTypeOfModulePara { param($id) $e = $this.Props.Params[[uint32]$id]; [PSCustomObject]@{ Name = $(if ($null -ne $e) { $e.Type } else { '' }) } }
    $n | Add-Member ScriptMethod GetModuleContext {
        param($id, $ref)
        if (-not $this.Props.Context.ContainsKey([int]$id)) { throw (New-ComError 'Context ObjectId not found' ([int]0x80070057)) }
        $ref.Value = $this.Props.Context[[int]$id]
    }
    $n | Add-Member ScriptMethod SetModuleContext {
        param($id, $oid)
        $global:T.Mods.Add("SetModuleContext $($this.PathName) $id $oid") | Out-Null
        if (-not $this.Props.Context.ContainsKey([int]$id)) { throw (New-ComError 'Context ObjectId not found' ([int]0x80070057)) }
        if (@($global:T.TaskOids) -notcontains [uint32]$oid) { throw (New-ComError 'Unspecified error' ([int]0x80004005)) }
        if ($global:T.Mode -eq 'ctx-ignore') { return }
        $this.Props.Context[[int]$id] = [uint32]$oid
    }
    Write-Output -NoEnumerate $n
}
$OnCreate = {
    param($Parent, $Name, $Sub, $Before, $VInfo)
    if ($Parent.PathName -ne $Folder) { throw (New-ComError 'Not implemented (mock)' -2147467263) }
    $v = [string]$VInfo
    $g = [guid]::Empty
    $isNtp = ([guid]::TryParse($v, [ref]$g) -and $g -eq [guid]$NtpGuid) -or $v -eq 'TcNtpExternalTimeProvider'
    if (-not $isNtp -and $global:T.Mode -eq 'class-hr-only') { throw (New-ComError 'localized text (mock)' ([int]0x98510009)) }
    if (-not $isNtp) { throw (New-ComError "TCOM Module / TCOM Configuration with GUID '%s' not found!" ([int]0x98510009)) }
    $nm = if ($global:T.Mode -eq 'objn') { "$($Name)_Obj1" } else { $Name }
    $m = Add-MockModule "$Folder^$nm (TcNtpExternalTimeProvider)" '#x01010020'
    if ($global:T.Mode -eq 'objn-hr') { }
    if ($global:T.Mode -eq 'wrong-guid') { $m.Xml = $m.Xml -replace '7E6D2FDA', '00000000' }
    return $m
}
function Reset-Mock {
    Reset-MockTree $Root
    $global:T.BootStatus = 'match'; $global:T.BootCalls = [System.Collections.ArrayList]::new()
    $global:T.OnCreate = $OnCreate
    $global:T.TaskOids = @([uint32]0x02010030)
    $null = Add-MockNode 'TIRC' 0
    $null = Add-MockNode $Folder 49
    $null = Add-MockModule $Ntp '#x01010010' @(1)
    $null = Add-MockModule "$Folder^JobPool (TcJobPool)" '#x01010030' @()
    $null = Add-MockNode 'TIRT' 0
    $null = Add-MockNode 'TIRT^PlcTask' 19 '<TreeItem><ItemName>PlcTask</ItemName><PathName>TIRT^PlcTask</PathName><ObjectId>#x02010030</ObjectId></TreeItem>'
    $null = Add-MockNode 'TIRT^NoOid' 19
}
$sm = New-MockSysManager
$sm | Add-Member ScriptMethod GetModuleManager {
    $mods = [PSCustomObject]@{}
    $mods | Add-Member ScriptProperty Count { @($global:T.Nodes.Values | Where-Object { $_.ItemType -eq 48 }).Count }
    $mods | Add-Member ScriptMethod Item {
        param($i)
        $n = @($global:T.Nodes.Values | Where-Object { $_.ItemType -eq 48 } | Sort-Object PathName)[$i]
        [PSCustomObject]@{ ModuleInstanceName = ($n.Name -replace ' \(.*\)$', ''); ModuleTypeName = 'TcNtpExternalTimeProvider'; oid = $n.Props.Oid; ParentOID = 0; ClassID = ''; PathName = $n.PathName }
    }
    $mm = [PSCustomObject]@{ Modules = $mods }
    $mm | Add-Member ScriptMethod GetOnlineModulePara {
        param($oid, $id, $max)
        if ($global:T.Mode -eq 'offline-runtime') { throw (New-ComError 'ADS error 0x71D' ([int]0x9811071D)) }
        $n = @($global:T.Nodes.Values | Where-Object { $_.ItemType -eq 48 -and $_.Props.Oid -eq [uint32]$oid })[0]
        if ($null -eq $n) { throw (New-ComError 'ADS error 0x71D' ([int]0x9811071D)) }
        if (-not $n.Props.Online.ContainsKey([uint32]$id)) { throw (New-ComError 'ADS error 0x703' ([int]0x98110703)) }
        , [byte[]]$n.Props.Online[[uint32]$id]
    }
    $mm | Add-Member ScriptMethod SetOnlineModulePara {
        param($oid, $id, $v)
        $global:T.Mods.Add("SetOnlineModulePara $oid $id") | Out-Null
        $n = @($global:T.Nodes.Values | Where-Object { $_.ItemType -eq 48 -and $_.Props.Oid -eq [uint32]$oid })[0]
        if ($null -eq $n) { throw (New-ComError 'ADS error 0x71D' ([int]0x9811071D)) }
        $b = [byte[]]@($v)
        if ($b.Length * 8 -ne $n.Props.Params[[uint32]$id].Bits) { throw (New-ComError 'ADS_E_INVALIDSIZE' ([int]0x98110705)) }
        $n.Props.Online[[uint32]$id] = $b
    }
    Write-Output -NoEnumerate $mm
}
$sm | Add-Member ScriptMethod GetTargetNetId { '199.5.42.250.1.1' }
$global:T.Sm = $sm
Install-MockModule $mod $Sln
& $mod {
    function script:Get-TcBootPackageDiff { [CmdletBinding()] param($SolutionPath, $Platform, $AmsNetId, $AdsPorts, $Variant) $null = $global:T.BootCalls.Add("$AmsNetId|$Platform"); [PSCustomObject]@{ status = $global:T.BootStatus; reason = 'mock'; mismatches = @('CurrentConfig.xml') } }
    function script:Get-TcSolutionPlatform { [CmdletBinding()] param() [PSCustomObject]@{ platform = 'TwinCAT OS (x64)'; projectPlatform = 'TwinCAT OS (x64)' } }
}
function Get-CodeChanged { & $mod { $e = Get-TcBuildRequired; if ($null -eq $e) { return $null }; (Get-TcBuildRequiredReasons $e)['code-changed'] } }
function Reset-BuildRequired { & $mod { $null = Clear-TcBuildRequired } }
function Get-Sets { @($global:T.Mods | Where-Object { $_ -match '^(CreateChild|SetModulePara|SetOnlineModulePara|SetModuleContext|DeleteChild) ' }) }

try {
    # ===== codec
    $tt = & $mod { Get-TcComParamType -Parameter ([PSCustomObject]@{ bitSize = 32; baseType = 'TimeType' }) -TypeName 'TimeType' -DataTypes @{ TimeType = [PSCustomObject]@{ isEnum = $true; baseType = 'DINT'; bitSize = 32 } } }
    Check 'codec: an enum of 32 bits is a signed 4-byte integer' ($tt.kind -eq 'int' -and $tt.bytes -eq 4) (J $tt)
    $b = & $mod { ConvertTo-TcComParamBytes -Type @{ name = 'LREAL'; bytes = 8; kind = 'float' } -Value '123.5' }
    $v = & $mod { param($x) ConvertFrom-TcComParamBytes -Type @{ name = 'LREAL'; bytes = 8; kind = 'float' } -Bytes $x } $b
    Check 'codec: LREAL 123.5 round trip (invariant culture)' ($b.Length -eq 8 -and $v -eq 123.5) "$v"
    $e = $null; try { $null = & $mod { ConvertTo-TcComParamBytes -Type @{ name = 'UINT'; bytes = 2; kind = 'uint' } -Value '70000' } } catch { $e = $_.Exception.Message }
    Check 'codec: UINT 70000 -> TCCOM_PARAM_INVALID_VALUE (no wrap)' ($e -match '^TCCOM_PARAM_INVALID_VALUE') "$e"
    $e = $null; try { $null = & $mod { ConvertTo-TcComParamBytes -Type @{ name = 'DINT'; bytes = 4; kind = 'int' } -Value 'abc' } } catch { $e = $_.Exception.Message }
    Check 'codec: DINT abc -> TCCOM_PARAM_INVALID_VALUE (XAE would store 0)' ($e -match '^TCCOM_PARAM_INVALID_VALUE') "$e"
    $b = & $mod { ConvertTo-TcComParamBytes -Type @{ name = 'SINT'; bytes = 1; kind = 'int' } -Value '-2' }
    $v = & $mod { param($x) ConvertFrom-TcComParamBytes -Type @{ name = 'SINT'; bytes = 1; kind = 'int' } -Bytes $x } $b
    Check 'codec: SINT -2 -> FE and back' ($b[0] -eq 254 -and $v -eq -2) "$($b[0]) $v"

    # ===== Add-TcComModule
    Reset-Mock; Reset-BuildRequired
    $r = Add-TcComModule -Name NtpNew
    Check 'AddTcComModule without ClassId / TypeName -> INVALID_PARAMS' ($r.error.code -eq 'INVALID_PARAMS') (J $r.error)
    $r = Add-TcComModule -Name NtpNew -ClassId 'not-a-guid'
    Check 'AddTcComModule bad GUID -> INVALID_PARAMS' ($r.error.code -eq 'INVALID_PARAMS') (J $r.error)
    $r = Add-TcComModule -Name ntpprobe -ClassId $NtpGuid
    Check 'AddTcComModule name taken as "<name> (<type>)" -> TCCOM_MODULE_ALREADY_EXISTS, nothing created' ($r.error.code -eq 'TCCOM_MODULE_ALREADY_EXISTS' -and (Get-Sets).Count -eq 0) (J $r)
    $r = Add-TcComModule -Name NtpNew -ClassId '7E6D2FDA-2D37-4998-A31F-36958D3A2C8A'
    Check 'AddTcComModule dry-run: GUID normalized, nothing created' ($r.success -and $r.data.dryRun -and $r.data.vInfo -eq $NtpGuid -and (Get-Sets).Count -eq 0) (J $r.data)
    $r = Add-TcComModule -Name NtpNew -ClassId $NtpGuid -DryRun $false
    Check 'AddTcComModule live: renamed path read back, classId, oid, contextIds, warning' ($r.success -and $r.data.createdPath -eq "$Folder^NtpNew (TcNtpExternalTimeProvider)" -and $r.data.classId -eq $NtpGuid -and $r.data.oidHex -eq '0x01010020' -and @($r.data.contextIds) -contains 1 -and @($r.data.warnings | Where-Object { $_ -like '*NtpNew (TcNtpExternalTimeProvider)*' }).Count -ge 1) (J $r.data)
    Check 'AddTcComModule live: BUILD_REQUIRED, backup' ((Get-CodeChanged) -match 'Add-TcComModule' -and (Test-Path -LiteralPath ([string]$r.data.backupPath))) "$(Get-CodeChanged)"
    Reset-Mock; Reset-BuildRequired; $global:T.Mode = 'objn'
    $r = Add-TcComModule -Name NtpObj -TypeName TcNtpExternalTimeProvider -DryRun $false
    Check 'AddTcComModule XAE adds _ObjN (4024) -> success with the actual name' ($r.success -and $r.data.createdName -eq 'NtpObj_Obj1 (TcNtpExternalTimeProvider)') (J $r.data)
    Reset-Mock; Reset-BuildRequired
    $r = Add-TcComModule -Name NtpX -ClassId '{11111111-2222-3333-4444-555555555555}' -DryRun $false
    Check 'AddTcComModule unknown class (0x98510009) -> TCCOM_CLASS_NOT_FOUND, recorded' ($r.error.code -eq 'TCCOM_CLASS_NOT_FOUND' -and (Get-CodeChanged) -match 'failed') (J $r.error)
    Reset-Mock; Reset-BuildRequired; $global:T.Mode = 'wrong-guid'
    $r = Add-TcComModule -Name NtpW -ClassId $NtpGuid -DryRun $false
    Check 'AddTcComModule readback GUID differs -> TCCOM_VERIFY_FAILED, rolled back' ($r.error.code -eq 'TCCOM_VERIFY_FAILED' -and $r.data.rolledBack -and -not $global:T.Nodes.ContainsKey("$Folder^NtpW (TcNtpExternalTimeProvider)")) (J $r)
    Reset-Mock; Reset-BuildRequired; $global:T.Dialog = New-MockDialog
    $r = Add-TcComModule -Name NtpD -ClassId $NtpGuid -DryRun $false
    Check 'AddTcComModule modal dialog -> IDE_MODAL_DIALOG, nothing created / recorded' ($r.error.code -eq 'IDE_MODAL_DIALOG' -and (Get-Sets).Count -eq 0 -and $null -eq (Get-CodeChanged)) (J $r.error)

    # ===== Get-TcComModuleParameter
    Reset-Mock; Reset-BuildRequired
    $r = Get-TcComModuleParameter -Module NtpProbe
    Check 'GetTcComParameter list: found by instance name, parameters with ids and project values' ($r.success -and $r.data.modulePath -eq $Ntp -and @($r.data.parameters).Count -eq 8 -and @($r.data.parameters | Where-Object { $_.name -eq 'PollInterval' -and $_.parameterId -eq '0x03150105' -and $_.projectValue -eq '4321' }).Count -eq 1) (J $r.data)
    $r = Get-TcComModuleParameter -Module NoSuch
    Check 'GetTcComParameter unknown module -> TCCOM_MODULE_NOT_FOUND with modules' ($r.error.code -eq 'TCCOM_MODULE_NOT_FOUND' -and @($r.data.modules) -contains 'NtpProbe') (J $r)
    $r = Get-TcComModuleParameter -Module NtpProbe -Name pollinterval
    Check 'GetTcComParameter PollInterval: UDINT 4321 decoded, rawHex' ($r.success -and $r.data.value -eq 4321 -and $r.data.rawHex -eq 'E1100000' -and $r.data.paramType -eq 'UDINT') (J $r.data)
    $r = Get-TcComModuleParameter -Module $Ntp -ParameterId '#x0509300A'
    Check 'GetTcComParameter by id (hex, other case): LREAL 2000' ($r.success -and $r.data.value -eq 2000 -and $r.data.name -eq 'Velocity') (J $r.data)
    $r = Get-TcComModuleParameter -Module NtpProbe -Name ServerName
    Check 'GetTcComParameter STRING decoded' ($r.success -and $r.data.value -eq 'ntp.example') (J $r.data)
    $r = Get-TcComModuleParameter -Module NtpProbe -Name ServerPara
    Check 'GetTcComParameter struct: rawHex only, value null' ($r.success -and $null -eq $r.data.value -and $r.data.rawHex.Length -eq 32) (J $r.data)
    $r = Get-TcComModuleParameter -Module NtpProbe -Name NoSuch
    Check 'GetTcComParameter unknown name -> TCCOM_PARAM_NOT_FOUND with parameters' ($r.error.code -eq 'TCCOM_PARAM_NOT_FOUND' -and @($r.data.parameters).Count -eq 8) (J $r.error)
    $global:T.Nodes[$Ntp].Props.Online[[uint32]0x03150105] = [byte[]][BitConverter]::GetBytes([uint32]7777)
    $r = Get-TcComModuleParameter -Module NtpProbe -Name PollInterval -Online
    Check 'GetTcComParameter -Online reads the running value (7777), not the project value' ($r.success -and $r.data.value -eq 7777 -and $r.data.projectValue -eq '4321' -and $r.data.online) (J $r.data)
    $global:T.Mode = 'offline-runtime'
    $r = Get-TcComModuleParameter -Module NtpProbe -Name PollInterval -Online
    Check 'GetTcComParameter -Online not running (0x9811071D) -> TCCOM_OBJECT_NOT_FOUND, hint Enable-TcConfig' ($r.error.code -eq 'TCCOM_OBJECT_NOT_FOUND' -and $r.error.hint -match 'Enable-TcConfig') (J $r.error)

    # ===== Set-TcComModuleParameter
    Reset-Mock; Reset-BuildRequired
    $r = Set-TcComModuleParameter -Module NtpProbe -Name PollInterval -Value 'abc'
    Check 'SetTcComParameter abc for UDINT -> TCCOM_PARAM_INVALID_VALUE, nothing written' ($r.error.code -eq 'TCCOM_PARAM_INVALID_VALUE' -and (Get-Sets).Count -eq 0) (J $r.error)
    $r = Set-TcComModuleParameter -Module NtpProbe -Name ServerPara -Value 1
    Check 'SetTcComParameter struct -> TCCOM_PARAM_UNSUPPORTED_TYPE' ($r.error.code -eq 'TCCOM_PARAM_UNSUPPORTED_TYPE') (J $r.error)
    $r = Set-TcComModuleParameter -Module NtpProbe -Name PollInterval -Value 5000
    Check 'SetTcComParameter dry-run: current / planned hex, nothing written' ($r.success -and $r.data.dryRun -and $r.data.currentHex -eq 'E1100000' -and $r.data.plannedHex -eq '88130000' -and (Get-Sets).Count -eq 0) (J $r.data)
    $r = Set-TcComModuleParameter -Module NtpProbe -Name PollInterval -Value 4321 -DryRun $false
    Check 'SetTcComParameter same value -> written false, nothing sent' ($r.success -and $r.data.written -eq $false -and (Get-Sets).Count -eq 0) (J $r.data)
    $r = Set-TcComModuleParameter -Module NtpProbe -Name PollInterval -Value 5000 -DryRun $false
    Check 'SetTcComParameter live: SetModulePara, readback verified, backup, BUILD_REQUIRED' ($r.success -and $r.data.verified -and $r.data.readbackHex -eq '88130000' -and (Test-Path -LiteralPath ([string]$r.data.backupPath)) -and (Get-CodeChanged) -match 'Set-TcComModuleParameter') (J $r.data)
    $r = Set-TcComModuleParameter -Module NtpProbe -Name ClientEnable -Value false -DryRun $false
    Check 'SetTcComParameter BOOL false -> 00' ($r.success -and $r.data.readbackHex -eq '00') (J $r.data)
    Reset-Mock; Reset-BuildRequired; $global:T.Mode = 'set-ignore'
    $r = Set-TcComModuleParameter -Module NtpProbe -Name PollInterval -Value 5000 -DryRun $false
    Check 'SetTcComParameter readback differs -> TCCOM_PARAM_VERIFY_FAILED, recorded' ($r.error.code -eq 'TCCOM_PARAM_VERIFY_FAILED' -and (Get-CodeChanged) -match 'Set-TcComModuleParameter') (J $r)
    Reset-Mock; Reset-BuildRequired
    $global:T.Nodes[$Ntp].Props.Params[[uint32]0x03150105].Bits = 16
    $r = Set-TcComModuleParameter -Module NtpProbe -Name PollInterval -Value 5000 -DryRun $false
    Check 'SetTcComParameter size refused by XAE (0x98110705) -> TCCOM_PARAM_SIZE_MISMATCH' ($r.error.code -eq 'TCCOM_PARAM_SIZE_MISMATCH') (J $r.error)
    Reset-Mock; Reset-BuildRequired
    $r = Set-TcComModuleParameter -Module NtpProbe -Name PollInterval -Value 5555 -Online -DryRun $false
    $n = $global:T.Nodes[$Ntp]
    Check 'SetTcComParameter -Online: running value changed, project value unchanged, nothing recorded' ($r.success -and $r.data.verified -and $r.data.projectChanged -eq $false -and [BitConverter]::ToUInt32($n.Props.Online[[uint32]0x03150105], 0) -eq 5555 -and [BitConverter]::ToUInt32($n.Props.Params[[uint32]0x03150105].Bytes, 0) -eq 4321 -and $null -eq (Get-CodeChanged) -and (Test-Path -LiteralPath ([string]$r.data.backupPath))) (J $r.data)
    Reset-Mock; Reset-BuildRequired; $global:T.Dialog = New-MockDialog
    $r = Set-TcComModuleParameter -Module NtpProbe -Name PollInterval -Value 5000 -DryRun $false
    Check 'SetTcComParameter modal dialog -> IDE_MODAL_DIALOG, nothing written / recorded' ($r.error.code -eq 'IDE_MODAL_DIALOG' -and (Get-Sets).Count -eq 0 -and $null -eq (Get-CodeChanged)) (J $r.error)

    # 4.6 N2: TIME (32 bit, ms, UDINT inside) is read as a number and written as ms or T#...
    Reset-Mock; Reset-BuildRequired
    $r = Get-TcComModuleParameter -Module NtpProbe -Name PollTime
    Check 'N2 GetTcComParameter TIME: value 1000 (ms), rawHex E8030000, paramType TIME' ($r.success -and $r.data.value -eq 1000 -and $r.data.rawHex -eq 'E8030000' -and $r.data.paramType -eq 'TIME') (J $r.data)
    $r = Set-TcComModuleParameter -Module NtpProbe -Name PollTime -Value 4321
    Check 'N2 SetTcComParameter TIME 4321 (ms) dry-run -> plannedHex E1100000, value 4321' ($r.success -and $r.data.plannedHex -eq 'E1100000' -and $r.data.value -eq 4321 -and (Get-Sets).Count -eq 0) (J $r.data)
    $r = Set-TcComModuleParameter -Module NtpProbe -Name PollTime -Value 'T#5S'
    Check 'N2 SetTcComParameter TIME T#5S -> 5000 ms (88130000)' ($r.success -and $r.data.plannedHex -eq '88130000' -and $r.data.value -eq 5000) (J $r.data)
    $r = Set-TcComModuleParameter -Module NtpProbe -Name PollTime -Value 'TIME#1m30s_250ms'
    Check 'N2 SetTcComParameter TIME#1m30s_250ms -> 90250 ms' ($r.success -and $r.data.value -eq 90250) (J $r.data)
    $r = Set-TcComModuleParameter -Module NtpProbe -Name PollTime -Value 'T#1.5s'
    Check 'N2 SetTcComParameter T#1.5s -> 1500 ms' ($r.success -and $r.data.value -eq 1500) (J $r.data)
    # review N1: units in the order d h m s ms, each once; N2: overflow keeps the fixed message
    foreach ($bad in @('T#1.5ms', '-1', 'T#-5s', 'abc', 'T#5x', '4294967296', 'T#5s1m', 'T#1s1s', 'T#1ms5s', 'T#1m1h', 'T#99999999999999999999999999999d')) {
        $r = Set-TcComModuleParameter -Module NtpProbe -Name PollTime -Value $bad
        Check "N2 SetTcComParameter TIME '$bad' -> TCCOM_PARAM_INVALID_VALUE, nothing written" ($r.error.code -eq 'TCCOM_PARAM_INVALID_VALUE' -and (Get-Sets).Count -eq 0) (J $r.error)
    }
    $r = Set-TcComModuleParameter -Module NtpProbe -Name PollTime -Value 'T#99999999999999999999999999999d'
    Check 'N2 TIME overflow -> fixed English message (out of the TIME range)' ($r.error.code -eq 'TCCOM_PARAM_INVALID_VALUE' -and $r.error.message -match 'out of the TIME range 0\.\.4294967295 ms') (J $r.error)
    $r = Set-TcComModuleParameter -Module NtpProbe -Name PollTime -Value 'T#1d2h3m4s5ms'
    Check 'N1 TIME all units in order T#1d2h3m4s5ms -> 93784005 ms' ($r.success -and $r.data.value -eq 93784005) (J $r.data)
    $r = Set-TcComModuleParameter -Module NtpProbe -Name PollTime -Value 'T#5s' -DryRun $false
    Check 'N2 SetTcComParameter TIME live: SetModulePara, readback 88130000, verified' ($r.success -and $r.data.verified -and $r.data.readbackHex -eq '88130000') (J $r.data)
    $r = Set-TcComModuleParameter -Module NtpProbe -Name ServerPara -Value 1
    Check 'N2 unsupported type: message names the type and the writable list (TIME included), hint lists TIME too' ($r.error.code -eq 'TCCOM_PARAM_UNSUPPORTED_TYPE' -and $r.error.message -match 'ST_ServerPara \(16 bytes\)' -and $r.error.message -match 'TIME' -and $r.error.hint -match 'TIME' -and $r.error.hint -match 'paramType') (J $r.error)

    # ===== Set-TcComModuleContext
    Reset-Mock; Reset-BuildRequired
    $r = Set-TcComModuleContext -Module 'JobPool' -Task 'TIRT^PlcTask'
    Check 'SetTcComContext module without context -> TCCOM_CONTEXT_INVALID' ($r.error.code -eq 'TCCOM_CONTEXT_INVALID' -and @($r.data.contextIds).Count -eq 0) (J $r)
    $r = Set-TcComModuleContext -Module NtpProbe -Task 'TIRT^PlcTask' -ContextId 0
    Check 'SetTcComContext -ContextId 0 (not a TMC id) -> TCCOM_CONTEXT_INVALID before any write' ($r.error.code -eq 'TCCOM_CONTEXT_INVALID' -and (Get-Sets).Count -eq 0 -and @($r.data.contextIds) -contains 1) (J $r)
    $r = Set-TcComModuleContext -Module NtpProbe -Task 'TIRT^NoOid'
    Check 'SetTcComContext task without ObjectId -> TCCOM_CONTEXT_INVALID' ($r.error.code -eq 'TCCOM_CONTEXT_INVALID') (J $r.error)
    $r = Set-TcComModuleContext -Module NtpProbe -Task 'TIRT^PlcTask'
    Check 'SetTcComContext dry-run: context 1, task oid 0x02010030' ($r.success -and $r.data.contextId -eq 1 -and $r.data.taskOidHex -eq '0x02010030' -and (Get-Sets).Count -eq 0) (J $r.data)
    $r = Set-TcComModuleContext -Module NtpProbe -Task 'TIRT^PlcTask' -DryRun $false
    Check 'SetTcComContext live: SetModuleContext(1, oid), readback, BUILD_REQUIRED' ($r.success -and $r.data.verified -and $r.data.readbackOidHex -eq '0x02010030' -and (Get-Sets) -contains "SetModuleContext $Ntp 1 33620016" -and (Get-CodeChanged) -match 'Set-TcComModuleContext') "$(J $r.data) $((Get-Sets) -join ';')"
    $r = Set-TcComModuleContext -Module NtpProbe -Task 'TIRT^PlcTask' -DryRun $false
    Check 'SetTcComContext already assigned -> written false' ($r.success -and $r.data.written -eq $false) (J $r.data)
    Reset-Mock; Reset-BuildRequired; $global:T.TaskOids = @()
    $r = Set-TcComModuleContext -Module NtpProbe -Task 'TIRT^PlcTask' -DryRun $false
    Check 'SetTcComContext XAE E_FAIL (oid no valid task) -> TCCOM_CONTEXT_INVALID, recorded' ($r.error.code -eq 'TCCOM_CONTEXT_INVALID' -and (Get-CodeChanged) -match 'failed') (J $r.error)
    Reset-Mock; Reset-BuildRequired; $global:T.Mode = 'ctx-ignore'
    $r = Set-TcComModuleContext -Module NtpProbe -Task 'TIRT^PlcTask' -DryRun $false
    Check 'SetTcComContext readback differs -> TCCOM_CONTEXT_VERIFY_FAILED' ($r.error.code -eq 'TCCOM_CONTEXT_VERIFY_FAILED') (J $r.error)

    # ===== review fixes
    # N1: 0x98510009 decides, not the English text
    Reset-Mock; Reset-BuildRequired; $global:T.Mode = 'class-hr-only'
    $r = Add-TcComModule -Name NtpX -ClassId '{11111111-2222-3333-4444-555555555555}' -DryRun $false
    Check 'N1 AddTcComModule: 0x98510009 with another text -> TCCOM_CLASS_NOT_FOUND' ($r.error.code -eq 'TCCOM_CLASS_NOT_FOUND' -and $r.data.hresultHex -eq '0x98510009') (J $r.error)
    # S10: a named type is an integer only when DataTypes say it is an enum
    Reset-Mock; Reset-BuildRequired
    $r = Get-TcComModuleParameter -Module NtpProbe -Name TimeType
    Check 'S10 enum confirmed by DataTypes (EnumInfo) -> integer value' ($r.success -and $r.data.value -eq 3) (J $r.data)
    $r = Get-TcComModuleParameter -Module NtpProbe -Name ModeWord
    Check 'S10 32-bit named type that is no enum -> raw only (value null)' ($r.success -and $null -eq $r.data.value -and -not [string]::IsNullOrEmpty($r.data.rawHex)) (J $r.data)
    $r = Set-TcComModuleParameter -Module NtpProbe -Name ModeWord -Value 5 -DryRun $false
    Check 'S10 writing that type -> TCCOM_PARAM_UNSUPPORTED_TYPE, nothing sent' ($r.error.code -eq 'TCCOM_PARAM_UNSUPPORTED_TYPE' -and (Get-Sets).Count -eq 0) (J $r.error)
    $global:T.Nodes[$Ntp].Props.Params[[uint32]0x03150105].Bytes = [byte[]]@(1, 2)
    $r = Set-TcComModuleParameter -Module NtpProbe -Name PollInterval -Value 5000 -DryRun $false
    Check 'S10 current value of another size than planned -> TCCOM_PARAM_SIZE_MISMATCH before sending' ($r.error.code -eq 'TCCOM_PARAM_SIZE_MISMATCH' -and (Get-Sets).Count -eq 0) (J $r.error)
    # S11: online writes need the project's configuration on the target
    Reset-Mock; Reset-BuildRequired; $global:T.BootStatus = 'mismatch'
    $r = Set-TcComModuleParameter -Module NtpProbe -Name PollInterval -Value 5555 -Online -DryRun $false
    Check 'S11 boot package mismatch -> TCCOM_ONLINE_CONFIG_MISMATCH, nothing written online' ($r.error.code -eq 'TCCOM_ONLINE_CONFIG_MISMATCH' -and (Get-Sets).Count -eq 0 -and $r.data.bootPackage.status -eq 'mismatch' -and $r.error.hint -match 'Enable-TcConfig') (J $r)
    Reset-Mock; Reset-BuildRequired; $global:T.BootStatus = 'unavailable'
    $r = Set-TcComModuleParameter -Module NtpProbe -Name PollInterval -Value 5555 -Online
    Check 'S11 not comparable (remote target) -> TCCOM_ONLINE_CONFIG_MISMATCH also in dry-run' ($r.error.code -eq 'TCCOM_ONLINE_CONFIG_MISMATCH' -and @($global:T.BootCalls).Count -eq 1 -and $global:T.BootCalls[0] -eq '199.5.42.250.1.1|TwinCAT OS (x64)') (J $r.error)
    Reset-Mock; Reset-BuildRequired
    $r = Set-TcComModuleParameter -Module NtpProbe -Name PollInterval -Value 4000
    Check 'S11 offline writes do not need the boot package check' ($r.success -and @($global:T.BootCalls).Count -eq 0) (J $r.data)

    # ===== hints / tools.json
    foreach ($c in @('TCCOM_MODULE_ALREADY_EXISTS', 'TCCOM_CLASS_NOT_FOUND', 'TCCOM_VERIFY_FAILED', 'TCCOM_MODULE_NOT_FOUND', 'TCCOM_PARAM_NOT_FOUND', 'TCCOM_PARAM_INVALID_VALUE', 'TCCOM_PARAM_UNSUPPORTED_TYPE', 'TCCOM_PARAM_SIZE_MISMATCH', 'TCCOM_PARAM_READ_FAILED', 'TCCOM_PARAM_WRITE_FAILED', 'TCCOM_PARAM_VERIFY_FAILED', 'TCCOM_OBJECT_NOT_FOUND', 'TCCOM_ONLINE_CONFIG_MISMATCH', 'TCCOM_CONTEXT_INVALID', 'TCCOM_CONTEXT_WRITE_FAILED', 'TCCOM_CONTEXT_VERIFY_FAILED')) {
        $h = & $mod { param($k) Get-TcErrorHint -Code $k } $c
        Check "hint $c" (-not [string]::IsNullOrWhiteSpace($h)) "$h"
    }
    $tools = @((Get-Content -Raw -Encoding UTF8 (Join-Path $PSScriptRoot '..\..\mcp-server\tools.json') | ConvertFrom-Json).tools)
    $byName = @{}; foreach ($tt in $tools) { $byName[$tt.name] = $tt }
    foreach ($pair in @(@('AddTcComModule', 'Add-TcComModule'), @('SetTcComParameter', 'Set-TcComModuleParameter'), @('SetTcComContext', 'Set-TcComModuleContext'))) {
        $tt = $byName[$pair[0]]
        Check "tools.json $($pair[0]): $($pair[1]), destructive, DryRun default true" ($null -ne $tt -and $tt.cmdlet -eq $pair[1] -and $tt.annotations.destructiveHint -eq $true -and $tt.inputSchema.properties.DryRun.default -eq $true) (J $tt.annotations)
    }
    $tt = $byName['GetTcComParameter']
    Check 'tools.json GetTcComParameter: read-only, Online boolean' ($null -ne $tt -and $tt.annotations.readOnlyHint -eq $true -and $tt.inputSchema.properties.Online.type -eq 'boolean') (J $tt)
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
