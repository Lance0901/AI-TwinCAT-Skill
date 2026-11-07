# Unit: Get-TcPlcLoginState (#188), no IDE / runtime needed. The SysManager tree items are mocked; the
# real helper runs with Invoke-TcComRetry replaced by a pass-through that can throw per operation.
# Covers: IsLoggedIn readable (true / false), IsLoggedIn throws -> ProduceXml, IsLoggedIn missing ($null,
# a COM property that does not exist) -> ProduceXml, both fail -> loggedIn null with error, an XML
# without LoggedIn -> null, IDE_* exceptions are rethrown from either source.
#   powershell.exe -NoProfile -File tests/Unit/plc-login-state-188.ps1
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

# The "<Plc> Project" ProduceXml shape (實測 2026-11-08, 4026 VS2022 + local UmRT, shortened)
function ProjXml([string]$LoggedIn) {
    $li = if ($null -eq $LoggedIn) { '' } else { "<LoggedIn>$LoggedIn</LoggedIn>" }
    "<TreeItem><ItemName>plc Project</ItemName><IECProjectDef><OnlineSettings>$li<PlcAppState>Run</PlcAppState></OnlineSettings></IECProjectDef></TreeItem>"
}

& $mod {
    # $script:UtIsLoggedIn: value of the node's IsLoggedIn ($null = property missing)
    # $script:UtThrow: OperationName pattern -> message thrown by the retry wrapper
    $script:UtIsLoggedIn = $null
    $script:UtXml = $null
    $script:UtThrow = @{}
    $script:UtOps = [System.Collections.Generic.List[string]]::new()
    function script:Invoke-TcComRetry {
        param([int]$MaxRetries, [string]$OperationName, [int]$TimeoutSec, [scriptblock]$ScriptBlock)
        $script:UtOps.Add($OperationName)
        foreach ($k in $script:UtThrow.Keys) { if ($OperationName -like $k) { throw $script:UtThrow[$k] } }
        & $ScriptBlock
    }
    $script:UtSm = [PSCustomObject]@{ Mock = $true }
    $script:UtSm | Add-Member -MemberType ScriptMethod -Name LookupTreeItem -Value {
        param($p)
        if ($p -eq 'TIPC^plc') { return [PSCustomObject]@{ Name = 'plc'; IsLoggedIn = $script:UtIsLoggedIn } }
        if ($p -eq 'TIPC^plc^plc Project') {
            $o = [PSCustomObject]@{ Name = 'plc Project' }
            $o | Add-Member -MemberType ScriptMethod -Name ProduceXml -Value { param($r) $script:UtXml }
            return $o
        }
        return $null
    }
}
$plc = [PSCustomObject]@{ name = 'plc'; nodePath = 'TIPC^plc'; projectPath = 'TIPC^plc^plc Project'; adsPort = 851; disabled = $false; projectFile = $null }
function Set-Case($IsLoggedIn, $Xml, [hashtable]$Throw) {
    & $mod { param($a, $b, $c) $script:UtIsLoggedIn = $a; $script:UtXml = $b; $script:UtThrow = $c; $script:UtOps.Clear() } $IsLoggedIn $Xml $(if ($null -eq $Throw) { @{} } else { $Throw })
}
function Get-State { & $mod { param($p) Get-TcPlcLoginState -SysManager $script:UtSm -Plc $p } $plc }
function Get-Ops { & $mod { @($script:UtOps) } }

# --- IsLoggedIn readable
Set-Case $true (ProjXml 'false') $null
$s = Get-State
Check 'IsLoggedIn true -> loggedIn true, source IsLoggedIn, no ProduceXml call' ($s.plc -eq 'plc' -and $s.loggedIn -eq $true -and $s.source -eq 'IsLoggedIn' -and $null -eq $s.error -and @(Get-Ops | Where-Object { $_ -like 'ProduceXml*' }).Count -eq 0) (J $s)
Set-Case $false (ProjXml 'true') $null
$s = Get-State
Check 'IsLoggedIn false -> loggedIn false (not null), source IsLoggedIn' ($s.loggedIn -is [bool] -and $s.loggedIn -eq $false -and $s.source -eq 'IsLoggedIn') (J $s)

# --- IsLoggedIn throws (not an IDE_* error) -> ProduceXml
Set-Case $null (ProjXml 'true') @{ 'IsLoggedIn*' = 'unit: Unknown name. (Exception from HRESULT: 0x80020006 (DISP_E_UNKNOWNNAME))' }
$s = Get-State
Check 'IsLoggedIn throws -> ProduceXml LoggedIn true, error keeps the IsLoggedIn failure' ($s.loggedIn -eq $true -and $s.source -eq 'ProduceXml' -and $s.error -match '^IsLoggedIn: unit: Unknown name') (J $s)
Set-Case $null (ProjXml ' False ') @{ 'IsLoggedIn*' = 'unit: no such member' }
$s = Get-State
Check 'IsLoggedIn throws -> ProduceXml LoggedIn " False " -> false' ($s.loggedIn -is [bool] -and $s.loggedIn -eq $false -and $s.source -eq 'ProduceXml') (J $s)

# --- IsLoggedIn missing (COM property that does not exist reads $null) -> ProduceXml
Set-Case $null (ProjXml 'true') $null
$s = Get-State
Check 'IsLoggedIn null -> ProduceXml, error says not readable' ($s.loggedIn -eq $true -and $s.source -eq 'ProduceXml' -and $s.error -match 'IsLoggedIn: not readable') (J $s)
Set-Case 'yes' (ProjXml 'false') $null
$s = Get-State
Check 'IsLoggedIn not a bool -> not trusted, ProduceXml false' ($s.loggedIn -eq $false -and $s.source -eq 'ProduceXml') (J $s)

# --- both fail -> null
Set-Case $null $null @{ 'IsLoggedIn*' = 'unit: boom 1'; 'ProduceXml*' = 'unit: boom 2' }
$s = Get-State
Check 'both throw -> loggedIn null, source null, error names both' ($null -eq $s.loggedIn -and $null -eq $s.source -and $s.error -match 'IsLoggedIn: unit: boom 1' -and $s.error -match 'ProduceXml: unit: boom 2') (J $s)
Set-Case $null (ProjXml $null) $null
$s = Get-State
Check 'no IsLoggedIn, XML without LoggedIn -> null' ($null -eq $s.loggedIn -and $null -eq $s.source -and $s.error -match 'no IECProjectDef/OnlineSettings/LoggedIn') (J $s)
Set-Case $null '<TreeItem><broken' $null
$s = Get-State
Check 'no IsLoggedIn, XML not parseable -> null with error' ($null -eq $s.loggedIn -and $s.error -match 'ProduceXml: ') (J $s)
Set-Case $null (ProjXml 'maybe') $null
$s = Get-State
Check 'LoggedIn neither true nor false -> null' ($null -eq $s.loggedIn -and $null -eq $s.source) (J $s)
$s = & $mod { Get-TcPlcLoginState -SysManager $script:UtSm -Plc ([PSCustomObject]@{ name = 'gone'; nodePath = 'TIPC^gone'; projectPath = 'TIPC^gone^gone Project' }) }
Check 'tree items not found -> null, error says not found' ($s.plc -eq 'gone' -and $null -eq $s.loggedIn -and $s.error -match "tree item 'TIPC\^gone' not found" -and $s.error -match "tree item 'TIPC\^gone\^gone Project' not found") (J $s)
# only a name given: node / project paths are built from it
Set-Case $true $null $null
$s = & $mod { Get-TcPlcLoginState -SysManager $script:UtSm -Plc ([PSCustomObject]@{ name = 'plc' }) }
Check 'only name -> TIPC^plc looked up, IsLoggedIn true' ($s.loggedIn -eq $true -and $s.source -eq 'IsLoggedIn') (J $s)

# --- IDE_* exceptions are rethrown (not swallowed into loggedIn null)
foreach ($code in @('IDE_MODAL_DIALOG', 'IDE_TIMEOUT', 'IDE_BUSY', 'IDE_CRASHED')) {
    Set-Case $null (ProjXml 'true') @{ 'IsLoggedIn*' = "${code}: unit" }
    $got = $null
    try { $null = Get-State; $got = 'no exception' } catch { $got = $_.Exception.Message }
    Check "$code on IsLoggedIn -> rethrown" ($got -match "^${code}:") $got
    Set-Case $null (ProjXml 'true') @{ 'ProduceXml*' = "${code}: unit" }
    $got = $null
    try { $null = Get-State; $got = 'no exception' } catch { $got = $_.Exception.Message }
    Check "$code on ProduceXml -> rethrown" ($got -match "^${code}:") $got
}

exit [Math]::Min($fail, 255)
