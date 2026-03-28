## 1. Module Scaffold

- [x] 1.1 Create PowerShell module directory structure: `src/TwinCATAutomation/TwinCATAutomation.psm1`, `src/TwinCATAutomation/Public/`, `src/TwinCATAutomation/Private/`
- [x] 1.2 Create module manifest `TwinCATAutomation.psd1` with exported cmdlets and module metadata
- [x] 1.3 Create `Invoke-TwinCATAutomation.ps1` CLI entry point that imports the module and routes operations to cmdlets

## 2. IDE Connection (core-module + ide-automation)

- [x] 2.1 Create `Private/Get-ComObject.ps1` — helper to retrieve COM objects from ROT by ProgID
- [x] 2.2 Create `Public/Connect-TcIde.ps1` — connect to TwinCAT IDE, obtain DTE + ITcSysManager, store in module scope. Support `-ProgId` parameter with XAE Shell default and VS2022 fallback
- [x] 2.3 Create `Public/Disconnect-TcIde.ps1` — release COM references and clear module-scoped state
- [x] 2.4 Create `Public/Get-TcIdeInfo.ps1` — return IDE version, ProgID, solution name, and ITcSysManager availability as JSON
- [x] 2.5 Test connection against TwinCAT XAE Shell on local machine

## 3. Project Management (project-management spec)

- [x] 3.1 Create `Public/New-TcProject.ps1` — create new solution + TwinCAT project + PLC project with MAIN via ITcSmTreeItem::CreateChild()
- [x] 3.2 Create `Public/Open-TcProject.ps1` — open .sln file via DTE and obtain ITcSysManager
- [x] 3.3 Create `Public/Get-TcProjectTree.ps1` — walk ITcSmTreeItem hierarchy and return full project tree as JSON
- [x] 3.4 Create `Public/Add-TcPou.ps1` — add POU (Program/FB/Function) via ITcSmTreeItem::CreateChild() with correct sub-type GUID
- [x] 3.5 Create `Public/Add-TcGvl.ps1` — add GVL via tree item creation
- [x] 3.6 Create `Public/Add-TcDut.ps1` — add DUT (Struct/Enum/Alias/Union) via tree item creation
- [x] 3.7 Create `Public/Add-TcLibrary.ps1` — add library reference via ITcPlcProject interface

## 4. PLC Code Writing

- [x] 4.1 Create `Public/Write-TcPouCode.ps1` — write declaration and implementation sections into an existing POU via ITcSmTreeItem
- [x] 4.2 Create `Public/Get-TcPouCode.ps1` — read declaration and implementation sections from an existing POU

## 5. I/O Configuration (io-configuration spec)

- [x] 5.1 Create `Public/Invoke-TcIoScan.ps1` — trigger EtherCAT device scan via ITcSysManager, return discovered topology
- [x] 5.2 Create `Public/Get-TcIoTree.ps1` — read TIID subtree via ITcSmTreeItem and return as JSON
- [x] 5.3 Create `Public/Set-TcVariableLink.ps1` — link PLC variable to I/O channel

## 6. Build & Deploy (build-deploy spec)

- [x] 6.1 Create `Public/Build-TcProject.ps1` — build via ITcPlcProject::BuildProject(), return errors/warnings
- [x] 6.2 Create `Public/Set-TcTarget.ps1` — set AMS Net ID target via ITcSysManager
- [x] 6.3 Create `Public/Enable-TcConfig.ps1` — activate configuration via ITcSysManager::ActivateConfiguration()
- [x] 6.4 Create `Public/Send-TcPlcProgram.ps1` — download PLC program to target via ITcPlcProject

## 7. ADS Communication (ads-communication spec)

- [x] 7.1 Create `Private/Find-TcAdsAssembly.ps1` — locate and load `TwinCAT.Ads.dll` from TwinCAT installation paths
- [x] 7.2 Create `Public/Connect-TcAds.ps1` — establish ADS connection using TcAdsClient with AMS Net ID and port, store in module scope
- [x] 7.3 Create `Public/Disconnect-TcAds.ps1` — close ADS connection and release resources
- [x] 7.4 Create `Public/Read-TcVariable.ps1` — read PLC variable(s) by symbol name via ADS, support single/multiple/struct reads
- [x] 7.5 Create `Public/Write-TcVariable.ps1` — write value to PLC variable by symbol name via ADS
- [x] 7.6 Create `Public/Watch-TcVariable.ps1` — poll variable at interval, support duration-based and condition-based monitoring
- [x] 7.7 Create `Public/Get-TcSymbols.ps1` — enumerate PLC symbols from ADS symbol table with optional filter

## 8. Runtime Control (runtime-control spec)

- [x] 8.1 Create `Public/Get-TcPlcState.ps1` — read current PLC runtime state via ADS
- [x] 8.2 Create `Public/Set-TcPlcState.ps1` — set PLC runtime state (Run/Stop/Reset) via ADS state control
- [x] 8.3 Create `Public/Enter-TcPlcOnline.ps1` — login to PLC runtime via ITcPlcProject (independent of download)
- [x] 8.4 Create `Public/Exit-TcPlcOnline.ps1` — logout from PLC runtime
- [x] 8.5 Create `Public/Get-TcSystemState.ps1` — read TwinCAT system state (Config/Run)
- [x] 8.6 Create `Public/Set-TcSystemState.ps1` — switch TwinCAT system state (Config/Run)

## 9. Automated Testing (automated-testing spec)

- [x] 9.1 Create `Public/New-TcTestCase.ps1` — define a test case with name, setup actions, wait condition, assertions, teardown
- [x] 9.2 Create `Public/Invoke-TcTest.ps1` — execute a single test case: setup → wait → assert → teardown, return pass/fail
- [x] 9.3 Create `Public/Invoke-TcTestCycle.ps1` — full cycle: Build → Activate → Login → Run → Execute Tests → Report → Stop
- [x] 9.4 Create `Private/Test-TcAssertion.ps1` — evaluate assertion operators (Equal, GreaterThan, IsTrue, etc.) against actual values

## 10. Shared Helpers

- [x] 10.1 Create `Private/New-TcResult.ps1` — helper to create standardized success/error JSON output objects
- [x] 10.2 Create `Private/Assert-TcConnection.ps1` — guard that checks for active IDE connection and throws if not connected
- [x] 10.3 Create `Private/Assert-TcAdsConnection.ps1` — guard that checks for active ADS connection
- [x] 10.4 Create `Private/Get-TcSysManager.ps1` — helper to retrieve ITcSysManager from current DTE connection

## 11. Documentation (api-reference spec)

- [x] 11.1 Create `docs/operations.md` — full operation reference with parameter schemas and return types
- [x] 11.2 Create `docs/getting-started.md` — prerequisites, installation, first connection walkthrough
- [x] 11.3 Create `docs/setup-claude-code.md` — Claude Code Skill installation and usage
- [x] 11.4 Create `docs/setup-codex.md` — Codex tool registration and usage
- [x] 11.5 Create `docs/setup-antigravity.md` — Antigravity plugin setup and usage
- [x] 11.6 Create `docs/testing-guide.md` — how to define and run automated PLC tests

## 12. Tool Adapters (tool-adapters spec)

- [x] 12.1 Create `adapters/claude-code/SKILL.md` — Claude Code Skill that references core module and docs
- [x] 12.2 Create `adapters/codex/tools.json` — Codex tool definitions mapping to Invoke-TwinCATAutomation.ps1
- [x] 12.3 Create `adapters/antigravity/plugin.yaml` — Antigravity plugin definition

## 14. Smart IDE Connection

- [x] 14.1 Update `Connect-TcIde.ps1` — add `-SolutionPath` parameter, smart DTE selection (prefer instance with TwinCAT project), auto-open solution, return `amsNetId` in response
- [x] 14.2 Update `Get-TcSysManager.ps1` — add `-Refresh` switch, verbose logging
- [x] 14.3 Update `ide-automation/spec.md` — add SolutionPath and smart selection scenarios
- [x] 14.4 Update `design.md` — add Decision #13

## 13. Integration Testing

- [ ] 13.1 End-to-end test: Connect → New Project → Add FB → Write Code → Build
- [x] 13.2 End-to-end test: Build → Activate → Login → Run → Read Variable → Stop (full test cycle)
  - **Tested 2026-03-27** against real project `Logger-Service` (FB_LoggerServer) on UM Runtime
  - Target AmsNetId: `199.4.42.250.1.1` (auto-detected via `GetTargetNetId()`)
  - Full lifecycle passed: Config(ADS) → Activate → Run(ADS) → Login(3) → Start → ADS Read
  - Variables read: `bStart=False`, `nBurstCount=6`, `nStep=0` — all correct
  - Zero dialog popups throughout entire cycle
- [x] 13.2b Full automated test cycle: Connect → Build → Activate → Login → Start → ADS → Test assertions
  - **Tested 2026-03-29** against Logger-Service on UM Runtime via VS2022
  - Fixed: Enter-TcPlcOnline uses LookupTreeItem with constructed path (Project child hidden after restart)
  - Fixed: Invoke-TcTestCycle correct order: Build→Activate→Login→ADS→Start (ADS after Login)
  - Fixed: Build-TcProject retry for RPC_E_CALL_REJECTED (5 attempts)
  - Fixed: Cache AmsNetId before Activate (COM references stale after restart)
  - Test 1 (Initial state check): **PASSED** — bStart=False, bBusy=False, nBurstCount=6
  - Test 2 (Trigger bStart): initially **FAIL** — nStep=0, root cause: wrote FB VAR_INPUT directly
  - **Re-tested 2026-03-29**: Changed to write `MAIN.bRunFlowTest` (MAIN-level var), assert `bDone=True` → **PASSED**
  - Root cause: PLC overwrites FB VAR_INPUT every scan cycle; must write MAIN-level vars that feed into FB calls (Decision #17)
- [ ] 13.3 Test CLI entry point with all operations including ADS
- [x] 13.4 Test Claude Code adapter with actual Claude Code session
  - **Tested 2026-03-27** — Claude Code successfully imported module, connected IDE, ran lifecycle
- [ ] 13.5 Verify JSON output format consistency across all cmdlets

## 15. Bug Fixes from Integration Testing

- [x] 15.1 Enter-TcPlcOnline: use `LookupTreeItem('TIPC^<name>^<name> Project')` instead of child enumeration — Project child hidden after TwinCAT restart but direct lookup still works
- [x] 15.2 Invoke-TcTestCycle: reorder steps — ADS Connect must come AFTER Login+Download (port 851 unavailable before download)
- [x] 15.3 Invoke-TcTestCycle: cache AmsNetId before Activate, don't reconnect IDE (original COM reference survives XAR restart)
- [x] 15.4 Build-TcProject: add retry loop for RPC_E_CALL_REJECTED with license check guidance
- [x] 15.5 Investigate Test 2 failure: Write-TcVariable works correctly; root cause is PLC overwriting FB VAR_INPUT each scan cycle
  - **Resolved 2026-03-29**: Must write MAIN-level variables (not FB inputs) when PLC calls FB with explicit input assignments
  - Write-TcVariable confirmed working for BOOL, UINT, and other types — ADS protocol write succeeds and persists for standalone VARs
