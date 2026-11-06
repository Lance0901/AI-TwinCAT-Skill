# TcAuto MCP Setup

Run the `TwinCATAutomation` module as the TcAuto MCP server so Claude Desktop, Claude Code or any MCP client can call <!-- generated:mcp-tool-count -->79<!-- /generated --> of the <!-- generated:cmdlet-count -->81<!-- /generated --> cmdlets (plus <!-- generated:composite-count -->5<!-- /generated --> composite tools; `NewProject` is not offered, #70) as tools, with IDE and ADS state kept between calls. Full reference: [mcp-server/README.md](../mcp-server/README.md).

The MCP client is registered **once** with a small, stable launcher. The launcher starts the runtime (a copy of `mcp-server\` and `src\TwinCATAutomation\` installed outside the checkout) and can switch to a newly installed version without reconnecting the client (#162):

```
MCP client --stdio--> %LOCALAPPDATA%\TwinCATAutomation\launcher\tcauto-launcher.mjs
                        --stdio--> node %LOCALAPPDATA%\TwinCATAutomation\runtime\<version>\mcp-server\index.js
                                     --> powershell.exe bridge.ps1 (imports runtime\<version>\src\TwinCATAutomation)
```

Why not register `<repo>\mcp-server\index.js` directly: the client then runs whatever branch the checkout has at that moment, and when the checkout sits in OneDrive, files that are online-only must be downloaded first. A failed download (cloud file provider error 383, "The cloud sync provider failed to validate the downloaded data") makes the bridge exit before ready (`MODULE_IMPORT_FAILED`, #162), and the module import there took 52-65 s against 6 s from `%TEMP%` (measured 2026-11-06, #158). The installed runtime lives in `%LOCALAPPDATA%`, never in OneDrive.

Two ways to install: a **customer PC** uses the release zip (next section; no Node.js, git or checkout needed). A **developer** installs from a checkout with `scripts\Install-TcAutoRuntime.ps1` (from "Prerequisites" on). Both put the same layout below `%LOCALAPPDATA%\TwinCATAutomation` and the same launcher.

## Customer install (release zip)

The release zip `TcAuto-<version>.zip` (GitHub Releases, built by `.github/workflows/release.yml` on a `v*` tag with `scripts\Build-TcAutoRelease.ps1`, #20) contains the runtime with its `node_modules`, the launcher, `Install-TcAuto.ps1` and an official Node.js `node.exe` (win-x64 LTS, version pinned in `Build-TcAutoRelease.ps1`; the build checks its SHA256 against the pinned value and the release's `SHASUMS256.txt`). The client runs that `node.exe`, so the PC needs no Node.js. A single executable (Node SEA) was not used: with a plain `node.exe` the launcher can still switch runtimes with `ReloadRuntime`.

Needed on the PC: Windows 10/11, Windows PowerShell 5.1, TwinCAT 3.1 XAE for `ConnectIde` (the installer warns when it finds neither `TWINCAT3DIR` nor the registry value `HKLM\SOFTWARE\WOW6432Node\Beckhoff\TwinCAT3\TwinCATDir`, and installs anyway).

1. Download `TcAuto-<version>.zip` and `TcAuto-<version>.zip.sha256` from the release. Compare the hash:

   ```powershell
   (Get-FileHash .\TcAuto-<version>.zip -Algorithm SHA256).Hash.ToLower()   # = first word of the .sha256 file
   ```

2. Unblock the zip (`Unblock-File .\TcAuto-<version>.zip`, or Properties -> **Unblock**) and extract it to a local folder (not OneDrive). Unblocking removes the "downloaded from the internet" mark from the extracted files; it does not let scripts run: the default execution policy of a Windows client PC is `Restricted`, which runs no script at all ([about_Execution_Policies](https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_execution_policies)). That is why step 3 starts the installer with `-ExecutionPolicy Bypass`, which applies only to that one `powershell.exe` process and changes no setting.
3. Close Claude Code, Claude Desktop and Codex (Claude Code rewrites `~\.claude.json` while it runs), then in the extracted folder:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-TcAuto.ps1
   ```

   It copies `node\`, `launcher\` and `runtime\<version>\` to `%LOCALAPPDATA%\TwinCATAutomation` (an installed copy of the same version is reused; `runtime\current.json` is switched atomically; the 3 newest runtimes are kept) and registers the server `tcauto` = `<InstallRoot>\node\node.exe <InstallRoot>\launcher\tcauto-launcher.mjs` in:

   | Client | File | Entry |
   |---|---|---|
   | Claude Code (user scope) | `%USERPROFILE%\.claude.json` | top-level `mcpServers.tcauto` (`type: stdio`, `command`, `args`, `env`); project scopes are not touched |
   | Claude Desktop | MSIX package (Microsoft Store / winget): `%LOCALAPPDATA%\Claude-Data\claude_<publisherId>\claude_desktop_config.json`; standard install: `%APPDATA%\Claude\claude_desktop_config.json` (see below) | `mcpServers.tcauto` (`command`, `args`) |
   | Codex | `%CODEX_HOME%\config.toml`, else `%USERPROFILE%\.codex\config.toml` | table `[mcp_servers.tcauto]` (`command`, `args`) |

   Only the `tcauto` entry changes; other servers and settings stay as they are. Each file is copied to `<file>.bak-<yyyyMMddTHHmmss>` before it changes. An existing `tcauto` (for example one that points at a checkout) is overwritten, and its old value is in the result (`data.clients[].previous`). A client is skipped (and reported) when its file (Claude Code) or folder (Claude Desktop, Codex) does not exist. Choose clients with `-Clients ClaudeCode,Codex`. A config file that is not valid JSON, or a Codex `tcauto` written as a key instead of a `[mcp_servers.tcauto]` table, is left unchanged (`CLIENT_CONFIG_FAILED`).

   **Claude Desktop has two config locations (#165).** The MSIX package reads `%LOCALAPPDATA%\Claude-Data\claude_<publisherId>\claude_desktop_config.json` (the folder that also holds its `preferences` and `logs\`), not `%APPDATA%\Claude\` (實測 2026-11-07, Windows 11, Claude Desktop MSIX 4.23118.0.0, package `Claude_4.23118.0.0_x64__pzs8sxrjxfjjc`, folder `claude_pzs8sxrjxfjjc`; Anthropic's documentation names only `%APPDATA%\Claude`). The installer writes every existing `%LOCALAPPDATA%\Claude-Data\claude_*\` folder, and `%APPDATA%\Claude\` when that folder exists or no MSIX folder was found; when both exist both get the entry. `data.clients[]` has one row per file with `variant` = `msix` / `standard`. `-ClaudeDesktopConfig <path>` writes only that file (`variant` = `override`); `-LocalAppDataRoot` / `-AppDataRoot` replace `%LOCALAPPDATA%` / `%APPDATA%` for this lookup.
4. At the end the installer runs the same check as `-Verify`: it starts the installed `node.exe` with the launcher, sends MCP `initialize` + `tools/list` and reports the tool count (<!-- generated:mcp-tool-count -->79<!-- /generated --> cmdlet tools + <!-- generated:composite-count -->5<!-- /generated --> composite tools + the launcher's `ReloadRuntime`) and the runtime commit. It does not connect to an IDE.
5. Restart each client once. Then ask it to call `GetStatus` (see "Verify" below), then `ConnectIde`.

The last stdout line is `TCAUTO_INSTALL_RESULT {json}` (`success`, `data` / `error.code` + `hint`), exit code 0 / 1; an unexpected error gives `INSTALL_FAILED` (`BUILD_FAILED` for `Build-TcAutoRelease.ps1`). In the table, `...` is `powershell -NoProfile -ExecutionPolicy Bypass`.

| Command | What it does |
|---|---|
| `... -File .\Install-TcAuto.ps1 -Verify` | Only the check of step 4; writes nothing |
| `... -File .\Install-TcAuto.ps1 -Uninstall` | Removes `tcauto` from the client files (every Claude Desktop location above) when its command is below the install root (backup first), then `node\`, `launcher\` and `runtime\`. A `tcauto` that runs another command but passes a file below the install root (e.g. `node <root>\launcher\tcauto-launcher.mjs`, a developer registration) is left (`shared`) and nothing is removed (`INSTALL_SHARED`): change that registration first, or add `-Force` to remove it and the files. Any other `tcauto` is left (`foreign`). Other files in `%LOCALAPPDATA%\TwinCATAutomation` (`ide-solutions.json`) stay. Close the clients first (`INSTALL_IN_USE` otherwise) |
| `-InstallRoot`, `-ClaudeCodeConfig`, `-ClaudeDesktopConfig`, `-CodexConfig`, `-LocalAppDataRoot`, `-AppDataRoot` | Other paths (tests use temp folders) |

**Next versions:** extract the new zip and run its `Install-TcAuto.ps1` the same way. The registration does not change, so no client restart is needed: call the MCP tool `ReloadRuntime`, then `ConnectIde` again ("Switch to another version" below). Only a new `node.exe` (another Node.js version in the zip) is used after the next client restart; a `node.exe` that a running client holds is renamed aside, not overwritten.

Build a zip yourself (maintainers): `powershell -NoProfile -File scripts\Build-TcAutoRelease.ps1` in a clean checkout (`-AllowDirty` otherwise; `-NodeExePath <node.exe>` uses a downloaded `node.exe`, which must have the pinned SHA256). Output: `dist\TcAuto-<git describe>.zip` + `.sha256` (about 40 MB).

## Prerequisites

- Windows 10/11 with TwinCAT 3.1 XAE (verified on 4026)
- Node.js >= 22 (`node --version`; 18 and 20 are end-of-life, CI tests 22 and 24) and npm on `PATH`
- Windows PowerShell 5.1 at `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe` (`pwsh` is not used)
- git on `PATH` (the install script reads the commit and whether the working tree is dirty)
- This repo cloned locally (it may be in OneDrive; only the install script reads it)

## Install the runtime

In the checkout, on the commit you want to run:

```powershell
powershell -NoProfile -File scripts\Install-TcAutoRuntime.ps1
```

What it does:

1. Refuses (`WORKTREE_DIRTY`, nothing written) when `git status` lists uncommitted changes below `mcp-server\` (except `test\`) or `src\TwinCATAutomation\`. `-AllowDirty` installs them anyway as `<commit>-dirty-<UTC time>` with `dirty: true`.
2. Copies the files `git ls-files -co --exclude-standard` lists (tracked + untracked that are not git-ignored; an ignored `temp_*.ps1` / `*.ps1xml` / `.env` is never installed) below `mcp-server\` (without `node_modules` and `test`) and `src\TwinCATAutomation\` to `%LOCALAPPDATA%\TwinCATAutomation\runtime\<12-char commit>\` (a staging folder first, renamed when complete) and runs `npm ci --omit=dev` there. A clean version that is installed already is reused.
3. Writes `runtime\<version>\tcauto-source.json` (`commit`, `ref`, `branch`, `dirty`, `installedAt`, `sourcePath`, `version`) and switches `runtime\current.json` to the new version atomically (temp file + replace).
4. Copies `mcp-server\launcher\tcauto-launcher.mjs` to `%LOCALAPPDATA%\TwinCATAutomation\launcher\` only when its content changed (the launcher rarely changes; a running launcher keeps the file it was started from).
5. Keeps the 3 newest versions (`-Keep N`, 1..20). An older one is removed only when it is not the current one and no running launcher uses it (a folder that cannot be renamed is reported in `pruneSkipped` and kept).

`TCAUTO_RUNTIME_ROOT` (or `-InstallRoot`) replaces `%LOCALAPPDATA%\TwinCATAutomation` for both the script and the launcher (tests use their own folder). The script writes only below `runtime\` and `launcher\`; `ide-solutions.json` and the other state files next to them are not touched. The last stdout line is `TCAUTO_INSTALL_RESULT {json}`.

If a copy fails with a OneDrive error, right-click the checkout folder in Explorer -> **Always keep on this device**, wait until OneDrive has downloaded it, then run the script again (`docs/troubleshooting.md` "OneDrive 與 hydration").

## Register the launcher (once)

Use absolute paths. Each runtime imports its own `src\TwinCATAutomation` and `tools.json`: the launcher does not pass `TWINCAT_MODULE_PATH`, `TWINCAT_MCP_TOOLS_JSON` or `TWINCAT_MCP_PROBE_SCAN_SCRIPT` to the runtime (it logs that it dropped them), so leave them out of the launcher registration.

### Claude Code

```powershell
claude mcp add --scope user tcauto -- node "$env:LOCALAPPDATA\TwinCATAutomation\launcher\tcauto-launcher.mjs"
```

An existing user-scope `tcauto` must be removed first (`claude mcp remove tcauto -s user`). The repo's `.mcp.json` (project scope, `node mcp-server/index.js`) stays for development of this repo; `claude mcp list` reports "Conflicting scopes" while both exist. Set `MCP_TOOL_TIMEOUT` as before (see Troubleshooting).

### Claude Desktop

`%APPDATA%\Claude\claude_desktop_config.json` (standard install) or, for the MSIX package, `%LOCALAPPDATA%\Claude-Data\claude_<publisherId>\claude_desktop_config.json` (實測 2026-11-07, Windows 11, Claude Desktop MSIX 4.23118.0.0; see "Claude Desktop has two config locations" above), then restart Claude Desktop:

```json
{
  "mcpServers": {
    "tcauto": {
      "command": "node",
      "args": ["C:\\Users\\<you>\\AppData\\Local\\TwinCATAutomation\\launcher\\tcauto-launcher.mjs"]
    }
  }
}
```

### Codex

`%USERPROFILE%\.codex\config.toml`:

```toml
[mcp_servers.tcauto]
command = "node"
args = ['C:\Users\<you>\AppData\Local\TwinCATAutomation\launcher\tcauto-launcher.mjs']
```

### Other MCP clients

Any client that launches stdio servers: command `node`, args `["<install root>\\launcher\\tcauto-launcher.mjs"]`.

## Switch to another version

1. In the checkout: check out / pull the commit you want.
2. `powershell -NoProfile -File scripts\Install-TcAutoRuntime.ps1`
3. In the MCP session: call the tool `ReloadRuntime`, then `ConnectIde` again.

`ReloadRuntime` belongs to the launcher (it is not in `tools.json`). It re-reads `current.json`, lets the running runtime retire its PowerShell bridge the way `ReloadModule` does (refused with `RELOAD_LIFECYCLE_BLOCKED` / `RELOAD_BUILD_REQUIRED` and nothing changes while the module holds a lifecycle block or unsaved BUILD_REQUIRED entries in memory), starts the new runtime, replays the client's `initialize` and sends `notifications/tools/list_changed`. It is refused with `RUNTIME_RELOAD_BUSY` while another tool call runs, and calls made during the reload get `RUNTIME_RELOADING`. The IDE and ADS connections are released (the IDE keeps running); IDEs this session launched stay owned by it, because the launcher passes the same owner id to every runtime (`docs/troubleshooting.md` "ReloadRuntime").

Only the **first** switch, from a registration that points at `<repo>\mcp-server\index.js` to the launcher, needs the client to reconnect (remove + add the registration, restart the client or `/mcp` reconnect). After that, new versions only need steps 1-3. Whether a client re-reads the tool list after `notifications/tools/list_changed` is up to the client (not verified for Claude Code, Claude Desktop or Codex as of this writing); a tool or parameter that a new version adds may only show up after a client reconnect, while calls to existing tools already go to the new runtime.

## Development: run index.js from the checkout

Running the checkout directly still works and behaves as before (no launcher, no `ReloadRuntime`): the repo root ships `.mcp.json`, so a Claude Code session opened in the repo root starts `node mcp-server/index.js` (relative path: only when the working directory is the repo root; run `npm install` in `mcp-server\` first). From elsewhere: `claude mcp add tcauto -- node "C:\path\to\2026-AI-TwinCAT-Skill\mcp-server\index.js"`. `TWINCAT_MODULE_PATH` is optional there (default: `../src/TwinCATAutomation/TwinCATAutomation.psm1`). To test another commit in the same session, check it out in a git worktree of this repository and call `ReloadModule ModulePath=<worktree>\src\TwinCATAutomation\TwinCATAutomation.psm1` (then `ConnectIde` again; see `docs/troubleshooting.md` "ReloadModule").

```powershell
cd mcp-server
npm install
npm test          # unit tests with a mock bridge, no TwinCAT needed
```

## Verify

Without TwinCAT: `npm test` in `mcp-server/` must pass.

With the client connected, ask it to call `GetStatus`. Before any `ConnectIde` the expected answer is:

```json
{ "success": false, "error": { "code": "NOT_CONNECTED", "message": "IDE not connected", "hint": "Run ConnectIde first (optionally with SolutionPath)." }, "data": { "bridge": { "ideConnected": false, ... } } }
```

That proves Node started, `powershell.exe` spawned and the module imported. `data.bridge.runtime` says which runtime runs: `source` (`installed` or `git-checkout`), `version`, `commit`, `branch`, `dirty`, `installedAt`, `runtimeRoot`, `launcherPid` (set when the launcher started it) and `ownerIdFrom`. `data.bridge.modulePath` / `moduleCommit` / `moduleDirty` / `moduleSource` / `loadedAt` say which module file the bridge loaded and when (#41). Then: "Connect to the IDE with `C:\path\to\MyProject.sln`, build it, activate with Force and read `MAIN.nCounter`" (or a single `RunLifecycle` call).

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Server not listed / "failed to start" in the client | Node < 22, wrong path in `args`, or (checkout registration) `npm install` not run | `node --version`; use the absolute path to the launcher; run `scripts\Install-TcAutoRuntime.ps1` (it runs `npm ci` in the runtime) |
| First call returns `RUNTIME_NOT_INSTALLED` | No `runtime\current.json` below the install root the launcher uses (`TCAUTO_RUNTIME_ROOT`, else the parent of the launcher folder) | Run `scripts\Install-TcAutoRuntime.ps1` (customer PC: `Install-TcAuto.ps1` of the release zip) |
| A call returns `RUNTIME_DIED` | The runtime process (node) exited during the call | The next call starts it again; `ConnectIde` again; the launcher stderr (client log) has the reason |
| Every call returns `MODULE_IMPORT_FAILED`, stderr "The cloud sync provider failed to validate the downloaded data" | The runtime or module is read from a OneDrive folder whose files are not on the device (#162) | Use the installed runtime and the launcher (above); for a checkout registration: "Always keep on this device" on the checkout |
| Every call returns `MODULE_IMPORT_FAILED` | `powershell.exe` not found (custom `TWINCAT_MCP_POWERSHELL`) or `TWINCAT_MODULE_PATH` wrong | Check both paths; run `powershell.exe -NoProfile -Command "Import-Module '<path>\TwinCATAutomation.psm1'"` by hand |
| Call returns `BRIDGE_TIMEOUT` | A DTE call was blocked (usually a modal dialog in XAE) longer than the tool timeout; the bridge was killed and all IDE/ADS state is lost. The XAE process keeps running | Follow `error.hint`: it names the IDE from `data.lastIde` (`ideProcessId`, `selectedBy`). An IDE the server launched: `taskkill /PID <pid> /T /F`; one you opened: dismiss the dialog. Then `ConnectIde` again and `GetIdeModalDialog` before retrying `BuildProject` / `EnableConfig` |
| Call returns `BRIDGE_DIED` | The PowerShell child exited | Next call restarts it; `ConnectIde` again (`data.lastIde` / hint as for `BRIDGE_TIMEOUT`). Check the log for the stderr line |
| Client reports a timeout (often around 60 s) on `ConnectIde`, `BuildProject`, `EnableConfig` or `RunLifecycle`, no `error.code` from the server | The MCP client's own request timeout (SDK default 60 s) is shorter than the call; the server keeps running and finishes the call anyway | Claude Code: set `MCP_TOOL_TIMEOUT` in milliseconds (e.g. `MCP_TOOL_TIMEOUT=900000`). SDK clients: pass `onprogress` + `resetTimeoutOnProgress: true` so the server's `notifications/progress` (every 10 s) keeps the request alive. Claude Desktop: not configurable as of this writing; use the fine-grained tools instead of `RunLifecycle` and check `GetStatus` afterwards. Details: [mcp-server/README.md](../mcp-server/README.md#client-request-timeout) |
| `RunLifecycle` / `EnableConfig` returns `ACTIVATE_FAILED` (target without TARGETINFO) | XAE's Check config failed: the solution platform differs from the target platform (a UmRT / Usermode Runtime needs `TwinCAT OS (x64)`; measured 2026-10-21 on 4026 XAE). `EnableConfig` compares the platforms first, but a target that answers TARGETINFO with ADS 0x702 (the runtime of TwinCAT 3.1.4026.21-22) reports none, so without `Platform` the check is skipped (`data.platformCheck` = `skipped`, `data.warning`) | `EnableConfig {"Force": true, "Platform": "TwinCAT OS (x64)"}` (switches + rebuilds), or `SetTarget {"AmsNetId": "<id>", "Platform": "TwinCAT OS (x64)"}` / `RunLifecycle` with `Platform`, then `BuildProject` + `EnableConfig` |
| Any other `error.code` | Module error, passed through unchanged | Follow `error.hint`; code table in [troubleshooting.md](troubleshooting.md) |

Claude Desktop writes the server's stderr (with the launcher, the launcher's and the runtime's) to `%APPDATA%\Claude\logs\mcp-server-tcauto.log` (MSIX package: `%LOCALAPPDATA%\Claude-Data\claude_<publisherId>\logs\mcp-server-tcauto.log`, 實測 2026-11-07, Windows 11, Claude Desktop MSIX 4.23118.0.0). Set `TWINCAT_MCP_VERBOSE=1` in the config `env` to also get `Write-Verbose` output from the module as `debug` log notifications.
