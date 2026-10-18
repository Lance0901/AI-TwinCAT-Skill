# TcAuto MCP Setup

Run the `TwinCATAutomation` module as the TcAuto MCP server so Claude Desktop, Claude Code or any MCP client can call the 35 cmdlets (plus 4 composite tools) as tools, with IDE and ADS state kept between calls. Full reference: [mcp-server/README.md](../mcp-server/README.md).

## Prerequisites

- Windows 10/11 with TwinCAT 3.1 XAE (verified on 4026)
- Node.js >= 18 (`node --version`)
- Windows PowerShell 5.1 at `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe` (`pwsh` is not used)
- This repo cloned locally; the module stays at `src/TwinCATAutomation/TwinCATAutomation.psm1`

## Install

```powershell
cd mcp-server
npm install
npm test          # unit tests with a mock bridge, no TwinCAT needed
```

## Configure

### Claude Desktop

Edit `%APPDATA%\Claude\claude_desktop_config.json` and restart Claude Desktop:

```json
{
  "mcpServers": {
    "tcauto": {
      "command": "node",
      "args": ["C:\\path\\to\\2026-AI-TwinCAT-Skill\\mcp-server\\index.js"],
      "env": {
        "TWINCAT_MODULE_PATH": "C:\\path\\to\\2026-AI-TwinCAT-Skill\\src\\TwinCATAutomation\\TwinCATAutomation.psm1"
      }
    }
  }
}
```

`TWINCAT_MODULE_PATH` is optional when `index.js` runs from inside the repo (default: `../src/TwinCATAutomation/TwinCATAutomation.psm1`).

### Claude Code

The repo root ships `.mcp.json`, so the server is available in any Claude Code session opened in this repo:

```json
{ "mcpServers": { "tcauto": { "command": "node", "args": ["mcp-server/index.js"] } } }
```

Two things this relies on:

- `mcp-server/index.js` is a **relative** path: it only resolves when the client's working directory is the repo root, i.e. Claude Code was started in `2026-AI-TwinCAT-Skill\` (not in a subfolder, and not with the repo added as a secondary directory). Anywhere else, register the server with an absolute path as shown below.
- `npm install` must have been run in `mcp-server/` first (see [Install](#install)); otherwise the server fails to start with `Cannot find package '@modelcontextprotocol/sdk'` and the client lists it as failed.

From another project, register it with an absolute path:

```powershell
claude mcp add tcauto -- node "C:\path\to\2026-AI-TwinCAT-Skill\mcp-server\index.js"
```

### Other MCP clients

Any client that launches stdio servers: command `node`, args `["C:\\path\\to\\2026-AI-TwinCAT-Skill\\mcp-server\\index.js"]`, optional environment variables from the table in [mcp-server/README.md](../mcp-server/README.md#environment-variables).

## Verify

Without TwinCAT: `npm test` in `mcp-server/` must pass.

With Claude Desktop (or Claude Code) connected, ask it to call `GetStatus`. Before any `ConnectIde` the expected answer is:

```json
{ "success": false, "error": { "code": "NOT_CONNECTED", "message": "IDE not connected", "hint": "Run ConnectIde first (optionally with SolutionPath)." }, "data": { "bridge": { "ideConnected": false, ... } } }
```

That proves Node started, `powershell.exe` spawned and the module imported. Then: "Connect to the IDE with `C:\path\to\MyProject.sln`, build it, activate with Force and read `MAIN.nCounter`" (or a single `RunLifecycle` call).

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Server not listed / "failed to start" in the client | Node < 18, wrong path in `args`, or `npm install` not run | `node --version`; use the absolute path to `mcp-server/index.js`; run `npm install` in `mcp-server/` |
| Every call returns `MODULE_IMPORT_FAILED` | `powershell.exe` not found (custom `TWINCAT_MCP_POWERSHELL`) or `TWINCAT_MODULE_PATH` wrong | Check both paths; run `powershell.exe -NoProfile -Command "Import-Module '<path>\TwinCATAutomation.psm1'"` by hand |
| Call returns `BRIDGE_TIMEOUT` | A DTE call was blocked (usually a modal dialog in XAE) longer than the tool timeout; the bridge was killed and all IDE/ADS state is lost. The XAE process keeps running | Follow `error.hint`: it names the IDE from `data.lastIde` (`ideProcessId`, `selectedBy`). An IDE the server launched: `taskkill /PID <pid> /T /F`; one you opened: dismiss the dialog. Then `ConnectIde` again and `GetIdeModalDialog` before retrying `BuildProject` / `EnableConfig` |
| Call returns `BRIDGE_DIED` | The PowerShell child exited | Next call restarts it; `ConnectIde` again (`data.lastIde` / hint as for `BRIDGE_TIMEOUT`). Check the log for the stderr line |
| Client reports a timeout (often around 60 s) on `ConnectIde`, `BuildProject`, `EnableConfig` or `RunLifecycle`, no `error.code` from the server | The MCP client's own request timeout (SDK default 60 s) is shorter than the call; the server keeps running and finishes the call anyway | Claude Code: set `MCP_TOOL_TIMEOUT` in milliseconds (e.g. `MCP_TOOL_TIMEOUT=900000`). SDK clients: pass `onprogress` + `resetTimeoutOnProgress: true` so the server's `notifications/progress` (every 10 s) keeps the request alive. Claude Desktop: not configurable as of this writing; use the fine-grained tools instead of `RunLifecycle` and check `GetStatus` afterwards. Details: [mcp-server/README.md](../mcp-server/README.md#client-request-timeout) |
| Any other `error.code` | Module error, passed through unchanged | Follow `error.hint`; code table in [troubleshooting.md](troubleshooting.md) |

Claude Desktop writes the server's stderr to `%APPDATA%\Claude\logs\mcp-server-tcauto.log`. Set `TWINCAT_MCP_VERBOSE=1` in the config `env` to also get `Write-Verbose` output from the module as `debug` log notifications.
