# TwinCAT Automation — AI Tool Guide

This project provides a PowerShell module for automating TwinCAT 3 IDE and PLC runtime. It is designed to work with **any AI coding tool** (Claude Code, Codex, Antigravity, etc.).

## Quick Start

```powershell
Import-Module "./src/TwinCATAutomation/TwinCATAutomation.psm1" -Force
```

## Core Workflow (No Dialogs)

The full PLC lifecycle runs without any dialog popups:

```powershell
# 1. Connect to IDE
Connect-TcIde

# 2. Build
Build-TcProject

# 3. Activate + Start (Config → Activate → Run, all via ADS — zero dialogs)
Enable-TcConfig -Force

# 4. Login + Download program (Login(3) suppresses all dialogs)
Enter-TcPlcOnline

# 5. Start PLC
Set-TcPlcState -State Run

# 6. Connect ADS (AmsNetId auto-detected from IDE target)
Connect-TcAds

# 7. Read/Write variables
Read-TcVariable -Path "MAIN.nCounter"
```

## Important Notes

- **AmsNetId is dynamic** — it changes per target (local UM Runtime, remote CX, etc.). Never hardcode it. `Connect-TcAds` auto-detects from the active IDE connection.
- **All commands return JSON**: `{"success": true, "data": {...}}` or `{"success": false, "error": {"message": "...", "code": "..."}}`
- **No dialogs**: `Enable-TcConfig -Force` uses ADS WriteControl (not StartRestartTwinCAT). `Enter-TcPlcOnline` uses `Login(3)` flag.

## Tool-Specific Adapters

| Tool | Config File |
|------|-------------|
| Claude Code | `adapters/claude-code/SKILL.md` |
| Codex | `adapters/codex/tools.json` |
| Antigravity | `adapters/antigravity/plugin.yaml` |

## Available Commands (34)

See `adapters/claude-code/SKILL.md` for the full list with parameters, or run:
```powershell
Import-Module "./src/TwinCATAutomation/TwinCATAutomation.psm1" -Force
Get-Command -Module TwinCATAutomation
```
