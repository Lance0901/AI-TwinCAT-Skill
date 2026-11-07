# TcAuto MCP Setup

Run the `TwinCATAutomation` module as the TcAuto MCP server so Claude Code, Claude Desktop, Codex or any MCP client can call <!-- generated:mcp-tool-count -->79<!-- /generated --> of the <!-- generated:cmdlet-count -->82<!-- /generated --> cmdlets (plus <!-- generated:composite-count -->5<!-- /generated --> composite tools and the launcher's `ReloadRuntime`; `NewProject` is not offered, #70) as tools, with IDE and ADS state kept between calls. Full reference: [mcp-server/README.md](../mcp-server/README.md).

Contents: [Customer install](#customer-install-release-zip) · [Developer install](#developer-install-from-a-checkout) · [Register by hand](#register-by-hand-per-client) · [Upgrade](#upgrade) · [Uninstall](#uninstall) · [Verify](#verify) · [Troubleshooting](#troubleshooting)

Every client is registered **once** with a small, stable launcher, never with `mcp-server\index.js` of a checkout (a project `.mcp.json` or `node mcp-server/index.js` is not a supported setup any more: the client would run whatever branch the checkout has, `ReloadRuntime` could not switch it, and a project-scope entry next to the user-scope one makes `claude mcp list` report "Conflicting scopes"). The launcher starts the runtime, an installed copy of `mcp-server\` and `src\TwinCATAutomation\` below `%LOCALAPPDATA%`, and can switch to a newly installed version without reconnecting the client (#162):

```
MCP client --stdio--> %LOCALAPPDATA%\TwinCATAutomation\launcher\tcauto-launcher.mjs
                        --stdio--> node %LOCALAPPDATA%\TwinCATAutomation\runtime\<version>\mcp-server\index.js
                                     --> powershell.exe bridge.ps1 (imports runtime\<version>\src\TwinCATAutomation)
```

Two ways to install, same layout and same launcher: a **customer PC** uses the release zip (no Node.js, git or checkout); a **developer** installs from a checkout with `scripts\Install-TcAutoRuntime.ps1`. Supported clients: Claude Code (user scope), Claude Desktop (standard and MSIX), Codex. Clients read their MCP registration **only when the app starts** (實測 2026-11-07, Windows 11: Claude Code in the Claude Desktop "Code" tab, which has no Reconnect button, and Claude Desktop itself). Restart each client once after the first install; later versions need no restart ("Upgrade").

## Customer install (release zip)

The release zip `TcAuto-<version>.zip` (+ `TcAuto-<version>.zip.sha256`) is built by `scripts\Build-TcAutoRelease.ps1` (#20). `.github/workflows/release.yml` builds it on a `v*` tag and attaches it to the GitHub Release of that tag: download it from the repository's **Releases** page. **No Release has been published yet.** Until then build the zip yourself in a clean checkout (needs git and Node.js/npm; `-AllowDirty` for a dirty tree, `-NodeExePath <node.exe>` for a downloaded `node.exe`, which must have the pinned SHA256):

```powershell
powershell -NoProfile -File scripts\Build-TcAutoRelease.ps1      # -> dist\TcAuto-<git describe>.zip + .sha256 (about 40 MB)
```

The zip contains the runtime with its `node_modules`, the launcher, `Install-TcAuto.ps1` (zip root) and an official Node.js 24.22.2 `node.exe` (win-x64; version and SHA256 pinned in `Build-TcAutoRelease.ps1`; the build checks the downloaded `node-v24.22.2-win-x64.zip` and the `node.exe` inside against the pinned values and against that release's `SHASUMS256.txt`, `NODE_HASH_MISMATCH` otherwise). The client runs that `node.exe`, so the PC needs no Node.js. A single executable (Node SEA) was not used: with a plain `node.exe` the launcher can still switch runtimes with `ReloadRuntime`.

Needed on the PC: Windows 10/11, Windows PowerShell 5.1, TwinCAT 3.1 XAE (4024 or 4026) for `ConnectIde` (the installer warns when it finds neither `TWINCAT3DIR` nor the registry value `HKLM\SOFTWARE\WOW6432Node\Beckhoff\TwinCAT3\TwinCATDir`, and installs anyway).

1. Download `TcAuto-<version>.zip` and `TcAuto-<version>.zip.sha256`. Compare the hash:

   ```powershell
   (Get-FileHash .\TcAuto-<version>.zip -Algorithm SHA256).Hash.ToLower()   # = first word of the .sha256 file
   ```

2. Unblock the zip (`Unblock-File .\TcAuto-<version>.zip`, or Properties -> **Unblock**) and extract it to a local folder. Unblocking removes the "downloaded from the internet" mark from the extracted files; it does not let scripts run: the default execution policy of a Windows client PC is `Restricted`, which runs no script at all ([about_Execution_Policies](https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_execution_policies)). That is why step 3 starts the installer with `-ExecutionPolicy Bypass`, which applies only to that one `powershell.exe` process and changes no setting.
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

   Only the `tcauto` entry changes; other servers and settings stay as they are. Each file is copied to `<file>.bak-<yyyyMMddTHHmmss>` before it changes. An existing `tcauto` (for example a developer registration) is overwritten, and its old value is in the result (`data.clients[].previous`). A client is skipped (and reported) when its file (Claude Code) or folder (Claude Desktop, Codex) does not exist. Choose clients with `-Clients ClaudeCode,Codex`. A config file that is not valid JSON, or a Codex `tcauto` written as a key instead of a `[mcp_servers.tcauto]` table, is left unchanged (`CLIENT_CONFIG_FAILED`).

   **Claude Desktop has two config locations (#165).** The MSIX package reads `%LOCALAPPDATA%\Claude-Data\claude_<publisherId>\claude_desktop_config.json` (the folder that also holds its `preferences`), not `%APPDATA%\Claude\` (實測 2026-11-07, Windows 11, Claude Desktop MSIX 4.23118.0.0, package `Claude_4.23118.0.0_x64__pzs8sxrjxfjjc`, folder `claude_pzs8sxrjxfjjc`; Anthropic's documentation names only `%APPDATA%\Claude`). Evidence: with tcauto only in `%APPDATA%\Claude\claude_desktop_config.json` a restart loaded no tcauto; after the entry was added to the `Claude-Data` file, the next restart logged `Connected to tcauto (85 tools)`. Desktop reads the file only at start: a newly written entry is not picked up until the app restarts (實測, same environment). The installer writes every existing `%LOCALAPPDATA%\Claude-Data\claude_*\` folder, and `%APPDATA%\Claude\` when that folder exists or no MSIX folder was found; when both exist both get the entry. `data.clients[]` has one row per file with `variant` = `msix` / `standard`. `-ClaudeDesktopConfig <path>` writes only that file (`variant` = `override`); `-LocalAppDataRoot` / `-AppDataRoot` replace `%LOCALAPPDATA%` / `%APPDATA%` for this lookup.
4. At the end the installer runs the same check as `-Verify`: it starts the installed `node.exe` with the launcher, sends MCP `initialize` + `tools/list` and reports the tool count (<!-- generated:mcp-tool-count -->79<!-- /generated --> cmdlet tools + <!-- generated:composite-count -->5<!-- /generated --> composite tools + the launcher's `ReloadRuntime`) and the runtime commit. It does not connect to an IDE.
5. Restart each client once. Then ask it to call `GetStatus` (see "Verify" below), then `ConnectIde`.

The last stdout line is `TCAUTO_INSTALL_RESULT {json}` (`success`, `data` / `error.code` + `hint`), exit code 0 / 1; an unexpected error gives `INSTALL_FAILED` (`BUILD_FAILED` for `Build-TcAutoRelease.ps1`). Error codes: `docs/troubleshooting.md` "安裝器錯誤碼". In the table, `...` is `powershell -NoProfile -ExecutionPolicy Bypass`.

| Command | What it does |
|---|---|
| `... -File .\Install-TcAuto.ps1 -Verify` | Only the check of step 4; writes nothing |
| `... -File .\Install-TcAuto.ps1 -Uninstall` | See "Uninstall" |
| `-InstallRoot`, `-ClaudeCodeConfig`, `-ClaudeDesktopConfig`, `-CodexConfig`, `-LocalAppDataRoot`, `-AppDataRoot` | Other paths (tests use temp folders) |

## Developer install (from a checkout)

Needed: Windows 10/11 with TwinCAT 3.1 XAE (4024 and 4026 verified), Node.js >= 22 and npm on `PATH` (`node --version`; 18 and 20 are end-of-life, CI tests 22 and 24), Windows PowerShell 5.1 at `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe` (`pwsh` is not used), git on `PATH` (the script reads the commit and whether the working tree is dirty) and this repository cloned locally.

1. In the checkout, on the commit you want to run:

   ```powershell
   powershell -NoProfile -File scripts\Install-TcAutoRuntime.ps1
   ```

2. Register the launcher once ("Register by hand" below; Claude Code: `claude mcp add --scope user tcauto -- node "$env:LOCALAPPDATA\TwinCATAutomation\launcher\tcauto-launcher.mjs"`).
3. Restart the client once.
4. From then on: edit code, commit, rerun step 1, call the MCP tool `ReloadRuntime` ("Upgrade"). A change that touches only the PowerShell module needs only `ReloadModule`.

What `Install-TcAutoRuntime.ps1` does:

1. Refuses (`WORKTREE_DIRTY`, nothing written) when `git status` lists uncommitted changes below `mcp-server\` (except `test\`) or `src\TwinCATAutomation\`. `-AllowDirty` installs them anyway as `<commit>-dirty-<UTC time>` with `dirty: true`.
2. Copies the files `git ls-files -co --exclude-standard` lists (tracked + untracked that are not git-ignored; an ignored `temp_*.ps1` / `*.ps1xml` / `.env` is never installed) below `mcp-server\` (without `node_modules` and `test`) and `src\TwinCATAutomation\` to `%LOCALAPPDATA%\TwinCATAutomation\runtime\<12-char commit>\` (a staging folder first, renamed when complete) and runs `npm ci --omit=dev` there. A clean version that is installed already is reused.
3. Writes `runtime\<version>\tcauto-source.json` (`commit`, `ref`, `branch`, `dirty`, `installedAt`, `sourcePath`, `version`) and switches `runtime\current.json` to the new version atomically (temp file + replace).
4. Copies `mcp-server\launcher\tcauto-launcher.mjs` to `%LOCALAPPDATA%\TwinCATAutomation\launcher\` only when its content changed (a running launcher keeps the file it was started from).
5. Keeps the 3 newest versions (`-Keep N`, 1..20). An older one is removed only when it is not the current one and no running launcher uses it (a folder that cannot be renamed is reported in `pruneSkipped` and kept).

`TCAUTO_RUNTIME_ROOT` (or `-InstallRoot`) replaces `%LOCALAPPDATA%\TwinCATAutomation` for both the script and the launcher (tests use their own folder). The script writes only below `runtime\` and `launcher\`; `ide-solutions.json` and the other state files next to them are not touched. The last stdout line is `TCAUTO_INSTALL_RESULT {json}`. Error codes: `docs/troubleshooting.md` "安裝器錯誤碼".

Tests without TwinCAT: `cd mcp-server; npm install; npm test` (mock bridge). Checks before a PR: `scripts\check.ps1`.

## Register by hand (per client)

`Install-TcAuto.ps1` does this for a customer PC. A developer registers the launcher once, with absolute paths. Each runtime imports its own `src\TwinCATAutomation` and `tools.json`: the launcher does not pass `TWINCAT_MODULE_PATH`, `TWINCAT_MCP_TOOLS_JSON` or `TWINCAT_MCP_PROBE_SCAN_SCRIPT` to the runtime (it logs that it dropped them), so leave them out. Set `MCP_TOOL_TIMEOUT` for Claude Code (see Troubleshooting).

### Claude Code

```powershell
claude mcp add --scope user tcauto -- node "$env:LOCALAPPDATA\TwinCATAutomation\launcher\tcauto-launcher.mjs"
```

An existing `tcauto` in another scope must be removed first (`claude mcp remove tcauto -s user`, or `-s project` / `-s local`).

### Claude Desktop

Standard install: `%APPDATA%\Claude\claude_desktop_config.json`. MSIX package (Microsoft Store / winget): `%LOCALAPPDATA%\Claude-Data\claude_<publisherId>\claude_desktop_config.json` (實測 2026-11-07, Windows 11, MSIX 4.23118.0.0; see "Claude Desktop has two config locations" above). Restart Claude Desktop afterwards.

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

## Upgrade

| Installed with | New version |
|---|---|
| Release zip | Extract the new zip and run its `Install-TcAuto.ps1` the same way. The registration does not change: no client restart, call `ReloadRuntime`, then `ConnectIde` again. Only a new `node.exe` (another Node.js version in the zip) is used after the next client restart; a `node.exe` that a running client holds is renamed aside, not overwritten. |
| Checkout | Check out / pull the commit, rerun `scripts\Install-TcAutoRuntime.ps1`, call `ReloadRuntime`, then `ConnectIde` again. |

`ReloadRuntime` belongs to the launcher (it is not in `tools.json`). It re-reads `current.json`, lets the running runtime retire its PowerShell bridge the way `ReloadModule` does (refused with `RELOAD_LIFECYCLE_BLOCKED` / `RELOAD_BUILD_REQUIRED` and nothing changes while the module holds a lifecycle block or unsaved BUILD_REQUIRED entries in memory), starts the new runtime, replays the client's `initialize` and sends `notifications/tools/list_changed`. It is refused with `RUNTIME_RELOAD_BUSY` while another tool call runs, and calls made during the reload get `RUNTIME_RELOADING`. The IDE and ADS connections are released (the IDE keeps running); IDEs this session launched stay owned by it, because the launcher passes the same owner id to every runtime (`docs/troubleshooting.md` "ReloadRuntime").

Whether a client re-reads the tool list after `notifications/tools/list_changed` is up to the client (not verified for Claude Code, Claude Desktop or Codex as of this writing); a tool or parameter that a new version adds may only show up after a client restart, while calls to existing tools already go to the new runtime. `ReloadModule ModulePath=<worktree>\src\TwinCATAutomation\TwinCATAutomation.psm1` loads the module of another commit (a git worktree of this repository) into the running bridge, then `ConnectIde` again (`docs/troubleshooting.md` "ReloadModule").

## Uninstall

- **Customer install:** close Claude Code, Claude Desktop and Codex, then `powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-TcAuto.ps1 -Uninstall`. It removes `tcauto` from the client files (every Claude Desktop location above) when its command is below the install root (backup first), then `node\`, `launcher\` and `runtime\`. A `tcauto` that runs another command but passes a file below the install root (e.g. `node <root>\launcher\tcauto-launcher.mjs`, a developer registration) is left (`shared`) and nothing is removed (`INSTALL_SHARED`): change that registration first, or add `-Force` to remove it and the files. Any other `tcauto` is left (`foreign`). Other files in `%LOCALAPPDATA%\TwinCATAutomation` (`ide-solutions.json`) stay. A folder a running client still uses gives `INSTALL_IN_USE`.
- **Developer install:** `claude mcp remove tcauto -s user` (and the Claude Desktop / Codex entries by hand), then delete `%LOCALAPPDATA%\TwinCATAutomation\launcher` and `runtime`.

## Verify

Without TwinCAT: `npm test` in `mcp-server/` must pass. A customer PC: `Install-TcAuto.ps1 -Verify`.

With the client connected, ask it to call `GetStatus`. Before any `ConnectIde` the expected answer is:

```json
{ "success": false, "error": { "code": "NOT_CONNECTED", "message": "IDE not connected", "hint": "Run ConnectIde first (optionally with SolutionPath)." }, "data": { "bridge": { "ideConnected": false, ... } } }
```

That proves Node started, `powershell.exe` spawned and the module imported. `data.bridge.runtime` says which runtime runs: `source` (`installed`), `version`, `commit`, `branch`, `dirty`, `installedAt`, `runtimeRoot`, `launcherPid` (set when the launcher started it) and `ownerIdFrom`. `data.bridge.modulePath` / `moduleCommit` / `moduleDirty` / `moduleSource` / `loadedAt` say which module file the bridge loaded and when (#41). Then: "Connect to the IDE with `C:\path\to\MyProject.sln`, build it, activate with Force and read `MAIN.nCounter`" (or a single `RunLifecycle` call).

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Server not listed / "failed to start" in the client | Wrong path in `args`, or (developer registration) Node < 22 | Use the absolute path to the launcher; customer install: `Install-TcAuto.ps1 -Verify`; developer: `node --version`, rerun `scripts\Install-TcAutoRuntime.ps1` (it runs `npm ci` in the runtime) |
| The client does not show tcauto after an install | Clients read their registration only at app start; Claude Desktop MSIX reads `Claude-Data\claude_*`, not `%APPDATA%\Claude` | Restart the app; check `data.clients[]` of the install result for the file that was written |
| First call returns `RUNTIME_NOT_INSTALLED` | No `runtime\current.json` below the install root the launcher uses (`TCAUTO_RUNTIME_ROOT`, else the parent of the launcher folder) | Run `Install-TcAuto.ps1` (customer) or `scripts\Install-TcAutoRuntime.ps1` (developer) |
| A call returns `RUNTIME_DIED` | The runtime process (node) exited during the call | The next call starts it again; `ConnectIde` again; the launcher stderr (client log) has the reason |
| Every call returns `MODULE_IMPORT_FAILED`, stderr "The cloud sync provider failed to validate the downloaded data" | The runtime or module is read from a cloud-synced folder whose files are not on the device (#162) | Use the installed runtime and the launcher (above), which live in `%LOCALAPPDATA%` |
| Every call returns `MODULE_IMPORT_FAILED` | `powershell.exe` not found (custom `TWINCAT_MCP_POWERSHELL`) or `TWINCAT_MODULE_PATH` wrong | Check both paths; run `powershell.exe -NoProfile -Command "Import-Module '<path>\TwinCATAutomation.psm1'"` by hand |
| Call returns `BRIDGE_TIMEOUT` | A DTE call was blocked (usually a modal dialog in XAE) longer than the tool timeout; the bridge was killed and all IDE/ADS state is lost. The XAE process keeps running | Follow `error.hint`: it names the IDE from `data.lastIde` (`ideProcessId`, `selectedBy`). An IDE the server launched: `taskkill /PID <pid> /T /F`; one you opened: dismiss the dialog. Then `ConnectIde` again and `GetIdeModalDialog` before retrying `BuildProject` / `EnableConfig` |
| Call returns `BRIDGE_DIED` | The PowerShell child exited | Next call restarts it; `ConnectIde` again (`data.lastIde` / hint as for `BRIDGE_TIMEOUT`). Check the log for the stderr line |
| Client reports a timeout (often around 60 s) on `ConnectIde`, `BuildProject`, `EnableConfig` or `RunLifecycle`, no `error.code` from the server | The MCP client's own request timeout (SDK default 60 s) is shorter than the call; the server keeps running and finishes the call anyway | Claude Code: set `MCP_TOOL_TIMEOUT` in milliseconds (e.g. `MCP_TOOL_TIMEOUT=900000`). SDK clients: pass `onprogress` + `resetTimeoutOnProgress: true` so the server's `notifications/progress` (every 10 s) keeps the request alive. Claude Desktop: not configurable as of this writing; use the fine-grained tools instead of `RunLifecycle` and check `GetStatus` afterwards. Details: [mcp-server/README.md](../mcp-server/README.md#client-request-timeout) |
| `RunLifecycle` / `EnableConfig` returns `ACTIVATE_FAILED` (target without TARGETINFO) | XAE's Check config failed: the solution platform differs from the target platform (a UmRT / Usermode Runtime needs `TwinCAT OS (x64)`; measured 2026-10-21 on 4026 XAE). `EnableConfig` compares the platforms first, but a target that answers TARGETINFO with ADS 0x702 (the runtime of TwinCAT 3.1.4026.21-22) reports none, so without `Platform` the check is skipped (`data.platformCheck` = `skipped`, `data.warning`) | `EnableConfig {"Force": true, "Platform": "TwinCAT OS (x64)"}` (switches + rebuilds), or `SetTarget {"AmsNetId": "<id>", "Platform": "TwinCAT OS (x64)"}` / `RunLifecycle` with `Platform`, then `BuildProject` + `EnableConfig` |
| Any other `error.code` | Module error, passed through unchanged | Follow `error.hint`; code table in [troubleshooting.md](troubleshooting.md) |

**Where the logs are.** The server's stderr (with the launcher, the launcher's and the runtime's) goes to the client's own log:

| Client | Log |
|---|---|
| Claude Desktop, MSIX package | `%LOCALAPPDATA%\Claude\Logs\mcp-server-tcauto.log`; `main.log` in the same folder has `[LocalMcpServerManager] Connected to tcauto (N tools)` (the older `%LOCALAPPDATA%\Claude-Data\claude_<publisherId>\logs\` is no longer written; 實測 2026-11-07, Windows 11, Claude Desktop MSIX 4.23118.0.0) |
| Claude Desktop, standard install | `%APPDATA%\Claude\logs\mcp-server-tcauto.log` |

Set `TWINCAT_MCP_VERBOSE=1` in the config `env` to also get `Write-Verbose` output from the module as `debug` log notifications.
