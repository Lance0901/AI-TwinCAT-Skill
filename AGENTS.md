# TwinCAT Automation — AI Tool Guide

PowerShell module for automating the TwinCAT 3 IDE and PLC runtime, for **Codex**, Claude Code and any AI coding tool. `Import-Module "./src/TwinCATAutomation/TwinCATAutomation.psm1" -Force` (setup check: `powershell -File ./TwinCATSetup-Codex.ps1`), or run it as the TcAuto MCP server: see `docs/setup-mcp.md`.

## Core Workflow (No Dialogs)

```powershell
Connect-TcIde -SolutionPath "C:\Projects\MyProject.sln"   # 1. connect (opens the solution)
# 1b. The target decides the platform: solution platform must equal it (UmRT = 'TwinCAT OS (x64)'), else ACTIVATE_FAILED;
#     a solution platform whose .tsproj maps to another project platform -> PLATFORM_PROJECT_MISMATCH (nothing switched).
#     Without -Platform it is read from the target (TARGETINFO); ADS 0x702 -> PLATFORM_UNKNOWN. -NoPlatformSwitch = NetId only.
Set-TcTarget -AmsNetId <data.amsNetId> -Platform 'TwinCAT OS (x64)'
Build-TcProject                   # 2. BUILD_FAILED -> data.errorItems (description/file/line)
Enable-TcConfig -Force            # 3. Config -> Activate -> Run -> Login+Download -> port 851 -> PLC Run (no Start-Sleep)
Connect-TcAds                     # 4. AmsNetId auto-detected from the IDE target
Read-TcVariable -Path "MAIN.nCounter"; Write-TcVariable -Path "MAIN.bEnable" -Value $true   # 5.
```

## Important Notes

- **AmsNetId is dynamic** — it changes per target. Never hardcode it. `Connect-TcAds` auto-detects from the active IDE connection.
- **All commands return JSON**: `{"success": true, "data": {...}}` or `{"success": false, "error": {"message": "...", "code": "...", "hint": "..."}}`; `error.hint`, when present, is the suggested next action.
- **No dialogs**: `Enable-TcConfig -Force` uses ADS WriteControl; `Connect-TcIde` enables the global `SilentMode`. Login flags (`-LoginMode Regular|Download|OnlineChange`, no `SILENT` by default, never 3): `docs/troubleshooting.md` "LOGIN_FAILED".
- **Editing project files on disk** (`.TcPOU` open in an editor, rewritten `.plcproj`): call `Reset-TcSolution` right after the write; see `docs/troubleshooting.md` "磁碟改檔的正確做法". `Write-TcPouCode` never needs it.
- **Write MAIN-level vars for FB testing** — the PLC overwrites `VAR_INPUT` every scan cycle.
- **Lifecycle order, platform, VS2022, false success**: `docs/troubleshooting.md` ("Lifecycle 正確順序", "環境矩陣", "ACTIVATE_FAILED", error-code sections). Run the whole lifecycle in ONE persistent PowerShell session.
- **TwinCAT facts**: check infosys.beckhoff.com first and cite the link (or mark the claim 實測 with date and environment).
- **Reviews** follow `CODING_STANDARDS.md`; mechanical checks: `scripts/check.ps1` (pre-commit runs `-Fast`, install with `scripts/install-hooks.ps1`).
- **Real-machine test agents**: shared rules in `docs/agent-brief-realmachine.md`.

## Available Commands (45)

Full list with parameters: `.agents/skills/twincat/SKILL.md` (Codex skill), `adapters/claude-code/SKILL.md`, `adapters/codex/tools.json`, or `Get-Command -Module TwinCATAutomation` after importing the module.
