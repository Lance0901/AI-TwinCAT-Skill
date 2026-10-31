---
name: TwinCAT-AutomationInterface
description: Use when the user asks to automate TwinCAT 3 IDE, build or deploy PLC programs, read or write PLC variables via ADS, modify Structured Text code, or run automated PLC tests. Requires Windows with TwinCAT 3 XAE installed.
---

# TwinCAT Automation Skill

Control TwinCAT 3 IDE and PLC runtime using the TwinCATAutomation PowerShell module.

## Setup

```powershell
Import-Module "<module-path>" -Force
```

## Full Lifecycle (Zero Dialogs)

```powershell
# 1. Connect (one-step with -SolutionPath)
$r = Connect-TcIde -SolutionPath "C:\Projects\MyProject.sln"
$amsNetId = $r.data.amsNetId

# 2. Build
Build-TcProject

# 3. Activate (Config -> Run via ADS, no dialogs)
Enable-TcConfig -Force

# 4. Wait for TwinCAT restart
Start-Sleep -Seconds 5

# 5. Login + Download (default -LoginMode Regular = flag 1, no SILENT flag; prompts answered by the global SilentMode from Connect-TcIde; creates the app on an empty runtime, attaches when one exists; no dialogs)
Enter-TcPlcOnline

# 6. Connect ADS (AFTER Login — port 851 needs program downloaded first)
Connect-TcAds -AmsNetId $amsNetId

# 7. Start PLC
Set-TcPlcState -State Run

# 8. Read/Write
Read-TcVariable -Path "MAIN.nCounter"
Write-TcVariable -Path "MAIN.bEnable" -Value $true
```

## All Commands

### IDE Connection
| Command | Parameters | Description |
|---------|-----------|-------------|
| `Connect-TcIde` | `[-SolutionPath <path>] [-ProgId <com>]` | Connect to IDE. With -SolutionPath: finds/launches IDE, opens solution, returns amsNetId |
| `Disconnect-TcIde` | | Disconnect from IDE |
| `Reset-TcSolution` | `[-SolutionPath <sln>] [-TimeoutSec 120]` | Dismiss the reload prompt, close all documents (no save), close + reopen the solution on the same IDE so XAE reloads project files changed on disk; only needed when the changed .TcPOU is open in an XAE editor (otherwise XAE picks it up within ~5 s) |
| `Get-TcIdeInfo` | | Get IDE version, solution path, connection status |

### Project Management
| Command | Parameters | Description |
|---------|-----------|-------------|
| `New-TcProject` | `-Name <name> [-Path <dir>]` | Create new TwinCAT project with PLC and MAIN. Only on an IDE with no solution open, otherwise `SOLUTION_ALREADY_OPEN` and nothing is created; not offered on MCP (#70) |
| `Open-TcProject` | `-Path <sln>` | Open existing .sln file |
| `Get-TcProjectTree` | | Get full project tree as JSON |
| `Add-TcPou` | `-Name <n> -Type <Program\|FunctionBlock\|Function> [-ReturnType <t>]` | Add POU |
| `Add-TcGvl` | `-Name <n> [-Variables @(@{name='nA';type='INT';init='3'}, @{name='bB';type='BOOL'})]` (or `[ordered]@{nA='INT'; bB='BOOL'}`; a plain `@{}` with more than one member is refused, #47) | Add Global Variable List, members in input order |
| `Add-TcDut` | `-Name <n> -DutType <Struct\|Enum\|Alias\|Union> [-Fields <same forms as -Variables; Enum: name / value>]` | Add Data Unit Type, members in input order |
| `Add-TcLibrary` | `-Name <lib>` | Add library reference |
| `Add-TcInterface` | `-Name <n> [-Extends <itf>] [-PlcProjectPath <folder>]` | Add an INTERFACE (Extends as one string) |
| `Add-TcPouMember` | `-ParentPath <path\|name> -Kind <Method\|Property\|Action\|Get\|Set> [-Name <n>] [-ReturnType <t>] [-Access PUBLIC\|PRIVATE\|PROTECTED\|INTERNAL] [-Language ST]` | Add a method / property / action to a POU or interface, Get / Set to a property; `data.path` is the `-PouPath` of the new member |
| `Get-TcLibraries` | `[-Repository] [-Filter <wildcard>] [-PlcProjectPath <plc>]` | Read-only: references / placeholders (placeholder fields from EffectiveResolution, `frozen` from the .plcproj on disk); `-Repository` = installed libraries (ScanLibraries) |
| `Add-TcLibraryPlaceholder` | `-Placeholder <n> [-LibraryName <lib>] [-Version *] [-Distributor <d>] [-PlcProjectPath <plc>]` | Add a placeholder; existing -> `alreadyPresent`; read back from References and the saved .plcproj |
| `Remove-TcLibraryReference` | `-Name <lib\|#placeholder> [-Kind Library\|Placeholder] [-DryRun $true] [-PlcProjectPath <plc>]` | Remove a reference / placeholder; dry-run by default; .plcproj backup; read back; `LIBRARY_NOT_FOUND` |
| `Install-TcLibrary` | `-LibraryPath <file> [-Repository System] [-DryRun $true]` | Install into the machine-wide repository; dry-run by default; `LIBRARY_ALREADY_INSTALLED`; ScanLibraries readback |
| `Uninstall-TcLibrary` | `-LibraryName <n> -Version <v> -Distributor <d> [-Repository System] [-DryRun $true]` | Uninstall one exact version (no wildcards); dry-run by default; `LIBRARY_NOT_INSTALLED`; backs up the repository version folder first (`LIBRARY_BACKUP_FAILED`); ScanLibraries readback |
| `Lock-TcLibraryPlaceholder` | `-Placeholder <n> \| -All [-DryRun $true]` | Freeze a placeholder (or all) to its current version; dry-run by default; .plcproj backup; verified from `<PlaceholderResolution>` in the .plcproj |
| `Add-TcPlcTask` | `-Name <n> -CycleTimeUs <us> [-Priority <p>] [-PlcProjectPath <plc>] [-DryRun $true]` | Add a PLC task: TIRT task (CycleTime = us * 10, 100 ns units) + same-name `<Plc> Project` task (621, LinkedTask set by XAE); dry-run by default; readback; rollback on failure (`data.rollback`); `data.verifyHint` = how to check `_TaskInfo[n].CycleCount` after activation |
| `Add-TcTaskProgram` | `-ProgramName <p> [-PlcTask PlcTask] [-PlcProjectPath <plc>] [-DryRun $true]` | Link a PROGRAM to a PLC task (CreateChild 650); XAE accepts any name, so the module refuses non-programs / missing / case-mismatch (`TASK_PROGRAM_INVALID`), duplicates (`TASK_PROGRAM_ALREADY_LINKED`), missing task (`TASK_NOT_FOUND`); dry-run by default |
| `Remove-TcTaskProgram` | `-ProgramName <p> [-PlcTask PlcTask] [-PlcProjectPath <plc>] [-DryRun $true]` | Remove a program call from a PLC task; dry-run by default; .TcTTO backup + ExportChild .zip first; exact name (`TASK_PROGRAM_NOT_LINKED`) |
| `Export-TcPlcOpen` | `[-Selection <obj>,<obj>] -FilePath <abs .xml> [-PlcProjectPath <plc>] [-Overwrite]` | PlcOpenExport on `<Plc> Project`; one object / folder per element, `.` between levels (`POUs.FB_A`), empty = whole project; `^` / members alone -> `PLCOPEN_FAILED`; existing file -> `PLCOPEN_FILE_EXISTS` (`-Overwrite` keeps `.bak`, restored on failure); file read back (`data.objects`) |
| `Import-TcPlcOpen` | `-FilePath <abs .xml> [-Option None\|Replace\|Rename\|Skip] [-PlcProjectPath <plc>] [-DryRun $true]` | PlcOpenImport; dry-run by default: `data.conflicts` and the preview per option (None + conflict -> `PLCOPEN_CONFLICT`, Replace deletes children the file lacks: `data.willReplace[].deletedChildren`); Replace backs up first: a PLCopen XML of the objects is required (`PLCOPEN_BACKUP_FAILED`; restore command in `data.backup.restore`); interface properties without Get / Set are not exported, so such an object also needs its disk file backup (`data.backup.diskOnly`); an incomplete object index refuses Replace; the .zip is best effort; readback (`data.renamed`, `data.skipped`); then saves the project and reads the .plcproj back (`PROJECT_SAVE_FAILED`); records BUILD_REQUIRED |
| `Save-TcPlcLibrary` | `-FilePath <abs .library\|.compiled-library> [-PlcProjectPath <plc>] [-Overwrite]` | `SaveAsLibrary(path, $false)`: not installed (use Install-TcLibrary), no encryption; existing file -> `LIBRARY_SAVE_FILE_EXISTS` (`-Overwrite` keeps `.bak`); file read back; project unchanged |
| `Save-TcArchive` | `-FilePath <abs .tnzip\|.tszip> [-Kind Solution\|Configuration] [-Overwrite]` | Solution `.tnzip` (TcArchivePersist) or Configuration `.tszip` (ITcSysManager9) of the state in XAE memory; a missing project is only reported in the Error List, so it is read before and after (`ARCHIVE_INCOMPLETE`, `ARCHIVE_UNVERIFIED`); `data.entries` (max 200) |

### PLC Code
| Command | Parameters | Description |
|---------|-----------|-------------|
| `Get-TcPouCode` | `-PouName <n> [-PouPath <treePath>]` | Read declaration + implementation |
| `Write-TcPouCode` | `-PouName <n> [-PouPath <p>] [-Declaration <d>] [-Implementation <i>]` | Write code to POU |

### Build & Deploy
| Command | Parameters | Description |
|---------|-----------|-------------|
| `Build-TcProject` | | Build project (auto-retry on RPC_E_CALL_REJECTED); `data.errorItems[]` = Error List errors (description/file/line) |
| `Clear-TcProject` | `[-TimeoutSec 300] [-AllowUnresolvedLibrary]` | Clean the solution: `Clean($false)` + `BuildState` polling (`CLEAN_TIMEOUT`), waits out a `$null` Solution / SolutionBuild (`data.nullReads`; #18, cause not confirmed); `LastBuildInfo` > 0 with only unresolved libraries -> `LIBRARY_UNRESOLVED` (`-AllowUnresolvedLibrary`: success + `data.warningCode`, `cleanVerified = false`), other errors -> `CLEAN_FAILED`, unreadable -> `CLEAN_UNVERIFIED`; same classifier as `Build-TcProject`: `data.errorItems[].category`, `data.warningCodes[]` |
| `Test-TcPlcProject` | `[-PlcProjectPath <plc>]` | Read-only (MCP `CheckAllObjects`): check every PLC object, also the unreferenced ones a build skips; `True` -> success, `errorItems = []`; `False` -> `CHECK_FAILED` with `errorItems` in the BuildProject shape; generates no code, BUILD_REQUIRED untouched |
| `New-TcBootProject` | `[-PlcProjectPath <plc>]` | `GenerateBootProject($false)` on the PLC root `TIPC^<Plc>`: writes only the project's `_Boot\<platform>\Plc\Port_<port>.*` (not the target; `bActivate=true` not offered: use Build-TcProject + Enable-TcConfig -Force); **saves the project files**; compiles by itself, a compile error -> `BOOTPROJECT_FAILED` with `data.errorItems` from the Error List; `Port_<port>.app` must be newer afterwards (`BOOTPROJECT_VERIFY_FAILED`); BUILD_REQUIRED unchanged |
| `Get-TcBuildErrors` | `[-IncludeWarnings] [-IncludeMessages] [-TimeoutSec 30]` | Read the XAE Error List via UI Automation (counts + rows) |
| `Enable-TcConfig` | `[-Force]` | Activate config. -Force = ADS WriteControl (no dialogs) |
| `Enter-TcPlcOnline` | `[-PlcProjectPath <p>] [-LoginMode Regular\|Download\|OnlineChange] [-SilentFlag]` | Login (flags 1/4/2; no SILENT=256 by default -- `Login(257)` skips app creation on an empty runtime, prompts are handled by the global `SilentMode`; `-SilentFlag` opts in; never 3). Refused with `BUILD_REQUIRED` (every LoginMode) after a platform switch or a `Build-TcProject` that was not a complete success, until a complete build (#56) |
| `Exit-TcPlcOnline` | | Logout from PLC |
| `Send-TcPlcProgram` | | Upload program to PLC |

### ADS Communication
| Command | Parameters | Description |
|---------|-----------|-------------|
| `Connect-TcAds` | `[-AmsNetId <id>] [-Port <851>]` | Connect ADS. AmsNetId auto-detected if omitted |
| `Disconnect-TcAds` | | Disconnect ADS |
| `Read-TcVariable` | `-Path <varPath>` | Read variable by symbol path |
| `Write-TcVariable` | `-Path <varPath> -Value <val>` | Write variable. Supports BOOL, INT, UINT, DINT, REAL, LREAL, STRING |
| `Watch-TcVariable` | `-Path <p> -IntervalMs <ms> [-Condition <script>] [-TimeoutMs <ms>]` | Monitor with condition |
| `Get-TcSymbols` | `[-Filter <wildcard>]` | List symbols (e.g. "MAIN.*") |

### Runtime Control
| Command | Parameters | Description |
|---------|-----------|-------------|
| `Set-TcPlcState` | `-State <Run\|Stop\|Reset>` | Set PLC state via ADS |
| `Get-TcPlcState` | | Read PLC state |
| `Set-TcSystemState` | `-State <Run\|Config> [-AmsNetId <id>]` | Set system state via ADS WriteControl |
| `Get-TcSystemState` | `[-AmsNetId <id>]` | Read system state |
| `Set-TcTarget` | `-AmsNetId <id>` | Set target system |

### I/O Configuration
| Command | Parameters | Description |
|---------|-----------|-------------|
| `Invoke-TcIoScan` | `[-Apply]` | Scan I/O devices (Config mode; -Apply adds them to the tree) |
| `Get-TcIoTree` | | Read I/O device tree |
| `Set-TcVariableLink` | `-PlcVariable <tree path> -IoChannel <tree path>` | Link PLC variable to I/O variable (verified) |
| `Remove-TcVariableLink` | `-PlcVariable <tree path> [-IoChannel <tree path>]` | Remove a variable link (verified) |

### Generic Tree Items (dry-run first; prefer the dedicated commands)
| Command | Parameters | Description |
|---------|-----------|-------------|
| `Get-TcTreeItem` | `-Path <tree path>` | LookupTreeItem: name, type, children (read-only) |
| `Get-TcTreeItemXml` | `-Path <tree path> [-Recursive]` | ProduceXml (read-only) |
| `New-TcTreeItem` | `-Path <parent> -Name <n> [-SubType <int>] [-Before <child>] [-VInfo <v>] [-DryRun $false]` | CreateChild; DryRun default true; backup + read-back |
| `Set-TcTreeItemXml` | `-Path <tree path> -Xml '<TreeItem>...</TreeItem>' [-DryRun $false]` | ConsumeXml fragment; DryRun default true; path check, backup, read-back compare |
| `Remove-TcTreeItem` | `-Path <tree path> -ConfirmName <name> [-DryRun $false]` | DeleteChild; ConfirmName must equal the node name; DryRun default true |
| `Export-TcTreeItem` | `-Path <tree path> -FilePath <abs .xti>` | ExportChild to a new file; a PLC folder below TIPC (601) needs `.zip` (measured 2026-10-30 4026 VS2022 on a PLC folder only; other TIPC nodes not measured) |
| `Import-TcTreeItem` | `-Path <parent> -FilePath <abs .xti> [-Name <n>] [-Before <child>] [-Reconnect $false] [-DryRun $false]` | ImportChild (`.zip` for a PLC folder); without `-Name` the name in the .xti is checked for a clash; DryRun default true; backup + read-back |

### Testing
| Command | Parameters | Description |
|---------|-----------|-------------|
| `New-TcTestCase` | `-Name <n> [-Setup @(...)] [-WaitMs <ms>] -Assertions @(...) [-Teardown @(...)]` | Define test case |
| `Invoke-TcTest` | `-TestCase <tc>` | Run single test |
| `Invoke-TcTestCycle` | `-TestCases @(...) [-SkipBuild] [-KeepRunning]` | Full Build->Deploy->Test->Stop cycle |

## Testing Example

```powershell
$test1 = New-TcTestCase -Name "Initial state" -Assertions @(
    @{ Path = "MAIN.bReady"; Operator = "IsTrue"; Expected = $null }
    @{ Path = "MAIN.nCount"; Operator = "Equal"; Expected = [uint16]0 }
)

$test2 = New-TcTestCase -Name "Trigger and verify" `
    -Setup @( @{ Path = "MAIN.bStart"; Value = $true } ) `
    -WaitMs 2000 `
    -Assertions @(
        @{ Path = "MAIN.bDone"; Operator = "IsTrue"; Expected = $null }
    ) `
    -Teardown @( @{ Path = "MAIN.bStart"; Value = $false } )

# Full cycle
Invoke-TcTestCycle -TestCases @($test1, $test2)
```

Assertion operators: `Equal`, `GreaterThan`, `LessThan`, `IsTrue`, `IsFalse`

## Output Format

All commands return JSON:
```json
{"success": true, "data": {"path": "MAIN.nCounter", "value": 42, "type": "UDINT"}}
{"success": false, "error": {"message": "Build failed", "code": "BUILD_FAILED"}}
```

## Critical Rules

1. **AmsNetId is dynamic** — never hardcode. Auto-detected from IDE target via `Connect-TcIde` or `Connect-TcAds`.
2. **Lifecycle order matters**: Build -> Activate -> Login -> ADS Connect -> Start (ADS port 851 only exists after Login+Download)
3. **Don't reconnect IDE after Activate** — original COM reference survives TwinCAT XAR restart
4. **Write MAIN-level vars for FB testing** — PLC overwrites FB `VAR_INPUT` every scan cycle. Write standalone MAIN variables instead.
5. **Use -PouPath for Get/Write-TcPouCode** — format: `TIPC^<PlcName>^<PlcName> Project^POUs^<PouName>`
