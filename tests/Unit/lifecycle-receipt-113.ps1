# Unit: #113 structured Clear receipt + cross-bridge sync of the lifecycle block. No IDE / ADS /
# runtime needed; every state file lives in an isolated TCAUTO_STATE_DIR.
# Covers:
#   (1) Clear-TcLifecycleBlock without -Reason / -FallbackMethod / -AllowedSideEffects /
#       -MaxVerifyLevel, with empty values, an unknown level or 'none' plus another side effect
#       -> LIFECYCLE_RECEIPT_INCOMPLETE (data.missing / data.invalid), nothing removed, no receipt
#   (2) a complete receipt: the fields (and clearedAtUtc, cleared) are in data and in
#       lifecycle-block-history.jsonl; hints registered
#   (3) cross-bridge, receipt: process B holds the block in memory, ANOTHER powershell.exe (A)
#       clears it -> B drops its in-memory copy and is no longer blocked
#   (4) cross-bridge, no receipt of THIS record: removed from the file by hand, an older receipt of
#       the same key, a receipt of another key, a no-op Clear (cleared = null) -> B keeps blocking,
#       the returned record and the LIFECYCLE_BLOCKED message carry syncNote
#   (5) review 1: a forged key-only line, a forged full line with a future clearedAtUtc, and a
#       second crash after the first instance was cleared -> B keeps blocking
#   (6) cross-bridge, history corrupt / unreadable / missing -> B keeps blocking (syncNote names
#       the reason); after the history is valid again the receipt is honoured
#   (7) review 2: an append while the history is being read succeeds; a reader does not block a
#       writer; an append that fails -> Clear success with receiptWritten = $false, historyWarning
#   (8) a record without createdAtUtc (older module) is never dropped
#   (9) review 4: time of one gated check against a 3000-line history (printed, bound 5 s)
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
$full = @{ Reason = 'unit 113: user approved'; FallbackMethod = 'rerun Enable-TcConfig -Force through tcauto'; AllowedSideEffects = @('TwinCAT restart', 'PLC download'); MaxVerifyLevel = 'PlcState' }

# Process "B" (this one) records a block: file + in-memory copy, as a bridge does after a failure.
function Set-B([string]$Id, [string]$Command = 'Set-TcSystemState') { & $mod { param($i, $c) $null = Set-TcLifecycleBlock -AmsNetId $i -Command $c -ErrorCode 'SYSTEM_STATE_TIMEOUT' -RequestedState 'Run' -ReachedState 'Config' } $Id $Command }
function Get-B([string]$Id) { & $mod { param($i) Get-TcLifecycleBlock -AmsNetId $i } $Id }
function Get-BLocal([string]$Id) { & $mod { param($i) $script:TcLifecycleBlockLocal[(ConvertTo-TcLifecycleKey $i)] } $Id }
function Test-BLocal([string]$Id) { $null -ne (Get-BLocal $Id) }
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
function Add-HistoryLine([string]$Line) { [IO.File]::AppendAllText($hist, $Line + "`r`n", (New-Object Text.UTF8Encoding($false))) }

$X = '10.113.1.1.1.1'
$Y = '10.113.2.2.1.1'
$Z = '10.113.3.3.1.1'
$W = '10.113.4.4.1.1'
$V = '10.113.6.6.1.1'
$F = '10.113.7.7.1.1'
$S = '10.113.8.8.1.1'
$T = '10.113.9.9.1.1'

try {
    # --- (1) incomplete receipt ---
    Set-B $X
    $base = @{ Reason = 'unit 113'; FallbackMethod = 'rerun'; AllowedSideEffects = @('none'); MaxVerifyLevel = 'None' }
    function Without([string[]]$Keys, [hashtable]$Set = @{}) { $h = $base.Clone(); foreach ($k in $Keys) { $null = $h.Remove($k) }; foreach ($k in $Set.Keys) { $h[$k] = $Set[$k] }; $h }
    $cases = [ordered]@{
        'nothing at all'        = @{ p = @{ }; m = 'AllowedSideEffects,FallbackMethod,MaxVerifyLevel,Reason'; i = 0 }
        'no Reason'             = @{ p = (Without @('Reason')); m = 'Reason'; i = 0 }
        'empty Reason'          = @{ p = (Without @() @{ Reason = '   ' }); m = 'Reason'; i = 0 }
        'no FallbackMethod'     = @{ p = (Without @('FallbackMethod')); m = 'FallbackMethod'; i = 0 }
        'no AllowedSideEffects' = @{ p = (Without @('AllowedSideEffects')); m = 'AllowedSideEffects'; i = 0 }
        'no MaxVerifyLevel'     = @{ p = (Without @('MaxVerifyLevel')); m = 'MaxVerifyLevel'; i = 0 }
        'empty FallbackMethod'  = @{ p = (Without @() @{ FallbackMethod = '  ' }); m = 'FallbackMethod'; i = 0 }
        'empty side effects'    = @{ p = (Without @() @{ AllowedSideEffects = @('', ' ') }); m = 'AllowedSideEffects'; i = 0 }
        'unknown level'         = @{ p = (Without @() @{ MaxVerifyLevel = 'Everything' }); m = ''; i = 1 }
        'none + other effect'   = @{ p = (Without @() @{ AllowedSideEffects = @('None', 'PLC download') }); m = ''; i = 1 }
    }
    foreach ($name in $cases.Keys) {
        $c = $cases[$name]
        $p = $c.p
        $r = Clear-TcLifecycleBlock -AmsNetId $X @p
        $miss = (@($r.data.missing) | Sort-Object) -join ','
        Check "(1) $name -> LIFECYCLE_RECEIPT_INCOMPLETE, missing='$($c.m)', $($c.i) invalid" ((-not $r.success) -and $r.error.code -eq 'LIFECYCLE_RECEIPT_INCOMPLETE' -and $miss -eq $c.m -and @($r.data.invalid).Count -eq $c.i -and $r.data.notRun -eq $true -and -not [string]::IsNullOrWhiteSpace($r.error.hint)) (J $r)
    }
    $b = Get-B $X
    Check '(1) nothing removed by an incomplete receipt' ($null -ne $b -and $b.errorCode -eq 'SYSTEM_STATE_TIMEOUT') (J $b)
    Check '(1) no receipt written by an incomplete call' (-not (Test-Path -LiteralPath $hist)) ''
    $pp = Without @() @{ MaxVerifyLevel = 'Everything' }
    $r = Clear-TcLifecycleBlock -AmsNetId $X @pp
    Check '(1) unknown level: message names the allowed levels' ($r.error.message -match 'TestObserved' -and (@($r.data.allowedVerifyLevels) -join ',') -eq 'None,SystemState,PlcState,VariableRead,TestObserved') (J $r)
    $pp = Without @() @{ AllowedSideEffects = @('none', 'PLC Run') }
    $r = Clear-TcLifecycleBlock -AmsNetId $X @pp
    Check "(1) 'none' + another side effect: data.invalid says why" ((@($r.data.invalid) -join ' ') -match "'none' cannot be combined") (J $r.data)

    # --- (2) complete receipt ---
    $c = Clear-TcLifecycleBlock -AmsNetId $X -Reason ' unit 113: user approved ' -FallbackMethod ' rerun Enable-TcConfig -Force through tcauto ' -AllowedSideEffects 'TwinCAT restart', '', 'PLC download' -MaxVerifyLevel 'plcstate'
    Check '(2) complete receipt -> success, record removed, receiptWritten' ($c.success -and $c.data.cleared.errorCode -eq 'SYSTEM_STATE_TIMEOUT' -and $null -eq (Get-B $X) -and $c.data.receiptWritten -eq $true -and $null -eq $c.data.historyWarning) (J $c)
    Check '(2) data: fields trimmed, empty entry dropped, level canonical' ($c.data.reason -eq 'unit 113: user approved' -and $c.data.fallbackMethod -eq 'rerun Enable-TcConfig -Force through tcauto' -and (@($c.data.allowedSideEffects) -join '|') -eq 'TwinCAT restart|PLC download' -and $c.data.maxVerifyLevel -eq 'PlcState' -and $c.data.receipt.maxVerifyLevel -eq 'PlcState') (J $c.data)
    $lines = @(Get-Content -LiteralPath $hist | Where-Object { $_.Trim() })
    $last = $lines[-1] | ConvertFrom-Json
    Check '(2) history receipt: fields + clearedAtUtc + cleared (with createdAtUtc)' ($last.key -eq $X -and $last.reason -eq 'unit 113: user approved' -and $last.fallbackMethod -eq 'rerun Enable-TcConfig -Force through tcauto' -and (@($last.allowedSideEffects) -join '|') -eq 'TwinCAT restart|PLC download' -and $last.maxVerifyLevel -eq 'PlcState' -and -not [string]::IsNullOrWhiteSpace([string]$last.clearedAtUtc) -and -not [string]::IsNullOrWhiteSpace([string]$last.cleared.createdAtUtc)) ($lines[-1])
    $h = & $mod { Get-TcErrorHint -Code 'LIFECYCLE_RECEIPT_INCOMPLETE' }
    Check '(2) LIFECYCLE_RECEIPT_INCOMPLETE hint registered and names the fields' ($h -match 'Reason' -and $h -match 'FallbackMethod' -and $h -match 'AllowedSideEffects' -and $h -match 'MaxVerifyLevel') "$h"
    $hb = & $mod { Get-TcErrorHint -Code 'LIFECYCLE_BLOCKED' }
    Check '(2) LIFECYCLE_BLOCKED hint asks for the full receipt' ($hb -match '-FallbackMethod' -and $hb -match '-AllowedSideEffects' -and $hb -match '-MaxVerifyLevel') "$hb"

    # --- (3) cross-bridge with the receipt of this record: another process clears, B drops its copy ---
    Set-B $Y
    Check '(3) B is blocked before the clear' ($null -ne (Get-B $Y) -and (Test-BLocal $Y)) ''
    $a = Invoke-AClear $Y
    Check '(3) process A cleared the record (receipt written)' ($a.success -and $a.data.cleared.errorCode -eq 'SYSTEM_STATE_TIMEOUT' -and $a.data.receiptWritten -eq $true) (J $a)
    $t = & $mod { param($i) Test-TcLifecycleBlock -AmsNetId $i -Command 'Enable-TcConfig' } $Y
    Check '(3) B: no longer blocked after A cleared' ($null -eq $t) (J $t)
    Check '(3) B: in-memory copy dropped' (-not (Test-BLocal $Y)) ''

    # --- (4) no receipt of THIS record ---
    Set-B $Z
    Remove-FromFileOnly $Z
    $b = Get-B $Z
    Check '(4) removed from the file by hand, no receipt -> B still blocked, syncNote says why' ($null -ne $b -and (Test-BLocal $Z) -and $b.syncNote -match 'no Clear receipt of this record' -and $b.syncNote -match 'THIS process') (J $b)
    $t = & $mod { param($i) Test-TcLifecycleBlock -AmsNetId $i -Command 'Enable-TcConfig' } $Z
    Check '(4) LIFECYCLE_BLOCKED message carries the syncNote' ($t.error.code -eq 'LIFECYCLE_BLOCKED' -and $t.error.message -match 'Cross-bridge sync' -and $null -eq (Get-BLocal $Z).PSObject.Properties['syncNote']) (J $t)
    Set-B $Y
    Remove-FromFileOnly $Y
    Check '(4) only an older receipt of that key (other record) -> B still blocked' ($null -ne (Get-B $Y) -and (Test-BLocal $Y)) ''
    $a = Invoke-AClear $W
    Check '(4) receipt of another key -> B still blocked by Z' ($a.success -and $null -ne (Get-B $Z)) (J $a)
    $a = Invoke-AClear $Z
    $b = Get-B $Z
    Check '(4) no-op Clear in A (cleared = null) does not count -> B still blocked' ($a.success -and $null -eq $a.data.cleared -and $null -ne $b -and (Test-BLocal $Z)) (J $b)

    # --- (5) review 1: forged / future / replayed receipts ---
    Set-B $F
    Remove-FromFileOnly $F
    Add-HistoryLine ('{"key":"' + $F + '","clearedAtUtc":"9999-01-01T00:00:00Z"}')
    Check '(5) forged key-only line -> B still blocked' ($null -ne (Get-B $F) -and (Test-BLocal $F)) ''
    $loc = Get-BLocal $F
    $forged = [ordered]@{ clearedAtUtc = [DateTime]::UtcNow.AddMinutes(10).ToString('o'); key = $F; cleared = [ordered]@{ command = $loc.command; createdAtUtc = $loc.createdAtUtc } }
    Add-HistoryLine (([PSCustomObject]$forged) | ConvertTo-Json -Compress -Depth 4)
    $b = Get-B $F
    Check '(5) receipt of this record with clearedAtUtc 10 min in the future -> still blocked, syncNote says future' ($null -ne $b -and (Test-BLocal $F) -and $b.syncNote -match 'future') (J $b)
    $forged.cleared.command = 'Enable-TcConfig'
    $forged.clearedAtUtc = [DateTime]::UtcNow.ToString('o')
    Add-HistoryLine (([PSCustomObject]$forged) | ConvertTo-Json -Compress -Depth 4)
    Check '(5) receipt with the right createdAtUtc but another command -> still blocked' ($null -ne (Get-B $F)) ''
    # second crash: the first instance of S is cleared by A (valid receipt), then S fails again
    Set-B $S
    $a = Invoke-AClear $S
    Check '(5) first instance of S cleared by A -> B drops it' ($a.success -and $null -eq (Get-B $S)) (J $a)
    Set-B $S 'Enable-TcConfig'
    Remove-FromFileOnly $S
    Check '(5) second crash of S, removed by hand: the old receipt is not replayed -> still blocked' ($null -ne (Get-B $S) -and (Test-BLocal $S)) ''
    # the same, with the record kept in memory only (file not written): probe of review 1
    & $mod { param($i) $script:TcLifecycleBlockLocal[$i] = [PSCustomObject]@{ amsNetId = $i; command = 'Set-TcSystemState'; errorCode = 'X'; time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); createdAtUtc = [DateTime]::UtcNow.ToString('o') } } $S
    Check '(5) memory-only third record of S -> still blocked' ($null -ne (Get-B $S)) ''

    # --- (6) history corrupt / unreadable / missing ---
    Set-B $V
    $a = Invoke-AClear $V
    Check '(6) setup: A cleared V (valid receipt), B not checked yet' ($a.success -and $null -ne $a.data.cleared -and (Test-BLocal $V)) (J $a)
    $good = [IO.File]::ReadAllText($hist)
    Add-HistoryLine '{ this is not json'
    $b = Get-B $V
    Check '(6) history has a truncated line -> B still blocked, syncNote names the line' ($null -ne $b -and (Test-BLocal $V) -and $b.syncNote -match 'line \d+ is corrupt') (J $b)
    [IO.File]::WriteAllText($hist, $good + "[1,2,3]`r`n")
    Check '(6) history line that is not a JSON object -> B still blocked' ($null -ne (Get-B $V)) ''
    [IO.File]::WriteAllText($hist, $good + '{"key":"' + $V + '", broken}' + "`r`n")
    Check '(6) {...} line naming the key that does not parse -> B still blocked' ($null -ne (Get-B $V)) ''
    [IO.File]::WriteAllText($hist, $good)
    $fs = [IO.File]::Open($hist, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $b = Get-B $V
        Check '(6) history cannot be read (locked) -> B still blocked, syncNote says so' ($null -ne $b -and (Test-BLocal $V) -and $b.syncNote -match 'could not be read') (J $b)
    }
    finally { $fs.Dispose() }
    $saved = Join-Path $env:TCAUTO_STATE_DIR 'history-113.saved'
    Move-Item -LiteralPath $hist -Destination $saved
    $b = Get-B $V
    Check '(6) history missing -> B still blocked' ($null -ne $b -and $b.syncNote -match 'does not exist') (J $b)
    Move-Item -LiteralPath $saved -Destination $hist
    Check '(6) history valid again -> the receipt is honoured, B no longer blocked' ($null -eq (Get-B $V) -and -not (Test-BLocal $V)) ''

    # --- (7) review 2: reader and writer do not collide; a failed append is reported ---
    $rfs = New-Object IO.FileStream($hist, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        Set-B $T
        $c = Clear-TcLifecycleBlock -AmsNetId $T @full
        Check '(7) Clear while the history is open for reading the way the module reads it -> receipt written' ($c.success -and $c.data.receiptWritten -eq $true) (J $c.data)
    }
    finally { $rfs.Dispose() }
    $wfs = New-Object IO.FileStream($hist, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
        $txt = & $mod { param($p) Read-TcLifecycleHistoryText -Path $p } $hist
        Check '(7) the module reads the history while another process appends to it' ($txt.Length -gt 0) ''
    }
    finally { $wfs.Dispose() }
    Set-B $T
    $lock = [IO.File]::Open($hist, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $c = Clear-TcLifecycleBlock -AmsNetId $T @full
    }
    finally { $lock.Dispose() }
    Check '(7) append fails -> success, record removed, receiptWritten=false, historyWarning, message says other bridges will NOT sync' ($c.success -and $null -ne $c.data.cleared -and $c.data.receiptWritten -eq $false -and -not [string]::IsNullOrWhiteSpace($c.data.historyWarning) -and $c.data.message -match 'will NOT sync' -and $null -eq (Get-B $T)) (J $c.data)

    # --- (8) a record without createdAtUtc (written by an older module) is never dropped ---
    & $mod { $script:TcLifecycleBlockLocal['10.113.5.5.1.1'] = [PSCustomObject]@{ amsNetId = '10.113.5.5.1.1'; command = 'Set-TcPlcState'; errorCode = 'PLC_RUN_TIMEOUT'; time = '2000-01-01 00:00:00' } }
    $b = Get-B '10.113.5.5.1.1'
    Check '(8) memory record without createdAtUtc -> still blocked (fail closed)' ($null -ne $b -and $b.errorCode -eq 'PLC_RUN_TIMEOUT' -and $b.syncNote -match 'createdAtUtc') (J $b)
    $c = Clear-TcLifecycleBlock -AmsNetId '10.113.5.5.1.1' @full
    Check '(8) a Clear in this process removes it' ($c.success -and $null -eq (Get-B '10.113.5.5.1.1')) (J $c)

    # --- (9) review 4: 3000-line history, one gated check ---
    $other = '{"clearedAt":"2026-11-05 10:00:00","clearedAtUtc":"2026-11-05T02:00:00.0000000Z","amsNetId":"1.1.1.1.1.1","key":"1.1.1.1.1.1","netIdSource":"explicit","reason":"r","fallbackMethod":"f","allowedSideEffects":["none"],"maxVerifyLevel":"None","pid":1,"cleared":{"amsNetId":"1.1.1.1.1.1","command":"c","errorCode":"e","message":"m","requestedState":null,"reachedState":null,"step":null,"time":"t","createdAtUtc":"2026-11-05T01:00:00.0000000Z"}}'
    [IO.File]::WriteAllText($hist, ((@($other) * 3000) -join "`r`n") + "`r`n")
    Set-B '10.113.10.10.1.1'
    Remove-FromFileOnly '10.113.10.10.1.1'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $b = Get-B '10.113.10.10.1.1'
    $ms = $sw.ElapsedMilliseconds
    "INFO (9) 3000-line history (no line names the key), one gated check: $ms ms"
    Check "(9) 3000-line history check is fast and still blocks ($ms ms < 5000)" ($null -ne $b -and $ms -lt 5000) ''
    foreach ($k in @($Y, $Z, $F, $S, '10.113.10.10.1.1')) { $null = Clear-TcLifecycleBlock -AmsNetId $k @full }
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
