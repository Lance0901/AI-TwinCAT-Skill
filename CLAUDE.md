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
- **No dialogs**: `Enable-TcConfig -Force` uses ADS WriteControl (not StartRestartTwinCAT). `Connect-TcIde` enables `ITcAutomationSettings.SilentMode` so XAE answers its own prompts with the default (Yes); `Enter-TcPlcOnline` calls `ITcPlcIECProject::Login(PLC_LOGIN_FLAGS)` with `-LoginMode Regular|Download|OnlineChange` = 1|4|2 and **no** `SILENT(256)` by default (`-SilentFlag` adds it; never 3). The `SILENT` flag means "skip anything that would prompt", not "answer with the default": `Login(257)` on an empty runtime returns in 0.5 s without creating the app, and `Login(260)` was never needed (the "Activate blocked 250 s" seen after it was an unrelated 32-bit XAE OutOfMemory crash, see `IDE_CRASHED`). All DTE/COM calls retry 1/2/4/8/16s on RPC busy and return `IDE_BUSY` when exhausted; when the IDE process dies mid-call they return `IDE_CRASHED`.
- **Editing project files on disk** (not through `Write-TcPouCode`, which writes the IDE edit buffer through COM and never prompts; the file on disk is only written on save / Build): a `.TcPOU` that is NOT open in an XAE editor is reloaded by XAE within ~5 s; one that IS open triggers the modal "File has been changed outside the environment. Reload the new file?" and blocks every DTE call. Call `Reset-TcSolution` right after the write: it dismisses that prompt, closes all documents, Solution.Close + Solution.Open on the same IDE and reconnects (20-25 s measured). `Get-TcIdeModalDialog` reports the prompt as `Kind = reload-prompt` (`data.dialogKind`). A rewritten `.plcproj` triggers XAE's own project prompt ("The project file ... has been modified outside of TwinCAT XAE. Do you want to reload the project?", same Kind, `ReloadTarget = project`); `Reset-TcSolution` answers Yes to it by dialog control id (works on any UI language), XAE reloads the project and only the reconnect runs (no close/reopen).
- **No blind waits**: `Set-TcSystemState`, `Enable-TcConfig -Force` and `Invoke-TcTestCycle` poll until the target state is reached. Do not add `Start-Sleep`.
- **Troubleshooting**: `docs/troubleshooting.md` — error code table, correct lifecycle order, environment matrix, known limits (UmRT fake Run, Reset kills `TcSystemServiceUm`, compiler codes only inferred from Error List text).

## Tool-Specific Adapters

| Tool | Config File |
|------|-------------|
| Claude Code | `adapters/claude-code/SKILL.md` |
| Codex | `adapters/codex/tools.json` |
| Antigravity | `adapters/antigravity/plugin.yaml` |
| MCP (Claude Desktop / any client) | `mcp-server/README.md` |

## Available Commands (36)

See `adapters/claude-code/SKILL.md` for the full list with parameters, or run:
```powershell
Import-Module "./src/TwinCATAutomation/TwinCATAutomation.psm1" -Force
Get-Command -Module TwinCATAutomation
```
