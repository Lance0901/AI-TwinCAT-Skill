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
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
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
$env:TCAUTO_ROUTE_PW_UNIT = $Secret
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
    # review S3: counter-examples of the reviewer (scratchpad mask.ps1): CDATA, entities, child elements,
    # comments, Passwd / Pwd, every matching attribute, '>' inside another attribute
    $cases = @(
        '<a><Password>s3cret</Password></a>', '<a><password>s3cret</password></a>', '<a><LogonPassword>s3cret</LogonPassword></a>',
        '<a><Password><![CDATA[s3cret]]></Password></a>', '<a><Password>s3&amp;cret</Password></a>', '<a Password="s3cret" Pwd="s3cret2"/>',
        '<a Name="x>y" Password="s3cret"/>', '<a><Password><Value>s3cret</Value></Password></a>', '<a><Passwd>s3cret</Passwd></a>',
        '<a><Password>s3cret<!-- c --></Password></a>', '<a><UserPassword xml:space="preserve">s3cret</UserPassword></a>')
    foreach ($c in $cases) {
        $m = & $mod { param($x) ConvertTo-TcMaskedXml -Xml $x } $c
        Check "S3 mask: $c" (-not ($m -match 's3') -and $m -match '\*\*\*') $m
    }
    $m = & $mod { ConvertTo-TcMaskedXml -Xml 'failed: <Password>abc</Pass' }
    Check 'S3 mask: text that does not parse but holds password -> (masked)' ($m -eq '(masked)') $m
    $m = & $mod { ConvertTo-TcMaskedXml -Xml 'plain message without secrets' }
    Check 'S3 mask: other text unchanged' ($m -eq 'plain message without secrets') $m
    # review S4: the XML-escaped secret is replaced as well
    $p1 = & $mod { Protect-TcSecretText -Text 'failed: <Password>p&amp;w</Password> Error parsing: TreeItem/RoutePrj/AddRoute' -Secret 'p&w' }
    $p2 = & $mod { Protect-TcSecretText -Text "ConsumeXml '<TreeItem><RoutePrj><AddRoute><Password>p&amp;w</Password></AddRoute></RoutePrj></TreeItem>' failed" -Secret 'p&w' }
    $p3 = & $mod { Protect-TcSecretText -Text "value 'p&amp;w' is invalid" -Secret 'p&w' }
    Check 'S4 Protect-TcSecretText: escaped secret, fragments and password elements scrubbed' (-not ("$p1$p2$p3" -match 'p&amp;w|p&w') -and $p2 -match '\(omitted\)' -and $p3 -eq "value '***' is invalid") "$p1 | $p2 | $p3"
    # review S5: password fields in the generic ConsumeXml
    Reset-Mock
    $r = Set-TcTreeItemXml -Path 'TISY' -Xml '<TreeItem><BootSettings><LogonPassword>new-pw-123</LogonPassword></BootSettings></TreeItem>' -DryRun $false
    Check 'S5 ConsumeXml only a password field -> XML_MERGE_FAILED secret-only, nothing sent' ($r.error.code -eq 'XML_MERGE_FAILED' -and $r.data.reason -eq 'secret-only' -and @(Get-MockWrites).Count -eq 0 -and -not ((J $r) -match 'new-pw-123')) (J $r)
    $r = Set-TcTreeItemXml -Path 'TISY' -Xml '<TreeItem><BootSettings><LogonPassword>***</LogonPassword></BootSettings></TreeItem>' -DryRun $false
    Check 'S5 fragment value *** is not "unchanged" -> secret-only (would set the password to ***)' ($r.error.code -eq 'XML_MERGE_FAILED' -and $r.data.reason -eq 'secret-only' -and @(Get-MockWrites).Count -eq 0) (J $r)
    $r = Set-TcTreeItemXml -Path 'TISY' -Xml '<TreeItem><BootSettings><AutoLogon>false</AutoLogon><LogonPassword>new-pw-123</LogonPassword></BootSettings></TreeItem>'
    Check 'S5 dry-run with a password field: data.changes masks both values, warning' ($r.success -and @($r.data.changes | Where-Object { $_.secret -and $_.current -eq '***' -and $_.planned -eq '***' }).Count -eq 1 -and -not ((J $r) -match 'new-pw-123|Xy7-unit') -and @($r.data.warnings | Where-Object { $_ -like '*password fields*' }).Count -eq 1) (J $r.data)
    $r = Set-TcTreeItemXml -Path 'TISY' -Xml '<TreeItem><BootSettings><AutoLogon>false</AutoLogon><LogonPassword>new-pw-123</LogonPassword></BootSettings></TreeItem>' -DryRun $false
    Check 'S5 live with a password field: verified on the other fields, password not compared, no secret returned' ($r.success -and $r.data.verified -and @($r.data.skippedSecret) -contains 'TreeItem/BootSettings/LogonPassword' -and -not ((J $r) -match 'new-pw-123|Xy7-unit') -and -not ([System.IO.File]::ReadAllText([string]$r.data.backupPath)).Contains($Secret)) (J $r.data)
    $hv = & $mod { Get-TcErrorHint -Code 'TREEITEM_VERIFY_FAILED' }
    Check 'S5 TREEITEM_VERIFY_FAILED hint: backups cannot restore a password' ($hv -match '\*\*\*') $hv
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
    # 4.6 N4: no PowerShell-only parameter (-Password) in the message, the MCP side has none
    Check 'N4 ROUTE_PASSWORD_MISSING message names -PasswordEnv, no -Password parameter' ($r.error.message -match '-PasswordEnv' -and $r.error.message -notmatch '-Password(?!Env)') (J $r.error)
    $sec = New-Object System.Security.SecureString; $sec.AppendChar('x'); $sec.MakeReadOnly()
    $r = Add-TcAdsRoute -Name CX-1 -NetId 5.1.2.3.1.1 -Address 192.168.1.20 -UserName Administrator -PasswordEnv TCAUTO_ROUTE_PW_UNIT -Password $sec
    Check 'N4 both password sources -> ROUTE_PASSWORD_MISSING, message without -Password' ($r.error.code -eq 'ROUTE_PASSWORD_MISSING' -and $r.error.message -match 'not two' -and $r.error.message -notmatch '-Password(?!Env)') (J $r.error)
    $r = Add-TcAdsRoute -Name CX-1 -NetId 5.1.2.3.1.1 -Address 192.168.1.20 -ProjectRoute -PasswordEnv TCAUTO_ROUTE_PW_UNIT
    Check 'N4 -ProjectRoute with -PasswordEnv -> INVALID_PARAMS, message without -Password' ($r.error.code -eq 'INVALID_PARAMS' -and $r.error.message -notmatch '-Password(?!Env)') (J $r.error)
    $r = Add-TcAdsRoute -Name CX-1 -NetId 5.1.2.3.1.1 -Address 192.168.1.20 -UserName Administrator -PasswordEnv TCAUTO_ROUTE_PW_NOT_SET_X
    Check 'AddAdsRoute empty environment variable -> ROUTE_PASSWORD_MISSING, hint PasswordEnv' ($r.error.code -eq 'ROUTE_PASSWORD_MISSING' -and $r.error.hint -match 'PasswordEnv') (J $r.error)
    $r = Add-TcAdsRoute -Name CX-1 -NetId 5.1.2.3.1.1 -Address 192.168.1.20 -UserName Administrator -PasswordEnv PATH
    Check 'B1 AddAdsRoute -PasswordEnv PATH (not TCAUTO_ROUTE_PW*) -> INVALID_PARAMS, nothing read' ($r.error.code -eq 'INVALID_PARAMS' -and $r.error.message -match 'TCAUTO_ROUTE_PW') (J $r.error)
    $r = Add-TcAdsRoute -Name CX-1 -NetId 5.1.2.3.1.1 -Address 192.168.1.20 -UserName Administrator -PasswordEnv tcauto_route_pw_unit
    Check 'B1 AddAdsRoute -PasswordEnv lower case -> INVALID_PARAMS' ($r.error.code -eq 'INVALID_PARAMS') (J $r.error)
    $src = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\Public\Add-TcAdsRoute.ps1'))
    Check 'B1 AddAdsRoute reads the Process scope only (no User scope fallback)' (-not ($src -match "GetEnvironmentVariable\([^)]*'User'")) ''
    $r = Add-TcAdsRoute -Name CX-1 -NetId 5.1.2.3.1 -Address 192.168.1.20 -UserName Administrator -PasswordEnv TCAUTO_ROUTE_PW_UNIT
    Check 'AddAdsRoute bad NetId -> INVALID_PARAMS' ($r.error.code -eq 'INVALID_PARAMS') (J $r.error)
    $r = Add-TcAdsRoute -Name CX-1 -NetId 5.1.2.3.1.1 -Address 192.168.1.20 -HostName cx1 -UserName Administrator -PasswordEnv TCAUTO_ROUTE_PW_UNIT
    Check 'AddAdsRoute Address and HostName -> INVALID_PARAMS' ($r.error.code -eq 'INVALID_PARAMS') (J $r.error)
    $r = Add-TcAdsRoute -Name CX-1 -NetId 5.1.2.3.1.1 -Address 192.168.1.20 -UserName Administrator -PasswordEnv TCAUTO_ROUTE_PW_UNIT
    Check 'AddAdsRoute dry-run: fields with password ***, source env, nothing sent, no secret anywhere' ($r.success -and $r.data.dryRun -and $r.data.fields.Password -eq '***' -and $r.data.passwordSource -eq 'env:TCAUTO_ROUTE_PW_UNIT' -and @(Get-MockWrites).Count -eq 0 -and (Test-NoSecret $r)) (J $r.data)
    $r = Add-TcAdsRoute -Name CX-1 -NetId 5.1.2.3.1.1 -Address 192.168.1.20 -UserName Administrator -PasswordEnv TCAUTO_ROUTE_PW_UNIT -DryRun $false
    Check 'S13 AddAdsRoute sends only <RoutePrj> below <TreeItem> (no ItemName / PathName)' ($global:T.LastXml.StartsWith('<TreeItem><RoutePrj><AddRoute>')) ''
    Check 'AddAdsRoute live: AddRoute sent with the real password, route read back, verified' ($r.success -and $r.data.verified -and @($r.data.readback)[0].netId -eq '5.1.2.3.1.1' -and $global:T.LastXml -match "<Password>$([regex]::Escape($Secret))</Password>" -and $global:T.LastXml -match '<RemoteNetId>5.1.2.3.1.1</RemoteNetId>') (J $r.data)
    Check 'AddAdsRoute live: no secret in the result or the backup, no BUILD_REQUIRED (not a project change)' ((Test-NoSecret $r ([string]$r.data.backupPath)) -and (Test-Path -LiteralPath ([string]$r.data.backupPath)) -and $null -eq (Get-CodeChanged)) "$($r.data.backupPath)"
    $r = Add-TcAdsRoute -Name CX-1 -NetId 5.1.2.3.1.1 -Address 192.168.1.20 -UserName Administrator -PasswordEnv TCAUTO_ROUTE_PW_UNIT -DryRun $false
    Check 'AddAdsRoute same NetId again -> ROUTE_ALREADY_EXISTS' ($r.error.code -eq 'ROUTE_ALREADY_EXISTS') (J $r.error)
    Reset-Mock; Reset-BuildRequired; $global:T.Mode = 'add-fail'
    $r = Add-TcAdsRoute -Name CX-1 -NetId 5.1.2.3.1.1 -Address 192.168.1.20 -UserName Administrator -PasswordEnv TCAUTO_ROUTE_PW_UNIT -DryRun $false
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
    $r = Add-TcAdsRoute -Name CX-1 -NetId 5.1.2.3.1.1 -Address 192.168.1.20 -UserName Administrator -PasswordEnv TCAUTO_ROUTE_PW_UNIT -DryRun $false
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
    Check 'tools.json GetAdsRoutes read-only; N3 FindAdsTargets read-only + openWorld' ($byName['GetAdsRoutes'].annotations.readOnlyHint -eq $true -and $byName['FindAdsTargets'].annotations.readOnlyHint -eq $true -and $byName['FindAdsTargets'].annotations.openWorldHint -eq $true) (J $byName['FindAdsTargets'].annotations)
    Check 'tools.json AddAdsRoute description names the TCAUTO_ROUTE_PW rule' ($byName['AddAdsRoute'].description -match 'TCAUTO_ROUTE_PW') ''
    Check 'tools.json has no RemoveAdsRoute (not supported)' ($null -eq $byName['RemoveAdsRoute']) ''
}
catch {
    Check 'unexpected-exception' $false "$($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber)"
}
finally {
    & $mod { $script:TcIdeConnected = $false; $script:TcSolutionPath = $null }
    Remove-Item Env:\TCAUTO_ROUTE_PW_UNIT -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $env:TCAUTO_STATE_DIR -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\TCAUTO_STATE_DIR -ErrorAction SilentlyContinue
}

"failed: $fail"
exit [Math]::Min($fail, 255)
