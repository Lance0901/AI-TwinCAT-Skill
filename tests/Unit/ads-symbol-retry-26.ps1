. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
# Unit: #26 Read-TcVariable retries once after ADS 0x711 (symbol version invalid after a new download):
# the ADS session is reopened (Connect-TcAdsSession with the cached AmsNetId / Port) and the read
# repeated; the entry has symbolsReloaded = true. A second 0x711 is reported (ADS_SYMBOL_VERSION_INVALID),
# other errors never reopen the session, and a normal read has symbolsReloaded = false.
# No ADS / runtime: Ensure-TcAdsConnection, Find-TcAdsAssembly, Read-TcAdsSymbolValue and
# Connect-TcAdsSession are stubbed in module scope.
#   powershell.exe -NoProfile -File tests/Unit/ads-symbol-retry-26.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 600) { $Detail = $Detail.Substring(0, 600) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}
function J($o) { ConvertTo-Json -InputObject $o -Depth 8 -Compress }

# $global:Stale[path] = number of 0x711 answers left for that path; $global:Other = paths throwing 0x710
$global:Stale = @{}
$global:Other = @()
$global:Reconnects = 0
& $mod {
    function script:Ensure-TcAdsConnection { $false }
    function script:Find-TcAdsAssembly { $true }
    function script:Connect-TcAdsSession { param([string]$AmsNetId, [int]$Port) $global:Reconnects++; 'Run' }
    function script:Read-TcAdsSymbolValue {
        param([string]$VarPath)
        if ($global:Other -contains $VarPath) { throw 'Ads-Error 0x710 : Symbol could not be found.' }
        if ($global:Stale.ContainsKey($VarPath) -and $global:Stale[$VarPath] -gt 0) {
            $global:Stale[$VarPath]--
            throw 'Ads-Error 0x711 : Symbol version is invalid. (AdsErrorCode: 1809, 0x711)'
        }
        [ordered]@{ path = $VarPath; value = 400; type = 'LREAL' }
    }
    $script:TcAdsAmsNetId = '10.26.0.1.1.1'; $script:TcAdsPort = 851
}
function Reset-Case { $global:Stale = @{}; $global:Other = @(); $global:Reconnects = 0 }

# --- 1: one path, 0x711 once -> reopened, read again, success, symbolsReloaded
Reset-Case; $global:Stale['Main.PaperLength'] = 1
$r = Read-TcVariable -Path 'Main.PaperLength'
Check '1 0x711 once -> success, value read after the reconnect' ($r.success -and $r.data.value -eq 400) (J $r)
Check '1 symbolsReloaded = true, one reconnect' ($r.data.symbolsReloaded -eq $true -and $global:Reconnects -eq 1) "reconnects=$($global:Reconnects) $(J $r.data)"

# --- 2: normal read -> symbolsReloaded = false, no reconnect
Reset-Case
$r = Read-TcVariable -Path 'Main.PaperLength'
Check '2 normal read -> symbolsReloaded = false, no reconnect' ($r.success -and $r.data.symbolsReloaded -eq $false -and $global:Reconnects -eq 0) (J $r)

# --- 3: 0x711 twice -> one reconnect only, ADS_SYMBOL_VERSION_INVALID reported
Reset-Case; $global:Stale['Main.PaperLength'] = 2
$r = Read-TcVariable -Path 'Main.PaperLength'
Check '3 0x711 again after the reconnect -> failure with ADS_SYMBOL_VERSION_INVALID hint, one reconnect' ((-not $r.success) -and $global:Reconnects -eq 1 -and $r.error.hint -eq (& $mod { Get-TcErrorHint -Code 'ADS_SYMBOL_VERSION_INVALID' })) "reconnects=$($global:Reconnects) $(J $r.error)"

# --- 4: other ADS error (0x710) -> no reconnect
Reset-Case; $global:Other = @('MAIN.nope')
$r = Read-TcVariable -Path 'MAIN.nope'
Check '4 0x710 -> SYMBOL_NOT_FOUND, no reconnect' ((-not $r.success) -and $r.error.code -eq 'SYMBOL_NOT_FOUND' -and $global:Reconnects -eq 0) (J $r.error)

# --- 5: several paths, the 2nd stale -> later entries carry symbolsReloaded, earlier one not
Reset-Case; $global:Stale['Main.b'] = 1
$r = Read-TcVariable -Path @('Main.a', 'Main.b', 'Main.c')
$d = @($r.data)
Check '5 three paths, 2nd 0x711 once -> success, one reconnect' ($r.success -and $global:Reconnects -eq 1 -and $d.Count -eq 3) (J $r)
Check '5 symbolsReloaded false, true, true' ($d[0].symbolsReloaded -eq $false -and $d[1].symbolsReloaded -eq $true -and $d[2].symbolsReloaded -eq $true) (J $d)

# --- 6: no cached AmsNetId (never connected) -> no reconnect attempt, error passed on
Reset-Case; $global:Stale['Main.PaperLength'] = 1
& $mod { $script:TcAdsAmsNetId = $null }
$r = Read-TcVariable -Path 'Main.PaperLength'
Check '6 no AmsNetId -> 0x711 reported, no reconnect' ((-not $r.success) -and $global:Reconnects -eq 0) "reconnects=$($global:Reconnects) $(J $r.error)"
& $mod { $script:TcAdsAmsNetId = '10.26.0.1.1.1' }

# --- 7: Invoke-TcAdsSymbolRetry directly: output of the action is returned unchanged (no unrolling)
Reset-Case
$out = & $mod { $f = $false; $o = Invoke-TcAdsSymbolRetry -Reloaded ([ref]$f) -Action { [ordered]@{ a = 1; b = 2 } }; @{ o = $o; f = $f } }
Check '7 helper returns the ordered dictionary, Reloaded false' ($out.o -is [System.Collections.Specialized.OrderedDictionary] -and $out.o.b -eq 2 -and $out.f -eq $false) (J $out)

# --- 8: retry fails again -> later entries still say symbolsReloaded (the session WAS reopened)
Reset-Case; $global:Stale['Main.b'] = 2
$r = Read-TcVariable -Path @('Main.b', 'Main.c')
$d = @($r.data)
Check '8 retry fails -> PARTIAL_READ_FAILED, code on the entry, next entry symbolsReloaded = true' ((-not $r.success) -and $d[0].code -eq 'ADS_SYMBOL_VERSION_INVALID' -and $d[1].symbolsReloaded -eq $true -and $global:Reconnects -eq 1) (J $d)

# --- 9: the reopen itself fails -> NOT_CONNECTED, message names the 0x711
Reset-Case; $global:Stale['Main.PaperLength'] = 1
& $mod { function script:Connect-TcAdsSession { param([string]$AmsNetId, [int]$Port) $global:Reconnects++; $global:LastReopen = "$AmsNetId`:$Port"; throw 'Ads-Error 0x7 : Target machine could not be found.' } }
$r = Read-TcVariable -Path 'Main.PaperLength'
Check '9 reopen fails -> NOT_CONNECTED, message names 0x711, reopened with the cached NetId:port' ((-not $r.success) -and $r.error.code -eq 'NOT_CONNECTED' -and $r.error.message -match '0x711' -and $global:LastReopen -eq '10.26.0.1.1.1:851') "$($r.error.code) $($r.error.message) reopen=$($global:LastReopen)"

exit $fail
