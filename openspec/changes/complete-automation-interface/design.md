## Context

- 現況：37 個 cmdlet;MCP 提供 36 個 cmdlet tool 加 4 個 composite。真機實測過的 tool 有 20 個(見 `docs/known-limitations.md`)。
- 所有 cmdlet 共用同一套基礎:`Connect-TcIde` 保存的 `$script:TcDte` / `$script:TcSysManager`、`Invoke-TcComRetry`、`New-TcResult`(JSON 加 hint)。MCP bridge 是一個常駐的 PS 5.1 STA。
- Automation Interface 大部分功能走同一個模式：用 `ITcSysManager.LookupTreeItem(path)` 拿到 `ITcSmTreeItem`,接著 `CreateChild(name, subType, before, vInfo)` / `ProduceXml()` / `ConsumeXml(xml)`。專用介面只出現在少數地方，例如 `ITcPlcLibraryManager`、`ITcPlcIECProject`、`ITcPlcOnline`。
  - 出處:TE1000 手冊 v1.7.0 第 5.1、5.2 章(https://download.beckhoff.com/download/document/automation/twincat3/TC3_Automation_Interface_EN.pdf),InfoSys 4.2.1(https://infosys.beckhoff.com/content/1033/tc3_automationinterface/242721803.html)。
- 測試環境：本機 UmRT `199.5.42.250.1.1`,4026 VS2022、4024 XAE 32-bit,副本放在 `C:\Temp\Verify-*`。沒有第二台 target(做 ADS route 要用到)。

## Goals / Non-Goals

**Goals:**
- 第 0–3 期涵蓋的 Automation Interface 功能，每一項都有 cmdlet 和 MCP tool,而且都用 registered tcauto 實測過。
- 修改類操作有防護，不會把使用者的組態悄悄改壞。
- 延續 v0.1.0-beta 的原則：不盲等、不誤報成功，修改後一律讀回驗證。

**Non-Goals:**
- 第 4 期：EtherCAT 實機組態、其他 fieldbus、Safety、C++、Scope、靜態分析、License。
- 不重寫既有 tool。只有第 0 期查證後確認錯誤的部分才改。
- 不支援 Legacy mode 專屬的 API(例如 `ITcSysManager.SaveConfiguration`,實測 2026-10-28 在非 Legacy mode 會丟例外)。

## Decisions

### D1. 先做通用 tree 操作，專用 tool 第二
- 第 1 期先做 7 個通用 tool。第 2、3 期的專用 tool 內部盡量重用這組函式(`Private/TreeItem/*.ps1`),只對常用而且參數複雜的功能(例如 Task、NC axis、Library)另外包成易用的 tool。
- 好處：通用 tool 一上線,agent 就能透過 XML 碰到大部分 Automation Interface 功能。專用 tool 主要是降低出錯率。
- 不採用的做法:「每個區塊各寫專用 tool」。工作量大概是兩倍，而且遇到沒包到的功能就完全沒辦法用。

### D2. 修改類 tool 的防護(ConsumeXml / DeleteChild / ImportChild / CreateChild)
- 預設 `DryRun=true`。dry-run 回傳目前 XML、預定的改動和 diff 摘要，不呼叫修改 API。
- 真的寫入前，把 `ProduceXml()` 的結果存成備份檔(`<solution dir>\.tcauto-backup\<timestamp>\<path>.xml`),回傳備份路徑。
- `Path` 必須是完整的 tree path,不接受 wildcard。DeleteChild 還要另外帶 `ConfirmName`,而且要和節點名稱一致。
- 寫入後重新 `ProduceXml()`,比對預期的欄位，不一致回 `TREEITEM_VERIFY_FAILED`。
- MCP 端標 `destructiveHint: true`。
- 不採用的做法：只靠 MCP client 的確認對話框。CLI 和 Codex 用的時候沒有這個保護。

### D3. ConsumeXml 只接受「片段」,不接受整份 XML
- 參數是 `ProduceXml` 結果的子集，也就是要修改的節點。實作時先把片段合併到目前的 XML,再整份 ConsumeXml。
- 原因：讓 agent 整份 XML 照抄回寫，容易把沒看懂的欄位改掉。
- 這點要先在 UmRT 實測確認 ConsumeXml 是否接受部分 XML。如果 Beckhoff 本身就接受部分 XML,就直接傳片段，不做合併。
- **實測結果(2.1,自建 client,實測 2026-10-30 4026 VS2022 XAE 3.1.4026.18,`TIRT^PlcTask`,離線)**:Beckhoff 本身就是合併語意，所以直接傳片段，不做合併。
  - 根元素必須是 `<TreeItem>`,路徑照 ProduceXml 的結構，例如 `TreeItem/TaskDef/CycleTime`。TE1000 v1.7.0 §5.2.1.1 寫 "XML document or XML snippet",§6.3.12 有 `<TreeItem><TaskDef><CpuAffinity>` 片段範例。
  - 片段沒列到的欄位保留原值。只送片段，和送整份但只改一欄，讀回結果完全相同。
  - **未知元素或錯的路徑會被靜默忽略**:回 S_OK,但什麼都沒改。根元素錯，或 XML 語法錯，回 0x80004005 E_FAIL,不會部分寫入。
  - **XAE 不驗證值**:CycleTime 給 0、負數、文字，都照收寫入。文字會被轉成 0。
  - 改 Task 會即時寫回 `.TcTTO`,這時還沒存檔。
- **對實作的影響**:
  - 送出前先檢查路徑：片段裡每個最底層元素的路徑，都要在目前的 ProduceXml 找得到。找不到就回 `XML_MERGE_FAILED`,不送出。
  - 讀回比對時排除衍生欄位(`TcModuleInstance` 的 Context、ParameterValues)。
  - 已知欄位(例如 CycleTime 必須大於 0)由模組自己驗證值。
  - D2 的備份除了 ProduceXml,還要包含節點對應的磁碟檔(例如 `.TcTTO`)。

### D4. 第 0 期先查證再修
- `ProduceScan` / `LinkTo`:先查 TE1000 手冊和 InfoSys,再在 UmRT 實測。只有確定錯了才改。
- 原因是使用者的規則：不能用推論修或開 issue。

### D5. 測試框架的等待改成輪詢
- `New-TcTestCase` 新增 `WaitUntil`(Path / Operator / Expected,加上 `TimeoutMs`),內部重用 `Watch-TcVariable` 的輪詢。
- `WaitMs` 保留做相容，但 help 裡標為不建議使用。
- 不採用的做法：直接刪掉 `WaitMs`。這是 BREAKING,目前沒有必要。

### D6. 每期一個 PR 系列，一期一個 beta
- 第 0 期 → v0.2.0-beta,第 1 期 → v0.3.0-beta,以此類推。
- 每期結束更新 `known-limitations.md` 的實測清單，並跑兩個 host 的 smoke test。

### D7. 錯誤碼
- 新錯誤碼一律寫進 `ConvertTo-TcAdsErrorCode` 的 hint 表和 `docs/troubleshooting.md`(`check.ps1 errorcodes` 會檢查兩邊一致)。
- 預計新增:`TREEITEM_NOT_FOUND`、`TREEITEM_CREATE_FAILED`、`TREEITEM_VERIFY_FAILED`、`TREEITEM_DELETE_NAME_MISMATCH`、`XML_MERGE_FAILED`、`BOOTPROJECT_FAILED`、`PLCOPEN_FAILED`、`ROUTE_ADD_FAILED`。

## Risks / Trade-offs

- [ConsumeXml 寫壞組態，而且 XAE 不報錯] → D2 的讀回比對，加上備份檔。實測時刻意送錯誤的 XML,觀察 XAE 的反應。
- [`CreateChild` 的 subType 數字沒有完整公開清單] → 只支援 TE1000 手冊或 InfoSys 有寫的 subType。查不到的不放進專用 tool,只能透過通用 CreateChild 由使用者自己指定。
- [NC 模擬軸、TcCOM 在 UmRT 的行為和 RT 不同] → 結論標「實測 + 日期 + 環境」。UmRT 跑不起來的就列進 known-limitations,不靠推論修。
- [ADS route 沒有第二台 target] → 只做單元測試和本機 loopback,known-limitations 標未實測，等第 4 期有硬體再驗。
- [tool 數量從 40 增加到約 70,agent 選錯 tool] → 通用 tool 的 description 寫明「優先使用專用 tool」。另外考慮在 SKILL.md 依區塊分組。
- [工作量大，又陷入一直開新 issue、收斂不了] → 範圍以本文件和 tasks.md 為準。實作中發現的新問題開 issue,但不進本期，除非它擋住本期的任務。

## Open Questions

- ConsumeXml 是否接受部分 XML?(影響 D3,第 1 期第一個任務就實測。)
- `GenerateBootProject` 在 UmRT 產生的檔案位置，和 `BOOT_PACKAGE_MISMATCH` 的比對邏輯是否相容?
- Variant management 需要哪個 TwinCAT 版本?4024 有沒有?(查 InfoSys。)
- 需不需要 `RunLifecycle` 這種 composite 來包 NC 軸的完整流程(建軸 → link → Activate → 讀軸狀態)?等第 3 期再決定。
