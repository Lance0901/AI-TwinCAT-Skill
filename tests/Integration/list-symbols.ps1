# Integration: list MAIN-level symbols to find writable standalone variables.
# Problem: need to locate variables that are not FB inputs (and so not overwritten each scan).
# Prerequisites: TwinCAT XAE/IDE open, UmRT running, a solution with a MAIN program.

param(
    [string]$SolutionPath = 'C:\Users\aka09\OneDrive\1000-Projects\2026-FB_Logger_V3\Logger-Service\Logger-Service.sln',
    # Pass -AllowUnresolvedLibrary to Build-TcProject: accept LIBRARY_UNRESOLVED (project with missing libraries, #45). Since #61 that build is never complete: a later Enable-TcConfig / login still refuses with BUILD_REQUIRED.
    [switch]$AllowUnresolvedLibrary
)

# List MAIN-level symbols to find writable standalone variables
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force


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

Write-Host "=== All MAIN.* symbols ==="
$symbols = Get-TcSymbols -Filter "MAIN.*"
if ($symbols.success) {
    foreach ($s in $symbols.data) {
        Write-Host "  $($s.path) : $($s.type)"
    }
} else {
    Write-Host "Error: $($symbols.error.message)"
}
