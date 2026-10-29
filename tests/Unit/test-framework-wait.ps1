# Unit: task 1.5 test framework polls instead of blind sleep (New-TcTestCase -WaitUntil / Invoke-TcTest),
# no IDE / ADS needed: Ensure-TcAdsConnection, Read-TcVariable, Write-TcVariable are stubbed in module scope.
#   powershell.exe -NoProfile -File tests/Unit/test-framework-wait.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 400) { $Detail = $Detail.Substring(0, 400) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}

# Mock PLC: $global:Plc[path] = scriptblock (param($n)) giving the value at read number $n (1-based)
$global:Plc = @{}
$global:Reads = @{}
$global:Writes = New-Object System.Collections.ArrayList
& $mod {
    function script:Ensure-TcAdsConnection { $false }
    function script:Write-TcVariable { [CmdletBinding()] param($Path, $Value) $null = $global:Writes.Add("$Path=$Value"); [PSCustomObject]@{ success = $true } }
    function script:Read-TcVariable {
        [CmdletBinding()] param([string]$Path)
        $global:Reads[$Path] = 1 + [int]$global:Reads[$Path]
        if (-not $global:Plc.ContainsKey($Path)) { return [PSCustomObject]@{ success = $false; error = [PSCustomObject]@{ code = 'SYMBOL_NOT_FOUND'; message = 'x' } } }
        $v = & $global:Plc[$Path] $global:Reads[$Path]
        [PSCustomObject]@{ success = $true; data = [PSCustomObject]@{ path = $Path; value = $v; type = 'INT' } }
    }
}
function Reset-Mock { $global:Plc = @{}; $global:Reads = @{}; $global:Writes.Clear() }

# --- New-TcTestCase shape
$tc = New-TcTestCase -Name 'legacy' -Assertions @(@{ Path = 'MAIN.n'; Expected = 1 })
Check 'legacy test case keeps waitMs=1000, no waitUntil' ($tc.waitMs -eq 1000 -and $null -eq $tc.PSObject.Properties['waitUntil']) ($tc | ConvertTo-Json -Compress)
$tc = New-TcTestCase -Name 'w' -WaitUntil @{ Path = 'MAIN.bDone'; Operator = 'IsTrue' } -Assertions @(@{ Path = 'MAIN.n'; Expected = 1 })
Check 'single hashtable WaitUntil stays an array, default timeout 5000' (($tc.waitUntil -is [array]) -and $tc.waitUntil.Count -eq 1 -and $tc.waitTimeoutMs -eq 5000) ($tc | ConvertTo-Json -Compress -Depth 4)

# --- invalid params -> INVALID_PARAMS
$bad = @(
    @('bad operator', { New-TcTestCase -Name 'x' -WaitUntil @{ Path = 'MAIN.n'; Operator = 'eq'; Expected = 1 } -Assertions @(@{ Path = 'a'; Expected = 1 }) }),
    @('missing Path', { New-TcTestCase -Name 'x' -WaitUntil @{ Operator = 'Equal'; Expected = 1 } -Assertions @(@{ Path = 'a'; Expected = 1 }) }),
    @('missing Expected', { New-TcTestCase -Name 'x' -WaitUntil @{ Path = 'MAIN.n'; Operator = 'GreaterThan' } -Assertions @(@{ Path = 'a'; Expected = 1 }) }),
    @('unknown key', { New-TcTestCase -Name 'x' -WaitUntil @{ Path = 'MAIN.n'; Expected = 1; Timeout = 5 } -Assertions @(@{ Path = 'a'; Expected = 1 }) }),
    @('timeout 0', { New-TcTestCase -Name 'x' -WaitUntil @{ Path = 'MAIN.n'; Expected = 1 } -WaitTimeoutMs 0 -Assertions @(@{ Path = 'a'; Expected = 1 }) }),
    @('timeout without WaitUntil', { New-TcTestCase -Name 'x' -WaitTimeoutMs 100 -Assertions @(@{ Path = 'a'; Expected = 1 }) }),
    @('empty WaitUntil', { New-TcTestCase -Name 'x' -WaitUntil @() -Assertions @(@{ Path = 'a'; Expected = 1 }) })
)
foreach ($b in $bad) {
    $r = & $b[1]
    Check "New-TcTestCase $($b[0]) -> INVALID_PARAMS" ($r.success -eq $false -and $r.error.code -eq 'INVALID_PARAMS') ($r | ConvertTo-Json -Compress -Depth 4)
}
# hand-built test case with a bad spec: refused before any setup write
Reset-Mock
$hand = [PSCustomObject]@{ name = 'h'; setup = @(@{ Path = 'MAIN.x'; Value = 1 }); teardown = $null; waitMs = 0; waitUntil = @(@{ Path = 'MAIN.n'; Operator = 'nope'; Expected = 1 }); waitTimeoutMs = 100; assertions = @(@{ Path = 'MAIN.n'; Expected = 1 }) }
$r = Invoke-TcTest -TestCase $hand
Check 'Invoke-TcTest bad hand-built WaitUntil -> INVALID_PARAMS, no write' ($r.success -eq $false -and $r.error.code -eq 'INVALID_PARAMS' -and $global:Writes.Count -eq 0) ($r | ConvertTo-Json -Compress -Depth 4)

# --- condition met early: fast, assertions run, waitMs far below the timeout
Reset-Mock
$global:Plc['MAIN.bDone'] = { param($n) $n -ge 3 }
$global:Plc['MAIN.nResult'] = { param($n) 42 }
$tc = New-TcTestCase -Name 'early' -Setup @(@{ Path = 'MAIN.bStart'; Value = $true }) -Teardown @(@{ Path = 'MAIN.bStart'; Value = $false }) `
    -WaitUntil @{ Path = 'MAIN.bDone'; Operator = 'IsTrue' } -WaitTimeoutMs 10000 `
    -Assertions @(@{ Path = 'MAIN.nResult'; Operator = 'Equal'; Expected = 42 })
$sw = [Diagnostics.Stopwatch]::StartNew()
$r = Invoke-TcTest -TestCase $tc
$sw.Stop()
Check 'early: Pass, waitTimedOut=false' ($r.success -and $r.data.result -eq 'Pass' -and $r.data.waitTimedOut -eq $false) ($r | ConvertTo-Json -Compress -Depth 4)
Check 'early: returned long before the 10 s timeout, waitMs reported' ($sw.ElapsedMilliseconds -lt 3000 -and $r.data.waitMs -lt 3000 -and $global:Reads['MAIN.bDone'] -eq 3) "elapsed=$($sw.ElapsedMilliseconds) waitMs=$($r.data.waitMs) reads=$($global:Reads['MAIN.bDone'])"
Check 'early: setup and teardown written' (($global:Writes -join ',') -eq 'MAIN.bStart=True,MAIN.bStart=False') ($global:Writes -join ',')

# --- timeout: Fail with waitTimedOut / lastValues / waitMs, assertions not evaluated, teardown still runs
Reset-Mock
$global:Plc['MAIN.bDone'] = { param($n) $false }
$global:Plc['MAIN.nResult'] = { param($n) 42 }
$tc = New-TcTestCase -Name 'timeout' -Teardown @(@{ Path = 'MAIN.bStart'; Value = $false }) `
    -WaitUntil @{ Path = 'MAIN.bDone'; Operator = 'IsTrue' } -WaitTimeoutMs 500 `
    -Assertions @(@{ Path = 'MAIN.nResult'; Operator = 'Equal'; Expected = 42 })
$r = Invoke-TcTest -TestCase $tc
Check 'timeout: result Fail, waitTimedOut=true' ($r.success -and $r.data.result -eq 'Fail' -and $r.data.waitTimedOut -eq $true) ($r | ConvertTo-Json -Compress -Depth 4)
Check 'timeout: waitMs ~ timeout, lastValues has the path' ($r.data.waitMs -ge 450 -and $r.data.waitMs -lt 2500 -and $r.data.lastValues.'MAIN.bDone' -eq $false) ($r.data | ConvertTo-Json -Compress -Depth 4)
Check 'timeout: assertions not evaluated, teardown ran' (@($r.data.assertions).Count -eq 0 -and -not $global:Reads.ContainsKey('MAIN.nResult') -and ($global:Writes -join ',') -eq 'MAIN.bStart=False') ($global:Writes -join ',')

# --- multiple conditions: all must hold in the same round
Reset-Mock
$global:Plc['MAIN.bA'] = { param($n) $n -ge 2 }            # true from read 2 on
$global:Plc['MAIN.nB'] = { param($n) if ($n -ge 4) { 10 } else { 0 } }   # > 5 from read 4 on
$global:Plc['MAIN.nResult'] = { param($n) 1 }
$tc = New-TcTestCase -Name 'multi' `
    -WaitUntil @(@{ Path = 'MAIN.bA'; Operator = 'IsTrue' }, @{ Path = 'MAIN.nB'; Operator = 'GreaterThan'; Expected = 5 }) -WaitTimeoutMs 10000 `
    -Assertions @(@{ Path = 'MAIN.nResult'; Expected = 1 })
$r = Invoke-TcTest -TestCase $tc
Check 'multi: waits for the slowest condition, then Pass' ($r.success -and $r.data.result -eq 'Pass' -and $global:Reads['MAIN.nB'] -eq 4 -and $global:Reads['MAIN.bA'] -eq 4) "reads A=$($global:Reads['MAIN.bA']) B=$($global:Reads['MAIN.nB']) $($r.data | ConvertTo-Json -Compress -Depth 3)"
Reset-Mock
$global:Plc['MAIN.bA'] = { param($n) $true }
$global:Plc['MAIN.nB'] = { param($n) 0 }
$global:Plc['MAIN.nResult'] = { param($n) 1 }
$tc = New-TcTestCase -Name 'multi-timeout' `
    -WaitUntil @(@{ Path = 'MAIN.bA'; Operator = 'IsTrue' }, @{ Path = 'MAIN.nB'; Operator = 'GreaterThan'; Expected = 5 }) -WaitTimeoutMs 300 `
    -Assertions @(@{ Path = 'MAIN.nResult'; Expected = 1 })
$r = Invoke-TcTest -TestCase $tc
Check 'multi: one condition never holds -> timeout Fail, lastValues for both paths' ($r.data.result -eq 'Fail' -and $r.data.waitTimedOut -and $r.data.lastValues.'MAIN.bA' -eq $true -and $r.data.lastValues.'MAIN.nB' -eq 0) ($r.data | ConvertTo-Json -Compress -Depth 4)

# --- condition that holds on the first read does not sleep at all
Reset-Mock
$global:Plc['MAIN.bDone'] = { param($n) $true }
$global:Plc['MAIN.nResult'] = { param($n) 1 }
$tc = New-TcTestCase -Name 'now' -WaitUntil @{ Path = 'MAIN.bDone'; Operator = 'IsTrue' } -Assertions @(@{ Path = 'MAIN.nResult'; Expected = 1 })
$r = Invoke-TcTest -TestCase $tc
Check 'first-read success: waitMs < 100' ($r.data.result -eq 'Pass' -and $r.data.waitMs -lt 100 -and $global:Reads['MAIN.bDone'] -eq 1) ($r.data | ConvertTo-Json -Compress -Depth 3)

# --- legacy WaitMs still a fixed wait; result has no wait fields
Reset-Mock
$global:Plc['MAIN.nResult'] = { param($n) 7 }
$tc = New-TcTestCase -Name 'legacy-wait' -WaitMs 400 -Assertions @(@{ Path = 'MAIN.nResult'; Operator = 'GreaterThan'; Expected = 5 })
$sw = [Diagnostics.Stopwatch]::StartNew()
$r = Invoke-TcTest -TestCase $tc
$sw.Stop()
Check 'legacy WaitMs: waits the fixed time, Pass, no waitTimedOut' ($r.success -and $r.data.result -eq 'Pass' -and $sw.ElapsedMilliseconds -ge 380 -and $null -eq $r.data.PSObject.Properties['waitTimedOut']) "elapsed=$($sw.ElapsedMilliseconds) $($r.data | ConvertTo-Json -Compress -Depth 3)"
Reset-Mock
$global:Plc['MAIN.nResult'] = { param($n) 7 }
$tc = New-TcTestCase -Name 'legacy-zero' -WaitMs 0 -Assertions @(@{ Path = 'MAIN.nResult'; Operator = 'LessThan'; Expected = 5 })
$r = Invoke-TcTest -TestCase $tc
Check 'legacy WaitMs 0: failing assertion -> Fail' ($r.data.result -eq 'Fail' -and $r.data.assertions[0].pass -eq $false -and $r.data.assertions[0].expected -eq '<5') ($r.data | ConvertTo-Json -Compress -Depth 3)

# --- WaitUntil given with explicit WaitMs: WaitMs ignored
Reset-Mock
$global:Plc['MAIN.bDone'] = { param($n) $true }
$global:Plc['MAIN.nResult'] = { param($n) 1 }
$tc = New-TcTestCase -Name 'both' -WaitMs 5000 -WaitUntil @{ Path = 'MAIN.bDone'; Operator = 'IsTrue' } -Assertions @(@{ Path = 'MAIN.nResult'; Expected = 1 })
$sw = [Diagnostics.Stopwatch]::StartNew()
$r = Invoke-TcTest -TestCase $tc
$sw.Stop()
Check 'WaitUntil + WaitMs: WaitMs ignored' ($r.data.result -eq 'Pass' -and $sw.ElapsedMilliseconds -lt 2000) "elapsed=$($sw.ElapsedMilliseconds)"

# --- Invoke-TcTestCycle: no fixed Start-Sleep other than the documented no-AmsNetId fallbacks
$cycle = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\Public\Invoke-TcTestCycle.ps1') -Raw
$sleeps = [regex]::Matches($cycle, 'Start-Sleep[^\r\n]*')
$unguarded = @($sleeps | Where-Object { $_.Value -notmatch 'fall back to settle delay|Let PLC initialize' })
Check 'Invoke-TcTestCycle: only the no-AmsNetId fallback sleeps remain' ($unguarded.Count -eq 0) (($unguarded | ForEach-Object { $_.Value }) -join ' | ')

exit $fail
