<#
.SYNOPSIS
    Install TwinCAT Automation skill for Google Antigravity.
    Checks prerequisites, then installs the skill to user-level
    so Antigravity can use TwinCAT automation in ANY project.
.DESCRIPTION
    Writes tcauto-install-manifest.json into the skill directory (#30): source repository,
    module version, commit (read from the .git files of this checkout, or from the
    tcauto-source.json stamp of a release zip; git is not started), install time and the
    SHA256 of every installed file. Get-TcAutomationVersion (MCP GetAutomationVersion) reads
    it offline. The Claude Code and Codex installers write the same schema.
.PARAMETER Uninstall
    Remove the skill directory.
.PARAMETER Verify
    Read-only. Prints the install manifest (source, version, commit, install time), checks the
    installed files against the manifest hashes, and compares them with an install from this
    source (.agents/skills/twincat/SKILL.md with <module-path> substituted, src/TwinCATAutomation).
    Exit code 0 = match, 1 = mismatch, not installed or no manifest.
.PARAMETER SkillDir
    Skill directory. Default: ~/.gemini/antigravity/skills/twincat-automation. A relative path is resolved against the current PowerShell location. Tests pass a temp folder.
.PARAMETER SkipPrerequisites
    Skip the TwinCAT / IDE / module import checks (tests and CI without TwinCAT).
.EXAMPLE
    pwsh ./TwinCATSetup-Antigravity.ps1
.EXAMPLE
    pwsh ./TwinCATSetup-Antigravity.ps1 -Uninstall
.EXAMPLE
    pwsh ./TwinCATSetup-Antigravity.ps1 -Verify
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$Verify,
    [string]$SkillDir = (Join-Path $HOME ".gemini\antigravity\skills\twincat-automation"),
    [switch]$SkipPrerequisites
)

$ErrorActionPreference = 'Continue'
$pass = 0
$fail = 0
$scriptRoot = $PSScriptRoot

# Paths
$srcModule    = Join-Path $scriptRoot "src\TwinCATAutomation"
$srcSkill     = Join-Path $scriptRoot ".agents\skills\twincat\SKILL.md"

# Install / manifest / verify helpers shared with the module (Get-TcAutomationVersion) and the
# other installers. A missing or broken helper is a failed run (exit 1), never a silent success.
$helper = Join-Path $srcModule "Private\InstallManifest.ps1"
if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) {
    Write-Host "  [FAIL] Installer helper missing: $helper (incomplete source tree; re-download or re-clone)" -ForegroundColor Red
    exit 1
}
try {
    $ErrorActionPreference = 'Stop'
    . $helper
    # absolute (relative to the PowerShell location, not the process directory), real spelling
    $userSkillDir = Resolve-TcInstallPath -Path $SkillDir -SessionState $ExecutionContext.SessionState
    $ErrorActionPreference = 'Continue'
}
catch {
    Write-Host "  [FAIL] Installer setup failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

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
    Write-Host "=== Uninstall TwinCAT Skill (Antigravity) ===" -ForegroundColor Yellow
    if (Test-Path -LiteralPath $userSkillDir) {
        if (-not (Test-TcInstalledSkillDir -Dir $userSkillDir)) {
            # never delete a folder this installer did not write (a mistyped -SkillDir)
            Write-Host "  [FAIL] Not a TwinCAT skill folder (no $($script:TcInstallManifestName), no SKILL.md + TwinCATAutomation\TwinCATAutomation.psd1): $userSkillDir; nothing removed" -ForegroundColor Red
            Write-Host ""
            exit 1
        }
        try {
            Remove-Item -LiteralPath $userSkillDir -Recurse -Force -ErrorAction Stop
        }
        catch {
            Write-Host "  [FAIL] Could not remove $userSkillDir`: $($_.Exception.Message) (a file in use? close the AI tool / PowerShell that loaded the module and retry)" -ForegroundColor Red
            Write-Host ""
            exit 1
        }
        Write-Host "  Removed: $userSkillDir" -ForegroundColor Green
    } else {
        Write-Host "  Not found: $userSkillDir" -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "Uninstall complete." -ForegroundColor Green
    Write-Host ""
    return
}

# --- Verify (read-only) ---
if ($Verify) {
    $code = 1
    try {
        $code = Invoke-TcInstallVerify -SkillDir $userSkillDir -SourceRoot $scriptRoot -SkillSource $srcSkill `
            -Label 'Antigravity' -InstallerScript 'pwsh ./TwinCATSetup-Antigravity.ps1'
    }
    catch {
        Write-Host "  [FAIL] Verify failed: $($_.Exception.Message)" -ForegroundColor Red
        $code = 1
    }
    if ($code -isnot [int]) { $code = 1 }
    exit $code
}
# --- Prerequisites Check ---
if ($SkipPrerequisites) {
    Write-Host ""
    Write-Host "=== Prerequisites skipped (-SkipPrerequisites) ===" -ForegroundColor Yellow
}
else {
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
    $modulePath = Join-Path $srcModule "TwinCATAutomation.psm1"
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
        exit 1
    }
}

# --- Install to User-Level ---
Write-Host ""
Write-Host "=== Install Skill (Antigravity user-level) ===" -ForegroundColor Cyan

# Module -> <skill>\TwinCATAutomation, SKILL.md with <module-path> = absolute path (UTF-8 without
# BOM), then the install manifest.
$manifest = $null
try {
    $manifest = Install-TcSkillPayload -SkillDir $userSkillDir -SourceRoot $scriptRoot -SkillSource $srcSkill -Installer 'antigravity'
}
catch {
    Write-Host "  [FAIL] Install failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "         The skill folder may be incomplete: fix the cause and run this installer again." -ForegroundColor Yellow
    Write-Host ""
    exit 1
}
if ($null -eq $manifest) {
    Write-Host "  [FAIL] Install failed: no install manifest written" -ForegroundColor Red
    exit 1
}
$absModulePath = Join-Path $userSkillDir "TwinCATAutomation\TwinCATAutomation.psm1"

Write-Host "  Installed module: $(Join-Path $userSkillDir 'TwinCATAutomation')" -ForegroundColor Green
Write-Host "  Installed skill:  $(Join-Path $userSkillDir 'SKILL.md')" -ForegroundColor Green
Write-Host "  Manifest:         $(Join-Path $userSkillDir $script:TcInstallManifestName)" -ForegroundColor Green
Write-Host "  Version:          $($manifest.version)  commit $(if ($manifest.commit) { $manifest.commit } else { '(unknown)' }) [$($manifest.commitSource)]" -ForegroundColor White
Write-Host "  Module path:      $absModulePath" -ForegroundColor White

# Done
Write-Host ""
Write-Host "=== Installation Complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "  Antigravity can now use TwinCAT automation in ANY project." -ForegroundColor Green
Write-Host "  Just ask: 'Connect to TwinCAT and build the project'" -ForegroundColor White
Write-Host ""
Write-Host "  To verify:    pwsh ./TwinCATSetup-Antigravity.ps1 -Verify" -ForegroundColor DarkGray
Write-Host "  To uninstall: pwsh ./TwinCATSetup-Antigravity.ps1 -Uninstall" -ForegroundColor DarkGray
Write-Host ""