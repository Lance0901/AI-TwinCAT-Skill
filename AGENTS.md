# TwinCAT Automation — AI Tool Guide

This project provides a PowerShell module for automating TwinCAT 3 IDE and PLC runtime. It works with **Codex**, Claude Code, and any AI coding tool.

## Quick Start

```powershell
Import-Module "./src/TwinCATAutomation/TwinCATAutomation.psm1" -Force
```

Or run the setup check first:
```powershell
pwsh ./TwinCATSetup-Codex.ps1
```

## Core Workflow (No Dialogs)

The full PLC lifecycle runs without any dialog popups:

```powershell
# 1. Connect to IDE (auto-opens solution if -SolutionPath given)
Connect-TcIde -SolutionPath "C:\Projects\MyProject.sln"

# 1b. TwinCAT 4026 XAE: solution platform must equal the target platform (UmRT = Usermode Runtime = 'TwinCAT OS (x64)'),
#     else ACTIVATE_FAILED. Without -Platform it is read from the target (TARGETINFO); ADS 0x702 -> PLATFORM_UNKNOWN
Set-TcTarget -AmsNetId <data.amsNetId> -Platform 'TwinCAT OS (x64)'

# 2. Build
Build-TcProject

# 3. Activate, one step: Config -> Activate -> wait Run -> Login+Download -> wait port 851 -> PLC Run
#    Already includes Enter-TcPlcOnline and Set-TcPlcState Run. No Start-Sleep needed.
Enable-TcConfig -Force

# 4. Connect ADS (AmsNetId auto-detected from IDE target)
Connect-TcAds

# 5. Read/Write variables
Read-TcVariable -Path "MAIN.nCounter"
Write-TcVariable -Path "MAIN.bEnable" -Value $true
```

Errors: see `docs/troubleshooting.md` (error code table, lifecycle order, environment matrix). `error.hint`, when present, is the suggested next action.

## Important Notes

- **AmsNetId is dynamic** — it changes per target. Never hardcode it. `Connect-TcAds` auto-detects from the active IDE connection.
- **All commands return JSON**: `{"success": true, "data": {...}}` or `{"success": false, "error": {"message": "...", "code": "..."}}`
- **No dialogs**: `Enable-TcConfig -Force` uses ADS WriteControl. `Connect-TcIde` enables the global `SilentMode`; `Enter-TcPlcOnline` uses `Login(REGULAR=1)` (flag 3 is mutually exclusive and aborts; no `SILENT` flag by default).
- **Write MAIN-level vars for FB testing** — PLC overwrites `VAR_INPUT` every scan cycle. Write standalone variables in MAIN that feed into FB calls.
- **Correct lifecycle order**: Build -> Activate -> Login -> ADS Connect -> Start PLC -> Test (ADS port 851 only exists after Login+Download)

## Available Commands (36)

### Connection
- `Connect-TcIde [-SolutionPath <path>]` — Connect to IDE
- `Disconnect-TcIde` — Disconnect from IDE
- `Reset-TcSolution [-SolutionPath <sln>]` — Dismiss the reload prompt, close all documents, close + reopen the solution on the same IDE so XAE reloads files changed on disk (only needed when the changed .TcPOU is open in an editor)
- `Connect-TcAds [-AmsNetId <id>]` — Connect ADS (auto-detects AmsNetId)
- `Disconnect-TcAds` — Disconnect ADS

### Project Management
- `New-TcProject -Name <name> [-Path <dir>]` — Create project
- `Open-TcProject -Path <sln>` — Open solution
- `Add-TcPou -Name <name> -Type <Program|FunctionBlock|Function>` — Add POU
- `Add-TcGvl -Name <name>` — Add GVL
- `Add-TcDut -Name <name> -DutType <Struct|Enum|Alias|Union>` — Add DUT
- `Add-TcLibrary -Name <name>` — Add library reference

### Code
- `Get-TcPouCode -PouName <name> [-PouPath <treePath>]` — Read POU code
- `Write-TcPouCode -PouName <name> -Declaration <text> -Implementation <text>` — Write POU code
- `Get-TcProjectTree` — Get project structure

### Build & Deploy
- `Build-TcProject [-TimeoutSec 600]` — Build (auto-retry on RPC busy; polls `BuildState`, `BUILD_TIMEOUT` on expiry); `data.errorItems[]` = Error List errors (description/file/line), `data.buildSec`
- `Get-TcBuildErrors [-IncludeWarnings] [-IncludeMessages]` — Read the XAE Error List via UI Automation
- `Enable-TcConfig [-Force]` — Activate config via ADS
- `Enter-TcPlcOnline` — Login + Download (no dialogs)
- `Exit-TcPlcOnline` — Logout
- `Send-TcPlcProgram` — Upload program

### Runtime
- `Set-TcPlcState -State <Run|Stop|Reset>` — Control PLC
- `Get-TcPlcState` — Read PLC state
- `Set-TcSystemState -State <Run|Config>` — System state
- `Get-TcSystemState` — Read system state
- `Set-TcTarget -AmsNetId <id> [-Platform <name>] [-Configuration Release] [-NoPlatformSwitch]` — Set target; the solution platform follows the target platform (TARGETINFO, ADS port 200 IG 0x700) or `-Platform` (UmRT: `'TwinCAT OS (x64)'`); unreadable without `-Platform` -> `PLATFORM_UNKNOWN` (NetId already set, `data.targetSet`); `-NoPlatformSwitch` = NetId only
- `Enable-TcConfig ... [-Platform <name>] [-NoPlatformFix]` — before Activate compares solution vs target platform (or `-Platform`), switches + rebuilds on a mismatch (`PLATFORM_MISMATCH` with `-NoPlatformFix`); neither known -> `data.platformCheck = 'skipped'` + warning
- `Get-TcIdeInfo` — IDE info

### ADS Variables
- `Read-TcVariable -Path <varPath>` — Read variable
- `Write-TcVariable -Path <varPath> -Value <value>` — Write variable
- `Watch-TcVariable -Path <varPath> -IntervalMs <ms>` — Monitor variable
- `Get-TcSymbols [-Filter <pattern>]` — List symbols

### I/O
- `Invoke-TcIoScan` — Scan EtherCAT
- `Get-TcIoTree` — Read I/O tree
- `Set-TcVariableLink` — Link variable to I/O

### Testing
- `New-TcTestCase -Name <name> -Assertions @(...)` — Define test
- `Invoke-TcTest -TestCase <tc>` — Run single test
- `Invoke-TcTestCycle -TestCases @(...)` — Full Build-Deploy-Test cycle
