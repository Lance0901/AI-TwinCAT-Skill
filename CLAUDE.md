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

# 1b. Target + solution platform. The platform is read from the target (ADS port 200 IG 0x700 TARGETINFO) and the
#     solution platform is switched to it. If the target cannot report it (ADS 0x702 on TcSystemServiceUm 3.1.0.2649),
#     Set-TcTarget without -Platform returns PLATFORM_UNKNOWN: pass it explicitly (UmRT / TwinCAT/BSD = 'TwinCAT OS (x64)').
#     -NoPlatformSwitch only sets the NetId.
Set-TcTarget -AmsNetId <data.amsNetId> -Platform 'TwinCAT OS (x64)'

# 2. Build (on BUILD_FAILED see data.errorItems: description/file/line read from the XAE Error List;
#    -TimeoutSec default 600 -> BUILD_TIMEOUT; a modal dialog during the build -> IDE_MODAL_DIALOG)
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
- **Editing project files on disk** (not through `Write-TcPouCode`, which writes the IDE edit buffer through COM and never prompts; the file on disk is only written on save / Build): a `.TcPOU` that is NOT open in an XAE editor is reloaded by XAE within ~5 s; one that IS open triggers the modal "File has been changed outside the environment. Reload the new file?" and blocks every DTE call. Call `Reset-TcSolution` right after the write: it dismisses that prompt, closes all documents, Solution.Close + Solution.Open on the same IDE and reconnects (20-25 s measured). `Get-TcIdeModalDialog` reports the prompt as `Kind = reload-prompt` (`data.dialogKind`). A rewritten `.plcproj` triggers XAE's own project prompt ("The project file ... has been modified outside of TwinCAT XAE. Do you want to reload the project?", same Kind, `ReloadTarget = project`); `Reset-TcSolution` answers Yes to it (Win32 box: dialog control id; VS2022 WPF box: UI Automation Invoke on `YesButton`; works on any UI language), XAE reloads the project and only the reconnect runs (no close/reopen).
- **Solution platform**: TwinCAT 4026 XAE refuses to activate when the active solution platform differs from the target platform (a UmRT is `TwinCAT OS (x64)`). XAE picks the solution platform when it loads the solution (from the target stored in the .tsproj) and SetTargetNetId does not change it. The module reads the target platform from ADS port 200 IG 0x700 IO 4 (TARGETINFO, [InfoSys "Runtime type (ADS)"](https://infosys.beckhoff.com/content/1033/tc170x_tc3_usermode_runtime/11687997963.html)); this PC's runtime answers 0x702 (not implemented). `Set-TcTarget`: `-Platform` wins; else target platform → automatic switch; else `PLATFORM_UNKNOWN` (NetId still set, `-NoPlatformSwitch` skips the check). `Enable-TcConfig [-Platform <name>] [-NoPlatformFix]`: before Activate compares the solution platform with the target platform (else `-Platform`) and switches + rebuilds (steps `platform-fix`, `platform-fix-build`), or returns `PLATFORM_MISMATCH` with `-NoPlatformFix`; with neither available `data.platformCheck='skipped'` + warning. With the wrong platform XAE's `ActivateConfiguration()` returns in ~2 s without exception, Output says only "Check config failed!", nothing is written to the target: `Enable-TcConfig` still detects it via `SolutionBuild.LastBuildInfo > 0` → `ACTIVATE_FAILED`. A 4024 .sln (project platform `TwinCAT OS (ARMT2)`) has no real `TwinCAT OS (x64)` project platform: Build "succeeds", 851 stays Invalid; add the platform in Configuration Manager.
- **VS2022**: `SolutionBuild.Build($true)` never returns, so `Build-TcProject` / the smoke scripts use `Build($false)` / `Clean($false)` and poll `BuildState`. VS2022 message boxes are WPF (`Microsoft.VisualStudio.MessageBox`, text in AutomationId `Text`, buttons `OKButton` etc.): `Get-TcIdeModalDialog` returns text and buttons, `Close-TcMessageBox` falls back to UI Automation Invoke. The Error List reader works on zh-TW VS2022 (`錯誤清單`, scope switched to Entire Solution).
- **No blind waits**: `Set-TcSystemState`, `Enable-TcConfig -Force` and `Invoke-TcTestCycle` poll until the target state is reached. Do not add `Start-Sleep`.
- **No false success (#28 / #32)**: run the whole lifecycle in ONE persistent PowerShell session (or the MCP server); a fresh `powershell.exe` per step releases COM and closes the XAE it launched. `Build-TcProject` returns `data.projects[]` (`built|skipped|failed|unknown` per .plcproj, from DTE `SolutionContext.ShouldBuild`), `skippedProjects`, `coverageComplete`; a PLC project missing from the active solution configuration's Build list gives `data.warningCode = PROJECT_SKIPPED_BY_CONFIGURATION`, with `-ExpectedProject <name>` it is a failure. `Set-TcSystemState` sends Reset(2) for Run / Reconfig(16) for Config (`data.sentAdsState`; Run(5) is refused on port 10000 with 0x701) and must read the state back stable for `-SettleSec` (else `SYSTEM_STATE_MISMATCH`). `Enable-TcConfig -Force` logs in / starts every PLC project on its own port (`data.plcs`), compares the project `_Boot` package with a local target's Boot folder (`BOOT_PACKAGE_MISMATCH`) and ends with a readback of port 10000 + every PLC port (`RUNTIME_STATE_MISMATCH`, `data.finalCheck`, `data.diagnostics`). `Enter-/Exit-TcPlcOnline` need `-PlcProjectPath` in a multi-PLC solution (`PLC_PROJECT_AMBIGUOUS`).
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
