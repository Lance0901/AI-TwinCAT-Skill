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

### Build & Deploy
- `Build-TcProject` — Build PLC project
- `Set-TcTarget -AmsNetId <id>` — Set target system
- `Enable-TcConfig [-Force]` — Activate configuration
- `Send-TcPlcProgram` — Download to PLC

### ADS Communication
- `Connect-TcAds [-AmsNetId <id>] [-Port <port>]` — Connect ADS
- `Read-TcVariable -Path <var-path>` — Read PLC variable
- `Write-TcVariable -Path <var-path> -Value <value>` — Write PLC variable
- `Watch-TcVariable -Path <var-path> -IntervalMs <ms>` — Monitor variable
- `Get-TcSymbols [-Filter <pattern>]` — List PLC symbols

### Runtime Control
- `Get-TcPlcState` / `Set-TcPlcState -State <Run|Stop|Reset>` — PLC state
- `Enter-TcPlcOnline` / `Exit-TcPlcOnline` — PLC login/logout
- `Get-TcSystemState` / `Set-TcSystemState -State <Run|Config>` — System state

### Testing
- `New-TcTestCase -Name <name> -Assertions @(...)` — Define test
- `Invoke-TcTest -TestCase <test>` — Run single test
- `Invoke-TcTestCycle -TestCases @(...)` — Full Build-Test cycle

## Output Format

All commands return JSON: `{"success": true, "data": {...}}` or `{"success": false, "error": {"message": "...", "code": "..."}}`

## Workflow Example

```powershell
Connect-TcIde
New-TcProject -Name "Demo"
Add-TcPou -Name "FB_Test" -Type FunctionBlock
Write-TcPouCode -PouName "FB_Test" -Declaration "..." -Implementation "..."
Build-TcProject
Enable-TcConfig -Force
Connect-TcAds
Enter-TcPlcOnline
Set-TcPlcState -State Run
Read-TcVariable -Path "MAIN.fbTest.nOutput"
```

For detailed parameter documentation, see `docs/operations.md`.
