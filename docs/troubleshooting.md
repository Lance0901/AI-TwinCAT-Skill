# Troubleshooting

本頁與 `adapters/claude-code/SKILL.md` 的 Troubleshooting 表同源,這裡多了「為什麼會發生」。錯誤碼與 `error.hint` 文字的中央表在 `src/TwinCATAutomation/Private/ConvertTo-TcAdsErrorCode.ps1`(`$script:TcErrorHints`)。

過去兩個月 701 次自動化失敗的根因分布:

| 根因 | 佔比 | 對應錯誤碼 | 本輪修法 |
|---|---|---|---|
| Activate 後 ADS 連線失效沒重連 | 41% | `NOT_CONNECTED`、`ADS_TARGET_NOT_FOUND` | Read/Write/Watch-TcVariable、Get/Set-TcPlcState 自動重連,data 回 `reconnected` |
| COM 被 modal dialog 擋(RPC_E_CALL_REJECTED) | 29% | `IDE_BUSY` | 所有 DTE/COM 呼叫包 retry(1/2/4/8/16s),耗盡才回 `IDE_BUSY` |
| Lifecycle 順序沒 gating | 29% | `ADS_PORT_NOT_FOUND`、`ADS_INVALID_STATE`、`PLC_NOT_LOADED`、`SYSTEM_STATE_TIMEOUT` | `Set-TcSystemState`、`Enable-TcConfig -Force`、`Invoke-TcTestCycle` 每步輪詢到目標狀態才返回 |

## Lifecycle 正確順序

```
Connect-TcIde -SolutionPath <sln>
      │  回 amsNetId、candidates[]
      ▼
Build-TcProject
      │  BUILD_FAILED → 看 IDE Error List
      ▼
Enable-TcConfig -Force            ┐
  ├─ Set-TcSystemState Config     │
  ├─ ActivateConfiguration        │  每步輪詢到目標才進下一步
  ├─ 等 port 10000 = Run          │  失敗回 steps[] 指出停在哪
  ├─ Enter-TcPlcOnline (download) │  (-NoLogin 跳過以下三步)
  ├─ 等 port 851 可達             │
  ├─ Set-TcPlcState Run           │
  ├─ 等 port 851 = Run            │
  └─ 若之前有 ADS 連線 → 自動重連 ┘
      ▼
Connect-TcAds                      (第一次;之後 cmdlet 自動重連)
      ▼
Read/Write/Watch-TcVariable、Invoke-TcTest
      ▼
Set-TcPlcState Stop / Exit-TcPlcOnline / Disconnect-TcAds
```

規則:

- port 851 只在 download 後存在;download 前 `Connect-TcAds -Port 851` 必回 `ADS_PORT_NOT_FOUND`。
- Activate 會重啟 TwinCAT XAR,所有既有 ADS 連線失效;IDE 的 COM 參考**不會**失效,不要重連 IDE。
- 不要用 `Start-Sleep` 猜等待時間;所有等待都已在 cmdlet 內輪詢(`-TimeoutSec` 可調)。
- `Invoke-TcTestCycle` 內部就是上面的流程,每步同樣 gating。

## 環境矩陣

| IDE | ProgID | ADS DLL | 備註 |
|---|---|---|---|
| 32-bit XAE Shell | `TcXaeShell.DTE.15.0` | 4024:TwinCAT 安裝目錄下 Components\Base;4026:package | 4024 原生;4026 安裝也會一併裝,常見於本機 UmRT 開發 |
| 64-bit XAE Shell | `TcXaeShell.DTE.17.0` | 4026 package | 4026 安裝一併裝 |
| VS2022 + TwinCAT 整合 | `VisualStudio.DTE.17.0` | 4026 package | 4026 安裝一併裝(需本機已有 VS2022) |

- TwinCAT 3.1.4026 的安裝會**同時**裝上面三種 IDE,三者的 XAE 版本相同;4024 專案可在 4026 XAE 開啟。
- Automation Interface(`ITcSysManager`、`EnvDTE`)在各組合完全相同;差別只在 IDE 抓取(ProgID)與 ADS DLL 位置。
- `Connect-TcIde` 嘗試順序:`TcXaeShell.DTE.15.0` → `TcXaeShell.DTE.17.0` → `VisualStudio.DTE.17.0`;多實例時依 `-SolutionPath` 挑,`data.candidates[]` 列出所有看到的實例,`data.ideProcessId` 是連上的 IDE pid。ROT 裡正在關閉的舊實例(讀 `Version` / `Solution` 回 0x800706BA / 0x80004005)會被跳過。
- `Connect-TcIde` 自行啟動 IDE 時:`CreateInstance` 後**不碰** `MainWindow.Visible`(此時會丟 property not found),改輪詢 `Version` + `Solution`(500 ms,最長 60 s),就緒後設 `UserControl = $true` 讓 IDE 可見且不隨 COM 釋放關閉;逾時則 `Quit()` 並 kill 啟動時刻之後出現的 `TcXaeShell.exe` / `devenv.exe`,回 `IDE_LAUNCH_FAILED`。
- `Connect-TcAds` 的 `data.adsBackend` 顯示實際載入的 ADS 後端(DLL 路徑 / 反射 fallback)。
- `Enable-TcConfig -Force` 在 UmRT 上第一次需要 license 齊全(trial 要涵蓋專案用到的 TF),否則系統停在 Config 直到 `SYSTEM_STATE_TIMEOUT`。
- 換 target(本機 UmRT ↔ 遠端 CX)或換 IDE 後要重新 `Connect-TcIde`,AmsNetId 會變。

## 已知 modal dialog

與 `IDE_BUSY`(COM 回 0x80010001,可重試)不同,下面這些視窗讓 DTE 呼叫**無限阻塞**、永不返回。模組在 Build / Activate / Login / Solution.Open 之前用 UI Automation(`Get-TcIdeModalDialog`)檢查一次,有就回 `IDE_MODAL_DIALOG`;呼叫進行中另有 watchdog 每 2 s 掃一次,呼叫失敗返回時若看過 dialog 也回 `IDE_MODAL_DIALOG`。模組**只偵測、不關閉任何視窗**;已經被卡住的呼叫無法中斷,只能手動關 dialog 或 kill IDE。

| 視窗 | 何時出現 | 解法 |
|---|---|---|
| `Assertion Failed: Abort=Quit, Retry=Debug, Ignore=Continue` | XAE 反覆開關 solution 後,Build 時(2026-10-18 實測:前一輪正常 Quit 後,下一輪 Build 幾乎必出;Clean 無效) | 關掉 IDE,把 PLC 專案目錄下的 `_CompileInfo` 資料夾改名或刪除(IDE 會重建),再開 solution Build |
| Microsoft Visual Studio 帳戶設定 | VS2022 未登入時 | 登入一次,或手動關閉視窗 |
| `Target system reports a fatal error` | Activate 的設定在 target 上無法啟動 | 看 XAE Output / Error List;UmRT 多半是 license 或 I/O 設定問題 |
| Trial license security code | 7 天 trial 到期或首次啟用 | 需人工輸入驗證碼,模組無法代勞 |

## 驗證紀錄 2026-10-18

環境:TwinCAT 3.1.4026.22 + 本機 UmRT(AmsNetId 199.5.42.250.1.1)。

| 組 | 專案 | IDE | 結果 |
|---|---|---|---|
| A | 4024.71 專案 | 32-bit XAE Shell(`TcXaeShell.DTE.15.0`) | 完整 lifecycle 通過:Connect-TcIde → Build → Enable-TcConfig -Force → Connect-TcAds → Read/Write → Exit-TcPlcOnline |
| B | 4026.24 Robust 專案 | VS2022(`VisualStudio.DTE.17.0`) | Activate 後 target 回 `Target system reports a fatal error`(modal),未通過,原因待查 |

這輪驗證修掉的問題:自啟 IDE 的 `MainWindow.Visible` race(留下孤兒 IDE)、ROT 撿到正在關閉的舊實例(`Solution.Open` 回 null)、`sysManagerAvailable` 在 solution 剛開時誤判 false、`Exit-TcPlcOnline` 在重啟後的舊路徑、`ADS_PORT_NOT_FOUND` hint 寫死 851、`Enter-TcPlcOnline` 訊息固定寫 download。

## 錯誤碼

### IDE_BUSY

- **現象**:任何走 COM 的 cmdlet(Build、Add-TcPou、Enter-TcPlcOnline…)回 `IDE_BUSY`。
- **為什麼**:XAE 正在顯示 modal dialog(license、「專案已修改」、build 確認)或在跑長操作,COM 回 `RPC_E_CALL_REJECTED`(0x80010001)或 `RPC_E_SERVERCALL_RETRYLATER`(0x8001010A)。模組已退避重試 1/2/4/8/16 秒(共約 31 秒)仍被拒。
- **下一步**:切到 XAE 關掉 dialog,重跑同一個 cmdlet。IDE COM 參考仍有效,不用 `Connect-TcIde`。常見 dialog 來源:license 試用到期提示、Activate 時的「Restart TwinCAT System」(用 `-Force` 走 ADS 就不會出現)。

### IDE_MODAL_DIALOG

- **現象**:`Build-TcProject`、`Enable-TcConfig`、`Enter-TcPlcOnline`、`Connect-TcIde` 回 `IDE_MODAL_DIALOG`,`data.dialogTitle` / `dialogText` 是視窗標題與內文。
- **為什麼**:XAE / VS 有 modal 視窗(見「已知 modal dialog」)。這類視窗不會讓 COM 回 `RPC_E_CALL_REJECTED`,而是讓 DTE 呼叫無限阻塞,retry 救不了,所以模組在每個主要 COM 步驟前先用 UI Automation 掃 IDE 程序(`data.ideProcessId`)的頂層視窗。
- **下一步**:手動處理 dialog 後重跑同一個 cmdlet;關不掉就 `Stop-Process -Id <ideProcessId>` 後重新 `Connect-TcIde -SolutionPath <sln>`。模組不會自動關閉任何視窗。
- **限制**:已經被 modal 擋住、正在阻塞中的呼叫無法從模組中斷;偵測靠視窗的 `IsModal` / `#32770` class / 已知標題,偵測不到時仍可能卡住。

### IDE_TIMEOUT

- **現象**:COM cmdlet 回 `IDE_TIMEOUT`,訊息含 `did not return within N s`。
- **為什麼**:`Invoke-TcComRetry -TimeoutSec`(預設 120 s;Build 600 s、Activate / Login 300 s)只是預期上限,同步呼叫無法被中斷;呼叫最後失敗返回時若已超過這個時間,就以 `IDE_TIMEOUT` 回報而不是原始錯誤(原始訊息附在後面)。
- **下一步**:看 XAE 有沒有 dialog 或長操作;必要時 kill IDE 後重新 `Connect-TcIde`。

### NOT_CONNECTED

- **現象**:`Read-TcVariable` 等 ADS cmdlet 回 `NOT_CONNECTED`。
- **為什麼**:從未 `Connect-TcAds`;或 `Enable-TcConfig` 重啟了 TwinCAT,自動重連也失敗(目標還沒回 Run、或 851 還不存在)。
- **下一步**:`Get-TcSystemState` 確認 Run → `Connect-TcAds`。若反覆發生,把 `Enable-TcConfig -TimeoutSec` 調大。

### ADS_PORT_NOT_FOUND(ADS 0x6)

- **為什麼**:PLC runtime port 851 不存在。程式尚未 download(Activate 後 PLC 是空的),或 PLC 專案沒被加進 config。
- **下一步**:`Enter-TcPlcOnline` → `Set-TcPlcState -State Run`;或直接 `Enable-TcConfig -Force`(不帶 `-NoLogin`)。

### ADS_TARGET_NOT_FOUND(ADS 0x7)

- **為什麼**:AmsNetId 無回應。TwinCAT 正在重啟(Activate 後數秒內)、AmsNetId 打錯、或遠端 route 沒建。
- **下一步**:等 `Get-TcSystemState` 回 Run 再 `Connect-TcAds`。AmsNetId 一律用 `Connect-TcIde` 回的 `data.amsNetId`,不要手打。

### ADS_SYMBOL_NOT_FOUND(ADS 0x710)

- **為什麼**:symbol 路徑在目前 PLC 內不存在。新加的變數還沒 download、路徑大小寫/拼字錯、或 symbol 被 optimizer 拿掉(沒被引用的變數)。
- **下一步**:`Get-TcSymbols -Filter "MAIN.*"` 列出實際名稱;必要時 Build → `Enter-TcPlcOnline`。

### ADS_INVALID_STATE(ADS 0x712)

- **為什麼**:PLC 在目前狀態不允許此操作,例如系統還在 Config 模式就送 PLC Run、或 PLC 在 Exception 狀態。
- **下一步**:`Get-TcSystemState` + `Get-TcPlcState` 看狀態;照順序 `Enable-TcConfig` → `Enter-TcPlcOnline` → `Set-TcPlcState Run`。

### ADS_TIMEOUT(ADS 0x745)

- **為什麼**:ADS 請求逾時。目標忙碌(重啟中、大量 symbol 上傳)、網路問題、或 UmRT service 已停。
- **下一步**:稍後重試;`Get-TcSystemState` 看目標是否活著;UmRT 看 `TcSystemServiceUm` 是否還在。

### PLC_NOT_LOADED

- **為什麼**:`Set-TcPlcState -State Run` 時 PLC 內沒有程式。Activate 會清掉 runtime 內的程式,必須重新 download。
- **下一步**:`Enter-TcPlcOnline` 後再 Run;或用 `Enable-TcConfig -Force`,它已包含 download。

### AMS_NETID_REQUIRED

- **為什麼**:cmdlet 需要 AmsNetId,但沒有 IDE 連線可推導,呼叫時也沒給 `-AmsNetId`。
- **下一步**:`Connect-TcIde -SolutionPath <sln>`,之後 AmsNetId 自動偵測。

### PROJECT_OPEN_TIMEOUT

- **為什麼**:`Connect-TcIde -SolutionPath` 開了 solution,但 `Solution.IsOpen` / `Projects.Count` 在時限內沒就緒。常見:.sln 內沒有 TwinCAT 專案、XAE 跳出 dialog(升級專案、缺 library)、或 IDE 正在冷啟動。
- **下一步**:看 XAE 畫面關 dialog;重跑 `Connect-TcIde -SolutionPath <sln>`。

### SYSTEM_STATE_TIMEOUT

- **為什麼**:`Set-TcSystemState` 透過 ADS WriteControl 要求切換後,輪詢 port 10000 在 `-TimeoutSec` 內沒到目標狀態。原因:TwinCAT System Service 報錯(license、config 錯)、UmRT service 掛掉、或 target 無回應。若 target 是 UmRT 且剛 Activate 就停在 Config,常見原因是 license 不足(trial 未涵蓋專案用到的 TF),請在 XAE 的 License 節點確認。
- **下一步**:`Get-TcSystemState` 看現在的狀態;看 XAE 的 TwinCAT 圖示、License 節點與 Windows 事件檢視器;UmRT 重啟 `TcSystemServiceUm`。

### BUILD_FAILED

- **為什麼**:編譯錯誤。模組目前只讀得到錯誤數,讀不到錯誤訊息(見已知限制)。
- **下一步**:在 IDE 的 Error List 看原因,改 code 後 `Build-TcProject`。不要在沒改東西的情況下重跑 Build。

### PROJECT_OPEN_FAILED

- **為什麼**:`Open-TcProject` / `Connect-TcIde -SolutionPath` 開 .sln 失敗。路徑錯、檔案損壞、或連到的 IDE 沒有 TwinCAT 整合(例如抓到沒裝 TwinCAT 的 VS)。
- **下一步**:確認路徑;指定 `-ProgId` 對應正確的 IDE(見環境矩陣)。

### POU_CREATE_FAILED

- **為什麼**:`Add-TcPou` 的 `CreateChild` 失敗。HRESULT `0x98510001` 表示 .plcproj 的 `<Compile Include>` 列了某個檔案,但磁碟上沒有(通常是手動刪檔、或 git 沒追蹤到)。
- **下一步**:從 .plcproj 移除缺檔的項目或補回檔案,重開 solution 後再 `Add-TcPou`。

### LOGOUT_FAILED

- **為什麼**:Logoff COM 呼叫失敗:PLC 不在 online(已 logout)、IDE busy、或 modal dialog。4026 上方法名是 **`Logoff()`**,不是 `Logout()`;`Login / Logoff / Start / Stop / Reset` 由 `TIPC^<Plc>` 與 `<Plc> Project` 節點透過 IDispatch 提供,而兩個節點的 `.Object` 都是 null(2026-10-18 以 `Get-Member` 實測)。`Exit-TcPlcOnline` 依序試 `plcNode.Logoff`、`plcNode.Logout`、`treeItem.Logoff`、`treeItem.Logout`,`data.logoutVia` 說明實際走哪條;舊版 `TIPC.Child(1).Object.Logout()` 因此永遠失敗。
- **下一步**:`Get-TcPlcState` 確認;IDE 有 dialog 就關掉再試;不用重連 IDE。

### NO_PROJECT

- **為什麼**:已連 IDE,但 `ITcSysManager` 拿不到(solution 內沒 TwinCAT 專案,或還沒開 solution)。
- **下一步**:`Open-TcProject -Path <sln>` 或重跑 `Connect-TcIde -SolutionPath <sln>`。

### LOGIN_FAILED

- **為什麼**:`Enter-TcPlcOnline` 的 `Login(3)` 失敗。系統在 Config 模式、上次 build 沒過、target 沒有 PLC license、或跳出 dialog。
- **下一步**:`Get-TcSystemState` 需為 Run;`Build-TcProject` 成功;關 dialog。

### ADS_CONNECT_FAILED / ADS_ASSEMBLY_NOT_FOUND

- **為什麼**:`Connect-TcAds` 建立 client 失敗;或找不到 TwinCAT.Ads.dll(TwinCAT 沒裝、或 PowerShell 7 載入失敗)。
- **下一步**:確認 TwinCAT XAE 安裝;`Connect-TcAds` 成功時看 `data.adsBackend` 用了哪個後端;PowerShell 7 下模組會嘗試反射 fallback。

### TYPE_MISMATCH

- **為什麼**:`Write-TcVariable` 的值型別與 symbol 型別不符(例如對 `UINT` 寫 `-1`、對 `BOOL` 寫字串)。
- **下一步**:`Get-TcSymbols` 看 type,用對應 PowerShell 型別轉型(`[uint16]0`、`$true`)。

### ACTIVATION_FAILED

- **為什麼**:`ActivateConfiguration()` COM 呼叫失敗。專案有錯誤、target 沒 license、I/O 配置與硬體不符、或跳出 dialog。
- **下一步**:Build 成功、IDE 無 dialog 後重跑;看 `data.steps[]` 停在哪一步。

## 已知限制

| 限制 | 說明 | 繞法 |
|---|---|---|
| Build 錯誤訊息讀不到 | `Build-TcProject` 只回錯誤/警告數,Error List 內容屬下一階段 | 在 IDE Error List 看訊息 |
| UmRT 假 Run | 本機 UmRT 跑約 30 分鐘後 task 可能停止循環,但 ADS 仍回 Run | 讀 `TwinCAT_SystemInfoVarList._TaskInfo[1].CycleCount` 兩次,沒動就重啟 `TcSystemServiceUm` 後 `Enable-TcConfig -Force` |
| Reset 殺 service | 對 UmRT 送 `Set-TcPlcState -State Reset` 會直接結束 `TcSystemServiceUm` | 不要對 UmRT 用 Reset;要清狀態改 Stop → `Enter-TcPlcOnline` 重新 download;真的 Reset 了就手動重啟 service |
| 重新 download 後 index offset 錯位 | symbol 的 indexGroup/indexOffset 在每次 download 後可能改變;舊 handle 會讀到別的變數 | 不快取 offset;懷疑錯位時比對 `TwinCAT_SystemInfoVarList._AppInfo.AppTimestamp` 是否變了,變了就重新 `Get-TcSymbols` |
| FB `VAR_INPUT` 寫不進去 | PLC 每個 scan 覆寫 FB 輸入 | 在 MAIN 宣告獨立變數餵 FB,寫 MAIN 層級變數 |

## 真機驗證腳本

`tests/Integration/` 有 4 支需要真實環境的手動腳本:`bool-write.ps1`、`write-verify.ps1`、`list-symbols.ps1`、`full-cycle.ps1`。用法見 `tests/Integration/README.md`。
