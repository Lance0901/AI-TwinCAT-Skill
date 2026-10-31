# Unit: task 4.5 (complete-automation-interface phase 3): Get-TcAdsRoutes (MCP GetAdsRoutes),
# Find-TcAdsTarget (FindAdsTargets), Add-TcAdsRoute (AddAdsRoute), the password mask of the generic
# tree tools / backups (ConvertTo-TcMaskedXml) and TIRR in the root candidates.
# No IDE / runtime: a mock TIRR whose ProduceXml looks like verification/phase3-probe.md question 22 and
# whose ConsumeXml behaves as question 23 (search only from the local system). AddRoute itself was never
# measured; the mock only stores the route so that the readback can be tested.
#   powershell.exe -NoProfile -File tests/Unit/ads-route.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
$env:TCAUTO_STATE_DIR = Join-Path $env:TEMP ("tcauto-unit-state-{0}" -f [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
. (Join-Path $PSScriptRoot 'lib\MockTree.ps1')
$mod = Get-Module TwinCATAutomation
$fail = 0

$Root = Join-Path $env:TEMP ("tcauto-unit-route-{0}" -f [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path (Join-Path $Root 'Prj') -Force
$Sln = Join-Path $Root 'Route.sln'
[System.IO.File]::WriteAllText($Sln, '')
[System.IO.File]::WriteAllText((Join-Path $Root 'Prj\Prj.tsproj'), '<TcSmProject/>')
$Secret = 'Xy7-unit-' + [guid]::NewGuid().ToString('N').Substring(0, 10)
$env:TCAUTO_UNIT_ROUTE_PW = $Secret
$Local = '192.168.50.168.1.1'

function New-TirrXml {
    $st = ($global:T.Static | ForEach-Object { "<Route><Name>$($_.Name)</Name><Address>$($_.Address)</Address><NetId>$($_.NetId)</NetId><Type>TCP_IP</Type></Route>" }) -join ''
    $pr = ($global:T.Project | ForEach-Object { "<Route><Name>$($_.Name)</Name><NetId>$($_.NetId)</NetId><IpAddr>$($_.Address)</IpAddr></Route>" }) -join ''
    $tg = ($global:T.Found | ForEach-Object { "<Target><Name>$($_.Name)</Name><NetId>$($_.NetId)</NetId><IpAddr>$($_.IpAddr)</IpAddr><Version>3.1.4026</Version><OS>Windows (10.0)</OS></Target>" }) -join ''
    "<TreeItem><ItemName>Routes</ItemName><PathName>TIRR</PathName><ItemType>31</ItemType><RoutePrj><Target>$($global:T.Target)</Target><UseRelativeNetIds>false</UseRelativeNetIds><ActualRoutes><Route><Name>route1</Name><NetId>169.254.215.73.1.1</NetId></Route></ActualRoutes><StaticRoutes>$st</StaticRoutes><ProjectRoutes>$pr</ProjectRoutes><TargetList><BroadcastSearch>false</BroadcastSearch><Search></Search>$tg</TargetList></RoutePrj></TreeItem>"
}
$OnConsume = {
    param($Node, $Xml)
    if ($Node.PathName -ne 'TIRR') { return $false }
    $d = New-Object System.Xml.XmlDocument; $d.LoadXml($Xml)
    if ($null -ne $d.SelectSingleNode('//TargetList')) {
        if ($global:T.Target -ne $Local) { throw (New-ComError "ConsumeXml 'TIRR' failed. Broadcast search only works on local target system. Please change target system to local system! Error parsing: TreeItem/RoutePrj/TargetList/BroadcastSearch" ([int]0x80004005)) }
        if ($global:T.Mode -eq 'found') { $global:T.Found = @([PSCustomObject]@{ Name = 'CX-1'; NetId = '5.1.2.3.1.1'; IpAddr = '192.168.1.20' }) }
    }
    $add = $d.SelectSingleNode('//AddRoute')
    if ($null -ne $add) {
        if ($global:T.Mode -eq 'add-fail') { throw (New-ComError "ConsumeXml '$Xml' failed. Route could not be added (password $($add.SelectSingleNode('Password').InnerText))" ([int]0x80004005)) }
        if ($global:T.Mode -ne 'add-noop') { $global:T.Static = @($global:T.Static) + @([PSCustomObject]@{ Name = $add.SelectSingleNode('RemoteName').InnerText; Address = $add.SelectSingleNode('RemoteIpAddr').InnerText; NetId = $add.SelectSingleNode('RemoteNetId').InnerText }) }
    }
    $pr = $d.SelectSingleNode('//AddProjectRoute')
    if ($null -ne $pr) { $global:T.Project = @($global:T.Project) + @([PSCustomObject]@{ Name = $pr.SelectSingleNode('Name').InnerText; Address = $pr.SelectSingleNode('IpAddr').InnerText; NetId = $pr.SelectSingleNode('NetId').InnerText }) }
    $Node.Xml = New-TirrXml
    return $true
}
function Reset-Mock([string]$Target = $Local) {
    Reset-MockTree $Root
    $global:T.OnConsume = $OnConsume
    $global:T.Target = $Target; $global:T.Static = @(); $global:T.Project = @(); $global:T.Found = @(); $global:T.LocalNetId = $Local
    $n = Add-MockNode 'TIRR' 31
    $n.Xml = New-TirrXml
    $null = Add-MockNode 'TISY' 0 "<TreeItem><ItemName>System</ItemName><PathName>TISY</PathName><BootSettings><AutoLogon>true</AutoLogon><LogonUserName>op</LogonUserName><LogonPassword>$Secret</LogonPassword></BootSettings></TreeItem>"
}
$global:T.Sm = New-MockSysManager
Install-MockModule $mod $Sln
& $mod { function script:Get-TcLocalSystemNetId { [CmdletBinding()] param() $global:T.LocalNetId } }
function Get-CodeChanged { & $mod { $e = Get-TcBuildRequired; if ($null -eq $e) { return $null }; (Get-TcBuildRequiredReasons $e)['code-changed'] } }
function Reset-BuildRequired { & $mod { $null = Clear-TcBuildRequired } }
function Test-NoSecret($Result, [string]$BackupPath) {
    $txt = ($Result | ConvertTo-Json -Depth 10)
    if ($txt.Contains($Secret)) { return $false }
    if (-not [string]::IsNullOrEmpty($BackupPath) -and (Test-Path -LiteralPath $BackupPath)) { if (([System.IO.File]::ReadAllText($BackupPath)).Contains($Secret)) { return $false } }
    return $true
}

try {
    # ===== password mask
    $m = & $mod { param($s) ConvertTo-TcMaskedXml -Xml "<TreeItem><BootSettings><LogonPassword>$s</LogonPassword><Bypass>1</Bypass></BootSettings><AddRoute><Password>$s</Password><Pwd x=`"1`">$s</Pwd></AddRoute><User Password=`"$s`"/></TreeItem>" } $Secret
    Check 'mask: LogonPassword / Password / Pwd elements and a Password attribute become ***, Bypass kept' (-not $m.Contains($Secret) -and $m -match '<LogonPassword>\*\*\*</LogonPassword>' -and $m -match '<Bypass>1</Bypass>' -and $m -match 'Password="\*\*\*"') $m
    $m2 = & $mod { ConvertTo-TcMaskedXml -Xml '<TreeItem><TaskDef><CycleTime>10000</CycleTime></TaskDef></TreeItem>' }
    Check 'mask: XML without passwords is returned unchanged' ($m2 -eq '<TreeItem><TaskDef><CycleTime>10000</CycleTime></TaskDef></TreeItem>') $m2
    Reset-Mock
    $r = Get-TcTreeItemXml -Path 'TISY'
    Check 'ProduceXml (generic tool) masks LogonPassword' ($r.success -and -not $r.data.xml.Contains($Secret) -and $r.data.xml -match '<LogonPassword>\*\*\*</LogonPassword>') (J $r.data)
    $b = & $mod { param($d, $s) New-TcTreeItemBackup -SolutionDir $d -Path 'TISY' -Xml "<TreeItem><LogonPassword>$s</LogonPassword></TreeItem>" } $Root $Secret
    Check 'backup files are masked too' (-not ([System.IO.File]::ReadAllText($b.backupPath)).Contains($Secret)) $b.backupPath
    $e = & $mod { param($s) (New-TcTreeItemErrorResult -ErrorRecord "ConsumeXml '<TreeItem><Password>$s</Password></TreeItem>' failed" -DefaultCode 'X' -Operation 'op').error.message } $Secret
    Check 'generic error messages are masked' (-not $e.Contains($Secret)) $e
    $r = Get-TcTreeItem -Path 'NOPE^x'
    Check 'TREEITEM_NOT_FOUND root list includes TIRR' ($r.error.code -eq 'TREEITEM_NOT_FOUND' -and @($r.data.nearestChildren) -contains 'TIRR') (J $r.data)

    # ===== Get-TcAdsRoutes
    Reset-Mock
    $global:T.Static = @([PSCustomObject]@{ Name = 'PLC-A'; Address = '10.0.0.5'; NetId = '10.0.0.5.1.1' })
    $global:T.Nodes['TIRR'].Xml = New-TirrXml
    $r = Get-TcAdsRoutes
    Check 'GetAdsRoutes: target, actual, static, project routes parsed' ($r.success -and $r.data.target -eq $Local -and @($r.data.actualRoutes)[0].netId -eq '169.254.215.73.1.1' -and @($r.data.staticRoutes)[0].address -eq '10.0.0.5' -and @($r.data.staticRoutes)[0].type -eq 'TCP_IP' -and @($r.data.projectRoutes).Count -eq 0) (J $r.data)

    # ===== Find-TcAdsTarget
    Reset-Mock -Target '199.5.42.250.1.1'
    $r = Find-TcAdsTarget
    Check 'FindAdsTargets target is the UmRT (not local) -> ROUTE_SEARCH_REQUIRES_LOCAL_TARGET, nothing sent, hint Set-TcTarget' ($r.error.code -eq 'ROUTE_SEARCH_REQUIRES_LOCAL_TARGET' -and @(Get-MockWrites).Count -eq 0 -and $r.error.hint -match 'Set-TcTarget') (J $r)
    Reset-Mock -Target '199.5.42.250.1.1'; $global:T.LocalNetId = $null
    $r = Find-TcAdsTarget
    Check 'FindAdsTargets local NetId unknown, XAE refuses -> ROUTE_SEARCH_REQUIRES_LOCAL_TARGET' ($r.error.code -eq 'ROUTE_SEARCH_REQUIRES_LOCAL_TARGET' -and @(Get-MockWrites).Count -eq 1) (J $r.error)
    Reset-Mock
    $r = Find-TcAdsTarget
    Check 'FindAdsTargets broadcast, nothing found -> success, targets [], note' ($r.success -and @($r.data.targets).Count -eq 0 -and $r.data.note -match 'does not prove' -and $global:T.LastXml -eq '<TreeItem><RoutePrj><TargetList><BroadcastSearch>true</BroadcastSearch></TargetList></RoutePrj></TreeItem>') (J $r.data)
    Reset-Mock; $global:T.Mode = 'found'
    $r = Find-TcAdsTarget -Search 192.168.1.20
    Check 'FindAdsTargets -Search: Search element, target parsed' ($r.success -and @($r.data.targets)[0].netId -eq '5.1.2.3.1.1' -and $global:T.LastXml -match '<Search>192.168.1.20</Search>') (J $r.data)
    $r = Find-TcAdsTarget -Search 'a<b'
    Check 'FindAdsTargets invalid -Search -> INVALID_PARAMS' ($r.error.code -eq 'INVALID_PARAMS') (J $r.error)

    # ===== Add-TcAdsRoute
    Reset-Mock; Reset-BuildRequired
    $r = Add-TcAdsRoute -Name CX-1 -NetId 5.1.2.3.1.1 -Address 192.168.1.20 -UserName Administrator
    Check 'AddAdsRoute without a password source -> ROUTE_PASSWORD_MISSING' ($r.error.code -eq 'ROUTE_PASSWORD_MISSING') (J $r.error)
    $r = Add-TcAdsRoute -Name CX-1 -NetId 5.1.2.3.1.1 -Address 192.168.1.20 -UserName Administrator -PasswordEnv TCAUTO_UNIT_NOT_SET_X
    Check 'AddAdsRoute empty environment variable -> ROUTE_PASSWORD_MISSING, hint PasswordEnv' ($r.error.code -eq 'ROUTE_PASSWORD_MISSING' -and $r.error.hint -match 'PasswordEnv') (J $r.error)
    $r = Add-TcAdsRoute -Name CX-1 -NetId 5.1.2.3.1 -Address 192.168.1.20 -UserName Administrator -PasswordEnv TCAUTO_UNIT_ROUTE_PW
    Check 'AddAdsRoute bad NetId -> INVALID_PARAMS' ($r.error.code -eq 'INVALID_PARAMS') (J $r.error)
    $r = Add-TcAdsRoute -Name CX-1 -NetId 5.1.2.3.1.1 -Address 192.168.1.20 -HostName cx1 -UserName Administrator -PasswordEnv TCAUTO_UNIT_ROUTE_PW
    Check 'AddAdsRoute Address and HostName -> INVALID_PARAMS' ($r.error.code -eq 'INVALID_PARAMS') (J $r.error)
    $r = Add-TcAdsRoute -Name CX-1 -NetId 5.1.2.3.1.1 -Address 192.168.1.20 -UserName Administrator -PasswordEnv TCAUTO_UNIT_ROUTE_PW
    Check 'AddAdsRoute dry-run: fields with password ***, source env, nothing sent, no secret anywhere' ($r.success -and $r.data.dryRun -and $r.data.fields.Password -eq '***' -and $r.data.passwordSource -eq 'env:TCAUTO_UNIT_ROUTE_PW' -and @(Get-MockWrites).Count -eq 0 -and (Test-NoSecret $r)) (J $r.data)
    $r = Add-TcAdsRoute -Name CX-1 -NetId 5.1.2.3.1.1 -Address 192.168.1.20 -UserName Administrator -PasswordEnv TCAUTO_UNIT_ROUTE_PW -DryRun $false
    Check 'AddAdsRoute live: AddRoute sent with the real password, route read back, verified' ($r.success -and $r.data.verified -and @($r.data.readback)[0].netId -eq '5.1.2.3.1.1' -and $global:T.LastXml -match "<Password>$([regex]::Escape($Secret))</Password>" -and $global:T.LastXml -match '<RemoteNetId>5.1.2.3.1.1</RemoteNetId>') (J $r.data)
    Check 'AddAdsRoute live: no secret in the result or the backup, no BUILD_REQUIRED (not a project change)' ((Test-NoSecret $r ([string]$r.data.backupPath)) -and (Test-Path -LiteralPath ([string]$r.data.backupPath)) -and $null -eq (Get-CodeChanged)) "$($r.data.backupPath)"
    $r = Add-TcAdsRoute -Name CX-1 -NetId 5.1.2.3.1.1 -Address 192.168.1.20 -UserName Administrator -PasswordEnv TCAUTO_UNIT_ROUTE_PW -DryRun $false
    Check 'AddAdsRoute same NetId again -> ROUTE_ALREADY_EXISTS' ($r.error.code -eq 'ROUTE_ALREADY_EXISTS') (J $r.error)
    Reset-Mock; Reset-BuildRequired; $global:T.Mode = 'add-fail'
    $r = Add-TcAdsRoute -Name CX-1 -NetId 5.1.2.3.1.1 -Address 192.168.1.20 -UserName Administrator -PasswordEnv TCAUTO_UNIT_ROUTE_PW -DryRun $false
    Check 'AddAdsRoute XAE error quoting XML and password -> ROUTE_ADD_FAILED, message without secret / XML' ($r.error.code -eq 'ROUTE_ADD_FAILED' -and (Test-NoSecret $r) -and $r.error.message -notmatch '<RemoteNetId>') (J $r.error)
    Reset-Mock; Reset-BuildRequired; $global:T.Mode = 'add-noop'
    $sec = ConvertTo-SecureString $Secret -AsPlainText -Force
    $r = Add-TcAdsRoute -Name CX-1 -NetId 5.1.2.3.1.1 -Address 192.168.1.20 -UserName Administrator -Password $sec -DryRun $false
    Check 'AddAdsRoute SecureString, route not in TIRR afterwards -> ROUTE_VERIFY_FAILED, no secret' ($r.error.code -eq 'ROUTE_VERIFY_FAILED' -and $r.data.passwordSource -eq 'SecureString' -and $global:T.LastXml.Contains($Secret) -and (Test-NoSecret $r)) (J $r.error)
    Reset-Mock; Reset-BuildRequired
    $r = Add-TcAdsRoute -Name CX-1 -NetId 5.1.2.3.1.1 -Address 192.168.1.20 -ProjectRoute -UserName x
    Check 'AddAdsRoute -ProjectRoute with credentials -> INVALID_PARAMS' ($r.error.code -eq 'INVALID_PARAMS') (J $r.error)
    $r = Add-TcAdsRoute -Name CX-1 -NetId 5.1.2.3.1.1 -Address 192.168.1.20 -ProjectRoute -DryRun $false
    Check 'AddAdsRoute -ProjectRoute: AddProjectRoute, ProjectRoutes read back, BUILD_REQUIRED' ($r.success -and $global:T.LastXml -match '<AddProjectRoute><Name>CX-1</Name><NetId>5.1.2.3.1.1</NetId><IpAddr>192.168.1.20</IpAddr></AddProjectRoute>' -and (Get-CodeChanged) -match 'Add-TcAdsRoute') (J $r.data)
    Reset-Mock; Reset-BuildRequired; $global:T.Dialog = New-MockDialog
    $r = Add-TcAdsRoute -Name CX-1 -NetId 5.1.2.3.1.1 -Address 192.168.1.20 -UserName Administrator -PasswordEnv TCAUTO_UNIT_ROUTE_PW -DryRun $false
    Check 'AddAdsRoute modal dialog -> IDE_MODAL_DIALOG, nothing sent' ($r.error.code -eq 'IDE_MODAL_DIALOG' -and @(Get-MockWrites).Count -eq 0 -and (Test-NoSecret $r)) (J $r.error)

    # ===== hints / tools.json
    foreach ($c in @('ROUTE_READ_FAILED', 'ROUTE_SEARCH_REQUIRES_LOCAL_TARGET', 'ROUTE_SEARCH_FAILED', 'ROUTE_ALREADY_EXISTS', 'ROUTE_PASSWORD_MISSING', 'ROUTE_ADD_FAILED', 'ROUTE_VERIFY_FAILED')) {
        $h = & $mod { param($k) Get-TcErrorHint -Code $k } $c
        Check "hint $c" (-not [string]::IsNullOrWhiteSpace($h)) "$h"
    }
    $tools = @((Get-Content -Raw -Encoding UTF8 (Join-Path $PSScriptRoot '..\..\mcp-server\tools.json') | ConvertFrom-Json).tools)
    $byName = @{}; foreach ($tt in $tools) { $byName[$tt.name] = $tt }
    $tt = $byName['AddAdsRoute']
    Check 'tools.json AddAdsRoute: destructive, DryRun true, PasswordEnv offered, no Password parameter, NOT MEASURED in the description' ($null -ne $tt -and $tt.annotations.destructiveHint -eq $true -and $tt.inputSchema.properties.DryRun.default -eq $true -and $null -ne $tt.inputSchema.properties.PasswordEnv -and $null -eq $tt.inputSchema.properties.Password -and $tt.description -match '^NOT MEASURED') (J $tt.inputSchema.properties.PSObject.Properties.Name)
    Check 'tools.json GetAdsRoutes read-only, FindAdsTargets present' ($byName['GetAdsRoutes'].annotations.readOnlyHint -eq $true -and $null -ne $byName['FindAdsTargets']) ''
    Check 'tools.json has no RemoveAdsRoute (not supported)' ($null -eq $byName['RemoveAdsRoute']) ''
}
catch {
    Check 'unexpected-exception' $false "$($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber)"
}
finally {
    & $mod { $script:TcIdeConnected = $false; $script:TcSolutionPath = $null }
    Remove-Item Env:\TCAUTO_UNIT_ROUTE_PW -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $env:TCAUTO_STATE_DIR -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\TCAUTO_STATE_DIR -ErrorAction SilentlyContinue
}

"failed: $fail"
exit [Math]::Min($fail, 255)
