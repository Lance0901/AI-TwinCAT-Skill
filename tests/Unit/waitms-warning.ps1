# Unit: task 1.8 WaitMs deprecation at run time (phase0-1.7 finding 3): New-TcTestCase data.warning,
# Invoke-TcTest / Invoke-TcTestCycle results carry it, no misleading default waitMs with WaitUntil.
# No IDE / ADS: Ensure-TcAdsConnection, Read/Write-TcVariable and the lifecycle cmdlets used by
# Invoke-TcTestCycle are stubbed in module scope.
#   powershell.exe -NoProfile -File tests/Unit/waitms-warning.ps1
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

& $mod {
    function script:Ensure-TcAdsConnection { $false }
    function script:Write-TcVariable { [CmdletBinding()] param($Path, $Value) [PSCustomObject]@{ success = $true } }
    function script:Read-TcVariable { [CmdletBinding()] param([string]$Path) [PSCustomObject]@{ success = $true; data = [PSCustomObject]@{ path = $Path; value = 1; type = 'INT' } } }
}
$asserts = @(@{ Path = 'MAIN.n'; Expected = 1 })

# --- New-TcTestCase
$tc = New-TcTestCase -Name 'legacy-default' -Assertions $asserts
Check 'no WaitUntil (default WaitMs 1000) -> warning: deprecated, use WaitUntil' ($tc.waitMs -eq 1000 -and $tc.warning -match 'deprecated' -and $tc.warning -match 'WaitUntil') ($tc | ConvertTo-Json -Compress)
$tc = New-TcTestCase -Name 'legacy-200' -WaitMs 200 -Assertions $asserts
Check 'explicit WaitMs only -> warning' ($tc.waitMs -eq 200 -and $tc.warning -match 'WaitMs is deprecated') ($tc | ConvertTo-Json -Compress)
$tc = New-TcTestCase -Name 'zero' -WaitMs 0 -Assertions $asserts
Check 'WaitMs 0 (no wait) -> no warning' ($tc.waitMs -eq 0 -and $null -eq $tc.PSObject.Properties['warning']) ($tc | ConvertTo-Json -Compress)
$tc = New-TcTestCase -Name 'wu' -WaitUntil @{ Path = 'MAIN.b'; Operator = 'IsTrue' } -Assertions $asserts
Check 'WaitUntil -> no waitMs (no misleading 1000), no warning' ($null -eq $tc.PSObject.Properties['waitMs'] -and $null -eq $tc.PSObject.Properties['warning'] -and $tc.waitTimeoutMs -eq 5000) ($tc | ConvertTo-Json -Compress -Depth 4)
$tc = New-TcTestCase -Name 'both' -WaitMs 5000 -WaitUntil @{ Path = 'MAIN.b'; Operator = 'IsTrue' } -Assertions $asserts
Check 'WaitUntil + explicit WaitMs -> waitMsIgnored + warning, no waitMs' ($null -eq $tc.PSObject.Properties['waitMs'] -and $tc.waitMsIgnored -eq 5000 -and $tc.warning -match 'ignored') ($tc | ConvertTo-Json -Compress -Depth 4)

# --- Invoke-TcTest carries the warning
$r = Invoke-TcTest -TestCase (New-TcTestCase -Name 'run-legacy' -WaitMs 50 -Assertions $asserts)
Check 'Invoke-TcTest WaitMs -> data.warning, still Pass' ($r.success -and $r.data.result -eq 'Pass' -and $r.data.warning -match 'deprecated') ($r.data | ConvertTo-Json -Compress -Depth 3)
$r = Invoke-TcTest -TestCase (New-TcTestCase -Name 'run-wu' -WaitUntil @{ Path = 'MAIN.n'; Operator = 'Equal'; Expected = 1 } -Assertions $asserts)
Check 'Invoke-TcTest WaitUntil -> no warning' ($r.success -and $r.data.result -eq 'Pass' -and $null -eq $r.data.PSObject.Properties['warning']) ($r.data | ConvertTo-Json -Compress -Depth 3)
# hand-built / JSON test case (MCP RunTest): no own warning, still gets the text
$hand = '{"name":"h","setup":null,"teardown":null,"waitMs":30,"assertions":[{"Path":"MAIN.n","Expected":1}]}' | ConvertFrom-Json
$hand.assertions = @(@{ Path = 'MAIN.n'; Expected = 1 })
$r = Invoke-TcTest -TestCase $hand
$text = & $mod { $script:TcWaitMsDeprecatedWarning }
Check 'Invoke-TcTest hand-built WaitMs test case -> default warning' ($r.success -and $r.data.warning -eq $text) ($r.data | ConvertTo-Json -Compress -Depth 3)
# setup write fails -> Error result still carries the warning
& $mod { function script:Write-TcVariable { [CmdletBinding()] param($Path, $Value) [PSCustomObject]@{ success = $false; error = [PSCustomObject]@{ message = 'nope'; code = 'X' } } } }
$r = Invoke-TcTest -TestCase (New-TcTestCase -Name 'setup-fail' -WaitMs 10 -Setup @(@{ Path = 'MAIN.x'; Value = 1 }) -Assertions $asserts)
Check 'Invoke-TcTest setup failure (Error) -> warning kept' ($r.data.result -eq 'Error' -and $r.data.warning -match 'deprecated') ($r.data | ConvertTo-Json -Compress)
& $mod { function script:Write-TcVariable { [CmdletBinding()] param($Path, $Value) [PSCustomObject]@{ success = $true } } }

# --- Invoke-TcTestCycle: per-result warning + data.warnings
& $mod {
    $script:TcSysManager = $null
    function script:Enable-TcConfig { param([switch]$Force) New-TcResult -Success $true -Data ([PSCustomObject]@{ activated = $true }) }
    function script:Connect-TcIde { New-TcResult -Success $true -Data ([PSCustomObject]@{ amsNetId = $null }) }
    function script:Enter-TcPlcOnline { New-TcResult -Success $true -Data ([PSCustomObject]@{ online = $true }) }
    function script:Connect-TcAds { param($AmsNetId) $script:TcAdsAmsNetId = $null; New-TcResult -Success $true -Data ([PSCustomObject]@{ connected = $true }) }
    function script:Set-TcPlcState { param($State) New-TcResult -Success $true -Data ([PSCustomObject]@{ state = $State }) }
    function script:Start-Sleep { param($Seconds, $Milliseconds) }
}
$cases = @(
    (New-TcTestCase -Name 'c-legacy' -WaitMs 20 -Assertions $asserts),
    (New-TcTestCase -Name 'c-wu' -WaitUntil @{ Path = 'MAIN.n'; Operator = 'Equal'; Expected = 1 } -Assertions $asserts)
)
$r = Invoke-TcTestCycle -TestCases $cases -SkipBuild -KeepRunning
$legacy = @($r.data.results | Where-Object { $_.name -eq 'c-legacy' })[0]
$wu = @($r.data.results | Where-Object { $_.name -eq 'c-wu' })[0]
Check 'Invoke-TcTestCycle: WaitMs result has warning, WaitUntil result none' ($r.success -and $legacy.warning -match 'deprecated' -and $null -eq $wu.PSObject.Properties['warning']) ($r.data.results | ConvertTo-Json -Compress -Depth 3)
Check 'Invoke-TcTestCycle: data.warnings lists the WaitMs test case once' (@($r.data.warnings).Count -eq 1 -and @($r.data.warnings)[0] -like 'c-legacy: *deprecated*') ($r.data.warnings -join ' | ')
$r = Invoke-TcTestCycle -TestCases @($cases[1]) -SkipBuild -KeepRunning
Check 'Invoke-TcTestCycle: no WaitMs test case -> no data.warnings' ($r.success -and $null -eq $r.data.PSObject.Properties['warnings']) ($r.data | ConvertTo-Json -Compress -Depth 3)

"failed: $fail"
exit [Math]::Min($fail, 255)
