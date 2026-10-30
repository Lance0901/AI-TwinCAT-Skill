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

## 真機驗證範圍(實測 2026-10-28 ~ 2026-10-29)

MCP 共 **48 個 tool**:`mcp-server/tools.json` 44 個(2026-10-29 用 node 讀的 37 個,加第 1 期 2026-10-30 新增的 7 個通用 tree tool)加 `mcp-server/lib/composites.js` 匯出的 4 個複合 tool(`RunLifecycle`、`QuickRead`、`GetStatus`、`GetIdeModalDialog`),兩份名稱沒有重複。`RunTestCycle` 在 `tools.json`(不是 composite)。`NewProject` 不在 MCP 上(見上方 #70)。

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

### 未實測(等第 1 期 task 2.8,7 個)

第 1 期新增的通用 tree tool,目前只有單元測試(`tests/Unit/tree-item-helpers.ps1`、`tests/Unit/tree-item-tools.ps1`,mock `ITcSysManager`),registered tcauto 還沒跑過。

| tool | cmdlet | 狀態 |
|---|---|---|
| `LookupTreeItem` | `Get-TcTreeItem` | 未實測(等 2.8) |
| `ProduceXml` | `Get-TcTreeItemXml` | 未實測(等 2.8) |
| `CreateChild` | `New-TcTreeItem` | 未實測(等 2.8) |
| `ConsumeXml` | `Set-TcTreeItemXml` | 未實測(等 2.8);ConsumeXml 本身的合併行為 2.1 用自建 client 實測過 |
| `DeleteChild` | `Remove-TcTreeItem` | 未實測(等 2.8) |
| `ExportChild` | `Export-TcTreeItem` | 未實測(等 2.8) |
| `ImportChild` | `Import-TcTreeItem` | 未實測(等 2.8) |

合計:已實測 39 + 部分實測 2 + 未實測 7 = 48。

### 未實測 / 只有單元測試

- **`RUNTIME_CRASHED` 提早退出**(`EnableConfig` / `SetSystemState` 偵測到 target 消失就提早回):只有單元測試(`tests/Unit/runtime-crashed.ps1`)。真機要等 UmRT 自然 crash 才能驗證,不能故意 `Stop-Process TcSystemServiceUm` 模擬。
- **`NewTestCase` 給 `WaitUntil` 時回傳不帶 `waitMs`**:只有單元測試。
- **`SetVariableLink` / `RemoveVariableLink` 成功路徑**:registered 未測(見上表)。
- **`NewProject`**:MCP 暫時下架,cmdlet 保留,沒有在真機驗證(見 #70)。
