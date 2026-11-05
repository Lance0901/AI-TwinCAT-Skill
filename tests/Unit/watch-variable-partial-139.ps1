. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
# Unit: #139 Watch-TcVariable fails closed like Read-TcVariable (#60). A read that failed in any
# sampling round -> success = false, WATCH_READ_FAILED (hint from $script:TcErrorHints); data stays
# complete (samples, untilMet, ...) plus failedReads / lastErrors; a failed read is null in the sample
# plus sample.errors.<path> (several paths) or sample.error / code (one path); top level partial /
# failedPaths in -Path order. Every read worked: success = true, partial = false, failedPaths = [].
# No ADS / runtime: Ensure-TcAdsConnection, Find-TcAdsAssembly and Read-TcAdsSymbolValue are stubbed
# in module scope (the real Read-TcVariable runs); a missing symbol throws "Ads-Error 0x710".
#   powershell.exe -NoProfile -File tests/Unit/watch-variable-partial-139.ps1
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
# what the MCP bridge sends (bridge.ps1: ConvertTo-Json -Depth 50 -Compress), read back
function Round([object]$R) { (ConvertTo-Json -InputObject $R -Depth 50 -Compress) | ConvertFrom-Json }

$global:Missing139 = @()       # paths whose read always throws ADS 0x710
$global:FlakyOnce139 = @{}     # path -> remaining failing reads, then it reads 1
$global:Value139 = @{}         # path -> value (default 7)
& $mod {
    function script:Ensure-TcAdsConnection { $false }
    function script:Find-TcAdsAssembly { $true }
    function script:Read-TcAdsSymbolValue {
        param([string]$VarPath)
        if ($global:Missing139 -contains $VarPath) { throw 'Ads-Error 0x710 : Symbol could not be found.' }
        if ($global:FlakyOnce139.ContainsKey($VarPath) -and $global:FlakyOnce139[$VarPath] -gt 0) {
            $global:FlakyOnce139[$VarPath]--
            throw 'Ads-Error 0x745 : Timeout elapsed.'
        }
        $v = if ($global:Value139.ContainsKey($VarPath)) { $global:Value139[$VarPath] } else { 7 }
        [ordered]@{ path = $VarPath; value = $v; type = 'INT' }
    }
}
$hint = & $mod { Get-TcErrorHint -Code 'WATCH_READ_FAILED' }

# --- 1: the #139 case: two paths, the second missing, no -Until
$global:Missing139 = @('Main.NoSuchVar_Repro139'); $global:FlakyOnce139 = @{}; $global:Value139 = @{}
$r = Watch-TcVariable -Path @('MAIN.a', 'Main.NoSuchVar_Repro139') -IntervalMs 10 -DurationMs 80
Check '1 one of two paths missing -> success=false WATCH_READ_FAILED' ((-not $r.success) -and $r.error.code -eq 'WATCH_READ_FAILED') (J $r)
Check '1 hint from the hint table' (-not [string]::IsNullOrWhiteSpace($r.error.hint) -and $r.error.hint -eq $hint) "$($r.error.hint)"
Check '1 top level partial = true, failedPaths = [missing path]' ($r.partial -eq $true -and (@($r.failedPaths) -join ',') -eq 'Main.NoSuchVar_Repro139') "partial=$($r.partial) failed=$(@($r.failedPaths) -join ',')"
$s0 = @($r.data.samples)[0]
Check '1 sample: value null plus errors.<path> with code SYMBOL_NOT_FOUND; readable path keeps its value' ($null -eq $s0.values.'Main.NoSuchVar_Repro139' -and $s0.values.'MAIN.a' -eq 7 -and $s0.errors.'Main.NoSuchVar_Repro139'.code -eq 'SYMBOL_NOT_FOUND' -and $null -eq $s0.errors.PSObject.Properties['MAIN.a']) (J $s0)
Check '1 sample error has no hint (KeepLast copies), data.lastErrors has it (#145)' ($null -eq $s0.errors.'Main.NoSuchVar_Repro139'.PSObject.Properties['hint'] -and -not [string]::IsNullOrWhiteSpace($r.data.lastErrors.'Main.NoSuchVar_Repro139'.hint)) (J $s0)
Check '1 data.failedReads = every round, data.lastErrors has the code' ($r.data.failedReads.'Main.NoSuchVar_Repro139' -eq $r.data.sampleCount -and $r.data.sampleCount -ge 1 -and $r.data.lastErrors.'Main.NoSuchVar_Repro139'.code -eq 'SYMBOL_NOT_FOUND') (J $r.data)
Check '1 message names the path, its code and the rounds' ($r.error.message -match 'Main\.NoSuchVar_Repro139 \(SYMBOL_NOT_FOUND, \d+ of \d+ rounds\)' -and $r.error.message -match '1 of 2 watched paths') $r.error.message
$j = Round $r
Check '1 JSON: success false, partial true, failedPaths an array of 1, samples kept' ($j.success -eq $false -and $j.partial -eq $true -and $j.failedPaths -is [array] -and $j.failedPaths.Count -eq 1 -and @($j.data.samples).Count -eq $r.data.sampleCount) (ConvertTo-Json -InputObject $r -Depth 50 -Compress)

# --- 2: -Until on the missing path: reported, untilMet false is not the PLC value
$r = Watch-TcVariable -Path @('MAIN.a', 'Main.NoSuchVar_Repro139') -IntervalMs 10 -Until 'Main.NoSuchVar_Repro139 == 1' -UntilTimeoutMs 80
Check '2 Until path unreadable -> WATCH_READ_FAILED, untilMet false still in data' ((-not $r.success) -and $r.error.code -eq 'WATCH_READ_FAILED' -and $r.data.untilMet -eq $false -and (@($r.failedPaths) -join ',') -eq 'Main.NoSuchVar_Repro139') (J $r)
Check '2 message says the Until path is among the failed ones' ($r.error.message -match '-Until path Main\.NoSuchVar_Repro139 is among them' -and $r.error.message -match 'untilMet=false does not mean') $r.error.message

# --- 3: every path read -> success, partial false, failedPaths empty, no errors in samples
$global:Missing139 = @()
$r = Watch-TcVariable -Path @('MAIN.a', 'MAIN.b') -IntervalMs 10 -DurationMs 50
$noErr = @($r.data.samples | Where-Object { $null -ne $_.PSObject.Properties['errors'] }).Count -eq 0
Check '3 all read -> success, partial false, failedPaths empty, no sample.errors, no failedReads' ($r.success -and $r.partial -eq $false -and @($r.failedPaths).Count -eq 0 -and $noErr -and $null -eq $r.data.PSObject.Properties['failedReads'] -and $null -eq $r.PSObject.Properties['error']) (J $r)
$j = Round $r
Check '3 JSON: failedPaths is [], partial false' ($j.success -eq $true -and $j.partial -eq $false -and $j.failedPaths -is [array] -and $j.failedPaths.Count -eq 0) (ConvertTo-Json -InputObject $r -Depth 50 -Compress)

# --- 4: a transient failure in the first round only, Until met later: still fail closed
$global:FlakyOnce139 = @{ 'MAIN.b' = 1 }; $global:Value139 = @{ 'MAIN.b' = 1 }
$r = Watch-TcVariable -Path @('MAIN.a', 'MAIN.b') -IntervalMs 10 -Until 'MAIN.b == 1' -UntilTimeoutMs 2000
Check '4 one failed round then Until met -> WATCH_READ_FAILED, untilMet true, failedReads 1, ADS_TIMEOUT' ((-not $r.success) -and $r.error.code -eq 'WATCH_READ_FAILED' -and $r.data.untilMet -eq $true -and $r.data.failedReads.'MAIN.b' -eq 1 -and $r.data.lastErrors.'MAIN.b'.code -eq 'ADS_TIMEOUT' -and $r.data.sampleCount -eq 2) (J $r)
Check '4 untilMet true came from a read: no "untilMet=false" sentence, untilSample has the value' ($r.error.message -notmatch 'untilMet=' -and $r.data.untilSample.values.'MAIN.b' -eq 1) $r.error.message

# --- 5: one path missing: sample has value null + error / code; same fail-closed result
$global:Missing139 = @('MAIN.gone'); $global:FlakyOnce139 = @{}; $global:Value139 = @{}
$r = Watch-TcVariable -Path @('MAIN.gone') -IntervalMs 10 -DurationMs 50
$s0 = @($r.data.samples)[0]
Check '5 one missing path -> WATCH_READ_FAILED, failedPaths [MAIN.gone], data.path a string' ((-not $r.success) -and $r.error.code -eq 'WATCH_READ_FAILED' -and (@($r.failedPaths) -join ',') -eq 'MAIN.gone' -and $r.data.path -eq 'MAIN.gone') (J $r)
Check '5 single sample: value null, code SYMBOL_NOT_FOUND, error text' ($null -eq $s0.value -and $s0.code -eq 'SYMBOL_NOT_FOUND' -and -not [string]::IsNullOrWhiteSpace($s0.error)) (J $s0)
Check '5 single sample: no hint (only in data.lastErrors, #145)' ($null -eq $s0.PSObject.Properties['hint'] -and -not [string]::IsNullOrWhiteSpace($r.data.lastErrors.'MAIN.gone'.hint)) (J $s0)

# --- 6: one readable path: unchanged sample shape, success, partial false
$global:Missing139 = @()
$r = Watch-TcVariable -Path @('MAIN.a') -IntervalMs 10 -Until 'MAIN.a == 7' -UntilTimeoutMs 500
$s0 = @($r.data.samples)[0]
Check '6 one readable path, Until met -> success, partial false, sample {timestamp, value} only' ($r.success -and $r.data.untilMet -and $r.partial -eq $false -and @($r.failedPaths).Count -eq 0 -and $s0.value -eq 7 -and $null -eq $s0.PSObject.Properties['error'] -and $null -eq $s0.PSObject.Properties['code']) (J $r)

# --- 7: an invalid -Until still returns INVALID_PARAMS before any read (no partial fields needed)
$r = Watch-TcVariable -Path @('MAIN.a') -Until 'MAIN.zz == 1'
Check '7 -Until path not in -Path -> INVALID_PARAMS' ((-not $r.success) -and $r.error.code -eq 'INVALID_PARAMS') (J $r)

# --- 8: a path given twice (other case) is read once per round: failedReads <= sampleCount (#145)
$global:Missing139 = @('MAIN.gone'); $global:FlakyOnce139 = @{}
$r = Watch-TcVariable -Path @('MAIN.a', 'MAIN.gone', 'main.GONE') -IntervalMs 10 -DurationMs 50
Check '8 duplicate path (case-insensitive) -> read once: failedReads = sampleCount, failedPaths one entry, data.path deduplicated' ((-not $r.success) -and $r.data.failedReads.'MAIN.gone' -eq $r.data.sampleCount -and (@($r.failedPaths) -join ',') -eq 'MAIN.gone' -and (@($r.data.path) -join ',') -eq 'MAIN.a,MAIN.gone' -and $r.error.message -match '1 of 2 watched paths') (J $r)
$r = Watch-TcVariable -Path @('MAIN.gone', 'main.gone') -IntervalMs 10 -DurationMs 50
Check '8 only duplicates of one path -> treated as one path (data.path a string, single sample shape)' ((-not $r.success) -and $r.data.path -eq 'MAIN.gone' -and $null -ne @($r.data.samples)[0].PSObject.Properties['code']) (J $r)

"failed: $fail"
exit $fail
