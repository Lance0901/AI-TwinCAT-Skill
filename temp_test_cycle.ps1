Import-Module "$PSScriptRoot/src/TwinCATAutomation/TwinCATAutomation.psm1" -Force

$slnPath = "C:\Users\aka09\OneDrive\1000-Projects\2026-FB_Logger_V3\Logger-Service\Logger-Service.sln"

# Step 1: Connect
Write-Host "=== Step 1: Connect IDE ==="
$r = Connect-TcIde -SolutionPath $slnPath
Write-Host ($r | ConvertTo-Json -Compress)
$amsNetId = $r.data.amsNetId

# Step 2: Define test cases
Write-Host ""
Write-Host "=== Step 2: Define Test Cases ==="

$test1 = New-TcTestCase -Name "Initial state check" -Assertions @(
    @{ Path = "MAIN.fbLoggerFlowTest.bStart"; Operator = "IsFalse"; Expected = $null }
    @{ Path = "MAIN.fbLoggerFlowTest.bBusy"; Operator = "IsFalse"; Expected = $null }
    @{ Path = "MAIN.fbLoggerFlowTest.nBurstCount"; Operator = "Equal"; Expected = [uint16]6 }
)
Write-Host "Test 1 defined: $($test1.name)"

$test2 = New-TcTestCase -Name "Trigger flow test and check completion" `
    -Setup @(
        @{ Path = "MAIN.bRunFlowTest"; Value = $true }
    ) `
    -WaitMs 2000 `
    -Assertions @(
        @{ Path = "MAIN.fbLoggerFlowTest.bDone"; Operator = "IsTrue"; Expected = $null }
    ) `
    -Teardown @(
        @{ Path = "MAIN.bRunFlowTest"; Value = $false }
    )
Write-Host "Test 2 defined: $($test2.name)"

# Step 3: Build
Write-Host ""
Write-Host "=== Step 3: Build ==="
$buildResult = Build-TcProject
Write-Host "Build: $($buildResult.success) errors=$($buildResult.data.errors)"
if (-not $buildResult.success) { Write-Host "BUILD FAILED: $($buildResult.error.message)"; exit 1 }

# Step 4: Activate (Config -> Activate -> Run via ADS)
Write-Host ""
Write-Host "=== Step 4: Activate ==="
$activateResult = Enable-TcConfig -Force
Write-Host "Activate: $($activateResult.success)"
if (-not $activateResult.success) { Write-Host "ACTIVATE FAILED: $($activateResult.error.message)"; exit 1 }

# Wait for TwinCAT restart — DO NOT reconnect IDE (original COM reference survives)
Write-Host "Waiting 5 seconds for TwinCAT restart..."
Start-Sleep -Seconds 5

# Step 5: Login + Download (use original SysManager reference — no reconnect!)
Write-Host ""
Write-Host "=== Step 5: Login + Download ==="
$loginResult = Enter-TcPlcOnline
Write-Host "Login: $($loginResult.success) $($loginResult.data.message)"
if (-not $loginResult.success) { Write-Host "LOGIN FAILED: $($loginResult.error.message)"; exit 1 }

Start-Sleep -Seconds 2

# Step 6: Connect ADS
Write-Host ""
Write-Host "=== Step 6: Connect ADS ==="
$adsResult = Connect-TcAds -AmsNetId $amsNetId
Write-Host "ADS: $($adsResult.success) state=$($adsResult.data.state)"
if (-not $adsResult.success) { Write-Host "ADS FAILED: $($adsResult.error.message)"; exit 1 }

# Step 7: Start PLC
Write-Host ""
Write-Host "=== Step 7: Start PLC ==="
$startResult = Set-TcPlcState -State Run
Write-Host "Start: $($startResult.success) state=$($startResult.data.currentState)"
Start-Sleep -Milliseconds 500

# Step 8: Run Tests
Write-Host ""
Write-Host "=== Step 8: Run Tests ==="
foreach ($tc in @($test1, $test2)) {
    Write-Host "  Running: $($tc.name)"
    $result = Invoke-TcTest -TestCase $tc
    if ($result.success) {
        Write-Host "    Result: $($result.data.result)"
        foreach ($a in $result.data.assertions) {
            Write-Host "      $($a.path): actual=$($a.actual) expected=$($a.expected) op=$($a.operator) pass=$($a.passed)"
        }
    } else {
        Write-Host "    ERROR: $($result.error.message)"
    }
}

Write-Host ""
Write-Host "=========================================="
Write-Host "  TEST CYCLE COMPLETE"
Write-Host "=========================================="
