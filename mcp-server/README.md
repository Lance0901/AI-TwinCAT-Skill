# TcAuto MCP

> **TL;DR(繁中)**:把 `TwinCATAutomation` PowerShell 模組的 36 個 cmdlet 加 4 個複合 tool,透過 MCP(stdio)暴露給 Claude Desktop、Claude Code 或任何 MCP client。Server 只開一個常駐的 Windows PowerShell 5.1(STA)子程序,IDE COM 參考與 ADS 連線在呼叫之間都保留,所以 `ConnectIde` → `BuildProject` → `EnableConfig` → `ReadVariable` 可以當成一連串獨立的 tool call 來用。安裝:`cd mcp-server && npm install`;設定見下方 Configure;錯誤碼表沿用 [docs/troubleshooting.md](../docs/troubleshooting.md)。

Exposes the `TwinCATAutomation` module (36 cmdlets) plus 4 composite tools over the Model Context Protocol (stdio transport). One long-lived Windows PowerShell 5.1 (STA) child process holds the module's COM (DTE, `ITcSysManager`) and ADS state, so tool calls are stateful across the whole session: connect once, then build, activate and read variables as separate calls.

## Requirements

| Requirement | Notes |
|---|---|
| Windows 10/11 | COM Automation Interface and `TwinCAT.Ads.dll` are Windows-only |
| Node.js >= 18 | `node --version` |
| Windows PowerShell 5.1 | `powershell.exe`, **not** `pwsh`. Default path `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`; override with `TWINCAT_MCP_POWERSHELL` |
| TwinCAT 3.1 XAE | Verified on 4026 (32-bit XAE Shell, 64-bit XAE Shell, VS2022 integration); 4024 projects open in a 4026 XAE |
| Module path | `src/TwinCATAutomation/TwinCATAutomation.psm1`; resolved relative to the server by default, override with `TWINCAT_MODULE_PATH` |

## Install

```powershell
cd mcp-server
npm install
npm test          # unit tests against a mock bridge, no TwinCAT needed
```

## Configure

### Claude Desktop

`%APPDATA%\Claude\claude_desktop_config.json`:

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

`TWINCAT_MODULE_PATH` can be omitted when the server runs from inside this repo; it then defaults to `../src/TwinCATAutomation/TwinCATAutomation.psm1` relative to `mcp-server/`. Restart Claude Desktop after editing the file.

### Claude Code

Project-level `.mcp.json` at the repo root (already checked in):

```json
{ "mcpServers": { "tcauto": { "command": "node", "args": ["mcp-server/index.js"] } } }
```

Or register it from the CLI:

```powershell
claude mcp add tcauto -- node mcp-server/index.js
```

### Any other MCP client

Generic stdio launch: command `node`, argument `<repo>/mcp-server/index.js`, optional `env` from the table below. The server speaks MCP over stdin/stdout and logs only to stderr.

## Environment variables

All variables are read in `lib/config.js`.

| Variable | Default | Purpose |
|---|---|---|
| `TWINCAT_MODULE_PATH` | `<repo>/src/TwinCATAutomation/TwinCATAutomation.psm1` | Module imported by the PowerShell bridge |
| `TWINCAT_MCP_POWERSHELL` | `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe` | PowerShell 5.1 executable to spawn |
| `TWINCAT_MCP_VERBOSE` | unset | `1` forwards `Write-Verbose` output as `debug` log notifications and echoes bridge stderr to the server's stderr |
| `TWINCAT_MCP_EAGER` | unset | `1` starts the PowerShell bridge at server start instead of on the first tool call |
| `TWINCAT_MCP_TOOLS_JSON` | `<mcp-server>/tools.json` | Alternate tool catalog |
| `TWINCAT_MCP_PROGRESS_INTERVAL_MS` | `10000` | How often `notifications/progress` is sent during a tool call when the client supplied a `progressToken` (see [Client request timeout](#client-request-timeout)) |
| `TWINCAT_MCP_MODAL_PROBE` | on | `0` / `false` / `off` / `no` disables the modal-dialog probe that watches the IDE during `BuildProject`, `EnableConfig`, `PlcLogin`, `SendPlcProgram`, `RunTestCycle`, `OpenProject`, `ConnectIde` and returns `IDE_MODAL_DIALOG` instead of waiting for `BRIDGE_TIMEOUT` |
| `TWINCAT_MCP_MODAL_PROBE_INTERVAL_SEC` | `5` | Probe scan interval in seconds (1..60); the first scan happens after one interval and a dialog is reported after `TWINCAT_MCP_PROBE_CONFIRM_SCANS` consecutive scans with the same title |
| `TWINCAT_MCP_PROBE_CONFIRM_SCANS` | `2` | Consecutive scans (1..10) that must see the same kill-worthy dialog before the probe reports it |
| `TWINCAT_MCP_PROBE_SCAN_SCRIPT` | `<dir of TWINCAT_MODULE_PATH>/Private/Get-TcIdeModalDialog.ps1` | File the probe dot-sources for `$script:TcUiaDialogScan` (the module's UIA dialog scan, single source of truth); the probe exits with an error if it is missing |

Testing only (replace the `powershell.exe` spawn with any command, e.g. the mock bridge in `test/fixtures/`):

| Variable | Purpose |
|---|---|
| `TWINCAT_MCP_BRIDGE_COMMAND` | Executable to spawn instead of `powershell.exe` |
| `TWINCAT_MCP_BRIDGE_ARGS` | JSON array of arguments for that executable |
| `TWINCAT_MCP_PROBE_COMMAND` | Executable to spawn instead of `powershell.exe bridge/modal-probe.ps1` (e.g. `test/fixtures/mock-modal-probe.js`) |
| `TWINCAT_MCP_PROBE_ARGS` | JSON array of arguments for that executable; the probe argument tail `-ProcessId N -IntervalSec S -ConfirmScans C -ScanScript F [-MainHwnd H] [-MaxLifetimeSec L]` is appended |
| `TWINCAT_MCP_SKIP_PID_CHECK` | `1` skips the `tasklist` check that `data.lastIde.ideProcessId` is still a live `TcXaeShell.exe` / `devenv.exe` before it is named in a `BRIDGE_TIMEOUT` / `BRIDGE_DIED` hint (mock IDE pids) |

Flags accept `1`, `true`, `yes`, `on` (case-insensitive).

## Tools (39)

Tool names equal the CLI action names (`ConnectIde` = `Connect-TcIde`). Parameters are the cmdlet parameters, passed as JSON (`switch` → boolean, `string[]` → array, `hashtable` → object; object keys must be non-empty and must not differ only in case, since PowerShell 5.1 cannot convert such JSON). `Timeout` is the per-call limit after which the bridge is killed; for tools with `TimeoutSec` / `TimeoutMs` / `DurationMs` parameters it grows to at least that value plus 30 s, capped at 2 h (schema `minimum` / `maximum` are enforced first).

### Composite tools

| Tool | Cmdlet | Required params | Timeout | Description |
|---|---|---|---|---|
| `RunLifecycle` | composite | — | 1500 s | `ConnectIde` → `SetTarget` (only with `TargetAmsNetId`; without a saved target in the .tsproj, `EnableConfig` otherwise activates on the IDE default local runtime) → `BuildProject` (unless `SkipBuild`) → `EnableConfig` (`Force`; `NoLogin`, `TimeoutSec` 10..3600 optional) → `ConnectAds`; stops at the first failing step, `data.steps[]` / `data.failedStep` tell where. **Destructive** (`annotations.destructiveHint`): restarts TwinCAT, downloads and starts the PLC program; confirm with the user first |
| `QuickRead` | composite | `Path` | 120 s | `ReadVariable`; on `NOT_CONNECTED` runs `ConnectAds` (auto-detected AmsNetId) and reads again; `data.connectedOnDemand`. Read-only |
| `GetStatus` | composite | — | 120 s | Bridge state (IDE/ADS connected, AmsNetId) + `GetIdeInfo` + `GetSystemState` + `GetPlcState`; `NOT_CONNECTED` before `ConnectIde`. Read-only |
| `GetIdeModalDialog` | composite (module-private `Get-TcIdeModalDialog`) | — | 90 s | Probe the XAE window for a blocking modal dialog; `data.dialog` is `null` or `{title, text, kind, reloadTarget, hwnd, buttons}` (`kind` `reload-prompt` = the "File has been changed outside the environment. Reload the new file?" prompt, `reloadTarget` `file`: a file open in an editor was changed on disk; or the XAE "The project file ... has been modified outside of TwinCAT XAE. Do you want to reload the project?" prompt, `reloadTarget` `project`: a `.plcproj` was rewritten on disk. For both call `ResetSolution` (it answers Yes to the project prompt and only reconnects; it dismisses the file prompt and reopens the solution). Else `unknown`, `reloadTarget` `null`. `buttons` = `[{id, name}]` of a Win32 message box, by control id: 1 OK, 2 Cancel, 6 Yes, 7 No). Uses the IDE pid from `ConnectIde`; after a `BRIDGE_TIMEOUT` / `BRIDGE_DIED` it falls back to `data.lastIde.ideProcessId`, and `ProcessId` (integer ≥ 1) overrides both. Read-only |

Tools carry MCP `annotations` (`readOnlyHint`, `destructiveHint`, …) in `tools/list` when `tools.json` defines them; the composites above set their own.

### Connection

| Tool | Cmdlet | Required params | Timeout | Description |
|---|---|---|---|---|
| `ConnectIde` | `Connect-TcIde` | — | 180 s | Attach to a running XAE / VS (ROT), launch one if none; optional `SolutionPath`, `ProgId`, `NoLaunch`; returns `ideProcessId`, `amsNetId`, `selectedBy`, `ownedBySession` (true when this session launched the IDE: `DisconnectIde Kill=true` is allowed) |
| `DisconnectIde` | `Disconnect-TcIde` | — | 120 s | Release DTE/COM references; `Quit=true` also closes the IDE (only one that `ConnectIde` launched). With `Quit=true` a modal dialog is checked first (→ `IDE_QUIT_FAILED` with `data.dialog`, `data.quit=false`, `data.disconnected=false`: nothing attempted and nothing released, the connection stays, so a reload-prompt can be cleared with `ResetSolution` and `DisconnectIde Quit=true` retried; otherwise `Kill=true` or `taskkill`); a failed `DTE.Quit` is `IDE_QUIT_FAILED` too (`success:false`, the IDE still runs, `data.ideProcessId`). After a failure the bridge keeps the IDE pid / `selectedBy`, so `Quit=true Kill=true` can follow directly without `ConnectIde`. `Kill=true` (only with `Quit=true`) kills the IDE process in those cases (`data.killed`; the pid must still be a `TcXaeShell` / `devenv` process with the start time `ConnectIde` saw, else it is treated as stale and not killed; a pid that already exited gives `alreadyExited: true`), but only an IDE this session launched (`data.ownedBySession: true`, which stays true after `ResetSolution`'s internal reconnect even though `selectedBy` then says `solution-match`); otherwise `IDE_NOT_OWNED` and nothing is killed. `Kill` without `Quit` → `INVALID_PARAMS` |
| `ResetSolution` | `Reset-TcSolution` | — | 180 s | XAE project prompt for a rewritten `.plcproj` ("The project file ... has been modified outside of TwinCAT XAE. Do you want to reload the project?", `GetIdeModalDialog` `reloadTarget: "project"`): answered **Yes** by control id (any UI language), XAE reloads the project, only `ConnectIde` runs again (`data.answeredYes: true`, `data.reopenedSolution: false`). Otherwise: dismiss the reload prompt if up, `Documents.CloseAll` (no save), `Solution.Close`, `Solution.Open` of the same `.sln` on the same IDE, `ConnectIde` again (20-25 s measured): XAE reloads every project file from disk. Use after `.TcPOU` / `.plcproj` files were changed on disk while open in an XAE editor (otherwise the modal "File has been changed outside the environment" blocks every call); a file not open in an editor is picked up within ~5 s without it. Optional `SolutionPath`, `TimeoutSec`; data has `dismissedReloadPrompt`, `reloadTarget` (`file` / `project` / null), `answeredYes`, `reopenedSolution`, `closedDocuments`, `sameIde`, `selectedBy`, `ownedBySession`, `openSec`, `connectSec`, `totalSec`; any other modal dialog returns `IDE_MODAL_DIALOG` |
| `GetIdeInfo` | `Get-TcIdeInfo` | — | 120 s | IDE version, edition, open solution; cheap connectivity check |
| `ConnectAds` | `Connect-TcAds` | — | 120 s | Open ADS; `AmsNetId` auto-detected from the IDE target, `Port` default 851 |
| `DisconnectAds` | `Disconnect-TcAds` | — | 120 s | Close ADS and forget the endpoint (disables auto-reconnect) |

### Project

| Tool | Cmdlet | Required params | Timeout | Description |
|---|---|---|---|---|
| `NewProject` | `New-TcProject` | `Name` | 120 s | Create a solution with a PLC project and MAIN |
| `OpenProject` | `Open-TcProject` | `Path` | 180 s | Open a `.sln` and wait until the TwinCAT project is loaded |
| `GetProjectTree` | `Get-TcProjectTree` | — | 120 s | Project tree as JSON incl. `<Plc> Project` POUs/DUTs/GVLs; `Depth` (1-10, default 4), `PlcOnly` (TIPC subtree only) |
| `AddPou` | `Add-TcPou` | `Name`, `Type` | 120 s | Add a Program / FunctionBlock / Function |
| `AddGvl` | `Add-TcGvl` | `Name` | 120 s | Add a Global Variable List |
| `AddDut` | `Add-TcDut` | `Name`, `DutType` | 120 s | Add a STRUCT / ENUM / ALIAS / UNION |
| `AddLibrary` | `Add-TcLibrary` | `Name` | 120 s | Add a library reference |
| `SetTarget` | `Set-TcTarget` | `AmsNetId` | 120 s | Set the target system AmsNetId |

### Code

| Tool | Cmdlet | Required params | Timeout | Description |
|---|---|---|---|---|
| `GetPouCode` | `Get-TcPouCode` | `PouName` | 120 s | Read declaration and implementation of a POU (`PouPath` optional, auto-detected; format `TIPC^<Plc>^<Plc> Project^POUs^<Pou>`; `POU_NOT_FOUND` if missing) |
| `WritePouCode` | `Write-TcPouCode` | `PouName` | 120 s | Write `Declaration` and/or `Implementation` into a POU (`PouPath` optional, auto-detected) |

### Build and deploy

| Tool | Cmdlet | Required params | Timeout | Description |
|---|---|---|---|---|
| `BuildProject` | `Build-TcProject` | — | 600 s | Build and wait; on `BUILD_FAILED` read `data.errorItems[]` (description/file/line from the Error List) |
| `GetBuildErrors` | `Get-TcBuildErrors` | — | 120 s | Read the XAE Error List via UI Automation: `errors[]` and `warnings[]` (`IncludeWarnings` defaults to true), `IncludeMessages` adds `messages[]`; counts also parsed from zh-TW button names |
| `EnableConfig` | `Enable-TcConfig` | — | 600 s | Activate without dialogs; `Force=true` runs Config → Activate → Run → Login+Download → PLC Run, `NoLogin=true` stops after system Run; `TimeoutSec` default 120 |
| `PlcLogin` | `Enter-TcPlcOnline` | — | 300 s | Login(3) + download, no dialogs |
| `PlcLogout` | `Exit-TcPlcOnline` | — | 120 s | Logout, runtime keeps running |
| `SendPlcProgram` | `Send-TcPlcProgram` | — | 300 s | Download the compiled program (alias of `PlcLogin`) |

### Runtime

| Tool | Cmdlet | Required params | Timeout | Description |
|---|---|---|---|---|
| `GetSystemState` | `Get-TcSystemState` | — | 120 s | TwinCAT Run/Config over port 10000; pass the `AmsNetId` from `ConnectIde` for a non-local target |
| `SetSystemState` | `Set-TcSystemState` | `State` | 180 s | Switch Run/Config via ADS WriteControl and poll until reached |
| `GetPlcState` | `Get-TcPlcState` | — | 120 s | PLC runtime state on the connected ADS port |
| `SetPlcState` | `Set-TcPlcState` | `State` | 180 s | Run / Stop / Reset and wait; **Reset kills `TcSystemServiceUm` on UmRT** |

### ADS variables

| Tool | Cmdlet | Required params | Timeout | Description |
|---|---|---|---|---|
| `ReadVariable` | `Read-TcVariable` | `Path` (array) | 120 s | Read one or more symbols; TIME/DATE types return the IEC literal (`"T#6s"`) plus the raw integer in `ms`/`ns`/`unix`, enums the integer plus `name`, STRUCTs raw bytes plus `size`; auto-reconnects after `EnableConfig` (`data.reconnected`) |
| `WriteVariable` | `Write-TcVariable` | `Path`, `Value` | 120 s | Write one symbol; JSON value converted to the PLC type (TIME/TOD: `"T#6s"` or integer ms, DATE/DT: `"DT#2026-10-20-12:30:00"`/ISO 8601 or seconds, enum: integer or member name); `data.written` is the converted value (normalized literal for time types); STRUCT/ARRAY -> `TYPE_MISMATCH` |
| `WatchVariable` | `Watch-TcVariable` | `Path` | 120 s | Poll one or more paths every `IntervalMs` for `DurationMs`, or until `Until` (`"<Path> <op> <value>"`, op `== != > < >= <=`) holds / `UntilTimeoutMs`; only the last `KeepLast` samples are returned; samples carry the `ReadVariable` conversion (`ms`/`ns`/`unix`, `name`) |
| `GetSymbols` | `Get-TcSymbols` | — | 120 s | List PLC symbols, optional `Filter` substring |

### I/O

| Tool | Cmdlet | Required params | Timeout | Description |
|---|---|---|---|---|
| `IoScan` | `Invoke-TcIoScan` | — | 180 s | Scan EtherCAT devices into the I/O tree (target in Config) |
| `GetIoTree` | `Get-TcIoTree` | — | 120 s | Current I/O device tree (TIID) as JSON |
| `SetVariableLink` | `Set-TcVariableLink` | `PlcVariable`, `IoChannel` | 120 s | Link a PLC variable to an I/O channel |

### Testing

| Tool | Cmdlet | Required params | Timeout | Description |
|---|---|---|---|---|
| `NewTestCase` | `New-TcTestCase` | `Name`, `Assertions` | 120 s | Build a test case object (`Setup` / `Teardown` writes, `Assertions` `{Path, Operator, Expected}`); no IDE/PLC access |
| `RunTest` | `Invoke-TcTest` | `TestCase` | 120 s | Run one test case against the connected PLC |
| `RunTestCycle` | `Invoke-TcTestCycle` | `TestCases` | 900 s | Build → Activate → Login → run all tests → Stop (`SkipBuild`, `KeepRunning`) |

## Result format

Every call returns a `CallToolResult` whose `content[0].text` is the module's raw JSON (`ConvertTo-Json -Depth 10`), `isError = !success`, and `structuredContent` is the same object:

```json
{ "success": true, "data": { "path": "MAIN.nCounter", "value": 42, "type": "UDINT", "reconnected": false } }
{ "success": false, "error": { "code": "ADS_PORT_NOT_FOUND", "message": "...", "hint": "..." }, "data": { ... } }
```

Every executed call also gets `data.seq` / `data.startedAt` / `data.finishedAt`. Tool calls sent in parallel in one turn arrive in no guaranteed order; the server runs them one at a time in arrival order, so use `data.seq` to see the real order. PowerShell cmdlet names inside `error.hint` (e.g. `Connect-TcIde -SolutionPath <sln>`) are rewritten to tool names (`ConnectIde SolutionPath=<sln>`) before the result is returned.

Module error codes and `error.hint` pass through (apart from that rewrite); the table is in [docs/troubleshooting.md](../docs/troubleshooting.md). Codes added by the server or bridge:

| Code | Source | Meaning / next step |
|---|---|---|
| `INVALID_PARAMS` | server / bridge | Unknown parameter, wrong JSON type, missing required parameter, or a `ValidateSet` / `ValidateRange` violation |
| `UNKNOWN_TOOL` | server | Tool name not in `tools.json` or the composite list |
| `INVALID_CMDLET` | bridge | Cmdlet not exported by the module (names are never evaluated as script; not reachable through a well-formed `tools.json`) |
| `BRIDGE_TIMEOUT` | server | Call exceeded its timeout; the PowerShell child was **killed and restarted, all IDE/ADS state is lost**. `data.lastIde` is the last successful `ConnectIde` (`{ideProcessId, selectedBy, solution, ideMainHwnd}`, or `null`) and `data.bridgeRestarted` is `true`; `error.hint` names that IDE (see below) |
| `BRIDGE_DIED` | server | The child exited while idle or mid-call; the next call restarts it. Same `data.lastIde` / `data.bridgeRestarted` / hint as `BRIDGE_TIMEOUT`. A message ending in `this call was not executed; safe to retry after reconnecting` means the call was still queued (behind a timed-out or crashed call, or during shutdown) and never reached PowerShell |
| `IDE_MODAL_DIALOG` | server (probe) | Also returned by the module itself when its pre-call check sees a dialog. Server-side variant: the modal-dialog probe saw a kill-worthy dialog (modal or Win32 `#32770`, IDE main window blocked: disabled, `BlockedByModalWindow`, or owning a modal / `#32770` child; no progress bar; same title in two consecutive scans) in the IDE while `BuildProject` / `EnableConfig` / `PlcLogin` / `SendPlcProgram` / `RunTestCycle` / `OpenProject` / `ConnectIde` was blocked (`ConnectIde` to a different `SolutionPath` only logs it, see Known limits); `message` is `<title> \| <first 200 chars of text>`. The bridge was killed (all IDE/ADS state lost) unless the call was still queued. `data.dialogTitle`, `data.dialogText`, `data.ideProcessId` (the watched pid), `data.lastIde` (snapshot at detection, `null` during `ConnectIde`), `data.bridgeRestarted`; the hint says to dismiss the dialog (or `taskkill` an IDE this server launched, after asking the user), then `ConnectIde` |
| `IDE_QUIT_FAILED` | module | `DisconnectIde Quit=true` could not quit the IDE: modal dialog (`data.dialog`, quit not attempted, connection kept: `reload-prompt` → `ResetSolution` then quit again) or `DTE.Quit` rejected (COM references released); the IDE process (`data.ideProcessId`) still runs, `data.quitError` says why. Use `GetIdeModalDialog` / `ResetSolution`, `DisconnectIde Quit=true Kill=true` for an IDE this session launched (`data.ownedBySession`), else `taskkill` that pid. The pid is kept, so `Kill=true` can follow without reconnecting. Also returned when `Kill=true` could not make the process exit within 10 s |
| `IDE_NOT_OWNED` | module | `DisconnectIde Quit=true Kill=true` on an IDE this session did not launch (`data.selectedBy` is not `launched`): nothing is killed. Kill it yourself (`data.ideProcessId`) if that is really intended |
| `CANCELLED` | server | The client cancelled the request (`notifications/cancelled`) while the call was still queued; nothing was executed. A call already handed to PowerShell cannot be cancelled and returns its real result |
| `MODULE_IMPORT_FAILED` | server / bridge | `powershell.exe` could not be spawned, or `Import-Module` of `TWINCAT_MODULE_PATH` failed (check the path and that `powershell.exe` is 5.1) |
| `INTERNAL_ERROR` | server | Unexpected exception inside the server or a composite step |
| `NO_RESULT` | bridge | The cmdlet emitted no object with a `success` property |
| `INVALID_REQUEST` | bridge | Malformed bridge request (not reachable through the MCP server) |

`BRIDGE_TIMEOUT` and `BRIDGE_DIED` keep the identity of the IDE the bridge was talking to, because the restarted bridge no longer knows it (the IDE itself keeps running, usually behind a modal dialog). The server remembers `data.ideProcessId` / `selectedBy` / `solution` of the last successful `ConnectIde` (also when it ran inside `RunLifecycle`) plus the IDE main window handle (`ideMainHwnd`, read with one `op:"state"` right after it, used by the modal-dialog probe), forgets it as soon as a new `ConnectIde` starts and on a successful `DisconnectIde`. Before the pid goes into a hint it is checked with `tasklist`: it must still be a running `TcXaeShell.exe` / `devenv.exe` (both the 32-bit and the 64-bit TcXaeShell, ProgId `TcXaeShell.DTE.15.0` / `.17.0`, run as `TcXaeShell.exe`; Visual Studio 2022 is `devenv.exe`), otherwise `lastIde` is dropped (`null`) and the generic hint is used, so a recycled pid is never offered for `taskkill`. The hint depends on who opened the IDE:

| `data.lastIde` | `error.hint` |
|---|---|
| `selectedBy == "launched"` | `The IDE (pid N, launched by this server) is probably blocked by a modal dialog. Kill it with `taskkill /PID N /T /F`, then ConnectIde again. Unsaved changes in that IDE will be lost; ask the user before killing it.` |
| any other `selectedBy` | `The IDE (pid N) was opened by the user; check its window for a modal dialog, dismiss it, then ConnectIde again.` |
| `null` (no `ConnectIde` yet, or the pid is no longer an XAE) | the generic hint: check `GetIdeModalDialog` after `ConnectIde`, then `ConnectIde` again |

```json
{ "success": false,
  "error": { "code": "BRIDGE_TIMEOUT", "message": "Build-TcProject did not finish within 600000 ms; PowerShell bridge killed",
             "hint": "The IDE (pid 18324, launched by this server) is probably blocked by a modal dialog. Kill it with `taskkill /PID 18324 /T /F`, then ConnectIde again. Unsaved changes in that IDE will be lost; ask the user before killing it." },
  "data": { "lastIde": { "ideProcessId": 18324, "selectedBy": "launched", "solution": "C:\\path\\to\\MyProject.sln", "ideMainHwnd": 1312048 }, "bridgeRestarted": true } }
```

`GetIdeModalDialog` can inspect that IDE before reconnecting: without `ProcessId` it uses `data.lastIde.ideProcessId` whenever the restarted bridge has no pid of its own.

## Client request timeout

The server-side timeouts above only bound the PowerShell call. The MCP **client** has its own request timeout, and the MCP SDK default is **60 s**: `ConnectIde` (36–90 s when it has to launch XAE and open a solution), `BuildProject` and `EnableConfig` routinely exceed it, in which case the client reports a timeout while the server happily finishes the call (the next tool call then sees the finished state).

To keep long calls alive the server sends `notifications/progress` every 10 s (`TWINCAT_MCP_PROGRESS_INTERVAL_MS`) **when the client supplied a `progressToken`** in the request (`params._meta.progressToken`); without a token nothing is sent. The notification carries `progress` = elapsed milliseconds (strictly increasing, no `total`) and `message` = `"<tool> running <n>s"`.

Cancelling a request (`notifications/cancelled`) only helps while the call is still waiting in the queue: it is dropped with `CANCELLED`. Once the request has been written to PowerShell it runs to completion (a DTE/ADS call cannot be interrupted) and the result is returned as usual.

| Client | How to survive a long call |
|---|---|
| `@modelcontextprotocol/sdk` client | `client.callTool(params, undefined, { onprogress: () => {}, resetTimeoutOnProgress: true, timeout: 900000 })` — `onprogress` makes the SDK attach a `progressToken`, `resetTimeoutOnProgress` restarts the timer on every progress notification |
| Claude Code | Environment variable `MCP_TOOL_TIMEOUT` in milliseconds, e.g. `MCP_TOOL_TIMEOUT=900000` (set it in the shell that starts `claude`, or in `settings.json` `env`). `MCP_TIMEOUT` is the separate server-startup timeout |
| Claude Desktop | No per-tool timeout setting is documented as of this writing. If a call is cut off, prefer the fine-grained tools (`ConnectIde`, `BuildProject`, `EnableConfig`, … as separate calls) over `RunLifecycle`, and call `GetStatus` afterwards: the bridge keeps running and finishes the call even when the client stopped waiting |

## Typical session

The tool names below are what Claude calls; each one is an independent MCP tool call and the bridge keeps the state in between.

```
GetStatus                                  -> NOT_CONNECTED, hint: Run ConnectIde first
ConnectIde      {"SolutionPath": "C:\\path\\to\\MyProject.sln"}
GetIdeModalDialog                          -> data.dialog == null (nothing blocking)
BuildProject                               -> on BUILD_FAILED read data.errorItems
EnableConfig    {"Force": true}            -> Config -> Activate -> Run -> Login+Download -> PLC Run
ConnectAds                                 -> AmsNetId auto-detected
ReadVariable    {"Path": ["MAIN.nCounter"]}
WriteVariable   {"Path": "MAIN.bEnable", "Value": true}
```

Or in one call:

```
RunLifecycle    {"SolutionPath": "C:\\path\\to\\MyProject.sln"}
RunLifecycle    {"SolutionPath": "C:\\path\\to\\MyProject.sln", "TargetAmsNetId": "199.5.42.250.1.1"}
QuickRead       {"Path": ["MAIN.nCounter"]}
```

Pass `TargetAmsNetId` (second example) when the .tsproj has no saved target or should run on another runtime than the IDE default (UmRT, remote CX); omit it to keep the target the IDE already has.

Do not add waits between calls: `EnableConfig`, `SetSystemState`, `SetPlcState` and `RunTestCycle` poll until the target state is reached.

## Logging

| Module stream | MCP notification |
|---|---|
| `Write-Warning` | `notifications/message`, level `warning`, `logger: "tcauto"` |
| `Write-Verbose` / `Write-Debug` | level `debug`, only with `TWINCAT_MCP_VERBOSE=1` |
| `Write-Information` | level `info` |
| bridge stderr | level `error` |

Log lines never end up inside the result object. The server itself logs to its own stderr only (Claude Desktop writes it to `%APPDATA%\Claude\logs\mcp-server-tcauto.log`).

## Known limits

- A DTE call blocked by a modal dialog still cannot be interrupted, but for `BuildProject`, `EnableConfig`, `PlcLogin`, `SendPlcProgram`, `RunTestCycle`, `OpenProject` and `ConnectIde` (also as `RunLifecycle` steps) the modal-dialog probe detects the dialog (two consecutive 5 s scans must see the same title, so typically 10–15 s after it appears; only a modal or Win32 `#32770` window while the IDE main window is blocked counts: `IsEnabled` false, `WindowInteractionState` `BlockedByModalWindow`, or a modal / `#32770` window owned by the main window, since the WPF XAE main window stays enabled behind a modal; progress boxes never do) and returns `IDE_MODAL_DIALOG` with its title and text instead of waiting for the 600 s `BRIDGE_TIMEOUT`; the bridge is killed either way, losing IDE and ADS state. The timeout path remains for tools that are not probed, for calls made before any `ConnectIde` (no IDE pid known), and when UI Automation itself hangs on the dialog. The IDE process survives and the interrupted DTE operation may still complete inside it once the dialog is dismissed (killing PowerShell does not cancel it); `data.lastIde` / `data.ideProcessId` / `error.hint` tell you which pid to inspect or kill. Window selection and dialog text come from the module's own scan (`$script:TcUiaDialogScan` in `src/TwinCATAutomation/Private/Get-TcIdeModalDialog.ps1`, dot-sourced by the probe), so the probe reads exactly what `Get-TcIdeModalDialog` reads. That scan only sees top-level windows of the IDE process; a dialog owned by the main window (UIA shows it as a child of the main window) is picked up by the probe's own fallback, which reads the Win32 caption and `Text` elements only (Windows 11 message boxes expose their message differently, so `dialogText` can be empty there). Titles are the Win32 caption (the UIA Name of a WPF window such as XAE Help > About is its content text) and are cut at 200 characters. The list of known dialogs is in [docs/troubleshooting.md](../docs/troubleshooting.md).
- `ConnectIde` with a `SolutionPath` different from `lastIde.solution` may launch a new IDE, so a dialog in the **previous** IDE is only logged (stderr + `warning` notification "... the call was not aborted"), never turned into `IDE_MODAL_DIALOG`; if that `ConnectIde` actually reuses the blocked IDE it ends in `BRIDGE_TIMEOUT`. `NoLaunch`, the same solution, or neither parameter → the call is aborted as usual.
- The probe cannot outlive the server: its stdin is a pipe from Node that is never written to, and EOF (server gone) makes it exit within ~250 ms; `-MaxLifetimeSec` (call timeout + 60 s) is a second safety net.
- MCP clients time out long calls on their side (SDK default 60 s); see [Client request timeout](#client-request-timeout).
- `GetBuildErrors` (and the `errorItems` / `warningItems` of `BuildProject`) need the XAE tool window to be named `Error List` (English UI) or `錯誤清單` (zh-TW VS2022); the summary-button counts are parsed from English and zh-TW names (including the VS2022 `0 / 2` "shown / total" form, total reported), other languages return `ERRORLIST_UNAVAILABLE`. In VS2022 the scope filter is switched to Entire Solution before the rows are read.
- One PowerShell session, one call at a time: concurrent tool calls are queued FIFO.
- Cancellation (`notifications/cancelled`) is honoured only for calls still waiting in that queue (`CANCELLED`, nothing executed). A call that has already been sent to PowerShell cannot be interrupted: it runs to the end (build, activation, download included) and its result is returned; cancel it by waiting, not by assuming it stopped.
- Per-call timeouts are capped at 2 h; `TimeoutSec` / `TimeoutMs` / `DurationMs` beyond the schema `maximum` are rejected with `INVALID_PARAMS`.
- If the server process is killed (client crash, `taskkill` of `node`) while the bridge is inside a DTE call, that `powershell.exe` becomes an orphan until the call returns (or forever, behind a modal dialog); the next server start spawns a fresh bridge and does not clean the old one up. Look for `powershell.exe ... -File ...\bridge\bridge.ps1` in Task Manager.
- An XAE that `ConnectIde` launched (`selectedBy: "launched"`) is **not** closed when the server exits; it keeps running with the solution open. Close it with `DisconnectIde {"Quit": true}` before the session ends, or kill the pid from `data.lastIde`.
- `scriptblock` parameters are not exposed (`WatchVariable` `Until` is a string condition since 2026-10-20).
- stdio transport only; Streamable HTTP is not provided yet.

## Regenerate tools.json

`tools.json` is generated from the module's cmdlet metadata. After changing a cmdlet's parameters:

```powershell
npm run generate-tools   # runs scripts/Export-ToolSchema.ps1 with powershell.exe
npm test
```

Commit the regenerated `tools.json` together with the module change.

## Architecture

```
MCP client (Claude Desktop / Claude Code)
   │ stdio, JSON-RPC
   ▼
index.js            tools/list, tools/call, logging; validation + per-call timeout (lib/tools.js)
   │ lib/bridge.js: newline-delimited JSON on stdin/stdout, FIFO queue, kill+restart on timeout
   ▼
powershell.exe -STA  bridge/bridge.ps1  → Import-Module TwinCATAutomation.psm1
                                           holds DTE / ITcSysManager / TcAdsClient across calls

index.js ── lib/modal-probe.js, only during long DTE calls once an IDE pid is known:
powershell.exe -STA  bridge/modal-probe.ps1 -ProcessId <IDE pid> -ScanScript <module scan> [-MainHwnd <hwnd>]
                                           UI Automation scan every 5 s (module's $script:TcUiaDialogScan);
                                           one JSON line on a kill-worthy dialog -> bridge killed, IDE_MODAL_DIALOG;
                                           exits by itself when Node's stdin pipe closes
```

Composite tools (`lib/composites.js`) chain catalog tools through the same validation and timeout path. The wire protocol between Node and PowerShell, parameter conversion rules and the result/log line format are specified in [PROTOCOL.md](PROTOCOL.md).
