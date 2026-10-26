# Integration: verify an ADS write sticks on a non-input variable.
# Problem: FB VAR_INPUT (e.g. bStart) is rewritten by MAIN each PLC scan, so an ADS write
#          is overwritten; nBurstCount is written to check whether it sticks, which proves it.
# Prerequisites: TwinCAT XAE/IDE open, UmRT running, solution with MAIN.fbLoggerFlowTest.
# Assumption: write MAIN-level (standalone) variables instead of FB VAR_INPUT.

param(
    [string]$SolutionPath = 'C:\Users\aka09\OneDrive\1000-Projects\2026-FB_Logger_V3\Logger-Service\Logger-Service.sln',
    # Pass -AllowUnresolvedLibrary to Build-TcProject: accept LIBRARY_UNRESOLVED (project with missing libraries, #45 / #56).
    [switch]$AllowUnresolvedLibrary
)

# Verify: Can ADS write stick on a non-input variable?
# If nBurstCount write sticks but bStart doesn't, it proves the PLC is overwriting bStart each cycle

Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force


Write-Host "=== Connect & Start ==="
Connect-TcIde -SolutionPath $SolutionPath | Out-Null
$amsNetId = (Connect-TcIde -SolutionPath $SolutionPath).data.amsNetId
Build-TcProject -AllowUnresolvedLibrary:$AllowUnresolvedLibrary | Out-Null
Enable-TcConfig -Force | Out-Null
Start-Sleep -Seconds 5
Enter-TcPlcOnline | Out-Null
Start-Sleep -Seconds 2
Connect-TcAds -AmsNetId $amsNetId | Out-Null
Set-TcPlcState -State Run | Out-Null
Start-Sleep -Seconds 1

Write-Host ""
Write-Host "=== Test A: Write nBurstCount (VAR_INPUT but maybe not overwritten) ==="
$before = (Read-TcVariable -Path "MAIN.fbLoggerFlowTest.nBurstCount").data
Write-Host "  Before: $($before.value) (type: $($before.type))"
Write-TcVariable -Path "MAIN.fbLoggerFlowTest.nBurstCount" -Value ([uint16]99) | Out-Null
Start-Sleep -Milliseconds 200
$after = (Read-TcVariable -Path "MAIN.fbLoggerFlowTest.nBurstCount").data
Write-Host "  After:  $($after.value) (type: $($after.type))"
if ($after.value -eq 99) {
    Write-Host "  RESULT: Write STICKS -> nBurstCount not overwritten by PLC"
} else {
    Write-Host "  RESULT: Write OVERWRITTEN -> PLC resets nBurstCount each cycle too"
}
# Restore
Write-TcVariable -Path "MAIN.fbLoggerFlowTest.nBurstCount" -Value ([uint16]6) | Out-Null

Write-Host ""
Write-Host "=== Test B: Write bStart (VAR_INPUT, likely overwritten) ==="
$before = (Read-TcVariable -Path "MAIN.fbLoggerFlowTest.bStart").data
Write-Host "  Before: $($before.value)"
Write-TcVariable -Path "MAIN.fbLoggerFlowTest.bStart" -Value $true | Out-Null
Start-Sleep -Milliseconds 200
$after = (Read-TcVariable -Path "MAIN.fbLoggerFlowTest.bStart").data
Write-Host "  After:  $($after.value)"
if ($after.value -eq $true) {
    Write-Host "  RESULT: Write STICKS"
} else {
    Write-Host "  RESULT: Write OVERWRITTEN -> PLC forces bStart=FALSE each cycle"
}

Write-Host ""
Write-Host "=== Test C: List all MAIN.* variables (find a standalone VAR) ==="
$symbols = Get-TcSymbols -Filter "MAIN.*"
if ($symbols.success) {
    foreach ($s in $symbols.data) {
        # Only show MAIN-level vars (not nested FB internals)
        $parts = $s.path -split '\.'
        if ($parts.Count -le 2) {
            Write-Host "  $($s.path) : $($s.type)"
        }
    }
}

Write-Host ""
Write-Host "=== DONE ==="
