# 已知限制(beta)

這份清單列出目前版本已知、還沒修好的問題,以及真機驗證的範圍。每條都寫:現象、影響、繞過方式、issue。錯誤碼的細節在 [troubleshooting.md](troubleshooting.md)。

遇到這裡沒列的問題,請到 [GitHub issues](https://github.com/Lance0901/AI-TwinCAT-Skill/issues) 開 issue,附上 **tool 名稱、傳入的參數、完整回傳 JSON**(含 `error.code`、`error.hint`、`data`),以及 XAE 版本 / IDE(ProgId)/ target。回報機制之後會做成 MCP tool(#78)。

## 讀取 / 監看

### 多路徑讀取時,讀不到的路徑回 null 但整體 success(#60)

- **現象**:`ReadVariable` / `QuickRead` / `WatchVariable` 一次給多個 `Path`,其中某些路徑讀不到時,該路徑的值是 `null`,整個呼叫仍回 `success: true`。
- **影響**:呼叫端如果只看 `success`,會把讀取失敗當成值為 null(或 FALSE / 0)的正常結果。
- **繞過**:拿到 `null` 一律視為**讀取失敗**,不要當成 PLC 的值;需要確定時改成一次只讀一個路徑(單一路徑讀不到會回錯誤碼,例如 `ADS_SYMBOL_NOT_FOUND`)。
- **Issue**:[#60](https://github.com/Lance0901/AI-TwinCAT-Skill/issues/60)

### UmRT 長時間執行後 task 停止循環,但 ADS 仍回 Run(#26)

- **現象**:本機 Usermode Runtime 跑約 30 分鐘後,PLC task 不再循環,但 `GetPlcState` / `GetSystemState` 仍回 Run(實測紀錄見 #26 與 troubleshooting「已知限制」的 UmRT fake Run)。
- **影響**:長時間測試讀到的值不再更新,狀態卻看起來正常。
- **繞過**:長測試要定期讀 `TwinCAT_SystemInfoVarList._TaskInfo[n].CycleCount`,確認它有在增加;沒有增加就視為 runtime 異常,重新 `EnableConfig Force=true`(必要時照 [agent-brief-realmachine.md](agent-brief-realmachine.md)「UmRT 復原」重啟 `TcSystemServiceUm`)。
- **Issue**:[#26](https://github.com/Lance0901/AI-TwinCAT-Skill/issues/26)

## 專案 / 程式碼

### NewProject:MCP 暫時下架(#70)

- **現象**:`New-TcProject` 給 `AddFromTemplate` 的 template 路徑是空字串,建專案的流程沒有對照 InfoSys 驗證;而且 `Solution.Create` 會關掉 IDE 目前開著的 solution(未存的改動會丟掉,#70 記錄的風險)。
- **影響**:MCP server **暫時不提供 `NewProject` tool**(`tools.json` 不再列出);cmdlet `New-TcProject` 保留,但 IDE 已開著 solution 時直接回 `SOLUTION_ALREADY_OPEN`,不呼叫 `Solution.Create`。
- **繞過**:在 XAE 手動建立新專案,再 `ConnectIde SolutionPath=<新 .sln>` 接上。
- **Issue**:[#70](https://github.com/Lance0901/AI-TwinCAT-Skill/issues/70)

### ResetSolution 會丟掉 XAE editor 中未存的程式碼(設計如此)

- **現象**:`ResetSolution` 會關閉並重新開啟 solution;XAE editor 裡還沒存檔的程式碼不會被保存(`Reset-TcSolution` 從不自動存 editor 內容,#76)。
- **影響**:在 XAE 手動改了程式但沒存,就呼叫 `ResetSolution`,那些改動會消失。
- **繞過**:
  - 在 **XAE 裡手動改**程式:改完先 **Save All**,再呼叫 `ResetSolution`。
  - 用**外部編輯器改磁碟檔**(`.TcPOU` / `.TcGVL` / `.plcproj`):**不要**在 XAE 按 Save All(會用 XAE 記憶體裡的舊版本蓋掉你的檔案),直接 `ResetSolution` 讓 XAE 重新讀檔。做法見 troubleshooting「磁碟改檔的正確做法」。
- **Issue**:#76(設計說明)

## IDE 連線

### ConnectIde 沒給 ProgId 可能用錯版本的 XAE 開 solution(#72)

- **現象**:電腦上裝了多個 XAE / Visual Studio 時,`ConnectIde` 不給 `ProgId`,可能接到或啟動另一個版本的 IDE 來開 solution。
- **影響**:solution 被別的 XAE 版本開啟,可能觸發升級提示、Build 結果不同,或接到使用者自己開著的 IDE。
- **繞過**:**一律明確給 `ProgId`**(例如 4024 32-bit XAE Shell `TcXaeShell.DTE.15.0`、4026 64-bit XAE Shell `TcXaeShell.DTE.17.0`、VS2022 `VisualStudio.DTE.17.0`),並給 `SolutionPath`。
- **Issue**:[#72](https://github.com/Lance0901/AI-TwinCAT-Skill/issues/72)

### bridge 重啟後 `ownedBySession` 可能誤報 false(#73)

- **現象**:`IDE_MODAL_DIALOG` 或逾時讓 MCP bridge 重啟後,本 session 啟動的 IDE 的 `data.ownedBySession` 可能變成 false。
- **影響**:`DisconnectIde Quit=true Kill=true` 會回 `IDE_NOT_OWNED`,不會殺掉自己啟動的 IDE。
- **繞過**:自己記下 `ConnectIde` 回傳的 `ideProcessId`;收尾時用這個 pid 確認要關的是自己啟動的 IDE,再 `DisconnectIde Quit=true`。不要關別人的 IDE。
- **Issue**:[#73](https://github.com/Lance0901/AI-TwinCAT-Skill/issues/73)

### 冷啟動第一次 modal dialog 掃描可能逾時回 null(#42)

- **現象**:IDE 冷啟動後第一次掃描 modal dialog(`GetIdeModalDialog`,以及其他 tool 內部的 dialog 檢查)可能逾時,結果是 `null`。
- **影響**:`null` 不代表「確定沒有 dialog」。
- **繞過**:冷啟動後第一次拿到 `null` 時再呼叫一次 `GetIdeModalDialog`;仍有疑慮就看 XAE 視窗。
- **Issue**:[#42](https://github.com/Lance0901/AI-TwinCAT-Skill/issues/42)

## Activate / Runtime

### UmRT 在 Activate(set-config)階段偶發 crash(#21)

- **現象**:`EnableConfig` 進行到 Activate 的 set-config 階段時,本機 UmRT 的 `TcSystemServiceUm` 偶發 crash(實測 2026-10-28 18:19,`TcSystemServiceUm` 3.1.0.2649,faulting module `TcOsSys.dll`,exception code 0xc0000005)。
- **影響**:模組等不到目標狀態,回 `SYSTEM_STATE_TIMEOUT`,**不會假成功**;但這次 Activate 沒有完成,PLC 不在 Run。
- **繞過**:照 [agent-brief-realmachine.md](agent-brief-realmachine.md)「UmRT 復原」重啟 `TcSystemServiceUm`,再重跑 `EnableConfig Force=true`。
- **Issue**:[#21](https://github.com/Lance0901/AI-TwinCAT-Skill/issues/21)

### UmRT 第二種 crash 簽名:ntdll.dll stack overflow(#21)

- **現象**:`EnableConfig` 的 set-config 階段,`TcSystemServiceUm` 3.1.0.2649 崩潰,faulting module `ntdll.dll`,exception code 0xc00000fd(stack overflow),offset 0x1cfa8(實測 2026-10-29 11:57,4026 VS2022,本機 UmRT)。前兆是 `TCNC.bootdata` 先變成 0 bytes。和上一條 `TcOsSys.dll` 0xc0000005 是不同簽名。
- **影響**:同上,target 消失,等不到目標狀態(模組現在偵測到 runtime 消失會提早回 `RUNTIME_CRASHED`,但這條路徑只有單元測試,見下方「未實測」)。
- **繞過**:同上,照「UmRT 復原」重啟 `TcSystemServiceUm` 後重跑 `EnableConfig Force=true`。
- **Issue**:追蹤在 [#21](https://github.com/Lance0901/AI-TwinCAT-Skill/issues/21),補充說明見 [issuecomment-6487701546](https://github.com/Lance0901/AI-TwinCAT-Skill/issues/21#issuecomment-6487701546)

### PLC login 中不能新增物件(`PLC_LOGGED_IN`)

- **現象**:PLC 處於 login 狀態時,`AddPou` / `AddGvl` / `AddDut` 會被 XAE 拒絕(「Cannot add an object because it affects a device you are currently logged into」),模組回 `PLC_LOGGED_IN`,不會建立任何物件,也不記 BUILD_REQUIRED(實測 2026-10-29,4026 VS2022,registered tcauto)。`AddLibrary` 在 login 中可以成功(實測 2026-10-29)。
- **影響**:`EnableConfig Force` 和 `RunTestCycle` 結束時 PLC 都停在 login,接著直接 `AddPou` 等會失敗。
- **繞過**:先 `PlcLogout`,再新增物件;新增完 `BuildProject` 再 `EnableConfig`。

### Interface property 的 Get / Set 不支援(`POU_MEMBER_UNSUPPORTED`)

- **現象**:`AddPouMember` 不在 interface property 底下建 Get / Set(ItemType 654 / 655);`GetPouCode` / `WritePouCode` 遇到這種物件只讀 ItemType 就回 `POU_MEMBER_UNSUPPORTED`。
- **原因**:建立後讀它的 `DeclarationText` 讓 VS2022 crash 兩次(實測 2026-10-31 4026 VS2022 自建 client,`devenv.exe` KERNELBASE.dll exception 0xe06d7363;細節 [verification/phase2-probe.md](../openspec/changes/complete-automation-interface/verification/phase2-probe.md))。64-bit XAE Shell、4024 是否一樣還不知道。
- **繞過**:interface property 不加 accessor;在實作該 interface 的 FB 裡建 Get / Set(`AddPouMember ParentPath=<FB path>^<property> Kind=Get`)並讀寫它。

### `WritePouCode` 不能清空 declaration

- **現象**:`Declaration ""` 回 `POU_WRITE_FAILED`(reason `empty-not-supported`),什麼都不寫。`Implementation ""` 會清空實作並讀回確認(實測 2026-10-31 4026 VS2022 自建 client 的 COM 行為;模組路徑只有單元測試)。
- **繞過**:declaration 一律給完整內容。

### `GetLibraries` 的 `frozen` 判斷未實測(待 3.8)

- **現象**:`frozen` 只看磁碟上 .plcproj 的 `<PlaceholderResolution><Resolution>` 版本是不是 `*`。實測過的只有「`AddPlaceholder` 用 `*` 加入 → `FreezePlaceholder` 後變成實際版本」(自建 client 2026-10-31 4026 VS2022)。用固定版本加入的 placeholder XAE 寫成什麼、會不會因此被讀成 `frozen = true`,沒有實測;只在 XAE 記憶體、還沒存的改動也看不到。
- **繞過**:要確定時先 `FreezePlaceholder`(會存檔再讀回),或在 XAE 的 Library Manager 看該 placeholder。待 task 3.8 registered 實測。

## 真機驗證範圍(實測 2026-10-28 ~ 2026-10-30)

MCP 共 **63 個 tool**:`mcp-server/tools.json` 59 個(2026-10-29 用 node 讀的 37 個,加第 1 期 2026-10-30 新增的 7 個通用 tree tool,加第 2 期 task 3.6 新增的 `AddInterface`、`AddPouMember`,加 task 3.1 新增的 6 個 Library Manager tool:`GetLibraries`、`AddPlaceholder`、`RemoveReference`、`InstallLibrary`、`UninstallLibrary`、`FreezePlaceholder`,加 task 3.7 的 `CheckAllObjects`,加 task 3.5 的 `AddPlcTask`、`LinkProgramToTask`、`UnlinkProgramFromTask`,加 task 3.3 的 `ExportPlcOpen`、`ImportPlcOpen`,加 task 3.2 的 `GenerateBootProject`)加 `mcp-server/lib/composites.js` 匯出的 4 個複合 tool(`RunLifecycle`、`QuickRead`、`GetStatus`、`GetIdeModalDialog`),兩份名稱沒有重複。`RunTestCycle` 在 `tools.json`(不是 composite)。`NewProject` 不在 MCP 上(見上方 #70)。

測試方式分兩種,下表分開標示:

- **registered tcauto**:用已註冊的 `mcp__tcauto__*` MCP 呼叫,對**本機 UmRT** 實際跑。
- **自建 client**:subagent 自己寫的 MCP client,只當輔助證據,不算 registered 驗證。

環境:**4026 VS2022**(`VisualStudio.DTE.17.0`)、**4026 XAE**(64-bit XAE Shell)、**4024 XAE**(32-bit XAE Shell `TcXaeShell.DTE.15.0`)。步驟見 [agent-brief-realmachine.md](agent-brief-realmachine.md),逐項紀錄見 [verification/phase0.md](../openspec/changes/complete-automation-interface/verification/phase0.md)。

### 已實測(registered tcauto,39 個)

| tool | 日期 | 環境 | 備註 |
|---|---|---|---|
| `ConnectIde` | 2026-10-28、10-29 | 4024 XAE、4026 XAE、4026 VS2022 | |
| `SetTarget` | 2026-10-28、10-29 | 4024 XAE(NoPlatformSwitch)、4026 VS2022 | |
| `BuildProject` | 2026-10-28、10-29 | 4024 XAE、4026 XAE、4026 VS2022 | |
| `EnableConfig` | 2026-10-28、10-29 | 4024 XAE、4026 VS2022 | 9~10 步全 success;set-config 偶發 UmRT crash,見上方 #21 |
| `ConnectAds` | 2026-10-28、10-29 | 4026 VS2022 | |
| `ReadVariable` | 2026-10-28 | 4026 VS2022 | |
| `WriteVariable` | 2026-10-28 | 4026 VS2022 | |
| `GetPouCode` | 2026-10-28 | 4026 VS2022 | |
| `WritePouCode` | 2026-10-28、10-29 | 4026 VS2022 | |
| `AddPou` | 2026-10-28、10-29 | 4026 VS2022 | login 中回 `PLC_LOGGED_IN`(10-29) |
| `AddDut` | 2026-10-28、10-29 | 4026 VS2022 | login 中回 `PLC_LOGGED_IN`(10-29) |
| `AddGvl` | 2026-10-28、10-29 | 4026 VS2022 | login 中回 `PLC_LOGGED_IN`;logout 後成功 |
| `AddLibrary` | 2026-10-28、10-29 | 4026 VS2022(registered);4024 XAE(10-29 registered,10-28 自建 client) | 成功 / 不存在(`LIBRARY_ADD_FAILED`)/ 重複(`alreadyPresent`)三條路徑 |
| `ResetSolution` | 2026-10-28 | 4026 VS2022 | |
| `DisconnectIde` | 2026-10-28、10-29 | 4024 XAE、4026 VS2022 | |
| `GetBuildErrors` | 2026-10-28 | 4026 VS2022 | |
| `PlcLogin` | 2026-10-28 | 4026 VS2022 | |
| `PlcLogout` | 2026-10-28、10-29 | 4026 VS2022 | logoutVia treeItem.Logoff |
| `GetProjectTree` | 2026-10-28 | 4026 VS2022 | |
| `GetSymbols` | 2026-10-28 | 4026 VS2022 | |
| `GetIdeInfo` | 2026-10-28 | 4026 VS2022 | |
| `OpenProject` | 2026-10-28 | 4026 VS2022 | 重開同一個 sln,約 6.8 s |
| `CleanProject` | 2026-10-28 | 4026 VS2022 | cleanVerified=true |
| `GetIoTree` | 2026-10-28 | 4026 VS2022 | 該專案 TIID 底下沒有子節點 |
| `GetSystemState` | 2026-10-28 | 4026 VS2022 | |
| `GetPlcState` | 2026-10-28 | 4026 VS2022 | |
| `SetPlcState` | 2026-10-28 | 4026 VS2022 | Stop -> Run |
| `SetSystemState` | 2026-10-28 | 4026 VS2022 | Config、Run->Run 重啟 |
| `DisconnectAds` | 2026-10-28 | 4026 VS2022 | 之後 `ReadVariable` 回 NOT_CONNECTED |
| `WatchVariable` | 2026-10-28 | 4026 VS2022 | 取樣與 Until |
| `SendPlcProgram` | 2026-10-28 | 4026 VS2022 | 程式碼沒改時不下載(downloaded=false),下載後 PLC 停在 Stop |
| `IoScan` | 2026-10-28、10-29 | 4026 VS2022、4024 XAE | Run 模式回 `IO_SCAN_REQUIRES_CONFIG`;Config 模式沒有裝置時 devices=[] 帶 warning |
| `NewTestCase` | 2026-10-29 | 4026 VS2022、4024 XAE | WaitUntil 與只用 WaitMs(回傳帶 warning)都測過 |
| `RunTest` | 2026-10-29 | 4026 VS2022、4024 XAE | Pass / Fail / WaitUntil 逾時;WaitMs-only 結果帶 warning |
| `RunTestCycle` | 2026-10-29 | 4026 VS2022 | 結束後 PLC 在 Stop |
| `RunLifecycle`(複合) | 2026-10-29 | 4026 VS2022 | 帶 Platform,5 步全 success,`data.warning` 為 null |
| `QuickRead`(複合) | 2026-10-28 | 4026 VS2022 | |
| `GetStatus`(複合) | 2026-10-28 | 4026 VS2022 | |
| `GetIdeModalDialog`(複合) | 2026-10-28 | 4026 VS2022 | dialog=null |

### 部分實測(失敗路徑 registered,成功路徑只有自建 client)

| tool | 狀態 |
|---|---|
| `SetVariableLink` | registered tcauto 2026-10-28(4026 VS2022)只測了 PLC 路徑錯 -> `TREEITEM_NOT_FOUND`。**成功路徑只有自建 client 測過**(離線 EK1100 + EL1004),registered 還沒測,要等第 1 期 `CreateChild` 才能建離線 I/O |
| `RemoveVariableLink` | 新 tool。registered tcauto 2026-10-29(4026 VS2022)只測了 `TREEITEM_NOT_FOUND`(`missingEnd` PlcVariable)。**成功路徑只有自建 client 測過**,同上等 `CreateChild` |

### 第 1 期通用 tree tool(task 2.8,7 個)

registered tcauto 實測 2026-10-30 4026 VS2022 XAE 3.1.4026.22,離線(副本 `C:\Temp\Verify-4026-axis`)。逐項紀錄見 [verification/phase1-2.8.md](../openspec/changes/complete-automation-interface/verification/phase1-2.8.md)。

| tool | cmdlet | 狀態 |
|---|---|---|
| `LookupTreeItem` | `Get-TcTreeItem` | 已實測。PathName 區分大小寫;找不到時 hint 列出最近的父節點和它的 children |
| `ProduceXml` | `Get-TcTreeItemXml` | 已實測。`Recursive` 在 Task / PLC folder 上輸出相同(參數說明已改成這個實測結果) |
| `ConsumeXml` | `Set-TcTreeItemXml` | 已實測。改 `TIRT^PlcTask` CycleTime:`verified=true`、備份含 `.TcTTO`、衍生欄位不誤報;錯誤 XML 全部 `XML_MERGE_FAILED` / `TREEITEM_INVALID_VALUE`,沒寫入 |
| `ExportChild` | `Export-TcTreeItem` | 已實測。TIPC 底下的 PLC folder 要用 `.zip` 檔名,`.xti` 會被 XAE 拒絕(實測 2026-10-30 4026 VS2022 僅 PLC folder;其他 TIPC 節點未測);模組只對 PLC folder(601)先擋(`plc-requires-zip`,hint 給 `.zip` 檔名;重測通過)。POU(`TestCam`,602)給 `.xti` 也被 XAE 拒絕、給 `.zip` 成功(重測 2026-10-30 實測) |
| `CreateChild` | `New-TcTreeItem` | 已實測(重測 2026-10-30):TIRT Task(SubType 1)與 TIPC PLC folder(601)都 `verified=true`、`parentUnchanged=true`、有 `childrenAfter`(#1 修正通過) |
| `ImportChild` | `Import-TcTreeItem` | 已實測(重測 2026-10-30):改名匯入 `verified=true`;Name 空白且撞名時 dry-run 回 `TREEITEM_ALREADY_EXISTS` 帶 `expectedName`;XAE 用 .xti 寫死的 `<Name>` 當匯入名稱;PLC folder 的 `.zip` 能匯回(#1、#4 修正通過) |
| `DeleteChild` | `Remove-TcTreeItem` | 已實測(重測 2026-10-30):TIRT 獨立 Task `verified=true`、`.xti` 備份、沒有 `.TcTTO` warning;TIPC PLC folder 預設產生 `.zip` 備份、`verified=true`,該 `.zip` 能用 ImportChild 還原(#2、#3 修正通過) |

沒測到：`PLC_LOGGED_IN`(UmRT 沒在跑，不能 Login)、DeleteChild 的 `parent-mismatch`、ConsumeXml 的 `repeated-count-mismatch`、有 mapping 節點的 `Reconnect`。

### 第 2 期新 tool(未實測，等第 2 期 registered,task 3.8)

| tool | cmdlet | 狀態 |
|---|---|---|
| `AddInterface` | `Add-TcInterface` | 未實測(等第 2 期 registered)。只有單元測試(`tests/Unit/pou-member.ps1`);設計依據是自建 client 實測 2026-10-31 4026 VS2022(`verification/phase2-probe.md` 3.6) |
| `AddPouMember` | `Add-TcPouMember` | 未實測(等第 2 期 registered)。同上 |
| `GetLibraries` | `Get-TcLibraries` | 未實測(等第 2 期 registered)。只有單元測試(`tests/Unit/library-manager.ps1`);設計依據是自建 client 實測 2026-10-31 4026 VS2022(`verification/phase2-probe.md` 3.1) |
| `AddPlaceholder` | `Add-TcLibraryPlaceholder` | 未實測(等第 2 期 registered)。同上 |
| `RemoveReference` | `Remove-TcLibraryReference` | 未實測(等第 2 期 registered)。同上 |
| `InstallLibrary` | `Install-TcLibrary` | 未實測(等第 2 期 registered)。同上;改整台機器的 library repository |
| `UninstallLibrary` | `Uninstall-TcLibrary` | 未實測(等第 2 期 registered)。同上;改整台機器的 library repository |
| `FreezePlaceholder` | `Lock-TcLibraryPlaceholder` | 未實測(等第 2 期 registered)。同上;`All=true`(凍結全部)連自建 client 都沒測過 |
| `CheckAllObjects` | `Test-TcPlcProject` | 未實測(等第 2 期 registered)。只有單元測試(`tests/Unit/check-all-objects.ps1`);設計依據是自建 client 實測 2026-10-31 4026 VS2022(`verification/phase2-probe.md` 3.7);4024 沒測過 |
| `AddPlcTask` | `Add-TcPlcTask` | 未實測(等第 2 期 registered)。只有單元測試(`tests/Unit/plc-task.ps1`);設計依據是自建 client 實測 2026-10-31 4026 VS2022(`verification/phase2-probe.md` 3.5);CycleTime 不是 base time 倍數時的處理、CycleCount 在線上有沒有增加都還沒測 |
| `LinkProgramToTask` | `Add-TcTaskProgram` | 未實測(等第 2 期 registered)。同上;PlcTask 的父節點讀回(parent ProduceXml 只能增加)在 650 上沒測過 |
| `UnlinkProgramFromTask` | `Remove-TcTaskProgram` | 未實測(等第 2 期 registered)。同上;650 節點的 ExportChild(.zip)沒測過 |
| `ExportPlcOpen` | `Export-TcPlcOpen` | 未實測(等第 2 期 registered)。只有單元測試(`tests/Unit/plcopen.ps1`);設計依據是自建 client 實測 2026-10-31 4026 VS2022(`verification/phase2-probe.md` 3.3);資料夾 selection 的讀回(projectstructure 的 Folder)沒實測 |
| `ImportPlcOpen` | `Import-TcPlcOpen` | 未實測(等第 2 期 registered)。同上;同名物件在別的資料夾算不算衝突、`<名稱>_1` 已存在時 Rename 的名稱、Replace 前 POU 節點的 ExportChild(.zip)都沒測過 |
| `GenerateBootProject` | `New-TcBootProject` | 未實測(等第 2 期 registered)。只有單元測試(`tests/Unit/boot-project.ps1`);設計依據是自建 client 實測 2026-10-31 4026 VS2022(`verification/phase2-probe.md` 3.2);只測 `bActivate=false`,4024 與 64-bit XAE Shell 沒測過 |

`GetPouCode` / `WritePouCode` 的 task 3.6 新行為(`FB_X.M_Run` 點號寫法、`POU_AMBIGUOUS`、654 / 655 回 `POU_MEMBER_UNSUPPORTED`、`Implementation ""` 清空)也只有單元測試，等 3.8 registered 重測;這兩個 tool 本身仍算已實測。

合計:已實測 46(39 + 第 1 期 7)+ 部分實測 2(`SetVariableLink`、`RemoveVariableLink`)+ 未實測 15(`AddInterface`、`AddPouMember`,task 3.1 的 6 個 Library Manager tool,task 3.7 的 `CheckAllObjects`,task 3.5 的 `AddPlcTask`、`LinkProgramToTask`、`UnlinkProgramFromTask`,task 3.3 的 `ExportPlcOpen`、`ImportPlcOpen`,task 3.2 的 `GenerateBootProject`)= 63。

### 未實測 / 只有單元測試

- **`RUNTIME_CRASHED` 提早退出**(`EnableConfig` / `SetSystemState` 偵測到 target 消失就提早回):只有單元測試(`tests/Unit/runtime-crashed.ps1`)。真機要等 UmRT 自然 crash 才能驗證,不能故意 `Stop-Process TcSystemServiceUm` 模擬。
- **`NewTestCase` 給 `WaitUntil` 時回傳不帶 `waitMs`**:只有單元測試。
- **`SetVariableLink` / `RemoveVariableLink` 成功路徑**:registered 未測(見上表)。
- **`NewProject`**:MCP 暫時下架,cmdlet 保留,沒有在真機驗證(見 #70)。
