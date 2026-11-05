---
name: TwinCAT-AutomationInterface
description: Use when the user asks to automate TwinCAT 3 IDE, build or deploy PLC programs, read or write PLC variables via ADS, modify Structured Text code, or run automated PLC tests. Requires Windows with TwinCAT 3 XAE installed.
---

# TwinCAT Automation Skill

Control TwinCAT 3 IDE and PLC runtime using the TwinCATAutomation PowerShell module.

Canonical repository: https://github.com/Lance0901/AI-TwinCAT-Skill. The installer records the source repo, version and commit in `tcauto-install-manifest.json` next to this file; `Get-TcAutomationVersion` reads it (include its output when reporting an issue).

## Setup

```powershell
Import-Module "<module-path>" -Force
```

## Full Lifecycle (Zero Dialogs)

Run the whole lifecycle in ONE persistent PowerShell session (or the MCP server). Every step polls until its state is reached: do not add `Start-Sleep`.

```powershell
# 1. Connect (one-step with -SolutionPath)
$r = Connect-TcIde -SolutionPath "C:\Projects\MyProject.sln"

# 1b. Target + solution platform (read from the target, switched to it)
Set-TcTarget -AmsNetId $r.data.amsNetId -Platform 'TwinCAT OS (x64)'

# 2. Build (BUILD_FAILED -> data.errorItems)
Build-TcProject

# 3. One step: Config -> Activate -> wait Run -> Login+Download -> wait port 851 -> PLC Run
Enable-TcConfig -Force

# 4. ADS (AmsNetId auto-detected from the IDE target; auto-reconnects after a later Enable-TcConfig)
Connect-TcAds

# 5. Read / write
Read-TcVariable -Path "MAIN.nCounter"
Write-TcVariable -Path "MAIN.bEnable" -Value $true   # confirm with the user first
```

`Enable-TcConfig -Force` includes Login and PLC Run; `-NoLogin` skips download / Run. Separate steps (`Enter-TcPlcOnline`, `Set-TcPlcState`) are only needed for finer control.

## Failure contract (fail closed, #68)

`success: true` only means the readback reached the target state. When a lifecycle command returns `success: false`, or `error.code` is `LIFECYCLE_BLOCKED`, or the result carries `data.lifecycleBlock`, or a state you read back differs from what you expected:

1. **Stop** every step that changes the runtime. Mark the remaining steps NOT RUN.
2. **Report** the result (`data.lifecycleBlock`, `data.steps`, `data.finalCheck`) to the user as it is. Read-only diagnosis is fine.
3. **Do not fall back** to raw ADS `WriteControl`, `StartRestartTwinCAT`, `DTE.ExecuteCommand`, the GUI, the `TcSystemServiceUm` console, or a re-`Connect-TcIde` after Activate.
4. `Clear-TcLifecycleBlock` (MCP `ClearLifecycleBlock`) **only after the user has seen the block and agreed**, with the receipt fields `-Reason`, `-FallbackMethod`, `-AllowedSideEffects`, `-MaxVerifyLevel`. Never to get past `LIFECYCLE_BLOCKED` on your own.
5. Confirm with the user before `Enable-TcConfig`, `Write-TcVariable`, `Set-TcSystemState` (Config stops the runtime, outputs go to zero), `Set-TcPlcState` (Reset kills `TcSystemServiceUm` on a UmRT target) and `Invoke-TcTestCycle`.

Details: https://github.com/Lance0901/AI-TwinCAT-Skill/blob/master/adapters/claude-code/SKILL.md ("Failure contract") and docs/troubleshooting.md "LIFECYCLE_BLOCKED".

## All Commands

Generated from the module (`scripts/Update-GeneratedDocs.ps1`); the table is the same one as in `adapters/claude-code/SKILL.md`, which also has the hand-written usage notes per cmdlet.

<!-- generated:cmdlet-signatures -->
<!-- 由 scripts/Update-GeneratedDocs.ps1 從 Get-Command 與 mcp-server/tools.json 產生,不要手改;上面的表是手寫的用法說明。 -->

| Cmdlet | MCP tool | 參數(`[ ]` = 選填;切換參數不帶值) |
|---|---|---|
| `Add-TcAdsRoute` | `AddAdsRoute` | `-Name <string> -NetId <string> [-Address <string>] [-HostName <string>] [-UserName <string>] [-PasswordEnv <string>] [-Password <securestring>] [-LocalName <string>] [-ProjectRoute] [-DryRun <bool>]` |
| `Add-TcComModule` | `AddTcComModule` | `-Name <string> [-ClassId <string>] [-TypeName <string>] [-DryRun <bool>]` |
| `Add-TcDut` | `AddDut` | `-Name <string> -DutType <string> [-Fields <obj>] [-AliasType <string>]` |
| `Add-TcGvl` | `AddGvl` | `-Name <string> [-Variables <obj>]` |
| `Add-TcInterface` | `AddInterface` | `-Name <string> [-Extends <string>] [-PlcProjectPath <string>]` |
| `Add-TcLibrary` | `AddLibrary` | `-Name <string> [-Version <string>] [-Vendor <string>] [-PlcProjectPath <string>]` |
| `Add-TcLibraryPlaceholder` | `AddPlaceholder` | `-Placeholder <string> [-LibraryName <string>] [-Version <string>] [-Distributor <string>] [-PlcProjectPath <string>]` |
| `Add-TcNcAxis` | `AddNcAxis` | `-Name <string> [-Task <string>] [-AxisType <string>] [-DryRun <bool>]` |
| `Add-TcNcTask` | `AddNcTask` | `[-Name <string>] [-DryRun <bool>]` |
| `Add-TcPlcTask` | `AddPlcTask` | `-Name <string> -CycleTimeUs <int> [-Priority <int>] [-PlcProjectPath <string>] [-DryRun <bool>]` |
| `Add-TcPou` | `AddPou` | `-Name <string> -Type <string> [-ReturnType <string>] [-PlcProjectPath <string>]` |
| `Add-TcPouMember` | `AddPouMember` | `-ParentPath <string> -Kind <string> [-Name <string>] [-ReturnType <string>] [-Access <string>] [-Language <string>]` |
| `Add-TcTaskProgram` | `LinkProgramToTask` | `-ProgramName <string> [-PlcTask <string>] [-PlcProjectPath <string>] [-DryRun <bool>]` |
| `Build-TcProject` | `BuildProject` | `[-TimeoutSec <int>] [-ExpectedProject <string[]>] [-AllowUnresolvedLibrary]` |
| `Clear-TcLifecycleBlock` | `ClearLifecycleBlock` | `[-AmsNetId <string>] [-Reason <string>] [-FallbackMethod <string>] [-AllowedSideEffects <string[]>] [-MaxVerifyLevel <string>]` |
| `Clear-TcProject` | `CleanProject` | `[-TimeoutSec <int>] [-AllowUnresolvedLibrary]` |
| `Connect-TcAds` | `ConnectAds` | `[-AmsNetId <string>] [-Port <int>]` |
| `Connect-TcIde` | `ConnectIde` | `[-ProgId <string>] [-SolutionPath <string>] [-NoLaunch] [-LaunchIfBlocked]` |
| `Connect-TcNcAxisToPlc` | `LinkNcAxis` | `-Axis <string> -PlcVariable <string> [-PlcProjectPath <string>] [-DryRun <bool>]` |
| `Disconnect-TcAds` | `DisconnectAds` | - |
| `Disconnect-TcIde` | `DisconnectIde` | `[-Quit] [-Kill]` |
| `Enable-TcConfig` | `EnableConfig` | `[-Force] [-NoLogin] [-TimeoutSec <int>] [-NoPlatformFix] [-Platform <string>] [-PlcProjectPath <string[]>] [-ActivateTimeoutSec <int>]` |
| `Enter-TcPlcOnline` | `PlcLogin` | `[-PlcProjectPath <string>] [-LoginMode <string>] [-SilentFlag] [-TimeoutSec <int>]` |
| `Exit-TcPlcOnline` | `PlcLogout` | `[-PlcProjectPath <string>]` |
| `Export-TcPlcOpen` | `ExportPlcOpen` | `[-Selection <string[]>] -FilePath <string> [-PlcProjectPath <string>] [-Overwrite]` |
| `Export-TcTreeItem` | `ExportChild` | `-Path <string> -FilePath <string>` |
| `Find-TcAdsTarget` | `FindAdsTargets` | `[-Search <string>]` |
| `Get-TcAdsRoutes` | `GetAdsRoutes` | - |
| `Get-TcAutomationVersion` | `GetAutomationVersion` | `[-Verify]` |
| `Get-TcBuildErrors` | `GetBuildErrors` | `[-IncludeWarnings] [-IncludeMessages] [-TimeoutSec <int>]` |
| `Get-TcComModuleParameter` | `GetTcComParameter` | `-Module <string> [-Name <string>] [-ParameterId <string>] [-Online]` |
| `Get-TcIdeInfo` | `GetIdeInfo` | - |
| `Get-TcIdeModalDialog` | `GetIdeModalDialog` (composite) | `[-ProcessId <int>] [-TimeoutSec <int>]` |
| `Get-TcIoTree` | `GetIoTree` | - |
| `Get-TcLibraries` | `GetLibraries` | `[-Repository] [-Filter <string>] [-PlcProjectPath <string>]` |
| `Get-TcPlcState` | `GetPlcState` | - |
| `Get-TcPouCode` | `GetPouCode` | `-PouName <string> [-PouPath <string>]` |
| `Get-TcProjectTree` | `GetProjectTree` | `[-Depth <int>] [-PlcOnly]` |
| `Get-TcProjectVariants` | `GetVariants` | - |
| `Get-TcSymbols` | `GetSymbols` | `[-Filter <string>]` |
| `Get-TcSystemState` | `GetSystemState` | `[-AmsNetId <string>]` |
| `Get-TcTreeItem` | `LookupTreeItem` | `-Path <string> [-MaxChildren <int>]` |
| `Get-TcTreeItemXml` | `ProduceXml` | `-Path <string> [-Recursive]` |
| `Import-TcPlcOpen` | `ImportPlcOpen` | `-FilePath <string> [-Option <string>] [-PlcProjectPath <string>] [-DryRun <bool>]` |
| `Import-TcTreeItem` | `ImportChild` | `-Path <string> -FilePath <string> [-Before <string>] [-Reconnect <bool>] [-Name <string>] [-DryRun <bool>]` |
| `Install-TcLibrary` | `InstallLibrary` | `-LibraryPath <string> [-Repository <string>] [-DryRun <bool>] [-PlcProjectPath <string>]` |
| `Invoke-TcIoScan` | `IoScan` | `[-Apply]` |
| `Invoke-TcTest` | `RunTest` | `-TestCase <psobject>` |
| `Invoke-TcTestCycle` | `RunTestCycle` | `-TestCases <psobject[]> [-SkipBuild] [-KeepRunning]` |
| `Lock-TcLibraryPlaceholder` | `FreezePlaceholder` | `[-Placeholder <string>] [-All] [-DryRun <bool>] [-PlcProjectPath <string>]` |
| `New-TcBootProject` | `GenerateBootProject` | `[-PlcProjectPath <string>]` |
| `New-TcIssueReport` | `ReportIssue` | `-Title <string> [-Tool <string>] [-Parameters <obj>] [-Result <obj>] [-Expected <string>] [-Notes <string>] [-Label <string>] [-MaxUrlLength <int>] [-ExtraMask <string[]>] [-NoEnvironment] [-IncludeSolutionName]` |
| `New-TcProject` | - | `-Name <string> [-Path <string>]` |
| `New-TcTestCase` | `NewTestCase` | `-Name <string> [-Setup <hashtable[]>] [-Teardown <hashtable[]>] [-WaitUntil <hashtable[]>] [-WaitTimeoutMs <int>] [-WaitMs <int>] -Assertions <hashtable[]>` |
| `New-TcTreeItem` | `CreateChild` | `-Path <string> -Name <string> [-SubType <int>] [-Before <string>] [-VInfo <obj>] [-DryRun <bool>]` |
| `Open-TcProject` | `OpenProject` | `-Path <string>` |
| `Read-TcVariable` | `ReadVariable` | `-Path <string[]>` |
| `Remove-TcLibraryReference` | `RemoveReference` | `-Name <string> [-Kind <string>] [-DryRun <bool>] [-PlcProjectPath <string>]` |
| `Remove-TcTaskProgram` | `UnlinkProgramFromTask` | `-ProgramName <string> [-PlcTask <string>] [-PlcProjectPath <string>] [-DryRun <bool>]` |
| `Remove-TcTreeItem` | `DeleteChild` | `-Path <string> -ConfirmName <string> [-DryRun <bool>] [-AllowNoExport]` |
| `Remove-TcVariableLink` | `RemoveVariableLink` | `-PlcVariable <string> [-IoChannel <string>]` |
| `Reset-TcSolution` | `ResetSolution` | `[-SolutionPath <string>] [-TimeoutSec <int>] [-DiscardProjectChanges] [-SaveProjectChanges]` |
| `Save-TcArchive` | `SaveArchive` | `-FilePath <string> [-Kind <string>] [-Overwrite]` |
| `Save-TcPlcLibrary` | `SaveAsLibrary` | `-FilePath <string> [-PlcProjectPath <string>] [-Overwrite]` |
| `Send-TcPlcProgram` | `SendPlcProgram` | `[-PlcProjectPath <string>]` |
| `Set-TcComModuleContext` | `SetTcComContext` | `-Module <string> -Task <string> [-ContextId <int>] [-DryRun <bool>]` |
| `Set-TcComModuleParameter` | `SetTcComParameter` | `-Module <string> [-Name <string>] [-ParameterId <string>] -Value <obj> [-Online] [-DryRun <bool>]` |
| `Set-TcCurrentVariant` | `SwitchVariant` | `-Name <string> [-DryRun <bool>]` |
| `Set-TcIndependentFile` | `SetIndependentFile` | `-Path <string> -Enabled <bool> [-DryRun <bool>]` |
| `Set-TcNcAxisParameter` | `SetNcAxisParameter` | `-Axis <string> [-MaxVelocity <double>] [-Acceleration <double>] [-Deceleration <double>] [-Jerk <double>] [-EncoderType <int>] [-DriveType <int>] [-ControllerType <int>] [-DryRun <bool>]` |
| `Set-TcPlcState` | `SetPlcState` | `-State <string> [-TimeoutSec <int>]` |
| `Set-TcProjectVariantConfig` | `SetVariantConfig` | `[-AddVariant <string[]>] [-RemoveVariant <string[]>] [-Group <string>] [-DryRun <bool>]` |
| `Set-TcSystemState` | `SetSystemState` | `-State <string> [-AmsNetId <string>] [-TimeoutSec <int>] [-SettleSec <int>]` |
| `Set-TcTarget` | `SetTarget` | `-AmsNetId <string> [-Platform <string>] [-Configuration <string>] [-NoPlatformSwitch]` |
| `Set-TcTreeItemXml` | `ConsumeXml` | `-Path <string> -Xml <string> [-DryRun <bool>]` |
| `Set-TcVariableLink` | `SetVariableLink` | `-PlcVariable <string> -IoChannel <string>` |
| `Test-TcPlcProject` | `CheckAllObjects` | `[-PlcProjectPath <string>]` |
| `Uninstall-TcLibrary` | `UninstallLibrary` | `-LibraryName <string> -Version <string> -Distributor <string> [-Repository <string>] [-DryRun <bool>] [-PlcProjectPath <string>]` |
| `Watch-TcVariable` | `WatchVariable` | `-Path <string[]> [-IntervalMs <int>] [-DurationMs <int>] [-Until <string>] [-UntilTimeoutMs <int>] [-TimeoutMs <int>] [-KeepLast <int>]` |
| `Write-TcPouCode` | `WritePouCode` | `-PouName <string> [-Declaration <string>] [-Implementation <string>] [-PouPath <string>]` |
| `Write-TcVariable` | `WriteVariable` | `-Path <string> -Value <obj>` |
<!-- /generated -->
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
2. **Lifecycle order matters**: Build -> Activate -> Login -> ADS Connect -> Start (ADS port 851 only exists after Login+Download); `Enable-TcConfig -Force` does Activate, Login and Run in one step
3. **Don't reconnect IDE after Activate** — original COM reference survives TwinCAT XAR restart
4. **Write MAIN-level vars for FB testing** — PLC overwrites FB `VAR_INPUT` every scan cycle. Write standalone MAIN variables instead.
5. **Use -PouPath for Get/Write-TcPouCode** — format: `TIPC^<PlcName>^<PlcName> Project^POUs^<PouName>`
