## Why

TcAuto 目前做到 PLC 開發的主流程，對應 TwinCAT Automation Interface(TE1000)的範圍大約是：IDE 連線、Build、POU/DUT/GVL、Activate、Login。除此之外，還有二十幾個功能區塊沒有做，例如 Task、Boot project、Library Manager、PLCopen、NC axis、TcCOM、ADS route。現有的 I/O 掃描和變數 link 呼叫的 API 名稱(`ProduceScan`、`LinkTo`)在 TE1000 手冊裡查不到，而且這兩個 tool 都還沒實測。目標是把 Automation Interface 的功能完整包成 cmdlet 和 MCP tool。v0.1.0-beta 已經把主流程穩定下來，現在可以在這個基礎上往外擴。

## What Changes

本版分四期，每期結束發一個 beta。第 4 期(需要實機或授權)不在本版。

- **第 0 期：修現有功能**
  - 查證 `Invoke-TcIoScan` 的 `ProduceScan()`、`Set-TcVariableLink` 的 `LinkTo()`。對照 TE1000 手冊的 `ScanDevices`、`ITcSysManager::LinkVariables`,不對就改。
  - `Add-TcLibrary` 改用 `ITcPlcLibraryManager.AddLibrary`(#80)。
  - 測試框架 `New-TcTestCase -WaitMs` 是固定等待，改成輪詢加 timeout。
  - 目前 20 個未實測的 MCP tool 全部用 registered tcauto 實測，有問題就修。
- **第 1 期：通用 tree 操作**
  - 新增 `ITcSysManager` / `ITcSmTreeItem` 的通用 tool:LookupTreeItem、CreateChild、DeleteChild、ProduceXml、ConsumeXml、ExportChild、ImportChild。
  - `ConsumeXml`、`DeleteChild`、`ImportChild` 會修改組態，預設 dry-run,改之前先備份原本的 XML,而且 tree path 要逐一明確指定(不可用 wildcard)。
- **第 2 期：PLC 補齊**
  - Library Manager 整組：placeholder、install/uninstall、remove reference、freeze。
  - Boot project 產生。
  - PLCopen import/export、SaveAsLibrary、archive 存取。
  - Task 建立，以及 task 和 program 的連結。
  - POU 子物件：Interface、Method、Property、Action。
  - `CheckAllObjects`。
- **第 3 期：系統組態(本機 UmRT 可測的部分)**
  - NC 模擬軸的建立和 link。
  - TcCOM module 實例與 online 參數。
  - Variant management。
  - Independent project file。
  - ADS route 的建立與 broadcast search(要第二台 target,沒有就只做單元測試，並標示未實測)。
- **不在本版(第 4 期)**:EtherCAT 實機組態和其他 fieldbus、Safety、C++ module、Scope / Measurement、靜態分析、License。使用者有硬體，排在下一版。

## Capabilities

### New Capabilities
- `existing-tool-verification`:現有 tool 的 API 查證與實測要求。每個 MCP tool 都要有實測紀錄，否則要列在 known-limitations。
- `tree-item-primitives`:通用 tree 操作 tool,以及修改類操作的防護(dry-run、備份、明確路徑、讀回驗證)。
- `plc-project-management`:Library Manager、Boot project、PLCopen、archive、Task、POU 子物件、CheckAllObjects。
- `system-configuration`:NC 模擬軸、TcCOM、Variant management、Independent project file、ADS route。

### Modified Capabilities
(`openspec/specs/` 目前沒有已發布的 spec,沒有要修改的。)

## Impact

- **程式碼**:
  - `src/TwinCATAutomation/Public/` 新增約 25–35 個 cmdlet。
  - 修改 `Invoke-TcIoScan`、`Set-TcVariableLink`、`Add-TcLibrary`、`New-TcTestCase`、`Invoke-TcTest`。
- **MCP**:
  - `mcp-server/tools.json` 由 `Export-ToolSchema.ps1` 重新產生，tool 數量會從 40 個增加到約 70 個。
  - 修改類 tool 要標 `destructiveHint`。
- **文件**:
  - 更新 `docs/known-limitations.md` 的實測清單、`docs/troubleshooting.md` 的新錯誤碼、`adapters/*`。
  - 更新 `CLAUDE.md`、`AGENTS.md`、`README.md` 的 cmdlet 數量(`scripts/check.ps1` 會檢查一致性)。
- **驗證**:
  - 每個新 tool 都要用 registered tcauto,在本機 UmRT 和 4026 VS2022 上實測。
  - 4024 XAE 至少測每期的代表性 tool。
  - TwinCAT 行為要附 InfoSys 或 TE1000 手冊出處。
- **相容性**:不改既有 tool 的參數和回傳格式。第 0 期如果發現既有 tool 的行為是錯的，修正時要在 PR 裡標 **BREAKING**。
