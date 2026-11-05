. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
# Unit: #60 Read-TcVariable with several paths fails closed when any path fails:
# success = false, PARTIAL_READ_FAILED (hint from $script:TcErrorHints), data stays the array of every
# entry (#57), and the result has the top-level fields partial / failedPaths. All read: success = true,
# partial = false, failedPaths = []. One path: unchanged (SYMBOL_NOT_FOUND, no partial / failedPaths).
# No ADS / runtime: Ensure-TcAdsConnection, Find-TcAdsAssembly and Read-TcAdsSymbolValue are stubbed
# in module scope; a missing symbol throws "Ads-Error 0x710" like the real TcAdsHelper.
#   powershell.exe -NoProfile -File tests/Unit/read-variable-partial-60.ps1
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

$global:Missing = @()      # paths whose read throws ADS 0x710
$global:Unmapped = @()     # paths whose read throws an error without an ADS code
& $mod {
    function script:Ensure-TcAdsConnection { $false }
    function script:Find-TcAdsAssembly { $true }
    function script:Read-TcAdsSymbolValue {
        param([string]$VarPath)
        if ($global:Missing -contains $VarPath) { throw 'Ads-Error 0x710 : Symbol could not be found.' }
        if ($global:Unmapped -contains $VarPath) { throw 'Native call failed in the mock (no ADS code).' }
        [ordered]@{ path = $VarPath; value = 7; type = 'INT' }
    }
}
# what the MCP bridge sends (bridge.ps1: ConvertTo-Json -Depth 50 -Compress), read back
function Round([object]$R) { (ConvertTo-Json -InputObject $R -Depth 50 -Compress) | ConvertFrom-Json }

# --- 1: two paths, the second missing -> fail closed
$global:Missing = @('MAIN.nope'); $global:Unmapped = @()
$r = Read-TcVariable -Path @('MAIN.a', 'MAIN.nope')
Check '1 one of two paths missing -> success=false PARTIAL_READ_FAILED' ((-not $r.success) -and $r.error.code -eq 'PARTIAL_READ_FAILED') (J $r)
Check '1 hint from the hint table' (-not [string]::IsNullOrWhiteSpace($r.error.hint) -and $r.error.hint -eq (& $mod { Get-TcErrorHint -Code 'PARTIAL_READ_FAILED' })) "$($r.error.hint)"
Check '1 message names the failed path and its code, counts' ($r.error.message -match '1 of 2 paths' -and $r.error.message -match 'MAIN\.nope \(ADS_SYMBOL_NOT_FOUND\)') "$($r.error.message)"
Check '1 top level: partial = true, failedPaths = [MAIN.nope]' ($r.partial -eq $true -and (@($r.failedPaths) -join ',') -eq 'MAIN.nope') "partial=$($r.partial) failed=$(@($r.failedPaths) -join ',')"
Check '1 data keeps every entry: the read value and the error entry' (@($r.data).Count -eq 2 -and @($r.data)[0].value -eq 7 -and @($r.data)[1].code -eq 'ADS_SYMBOL_NOT_FOUND' -and -not [string]::IsNullOrWhiteSpace([string]@($r.data)[1].error)) (J $r.data)
$j = Round $r
Check '1 JSON: data is an array of 2, failedPaths an array (one element), partial true' ($j.success -eq $false -and $j.data -is [array] -and $j.data.Count -eq 2 -and $j.failedPaths -is [array] -and $j.failedPaths.Count -eq 1 -and $j.failedPaths[0] -eq 'MAIN.nope' -and $j.partial -eq $true) (ConvertTo-Json -InputObject $r -Depth 50 -Compress)

# --- 2: every path missing -> still PARTIAL_READ_FAILED, every path listed
$global:Missing = @('MAIN.nope1', 'MAIN.nope2')
$r = Read-TcVariable -Path @('MAIN.nope1', 'MAIN.nope2')
Check '2 all paths missing -> success=false PARTIAL_READ_FAILED, failedPaths both in input order' ((-not $r.success) -and $r.error.code -eq 'PARTIAL_READ_FAILED' -and $r.partial -eq $true -and (@($r.failedPaths) -join ',') -eq 'MAIN.nope1,MAIN.nope2' -and @($r.data).Count -eq 2 -and $r.error.message -match '2 of 2 paths') (J $r)

# --- 3: every path read -> success, partial false, failedPaths empty
$global:Missing = @()
$r = Read-TcVariable -Path @('MAIN.a', 'MAIN.b', 'MAIN.c')
Check '3 all read -> success=true, partial=false, failedPaths empty, data array of 3' ($r.success -and $r.partial -eq $false -and @($r.failedPaths).Count -eq 0 -and @($r.data).Count -eq 3 -and $null -eq $r.PSObject.Properties['error']) (J $r)
$j = Round $r
Check '3 JSON: failedPaths is [], partial false, data array of 3' ($j.success -eq $true -and $j.partial -eq $false -and $j.failedPaths -is [array] -and $j.failedPaths.Count -eq 0 -and $j.data -is [array] -and $j.data.Count -eq 3) (ConvertTo-Json -InputObject $r -Depth 50 -Compress)

# --- 4: an error without an ADS code still counts as failed (code 'unmapped' in the message)
$global:Unmapped = @('MAIN.weird')
$r = Read-TcVariable -Path @('MAIN.a', 'MAIN.weird')
Check '4 unmapped error -> PARTIAL_READ_FAILED, failedPaths, message (unmapped)' ($r.error.code -eq 'PARTIAL_READ_FAILED' -and (@($r.failedPaths) -join ',') -eq 'MAIN.weird' -and $r.error.message -match 'MAIN\.weird \(unmapped\)') (J $r)
$global:Unmapped = @()

# --- 5: one path keeps its old contract
$global:Missing = @('MAIN.nope')
$r = Read-TcVariable -Path @('MAIN.nope')
Check '5 one missing path -> SYMBOL_NOT_FOUND, no partial / failedPaths' ((-not $r.success) -and $r.error.code -eq 'SYMBOL_NOT_FOUND' -and $null -eq $r.PSObject.Properties['partial'] -and $null -eq $r.PSObject.Properties['failedPaths']) (J $r)
$r = Read-TcVariable -Path @('MAIN.a')
Check '5 one readable path -> success, data is the entry, no partial / failedPaths' ($r.success -and $r.data.value -eq 7 -and $null -eq $r.PSObject.Properties['partial'] -and $null -eq $r.PSObject.Properties['failedPaths']) (J $r)

"failed: $fail"
exit $fail
