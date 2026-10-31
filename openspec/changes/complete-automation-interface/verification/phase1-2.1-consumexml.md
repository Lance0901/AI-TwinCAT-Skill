# Phase 1 task 2.1:ConsumeXml 是否接受部分 XML

- 環境:實測 2026-10-30,4026 VS2022(`VisualStudio.DTE.17.0`,XAE 3.1.4026.18),副本 `C:\Temp\Verify-4026-axis\AxisInterface_Type01_Library.sln`,離線操作(沒有 Activate,沒碰 UmRT;當時 `TcSystemServiceUm` 本來就沒在跑)。
- 方式：**自建 client**(PowerShell 5.1 單一行程,`Import-Module` 模組 + `Connect-TcIde`,用 `& (Get-Module TwinCATAutomation) { Get-TcSysManager }` 取得 `ITcSysManager`,直接呼叫 COM `ITcSmTreeItem.ConsumeXml/ProduceXml`)。沒有對應的 tcauto tool,所以沒走 MCP。
- 測試節點:`TIRT^PlcTask`(TIRT 下只有這一個 child,ItemSubType 1)。原始值 `TaskDef/CycleTime=20000`(100 ns 單位 = 2 ms)、`Priority=20`。
- 腳本與所有 XML:`C:\Users\aka09\AppData\Local\Temp\claude\C--Users-aka09-OneDrive----10-Works-Beckhoff-InternalProject-TwinCAT-AI-coding-2026-AI-TwinCAT-Skill\2ef230f0-30e3-4b2a-8ecd-5c33ec4cc6bb\scratchpad\exp\`(`run-consumexml.ps1`、`run.log`、`orig.xml`、`<case>.in.xml`、`<case>.after.xml`、`*.pretty` 是排版後用來 diff 的版本)。

## 手冊出處

TE1000 手冊 PDF(Version 1.7.0):https://download.beckhoff.com/download/document/automation/twincat3/TC3_Automation_Interface_EN.pdf
(InfoSys 起點 https://infosys.beckhoff.com/content/1033/tc3_automationinterface/242721803.html 只有 TOC 外殼，抓不到 ConsumeXml 的子頁 URL,所以引用 PDF 章節。)

- **5.2.1.1 ITcSmTreeItem::ConsumeXml**:參數 `bstrXML` 說明是 "XML document or XML snippet for Tree Item import"。錯誤碼:`E_FAIL`(XML 無法載入或找不到目標 Tree Item)、`TSM_E_ITEMNOTFOUND`、`TSM_E_INVALIDITEMTYPE`、`TSM_E_MISMATCHINGITEMS`、`E_ACCESSDENIED`、`TSM_E_ITEMDELETED`。手冊**沒有**提到未知元素或不合法的值怎麼處理。
- **5.2.1.8 ITcSmTreeItem::ProduceXml**:輸出的根節點是 `TreeItem`。
- **4.2.3 Custom TreeItem Parameters**:ProduceXml/ConsumeXml 等同 IDE 的 "Export/Import XML Description";建議的做法是先 export,改內容，再 import。
- 官方範例都**只傳要改的片段**:
  - 6.3.12 "Configuring CPU cores" → "Setting the task CPU affinity"(約 p.215):`task1.ConsumeXml("<TreeItem><TaskDef><CpuAffinity>#x0000000000000001</CpuAffinity></TaskDef></TreeItem>")`。這是 Task 節點的片段範例;手冊裡沒有改 Task cycle time 的範例，最接近的就是這一個。
  - 同節 TIRS:`<TreeItem><RTimeSetDef><MaxCPUs>..</MaxCPUs><Affinity>..</Affinity>...</RTimeSetDef></TreeItem>`。
  - 6.3.4 "From offline to online configurations":`<TreeItem><DeviceDef>{AddressInfo}</DeviceDef></TreeItem>`。
  - TIRS 那節另外寫了 "Simply writing back the XML as-is has no effect"(這是 TIRS 特有的行為)。

## 結果表(實測 2026-10-30 4026 VS2022,自建 client)

每個 case 結束後都用 `orig.xml` 整份 ConsumeXml 還原，再讀回確認和原始 byte 相同，才做下一個 case。「其他欄位」是把 `orig` 和 `after` 排版後 diff 的結果。

| Case | 送出的 XML(節錄) | ConsumeXml 例外 | 讀回目標欄位 | 其他欄位 |
|---|---|---|---|---|
| A 整份，只改 CycleTime | 整份 ProduceXml(1944 chars),`CycleTime 20000→40000` | 無(S_OK) | CycleTime=40000 | 只有連動的衍生欄位變了:`TcModuleInstance/.../Context/CycleTime 2000000→4000000`(ns)、`ParameterValues CycleTime #x1e8480→#x3d0900`。其他沒變 |
| B 片段 CycleTime | `<TreeItem><TaskDef><CycleTime>40000</CycleTime></TaskDef></TreeItem>` | 無 | CycleTime=40000 | 和 A **完全相同**(只有同樣的衍生欄位變)。Priority 等沒列出的欄位都保留 |
| B2 片段 Priority | `<TreeItem><TaskDef><Priority>21</Priority></TaskDef></TreeItem>` | 無 | Priority=21,CycleTime 不變 | 只有衍生欄位 `Context/Priority`、`ParameterValues Priority #x14→#x15` 變 |
| C1 未知元素 | `<TreeItem><TaskDef><NoSuchElement>1</NoSuchElement></TaskDef></TreeItem>` | **無(S_OK)** | 不變 | 全部不變(靜默忽略) |
| C2 錯的 Def 路徑 | `<TreeItem><NoSuchDef><CycleTime>40000</CycleTime></NoSuchDef></TreeItem>` | **無(S_OK)** | CycleTime=20000 不變 | 全部不變(靜默忽略) |
| C3 錯的根元素 | `<NotTreeItem><TaskDef>...</TaskDef></NotTreeItem>` | `COMException 0x80004005 (E_FAIL)` "No TreeItem found." | 不變 | 全部不變 |
| D 語法錯誤 | `<TreeItem><TaskDef><CycleTime>40000</TaskDef>` | `COMException 0x80004005 (E_FAIL)` 只有泛用訊息 "Error HRESULT E_FAIL has been returned from a call to a COM component." | 不變 | 全部不變(沒有部分寫入) |
| E1 CycleTime=0 | `<TreeItem><TaskDef><CycleTime>0</CycleTime></TaskDef></TreeItem>` | **無** | CycleTime=0(被接受) | 衍生欄位跟著變 0 |
| E2 CycleTime 負數 | `...<CycleTime>-10000</CycleTime>...` | **無** | CycleTime=-10000(被接受) | 衍生 `Context/CycleTime=-1000000`、`ParameterValues=#xfff0bdc0`(UDINT 溢位) |
| E3 CycleTime 文字 | `...<CycleTime>abc</CycleTime>...` | **無** | CycleTime=0(文字被轉成 0) | 衍生欄位變 0 |
| E4 CycleTime 非整 tick | `...<CycleTime>12345</CycleTime>...` | **無** | CycleTime=12345(沒有對齊 base time) | 衍生欄位跟著變 |

## 還原與檔案

- 每個 case 還原後讀回都和原始 byte 相同(True)。最後一次整份還原:讀回和原始一致,`CycleTime=20000 Priority=20`。
- 沒有存檔:`Disconnect-TcIde -Quit` 用的是 `Solution.Close($false)` + `DTE.Quit()`,結果 success、solutionClosed=true、quit=true。
- `.tsproj` 的 SHA-256 前後一致(3 個 .tsproj):
  - `AxisInterface_Type01_Library.tsproj`:`c141d3b9fab2782d328603a664a267f39fb5d57f1a3be9be371fa6dc06e55682`(前後相同)
  - `-Lance-G16.tsproj`:`6625f3c4...5c7070`(前後相同),`-LanceP-NB1.tsproj`:`15ac3105...482978`(前後相同)
- **要注意**:就算沒存檔,XAE 還是在實驗期間(10:16:24)直接把 PLC 專案的 `AxisInterface\PlcTask.TcTTO` 寫到磁碟。最後的內容是 `CycleTime 2000`(µs)、`Priority 20`,也就是原始值。實驗前沒有對這個檔做 hash,所以只能確認值相同，沒辦法證明 byte 完全相同。`LineIDs.dbg`(10:16:24)和 `A10_Scope\VSSettings\.vsm`(10:16:26,quit 時寫的)也被更新了。`.sln` 的 mtime 是 10:15:37,是第一次 attempt 開啟 solution 時被 VS 改寫，不是 ConsumeXml 造成的。
  → D2 的備份只存 ProduceXml 不夠：改 Task 會連帶即時改寫 PLC 專案的 `.TcTTO`,不管有沒有存 solution。

## 結論

**ConsumeXml 接受部分 XML:是(有條件)。**

條件與限制:
1. 根元素必須是 `<TreeItem>`,下面的路徑要對到 ProduceXml 的結構(Task 是 `TreeItem/TaskDef/<欄位>`)。只會改片段裡出現的欄位，沒列出的欄位都保留。片段和「整份只改一欄」(A vs B)的結果完全相同。這和手冊 "XML snippet" 的寫法以及 6.3.12 的 `TaskDef/CpuAffinity` 範例一致。
2. 根元素錯誤 → `E_FAIL` "No TreeItem found."。語法錯誤 → `E_FAIL`,只有泛用訊息。兩種情況都不會部分寫入。
3. **未知元素或錯的 Def 路徑會被靜默忽略，回 S_OK**:呼叫端看不出改動沒有生效。
4. **XAE 不驗證值**:0、負數、文字(轉成 0)、沒對齊 base time 的 cycle time 都會被接受並寫入。
5. 衍生欄位(`TcModuleInstance` Context、ParameterValues)會自動跟著改，比對時要排除，或者只比對目標欄位。

對 D3 的建議:**直接傳片段，不需要做「合併到整份再 ConsumeXml」**(Beckhoff 本身就是 merge 語意)。但有三件事要做：第 3 點和第 4 點要由模組自己處理，第 5 點要在比對時處理:
- 寫入前檢查片段裡每個 leaf element 的路徑都存在於目前的 ProduceXml,不存在就回錯誤(例如 `TREEITEM_VERIFY_FAILED` 或新的 code),不要送出。
- 寫入後讀回，比對片段裡的每個 leaf 值(D2 已經規劃)。比對時忽略衍生欄位。
- 已知欄位(例如 CycleTime > 0)要在模組這邊驗證。
- D2 的備份或還原要考慮 `.TcTTO` 這類被即時改寫的檔案。

## 過程備註

- 第一次執行時，腳本對 `Connect-TcIde` 的回傳值多做了一次 `ConvertFrom-Json`(實際回傳的是 PSCustomObject),腳本因此提前結束。這時 VS2022 已經啟動(pid 53528,10:15:08 建立,`devenv.exe -Embedding`,是這次啟動的)。第二次執行時 reattach 到這個 pid(selectedBy=solution-match,所以 ownedBySession=false),用記下的 pid 確認是自己啟動的，才繼續實驗，最後用 `Disconnect-TcIde -Quit` 關掉。結束後已確認沒有殘留的 devenv。
- 沒有跑 `Watch-Runtime.ps1`:UmRT 沒在跑，這次也完全沒有 runtime 或 ADS 操作。
