# Unit: #232 Enter-TcPlcOnline / Exit-TcPlcOnline read the login state back (fail closed, #68,
# CODING_STANDARDS 2). No IDE / runtime: the SysManager, the tree items and Get-TcPlcLoginState are mocked.
# Covers:
#   Exit:  logged in -> Logoff -> read back false -> success, data.loggedIn false
#          still true after Logoff -> LOGOUT_FAILED (data.loggedIn true)
#          read back unknown after Logoff -> LOGOUT_FAILED (fail closed, data.loggedIn null)
#          already logged out (read back false before) -> success, alreadyLoggedOut, no Logoff sent
#          plcNode.Logoff missing -> treeItem.Logoff (logoutVia)
#   Enter: Login returns, read back true -> success, data.loggedIn true
#          Login returns, read back false (Login(257) on 4026, #232) -> LOGIN_FAILED, data.loggedIn false
#          read back unknown -> LOGIN_FAILED (fail closed), data.loggedIn null
#   Enable-TcConfig login step: a nested Enter-TcPlcOnline success without loggedIn = true is not a login
#          (LOGIN_FAILED, loggedIn false) - covered in lifecycle-block.ps1 mocks returning loggedIn.
#   powershell.exe -NoProfile -File tests/Unit/plc-login-readback-232.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 600) { $Detail = $Detail.Substring(0, 600) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}
function J($o) { $o | ConvertTo-Json -Compress -Depth 6 }

& $mod {
    # $script:UtStates: queue of login states Get-TcPlcLoginState returns ($true / $false / $null), in call order
    $script:UtStates = [System.Collections.Generic.Queue[object]]::new()
    $script:UtCalls = [System.Collections.Generic.List[string]]::new()
    $script:UtNodeHasLogoff = $false
    function script:Assert-TcConnection { }
    function script:Test-TcLifecycleBlock { param($AmsNetId, $Command) $null }
    function script:Resolve-TcLifecycleNetId { param($SysManager) '1.2.3.4.1.1' }
    function script:Get-TcResetRequiredGuard { $null }
    function script:Get-TcBuildRequired { $null }
    function script:Find-TcIdeModalDialog { $null }
    function script:New-TcAdsClient { param($AmsNetId, $Port) throw 'unit: no ADS' }
    function script:Get-TcPlcProjectList { param($SysManager) @([PSCustomObject]@{ name = 'plc'; nodePath = 'TIPC^plc'; projectPath = 'TIPC^plc^plc Project'; adsPort = 851; disabled = $false; projectFile = $null }) }
    function script:Resolve-TcPlcProjectPath { param($SysManager, [switch]$RequireSingle) 'TIPC^plc^plc Project' }
    function script:Invoke-TcComRetry {
        param([int]$MaxRetries, [string]$OperationName, [int]$TimeoutSec, [scriptblock]$ScriptBlock)
        & $ScriptBlock
    }
    function script:Get-TcPlcLoginState {
        param($SysManager, $Plc)
        $script:UtCalls.Add("LoginState $($Plc.name)")
        $v = if ($script:UtStates.Count -gt 0) { $script:UtStates.Dequeue() } else { $null }
        [PSCustomObject]@{ plc = $Plc.name; loggedIn = $v; source = $(if ($null -eq $v) { $null } else { 'ProduceXml' }); error = $(if ($null -eq $v) { 'unit: unreadable' } else { $null }) }
    }
    $script:UtSm = [PSCustomObject]@{ Mock = $true }
    $script:UtSm | Add-Member -MemberType ScriptMethod -Name GetTargetNetId -Value { '1.2.3.4.1.1' }
    $script:UtSm | Add-Member -MemberType ScriptMethod -Name LookupTreeItem -Value {
        param($p)
        if ($p -eq 'TIPC^plc') {
            $n = [PSCustomObject]@{ Name = 'plc' }
            if ($script:UtNodeHasLogoff) { $n | Add-Member -MemberType ScriptMethod -Name Logoff -Value { $script:UtCalls.Add('plcNode.Logoff') } }
            return $n
        }
        if ($p -eq 'TIPC^plc^plc Project') {
            $o = [PSCustomObject]@{ Name = 'plc Project' }
            $o | Add-Member -MemberType ScriptMethod -Name Logoff -Value { $script:UtCalls.Add('treeItem.Logoff') }
            $o | Add-Member -MemberType ScriptMethod -Name Login -Value { param($f) $script:UtCalls.Add("Login($f)") }
            return $o
        }
        return $null
    }
    function script:Get-TcSysManager { $script:UtSm }
}
function Set-Case([object[]]$States, [bool]$NodeHasLogoff = $false) {
    & $mod { param($s, $n) $script:UtStates.Clear(); foreach ($x in $s) { $script:UtStates.Enqueue($x) }; $script:UtCalls.Clear(); $script:UtNodeHasLogoff = $n } $States $NodeHasLogoff
}
function Get-Calls { & $mod { @($script:UtCalls) } }
function Has-Prop($o, [string]$n) { $null -ne $o -and $null -ne $o.PSObject.Properties[$n] }

# ---------------- Exit-TcPlcOnline
Set-Case @($true, $false)
$r = & $mod { Exit-TcPlcOnline }
$c = Get-Calls
Check 'Exit: logged in -> Logoff -> read back false -> success, loggedIn false' ($r.success -and (Has-Prop $r.data 'loggedIn') -and $r.data.loggedIn -eq $false -and $r.data.loggedIn -is [bool] -and $r.data.alreadyLoggedOut -eq $false -and $r.data.logoutVia -eq 'treeItem.Logoff' -and $r.data.loginStateSource -eq 'ProduceXml') ((J $r) + ' calls=' + ($c -join ','))
Check 'Exit: plcNode without Logoff -> treeItem.Logoff was called once' (@($c | Where-Object { $_ -eq 'treeItem.Logoff' }).Count -eq 1) ($c -join ',')

Set-Case @($true, $false) $true
$r = & $mod { Exit-TcPlcOnline }
Check 'Exit: plcNode with Logoff -> logoutVia plcNode.Logoff' ($r.success -and $r.data.logoutVia -eq 'plcNode.Logoff') (J $r)

Set-Case @($true, $true)
$r = & $mod { Exit-TcPlcOnline }
Check 'Exit: still logged in after Logoff -> LOGOUT_FAILED, loggedIn true' ((-not $r.success) -and $r.error.code -eq 'LOGOUT_FAILED' -and $r.data.loggedIn -eq $true -and $r.data.online -eq $true) (J $r)

Set-Case @($true, $null)
$r = & $mod { Exit-TcPlcOnline }
Check 'Exit: read back unknown after Logoff -> LOGOUT_FAILED (fail closed), loggedIn null' ((-not $r.success) -and $r.error.code -eq 'LOGOUT_FAILED' -and (Has-Prop $r.data 'loggedIn') -and $null -eq $r.data.loggedIn -and $r.error.message -match 'unknown|could not be read') (J $r)

Set-Case @($false)
$r = & $mod { Exit-TcPlcOnline }
$c = Get-Calls
Check 'Exit: already logged out -> success, alreadyLoggedOut, no Logoff sent' ($r.success -and $r.data.loggedIn -eq $false -and $r.data.alreadyLoggedOut -eq $true -and $null -eq $r.data.logoutVia -and @($c | Where-Object { $_ -like '*Logoff' }).Count -eq 0) ((J $r) + ' calls=' + ($c -join ','))

Set-Case @($null, $false)
$r = & $mod { Exit-TcPlcOnline }
$c = Get-Calls
Check 'Exit: state unknown before -> Logoff sent, read back false -> success' ($r.success -and $r.data.loggedIn -eq $false -and $r.data.alreadyLoggedOut -eq $false -and @($c | Where-Object { $_ -like '*Logoff' }).Count -eq 1) ((J $r) + ' calls=' + ($c -join ','))

# ---------------- Enter-TcPlcOnline
Set-Case @($true)
$r = & $mod { Enter-TcPlcOnline -WarningAction SilentlyContinue }
$c = Get-Calls
Check 'Enter: Login, read back true -> success, loggedIn true' ($r.success -and $r.data.online -eq $true -and $r.data.loggedIn -eq $true -and $r.data.loginStateSource -eq 'ProduceXml' -and ($c -contains 'Login(1)') -and ($c -contains 'LoginState plc')) ((J $r) + ' calls=' + ($c -join ','))

Set-Case @($false)
$r = & $mod { Enter-TcPlcOnline -SilentFlag -WarningAction SilentlyContinue }
Check 'Enter: Login(257) returns but read back false -> LOGIN_FAILED, loggedIn false, online false' ((-not $r.success) -and $r.error.code -eq 'LOGIN_FAILED' -and $r.data.loggedIn -eq $false -and $r.data.online -eq $false -and $r.data.loginFlags -eq 257) (J $r)

Set-Case @($null)
$r = & $mod { Enter-TcPlcOnline -WarningAction SilentlyContinue }
Check 'Enter: read back unknown -> LOGIN_FAILED (fail closed), loggedIn null' ((-not $r.success) -and $r.error.code -eq 'LOGIN_FAILED' -and (Has-Prop $r.data 'loggedIn') -and $null -eq $r.data.loggedIn -and $r.error.message -match 'unknown|could not be read') (J $r)

"FAILED: $fail"
exit $fail
