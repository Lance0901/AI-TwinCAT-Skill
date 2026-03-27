---
name: TwinCAT Automation
description: Control TwinCAT 3 IDE, manage PLC projects, read/write runtime variables via ADS, and run automated tests.
---

# TwinCAT Automation Skill

You can control TwinCAT 3 IDE and PLC runtime using the TwinCATAutomation PowerShell module.

## Setup

Before any operation, import the module:
```powershell
Import-Module "<project-root>/src/TwinCATAutomation/TwinCATAutomation.psm1" -Force
```

## Available Operations

### IDE Connection
- `Connect-TcIde` — Connect to TwinCAT IDE (XAE Shell or VS2022)
- `Disconnect-TcIde` — Disconnect from IDE
- `Get-TcIdeInfo` — Get IDE version and status

### Project Management
- `New-TcProject -Name <name> [-Path <path>]` — Create new project
- `Open-TcProject -Path <sln-path>` — Open existing project
- `Get-TcProjectTree` — Read project structure as JSON
- `Add-TcPou -Name <name> -Type <Program|FunctionBlock|Function>` — Add POU
- `Add-TcGvl -Name <name> [-Variables @{var=type}]` — Add GVL
- `Add-TcDut -Name <name> -DutType <Struct|Enum|Alias|Union>` — Add DUT
- `Add-TcLibrary -Name <lib-name>` — Add library reference

### PLC Code
- `Write-TcPouCode -PouName <name> -Declaration <text> -Implementation <text>` — Write code
- `Get-TcPouCode -PouName <name>` — Read code

### Build & Deploy (No Dialogs)
- `Build-TcProject` — Build PLC project
- `Set-TcTarget -AmsNetId <id>` — Set target system
- `Enable-TcConfig [-Force]` — Activate configuration. `-Force` does full Config→Activate→Run via ADS (no dialogs)
- `Enter-TcPlcOnline [-PlcProjectPath <path>]` — Login + Download program (uses Login(3), no dialogs)
- `Send-TcPlcProgram` — Alias for Enter-TcPlcOnline

### ADS Communication
- `Connect-TcAds [-AmsNetId <id>] [-Port <port>]` — Connect ADS. **AmsNetId auto-detected from IDE target if omitted.**
- `Read-TcVariable -Path <var-path>` — Read PLC variable
- `Write-TcVariable -Path <var-path> -Value <value>` — Write PLC variable
- `Watch-TcVariable -Path <var-path> -IntervalMs <ms>` — Monitor variable
- `Get-TcSymbols [-Filter <pattern>]` — List PLC symbols

### Runtime Control
- `Get-TcPlcState` / `Set-TcPlcState -State <Run|Stop|Reset>` — PLC state via ADS
- `Enter-TcPlcOnline` / `Exit-TcPlcOnline` — PLC login/logout
- `Get-TcSystemState` / `Set-TcSystemState -State <Run|Config>` — System state via ADS WriteControl (no dialogs)

### Testing
- `New-TcTestCase -Name <name> -Assertions @(...)` — Define test
- `Invoke-TcTest -TestCase <test>` — Run single test
- `Invoke-TcTestCycle -TestCases @(...)` — Full Build-Test cycle

## Output Format

All commands return JSON: `{"success": true, "data": {...}}` or `{"success": false, "error": {"message": "...", "code": "..."}}`

## Workflow Example (No Dialogs)

```powershell
# Full lifecycle — zero dialog popups
Connect-TcIde
Build-TcProject
Enable-TcConfig -Force          # Config → Activate → Run (ADS WriteControl)
Enter-TcPlcOnline               # Login(3) + Download (suppresses all dialogs)
Set-TcPlcState -State Run       # Start PLC
Connect-TcAds                   # AmsNetId auto-detected from IDE target
Read-TcVariable -Path "MAIN.fbTest.nOutput"
```

## Important

- **AmsNetId is dynamic** — changes per target (local UM Runtime, remote CX, etc.). Never hardcode. Auto-detected from IDE.
- **No dialogs** — `Enable-TcConfig -Force` uses ADS WriteControl. `Enter-TcPlcOnline` uses `Login(3)` flag.
- For detailed parameter documentation, see `docs/operations.md`.
