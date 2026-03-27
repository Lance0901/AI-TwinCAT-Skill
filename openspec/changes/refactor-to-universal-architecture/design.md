## Context

The initial design packages everything as a Claude Code Skill with standalone PowerShell scripts. This works but locks the project into one AI tool. Meanwhile, the COM automation approach uses generic `EnvDTE` patterns rather than the TwinCAT-specific Automation Interface that Beckhoff provides — missing richer functionality like `ITcSysManager` for system configuration, `ITcSmTreeItem` for tree navigation, and `ITcPlcProject` for PLC-specific operations.

The project must serve three AI tools today (Claude Code, Codex, Antigravity) and remain extensible for future tools. All tools can invoke PowerShell and consume JSON — this is the common denominator.

## Goals / Non-Goals

**Goals:**
- Build a standalone PowerShell module (`TwinCATAutomation`) that any process can import and use
- Use TwinCAT Automation Interface API as the primary COM layer (`ITcSysManager`, `ITcSmTreeItem`, `ITcPlcProject`)
- Provide thin adapters for Claude Code, Codex, and Antigravity that map tool-specific conventions to module cmdlets
- Keep universal Markdown docs that any AI tool can ingest as context
- Maintain JSON as the standard interchange format for all operations
- Enable ADS-based runtime variable access for reading/writing PLC data at runtime
- Provide a complete test-build-run cycle that AI tools can invoke to verify PLC code correctness
- Support independent PLC runtime control (Login/Logout, Run/Stop/Reset)

**Non-Goals:**
- GUI or interactive mode — this is a headless automation module
- Supporting TwinCAT 2 or non-Windows platforms
- Building a REST API layer (PowerShell module + JSON is sufficient)
- Deep integration with each AI tool's proprietary plugin system beyond basic adapter wiring

## Decisions

### 1. PowerShell module with Public/Private function layout
**Decision**: Structure as a proper PowerShell module (`TwinCATAutomation.psm1`) with exported public cmdlets and internal private helpers.
**Rationale**: A module can be imported by any PowerShell session — AI tool adapters just `Import-Module` and call cmdlets. This is cleaner than loose scripts and enables proper parameter validation, help text, and tab completion. Alternatives:
- Loose scripts (current): No encapsulation, harder to version, each AI tool must know individual script paths
- C# library: Would need compilation, harder for users to modify/debug

### 2. TwinCAT Automation Interface as primary API
**Decision**: Use `ITcSysManager` (obtained via `$dte.Solution.Projects.Item(1).Object`) as the main entry point for all TwinCAT operations. Navigate the system tree via `ITcSmTreeItem`. Use `ITcPlcProject` for PLC-specific operations.
**Rationale**: This is Beckhoff's intended API for programmatic TwinCAT control. It exposes:
- System tree navigation: `LookupTreeItem()`, `CreateChild()`, `DeleteChild()`
- I/O configuration: Tree items under `TIID` (I/O devices)
- PLC operations: `ITcPlcProject` for build, login, download
- Configuration activation: `ITcSysManager::ActivateConfiguration()`

Using this instead of raw DTE gives us typed access to TwinCAT-specific operations and avoids brittle string-based workarounds.

### 3. Unified CLI entry point
**Decision**: Provide `Invoke-TwinCATAutomation.ps1` as a single-file CLI wrapper that accepts an operation name and JSON parameters, calls the corresponding module cmdlet, and returns JSON output.
**Rationale**: Some AI tools (Codex, Antigravity) may not support `Import-Module` directly. A single script entry point with `--operation` and `--params` arguments gives maximum compatibility:
```
pwsh Invoke-TwinCATAutomation.ps1 --operation NewProject --params '{"name":"MyProject","path":"C:\\Projects"}'
```

### 4. Adapter-per-tool pattern
**Decision**: Each AI tool gets a thin adapter directory:
- `adapters/claude-code/` → `.claude/skills/twincat/SKILL.md` (references module cmdlets)
- `adapters/codex/` → Task/tool definitions in Codex format
- `adapters/antigravity/` → Plugin definition in Antigravity format

**Rationale**: Adapters only contain tool-specific wiring (prompt templates, tool schemas). All logic lives in the core module. Adding a new AI tool means writing one adapter file, not reimplementing operations.

### 5. Connection management via singleton pattern
**Decision**: `Connect-TcIde` cmdlet stores the DTE/ITcSysManager references in module-scoped variables. Subsequent cmdlets check for an active connection and fail fast if not connected.
**Rationale**: COM objects are stateful — the IDE connection must persist across multiple operations in a session. Module-scoped variables are the PowerShell-native way to maintain state within an imported module.

### 6. COM ProgID strategy
**Decision**: Default to `TcXaeShell.DTE.17.0` (TwinCAT XAE Shell), with fallback to `VisualStudio.DTE.17.0` (VS2022). User can override via `-ProgId` parameter.
**Rationale**: XAE Shell is lighter and more common on automation engineer machines. VS2022 is used by software engineers. The ProgID version (17.0) targets the current generation; older versions can be specified manually.

### 7. ADS communication via TcAdsClient
**Decision**: Use `TwinCAT.Ads.dll` (.NET assembly) loaded in PowerShell for ADS communication. Connect via `TcAdsClient`, use symbol-based access (`ReadSymbol`/`WriteSymbol`) for variable read/write.
**Rationale**: The .NET ADS library ships with every TwinCAT installation (in `C:\TwinCAT\AdsApi\.NET\`), supports symbol-based access (no manual handle management), and integrates cleanly with PowerShell via `Add-Type -Path`. Alternatives:
- COM-based `TcAdsDll.dll`: Lower-level, requires manual ADS handle management
- ADS over raw TCP: Too low-level, reinventing the wheel
- Python `pyads`: Adds external dependency

### 8. Separate IDE and ADS connection management
**Decision**: IDE connection (`Connect-TcIde`) and ADS connection (`Connect-TcAds`) are independent. IDE connection is for design-time operations (edit, build). ADS connection is for runtime operations (read/write variables, state control).
**Rationale**: They serve different purposes and may target different systems (e.g., develop on local machine, test on remote PLC). Keeping them separate also allows runtime testing without an IDE open (ADS only needs TwinCAT runtime, not XAE).

### 10. Dialog-free lifecycle via ADS WriteControl and Login(3)
**Decision**: Use ADS `WriteControl` on port 10000 (AdsState=Reconfig/Reset) to switch system state instead of `ITcSysManager::StartRestartTwinCAT()`. Use `ITcSmTreeItem::Login(3)` (flag 3 = CompileBeforeLogin + SuppressAllDialogs) for PLC login and download.
**Rationale**: `StartRestartTwinCAT()` and `ITcPlcProject::Login()` trigger interactive dialog popups that block headless AI tool automation. ADS WriteControl operates at the protocol level with no UI. Login(3) was discovered via testing — the flag value 3 combines compile-before-login (1) and suppress-all-dialogs (2). Verified 2026-03-27 on UM Runtime.

### 11. Dynamic AmsNetId via GetTargetNetId()
**Decision**: Never hardcode AmsNetId. Auto-detect from `ITcSysManager::GetTargetNetId()` which returns the AmsNetId of the currently connected target.
**Rationale**: AmsNetId changes per target — local UM Runtime (`199.4.42.250.1.1`), local kernel-mode (`192.168.x.x.1.1`), remote CX controllers, etc. Hardcoding `127.0.0.1.1.1` (the loopback) fails on UM Runtime. The IDE always knows the correct AmsNetId for the active target.

### 12. Login(3) handles both login and download
**Decision**: `Enter-TcPlcOnline` calls `Login(3)` on the PLC Project tree item (not `ITcPlcProject.Login()` + `ITcPlcProject.Download()` separately).
**Rationale**: `Login(3)` on `ITcSmTreeItem` automatically detects whether the runtime has a program loaded and triggers download if needed. The `ITcPlcProject` COM interface obtained via `$treeItem.Object` returns `System.__ComObject` that doesn't always expose `Login`/`Download` methods reliably. Using the tree item's `Login(nFlags)` method is more robust and tested.

### 9. Test cycle as composable pipeline
**Decision**: `Invoke-TcTestCycle` orchestrates Build → Activate → Login → Run → Test → Stop as a single command, but each step is also available as an independent cmdlet.
**Rationale**: AI tools benefit from a single "test everything" command for the common case. But advanced users and edge cases need individual steps (e.g., skip build if already built, keep PLC running after tests).

## Risks / Trade-offs

- **COM type library registration varies by TwinCAT version** → Mitigation: Use late binding (`[System.__ComObject]`) with runtime method invocation; document tested versions (Build 4024+, 4026)
- **Module import adds startup overhead vs. direct script execution** → Mitigation: Lazy-load COM connections; module import itself is fast (~50ms)
- **Adapter maintenance burden for each AI tool** → Mitigation: Adapters are thin (single file each); core changes don't require adapter updates unless the cmdlet interface changes
- **PowerShell execution policy blocks module loading** → Mitigation: Document `Set-ExecutionPolicy RemoteSigned` requirement; provide `-ExecutionPolicy Bypass` fallback in CLI entry point
- **ITcSysManager interface may differ between TwinCAT versions** → Mitigation: Target TwinCAT 3.1 Build 4024+ which has stable API; test against 4026 as well
- **ADS .NET assembly path varies by TwinCAT installation** → Mitigation: Search common paths (`C:\TwinCAT\AdsApi\.NET\`, `C:\TwinCAT\3.1\Components\`); fail with clear error if not found
- **ADS connection requires TwinCAT runtime running** → Mitigation: `Connect-TcAds` checks runtime availability first; `Invoke-TcTestCycle` ensures activation before attempting ADS connection
- **Test assertions on timing-sensitive PLC logic** → Mitigation: Support configurable wait times and polling intervals; `Watch-TcVariable` supports condition-based waiting with timeout
- **PLC state transitions may need TwinCAT system restart** → Mitigation: Detect restart-required scenarios and report clearly; provide `-Force` flag for auto-restart when safe
