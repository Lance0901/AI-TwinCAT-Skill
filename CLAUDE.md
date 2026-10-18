# TwinCAT Automation — AI Tool Guide

This project provides a PowerShell module for automating TwinCAT 3 IDE and PLC runtime. It is designed to work with **any AI coding tool** (Claude Code, Codex, Antigravity, etc.).

## Quick Start

```powershell
Import-Module "./src/TwinCATAutomation/TwinCATAutomation.psm1" -Force
```

Or run it as the TcAuto MCP server (tool names = CLI action names, e.g. `ConnectIde`, `BuildProject`, `EnableConfig`, `ReadVariable`): see `docs/setup-mcp.md`.

## Core Workflow (No Dialogs)

The full PLC lifecycle runs without any dialog popups:

```powershell
# 1. Connect to IDE
Connect-TcIde

# 2. Build (on BUILD_FAILED see data.errorItems: description/file/line read from the XAE Error List)
Build-TcProject

# 3. Activate, one step: Config → Activate → wait Run → Login+Download → wait port 851 → PLC Run
#    Already includes Enter-TcPlcOnline and Set-TcPlcState Run. No Start-Sleep needed.
#    (-NoLogin skips download/Run; -TimeoutSec default 120; data has steps[], plcState, loggedIn, reconnected)
Enable-TcConfig -Force

# 4. Connect ADS (AmsNetId auto-detected from IDE target)
Connect-TcAds

# 5. Read/Write variables (auto-reconnect after a later Enable-TcConfig; data.reconnected tells you)
Read-TcVariable -Path "MAIN.nCounter"
```

## Important Notes

- **AmsNetId is dynamic** — it changes per target (local UM Runtime, remote CX, etc.). Never hardcode it. `Connect-TcAds` auto-detects from the active IDE connection.
- **All commands return JSON**: `{"success": true, "data": {...}}` or `{"success": false, "error": {"message": "...", "code": "...", "hint": "..."}}`. `error.hint` is optional; when present it is the suggested next action.
- **No dialogs**: `Enable-TcConfig -Force` uses ADS WriteControl (not StartRestartTwinCAT). `Enter-TcPlcOnline` uses `Login(3)` flag. All DTE/COM calls retry 1/2/4/8/16s on RPC busy and return `IDE_BUSY` when exhausted.
- **No blind waits**: `Set-TcSystemState`, `Enable-TcConfig -Force` and `Invoke-TcTestCycle` poll until the target state is reached. Do not add `Start-Sleep`.
- **Troubleshooting**: `docs/troubleshooting.md` — error code table, correct lifecycle order, environment matrix, known limits (UmRT fake Run, Reset kills `TcSystemServiceUm`, compiler codes only inferred from Error List text).

## Tool-Specific Adapters

| Tool | Config File |
|------|-------------|
| Claude Code | `adapters/claude-code/SKILL.md` |
| Codex | `adapters/codex/tools.json` |
| Antigravity | `adapters/antigravity/plugin.yaml` |
| MCP (Claude Desktop / any client) | `mcp-server/README.md` |

## Available Commands (35)

See `adapters/claude-code/SKILL.md` for the full list with parameters, or run:
```powershell
Import-Module "./src/TwinCATAutomation/TwinCATAutomation.psm1" -Force
Get-Command -Module TwinCATAutomation
```
