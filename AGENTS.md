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

# 2. Build
Build-TcProject

# 3. Activate + Start (Config -> Activate -> Run, all via ADS)
Enable-TcConfig -Force

# 4. Login + Download program (Login(3) suppresses all dialogs)
Enter-TcPlcOnline

# 5. Connect ADS (AmsNetId auto-detected from IDE target)
Connect-TcAds

# 6. Start PLC
Set-TcPlcState -State Run

# 7. Read/Write variables
Read-TcVariable -Path "MAIN.nCounter"
Write-TcVariable -Path "MAIN.bEnable" -Value $true
```

## Important Notes

- **AmsNetId is dynamic** — it changes per target. Never hardcode it. `Connect-TcAds` auto-detects from the active IDE connection.
- **All commands return JSON**: `{"success": true, "data": {...}}` or `{"success": false, "error": {"message": "...", "code": "..."}}`
- **No dialogs**: `Enable-TcConfig -Force` uses ADS WriteControl. `Enter-TcPlcOnline` uses `Login(3)` flag.
- **Write MAIN-level vars for FB testing** — PLC overwrites `VAR_INPUT` every scan cycle. Write standalone variables in MAIN that feed into FB calls.
- **Correct lifecycle order**: Build -> Activate -> Login -> ADS Connect -> Start PLC -> Test (ADS port 851 only exists after Login+Download)

## Available Commands (34)

### Connection
- `Connect-TcIde [-SolutionPath <path>]` — Connect to IDE
- `Disconnect-TcIde` — Disconnect from IDE
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
- `Build-TcProject` — Build (auto-retry on RPC busy)
- `Enable-TcConfig [-Force]` — Activate config via ADS
- `Enter-TcPlcOnline` — Login + Download (no dialogs)
- `Exit-TcPlcOnline` — Logout
- `Send-TcPlcProgram` — Upload program

### Runtime
- `Set-TcPlcState -State <Run|Stop|Reset>` — Control PLC
- `Get-TcPlcState` — Read PLC state
- `Set-TcSystemState -State <Run|Config>` — System state
- `Get-TcSystemState` — Read system state
- `Set-TcTarget -AmsNetId <id>` — Set target
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
