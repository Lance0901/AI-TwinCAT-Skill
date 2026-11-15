# TcAuto MCP Setup

Run the `TwinCATAutomation` module as the TcAuto MCP server so Claude Code, Claude Desktop, Codex or any MCP client can call <!-- generated:mcp-tool-count -->84<!-- /generated --> of the <!-- generated:cmdlet-count -->87<!-- /generated --> cmdlets (plus <!-- generated:composite-count -->6<!-- /generated --> composite tools and the launcher's `ReloadRuntime`; `NewProject` is not offered, #70; `Start-TcLifecycle` is served by the composite tool `RunLifecycle`, #27) as tools, with IDE and ADS state kept between calls. Tool reference: [mcp-server/README.md](../mcp-server/README.md). Short version for a customer PC: [README.md](../README.md#install-customer).

Contents: [Which install](#which-install-do-you-need) · [Layout](#layout) · [Customer install](#customer-install-release-zip) · [Developer install](#developer-install-from-a-checkout) · [Register by hand](#register-by-hand-per-client) · [First call and approvals](#first-call-and-client-settings) · [Upgrade](#upgrade) · [Uninstall](#uninstall) · [Verify](#verify) · [Troubleshooting](#troubleshooting)

## Which install do you need

| You are | Use | Needs on the PC |
|---|---|---|
| A customer or tester who only runs the tool | [Customer install](#customer-install-release-zip): release zip + `Install-TcAuto.ps1` | Windows 10/11, Windows PowerShell 5.1, TwinCAT 3.1 XAE for `ConnectIde`. No Node.js, git or npm. |
| A developer working on this repository | [Developer install](#developer-install-from-a-checkout): `scripts\Install-TcAutoRuntime.ps1` | The above plus Node.js >= 22, npm, git, a clone of the repository |

Both produce the same layout and the same launcher. Do not register `mcp-server\index.js` of a checkout or a project `.mcp.json`: the client would run whatever branch the checkout has, `ReloadRuntime` could not switch it, and a project-scope entry next to the user-scope one makes `claude mcp list` report "Conflicting scopes".

## Layout

Every client is registered **once** with a small, stable launcher. The launcher starts the runtime, an installed copy of `mcp-server\` and `src\TwinCATAutomation\` below `%LOCALAPPDATA%`, and can switch to a newly installed version without reconnecting the client (#162):

```
MCP client --stdio--> %LOCALAPPDATA%\TwinCATAutomation\launcher\tcauto-launcher.mjs
                        --stdio--> node %LOCALAPPDATA%\TwinCATAutomation\runtime\<version>\mcp-server\index.js
                                     --> powershell.exe bridge.ps1 (imports runtime\<version>\src\TwinCATAutomation)
```

| Path below `%LOCALAPPDATA%\TwinCATAutomation` | Content |
|---|---|
| `node\` | `node.exe` (customer install only; a developer install uses the `node` on `PATH`) |
| `launcher\tcauto-launcher.mjs` | The only file a client points at |
| `runtime\<version>\` | One installed version (`tcauto-source.json` inside); the 3 newest are kept |
| `runtime\current.json` | Which version the launcher starts; switched atomically |
| `ide-solutions.json` and other state files | Written by the module at run time; the installers never touch them |

`TCAUTO_RUNTIME_ROOT` (or `-InstallRoot`) replaces `%LOCALAPPDATA%\TwinCATAutomation` for the installers and the launcher (tests use their own folder).

Clients read their MCP registration **only when the app starts** (實測 2026-11-07, Windows 11: Claude Code in the Claude Desktop "Code" tab, which has no Reconnect button, and Claude Desktop itself). Restart each client once after the first install; later versions need no restart ([Upgrade](#upgrade)).

## Customer install (release zip)

### Where the zip comes from

`TcAuto-<version>.zip` and `TcAuto-<version>.zip.sha256` are built by `scripts\Build-TcAutoRelease.ps1` (#20). `.github/workflows/release.yml` runs it on `windows-latest` when a `v*` tag is pushed and attaches both files to the GitHub Release of that tag (when the workflow itself creates the Release, a tag with a `-` such as `v0.6.0-beta` makes it a pre-release; an existing Release keeps its flag). Download them from the repository's [Releases](https://github.com/Lance0901/AI-TwinCAT-Skill/releases) page.

**v0.6.0-beta is the first release with the zip.** v0.5.0-beta and earlier releases have no install package. If the Releases page does not list a zip yet, use the [developer install](#developer-install-from-a-checkout); building the zip yourself is described there.

What is in the zip (about 40 MB):

| Entry | Content |
|---|---|
| `Install-TcAuto.ps1`, `lib\` | The installer and the code it shares with `Install-TcAutoRuntime.ps1` and `lib\tcauto-client-config.mjs` (merges the `tcauto` entry into the client configs) |
| `node\node.exe`, `node\LICENSE` | Official Node.js 24.22.2 win-x64 build. Version and SHA256 are pinned in `Build-TcAutoRelease.ps1`; the build checks the downloaded `node-v24.22.2-win-x64.zip` and the `node.exe` inside against the pinned values and against that release's `SHASUMS256.txt` (`NODE_HASH_MISMATCH` otherwise). |
| `launcher\tcauto-launcher.mjs` | The launcher |
| `runtime\<12-char commit>\` | The built runtime: `mcp-server\` and `src\TwinCATAutomation\` plus production `node_modules` (`npm ci --omit=dev`) and `tcauto-source.json` |
| `tcauto-release.json`, `README.txt` | Version, commit, Node.js version and SHA256, build time; the short install steps |

The client runs that `node.exe`, so the PC needs no Node.js. A single executable (Node SEA) was not used: with a plain `node.exe` the launcher can still switch runtimes with `ReloadRuntime`.

### Steps

Needed on the PC: Windows 10/11, Windows PowerShell 5.1, TwinCAT 3.1 XAE (4024 or 4026) for `ConnectIde`. The installer warns when it finds neither `TWINCAT3DIR` nor the registry value `HKLM\SOFTWARE\[WOW6432Node\]Beckhoff\TwinCAT3\TwinCATDir` (both locations), and installs anyway.

Do steps 1 to 4 in the same PowerShell window, because the `$zip` variable is reused.

1. Download the zip and its `.sha256`, then compare the hash (in a normal PowerShell window; replace the version):

   ```powershell
   cd "$HOME\Downloads"
   $zip = '.\TcAuto-0.6.0-beta.zip'
   (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()   # = first word of the .sha256 file
   Get-Content "$zip.sha256"
   ```

2. Unblock the zip and extract it to a local folder (not OneDrive or another cloud-synced folder; see "Troubleshooting"):

   ```powershell
   Unblock-File $zip
   Expand-Archive $zip -DestinationPath "$HOME\TcAuto-0.6.0-beta"
   ```

   Unblocking removes the "downloaded from the internet" mark from the extracted files; it does not let scripts run. The default execution policy of a Windows client PC is `Restricted`, which runs no script at all ([about_Execution_Policies](https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_execution_policies)). That is why step 4 starts the installer with `-ExecutionPolicy Bypass`, which applies only to that one `powershell.exe` process and changes no setting.
3. Close Claude Code, Claude Desktop and Codex (Claude Code rewrites `~\.claude.json` while it runs).
4. **Run the installer from a normal PowerShell window** (Start menu or Windows Terminal), in the extracted folder:

   ```powershell
   cd "$HOME\TcAuto-0.6.0-beta"
   powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-TcAuto.ps1
   ```

   **Not from the "Code" tab of Claude Desktop, and not from any shell inside an MSIX package** (#170). Windows redirects writes below `%LOCALAPPDATA%` / `%APPDATA%` from a process in an MSIX package to `%LOCALAPPDATA%\Packages\<package>\LocalCache\{Local,Roaming}\`, where only that package sees them: Claude Code in a terminal and Codex would find no runtime. The installer checks the package identity, and as a second check writes a probe file next to the install root and looks for it below `Packages\*\LocalCache\`; either hit stops it with `INSTALL_PACKAGED_CONTEXT` before anything is written. A probe that cannot be written or removed also stops it (`INSTALL_PROBE_FAILED`). Writes to `%TEMP%` are not redirected (實測 2026-11-08, Windows 11).
5. Restart each client once.
6. Ask the client to call `GetStatus` (see [Verify](#verify)), then `ConnectIde`.

### What the installer does

1. Copies `node\`, `launcher\` and `runtime\<version>\` to `%LOCALAPPDATA%\TwinCATAutomation` (an installed copy of the same version is reused; `runtime\current.json` is switched atomically; the 3 newest runtimes are kept). A `node.exe` that a running client holds is renamed aside, not overwritten.
2. Registers the server `tcauto` = `<InstallRoot>\node\node.exe <InstallRoot>\launcher\tcauto-launcher.mjs` in:

   | Client | File | Entry |
   |---|---|---|
   | Claude Code (user scope) | `%USERPROFILE%\.claude.json` | top-level `mcpServers.tcauto` (`type: stdio`, `command`, `args`, `env`); project scopes are not touched |
   | Claude Desktop | MSIX package (Microsoft Store / winget): `%LOCALAPPDATA%\Claude-Data\claude_<publisherId>\claude_desktop_config.json`; standard install: `%APPDATA%\Claude\claude_desktop_config.json` (see below) | `mcpServers.tcauto` (`command`, `args`) |
   | Codex | `%CODEX_HOME%\config.toml`, else `%USERPROFILE%\.codex\config.toml` | table `[mcp_servers.tcauto]` (`command`, `args`) |

   Only the `tcauto` entry changes; other servers and settings stay as they are. Each file is copied to `<file>.bak-<yyyyMMddTHHmmss>` before it changes. In an existing `tcauto` (for example a developer registration) only the keys the installer owns are set: `command` and `args` (Claude Code also `type = "stdio"`, and `env = {}` when there is no `env`). Every other key and sub-table you added under `tcauto` (for example `env`, Codex `default_tools_approval_mode` or `[mcp_servers.tcauto.tools.*]`) keeps its value and position ([#204](https://github.com/Lance0901/AI-TwinCAT-Skill/issues/204); listed in `data.clients[].keptKeys`). Exception: an env variable `TCAUTO_RUNTIME_ROOT` under `tcauto` is removed (`data.clients[].removedKeys`), because the launcher would take its install root from it and run another runtime than the one the installer checks. A `cwd`, or Codex `enabled = false`, is kept but reported in `data.clients[].warnings` (it changes how tcauto starts or whether it runs). In Codex a `command` / `args` statement whose value differs is rewritten as a whole line (an end-of-line comment on it is lost); one that already has the right value is left as written; lines that are not changed keep their own line ending, new or rewritten lines get the one most lines of the file use. After the change the file is read back (exactly one `command` and one `args` in `[mcp_servers.tcauto]` with the new values) before it is written. The old value is in the result (`data.clients[].previous`). `-Uninstall` removes the whole entry (Codex: the table with all its sub-tables). A client is skipped (and reported) when its file (Claude Code) or folder (Claude Desktop, Codex) does not exist. A config file that is not valid JSON, a Codex `tcauto` written as a key or as an array of tables (`[[mcp_servers.tcauto]]`) instead of one `[mcp_servers.tcauto]` table, or a Codex table that does not read back correctly (for example two `command` keys), is left unchanged (`CLIENT_CONFIG_FAILED`).
3. Runs the same check as `-Verify`: starts the installed `node.exe` with the launcher, sends MCP `initialize` + `tools/list` and reports the tool count (<!-- generated:mcp-tool-count -->84<!-- /generated --> cmdlet tools + <!-- generated:composite-count -->6<!-- /generated --> composite tools + the launcher's `ReloadRuntime`) and the runtime commit. It does not connect to an IDE.

**Claude Desktop has two config locations (#165).** The MSIX package reads `%LOCALAPPDATA%\Claude-Data\claude_<publisherId>\claude_desktop_config.json` (the folder that also holds its `preferences`), not `%APPDATA%\Claude\` (實測 2026-11-07, Windows 11, Claude Desktop MSIX 4.23118.0.0, package `Claude_4.23118.0.0_x64__pzs8sxrjxfjjc`, folder `claude_pzs8sxrjxfjjc`; Anthropic's documentation names only `%APPDATA%\Claude`). Evidence: with tcauto only in `%APPDATA%\Claude\claude_desktop_config.json` a restart loaded no tcauto; after the entry was added to the `Claude-Data` file, the next restart logged `Connected to tcauto (85 tools)`. Desktop reads the file only at start. The installer writes every existing `%LOCALAPPDATA%\Claude-Data\claude_*\` folder, and `%APPDATA%\Claude\` when that folder exists or no MSIX folder was found; when both exist both get the entry. `data.clients[]` has one row per file with `variant` = `msix` / `standard`.

### Installer options

The last stdout line is `TCAUTO_INSTALL_RESULT {json}` (`success`, `data` / `error.code` + `hint`), exit code 0 / 1; an unexpected error gives `INSTALL_FAILED` (`BUILD_FAILED` for `Build-TcAutoRelease.ps1`). Error codes: `docs/troubleshooting.md` "安裝器錯誤碼". Below, `...` is `powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-TcAuto.ps1`.

| Option | Effect |
|---|---|
| `... -Clients ClaudeCode,Codex` | Register only these clients (`ClaudeCode`, `ClaudeDesktop`, `Codex`; default all three) |
| `... -Verify` | Only the check of step 3; writes nothing |
| `... -NoVerify`, `-VerifyTimeoutSec <5..600>` | Skip the final check; its time limit (default 90 s) |
| `... -Uninstall` [`-Force`] | See [Uninstall](#uninstall) |
| `-Keep <1..20>` | Runtime versions to keep (default 3; the current one is never removed) |
| `-InstallRoot`, `-ClaudeCodeConfig`, `-ClaudeDesktopConfig`, `-CodexConfig`, `-LocalAppDataRoot`, `-AppDataRoot`, `-PackageRoot` | Other paths (tests use temp folders). `-ClaudeDesktopConfig <path>` writes only that file (`variant` = `override`); `-LocalAppDataRoot` / `-AppDataRoot` replace `%LOCALAPPDATA%` / `%APPDATA%` for the Claude Desktop lookup. |

## Developer install (from a checkout)

Needed: Windows 10/11 with TwinCAT 3.1 XAE (4024 and 4026 verified), Node.js >= 22 and npm on `PATH` (`node --version`; 18 and 20 are end-of-life, CI tests 22 and 24), Windows PowerShell 5.1 at `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe` (`pwsh` is not used), git on `PATH` (the script reads the commit and whether the working tree is dirty) and this repository cloned locally.

1. In the checkout, on the commit you want to run:

   ```powershell
   powershell -NoProfile -File scripts\Install-TcAutoRuntime.ps1
   ```

2. Register the launcher once ([Register by hand](#register-by-hand-per-client); Claude Code: `claude mcp add --scope user tcauto -- node "$env:LOCALAPPDATA\TwinCATAutomation\launcher\tcauto-launcher.mjs"`).
3. Restart the client once.
4. From then on: edit code, commit, rerun step 1, call the MCP tool `ReloadRuntime` ([Upgrade](#upgrade)). A change that touches only the PowerShell module needs only `ReloadModule`.

Parameters: `-InstallRoot`, `-AllowDirty`, `-Keep <1..20>` (default 3), `-NpmPath` (default `npm.cmd`). What `Install-TcAutoRuntime.ps1` does:

1. Refuses (`WORKTREE_DIRTY`, nothing written) when `git status` lists uncommitted changes below `mcp-server\` (except `test\`) or `src\TwinCATAutomation\`. `-AllowDirty` installs them anyway as `<commit>-dirty-<UTC time>` with `dirty: true`.
2. Copies the files `git ls-files -co --exclude-standard` lists (tracked + untracked that are not git-ignored; an ignored `temp_*.ps1` / `*.ps1xml` / `.env` is never installed) below `mcp-server\` (without `node_modules` and `test`) and `src\TwinCATAutomation\` to `%LOCALAPPDATA%\TwinCATAutomation\runtime\<12-char commit>\` (a staging folder first, renamed when complete) and runs `npm ci --omit=dev` there. A clean version that is installed already is reused.
3. Writes `runtime\<version>\tcauto-source.json` (`commit`, `ref`, `branch`, `dirty`, `installedAt`, `sourcePath`, `version`) and switches `runtime\current.json` to the new version atomically (temp file + replace).
4. Copies `mcp-server\launcher\tcauto-launcher.mjs` to `%LOCALAPPDATA%\TwinCATAutomation\launcher\` only when its content changed (a running launcher keeps the file it was started from).
5. Keeps the 3 newest versions. An older one is removed only when it is not the current one and no running launcher uses it (a folder that cannot be renamed is reported in `pruneSkipped` and kept).

### Building the release zip

To build the zip of your checkout (clean working tree; needs git and Node.js/npm; `-AllowDirty` for a dirty tree, `-NodeExePath <node.exe>` for a downloaded `node.exe`, which must have the pinned SHA256):

```powershell
powershell -NoProfile -File scripts\Build-TcAutoRelease.ps1      # -> dist\TcAuto-<git describe>.zip + .sha256 (about 40 MB)
```

The zip layout is described under "Customer install".

The script writes only below `runtime\` and `launcher\`. The last stdout line is `TCAUTO_INSTALL_RESULT {json}`. Error codes: `docs/troubleshooting.md` "安裝器錯誤碼".

Tests without TwinCAT: `cd mcp-server; npm install; npm test` (mock bridge). Checks before a PR: `scripts\check.ps1`.

## Register by hand (per client)

`Install-TcAuto.ps1` does this for a customer PC. A developer registers the launcher once, with absolute paths. Each runtime imports its own `src\TwinCATAutomation` and `tools.json`: the launcher does not pass `TWINCAT_MODULE_PATH`, `TWINCAT_MCP_TOOLS_JSON` or `TWINCAT_MCP_PROBE_SCAN_SCRIPT` to the runtime (it logs that it dropped them), so leave them out. Set `MCP_TOOL_TIMEOUT` for Claude Code (see Troubleshooting).

### Claude Code

```powershell
claude mcp add --scope user tcauto -- node "$env:LOCALAPPDATA\TwinCATAutomation\launcher\tcauto-launcher.mjs"
```

An existing `tcauto` in another scope must be removed first (`claude mcp remove tcauto -s user`, or `-s project` / `-s local`).

### Claude Desktop

Standard install: `%APPDATA%\Claude\claude_desktop_config.json`. MSIX package (Microsoft Store / winget): `%LOCALAPPDATA%\Claude-Data\claude_<publisherId>\claude_desktop_config.json` (see "Claude Desktop has two config locations" above). Restart Claude Desktop afterwards.

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

**Flow card and guide topics (#307, #310):** the server sends `mcp-server/instructions.md` (one page: golden rules, UmRT or real machine, when the tool asks the user, what to do on a failure, which topic to read per task) as the `instructions` of its `initialize` result, and the read-only tool `GetGuide` returns the same card (`GetGuide('start')`, or no topic) or one topic file `mcp-server/guide/<topic>.md` (`open-project`, `change-code`, `deploy`, `testing`, `nc-axis`, `io`, `tccom`, `variants`, `plcopen`, `libraries`, `recovery`, `consent`). Both ship inside the runtime folder (release zip and `Install-TcAutoRuntime.ps1`). Claude Code puts the instructions into the model context and cuts them after 4,096 characters ([code.claude.com/docs/en/mcp](https://code.claude.com/docs/en/mcp)), so the card stays below that (`npm test` checks it). **Codex may not show MCP instructions to the model**: codex-cli 0.167.0 could not quote the card on 2026-11-13 (#308), but quoted it without any tool call on 2026-11-15 (實測, same version, branch runtime of #310; with `-c mcp_servers.tcauto.enabled=false` it answered NOT-IN-CONTEXT), so do not rely on it. It always gets the card through the tool: the `GetGuide` description starts with `Read GetGuide('start') before your first TcAuto call.`, so nothing has to be written into `AGENTS.md` (replaces #308). `TwinCATSetup-Codex.ps1` (older skill installer) still appends the card to `%USERPROFILE%\.codex\AGENTS.md`.

### Other MCP clients

Any client that launches stdio servers: command `<install root>\node\node.exe` (customer install) or `node` (developer install), args `["<install root>\\launcher\\tcauto-launcher.mjs"]`.

## First call and client settings

Verified with the 0.6.0-beta release candidate zip on the local UmRT, 4026 (Visual Studio 2022) and 4024 (32-bit XAE Shell), 2026-11-08:

| Client | Result |
|---|---|
| Claude Code | Opus 5.5 and Sonnet 5.5: full lifecycle (`ConnectIde`, `SetTarget`, `BuildProject`, `EnableConfig Force=true`, `ConnectAds`, `ReadVariable` with a rising counter). Haiku 5.5: connection only. |
| Codex | codex-cli 0.167.0, model gpt-6.1-sol: full lifecycle. `ConnectIde` took 66 s with the default tool timeout and was not interrupted. |
| Claude Desktop | Install and registration verified (the log showed `Connected to tcauto (85 tools)` after a restart, 實測 2026-11-07, MSIX 4.23118.0.0). Tool calls inside a Desktop conversation are not fully verified. |
| Antigravity | No MCP registration by the installer; `adapters/antigravity/plugin.yaml` exists. Not tested. |

Settings worth knowing:

- **Codex asks for approval of every MCP tool call by default** (實測 2026-11-08, codex-cli 0.167.0). In an interactive session you answer each prompt. To run unattended, approve the tools in the `[mcp_servers.tcauto]` table:

  ```toml
  default_tools_approval_mode = "approve"
  ```

  or approve single tools only, one sub-table per tool:

  ```toml
  [mcp_servers.tcauto.tools.ConnectIde]
  approval_mode = "approve"
  ```

  **Headless runs need it** ([#250](https://github.com/Lance0901/AI-TwinCAT-Skill/issues/250)): `codex exec` with `approval_policy="never"` cannot ask, so only the tools approved this way run. Every other tcauto call fails with `MCP tool call requires approval, but approval policy is never` and the lifecycle stops at the first unapproved tool. 實測 2026-11-12, codex-cli 0.167.0, TcAuto v0.6.1-beta-rc2: with only `tools.ConnectIde.approval_mode` approved, `ConnectIde` ran and `SetTarget` failed with that message; with `-c mcp_servers.tcauto.default_tools_approval_mode=approve` added, the full lifecycle passed. For a headless lifecycle approve at least every tool it calls (`ConnectIde`, `SetTarget`, `BuildProject`, `EnableConfig`, `ConnectAds`, `ReadVariable`, or `RunLifecycle`), or use `default_tools_approval_mode`.

  Risk of `default_tools_approval_mode = "approve"`: the model can then call every tcauto tool without asking you, including `EnableConfig` (restarts the target runtime, outputs go to zero), `WriteVariable`, `SetPlcState` (Run / Stop / Reset) and the plan step of `InstallPackage`. A wrong prompt acts on the real machine. `InstallPackage` still installs nothing without `Approved=true` plus the `PlanToken` of a plan made in the same server process, and since #258 the server also asks you in a confirmation form that the model cannot answer (see "Confirmation forms"); the same form guards routes, libraries, `ResetSolution Force=true`, attaching to your own IDE and the first runtime change of a target that is not the local UmRT. Use it for a test target only, or approve single tools instead. The key names are 實測 (2026-11-08 / 2026-11-12, codex-cli 0.167.0) when passed with `codex exec -c ...`; no Codex documentation for them was found, and the form written into `config.toml` has **not been tested yet**.

  The installer never writes these keys. A re-run of `Install-TcAuto.ps1` keeps the ones you added (see "What the installer does"; [#204](https://github.com/Lance0901/AI-TwinCAT-Skill/issues/204)).
- **Claude Code:** set the environment variable `MCP_TOOL_TIMEOUT` (milliseconds, for example `900000`; in the environment that starts `claude` or in the `env` block of `settings.json`, then restart Claude Code) so long calls are not cut by the client ([Troubleshooting](#troubleshooting)).
- **Platform:** the target decides the solution platform; pass `Platform` to `SetTarget` / `EnableConfig` / `RunLifecycle` where the target cannot report it (`docs/troubleshooting.md` "環境矩陣").

## Confirmation forms (MCP elicitation, #258)

Calls that need the user's consent are confirmed by the user in a form the TcAuto server sends through the MCP client (MCP `elicitation/create`); the AI cannot answer it. The form has one required choice, `decision` = `approve` / `reject`; only `approve` runs the call. Which calls ask and when: `docs/troubleshooting.md` "確認框(MCP elicitation,#258)". There is no setting, parameter or environment variable that turns the forms off or approves in advance; the PowerShell module itself (not through MCP) does not ask.

| Client / mode | Behaviour with a TcAuto form | Result |
|---|---|---|
| Claude Code, interactive | Shows the form (Claude Code v2.1.76 or newer, per its changelog) | runs on `approve` |
| Claude Code `claude -p`, any permission mode including `bypassPermissions` / `--dangerously-skip-permissions` | cancels every form at once (實測 #258 before the implementation, Claude Code 2.1.319) | `CONSENT_DECLINED` |
| Codex CLI, interactive | Shows the form (codex-cli 0.119.0 or newer, per its release notes) | runs on `approve` |
| `codex exec`, default / `approval_policy="never"` | the MCP tool call itself is blocked unless approved in the config; when approved, the form is declined (實測 #258 before the implementation, codex-cli 0.167.0) | `CONSENT_DECLINED` |
| `codex exec --dangerously-bypass-approvals-and-sandbox` | a form without fields is accepted automatically, a form with a required choice is declined (實測 #258 before the implementation, codex-cli 0.167.0): TcAuto forms always have the required choice | `CONSENT_DECLINED` |
| A client that does not declare `capabilities.elicitation` (Claude Desktop: no official support found; Antigravity: not tested) | no form is sent | `CONSENT_REQUIRED` |

On `CONSENT_DECLINED` / `CONSENT_REQUIRED` nothing ran. Retry in an interactive client that shows forms, or run the operation yourself with the PowerShell module (`InstallPackage` returns the tcpkg command to run in an elevated PowerShell). A form not answered within 10 minutes counts as `CONSENT_REQUIRED`. Headless runs therefore cannot install packages or change a runtime that is not the local UmRT: this is intended. Only these two kinds of calls ask (owner decision 2026-11-15: ask only where people can get hurt, plus the tcpkg install rule); `AddAdsRoute`, `InstallLibrary` / `UninstallLibrary`, `ResetSolution Force=true` and `ConnectIde ProcessId` do not show a form.

## Upgrade

| Installed with | New version |
|---|---|
| Release zip | Do steps 1, 2 and 4 of the customer install with the new zip (download and check, extract, run `Install-TcAuto.ps1` from a normal PowerShell window); step 3 and a client restart are not needed. The clients can stay open because the registration does not change: afterwards call `ReloadRuntime`, then `ConnectIde` again. Only a new `node.exe` (another Node.js version in the zip) is used after the next client restart; a `node.exe` that a running client holds is renamed aside, not overwritten. |
| Checkout | Check out / pull the commit, rerun `scripts\Install-TcAutoRuntime.ps1`, call `ReloadRuntime`, then `ConnectIde` again. |

`ReloadRuntime` belongs to the launcher (it is not in `tools.json`). It re-reads `current.json`, lets the running runtime retire its PowerShell bridge the way `ReloadModule` does (refused with `RELOAD_LIFECYCLE_BLOCKED` / `RELOAD_BUILD_REQUIRED` and nothing changes while the module holds a lifecycle block or unsaved BUILD_REQUIRED entries in memory), starts the new runtime, replays the client's `initialize` and sends `notifications/tools/list_changed`. It is refused with `RUNTIME_RELOAD_BUSY` while another tool call runs, and calls made during the reload get `RUNTIME_RELOADING`. The IDE and ADS connections are released (the IDE keeps running); IDEs this session launched stay owned by it, because the launcher passes the same owner id to every runtime (`docs/troubleshooting.md` "ReloadRuntime"). `GetStatus` -> `data.bridge.runtime` shows the version and commit that run now.

Whether a client re-reads the tool list after `notifications/tools/list_changed` is up to the client (not verified for Claude Code, Claude Desktop or Codex as of this writing); a tool or parameter that a new version adds may only show up after a client restart, while calls to existing tools already go to the new runtime. `ReloadModule ModulePath=<worktree>\src\TwinCATAutomation\TwinCATAutomation.psm1` loads the module of another commit (a git worktree of this repository) into the running bridge, then `ConnectIde` again (`docs/troubleshooting.md` "ReloadModule").

## Uninstall

- **Customer install:** close Claude Code, Claude Desktop and Codex, then run this **in the extracted folder** (keep that folder, or extract the zip again):

  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-TcAuto.ps1 -Uninstall
  ```

  It removes `tcauto` from the client files (every Claude Desktop location above) when its command is below the install root (backup first), then `node\`, `launcher\` and `runtime\`. A `tcauto` that runs another command but passes a file below the install root (e.g. `node <root>\launcher\tcauto-launcher.mjs`, a developer registration) is left (`shared`) and nothing is removed (`INSTALL_SHARED`): change that registration first, or add `-Force` to remove it and the files. Any other `tcauto` is left (`foreign`). Other files in `%LOCALAPPDATA%\TwinCATAutomation` (`ide-solutions.json`) stay; the install root itself is removed only when it is empty then. The config backups stay next to the config files. A folder a running client still uses gives `INSTALL_IN_USE` (a rename that fails with access denied or a sharing violation is retried first; the three folders share one 5 s retry time, so a client that really holds them gives the error after about 5 s, #208). `-Uninstall` cannot be combined with `-Verify` (`BAD_ARGUMENT`).
- **Developer install:** `claude mcp remove tcauto -s user` (and the Claude Desktop / Codex entries by hand), then delete `%LOCALAPPDATA%\TwinCATAutomation\launcher` and `runtime`.

## Verify

Without TwinCAT: `npm test` in `mcp-server/` must pass. A customer PC, in the extracted folder: `powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-TcAuto.ps1 -Verify`.

With the client connected, ask it to call `GetStatus`. Before any `ConnectIde` the expected answer is:

```json
{ "success": false, "error": { "code": "NOT_CONNECTED", "message": "IDE not connected", "hint": "Run ConnectIde first (optionally with SolutionPath)." }, "data": { "bridge": { "ideConnected": false, ... } } }
```

That proves Node started, `powershell.exe` spawned and the module imported. `data.bridge.runtime` says which runtime runs: `source` (`installed`), `version`, `commit`, `branch`, `dirty`, `installedAt`, `runtimeRoot`, `launcherPid` (set when the launcher started it) and `ownerIdFrom`. `data.bridge.modulePath` / `moduleCommit` / `moduleDirty` / `moduleSource` / `loadedAt` say which module file the bridge loaded and when (#41). Then: "Connect to the IDE with `C:\path\to\MyProject.sln`, build it, activate with Force and read `MAIN.nCounter`" (or a single `RunLifecycle` call).

## Tool-call trace(TCAUTO_TRACE_FILE)

預設關閉。在 client 設定的 `env` 加 `TCAUTO_TRACE_FILE=<絕對路徑>`,server 會在每個 tool call 結束後往該檔 append 一行 JSON(JSONL)。紀錄由 server 自己寫,不靠 AI 回報:用途是 AI 行為 eval(評分程式讀「呼叫了哪些工具、順序、結果」)與除錯。

```json
{ "mcpServers": { "tcauto": { "command": "...", "args": ["..."], "env": { "TCAUTO_TRACE_FILE": "C:\\Temp\\tcauto-trace.jsonl" } } } }
```

Claude Code:`claude mcp add` 時加 `-e TCAUTO_TRACE_FILE=C:\Temp\tcauto-trace.jsonl`。設定後要重連 client(launcher 把環境變數原樣傳給 runtime;`ReloadRuntime` 後是新的 runtime 行程,`sessionId` 會換)。

| 欄位 | 內容 |
|---|---|
| `ts` | 呼叫開始時間(ISO 8601,UTC) |
| `durationMs` | 呼叫耗時 |
| `seq` | 本 server 行程內的呼叫序號(呼叫開始時配號,從 1 起) |
| `parentSeq` | composite(`RunLifecycle`、`QuickRead`、`GetStatus`)內部 step 那一行填 composite 那一行的 `seq`;client 自己發出的呼叫為 `null`。評分時一律用 `parentSeq === null` 判斷「AI 呼叫了什麼」,不要靠工具名單 |
| `sessionId` | server 行程啟動時產生的 UUID |
| `tool` | 工具名稱 |
| `args` | 收到的參數原樣;超過 4,000 字元的字串截斷,結尾加 `...[truncated, N chars]` |
| `truncated` | `args` 有字串被截斷時為 `true` |
| `success` | `result.success === true` |
| `errorCode` | 失敗時的 `error.code`,成功為 `null` |
| `dataKeys` | `data` 是物件時的頂層 key 清單(不存整份 data);陣列或沒有 data 為 `null` |
| `resultChars` | client 收到的結果文字長度(step 行:該 step 結果以同樣格式序列化的長度) |
| `blockedBy` | **只出現在被確認閘門(#258)擋下、沒送到 bridge 的那一行**;沒被擋的呼叫是 `null`(每行都有這個欄位)。值是閘門名稱 `consent:<種類>`:`consent:runtime`(改 runtime 狀態的工具,目標不是 local-umrt)、`consent:install`(`InstallPackage` 附 `Approved=true`)。擋下原因看同一行的 `errorCode`(`CONSENT_DECLINED` 使用者拒絕 / `CONSENT_REQUIRED` client 無法確認)。只記閘門名稱,不記確認框內容與使用者回答 |

注意:

- 一行在呼叫**結束**時寫入,所以 composite 的 step 行排在 composite 本身那一行前面;要還原呼叫順序請依 `seq` 排序。被 server 擋下、沒送到 bridge 的呼叫(`INVALID_PARAMS`、`UNKNOWN_TOOL`、`RUNTIME_RETIRED`)也會記。composite 的 step 被確認閘門擋下(例:`RunLifecycle` 的 `EnableConfig`)時,`blockedBy` 記在該 step 那一行(`parentSeq` 指向 composite);composite 本身那一行只有 `errorCode`,`blockedBy` 為 `null`。

  範例(使用者在確認框按拒絕):`{"ts":"...","durationMs":5123,"seq":4,"parentSeq":null,"sessionId":"...","tool":"WriteVariable","args":{"Path":"MAIN.x","Value":1},"truncated":false,"success":false,"errorCode":"CONSENT_DECLINED","dataKeys":["notRun","consent","amsNetId","targetKind"],"resultChars":612,"blockedBy":"consent:runtime"}`
- 每行一次 open-append-close(`O_APPEND` 單次寫入),多個 server 行程可以寫同一個檔,用 `sessionId` 分開。
- 寫檔失敗(路徑是目錄、沒有權限、磁碟滿)不影響工具呼叫結果,只在 server stderr 記一次警告。相對路徑不接受(stderr 警告後關閉):launcher 啟動的 runtime 工作目錄是 runtime 資料夾。
- `args` 原樣保存:`WritePouCode` 的程式碼、`SolutionPath`、AmsNetId 等都會進檔。不要把 trace 檔放在會同步或分享的資料夾,用完自行刪除;檔案不會自動輪替。
- 只在 runtime 行程內記錄。launcher 自己回應、沒進 runtime 的呼叫不會記:`ReloadRuntime` 本身、reload 中的 `RUNTIME_RELOADING`、runtime 起不來(`RUNTIME_NOT_INSTALLED` 等)、runtime 在呼叫中途死掉(`RUNTIME_DIED`,進行中那筆不會寫)。
- 漏行偵測:同一 `sessionId` 內 `seq` 有斷號,代表有行沒寫進去(寫檔失敗,或 runtime 中途死掉);這份 trace 不能拿來判斷「AI 沒呼叫某工具」。

## Troubleshooting

Install problems first, then problems after the first call.

| Symptom | Cause | Fix |
|---|---|---|
| Installer stops with `INSTALL_PACKAGED_CONTEXT` | It ran inside an MSIX package (typically the Claude Desktop "Code" tab); Windows would have redirected the files into the package (#170). Nothing was written. | Run the same command from a normal PowerShell window (Start menu / Windows Terminal), then restart the clients |
| Claude Code: `tcauto` `CONNECTION_CLOSED`, while Claude Desktop lists it | An install from before #170 ran in the Claude Desktop "Code" tab: the files went to `%LOCALAPPDATA%\Packages\Claude_<id>\LocalCache\Local\TwinCATAutomation\`, which only that package sees. | Run the installer again from a normal PowerShell window and restart Claude Code |
| The client does not show tcauto after an install | Clients read their registration only at app start; Claude Desktop MSIX reads `Claude-Data\claude_*`, not `%APPDATA%\Claude` | Restart the app; check `data.clients[]` of the install result for the file that was written; `claude mcp list` for Claude Code |
| Server not listed / "failed to start" in the client | Wrong path in `args`, or (developer registration) Node < 22 | Use the absolute path to the launcher; customer install: `Install-TcAuto.ps1 -Verify`; developer: `node --version`, rerun `scripts\Install-TcAutoRuntime.ps1` (it runs `npm ci` in the runtime) |
| Installer: `PACKAGE_INCOMPLETE` | Not a complete extracted release folder | Extract the whole zip again after checking its SHA256, and run the installer from that folder |
| Installer: `NODE_IN_USE`, `INSTALL_IN_USE` | A client still runs the launcher or `node.exe` | Close Claude Code, Claude Desktop and Codex and run it again |
| First call returns `RUNTIME_NOT_INSTALLED` | No `runtime\current.json` below the install root the launcher uses (`TCAUTO_RUNTIME_ROOT`, else the parent of the launcher folder) | Run `Install-TcAuto.ps1` (customer) or `scripts\Install-TcAutoRuntime.ps1` (developer) |
| A call returns `RUNTIME_DIED` | The runtime process (node) exited during the call | The next call starts it again; `ConnectIde` again; the launcher stderr (client log) has the reason |
| Every call returns `MODULE_IMPORT_FAILED`, stderr "The cloud sync provider failed to validate the downloaded data" | The runtime or module is read from a cloud-synced folder whose files are not on the device (#162) | Use the installed runtime and the launcher (above), which live in `%LOCALAPPDATA%`; extract the zip outside OneDrive |
| Every call returns `MODULE_IMPORT_FAILED` | `powershell.exe` not found (custom `TWINCAT_MCP_POWERSHELL`) or `TWINCAT_MODULE_PATH` wrong | Check both paths; run `powershell.exe -NoProfile -Command "Import-Module '<path>\TwinCATAutomation.psm1'"` by hand |
| Call returns `BRIDGE_TIMEOUT` | A DTE call was blocked (usually a modal dialog in XAE) longer than the tool timeout; the bridge was killed and all IDE/ADS state is lost. The XAE process keeps running | Follow `error.hint`: it names the IDE from `data.lastIde` (`ideProcessId`, `selectedBy`, `ownedBySession`). `ownedBySession` true (this session launched or took over the IDE, [#237](https://github.com/Lance0901/AI-TwinCAT-Skill/issues/237)): dismiss the dialog, or `taskkill /PID <pid> /T /F` after asking the user; first confirm with `Get-Process -Id <pid> | Select-Object Name, StartTime` that the pid is still a TcXaeShell.exe / devenv.exe started before this session's `ConnectIde` (a pid can be reused; `DisconnectIde Quit=true Kill=true` cannot kill it after a bridge restart, [#269](https://github.com/Lance0901/AI-TwinCAT-Skill/issues/269)). `ownedBySession` false or missing: not this session's IDE, dismiss the dialog (or ask the user to), never kill it. Then `ConnectIde` again and `GetIdeModalDialog` before retrying `BuildProject` / `EnableConfig` |
| Call returns `BRIDGE_DIED` | The PowerShell child exited | Next call restarts it; `ConnectIde` again (`data.lastIde` / hint as for `BRIDGE_TIMEOUT`). Check the log for the stderr line |
| Client reports a timeout (often around 60 s) on `ConnectIde`, `BuildProject`, `EnableConfig` or `RunLifecycle`, no `error.code` from the server | The MCP client's own request timeout (SDK default 60 s) is shorter than the call; the server keeps running and finishes the call anyway | Claude Code: set `MCP_TOOL_TIMEOUT` in milliseconds (e.g. `MCP_TOOL_TIMEOUT=900000`). SDK clients: pass `onprogress` + `resetTimeoutOnProgress: true` so the server's `notifications/progress` (every 10 s) keeps the request alive. Codex: `ConnectIde` of 66 s was not interrupted with the default timeout (實測 2026-11-08, codex-cli 0.167.0). Claude Desktop: not configurable as of this writing; use the fine-grained tools instead of `RunLifecycle` and check `GetStatus` afterwards. Details: [mcp-server/README.md](../mcp-server/README.md#client-request-timeout) |
| Codex asks for approval on every tool call; `codex exec` fails with `MCP tool call requires approval, but approval policy is never` | Default behavior of Codex (實測 2026-11-08 / 2026-11-12, codex-cli 0.167.0); with `approval_policy="never"` only approved tools run (#250) | See "First call and client settings" for `default_tools_approval_mode` / per-tool `approval_mode` and the risk |
| `RunLifecycle` / `EnableConfig` returns `ACTIVATE_FAILED` (target without TARGETINFO) | XAE's Check config failed: the solution platform differs from the target platform (a UmRT / Usermode Runtime needs `TwinCAT OS (x64)` on 4026; measured 2026-10-21 on 4026 XAE). `EnableConfig` compares the platforms first, but a target that answers TARGETINFO with ADS 0x702 (the runtime of TwinCAT 3.1.4026.21-22) reports none, so without `Platform` the check is skipped (`data.platformCheck` = `skipped`, `data.warning`) | `EnableConfig {"Force": true, "Platform": "TwinCAT OS (x64)"}` (switches + rebuilds), or `SetTarget {"AmsNetId": "<id>", "Platform": "TwinCAT OS (x64)"}` / `RunLifecycle` with `Platform`, then `BuildProject` + `EnableConfig` |
| `RUNTIME_CRASHED` or `LIFECYCLE_BLOCKED` | The local UmRT service `TcSystemServiceUm` disappeared during Config/Activate (#21), or an earlier failure left a block | Stop and report `data`; restart the UmRT, then `ClearLifecycleBlock` with a reason after the user agreed (`docs/troubleshooting.md` "RUNTIME_CRASHED", "LIFECYCLE_BLOCKED") |
| `ConnectIde` / `GetProjectVersion` (4024 project) say `PROGID_REQUIRED` and the hint names `Install-TcPackage` | The Remote Manager of exactly the project version is not installed (`data.remoteManagerInstall`, #229) | `GetPackageInfo PackageId=["TwinCAT.StandardRM.XAE"]` lists the installed and feed versions (read-only, needs the TwinCAT Package Manager CLI `tcpkg`, else `TCPKG_NOT_FOUND`); `InstallPackage PackageId=TwinCAT.StandardRM.XAE Version=<ver>` only returns the plan (`data.executed=false`, `data.plan`, one-time `data.planToken`): show `data.plan` to the user, and only after the user agreed call it again with `Approved=true PlanToken=<data.planToken>` (without a valid token: `TCPKG_PLAN_REQUIRED`; tokens live only in the running server process). The install needs an elevated (administrator) server and no running TcXaeShell / Visual Studio (`TCPKG_ELEVATION_REQUIRED`, `TCPKG_IDE_RUNNING`); feeds and the myBeckhoff account are set up by the user. See troubleshooting.md "tcpkg" |
| Any other `error.code` | Module error, passed through unchanged | Follow `error.hint`; code table in [troubleshooting.md](troubleshooting.md) |

**Where the logs are.** The server's stderr (with the launcher, the launcher's and the runtime's) goes to the client's own log:

| Client | Log |
|---|---|
| Claude Desktop, MSIX package | `%LOCALAPPDATA%\Claude\Logs\mcp-server-tcauto.log`; `main.log` in the same folder has `[LocalMcpServerManager] Connected to tcauto (N tools)` (the older `%LOCALAPPDATA%\Claude-Data\claude_<publisherId>\logs\` is no longer written; 實測 2026-11-07, Windows 11, Claude Desktop MSIX 4.23118.0.0) |
| Claude Desktop, standard install | `%APPDATA%\Claude\logs\mcp-server-tcauto.log` |

Set `TWINCAT_MCP_VERBOSE=1` in the config `env` to also get `Write-Verbose` output from the module as `debug` log notifications.
