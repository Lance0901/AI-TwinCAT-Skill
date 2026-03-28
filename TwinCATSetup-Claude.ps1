<#
.SYNOPSIS
    Install TwinCAT Automation skill for Claude Code.
    Checks prerequisites, then installs the skill to user-level
    so Claude Code can use TwinCAT automation in ANY project.
.EXAMPLE
    pwsh ./TwinCATSetup-Claude.ps1
.EXAMPLE
    pwsh ./TwinCATSetup-Claude.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [switch]$Uninstall
)

$ErrorActionPreference = 'Continue'
$pass = 0
$fail = 0
$scriptRoot = $PSScriptRoot

# Paths
$userSkillDir = Join-Path $HOME ".claude\skills\twincat-automation"

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

# --- Uninstall ---
if ($Uninstall) {
    Write-Host ""
    Write-Host "=== Uninstall TwinCAT Skill (Claude Code) ===" -ForegroundColor Yellow
    if (Test-Path $userSkillDir) {
        Remove-Item $userSkillDir -Recurse -Force
        Write-Host "  Removed: $userSkillDir" -ForegroundColor Green
    } else {
        Write-Host "  Not found: $userSkillDir" -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "Uninstall complete." -ForegroundColor Green
    Write-Host ""
    return
}

# --- Prerequisites Check ---
Write-Host ""
Write-Host "=== TwinCAT Automation - Setup Check ===" -ForegroundColor Cyan
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
$modulePath = Join-Path $scriptRoot "src\TwinCATAutomation\TwinCATAutomation.psm1"
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
Write-Host "=== Prerequisites ===" -ForegroundColor Cyan
Write-Host "  Passed: $pass" -ForegroundColor Green
Write-Host "  Failed: $fail" -ForegroundColor $(if ($fail -gt 0) { "Red" } else { "Green" })

if ($fail -gt 0) {
    Write-Host ""
    Write-Host "Some checks failed. Please install missing prerequisites." -ForegroundColor Yellow
    Write-Host "See README.md for requirements."
    Write-Host ""
    return
}

# --- Install to User-Level ---
Write-Host ""
Write-Host "=== Install Skill (Claude Code user-level) ===" -ForegroundColor Cyan

$absModulePath = (Resolve-Path $modulePath).Path

# 1. Copy skill to ~/.claude/skills/twincat-automation/
if (-not (Test-Path $userSkillDir)) {
    New-Item -Path $userSkillDir -ItemType Directory -Force | Out-Null
}

# Read source SKILL.md and replace <project-root> with absolute path
$srcSkill = Join-Path $scriptRoot "adapters\claude-code\SKILL.md"
$skillContent = Get-Content $srcSkill -Raw
$absProjectRoot = (Resolve-Path $scriptRoot).Path
$skillContent = $skillContent -replace '<project-root>', $absProjectRoot
Set-Content -Path (Join-Path $userSkillDir "SKILL.md") -Value $skillContent -Encoding UTF8

Write-Host "  Installed skill: $userSkillDir\SKILL.md" -ForegroundColor Green
Write-Host "  Module path:     $absModulePath" -ForegroundColor White

# Done
Write-Host ""
Write-Host "=== Installation Complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "  Claude Code can now use TwinCAT automation in ANY project." -ForegroundColor Green
Write-Host "  Just ask Claude: 'Connect to TwinCAT and build the project'" -ForegroundColor White
Write-Host ""
Write-Host "  To uninstall: pwsh ./TwinCATSetup-Claude.ps1 -Uninstall" -ForegroundColor DarkGray
Write-Host ""
