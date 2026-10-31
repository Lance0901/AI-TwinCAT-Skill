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

### `GetLibraries` 的 `frozen` 只代表 .plcproj 有固定版本

- **現象**:`frozen` 只看磁碟上 .plcproj 的 `<PlaceholderResolution><Resolution>` 版本是不是 `*`。用固定版本加入的 placeholder(`AddPlaceholder Version=3.5.1.0`),XAE 直接寫固定版本的 Resolution,沒有 freeze 過也讀成 `frozen = true`;DefaultResolution 是固定版本、但 .plcproj 沒有 Resolution 的(例如 `#Tc2_Standard`)讀成 `frozen = false`(registered tcauto 實測 2026-10-31 4026 VS2022)。只在 XAE 記憶體、還沒存的改動看不到。
- **繞過**:`frozen` 當成「.plcproj 有沒有固定版本」來讀，不要當成「呼叫過 FreezePlaceholder」;實際解析的版本看 `effectiveResolution`。

### `FreezePlaceholder All=true` 可能改掉 library 版本

- **現象**:XAE 凍結的版本不一定是目前的 effective 版本:`#Tc2_System` 3.10.1.0 → 3.9.1.0、`#CBML` 4.0.0.0(CODESYS)→ 3.5.13.0(3S)(4026 VS2022);`VisuDialogs` 3.5.12.0 → 4.8.0.0(4024 XAE,回 success、沒有 warning)。模組讀回只檢查不是 `*`,抓不到。XAE 隱含加入、.plcproj 沒有 `<PlaceholderReference>` 的 placeholder(4026 的 `#Tc3_GlobalTypes`)不會被寫，模組回 `LIBRARY_VERIFY_FAILED`,但其他 placeholder 已經改了並存檔(registered tcauto 實測 2026-10-31,細節 [verification/phase2-3.8.md](../openspec/changes/complete-automation-interface/verification/phase2-3.8.md) 7)。
- **繞過**:不要用 `All=true`;一個一個 `FreezePlaceholder Placeholder=<name>`(單一 freeze 的版本和 effective 相同，實測)。已經跑過 `All` 就用 `data.backupFiles` 的 .plcproj 複製回去再 `ResetSolution`。
- **模組修正(2026-10-31,只有單元測試，待真機重測)**:凍結後逐一比對 `<Resolution>` 和凍結前的 EffectiveResolution;不同時先用 `SetEffectiveResolution` 釘回(未實測),仍不同回 `LIBRARY_VERSION_CHANGED`(`data.versionChanges[]`、`data.changed[]`、`data.restore`),不再回 success。dry-run 的 `targets[].willFreezeTo` / `versionWillChange` 先預告。`All` 跳過隱含 placeholder 與沒有 EffectiveResolution 的(`data.skipped[]`),不算 `notFrozen`。見 troubleshooting「LIBRARY_VERSION_CHANGED」。

### `AddPlcTask` 建的 task 沒有存進專案檔

- **現象**:`AddPlcTask` 回 `verified=true`,但 .tsproj / .plcproj 沒有寫(只在 XAE 記憶體);接著 `ResetSolution`(含 `SaveProjectChanges=true`)後 TIRT 與 PLC 底下的新 task 都消失，`ResetSolution` 也沒偵測到(registered tcauto 實測 2026-10-31 4026 VS2022)。
- **繞過**:AddPlcTask 之後跑一個會存專案檔的 tool(例如 `AddGvl` / `AddPou`,或 `GenerateBootProject`),再確認 .tsproj 有 task 名稱、.plcproj 有 `<Compile Include="<task>.TcTTO">`;在那之前不要 `ResetSolution`。
- **模組修正(2026-10-31,只有單元測試，待真機重測)**:`AddPlcTask` 讀回後自己存檔(同 `AddPou`),並從磁碟讀回 `.plcproj` 的 `<task>.TcTTO`、`.tsproj` 的 task 名稱才 success(`data.projectSaved`)。`LinkProgramToTask` / `UnlinkProgramFromTask` 不需要:650 當下就改寫 `.TcTTO`(實測)。

### `SaveAsLibrary` 會存 .plcproj

- **現象**:tool 說明寫不改專案，實際會把 XAE 記憶體裡還沒存的改動寫進 .plcproj(4026 VS2022、4024 XAE,registered tcauto 實測 2026-10-31)。
- **繞過**:為了產生 library 暫時改的 project info 等設定，SaveAsLibrary 之後要改回去並再存一次。
- **模組說明已改**(2026-10-31):cmdlet 說明、`tools.json`、SKILL.md 寫明會存 .plcproj;回傳 `data.projectSaved`(= `data.projectFileWritten`,呼叫前後 `data.projectFile` 的 LastWriteTime 比較;找不到 .plcproj 時 null)。行為本身是 XAE 的，模組不擋。

## 真機驗證範圍(實測 2026-10-28 ~ 2026-10-31)

MCP 共 **65 個 tool**:`mcp-server/tools.json` 61 個(2026-10-29 用 node 讀的 37 個,加第 1 期 2026-10-30 新增的 7 個通用 tree tool,加第 2 期 task 3.6 新增的 `AddInterface`、`AddPouMember`,加 task 3.1 新增的 6 個 Library Manager tool:`GetLibraries`、`AddPlaceholder`、`RemoveReference`、`InstallLibrary`、`UninstallLibrary`、`FreezePlaceholder`,加 task 3.7 的 `CheckAllObjects`,加 task 3.5 的 `AddPlcTask`、`LinkProgramToTask`、`UnlinkProgramFromTask`,加 task 3.3 的 `ExportPlcOpen`、`ImportPlcOpen`,加 task 3.2 的 `GenerateBootProject`,加 task 3.4 的 `SaveAsLibrary`、`SaveArchive`)加 `mcp-server/lib/composites.js` 匯出的 4 個複合 tool(`RunLifecycle`、`QuickRead`、`GetStatus`、`GetIdeModalDialog`),兩份名稱沒有重複。`RunTestCycle` 在 `tools.json`(不是 composite)。`NewProject` 不在 MCP 上(見上方 #70)。

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

### 第 2 期新 tool(task 3.8,17 個)

registered tcauto 實測 2026-10-31 本機，離線(沒有 Activate / Login):**4026 VS2022**(TwinCAT 3.1.4026.22,副本 `C:\Temp\Verify-4026-axis`)每個 tool 都跑 dry-run(有的話)、實寫、讀回、錯誤路徑;**4024 XAE**(32-bit XAE Shell,專案 3.1.4024.71,副本 `C:\Temp\Verify-4024-bfh`)每個 tool 跑一次成功路徑。逐項紀錄與「發現的問題」P1–P8 見 [verification/phase2-3.8.md](../openspec/changes/complete-automation-interface/verification/phase2-3.8.md)。多數 hint 還有 cmdlet 名稱或 PowerShell 參數寫法，有幾條轉換壞掉(例如 `DryRun=true $false`、`PlcOnly=and`),見 P1。

| tool | cmdlet | 狀態 |
|---|---|---|
| `AddInterface` | `Add-TcInterface` | 已實測(4026、4024)。EXTENDS 讀回正確、.plcproj 讀回 |
| `AddPouMember` | `Add-TcPouMember` | 已實測(4026、4024)。非 PUBLIC 讀回 `METHOD PRIVATE M : BOOL` / `PROPERTY PROTECTED P : INT` / `METHOD INTERNAL ...`;ITF property 的 Get 在建立前就擋 |
| `GetLibraries` | `Get-TcLibraries` | 已實測(4026、4024)。`frozen` 的意思見上方「`frozen` 只代表 .plcproj 有固定版本」 |
| `AddPlaceholder` | `Add-TcLibraryPlaceholder` | 已實測(4026、4024) |
| `RemoveReference` | `Remove-TcLibraryReference` | 已實測(4026、4024)。帶不帶 `#` 都可 |
| `InstallLibrary` | `Install-TcLibrary` | 已實測(4026、4024,只用自己產生的 library;結束時 repository 與開始前相同)。dry-run 不檢查 repository 名稱(P8) |
| `UninstallLibrary` | `Uninstall-TcLibrary` | 已實測(4026、4024)。備份目錄內容正確;把備份目錄手動複製回 repository XAE 不認，要用 InstallLibrary 安裝備份裡的 `.library` 還原 |
| `FreezePlaceholder` | `Lock-TcLibraryPlaceholder` | 已實測(4026、4024)。單一 placeholder 正確;**`All=true` 有問題**,見上方「`FreezePlaceholder All=true` 可能改掉 library 版本」(P2、P3) |
| `CheckAllObjects` | `Test-TcPlcProject` | 已實測(4026 passed / CHECK_FAILED 兩條;4024 支援，副本本身沒被引用的 FB 有錯，只走到 CHECK_FAILED) |
| `AddPlcTask` | `Add-TcPlcTask` | 已實測(4026、4024)。父節點只多 ChildCount;Priority 超出 XAE 接受範圍會被換成別的值 → 讀回不符、回滾;cycle time 不是 base time 倍數時離線照收、沒警告;**沒存檔**,見上方(P4)。線上 CycleCount 沒測 |
| `LinkProgramToTask` | `Add-TcTaskProgram` | 已實測(4026、4024)。650 `parentUnchanged=true` |
| `UnlinkProgramFromTask` | `Remove-TcTaskProgram` | 已實測(4026、4024)。650 的 `.zip` 匯不出("No content in ZIP file."),`.TcTTO` 複製回去 + `ResetSolution` 可還原(task 已存檔的前提下) |
| `ExportPlcOpen` | `Export-TcPlcOpen` | 已實測(4026、4024)。頂層資料夾 selection 讀回 `folder` 正確;**整專案匯出的讀回只列 GVL、ITF method 不列在 members**(P5) |
| `ImportPlcOpen` | `Import-TcPlcOpen` | 已實測(4026 四種 Option + 還原;4024 Rename)。Skip / Rename / None 與 dry-run 一致;`_1` 已存在時 XAE 用 `_2`;**Replace 預告會多報 ITF method 被刪**(P6);PLCopen 備份與 diskOnly 的磁碟檔都能還原;不同資料夾的同名物件 XAE 也當衝突 |
| `GenerateBootProject` | `New-TcBootProject` | 已實測(4026 `TwinCAT OS (x64)`、4024 `TwinCAT RT (x64)`)。boot 檔讀回和實際變動相同，target Boot 目錄不變;只測 `bActivate=false` |
| `SaveAsLibrary` | `Save-TcPlcLibrary` | 已實測(4026、4024)。**會存 .plcproj**,見上方(P7);從沒 build 過的專案沒測 |
| `SaveArchive` | `Save-TcArchive` | 已實測(4026 Solution 回 `ARCHIVE_INCOMPLETE`(Scope 專案)、Configuration 成功;4024 兩種都成功)。"Error creating Archive" 在呼叫期間同步出現;載入 archive 不在範圍內 |

`GetPouCode` / `WritePouCode` 的 task 3.6 新行為:`FB_X.M_Run` 點號寫法(含 `FB_X.P.Set`)與 `Implementation ""` 清空(`cleared=true`)已 registered 實測(2026-10-31 4026 VS2022);`POU_AMBIGUOUS` 與 654 / 655 的 `POU_MEMBER_UNSUPPORTED` 仍只有單元測試(專案裡沒有這種物件，也不能建 654 / 655)。

合計:已實測 63(39 + 第 1 期 7 + 第 2 期 17)+ 部分實測 2(`SetVariableLink`、`RemoveVariableLink`)= 65。

### 未實測 / 只有單元測試

- **`RUNTIME_CRASHED` 提早退出**(`EnableConfig` / `SetSystemState` 偵測到 target 消失就提早回):只有單元測試(`tests/Unit/runtime-crashed.ps1`)。真機要等 UmRT 自然 crash 才能驗證,不能故意 `Stop-Process TcSystemServiceUm` 模擬。
- **`ImportPlcOpen` Replace 後用 `.zip` 還原**:磁碟檔副本複製回去 + `ResetSolution` 已實測可還原 ITF property(2026-10-31 4026 VS2022);`ImportChild` 匯回備份 `.zip` 這條沒測。
- **`GenerateBootProject` solution / project platform 不同時的資料夾**:模組兩個 `_Boot\<platform>\Plc` 都查;XAE 實際寫哪一個沒實測(3.8 的 4026 / 4024 副本兩者都相同)。
- **`AddPlcTask` 線上行為**:cycle time 不是 base time 倍數時 Activate 後怎麼處理、新 task 的 CycleCount 有沒有增加，都要 Activate 才能測，沒測。
- **`NewTestCase` 給 `WaitUntil` 時回傳不帶 `waitMs`**:只有單元測試。
- **`SetVariableLink` / `RemoveVariableLink` 成功路徑**:registered 未測(見上表)。
- **`NewProject`**:MCP 暫時下架,cmdlet 保留,沒有在真機驗證(見 #70)。
