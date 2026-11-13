# TcAuto — how to use these tools

TcAuto drives a TwinCAT 3 engineering IDE (XAE / Visual Studio) and a TwinCAT runtime for you. On a real machine a wrong call can stop a PLC or move an axis. Read every result, and ask the user where this card says so.

## Golden rules
1. `success: true` means the target state was read back. `success: false` means stop: do not treat any `data` field as done.
2. Every error has `error.code`; when `error.hint` is present it is the next step. Follow it, do not improvise another route.
3. Never hard-code or reuse an AmsNetId from the chat; tools find it (`ConnectIde` → `data.amsNetId`).
4. No sleeps, no retries in a loop. The tools already wait until the target state is reached.

## UmRT or real machine?
`ConnectIde`, `SetTarget`, `GetStatus` and `RunLifecycle` report `data.targetKind`.
- `local-umrt` (the user-mode runtime on this PC, no real I/O): build, activate, run, write variables and test freely; no need to ask.
- Everything else (`local-xar`, `remote`, `unknown`) is a real machine, including a Windows XAR on this same PC. Before the FIRST call of this session that changes it (`RunLifecycle`, `EnableConfig`, `RunTestCycle`, `RunTest`, `WriteVariable`, `SetPlcState`, …) tell the user what can happen (TwinCAT restarts, the PLC stops and starts, outputs switch, axes can move) and ask once. After the user agrees, do not ask again for that target in this session, unless you go beyond what was agreed.

## Pick your path
| Task | Tools, in order |
|---|---|
| Open a project | `GetProjectVersion` first: it reads the TwinCAT version the project was saved with and tells which IDE fits (4024 → 32-bit XAE Shell, 4026 → 64-bit XAE or VS2022). Tell the user, then `ConnectIde SolutionPath=<.sln>` without ProgId |
| Read code / structure | `GetProjectTree` → `GetPouCode` |
| Change PLC code | `LintCandidate` (the new code) → `WritePouCode` (new object: `AddPou` / `AddDut` / `AddGvl` / `AddInterface` / `AddPouMember` first) → `BuildProject` → `LintProject` |
| You edited files on disk instead | `LintProject` → `ResetSolution` → `BuildProject` |
| Build and see errors | `BuildProject` (failures list `data.errorItems`) → fix → `BuildProject` |
| New PROGRAM that must run | `AddPou` → `AddPlcTask` (if no task fits) → `LinkProgramToTask` → `BuildProject` |
| Libraries | `GetLibraries` (`Repository=true`: what is installed) → `AddLibrary` / `AddPlaceholder` → `BuildProject`; pin versions with `FreezePlaceholder` |
| NC axis | `AddNcTask` (once) → `AddNcAxis` → `SetNcAxisParameter` → `LinkNcAxis` (to the PLC `AXIS_REF`) → `BuildProject` |
| I/O | `IoScan` (target in Config; `Apply=true` adds devices) → `GetIoTree` → `SetVariableLink` / `RemoveVariableLink` → `BuildProject` |
| TcCOM module | `AddTcComModule` → `SetTcComContext` (task) → `GetTcComParameter` / `SetTcComParameter` |
| Project variants | `GetVariants` → `SetVariantConfig` / `SwitchVariant` → `BuildProject` |
| Exchange code | `ExportPlcOpen` / `ImportPlcOpen` (dry-run first) |
| Deploy and run (one step) | `RunLifecycle` |
| Deploy step by step | `SetTarget` (if needed) → `BuildProject` → `EnableConfig Force=true` → `ConnectAds` |
| Check the running PLC | `GetStatus`, `GetPlcState`, `ReadVariable`, `WatchVariable` |
| Automated test | `NewTestCase` (setup writes, assertions, teardown) → `RunTest` (PLC already running) or `RunTestCycle` (build + activate + run all + stop) |
| Finish | `DisconnectIde` (add `Quit=true` only for an IDE this session launched) |

Tools with a `DryRun` parameter run as a dry-run by default: read `data` (what would change), then call again with `DryRun=false`.

## Always ask the user before
- `InstallPackage`: installs or changes TwinCAT on this PC. Never without the user's explicit yes.
- `AddAdsRoute`, `InstallLibrary` / `UninstallLibrary`: they change the machine, not just the project.
- `ConnectIde ProcessId=<pid>` after `IDE_ATTACH_CONSENT_REQUIRED`: that IDE belongs to the user.
- `ResetSolution Force=true` (throws away unsaved IDE changes).
- Deleting anything (`DeleteChild`, `RemoveReference`, `UnlinkProgramFromTask`).
- `ClearLifecycleBlock`: only after the user saw `data.lifecycleBlock` and agreed; fill the four fields with the user's words.
- A lint result with `requiresDisposition: true`, or new suppressions to write.
- Any dialog with more than one button: report its text, do not click.

## When something fails
- Stop all runtime-changing calls. Report `error.code`, `error.message` and `data.steps` / `data.lifecycleBlock` as returned.
- `LIFECYCLE_BLOCKED`: nothing that changes the runtime will run until the user agrees to clear it.
- Read-only diagnosis is always allowed: `GetStatus`, `GetSystemState`, `GetPlcState`, `GetBuildErrors`, `GetIdeModalDialog`.
- Never work around a failure through another channel: raw ADS WriteControl, COM / DTE commands, clicking the GUI, the runtime console, reconnecting the IDE after Activate, or changing Platform / Target / Route / build settings to make it pass.
- Details for every code: docs/troubleshooting.md in the TcAuto installation.

## Tools you normally do not need
- `PlcLogin`, `PlcLogout`, `SendPlcProgram`, `SetSystemState`, `SetPlcState`: `EnableConfig Force=true` already does Login, Download and Run in the right order.
- Generic tree tools (`LookupTreeItem`, `ProduceXml`, `ConsumeXml`, `CreateChild`, `DeleteChild`, `ExportChild`, `ImportChild`): only when no dedicated tool above exists; dry-run first.
- `ReloadModule`, `ReloadRuntime`, `ReportIssue`: maintenance of TcAuto itself.
