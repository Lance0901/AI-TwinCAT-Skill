<#
.SYNOPSIS
    Generates mcp-server/tools.json (MCP tool definitions) from the TwinCATAutomation module.

.DESCRIPTION
    For every exported cmdlet of the module this script
      * takes the MCP tool name from the $operationMap of Invoke-TwinCATAutomation.ps1
        (CLI action name -> cmdlet), falling back to "<Verb><Noun without Tc>",
      * builds a JSON schema from the cmdlet's parameters (types, ValidateSet,
        ValidateRange, literal default values, Mandatory -> required),
      * takes descriptions from comment-based help, overridden by $descriptionOverrides
        for the tools where the help alone is not enough,
      * assigns a per-tool timeout (ms) used by the Node side.

    Run it again whenever a cmdlet signature changes:
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/Export-ToolSchema.ps1

.PARAMETER ModulePath
    TwinCATAutomation.psm1. Default: ../../src/TwinCATAutomation/TwinCATAutomation.psm1.
.PARAMETER CliPath
    Invoke-TwinCATAutomation.ps1 (source of $operationMap). Default: ../../Invoke-TwinCATAutomation.ps1.
.PARAMETER OutPath
    Output file. Default: ../tools.json.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$ModulePath,

    [Parameter()]
    [string]$CliPath,

    [Parameter()]
    [string]$OutPath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# $PSScriptRoot is not populated while parameter defaults are evaluated in PS 5.1.
$scriptDir = Split-Path -Parent $PSCommandPath
if ([string]::IsNullOrWhiteSpace($ModulePath)) { $ModulePath = Join-Path $scriptDir '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1' }
if ([string]::IsNullOrWhiteSpace($CliPath)) { $CliPath = Join-Path $scriptDir '..\..\Invoke-TwinCATAutomation.ps1' }
if ([string]::IsNullOrWhiteSpace($OutPath)) { $OutPath = Join-Path $scriptDir '..\tools.json' }

$ModulePath = (Resolve-Path -LiteralPath $ModulePath).ProviderPath
$CliPath = (Resolve-Path -LiteralPath $CliPath).ProviderPath
if (-not [System.IO.Path]::IsPathRooted($OutPath)) {
    $OutPath = Join-Path (Get-Location).ProviderPath $OutPath
}
$OutPath = [System.IO.Path]::GetFullPath($OutPath)

# ---------------------------------------------------------------------------
# Hand-written tool descriptions (what an MCP client needs to know that the
# comment-based help does not say). Keys = tool names.
# ---------------------------------------------------------------------------
$descriptionOverrides = @{
    'ConnectIde'      = 'Connect to a running TwinCAT XAE / Visual Studio instance (found through the Running Object Table); only if none is found does it launch a new XAE. SolutionPath is optional and opens that .sln after connecting. Call this before any project, build or runtime tool. Returns ideProcessId, connectSec (total seconds), launchSec (only when a new IDE was launched: seconds until DTE was ready) and, when a solution is open, the detected target AmsNetId. When the IDE that has SolutionPath open is blocked by a modal dialog or busy (its DTE answers RPC_E_CALL_REJECTED or an empty Version), it is recognised without COM and IDE_MODAL_DIALOG (or IDE_BUSY without a dialog) is returned with data.ideProcessId, data.dialog, data.matchedBy and data.attached; no second IDE is launched. matchedBy module-state (the IDE this server was connected to), session-record (an earlier ConnectIde saw this process with this solution) or dialog-path (the dialog names a file in the solution folder) attach that IDE (attached=true): GetIdeModalDialog / ResetSolution work on it right away. window-title (title = solution name only; may be a same-named copy elsewhere) does not attach (attached=false); when that IDE is not yours, LaunchIfBlocked=true ignores it and launches. After the dialog is closed the same ConnectIde call connects to it.'
    'CleanProject'    = 'Clean the open solution (Build > Clean Solution) and wait until SolutionBuild.BuildState is Done (TimeoutSec default 300 -> CLEAN_TIMEOUT). Use instead of touching DTE yourself: issue #18 once hit a null-valued expression on Solution / SolutionBuild right after ConnectIde (cause not confirmed); this tool waits for them and counts the null answers (data.nullReads). A modal dialog returns IDE_MODAL_DIALOG. Readback SolutionBuild.LastBuildInfo: 0 -> success, data.cleanVerified=true; unreadable -> CLEAN_UNVERIFIED (always a failure); > 0 with only unresolved-library Error List rows (<plc>.Library Manager, no line) -> LIBRARY_UNRESOLVED (data.libraryErrorItems; a later BuildProject success may not have compiled the PLC code, #45), or with AllowUnresolvedLibrary=true success with data.warningCode=LIBRARY_UNRESOLVED and cleanVerified=false; any other error -> CLEAN_FAILED (data.errorItems). data: buildState, failedProjects, cleanVerified, cleanSec, nullReads, errorItems.'
    'DisconnectIde'   = 'Release the DTE/COM references held by the bridge. The IDE keeps running unless Quit=true, which closes the solution without saving and quits the IDE (only use on an IDE that ConnectIde launched). With Quit=true a modal dialog is checked first: if one is up nothing is attempted, nothing is released (the connection stays: for kind reload-prompt run ResetSolution, then DisconnectIde Quit=true again) and the result is IDE_QUIT_FAILED (data.dialog {title, text, kind, reloadTarget}, quit=false, disconnected=false); if DTE.Quit fails the result is also IDE_QUIT_FAILED (success=false, data.ideProcessId / quitError; the IDE process still runs). After a failure the IDE pid is kept, so DisconnectIde Quit=true Kill=true can follow directly without ConnectIde. Kill=true (only with Quit=true) kills the IDE process in those two cases, but only when this session launched it (data.ownedBySession, still true after the internal reconnect of ResetSolution), otherwise IDE_NOT_OWNED and nothing is killed; data.killed tells whether it was killed. COM references are always released.'
    'ResetSolution'   = 'Reload every project file from disk: dismisses the reload prompt if it is up (data.dismissedReloadPrompt). The XAE project prompt "The project file ... has been modified outside of TwinCAT XAE. Do you want to reload the project?" (a rewritten .plcproj; GetIdeModalDialog kind reload-prompt, reloadTarget project) is answered Yes by dialog control id (any UI language) and XAE reloads the project itself: then only ConnectIde runs again, no close / reopen (data.answeredYes=true, data.reopenedSolution=false, data.reloadTarget). Otherwise it closes all documents without saving (data.closedDocuments), Solution.Close, Solution.Open of the same .sln on the same IDE, then ConnectIde again (20-25 s in total, data.totalSec). Use right after .TcPOU / .plcproj files were changed ON DISK by another tool while they are open in an XAE editor: otherwise XAE shows the modal "File has been changed outside the environment. Reload the new file?" (GetIdeModalDialog kind reload-prompt) and every call blocks. A file that is not open in an editor is picked up automatically within ~5 s and needs no call; WritePouCode writes the IDE edit buffer through COM and never needs it (the file on disk is only written on save / BuildProject). Any other modal dialog is reported as IDE_MODAL_DIALOG. The ADS connection is kept.'
    'GetIdeInfo'      = 'Return version, edition, open solution, ITcSysManager availability and the active solution platform / configuration (solutionPlatform, solutionConfiguration; null when unreadable) of the connected IDE. Cheap connectivity check; fails with NOT_CONNECTED before ConnectIde.'
    'BuildProject'    = 'Build the PLC project of the open solution and wait for the result. On BUILD_FAILED read data.codeErrors (description/file/line taken from the XAE Error List) instead of guessing. data.errors counts CODE errors only; missing / unresolved libraries (Library Manager rows such as "Could not open library") are counted separately in data.libraryErrors and listed in data.libraryErrorItems. With library errors the PLC code may not have been compiled at all (no code error is then reported), so a build that would otherwise succeed returns LIBRARY_UNRESOLVED (success=false, buildSucceeded=null, codeVerified=false): install the missing libraries in the XAE Library Manager first; AllowUnresolvedLibrary=true accepts it as success with data.warningCode=LIBRARY_UNRESOLVED. data.codeVerified=true means the Error List was read, lists no library error and no code row without a line, and every PLC project took part in the build: a PLC project skipped by the configuration (or none in the solution) gives codeVerified=false and data.warningCodes [PROJECT_SKIPPED_BY_CONFIGURATION, CODE_NOT_VERIFIED] (#58); a success that is not verified that way (Error List unreadable, unlocated code rows) carries data.warningCode=CODE_NOT_VERIFIED. data.warningCodes lists every warning code (data.warningCode is the first). Breaking change (#23): data.errors no longer includes Library Manager rows. data.errorItems keeps every Error List error, each with category code | library | other (other = no file, e.g. a build-summary row). data.decidedBy says what decided buildSucceeded (LastBuildInfo, else ErrorList). Warnings come with their contents: data.warningItems (same shape) and data.codeWarnings (without Library Manager items), unless data.errorListError is set. A full build can take several minutes: the build is started asynchronously and SolutionBuild.BuildState is polled (the synchronous VS2022 call never returns); TimeoutSec (default 600) bounds the wait, after which BUILD_TIMEOUT is returned; a modal dialog that appears during the build is returned as IDE_MODAL_DIALOG. Requires ConnectIde with an open solution. Coverage: data.projects lists every PLC project (.plcproj) with status built / skipped / failed / unknown (from the active solution configuration, DTE SolutionContext.ShouldBuild), data.skippedProjects and data.coverageComplete. data.solutionConfiguration is ''<configuration>|<solution platform>'' read like GetIdeInfo (data.solutionPlatform equals GetIdeInfo solutionPlatform), data.projectPlatform the .tsproj project platform, data.platformSource how the solution platform was read (with ''context'' solutionConfiguration is the configuration name only); each PLC project''s own platform is data.projects[].platform. BUILD_REQUIRED (after a platform switch) is cleared only by a build with coverageComplete=true and codeVerified=true (or an AllowUnresolvedLibrary build with library rows only). A PLC project that the active solution configuration does not build (no Build.0 in the .sln) is skipped silently by XAE while it still says Build succeeded: the result keeps success but sets data.warningCode=PROJECT_SKIPPED_BY_CONFIGURATION and data.warning. ExpectedProject=[names] makes a skipped project a failure (PROJECT_SKIPPED_BY_CONFIGURATION, build not started), an unknown name EXPECTED_PROJECT_NOT_FOUND; use it whenever a specific PLC (e.g. a unit-test PLC) must be compiled.'
    'GetBuildErrors'  = 'Read the compiler messages currently shown in the XAE Error List: data.counts {errors, warnings, messages}, data.errors[] and data.warnings[] (IncludeWarnings defaults to true; IncludeWarnings=false skips the warning toggle and saves 1-2 s); IncludeMessages=true adds data.messages[]. Items are {severity, code, description, project, file, line, column}. Counts are read from the summary buttons in English and zh-TW UI (zh-TW VS2022 ''shown / total'' labels report the total); other UI languages return ERRORLIST_UNAVAILABLE. In VS2022 the Error List scope filter is switched from Current Project / Current Document / Open Documents to Entire Solution before reading (left switched).'
    'EnableConfig'    = 'Activate the configuration on the target without any dialog. Restarts TwinCAT and downloads/starts the PLC program: the machine stops and restarts. Confirm with the user first. With Force=true it runs the whole lifecycle: Config -> Activate -> wait for Run -> PLC Login+Download -> wait for port 851 -> PLC Run, and reports every step in data.steps. NoLogin=true stops after TwinCAT is in Run (no download, no PLC Run). TwinCAT restarts, so call ConnectAds again afterwards (ReadVariable/WriteVariable also auto-reconnect; data.reconnected tells you). Never add sleeps around this call; it polls until the target state is reached. Before Activate the active solution platform is compared with the platform the target reports through TARGETINFO (ADS port 200, IG 0x700; data.platformCheck=''target''), else with Platform when given (''parameter''); the solution platform and the project platform of its .tsproj must both match; on a mismatch the solution platform is switched and the project rebuilt (steps platform-fix, platform-fix-build; data.platformFixed=true; not part of TimeoutSec). NoPlatformFix=true returns PLATFORM_MISMATCH instead, before anything is activated. A solution platform with the right name whose .tsproj is built for another project platform makes the switch return PLATFORM_PROJECT_MISMATCH (data.platformMap, data.requestedProjectPlatform; fix the Configuration Manager). A target without TARGETINFO (ADS 0x702, e.g. the UmRT of TwinCAT 3.1.4026.21-22) and no Platform: platformCheck=''skipped'', data.warning set, Activate runs as before. data always has targetPlatform, targetPlatformSource (adsTargetInfo / unavailable), solutionPlatform, projectPlatform (.tsproj project platform), platformFixed, platformCheck. ACTIVATE_FAILED = ActivateConfiguration() returned but XAE reported failed projects (''Check config failed!''; nothing written to the target), usually because the active solution platform (data.solutionPlatform) differs from the target platform: retry with Platform (''TwinCAT OS (x64)'' for a Usermode Runtime / UmRT or TwinCAT/BSD, ''TwinCAT RT (x64)'' for a Windows RT target). Multi-PLC: every PLC project (or PlcProjectPath) is logged in and started on its own ADS port (851, 852, ...; data.plcs). After Activate the project _Boot package is compared with the Boot folder of a target on this PC (data.bootPackage, BOOT_PACKAGE_MISMATCH). Step verify reads back port 10000 and every PLC port at the end and checks for a modal dialog: anything not Run is RUNTIME_STATE_MISMATCH (data.finalCheck), never success; failures after Activate carry data.diagnostics (dialog, Error List rows, bootPackage).'
    'SetTarget'       = 'Set the target AmsNetId (ITcSysManager.SetTargetNetId, always done first: data.amsNetId, data.targetSet=true even when the result is an error) and make the active solution platform follow the target. The target decides the platform: the active solution platform must match it (Usermode Runtime / UmRT and TwinCAT/BSD = ''TwinCAT OS (x64)'', Windows RT target = ''TwinCAT RT (x64)''), otherwise EnableConfig fails with ACTIVATE_FAILED. Before switching, the project platform of the .tsproj under the chosen solution platform is checked: a solution platform that maps to another project platform (e.g. ''TwinCAT OS (x64)'' -> ''TwinCAT OS (ARMT2)'') returns PLATFORM_PROJECT_MISMATCH and nothing is switched (data.platformMap). With Platform that platform is activated for Configuration (default Release; data.platformCheck=''parameter''). Without Platform the platform the target reports through TARGETINFO (ADS port 200, IG 0x700) is activated (''target''); not in the solution -> PLATFORM_NOT_FOUND. Target without TARGETINFO (ADS 0x702, data.adsError) and no Platform -> PLATFORM_UNKNOWN (NetId already set; nothing guessed). NoPlatformSwitch=true only sets the NetId (''disabled''). Returns data.platform (solution platform) / projectPlatform (active .tsproj) / requestedProjectPlatform / platformChanged / targetPlatform / targetPlatformSource and, when a platform was activated, configuration / previousPlatform / availablePlatforms / projectCheck / platformMap.'
    'ConnectAds'      = 'Open the ADS connection to the PLC runtime. Leave AmsNetId empty: it is auto-detected from the IDE target and changes per target (local UmRT, remote CX ...), so never hardcode it. Port defaults to 851 (PLC runtime 1). Requires ConnectIde for auto-detection.'
    'DisconnectAds'   = 'Close the ADS connection and forget the cached endpoint (disables auto-reconnect).'
    'ReadVariable'    = 'Read one or more PLC variables by symbol path (e.g. ["MAIN.nCounter","GVL.bRun"]) via ADS. Path is always an array, even for a single variable. One path: data is the entry (an unknown symbol fails with SYMBOL_NOT_FOUND); several paths: data is an array with one entry per path, a path that could not be read is {path, error, code, hint} inside it, so check every entry. Each entry has path, value, type: BOOL/integers/REAL/STRING are plain values; TIME/TOD, LTIME/LTOD, DATE/DT, LDATE/LDT return the IEC literal in value ("T#6s", "DT#2026-10-20-12:30:00") plus the raw integer in ms (TIME/TOD), ns (LTIME/LTOD/LDATE/LDT) or unix (DATE/DT); enums return the integer in value plus the member name in name; STRUCT/ARRAY return the raw bytes in value plus size. Requires ConnectAds (auto-reconnects after EnableConfig).'
    'WriteVariable'   = 'Write a single PLC variable by symbol path via ADS. Writes directly into the running PLC; may drive outputs or axes. Confirm with the user first. Value is converted to the PLC type of the symbol: JSON bool for BOOL, number for integer/REAL types, string for STRING; TIME/TOD take an IEC literal ("T#6s", "T#1m30s500ms", "TOD#12:30:00"; integer ms also accepted), LTIME/LTOD "LTIME#1us" (or integer ns), DATE/DT "D#2026-10-20" / "DT#2026-10-20-12:30:00" / ISO 8601 (or integer seconds since 1970), enums an integer or the member name. STRUCT/ARRAY cannot be written as a whole (TYPE_MISMATCH): write their members. data.written is the value actually written: the normalized literal for time types ("T#6000ms" -> "T#6s", raw integer in ms/ns/unix), the converted number otherwise, plus name for enums. Requires ConnectAds.'
    'WatchVariable'   = 'Poll one or more PLC variables (Path is an array; every round reads each path in order) every IntervalMs. Without Until it samples for DurationMs (default 2000). With Until it waits for a condition ''<Path> <op> <value>'' (op: == != > < >= <=, e.g. ''MAIN.fTarget == 123.5'' or ''MAIN.bDone == TRUE''; <Path> must be one of Path) and returns as soon as it holds or after UntilTimeoutMs (default 5000): data.untilMet, untilSample, elapsedMs. Numbers compare numerically, TRUE/FALSE as booleans, other values as case-insensitive text; a failed read never satisfies the condition. Only the last KeepLast samples are returned (default 20 with Until, 50 without); sampleCount is the total and truncated tells whether older samples were dropped. Single-path samples are {timestamp, value} plus ms/ns/unix for TIME/DATE types and name for enums (same conversion as ReadVariable; a numeric Until value compares with that raw integer, text with the IEC literal / enum member name), multi-path samples {timestamp, values:{<path>:<value>}}. Use Until instead of a long DurationMs or repeated ReadVariable calls. Requires ConnectAds.'
    'GetSymbols'      = 'List the PLC symbols of the connected runtime, optionally filtered by a substring (Filter): data is an array (empty when nothing matches) of {path, type, size, comment}, plus enumValues (member name -> value) for enum types; the execution order is in the top-level order field. Use it to find exact variable paths and types before ReadVariable/WriteVariable.'
    'GetPlcState'     = 'Read the PLC runtime state (Run/Stop/...) on the connected ADS port.'
    'SetPlcState'     = 'Switch the PLC runtime to Run, Stop or Reset and wait for the state. WARNING: on a UmRT (user-mode runtime) target, Reset kills TcSystemServiceUm and you must EnableConfig again. Prefer Run/Stop.'
    'PlcLogin'        = 'Login to the PLC project and download the program in one call (PLC_LOGIN_FLAGS Regular, prompts answered by SilentMode, no dialogs). Use after a successful BuildProject when TwinCAT is already in Run; EnableConfig Force=true already includes this step. With several PLC projects pass PlcProjectPath (PLC name such as FrameworkUnitTest or tree path); without it PLC_PROJECT_AMBIGUOUS is returned instead of logging into the first PLC. data.adsPort is the PLC''s ADS port.'
    'PlcLogout'       = 'Log out of the PLC project (the runtime keeps running). With several PLC projects pass PlcProjectPath (PLC name or tree path); without it PLC_PROJECT_AMBIGUOUS. data.plcProjectPath / data.adsPort tell which PLC was logged out.'
    'GetSystemState'  = 'Read the TwinCAT system state (Run/Config) of a target over ADS port 10000. AmsNetId defaults to the IDE target (ConnectIde), then the ADS session (ConnectAds), then the local system 127.0.0.1.1.1; data.amsNetId / data.netIdSource tell which one was used. netIdSource=local means you read the local TwinCAT system, which is usually NOT your target.'
    'SetSystemState'  = 'Switch TwinCAT to Run or Config via ADS WriteControl (no StartRestartTwinCAT dialog) and poll until the state is reached. Switching to Config stops the runtime: all outputs go to zero. Does not download the PLC program; EnableConfig Force=true is the usual choice. Run sends AdsState Reset (2) and Config sends Reconfig (16) on port 10000 (data.sentAdsState; Run (5) is refused there with ADS 0x701). After the target state is seen it must hold for SettleSec (default 3 s) and is read back (data.readbackState, data.stateTrace): a runtime that falls back to Config (e.g. ADS 1809 symbol version invalid) returns SYSTEM_STATE_MISMATCH, never success. When the original state equals the target (Run -> Run restart) the system must first be seen leaving it. data: originalState, finalState, reached, held, leftOriginal, latencyMs; when it stays in / falls back to Config the license server (ADS port 30) is read and expired / invalid licenses are put into error.hint and data.licenses.'
    'SendPlcProgram'  = 'Download the compiled PLC program to the target (alias of PlcLogin: Login+Download without dialogs).'
    'RunTestCycle'    = 'Builds, activates (TwinCAT restart) and runs the PLC: changes the running machine. Confirm with the user first. Full automated test cycle: build (unless SkipBuild), activate configuration, login, run every test case from NewTestCase, then stop the PLC (unless KeepRunning). Returns per-test results. Can take many minutes (timeout 900 s).'
    'RunTest'         = 'Execute one test case created with NewTestCase (setup writes -> wait -> assertions -> teardown writes) against the connected PLC. Requires ConnectAds.'
    'NewTestCase'     = 'Build a test case object for RunTest/RunTestCycle. Setup/Teardown are arrays of {Path, Value} writes; Assertions are {Path, Operator, Expected} with Operator one of Equal (default), NotEqual, GreaterThan, LessThan, GreaterThanOrEqual, LessThanOrEqual, Contains, IsTrue, IsFalse. Pure data, no IDE/PLC access.'
    'OpenProject'     = 'Open a solution (.sln) in the connected IDE and wait until the TwinCAT project is loaded.'
    'IoScan'          = 'Scan the I/O devices (EtherCAT ...) of the target and add them to the I/O tree. Requires the target in Config mode.'
    'GetProjectTree'  = 'Read the project tree. Every node has name, path, type, itemType, subType and children; path can be passed as-is to GetPouCode / WritePouCode PouPath. type is the item kind from ItemType (Project, Folder, FunctionBlock, Function, Program, Dut, Gvl, Task, References ...) or the numeric ItemType when unknown (itemType / subType are also returned as numbers). The PLC node TIPC^<Plc> also lists "<Plc> Project" with its POUs, DUTs and GVLs folders (on 4024 and 4026 the project node is hidden from enumeration and is added by path). Depth (default 4) = levels below each root, enough for TIPC^<Plc>^<Plc> Project^POUs^<POU>; a node at the depth limit that still has children comes back with children=[] and truncated=true. PlcOnly=true returns only the TIPC subtree.'
    'AddPou'          = 'Create a POU (Program, FunctionBlock or Function, language ST) in <Plc> Project^POUs (or PlcProjectPath) and read it back: success only when the new item is found with the expected kind. data: path, folderPath, objectKind (POU), itemType (602 Program / 603 Function / 604 FunctionBlock), language (read back from the new item, must be ST), declaration (default header written by XAE; a Function header must contain : ReturnType). Then fill it with WritePouCode. A POU / DUT / GVL / ITF with the same name anywhere in the same PLC project -> POU_CREATE_FAILED with its path (nothing created; data.duplicateCheckScope = project, or folder when the project has more than 3000 nodes); a failed readback names the step and that the object stays in the tree (error.hint says what to do). A modal dialog in XAE -> IDE_MODAL_DIALOG before anything is created.'
    'AddDut'          = 'Create a DUT (Struct / Enum / Union / Alias) in <Plc> Project^DUTs, write its declaration (TYPE ... END_TYPE from Fields / AliasType; an Enum without Fields gets enum_member := 0) and read it back. data: path, objectKind (DUT), itemType (605 Enum / 606 Struct / 607 Union / 623 Alias), declaration. A name that already exists or a declaration that reads back different -> DUT_CREATE_FAILED. Change it later with WritePouCode Declaration only (a DUT has no implementation).'
    'AddGvl'          = 'Create a GVL in <Plc> Project^GVLs, write VAR_GLOBAL ... END_VAR from Variables and read it back. data: path, objectKind (GVL), itemType 615, declaration. A name that already exists or a declaration that reads back different -> GVL_CREATE_FAILED. Change it later with WritePouCode Declaration only (a GVL has no implementation).'
    'GetPouCode'      = 'Read the source of a PLC object: POU, DUT, GVL, interface, method ... data.objectKind (POU / DUT / GVL / ITF / METHOD / ACTION / PROPERTY_GET / ... / UNKNOWN, from the tree item ItemType; data.itemType, data.itemTypeName), data.pouType (Program / Function / FunctionBlock for a POU, Struct / Enum / Union / Alias for a DUT), data.language (ST / LD / FBD ..., null for DUT / GVL / ITF), data.hasImplementation, data.implementationReadable, data.declaration, data.implementation. hasImplementation=false (DUT, GVL, ITF, property): implementation is null because the object has no implementation part, the whole source is in declaration. A POU returns an implementation string (empty when there is no code; LD / FBD return XAE XML, not ST); implementationReadable=false means it has an implementation part that did not come back as text (implementation null). A COM call that throws, or a declaration that reads null, returns POU_READ_FAILED.'
    'WritePouCode'    = 'Write Declaration and/or Implementation of an existing PLC object through the XAE edit buffer (no ResetSolution needed). DUT / GVL / ITF / property have only a declaration: passing Implementation for one of them returns INVALID_PARAMS and nothing is written (data.objectKind; for a property the hint points to its ^Get / ^Set accessor); send the whole TYPE ... END_TYPE / VAR_GLOBAL ... END_VAR as Declaration. data: pouPath, resolvedBy, objectKind, updated[]. Run BuildProject afterwards to compile.'
}

# Per-tool timeouts in ms (Node side kills and restarts the bridge when exceeded).
$defaultTimeoutMs = 120000
$timeoutOverrides = @{
    'BuildProject'   = 660000
    'CleanProject'   = 330000
    'EnableConfig'   = 600000
    'RunTestCycle'   = 900000
    'ConnectIde'     = 180000
    'OpenProject'    = 180000
    'ResetSolution'  = 180000
    'PlcLogin'       = 300000
    'SendPlcProgram' = 300000
    'SetSystemState' = 180000
    'SetPlcState'    = 180000
    'IoScan'         = 180000
}

# MCP tool annotations (https://modelcontextprotocol.io: ToolAnnotations).
# readOnlyHint: no side effects on IDE/project/runtime.
# destructiveHint: changes the running machine / runtime / connection state in a way
# that cannot simply be undone. Everything else (project edits, connecting) is
# readOnlyHint=false, destructiveHint=false.
$readOnlyTools = @(
    'GetIdeInfo', 'GetProjectTree', 'GetPouCode', 'GetIoTree', 'GetBuildErrors', 'GetSymbols',
    'GetPlcState', 'GetSystemState', 'ReadVariable', 'WatchVariable', 'NewTestCase'
)
$destructiveTools = @(
    'EnableConfig', 'SetSystemState', 'SetPlcState', 'WriteVariable', 'RunTest', 'RunTestCycle',
    'PlcLogin', 'SendPlcProgram', 'IoScan', 'SetTarget', 'DisconnectIde', 'PlcLogout', 'ResetSolution'
)

function Get-ToolAnnotations {
    param([string]$ToolName)
    if ($readOnlyTools -contains $ToolName) { return [ordered]@{ readOnlyHint = $true } }
    if ($destructiveTools -contains $ToolName) { return [ordered]@{ readOnlyHint = $false; destructiveHint = $true } }
    return [ordered]@{ readOnlyHint = $false; destructiveHint = $false }
}

# Parameter description overrides: "<ToolName>.<ParamName>" = text.
$paramDescriptionOverrides = @{
    'ReadVariable.Path'       = 'Array of PLC symbol paths, e.g. ["MAIN.nCounter"]. Always an array, also for a single variable.'
    'WriteVariable.Value'     = 'New value matching the PLC type of the symbol: JSON bool (BOOL), number (integer/REAL/LREAL), string (STRING). TIME/TOD: "T#6s" / "T#1m30s500ms" / "TOD#12:30:00" (integer ms also accepted); LTIME/LTOD: "LTIME#1us" (or integer ns); DATE/DT: "D#2026-10-20", "DT#2026-10-20-12:30:00" or ISO 8601 (or integer seconds since 1970); LDATE/LDT: "LDT#..." (or integer ns); enum: integer or member name ("READY").'
    'ConnectAds.AmsNetId'     = 'Target AmsNetId. Leave empty to auto-detect from the IDE target (recommended; it differs per target).'
    'GetSystemState.AmsNetId' = 'Target AmsNetId. Leave empty to use the IDE target, then the ADS session, then the local system 127.0.0.1.1.1 (see data.netIdSource).'
    'SetPlcState.State'       = 'Run, Stop or Reset. Reset kills TcSystemServiceUm on a UmRT target.'
    'EnableConfig.Force'      = 'true = full lifecycle without dialogs (Config -> Activate -> Run -> Login/Download -> PLC Run).'
    'EnableConfig.NoLogin'    = 'true = stop after TwinCAT reaches Run; skip PLC login/download/Run.'
    'EnableConfig.AllowUnresolvedLibrary' = 'Passed to the build that follows an automatic platform switch: accept unresolved libraries (LIBRARY_UNRESOLVED) as success. After a platform switch EnableConfig refuses to activate (BUILD_REQUIRED) until a complete BuildProject (data.completeBuild=true: coverageComplete and codeVerified=true, or AllowUnresolvedLibrary with library errors only); the BUILD_REQUIRED message says why the last build did not count.'
    'RunTestCycle.AllowUnresolvedLibrary' = 'Passed to its BuildProject and EnableConfig steps: accept unresolved libraries (LIBRARY_UNRESOLVED) as success. Only when the user accepts that the PLC code may not have been compiled.'
    'EnableConfig.NoPlatformFix' = 'true = do not switch the solution platform; a mismatch with the target (or Platform) platform returns PLATFORM_MISMATCH before anything is activated.'
    'EnableConfig.Platform'   = 'Reference platform used only when the target does not report one through TARGETINFO (ADS 0x702): ''TwinCAT OS (x64)'' for a Usermode Runtime / UmRT or TwinCAT/BSD, ''TwinCAT RT (x64)'' for a Windows RT target. A platform the target reports wins.'
    'SetTarget.Platform'      = 'Solution platform to activate, e.g. ''TwinCAT OS (x64)'' (Usermode Runtime / UmRT, TwinCAT/BSD) or ''TwinCAT RT (x64)'' (Windows RT). Omit to follow the platform the target reports (TARGETINFO); a target without TARGETINFO then returns PLATFORM_UNKNOWN.'
    'SetTarget.Configuration' = 'Solution configuration name. With Platform default Release; for the automatic switch the active configuration.'
    'SetTarget.NoPlatformSwitch' = 'true = only set the target NetId; never touch the solution platform and never return PLATFORM_UNKNOWN.'
    'NewTestCase.Setup'       = 'Writes before the test: array of {"Path":"MAIN.x","Value":1} (keys Path = PLC symbol path, Value = value to write, converted to the PLC type).'
    'NewTestCase.Teardown'    = 'Writes after the test (also run when the test fails): array of {"Path":"MAIN.x","Value":0} (keys Path, Value).'
    'NewTestCase.Assertions'  = 'Checks after WaitMs: array of {"Path":"MAIN.y","Operator":"Equal","Expected":1}. Keys: Path (PLC symbol path), Operator (optional, default Equal; one of Equal, NotEqual, GreaterThan, LessThan, GreaterThanOrEqual, LessThanOrEqual, Contains, IsTrue, IsFalse), Expected (omit for IsTrue/IsFalse). Short forms like "eq"/"gt" are NOT accepted.'
    'AddDut.Fields'           = 'Optional object of field declarations (name = type) for Struct/Union (name = value for Enum). Declaration order is not guaranteed (PowerShell hashtable).'
    'AddGvl.Variables'        = 'Optional object of variable declarations (name = type). Declaration order is not guaranteed (PowerShell hashtable).'
    'RunTest.TestCase'        = 'A test case object as returned by NewTestCase.'
    'RunTestCycle.TestCases'  = 'Array of test case objects as returned by NewTestCase.'
    'DisconnectIde.Quit'      = 'true = also close the solution (without saving) and quit the IDE.'
    'DisconnectIde.Kill'      = 'Only with Quit=true: kill the IDE process when it cannot be quit (modal dialog, DTE.Quit failed). Only for an IDE this session launched (data.ownedBySession); any other IDE -> IDE_NOT_OWNED, nothing killed.'
    'ResetSolution.SolutionPath' = '.sln to reopen. Default: the solution ConnectIde / OpenProject opened.'
    'WatchVariable.Path'           = 'One or more variable paths to monitor, e.g. ["MAIN.nCounter"] or ["MAIN.fActual","MAIN.bDone"]. Always an array.'
    'WatchVariable.Until'          = 'Stop condition ''<Path> <op> <value>'' with op one of == != > < >= <=, e.g. ''MAIN.fTarget == 123.5''. <Path> must be in Path (case-insensitive).'
    'WatchVariable.UntilTimeoutMs' = 'Maximum time in ms to wait for Until before returning untilMet=false. Default 5000.'
    'WatchVariable.TimeoutMs'      = 'Legacy alias of UntilTimeoutMs; used only when UntilTimeoutMs is not given.'
    'WatchVariable.KeepLast'       = 'Number of most recent samples to return. 0 = auto (20 with Until, 50 without). sampleCount still counts every round; truncated=true when older samples were dropped.'
    'WatchVariable.DurationMs'     = 'Sampling duration in ms when Until is not given (default 2000).'
    'ResetSolution.TimeoutSec'   = 'Expected upper bound for each of Documents.CloseAll, Solution.Close and Solution.Open in seconds (default 120).'
    'GetPouCode.PouPath'      = 'Full tree path; omit to auto-detect from PouName (POUs folder -> project root -> tree search depth 4, see data.pouPath / data.resolvedBy). Format on 4024 and 4026: TIPC^<Plc>^<Plc> Project^POUs^<name>; DUT ...^DUTs^<name>, GVL ...^GVLs^<name>. Use GetProjectTree with PlcOnly=true to list paths.'
    'WritePouCode.PouPath'    = 'Full tree path; omit to auto-detect from PouName (POUs folder -> project root -> tree search depth 4, see data.pouPath / data.resolvedBy). Format on 4024 and 4026: TIPC^<Plc>^<Plc> Project^POUs^<name>; DUT ...^DUTs^<name>, GVL ...^GVLs^<name>. Use GetProjectTree with PlcOnly=true to list paths.'
    'AddPou.PlcProjectPath'   = 'Tree path of the folder the POU is created in, e.g. TIPC^<Plc>^<Plc> Project^POUs (same on 4024 and 4026). Omit to auto-detect (<Plc> Project^POUs, else the <Plc> Project node; see data.folderPath).'
    'GetProjectTree.Depth'    = 'Levels below each root node (1-10, default 4). 4 reaches the POUs: TIPC(0)^<Plc>(1)^<Plc> Project(2)^POUs(3)^<POU>(4). Nodes at the limit that have children return truncated=true.'
    'GetProjectTree.PlcOnly'  = 'true = return only the TIPC (PLC) subtree.'
    'BuildProject.AllowUnresolvedLibrary' = 'Accept a build whose Error List shows unresolved libraries as success (data.warningCode=LIBRARY_UNRESOLVED, codeVerified=false) instead of returning LIBRARY_UNRESOLVED. Only when the user accepts that the PLC code may not have been compiled.'
    'BuildProject.ExpectedProject' = 'PLC project name(s) that must be compiled, e.g. ["FrameworkUnitTest"] (the .plcproj file name without extension). Skipped by the active solution configuration -> PROJECT_SKIPPED_BY_CONFIGURATION (build not started); not in the solution -> EXPECTED_PROJECT_NOT_FOUND.'
    'EnableConfig.PlcProjectPath'  = 'PLC project(s) to log in and start, by name (["FrameworkUnitTest"]) or tree path. Default: every PLC project of the solution.'
    'PlcLogin.PlcProjectPath'      = 'PLC name (FrameworkUnitTest) or tree path (TIPC^FrameworkUnitTest^FrameworkUnitTest Project). Required when the solution has more than one PLC project.'
    'PlcLogout.PlcProjectPath'     = 'PLC name (FrameworkUnitTest) or tree path (TIPC^FrameworkUnitTest^FrameworkUnitTest Project). Required when the solution has more than one PLC project.'
    'EnableConfig.ActivateTimeoutSec' = 'Deadline in seconds for ActivateConfiguration() (default 180, also bounded by TimeoutSec with Force). On timeout ACTIVATE_TIMEOUT with data.activateDiagnostics (dialog, ideAlive, ideResponding, runtimeAlive, systemState) instead of waiting forever.'
    'SetSystemState.SettleSec'     = 'Seconds the reached state must hold before success (sampled every 250 ms, then read back). Default 3; 0 = final readback only.'
}

$commonParameters = @(
    'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction',
    'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable',
    'OutBuffer', 'PipelineVariable', 'WhatIf', 'Confirm', 'ProgressAction'
)

# ---------------------------------------------------------------------------
# Load module and CLI operation map
# ---------------------------------------------------------------------------
$module = Import-Module -Name $ModulePath -Force -PassThru -DisableNameChecking 3>$null 4>$null
$moduleVersion = [string]$module.Version
$psd1 = [System.IO.Path]::ChangeExtension($ModulePath, '.psd1')
if (Test-Path -LiteralPath $psd1) {
    try {
        $manifest = Import-PowerShellDataFile -LiteralPath $psd1
        if ($manifest.ModuleVersion) { $moduleVersion = [string]$manifest.ModuleVersion }
    }
    catch { Write-Warning "Could not read ModuleVersion from $psd1 : $($_.Exception.Message)" }
}

$cliText = [System.IO.File]::ReadAllText($CliPath)
$mapMatch = [regex]::Match($cliText, '\$operationMap\s*=\s*@\{(?<body>.*?)\n\}', 'Singleline')
if (-not $mapMatch.Success) { throw "Could not find `$operationMap in $CliPath" }
$opToCmdlet = [ordered]@{}
$cmdletToOp = @{}
foreach ($m in [regex]::Matches($mapMatch.Groups['body'].Value, "(?m)^\s*'(?<op>[A-Za-z0-9]+)'\s*=\s*(?<val>'[^']*'|\`$null)")) {
    $op = $m.Groups['op'].Value
    $val = $m.Groups['val'].Value
    if ($val -eq '$null') { continue }
    $cmdletName = $val.Trim("'")
    $opToCmdlet[$op] = $cmdletName
    $cmdletToOp[$cmdletName] = $op
}

$commands = @(Get-Command -Module $module.Name -CommandType Function | Sort-Object Name)
$commandNames = @($commands | ForEach-Object { $_.Name })
foreach ($op in @($opToCmdlet.Keys)) {
    if ($commandNames -notcontains $opToCmdlet[$op]) {
        Write-Warning "operationMap entry '$op' -> '$($opToCmdlet[$op])' has no matching cmdlet in the module; skipped."
    }
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Get-ToolName {
    param([string]$CmdletName)
    if ($cmdletToOp.ContainsKey($CmdletName)) { return $cmdletToOp[$CmdletName] }
    $fallback = $CmdletName -replace '^([A-Za-z]+)-Tc', '$1' -replace '-', ''
    Write-Warning "Cmdlet '$CmdletName' is not in the CLI operationMap; using tool name '$fallback'."
    return $fallback
}

function Get-LiteralDefault {
    # Returns @{ Found = bool; Value = ... } for a parameter's AST default value.
    param([System.Management.Automation.Language.ExpressionAst]$Ast)
    $none = @{ Found = $false; Value = $null }
    if ($null -eq $Ast) { return $none }
    if ($Ast -is [System.Management.Automation.Language.ConstantExpressionAst]) {
        return @{ Found = $true; Value = $Ast.Value }
    }
    if ($Ast -is [System.Management.Automation.Language.VariableExpressionAst]) {
        switch ($Ast.VariablePath.UserPath.ToLowerInvariant()) {
            'true' { return @{ Found = $true; Value = $true } }
            'false' { return @{ Found = $true; Value = $false } }
            default { return $none }   # $null or a runtime variable
        }
    }
    if ($Ast -is [System.Management.Automation.Language.UnaryExpressionAst] -and
        $Ast.TokenKind -eq [System.Management.Automation.Language.TokenKind]::Minus -and
        $Ast.Child -is [System.Management.Automation.Language.ConstantExpressionAst]) {
        return @{ Found = $true; Value = (0 - $Ast.Child.Value) }
    }
    return $none
}

function Get-TypeSchema {
    # Maps a .NET parameter type to a JSON schema fragment. Returns $null for unsupported types.
    param([System.Type]$Type)
    $tn = $Type.FullName
    switch ($tn) {
        'System.String' { return [ordered]@{ type = 'string' } }
        'System.Int32' { return [ordered]@{ type = 'integer' } }
        'System.Int64' { return [ordered]@{ type = 'integer' } }
        'System.Int16' { return [ordered]@{ type = 'integer' } }
        'System.UInt32' { return [ordered]@{ type = 'integer' } }
        'System.UInt16' { return [ordered]@{ type = 'integer' } }
        'System.Byte' { return [ordered]@{ type = 'integer' } }
        'System.Double' { return [ordered]@{ type = 'number' } }
        'System.Single' { return [ordered]@{ type = 'number' } }
        'System.Decimal' { return [ordered]@{ type = 'number' } }
        'System.Boolean' { return [ordered]@{ type = 'boolean' } }
        'System.Management.Automation.SwitchParameter' { return [ordered]@{ type = 'boolean' } }
        'System.String[]' { return [ordered]@{ type = 'array'; items = [ordered]@{ type = 'string' }; minItems = 1 } }
        'System.Collections.Hashtable' { return [ordered]@{ type = 'object'; additionalProperties = $true } }
        'System.Collections.Hashtable[]' { return [ordered]@{ type = 'array'; items = [ordered]@{ type = 'object'; additionalProperties = $true } } }
        'System.Management.Automation.PSObject' { return [ordered]@{ type = 'object'; additionalProperties = $true } }
        'System.Management.Automation.PSCustomObject' { return [ordered]@{ type = 'object'; additionalProperties = $true } }
        'System.Management.Automation.PSObject[]' { return [ordered]@{ type = 'array'; items = [ordered]@{ type = 'object'; additionalProperties = $true } } }
        'System.Object' { return [ordered]@{} }
        'System.Management.Automation.ScriptBlock' { return $null }
        default {
            if ($Type.IsArray) { return [ordered]@{ type = 'array'; items = [ordered]@{} } }
            Write-Warning "Unmapped parameter type $tn; exposing as free-form."
            return [ordered]@{}
        }
    }
}

function Get-HelpText {
    param($Description)
    if ($null -eq $Description) { return '' }
    $parts = @($Description | ForEach-Object { if ($null -ne $_.Text) { [string]$_.Text } else { [string]$_ } })
    $text = ($parts -join ' ') -replace '\s+', ' '
    return $text.Trim()
}

# ---------------------------------------------------------------------------
# Build tool list
# ---------------------------------------------------------------------------
$tools = New-Object System.Collections.ArrayList
$warningsCollected = New-Object System.Collections.ArrayList

foreach ($cmd in $commands) {
    $cmdletName = $cmd.Name
    $toolName = Get-ToolName -CmdletName $cmdletName

    $help = $null
    try { $help = Get-Help -Name $cmdletName -Full -ErrorAction Stop } catch { $help = $null }

    # --- tool description ---
    $synopsis = ''
    if ($null -ne $help -and $null -ne $help.Synopsis) { $synopsis = ([string]$help.Synopsis -replace '\s+', ' ').Trim() }
    $hasRealHelp = -not [string]::IsNullOrWhiteSpace($synopsis) -and
        $synopsis -ne $cmdletName -and
        -not ($synopsis -match ('^' + [regex]::Escape($cmdletName) + '(\s|\[|$)'))
    $description = if ($descriptionOverrides.ContainsKey($toolName)) { $descriptionOverrides[$toolName] }
                   elseif ($hasRealHelp) { $synopsis }
                   else { "$cmdletName (TwinCATAutomation)" }

    # --- parameter help lookup ---
    $paramHelp = @{}
    if ($null -ne $help -and $null -ne $help.parameters -and $null -ne $help.parameters.parameter) {
        foreach ($hp in @($help.parameters.parameter)) {
            if ($null -ne $hp.name) { $paramHelp[[string]$hp.name] = Get-HelpText $hp.description }
        }
    }

    # --- AST defaults ---
    $astDefaults = @{}
    try {
        $paramBlock = $cmd.ScriptBlock.Ast.Body.ParamBlock
        if ($null -ne $paramBlock) {
            foreach ($p in $paramBlock.Parameters) {
                $astDefaults[$p.Name.VariablePath.UserPath] = Get-LiteralDefault -Ast $p.DefaultValue
                if ($null -ne $p.DefaultValue -and -not $astDefaults[$p.Name.VariablePath.UserPath].Found) {
                    $null = $warningsCollected.Add("$cmdletName -$($p.Name.VariablePath.UserPath): default '$($p.DefaultValue.Extent.Text)' is not a literal; omitted from schema.")
                }
            }
        }
    }
    catch { }

    $properties = [ordered]@{}
    $required = New-Object System.Collections.ArrayList

    foreach ($pName in $cmd.Parameters.Keys) {
        if ($commonParameters -contains $pName) { continue }
        $meta = $cmd.Parameters[$pName]
        $schema = Get-TypeSchema -Type $meta.ParameterType
        if ($null -eq $schema) {
            $null = $warningsCollected.Add("$cmdletName -$pName ($($meta.ParameterType.Name)) is not exposed via MCP.")
            continue
        }

        $isMandatory = $false
        foreach ($attr in $meta.Attributes) {
            if ($attr -is [System.Management.Automation.ParameterAttribute] -and $attr.Mandatory) { $isMandatory = $true }
            elseif ($attr -is [System.Management.Automation.ValidateSetAttribute]) { $schema['enum'] = @($attr.ValidValues) }
            elseif ($attr -is [System.Management.Automation.ValidateRangeAttribute]) {
                $schema['minimum'] = $attr.MinRange
                $schema['maximum'] = $attr.MaxRange
            }
        }

        $descKey = "$toolName.$pName"
        $pDesc = ''
        if ($paramDescriptionOverrides.ContainsKey($descKey)) { $pDesc = $paramDescriptionOverrides[$descKey] }
        elseif ($paramHelp.ContainsKey($pName)) { $pDesc = $paramHelp[$pName] }
        if (-not [string]::IsNullOrWhiteSpace($pDesc)) { $schema['description'] = $pDesc }

        if ($astDefaults.ContainsKey($pName) -and $astDefaults[$pName].Found -and
            $meta.ParameterType.FullName -ne 'System.Management.Automation.SwitchParameter') {
            $schema['default'] = $astDefaults[$pName].Value
        }

        if ($isMandatory) {
            if ($schema.Contains('default')) {
                $null = $warningsCollected.Add("$cmdletName -$pName is Mandatory but has a default value; kept in required, default dropped.")
                $schema.Remove('default')
            }
            $null = $required.Add($pName)
        }

        $properties[$pName] = $schema
    }

    $timeoutMs = if ($timeoutOverrides.ContainsKey($toolName)) { $timeoutOverrides[$toolName] } else { $defaultTimeoutMs }

    $tool = [ordered]@{
        name        = $toolName
        cmdlet      = $cmdletName
        description = $description
        timeoutMs   = $timeoutMs
        annotations = (Get-ToolAnnotations -ToolName $toolName)
        inputSchema = [ordered]@{
            type                 = 'object'
            properties           = $properties
            required             = @($required.ToArray())
            additionalProperties = $false
        }
    }
    $null = $tools.Add($tool)
}

$sortedTools = @($tools | Sort-Object { $_['name'] })
$dupes = @($sortedTools | Group-Object { $_['name'] } | Where-Object { $_.Count -gt 1 })
foreach ($d in $dupes) { Write-Warning "Duplicate tool name '$($d.Name)'." }
$allNames = @($sortedTools | ForEach-Object { $_['name'] })
foreach ($n in @($readOnlyTools + $destructiveTools)) {
    if ($allNames -notcontains $n) { Write-Warning "Annotation list names unknown tool '$n'." }
}

$document = [ordered]@{
    generatedAt   = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    moduleVersion = $moduleVersion
    tools         = $sortedTools
}

$json = ConvertTo-Json -InputObject $document -Depth 20
# PS 5.1 escapes a few ASCII characters as \u00XX; keep them readable for diffs.
$json = $json -replace '\\u0027', "'" -replace '\\u003c', '<' -replace '\\u003e', '>' -replace '\\u0026', '&'
$json = $json -replace "`r?`n", "`r`n"
if (-not $json.EndsWith("`n")) { $json += "`r`n" }

$outDir = [System.IO.Path]::GetDirectoryName($OutPath)
if (-not (Test-Path -LiteralPath $outDir)) { $null = New-Item -ItemType Directory -Path $outDir -Force }
[System.IO.File]::WriteAllText($OutPath, $json, (New-Object System.Text.UTF8Encoding($false)))

foreach ($w in $warningsCollected) { Write-Warning $w }
Write-Host "Wrote $($sortedTools.Count) tools to $OutPath (module $moduleVersion)."
