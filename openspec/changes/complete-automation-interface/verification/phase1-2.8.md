# Phase 1 task 2.8:7 個通用 tree tool 實測

- 環境：**registered tcauto 實測 2026-10-30 4026 VS2022 XAE 3.1.4026.22**(`VisualStudio.DTE.17.0`;版本取自 ExportChild 產生的 .xti `TcVersion`),副本 `C:\Temp\Verify-4026-axis\AxisInterface_Type01_Library.sln`,離線(沒有 Activate、沒有 ADS;`TcSystemServiceUm` 本來就沒在跑)。
- 方式：全部經 registered `mcp__tcauto__*` 呼叫，沒有用 Import-Module 自建 client。7 個 tool(`LookupTreeItem`、`ProduceXml`、`CreateChild`、`ConsumeXml`、`DeleteChild`、`ExportChild`、`ImportChild`)測試前都已在 MCP tool 清單裡。
- IDE:`ConnectIde SolutionPath=<副本> ProgId=VisualStudio.DTE.17.0` → `selectedBy=launched`、`ownedBySession=true`、pid 82320、connectSec 40.1(launchSec 2.3)。測試前沒有任何 devenv / XAE 在跑。結束 `DisconnectIde Quit=true` → solutionClosed / quit 都 true,之後沒有殘留 devenv。
- 基準(測試前):`TIRT` 只有 `PlcTask`(ItemSubType 1),`TaskDef/CycleTime=20000`、`Priority=20`;`TIPC^AxisInterface^AxisInterface Project` 12 個 child。磁碟 hash 見「收尾」。
- 除非另外註明，以下每項都是「registered tcauto 實測 2026-10-30 4026 VS2022 XAE 3.1.4026.22」。

## 1. ConsumeXml 改 `TIRT^PlcTask` 的 CycleTime

| 步驟 | 送出 | 回傳重點 |
|---|---|---|
| dry-run | `<TreeItem><TaskDef><CycleTime>40000</CycleTime></TaskDef></TreeItem>` | success,`dryRun=true`,`changes=[{path:TreeItem/TaskDef/CycleTime, current:20000, planned:40000, changed:true, derived:false}]`,`changedCount=1`,附 `currentXml`(1944 chars)。沒寫入 |
| 實寫 | 同上,`DryRun=false` | success,`written=true`,**`verified=true`**,`warnings=[]`,`backupPath=...\.tcauto-backup\20261030-133551\TIRT_PlcTask.xml`(1944 B),**`backupFiles=[...\TIRT_PlcTask.PlcTask.TcTTO]`**(702 B,hash 與測試前磁碟上的 `PlcTask.TcTTO` 相同) |
| 讀回 | `ProduceXml TIRT^PlcTask` | `TaskDef/CycleTime=40000`;衍生欄位 XAE 自己跟著改:`Context/CycleTime 2000000→4000000`、`ParameterValues CycleTime #x1e8480→#x3d0900`。實寫回傳沒有 `unexpectedChanges` → **全量比對沒有把衍生欄位誤報成差異** |
| 已是目標值 | 再 dry-run 一次 40000 | success,`changedCount=0`,`warnings=["every value in the fragment already equals the current value; nothing would change"]` |
| 改回 | `CycleTime=20000`,`DryRun=false` | success,`verified=true`,另一份備份 `20261030-133643\`(同樣含 .TcTTO)。讀回整份 XML 與基準相同(衍生欄位也回到 2000000 / #x1e8480) |

觀察(實測):這次 ConsumeXml 把 tree 改成 40000 時，磁碟上的 `AxisInterface\PlcTask.TcTTO` **沒有被改寫**(mtime 一直是 2.1 留下的 10:16:24,內容 `CycleTime 2000`,hash 不變)。2.1 時這個檔在實驗期間被寫過;那次有「整份 XML ConsumeXml」與多次還原，哪一步觸發的沒有分出來。結論：.TcTTO 何時被 XAE 改寫不固定，備份照現在的做法帶上 .TcTTO 是對的。

## 2. 錯誤的 XML(都沒有寫入)

每個 case 後，下一次 dry-run 的 `current` 仍是 40000(當時的值),而且 `.tcauto-backup` 只多出真正實寫的那兩個資料夾 → 被擋的呼叫沒有寫入、也沒有產生備份。

| Case | 送出(節錄) | DryRun | 錯誤碼 | data 重點 |
|---|---|---|---|---|
| 未知元素 | `<TreeItem><TaskDef><NoSuchElement>1</NoSuchElement></TaskDef></TreeItem>` | false | `XML_MERGE_FAILED` | `reason=paths-not-in-current-xml`,`missingPaths=[TreeItem/TaskDef/NoSuchElement]` |
| 錯的 Def 路徑 | `<TreeItem><NoSuchDef><CycleTime>30000</CycleTime></NoSuchDef></TreeItem>` | true | `XML_MERGE_FAILED` | `reason=paths-not-in-current-xml`,`missingPaths=[TreeItem/NoSuchDef/CycleTime]` |
| 錯的根元素 | `<NotTreeItem>...` | false | `XML_MERGE_FAILED` | `reason=root` |
| XML 語法錯 | `<TreeItem><TaskDef><CycleTime>30000</CycleTime></TaskDef>`(少 `</TreeItem>`) | false | `XML_MERGE_FAILED` | `reason=syntax`,message 帶 .NET LoadXml 的錯誤(行 1 位置 58) |
| 空字串 | `` | true | `XML_MERGE_FAILED` | `reason=empty` |
| 有 attribute | `<TreeItem Foo="1">...` | true | `XML_MERGE_FAILED` | `reason=attributes-not-supported`,`attributePaths=[TreeItem/@Foo]` |
| 值放在有子元素的節點 | `<TreeItem><TaskDef/></TreeItem>` | true | `XML_MERGE_FAILED` | `reason=structure-mismatch`,`structurePaths=[TreeItem/TaskDef]` |
| 只改衍生欄位 | `...<Contexts><Context><CycleTime>3000000</CycleTime>...` | true | `XML_MERGE_FAILED` | `reason=derived-only`,`derivedPaths=[TreeItem/TcModuleInstance/Module/Contexts/Context/CycleTime]` |
| CycleTime=0 | `<CycleTime>0</CycleTime>` | false | `TREEITEM_INVALID_VALUE` | `invalidFields=[{value:"0", reason:"0 is not > 0"}]` |
| CycleTime 負數 | `<CycleTime>-10000</CycleTime>` | false | `TREEITEM_INVALID_VALUE` | `reason:"-10000 is not > 0"` |
| CycleTime 文字 | `<CycleTime>abc</CycleTime>` | false | `TREEITEM_INVALID_VALUE` | `reason:"'abc' is not an integer"` |
| 路徑不存在 | `Path=TIRT^NoTask` | true | `TREEITEM_NOT_FOUND` | `nearestPath=TIRT`,`nearestChildren=[PlcTask]` |

`repeated-count-mismatch` 沒測(`TIRT^PlcTask` 沒有重複的兄弟元素)。

## 3. CreateChild 在 `TIRT` 底下建 Task(SubType=1)

| 步驟 | 回傳重點 |
|---|---|
| dry-run `Name=Task28 SubType=1` | success,`plannedPath=TIRT^Task28`,`currentChildren=[PlcTask]` |
| 實寫 | **`success=false`,`TREEITEM_VERIFY_FAILED`**,但 `createdPath=TIRT^Task28`、`itemType=1`、`itemSubType=1`,節點**確實建出來了**。`parentUnchanged=false`,`unexpectedChanges=[{path:TreeItem/ChildCount, kind:"removed", before:"1", after:"2"}]`。備份 `20261030-133702\TIRT.parent.xml`。→ 見「發現的問題」#1 |
| 讀回 `ProduceXml TIRT^Task28` | XAE 給的預設值：`Priority=1`、`AmsPort=351`、`CycleTime=100000`(10 ms) |
| 同名再建 | `TREEITEM_ALREADY_EXISTS`,`currentChildren=[PlcTask, Task28]`,沒有建立 |
| 名稱只差大小寫 `task28`(dry-run) | success(dry-run 沒擋)。實際 XAE 會不會接受沒有實寫測 |
| 父節點不存在 `TIRT^NoParent` | `TREEITEM_NOT_FOUND`,`nearestPath=TIRT` |
| `Before=NoSuch` | `TREEITEM_NOT_FOUND`,hint 列出可用的 child |

父節點 additions-only 比對：有在跑，但會把 `ChildCount` 數值增加當成「原本的值不見了」(`kind=removed`),所以每次建立都回 VERIFY_FAILED。

## 4. DeleteChild

| 步驟 | 回傳重點 |
|---|---|
| `ConfirmName=Task28`(Path 是 `TIRT^Task28b`) | `TREEITEM_DELETE_NAME_MISMATCH`,`nodeName=Task28b`,沒刪 |
| `ConfirmName=task28b`(只差大小寫) | `TREEITEM_DELETE_NAME_MISMATCH`(大小寫要相同),沒刪 |
| `Path=TIRT`(頂層) | `TREEITEM_PATH_INVALID` "is a top-level node" |
| dry-run 正確名稱 | success,`nodeName`、`itemType=1`、`childCount=0`、`itemParentPath=TIRT` |
| 實刪 `TIRT^Task28b` / `Task28c` / `Task28_1` / `Task28` | 都 success,**`verified=true`**,`backupPath=<ts>\TIRT_<name>.xml`,**`exportPath=<ts>\TIRT_<name>.xti`**(例:`TIRT_Task28.xti` 內容 `<Task Id="6" Priority="1" CycleTime="100000" AmsPort="351">`、`<Name>Task28</Name>`)。`warnings=["Task node ...: no <name>.TcTTO found ...; that disk file is NOT in the backup"]` → 見「發現的問題」#3 |
| SilentMode 下的確認 dialog | 每次實刪 0.8~1.0 s 就返回，之後 `GetIdeModalDialog` → `dialog=null`。沒有跳確認 dialog |
| 刪除後 `.TcTTO` 孤兒 | 沒有。`TIRT` 底下的獨立 Task(沒有 PLC)本來就沒有 .TcTTO;`C:\Temp\Verify-4026-axis` 底下 .TcTTO 只有原本的 `PlcTask.TcTTO`(加上兩份備份) |
| TIPC 底下的節點 | 預設(AllowNoExport=false)**失敗**:`TREEITEM_BACKUP_FAILED` `reason=export-failed`,XAE 回 "The filename '...xti' doesn't specify a zip archive!",沒刪。→ 見「發現的問題」#2。`AllowNoExport=true` → success,`verified=true`,warning 寫明只有 ProduceXml 備份 |

`parent-mismatch` 沒測到：用完整路徑 LookupTreeItem 拿到的節點，它的 parent 就是路徑推出的那個，找不到安全的方式造出不一致的情況。

## 5. ExportChild → ImportChild 改名匯入

| 步驟 | 回傳重點 |
|---|---|
| `ExportChild TIRT^Task28 → scratchpad\x28\Task28.xti` | success,`exported=true`,`fileSize=378` |
| 同一檔名再匯出 | `TREEITEM_EXPORT_FAILED` `reason=file-exists` |
| 資料夾不存在 | `TREEITEM_EXPORT_FAILED` `reason=folder-missing` |
| 相對路徑 `Task28.xti` | `TREEITEM_EXPORT_FAILED` `reason=not-absolute` |
| Path 不存在 | `TREEITEM_NOT_FOUND` |
| `ImportChild` dry-run `Name=Task28b` | success,`reconnect=true`,`fileSize=378`,`currentChildren` |
| 檔案不存在 | `TREEITEM_IMPORT_FAILED` `reason=file-missing` |
| 實匯入 `Name=Task28b` | **`TREEITEM_VERIFY_FAILED`**(同 #1:`ChildCount 2→3`),但 `importedPath=TIRT^Task28b` 確實匯入了 |
| 同名再匯入 | `TREEITEM_ALREADY_EXISTS`,沒匯入 |
| 實匯入 `Name=Task28c Reconnect=false` | 同樣 VERIFY_FAILED(`ChildCount 3→4`),`reconnect=false` 有傳下去,節點建出來了 |
| 實匯入 `Name` 空白 | dry-run 沒預警;實際 XAE 用檔名 `Task28`,撞名後自己改成 **`Task28_1`**(`importedName=Task28_1`,`warnings=[]`)。→ 見「發現的問題」#4 |

**.xti 內容**:ExportChild 的檔案 `<Name>__FILENAME__</Name>`(檔名剛好是節點名);DeleteChild 備份的 `TIRT_Task28.xti` 則是 `<Name>Task28</Name>`。兩者都帶 `Priority="1" CycleTime="100000" AmsPort="351"`。

**兩邊 XML 比對**(`Task28` vs `Task28b` vs `Task28c`):`TaskDef/CycleTime=100000`、其他 TaskDef 欄位都相同;**不同的是** ItemName / PathName / Context Name / InstanceName(改名)、`ItemId 6/7/8`、`ObjectId / OTCID #x02010060/70/80`、**`Priority 1/2/3`、`AmsPort 351/352/353`**。也就是 XAE 匯入時會重新分配 Priority 與 AmsPort,不保留 .xti 裡的值(實測)。

**bReconnect**:`Reconnect=true` 與 `false` 匯入的結果欄位相同。Task 沒有變數 mapping,所以這裡看不出差異;回傳 `data.reconnect` 正確反映傳入值。有 mapping 的節點(I/O)要等之後有離線 I/O 再測。

TIPC 底下：`ExportChild` 給 `.xti` → `TREEITEM_EXPORT_FAILED`(XAE "doesn't specify a zip archive!");給 **`.zip`** → success(`fileSize=122`)。`ImportChild` 這個 .zip 回 `TIPC^...^Tmp28Folder` → 同 #1 的 VERIFY_FAILED,但節點有匯入，帶 `buildRequired`。

## 6. 其他

**LookupTreeItem 錯誤路徑的 hint**

| Path | 錯誤碼 | hint / data |
|---|---|---|
| `TIRT^NoSuchTask` | `TREEITEM_NOT_FOUND` | "nearest existing parent is 'TIRT', 'NoSuchTask' is not one of its children: 'PlcTask'. Use LookupTreeItem (LookupTreeItem) -Path 'TIRT' to browse.";`nearestPath=TIRT`,`nearestChildren=[PlcTask]` |
| `tirt^plctask` | `TREEITEM_NOT_FOUND` | "the first segment 'tirt' does not exist. Top-level nodes that resolve: 'TIPC', 'TIID', 'TIRC', 'TIRS', 'TIRT', 'TINC'";`nearestPath=null` |
| `TIRT^plctask` | `TREEITEM_NOT_FOUND` | nearest `TIRT`,children `PlcTask` |
| `TIRT^*` | `TREEITEM_PATH_INVALID` | 不接受 wildcard |

→ **PathName 區分大小寫**(XAE `LookupTreeItem` 對頂層與子節點都是，實測)。hint 會列出正確大小寫的名稱，agent 照抄即可。

**Recursive**:`ProduceXml` 對 `TIRT`、`TIRT^PlcTask`、`TIPC^...^Basic Function`(PLC folder,3 個 child)給 `Recursive=true/false`,輸出**完全相同**(長度 214 / 1944 / 401)。這三種節點看不出 bRecursive 有什麼作用;其他類型(I/O、NC)未測。

**TIPC 的 buildRequired**:`CreateChild TIPC^AxisInterface^AxisInterface Project Name=Tmp28Folder SubType=601`(ItemSubTypeName `TREEITEMTYPE_PLCFOLDER`,實測 ProduceXml)、ImportChild、DeleteChild 都回 `buildRequired="PLC code changed by <cmdlet> <path>"`,VERIFY_FAILED 時也有。TIRT 底下的操作不回 buildRequired。`.plcproj` 磁碟檔在建立 / 刪除 folder 之後 hash 不變(沒存檔)。

**PLC_LOGGED_IN**:沒測。UmRT(`TcSystemServiceUm`)沒在跑，不能 Login;任務規定不修 UmRT。

**耗時**(取自回傳的 startedAt / finishedAt,含 MCP / bridge 開銷)

| tool | dry-run / 唯讀 | 實寫 | 模組先擋(沒碰 XAE 修改 API) |
|---|---|---|---|
| ConnectIde(冷啟動 VS2022) | — | 40.1 s(launchSec 2.3) | — |
| LookupTreeItem | 0.10~0.34 s | — | 0.02 s(wildcard) |
| ProduceXml | 0.04~0.26 s | — | — |
| ConsumeXml | 0.47 s | 0.63~0.93 s | 0.01~0.15 s |
| CreateChild | 0.05~0.10 s | TIRT 0.42 s;TIPC 2.73 s | — |
| ExportChild | — | TIRT 0.46 s;TIPC(.zip)0.58 s | 0.01 s |
| ImportChild | 0.05~0.13 s | TIRT 0.36~0.50 s;TIPC 2.28 s | 0.01 s |
| DeleteChild | 0.12 s | TIRT 0.83~1.02 s;TIPC 1.0~1.2 s | 0.03~0.05 s |
| DisconnectIde Quit | — | 2.0 s | — |

## 7. 收尾：副本恢復

- `LookupTreeItem TIRT` → 只有 `PlcTask`(childCount 1);`ProduceXml TIRT^PlcTask` 與基準整份相同(1944 chars,CycleTime 20000、Priority 20、衍生欄位 2000000 / #x1e8480)。
- `LookupTreeItem TIPC^AxisInterface^AxisInterface Project` → 12 個 child,`Tmp28Folder` 已不在。
- `GetIdeModalDialog` → `dialog=null`;`DisconnectIde Quit=true` 沒存檔。
- 磁碟 hash(SHA-256)測試前後相同:`PlcTask.TcTTO 0B063EBD...945457`、`AxisInterface.plcproj C7EB837B...1B70C3`、`AxisInterface_Type01_Library.tsproj C141D3B9...E55682`、`-Lance-G16.tsproj 6625F3C4...5C7070`、`-LanceP-NB1.tsproj 15AC3105...482978`。
- `.sln` mtime 13:35:15 是 ConnectIde 開啟 solution 時 VS 改寫的(2.1 也有同樣情況),不是 tree tool 造成的。
- 留下的檔案：副本的 `.tcauto-backup\20261030-1335xx ~ 134026\`(15 個資料夾，測試證據，未刪);匯出檔在 scratchpad `x28\`(`Task28.xti`、`Tmp28Folder.zip`)。

## 發現的問題(沒有修 code,交主 session 決定)

### #1 CreateChild / ImportChild 每次成功都回 TREEITEM_VERIFY_FAILED(高)

- **重現**:`CreateChild Path=TIRT Name=Task28 SubType=1 DryRun=false`(或任何 `ImportChild DryRun=false`)。
- **實際回傳**:`success=false`,`code=TREEITEM_VERIFY_FAILED`,`createdPath=TIRT^Task28`(節點已建立),`parentUnchanged=false`,`unexpectedChanges=[{"path":"TreeItem/ChildCount","kind":"removed","before":"1","after":"2"}]`。TIRT、TIPC 都一樣，共 6 次全中。
- **原因(讀 code)**:`Test-TcTreeItemParentUnchanged`(`src/TwinCATAutomation/Private/TreeItem/TreeItemXml.ps1:477`)用 `Compare-TcTreeItemXmlFull -AdditionsOnly` 比父節點，父節點的 `ChildCount` 新增子節點後一定 +1,被當成「原本的值不見了」(kind 也因此標成 `removed`)。
- **影響**:agent 照 hint 會以為失敗而重試(第二次得到 ALREADY_EXISTS)或去還原;單元測試 mock 沒抓到。
- **建議**:比對時排除 `TreeItem/ChildCount`(或允許它恰好 +1),並補一個 mock 會讓 ChildCount 變的單元測試。
- **狀態**:已修(commit 655385b),registered 重測通過(見「重測(registered tcauto 2026-10-30 4026 VS2022)」)。父節點比對允許 `TreeItem/ChildCount` 剛好 +1(`$script:TcTreeItemParentIncrements`),+2 等其他變化仍回 VERIFY_FAILED;before / after 都有值時 kind 改成 `changed`(原本 additions-only 一律標 `removed`)。

### #2 TIPC 底下的 DeleteChild 預設一定失敗(高)

- **重現**:`DeleteChild Path="TIPC^AxisInterface^AxisInterface Project^Tmp28Folder" ConfirmName=Tmp28Folder DryRun=false`。
- **實際回傳**:`TREEITEM_BACKUP_FAILED`,`reason=export-failed`,message "Cannot export child. The filename '...\TIPC_AxisInterface_AxisInterface Project_Tmp28Folder.xti' doesn't specify a zip archive! (ITcSmTreeItem:ExportChild)"。沒刪(防護本身正確)。
- **驗證**:同一節點 `ExportChild` 給 `.zip` 檔名 → success(122 B),`ImportChild` 這個 .zip 也能匯回。
- **影響**:PLC 物件只能靠 `AllowNoExport=true` 刪，而那樣就沒有可 ImportChild 還原的備份。
- **建議**:DeleteChild 的備份在 TIPC 底下(PLC 專案內的節點)改用 `.zip` 副檔名;ExportChild 的 description / hint 註明 PLC 節點要 `.zip`。出處待查 TE1000(手冊 5.2.1.4 沒寫);目前只有 XAE 錯誤訊息與實測。**範圍**:實測 2026-10-30 僅 PLC folder(`Tmp28Folder`,SubType 601);其他 TIPC 節點未測。
- **狀態**:已修(commit 655385b),registered 重測通過(見「重測(registered tcauto 2026-10-30 4026 VS2022)」)。DeleteChild 備份在 `TIPC^` 底下用 `.zip`;ExportChild 收到 TIPC 路徑 + 非 .zip 先回 `TREEITEM_EXPORT_FAILED` reason `plc-requires-zip`(hint 給 .zip 檔名);help / MCP description / hint 註明 PLC 節點用 .zip。

### #3 DeleteChild 對沒有 PLC 的 Task 誤報缺 .TcTTO(低)

- **重現**:刪 `TIRT^Task28`(CreateChild 建的獨立 Task)。
- **實際回傳**:success、verified=true,但 `warnings=["Task node 'TIRT^Task28': no Task28.TcTTO found below C:\\Temp\\Verify-4026-axis; that disk file is NOT in the backup ..."]`。
- **說明**:`.TcTTO` 只存在於 PLC 專案的 Task 物件;TIRT 的獨立 Task 本來就沒有，這個 warning 是雜訊。建議改成只有找得到 PLC 對應 Task 時才要求 .TcTTO,或降為 info。
- **狀態**:已修(commit 655385b),registered 重測通過(見「重測(registered tcauto 2026-10-30 4026 VS2022)」)。Task 規則找不到 `.TcTTO` 時不發 warning(找到多個仍然 warning;.TcPOU / .TcDUT / .TcGVL 找不到仍然 warning)。

### #4 ImportChild 的 Name 空白時沒預測撞名，XAE 自動改名也沒 warning(中)

- **重現**:`ImportChild Path=TIRT FilePath=<Task28.xti> DryRun=false`(Name 留空,`TIRT^Task28` 已存在)。
- **實際回傳**:dry-run success(沒提到撞名);實寫 `importedPath=TIRT^Task28_1`,`warnings=[]`(另外有 #1 的 VERIFY_FAILED)。
- **建議**:Name 空白時從 .xti 的 `<Name>`(或 `__FILENAME__` → 檔名)推出名稱做 ALREADY_EXISTS 檢查;或在 `importedName` 和預期不同時加 warning(CreateChild 的 description 已經提到 XAE 可能改名要給 `data.warnings`,ImportChild 沒做)。
- **狀態**:已修(commit 655385b),registered 重測通過(見「重測(registered tcauto 2026-10-30 4026 VS2022)」)。Name 空白時從 .xti 第一個子元素的 `<Name>` 推出 `data.expectedName`(`__FILENAME__` → 檔名去副檔名;.zip 跳過),dry-run 與實寫都做 ALREADY_EXISTS 檢查;匯入後名稱和預期不同加進 `data.warnings`。

### #5 hint 文字重複(低)

- `TREEITEM_NOT_FOUND` 的 hint 寫成 "Use LookupTreeItem (LookupTreeItem) -Path ..."、`TREEITEM_PATH_INVALID` 寫 "LookupTreeItem(LookupTreeItem)":MCP 名稱與 cmdlet 名稱替換後變成重複。應該是 "LookupTreeItem (Get-TcTreeItem)"。
- **狀態**:已修(commit 655385b),registered 重測通過(見「重測(registered tcauto 2026-10-30 4026 VS2022)」)。原因是 MCP server(`mcp-server/lib/tools.js` `rewriteHintCmdletNames`)把 hint 裡的 cmdlet 名稱換成 tool 名稱;hint 改成只寫 cmdlet(`Get-TcTreeItem`、`Get-TcProjectTree`),cmdlet 模式顯示 cmdlet、MCP 模式顯示 `LookupTreeItem`。同樣問題的 `PlcLogout(Exit-TcPlcOnline)`(PLC_LOGGED_IN 兩個 hint)一起改成 `Exit-TcPlcOnline`;單元測試掃全部 hint 不能有「名稱(cmdlet)」。

### review 修正(reviewer 審 `75c2bcb..1c3e9b9` 後)

都是單元測試與 `scripts/check.ps1` 完整版驗證(mock,沒有碰真機),registered 重測通過(見「重測(registered tcauto 2026-10-30 4026 VS2022)」)。

| 項目 | 修正 | commit |
|---|---|---|
| XXE | `Get-TcXtiItemName` 改用 `XmlReader`(`DtdProcessing = Prohibit`、`XmlResolver = $null`,try/finally Dispose);帶 DOCTYPE 的檔案回 `$null`;`get_DocumentElement()`、`<Name>` 用 `-ceq` | 0464094 |
| #3 範圍太大 | Task 找不到 `.TcTTO` 時掃 solution 目錄下 `.plcproj` / `.tsproj` 是否提到 `<task>.TcTTO`(大小寫不分):有參照 → warning;沒有參照 → 不發;掃描失敗 → warning。PLC Task 在 `.plcproj` 列成 `<Compile Include="PlcTask.TcTTO">`(2026-10-30 讀 4026 副本) | 0464094 |
| #2 範圍太大 | `plc-requires-zip` 只擋 PLC folder(ItemType 601),其他 TIPC 節點交給 XAE;DeleteChild 備份維持 TIPC 一律 `.zip`(export 失敗就不刪)。出處改成「實測 2026-10-30 僅 PLC folder;其他 TIPC 節點未測」(help、MCP description、hint、troubleshooting、本檔 #2) | 0464094、8950c48 |
| JS hint 測試 | `mcp-server/test/tools.test.js` 用真的 `tools.json` 測 `rewriteHintCmdletNames`:`Get-TcTreeItem -Path 'TIRT'`、`Get-TcProjectTree`、`Exit-TcPlcOnline`、路徑含空白與 `^` 的 `Export-TcTreeItem` | 0464094 |
| hint 單引號 | `plc-requires-zip` hint 裡 `$Path` / `$FilePath` 的 `'` 跳脫成 `''` | 0464094 |
| ImportChild .zip | Name 空白、推不出 `expectedName` 時 `data.warnings` 註明沒有做撞名檢查 | 0464094 |
| ChildCount 淨值 +1 | CreateChild / ImportChild 成功後比對子節點名稱：原有的都在、剛好多一個(`data.childrenAfter`),否則 `TREEITEM_VERIFY_FAILED`(`data.missingChildren` / `addedChildren`);清單被 `TcTreeItemMaxChildNames` 截斷時跳過並留 warning | 0464094 |

### 其他觀察(不算 bug)

- CreateChild 的同名檢查與 XAE 一樣區分大小寫(`task28` dry-run 通過);XAE 實際接不接受只差大小寫的名稱沒有實寫測。
- ImportChild 會讓 XAE 重新分配 Priority / AmsPort,不保留 .xti 的值;改名匯入後若要相同 Priority,要再用 ConsumeXml 改。
- `Recursive` 在 Task / PLC folder 上沒有作用;tool description 現在寫「not measured」,可以改成這次的實測結果。→ 已改(commit 655385b)。

## 重測(registered tcauto 2026-10-30 4026 VS2022)

- 環境：同上(`VisualStudio.DTE.17.0`,XAE 3.1.4026.22,副本 `C:\Temp\Verify-4026-axis`,離線，沒有 UmRT)。全部經 registered `mcp__tcauto__*`;重測前 ToolSearch 看得到 7 個 tree tool,`ExportChild` description 已是「PLC folder (ItemType 601) ... measured on a PLC folder only」的新版。
- IDE:測試前沒有 devenv / XAE 在跑。`ConnectIde SolutionPath=<副本> ProgId=VisualStudio.DTE.17.0` → `selectedBy=launched`、`ownedBySession=true`、pid 52464、connectSec 44.2(launchSec 2.3)。結束 `DisconnectIde Quit=true` → solutionClosed / quit 都 true,之後沒有殘留 devenv。
- 基準：`TIRT` 只有 `PlcTask`;`TIPC^AxisInterface^AxisInterface Project` 12 個 child;`ProduceXml TIRT^PlcTask` 1944 chars(CycleTime 20000)。磁碟 hash 與上一輪「收尾」相同。

| # | 測試 | 結果 | 回傳重點 |
|---|---|---|---|
| 1 | `CreateChild TIRT Name=Task28 SubType=1 DryRun=false` | **通過** | success,`verified=true`,`parentUnchanged=true`,`childrenAfter=[PlcTask, Task28]`,`warnings=[]`,沒有 VERIFY_FAILED |
| 1 | `ExportChild TIRT^Task28` → `Task28.xti`(378 B),`ImportChild TIRT Name=Task28b DryRun=false` | **通過** | success,`verified=true`,`parentUnchanged=true`,`childrenAfter=[PlcTask, Task28, Task28b]`,`importedName=Task28b` |
| 1 | `CreateChild TIPC^...^AxisInterface Project Name=Tmp28Folder SubType=601 DryRun=false` | **通過** | success,`verified=true`,`itemType=601`,`childrenAfter` 13 個(Tmp28Folder 排在 CorrugatedPrint 後),`buildRequired` |
| 2 | `ExportChild` PLC folder `Tmp28Folder` → `.xti` | **通過** | `TREEITEM_EXPORT_FAILED` `reason=plc-requires-zip`,`itemType=601`,hint "rerun ExportChild Path='…^Tmp28Folder' FilePath='…\Tmp28Folder.zip'",沒呼叫 XAE(0.04 s) |
| 2 | `DeleteChild …^Tmp28Folder ConfirmName=Tmp28Folder DryRun=false`(AllowNoExport 預設 false) | **通過** | success,`verified=true`,`exportPath=…\20261030-151000\TIPC_AxisInterface_AxisInterface Project_Tmp28Folder.zip`(檔案存在),`warnings=[]`,`buildRequired` |
| 2 | `ImportChild …^AxisInterface Project FilePath=<上面的 .zip>`(不給 Name)`DryRun=false` | **通過** | success,`verified=true`,`importedName=Tmp28Folder`,`expectedName=null`,`warnings=["a .zip file does not tell the name of the item, so no name clash check was done; pass -Name to have it checked"]` → 還原成功 |
| 2 | `ExportChild` POU `TestCam`(ItemType 602,FunctionBlock)→ `.xti` | 觀察 | 模組不先擋(只擋 601),XAE 拒絕:`TREEITEM_EXPORT_FAILED` "The filename '…\TestCam.xti' doesn't specify a zip archive! (ITcSmTreeItem:ExportChild)"。沒有檔案產生 |
| 2 | `ExportChild` POU `TestCam` → `.zip` | 觀察 | success,`exported=true`,`fileSize=14854`。→ **POU 也要 `.zip`、不能 `.xti`**(實測 2026-10-30 4026 VS2022;只測 ExportChild,沒有用 ImportChild 匯回 POU,避免改動 TestCam) |
| 3 | `DeleteChild TIRT^Hard28` / `Task28b` / `Task28`(獨立 Task,DryRun=false) | **通過** | 三次都 success,`verified=true`,`exportPath=…\TIRT_<name>.xti`,`backupFiles=[]`,**`warnings=[]`**(沒有 .TcTTO warning) |
| 3 | `ConsumeXml TIRT^PlcTask` CycleTime 20000→40000 dry-run | **通過** | success,`changes=[{CycleTime, current:20000, planned:40000}]`。dry-run 回傳**本來就沒有備份計畫欄位**(code 只在實寫時建備份,`Set-TcTreeItemXml`),所以另外用實寫驗 |
| 3 | 同上實寫 40000,再實寫改回 20000 | **通過** | 兩次都 `verified=true`,`backupFiles=[…\TIRT_PlcTask.PlcTask.TcTTO]`,`warnings=[]` |
| 4 | `ImportChild TIRT FilePath=Task28.xti`(不給 Name,`TIRT^Task28` 已存在,dry-run) | **通過** | `TREEITEM_ALREADY_EXISTS`,`expectedName=Task28`(.xti 是 `<Name>__FILENAME__</Name>` → 檔名),沒有匯入 |
| 4 | 寫死 `<Name>`:複製 Task28.xti 為 `FileNameX.xti`,把 `<Name>__FILENAME__</Name>` 改成 `<Name>Hard28</Name>`,不給 Name 實匯入 | **通過** | dry-run 階段算出 `expectedName=Hard28`;實寫 `importedName=Hard28`、`importedPath=TIRT^Hard28`、`verified=true`、`warnings=[]`。→ **XAE 用 .xti 寫死的 `<Name>` 當匯入名稱，不是檔名 `FileNameX`**(實測) |
| 4 | 同一個 `FileNameX.xti` 再 dry-run(`Hard28` 已存在) | **通過** | `TREEITEM_ALREADY_EXISTS`,`expectedName=Hard28` |
| 5 | `LookupTreeItem TIRT^NoSuchTask` | **通過** | hint 結尾 "Use LookupTreeItem Path='TIRT' to browse.",沒有 "(LookupTreeItem)" 重複 |
| 5 | `LookupTreeItem tirt^plctask` / `TIRT^*` | **通過** | hint "Use LookupTreeItem on one of them, or GetProjectTree.";`TREEITEM_PATH_INVALID` hint "先用 LookupTreeItem 或 GetProjectTree 查到確切路徑",都沒有「名稱(cmdlet)」重複 |

**收尾**

- 多建的節點都刪掉了:`Hard28`、`Task28b`、`Task28`(#3 那三次)、`Tmp28Folder`(匯回後再 `DeleteChild`,success / verified / `.zip` 備份)。
- `LookupTreeItem TIRT` → 只有 `PlcTask`;`TIPC^…^AxisInterface Project` → 12 個 child,和基準相同;`ProduceXml TIRT^PlcTask` 與基準整份相同(1944 chars,CycleTime 20000、衍生欄位 2000000 / #x1e8480)。
- `GetIdeModalDialog` → `dialog=null`;`DisconnectIde Quit=true` 沒存檔。
- 磁碟 hash(SHA-256 前 16 碼)測試前後相同:`PlcTask.TcTTO 0B063EBD466F6B68`、`AxisInterface.plcproj C7EB837B54367C76`、`AxisInterface_Type01_Library.tsproj C141D3B9FAB2782D`、`-Lance-G16.tsproj 6625F3C42FF3CB4C`、`-LanceP-NB1.tsproj 15AC3105A92C901E`,mtime 也沒變。
- 留下的檔案：副本 `.tcauto-backup\20261030-150831 ~ 151014\`(13 個資料夾，測試證據，未刪);scratchpad `rt28\`(`Task28.xti`、`FileNameX.xti`、`TestCam.zip`)。

**結論**:#1–#5 的修正在 registered tcauto 上全部通過，沒有發現新 bug。新的實測事實兩條:POU 的 ExportChild 也要 `.zip`;ImportChild 不給 Name 時 XAE 用 .xti 的 `<Name>`(`__FILENAME__` 時才用檔名)。

**後續(不是 bug)**:ExportChild 的 `plc-requires-zip` 目前只擋 ItemType 601;POU(602)給 `.xti` 會走到 XAE 才失敗，而且 XAE 拒絕時 `data.reason` 是空的。要不要把先擋擴大到 POU(或全部 TIPC 節點)、description 的「other TIPC nodes not measured」要不要改，交主 session 決定。
