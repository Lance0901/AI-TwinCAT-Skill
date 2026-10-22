[繁體中文](README.zh-TW.md) | English

# AI TwinCAT Skill

A PowerShell module that lets **any AI coding tool** (Claude Code, Codex, Antigravity, etc.) fully automate TwinCAT 3 IDE and PLC runtime — from project creation to live testing — with zero dialog popups.

## Why

TwinCAT 3 has a powerful COM-based Automation Interface, but it's notoriously hard to script: modal dialogs block automation, COM type conflicts crash PowerShell, and the lifecycle has undocumented ordering requirements. This module solves all of that, providing 36 cmdlets that any AI tool can call to build, deploy, and test PLC programs autonomously.

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

# 1b. TwinCAT 4026 XAE: the solution platform must equal the target platform (UmRT = Usermode Runtime = 'TwinCAT OS (x64)'),
#     else ACTIVATE_FAILED. Without -Platform it is read from the target (TARGETINFO); a runtime that answers ADS 0x702
#     (e.g. the UmRT of TwinCAT 3.1.4026.21-22) returns PLATFORM_UNKNOWN, so pass it (or Enable-TcConfig -Platform ...)
Set-TcTarget -AmsNetId <data.amsNetId> -Platform 'TwinCAT OS (x64)'

# 2. Build
Build-TcProject

# 3. Activate, one step (Config -> Activate -> wait Run -> Login+Download -> PLC Run, zero dialogs)
#    Already includes Enter-TcPlcOnline and Set-TcPlcState Run; every step polls, no Start-Sleep
Enable-TcConfig -Force

# 4. Connect ADS (AmsNetId auto-detected from IDE)
Connect-TcAds

# 5. Read/Write variables
Read-TcVariable -Path "MAIN.nCounter"
Write-TcVariable -Path "MAIN.bEnable" -Value $true
```

Something failed? See [docs/troubleshooting.md](docs/troubleshooting.md) — error code table (`error.code` / `error.hint`), correct lifecycle order, environment matrix, known limits. Hardware-in-the-loop checks live in [tests/Integration](tests/Integration/README.md).

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

## All Commands (36)

### Connection
| Command | Description |
|---------|-------------|
| `Connect-TcIde` | Connect to TwinCAT IDE (optional `-SolutionPath` for one-step connect) |
| `Disconnect-TcIde` | Disconnect from IDE |
| `Reset-TcSolution` | Dismiss the reload prompt, close all documents (no save), close + reopen the solution on the same IDE (20-25 s) so XAE reloads project files changed on disk; needed only when a changed `.TcPOU` is open in an XAE editor (otherwise XAE picks it up within ~5 s) |
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
| `Build-TcProject` | Build (auto-retry on RPC busy; polls `BuildState`, `-TimeoutSec` default 600 -> `BUILD_TIMEOUT`); `data.errorItems[]` lists the Error List errors (description/file/line) |
| `Get-TcBuildErrors` | Read the XAE Error List (errors, `-IncludeWarnings`, `-IncludeMessages`) via UI Automation |
| `Enable-TcConfig` | Activate configuration via ADS (no dialogs with `-Force`) |
| `Enter-TcPlcOnline` | Login + download program (`-LoginMode Regular|Download|OnlineChange` = 1/4/2; prompts handled by the global `SilentMode`, no `SILENT` flag unless `-SilentFlag`) |
| `Exit-TcPlcOnline` | Logout from PLC |
| `Send-TcPlcProgram` | Upload program to PLC |

### Runtime Control
| Command | Description |
|---------|-------------|
| `Set-TcPlcState` | Start / Stop / Reset PLC |
| `Get-TcPlcState` | Read current PLC state |
| `Set-TcSystemState` | Set TwinCAT system state (Config/Run) |
| `Get-TcSystemState` | Read TwinCAT system state |
| `Set-TcTarget` | Set target system (local/remote); follows the target platform (TARGETINFO) or `-Platform` (UmRT: `'TwinCAT OS (x64)'`); `-NoPlatformSwitch` = NetId only |
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
  Public/                       # 36 exported cmdlets
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
- **No dialogs** -- `Enable-TcConfig -Force` uses ADS WriteControl, `Connect-TcIde` enables the global `ITcAutomationSettings.SilentMode` (XAE answers prompts with the default). `Enter-TcPlcOnline` does **not** OR the `SILENT` login flag by default: measured on an empty runtime, `Login(257)` skips creating the app instead of answering Yes; `-SilentFlag` opts in.
- **Solution platform (TwinCAT 4026)** -- the active solution platform must equal the target platform (UmRT / Usermode Runtime = `TwinCAT OS (x64)`), otherwise `Enable-TcConfig` returns `ACTIVATE_FAILED` (XAE "Check config failed!", nothing written to the target). XAE chooses the platform when it loads the solution. `Set-TcTarget` and `Enable-TcConfig` read the target platform through TARGETINFO (ADS port 200, IG 0x700, [InfoSys](https://infosys.beckhoff.com/content/1033/tc170x_tc3_usermode_runtime/11687997963.html)) and switch automatically (`Enable-TcConfig` also rebuilds); the runtime of TwinCAT 3.1.4026.21-22 answers ADS 0x702 there, so pass `-Platform 'TwinCAT OS (x64)'` (`Set-TcTarget` returns `PLATFORM_UNKNOWN` without it, `Enable-TcConfig` warns and activates as before; `-NoPlatformFix` turns a mismatch into `PLATFORM_MISMATCH`). MCP: `SetTarget` / `EnableConfig` / `RunLifecycle` `Platform`. See `docs/troubleshooting.md`.
- **Write to MAIN-level vars** when testing FBs -- PLC overwrites `VAR_INPUT` every scan cycle (see Decision #17).

## Claude Code Setup

One command to install the TwinCAT skill globally for Claude Code (works in any project after install):

```powershell
pwsh ./TwinCATSetup-Claude.ps1
```

This checks prerequisites and installs the skill + PowerShell module to `~/.claude/skills/twincat-automation/`.

To uninstall: `pwsh ./TwinCATSetup-Claude.ps1 -Uninstall`

## Codex Setup

One command to install the TwinCAT skill globally for Codex (works in any project after install):

```powershell
pwsh ./TwinCATSetup-Codex.ps1
```

This checks prerequisites (Windows, TwinCAT, ADS DLL, IDE, module) and installs:
- `~/.agents/skills/twincat/TwinCATAutomation/` -- PowerShell module (all cmdlets)
- `~/.agents/skills/twincat/SKILL.md` -- Codex skill with full API reference
- `~/.codex/AGENTS.md` -- global project instructions

To uninstall: `pwsh ./TwinCATSetup-Codex.ps1 -Uninstall`

## Antigravity Setup

One command to install the TwinCAT skill globally for Google Antigravity:

```powershell
pwsh ./TwinCATSetup-Antigravity.ps1
```

This checks prerequisites and installs the skill + PowerShell module to `~/.gemini/antigravity/skills/twincat-automation/`.

To uninstall: `pwsh ./TwinCATSetup-Antigravity.ps1 -Uninstall`

## MCP Server Setup (Claude Desktop / any MCP client)

The same module is also available as the TcAuto MCP server (stdio) exposing all 36 cmdlets plus 4 composite tools (`RunLifecycle`, `QuickRead`, `GetStatus`, `GetIdeModalDialog`). One long-lived Windows PowerShell 5.1 process keeps the IDE/ADS connection state across tool calls.

```powershell
cd mcp-server
npm install
npm test          # no TwinCAT needed
```

Claude Code picks it up from the repo's `.mcp.json`; for Claude Desktop see [docs/setup-mcp.md](docs/setup-mcp.md) and [mcp-server/README.md](mcp-server/README.md).

## Development

Run `powershell -File scripts/install-hooks.ps1` once per clone: the pre-commit hook then runs `scripts/check.ps1 -Fast` (PS 5.1 parse and file encoding, cmdlet count vs docs, banned wording, error codes documented, `tools.json` in sync; it reads the working tree, not the index); run `scripts/check.ps1` (adds `npm test`) before a PR, CI runs it with `-Strict` (SKIP fails) on `windows-latest`. Review rules: [CODING_STANDARDS.md](CODING_STANDARDS.md).

## Changelog

### 2026-04-02

- **Fix setup scripts**: All three installers (Claude, Codex, Antigravity) now copy the full `TwinCATAutomation` PowerShell module alongside SKILL.md. Previously only the skill documentation was installed, so AI tools couldn't find the actual module when running from other projects.
- **Multi-instance IDE detection**: `Connect-TcIde` now enumerates ALL running VS2022/XAE Shell instances via the Running Object Table (ROT) instead of using `GetActiveObject` which only returns one per ProgID. When multiple IDEs are open, it correctly finds the one with the target solution instead of launching a new instance.
- **Fix TcAdsHelper loading**: Rewrote `Initialize-TcAdsHelper` with 3 fallback strategies (explicit path → loaded assembly → common paths) to reliably compile the C# helper. Added lazy-loading guards in `Get-TcSymbols`, `Read-TcVariable`, `Write-TcVariable`. `Connect-TcAds` now warns if helper fails to compile.

### 2026-03-29

- **Codex desktop integration**: `TwinCATSetup-Codex.ps1` installer -- checks prerequisites and installs skill + AGENTS.md to user-level (`~/.agents/skills/`, `~/.codex/`) so Codex can use TwinCAT automation in any project
- **AGENTS.md**: project instructions for Codex (auto-discovered at repo and user level)
- **.agents/skills/twincat/SKILL.md**: full 36-command API reference as Codex skill
- **Fix Test 2 root cause**: ADS writes to FB `VAR_INPUT` are overwritten by PLC each scan cycle. Must write MAIN-level standalone variables instead (Decision #17)
- **Fix full automated test cycle**: Correct lifecycle order is Build -> Activate -> Login -> ADS -> Start -> Test (ADS connection must come after Login+Download)
- **Fix `Enter-TcPlcOnline`**: Use `LookupTreeItem` with constructed path instead of child enumeration (Project child hidden after TwinCAT restart)
- **Fix `Build-TcProject`**: Add retry loop (5 attempts) for `RPC_E_CALL_REJECTED` when IDE is busy
- **Fix `Invoke-TcTestCycle`**: Cache AmsNetId before Activate; don't reconnect IDE after restart (original COM reference survives XAR restart)

### 2026-03-28

- **Smart IDE connection**: `Connect-TcIde -SolutionPath` for one-step connect -- finds or launches IDE, opens solution, returns AmsNetId
- **Fix `Write-TcVariable`**: C# helper (`TcAdsHelper`) bypasses PowerShell CLS compliance issue with `TcAdsSymbol.Datatype` vs `DataType`

### 2026-03-27

- **Dialog-free lifecycle**: `Enable-TcConfig -Force` (ADS-based), `Enter-TcPlcOnline -LoginMode` (prompts handled by global `SilentMode`; 2026-10-19: the `SILENT` login flag was dropped from the default because `Login(257)` skips app creation) -- full Build->Activate->Login->Run->Read cycle with zero popups
- **Cross-tool adapters**: Claude Code SKILL.md, Codex tools.json, Antigravity plugin.yaml
- **CLAUDE.md**: Project guide for AI tools

### 2026-03-26

- **Initial release**: 34 PowerShell cmdlets covering IDE automation, project management, code R/W, build/deploy, ADS communication, runtime control, I/O config, and automated testing
- **OpenSpec-based development**: Full design documentation with architectural decisions

## License

MIT
