# Bridge protocol (Node ⇄ PowerShell 5.1)

The TcAuto MCP server (`index.js`) keeps **one** long-lived `powershell.exe` child
(Windows PowerShell 5.1, `-STA -NoProfile -NonInteractive -ExecutionPolicy Bypass
-File bridge/bridge.ps1 -ModulePath <psm1>`). All tool calls are serialised
through that child so the module's `$script:` state (DTE, ITcSysManager,
TcAdsClient, AmsNetId, IDE pid) survives across calls.

Transport: newline-delimited JSON, UTF-8, one JSON object per line, on the
child's stdin (requests) and stdout (responses + events). Nothing else may be
written to stdout. stderr is free-form and is forwarded to the MCP client as
`notifications/message` at level `error`.

## Startup

Child writes exactly one line before accepting requests:

```json
{"event":"ready","ok":true,"cmdlets":["Connect-TcIde", ...],"psVersion":"5.1.26100.1","apartment":"STA","modulePath":"..."}
{"event":"ready","ok":false,"error":{"code":"MODULE_IMPORT_FAILED","message":"...","hint":"..."}}
```

On `ok:false` the child exits with code 2 after writing the line.

## Requests (stdin, one per line)

| field | type | notes |
|---|---|---|
| `id` | string | opaque, echoed back |
| `op` | `"call"` \| `"modal"` \| `"state"` \| `"ping"` \| `"shutdown"` | default `"call"` |
| `cmdlet` | string | `op:"call"` only. Must be in the exported list from `ready`; anything else → `{"success":false,"error":{"code":"INVALID_CMDLET"}}`. Never evaluated as script. |
| `params` | object | `op:"call"` only. Splatted. See conversion rules. |

A line that is not valid JSON (PS 5.1 `ConvertFrom-Json` also rejects objects whose
keys differ only in case, e.g. `{"a":1,"A":2}`) or not a JSON object gets
`{"id":<id>,"event":"result","success":false,"error":{"code":"INVALID_REQUEST",...}}`.
`<id>` is recovered from the raw line with the regex `"id"\s*:\s*("([^"]*)"|(\d+))`
(string id -> string, digits -> number); only when that does not match is it `null`.

* `modal`  → calls the module-private `Get-TcIdeModalDialog -ProcessId <pid> -TimeoutSec <t>`
  inside the module scope (`& (Get-Module TwinCATAutomation) { ... }`). Optional
  `params.ProcessId` (positive integer) selects the IDE process to scan; without it the
  pid stored by `Connect-TcIde` (`$script:TcIdeProcessId`) is used. Optional
  `params.TimeoutSec` (default 5, clamped to 1..60). Result:
  `{"success":true,"data":{"ideProcessId":<pid actually scanned>,"dialog":null|{"title":"...","text":"...","kind":"reload-prompt"|"unknown","reloadTarget":"file"|"project"|null,"hwnd":int|null,"buttons":[{"id":int,"name":"..."}]}}}`
  (`kind` `reload-prompt` = the VS "File has been changed outside the environment. Reload the new
  file?" prompt, a file open in an editor was changed on disk (`reloadTarget` `"file"`:
  `ResetSolution` dismisses it and reopens the solution), or the XAE "The project file ... has
  been modified outside of TwinCAT XAE. Do you want to reload the project?" prompt, a `.plcproj`
  was rewritten on disk (`reloadTarget` `"project"`: `ResetSolution` answers Yes and only
  reconnects); `reloadTarget` is `null` for `unknown`. `buttons` are the Win32 button children
  of a `#32770` message box by control id (1 OK, 2 Cancel, 6 Yes, 7 No; `name` is the localized
  caption), empty for other windows; `hwnd` is the dialog window handle. Kind and reloadTarget
  come from the module's `Add-TcDialogKind`)
  (`dialog` is `null` also when the pid does not exist). A non-integer / non-positive
  `ProcessId` → `INVALID_PARAMS`. When neither `params.ProcessId` nor a stored pid is
  available: `{"success":false,"error":{"code":"NOT_CONNECTED","message":"...","hint":"Run Connect-TcIde first, or pass params.ProcessId."}}`.
* `state`  → snapshot of module state, no COM calls:
  `{"success":true,"data":{"ideConnected":bool,"ideProcessId":int|null,"ideMainHwnd":int|null,"sysManagerAvailable":bool,"adsConnected":bool,"amsNetId":string|null,"adsPort":int|null,"lastModalDialog":null|{title,text,kind,reloadTarget,hwnd,buttons}}}`
  (`lastModalDialog` = `$script:TcLastModalDialog`, the last dialog the module's COM watchdog saw,
  same shape as the `modal` op's `dialog`)
  (`ideMainHwnd` = module variable `$script:TcIdeMainHwnd`, the IDE main window handle stored by
  `Connect-TcIde`; `null` when unset, 0 or not a number).
* `ping`   → `{"success":true,"data":{"pong":true}}`.
* `shutdown` → child disconnects ADS (ignore errors), releases COM refs via
  `Disconnect-TcIde` without `-Quit`, replies `{"success":true}` and exits 0.

### Parameter conversion (`op:"call"`)

The bridge looks up `(Get-Command $cmdlet).Parameters[$name].ParameterType`
and converts the JSON value before splatting:

| target type | JSON value | conversion |
|---|---|---|
| `switch` | bool | `[switch]$value` |
| `hashtable` | object | recursive PSCustomObject → `[hashtable]`. Key order is **NOT** guaranteed (`[hashtable]` parameters lose it), so e.g. `AddDut.Fields` / `AddGvl.Variables` declaration order is not fixed. |
| `hashtable[]` | array of object | each element → `[hashtable]` |
| `PSCustomObject` / `PSCustomObject[]` | object / array | passed as-is from `ConvertFrom-Json` |
| `string[]` | string or array | `[string[]]@(...)` |
| integer types (`int`, `long`, `short`, `byte`, unsigned) | number | must be integral: `2.5` → `INVALID_PARAMS` (no rounding); out of range → `INVALID_PARAMS` |
| `double` / `single` / `decimal` | number | cast |
| any numeric type | string, bool, object, array | rejected: `INVALID_PARAMS` (`"5"` is not a number; JSON has a number type) |
| `object` | anything | passed as-is |
| `scriptblock` | — | rejected: `INVALID_PARAMS` (not exposed in tools.json) |

Unknown parameter names → `{"success":false,"error":{"code":"INVALID_PARAMS","message":"Unknown parameter 'X' for Connect-TcIde"}}`.
`null` values are dropped (parameter not passed).

### Responses (stdout)

Exactly one **result** line per request, possibly preceded by zero or more
**log** lines for the same id:

```json
{"id":"7","event":"log","level":"warning","message":"..."}
{"id":"7","event":"log","level":"debug","message":"..."}   // Write-Verbose, only when TWINCAT_MCP_VERBOSE=1
{"id":"7","event":"result","success":true,"data":{...}}
{"id":"7","event":"result","success":false,"error":{"message":"...","code":"...","hint":"..."},"data":{...}?}
```

Result lines are the module's `New-TcResult` object serialised with
`ConvertTo-Json -Depth 50 -Compress`, plus `id` and `event`. The bridge takes
the **last** pipeline object that has a `success` property. If the cmdlet
emitted output but nothing with `success` (e.g. `New-TcTestCase` returns a
plain test-case object), the output is wrapped as
`{"success":true,"data":<object or array>}`; if it emitted nothing at all the
bridge returns
`{"success":false,"error":{"code":"NO_RESULT","message":"<cmdlet> returned no result object"}}`.
A `success:false` result without `hint` gets one from the module's
`Get-TcErrorHint` table when available (for `NOT_CONNECTED` whose message
refers to the IDE, the hint is "Run Connect-TcIde first (ConnectIde).").
Parameter-binding failures (ValidateSet/ValidateRange violation, missing
Mandatory) are reported as `INVALID_PARAMS`, not `EXECUTION_ERROR`.

For `op:"call"` the bridge adds execution-order fields to `data` (a new `data` object is
created when the result has none or it is not an object): `seq` (counter from 1, incremented only
when the request is really written to PowerShell), `startedAt` and `finishedAt` (ISO 8601). The
bridge is strictly FIFO and runs one call at a time, so `seq` order = execution order. Timed-out /
killed calls carry them too; calls that never left the queue (`CANCELLED`, queued `BRIDGE_DIED`)
and `ping` / `state` / `modal` do not.
An uncaught exception → `{"success":false,"error":{"code":"EXECUTION_ERROR","message":"<exception message>","hint":"..."}}`;
if the exception message starts with a known code (`IDE_BUSY`, `IDE_TIMEOUT`,
`IDE_MODAL_DIALOG`, …) that code is used instead of `EXECUTION_ERROR`.
Tool-level codes pass through unchanged, e.g. `POU_NOT_FOUND` from `GetPouCode`/`WritePouCode` (POU not under `<Plc> Project`; `data.tried[]`, `data.projectChildren[]`). `GetProjectTree` takes `Depth` (integer 1-10, default 4) and `PlcOnly` (boolean).

Streams 2 (error), 3 (warning), 4 (verbose), 5 (debug), 6 (information) are captured
with redirection (`2>&1 3>&1 4>&1 5>&1 6>&1`) and emitted as log lines (level
`error` with the ErrorRecord's exception message, `warning`, `debug`, `debug`, `info`);
they never end up inside the result object. Records are processed as they are
produced, so log lines written before a terminating exception are still sent ahead
of the `EXECUTION_ERROR` result. Only non-terminating `Write-Error` records reach the
`error` log level; terminating errors become the result as described above. The bridge
runs with `$ErrorActionPreference = 'Stop'`, so a plain `Write-Error` inside a module
cmdlet is normally terminating (-> `EXECUTION_ERROR`); only records written with an
explicit `-ErrorAction Continue` (or equivalent) are logged. Verbose/debug lines are only produced when
`TWINCAT_MCP_VERBOSE=1` (the bridge sets the global preference variables).
Common parameters (`Verbose`, `ErrorAction`, …) are not accepted as params.

## Node-side behaviour

* Timeout per call:
  `max(tools.json[tool].timeoutMs ?? 120000, TimeoutSec*1000 + 30000, TimeoutMs + DurationMs + 30000)`
  (the `*Sec`/`*Ms` terms only when those params are present; Build 600000,
  RunTestCycle 900000 in tools.json), **clamped to 1000 .. 7200000 ms (1 s .. 2 h)** so a huge
  `TimeoutSec` can neither overflow `setTimeout` (which would report `BRIDGE_TIMEOUT` at once)
  nor hold the bridge forever. Schema `minimum` / `maximum` on integer and number parameters are
  enforced before the call (`INVALID_PARAMS`). On timeout the child is **killed** (a DTE call blocked by
  a modal dialog can't be interrupted) and restarted; the tool returns
  `{"success":false,"error":{"code":"BRIDGE_TIMEOUT","message":"...","hint":"PowerShell bridge was restarted and all IDE/ADS state is lost. Check for a modal dialog in the XAE window (GetIdeModalDialog after ConnectIde), then ConnectIde again."}}`.
  Calls still queued behind the timed-out one get `BRIDGE_DIED` with a message ending in
  `this call was not executed; safe to retry after reconnecting`.
* Child death is detected on the child's `close` event (process exited **and** stdout drained), so a
  result line written just before an exit is still delivered. Child exit while idle or mid-call →
  pending call gets `{"success":false,"error":{"code":"BRIDGE_DIED","message":"...","hint":"...ConnectIde again"}}`;
  queued calls get the same code with the `not executed; safe to retry` message; the next call lazily
  restarts the child. Restart failure (import failed) → `MODULE_IMPORT_FAILED` with the child's error.
  With `TWINCAT_MCP_EAGER=1` the child is started at server start; calls that arrive while it is
  starting wait and are dispatched (or fail with `MODULE_IMPORT_FAILED`) once the start settles.
  Calls that arrive while the server is stopping the bridge get `BRIDGE_DIED` immediately.
* A `result` line with `id: null` (the bridge could not parse the request line → `INVALID_REQUEST`)
  is attributed to the call in flight, which it finishes; the child is not killed. With no call in
  flight it is only logged.
* Cancellation: the `AbortSignal` of the `tools/call` request (`notifications/cancelled`) is passed
  to the bridge call. A call that is **still queued** is removed and answered with
  `{"success":false,"error":{"code":"CANCELLED","message":"Request cancelled before it was sent to PowerShell; nothing was executed."}}`.
  A call that has already been written to the child cannot be interrupted: it runs to completion
  and its real result is returned. Composite tools pass the same signal to every step.
* `BRIDGE_TIMEOUT` / `BRIDGE_DIED` results are decorated by `index.js` (not by `lib/bridge.js`,
  whose `errorResult` stays pure) with
  `data.lastIde = {ideProcessId, selectedBy, solution, ideMainHwnd} | null` and `data.bridgeRestarted = true`.
  `lastIde` is the `data` of the last successful `ConnectIde` that went through the server
  (including the step inside `RunLifecycle`); right after that `ConnectIde` the server issues one
  `op:"state"` (no COM call) and stores `state.ideMainHwnd` as `lastIde.ideMainHwnd` (positive
  integer or `null`). `lastIde` is cleared when a new `ConnectIde` **starts** (so a
  failed reconnect never points at an older IDE) and by a successful `DisconnectIde`. Before it is
  used in a hint the pid is verified with `tasklist /FI "PID eq N" /FO CSV /NH`: it must be alive and
  its image name must be `TcXaeShell.exe` or `devenv.exe` (both the 32-bit and the 64-bit TcXaeShell
  are `TcXaeShell.exe`), otherwise `lastIde` is forgotten and the
  generic hint is kept (`TWINCAT_MCP_SKIP_PID_CHECK=1` disables the check for tests with mock pids).
  When `lastIde` is valid the hint names the pid: `selectedBy == "launched"` → kill it with
  `taskkill /PID N /T /F` then `ConnectIde`, with the warning "Unsaved changes in that IDE will be
  lost; ask the user before killing it."; otherwise → the user opened it, dismiss the dialog then
  `ConnectIde`. Without `lastIde` the generic hint above is kept.
* **Modal-dialog probe during long calls.** A modal dialog in XAE blocks the DTE call inside the
  bridge forever, so for `BuildProject`, `EnableConfig`, `PlcLogin`, `SendPlcProgram`,
  `RunTestCycle`, `OpenProject` and `ConnectIde` (and therefore the matching steps of
  `RunLifecycle`, which go through the same path) the server starts a second, short-lived process
  next to the call:
  `powershell.exe -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File bridge/modal-probe.ps1 -ProcessId N -IntervalSec 5 -ConfirmScans 2 -ScanScript <module>/Private/Get-TcIdeModalDialog.ps1 [-MainHwnd H] -MaxLifetimeSec L`.
  `-MainHwnd` is `lastIde.ideMainHwnd`, passed only when known (> 0); `-MaxLifetimeSec` is
  `ceil(call timeout / 1000) + 60`.
  The pid is `lastIde.ideProcessId`; for `ConnectIde` it is the **previous** IDE (captured before
  `lastIde` is cleared), the typical reconnect-after-`BRIDGE_TIMEOUT` case where the dialog is still
  up. No pid known (no `ConnectIde` yet, or after `DisconnectIde`) → no probe. The pid is checked
  with the same `tasklist` liveness test as `lastIde` (in parallel with the call, never delaying
  it) so a recycled pid is never watched.
  - **ConnectIde policy.** `ConnectIde` probes the previous IDE in **kill** mode (below) only when
    it will talk to that IDE again: `NoLaunch: true`, or `SolutionPath` equal to
    `lastIde.solution` (case-insensitive, path-normalised), or neither `SolutionPath` nor
    `NoLaunch` given. A different `SolutionPath` (a new IDE may be launched) runs the probe in
    **log-only** mode: a report only writes a server stderr line and a `notifications/message`
    `warning` ("previous IDE (pid N) shows dialog '<title>' ... the call was not aborted") and the
    call continues. `ProgId` plays no role. All other probed tools always use kill mode.
  - **Scan.** The probe dot-sources `-ScanScript` and runs the module's `$script:TcUiaDialogScan`
    (single source of truth for window selection, the known-title list and text collection; the
    probe exits 2 if the file is missing or does not define it). It waits one interval **before**
    its first scan (the cmdlet's own pre-call `Get-TcIdeModalDialog` check gets to answer cleanly
    first), then scans every interval, each scan in a fresh STA runspace, abandoned after 4 s if
    UIA hangs (normal while XAE's UI thread is busy building; logged for the first abandoned scan
    and then every 10th). Abandoned scans are disposed once they finish; while 10 still hang no new
    scan starts. The module scan only sees top-level windows of the pid; a dialog **owned** by the
    main window is a UIA child of the main window, so when the module scan found nothing the
    probe also checks the main window's direct `Window` children and takes the first modal /
    `#32770` one (floating tool windows are owned too and are ignored; Win32 caption + `Text`
    descendants only).
  - **Kill rule.** A candidate is kill-worthy only when it is `IsModal` or a Win32 dialog
    (`#32770`) **and** the IDE main window is blocked: `IsEnabled == false` (Win32 / WinForms
    owners), or `WindowPattern.WindowInteractionState == BlockedByModalWindow` (the XAE main window
    is WPF and keeps `IsEnabled` true behind a modal), or the main window owns a child window that
    is modal / `#32770` (a pure WPF owner reports neither). Main window = `-MainHwnd`, else
    `Process.MainWindowHandle`, else the module's title pattern matched against the UIA Name and
    the Win32 caption. No main window found → kill-worthy only when `IsModal`. A window with a
    `ProgressBar` descendant (progress / wait boxes), a title-only match, or an unblocked main window
    is log-only: stderr `debug: dialog '<title>' seen but not kill-worthy (<reason>)`, not counted.
    A kill-worthy dialog is reported only when `ConfirmScans` (default 2,
    `TWINCAT_MCP_PROBE_CONFIRM_SCANS`, 1..10) consecutive scans saw the same title; detection
    therefore takes about two intervals plus the scan time after the dialog appears.
  - **Output.** `title` is the Win32 caption (the UIA Name of a WPF window is often its content
    text, e.g. XAE Help > About), cut at 200 chars; when the caption differs from the UIA Name and
    no text was collected, the Name becomes `text`. On a report it writes exactly one line to stdout,
    `{"title":"...","text":"...","className":"...","isModal":true,"processId":N,"mainWindowBlocked":true|false|null,"reason":"modal"|"win32-dialog"}`
    (non-ASCII escaped as `\uXXXX`; `reason` is `win32-dialog` for `#32770`, else `modal`), and
    exits 0; exit 3 = process not found, 2 = error. stderr lines start with `debug: ` (routine:
    abandoned scans, confirmation progress, not kill-worthy, stdin closed, lifetime) or `error: `
    (real failures). `lib/modal-probe.js` routes `debug:` lines to the server's debug output (only
    with `TWINCAT_MCP_VERBOSE=1`) and everything else, plus non-zero exits and spawn errors, to
    server stderr + `notifications/message` level `warning`.
  - **Orphan protection.** The probe's stdin is a pipe that Node keeps open and never writes to;
    EOF (or any byte) means the parent is gone and the probe exits 0 within ~250 ms (it sleeps in
    250 ms slices). `-MaxLifetimeSec` (default 7260, clamped 10..86400) is a second safety net.
  In kill mode Node then aborts the call: if it is in flight the bridge is **killed exactly like on
  `BRIDGE_TIMEOUT`** (calls queued behind it get `BRIDGE_DIED` / not executed), if it is still
  queued it is only removed (the bridge keeps running). The result is
  `{"success":false,"error":{"code":"IDE_MODAL_DIALOG","message":"<title> | <first 200 chars of text>","hint":"..."},"data":{"dialogTitle","dialogText","ideProcessId","lastIde","bridgeRestarted"}}`
  (`message` is just the title when the text is empty; `lastIde` is the snapshot at detection time,
  `null` during `ConnectIde`; `bridgeRestarted` is `false` for a dequeued call). The hint names the
  pid: launched by this server → dismiss the dialog or `taskkill /PID N /T /F` (ask the user first),
  opened by the user → dismiss it; then `ConnectIde`; it also warns that the interrupted DTE
  operation may still complete inside the IDE once the dialog closes (killing PowerShell does not
  cancel it), and for a dequeued call that the call ahead of it may stay blocked until its own
  timeout. `BRIDGE_*` decoration does not touch this
  result. A report that arrives after the call finished is ignored (logged). The probe is killed
  (fire-and-forget, `taskkill /T /F` after 1 s) as soon as the call
  ends and on server shutdown; probe failures (spawn error, crash, garbage on stdout) are only
  logged and never affect the call.
  `TWINCAT_MCP_MODAL_PROBE=0` disables it, `TWINCAT_MCP_MODAL_PROBE_INTERVAL_SEC` (1..60, default 5)
  sets the interval, `TWINCAT_MCP_PROBE_SCAN_SCRIPT` overrides the scan file; tests replace the
  spawn with `TWINCAT_MCP_PROBE_COMMAND` / `TWINCAT_MCP_PROBE_ARGS` (the same argument tail
  `-ProcessId ... -MaxLifetimeSec` is appended).
* `GetIdeModalDialog` (`op:"modal"`) accepts an optional `ProcessId` (integer ≥ 1) which is passed
  as `params.ProcessId`. Without it, the server first reads `op:"state"`; when the bridge has no
  `ideProcessId` (restarted after `BRIDGE_TIMEOUT` / `BRIDGE_DIED`) but `lastIde` is known, the
  server sends `params.ProcessId = lastIde.ideProcessId` so the dialog can be inspected before
  reconnecting.
* `tools/list` entries carry `annotations` when the catalog entry in tools.json has them; the
  composites set their own (`GetStatus`, `QuickRead`, `GetIdeModalDialog`: `readOnlyHint: true`;
  `RunLifecycle`: `destructiveHint: true, readOnlyHint: false`).
* `RunLifecycle` steps: `ConnectIde`, `SetTarget` (only when `TargetAmsNetId` and/or `Platform` is a non-empty
  string; runs right after `ConnectIde` as `SetTarget {AmsNetId, Platform}` with `Platform`, or
  `SetTarget {AmsNetId, NoPlatformSwitch: true}` without it; `AmsNetId` falls back to the one `ConnectIde`
  reported), `BuildProject` (unless `SkipBuild`), `EnableConfig` (no `Platform`: it checks the target platform
  itself), `ConnectAds`. Without `TargetAmsNetId` and `Platform` there is no `SetTarget` step.
* When the `tools/call` request carries `params._meta.progressToken` (SDK: `extra._meta.progressToken`
  in the request handler), the server sends `notifications/progress`
  `{progressToken, progress: <elapsed milliseconds, strictly increasing>, message: "<tool> running <n>s"}`
  every `TWINCAT_MCP_PROGRESS_INTERVAL_MS` (default 10000) until the call returns. No token → no
  progress notifications. The PowerShell child is not involved.
* Calls are queued FIFO; the child handles one at a time.
* Every `log` line → `notifications/message` (`logger: "tcauto"`, `level`
  warning/debug/info). Child stderr lines → level `error`.
