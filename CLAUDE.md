# TwinCAT Automation — AI Tool Guide

PowerShell module for automating the TwinCAT 3 IDE and PLC runtime, for **any AI coding tool** (Claude Code, Codex, Antigravity, ...). `Import-Module "./src/TwinCATAutomation/TwinCATAutomation.psm1" -Force`, or run it as the TcAuto MCP server (tool names = CLI action names, e.g. `ConnectIde`, `BuildProject`, `EnableConfig`, `ReadVariable`), registered once through the installed launcher (customer: `Install-TcAuto.ps1` of the release zip; developer: `scripts/Install-TcAutoRuntime.ps1`; upgrade with `ReloadRuntime`; never register `mcp-server/index.js` or a project `.mcp.json`): see `docs/setup-mcp.md`. `TwinCATSetup-*.ps1` are the older skill installers and do not register the MCP server.

## Core Workflow (No Dialogs)

```powershell
Connect-TcIde                     # 1. connect to the IDE (without -SolutionPath the selected IDE is attached only if TcAuto launched it or it is bound with -ProcessId until Disconnect-TcIde, else IDE_ATTACH_CONSENT_REQUIRED: ask the user, then -ProcessId; launching with several IDEs installed: pass -ProgId or a -SolutionPath with a .tsproj TcVersion equal to an installed XAE version, else PROGID_REQUIRED)
# 1b. target + solution platform: read from the target (TARGETINFO, ADS port 200 IG 0x700) and switched to it.
#     A target that cannot report it (ADS 0x702, TcSystemServiceUm 3.1.0.2649) -> PLATFORM_UNKNOWN without -Platform
#     (UmRT / TwinCAT/BSD = 'TwinCAT OS (x64)'); -NoPlatformSwitch only sets the NetId.
Set-TcTarget -AmsNetId <data.amsNetId> -Platform 'TwinCAT OS (x64)'
# 2. build: BUILD_FAILED -> data.errorItems (description/file/line from the XAE Error List);
#    -TimeoutSec default 600 -> BUILD_TIMEOUT; a modal dialog during the build -> IDE_MODAL_DIALOG
Build-TcProject
# 3. one step: Config → Activate → wait Run → Login+Download → wait port 851 → PLC Run (no Start-Sleep needed).
#    -NoLogin skips download/Run; -TimeoutSec default 120; data has steps[], plcState, loggedIn, reconnected
Enable-TcConfig -Force
Connect-TcAds                     # 4. AmsNetId auto-detected from the IDE target
Read-TcVariable -Path "MAIN.nCounter"   # 5. auto-reconnects after a later Enable-TcConfig (data.reconnected)
```

## Important Notes

- **AmsNetId is dynamic** — it changes per target (local UM Runtime, remote CX, etc.). Never hardcode it. `Connect-TcAds` auto-detects from the active IDE connection.
- **All commands return JSON**: `{"success": true, "data": {...}}` or `{"success": false, "error": {"message": "...", "code": "...", "hint": "..."}}`. `error.hint` is optional; when present it is the suggested next action.
- **No dialogs**: `Enable-TcConfig -Force` uses ADS WriteControl (not StartRestartTwinCAT); `Connect-TcIde` enables `ITcAutomationSettings.SilentMode` (XAE answers prompts with the default). Login flags (`-LoginMode Regular|Download|OnlineChange`, no `SILENT` by default, never 3): see `docs/troubleshooting.md` "LOGIN_FAILED". DTE/COM calls retry on RPC busy (`IDE_BUSY`); a dead IDE gives `IDE_CRASHED`.
- **Editing project files on disk** (`.TcPOU` open in an editor, rewritten `.plcproj`): write → `Invoke-TcLintProject` (MCP `LintProject`, offline) → only when it passes `Reset-TcSolution` → `Build-TcProject`; `requiresDisposition: true` = fix each `data.unresolved[]` entry or suppress it with a reason, list every `data.newSuppressions[]` and `data.newOverrides[]` (profile weakenings) entry to the user and do not commit them before the user confirmed, no EnableConfig before that (`adapters/claude-code/SKILL.md` "Semantic lint"). Call `Reset-TcSolution` right after the lint passes (it refuses with `UNSAVED_CHANGES` while the IDE itself holds unsaved changes, e.g. after `Set-TcTarget` without a build: ask the user, `-Force` only with their consent, #175); why and how: `docs/troubleshooting.md` "磁碟改檔的正確做法". `Write-TcPouCode` (COM edit buffer) never needs it.
- **Solution platform** (the target decides the platform; a mismatch fails Activate, `ACTIVATE_FAILED`; a solution platform whose .tsproj maps to another project platform -> `PLATFORM_PROJECT_MISMATCH`, nothing switched): `docs/troubleshooting.md` "ACTIVATE_FAILED", "PLATFORM_PROJECT_MISMATCH", "Target platform(TARGETINFO)", "環境矩陣".
- **VS2022**: `Build($true)` never returns (module polls `BuildState`); WPF message boxes; zh-TW Error List: `docs/troubleshooting.md` "已知 modal dialog", "BUILD_TIMEOUT", "ERRORLIST_UNAVAILABLE".
- **No blind waits**: `Set-TcSystemState`, `Enable-TcConfig -Force` and `Invoke-TcTestCycle` poll until the target state is reached. Do not add `Start-Sleep`.
- **No false success (#28 / #32)**: run the whole lifecycle in ONE persistent PowerShell session (or the MCP server). Build coverage (`PROJECT_SKIPPED_BY_CONFIGURATION`, `-ExpectedProject`), state readback (`SYSTEM_STATE_MISMATCH`, `RUNTIME_STATE_MISMATCH`, `BOOT_PACKAGE_MISMATCH`) and multi-PLC `-PlcProjectPath` (`PLC_PROJECT_AMBIGUOUS`): `docs/troubleshooting.md` "Lifecycle 正確順序" and the error-code sections.
- **Fail closed (#68)**: `success: true` only after the readback reached the target state. On `success: false` or `LIFECYCLE_BLOCKED`: stop, report `data.lifecycleBlock` / `data.steps` to the user, never fall back to raw ADS WriteControl / COM / DTE / GUI / console or a re-`Connect-TcIde` after Activate; `Clear-TcLifecycleBlock -Reason` only after the user agreed. Stop conditions, postcondition table, forbidden fallbacks: `adapters/claude-code/SKILL.md` "Failure contract"; `docs/troubleshooting.md` "LIFECYCLE_BLOCKED".
- **Troubleshooting**: `docs/troubleshooting.md` — error code table, correct lifecycle order, environment matrix, known limits (intermittent UmRT crash during Config/Activate #21, compiler codes only inferred from Error List text; the older reports "UmRT fake Run" and "Reset kills `TcSystemServiceUm`" did not reproduce on 2026-11-08, #26).
- **TwinCAT facts**: check infosys.beckhoff.com first and cite the link (or mark the claim 實測 with date and environment).
- **Reviews** follow `CODING_STANDARDS.md`; mechanical checks: `scripts/check.ps1` (pre-commit runs `-Fast`, install with `scripts/install-hooks.ps1`); counts of cmdlets / tools / composites and the SKILL.md signature table sit between HTML comment markers named `generated:KEY` - never edit them by hand, run `scripts/Update-GeneratedDocs.ps1` (check.ps1 fails when stale, #25)
- **Real-machine test agents**: shared rules in `docs/agent-brief-realmachine.md`.

## Tool-Specific Adapters

Claude Code `adapters/claude-code/SKILL.md` · Codex `adapters/codex/tools.json` · Antigravity `adapters/antigravity/plugin.yaml` · MCP (Claude Desktop / any client) `mcp-server/README.md`

## Available Commands (<!-- generated:cmdlet-count -->86<!-- /generated -->)

Full list with parameters: `adapters/claude-code/SKILL.md`, or `Get-Command -Module TwinCATAutomation` after importing the module.
