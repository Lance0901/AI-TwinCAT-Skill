<#
.SYNOPSIS
    TwinCAT Automation setup check for Codex.
    Run this after cloning to verify all prerequisites are met.
.EXAMPLE
    pwsh ./TwinCATSetup-Codex.ps1
#>

$ErrorActionPreference = 'Continue'
$pass = 0
$fail = 0

function Write-Check {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    if ($Ok) {
        Write-Host "  [PASS] $Name" -ForegroundColor Green
        if ($Detail) { Write-Host "         $Detail" -ForegroundColor DarkGray }
        $script:pass++
    } else {
        Write-Host "  [FAIL] $Name" -ForegroundColor Red
        if ($Detail) { Write-Host "         $Detail" -ForegroundColor Yellow }
        $script:fail++
    }
}

Write-Host ""
Write-Host "=== TwinCAT Automation — Setup Check ===" -ForegroundColor Cyan
Write-Host ""

# 1. Windows
$isWin = $env:OS -eq 'Windows_NT'
Write-Check "Windows OS" $isWin $(if ($isWin) { [System.Environment]::OSVersion.VersionString } else { "TwinCAT requires Windows" })

# 2. PowerShell version
$psVer = $PSVersionTable.PSVersion
$psOk = $psVer.Major -ge 5
Write-Check "PowerShell 5.1+" $psOk "Version: $psVer"

# 3. TwinCAT installation
$tcPaths = @(
    "C:\TwinCAT\3.1",
    "${env:ProgramFiles(x86)}\Beckhoff\TwinCAT\3.1",
    "C:\TwinCAT"
)
$tcFound = $null
foreach ($p in $tcPaths) {
    if (Test-Path $p) { $tcFound = $p; break }
}
Write-Check "TwinCAT 3 installed" ($null -ne $tcFound) $(if ($tcFound) { $tcFound } else { "Not found in common paths" })

# 4. TwinCAT.Ads.dll
$adsDllSearchRoots = @(
    "C:\TwinCAT",
    "${env:ProgramFiles(x86)}\Beckhoff\TwinCAT"
)
$adsFound = $null
foreach ($root in $adsDllSearchRoots) {
    if (Test-Path $root) {
        $found = Get-ChildItem -Path $root -Filter "TwinCAT.Ads.dll" -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.DirectoryName -match 'Components[\\/]Base[\\/]v\d+' } |
            Sort-Object { [regex]::Match($_.DirectoryName, 'v(\d+)').Groups[1].Value -as [int] } -Descending |
            Select-Object -First 1
        if ($found) { $adsFound = $found.FullName; break }
    }
}
Write-Check "TwinCAT.Ads.dll" ($null -ne $adsFound) $(if ($adsFound) { $adsFound } else { "Required for ADS communication" })

# 5. Visual Studio / TwinCAT XAE Shell
$vsFound = $false
$vsDetail = ""
try {
    $dteProgIds = @("VisualStudio.DTE.17.0", "VisualStudio.DTE.16.0", "TcXaeShell.DTE.15.0")
    foreach ($progId in $dteProgIds) {
        try {
            $type = [System.Type]::GetTypeFromProgID($progId)
            if ($null -ne $type) { $vsFound = $true; $vsDetail = $progId; break }
        } catch {}
    }
} catch {}
Write-Check "IDE available (VS2022/XAE Shell)" $vsFound $(if ($vsDetail) { "ProgID: $vsDetail" } else { "No compatible IDE found" })

# 6. Module import
Write-Host ""
Write-Host "--- Module Import ---" -ForegroundColor Cyan
$modulePath = Join-Path $PSScriptRoot "src\TwinCATAutomation\TwinCATAutomation.psm1"
$moduleOk = $false
$cmdletCount = 0
try {
    Import-Module $modulePath -Force -ErrorAction Stop 3>$null
    $cmds = Get-Command -Module TwinCATAutomation -ErrorAction SilentlyContinue
    $cmdletCount = $cmds.Count
    $moduleOk = $cmdletCount -gt 0
} catch {
    $moduleOk = $false
}
Write-Check "Module import" $moduleOk "$cmdletCount cmdlets loaded"

# Summary
Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Cyan
Write-Host "  Passed: $pass" -ForegroundColor Green
Write-Host "  Failed: $fail" -ForegroundColor $(if ($fail -gt 0) { "Red" } else { "Green" })
Write-Host ""

if ($fail -eq 0) {
    Write-Host "Ready to use! Start with:" -ForegroundColor Green
    Write-Host '  Import-Module "./src/TwinCATAutomation/TwinCATAutomation.psm1" -Force'
    Write-Host '  Connect-TcIde -SolutionPath "C:\path\to\your.sln"'
} else {
    Write-Host "Some checks failed. Please install missing prerequisites." -ForegroundColor Yellow
    Write-Host "See README.md for requirements."
}
Write-Host ""
