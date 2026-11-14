# TcAuto — how to use these tools

TcAuto drives a TwinCAT 3 IDE (XAE / Visual Studio) and a TwinCAT runtime. On a real machine a wrong call can stop a PLC or move an axis.

## Golden rules
1. `success: true` = target state read back. `success: false` = stop; no `data` field counts as done.
2. Every error has `error.code`; `error.hint`, when present, is the next step. Do not improvise another route.
3. Never hard-code an AmsNetId; take it from `ConnectIde` `data.amsNetId`.
4. No sleeps, no retry loops: the tools wait for the target state.

## UmRT or real machine?
`ConnectIde`, `SetTarget`, `GetStatus`, `RunLifecycle` report `data.targetKind`.
- `local-umrt` (the user-mode runtime on this PC): build, activate, run, write, test freely; no need to ask.
- The kind belongs to one AmsNetId. Before `RunLifecycle TargetAmsNetId=<id>` (or any call on another target) check that id first: `GetStatus AmsNetId=<id>`.
- Anything else (`local-xar`, `remote`, `unknown`) is a real machine, a Windows XAR on this PC included. Before the FIRST call of this session that changes it (`RunLifecycle`, `EnableConfig`, `RunTestCycle`, `RunTest`, `WriteVariable`, `SetPlcState`, …) tell the user what can happen (TwinCAT restarts, the PLC stops and starts, outputs switch, axes can move) and ask once. Once agreed, do not ask again for that target this session unless you go beyond what was agreed.

## Always ask the user before
- `InstallPackage` (changes TwinCAT on this PC), `AddAdsRoute`, `InstallLibrary` / `UninstallLibrary`.
- `ConnectIde ProcessId=<pid>` after `IDE_ATTACH_CONSENT_REQUIRED` (the user's IDE); `ResetSolution Force=true` (drops unsaved changes).
- Deleting (`DeleteChild`, `RemoveReference`, `UnlinkProgramFromTask`).
- `ClearLifecycleBlock`: only after the user saw `data.lifecycleBlock` and agreed.
- `requiresDisposition: true` lint results; any dialog with more than one button (report it, do not click).

## When something fails
Stop runtime-changing calls; report `error.code`, `error.message`, `data.steps` / `data.lifecycleBlock`. Read-only diagnosis is fine (`GetStatus`, `GetSystemState`, `GetPlcState`, `GetBuildErrors`, `GetIdeModalDialog`). Never work around it via raw ADS, COM / DTE, the GUI, the runtime console, reconnecting the IDE after Activate, or changing Platform / Target / Route / build settings.

## Pick your path
| Task | Tools, in order |
|---|---|
| Open a project | `GetProjectVersion` (tell the user version + IDE) → `ConnectIde SolutionPath=<.sln>` without ProgId |
| Read code | `GetProjectTree` → `GetPouCode` |
| Change code | `LintCandidate` → `WritePouCode` (new object: `AddPou` / `AddDut` / `AddGvl` / `AddInterface` / `AddPouMember`) → `BuildProject` → `LintProject` |
| Edited files on disk | `LintProject` → `ResetSolution` → `BuildProject` |
| New PROGRAM | `AddPou` → `AddPlcTask` → `LinkProgramToTask` → `BuildProject` |
| Libraries | `GetLibraries` → `AddLibrary` / `AddPlaceholder` → `BuildProject` |
| NC axis | `AddNcTask` → `AddNcAxis` → `SetNcAxisParameter` → `LinkNcAxis` |
| I/O | `IoScan` (Config mode) → `GetIoTree` → `SetVariableLink` |
| TcCOM module | `AddTcComModule` → `SetTcComContext` → `GetTcComParameter` / `SetTcComParameter` |
| Variants | `GetVariants` → `SetVariantConfig` / `SwitchVariant` → `BuildProject` |
| PLCopen XML | `ExportPlcOpen` / `ImportPlcOpen` |
| Deploy + run | `RunLifecycle`, or `BuildProject` → `EnableConfig Force=true` → `ConnectAds` |
| Check PLC | `GetStatus`, `GetPlcState`, `ReadVariable` |
| Test | `NewTestCase` → `RunTest` / `RunTestCycle` |
| Finish | `DisconnectIde` (`Quit=true` only for an IDE this session launched) |

Tools with `DryRun` default to a dry-run: read `data`, then call with `DryRun=false`. `EnableConfig Force=true` already does Login, Download, Run: `PlcLogin`, `SendPlcProgram`, `SetSystemState`, `SetPlcState` are rarely needed. Details per error code: docs/troubleshooting.md of the TcAuto installation.
