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

## 真機驗證範圍(實測 2026-10-28)

下表「已實測」欄的 20 個 tool 在 2026-10-28 用 registered tcauto MCP 對**本機 UmRT** 實際跑過:主流程 `ConnectIde` → `SetTarget` → `BuildProject` → `EnableConfig` → `ConnectAds` → `ReadVariable` / `WriteVariable` / `QuickRead`,加上 `GetPouCode` / `WritePouCode`、`AddPou` / `AddDut` / `AddGvl`、`ResetSolution`、`GetBuildErrors`、`GetStatus`、`PlcLogin`、`GetProjectTree`、`GetSymbols`、`DisconnectIde`,IDE 為 **4024 XAE(32-bit XAE Shell)、4026 XAE(64-bit XAE Shell)、VS2022**(環境與步驟見 [agent-brief-realmachine.md](agent-brief-realmachine.md))。其他 tool 近期沒有在真機上跑過,視為 **beta / 未驗證**:能用,但結果請多一層確認,有問題請開 issue。

下表依 `mcp-server/tools.json`(36 個 cmdlet tool)加 4 個複合 tool(`RunLifecycle`、`QuickRead`、`GetStatus`、`GetIdeModalDialog`)列出全部 MCP tool:

| 已實測(2026-10-28,本機 UmRT,registered tcauto) | 未實測(beta / 未驗證) |
|---|---|
| `ConnectIde` | `AddLibrary`(#80 已改用 ITcPlcLibraryManager.AddLibrary;自建 client 實測 2026-10-28 4024 / 4026 PASS,待 registered tcauto 複測) |
| `SetTarget` | `CleanProject` |
| `BuildProject` | `DisconnectAds` |
| `EnableConfig` | `GetIdeInfo` |
| `ConnectAds` | `GetIoTree` |
| `ReadVariable` | `GetPlcState` |
| `WriteVariable` | `GetSystemState` |
| `QuickRead`(複合) | `IoScan` |
| `GetPouCode` | `NewTestCase` |
| `WritePouCode` | `OpenProject` |
| `AddPou` | `PlcLogout` |
| `AddDut` | `RunTest` |
| `AddGvl` | `RunTestCycle` |
| `ResetSolution` | `SendPlcProgram` |
| `DisconnectIde` | `SetPlcState` |
| `GetBuildErrors` | `SetSystemState` |
| `GetStatus`(複合) | `SetVariableLink` |
| `PlcLogin` | `WatchVariable` |
| `GetProjectTree` | `RunLifecycle`(複合) |
| `GetSymbols` | `GetIdeModalDialog`(複合) |

`NewProject` 不在 MCP 上(見上方 #70)。
