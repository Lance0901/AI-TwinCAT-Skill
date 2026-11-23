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
        powershell.exe -NoProfile -File scripts/Export-ToolSchema.ps1

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
    'ClearLifecycleBlock' = 'Remove the LIFECYCLE_BLOCKED record of one target. Call it ONLY after the user has seen the block (data.lifecycleBlock of the refused tool: command, errorCode, requestedState, reachedState, message, time) and agreed; never call it on your own to get past LIFECYCLE_BLOCKED, never move or delete the block file. Receipt, all four required and filled in with the user''s words, never invented: Reason (why the user approved lifting the block), FallbackMethod (how the work continues), AllowedSideEffects (array, e.g. ["TwinCAT restart","PLC download"]; exactly ["none"] when none), MaxVerifyLevel (None, SystemState, PlcState, VariableRead, TestObserved: results must not claim more). Empty or invalid -> LIFECYCLE_RECEIPT_INCOMPLETE (data.missing / data.invalid), nothing removed. AmsNetId defaults to the IDE target, then the ADS session; ''<unknown>'' and ''<corrupt>'' records (they block every target) are cleared by name. data: cleared, remaining, remainingKeys, stillBlocking, receipt, receiptWritten (false: another bridge keeps blocking, see data.lifecycleBlock.syncNote there). Afterwards run the lifecycle again from the start with the approved FallbackMethod; nothing clears a block automatically. Details GetGuide(''recovery'').'
    # Generic tree tools (complete-automation-interface phase 1). Not yet verified on a real target (task 2.8).
    'LookupTreeItem'  = 'Generic tree tool, read-only: look up ONE tree item by its full path (ITcSysManager.LookupTreeItem, TE1000 v1.7.0 5.1.1.3) and return name, itemType, subType, subTypeName, type, disabled, disabledState, childCount and children[] (name, path, itemType, subType, type, disabled, disabledState). childCount / children[] / nearestChildren are the DIRECT children only: the terminals that ITcSmTreeItem.Child(i) of an EtherCAT device also returns below a coupler (measured 2026-11-08, 4024 XAE) are left out (#182). childrenTruncated = children has fewer entries than childCount (more than MaxChildren, or a child could not be read); childrenUnreadable = number of children that could not be read (-1 = ChildCount unreadable). disabledState is the ITcSmTreeItem.Disabled DISABLED_STATE name (SMDS_NOT_DISABLED / SMDS_DISABLED / SMDS_PARENT_DISABLED), disabled is true for the last two, both null when Disabled cannot be read. Path is the full tree path separated by ^, e.g. TIRT^PlcTask, TIPC^MyPlc^MyPlc Project^POUs, TIID^Device 1 (EtherCAT); wildcards * ? return TREEITEM_PATH_INVALID. A missing path returns TREEITEM_NOT_FOUND whose error.hint and data.nearestPath / nearestChildren name the nearest existing parent and its children. Prefer GetProjectTree / GetIoTree / GetPouCode when they cover the node.'
    'ProduceXml'      = 'Generic tree tool, read-only: return the XML description of one tree item (ITcSmTreeItem.ProduceXml, TE1000 v1.7.0 5.2.1.8; root element TreeItem) in data.xml. Use its element paths to build a ConsumeXml fragment (e.g. TreeItem/TaskDef/CycleTime of a task). Missing path: TREEITEM_NOT_FOUND with the nearest existing parent in error.hint.'
    'ConsumeXml'      = 'Generic tree tool that CHANGES the configuration: write an XML fragment into one tree item (ITcSmTreeItem.ConsumeXml). Prefer a dedicated tool when one exists. DryRun defaults to true: first call it without DryRun and read data.changes (path, current, planned, changed) and data.currentXml; then call again with DryRun=false. Fragment: root <TreeItem>, element paths exactly as in ProduceXml, only the fields to change, e.g. <TreeItem><TaskDef><CycleTime>40000</CycleTime></TaskDef></TreeItem> (CycleTime unit 100 ns). Refused before sending with XML_MERGE_FAILED (data.reason, data.missingPaths): a leaf path not in the current XML, attributes, structure or repeated-count mismatch, derived-only changes; bad known values -> TREEITEM_INVALID_VALUE. DryRun=false: backup to <solution dir>\.tcauto-backup\<time>\ (data.backupPath), send, read back: data.verified=true, else TREEITEM_VERIFY_FAILED (data.mismatches, data.unexpectedChanges). A dialog -> IDE_MODAL_DIALOG, nothing sent. Below TIPC records BUILD_REQUIRED. Details GetGuide(''io'').'
    'CreateChild'     = 'Generic tree tool that CHANGES the configuration: create a child below Path (ITcSmTreeItem.CreateChild(Name, SubType, Before, VInfo), TE1000 v1.7.0 5.2.1.2). Prefer AddPou / AddDut / AddGvl / AddLibrary / IoScan when they cover the object. SubType / VInfo depend on the parent; only use values documented in TE1000 / InfoSys, e.g. TIRT task SubType 0 = with image, 1 = without image (6.3.1); TIID EtherCAT master 111 (6.6.1). DryRun defaults to true (nothing created; data.plannedPath, data.currentChildren = direct children only, data.childrenTruncated, data.rawChildCount = ChildCount as XAE reports it, -1 when unreadable). Checks: parent exists (TREEITEM_NOT_FOUND with nearest parent), no child with Name (TREEITEM_ALREADY_EXISTS), Before is a child (looked up as Path^Before). DryRun=false: backup of the parent ProduceXml (data.backupPath), IDE_MODAL_DIALOG if a dialog is open (nothing created), CreateChild, look up again and re-read the parent ProduceXml (it may only gain entries, ChildCount +1 is expected, data.parentUnchanged) and the child names must be the old ones plus exactly one (data.childrenAfter; skipped with a warning when the list is cut): data.verified=true, data.createdPath / createdName (XAE may rename: data.warnings); refused -> TREEITEM_CREATE_FAILED, not found afterwards or a parent field changed (data.unexpectedChanges) -> TREEITEM_VERIFY_FAILED. Below TIPC records BUILD_REQUIRED code-changed.'
    'DeleteChild'     = 'Generic tree tool that DELETES configuration: delete the tree item at Path (its parent ITcSmTreeItem.DeleteChild(name), TE1000 v1.7.0 5.2.1.3). Prefer a dedicated tool when one exists. Full path only, no wildcards, not a top-level node (TREEITEM_PATH_INVALID). ConfirmName is required and must equal the item name exactly, else TREEITEM_DELETE_NAME_MISMATCH (data.nodeName) and nothing is deleted. The item must report the parent derived from Path, else TREEITEM_DELETE_FAILED data.reason parent-mismatch (nothing deleted). DryRun defaults to true (nothing deleted; data.nodeName, itemType, childCount and children = direct children only like LookupTreeItem, rawChildCount = ChildCount as XAE reports it, -1 when unreadable; childrenTruncated, childrenUnreadable). DryRun=false: backup first (recursive ProduceXml data.backupPath, disk file data.backupFiles, ExportChild file data.exportPath for ImportChild: .xti, or .zip for every node below TIPC; XAE refuses .xti for a PLC folder, measured 2026-10-30 4026 VS2022 on a PLC folder only, other TIPC nodes not measured, a failed export deletes nothing). A missing <task>.TcTTO is a warning only when a .plcproj / .tsproj references it (a task without a PLC project has none). When the ExportChild backup fails, its file is missing or empty (0 bytes) nothing is deleted: TREEITEM_BACKUP_FAILED data.reason export-failed / export-missing / export-empty; AllowNoExport=true deletes anyway with a warning (only for these, never a dialog). Before the backup ExportChild and before DeleteChild: IDE_MODAL_DIALOG on a dialog, MODAL_SCAN_INCOMPLETE (data.modalScan) when the scan exceeded ModalScanTimeoutSec (default 30), could not read every IDE window, or the 265 s call had no time left (no-budget): not deleted, backups kept. Then DeleteChild, then the path must no longer resolve: data.verified=true, else TREEITEM_VERIFY_FAILED; refused -> TREEITEM_DELETE_FAILED. Below TIPC records BUILD_REQUIRED code-changed.'
    'ExportChild'     = 'Generic tree tool: export the tree item at Path with its subtree to an .xti file (parent ITcSmTreeItem.ExportChild(name, FilePath), TE1000 v1.7.0 5.2.1.4). Does not change the configuration. A PLC folder below TIPC (ItemType 601) needs a .zip file name: XAE refuses .xti there ("doesn''t specify a zip archive", measured 2026-10-30 4026 VS2022 on a PLC folder only; other TIPC nodes not measured and passed to XAE as given), so the module refuses it first (TREEITEM_EXPORT_FAILED data.reason plc-requires-zip, data.itemType, hint with the .zip name). FilePath must be an absolute file path (not a root such as C:\, no < > | " * ?), its folder must exist and the file must not exist (TREEITEM_EXPORT_FAILED, data.reason not-absolute / invalid-path / folder-missing / file-exists). IDE_MODAL_DIALOG if a dialog is open; MODAL_SCAN_INCOMPLETE (data.modalScan) when the dialog scan did not finish within ModalScanTimeoutSec (default 30 s, 1..60), could not look at every IDE window, or the 145 s call deadline left no time (reason no-budget): nothing exported, never read as no dialog. Success only when the file exists and is not empty (data.exported, data.fileSize). Re-import with ImportChild.'
    'ImportChild'     = 'Generic tree tool that CHANGES the configuration: import an .xti / XML file as a child of Path (ITcSmTreeItem.ImportChild(FilePath, Before, Reconnect, Name), TE1000 v1.7.0 5.2.1.6; templates 6.3.2). A PLC folder is imported from the .zip file ExportChild wrote (measured 2026-10-30 4026 VS2022 on a PLC folder only; other TIPC nodes not measured). DryRun defaults to true (nothing imported; data.currentChildren, data.fileSize). Checks: FilePath is a valid absolute file path and exists (TREEITEM_IMPORT_FAILED, data.reason not-absolute / invalid-path / file-missing), parent exists, a child named Name does not exist (TREEITEM_ALREADY_EXISTS), Before is a child (looked up as Path^Before). Without Name the name is read from the .xti (data.expectedName; __FILENAME__ = file name without extension; null for a .zip, then data.warnings says no clash check was done) and checked the same way, dry-run included (XAE would rename silently, e.g. Task28 -> Task28_1). DryRun=false: backup of the parent ProduceXml (data.backupPath), IDE_MODAL_DIALOG if a dialog is open (nothing imported), ImportChild, look the imported item up again and re-read the parent ProduceXml (it may only gain entries, ChildCount +1 is expected, data.parentUnchanged) and the child names must be the old ones plus exactly one (data.childrenAfter; skipped with a warning when the list is cut): data.verified=true, data.importedPath / importedName (a name other than Name / expectedName: data.warnings); refused -> TREEITEM_IMPORT_FAILED, not found or a parent field changed (data.unexpectedChanges) -> TREEITEM_VERIFY_FAILED. Below TIPC records BUILD_REQUIRED code-changed.'
    'ConnectIde'      = 'Connect to a TwinCAT XAE / Visual Studio instance (Running Object Table) or launch one; call it before any project, build or runtime tool. Open a project: SolutionPath=<.sln> without ProgId (the XAE matching the .tsproj TcVersion is launched; several XAE installed and no match -> PROGID_REQUIRED: pass ProgId). Only an IDE TcAuto launched, or one bound with ProcessId, is attached. Any other IDE (opened by the user, also the one that already has SolutionPath open) -> IDE_ATTACH_CONSENT_REQUIRED with data.candidates, nothing attached or changed: ask the user whether TcAuto may work in it (it turns on SilentMode; unsaved changes may be affected); yes -> ConnectIde ProcessId=<pid> (plus SolutionPath); no -> the user closes that solution there, or ConnectIde SolutionPath to open another IDE. Never choose without asking; ProcessId is the only way to consent. TakeOverOrphan=true (an IDE whose launching session ended) only after asking the user. After a BRIDGE_TIMEOUT call ConnectIde again with the same parameters; never launch an IDE yourself. Returns ideProcessId, amsNetId (the target the IDE has: use it, never hard-code one), targetKind (local-umrt | local-xar | remote | unknown; anything but local-umrt is a real machine), targetKindSource, ownedBySession, connectSec, launchSec. Blocked IDE -> IDE_MODAL_DIALOG / IDE_BUSY (GetIdeModalDialog). Other errors (IDE_LAUNCH_PENDING, ORPHAN_TAKEOVER_REFUSED, IDE_PID_NOT_FOUND, IDE_PID_MISMATCH, REMOTE_MANAGER_MISMATCH, IDE_VERSION_NOT_REGISTERED; RESET_REQUIRED of later tools after an answered reload prompt): follow error.hint; details GetGuide(''open-project'').'
    'CleanProject'    = 'Clean the open solution (Build > Clean Solution) and wait until SolutionBuild.BuildState is Done (TimeoutSec default 300 -> CLEAN_TIMEOUT). Use instead of touching DTE yourself: issue #18 once hit a null-valued expression on Solution / SolutionBuild right after ConnectIde (cause not confirmed); this tool waits for them and counts the null answers (data.nullReads). A modal dialog returns IDE_MODAL_DIALOG. Readback SolutionBuild.LastBuildInfo: 0 -> success, data.cleanVerified=true; unreadable -> CLEAN_UNVERIFIED (always a failure); > 0 with only unresolved-library Error List rows (<plc>.Library Manager, no line) -> LIBRARY_UNRESOLVED (data.libraryErrorItems; a later BuildProject success may not have compiled the PLC code, #45), or with AllowUnresolvedLibrary=true success with data.warningCode=LIBRARY_UNRESOLVED and cleanVerified=false; any other error -> CLEAN_FAILED (data.errorItems). data: buildState, failedProjects, cleanVerified, cleanSec, nullReads, errorItems.'
    'DisconnectIde'   = 'Release the DTE/COM references held by the bridge. The IDE keeps running unless Quit=true, which closes the solution without saving and quits the IDE - only an IDE this session launched (data.ownedBySession): any other IDE (one the user opened, attached by solution-match, first-instance or ProcessId) is refused with IDE_NOT_OWNED before anything is closed, the connection is kept (#227). With Quit=true a modal dialog is checked first: if one is up nothing is attempted, nothing is released (the connection stays: for kind reload-prompt run ResetSolution, then DisconnectIde Quit=true again) and the result is IDE_QUIT_FAILED (data.dialog {title, text, kind, reloadTarget}, quit=false, disconnected=false); if DTE.Quit fails the result is also IDE_QUIT_FAILED (success=false, data.ideProcessId / quitError; the IDE process still runs). After a failure the IDE pid is kept, so DisconnectIde Quit=true Kill=true can follow directly without ConnectIde. Kill=true (only with Quit=true) kills the IDE process in those two cases, but only when this session launched it (data.ownedBySession, still true after the internal reconnect of ResetSolution), otherwise IDE_NOT_OWNED and nothing is killed; data.killed tells whether it was killed. COM references are always released. ForgetPendingLaunch=true (alone) only forgets the launch records whose pid could not be confirmed (ConnectIde IDE_LAUNCH_PENDING probe pid-unconfirmed): nothing is closed, the connection is kept (data.forgottenLaunches).'
    'ResetSolution'   = 'Reload every project file from disk in the connected IDE. Use it after .TcPOU / .plcproj / .tsproj files were changed ON DISK (after LintProject passed); WritePouCode / AddPou write through COM and never need it. Refused, nothing saved or closed: UNSAVED_CHANGES (the IDE holds unsaved documents / projects / solution: data.unsavedCheck) -> ASK THE USER whether to discard them; Force=true drops them, only with their consent. PROJECT_UNSAVED_CHANGES (objects XAE has that the .plcproj on disk does not list: data.projectCheck) -> SaveProjectChanges=true keeps the XAE version, DiscardProjectChanges=true keeps the disk version (neither is consent for Force); do not use BuildProject to resolve it. It answers the XAE reload prompt itself (project prompt: Yes; VS2022 solution prompt: Ignore, then close + reopen), otherwise closes all documents without saving and reopens the .sln, then reads back until loaded (SOLUTION_RELOAD_INCOMPLETE, IDE_CRASHED); any other dialog -> IDE_MODAL_DIALOG. Records BUILD_REQUIRED: BuildProject next. data: dismissedReloadPrompt, answeredYes, reopenedSolution, reloadPromptAttempts, closedDocuments, projectCheck, savedProjects, unsavedCheck, discardedChanges, loadCheck, totalSec. Details GetGuide(''change-code'').'
    'ReportIssue'     = 'Build a de-identified, pre-filled GitHub new-issue URL (and the same title / body as text) for a problem found while using this server; it creates NOTHING, calls no GitHub API and no network, needs no token and no IDE / ADS connection (works while the IDE is blocked by a modal dialog and is not refused by LIFECYCLE_BLOCKED). The repository is PUBLIC: show data.maskReport and data.body to the user; ONLY THE USER opens data.url in a browser signed in to GitHub, reviews the text and submits it. Never open or submit it yourself. Title is the one-line summary; Tool, Parameters, Result (the failing result object), Expected and Notes are optional; ExtraMask lists literal strings (customer / site / person names) to hide as well. User names, this machine''s names, host names, AMS NetIds, IP / MAC / e-mail addresses, project paths, the open solution''s name and secrets are masked (data.masks, data.maskReport). The URL is capped at MaxUrlLength (default 7000; data.truncated); data.body is always the complete de-identified text. XAE / TwinCAT version is not read: put it in Notes. Details GetGuide(''recovery'').'
    'GetIdeInfo'      = 'Return version, edition, open solution, ITcSysManager availability and the active solution platform / configuration (solutionPlatform, solutionConfiguration; null when unreadable) of the connected IDE, and the Remote Manager version the IDE uses (remoteManagerVersion, read-only from TcRemoteManager.Version; null with remoteManagerError when unreadable). Cheap connectivity check; fails with NOT_CONNECTED before ConnectIde.'
    'BuildProject'    = 'Build the PLC project of the open solution and wait for the result (TimeoutSec default 600 -> BUILD_TIMEOUT; a dialog during the build -> IDE_MODAL_DIALOG). Run it after every code or project change: EnableConfig / PlcLogin / SendPlcProgram refuse with BUILD_REQUIRED until a build returns data.completeBuild=true (coverageComplete and codeVerified true). Failures (success=false): BUILD_FAILED -> read data.codeErrors (description, file, line from the XAE Error List) and fix the code, never guess; with the PLC logged in XAE does not compile (data.plcOnlineSuspected, hint BUILD_FAILED_PLC_ONLINE): PlcLogout, then build again. LIBRARY_UNRESOLVED -> install the missing libraries (data.libraryErrorItems); AllowUnresolvedLibrary=true accepts such a build but it is never complete. PROJECT_LOAD_ERRORS -> XAE could not load project files (data.loadErrorFiles): report them, fix the XML (ask before restoring whole files), ResetSolution, build again. Warnings in data.warningCodes: PROJECT_SKIPPED_BY_CONFIGURATION (a PLC project was not built; ExpectedProject=[names] makes it a failure, EXPECTED_PROJECT_NOT_FOUND / EXPECTED_PROJECT_DISABLED), CODE_NOT_VERIFIED, STATIC_ANALYSIS_ERRORS. data: errors (code errors only), errorItems, codeErrors, warningItems, codeWarnings, libraryErrors, libraryErrorItems, runtimeMessages, staticAnalysisItems, projects[] (built / skipped / failed / unknown / disabled), coverageComplete, codeVerified, completeBuild, buildRequired, decidedBy, failedProjects, solutionConfiguration, buildPaneMessages, warningLines. Details GetGuide(''change-code'').'
    'GetBuildErrors'  = 'Read the compiler messages currently in the XAE Error List: data.counts {errors, warnings, messages}, data.errors[] and data.warnings[] (IncludeWarnings defaults to true); IncludeMessages=true adds data.messages[]. Items are {severity, code, description, project, file, line, column}. Source 1 is COM (DTE2 ErrorList.ErrorItems read with a compiled helper, data.source ''ErrorList(COM)''): needs no visible Error List window and no foreground, a few ms per row. It is used only when it is provably the whole list: the Error List scope is Entire Solution (window caption), severity is certain, and, when the build failed, at least one error row was read; otherwise the UI Automation scan reads (data.source ''ErrorList(UIA)'', data.fallbackReason says why). With COM, code is the Cxxxx of the matching build output pane line or null (the COM description has none), file is the base name + '' (Impl)''/'' (Decl)'' like the UIA grid (item.filePath = full path), column is null. Source 2, UIA: counts are read from the summary buttons in English and zh-TW UI (zh-TW VS2022 ''shown / total'' labels report the total); other UI languages return ERRORLIST_UNAVAILABLE. In VS2022 the Error List scope filter is read from the scope combo itself (also while collapsed) and switched to Entire Solution before reading when it shows anything else (left switched, read back). Fewer rows read than the button totals, or a scope that could not be switched, return ERRORLIST_INCOMPLETE (data.missingRows, data.scope), never success with a partial list. BuildProject / CheckAllObjects / CleanProject keep the rows read and block (codeVerified=null) only when the ERROR rows are not proven complete; warnings read short there is data.warningCodes WARNINGS_INCOMPLETE, not blocking. data.errors / data.warnings include runtime / system log rows (''<source>'' (<number>): ..., e.g. TcUnit / ADSLOGSTR output of a running PLC, #66): they are not compiler messages, see BuildProject data.runtimeMessages.'
    'EnableConfig'    = 'Activate the configuration on the target without any dialog: TwinCAT restarts, the PLC program is downloaded and started, the machine stops and restarts. Force=true: Config -> Activate -> Run -> PLC Login + Download -> PLC Run on every PLC port (PlcProjectPath selects PLCs), then reads back port 10000 and every PLC port (not Run -> RUNTIME_STATE_MISMATCH). NoLogin=true stops after TwinCAT is in Run; afterwards ConnectAds. A solution platform that differs from the target platform is switched and rebuilt (NoPlatformFix=true -> PLATFORM_MISMATCH). Refused before anything runs: BUILD_REQUIRED (BuildProject until completeBuild=true), PLATFORM_PROJECT_MISMATCH, BUILD_SELECTION_CHANGED. After Activate, failures record a lifecycle block: ACTIVATE_FAILED (usually the wrong platform: pass Platform), LICENSE_MISSING (never press the dialog), RUNTIME_CRASHED, BOOT_PACKAGE_MISMATCH, LOGIN_FAILED. data: steps, plcs, loggedIn, dialogsSeen, finalCheck, diagnostics. Details GetGuide(''deploy''); failures GetGuide(''recovery'').'
    'SetTarget'       = 'Set the target AmsNetId (always done first: data.amsNetId, data.targetSet and data.targetKind local-umrt | local-xar | remote | unknown, also on an error) and make the active solution platform follow the target: UmRT and TwinCAT/BSD = ''TwinCAT OS (x64)'', Windows RT target = ''TwinCAT RT (x64)''; a mismatch fails EnableConfig with ACTIVATE_FAILED. Without Platform the platform the target reports through TARGETINFO is activated for Configuration (default Release); a target that reports none -> PLATFORM_UNKNOWN (NetId set, nothing guessed): pass Platform. NoPlatformSwitch=true only sets the NetId. Fail closed, nothing switched: PLATFORM_NOT_FOUND, PLATFORM_PROJECT_MISMATCH (data.platformMap; fix the Configuration Manager), BUILD_SELECTION_CHANGED / BUILD_SELECTION_UNKNOWN (the switch would change which PLC projects are built; data.buildSelectionChanges; when the restore failed BuildProject / EnableConfig refuse until SetTarget switches back). Never change Platform / Target to get past another tool''s failure. Returns platform, projectPlatform, requestedProjectPlatform, platformChanged, targetPlatform, targetPlatformSource, configuration, previousPlatform, availablePlatforms, buildSelection, platformMapReliable. Details GetGuide(''open-project'').'
    'ConnectAds'      = 'Open the ADS connection to the PLC runtime. Leave AmsNetId empty: it is auto-detected from the IDE target and changes per target (local UmRT, remote CX ...), so never hardcode it. Port defaults to 851 (PLC runtime 1). Requires ConnectIde for auto-detection.'
    'DisconnectAds'   = 'Close the ADS connection and forget the cached endpoint (disables auto-reconnect).'
    'ReadVariable'    = 'Read one or more PLC variables by symbol path (e.g. ["MAIN.nCounter","GVL.bRun"]) via ADS. Path is always an array, even for a single variable. One path: data is the entry (an unknown symbol fails with SYMBOL_NOT_FOUND); several paths: data is an array with one entry per path, a path that could not be read is {path, error, code, hint} inside it. Fail closed (#60): when any of several paths fails the result is success=false with PARTIAL_READ_FAILED, data still holds every entry (the values that were read included), and the top level has partial=true and failedPaths (the failed paths in input order); with every path read it is success=true, partial=false, failedPaths=[]. Each entry has path, value, type: BOOL/integers/REAL/STRING are plain values; TIME/TOD, LTIME/LTOD, DATE/DT, LDATE/LDT return the IEC literal in value ("T#6s", "DT#2026-10-20-12:30:00") plus the raw integer in ms (TIME/TOD), ns (LTIME/LTOD/LDATE/LDT) or unix (DATE/DT); enums return the integer in value plus the member name in name; STRUCT/ARRAY return the raw bytes in value plus size. Requires ConnectAds (auto-reconnects after EnableConfig).'
    'WriteVariable'   = 'Write a single PLC variable by symbol path via ADS. Writes directly into the running PLC; may drive outputs or axes. Requires ConnectAds. Value is converted to the PLC type of the symbol: JSON bool for BOOL, number for integer / REAL, string for STRING; TIME / TOD an IEC literal ("T#6s", "TOD#12:30:00") or integer ms, LTIME / LTOD "LTIME#1us" or integer ns, DATE / DT "D#2026-10-20", "DT#2026-10-20-12:30:00", ISO 8601 or integer seconds since 1970, enums an integer or the member name. STRUCT / ARRAY cannot be written as a whole (TYPE_MISMATCH): write their members. data.written = the value actually written (normalized literal for time types, the converted number otherwise, plus name for enums). Details GetGuide(''testing'').'
    'WatchVariable'   = 'Poll one or more PLC variables (Path is an array; every round reads each path in order) every IntervalMs. Without Until it samples for DurationMs (default 2000). With Until it waits for a condition ''<Path> <op> <value>'' (op: == != > < >= <=, e.g. ''MAIN.fTarget == 123.5'' or ''MAIN.bDone == TRUE''; <Path> must be one of Path) and returns as soon as it holds or after UntilTimeoutMs (default 5000): data.untilMet, untilSample, elapsedMs. Numbers compare numerically, TRUE/FALSE as booleans, other values as case-insensitive text; a failed read never satisfies the condition. Only the last KeepLast samples are returned (default 20 with Until, 50 without); sampleCount is the total and truncated tells whether older samples were dropped. Single-path samples are {timestamp, value} plus ms/ns/unix for TIME/DATE types and name for enums (same conversion as ReadVariable; a numeric Until value compares with that raw integer, text with the IEC literal / enum member name), multi-path samples {timestamp, values:{<path>:<value>}}. Fail closed (#139): when a read fails in any round the result is success=false with WATCH_READ_FAILED; data is still complete (samples, untilMet, ...) plus failedReads (path -> failed rounds) and lastErrors (path -> last {error, code, hint}); a failed read is null in the sample plus sample.errors.<path> (several paths) or sample.error / code (one path), never a PLC value; the top level has partial and failedPaths (partial=false, failedPaths=[] when every read worked). Use Until instead of a long DurationMs or repeated ReadVariable calls. Requires ConnectAds.'
    'GetSymbols'      = 'List the PLC symbols of the connected runtime, optionally filtered by a substring (Filter): data is an array (empty when nothing matches) of {path, type, size, comment}, plus enumValues (member name -> value) for enum types; the execution order is in the top-level order field. Use it to find exact variable paths and types before ReadVariable/WriteVariable.'
    'GetPlcState'     = 'Read the PLC runtime state (Run/Stop/...) on the connected ADS port. data.systemState / systemAdsState / systemStateReadAt are the TwinCAT system state (ADS port 10000) of the same target (#287); Exception (adsState 19, after a PLC exception) cannot be recovered by SetPlcState, only by a new Activate (EnableConfig Force=true; on a local UmRT restart the runtime first after any PLC exception, measured; fix the code that raised it first). A failed port 10000 read does not fail the call: systemState is null and data.systemStateError says why.'
    'SetPlcState'     = 'Switch the PLC runtime to Run, Stop or Reset and wait for the state (Reset leaves the PLC in Stop; call Run to recover). Rarely needed: EnableConfig Force=true already starts the PLC. Before sending, port 10000 is read: SYSTEM_EXCEPTION (TwinCAT in Exception) or SYSTEM_STATE_FAILED -> nothing sent, no lifecycle block: do not recover it yourself, report it (recovery steps: GetGuide(''recovery'')). Run succeeds only when the PLC port and port 10000 read Run in every round of a 1500 ms confirm window, else RUNTIME_STATE_MISMATCH (lifecycle block when Run was sent). data: originalState, currentState / finalState (Unreachable when the last read failed), lastState, lastError, leftOriginal, unreachableSeen, systemState, runConfirm, reached.'
    'PlcLogin'        = 'Log in to the PLC project and download the program in one call (no dialogs). Use after a successful BuildProject when TwinCAT is already in Run; EnableConfig Force=true already includes this step. Several PLC projects: pass PlcProjectPath (PLC name such as FrameworkUnitTest or tree path), else PLC_PROJECT_AMBIGUOUS. Refused with BUILD_REQUIRED (nothing sent) until a complete BuildProject after a code / project / platform change. The login state is read back: false or unreadable -> LOGIN_FAILED. data: adsPort, loggedIn, loginStateSource. Details GetGuide(''deploy'').'
    'PlcLogout'       = 'Log out of the PLC project (the runtime keeps running). With several PLC projects pass PlcProjectPath (PLC name or tree path); without it PLC_PROJECT_AMBIGUOUS. data.plcProjectPath / data.adsPort tell which PLC was logged out. Fail closed (#232): the login state is read back (data.loggedIn, data.loginStateSource); success only when it reads back false, still true or unreadable -> LOGOUT_FAILED. Already logged out -> success with data.alreadyLoggedOut=true and nothing sent (idempotent); data.logoutVia names the call (treeItem.Logoff = Logoff() on the <Plc> Project item).'
    # tcauto-allow(amsnetid): tool text that documents the read-only local fallback of GetSystemState
    'GetSystemState'  = 'Read the TwinCAT system state (Run/Config) of a target over ADS port 10000. AmsNetId defaults to the IDE target (ConnectIde), then the ADS session (ConnectAds), then the local system 127.0.0.1.1.1; data.amsNetId / data.netIdSource tell which one was used. netIdSource=local means you read the local TwinCAT system, which is usually NOT your target.'
    # tcauto-allow(startrestart,writecontrol): tool text that names the ADS state write and says StartRestartTwinCAT is NOT used
    'SetSystemState'  = 'Switch TwinCAT to Run or Config via ADS WriteControl (no dialog) and poll until the state is reached and holds for SettleSec (default 3 s); Config stops the runtime and all outputs go to zero. Does not download the PLC program: EnableConfig Force=true is the usual choice. A runtime that falls back to Config -> SYSTEM_STATE_MISMATCH (data.readbackState, data.stateTrace, data.diagnostics: dialog, Error List, bootPackage, licenses; error.hint follows them). LICENSE_MISSING: stop and report, never press the dialog. Local UmRT process gone -> RUNTIME_CRASHED (data.runtimeCrash fields lastError, lastState, unreachableMs): the user restarts the UmRT, then EnableConfig Force=true. Any failure after the request was sent records a lifecycle block. data: originalState, finalState / currentState (Unreachable when the last read failed), lastState, reached, held, leftOriginal, unreachableSeen, sentAdsState, latencyMs. Details GetGuide(''recovery'').'
    'SendPlcProgram'  = 'Download the compiled PLC program to the target (alias of PlcLogin LoginMode=Download: Login+Download without dialogs). Refused with BUILD_REQUIRED like PlcLogin. When the code is unchanged since the running program XAE skips the download: data.downloaded=false (measured 2026-10-28, _AppInfo.AppTimestamp unchanged). After a real download the PLC is left in Stop (data.plcStateAfter): SetPlcState State=Run to start it.'
    'RunTestCycle'    = 'Builds, activates (TwinCAT restart) and runs the PLC: changes the running machine. Full automated test cycle: build (unless SkipBuild), activate configuration, login, run every test case from NewTestCase, then stop the PLC (unless KeepRunning). Returns per-test results; can take many minutes (timeout 900 s). RUNTIME_CRASHED during activation is returned as it is (data.runtimeCrash). A test case that waits with the deprecated WaitMs has data.warning (listed in data.warnings). Details GetGuide(''testing'').'
    'RunTest'         = 'Execute one test case created with NewTestCase (setup writes -> wait -> assertions -> teardown writes) against the connected PLC. Requires ConnectAds.'
    'NewTestCase'     = 'Build a test case object for RunTest/RunTestCycle. Setup/Teardown are arrays of {Path, Value} writes; Assertions are {Path, Operator, Expected} with Operator one of Equal (default), NotEqual, GreaterThan, LessThan, GreaterThanOrEqual, LessThanOrEqual, Contains, IsTrue, IsFalse. WaitUntil (preferred) = array of {Path, Operator, Expected} polled until all hold (WaitTimeoutMs, default 5000); on timeout RunTest reports Fail with waitTimedOut, lastValues, waitMs. WaitMs is a deprecated fixed blind wait. Pure data, no IDE/PLC access. Without WaitUntil the result has waitMs and a warning that WaitMs is deprecated (RunTest / RunTestCycle results carry it too); with WaitUntil there is no waitMs (an explicit WaitMs is reported as waitMsIgnored + warning).'
    'OpenProject'     = 'Open a solution (.sln) in the connected IDE and wait until the TwinCAT project is loaded.'
    'IoScan'          = 'Scan the I/O devices of the target (ProduceXml(false) on TIID, TE1000 6.6.2). Requires the target in Config mode, otherwise IO_SCAN_REQUIRES_CONFIG. Default: only returns data.devices, the I/O tree is not changed; Apply=true adds them (CreateChild + AddressInfo + ScanBoxes) and reads them back. No device found: success, devices=[] and data.warning.'
    'GetProjectTree'  = 'Read the project tree. Every node has name, path, type, itemType, subType and children; path can be passed as-is to GetPouCode / WritePouCode PouPath. type is the item kind from ItemType (Project, Folder, FunctionBlock, Function, Program, Dut, Gvl, Task, References ...) or the numeric ItemType when unknown (itemType / subType are also returned as numbers). The PLC node TIPC^<Plc> also lists "<Plc> Project" with its POUs, DUTs and GVLs folders (on 4024 and 4026 the project node is hidden from enumeration and is added by path). Depth (default 4) = levels below each root, enough for TIPC^<Plc>^<Plc> Project^POUs^<POU>; a node at the depth limit that still has children comes back with children=[] and truncated=true. In the TIID section every node lists only its direct children: the terminals that ITcSmTreeItem.Child(i) of an EtherCAT device also returns below a coupler (measured 2026-11-08, 4024 XAE) are not listed a second time below the device (#186). A busy / crashed IDE while reading the tree -> IDE_BUSY / IDE_CRASHED / IDE_MODAL_DIALOG / IDE_TIMEOUT, never a partial tree. PlcOnly=true returns only the TIPC subtree.'
    'AddPou'          = 'Create a POU (Program, FunctionBlock or Function, language ST) in <Plc> Project^POUs (or PlcProjectPath), save the project files and read it back; then fill it with WritePouCode (LintCandidate first). A new PROGRAM also needs AddPlcTask + LinkProgramToTask. data: path, folderPath, objectKind (POU), itemType (602 Program / 603 Function / 604 FunctionBlock), language, declaration (default header; a Function header must contain : ReturnType), projectSaved. A POU / DUT / GVL / ITF with the same name in the PLC project -> POU_CREATE_FAILED with its path, nothing created; a failed readback names the step (the object stays in the tree, error.hint). Saved only in XAE memory -> PROJECT_SAVE_FAILED / PROJECT_SAVE_TIMEOUT (data.objectPath, createdInMemory; follow error.hint). PLC still logged in -> PLC_LOGGED_IN, nothing created: PlcLogout first, then call it again. A dialog -> IDE_MODAL_DIALOG. Records BUILD_REQUIRED: BuildProject before EnableConfig / PlcLogin. Details GetGuide(''change-code'').'
    'AddDut'          = 'Create a DUT (Struct / Enum / Union / Alias) in <Plc> Project^DUTs, write its declaration (TYPE ... END_TYPE from Fields / AliasType), save the project files and read it back. Fields is an ARRAY in declaration order: [{"name":"bStart","type":"BOOL"},{"name":"nCount","type":"INT","init":"0","comment":"..."}]; the object form {"bStart":"BOOL"} or an invalid entry (name not an identifier, duplicate, missing type, unknown key) -> INVALID_PARAMS, nothing created. Enum: [{"name":"eIdle","value":0},{"name":"eRun","value":1}]. The member order read back must equal the input, else MEMBER_ORDER_MISMATCH (data.expectedOrder, data.actualOrder; the DUT exists: fix it with WritePouCode). data: path, objectKind (DUT), itemType (605 Enum / 606 Struct / 607 Union / 623 Alias), declaration, memberOrder, projectSaved. Name exists or declaration reads back different -> DUT_CREATE_FAILED. Change it later with WritePouCode Declaration only. Saved only in XAE memory -> PROJECT_SAVE_FAILED / PROJECT_SAVE_TIMEOUT (data.objectPath, createdInMemory; follow error.hint). PLC still logged in -> PLC_LOGGED_IN, nothing created: PlcLogout first, then call it again. A dialog -> IDE_MODAL_DIALOG. Records BUILD_REQUIRED: BuildProject before EnableConfig / PlcLogin. Details GetGuide(''change-code'').'
    'AddLibrary'      = 'Add a library reference to the PLC project: ITcPlcLibraryManager.AddLibrary(Name, Version, Vendor) on TIPC^<Plc>^<Plc> Project^References (TE1000 6.5.14). Version * = newest installed (.plcproj gets LibraryReference Include="<name>,newest,<vendor>"). Already referenced (also as placeholder #<name>): success with data.alreadyPresent=true, nothing added, no BUILD_REQUIRED. Not installed: LIBRARY_ADD_FAILED with data.notInstalled=true and an install hint; nothing is saved, the .plcproj is unchanged. Several PLC projects: pass PlcProjectPath (else PLC_PROJECT_AMBIGUOUS). BUILD_REQUIRED (#65): the added reference (also when AddLibrary failed for another reason) records kind code-changed for the open solution (data.buildRequired names the tool and the library; data.stateWarning when the state file could not be written): EnableConfig / PlcLogin / SendPlcProgram then refuse with BUILD_REQUIRED until BuildProject returns data.completeBuild=true. Project file (#76): the reference is stored in the .plcproj, which is saved (DTE Project.Save of the .tsproj, deadline: PROJECT_SAVE_TIMEOUT) and read back from disk: success only when it lists a library reference named Name (data.projectSaved); otherwise PROJECT_SAVE_FAILED or IDE_MODAL_DIALOG. What else Project.Save writes (measured 2026-10-28, 4026 VS2022): a dirty plain text document is NOT saved; whether unsaved content of a PLC editor (a POU edited in the GUI) is written was NOT verified.'
    'AddGvl'          = 'Create a GVL in <Plc> Project^GVLs, write VAR_GLOBAL ... END_VAR from Variables, save the project files and read it back. Variables is an ARRAY in declaration order: [{"name":"bStart","type":"BOOL"},{"name":"nCount","type":"INT","init":"0","comment":"..."}]; the object form {"bStart":"BOOL"} or an invalid entry (name not an identifier, duplicate, missing type, unknown key) -> INVALID_PARAMS, nothing created. The variable order read back must equal the input, else MEMBER_ORDER_MISMATCH (data.expectedOrder, data.actualOrder; the GVL exists: fix it with WritePouCode). data: path, objectKind (GVL), itemType 615, declaration, memberOrder, projectSaved. Name exists or declaration reads back different -> GVL_CREATE_FAILED. Change it later with WritePouCode Declaration only. Saved only in XAE memory -> PROJECT_SAVE_FAILED / PROJECT_SAVE_TIMEOUT (data.objectPath, createdInMemory; follow error.hint). PLC still logged in -> PLC_LOGGED_IN, nothing created: PlcLogout first, then call it again. A dialog -> IDE_MODAL_DIALOG. Records BUILD_REQUIRED: BuildProject before EnableConfig / PlcLogin. Details GetGuide(''change-code'').'
    # complete-automation-interface phase 3, task 4.5: credentials never go through the tool input.
    'AddAdsRoute'     = 'NOT MEASURED (no second target was available; only unit tests): add an ADS route to a remote system (TIRR ConsumeXml AddRoute: Name, NetId, Address (IPv4) or HostName, UserName, LocalName) or, with ProjectRoute=true, only a project route (AddProjectRoute, no credentials). DryRun defaults to true. The password is NEVER a tool input: PasswordEnv names an environment variable of the MCP server process (Process scope only; the name must be TCAUTO_ROUTE_PW or TCAUTO_ROUTE_PW_<SUFFIX>, anything else is INVALID_PARAMS; set it in the server env of your MCP client config); data, errors, logs and backups never contain the password or the XML (masked as ***). AddRoute credentials are protected only by a fixed key on the network (Beckhoff advisory 2017-002): trusted networks only. A route to the same NetId -> ROUTE_ALREADY_EXISTS; TIRR is read back (ROUTE_VERIFY_FAILED). There is no tool to remove a route: the Automation Interface cannot (edit StaticRoutes.xml and restart the TwinCAT service, which also stops a local UmRT; see docs/troubleshooting.md).'
    # complete-automation-interface phase 2, task 3.6. Not yet verified through the registered server (task 3.8).
    'AddPouMember'    = 'Add a Method, Property, Action, or a property Get / Set accessor below a PROGRAM / FUNCTION_BLOCK / INTERFACE (Get / Set: below a property) and read it back. ParentPath: full tree path (TIPC^<Plc>^<Plc> Project^POUs^FB_Motor) or a name as for GetPouCode (FB_Motor, FB_Motor.P_Speed). ReturnType: required for a Property, optional for a Method, not allowed for Action / Get / Set; Name is not needed for Get / Set. Access PUBLIC / PRIVATE / PROTECTED / INTERNAL (not on interface members). A property gets no Get / Set by itself: add them with Kind Get / Set. data.path = full tree path of the member: pass it as PouPath to GetPouCode / WritePouCode. Nothing created on: POU_MEMBER_INVALID, POU_MEMBER_UNSUPPORTED, POU_MEMBER_EXISTS (data.existingPath), POU_AMBIGUOUS (data.candidates), IDE_MODAL_DIALOG, PLC_LOGGED_IN (PlcLogout first). POU_MEMBER_CREATE_FAILED = the member stays in the tree (error.hint). Records BUILD_REQUIRED. Details GetGuide(''change-code'').'
    'AddInterface'    = 'Create an INTERFACE (CreateChild 618, TE1000 v1.7.0 6.5.5) in <Plc> Project^POUs (or PlcProjectPath) and read it back: the declaration must be INTERFACE <Name> (EXTENDS <Extends> when given). Extends is one string (an array is refused by XAE, measured 2026-10-31 4026 VS2022); not an identifier list -> INVALID_PARAMS. Same checks, BUILD_REQUIRED (#65), project file save (#76, .TcIO in the .plcproj) and PLC_LOGGED_IN as AddPou; failure codes POU_CREATE_FAILED (step in the message), PROJECT_SAVE_FAILED / PROJECT_SAVE_TIMEOUT, IDE_MODAL_DIALOG. data: path, folderPath, objectKind (ITF), itemType 618, extends, declaration, projectSaved. Add methods / properties with AddPouMember ParentPath=<data.path>.'
    # #30: install manifest written by TwinCATSetup-*.ps1
    'GetAutomationVersion' = 'Read-only and offline: which TwinCATAutomation this server runs (#30). Module installed by TwinCATSetup-Claude/Codex/Antigravity.ps1: read from tcauto-install-manifest.json in the skill folder (data.installed=true, source=install-manifest): name, sourceUrl, version, release, commit, ref, commitSource (git / release-stamp / unknown), installer, installedAt, sourcePath, fileCount. Server started from the repository: installed=false, source=source-tree, version from the .psd1 and commit from the .git files (git is not started; uncommitted changes are not detected). data.moduleVersion / modulePath describe the loaded module. Verify=true compares every installed file with the SHA256 in the manifest (data.verify: ok, checked, matched, mismatched [path, expected, actual], missing, extra, unreadable [path, error]): a difference returns INSTALL_MANIFEST_MISMATCH, no manifest INSTALL_MANIFEST_NOT_FOUND, an unreadable manifest INSTALL_MANIFEST_INVALID. Include version and commit when reporting an issue.'
# #214: reads the .sln / .tsproj files only
    'GetProjectVersion' = 'Read-only and offline (reads the .sln and .tsproj files, needs no IDE, ADS or connection): the TwinCAT version a solution was saved with (#214). data.projects[] lists every .tsproj referenced by the .sln with tcVersion (the raw TcVersion attribute of its root element, e.g. 3.1.4026.22) and major / minor / build / revision (null when not parseable). data.launch is the answer of the SAME selection ConnectIde uses when no ProgId is given: wantedProgIds (build >= 4026: TcXaeShell.DTE.17.0 or VisualStudio.DTE.17.0; older: TcXaeShell.DTE.15.0; empty when the build is not decidable), matchingProgIds (installed IDEs among them whose XAE version equals the project TcVersion exactly, revision included; empty when the build is not decidable or no IDE matches), progId (what ConnectIde would launch, null when it would refuse), connectIdeWouldLaunch (true only when ConnectIde without ProgId would launch progId; when false do NOT pick a ProgId yourself and call ConnectIde: opening a project with another XAE version may upgrade or downgrade it, ask the user first), registeredProgIds, ide[] (XAE version of each registered IDE) and errorCode / errorMessage / hint when ConnectIde would refuse (TWINCAT_NOT_FOUND, IDE_VERSION_NOT_REGISTERED, PROGID_REQUIRED): that is part of the answer, success stays true. Use it before ConnectIde to see which IDE a solution needs. Errors: SOLUTION_NOT_FOUND, TSPROJ_NOT_FOUND (no .tsproj in the .sln), TCVERSION_UNKNOWN (a .tsproj has no readable TcVersion; data.projects[].error), each with error.hint.'
    # #229: TwinCAT Package Manager CLI (tcpkg); InstallPackage is plan-only unless Approved=true
    'LintCandidate'   = 'Read-only and offline semantic lint of ONE PLC object BEFORE it is written: the candidate Declaration / Implementation is laid over the .plcproj on disk in memory and checked with the LintProject rules, scoped to that object; nothing is written, no IDE, no ADS, no lifecycle block. Workflow: LintCandidate -> fix until it passes and requiresDisposition is false -> WritePouCode (or AddPou + WritePouCode) -> BuildProject -> LintProject. ObjectKind: Program, FunctionBlock, Function, DUT, GVL, Interface, Method, Property, Action. ObjectName as WritePouCode PouName: FB_X, FB_X.M_Run, FB_X.P, FB_X.P.Get. Implementation only ST. PlcProjectPath = path of the .plcproj; omitted = text-only: a candidate that needs the project gives LINT_CONTEXT_REQUIRED (data.candidate.contextRequired), never a silent pass. A pass is NOT a pass of the project: run LintProject after writing. requiresDisposition=true -> fix each data.unresolved[] or suppress it inline with a reason, and list every data.newSuppressions[] and data.newOverrides[] to the user; no EnableConfig before that. data: as LintProject plus contextLevel, candidate, crossObject {checked, newFindings[], blocking}, preExisting[], projectVerdict. Errors, each with error.hint: LINT_FAILED, LINT_PARSE_FAILED, LINT_CONTEXT_REQUIRED, LINT_INCOMPLETE, LINT_INPUT_INVALID, LINT_PROFILE_INVALID, LINT_BASELINE_INVALID, LINT_ENGINE_ERROR, LINT_ENGINE_UNAVAILABLE. Details GetGuide(''change-code'').'
    'LintProject'     = 'Read-only and offline semantic lint of a TwinCAT PLC project ON DISK: reads the .plcproj, every file its <Compile> items list, the .tsproj and the .sln; needs no IDE, no ADS, writes nothing. Checks project integrity broken by editing files outside XAE (PROJECT-*), ST parsing (LINT-PARSE-*) and machine behaviour Build does not catch (SCAN-TEMPFB-001, PROJECT-TASK-001 / 002, SCAN-LOOP-001, SCAN-FOR-001, SCAN-ARR-001, SAFETY-ARR-001, SAFETY-DIV-001). Use it after changing .TcPOU / .plcproj / .tsproj files directly: LintProject -> only when it passes ResetSolution -> BuildProject; and after WritePouCode + BuildProject. PlcProjectPath = path of the .plcproj file; or SolutionPath with PlcProjectPath = the PLC name (several PLCs without a name: PLC_PROJECT_AMBIGUOUS, data.plcProjects). Scope=Object checks only ObjectPaths: run Scope=All before ResetSolution / BuildProject. passed=true does NOT mean the program is correct: read data.coverage and data.unresolved with it. requiresDisposition=true -> fix each data.unresolved[] or suppress it with a reason; list every data.newSuppressions[] and data.newOverrides[] to the user, no EnableConfig before that. Never delete Compile items, reuse GUIDs or weaken the lint profile to get a pass. data: verdict (pass / fail / incomplete), passed, diagnostics[], unresolved[], requiresDisposition, summary, coverage, profile, baseline, source, engine. Errors, each with error.hint: LINT_FAILED, LINT_PARSE_FAILED (BuildProject decides), LINT_INCOMPLETE, LINT_INPUT_INVALID, PLC_PROJECT_AMBIGUOUS, PLC_PROJECT_NOT_FOUND, LINT_PROFILE_INVALID, LINT_BASELINE_INVALID, LINT_ENGINE_ERROR, LINT_ENGINE_UNAVAILABLE. Details GetGuide(''change-code'').'
    'GetPackageInfo'  = 'Read-only (#229): installed and feed versions of the TwinCAT XAE / XAR / Remote Manager packages through the TwinCAT Package Manager CLI tcpkg (tcpkg list -i --as-json, then tcpkg list <id> -a --as-json per id: a network query of the feeds the user configured; nothing is installed, no credentials are handled). PackageId default: TwinCAT.Standard.XAE, TwinCAT.Standard.XAR, TwinCAT.StandardRM.XAE (Remote Manager). NoAvailable=true = installed only (offline). data: installed[] {id, version, installDate, workload}, available[] {id, version, source (feed name, e.g. Beckhoff Outdated Feed), isPreview, installed}; every TwinCAT.StandardRM.XAE entry also has buildFolder (Build_<a>.<b> of version <a>.<b>.<c>, e.g. 4024.71.2 -> Build_4024.71, measured 2026-11-12), buildFolderPath and buildFolderExists (the folder ConnectIde needs for a 4024 project); remoteManagerRoot, remoteManagerBuilds, runs[] (command line, exit code, seconds). Use it when ConnectIde / GetProjectVersion say a Remote Manager version is missing, before InstallPackage. Errors: TCPKG_NOT_FOUND (tcpkg not installed), TCPKG_TIMEOUT (one call exceeded TimeoutSec, default 60 s each, and was stopped), TCPKG_LIST_FAILED (exit code not 0, e.g. unknown id / feed not reachable or not signed in, or output not JSON; data.runs[].stderrTail), each with error.hint.'
    'InstallPackage'  = 'Install a TwinCAT XAE or Remote Manager version with tcpkg; changes TwinCAT on this PC. ASK THE USER FIRST: WITHOUT Approved=true NOTHING is installed: the result is a plan (success=true, data.executed=false, data.plan, data.planToken, data.command, requiresAdministrator, runningIdes, blockers[]). Show data.plan to the user and ask; call again with Approved=true AND PlanToken=<data.planToken> ONLY after the user agreed. Consent (MCP): Approved=true makes the server ask the user in a confirmation form (MCP elicitation) every time, showing the plan of that PlanToken; you cannot answer it. Refused: CONSENT_DECLINED (the user did not approve) or CONSENT_REQUIRED (no form possible, failed or timed out, or a PlanToken this server did not issue); nothing ran: stop and report, do not retry or work around it; the refusal hint and data.command carry the tcpkg command the user can run in an elevated PowerShell. Never elevate, never close or kill IDEs yourself. PackageId: TwinCAT.Standard.XAE or TwinCAT.StandardRM.XAE only; Version: an exact version from GetPackageInfo data.available[].version. Fail closed: success only when tcpkg list -i lists the version afterwards. Errors: TCPKG_PLAN_REQUIRED (new plan, ask again), TCPKG_NOT_FOUND, TCPKG_SIGNATURE_INVALID, TCPKG_ELEVATION_REQUIRED, TCPKG_PRECHECK_FAILED, TCPKG_IDE_RUNNING, TCPKG_RUNNING, TCPKG_VERSION_NOT_FOUND, TCPKG_INSTALL_FAILED, TCPKG_TIMEOUT (tcpkg may still run: wait for data.installProcessId to end, then GetPackageInfo; never rerun), TCPKG_INSTALL_UNVERIFIED. data: steps[], changedPackages, unexpectedChanges / warnings (report them). Details GetGuide(''consent'').'
    'GetPouCode'      = 'Read the source of a PLC object: POU, DUT, GVL, interface, method ... data.objectKind (POU / DUT / GVL / ITF / METHOD / ACTION / PROPERTY_GET / ... / UNKNOWN, from the tree item ItemType; data.itemType, data.itemTypeName), data.pouType (Program / Function / FunctionBlock for a POU, Struct / Enum / Union / Alias for a DUT), data.language (ST / LD / FBD ..., null for DUT / GVL / ITF), data.hasImplementation, data.implementationReadable, data.declaration, data.implementation. hasImplementation=false (DUT, GVL, ITF, property): implementation is null because the object has no implementation part, the whole source is in declaration. A POU returns an implementation string (empty when there is no code; LD / FBD return XAE XML, not ST); implementationReadable=false means it has an implementation part that did not come back as text (implementation null). A COM call that throws, or a declaration that reads null, returns POU_READ_FAILED. Members: PouPath <POU path>^<member> (accessor ^<property>^Get), or PouName Parent.Member (FB_X.M_Run, FB_X.P_Value.Get; tried after the name as given). A name that several objects carry (M_Run in two FBs) -> POU_AMBIGUOUS with data.candidates (full paths), never the first hit. The Get / Set of an INTERFACE property (ItemType 654 / 655) -> POU_MEMBER_UNSUPPORTED, nothing read (reading it crashed VS2022, measured 2026-10-31 4026 VS2022). An ItemType that cannot be read -> POU_READ_FAILED reason itemtype-unreadable (fail-closed).'
    'WritePouCode'    = 'Write Declaration and/or Implementation of an existing PLC object through the XAE edit buffer (no ResetSolution needed). DUT / GVL / ITF / property have only a declaration: passing Implementation for one of them returns INVALID_PARAMS and nothing is written (data.objectKind; for a property the hint points to its ^Get / ^Set accessor); send the whole TYPE ... END_TYPE / VAR_GLOBAL ... END_VAR as Declaration. An action has only an implementation: Declaration on it -> INVALID_PARAMS. Implementation "" clears the body (written as '' and read back empty, data.cleared=true; otherwise POU_WRITE_FAILED reason empty-not-applied); Declaration "" -> POU_WRITE_FAILED reason empty-not-supported, nothing written. Members and POU_AMBIGUOUS / POU_MEMBER_UNSUPPORTED (ITF property Get / Set) as for GetPouCode. data: pouPath, resolvedBy, objectKind, updated[], cleared. Run BuildProject afterwards to compile. BUILD_REQUIRED (#65): a write records kind code-changed (also a write that failed after a setter was called: the edit buffer may have changed; a request refused before any setter records nothing). An ItemType that cannot be read -> POU_WRITE_FAILED reason itemtype-unreadable, nothing written for the open solution (data.buildRequired names the tool and the object; data.stateWarning when the state file could not be written): EnableConfig / PlcLogin / SendPlcProgram then refuse with BUILD_REQUIRED until BuildProject returns data.completeBuild=true.'
}
# #68 fail-closed guard: the same sentence on every tool that is refused while a lifecycle block exists.
$lifecycleBlockNote = ' Fail closed: success=true only after the readback reached the requested state. LIFECYCLE_BLOCKED (an earlier runtime-changing request failed: data.lifecycleBlock) = this tool does nothing: stop, report data.lifecycleBlock to the user, never switch to another control channel (raw ADS, COM, DTE, GUI, console); ClearLifecycleBlock only after the user agreed.'
# Appended in the tool loop below (also to a description that comes from the comment-based help).
$lifecycleBlockedTools = @('SetSystemState', 'EnableConfig', 'PlcLogin', 'SendPlcProgram', 'SetPlcState', 'WriteVariable', 'RunTest', 'RunTestCycle', 'SetTcComParameter')

# #258: the consent gate of the MCP server (mcp-server/lib/consent.js), appended like the #68 note.
$consentRefused = ' CONSENT_DECLINED (the user did not approve) / CONSENT_REQUIRED (no form possible, failed or timed out) = nothing ran: stop and report, do not retry or work around it.'
$consentRuntimeNote = ' Confirmation: targetKind local-umrt never asks. Any other target (local-xar, remote, unknown) is a real machine: before the first such call of this session to that target tell the user what can happen (TwinCAT restarts, the PLC stops and starts, outputs switch, axes can move). Through the MCP server the server then asks the user in a confirmation form (MCP elicitation): you cannot answer it and a chat answer is not consent. Without the MCP server (PowerShell) ask once yourself.' + $consentRefused
$consentNotes = @{
    # InstallPackage: the consent rule is part of its description (front), #310
}
foreach ($t in @('EnableConfig', 'RunTestCycle', 'RunTest', 'WriteVariable', 'SetPlcState', 'SetSystemState', 'PlcLogin', 'SendPlcProgram')) { $consentNotes[$t] = $consentRuntimeNote }
$consentNotes['SetTcComParameter'] = $consentRuntimeNote.Replace('Any other target', 'With Online=true and DryRun=false, any other target')

# Per-tool timeouts in ms (Node side kills and restarts the bridge when exceeded).
$defaultTimeoutMs = 120000
$timeoutOverrides = @{
    'BuildProject'   = 690000   # default TimeoutSec 600 + 90 s (Error List 30 s + readbacks, #107 / #138; mcp-server/lib/tools.js TOOL_GRACE_MS)
    'CleanProject'   = 360000   # default TimeoutSec 300 + 60 s (Error List after a failed clean; lib/tools.js TOOL_GRACE_MS, #138)
    'CheckAllObjects' = 600000
    'GenerateBootProject' = 600000
    'EnableConfig'   = 600000
    'RunTestCycle'   = 900000
    # #249: worst case of a cold launch (Connect-TcIde stage deadlines: launch poll 60 + ROT 10 + modal
    # scan with the #230 retry 85 + solution load 60 + ITcSysManager 10 + reads ~5 = 230 s, plus a check
    # before the launch: own pending IDE wait 60 s or #235 empty-orphan check up to 115 s) = 345 s + margin.
    # The node side cannot know beforehand whether the call launches; an attach returns in seconds.
    'ConnectIde'     = 360000
    'OpenProject'    = 180000
    'ResetSolution'  = 180000
    'PlcLogin'       = 300000
    'SendPlcProgram' = 300000
    'SetSystemState' = 180000
    'SetPlcState'    = 180000
    'IoScan'         = 180000
    'GetPackageInfo' = 420000   # default: up to 6 tcpkg calls x TimeoutSec 60 (list -i + list -a per id, at most 5 ids) + margin; lib/tools.js TOOL_GRACE_MS covers TimeoutSec up to 120
    'InstallPackage' = 2200000  # default TimeoutSec 1800 for the install + 3 x 120 s tcpkg list + margin; lib/tools.js TOOL_GRACE_MS
    # #321 (review M1): the module's call deadline ($script:TcTreeItemCallDeadlineSec, TreeItemPath.ps1:
    # Export 145 s, Remove 265 s; no dialog scan or COM call - retries and the readback included - starts after
    # it, review r2) + $script:TcTreeItemAfterDeadlineSec (35 s). The timeout runs over the whole call: the last
    # COM call, started before the module deadline, has the rest of it to return; no per-COM-call timeout.
    # The deadlines hold every gate at ModalScanTimeoutSec 60 + the 60 s prepare cap. computeTimeoutMs only
    # reads TimeoutSec, so these stay for any ModalScanTimeoutSec. Checked against the module source by
    # tests/Unit/tree-item-tools.ps1 and mcp-server/test/tools.test.js.
    'ExportChild'    = 180000
    'DeleteChild'    = 300000
}

# MCP tool annotations (https://modelcontextprotocol.io: ToolAnnotations).
# readOnlyHint: no side effects on IDE/project/runtime.
# destructiveHint: changes the running machine / runtime / connection state in a way
# that cannot simply be undone. Everything else (project edits, connecting) is
# readOnlyHint=false, destructiveHint=false.
$readOnlyTools = @(
    'GetIdeInfo', 'GetProjectTree', 'GetPouCode', 'GetIoTree', 'GetBuildErrors', 'GetSymbols',
    'GetPlcState', 'GetSystemState', 'ReadVariable', 'WatchVariable', 'NewTestCase',
    'LookupTreeItem', 'ProduceXml', 'GetLibraries',
    # CheckAllObjects (task 3.7) generates no code and changes no file (phase2-probe.md 3.7)
    'CheckAllObjects',
    # TcCOM parameter read (task 4.2): offline from the project, -Online from the running object
    'GetTcComParameter',
    'GetVariants', 'GetAdsRoutes',
    # ReportIssue (#78): only formats text (a pre-filled GitHub new-issue URL); no IDE / ADS / network call
    'ReportIssue',
    # FindAdsTargets (task 4.5): sends a broadcast / search on the network but changes nothing
    'FindAdsTargets',
    # #30: reads the install manifest / module version, writes nothing
    'GetAutomationVersion',
    # #214: reads the .sln / .tsproj files only
    'GetProjectVersion',
    # #229: read-only tcpkg list (installed + feed versions; network)
    'GetPackageInfo',
    # #252: semantic lint of the project files on disk / of a candidate object in memory; writes nothing, no IDE / ADS
    'LintProject', 'LintCandidate'
)
# openWorldHint: the tool talks to systems outside the IDE / project (network search).
$openWorldTools = @('FindAdsTargets', 'GetPackageInfo')
$destructiveTools = @(
    'EnableConfig', 'SetSystemState', 'SetPlcState', 'WriteVariable', 'RunTest', 'RunTestCycle',
    'PlcLogin', 'SendPlcProgram', 'IoScan', 'SetTarget', 'DisconnectIde', 'PlcLogout', 'ResetSolution',
    # Generic tree tools that change / delete configuration (design D2): dry-run by default.
    'CreateChild', 'ConsumeXml', 'DeleteChild', 'ImportChild',
    # Library Manager (task 3.1): remove / freeze change the project, install / uninstall the
    # library repository of the whole machine; dry-run by default.
    'RemoveReference', 'InstallLibrary', 'UninstallLibrary', 'FreezePlaceholder',
    # PLC task program call removal (task 3.5); dry-run by default.
    'UnlinkProgramFromTask',
    # PLCopen import (task 3.3): Replace deletes children the file lacks; dry-run by default.
    'ImportPlcOpen',
    # Phase 3 system configuration (tasks 4.1-4.5): change the TwinCAT configuration; dry-run by default.
    'AddNcTask', 'AddNcAxis', 'SetNcAxisParameter', 'LinkNcAxis',
    'AddTcComModule', 'SetTcComParameter', 'SetTcComContext',
    'SetVariantConfig', 'SwitchVariant', 'SetIndependentFile', 'AddAdsRoute',
    # #68: lifts the fail-closed lifecycle block (only after the user agreed)
    'ClearLifecycleBlock',
    # #229: installs XAE / Remote Manager on the whole machine; plan only unless Approved=true
    'InstallPackage'
)

function Get-ToolAnnotations {
    param([string]$ToolName)
    if ($readOnlyTools -contains $ToolName -and $openWorldTools -contains $ToolName) { return [ordered]@{ readOnlyHint = $true; openWorldHint = $true } }
    if ($readOnlyTools -contains $ToolName) { return [ordered]@{ readOnlyHint = $true } }
    if ($destructiveTools -contains $ToolName) { return [ordered]@{ readOnlyHint = $false; destructiveHint = $true } }
    return [ordered]@{ readOnlyHint = $false; destructiveHint = $false }
}

# Parameter description overrides: "<ToolName>.<ParamName>" = text.
$paramDescriptionOverrides = @{
    'ReadVariable.Path'       = 'Array of PLC symbol paths, e.g. ["MAIN.nCounter"]. Always an array, also for a single variable.'
    'WriteVariable.Value'     = 'New value matching the PLC type of the symbol: JSON bool (BOOL), number (integer/REAL/LREAL), string (STRING). TIME/TOD: "T#6s" / "T#1m30s500ms" / "TOD#12:30:00" (integer ms also accepted); LTIME/LTOD: "LTIME#1us" (or integer ns); DATE/DT: "D#2026-10-20", "DT#2026-10-20-12:30:00" or ISO 8601 (or integer seconds since 1970); LDATE/LDT: "LDT#..." (or integer ns); enum: integer or member name ("READY").'
    'ConnectAds.AmsNetId'     = 'Target AmsNetId. Leave empty to auto-detect from the IDE target (recommended; it differs per target).'
    # tcauto-allow(amsnetid): tool text that documents the read-only local fallback of GetSystemState
    'GetSystemState.AmsNetId' = 'Target AmsNetId. Leave empty to use the IDE target, then the ADS session, then the local system 127.0.0.1.1.1 (see data.netIdSource).'
    'SetPlcState.State'       = 'Run, Stop or Reset. Reset leaves the PLC in Stop (an older report that it kills TcSystemServiceUm on a UmRT did not reproduce: 實測 2026-11-08, #26).'
    'EnableConfig.Force'      = 'true = full lifecycle without dialogs (Config -> Activate -> Run -> Login/Download -> PLC Run).'
    'EnableConfig.NoLogin'    = 'true = stop after TwinCAT reaches Run; skip PLC login/download/Run.'
    'EnableConfig.NoPlatformFix' = 'true = do not switch the solution platform; a mismatch with the target (or Platform) platform returns PLATFORM_MISMATCH before anything is activated.'
    'EnableConfig.Platform'   = 'Reference platform used only when the target does not report one through TARGETINFO (ADS 0x702): ''TwinCAT OS (x64)'' for a Usermode Runtime / UmRT or TwinCAT/BSD, ''TwinCAT RT (x64)'' for a Windows RT target. A platform the target reports wins.'
    'SetTarget.Platform'      = 'Solution platform to activate, e.g. ''TwinCAT OS (x64)'' (Usermode Runtime / UmRT, TwinCAT/BSD) or ''TwinCAT RT (x64)'' (Windows RT). Omit to follow the platform the target reports (TARGETINFO); a target without TARGETINFO then returns PLATFORM_UNKNOWN.'
    'SetTarget.Configuration' = 'Solution configuration name. With Platform default Release; for the automatic switch the active configuration.'
    'SetTarget.NoPlatformSwitch' = 'true = only set the target NetId; never touch the solution platform and never return PLATFORM_UNKNOWN.'
    'NewTestCase.Setup'       = 'Writes before the test: array of {"Path":"MAIN.x","Value":1} (keys Path = PLC symbol path, Value = value to write, converted to the PLC type).'
    'NewTestCase.Teardown'    = 'Writes after the test (also run when the test fails): array of {"Path":"MAIN.x","Value":0} (keys Path, Value).'
    'NewTestCase.WaitUntil'   = 'Conditions to poll before the assertions (replaces WaitMs): array of {"Path":"MAIN.bDone","Operator":"IsTrue"} (same keys and Operator set as Assertions; Expected omitted for IsTrue/IsFalse). All conditions must hold in the same 100 ms sampling round; assertions then run immediately. Not met within WaitTimeoutMs: the test case is Fail with waitTimedOut=true, lastValues, waitMs. Invalid entries: INVALID_PARAMS.'
    'NewTestCase.WaitTimeoutMs' = 'Maximum time in ms to poll WaitUntil (1..600000, default 5000). Only used with WaitUntil.'
    'NewTestCase.WaitMs'      = 'DEPRECATED: fixed blind wait in ms before the assertions (default 1000), ignored when WaitUntil is given. Use WaitUntil.'
    'NewTestCase.Assertions'  = 'Checks after WaitUntil (or the deprecated WaitMs): array of {"Path":"MAIN.y","Operator":"Equal","Expected":1}. Keys: Path (PLC symbol path), Operator (optional, default Equal; one of Equal, NotEqual, GreaterThan, LessThan, GreaterThanOrEqual, LessThanOrEqual, Contains, IsTrue, IsFalse), Expected (omit for IsTrue/IsFalse). Short forms like "eq"/"gt" are NOT accepted.'
    'AddDut.Fields'           = 'Members in declaration order (array; the order is kept and verified on readback, #47). Struct / Union: [{"name":"bStart","type":"BOOL"},{"name":"nCount","type":"INT","init":"0","comment":"counter"}] (name and type required). Enum: [{"name":"eIdle","value":0},{"name":"eRun"}] (value optional). Ignored for Alias.'
    'AddGvl.Variables'        = 'Variables in declaration order (array; the order is kept and verified on readback, #47): [{"name":"bStart","type":"BOOL"},{"name":"nCount","type":"INT","init":"0","comment":"counter"}] (name and type required).'
    'RunTest.TestCase'        = 'A test case object as returned by NewTestCase.'
    'RunTestCycle.TestCases'  = 'Array of test case objects as returned by NewTestCase.'
    'DeleteChild.AllowNoExport' = 'true = delete even when the ExportChild backup (.xti, .zip below TIPC) failed or was not written (only the recursive ProduceXml backup remains, ImportChild cannot restore it; data.warnings says so). Default false: TREEITEM_BACKUP_FAILED, nothing deleted.'
    'DisconnectIde.Quit'      ='true = also close the solution (without saving) and quit the IDE.'
    'DisconnectIde.Kill'      = 'Only with Quit=true: kill the IDE process when it cannot be quit (modal dialog, DTE.Quit failed). Only for an IDE this session launched (data.ownedBySession); any other IDE -> IDE_NOT_OWNED, nothing killed.'
    'ResetSolution.SolutionPath' = '.sln to reopen. Default: the solution ConnectIde / OpenProject opened.'
    'WatchVariable.Path'           = 'One or more variable paths to monitor, e.g. ["MAIN.nCounter"] or ["MAIN.fActual","MAIN.bDone"]. Always an array.'
    'WatchVariable.Until'          = 'Stop condition ''<Path> <op> <value>'' with op one of == != > < >= <=, e.g. ''MAIN.fTarget == 123.5''. <Path> must be in Path (case-insensitive).'
    'WatchVariable.UntilTimeoutMs' = 'Maximum time in ms to wait for Until before returning untilMet=false. Default 5000.'
    'WatchVariable.TimeoutMs'      = 'Legacy alias of UntilTimeoutMs; used only when UntilTimeoutMs is not given.'
    'WatchVariable.KeepLast'       = 'Number of most recent samples to return. 0 = auto (20 with Until, 50 without). sampleCount still counts every round; truncated=true when older samples were dropped.'
    'WatchVariable.DurationMs'     = 'Sampling duration in ms when Until is not given (default 2000).'
    'ResetSolution.TimeoutSec'   = 'Expected upper bound for each of Documents.CloseAll, Solution.Close and Solution.Open, and the total time Solution.FullName is polled in one call (wait after a Yes reload, solution check), in seconds (default 120).'
    'ResetSolution.DiscardProjectChanges' = 'true = keep the disk version: skip the project file check and close without saving even when PLC objects in XAE are missing from the .plcproj on disk (they are dropped). Use after PROJECT_UNSAVED_CHANGES when the disk version is the one to keep. Not together with SaveProjectChanges.'
    'ResetSolution.Force' = 'true = the user agreed to drop the unsaved changes of the IDE that UNSAVED_CHANGES listed (data.unsavedCheck): close without saving anyway; data.discardedChanges lists what was dropped. Only after asking the user. Not together with SaveProjectChanges.'
    'ResetSolution.SaveProjectChanges' = 'true = keep the XAE version: objects in XAE that the .plcproj on disk does not list are saved (project files only) before closing. Refused (PROJECT_UNSAVED_CHANGES, data.saveRefused) when the disk shows a change: a reload prompt was handled, an object file is missing on disk, or any PLC of the same .tsproj (Project.Save writes all of them) could not be compared, was compared incompletely or its .plcproj lists objects XAE does not have. Not together with DiscardProjectChanges.'
    'GetPouCode.PouPath'      = 'Full tree path; omit to auto-detect from PouName (POUs folder -> project root -> tree search depth 4 -> Parent.Member, see data.pouPath / data.resolvedBy). Format on 4024 and 4026: TIPC^<Plc>^<Plc> Project^POUs^<name>; DUT ...^DUTs^<name>, GVL ...^GVLs^<name>; member ...^<POU>^<member>, accessor ...^<POU>^<property>^Get. Use GetProjectTree with PlcOnly=true to list paths.'
    'WritePouCode.PouPath'    = 'Full tree path; omit to auto-detect from PouName (POUs folder -> project root -> tree search depth 4 -> Parent.Member, see data.pouPath / data.resolvedBy). Format on 4024 and 4026: TIPC^<Plc>^<Plc> Project^POUs^<name>; DUT ...^DUTs^<name>, GVL ...^GVLs^<name>; member ...^<POU>^<member>, accessor ...^<POU>^<property>^Get. Use GetProjectTree with PlcOnly=true to list paths.'
    'AddInterface.PlcProjectPath' = 'Tree path of the folder the interface is created in, e.g. TIPC^<Plc>^<Plc> Project^POUs (same as AddPou PlcProjectPath). Omit to auto-detect (<Plc> Project^POUs, else the <Plc> Project node; see data.folderPath).'
    'AddPou.PlcProjectPath'   = 'Tree path of the folder the POU is created in, e.g. TIPC^<Plc>^<Plc> Project^POUs (same on 4024 and 4026). Omit to auto-detect (<Plc> Project^POUs, else the <Plc> Project node; see data.folderPath).'
    'GetProjectTree.Depth'    = 'Levels below each root node (1-10, default 4). 4 reaches the POUs: TIPC(0)^<Plc>(1)^<Plc> Project(2)^POUs(3)^<POU>(4). Nodes at the limit that have children return truncated=true.'
    'GetProjectTree.PlcOnly'  = 'true = return only the TIPC (PLC) subtree.'
    'BuildProject.AllowUnresolvedLibrary' = 'Accept a build whose Error List shows unresolved libraries as success (data.warningCode=LIBRARY_UNRESOLVED, codeVerified=false) instead of returning LIBRARY_UNRESOLVED. It is not a complete build (data.completeBuild=false): BUILD_REQUIRED stays recorded and EnableConfig / PlcLogin / RunLifecycle still refuse to activate or download it (#61); install the missing libraries for that.'
    'BuildProject.ExpectedProject' = 'PLC project name(s) that must be compiled, e.g. ["FrameworkUnitTest"] (the .plcproj file name without extension). Skipped by the active solution configuration -> PROJECT_SKIPPED_BY_CONFIGURATION (build not started); not in the solution -> EXPECTED_PROJECT_NOT_FOUND; disabled in the TwinCAT project -> EXPECTED_PROJECT_DISABLED.'
    'EnableConfig.PlcProjectPath'  = 'PLC project(s) to log in and start, by name (["FrameworkUnitTest"]) or tree path. Default: every PLC project of the solution.'
    'AddLibrary.PlcProjectPath'    = 'PLC name (FrameworkUnitTest) or tree path (TIPC^FrameworkUnitTest^FrameworkUnitTest Project). Required when the solution has more than one PLC project.'
    'PlcLogin.PlcProjectPath'      = 'PLC name (FrameworkUnitTest) or tree path (TIPC^FrameworkUnitTest^FrameworkUnitTest Project). Required when the solution has more than one PLC project.'
    'PlcLogout.PlcProjectPath'     = 'PLC name (FrameworkUnitTest) or tree path (TIPC^FrameworkUnitTest^FrameworkUnitTest Project). Required when the solution has more than one PLC project.'
    'EnableConfig.ActivateTimeoutSec' = 'Deadline in seconds for ActivateConfiguration() (default 180, also bounded by TimeoutSec with Force). On timeout ACTIVATE_TIMEOUT with data.activateDiagnostics (dialog, dialogSeenDuringWait, ideAlive, ideResponding, runtimeAlive, runtimeCheck, systemState (may be skipped:), elapsedSec, diagnosticsSec) instead of waiting forever; returns within ActivateTimeoutSec + 10 s diagnostics budget + about 1 s.'
    'SetSystemState.SettleSec'     = 'Seconds the reached state must hold before success (sampled every 250 ms, then read back). Default 3; 0 = final readback only.'
}

# Parameters whose JSON schema is written by hand (the .NET type alone says too little).
# #47: AddDut.Fields / AddGvl.Variables are [object] in PowerShell (array, [ordered]@{} or a
# single-member hashtable); over MCP only the ordered array form is offered.
$varEntrySchema = [ordered]@{
    type                 = 'object'
    properties           = [ordered]@{
        name    = [ordered]@{ type = 'string'; description = 'Member name (IEC identifier).' }
        type    = [ordered]@{ type = 'string'; description = 'IEC type, e.g. INT, STRING(20), ST_Motor.' }
        init    = [ordered]@{ type = 'string'; description = 'Optional initial value, e.g. 0 or TRUE.' }
        comment = [ordered]@{ type = 'string'; description = 'Optional one-line comment (written as // comment).' }
    }
    required             = @('name', 'type')
    additionalProperties = $false
}
$dutEntrySchema = [ordered]@{
    type                 = 'object'
    properties           = [ordered]@{
        name    = [ordered]@{ type = 'string'; description = 'Member name (IEC identifier).' }
        type    = [ordered]@{ type = 'string'; description = 'Struct / Union: IEC type of the member (required there).' }
        init    = [ordered]@{ type = 'string'; description = 'Struct / Union: optional initial value.' }
        value   = [ordered]@{ type = @('string', 'integer'); description = 'Enum: optional value, e.g. 0.' }
        comment = [ordered]@{ type = 'string'; description = 'Optional one-line comment (written as // comment).' }
    }
    required             = @('name')
    additionalProperties = $false
}
$schemaOverrides = @{
    'AddDut.Fields'    = [ordered]@{ type = 'array'; items = $dutEntrySchema }
    'AddGvl.Variables' = [ordered]@{ type = 'array'; items = $varEntrySchema }
    # #321 review m1: the cmdlet parameter is [double] + ValidateScript (a whole number 1..60, checked before
    # rounding); over MCP it is an integer 1..60 (validateParams refuses a fraction itself)
    'ExportChild.ModalScanTimeoutSec' = [ordered]@{ type = 'integer'; minimum = 1; maximum = 60 }
    'DeleteChild.ModalScanTimeoutSec' = [ordered]@{ type = 'integer'; minimum = 1; maximum = 60 }
}

# Parameters that are required over MCP although the cmdlet does not declare them Mandatory.
# #113: Clear-TcLifecycleBlock checks the receipt fields itself (LIFECYCLE_RECEIPT_INCOMPLETE as
# JSON instead of a PowerShell prompt / binding error); MCP marks them required.
$requiredOverrides = @('ClearLifecycleBlock.Reason', 'ClearLifecycleBlock.FallbackMethod', 'ClearLifecycleBlock.AllowedSideEffects', 'ClearLifecycleBlock.MaxVerifyLevel')

# Cmdlets that are NOT offered as MCP tools (the cmdlet itself stays in the module).
# NewProject (#70): Solution.Create closes the solution the IDE has open, and the cmdlet has not been
# driven through tcauto itself (measured 2026-11-05, 4024 32-bit XAE Shell and 4026.22 XAE in VS2022:
# create with a self-made client, Build with the registered tcauto, both succeed).
# GetIdeModalDialog (#86): the Get-TcIdeModalDialog cmdlet is not a catalog tool because the composite
# tool of the same name (lib/composites.js) already serves it. The composite must stay: when a modal
# dialog blocks the bridge, it answers through the out-of-process probe, which a plain cmdlet call cannot.
# StartLifecycle (#27): the Start-TcLifecycle cmdlet is served by the composite RunLifecycle (same
# parameters, steps and data fields). Only the composite has the modal probe of each step, a timeout
# per step and the lastIde tracking of its ConnectIde step; one bridge call for the whole lifecycle
# would have none of these.
$excludedTools = @('NewProject', 'GetIdeModalDialog', 'StartLifecycle')

# Parameters of a cmdlet that only other cmdlets pass (not part of the tool contract; review #332 N3)
$internalParameters = @('GetBuildErrors.BuildPaneText', 'GetBuildErrors.RequireBuildSummary', 'GetBuildErrors.ZeroErrorsKnown')

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

# #113: the MaxVerifyLevel enum is the module's own list (Private/LifecycleBlock.ps1)
$schemaOverrides['ClearLifecycleBlock.MaxVerifyLevel'] = [ordered]@{ type = 'string'; enum = @(& $module { $script:TcLifecycleVerifyLevels }) }

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
        # a SecureString cannot come over JSON: AddAdsRoute takes PasswordEnv instead (task 4.5)
        'System.Security.SecureString' { return $null }
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
    if ($excludedTools -contains $toolName) { continue }

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
    # #310: the safety notes go right after the first sentence (front of the description), never to the end.
    $safety = ''
    if ($consentNotes.ContainsKey($toolName)) { $safety += $consentNotes[$toolName] }
    if ($lifecycleBlockedTools -contains $toolName) {
        $note = $lifecycleBlockNote
        if ($toolName -eq 'SetTcComParameter') { $note = $note.Replace('this tool does nothing', 'this tool (Online=true, DryRun=false) does nothing') }
        $safety += $note
    }
    if ($safety) {
        $cut = $description.IndexOf('. ')
        $description = if ($cut -lt 0) { $description.TrimEnd() + $safety } else { $description.Substring(0, $cut + 1) + $safety + ' ' + $description.Substring($cut + 2) }
    }

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
        if ($internalParameters -contains "$toolName.$pName") { continue }
        $meta = $cmd.Parameters[$pName]
        $schema = if ($schemaOverrides.ContainsKey("$toolName.$pName")) { $schemaOverrides["$toolName.$pName"] } else { Get-TypeSchema -Type $meta.ParameterType }
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

        if ($requiredOverrides -contains "$toolName.$pName") { $isMandatory = $true }
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
