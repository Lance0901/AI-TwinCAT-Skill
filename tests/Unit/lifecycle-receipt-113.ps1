# Unit: #113 structured Clear receipt + cross-bridge sync of the lifecycle block. No IDE / ADS /
# runtime needed; every state file lives in an isolated TCAUTO_STATE_DIR.
# Covers:
#   (1) Clear-TcLifecycleBlock without -FallbackMethod / -AllowedSideEffects / -MaxVerifyLevel, with
#       empty values or an unknown level -> LIFECYCLE_RECEIPT_INCOMPLETE (data.missing), nothing removed
#   (2) a complete receipt: the three fields (and clearedAtUtc) are in data and in
#       lifecycle-block-history.jsonl; the hint key has a troubleshooting heading (check.ps1 errorcodes)
#   (3) cross-bridge, receipt: process B holds the block in memory, ANOTHER powershell.exe (A) clears
#       it -> B drops its in-memory copy and is no longer blocked
#   (4) cross-bridge, no receipt: the record vanished from the file without a Clear (by hand), or the
#       only receipt of that key is older than the block -> B keeps blocking
#   (5) cross-bridge, history corrupt / unreadable / missing -> B keeps blocking; after the history
#       is valid again the receipt is honoured
#   (6) a record without createdAtUtc (older module) is never dropped
#   powershell.exe -NoProfile -File tests/Unit/lifecycle-receipt-113.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($env:TCAUTO_STATE_DIR)) {
    $env:TCAUTO_STATE_DIR = Join-Path $env:TEMP ("tcauto-unit-state-113-{0}" -f [guid]::NewGuid().ToString('N'))
    $env:TCAUTO_UNIT_113_OWNED = '1'
}
$modulePath = Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
Import-Module $modulePath -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 600) { $Detail = $Detail.Substring(0, 600) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}
function J($o) { $o | ConvertTo-Json -Compress -Depth 6 }

$null = New-Item -ItemType Directory -Path $env:TCAUTO_STATE_DIR -Force
$hist = Join-Path $env:TCAUTO_STATE_DIR 'lifecycle-block-history.jsonl'
$blockFile = Join-Path $env:TCAUTO_STATE_DIR 'lifecycle-block.json'
$full = @{ FallbackMethod = 'rerun Enable-TcConfig -Force through tcauto'; AllowedSideEffects = @('TwinCAT restart', 'PLC download'); MaxVerifyLevel = 'PlcState' }

# Process "B" (this one) records a block: file + in-memory copy, as a bridge does after a failure.
function Set-B([string]$Id) { & $mod { param($i) $null = Set-TcLifecycleBlock -AmsNetId $i -Command 'Set-TcSystemState' -ErrorCode 'SYSTEM_STATE_TIMEOUT' -RequestedState 'Run' -ReachedState 'Config' } $Id }
function Get-B([string]$Id) { & $mod { param($i) Get-TcLifecycleBlock -AmsNetId $i } $Id }
function Test-BLocal([string]$Id) { & $mod { param($i) $script:TcLifecycleBlockLocal.ContainsKey((ConvertTo-TcLifecycleKey $i)) } $Id }
# Removes a key from the state file the way another process (or a person) would, without a receipt.
function Remove-FromFileOnly([string]$Id) {
    & $mod {
        param($i)
        $k = ConvertTo-TcLifecycleKey $i
        $null = Invoke-TcBuildRequiredLocked -MutexName (Get-TcLifecycleBlockMutexName) -Body {
            $st = Read-TcLifecycleBlockState
            $null = $st.Remove($k)
            Write-TcLifecycleBlockState -Entries $st
        }
    } $Id
}
# Process "A": a separate powershell.exe (same TCAUTO_STATE_DIR, inherited) that clears the block.
function Invoke-AClear([string]$Id) {
    $code = @"
`$ErrorActionPreference = 'Stop'
`$ProgressPreference = 'SilentlyContinue'
Import-Module '$($modulePath.Replace("'", "''"))' -Force -WarningAction SilentlyContinue
Clear-TcLifecycleBlock -AmsNetId '$Id' -Reason 'unit 113: user approved in process A' -FallbackMethod 'rerun Enable-TcConfig -Force through tcauto' -AllowedSideEffects 'TwinCAT restart','PLC download' -MaxVerifyLevel PlcState | ConvertTo-Json -Depth 6 -Compress
"@
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    $out = & powershell.exe -NoProfile -NonInteractive -EncodedCommand $enc
    $txt = (@($out | ForEach-Object { [string]$_ }) -join "`n")
    $json = @($txt -split "`n" | Where-Object { $_.TrimStart().StartsWith('{') })[-1]
    if ($null -eq $json) { return [PSCustomObject]@{ success = $false; raw = $txt } }
    $json | ConvertFrom-Json
}

$X = '10.113.1.1.1.1'
$Y = '10.113.2.2.1.1'
$Z = '10.113.3.3.1.1'
$W = '10.113.4.4.1.1'

try {
    # --- (1) incomplete receipt ---
    Set-B $X
    $cases = [ordered]@{
        'no new field'          = @{ }
        'no FallbackMethod'     = @{ AllowedSideEffects = @('none'); MaxVerifyLevel = 'None' }
        'no AllowedSideEffects' = @{ FallbackMethod = 'rerun'; MaxVerifyLevel = 'None' }
        'no MaxVerifyLevel'     = @{ FallbackMethod = 'rerun'; AllowedSideEffects = @('none') }
        'empty FallbackMethod'  = @{ FallbackMethod = '  '; AllowedSideEffects = @('none'); MaxVerifyLevel = 'None' }
        'empty side effects'    = @{ FallbackMethod = 'rerun'; AllowedSideEffects = @('', ' '); MaxVerifyLevel = 'None' }
        'unknown level'         = @{ FallbackMethod = 'rerun'; AllowedSideEffects = @('none'); MaxVerifyLevel = 'Everything' }
    }
    $expect = @{
        'no new field' = @('FallbackMethod', 'AllowedSideEffects', 'MaxVerifyLevel'); 'no FallbackMethod' = @('FallbackMethod')
        'no AllowedSideEffects' = @('AllowedSideEffects'); 'no MaxVerifyLevel' = @('MaxVerifyLevel'); 'empty FallbackMethod' = @('FallbackMethod')
        'empty side effects' = @('AllowedSideEffects'); 'unknown level' = @('MaxVerifyLevel')
    }
    foreach ($name in $cases.Keys) {
        $p = $cases[$name]
        $r = Clear-TcLifecycleBlock -AmsNetId $X -Reason 'unit 113' @p
        $miss = (@($r.data.missing) | Sort-Object) -join ','
        $want = (@($expect[$name]) | Sort-Object) -join ','
        Check "(1) $name -> LIFECYCLE_RECEIPT_INCOMPLETE, missing=$want" ((-not $r.success) -and $r.error.code -eq 'LIFECYCLE_RECEIPT_INCOMPLETE' -and $miss -eq $want -and $r.data.notRun -eq $true -and -not [string]::IsNullOrWhiteSpace($r.error.hint)) (J $r)
    }
    $b = Get-B $X
    Check '(1) nothing removed by an incomplete receipt' ($null -ne $b -and $b.errorCode -eq 'SYSTEM_STATE_TIMEOUT') (J $b)
    Check '(1) no receipt written by an incomplete call' (-not (Test-Path -LiteralPath $hist)) ''
    $r = Clear-TcLifecycleBlock -AmsNetId $X -Reason 'unit 113' -FallbackMethod 'rerun' -AllowedSideEffects 'none' -MaxVerifyLevel 'Everything'
    Check '(1) unknown level: message names the allowed levels' ($r.error.message -match 'TestObserved' -and (@($r.data.allowedVerifyLevels) -join ',') -eq 'None,SystemState,PlcState,VariableRead,TestObserved') (J $r)

    # --- (2) complete receipt ---
    $c = Clear-TcLifecycleBlock -AmsNetId $X -Reason 'unit 113: user approved' -FallbackMethod ' rerun Enable-TcConfig -Force through tcauto ' -AllowedSideEffects 'TwinCAT restart', '', 'PLC download' -MaxVerifyLevel 'plcstate'
    Check '(2) complete receipt -> success, record removed' ($c.success -and $c.data.cleared.errorCode -eq 'SYSTEM_STATE_TIMEOUT' -and $null -eq (Get-B $X)) (J $c)
    Check '(2) data has fallbackMethod (trimmed), allowedSideEffects (empty entry dropped), maxVerifyLevel (canonical)' ($c.data.fallbackMethod -eq 'rerun Enable-TcConfig -Force through tcauto' -and (@($c.data.allowedSideEffects) -join '|') -eq 'TwinCAT restart|PLC download' -and $c.data.maxVerifyLevel -eq 'PlcState' -and $c.data.receipt.maxVerifyLevel -eq 'PlcState') (J $c.data)
    $lines = @(Get-Content -LiteralPath $hist | Where-Object { $_.Trim() })
    $last = $lines[-1] | ConvertFrom-Json
    Check '(2) history receipt has the three fields + clearedAtUtc + key' ($last.key -eq $X -and $last.reason -eq 'unit 113: user approved' -and $last.fallbackMethod -eq 'rerun Enable-TcConfig -Force through tcauto' -and (@($last.allowedSideEffects) -join '|') -eq 'TwinCAT restart|PLC download' -and $last.maxVerifyLevel -eq 'PlcState' -and -not [string]::IsNullOrWhiteSpace([string]$last.clearedAtUtc) -and $null -ne $last.cleared) ($lines[-1])
    $h = & $mod { Get-TcErrorHint -Code 'LIFECYCLE_RECEIPT_INCOMPLETE' }
    Check '(2) LIFECYCLE_RECEIPT_INCOMPLETE hint registered and names the fields' ($h -match 'FallbackMethod' -and $h -match 'AllowedSideEffects' -and $h -match 'MaxVerifyLevel') "$h"
    $hb = & $mod { Get-TcErrorHint -Code 'LIFECYCLE_BLOCKED' }
    Check '(2) LIFECYCLE_BLOCKED hint asks for the full receipt' ($hb -match '-FallbackMethod' -and $hb -match '-AllowedSideEffects' -and $hb -match '-MaxVerifyLevel') "$hb"

    # --- (3) cross-bridge with a receipt: another process clears, B drops its copy ---
    Set-B $Y
    Check '(3) B is blocked before the clear' ($null -ne (Get-B $Y) -and (Test-BLocal $Y)) ''
    $a = Invoke-AClear $Y
    Check '(3) process A cleared the record (receipt in history)' ($a.success -and $a.data.cleared.errorCode -eq 'SYSTEM_STATE_TIMEOUT' -and $a.data.maxVerifyLevel -eq 'PlcState') (J $a)
    $t = & $mod { param($i) Test-TcLifecycleBlock -AmsNetId $i -Command 'Enable-TcConfig' } $Y
    Check '(3) B: no longer blocked after A cleared (file has no record + later receipt)' ($null -eq $t) (J $t)
    Check '(3) B: in-memory copy dropped' (-not (Test-BLocal $Y)) ''

    # --- (4) cross-bridge without a receipt ---
    Set-B $Z
    Remove-FromFileOnly $Z
    $b = Get-B $Z
    Check '(4) record removed from the file by hand, no receipt -> B still blocked' ($null -ne $b -and $b.errorCode -eq 'SYSTEM_STATE_TIMEOUT' -and (Test-BLocal $Z)) (J $b)
    # an OLDER receipt of the same key does not count: Y was cleared in (3); block Y again, remove by hand
    Set-B $Y
    Remove-FromFileOnly $Y
    $b = Get-B $Y
    Check '(4) only an older receipt of that key in the history -> B still blocked' ($null -ne $b -and (Test-BLocal $Y)) (J $b)
    # a receipt of ANOTHER key does not count either
    $a = Invoke-AClear $W
    Check '(4) receipt of another key -> B still blocked by Z' ($a.success -and $null -ne (Get-B $Z)) (J $a)

    # --- (5) history corrupt / unreadable / missing ---
    $a = Invoke-AClear $Z
    Check '(5) setup: A cleared Z (valid receipt)' ($a.success) (J $a)
    $good = [IO.File]::ReadAllText($hist)
    [IO.File]::AppendAllText($hist, "{ this is not json`r`n")
    $b = Get-B $Z
    Check '(5) history has a corrupt line -> B still blocked' ($null -ne $b -and (Test-BLocal $Z)) (J $b)
    [IO.File]::WriteAllText($hist, $good + "[1,2,3]`r`n")
    $b = Get-B $Z
    Check '(5) history line that is not a JSON object -> B still blocked' ($null -ne $b -and (Test-BLocal $Z)) (J $b)
    [IO.File]::WriteAllText($hist, $good)
    $fs = [IO.File]::Open($hist, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $b = Get-B $Z
        Check '(5) history cannot be read (locked) -> B still blocked' ($null -ne $b -and (Test-BLocal $Z)) (J $b)
    }
    finally { $fs.Dispose() }
    $saved = Join-Path $env:TCAUTO_STATE_DIR 'history-113.saved'
    Move-Item -LiteralPath $hist -Destination $saved
    $b = Get-B $Z
    Check '(5) history missing -> B still blocked' ($null -ne $b -and (Test-BLocal $Z)) (J $b)
    Move-Item -LiteralPath $saved -Destination $hist
    $b = Get-B $Z
    Check '(5) history valid again -> the receipt is honoured, B no longer blocked' ($null -eq $b -and -not (Test-BLocal $Z)) (J $b)

    # --- (6) a record without createdAtUtc (written by an older module) is never dropped ---
    & $mod { $script:TcLifecycleBlockLocal['10.113.5.5.1.1'] = [PSCustomObject]@{ amsNetId = '10.113.5.5.1.1'; command = 'Set-TcPlcState'; errorCode = 'PLC_RUN_TIMEOUT'; time = '2000-01-01 00:00:00' } }
    $a = Invoke-AClear '10.113.5.5.1.1'
    $b = Get-B '10.113.5.5.1.1'
    Check '(6) memory record without createdAtUtc + later receipt -> still blocked (fail closed)' ($a.success -and $null -ne $b -and $b.errorCode -eq 'PLC_RUN_TIMEOUT') (J $b)
    $c = Clear-TcLifecycleBlock -AmsNetId '10.113.5.5.1.1' -Reason 'unit 113 cleanup' @full
    Check '(6) a Clear in this process removes it' ($c.success -and $null -eq (Get-B '10.113.5.5.1.1')) (J $c)
    $null = Clear-TcLifecycleBlock -AmsNetId $Y -Reason 'unit 113 cleanup' @full
}
finally {
    if ($env:TCAUTO_UNIT_113_OWNED -eq '1') {
        Remove-Item -LiteralPath $env:TCAUTO_STATE_DIR -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item Env:\TCAUTO_STATE_DIR -ErrorAction SilentlyContinue
        Remove-Item Env:\TCAUTO_UNIT_113_OWNED -ErrorAction SilentlyContinue
    }
}
"failed: $fail"
exit [Math]::Min($fail, 255)
