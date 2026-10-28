# Integration: BOOL write methods comparison (WriteAny vs raw ADS write).
# Problem: writing a BOOL via ADS did not seem to take effect; this compares
#          WriteAny([bool]) against a raw 1-byte ADS write and monitors the result.
# Prerequisites: TwinCAT XAE/IDE open, UmRT running, a solution containing
#          MAIN.fbLoggerFlowTest (adjust paths below / -SolutionPath).
# Assumption: the FB input is overwritten by MAIN every PLC scan, so writes may not stick.

param(
    [string]$SolutionPath = 'C:\Users\aka09\OneDrive\1000-Projects\2026-FB_Logger_V3\Logger-Service\Logger-Service.sln',
    # Pass -AllowUnresolvedLibrary to Build-TcProject: accept LIBRARY_UNRESOLVED (project with missing libraries, #45). Since #61 that build is never complete: a later Enable-TcConfig / login still refuses with BUILD_REQUIRED.
    [switch]$AllowUnresolvedLibrary
)

# Diagnostic: BOOL write methods comparison
# Test different approaches to writing BOOL values via ADS

Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force


Write-Host "=== Connect & Start ==="
$r = Connect-TcIde -SolutionPath $SolutionPath
$amsNetId = $r.data.amsNetId
Build-TcProject -AllowUnresolvedLibrary:$AllowUnresolvedLibrary | Out-Null
Enable-TcConfig -Force | Out-Null
Start-Sleep -Seconds 5
Enter-TcPlcOnline | Out-Null
Start-Sleep -Seconds 2
Connect-TcAds -AmsNetId $amsNetId | Out-Null
Set-TcPlcState -State Run | Out-Null
Start-Sleep -Seconds 1

$path = "MAIN.fbLoggerFlowTest.bStart"
$client = (Get-Variable -Name TcAdsClient -Scope Script -ErrorAction SilentlyContinue)
# Access internal client via module scope
$client = & (Get-Module TwinCATAutomation) { $script:TcAdsClient }

Write-Host ""
Write-Host "=== Symbol Info ==="
$symInfo = [TcAdsHelper]::GetSymbolInfo($client, $path)
Write-Host "  Name:     $($symInfo['Name'])"
Write-Host "  Type:     $($symInfo['TypeName'])"
Write-Host "  Size:     $($symInfo['Size']) bytes"
Write-Host "  DataType: $($symInfo['DataTypeId'])"
Write-Host "  IG:       0x$($symInfo['IndexGroup'].ToString('X8'))"
Write-Host "  IO:       0x$($symInfo['IndexOffset'].ToString('X8'))"

Write-Host ""
Write-Host "=== Method 1: WriteAny with [bool] ==="
$handle = $client.CreateVariableHandle($path)
try {
    $client.WriteAny($handle, [bool]$true)
    Write-Host "  WriteAny([bool]true) done"
    Start-Sleep -Milliseconds 200
    $val = $client.ReadAny($handle, [bool])
    Write-Host "  ReadAny([bool]) = $val"
} finally {
    $client.DeleteVariableHandle($handle)
}

Write-Host ""
Write-Host "=== Method 2: Raw ADS Write (1 byte, value 1) ==="
$ig = $symInfo['IndexGroup']
$io = $symInfo['IndexOffset']
$stream = New-Object TwinCAT.Ads.AdsStream(1)
$writer = New-Object System.IO.BinaryWriter($stream)
$writer.Write([byte]1)
$stream.Position = 0
$client.Write($ig, $io, $stream, 0, 1)
Write-Host "  Raw write 0x01 (1 byte) done"
Start-Sleep -Milliseconds 200
$readStream = New-Object TwinCAT.Ads.AdsStream(1)
$client.Read($ig, $io, $readStream, 0, 1)
$readStream.Position = 0
$reader = New-Object System.IO.BinaryReader($readStream)
$rawVal = $reader.ReadByte()
Write-Host "  Raw read = $rawVal (0x$($rawVal.ToString('X2')))"

# Also check bStart via Read-TcVariable
$rv = Read-TcVariable -Path $path
Write-Host "  Read-TcVariable = $($rv.data.value)"

Write-Host ""
Write-Host "=== Monitor after raw write ==="
for ($i = 1; $i -le 5; $i++) {
    Start-Sleep -Milliseconds 500
    $bStart = (Read-TcVariable -Path "MAIN.fbLoggerFlowTest.bStart").data.value
    $bBusy  = (Read-TcVariable -Path "MAIN.fbLoggerFlowTest.bBusy").data.value
    $nStep  = (Read-TcVariable -Path "MAIN.fbLoggerFlowTest.nStep").data.value
    Write-Host "  [$i] bStart=$bStart bBusy=$bBusy nStep=$nStep"
}

Write-Host ""
Write-Host "=== Method 3: Reset with raw write 0x00, then try WriteAny again ==="
$stream.Position = 0
$writer.Write([byte]0)
$stream.Position = 0
$client.Write($ig, $io, $stream, 0, 1)
Start-Sleep -Milliseconds 500
Write-Host "  Reset to FALSE"
$rv = Read-TcVariable -Path $path
Write-Host "  Verify: bStart = $($rv.data.value)"

Write-Host ""
Write-Host "=== DONE ==="
