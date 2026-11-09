[繁體中文](README.zh-TW.md) | English

# AI TwinCAT Skill

Lets an AI coding tool (Claude Code, Codex, Claude Desktop, or any MCP client) drive the TwinCAT 3 IDE and PLC runtime on a Windows PC: open a solution, edit PLC code, build, activate, download, run and read or write variables over ADS, without dialog popups. It is a PowerShell module providing <!-- generated:cmdlet-count -->82<!-- /generated --> cmdlets, installed as the **TcAuto MCP server**; it can also be imported and called directly.

Status: beta. Known limits are listed in [Known limitations](#known-limitations) and in [docs/known-limitations.md](docs/known-limitations.md).

Contents: [Requirements](#requirements) · [Install (customer)](#install-customer) · [First use](#first-use) · [Supported clients](#supported-clients-and-verification-status) · [Upgrade and remove](#upgrade-and-remove) · [Troubleshooting](#troubleshooting) · [What is new in v0.6.0-beta](#what-is-new-in-v060-beta) · [Known limitations](#known-limitations) · [Developer install](#developer-install-checkout) · [Using the PowerShell module directly](#using-the-powershell-module-directly) · [Documentation index](#documentation-index) · [Legacy skill installers](#legacy-skill-installers-without-mcp)

## Requirements

- Windows 10 or 11 and Windows PowerShell 5.1 (included with Windows). The MCP server runs the module in `powershell.exe` 5.1.
- TwinCAT 3.1 XAE, build 4024 or 4026: the standalone XAE Shell or Visual Studio 2022 with TwinCAT integration. The installer warns when it finds no TwinCAT installation and installs anyway; `ConnectIde` needs it.
- A target to run on: the local user-mode runtime (UmRT), a local Windows runtime, or a remote controller reachable by ADS.
- An AI client that speaks MCP over stdio: Claude Code, Claude Desktop, Codex, or another ([status table](#supported-clients-and-verification-status)).
- Nothing else on a customer PC. The release zip brings its own Node.js; Node.js, npm and git are needed only for the [developer install](#developer-install-checkout).

## Install (customer)

The install package is the release zip `TcAuto-<version>.zip` with `TcAuto-<version>.zip.sha256` on the [GitHub Releases](https://github.com/Lance0901/AI-TwinCAT-Skill/releases) page. `.github/workflows/release.yml` builds and attaches both when a `v*` tag is pushed. **v0.6.0-beta is the first release that has the zip; v0.5.0-beta and earlier releases have no install package.** If the Releases page lists no zip yet, use the [developer install](#developer-install-checkout) instead.

The zip contains the official Node.js 24.22.2 `node.exe` (win-x64, SHA256 pinned in `scripts/Build-TcAutoRelease.ps1`), the launcher, `Install-TcAuto.ps1` and the runtime already built (with `node_modules`, about 40 MB), so the PC needs no Node.js, git or npm.

Do steps 1 to 4 in the same PowerShell window, because the `$zip` variable is reused.

1. Download `TcAuto-<version>.zip` and `TcAuto-<version>.zip.sha256`, then check the hash. In a normal PowerShell window (replace `0.6.0-beta` with the version you downloaded):

   ```powershell
   cd "$HOME\Downloads"
   $zip = '.\TcAuto-0.6.0-beta.zip'
   (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()   # must equal the first word of the next line
   Get-Content "$zip.sha256"
   ```

2. Unblock and extract the zip to a local folder (not a cloud-synced one such as OneDrive):

   ```powershell
   Unblock-File $zip
   Expand-Archive $zip -DestinationPath "$HOME\TcAuto-0.6.0-beta"
   ```

3. Close Claude Code, Claude Desktop and Codex (Claude Code rewrites `~\.claude.json` while it runs).
4. **From a normal PowerShell window** (Start menu or Windows Terminal), run the installer from the extracted folder:

   ```powershell
   cd "$HOME\TcAuto-0.6.0-beta"
   powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-TcAuto.ps1
   ```

   `-ExecutionPolicy Bypass` applies to this one `powershell.exe` process only and changes no setting; the default policy of a Windows client PC (`Restricted`) runs no script at all ([about_Execution_Policies](https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_execution_policies)), and unblocking the zip does not change that.

   **Do not run the installer in the "Code" tab of Claude Desktop, or in any shell inside an MSIX package.** Windows redirects writes below `%LOCALAPPDATA%` from such a process to `%LOCALAPPDATA%\Packages\<package>\LocalCache\`, where Claude Code in a terminal and Codex cannot see them. The installer detects this and stops with `INSTALL_PACKAGED_CONTEXT` without writing anything (#170). Writes to `%TEMP%` are not redirected (實測 2026-11-08, Windows 11).

5. Restart each client once. A client reads its MCP registration only when the app starts (實測 2026-11-07, Windows 11: Claude Desktop, and Claude Code in the Desktop "Code" tab, which has no reconnect button).
6. In the client, call `GetStatus`, then `ConnectIde`. Before any `ConnectIde`, `GetStatus` answers `success: false` with `error.code` `NOT_CONNECTED` ("IDE not connected"): that proves Node started, `powershell.exe` spawned and the module imported. `data.bridge.runtime` names the runtime that is running (`version`, `commit`).

What the installer does:

- Copies `node\`, `launcher\` and `runtime\<version>\` to `%LOCALAPPDATA%\TwinCATAutomation\` and switches `runtime\current.json` to the new version. The 3 newest runtimes are kept.
- Registers one MCP server `tcauto` = `<install root>\node\node.exe <install root>\launcher\tcauto-launcher.mjs` in Claude Code (user scope, `%USERPROFILE%\.claude.json`), Claude Desktop (MSIX package: `%LOCALAPPDATA%\Claude-Data\claude_*\claude_desktop_config.json`; standard install: `%APPDATA%\Claude\claude_desktop_config.json`) and Codex (`%USERPROFILE%\.codex\config.toml`, table `[mcp_servers.tcauto]`). A client whose config file or folder does not exist is skipped and reported.
- Changes only the `tcauto` entry and copies each config file to `<file>.bak-<yyyyMMddTHHmmss>` first.
- Runs `-Verify` at the end: starts the installed `node.exe` with the launcher, sends MCP `initialize` and `tools/list`, reports the tool count and the runtime commit. It does not connect to an IDE.

Options: `-Clients ClaudeCode,ClaudeDesktop,Codex` (default all three), `-Verify` (check only, writes nothing), `-Uninstall`, `-NoVerify`, `-Keep <n>`, `-InstallRoot <dir>` and per-client config path overrides. The last stdout line is `TCAUTO_INSTALL_RESULT {json}`; installer error codes: [docs/troubleshooting.md](docs/troubleshooting.md) "安裝器錯誤碼". Full guide, per-client details and logs: [docs/setup-mcp.md](docs/setup-mcp.md).

## First use

Start a new conversation in the client and ask for the lifecycle in plain words, for example:

> Connect to the TwinCAT IDE with `C:\TcProjects\MyProject\MyProject.sln`. The target is the local user-mode runtime; use platform `TwinCAT OS (x64)`. Build the project, activate the configuration with Force, then read `MAIN.nCounter` twice and tell me whether it increases.

Use your own solution path and platform (see step 2 below). The client turns this into tool calls. The typical order (MCP tool names equal the CLI action names):

| Step | Tool | What happens |
|---|---|---|
| 1 | `ConnectIde` | Finds the running IDE for the solution or launches one, opens the solution, enables `SilentMode`. Returns `data.amsNetId` and the solution platform. Can take over a minute on a cold start. |
| 2 | `SetTarget` | Sets the target AmsNetId and the solution platform. The target decides the platform: on 4026 a UmRT needs `TwinCAT OS (x64)` and a Windows runtime `TwinCAT RT (x64)` (實測 2026-10-21; a 4024 project that only offers the RT platforms activated on the UmRT with `TwinCAT RT (x64)`, see "環境矩陣" in [docs/troubleshooting.md](docs/troubleshooting.md)). A target that cannot report its platform (the UmRT of TwinCAT 3.1.4026.21-22 answers ADS 0x702) gives `PLATFORM_UNKNOWN` unless `Platform` is passed. |
| 3 | `BuildProject` | Builds and waits. `BUILD_FAILED` carries `data.errorItems` (description, file, line from the XAE Error List). |
| 4 | `EnableConfig` with `Force=true` | Config, Activate, wait for Run, Login and download, wait for the PLC port, PLC Run, each step polled to the target state. |
| 5 | `ConnectAds` | AmsNetId is detected from the IDE target. |
| 6 | `ReadVariable` / `WriteVariable` / `WatchVariable` | Symbol access over ADS. Reconnects by itself after a later Activate (`data.reconnected`). |

`RunLifecycle` does steps 1 to 5 plus a PLC-state readback in one call and stops at the first failing step (`data.steps[]`, `data.failedStep`). With several PLC projects pass `PlcProjectPath`; `AdsPort` must then be one of the selected PLCs' ports, otherwise `PLC_PORT_MISMATCH`.

Rules the tools follow, and that you should expect from the AI:

- `success: true` only after the target state was read back. On `success: false` the AI stops and reports `data` and `error.hint`; it does not fall back to raw ADS, COM or GUI. After a crash or a failed activation the module records a lifecycle block for that target and answers `LIFECYCLE_BLOCKED` until you agree and `ClearLifecycleBlock` is called with a reason. Details: [adapters/claude-code/SKILL.md](adapters/claude-code/SKILL.md) "Failure contract".
- Activating restarts the target runtime and outputs go to zero. Use a target where that is acceptable.
- Long calls (`ConnectIde`, `BuildProject`, `EnableConfig`, `RunLifecycle`) can outlast a client's own request timeout (SDK default 60 s) while the server keeps working. Claude Code: set the environment variable `MCP_TOOL_TIMEOUT` in milliseconds (for example `900000`), in the environment that starts `claude` or in the `env` block of `settings.json`, then restart Claude Code. Details: [mcp-server/README.md](mcp-server/README.md#client-request-timeout).
- Codex asks you to approve every MCP tool call by default (實測 2026-11-08, codex-cli 0.167.0). To run unattended, the setting below in the `[mcp_servers.tcauto]` table of `%USERPROFILE%\.codex\config.toml` is meant to do it:

  ```toml
  default_tools_approval_mode = "approve"
  ```

  This lets the model call every tcauto tool, including `EnableConfig`, `WriteVariable` and `SetPlcState`, without asking you, so a wrong prompt can start, stop or reset a PLC on a real machine. Use it on a test target only.

  The key name is 實測 2026-11-08, codex-cli 0.167.0: it took effect when passed as `codex exec -c mcp_servers.tcauto.default_tools_approval_mode="approve"`. No Codex documentation for it was found. The form written into `config.toml` (the toml block above) has **not been tested yet**.

  The line survives a re-run of `Install-TcAuto.ps1`: in `[mcp_servers.tcauto]` the installer sets only `command` and `args` and keeps every key and sub-table you added ([#204](https://github.com/Lance0901/AI-TwinCAT-Skill/issues/204); verified by unit tests and an install test on temp folders, no real config was touched). `-Uninstall` still removes the whole table with its sub-tables.

## Supported clients and verification status

Verified with the 0.6.0-beta release candidate zip on the local UmRT, with 4026 (Visual Studio 2022) and 4024 (32-bit XAE Shell), 2026-11-08.

| Client | Registered by the installer | Verified | Notes |
|---|---|---|---|
| Claude Code | yes, user scope | Opus 5.5 and Sonnet 5.5: full lifecycle. Haiku 5.5: connection only. | Set `MCP_TOOL_TIMEOUT` for long calls. |
| Codex | yes, `config.toml` | codex-cli 0.167.0, model gpt-6.1-sol: full lifecycle. `ConnectIde` took 66 s with the default tool timeout and was not interrupted. | Asks for approval on each tool call by default, see "First use". |
| Claude Desktop | yes, writes the MSIX config file (and the standard one when that folder exists) | Install and registration: after a restart the log showed `Connected to tcauto (85 tools)` (實測 2026-11-07, MSIX 4.23118.0.0). Tool calls inside a Desktop conversation are **not fully verified**. | Config location differs between the MSIX and the standard install, see [docs/setup-mcp.md](docs/setup-mcp.md). |
| Antigravity | no MCP registration | **Not tested.** The adapter `adapters/antigravity/plugin.yaml` is generated from the tool definitions. | The old skill installer is [below](#legacy-skill-installers-without-mcp). |
| Other MCP clients | by hand | Not tested | stdio server. Command `<install root>\node\node.exe` (customer install) or `node` (developer install); args `["<install root>\\launcher\\tcauto-launcher.mjs"]`. |

"Full lifecycle" = `ConnectIde`, `SetTarget`, `BuildProject`, `EnableConfig Force=true`, `ConnectAds`, `ReadVariable` with a counter that increases.

## Upgrade and remove

**Upgrade.** Do steps 1, 2 and 4 of the install with the new zip (download and check the hash, extract, run `Install-TcAuto.ps1`); step 3 and a client restart are not needed. The clients can stay open because the registration does not change: afterwards call the MCP tool `ReloadRuntime`, then `ConnectIde` again. `ReloadRuntime` is refused (`RELOAD_LIFECYCLE_BLOCKED`, `RELOAD_BUILD_REQUIRED`) while the module holds a lifecycle block or unsaved build-required state, and with `RUNTIME_RELOAD_BUSY` while another call runs. The IDE and ADS connections are released; the IDE keeps running. A newer `node.exe` is used only after the next client restart. `GetStatus` then shows the new commit in `data.bridge.runtime`.

**Remove.** Close the clients, then run this from a normal PowerShell window **in the extracted folder** (keep that folder, or extract the zip again):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-TcAuto.ps1 -Uninstall
```

It removes the `tcauto` entry from the client files (backup first) and `node\`, `launcher\` and `runtime\` of the install root. Other files there (`ide-solutions.json`) stay. A `tcauto` entry that points at a different command is left alone; one that still uses this install through its arguments (a developer registration) stops the removal with `INSTALL_SHARED` unless `-Force` is given.

## Troubleshooting

The five codes you are most likely to meet. Every `error` has `code`, `message` and usually `hint`; the full table with causes and next steps is [docs/troubleshooting.md](docs/troubleshooting.md), install problems are in [docs/setup-mcp.md](docs/setup-mcp.md#troubleshooting).

| You see | Meaning | Do |
|---|---|---|
| Installer stops with `INSTALL_PACKAGED_CONTEXT` | The installer ran inside an MSIX package, typically the Claude Desktop "Code" tab. Nothing was written. | Run the same command from a normal PowerShell window, then restart the clients. Installer error codes: [docs/troubleshooting.md](docs/troubleshooting.md), section "安裝器錯誤碼". |
| The client reports a timeout after about 60 s, no `error.code` from the server | The client's own request timeout is shorter than the call; the server finishes the call anyway. | Claude Code: set `MCP_TOOL_TIMEOUT=900000` (milliseconds; in the environment that starts `claude` or in `settings.json` `env`, then restart Claude Code). Check `GetStatus`. [mcp-server/README.md](mcp-server/README.md#client-request-timeout) |
| `PLATFORM_UNKNOWN`, or `ACTIVATE_FAILED` ("Check config failed") | The solution platform differs from the target platform, or the target cannot report its platform. | Pass `Platform` (`TwinCAT OS (x64)` for a UmRT on 4026) to `SetTarget`, `EnableConfig` or `RunLifecycle`, then build and activate again. Details: [docs/troubleshooting.md](docs/troubleshooting.md), sections "環境矩陣", "PLATFORM_UNKNOWN" and "ACTIVATE_FAILED". |
| [`IDE_MODAL_DIALOG`](docs/troubleshooting.md#ide_modal_dialog--ide_modal_dialog_reload) | A dialog in XAE blocks the call. | Read it with `GetIdeModalDialog`, answer it in the IDE or as the hint says, then repeat. Do not retry blindly. |
| [`RUNTIME_CRASHED`](docs/troubleshooting.md#runtime_crashed) or [`LIFECYCLE_BLOCKED`](docs/troubleshooting.md#lifecycle_blocked) | The local UmRT service `TcSystemServiceUm` disappeared during Config or Activate (#21), or an earlier failure left a block. | Stop; let the AI report `data`. Restart the UmRT yourself, then agree to `ClearLifecycleBlock`, then run `EnableConfig Force=true` again. |

## What is new in v0.6.0-beta

- **Install package.** Release zip with a pinned `node.exe`, launcher and prebuilt runtime; `Install-TcAuto.ps1` registers Claude Code, Claude Desktop (MSIX and standard) and Codex (#20, #162, #165). `ReloadRuntime` switches versions without a client restart. The installer refuses to run inside an MSIX package (#170).
- **`RunLifecycle` / `Start-TcLifecycle`** supports several PLC projects: `PlcProjectPath`, `AdsPort`, `PLC_PORT_MISMATCH` (#27).
- **`ConnectIde TakeOverOrphan=true`** takes over an IDE that an ended session launched, after you confirmed nobody uses it (#196). Refusals: `ORPHAN_TAKEOVER_REFUSED`.
- **Tree tools.** `GetProjectTree` (I/O section), `LookupTreeItem` and `GetIoTree` list direct children only, so a coupler's terminals no longer appear twice; nodes carry `disabled` and `disabledState` (#172, #177, #182, #186).
- **`ResetSolution`** answers the solution-level reload prompt of Visual Studio, reads the reloaded solution back (`SOLUTION_RELOAD_INCOMPLETE` otherwise) and retries a late prompt (#106, #135, #174, #176, #180).
- **`SetSystemState`** stuck in Config returns `data.diagnostics` (dialog, Error List, boot package) and a hint that points at the real cause (#194).
- **`ReadVariable` / `WriteVariable`** reopen the ADS session once and retry when a download left a stale handle (ADS 0x711, `data.symbolsReloaded`, #26).
- **Older claims corrected.** "UmRT fake Run" and "Reset kills `TcSystemServiceUm`" did not reproduce on 2026-11-08 (#26), see below.

## Known limitations

The complete list with workarounds is [docs/known-limitations.md](docs/known-limitations.md). Those that matter for most users:

- **UmRT crash during Config/Activate switching (#21).** Intermittently `TcSystemServiceUm` ends (faulting module `TcOsSys.dll`, c0000005). The module answers `RUNTIME_CRASHED`, records a lifecycle block, and does not retry. On a local UmRT: restart the service, read the state back, then `ClearLifecycleBlock` with a reason. The root cause is in the runtime.
- **Earlier reports that did not reproduce (#26).** Older notes said a UmRT stops cycling its task after about 30 minutes while ADS still says Run, and that a PLC Reset kills `TcSystemServiceUm`. 實測 2026-11-08, 4026 Visual Studio 2022 and the local UmRT: 47 minutes of runtime with the cycle counter rising about 25000 per minute; two Resets left the service running, the PLC in Stop, and `Run` recovered it. Longer runs were not tested.
- **#175:** `ResetSolution` drops unsaved in-memory `.tsproj` changes and unsaved `WritePouCode` editor buffers. Save in XAE first.
- **#49:** `EnableConfig` does not check the target license first. With an expired license the target reports a fatal error and XAE shows a dialog on every XAE connected to that target.
- **#201:** an orphan IDE with a reload prompt open cannot be taken over (`TakeOverOrphan` is refused because of the dialog, and the hinted `ResetSolution` answers `NOT_CONNECTED`). Press Ignore in that IDE or close it by hand.
- **#19:** 32-bit XAE with a Visu project can run out of memory on repeated Activate in one IDE instance. The module detects it (`IDE_CRASHED`, memory warning) but does not restart the IDE.

## Developer install (checkout)

Needs Node.js >= 22, npm and git on `PATH`, plus this repository cloned locally. The result is the same layout as the customer install.

1. In the checkout, on the commit you want to run:

   ```powershell
   powershell -NoProfile -File scripts\Install-TcAutoRuntime.ps1
   ```

   It refuses uncommitted changes below `mcp-server\` and `src\TwinCATAutomation\` (`WORKTREE_DIRTY`; `-AllowDirty` installs them as `<commit>-dirty-<UTC time>`), copies the committed runtime and `npm ci --omit=dev` to `%LOCALAPPDATA%\TwinCATAutomation\runtime\<commit>\`, switches `current.json` and copies the launcher.
2. Register the launcher once (Claude Desktop and Codex: [docs/setup-mcp.md](docs/setup-mcp.md) "Register by hand"):

   ```powershell
   claude mcp add --scope user tcauto -- node "$env:LOCALAPPDATA\TwinCATAutomation\launcher\tcauto-launcher.mjs"
   ```

3. Restart the client once.
4. Upgrade: edit, commit, rerun step 1, call `ReloadRuntime` (`ReloadModule` when only the PowerShell module changed). `GetStatus` -> `data.bridge.runtime` shows the running commit.

Registering `mcp-server/index.js` or a project `.mcp.json` directly is not supported. Build a release zip of your checkout with `powershell -NoProfile -File scripts\Build-TcAutoRelease.ps1` (output `dist\TcAuto-<version>.zip`, needs a clean working tree or `-AllowDirty`).

Checks: run `powershell -File scripts/install-hooks.ps1` once per clone; the pre-commit hook then runs `scripts/check.ps1 -Fast` (PS 5.1 parse and file encoding, cmdlet count vs docs, banned wording, error codes documented, `tools.json` in sync). Run `scripts/check.ps1` (adds `npm test`) before a PR; CI runs it with `-Strict` on `windows-latest`. Counts and the cmdlet signature table in the docs sit between HTML comment markers named `generated:KEY`: never edit them by hand, run `scripts/Update-GeneratedDocs.ps1`. Unit tests without TwinCAT: `cd mcp-server; npm install; npm test`. Review rules: [CODING_STANDARDS.md](CODING_STANDARDS.md). `scripts/check.ps1` and `npm run generate-tools` run local `.ps1` files without `-ExecutionPolicy Bypass`; with a `Restricted` or `AllSigned` policy run once `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

## Using the PowerShell module directly

No MCP needed: import the module in Windows PowerShell 5.1 or PowerShell 7. If the repository came from a zip or a browser download, run `Get-ChildItem -Recurse <repo> | Unblock-File` once, otherwise a `RemoteSigned` policy refuses the scripts.

```powershell
Import-Module ./src/TwinCATAutomation/TwinCATAutomation.psm1 -Force

# 1. Connect to the IDE (finds a running one for the solution, else launches one)
Connect-TcIde -SolutionPath "C:\Projects\MyProject.sln"

# 1b. The target decides the platform; on 4026 a UmRT needs 'TwinCAT OS (x64)', else ACTIVATE_FAILED.
#     Without -Platform it is read from the target (TARGETINFO); a runtime that answers ADS 0x702
#     (the UmRT of TwinCAT 3.1.4026.21-22) gives PLATFORM_UNKNOWN, so pass it.
Set-TcTarget -AmsNetId <data.amsNetId> -Platform 'TwinCAT OS (x64)'

# 2. Build
Build-TcProject

# 3. One step: Config -> Activate -> wait Run -> Login+Download -> PLC Run, zero dialogs, every step polls
Enable-TcConfig -Force

# 4. Connect ADS (AmsNetId detected from the IDE target)
Connect-TcAds

# 5. Read / write variables
Read-TcVariable -Path "MAIN.nCounter"
Write-TcVariable -Path "MAIN.bEnable" -Value $true
```

`Start-TcLifecycle` runs steps 1 to 4 plus a state readback in one call. Run the whole lifecycle in one persistent PowerShell session: the IDE and ADS state live in it. All commands return JSON: `{"success": true, "data": {...}}` or `{"success": false, "error": {"message": "...", "code": "...", "hint": "..."}}`.

Automated tests (Build, Activate, Login, Start, test, Stop):

```powershell
$test1 = New-TcTestCase -Name "Initial state" -Assertions @(
    @{ Path = "MAIN.bReady"; Operator = "IsTrue"; Expected = $null }
    @{ Path = "MAIN.nCount"; Operator = "Equal"; Expected = [uint16]0 }
)
$test2 = New-TcTestCase -Name "Trigger and verify" `
    -Setup @( @{ Path = "MAIN.bStart"; Value = $true } ) `
    -WaitUntil @{ Path = "MAIN.bDone"; Operator = "Equal"; Expected = $true } `
    -Assertions @( @{ Path = "MAIN.bDone"; Operator = "IsTrue"; Expected = $null } ) `
    -Teardown @( @{ Path = "MAIN.bStart"; Value = $false } )
Invoke-TcTestCycle -TestCases @($test1, $test2)
```

Write to `MAIN`-level variables when testing a function block: the PLC overwrites `VAR_INPUT` every scan cycle.

Edit PLC code:

```powershell
$code = Get-TcPouCode -PouName "MAIN"
$newDecl = $code.data.declaration -replace 'END_VAR', "    nCycleCount : UDINT;`nEND_VAR"
$newImpl = "nCycleCount := nCycleCount + 1;`n" + $code.data.implementation
Write-TcPouCode -PouName "MAIN" -Declaration $newDecl -Implementation $newImpl
```

`-PouPath` can be left out (the module searches `POUs`, then the project root); `Write-TcPouCode` edits the COM buffer and needs no `Reset-TcSolution`. When you edit project files on disk instead, call `Reset-TcSolution` right after the write ([docs/troubleshooting.md](docs/troubleshooting.md) "磁碟改檔的正確做法").

### All Commands (<!-- generated:cmdlet-count -->82<!-- /generated -->)

Parameters and MCP tool names: the generated table in [adapters/claude-code/SKILL.md](adapters/claude-code/SKILL.md), [mcp-server/README.md](mcp-server/README.md), or `Get-Help <cmdlet>` after importing the module. Anything that changes a project or the system is dry-run by default where the cmdlet says so.

| Group | Cmdlets |
|---|---|
| Connection | `Connect-TcIde`, `Disconnect-TcIde`, `Reset-TcSolution`, `Connect-TcAds`, `Disconnect-TcAds`, `Get-TcIdeInfo`, `Get-TcIdeModalDialog`, `Get-TcAutomationVersion` |
| Project | `New-TcProject`, `Open-TcProject`, `Get-TcProjectTree`, `Add-TcPou`, `Add-TcGvl`, `Add-TcDut`, `Add-TcInterface`, `Add-TcPouMember` |
| Code | `Get-TcPouCode`, `Write-TcPouCode` |
| Libraries | `Get-TcLibraries`, `Add-TcLibrary`, `Add-TcLibraryPlaceholder`, `Remove-TcLibraryReference`, `Lock-TcLibraryPlaceholder`, `Install-TcLibrary`, `Uninstall-TcLibrary` |
| Tasks | `Add-TcPlcTask`, `Add-TcTaskProgram`, `Remove-TcTaskProgram` |
| Import / export | `Export-TcPlcOpen`, `Import-TcPlcOpen`, `Save-TcPlcLibrary`, `Save-TcArchive` |
| Build and deploy | `Build-TcProject`, `Clear-TcProject`, `Test-TcPlcProject`, `New-TcBootProject`, `Get-TcBuildErrors`, `Enable-TcConfig`, `Enter-TcPlcOnline`, `Exit-TcPlcOnline`, `Send-TcPlcProgram`, `Start-TcLifecycle` |
| Runtime | `Set-TcPlcState`, `Get-TcPlcState`, `Set-TcSystemState`, `Get-TcSystemState`, `Set-TcTarget`, `Clear-TcLifecycleBlock`, `New-TcIssueReport` |
| ADS variables | `Read-TcVariable`, `Write-TcVariable`, `Watch-TcVariable`, `Get-TcSymbols` |
| I/O | `Invoke-TcIoScan`, `Get-TcIoTree`, `Set-TcVariableLink`, `Remove-TcVariableLink` |
| System configuration (dry-run by default; unit tests only, real-target check pending) | `Add-TcNcTask`, `Add-TcNcAxis`, `Set-TcNcAxisParameter`, `Connect-TcNcAxisToPlc`, `Add-TcComModule`, `Get-TcComModuleParameter`, `Set-TcComModuleParameter`, `Set-TcComModuleContext`, `Get-TcProjectVariants`, `Set-TcProjectVariantConfig`, `Set-TcCurrentVariant`, `Set-TcIndependentFile`, `Get-TcAdsRoutes`, `Find-TcAdsTarget`, `Add-TcAdsRoute` |
| Generic tree items (dry-run first; prefer the dedicated cmdlets) | `Get-TcTreeItem`, `Get-TcTreeItemXml`, `New-TcTreeItem`, `Set-TcTreeItemXml`, `Remove-TcTreeItem`, `Export-TcTreeItem`, `Import-TcTreeItem` |
| Testing | `New-TcTestCase`, `Invoke-TcTest`, `Invoke-TcTestCycle` |

### Architecture

```
src/TwinCATAutomation/          # Core PowerShell module (tool-agnostic)
  TwinCATAutomation.psm1        # Module loader
  Public/                       # 82 exported cmdlets
  Private/                      # Internal helpers (COM, ADS, assertions)
Invoke-TwinCATAutomation.ps1    # Unified CLI entry point (JSON in/out)
mcp-server/                     # TcAuto MCP server, launcher, tools.json
scripts/                        # Install-TcAuto.ps1, Install-TcAutoRuntime.ps1, Build-TcAutoRelease.ps1, check.ps1
adapters/
  claude-code/                  # Claude Code SKILL.md adapter
  codex/                        # OpenAI Codex tools.json
  antigravity/                  # Antigravity plugin.yaml
```

The MCP server (stdio) exposes <!-- generated:mcp-tool-count -->79<!-- /generated --> of the <!-- generated:cmdlet-count -->82<!-- /generated --> cmdlets plus <!-- generated:composite-count -->5<!-- /generated --> composite tools (`RunLifecycle`, `QuickRead`, `GetStatus`, `GetIdeModalDialog`, `ReloadModule`) and the launcher's `ReloadRuntime`. `NewProject` is temporarily not offered over MCP (#70); `Start-TcLifecycle` is the composite tool `RunLifecycle` (#27). One long-lived Windows PowerShell 5.1 process keeps the IDE and ADS state across tool calls.

## Documentation index

| Document | For |
|---|---|
| [docs/setup-mcp.md](docs/setup-mcp.md) | Customer and developer install, per-client config files, upgrade, uninstall, verify, logs |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Error code table (`error.code` / `error.hint`), correct lifecycle order, environment matrix, installer error codes |
| [docs/known-limitations.md](docs/known-limitations.md) | Known issues, workarounds, real-hardware coverage |
| [mcp-server/README.md](mcp-server/README.md) | MCP tool table, environment variables, client request timeout |
| [adapters/claude-code/SKILL.md](adapters/claude-code/SKILL.md) | Skill text for Claude Code: lifecycle, failure contract, cmdlet signature table |
| [docs/getting-started.md](docs/getting-started.md), [docs/operations.md](docs/operations.md) | Module-level introduction and operations reference |
| [docs/testing-guide.md](docs/testing-guide.md), [tests/Integration](tests/Integration/README.md) | Test framework and hardware-in-the-loop checks |
| [docs/agent-brief-realmachine.md](docs/agent-brief-realmachine.md) | Rules for agents that test on a real machine |
| [CODING_STANDARDS.md](CODING_STANDARDS.md), [AGENTS.md](AGENTS.md), [CLAUDE.md](CLAUDE.md) | Review rules and the guides for AI tools working in this repository |

## Legacy skill installers (without MCP)

These scripts predate the MCP install: they copy the PowerShell module and `SKILL.md` for AI tools that call the module with `Import-Module`. They do **not** register the MCP server and do not touch any MCP config file. Use the [customer install](#install-customer) for MCP. They run from a checkout.

| Tool | Install | Uninstall | Installed to |
|---|---|---|---|
| Claude Code | `pwsh ./TwinCATSetup-Claude.ps1` | `pwsh ./TwinCATSetup-Claude.ps1 -Uninstall` | `~/.claude/skills/twincat-automation/` |
| Codex | `pwsh ./TwinCATSetup-Codex.ps1` | `pwsh ./TwinCATSetup-Codex.ps1 -Uninstall` | `~/.agents/skills/twincat/` (module and `SKILL.md`) and `~/.codex/AGENTS.md` |
| Antigravity | `pwsh ./TwinCATSetup-Antigravity.ps1` | `pwsh ./TwinCATSetup-Antigravity.ps1 -Uninstall` | `~/.gemini/antigravity/skills/twincat-automation/` |

Every install writes `tcauto-install-manifest.json` next to the installed `SKILL.md`: source repository, module version, commit (or the `tcauto-source.json` stamp of a release zip), install time and the SHA256 of every installed file. `Get-TcAutomationVersion` (MCP `GetAutomationVersion`) reports it offline; `-Verify` checks the installed files against the recorded hashes (`INSTALL_MANIFEST_MISMATCH`). `pwsh ./TwinCATSetup-<Claude|Codex|Antigravity>.ps1 -Verify` prints the manifest and compares the install with the manifest and with this checkout (exit 0 = match). `-SkillDir <dir>` installs or verifies another folder (`-CodexHome` for Codex's `AGENTS.md`); details: [docs/troubleshooting.md](docs/troubleshooting.md) "安裝 manifest(#30)".

## Changes between releases

See the [GitHub Releases](https://github.com/Lance0901/AI-TwinCAT-Skill/releases) page and the merged pull requests. The changelog that used to be in this file stopped at 2026-04.

## License

MIT
