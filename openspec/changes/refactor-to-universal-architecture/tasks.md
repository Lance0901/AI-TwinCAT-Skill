## 1. Module Scaffold

- [ ] 1.1 Create PowerShell module directory structure: `src/TwinCATAutomation/TwinCATAutomation.psm1`, `src/TwinCATAutomation/Public/`, `src/TwinCATAutomation/Private/`
- [ ] 1.2 Create module manifest `TwinCATAutomation.psd1` with exported cmdlets and module metadata
- [ ] 1.3 Create `Invoke-TwinCATAutomation.ps1` CLI entry point that imports the module and routes operations to cmdlets

## 2. IDE Connection (core-module + ide-automation)

- [ ] 2.1 Create `Private/Get-ComObject.ps1` — helper to retrieve COM objects from ROT by ProgID
- [ ] 2.2 Create `Public/Connect-TcIde.ps1` — connect to TwinCAT IDE, obtain DTE + ITcSysManager, store in module scope. Support `-ProgId` parameter with XAE Shell default and VS2022 fallback
- [ ] 2.3 Create `Public/Disconnect-TcIde.ps1` — release COM references and clear module-scoped state
- [ ] 2.4 Create `Public/Get-TcIdeInfo.ps1` — return IDE version, ProgID, solution name, and ITcSysManager availability as JSON
- [ ] 2.5 Test connection against TwinCAT XAE Shell on local machine

## 3. Project Management (project-management spec)

- [ ] 3.1 Create `Public/New-TcProject.ps1` — create new solution + TwinCAT project + PLC project with MAIN via ITcSmTreeItem::CreateChild()
- [ ] 3.2 Create `Public/Open-TcProject.ps1` — open .sln file via DTE and obtain ITcSysManager
- [ ] 3.3 Create `Public/Get-TcProjectTree.ps1` — walk ITcSmTreeItem hierarchy and return full project tree as JSON
- [ ] 3.4 Create `Public/Add-TcPou.ps1` — add POU (Program/FB/Function) via ITcSmTreeItem::CreateChild() with correct sub-type GUID
- [ ] 3.5 Create `Public/Add-TcGvl.ps1` — add GVL via tree item creation
- [ ] 3.6 Create `Public/Add-TcDut.ps1` — add DUT (Struct/Enum/Alias/Union) via tree item creation
- [ ] 3.7 Create `Public/Add-TcLibrary.ps1` — add library reference via ITcPlcProject interface

## 4. PLC Code Writing

- [ ] 4.1 Create `Public/Write-TcPouCode.ps1` — write declaration and implementation sections into an existing POU via ITcSmTreeItem
- [ ] 4.2 Create `Public/Get-TcPouCode.ps1` — read declaration and implementation sections from an existing POU

## 5. I/O Configuration (io-configuration spec)

- [ ] 5.1 Create `Public/Invoke-TcIoScan.ps1` — trigger EtherCAT device scan via ITcSysManager, return discovered topology
- [ ] 5.2 Create `Public/Get-TcIoTree.ps1` — read TIID subtree via ITcSmTreeItem and return as JSON
- [ ] 5.3 Create `Public/Set-TcVariableLink.ps1` — link PLC variable to I/O channel

## 6. Build & Deploy (build-deploy spec)

- [ ] 6.1 Create `Public/Build-TcProject.ps1` — build via ITcPlcProject::BuildProject(), return errors/warnings
- [ ] 6.2 Create `Public/Set-TcTarget.ps1` — set AMS Net ID target via ITcSysManager
- [ ] 6.3 Create `Public/Enable-TcConfig.ps1` — activate configuration via ITcSysManager::ActivateConfiguration()
- [ ] 6.4 Create `Public/Send-TcPlcProgram.ps1` — download PLC program to target via ITcPlcProject

## 7. ADS Communication (ads-communication spec)

- [ ] 7.1 Create `Private/Find-TcAdsAssembly.ps1` — locate and load `TwinCAT.Ads.dll` from TwinCAT installation paths
- [ ] 7.2 Create `Public/Connect-TcAds.ps1` — establish ADS connection using TcAdsClient with AMS Net ID and port, store in module scope
- [ ] 7.3 Create `Public/Disconnect-TcAds.ps1` — close ADS connection and release resources
- [ ] 7.4 Create `Public/Read-TcVariable.ps1` — read PLC variable(s) by symbol name via ADS, support single/multiple/struct reads
- [ ] 7.5 Create `Public/Write-TcVariable.ps1` — write value to PLC variable by symbol name via ADS
- [ ] 7.6 Create `Public/Watch-TcVariable.ps1` — poll variable at interval, support duration-based and condition-based monitoring
- [ ] 7.7 Create `Public/Get-TcSymbols.ps1` — enumerate PLC symbols from ADS symbol table with optional filter

## 8. Runtime Control (runtime-control spec)

- [ ] 8.1 Create `Public/Get-TcPlcState.ps1` — read current PLC runtime state via ADS
- [ ] 8.2 Create `Public/Set-TcPlcState.ps1` — set PLC runtime state (Run/Stop/Reset) via ADS state control
- [ ] 8.3 Create `Public/Enter-TcPlcOnline.ps1` — login to PLC runtime via ITcPlcProject (independent of download)
- [ ] 8.4 Create `Public/Exit-TcPlcOnline.ps1` — logout from PLC runtime
- [ ] 8.5 Create `Public/Get-TcSystemState.ps1` — read TwinCAT system state (Config/Run)
- [ ] 8.6 Create `Public/Set-TcSystemState.ps1` — switch TwinCAT system state (Config/Run)

## 9. Automated Testing (automated-testing spec)

- [ ] 9.1 Create `Public/New-TcTestCase.ps1` — define a test case with name, setup actions, wait condition, assertions, teardown
- [ ] 9.2 Create `Public/Invoke-TcTest.ps1` — execute a single test case: setup → wait → assert → teardown, return pass/fail
- [ ] 9.3 Create `Public/Invoke-TcTestCycle.ps1` — full cycle: Build → Activate → Login → Run → Execute Tests → Report → Stop
- [ ] 9.4 Create `Private/Test-TcAssertion.ps1` — evaluate assertion operators (Equal, GreaterThan, IsTrue, etc.) against actual values

## 10. Shared Helpers

- [ ] 10.1 Create `Private/New-TcResult.ps1` — helper to create standardized success/error JSON output objects
- [ ] 10.2 Create `Private/Assert-TcConnection.ps1` — guard that checks for active IDE connection and throws if not connected
- [ ] 10.3 Create `Private/Assert-TcAdsConnection.ps1` — guard that checks for active ADS connection
- [ ] 10.4 Create `Private/Get-TcSysManager.ps1` — helper to retrieve ITcSysManager from current DTE connection

## 11. Documentation (api-reference spec)

- [ ] 11.1 Create `docs/operations.md` — full operation reference with parameter schemas and return types
- [ ] 11.2 Create `docs/getting-started.md` — prerequisites, installation, first connection walkthrough
- [ ] 11.3 Create `docs/setup-claude-code.md` — Claude Code Skill installation and usage
- [ ] 11.4 Create `docs/setup-codex.md` — Codex tool registration and usage
- [ ] 11.5 Create `docs/setup-antigravity.md` — Antigravity plugin setup and usage
- [ ] 11.6 Create `docs/testing-guide.md` — how to define and run automated PLC tests

## 12. Tool Adapters (tool-adapters spec)

- [ ] 12.1 Create `adapters/claude-code/SKILL.md` — Claude Code Skill that references core module and docs
- [ ] 12.2 Create `adapters/codex/tools.json` — Codex tool definitions mapping to Invoke-TwinCATAutomation.ps1
- [ ] 12.3 Create `adapters/antigravity/plugin.yaml` — Antigravity plugin definition

## 13. Integration Testing

- [ ] 13.1 End-to-end test: Connect → New Project → Add FB → Write Code → Build
- [ ] 13.2 End-to-end test: Build → Activate → Login → Run → Read Variable → Stop (full test cycle)
- [ ] 13.3 Test CLI entry point with all operations including ADS
- [ ] 13.4 Test Claude Code adapter with actual Claude Code session
- [ ] 13.5 Verify JSON output format consistency across all cmdlets
