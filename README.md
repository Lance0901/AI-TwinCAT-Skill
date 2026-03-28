[繁體中文](README.zh-TW.md) | English

# AI TwinCAT Skill

A PowerShell module that lets **any AI coding tool** (Claude Code, Codex, Antigravity, etc.) fully automate TwinCAT 3 IDE and PLC runtime — from project creation to live testing — with zero dialog popups.

## Why

TwinCAT 3 has a powerful COM-based Automation Interface, but it's notoriously hard to script: modal dialogs block automation, COM type conflicts crash PowerShell, and the lifecycle has undocumented ordering requirements. This module solves all of that, providing 34 cmdlets that any AI tool can call to build, deploy, and test PLC programs autonomously.

## Features

| Category | What You Can Do |
|----------|----------------|
| **IDE Automation** | Connect to VS2022 / TwinCAT XAE Shell, smart instance selection with `-SolutionPath` |
| **Project Management** | Create projects, add POUs / GVLs / DUTs / Libraries |
| **PLC Code R/W** | Read and write Structured Text in any POU programmatically |
| **Build & Deploy** | Build, activate config (ADS-based, no dialogs), login + download |
| **Runtime Control** | Start / Stop / Reset PLC, system state management |
| **ADS Communication** | Read / write any PLC variable at runtime, symbol enumeration |
| **Automated Testing** | Define test cases, run full Build-Deploy-Test cycles, get JSON reports |
| **I/O Configuration** | Scan EtherCAT devices, read I/O tree, link variables to channels |

## Quick Start

```powershell
Import-Module ./src/TwinCATAutomation/TwinCATAutomation.psm1 -Force

# 1. Connect to IDE (auto-opens solution if needed)
Connect-TcIde -SolutionPath "C:\Projects\MyProject.sln"

# 2. Build
Build-TcProject

# 3. Activate + Run (Config mode -> Run mode via ADS, zero dialogs)
Enable-TcConfig -Force

# 4. Login + Download program (Login(3) suppresses all dialogs)
Enter-TcPlcOnline

# 5. Connect ADS (AmsNetId auto-detected from IDE)
Connect-TcAds

# 6. Start PLC
Set-TcPlcState -State Run

# 7. Read/Write variables
Read-TcVariable -Path "MAIN.nCounter"
Write-TcVariable -Path "MAIN.bEnable" -Value $true
```

### Automated Testing

```powershell
# Define test cases
$test1 = New-TcTestCase -Name "Initial state" -Assertions @(
    @{ Path = "MAIN.bReady"; Operator = "IsTrue"; Expected = $null }
    @{ Path = "MAIN.nCount"; Operator = "Equal"; Expected = [uint16]0 }
)

$test2 = New-TcTestCase -Name "Trigger and verify" `
    -Setup @( @{ Path = "MAIN.bStart"; Value = $true } ) `
    -WaitMs 2000 `
    -Assertions @(
        @{ Path = "MAIN.bDone"; Operator = "IsTrue"; Expected = $null }
    ) `
    -Teardown @( @{ Path = "MAIN.bStart"; Value = $false } )

# Run full cycle: Build -> Activate -> Login -> Start -> Test -> Stop
Invoke-TcTestCycle -TestCases @($test1, $test2)
```

### Modify PLC Code Programmatically

```powershell
# Read current code
$code = Get-TcPouCode -PouName "MAIN" -PouPath "TIPC^MyPLC^MyPLC Project^POUs^MAIN"

# Modify and write back
$newDecl = $code.data.declaration -replace 'END_VAR', "    nCycleCount : UDINT;`nEND_VAR"
$newImpl = "nCycleCount := nCycleCount + 1;`n" + $code.data.implementation
Write-TcPouCode -PouName "MAIN" -PouPath "TIPC^MyPLC^MyPLC Project^POUs^MAIN" `
    -Declaration $newDecl -Implementation $newImpl
```

## All Commands (34)

### Connection
| Command | Description |
|---------|-------------|
| `Connect-TcIde` | Connect to TwinCAT IDE (optional `-SolutionPath` for one-step connect) |
| `Disconnect-TcIde` | Disconnect from IDE |
| `Connect-TcAds` | Connect ADS client (AmsNetId auto-detected from IDE) |
| `Disconnect-TcAds` | Disconnect ADS client |

### Project Management
| Command | Description |
|---------|-------------|
| `New-TcProject` | Create new TwinCAT project |
| `Open-TcProject` | Open existing solution/project |
| `Add-TcPou` | Add POU (Program / FB / Function) |
| `Add-TcGvl` | Add Global Variable List |
| `Add-TcDut` | Add Data Unit Type (struct/enum/union) |
| `Add-TcLibrary` | Add library reference |

### Code Operations
| Command | Description |
|---------|-------------|
| `Get-TcPouCode` | Read declaration + implementation from a POU |
| `Write-TcPouCode` | Write declaration + implementation to a POU |
| `Get-TcProjectTree` | Get project tree structure |

### Build & Deploy
| Command | Description |
|---------|-------------|
| `Build-TcProject` | Build with error/warning reporting (auto-retry on RPC busy) |
| `Enable-TcConfig` | Activate configuration via ADS (no dialogs with `-Force`) |
| `Enter-TcPlcOnline` | Login + download program (Login(3), no dialogs) |
| `Exit-TcPlcOnline` | Logout from PLC |
| `Send-TcPlcProgram` | Upload program to PLC |

### Runtime Control
| Command | Description |
|---------|-------------|
| `Set-TcPlcState` | Start / Stop / Reset PLC |
| `Get-TcPlcState` | Read current PLC state |
| `Set-TcSystemState` | Set TwinCAT system state (Config/Run) |
| `Get-TcSystemState` | Read TwinCAT system state |
| `Set-TcTarget` | Set target system (local/remote) |
| `Get-TcIdeInfo` | Get IDE version and connection info |

### ADS Variables
| Command | Description |
|---------|-------------|
| `Read-TcVariable` | Read PLC variable by symbol path |
| `Write-TcVariable` | Write PLC variable by symbol path |
| `Watch-TcVariable` | Monitor variable with condition-based waiting |
| `Get-TcSymbols` | Enumerate all PLC symbols (with wildcard filter) |

### I/O
| Command | Description |
|---------|-------------|
| `Invoke-TcIoScan` | Scan for EtherCAT devices |
| `Get-TcIoTree` | Read I/O device tree |
| `Set-TcVariableLink` | Link PLC variable to I/O channel |

### Testing
| Command | Description |
|---------|-------------|
| `New-TcTestCase` | Define a test case (setup / assertions / teardown) |
| `Invoke-TcTest` | Execute a single test case |
| `Invoke-TcTestCycle` | Full cycle: Build -> Deploy -> Test -> Report |

## Architecture

```
src/TwinCATAutomation/          # Core PowerShell module (tool-agnostic)
  TwinCATAutomation.psm1        # Module loader
  Public/                       # 34 exported cmdlets
  Private/                      # Internal helpers (COM, ADS, assertions)
Invoke-TwinCATAutomation.ps1    # Unified CLI entry point (JSON in/out)
adapters/
  claude-code/                  # Claude Code SKILL.md adapter
  codex/                        # OpenAI Codex tools.json
  antigravity/                  # Antigravity plugin.yaml
```

All commands return structured JSON:
```json
{ "success": true, "data": { "path": "MAIN.nCounter", "value": 42, "type": "UDINT" } }
{ "success": false, "error": { "message": "Build failed", "code": "BUILD_FAILED" } }
```

## Prerequisites

- Windows 10/11
- TwinCAT 3 XAE (Build 4024+) or Visual Studio 2022 with TwinCAT integration
- PowerShell 5.1+ or PowerShell 7+
- .NET Framework (for TwinCAT.Ads.dll)

## Important Notes

- **AmsNetId is dynamic** -- never hardcode it. `Connect-TcAds` auto-detects from the active IDE target.
- **No dialogs** -- `Enable-TcConfig -Force` uses ADS WriteControl, `Enter-TcPlcOnline` uses `Login(3)`.
- **Write to MAIN-level vars** when testing FBs -- PLC overwrites `VAR_INPUT` every scan cycle (see Decision #17).

## Codex Setup

One command to install the TwinCAT skill globally for Codex (works in any project after install):

```powershell
pwsh ./TwinCATSetup-Codex.ps1
```

This checks prerequisites (Windows, TwinCAT, ADS DLL, IDE, module) and installs:
- `~/.agents/skills/twincat/SKILL.md` -- Codex skill with full API reference
- `~/.codex/AGENTS.md` -- global project instructions

To uninstall: `pwsh ./TwinCATSetup-Codex.ps1 -Uninstall`

## Changelog

### 2026-03-29

- **Codex desktop integration**: `TwinCATSetup-Codex.ps1` installer -- checks prerequisites and installs skill + AGENTS.md to user-level (`~/.agents/skills/`, `~/.codex/`) so Codex can use TwinCAT automation in any project
- **AGENTS.md**: project instructions for Codex (auto-discovered at repo and user level)
- **.agents/skills/twincat/SKILL.md**: full 34-command API reference as Codex skill
- **Fix Test 2 root cause**: ADS writes to FB `VAR_INPUT` are overwritten by PLC each scan cycle. Must write MAIN-level standalone variables instead (Decision #17)
- **Fix full automated test cycle**: Correct lifecycle order is Build -> Activate -> Login -> ADS -> Start -> Test (ADS connection must come after Login+Download)
- **Fix `Enter-TcPlcOnline`**: Use `LookupTreeItem` with constructed path instead of child enumeration (Project child hidden after TwinCAT restart)
- **Fix `Build-TcProject`**: Add retry loop (5 attempts) for `RPC_E_CALL_REJECTED` when IDE is busy
- **Fix `Invoke-TcTestCycle`**: Cache AmsNetId before Activate; don't reconnect IDE after restart (original COM reference survives XAR restart)

### 2026-03-28

- **Smart IDE connection**: `Connect-TcIde -SolutionPath` for one-step connect -- finds or launches IDE, opens solution, returns AmsNetId
- **Fix `Write-TcVariable`**: C# helper (`TcAdsHelper`) bypasses PowerShell CLS compliance issue with `TcAdsSymbol.Datatype` vs `DataType`

### 2026-03-27

- **Dialog-free lifecycle**: `Enable-TcConfig -Force` (ADS-based), `Enter-TcPlcOnline` with `Login(3)` -- full Build->Activate->Login->Run->Read cycle with zero popups
- **Cross-tool adapters**: Claude Code SKILL.md, Codex tools.json, Antigravity plugin.yaml
- **CLAUDE.md**: Project guide for AI tools

### 2026-03-26

- **Initial release**: 34 PowerShell cmdlets covering IDE automation, project management, code R/W, build/deploy, ADS communication, runtime control, I/O config, and automated testing
- **OpenSpec-based development**: Full design documentation with architectural decisions

## License

MIT
