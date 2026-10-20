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
      │  BUILD_FAILED → 看 data.errorItems(Error List 明細)
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
| 32-bit XAE Shell | `TcXaeShell.DTE.15.0` | 4024:TwinCAT 安裝目錄下 Components\Base;4026:package | TwinCAT 4024 |
| 64-bit XAE Shell | `TcXaeShell.DTE.17.0` | 4026 package | TwinCAT 4026 |
| VS2022 + TwinCAT 整合 | `VisualStudio.DTE.17.0` | 4026 package | TwinCAT 4026(與 64-bit XAE Shell 同一套 XAE;需本機已有 VS2022) |

- 版本對應:32-bit XAE Shell(`TcXaeShell.DTE.15.0`)= **TwinCAT 4024**;64-bit XAE Shell(`TcXaeShell.DTE.17.0`)與 VS2022(`VisualStudio.DTE.17.0`)= 4026,後兩者是同一套 XAE。Runtime:本機只有一個 UmRT_Default,三種 IDE 共用;UmRT 本身沒有版本,它是本機安裝的 TwinCAT runtime 跑在 user mode(`TcSystemServiceUm.exe` 檔案版本 3.1.4026.21 只是識別用;`TCATSysSrv` 4026.22)。
- Automation Interface(`ITcSysManager`、`EnvDTE`)在各組合完全相同;差別只在 IDE 抓取(ProgID)與 ADS DLL 位置。
- `Connect-TcIde` 嘗試順序:`TcXaeShell.DTE.15.0` → `TcXaeShell.DTE.17.0` → `VisualStudio.DTE.17.0`;多實例時依 `-SolutionPath` 挑:只接已開該 sln 的實例(`data.selectedBy=solution-match`),沒有就啟動新實例(`launched`);別人開的空 IDE 或開著其他 sln 的 IDE 一律不碰,`Disconnect-TcIde -Quit` 也只關自己連上的那個 pid。`data.candidates[]` 列出所有看到的實例,`data.ideProcessId` 是連上的 IDE pid(`Get-TcIdeModalDialog` 只掃這個 pid 的視窗)。真機驗證:`tests/Integration/multi-ide.ps1`。ROT 裡正在關閉的舊實例(讀 `Version` / `Solution` 回 0x800706BA / 0x80004005)會被跳過。
- `Connect-TcIde` 自行啟動 IDE 時:`CreateInstance` 後**不碰** `MainWindow.Visible`(此時會丟 property not found),改輪詢 `Version` + `Solution`(500 ms,最長 60 s),就緒後設 `UserControl = $true` 讓 IDE 可見且不隨 COM 釋放關閉;逾時則 `Quit()` 並 kill 啟動時刻之後出現的 `TcXaeShell.exe` / `devenv.exe`,回 `IDE_LAUNCH_FAILED`。
- `Connect-TcAds` 的 `data.adsBackend` 顯示實際載入的 ADS 後端(DLL 路徑 / 反射 fallback)。
- `Enable-TcConfig -Force` 在 UmRT 上第一次需要 license 齊全(trial 要涵蓋專案用到的 TF),否則系統停在 Config 直到 `SYSTEM_STATE_TIMEOUT`。
- 換 target(本機 UmRT ↔ 遠端 CX)或換 IDE 後要重新 `Connect-TcIde`,AmsNetId 會變。

## 已知 modal dialog

與 `IDE_BUSY`(COM 回 0x80010001,可重試)不同,下面這些視窗讓 DTE 呼叫**無限阻塞**、永不返回。模組在 Build / Activate / Login / Solution.Open 之前用 UI Automation(`Get-TcIdeModalDialog`)檢查一次,有就回 `IDE_MODAL_DIALOG`;呼叫進行中另有 watchdog 每 2 s 掃一次,呼叫失敗返回時若看過 dialog 也回 `IDE_MODAL_DIALOG`。模組**只偵測、不關閉任何視窗**;已經被卡住的呼叫無法中斷,只能手動關 dialog 或 kill IDE。

| 視窗 | 何時出現 | 解法 |
|---|---|---|
| `Assertion Failed: Abort=Quit, Retry=Debug, Ignore=Continue` | Build 時 CODESYS 優化器處理 visu 元素的內部錯誤(NullReference / DivideByZero),**間歇性**:反覆開關 solution 後、或全新專案第一次全編譯都可能出;Clean 無效,清 `_CompileInfo` 也不保證 | 這個 modal 會讓 DTE 呼叫無限阻塞,只能 `Stop-Process` 該 IDE,重開 solution 再 Build(通常第二次就過) |
| Microsoft Visual Studio 帳戶設定 | VS2022 未登入時 | 登入一次,或手動關閉視窗 |
| `Target system reports a fatal error` | Activate 的設定在 target 上無法啟動 | 看 XAE Output / Error List;UmRT 多半是 license 或 I/O 設定問題 |
| Trial license security code | 7 天 trial 到期或首次啟用 | 需人工輸入驗證碼,模組無法代勞 |
| `Application 'Port_851' does not exist on device ... create it and proceed with download?` | 空 runtime 上 Login 時全域 `SilentMode` 沒開(例如沒經 `Connect-TcIde` 連線) | `Connect-TcIde` 連上就開 `ITcAutomationSettings.SilentMode`,XAE 自動答 Yes,不應再出現;手動點 Yes 即可。**不要**改用旗標 SILENT(257)壓框:它會跳過建 app,851 仍 Invalid |
| `Login aborted: Conflicting flag settings` | Login 旗標 3(REGULAR\|FORCEONLINECHANGE 互斥) | 不要用 3;用 `-LoginMode Regular\|Download\|OnlineChange`(1/4/2,不 OR SILENT) |
| `File has been changed outside the environment. Reload the new file?`(VS2022 寫法 `... changed outside the source editor. Do you want to reload it?`) | 開在編輯器裡的檔案(.TcPOU 等)被磁碟上的工具(AI 編輯器、git checkout、產生器)改了,約 1 s 後出現;VS 選項 `AutoloadExternalChanges` 壓不掉。沒開在編輯器的檔案 XAE 約 5 s 內自動重載、不跳框(2026-10-20 `reload-experiment.ps1`) | `Get-TcIdeModalDialog` 回 `Kind = reload-prompt`(結果 `data.dialogKind`),hint 指向 `Reset-TcSolution`,它會對這個提示送 WM_CLOSE、`Documents.CloseAll`、`Solution.Close`、同一個 IDE `Solution.Open`、`Connect-TcIde` 重連(約 20~25 s);之後改磁碟後立刻 `Reset-TcSolution` 即可。見「磁碟改檔的正確做法」 |
| `TwinCAT PLC Control`(class `#32770`) | 2026-10-18 經 MCP server 跑 `BuildProject` 時出現一次;成因未定,懷疑 OneDrive 檔案鎖或新啟動的 IDE 第一次 build。標題不在已知清單,靠 `#32770` class 偵測 | DTE 呼叫無限阻塞,等到 `BRIDGE_TIMEOUT`(Build 600 s)才 kill bridge;IDE 本身不會退出,只能 kill 該 IDE(MCP 結果的 `data.lastIde.ideProcessId` / `error.hint` 會給 pid 與 `taskkill` 指令),重新 `ConnectIde` 再 Build |

## 磁碟改檔的正確做法(.TcPOU / .TcGVL / .plcproj 直接改檔案)

`Write-TcPouCode` / `Add-TcPou` 走 COM(`ITcSmTreeItem.DeclarationText` / `ImplementationText`)寫進 IDE 的編輯 buffer,**不會**跳框,優先用它;但磁碟檔案**不會**立刻更新(真機:mtime/hash 不變、`Document.Saved = false`),要到存檔或 Build 的 Save all before build 才落地,要讓磁碟同步就接著 `Build-TcProject`。AI 或其他工具直接改磁碟上的檔案時,決定一切的是「該檔案有沒有開在 XAE 的文件視窗」(2026-10-20 `tests/Integration/reload-experiment.ps1`,4024 32-bit XAE,log 在 `tests/Integration/logs/reload-S*.log`):

| 情境 | XAE 行為 | 正確做法 |
|---|---|---|
| 檔案**沒有**開在編輯器 | 約 5 s 內自動偵測並重載,`Get-TcPouCode` 讀到新內容、Build 用新檔;不跳任何框 | 改完等 5 s 再呼叫 DTE(或直接 `Reset-TcSolution` 確保一致) |
| 檔案**開著** | 約 1 s 後跳 modal「File has been changed outside the environment. Reload the new file?」,所有 DTE 呼叫阻塞;`Tools > Options > Environment > Documents > AutoloadExternalChanges` 壓不掉 | 改完**立刻** `Reset-TcSolution`:提示已經跳出來也沒關係,它會先把提示關掉(`dismissedReloadPrompt = true`),並 `Documents.CloseAll`,所以 reset 後檔案不再開在編輯器、下次改磁碟不會再跳(XAE 重開 solution 時會還原上次的編輯視窗,不關就會再跳) |
| `Project.UnloadProject` / `ReloadProject` | 回「not available」、`GetItem` 為 null | 不可行,Automation Interface 沒有 reload 命令 |

`Reset-TcSolution [-SolutionPath <sln>] [-TimeoutSec 120]` 的步驟:(1) `Get-TcIdeModalDialog`:`Kind = reload-prompt` 就對該視窗(只接受自己 IDE pid 的)送 WM_CLOSE,等它消失(真機 2 s),`data.dismissedReloadPrompt = true`;其他 modal 回 `IDE_MODAL_DIALOG`,因為 `Solution.Close` 也會被擋。(2) `Documents.CloseAll(vsSaveChangesNo)`,`data.closedDocuments`。(3) `Solution.Close($false)`、釋放舊 `ITcSysManager`。(4) 在**同一個** `$dte` 上 `Solution.Open(<sln>)`(真機 7~9 s,`data.openSec`):`Connect-TcIde -SolutionPath` 不會接沒開 solution 的 IDE(那是別人的,見 PR #9),所以必須在手上這個實例重開。(5) `Connect-TcIde -SolutionPath <sln> -ProgId <同一個> -NoLaunch`,以 solution-match 接回同 pid、重取 `ITcSysManager`、重開 SilentMode(真機 12~13 s,`data.connectSec`);`data.sameIde` 回報。全程 `data.totalSec` 實測 22~25 s(2026-10-20 真機 10/10 PASS,含 reload 框跳著時呼叫的情境)。ADS 連線不受影響;`Enable-TcConfig` 後的 PLC 不受影響。solution 路徑由 `Connect-TcIde` / `Open-TcProject` 記住(`$script:TcSolutionPath`),`Disconnect-TcIde` 清掉。中途失敗時 `data.closed` / `data.reopened` 說明做到哪一步。

`Get-TcIdeModalDialog` 的結果現在多 `Kind`(`reload-prompt` / `unknown`),`IDE_MODAL_DIALOG` 結果多 `data.dialogKind`;MCP 的 `GetIdeModalDialog` 回 `data.dialog.kind`。`reload-prompt` 的 `error.hint` 直接寫這段流程。

## 驗證紀錄 2026-10-18

環境:32-bit XAE 4024 + 本機 UmRT_Default(AmsNetId 199.5.42.250.1.1)。

| 組 | 專案 | IDE | 結果 |
|---|---|---|---|
| A | 4024.71 專案 | 32-bit XAE Shell(`TcXaeShell.DTE.15.0`) | 完整 lifecycle 通過:Connect-TcIde → Build → Enable-TcConfig -Force → Connect-TcAds → Read/Write → Exit-TcPlcOnline |
| B | 4026.24 Robust 專案 | VS2022(`VisualStudio.DTE.17.0`) | Activate 後 target 回 `Target system reports a fatal error`(modal),未通過,原因待查 |

2026-10-19:空 UmRT(沒有 application)情況下,`Enable-TcConfig -Force` 以 `Login(REGULAR)`(=1)+ 全域 `SilentMode` 建立 app 並下載(26 s),lifecycle-smoke 37/37;`-NoLogin` 後直接 `Set-TcPlcState Run` 正確回 `PLC_NOT_LOADED`。同日 23:27 對照:`Login(257)`(REGULAR|SILENT)0.5 s 返回但不建 app、851 仍 Invalid;`Login(260)`(FORCEDOWNLOAD|SILENT)下載 28 s 成功,但下一輪 `ActivateConfiguration()` 耗 250 s 後失敗,實為 32-bit XAE OutOfMemory crash(Visu 引擎,事件 1026),與旗標無關;`Login(3)` 旗標互斥 abort。

這輪驗證修掉的問題:自啟 IDE 的 `MainWindow.Visible` race(留下孤兒 IDE)、ROT 撿到正在關閉的舊實例(`Solution.Open` 回 null)、`sysManagerAvailable` 在 solution 剛開時誤判 false、`Exit-TcPlcOnline` 在重啟後的舊路徑、`ADS_PORT_NOT_FOUND` hint 寫死 851、`Enter-TcPlcOnline` 訊息固定寫 download。

## 錯誤碼

### IDE_BUSY

- **現象**:任何走 COM 的 cmdlet(Build、Add-TcPou、Enter-TcPlcOnline…)回 `IDE_BUSY`。
- **為什麼**:XAE 正在顯示 modal dialog(license、「專案已修改」、build 確認)或在跑長操作,COM 回 `RPC_E_CALL_REJECTED`(0x80010001)或 `RPC_E_SERVERCALL_RETRYLATER`(0x8001010A)。模組已退避重試 1/2/4/8/16 秒(共約 31 秒)仍被拒。
- **下一步**:切到 XAE 關掉 dialog,重跑同一個 cmdlet。IDE COM 參考仍有效,不用 `Connect-TcIde`。常見 dialog 來源:license 試用到期提示、Activate 時的「Restart TwinCAT System」(用 `-Force` 走 ADS 就不會出現)。

### IDE_MODAL_DIALOG

- **現象**:`Build-TcProject`、`Enable-TcConfig`、`Enter-TcPlcOnline`、`Connect-TcIde`、`Reset-TcSolution` 回 `IDE_MODAL_DIALOG`,`data.dialogTitle` / `dialogText` 是視窗標題與內文,`data.dialogKind` 是分類:`reload-prompt`(磁碟改檔的 reload 提示,hint 指向 `Reset-TcSolution`,見「磁碟改檔的正確做法」)或 `unknown`。
- **為什麼**:XAE / VS 有 modal 視窗(見「已知 modal dialog」)。這類視窗不會讓 COM 回 `RPC_E_CALL_REJECTED`,而是讓 DTE 呼叫無限阻塞,retry 救不了,所以模組在每個主要 COM 步驟前先用 UI Automation 掃 IDE 程序(`data.ideProcessId`)的頂層視窗。
- **下一步**:手動處理 dialog 後重跑同一個 cmdlet;關不掉就 `Stop-Process -Id <ideProcessId>` 後重新 `Connect-TcIde -SolutionPath <sln>`。模組不會自動關閉任何視窗。
- **限制**:已經被 modal 擋住、正在阻塞中的呼叫無法從模組中斷;偵測靠視窗的 `IsModal` / `#32770` class / 已知標題,偵測不到時仍可能卡住。

### IDE_TIMEOUT

- **現象**:COM cmdlet 回 `IDE_TIMEOUT`,訊息含 `did not return within N s`。
- **為什麼**:`Invoke-TcComRetry -TimeoutSec`(預設 120 s;Build 600 s、Activate / Login 300 s)只是預期上限,同步呼叫無法被中斷;呼叫最後失敗返回時若已超過這個時間,就以 `IDE_TIMEOUT` 回報而不是原始錯誤(原始訊息附在後面)。
- **下一步**:看 XAE 有沒有 dialog 或長操作;必要時 kill IDE 後重新 `Connect-TcIde`。

### IDE_CRASHED

- **現象**:`Enable-TcConfig -Force` 的 Activate 卡 3~4 分鐘後回 `0x800706BE`,之後所有 COM 呼叫都失敗;模組現在回 `IDE_CRASHED`(`steps[]` 的 detail 保留原始訊息)。
- **確認**:事件檢視器 Application 日誌有 1026(.NET Runtime)且堆疊含 `_3S.CoDeSys.VisualEditor`(`OfflinePainting` / `VisuStylesWrapper` / `VisualizationStyle`),並有 1000/1001;`%LOCALAPPDATA%\CrashDumps\TcXaeShell.exe.<pid>.dmp`。
- **根因**:32-bit `TcXaeShell.exe`(15.0,exe 為 LARGEADDRESSAWARE)在第二次 Activate 時 `System.OutOfMemoryException`;crash 前 XAE 工作集約 1.27 GB。與 Login 旗標無關(`Login(260)` 那次 250 s 的「阻塞」就是這個 crash)。
- **處置**:重新 `Connect-TcIde -SolutionPath ...`,從 Build / `Enable-TcConfig` 開始。長流程在輪次間用 `Disconnect-TcIde -Quit` 離開 IDE,避免記憶體累積;`Enable-TcConfig` 會在 `data.ideMemoryMB` 回報 Activate 前的工作集,32-bit IDE 超過 1500 MB 時 `Write-Warning`。這是 32-bit XAE 加上 Visu 專案的組合才會發生。

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
- **注意**:`Get-TcSystemState` 不帶 `-AmsNetId` 時跟隨 IDE target(其次 ADS session);若 `data.netIdSource` 是 `local`,讀到的是本機 TcSysSrv(`127.0.0.1.1.1`)而非你的 target(例如 UmRT 已 Run 但本機顯示 Config),請先 `Connect-TcIde`。

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

- **為什麼**:成功與否依序判定:(a) `SolutionBuild.LastBuildInfo`(= build 失敗的專案數,回在 `data.failedProjects`)讀得到就用它(> 0 = 失敗);(b) 讀不到(`failedProjects = null`)就看 Error List:有任何**非 Library Manager** 的 Error(file 不像 `*Library Manager`、line > 0)就算失敗;(c) 兩者都讀不到 → `BUILD_STATUS_UNKNOWN`(見下)。TwinCAT 的 PLC 編譯訊息**不走** DTE(`ErrorList.ErrorItems.Count` 永遠 0、`OutputWindow.OutputWindowPanes` 空),所以模組用 UI Automation 讀 XAE 的 Error List 視窗(`Get-TcBuildErrors`),`data.errors` 是 Error List 的錯誤數,`data.errorItems[]` 是每筆 `{ severity, code, description, project, file, line, column }`,`data.codeErrors[]` 是其中排除 Library Manager 項目後的 PLC code 錯誤,`data.buildSucceeded` 是判定結果,`error.message` 含 codeErrors 數(括號補 Library Manager 數)與前 3 筆摘要。
- **下一步**:看 `data.codeErrors`(file + line 直接指到 POU),改 code 後 `Build-TcProject`。不要在沒改東西的情況下重跑 Build。`data.errorListError` 出現時表示 Error List 讀不到(見 `ERRORLIST_UNAVAILABLE`),`errors` 退回 `failedProjects`。

### BUILD_STATUS_UNKNOWN

- **為什麼**:`Build-TcProject` 的 build 呼叫有返回,但 `LastBuildInfo` 讀不到(COM 例外),而 Error List 也讀不到(或讀到的列 severity 無法判定:`data.severityUnknown`),所以無法判定 build 是成功還是失敗。`success = false`、`data.buildSucceeded = null`。以前這種情況會被當成 `failedProjects = 0` 回 success,現在不會。
- **下一步**:看 XAE 的 Error List 後再決定;處理 IDE 的 dialog(`Get-TcIdeModalDialog`)或讓 Error List 可見後重跑 `Build-TcProject`(或單獨 `Get-TcBuildErrors`)。
- **`code` 可能是 null**:TcXaeShell 15.0 的 Error List 沒有 Code 欄(右鍵表頭 Show Columns 只有 Severity / Description / Project / Project Rank / Path / File / Line / Column / Source),描述文字也不含 Cxxxx。模組只對幾個常見訊息推回編碼(C0046 `Identifier 'x' not defined`、C0018 `'x' is no valid assignment target`、C0032、C0035、C0037、C0077、C0080;表在 `Private/Get-TcIdeErrorList.ps1` 的 `$script:TcCompilerCodePatterns`),靜態分析訊息 `SAxxxx` 則直接在描述裡。
- **Build 成功時 `errorItems` 不一定空**:Error List 會留著非 PLC code 的項目。2026-10-18 實測 GantryCylinder 專案 build 成功仍有 7 筆 Error,全部是 `file = plc.Library Manager`、`line = 0` 的「Could not open library '#System_VisuElem3DPath' / '#System_VisuElemTrace' / '#System_VisuElemCamDisplayer' / '#System_VisuElemsAlarm' / '#System_VisuElemsDateTime'(placeholder 無法解析)」與「'#Analyzation' 3.5.2.0 / '#IecSfc' 3.4.2.0 has not been installed」——是機器上缺 visu/分析函式庫,不影響 `failedProjects`。用 `file` 分辨 PLC code 的錯誤。
- **XAE Build 會先存檔**:VS 的 Save all before build 預設開啟,`Write-TcPouCode` 後 `Build-TcProject` 會把 POU 寫進磁碟;要試錯請用複本。
- **Error List 的 UIA 結構(TcXaeShell 15.0,2026-10-18)**,改版時照這個找:
  ```
  Window '<sln> - TcXaeShell'
    Pane 'Error List' (ViewPresenter)
      ToolBar 'Error List'
        Button '9 Errors' / '8 Warnings' / '0 of 10 Messages'   ← Toggle pattern(過濾開關),最後一個數字 = 總數
      Pane 'Error List' (GenericPane) > Custom (WrapListView)
        DataGrid 'Tracking List View' (ListView; Scroll/Grid/Table pattern,虛擬化)
          Header 'Header Row' > HeaderItem aid=detailsexpander|errorseverity|text|projectname|documentname|line
          DataItem Name='Identifier 'nUndefinedVar_Test' not defined' (ListViewItem)
            Custom (ContentPresenter; GridItem/TableItem) > Image (severity 圖示,Name 無意義)
            Custom > Text 'Identifier ... not defined'   ← description
            Custom > Text 'plc'                          ← project
            Custom > Text 'MAIN_GantryCylinder.TcPOU'    ← file
            Custom > Text '567'                          ← line
  ```
  severity 圖示讀不出文字,所以模組依序只開一種過濾按鈕(TogglePattern)讀列、讀完還原;每列的欄位用 TableItemPattern 的 header AutomationId 對應;列表用 ScrollPattern 逐頁捲到 `VerticalScrollPercent` 不再變;以 description+project+file+line 去重。

### ERRORLIST_UNAVAILABLE

- **為什麼**:`Get-TcBuildErrors` 的 UI Automation 在 `-TimeoutSec`(預設 30 s)內找不到 Error List(視窗被關閉 / auto-hide、IDE pid 未知、UIA 被 modal dialog 卡住)。模組會先 `View.ErrorList` 把視窗叫出來,但 auto-hide 的視窗仍讀不到。
- **下一步**:確認 XAE 主視窗可見、Error List 釘住(不是 auto-hide);手動 View > Error List 後重跑;IDE 若有 dialog 先處理(`Get-TcIdeModalDialog`)。`Build-TcProject` 遇到這個情況不會失敗,只把 `data.errorListError` 設為此 code 並讓 `errors` 退回 `failedProjects`。

### SOLUTION_CLOSE_FAILED / NO_SOLUTION

- **現象**:`Reset-TcSolution` 回 `SOLUTION_CLOSE_FAILED`(`Solution.Close` COM 呼叫失敗;被 dialog 擋住時是 `IDE_MODAL_DIALOG` / `IDE_BUSY`)或 `NO_SOLUTION`(沒有開啟的 solution、也沒給 `-SolutionPath`)。
- **下一步**:`Get-TcIdeModalDialog` 看有沒有 dialog;`NO_SOLUTION` 就 `Connect-TcIde -SolutionPath <sln>`。關掉之後重開失敗時,結果保留 `Connect-TcIde` 的 code / hint,`data.closed = true` 表示 solution 已關、要自己重連。

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

- **為什麼**:`Enter-TcPlcOnline` 的 `ITcPlcIECProject::Login(PLC_LOGIN_FLAGS)` 失敗。系統在 Config 模式、上次 build 沒過、target 沒有 PLC license、跳出 dialog、或旗標互斥。
- **PLC_LOGIN_FLAGS**(TCatSysManagerLib):NONE=0、REGULAR=1、FORCEONLINECHANGE=2、FORCEDOWNLOAD=4、FORCECOMPILECODE=16、FORCEGENERATECODE=32、SILENT=256。模組:`-LoginMode Regular|Download|OnlineChange` 對應 1/4/2,**預設不 OR SILENT**;提示框靠 `Connect-TcIde` 開的全域 `ITcAutomationSettings.SilentMode`(用預設答案 Yes)處理,`-SilentFlag` 才會 OR 256。`Enable-TcConfig -Force` 的 login 步用 `-LoginMode Regular`(=1,XAE 自行決定是否下載;空 runtime 會建 app 並下載);只有 `Send-TcPlcProgram` 用 Download(=4),已登入且 PLC 在跑時再做 full download。
- **2026-10-19 實測(4024、32-bit XAE、空 UmRT)**:`Login(3)`=REGULAR|FORCEONLINECHANGE → XAE 回「Login aborted: Conflicting flag settings ('Regular' and 0x00000002)」(舊註解「3 = compile + suppress dialogs」是錯的,以前能跑只因 runtime 已有 app);`Login(1/2/4)` 在全域 SilentMode 沒開時會卡在「Application 'Port_851' does not exist ... create it and proceed with download?」;開 `ITcAutomationSettings.SilentMode` 後自動採預設 Yes,851 `Invalid → Stop`,lifecycle 37/37。
- **2026-10-19 23:27 旗標 SILENT 對照(全域 SilentMode 皆開)**:

  | Login 旗標 | 結果 |
  |---|---|
  | `1`(REGULAR) | 建 application + 下載 26 s,lifecycle 37/37 |
  | `257`(REGULAR\|SILENT) | 0.5 s 返回,**沒有**建 app / 下載,851 仍 Invalid |
  | `260`(FORCEDOWNLOAD\|SILENT) | 下載 28 s 成功;下一輪 Activate 時 32-bit XAE OOM crash(Visu 引擎,事件 1026),與旗標無關 |
  | `3`(REGULAR\|FORCEONLINECHANGE) | 旗標互斥 abort |

  結論:旗標 `SILENT(256)` 是「遇到要問的就跳過不做」,不是「用預設答案」;全域 `SilentMode` 才是「用預設答案(Yes)」。因此模組預設不加 256。
- **注意**:SilentMode 開啟時,對已在 Run 且程式不一致的 PLC 直接呼叫 `Enter-TcPlcOnline`,XAE 會自動採用 online change/download 提示的預設答案;要明確控制就帶 `-LoginMode Download` 或 `OnlineChange`。`Enable-TcConfig` 不受影響。
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
| Build 錯誤沒有編碼 | Error List 沒有 Code 欄,`errorItems[].code` 只對常見訊息推得(C0046 等),其餘 null | 用 description + file + line 判斷;需要編碼時查 InfoSys compiler errors |
| UmRT 假 Run | 本機 UmRT 跑約 30 分鐘後 task 可能停止循環,但 ADS 仍回 Run | 讀 `TwinCAT_SystemInfoVarList._TaskInfo[1].CycleCount` 兩次,沒動就重啟 `TcSystemServiceUm` 後 `Enable-TcConfig -Force` |
| Reset 殺 service | 對 UmRT 送 `Set-TcPlcState -State Reset` 會直接結束 `TcSystemServiceUm` | 不要對 UmRT 用 Reset;要清狀態改 Stop → `Enter-TcPlcOnline` 重新 download;真的 Reset 了就手動重啟 service |
| 重新 download 後 index offset 錯位 | symbol 的 indexGroup/indexOffset 在每次 download 後可能改變;舊 handle 會讀到別的變數 | 不快取 offset;懷疑錯位時比對 `TwinCAT_SystemInfoVarList._AppInfo.AppTimestamp` 是否變了,變了就重新 `Get-TcSymbols` |
| FB `VAR_INPUT` 寫不進去 | PLC 每個 scan 覆寫 FB 輸入 | 在 MAIN 宣告獨立變數餵 FB,寫 MAIN 層級變數 |

## 真機驗證腳本

`tests/Integration/` 的手動腳本需要真實環境:`bool-write.ps1`、`write-verify.ps1`、`list-symbols.ps1`、`full-cycle.ps1`、`lifecycle-smoke.ps1`、`login-logout.ps1`、`build-errors.ps1`(注入 C0046 錯誤驗證 `Build-TcProject` 的 `errorItems`,只對複本跑)、`reload-experiment.ps1`(磁碟改 .TcPOU 的 reload 行為,S0a/S0b/S2a/S2b/S3/S3b 六種情境,只對複本跑)。用法見 `tests/Integration/README.md`。
