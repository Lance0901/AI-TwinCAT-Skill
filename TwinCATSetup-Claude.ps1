<#
.SYNOPSIS
    Install TwinCAT Automation skill for Claude Code.
    Checks prerequisites, then installs the skill to user-level
    so Claude Code can use TwinCAT automation in ANY project.
.PARAMETER Uninstall
    Remove the user-level skill directory.
.PARAMETER Verify
    Read-only. Compare the repo's adapters/claude-code/SKILL.md (after <module-path>
    substitution) and src/TwinCATAutomation against the installed copy under
    ~/.claude/skills/twincat-automation by SHA256. Prints match / mismatch and the
    differing file names. Exit code 0 = match, 1 = mismatch or not installed.
.EXAMPLE
    pwsh ./TwinCATSetup-Claude.ps1
.EXAMPLE
    pwsh ./TwinCATSetup-Claude.ps1 -Uninstall
.EXAMPLE
    pwsh ./TwinCATSetup-Claude.ps1 -Verify
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$Verify
)

$ErrorActionPreference = 'Continue'
$pass = 0
$fail = 0
$scriptRoot = $PSScriptRoot

# Paths
$userSkillDir = Join-Path $HOME ".claude\skills\twincat-automation"
$srcModule    = Join-Path $scriptRoot "src\TwinCATAutomation"
$srcSkill     = Join-Path $scriptRoot "adapters\claude-code\SKILL.md"
$destModule   = Join-Path $userSkillDir "TwinCATAutomation"
$destSkill    = Join-Path $userSkillDir "SKILL.md"
$absModulePath = Join-Path $destModule "TwinCATAutomation.psm1"

# UTF-8 without BOM. Windows PowerShell 5.1's Set-Content -Encoding UTF8 writes a BOM,
# and Get-Content without -Encoding reads BOM-less files as ANSI, so use .NET directly.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Read-Utf8File {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Write-Utf8File {
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Get-RenderedSkillContent {
    # SKILL.md as it should appear after install: only <module-path> is substituted.
    # The frontmatter name is taken verbatim from the repo file.
    $content = Read-Utf8File $srcSkill
    # String.Replace, not -replace: the path must be inserted literally (no regex substitution tokens).
    return $content.Replace('<module-path>', $absModulePath)
}

function Get-StringSha256 {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $utf8NoBom.GetBytes($Text)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
    } finally { $sha.Dispose() }
}

function Get-FileSha256 {
    param([string]$Path)
    return (Get-FileHash -Path $Path -Algorithm SHA256).Hash
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

# --- Verify (read-only) ---
if ($Verify) {
    Write-Host ""
    Write-Host "=== Verify TwinCAT Skill (Claude Code) ===" -ForegroundColor Cyan
    Write-Host "  Repo:      $scriptRoot" -ForegroundColor DarkGray
    Write-Host "  Installed: $userSkillDir" -ForegroundColor DarkGray
    Write-Host ""

    $mismatches = New-Object System.Collections.Generic.List[string]

    if (-not (Test-Path $userSkillDir)) {
        Write-Host "  [MISMATCH] Skill not installed: $userSkillDir" -ForegroundColor Red
        Write-Host ""
        exit 1
    }

    # 1. SKILL.md (repo content with <module-path> substituted vs installed file)
    if (-not (Test-Path $srcSkill)) {
        Write-Host "  [MISMATCH] Repo SKILL.md missing: $srcSkill" -ForegroundColor Red
        $mismatches.Add('SKILL.md (repo file missing)')
    }
    elseif (-not (Test-Path $destSkill)) {
        Write-Host "  [MISMATCH] SKILL.md not installed" -ForegroundColor Red
        $mismatches.Add('SKILL.md (not installed)')
    }
    else {
        $expectedHash = Get-StringSha256 (Get-RenderedSkillContent)
        $actualHash   = Get-StringSha256 (Read-Utf8File $destSkill)
        if ($expectedHash -eq $actualHash) {
            Write-Host "  [MATCH]    SKILL.md  $expectedHash" -ForegroundColor Green
        } else {
            Write-Host "  [MISMATCH] SKILL.md" -ForegroundColor Red
            Write-Host "             expected $expectedHash" -ForegroundColor Yellow
            Write-Host "             actual   $actualHash" -ForegroundColor Yellow
            $mismatches.Add('SKILL.md')
        }
        $installedBytes = [System.IO.File]::ReadAllBytes($destSkill)
        if ($installedBytes.Length -ge 3 -and $installedBytes[0] -eq 0xEF -and $installedBytes[1] -eq 0xBB -and $installedBytes[2] -eq 0xBF) {
            Write-Host "  [WARN]     Installed SKILL.md has a UTF-8 BOM (written by an older installer)" -ForegroundColor Yellow
        }
    }

    # 2. Module directory (file-by-file SHA256)
    if (-not (Test-Path $destModule)) {
        Write-Host "  [MISMATCH] Module not installed: $destModule" -ForegroundColor Red
        $mismatches.Add('TwinCATAutomation/ (not installed)')
    }
    else {
        $srcFiles = Get-ChildItem -Path $srcModule -Recurse -File
        $dstFiles = Get-ChildItem -Path $destModule -Recurse -File
        $srcMap = @{}
        foreach ($f in $srcFiles) { $srcMap[$f.FullName.Substring($srcModule.Length).TrimStart('\', '/')] = $f.FullName }
        $dstMap = @{}
        foreach ($f in $dstFiles) { $dstMap[$f.FullName.Substring($destModule.Length).TrimStart('\', '/')] = $f.FullName }

        $moduleOk = $true
        foreach ($rel in ($srcMap.Keys | Sort-Object)) {
            if (-not $dstMap.ContainsKey($rel)) {
                Write-Host "  [MISMATCH] TwinCATAutomation\$rel  (missing in install)" -ForegroundColor Red
                $mismatches.Add("TwinCATAutomation\$rel (missing)")
                $moduleOk = $false
                continue
            }
            if ((Get-FileSha256 $srcMap[$rel]) -ne (Get-FileSha256 $dstMap[$rel])) {
                Write-Host "  [MISMATCH] TwinCATAutomation\$rel  (content differs)" -ForegroundColor Red
                $mismatches.Add("TwinCATAutomation\$rel (differs)")
                $moduleOk = $false
            }
        }
        foreach ($rel in ($dstMap.Keys | Sort-Object)) {
            if (-not $srcMap.ContainsKey($rel)) {
                Write-Host "  [MISMATCH] TwinCATAutomation\$rel  (extra in install)" -ForegroundColor Red
                $mismatches.Add("TwinCATAutomation\$rel (extra)")
                $moduleOk = $false
            }
        }
        if ($moduleOk) {
            Write-Host "  [MATCH]    TwinCATAutomation\ ($($srcMap.Count) files)" -ForegroundColor Green
        }
    }

    Write-Host ""
    if ($mismatches.Count -eq 0) {
        Write-Host "Result: match" -ForegroundColor Green
        Write-Host ""
        exit 0
    } else {
        Write-Host "Result: mismatch ($($mismatches.Count) item(s))" -ForegroundColor Red
        foreach ($m in $mismatches) { Write-Host "  - $m" -ForegroundColor Yellow }
        Write-Host ""
        Write-Host "Run 'pwsh ./TwinCATSetup-Claude.ps1' to reinstall." -ForegroundColor DarkGray
        Write-Host ""
        exit 1
    }
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
#    4024 32-bit XAE Shell = TcXaeShell.DTE.15.0, 4026 XAE Shell = TcXaeShell.DTE.17.0,
#    4026 + VS2022 = VisualStudio.DTE.17.0
$vsFound = $false
$vsDetail = ""
try {
    $dteProgIds = @("TcXaeShell.DTE.15.0", "TcXaeShell.DTE.17.0", "VisualStudio.DTE.17.0", "VisualStudio.DTE.16.0")
    foreach ($progId in $dteProgIds) {
        try {
            $type = [System.Type]::GetTypeFromProgID($progId)
            if ($null -ne $type) { $vsFound = $true; $vsDetail = $progId; break }
        } catch {}
    }
} catch {}
Write-Check "IDE available (XAE Shell / VS2022)" $vsFound $(if ($vsDetail) { "ProgID: $vsDetail" } else { "No compatible IDE found" })

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
    return
}

# --- Install to User-Level ---
Write-Host ""
Write-Host "=== Install Skill (Claude Code user-level) ===" -ForegroundColor Cyan

# 1. Create skill directory
if (-not (Test-Path $userSkillDir)) {
    New-Item -Path $userSkillDir -ItemType Directory -Force | Out-Null
}

# 2. Copy module to skill directory
if (Test-Path $destModule) { Remove-Item $destModule -Recurse -Force }
Copy-Item $srcModule -Destination $destModule -Recurse -Force
Write-Host "  Installed module: $destModule" -ForegroundColor Green

# 3. Copy SKILL.md, replace <module-path> with absolute path, write UTF-8 without BOM.
#    The frontmatter name is whatever the repo SKILL.md says; nothing is hardcoded here.
Write-Utf8File -Path $destSkill -Content (Get-RenderedSkillContent)

Write-Host "  Installed skill: $destSkill" -ForegroundColor Green
Write-Host "  Module path:     $absModulePath" -ForegroundColor White

# Done
Write-Host ""
Write-Host "=== Installation Complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "  Claude Code can now use TwinCAT automation in ANY project." -ForegroundColor Green
Write-Host "  Just ask Claude: 'Connect to TwinCAT and build the project'" -ForegroundColor White
Write-Host ""
Write-Host "  To verify:    pwsh ./TwinCATSetup-Claude.ps1 -Verify" -ForegroundColor DarkGray
Write-Host "  To uninstall: pwsh ./TwinCATSetup-Claude.ps1 -Uninstall" -ForegroundColor DarkGray
Write-Host ""
