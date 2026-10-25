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
      │  回 amsNetId、candidates[]、solutionPlatform / solutionConfiguration
      ▼
Set-TcTarget -AmsNetId <id> [-Platform <name>] (平台由 target 決定:UmRT / BSD = 'TwinCAT OS (x64)',
      │                                          Windows RT = 'TwinCAT RT (x64)';target 有 TARGETINFO
      │                                          就自動對齊,沒有(ADS 0x702)要帶 -Platform,只換 NetId
      │                                          用 -NoPlatformSwitch。切換前檢查 .tsproj 的 project
      │                                          platform,不符 → PLATFORM_PROJECT_MISMATCH)
      ▼
Build-TcProject [-ExpectedProject <PLC>]
      │  BUILD_FAILED → 看 data.errorItems(Error List 明細);BUILD_TIMEOUT → 看 dialog
      │  data.projects[] / coverageComplete;PLC project 沒在 Build 清單 → PROJECT_SKIPPED_BY_CONFIGURATION
      ▼
Enable-TcConfig -Force [-Platform <name>]
  ├─ platform check(先於 deadline):solution platform vs target(TARGETINFO)/ -Platform
  │    不一致 → 切換 + Build(steps platform-fix / platform-fix-build;-NoPlatformFix → PLATFORM_MISMATCH)
  │    兩者都沒有 → platformCheck = skipped + warning,照舊 Activate
  ├─ Set-TcSystemState Config     ┐
  ├─ ActivateConfiguration        │  每步輪詢到目標才進下一步
  │    LastBuildInfo > 0 → ACTIVATE_FAILED(Check config failed,停在這步)
  ├─ boot-package                 │  專案 _Boot vs target Boot(SHA-256)→ BOOT_PACKAGE_MISMATCH
  ├─ 等 port 10000 = Run 且停住   │  失敗回 steps[] 指出停在哪(SYSTEM_STATE_MISMATCH)
  ├─ 每個 PLC Enter-TcPlcOnline   │  (-NoLogin 跳過 login / Run)
  ├─ 等各 PLC port 可達           │  851、852…(PLC 節點 <AdsPort>)
  ├─ 各 PLC Run,等 = Run         │
  ├─ verify:讀回 10000 + 各 PLC  │  不是 Run / 有 modal → RUNTIME_STATE_MISMATCH
  └─ 若之前有 ADS 連線 → 自動重連 ┘
      ▼
Connect-TcAds                      (第一次;之後 cmdlet 自動重連)
      ▼
Read/Write/Watch-TcVariable、Invoke-TcTest
      ▼
Set-TcPlcState Stop / Exit-TcPlcOnline / Disconnect-TcAds
```

規則:

- **整個 lifecycle 在同一個常駐 PowerShell session(或 MCP server)裡跑**。每步開一個新的 `powershell.exe`:行程結束時 COM 參考被釋放,`Connect-TcIde` 啟動的 XAE 會跟著關,後面的 Activate / Login 失去同一個 IDE session(#32)。
- 多 PLC solution:`Enter-TcPlcOnline` / `Exit-TcPlcOnline` 要帶 `-PlcProjectPath <PLC 名稱>`(否則 `PLC_PROJECT_AMBIGUOUS`);`Enable-TcConfig -Force` 自己處理每個 PLC。
- port 851 只在 download 後存在;download 前 `Connect-TcAds -Port 851` 必回 `ADS_PORT_NOT_FOUND`。
- Activate 會重啟 TwinCAT XAR,所有既有 ADS 連線失效;IDE 的 COM 參考**不會**失效,不要重連 IDE。
- 不要用 `Start-Sleep` 猜等待時間;所有等待都已在 cmdlet 內輪詢(`-TimeoutSec` 可調)。
- `Invoke-TcTestCycle` 內部就是上面的流程,每步同樣 gating。
- `SetTargetNetId` 本身**不會**改 solution platform(實測,見「ACTIVATE_FAILED」的「platform 怎麼來的」)。`Set-TcTarget` 設完 NetId 後讀 target 的 TARGETINFO(見「Target platform(TARGETINFO)」),讀得到就自動切 solution platform;讀不到又沒給 `-Platform` → `PLATFORM_UNKNOWN`(NetId 已設好)。目前這台的 UmRT / Windows XAR 都回 0x702,所以換 target 或 tsproj 的 target 連不到時,要加 `-Platform`(或 `Enable-TcConfig -Platform`;`Connect-TcIde` 的 `data.solutionPlatform` 看現在是哪個)。見 `ACTIVATE_FAILED`。

## 環境矩陣

| IDE | ProgID | ADS DLL | 備註 |
|---|---|---|---|
| 32-bit XAE Shell | `TcXaeShell.DTE.15.0` | 4024:TwinCAT 安裝目錄下 Components\Base;4026:package | TwinCAT 4024 |
| 64-bit XAE Shell | `TcXaeShell.DTE.17.0` | 4026 package | TwinCAT 4026 |
| VS2022 + TwinCAT 整合 | `VisualStudio.DTE.17.0` | 4026 package | TwinCAT 4026(與 64-bit XAE Shell 同一套 XAE;需本機已有 VS2022) |

- 版本對應:32-bit XAE Shell(`TcXaeShell.DTE.15.0`)= **TwinCAT 4024**;64-bit XAE Shell(`TcXaeShell.DTE.17.0`)與 VS2022(`VisualStudio.DTE.17.0`)= 4026,後兩者是同一套 XAE。Runtime:本機只有一個 UmRT_Default,三種 IDE 共用;UmRT 本身沒有版本,它是本機安裝的 TwinCAT runtime 跑在 user mode(Usermode Runtime;`TcSystemServiceUm.exe` FileVersion 3.1.0.2649 / ProductVersion 3.1.4026.21 只是識別用;`TCATSysSrv` 4026.22)。
- Automation Interface(`ITcSysManager`、`EnvDTE`)在各組合完全相同;差別只在 IDE 抓取(ProgID)與 ADS DLL 位置。
- **4026 與 4024 的差異**(2026-10-20/21 B 組實測):
  - 相同:PLC 樹路徑 `TIPC^<plc>^<plc> Project^POUs`(例 `TIPC^Untitled1^Untitled1 Project`);`Login(1)` + `SilentMode`;ADS DLL(GAC `TwinCAT.Ads.dll` 4.3.32.0);三個 host 的 XAE Base extension 都是 3.1.4026.22。
  - 不同:(1) 實測 4026 XAE 在 Activate 時檢查 solution platform 與 target platform 是否一致,不一致 → `ACTIVATE_FAILED`(A 組 4024 XAE 沒觀察到這個檢查;這是觀察紀錄,不是選平台的規則:平台一律由 target 決定,UmRT(Usermode Runtime)是 `TwinCAT OS (x64)`)。(2) VS2022 的 `SolutionBuild.Build($true)`(等待)永遠不返回,模組改 `Build($false)` + 輪詢 `BuildState`(`Clean` 同理)。(3) VS2022 的訊息框是 WPF(見「已知 modal dialog」)。(4) zh-TW VS2022 的 Error List 視窗名 `錯誤清單`、預設 scope `目前專案` 會藏其他專案的列,模組自動切到 `整個方案`。
  - VS2022 時間參考:`Connect-TcIde` 自啟 1.5~2.3 s、含開 solution 總計 25~63 s;solution-match 重連 1~1.5 s;`Reset-TcSolution` 8~11 s。
- 實測紀錄(smoke / MCP / multi-ide 的 B 組結果)見「驗證紀錄」的「B 組 2026-10-20/21」。
- **Solution platform ≠ project platform**(專案設定,與 XAE 版本無關):平台由目標對象決定(UmRT / TwinCAT/BSD = `TwinCAT OS (x64)`,Windows RT = `TwinCAT RT (x64)`,CX ARM = 對應的 ARM 平台;[InfoSys TARGETINFO](https://infosys.beckhoff.com/content/1033/tc170x_tc3_usermode_runtime/11687997963.html)),但 solution platform 名稱可以對到別的 project platform。A 組 Festo .sln 的 solution `Release|TwinCAT OS (x64)` 底下 .tsproj 與 .plcproj 都對到 project platform `TwinCAT OS (ARMT2)` 且沒有 `Build.0`(ShouldBuild=False),選它什麼都不 build(實測:Build 1.4 s「成功」、Activate 不回 `ACTIVATE_FAILED`,851 維持 Invalid `PLC_NOT_LOADED`)。target platform 決定 configuration 編給哪種 target,Configuration Manager 決定子專案是否參與 build([InfoSys「Setting the TwinCAT target platform」](https://infosys.beckhoff.com/content/1033/tc3_automationinterface/650882187.html))。模組切換前檢查 .tsproj 的 project platform,不符就回 `PLATFORM_PROJECT_MISMATCH`(`data.platformMap`),見該節。
- `Connect-TcIde` 嘗試順序:`TcXaeShell.DTE.15.0` → `TcXaeShell.DTE.17.0` → `VisualStudio.DTE.17.0`;多實例時依 `-SolutionPath` 挑:只接已開該 sln 的實例(`data.selectedBy=solution-match`),沒有就啟動新實例(`launched`);別人開的空 IDE 或開著其他 sln 的 IDE 一律不碰,`Disconnect-TcIde -Quit` 也只關自己連上的那個 pid。`data.candidates[]` 列出所有看到的實例,`data.ideProcessId` 是連上的 IDE pid(`Get-TcIdeModalDialog` 只掃這個 pid 的視窗)。真機驗證:`tests/Integration/multi-ide.ps1`。ROT 裡正在關閉的舊實例(讀 `Version` / `Solution` 回 0x800706BA / 0x80004005)會被跳過。
- `Connect-TcIde` 自行啟動 IDE 時:`CreateInstance` 後**不碰** `MainWindow.Visible`(此時會丟 property not found),改輪詢 `Version` + `Solution`(500 ms,最長 60 s),就緒後設 `UserControl = $true` 讓 IDE 可見且不隨 COM 釋放關閉;逾時則 `Quit()` 並 kill 啟動時刻之後出現的 `TcXaeShell.exe` / `devenv.exe`,回 `IDE_LAUNCH_FAILED`。
- `Connect-TcAds` 的 `data.adsBackend` 顯示實際載入的 ADS 後端(DLL 路徑 / 反射 fallback)。
- `Enable-TcConfig -Force` 在 UmRT 上第一次需要 license 齊全(trial 要涵蓋專案用到的 TF),否則系統停在 Config 直到 `SYSTEM_STATE_TIMEOUT`。
- 換 target(本機 UmRT ↔ 遠端 CX)或換 IDE 後要重新 `Connect-TcIde`,AmsNetId 會變;solution platform 要對齊新 target 的平台(`Set-TcTarget` 讀得到 TARGETINFO 時自動,否則 `-Platform`)。
- **已知未解**:IDE 被 modal dialog 擋住時,它的 DTE `Version` 讀成空字串,`Connect-TcIde` 把該 ROT 項目當過期實例,帶 `-SolutionPath` 時會**另外啟動第二個 IDE**(VS2022 出現過一次)。重連前先 `Get-TcIdeModalDialog`(MCP `GetIdeModalDialog`)確認 IDE 沒被擋,有 dialog 先處理。

## 已知 modal dialog

與 `IDE_BUSY`(COM 回 0x80010001,可重試)不同,下面這些視窗讓 DTE 呼叫**無限阻塞**、永不返回。模組在 Build / Activate / Login / Solution.Open 之前用 UI Automation(`Get-TcIdeModalDialog`)檢查一次,有就回 `IDE_MODAL_DIALOG`;呼叫進行中另有 watchdog 每 2 s 掃一次,呼叫失敗返回時若看過 dialog 也回 `IDE_MODAL_DIALOG`。模組只偵測,唯一會主動回答的是 reload 提示(`Reset-TcSolution`,見下表);其他已經被卡住的呼叫無法中斷,只能手動關 dialog 或 kill IDE(本 session 啟動的 IDE 可用 `Disconnect-TcIde -Quit -Kill`)。

**中文 UI 的訊息框**:中文 Windows 上 XAE 的訊息框是 Win32 `#32770`,按鈕在 UIA 裡是 `ControlType.Pane`(ClassName `Button`,不是 `ControlType.Button`),Name 是「是(Y)」「否(N)」,AutomationId 是 control id 6 / 7(= `IDYES` / `IDNO`)。比對英文 "Yes" 或 `ControlType.Button` 一定失敗;模組(`Close-TcMessageBox`)對 Win32 訊息框只用 control id:`GetDlgItem(hwnd, 6)` + `BM_CLICK`(`SendMessageTimeout`,5 s),找不到按鈕才 post `WM_COMMAND`,語系無關。`Get-TcIdeModalDialog` 的 `Buttons`(MCP `data.dialog.buttons`)列出 `#32770` 的按鈕 `{id, name}`。

**VS2022 的訊息框是 WPF**(AutomationId `Microsoft.VisualStudio.MessageBox`,2026-10-21):內文在 AutomationId `Text` 的元素,按鈕是真的 `ControlType.Button`,AutomationId `OKButton` / `YesButton` / `NoButton` / `CancelButton`,**沒有** Win32 control id。`Get-TcIdeModalDialog` 回完整內文與按鈕(`Buttons[]` 多 `automationId`,MCP `data.dialog.buttons[].automationId`);`Close-TcMessageBox` 沒有 control id 時退到 UI Automation `InvokePattern.Invoke()`(回傳 `Method = UIA_INVOKE`,STA runspace、10 s 逾時),不依賴語系與 hwnd(`-Hwnd 0` 時依 AutomationId 在 IDE 主視窗下找)。所以「只靠 control id 回答」只適用 `#32770`。

| 視窗 | 何時出現 | 解法 |
|---|---|---|
| `Assertion Failed: Abort=Quit, Retry=Debug, Ignore=Continue` | Build 時 CODESYS 優化器處理 visu 元素的內部錯誤(NullReference / DivideByZero),**間歇性**:反覆開關 solution 後、或全新專案第一次全編譯都可能出;Clean 無效,清 `_CompileInfo` 也不保證 | 這個 modal 會讓 DTE 呼叫無限阻塞,只能 `Stop-Process` 該 IDE,重開 solution 再 Build(通常第二次就過) |
| Microsoft Visual Studio 帳戶設定 | VS2022 未登入時 | 登入一次,或手動關閉視窗 |
| `Target system reports a fatal error` | Activate 的設定在 target 上無法啟動。2026-10-18 B 組那次的根因是 **solution platform 錯**(`TwinCAT RT (x64)` 對 UmRT),見 `ACTIVATE_FAILED`;不是 license、isolated core(`<Settings NonWinCpus/Cpu CpuId>`)、tsproj `TcVersion`、UmRT `TargetFeatures.xml`(都試過、無影響) | 先 `Get-TcIdeInfo` 看 `solutionPlatform`,不對就 `Set-TcTarget -Platform`;再看 XAE Output / Error List,UmRT 其次才是 license 或 I/O 設定問題 |
| `Active solution platform 'TwinCAT RT (x64)' differs from current target platform 'TwinCAT OS (x64)'! Adjust solution platform and retry.`(WPF 訊息框) | 4026 Activate 時 solution platform 與 target platform 不一致。`SilentMode` 關閉時訊息框一直在、`ActivateConfiguration()` 阻塞到框被關(實測 102 s);`SilentMode` 開著(`Connect-TcIde` 預設)時 XAE 自動關框、`ActivateConfiguration()` 約 2 s 無例外返回,Output 只有「Check config failed!」 | `Enable-TcConfig` 以 `LastBuildInfo > 0` 偵測並回 `ACTIVATE_FAILED`;`Set-TcTarget -AmsNetId <id> -Platform 'TwinCAT OS (x64)'` 後重跑 Build + `Enable-TcConfig -Force` |
| Trial license security code | 7 天 trial 到期或首次啟用 | 需人工輸入驗證碼,模組無法代勞 |
| `Application 'Port_851' does not exist on device ... create it and proceed with download?` | 空 runtime 上 Login 時全域 `SilentMode` 沒開(例如沒經 `Connect-TcIde` 連線) | `Connect-TcIde` 連上就開 `ITcAutomationSettings.SilentMode`,XAE 自動答 Yes,不應再出現;手動點 Yes 即可。**不要**改用旗標 SILENT(257)壓框:它會跳過建 app,851 仍 Invalid |
| `Login aborted: Conflicting flag settings` | Login 旗標 3(REGULAR\|FORCEONLINECHANGE 互斥) | 不要用 3;用 `-LoginMode Regular\|Download\|OnlineChange`(1/4/2,不 OR SILENT) |
| `File has been changed outside the environment. Reload the new file?`(VS2022 寫法 `... changed outside the source editor. Do you want to reload it?`) | 開在編輯器裡的檔案(.TcPOU 等)被磁碟上的工具(AI 編輯器、git checkout、產生器)改了,約 1 s 後出現;VS 選項 `AutoloadExternalChanges` 壓不掉。沒開在編輯器的檔案 XAE 約 5 s 內自動重載、不跳框(2026-10-20 `reload-experiment.ps1`) | `Get-TcIdeModalDialog` 回 `Kind = reload-prompt`(結果 `data.dialogKind`),hint 指向 `Reset-TcSolution`,它會對這個提示送 WM_CLOSE、`Documents.CloseAll`、`Solution.Close`、同一個 IDE `Solution.Open`、`Connect-TcIde` 重連(約 20~25 s);之後改磁碟後立刻 `Reset-TcSolution` 即可。見「磁碟改檔的正確做法」 |
| `The project file '...\plc.plcproj' has been modified outside of TwinCAT XAE. Do you want to reload the project?` | `.plcproj` 在磁碟上被改寫(產生器每次都重寫,內容相同、只有 mtime 變也會跳);2026-10-20 gantry-watchdog dogfooding | `Get-TcIdeModalDialog` 回 `Kind = reload-prompt`、`ReloadTarget = project`(結果 `data.dialogKind` / `data.dialogReloadTarget`,MCP `data.dialog.reloadTarget`)。直接 `Reset-TcSolution`:它對這個提示按 **Yes**(Win32 框用 control id 6、VS2022 WPF 框用 UIA Invoke `YesButton`,皆語系無關),XAE 自己 reload 專案,模組只重新 `Connect-TcIde` 並用 `LookupTreeItem('TIPC')` 確認 `ITcSysManager` 可用,不做 close/reopen(`data.answeredYes = true`、`data.reopenedSolution = false`);按 Yes 失敗或探測失敗才退回 WM_CLOSE + close/reopen |
| `TwinCAT PLC Control`(class `#32770`) | 2026-10-18 經 MCP server 跑 `BuildProject` 時出現一次;成因未定,懷疑 OneDrive 檔案鎖或新啟動的 IDE 第一次 build。標題不在已知清單,靠 `#32770` class 偵測 | DTE 呼叫無限阻塞,等到 `BRIDGE_TIMEOUT`(Build 600 s)才 kill bridge;IDE 本身不會退出,只能 kill 該 IDE(MCP 結果的 `data.lastIde.ideProcessId` / `error.hint` 會給 pid 與 `taskkill` 指令),重新 `ConnectIde` 再 Build |

## 磁碟改檔的正確做法(.TcPOU / .TcGVL / .plcproj 直接改檔案)

`Write-TcPouCode` / `Add-TcPou` 走 COM(`ITcSmTreeItem.DeclarationText` / `ImplementationText`)寫進 IDE 的編輯 buffer,**不會**跳框,優先用它;但磁碟檔案**不會**立刻更新(真機:mtime/hash 不變、`Document.Saved = false`),要到存檔或 Build 的 Save all before build 才落地,要讓磁碟同步就接著 `Build-TcProject`。AI 或其他工具直接改磁碟上的檔案時,決定一切的是「該檔案有沒有開在 XAE 的文件視窗」(2026-10-20 `tests/Integration/reload-experiment.ps1`,4024 32-bit XAE,log 在 `tests/Integration/logs/reload-S*.log`):

| 情境 | XAE 行為 | 正確做法 |
|---|---|---|
| 檔案**沒有**開在編輯器 | 約 5 s 內自動偵測並重載,`Get-TcPouCode` 讀到新內容、Build 用新檔;不跳任何框 | 改完等 5 s 再呼叫 DTE(或直接 `Reset-TcSolution` 確保一致) |
| 檔案**開著** | 約 1 s 後跳 modal「File has been changed outside the environment. Reload the new file?」,所有 DTE 呼叫阻塞;`Tools > Options > Environment > Documents > AutoloadExternalChanges` 壓不掉 | 改完**立刻** `Reset-TcSolution`:提示已經跳出來也沒關係,它會先把提示關掉(`dismissedReloadPrompt = true`),並 `Documents.CloseAll`,所以 reset 後檔案不再開在編輯器、下次改磁碟不會再跳(XAE 重開 solution 時會還原上次的編輯視窗,不關就會再跳) |
| `.plcproj` 被改寫(產生器、git checkout) | 跳 modal「The project file ... has been modified outside of TwinCAT XAE. Do you want to reload the project?」(`reload-prompt`、`ReloadTarget = project`),內容相同也會跳 | 改完**立刻** `Reset-TcSolution`:它對 project 提示按 Yes,XAE 自己 reload 專案,只重連不 close/reopen,比檔案提示的流程快(`data.answeredYes = true`、`data.reopenedSolution = false`);若同時還有 .TcPOU 的檔案提示,它會接著關掉並走完整 close/reopen |
| `Project.UnloadProject` / `ReloadProject` | 回「not available」、`GetItem` 為 null | 不可行,Automation Interface 沒有 reload 命令 |

`Reset-TcSolution [-SolutionPath <sln>] [-TimeoutSec 120]` 的步驟:(1) `Get-TcIdeModalDialog`(連續出現的 reload 提示最多處理 5 個):`ReloadTarget = project` 就按 Yes(`Close-TcMessageBox -Answer Yes`,等最多 15 s 消失,`data.answeredYes = true`);`ReloadTarget = file`(或 Yes 失敗的 project 提示)就對該視窗(只接受自己 IDE pid 的)送 WM_CLOSE,等它消失(真機 2 s);兩者都設 `data.dismissedReloadPrompt = true`、`data.reloadTarget`;其他 modal 回 `IDE_MODAL_DIALOG`,因為 `Solution.Close` 也會被擋。只按過 Yes(沒有用 WM_CLOSE 關過檔案提示)時跳過 (2)~(4),直接 (5) 重連並探測 `LookupTreeItem('TIPC')`,成功就回傳(`data.reopenedSolution = false`),探測失敗才繼續 (2)~(5)。(2) `Documents.CloseAll(vsSaveChangesNo)`,`data.closedDocuments`。(3) `Solution.Close($false)`、釋放舊 `ITcSysManager`。(4) 在**同一個** `$dte` 上 `Solution.Open(<sln>)`(真機 7~9 s,`data.openSec`):`Connect-TcIde -SolutionPath` 不會接沒開 solution 的 IDE(那是別人的,見 PR #9),所以必須在手上這個實例重開。(5) `Connect-TcIde -SolutionPath <sln> -ProgId <同一個> -NoLaunch`,以 solution-match 接回同 pid、重取 `ITcSysManager`、重開 SilentMode(真機 12~13 s,`data.connectSec`);`data.sameIde` 回報。全程 `data.totalSec` 實測 22~25 s(2026-10-20 真機 10/10 PASS,含 reload 框跳著時呼叫的情境)。ADS 連線不受影響;`Enable-TcConfig` 後的 PLC 不受影響。solution 路徑由 `Connect-TcIde` / `Open-TcProject` 記住(`$script:TcSolutionPath`),`Disconnect-TcIde` 清掉。中途失敗時 `data.closed` / `data.reopened` 說明做到哪一步。

`Get-TcIdeModalDialog` 的結果現在多 `Kind`(`reload-prompt` / `unknown`)、`ReloadTarget`(`file` / `project` / `$null`)與 `Buttons`,`IDE_MODAL_DIALOG` 結果多 `data.dialogKind` / `data.dialogReloadTarget` / `data.dialogButtons` 與 `data.dialog`(`{title, text, kind, reloadTarget, buttons}`);MCP 的 `GetIdeModalDialog` 回 `data.dialog.kind` / `reloadTarget` / `hwnd` / `buttons`。`reload-prompt` 的 `error.hint` 直接寫這段流程。VS2022 WPF 訊息框(見上)的 `Buttons[]` 多 `automationId`,`text` 是完整內文。

## 驗證紀錄 2026-10-18

環境:32-bit XAE 4024 + 本機 UmRT_Default(AmsNetId 199.5.42.250.1.1)。

| 組 | 專案 | IDE | 結果 |
|---|---|---|---|
| A | 4024.71 專案 | 32-bit XAE Shell(`TcXaeShell.DTE.15.0`) | 完整 lifecycle 通過:Connect-TcIde → Build → Enable-TcConfig -Force → Connect-TcAds → Read/Write → Exit-TcPlcOnline |
| B | 4026.24 Robust 專案 | VS2022(`VisualStudio.DTE.17.0`) | Activate 後 target 回 `Target system reports a fatal error`(modal),未通過。**根因已查明(issue #16):solution platform 錯**,見下「B 組 2026-10-20/21」與 `ACTIVATE_FAILED` |

2026-10-19:空 UmRT(沒有 application)情況下,`Enable-TcConfig -Force` 以 `Login(REGULAR)`(=1)+ 全域 `SilentMode` 建立 app 並下載(26 s),lifecycle-smoke 37/37;`-NoLogin` 後直接 `Set-TcPlcState Run` 正確回 `PLC_NOT_LOADED`。同日 23:27 對照:`Login(257)`(REGULAR|SILENT)0.5 s 返回但不建 app、851 仍 Invalid;`Login(260)`(FORCEDOWNLOAD|SILENT)下載 28 s 成功,但下一輪 `ActivateConfiguration()` 耗 250 s 後失敗,實為 32-bit XAE OutOfMemory crash(Visu 引擎,事件 1026),與旗標無關;`Login(3)` 旗標互斥 abort。

這輪驗證修掉的問題:自啟 IDE 的 `MainWindow.Visible` race(留下孤兒 IDE)、ROT 撿到正在關閉的舊實例(`Solution.Open` 回 null)、`sysManagerAvailable` 在 solution 剛開時誤判 false、`Exit-TcPlcOnline` 在重啟後的舊路徑、`ADS_PORT_NOT_FOUND` hint 寫死 851、`Enter-TcPlcOnline` 訊息固定寫 download。

### B 組 2026-10-20/21(4026)

環境:TwinCAT 3.1.4026.22 XAE;專案 RobustSolutionFrameworkDemo 4026.24 的複本(`C:\Temp\RobustDemo-b`),PLC 專案 `Untitled1`;target 本機 UmRT_Default(199.5.42.250.1.1)。原專案在 4026 編不過(`FB_AxisControl.M_CheckAxisInfo` 指派未宣告的 `alarm`,C0046 / C0018),只在複本修;這是專案問題,不是工具問題。

| Run | IDE / ProgId | 結果 | 備註 |
|---|---|---|---|
| `lifecycle-smoke.ps1 -SolutionPlatform 'TwinCAT OS (x64)'`(log `tests/Integration/logs/B-vs2022.log`) | VS2022 Community 17.x zh-TW,`VisualStudio.DTE.17.0` | 35/35 PASS,77 s | Connect launch 1.6 s / 總計 30.2 s;Build 9.2 s(build 本身 6 s);Enable -Force 8.4 s;ADS DLL GAC `TwinCAT.Ads.dll` 4.3.32.0(同 4024);無 dialog |
| 同參數(log `B-xae64.log`) | 64-bit XAE Shell `TcXaeShell.DTE.17.0` | 35/35 PASS(第 3 次跑) | launch 6.8~8.7 s / connect 40~85 s;3 次 Activate 的 `ideMemoryMB` 931/936/935;第 1 次撞 UmRT crash #8、第 2 次撞 UmRT ADS 0x502「Mailbox is full」hang(見「已知限制」),都是 UmRT 側 |
| MCP `node mcp-server/scripts/lifecycle-client.mjs --expect-fail ACTIVATE_FAILED --fail-platform "TwinCAT RT (x64)" --platform "TwinCAT OS (x64)"` | VS2022 | 7/7 PASS | `RunLifecycle` 用 RT → `ACTIVATE_FAILED` 47 s(含啟動 IDE);用 OS 14.4 s(Connect 0.5 / SetTarget 1.5 / Build 3.8 / Enable 8.4 / ConnectAds 0.05 s);`TaskInfo[1].CycleCount` 319 → 420(1 s);`DisconnectIde Quit`,沒殘留 IDE / bridge |
| `multi-ide.ps1 -ProgId VisualStudio.DTE.17.0`,target RobustDemo-b;干擾:A = 32-bit XAE 開 TcReloadTest、B = 空 32-bit XAE、C = 空 VS2022 | `VisualStudio.DTE.17.0` | 25/25 PASS | target 是新啟動的(沒接 C)、A 的 modal 不會算到 target、只關 target |
| platform 切換檢查(直接 PowerShell) | VS2022 | RT → `ACTIVATE_FAILED` 4.7 s;OS → Run 10.9 s;未知 platform → `PLATFORM_NOT_FOUND` | 失敗 Activate 留下的 `LastBuildInfo` 會被下一次成功的 Activate 重設 |

`ACTIVATE_FAILED`(issue #16)根因與驗證細節見該錯誤碼。

### #28 / #32 沒成功卻回 success(2026-10-21,4026 + VS2022,本機 UmRT 199.5.42.250.1.1)

測試 solution:`RobustSolutionFrameworkDemo` 複本加第二個 PLC `FrameworkUnitTest`(port 852),`tests/Integration/false-success.ps1`。

| 情境 | 結果 |
|---|---|
| 移除 FrameworkUnitTest 的 `Build.0` → `Build-TcProject` | success,`coverageComplete = false`,FrameworkUnitTest `skipped`,`warningCode = PROJECT_SKIPPED_BY_CONFIGURATION` |
| 同上 `-ExpectedProject FrameworkUnitTest` | `success = false`、`PROJECT_SKIPPED_BY_CONFIGURATION`,沒開始 Build |
| 同上 `-ExpectedProject Untitled1` | success,`coverageComplete = false` |
| 多 PLC `Enable-TcConfig -Force` | success:activate 4.0 s(獨立執行緒)、boot-package 6 檔 SHA-256 相同、851 / 852 各自 login + Run、verify 讀回全 Run |
| `Enter-TcPlcOnline` / `Exit-TcPlcOnline` 不帶路徑 | `PLC_PROJECT_AMBIGUOUS` |
| `Exit-TcPlcOnline -PlcProjectPath FrameworkUnitTest` | success,`adsPort = 852` |
| port 852 讀 `MAIN.sAlias`(T_MaxString)、`MAIN.stAddr.port`、`_AppInfo.ProjectName` / `AdsPort`、`_TaskInfo[1].FirstCycle` | 全部是 scalar(alias STRING 依 ADS data type id 解碼) |
| `Set-TcSystemState Run`(原本 Run) | success,`leftOriginal = true`,`latencyMs = 1411` |
| `Set-TcSystemState Run`,另一個行程在進 Run 0.8 s 後送 Reconfig(模擬退回 Config) | `SYSTEM_STATE_MISMATCH`,trace `+7ms Run, +772ms Unreachable, +1555ms Config` |
| target Boot 的 CurrentConfig 換回前一版、保留新 Port_852.app,`Set-TcSystemState Run` | system 進 Run 並停住,但 851 / 852 Invalid:只看 system state 會誤判,`Enable-TcConfig` 的 verify 擋得下 |
| 鎖住 target `Boot\CurrentConfig.xml` 後 Activate(舊版程式碼) | `ActivateConfiguration()` 掛 17 分鐘;因此加了 `ACTIVATE_TIMEOUT`(mock 測試 `tests/Unit/activate-timeout.ps1` 6/6) |
| lifecycle-smoke B(VS2022,RobustDemo-b,`TwinCAT OS (x64)`) | 37/37 |
| lifecycle-smoke A(32-bit XAE 4024,TcFestoNoVisu) | 34/34 |

## 錯誤碼

### IDE_BUSY

- **現象**:任何走 COM 的 cmdlet(Build、Add-TcPou、Enter-TcPlcOnline…)回 `IDE_BUSY`。
- **為什麼**:XAE 正在顯示 modal dialog(license、「專案已修改」、build 確認)或在跑長操作,COM 回 `RPC_E_CALL_REJECTED`(0x80010001)或 `RPC_E_SERVERCALL_RETRYLATER`(0x8001010A)。模組已退避重試 1/2/4/8/16 秒(共約 31 秒)仍被拒。
- **下一步**:先 `Get-TcIdeModalDialog -ProcessId <data.ideProcessId>`(MCP `GetIdeModalDialog ProcessId=...`)看是哪個視窗(`reload-prompt` → `Reset-TcSolution`),切到 XAE 關掉 dialog,重跑同一個 cmdlet。IDE COM 參考仍有效,不用 `Connect-TcIde`。常見 dialog 來源:license 試用到期提示、Activate 時的「Restart TwinCAT System」(用 `-Force` 走 ADS 就不會出現)。
- **`Connect-TcIde -SolutionPath` 回 `IDE_BUSY`(#29)**:開著這個 sln 的 IDE 被認出來(證據見「IDE_MODAL_DIALOG」的 #29 條目),但它拒絕 DTE 呼叫而且 UI Automation 找不到 dialog。強證據(`module-state` / `session-record` / `dialog-path`)時,沒有 dialog 也會回 `IDE_BUSY` 並 attach(`data.attached = true`);只有標題、證據矛盾、或兩個 IDE 都符合時不 attach(hint `IDE_BLOCKED_SAME_NAME`,見該節)。兩種情況都**不另開 IDE**(有沒有 `-NoLaunch` 都一樣),`data.ideProcessId` / `rotDisplayName` / `windowTitle` / `matchedBy` / `probe` / `notAttachedReason` 說明判斷依據。等它忙完(或關掉 dialog)再重跑同一個 `Connect-TcIde`;確定那不是你的 IDE 就加 `-LaunchIfBlocked` 另開。

### IDE_BLOCKED_SAME_NAME

- **碼與 hint**:hint key;錯誤碼是 `IDE_MODAL_DIALOG`(有 dialog)或 `IDE_BUSY`(沒有 dialog),`error.message` 以 `IDE_BLOCKED_SAME_NAME:` 開頭,`data.attached = false`。
- **為什麼(#29)**:`Connect-TcIde -SolutionPath` 找不到開著這個 .sln 的可讀 IDE,有個被擋住的 IDE 可能開著它,但證據不夠或互相矛盾(`data.notAttachedReason`):只有主視窗標題同名、session record / module-state 與標題或 dialog 路徑矛盾,或兩個 IDE 都有強證據(見「IDE_MODAL_DIALOG」的 #29 條目)。可能就是你的 IDE,也可能是別處的同名複本(實測 2026-10-25,4024 32-bit XAE Shell:別的 agent 的 `C:\Temp\Pou-A\TwinCAT_Festo.sln` 被 runtime 的 fatal error 擋住時就這樣)。模組不另開 IDE、也不 attach。
- **下一步**:是你的 → 關掉 `data.dialog`(`Get-TcIdeModalDialog -ProcessId <data.ideProcessId>`)後重跑同一個 `Connect-TcIde`;確定不是你的 → `Connect-TcIde -SolutionPath <sln> -LaunchIfBlocked`(MCP `ConnectIde LaunchIfBlocked=true`)另開一個。

### IDE_MODAL_DIALOG / IDE_MODAL_DIALOG_RELOAD

- **碼與 hint**:錯誤碼都是 `IDE_MODAL_DIALOG`;`IDE_MODAL_DIALOG_RELOAD` 只是 `kind = reload-prompt` 時用的 hint key(`error.hint` 指向 `Reset-TcSolution`)。
- **現象**:`Build-TcProject`、`Enable-TcConfig`、`Enter-TcPlcOnline`、`Connect-TcIde`、`Reset-TcSolution` 回 `IDE_MODAL_DIALOG`(`Disconnect-TcIde -Quit` 遇到 modal 回的是 `IDE_QUIT_FAILED`,見下),`data.dialogTitle` / `dialogText` 是視窗標題與內文,`data.dialogKind` 是分類:`reload-prompt`(磁碟改檔的 reload 提示,hint 指向 `Reset-TcSolution`,見「磁碟改檔的正確做法」)或 `unknown`;`data.dialogReloadTarget` 區分 `file`(.TcPOU 等開著的檔案,「File has been changed outside the environment」)與 `project`(.plcproj 被改寫,「The project file ... has been modified outside of TwinCAT XAE. Do you want to reload the project?」)。
- **為什麼**:XAE / VS 有 modal 視窗(見「已知 modal dialog」)。這類視窗不會讓 COM 回 `RPC_E_CALL_REJECTED`,而是讓 DTE 呼叫無限阻塞,retry 救不了,所以模組在每個主要 COM 步驟前先用 UI Automation 掃 IDE 程序(`data.ideProcessId`)的頂層視窗。`Build-TcProject` 輪詢 `BuildState` 期間也每輪掃,build 中跳出的 dialog 回這個碼(不再等到逾時)。
- **下一步**:先 `Get-TcIdeModalDialog`(MCP `GetIdeModalDialog`)看 `kind`:`reload-prompt`(兩種 target 都算)→ 直接 `Reset-TcSolution`(project 提示按 Yes、檔案提示 WM_CLOSE + close/reopen);其他手動處理 dialog 後重跑同一個 cmdlet,關不掉就 `Disconnect-TcIde -Quit -Kill`(只限本 session 啟動的 IDE)或 `Stop-Process -Id <ideProcessId>`,再重新 `Connect-TcIde -SolutionPath <sln>`。除了 reload 提示,模組不會自動關閉任何視窗。
- **限制**:已經被 modal 擋住、正在阻塞中的呼叫無法從模組中斷;偵測靠視窗的 `IsModal` / `#32770` class / 已知標題,偵測不到時仍可能卡住。
- **`Connect-TcIde -SolutionPath` 遇到被 modal 擋住的 IDE(#29)**:以前 ROT 探測讀不到被擋住那個 IDE 的 solution,就把它跳過:帶 `-NoLaunch` 回 `IDE_NOT_FOUND`(更舊的版本回 `PROJECT_OPEN_FAILED` null-valued expression),不帶就**再開一個 IDE** 開同一個 .sln。實測 2026-10-25(4024 32-bit XAE Shell,磁碟改寫 `plc.plcproj` 觸發 XAE「The project file ... has been modified outside of TwinCAT XAE」):被擋住時 `DTE.Version` 回**空字串**(不是 `RPC_E_CALL_REJECTED`)。現在對讀不到(忙碌或回空值)、pid 已知的 ROT 項目不呼叫 COM,module-state / session-record 必須**沒有矛盾、而且有當下事實佐證**(標題以 solution 名稱開頭,或 dialog 路徑在資料夾內)才算強證據;依序看四種證據:(0) 模組自己上一次連的就是這個行程且是同一個 .sln(`module-state`);(1) session record:先前任何一次 `Connect-TcIde` 成功連上同一個行程(pid + 啟動時間)並開著這個 .sln(`%LOCALAPPDATA%\TwinCATAutomation\ide-solutions.json`,每次帶 solution 連線成功就寫;記錄是別的 .sln 就排除),`matchedBy = session-record`;(2) UI Automation 掃到的 dialog 內文路徑落在 .sln 資料夾內(`dialog-path`;路徑都在別處就排除);(3) 主視窗標題以 solution 名稱開頭(`window-title`,弱證據)。符合就回 `IDE_MODAL_DIALOG`(`data.ideProcessId`、`rotDisplayName`、`windowTitle`、`matchedBy`、`probe`、`attached`、`data.dialog`),**不另開 IDE**。(1)(2) 是強證據:模組連線同時指向該 IDE(`attached = true`),接著 `Get-TcIdeModalDialog` / `Reset-TcSolution` 可以直接用(reload 提示 → `Reset-TcSolution` 按 Yes 後自己重連);只有 (3) 時不 attach(`attached = false`,理由見「IDE_BUSY」);關掉 dialog 後重跑同一個 `Connect-TcIde` 就是 `solution-match`。只回空值而沒有 dialog 的 IDE 視為正在關閉,照舊跳過。 **證據互相矛盾時不 attach**:session record / module-state 可能過期(例如在 GUI 換開別的 solution),所以 dialog 內文的專案檔都在別處,或標題非空卻不以 solution 名稱開頭時,降成弱證據;`Open-TcProject` / `New-TcProject` 換 solution 時也會更新 record。module-state 比對 pid **和**啟動時間(pid 重用不算)。兩個以上 IDE 都有強證據時一個都不 attach(`data.blockedCandidates` 全列)。失敗的 `Connect-TcIde` 不會留下上一個 IDE 的連線(`TcDte` 等一律清掉),所以 hint 叫你接 `Reset-TcSolution` 時只會作用在 attach 的那個 IDE。限制:dialog 內文的路徑以文字比對(`GetFullPath` 後),8.3 短檔名與 UNC 路徑不會展開,可能比不出 `inside`。

### IDE_QUIT_FAILED

- **現象**:`Disconnect-TcIde -Quit` 回 `success: false`、`IDE_QUIT_FAILED`;`data.quit = false`,`data.quitError` 是原因(`modal dialog is up: <title>`,或 `DTE.Quit: ... RPC_E_CALL_REJECTED`);有 modal 時 `data.dialog = {title, text, kind, reloadTarget}`,`data.solutionClosed`、`data.ideProcessId`、`data.selectedBy`、`data.ownedBySession` 照給。**IDE 行程還活著**。
- **為什麼**:IDE 被 modal dialog 擋住或忙碌,`Solution.Close` / `DTE.Quit` 失敗。以前這種情況回 `success: true`,AI 以為 IDE 已關,下一個 `Connect-TcIde` 又以 solution-match 黏回同一個被擋住的 IDE(2026-10-20 dogfooding B3)。
- **下一步**:有 modal(`data.dialog`)時連線仍在:`kind = reload-prompt` → `Reset-TcSolution`,再 `Disconnect-TcIde -Quit`;其他 dialog 或 DTE.Quit 失敗 → 這個 IDE 是本 session 啟動的(`data.ownedBySession = true`)就 `Disconnect-TcIde -Quit -Kill`(`Stop-Process -Force` 後等最多 10 s,`data.killed = true`);否則自己 `Stop-Process -Id <data.ideProcessId>`。`-Kill` 之後 10 s 行程還在也回這個碼(`killed = false`)。
- 呼叫 `-Quit` 前若已偵測到 modal dialog,模組不會白跑 60 s 的 `Solution.Close` retry,直接回 `IDE_QUIT_FAILED`(`data.dialog`、`data.quit = false`、`data.disconnected = false`),而且**什麼都不釋放**:DTE / `ITcSysManager` / 連線狀態原封不動(quit 根本沒嘗試,DTE 仍有效),所以可以接 `Reset-TcSolution` 再 `-Quit`,或 `-Quit -Kill`;加 `-Kill` 則直接走 kill。
- **狀態保留**:真的嘗試過 quit(或走 kill)的路徑會釋放 COM 參考,但失敗時(`IDE_QUIT_FAILED`、`IDE_NOT_OWNED`)模組保留 IDE 的 pid / `selectedBy` / solution 路徑,所以可以**直接**接 `Disconnect-TcIde -Quit -Kill`,不用(也沒辦法,modal 還在)重新 `Connect-TcIde`。成功 quit / kill、不帶 `-Quit` 的 disconnect、或下一次 `Connect-TcIde` 才會清掉。kill 前會確認該 pid 仍是 `TcXaeShell` / `devenv`,且啟動時間與 `Connect-TcIde` 記下的相同(±2 s);不是(pid 被回收)就不殺、忘掉該 pid,回 `IDE_QUIT_FAILED`(`killed = false`)。pid 已經不存在(IDE 自己結束了)則回 `success: true`、`killed = false`、`alreadyExited = true`。
- `-Kill` 看的是 `data.ownedBySession`(本 session 啟動的 IDE),`Reset-TcSolution` 內部重連後 `selectedBy` 會變成 `solution-match`,但 `ownedBySession` 仍為 true,`-Kill` 照樣允許。

### IDE_NOT_OWNED

- **現象**:`Disconnect-TcIde -Quit -Kill` 回 `IDE_NOT_OWNED`,`data.ownedBySession = false`(`data.selectedBy` 例如 `solution-match`)。
- **為什麼**:`-Kill` 只殺本 session 用 `Connect-TcIde` 啟動的 IDE,不殺使用者自己開的 IDE。`Reset-TcSolution` 重連到同一個 pid 時仍算 launched。
- **下一步**:確定要關就自己 `Stop-Process -Id <data.ideProcessId>`,再重新 `Connect-TcIde -SolutionPath <sln>`。`data.quitError` 說明 quit 為什麼失敗。再呼叫一次 `-Quit -Kill` 結果不變(仍 `IDE_NOT_OWNED`)。

### IDE_LAUNCH_FAILED

- **現象**:`Connect-TcIde` 找不到可接的 IDE、自己啟動一個,但 60 s 內 DTE 沒有就緒,回 `IDE_LAUNCH_FAILED`(啟動的行程會被收掉,不留孤兒)。
- **為什麼**:XAE / VS 卡在首次啟動精靈、帳戶登入視窗、license 提示,或該 ProgId 對應的 IDE 沒裝好。
- **下一步**:手動開一次該 IDE 確認能正常進到主畫面;或改用 `-ProgId` 指定另一個 IDE,或先手動開好 IDE(含 solution)再 `Connect-TcIde -SolutionPath <sln>`。

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

### ADS_SYMBOL_NOT_FOUND / SYMBOL_NOT_FOUND(ADS 0x710)

- **碼**:`Read-TcVariable` 把 `ADS_SYMBOL_NOT_FOUND` 回成 `SYMBOL_NOT_FOUND`(相容舊碼),hint 相同。
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

- **為什麼**:`Set-TcSystemState` 透過 ADS WriteControl 要求切換後,輪詢 port 10000 在 `-TimeoutSec` 內沒到目標狀態。原因:TwinCAT System Service 報錯(license、config 錯)、UmRT service 掛掉、或 target 無回應。UmRT 還有一種:process 活著、CPU idle,但對 199.5.42.250.1.1 的每個 ADS 呼叫都回 **0x502「Mailbox is full」**(本機 TcSysSrv 正常)→ `Enable-TcConfig` 等 180 s 回 `SYSTEM_STATE_TIMEOUT`(2026-10-21 實測,見「已知限制」)。若 target 是 UmRT 且剛 Activate 就停在 Config,常見原因是 license 不足(trial 未涵蓋專案用到的 TF),請在 XAE 的 License 節點確認。
- **下一步**:`Get-TcSystemState` 看現在的狀態;看 XAE 的 TwinCAT 圖示、License 節點與 Windows 事件檢視器;UmRT 重啟 `TcSystemServiceUm`(0x502 的唯一解法;重啟後停在 Config,再 `Enable-TcConfig -Force`)。

  UmRT 重啟指令(process 卡死時先 `Stop-Process` 舊的 `TcSystemServiceUm`;`cmd /c` 執行時 `%TWINCAT3DIR%` 不會展開):

  ```powershell
  Start-Process "$env:TWINCAT3DIR\Runtimes\bin\TcSystemServiceUm.exe" `
      -ArgumentList '-t bin -i path -n "UmRT_Default" -c .\3.1' `
      -WorkingDirectory 'C:\ProgramData\Beckhoff\TwinCAT\3.1\Runtimes\UmRT_Default'
  ```

### SYSTEM_STATE_MISMATCH

- **為什麼**:`Set-TcSystemState` 看到 port 10000 到了目標狀態,但接下來 `-SettleSec`(預設 3 s,每 250 ms 取樣)內離開過、或最後讀回不同(`data.stateTrace`、`data.readbackState`)。典型:runtime 進 Run 後因 PLC 啟動失敗退回 Config(#32:port 852 的 application 與 symbol description 不同版,ADS 1809)。以前只要瞬間看到 Run 就回 success。
- **送出的 AdsState**:Run → `Reset`(2)、Config → `Reconfig`(16),`data.sentAdsState` / `sentAdsStateCode` 回報實際送出的值。[InfoSys TwinCAT.Ads `AdsState`](https://infosys.beckhoff.com/content/1033/tc3_ads.net/9408236299.html):Reset = 2、Run = 5、Config = 15、Reconfig = 16「System should restart in config mode」。哪個值讓 port 10000 重啟進 Run,InfoSys 未記載,實測(2026-10-21 本機 UmRT,`TcSystemServiceUm.exe` 3.1.0.2649):`Run`(5) 回 ADS 0x701「Service is not supported by server」;`Reset`(2) 0.3 s 斷線 → Stop → 1.3 s 到 Run;`Reconfig`(16) → Stop → 1.1 s 到 Config。所以「requestedState = Run、送 Reset」是設計,不是不一致。
- **下一步**:`Get-TcIdeModalDialog` 看 XAE 有沒有「Target system reports a fatal error」;看 XAE Error List;本機 runtime 比對 Boot package(`Enable-TcConfig -Force` 會自動做,見 `BOOT_PACKAGE_MISMATCH`)。
- **原狀態 = 目標**(Run → Run 重啟、Config → Config):送出後必須先看到 port 10000 離開該狀態(別的狀態或連不上,每 100 ms 讀,最多 10 s)才開始等目標;看不到就是 `SYSTEM_STATE_MISMATCH`(`data.leftOriginal = false`),不把舊狀態當成重啟完成。data 另有 `originalState`、`finalState`、`reached`、`held`、`latencyMs`。
- **授權診斷**:`SYSTEM_STATE_TIMEOUT` / `SYSTEM_STATE_MISMATCH` 且狀態是 Config 時,讀 target 的授權伺服器(ADS port 30,[InfoSys AmsPort「R0_LicenseServer 30」](https://infosys.beckhoff.com/content/1033/tc3_ads.net/9408352011.html);同樣的資料 PLC 端用 [FB_GetLicenses](https://infosys.beckhoff.com/content/1031/tcplclib_tc2_utilities/1876715915.html) 讀)。有過期或無效的授權就寫進 `error.hint` 開頭,清單在 `data.licenses`(name / expires / status / valid / expired);讀不到就略過,不會變成新錯誤。index group(0x01010006 有效、0x0101000A 無效、0x0101000C 名稱)InfoSys 未記載,是實測(本機 UmRT:9 個 trial 授權,到期 2026-10-25)。

### RUNTIME_STATE_MISMATCH

- **為什麼**:`Enable-TcConfig -Force` 前面每一步都過了,最後的 `verify` 步驟讀回 port 10000 不是 Run、某個 PLC port(851、852…)不是 Run,或 IDE 有 modal dialog(`data.finalCheck = { systemState, plcs[], dialog, ok }`)。多 PLC solution 以前只看 851,852 起不來也回 success。
- **data.diagnostics**(Activate 之後任何一步失敗都會附):`dialog`(modal 標題/內文)、`errorList`(XAE Error List 前 10 筆錯誤描述;有 dialog 時不讀)、`bootPackage`(重新比對一次)。
- **下一步**:看 `diagnostics`;Boot package 不一致見下;dialog 是 fatal error 時看 Error List 的訊息(例如「The loaded symbol description does not match the plc application」)。

### BOOT_PACKAGE_MISMATCH

- **為什麼**:Activate 後專案 `_Boot\<platform>` 與 target Boot 目錄的檔案不一致,代表 Activate 沒把新 configuration 寫到 target,runtime 會用舊 package 啟動。比對 `CurrentConfig.xml`、`CurrentConfig.tszip`、`CurrentConfig\*.tpzip`、`Plc\Port_*.app`(只比本機 package 有的檔;target 多出來的 tpzip 列在 `extraOnTarget`,不算不一致),`data.bootPackage.files[]` 每檔有 local / target 的 `size`、`lastWriteTime`、`sha256`。
- **只對本機 runtime**:UmRT 依 `%ProgramData%\Beckhoff\TwinCAT\3.1\Runtimes\<name>\3.1\TcRegistry.xml` 的 `AmsNetId`(BIN,`C7052AFA0101` = 199.5.42.250.1.1)找到 `<name>\3.1\Boot`(InfoSys 未記載,實測);本機 XAR 是 `%ProgramData%\Beckhoff\TwinCAT\3.1\Boot`([InfoSys 4026 起的 Boot 目錄](https://infosys.beckhoff.com/content/1033/tc3_grundlagen/4291093003.html),4026 前是 `C:\TwinCAT\3.1\Boot`)。遠端 target `status = unavailable`,不阻擋流程。
- **實測**(2026-10-21,4026 + VS2022,本機 UmRT):正常 Activate 後 6 個檔(2 個 CurrentConfig、2 個 tpzip、Port_851.app、Port_852.app)SHA-256 全相同。把 target 的 CurrentConfig 三個檔換回前一版、保留新的 Port_852.app 後 `Set-TcSystemState -State Run`:system 照樣進 Run 並停住,但 851 / 852 都是 Invalid(PLC 沒載入)→ 只看 system state 會誤判,`Enable-TcConfig -Force` 由 `verify` 擋下。
- **下一步**:重跑 `Enable-TcConfig -Force`(Activate 會重寫 Boot);仍不一致時先備份 target Boot 目錄,再把 `_Boot\<platform>` 的上述檔案複製過去並比對 SHA-256。模組只讀不寫,不會自動覆寫 target 檔案。

### ACTIVATE_TIMEOUT

- **為什麼**:`ActivateConfiguration()` 在 `-ActivateTimeoutSec`(預設 180 s;`-Force` 時再受 `-TimeoutSec` 剩餘時間限制)內沒返回。以前這個 COM 呼叫在呼叫端執行緒同步執行,`Invoke-TcComRetry` 的 `-TimeoutSec` 只能在呼叫「失敗返回後」歸類成 `IDE_TIMEOUT`,中斷不了:2026-10-21 實測 target Boot 檔被鎖住時掛了 17 分鐘,VS2022 最後被 Windows 判定沒回應關掉,UmRT 也一起消失。現在 Activate 在另一個 STA runspace 執行(依 IDE pid 從 Running Object Table 取同一個 DTE,`Solution.Projects(i).Object` 取 `ITcSysManager`),主執行緒限時等待、每 2 s 掃 modal;逾時就放棄等待(呼叫本身停不掉,XAE 內部可能還在跑)。
- **data.activateDiagnostics**:`dialog`(modal 標題/內文)、`ideAlive`、`ideResponding`(Windows 的「沒有回應」)、`runtimeAlive`(本機 UmRT 的 `TcSystemServiceUm.exe` 是否還在;非本機 UmRT 為 null)、`systemState`(port 10000 的 AdsState 或 unreachable)、`elapsedSec`。
- **下一步**:依診斷處理:dialog → 處理視窗;`ideResponding = false` → `Disconnect-TcIde -Quit -Kill`(本 session 啟動的)後重新 `Connect-TcIde`;`runtimeAlive = false` → 照 `SYSTEM_STATE_TIMEOUT` 的指令重啟 UmRT 後 `Enable-TcConfig -Force`。

### ADS_SYMBOL_VERSION_INVALID(ADS 0x711 / 1809)

- **為什麼**:[InfoSys ADS Return Codes](https://infosys.beckhoff.com/content/1033/tc3_c/374277003.html):0x711 = `ADSERR_DEVICE_SYMBOLVERSIONINVALID`「Invalid symbol version. This can occur due to an online change. Create a new handle.」;Activate 後出現時通常是 PLC application 與 symbol description 不同版(#32)。
- **下一步**:`Connect-TcAds` 重取 handle;Activate 後才出現就看 `Enable-TcConfig` 的 `data.bootPackage` / `diagnostics`。

### CYCLE_TIMEOUT

- **現象**:`Enable-TcConfig -Force` 回 `CYCLE_TIMEOUT`,訊息 `exceeded -TimeoutSec N s before step '<step>'`。
- **為什麼**:`-TimeoutSec`(預設 120 s)是整個 lifecycle 的總預算,每一步開始前檢查剩餘時間;用完就停在那一步之前,不再往下做。
- **下一步**:看 `data.steps` 卡在哪一步;用 `Get-TcSystemState` / `Get-TcPlcState` 確認目前狀態,加大 `-TimeoutSec` 後重跑 `Enable-TcConfig -Force`。

### PLC_RUN_TIMEOUT

- **現象**:`Set-TcPlcState -State Run`(或 `Enable-TcConfig -Force` 的 PLC Run 步)回 `PLC_RUN_TIMEOUT`(Stop / Reset 對應的是 `STATE_SET_FAILED`)。
- **為什麼**:送出 Run 後 PLC 在 `-TimeoutSec` 內沒有進入 Run(PLC 例外、程式沒載入、runtime 狀態不對)。
- **下一步**:`Get-TcPlcState` 看目前狀態;Error / Stop 就檢查 PLC 例外或 Build 錯誤,再 `Enter-TcPlcOnline` 後重試;851 是 Invalid 見 `PLC_NOT_LOADED`。

### PLC_PROJECT_NOT_FOUND

- **現象**:`Enter-TcPlcOnline` / `Exit-TcPlcOnline` / `Get-TcPouCode` / `Write-TcPouCode` / `Enable-TcConfig` 回 `PLC_PROJECT_NOT_FOUND`。
- **為什麼**:`TIPC` 下找不到 `<Plc> Project` 節點(solution 沒有 PLC 專案、`-PlcProjectPath` 名稱打錯,或剛 Activate / 重啟後樹還沒就緒)。
- **下一步**:`Get-TcProjectTree -PlcOnly` 確認 PLC 名稱(`data.plcProjects` 列出候選),`-PlcProjectPath` 給 PLC 名稱(`FrameworkUnitTest`)或樹路徑(`TIPC^FrameworkUnitTest^FrameworkUnitTest Project`);剛重啟可重試一次。

### PLC_PROJECT_AMBIGUOUS

- **為什麼**:`Enter-TcPlcOnline` / `Exit-TcPlcOnline` 沒給 `-PlcProjectPath`,solution 卻有多個 PLC project。以前直接拿 `TIPC` 的第一個 child,多 PLC 時登入/登出錯的 PLC(#32)。
- **下一步**:`-PlcProjectPath FrameworkUnitTest`(PLC 名稱)、`TIPC^FrameworkUnitTest` 或 `TIPC^FrameworkUnitTest^FrameworkUnitTest Project` 都可以;`data.plcProjects` 列出 name / projectPath / adsPort。ADS port 取自 PLC 節點 `ProduceXml` 的 `<AdsPort>`(InfoSys 未記載,實測 851 / 852)。

### PROJECT_SKIPPED_BY_CONFIGURATION

- **為什麼**:solution Build 只編 active solution configuration 裡勾了 Build 的 project(.sln 的 `{guid}.<Config>|<Platform>.Build.0`)。PLC project 少了這行時 XAE 默默跳過、仍顯示 Build succeeded,Port 852 的產物還是舊的(#28)。`Build-TcProject` 在 Build 前讀 DTE `Solution.SolutionBuild.ActiveConfiguration.SolutionContexts`,每個 `.plcproj` 看 `ShouldBuild`([Microsoft Learn: SolutionContext.ShouldBuild](https://learn.microsoft.com/en-us/previous-versions/visualstudio/visual-studio-2013/1a52ztxh(v=vs.120))「whether the current project is built when the solution configuration associated with this SolutionContext is selected」),不解析 .sln 文字。
- **回傳**:`data.projects[]`(name、uniqueName、configuration、platform、shouldBuild、status = `built` / `skipped` / `failed` / `unknown`)、`data.skippedProjects[]`、`data.coverageComplete`(每個 PLC project 都是 built 才是 true)。沒帶 `-ExpectedProject`:success 照 build 結果,另外 `data.warningCode = PROJECT_SKIPPED_BY_CONFIGURATION` + `data.warning`(也會 Write-Warning)。帶 `-ExpectedProject FrameworkUnitTest` 且它被跳過:不開始 Build,直接 `success = false`、這個 code。
- **solution Build、單一 project Build、compiler coverage 的差別**:solution Build(`Build-TcProject`)= 只編 `ShouldBuild = true` 的 project;單一 project Build(XAE 右鍵 Build / `SolutionBuild.BuildProject`)不受 Build.0 影響;compiler coverage = 這次 Build 實際編到哪些 PLC,看 `data.projects[].status`。
- **下一步**:XAE Configuration Manager 把該 PLC project 的 Build 勾起來並存檔(會補回 Build.0),再 `Build-TcProject -ExpectedProject <name>`。

### EXPECTED_PROJECT_NOT_FOUND / BUILD_COVERAGE_UNKNOWN

- **EXPECTED_PROJECT_NOT_FOUND**:`-ExpectedProject` 的名稱不是這個 solution 的 PLC project(比對 .plcproj 檔名,不含副檔名;也收 `TIPC^<Plc>`),沒有開始 Build。用 `data.projects` 的 name。
- **BUILD_COVERAGE_UNKNOWN**:帶了 `-ExpectedProject` 但無法確認它有被編到:SolutionContexts 讀不到(`data.coverageError`),或 Build 結果不是成功、Error List 又沒有那個 project 的列(status `unknown`)。不要當成 Build 成功。

### BUILD_FAILED / BUILD_FAILED_COMPILE

- **碼與 hint**:錯誤碼是 `BUILD_FAILED`;`BUILD_FAILED_COMPILE` 是讀到 Error List 錯誤列時用的 hint key(看 `data.errorItems`)。
- **為什麼**:成功與否依序判定:(a) `SolutionBuild.LastBuildInfo`(= build 失敗的專案數,回在 `data.failedProjects`)讀得到就用它(> 0 = 失敗);(b) 讀不到(`failedProjects = null`)就看 Error List:有任何**非 Library Manager** 的 Error(file 不像 `*Library Manager`、line > 0)就算失敗;(c) 兩者都讀不到 → `BUILD_STATUS_UNKNOWN`(見下)。TwinCAT 的 PLC 編譯訊息**不走** DTE(`ErrorList.ErrorItems.Count` 永遠 0、`OutputWindow.OutputWindowPanes` 空),所以模組用 UI Automation 讀 XAE 的 Error List 視窗(`Get-TcBuildErrors`),`data.errors` 是 Error List 的錯誤數,`data.errorItems[]` 是每筆 `{ severity, code, description, project, file, line, column }`,`data.codeErrors[]` 是其中排除 Library Manager 項目後的 PLC code 錯誤,`data.buildSucceeded` 是判定結果,`error.message` 含 codeErrors 數(括號補 Library Manager 數)與前 3 筆摘要。
- **下一步**:看 `data.codeErrors`(file + line 直接指到 POU),改 code 後 `Build-TcProject`。不要在沒改東西的情況下重跑 Build。`data.errorListError` 出現時表示 Error List 讀不到(見 `ERRORLIST_UNAVAILABLE`),`errors` 退回 `failedProjects`。

### BUILD_STATUS_UNKNOWN

- **為什麼**:`Build-TcProject` 的 build 呼叫有返回,但 `LastBuildInfo` 讀不到(COM 例外),而 Error List 也讀不到(或讀到的列 severity 無法判定:`data.severityUnknown`),所以無法判定 build 是成功還是失敗。`success = false`、`data.buildSucceeded = null`。以前這種情況會被當成 `failedProjects = 0` 回 success,現在不會。
- **下一步**:看 XAE 的 Error List 後再決定;處理 IDE 的 dialog(`Get-TcIdeModalDialog`)或讓 Error List 可見後重跑 `Build-TcProject`(或單獨 `Get-TcBuildErrors`)。
- **`code` 可能是 null**:TcXaeShell 15.0 的 Error List 沒有 Code 欄(右鍵表頭 Show Columns 只有 Severity / Description / Project / Project Rank / Path / File / Line / Column / Source),描述文字也不含 Cxxxx。模組只對幾個常見訊息推回編碼(C0046 `Identifier 'x' not defined`、C0018 `'x' is no valid assignment target`、C0032、C0035、C0037、C0077、C0080;表在 `Private/Get-TcIdeErrorList.ps1` 的 `$script:TcCompilerCodePatterns`),靜態分析訊息 `SAxxxx` 則直接在描述裡。
- **Build 成功時 `errorItems` 不一定空**:Error List 會留著非 PLC code 的項目。2026-10-18 實測 GantryCylinder 專案 build 成功仍有 7 筆 Error,全部是 `file = plc.Library Manager`、`line = 0` 的「Could not open library '#System_VisuElem3DPath' / '#System_VisuElemTrace' / '#System_VisuElemCamDisplayer' / '#System_VisuElemsAlarm' / '#System_VisuElemsDateTime'(placeholder 無法解析)」與「'#Analyzation' 3.5.2.0 / '#IecSfc' 3.4.2.0 has not been installed」——是機器上缺 visu/分析函式庫,不影響 `failedProjects`。用 `file` 分辨 PLC code 的錯誤。
- **XAE Build 會先存檔**:VS 的 Save all before build 預設開啟,`Write-TcPouCode` 後 `Build-TcProject` 會把 POU 寫進磁碟;要試錯請用複本。
- **Warning 也讀得到內容**(2026-10-20):`Build-TcProject` 的 `data.warningItems[]`(與 errorItems 同格式)與 `data.codeWarnings[]`(排除 Library Manager 項),`Get-TcBuildErrors` 的 `-IncludeWarnings` 預設開(`-IncludeWarnings:$false` 省 1~2 s 的 toggle)。之前 `warnings=1` 卻沒有項目,就是這個開關沒開。按鈕計數的 regex 也認 zh-TW 的「3 個錯誤 / 1 個警告 / 2 則訊息」。
- **zh-TW VS2022 也讀得到**(2026-10-21,取代舊註記「需英文 UI」):窗格名 `錯誤清單`(英文 UI 是 `Error List`);摘要按鈕是 `0 / 2 錯誤` 的「顯示 / 總數」形式,取總數;VS2022 的 Error List 預設 scope 是 `目前專案`(Current Project),會藏其他專案的列,模組讀之前先切到 `整個方案`(Entire Solution)。其他語系仍回 `ERRORLIST_UNAVAILABLE`。
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

### BUILD_TIMEOUT

- **現象**:`Build-TcProject` 回 `BUILD_TIMEOUT`,`data.buildState` / `data.buildSec` 是逾時時的 `SolutionBuild.BuildState` 與已耗秒數。
- **為什麼**:VS2022 上 `SolutionBuild.Build($true)`(wait)**永遠不返回**,所以模組改 `Build($false)` 再每輪輪詢 `BuildState`(到 3 = Done)。新增 `-TimeoutSec`(預設 600)是輪詢上限;逾時時 `BuildState` 還沒到 Done。輪詢期間也掃 modal dialog:有就回 `IDE_MODAL_DIALOG`,不會拖到逾時。成功時 `data.buildSec` 是 `Build($false)` 到 Done 的秒數(VS2022 實測 6 s、首次含啟動約 9 s)。
- **下一步**:`Get-TcIdeModalDialog` 看有沒有 dialog;看 XAE Output 視窗的 build 進度;大型專案加大 `-TimeoutSec` 重跑 `Build-TcProject`;XAE 沒反應就 kill IDE 後重新 `Connect-TcIde`。`Clear-TcProject` 與 `multi-ide.ps1` 的 `Clean` 同樣是 `Clean($false)` + 輪詢。

### CLEAN_TIMEOUT

- **現象**:`Clear-TcProject` 回 `CLEAN_TIMEOUT`,`data.buildState` / `data.cleanSec` 是逾時時的 `SolutionBuild.BuildState` 與已耗秒數。
- **為什麼**:`Clean($false)` 之後 `BuildState` 在 `-TimeoutSec`(預設 300)內沒到 3 = Done([vsBuildState](https://learn.microsoft.com/en-us/dotnet/api/envdte.vsbuildstate))。輪詢期間每 ~5 s 掃一次 modal,有 dialog 會回 `IDE_MODAL_DIALOG`,不會拖到逾時。
- **下一步**:`Get-TcIdeModalDialog` 看有沒有 dialog;沒有就加大 `-TimeoutSec` 重跑 `Clear-TcProject`;XAE 沒反應就 kill IDE 後重新 `Connect-TcIde -SolutionPath <sln>`。

### CLEAN_UNVERIFIED

- **現象**:`Clear-TcProject` 回 `CLEAN_UNVERIFIED`:`BuildState` 到了 Done,但 `SolutionBuild.LastBuildInfo` 讀不到(`data.failedProjects = $null`)。
- **為什麼**:Clean 是否成功只能從 `LastBuildInfo`(失敗的 project 數)確認;讀不到就不回 success(CODING_STANDARDS 2),沒有參數可以放行。
- **下一步**:`Get-TcIdeModalDialog` 看有沒有 dialog,重跑 `Clear-TcProject`;仍讀不到就 `Reset-TcSolution` 後再試。

### CLEAN_LIBRARY_UNRESOLVED

- **碼與 hint**:hint key;錯誤碼是 `LIBRARY_UNRESOLVED`(`Clear-TcProject`,與 PR #44 的 `Build-TcProject` 同名同規則)。
- **現象**:Clean 回報有 project 失敗(`LastBuildInfo` > 0),Error List 的錯誤全是「Could not open library ...」(file `<plc>.Library Manager`、沒有行號,`data.libraryErrorItems`)。
- **為什麼**:library 解析不到時 PLC 程式碼可能根本沒編譯、Build 卻照樣回 success(#45,實測 2026-10-25,4024 32-bit XAE Shell,去掉 Visu library 的 Festo 複本),所以預設回失敗。
- **下一步**:在 XAE Library Manager 安裝缺的 library 後重跑;確定要接受(例如刻意缺 library 的測試複本)才用 `Clear-TcProject -AllowUnresolvedLibrary`(MCP `CleanProject AllowUnresolvedLibrary=true`):success,但 `data.cleanVerified = false`、`data.warningCode = LIBRARY_UNRESOLVED`。

### RESET_SOLUTION_MISMATCH

- **現象**:`Reset-TcSolution` 沒有動作,`data.openSolution` 與 `data.expectedSolution` 不同。
- **為什麼(#29)**:`Connect-TcIde` 可能依 session record 等證據 attach 了一個被擋住的 IDE;關掉 dialog 後讀得到的 `Solution.FullName` 若不是模組以為的 solution(模組最後連到 / 開啟的那個;沒有就用 `-SolutionPath`),關閉它會動到別人的工作,所以在 `Documents.CloseAll` / `Solution.Close` 之前就停下。`-SolutionPath` 指定另一個 .sln(換開)不算不一致:比對的是 IDE 目前開的與模組預期的。
- **下一步**:`Connect-TcIde -SolutionPath <你的 sln>` 連到正確的 IDE(找不到就加 `-LaunchIfBlocked`),再 `Reset-TcSolution`。

### CLEAN_FAILED

- **現象**:`Clear-TcProject` 回 `CLEAN_FAILED`:`data.failedProjects` > 0(Clean 完 `SolutionBuild.LastBuildInfo`,[失敗的 project 數](https://learn.microsoft.com/en-us/dotnet/api/envdte.solutionbuild.lastbuildinfo)),或 DTE 的 `Solution` / `SolutionBuild` 連續 15 s 都是 `$null`(`data.nullReads`),或 `Clean` / `BuildState` 的 COM 呼叫失敗。
- **為什麼(#18)**:lifecycle-smoke 的 `03a-clean` 以前在模組 scope 直接呼叫 `$script:TcDte.Solution.SolutionBuild.Clean(...)`,兩次在 `Connect-TcIde` 成功後 0.2 s 內丟「不可在值為 Null 的運算式上呼叫方法」(實測 2026-10-19、2026-10-20,4024 32-bit XAE Shell,log `A-login1-silentmode-final.log`、`master-1717e3e-run2.log`)。哪一段是 `$null`(`$script:TcDte`、`Solution` 或 `SolutionBuild`)log 沒記,**原因未確認**:同一秒的 `02b-verify-target` 用的是 `$script:TcSysManager`,不能證明 `TcDte` 非 null;較可能是剛開好 solution 的 XAE 短暫回 `$null`(`Connect-TcIde` 最後重讀 `Version` / `Solution.FullName` 也看過空值,實測,見其註解)。改用 `Clear-TcProject` 之後 2026-10-25 連跑 A 組(4024)、B 組(4026 VS2022)各 3 輪,`03a` 6/6 PASS,`data.nullReads` 全是 0(沒有重現)。`Clear-TcProject` 先輪詢到 `Solution` / `SolutionBuild` 都有值才 Clean,`$null` 有出現時 `data.nullReads` 會記下次數,再發生就能定位。
- **Library Manager 錯誤**:`LastBuildInfo` > 0 而 Error List 全是 library 解析失敗時回 `LIBRARY_UNRESOLVED`(見「CLEAN_LIBRARY_UNRESOLVED」),`-AllowUnresolvedLibrary` 才放行成 success + `warningCode`;`LastBuildInfo` 讀不到回 `CLEAN_UNVERIFIED`。實測 2026-10-25,4024 32-bit XAE Shell:去掉 Visu library 的 Festo 複本開好 solution 後第一次 Clean `LastBuildInfo = 1`,Error List 7 筆都是這種;Build 後再 Clean 是 0;4026 VS2022 RobustDemo 一律 0。其他錯誤、或 Error List 讀不到,是 `CLEAN_FAILED`。
- **下一步**:看 XAE Output 視窗;剛 `Connect-TcIde` 完就再跑一次 `Clear-TcProject`,仍失敗就 `Reset-TcSolution` 後再試。腳本不要再直接用模組內部的 `$script:TcDte` 做 Clean。

### ERRORLIST_UNAVAILABLE

- **為什麼**:`Get-TcBuildErrors` 的 UI Automation 在 `-TimeoutSec`(預設 30 s)內找不到 Error List(視窗名要是 `Error List` 或 zh-TW VS2022 的 `錯誤清單`,其他語系找不到;視窗被關閉 / auto-hide、IDE pid 未知、UIA 被 modal dialog 卡住)。模組會先 `View.ErrorList` 把視窗叫出來,但 auto-hide 的視窗仍讀不到。
- **下一步**:確認 XAE 主視窗可見、Error List 釘住(不是 auto-hide);手動 View > Error List 後重跑;IDE 若有 dialog 先處理(`Get-TcIdeModalDialog`)。`Build-TcProject` 遇到這個情況不會失敗,只把 `data.errorListError` 設為此 code 並讓 `errors` 退回 `failedProjects`。

### SOLUTION_CLOSE_FAILED / NO_SOLUTION

- **現象**:`Reset-TcSolution` 回 `SOLUTION_CLOSE_FAILED`(`Solution.Close` COM 呼叫失敗;被 dialog 擋住時是 `IDE_MODAL_DIALOG` / `IDE_BUSY`)或 `NO_SOLUTION`(沒有開啟的 solution、也沒給 `-SolutionPath`)。
- **下一步**:`Get-TcIdeModalDialog` 看有沒有 dialog;`NO_SOLUTION` 就 `Connect-TcIde -SolutionPath <sln>`。關掉之後重開失敗時,結果保留 `Connect-TcIde` 的 code / hint,`data.closed = true` 表示 solution 已關、要自己重連。

### PROJECT_OPEN_FAILED

- **為什麼**:`Open-TcProject` / `Connect-TcIde -SolutionPath` 開 .sln 失敗。路徑錯、檔案損壞、或連到的 IDE 沒有 TwinCAT 整合(例如抓到沒裝 TwinCAT 的 VS)。
- **下一步**:確認路徑;指定 `-ProgId` 對應正確的 IDE(見環境矩陣)。開著這個 .sln 的 IDE 被 modal 擋住時現在回 `IDE_MODAL_DIALOG` / `IDE_BUSY`,不再是這個碼(#29,見「IDE_MODAL_DIALOG」)。

### POU_NOT_FOUND

- **現象**:`Get-TcPouCode` / `Write-TcPouCode` 回 `POU_NOT_FOUND`。(`PLC_PROJECT_NOT_FOUND` 是 TIPC 下找不到 `<Plc> Project` 節點,處理方式相同。)
- **為什麼**:4024 與 4026 的 PLC 樹格式相同:`TIPC^<Plc>^<Plc> Project^POUs^<name>`(DUT 在 `^DUTs^`、GVL 在 `^GVLs^`)。不給 `-PouPath` 時依序試 `<Plc> Project^POUs^<name>`、`<Plc> Project^<name>`,最後遞迴走 project 子樹(深度 4)比對名稱;給了 `-PouPath` 但找不到也會改用名稱自動找。都沒命中才回此碼。
- **下一步**:`error.message` 列出試過的路徑(`data.tried[]`),`error.hint` 說明格式並列出 `<Plc> Project` 第一層子節點(例如 `POUs, DUTs, GVLs, VISUs`,另見 `data.projectChildren[]`)。用 `Get-TcProjectTree -PlcOnly` 查節點 `path` 後給 `-PouPath`。與 `POU_READ_FAILED` / `POU_WRITE_FAILED` 不同:後兩者只在 COM 例外(例如讀 DeclarationText 失敗)時回,代表 POU 找到了但存取失敗。

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

- **為什麼**:`Write-TcVariable` 無法把值轉成 symbol 的型別(對 `UINT` 寫 `-1` 或 `2.5`、對 `BOOL` 寫 `"yes"`、對 `TIME` 寫 `DT#…`、enum 成員名拼錯),或 symbol 是 STRUCT/ARRAY(不支援整筆寫)。`error.message` 說明原因,`hint` 列出支援型別。
- **下一步**:`Get-TcSymbols` 看 `type`(enum 會列 `enumValues`);TIME/TOD 給 IEC 字面 `T#6s`、`T#1m30s500ms`、`TOD#12:30:00`(整數 ms 也收),LTIME 給 `LTIME#1us`(或 ns),DATE/DT 給 `D#2026-10-20`、`DT#2026-10-20-12:30:00` 或 ISO 8601(或 UNIX 秒),enum 給整數或成員名;STRUCT 改寫個別成員(`stPar.fMax`)。`data.written` 是實際寫入的轉換值(數值型回數值;時間類回正規化字面,`T#6000ms` → `T#6s`,另附 `ms`/`ns`/`unix`),enum 另回 `name`。

### ACTIVATION_FAILED

- **為什麼**:`ActivateConfiguration()` COM 呼叫失敗。專案有錯誤、target 沒 license、I/O 配置與硬體不符、或跳出 dialog。
- **下一步**:Build 成功、IDE 無 dialog 後重跑;看 `data.steps[]` 停在哪一步。
- 與 `ACTIVATE_FAILED` 不同:`ACTIVATION_FAILED` 是 COM 呼叫本身丟例外;`ACTIVATE_FAILED` 是呼叫無例外返回、但 XAE 的 Check config 失敗。

### ACTIVATE_FAILED

- **現象**:`Enable-TcConfig`(含 `-Force` 流程,停在 activate 那一步,`data.steps[]` 看得到;`data.solutionPlatform` 是當時的 active solution platform)回 `ACTIVATE_FAILED`。`ActivateConfiguration()` 約 2 s 無例外返回,XAE Output 視窗只有「Check config failed!」,`SolutionBuild.LastBuildInfo` 由 0 變 1;target 上什麼都沒寫(UmRT 的 `Boot\CurrentConfig.xml` 沒更新,只有 `Boot\Plc\Port_851.*`),port 851 維持 Invalid(不經此檢查就會變成 `PLC_NOT_LOADED`)。
- **為什麼**:4026 XAE 在 Activate 時檢查 active solution platform 與 target platform。本機 UmRT_Default 是 user mode 的 TcOsSys(Usermode Runtime),target platform 是 `TwinCAT OS (x64)`;solution platform 卻是 `TwinCAT RT (x64)` 時 XAE 顯示訊息框「Active solution platform 'TwinCAT RT (x64)' differs from current target platform 'TwinCAT OS (x64)'! Adjust solution platform and retry.」。`SilentMode` 開著時框被自動關掉,於是只剩 `LastBuildInfo > 0`(模組據此回這個碼);`SilentMode` 關著時框一直在,`ActivateConfiguration()` 阻塞到框被關(實測 102 s)。
- **platform 怎麼來的**(實測,issue #16 調查,4026 XAE;只有下面這組對照,沒有官方出處):原專案的 target 199.4.42.250.1.1 在這台 PC 連不到 → 選 `TwinCAT RT (x64)`;tsproj target 改成 199.5.42.250.1.1(UmRT)→ 選 `TwinCAT OS (x64)`(只翻 `TargetNetId` + 刪 `.vs` 驗證)。`Set-TcTarget`(`SetTargetNetId`)**不會**事後改 platform。這就是 2026-10-18 B 組「Target system reports a fatal error」的根因(issue #16)。已試過、無影響:`<Settings NonWinCpus/Cpu CpuId>` isolated core、tsproj `TcVersion`、UmRT `TargetFeatures.xml`。
- **模組現在先擋**:`Enable-TcConfig` 在 Activate 前比對 solution platform 與 target platform(target 的 TARGETINFO,讀不到時用 `-Platform`),不一致就切換並重新 Build(`platform-fix` / `platform-fix-build`)。所以這個碼現在只會出現在 `data.platformCheck = 'skipped'`(target 不支援 TARGETINFO、又沒給 `-Platform`;`data.warning` 有說明)或其他 Check config 失敗原因。
- **下一步**:`Enable-TcConfig -Force -Platform 'TwinCAT OS (x64)'`(會自己切換 + Build),或 `Set-TcTarget -AmsNetId <id> -Platform 'TwinCAT OS (x64)'`(Windows RT target 用 `'TwinCAT RT (x64)'`)再 `Build-TcProject` + `Enable-TcConfig -Force`。MCP:`RunLifecycle` 加 `Platform`,或 `SetTarget` / `EnableConfig` 的 `Platform`。
- **限制**:solution platform 名稱對、但 .tsproj 對到別的 project platform 的專案(Festo:solution `TwinCAT OS (x64)` → project `TwinCAT OS (ARMT2)`)實測**不會**得到 `ACTIVATE_FAILED`;模組改在切換前擋下,回 `PLATFORM_PROJECT_MISMATCH`。

### Target platform(TARGETINFO)

- **介面**:InfoSys TC1700/TC170x Usermode Runtime 手冊「Runtime type (ADS)」 https://infosys.beckhoff.com/content/1033/tc170x_tc3_usermode_runtime/11687997963.html :ADS port 200、IndexGroup `0x00000700`(SYSTEMSERVICE_TARGETINFO);IndexOffset `0x4` TARGETINFO_PLATFORM = 字串,XAE 裡選的 platform(Usermode Runtime 與 TwinCAT/BSD 為 `TwinCAT OS (x64)`);IndexOffset `0x2` TARGETINFO_TARGETTYPE = ULONG,1 = Usermode Runtime。這一條出現在手冊 v1.6.1(2026-08);最低支援的 runtime build **未確認**。
- **模組**:Private `Get-TcTargetPlatform -AmsNetId <id> [-TimeoutMs 2000]` 只讀這個介面(暫時 client,不碰模組 ADS session,永不 throw):回 `targetPlatform`、`isUsermodeRuntime`、`source`(`adsTargetInfo` / `unavailable`)、`adsError`(看到的 ADS 錯誤碼,例 `0x702`、`0x745`)、`detail`。讀不到就是讀不到,**不猜**。
- **本機實測 2026-10-21**:UmRT 199.5.42.250.1.1(`TcSystemServiceUm.exe` FileVersion 3.1.0.2649 / ProductVersion 3.1.4026.21,TwinCAT 3.1.4026.21~22)與本機 Windows XAR 192.168.50.168.1.1 對 IG 0x700(IO 4 與 IO 2)都回 **0x702**(IndexGroup invalid),Run 狀態下也一樣 → `source = unavailable`;連不到的 199.4.42.250.1.1 → `0x745`,約 2 s 返回。也就是這版 runtime 還沒有 TARGETINFO,自動對齊要等支援它的 runtime;現在請帶 `-Platform`。
- **用在哪**:`Set-TcTarget`(`data.platformCheck` = `parameter` / `target` / `unknown` / `disabled`)與 `Enable-TcConfig`(`data.platformCheck` = `target` / `parameter` / `skipped`)。

### PLATFORM_UNKNOWN

- **現象**:`Set-TcTarget -AmsNetId <id>`(沒給 `-Platform`、沒給 `-NoPlatformSwitch`)回 `PLATFORM_UNKNOWN`;`data.amsNetId`、`data.targetSet = true`(NetId **已經設好**,不用重做)、`data.platformCheck = 'unknown'`、`data.adsError`(例 `0x702`)、`data.platform`(沒動的 solution platform)。
- **為什麼**:target 不回 TARGETINFO(見上),模組不猜 platform。
- **下一步**:重跑 `Set-TcTarget -AmsNetId <id> -Platform '<平台>'`(UmRT / TwinCAT/BSD 為 `'TwinCAT OS (x64)'`,Windows RT 為 `'TwinCAT RT (x64)'`);只想換 NetId 就加 `-NoPlatformSwitch`(`lifecycle-smoke.ps1` 的 `02-set-target`、`login-logout.ps1`、MCP `RunLifecycle` 沒給 `Platform` 時都這樣呼叫)。`Enable-TcConfig` 在同樣情況下**不擋**:`platformCheck = 'skipped'`、Write-Warning + `data.warning`(同一段 hint)。
- **平台由目標對象決定,不看 XAE 版本**:UmRT / TwinCAT/BSD = `'TwinCAT OS (x64)'`,Windows RT = `'TwinCAT RT (x64)'`。solution platform 名稱可能對到別的 project platform(Festo .sln 的 `TwinCAT OS (x64)` → `TwinCAT OS (ARMT2)`):`-Platform 'TwinCAT OS (x64)'` 會在切換前被擋下,回 `PLATFORM_PROJECT_MISMATCH`(見該節),要先修專案的 Configuration Manager。專案還沒修、只想照目前的平台跑,就用 `-NoPlatformSwitch`(這是專案設定的限制;實測 2026-10-21 A 組以 `TwinCAT RT (x64)` 在 UmRT 上跑過)。

### PLATFORM_MISMATCH

- **現象**:`Enable-TcConfig -NoPlatformFix` 在 Activate 前回 `PLATFORM_MISMATCH`(以下兩種情況回的是 `PLATFORM_PROJECT_MISMATCH`,切換救不了,見該節:solution platform 名稱已經等於目標、只有 .tsproj 的 project platform 不同;或名稱不同,但唯讀查到目前 configuration 的 `<configuration>|<目標>` 底下 .tsproj 對到別的 project platform(真機 A3b:Festo active `TwinCAT RT (x64)`、目標 `TwinCAT OS (x64)` → `TwinCAT OS (ARMT2)`),這時 `data.platformMap` / `requestedProjectPlatform` 有值;solution configuration 讀不到時照舊回 `PLATFORM_MISMATCH`);`data.steps` 只有一筆 `platform-fix`(ok=false),`data.activated = false`,`data.solutionPlatform` 是沒動的那個,`data.platformCheck` 說比對對象(`target` / `parameter`)。
- **為什麼**:active solution platform 與 target platform(或 `-Platform`)不同,Activate 必然 Check config failed;`-NoPlatformFix` 要求不要自動切。
- **比對**:solution platform 與 `.tsproj` 的 project platform(`data.projectPlatform`)都要等於目標才算一致;只有 solution platform 名稱相同、project platform 不同也是 mismatch(讀不到 project platform 時只比 solution platform)。
- **下一步**:`Set-TcTarget -AmsNetId <id> -Platform '<platform>'` 再 `Build-TcProject` + `Enable-TcConfig`,或拿掉 `-NoPlatformFix`(預設會切換 + Build,`data.platformFixed = true`)。自動切換失敗回 `PLATFORM_NOT_FOUND`(solution 沒有那個 platform)、`PLATFORM_PROJECT_MISMATCH`(該 solution platform 的 .tsproj 對到別的 project platform,`data.platformMap`)或 `PLATFORM_SET_FAILED`;切換後的 Build 失敗回 Build 的碼(`BUILD_FAILED` …,step `platform-fix-build` ok=false)。

### PLATFORM_NOT_FOUND

- **現象**:`Set-TcTarget -Platform <name>`(或自動切換到 target 回報 / `Enable-TcConfig -Platform` 的 platform)回 `PLATFORM_NOT_FOUND`;`data.availablePlatforms`(`-Configuration` 那組 SolutionConfiguration 的 **solution platform** 名稱)、`data.platformMap`、`data.availableConfigurations` 列出現有的,`error.hint` 也列。
- **為什麼**:名稱拼錯,或 solution 沒有這個 solution platform。列的是真正的 solution platform(`SolutionConfiguration2.PlatformName`,[Microsoft Learn](https://learn.microsoft.com/en-us/dotnet/api/envdte80.solutionconfiguration2?view=visualstudiosdk-2022);VS2022 經 PowerShell 讀回 `$null` 時改依 index 對應 .sln 的 `SolutionConfigurationPlatforms`,只在行數與 configuration 名稱都對得上時採用,否則退回舊做法:第一個 SolutionContexts 的 project platform,`data.platformMatchedBy = 'projectPlatform'`)。實測 2026-10-22(TcXaeShell 15.0 / VS2022,TwinCAT 3.1.4026.22)。名稱存在但 .tsproj 對到別的 project platform 的是 `PLATFORM_PROJECT_MISMATCH`,不是這個碼。platform 是 target 回報的時候,message / hint 會註明「read from the target」。
- **下一步**:用 `availablePlatforms` 的名稱重跑 `Set-TcTarget -AmsNetId <id> -Platform <name>`;UmRT(Usermode Runtime)是 `'TwinCAT OS (x64)'`,Windows RT 是 `'TwinCAT RT (x64)'`;`-Configuration` 預設 `Release`。solution 沒有該平台就在 Configuration Manager 新增(.tsproj 與 PLC 專案對到同名 project platform)。

### PLATFORM_PROJECT_MISMATCH

- **現象**:`Set-TcTarget -Platform <name>`(或 target 回報的平台、`Enable-TcConfig` 的自動切換 `platform-fix`)回 `PLATFORM_PROJECT_MISMATCH`;**什麼都沒切換**(目標已經是 active 也照樣檢查)。`data.projectCheck = 'mismatch'`、`data.requestedProjectPlatform`(目標 solution platform 底下 .tsproj 的 project platform)、`data.platformMap`(該 configuration 每個 solution platform → `{ solutionPlatform; solutionPlatformSource; projectPlatforms = [{ project; platform; shouldBuild }] }`),hint 列出 .tsproj 真的編給目標平台的 solution platform。
- **為什麼**:solution platform 名稱對了,但 Configuration Manager 把它底下的 TwinCAT 專案(.tsproj)對到另一個 project platform。實例(A 組 Festo,實測 2026-10-22,TcXaeShell.DTE.15.0):solution `Release|TwinCAT OS (x64)` → `TwinCAT_Festo.tsproj` 與 `plc.plcproj` 都是 project platform `TwinCAT OS (ARMT2)`、ShouldBuild=False。切過去 Build「成功」卻什麼都沒編,Activate 不回 `ACTIVATE_FAILED`,851 維持 Invalid。target platform 決定 configuration 編給哪種 target,Configuration Manager 決定子專案是否參與 build:[InfoSys「Setting the TwinCAT target platform」](https://infosys.beckhoff.com/content/1033/tc3_automationinterface/650882187.html)。solution platform 與 project platform 的差別:`SolutionConfiguration2.PlatformName` 是 solution platform,`SolutionContext.PlatformName` 是 project platform([Microsoft Learn](https://learn.microsoft.com/en-us/dotnet/api/envdte.solutioncontext.platformname?view=visualstudiosdk-2022))。
- **下一步**:XAE 的 Build > Configuration Manager,選該 solution platform,把 TwinCAT 專案(.tsproj)與 PLC 專案的 Platform 欄改成正確的 project platform(沒有就 `<New...>` 新增)並勾 Build,存檔後重跑 `Set-TcTarget -AmsNetId <id> -Platform '<platform>'`;或改選 `data.platformMap` 裡 project platform 正確的 solution platform。專案不能改、只想照目前平台跑:`Set-TcTarget -NoPlatformSwitch`(`Enable-TcConfig -NoPlatformFix` 則回 `PLATFORM_MISMATCH`)。
- **沒有 .tsproj context**(讀不到 TwinCAT 專案)時不擋:`data.projectCheck = 'no-tsproj'`,照舊切換。
- **`Enable-TcConfig` 刻意擋下**:target 有 TARGETINFO(或給了 `-Platform`)時,`Enable-TcConfig` 的自動切換同樣回這個碼,且沒有逃生口(`-NoPlatformFix` 時:solution platform 名稱不同回 `PLATFORM_MISMATCH`,名稱相同只差 project platform 也回 `PLATFORM_PROJECT_MISMATCH`),只能修專案設定。target 沒有 TARGETINFO 時:`Set-TcTarget -NoPlatformSwitch` 只設 NetId、`Enable-TcConfig` 不帶 `-Platform`,照專案目前的平台跑。
- **data**:`data.projectPlatform` 是操作後實際 active 的 .tsproj project platform(這個碼:沒動的那個),`data.requestedProjectPlatform` 是目標 solution platform 底下的(Festo:`TwinCAT OS (ARMT2)`)。

### PLATFORM_SET_FAILED

- **為什麼**:`SolutionConfiguration.Activate()` 之後(實測同步生效,~30 ms),最多 3 s 內讀回的 solution platform(`Solution.Properties('ActiveConfig')`)或 .tsproj 的 project platform 不是要求的那個(切換沒生效,或 XAE 有 dialog)。模組會 `Activate()` 切換前的 configuration 還原,`data.restored = true/false`(已是 active、沒切換時為 null)。只要 solution platform 讀得到(`ActiveConfig` / `PlatformName`),讀回就一律要求它等於目標;solution platform 未知(VS2022 且 .sln 對不上)時依 project platform 找到的候選會逐一 Activate 驗證。
- **下一步**:`Get-TcIdeInfo` 看 `solutionPlatform`;`Get-TcIdeModalDialog` 檢查 dialog;必要時在 XAE 工具列的 Solution Platforms 下拉手動選,再重跑 `Set-TcTarget -Platform`。

### 成功時的 Set-TcTarget data

`Set-TcTarget -AmsNetId <id> [-Platform <name>] [-Configuration Release] [-NoPlatformSwitch]` 的 data:`amsNetId`、`targetSet`、`platformCheck`、`targetPlatform`、`targetPlatformSource`、`adsError`、`platform`(solution platform)、`projectPlatform`(操作後 active 的 .tsproj project platform,沒有 .tsproj 為 null)、`platformChanged`(bool);有切換時另有 `requestedProjectPlatform`、 `configuration`、`previousPlatform`、`availablePlatforms`、`projectCheck`(`ok` / `mismatch` / `no-tsproj`)、`platformMatchedBy`、`platformMap`。`Enable-TcConfig` 的 data 一律有 `targetPlatform`、`targetPlatformSource`、`solutionPlatform`、`projectPlatform`、`platformFixed`、`platformCheck`(skipped 時加 `warning`;自動切換失敗時加 `platformMap`、`requestedProjectPlatform`)。`Connect-TcIde` / `Get-TcIdeInfo` 的 data 多 `solutionPlatform`、`solutionConfiguration`、`projectPlatform`。MCP `SetTarget` 有 `Platform` / `Configuration` / `NoPlatformSwitch` 參數,`EnableConfig` 有 `Platform` / `NoPlatformFix`;`RunLifecycle` 的 `Platform` 只給 SetTarget 步驟(在 Build 之前切換,沒給 `TargetAmsNetId` 用 `ConnectIde` 回的 AmsNetId;之後 EnableConfig 比對結果相同),沒給 `Platform` 時 SetTarget 帶 `NoPlatformSwitch=true`,platform 交給 EnableConfig 檢查。MCP 的 hint 改寫保留引號內的值:`Set-TcTarget -Platform 'TwinCAT OS (x64)'` → `SetTarget Platform='TwinCAT OS (x64)'`。

## 已知限制

| 限制 | 說明 | 繞法 |
|---|---|---|
| Build 錯誤沒有編碼 | Error List 沒有 Code 欄,`errorItems[].code` 只對常見訊息推得(C0046 等),其餘 null | 用 description + file + line 判斷;需要編碼時查 InfoSys compiler errors |
| UmRT 假 Run | 本機 UmRT 跑約 30 分鐘後 task 可能停止循環,但 ADS 仍回 Run | 讀 `TwinCAT_SystemInfoVarList._TaskInfo[1].CycleCount` 兩次,沒動就重啟 `TcSystemServiceUm` 後 `Enable-TcConfig -Force` |
| Reset 殺 service | 對 UmRT 送 `Set-TcPlcState -State Reset` 會直接結束 `TcSystemServiceUm` | 不要對 UmRT 用 Reset;要清狀態改 Stop → `Enter-TcPlcOnline` 重新 download;真的 Reset 了就手動重啟 service |
| UmRT crash(`TcSystemServiceUm` 消失,issue #21) | 簽章固定:`TcOsSys.dll` c0000005,offset 0x589534,bucket 1526877736441380629(dump `TcSystemServiceUm.exe.86180.dmp` / `.58132.dmp`)。crash #7 2026-10-20 22:09:40、#8 2026-10-21 00:57:15,兩次都在 6~9 s 前 `Boot\TCNC.bootdata` 被截成 0 bytes;#8 發生在已跑約 1 h 的 UmRT 做 set-config(port 10000 Config)時 | 重啟 `TcSystemServiceUm` 後 `Enable-TcConfig -Force`;根因在 UmRT 側,模組無法避免 |
| UmRT ADS 0x502「Mailbox is full」 | 2026-10-21 約 01:02 新現象:UmRT process 活著、CPU idle,對 199.5.42.250.1.1 的**每個** ADS 呼叫都回 0x502(本機 TcSysSrv 正常),`Enable-TcConfig` 180 s 後回 `SYSTEM_STATE_TIMEOUT`。先 `Get-TcSystemState -AmsNetId 127.0.0.1.1.1` 對照本機 TcSysSrv 正常、target 不正常即是 | kill 並重啟 `TcSystemServiceUm`,再 `Enable-TcConfig -Force` |
| solution platform 對到別的 project platform 的專案跑不到 UmRT | 專案設定(與 XAE 版本無關):A 組 Festo .sln 的 `Release\|TwinCAT OS (x64)` 對到 project platform `TwinCAT OS (ARMT2)` 且沒有 Build.0;Build「成功」(1.4 s)什麼都沒 build、Activate 無 `ACTIVATE_FAILED`、851 維持 Invalid(`PLC_NOT_LOADED`)。`Set-TcTarget -Platform 'TwinCAT OS (x64)'` 現在在切換前回 `PLATFORM_PROJECT_MISMATCH` | 在 Configuration Manager 讓 `TwinCAT OS (x64)` 底下的 .tsproj / PLC 專案對到真正的 `TwinCAT OS (x64)` project platform(沒有就新增)再 Build |
| 被 modal 擋住的 IDE 會被當過期實例 | IDE 被 modal 擋住時 DTE `Version` 讀空字串,`Connect-TcIde` 當 ROT 過期項目,帶 `-SolutionPath` 會另外啟動第二個 IDE(VS2022 出現過一次,**未修**) | 重連前先 `Get-TcIdeModalDialog` / MCP `GetIdeModalDialog`;有 dialog 先處理;已多開就用 `data.candidates[]` / `Stop-Process` 收掉多的那個 |
| 重新 download 後 index offset 錯位 | symbol 的 indexGroup/indexOffset 在每次 download 後可能改變;舊 handle 會讀到別的變數 | 不快取 offset;懷疑錯位時比對 `TwinCAT_SystemInfoVarList._AppInfo.AppTimestamp` 是否變了,變了就重新 `Get-TcSymbols` |
| UIA 看不到的 dialog 仍會擋 quit | 標題為空等 UIA 掃描抓不到的 modal,`Disconnect-TcIde -Quit` 的事前檢查看不到,`Solution.Close` / `DTE.Quit` 照樣無限阻塞;經 MCP 時會先撞到 `BRIDGE_TIMEOUT`,走不到 `-Kill` | `Stop-Process -Id <data.ideProcessId>`(MCP 結果的 `data.lastIde.ideProcessId`),再重新 `Connect-TcIde` |
| FB `VAR_INPUT` 寫不進去 | PLC 每個 scan 覆寫 FB 輸入 | 在 MAIN 宣告獨立變數餵 FB,寫 MAIN 層級變數 |
| `Watch-TcVariable` 的 `samples` 被截短 | 預設只回最後 `-KeepLast` 筆(有 `-Until` 20、沒有 50),免得 50 筆 × 多變數塞爆 AI context;`sampleCount` 仍是總數,`truncated=true` 表示有丟 | 要全部就給大一點的 `-KeepLast`;等某個值用 `-Until "<Path> <op> <value>"`(`== != > < >= <=`,`<Path>` 要在 -Path 內,否則 `INVALID_PARAMS`),命中立刻返回 `untilMet=true` / `untilSample` / `elapsedMs` |
| MCP 同回合平行 tool call 順序 | client 平行送出的 call 到達 server 的順序不保證;bridge 嚴格 FIFO 一次執行一個,但 FIFO 的順序 = 到達順序 | 看每個結果 `data.seq` / `startedAt` / `finishedAt` 判斷實際順序;有因果的步驟(寫參數 → 下命令 → 觀察)分回合送 |

## 真機驗證腳本

`tests/Integration/` 的手動腳本需要真實環境:`bool-write.ps1`、`write-verify.ps1`、`list-symbols.ps1`、`full-cycle.ps1`、`lifecycle-smoke.ps1`、`login-logout.ps1`、`build-errors.ps1`(注入 C0046 錯誤驗證 `Build-TcProject` 的 `errorItems`,只對複本跑)、`reload-experiment.ps1`(磁碟改 .TcPOU 的 reload 行為,S0a/S0b/S2a/S2b/S3/S3b 六種情境,只對複本跑)。用法見 `tests/Integration/README.md`。`false-success.ps1`:#28 / #32 的真機情境(少 Build.0、多 PLC readback、nested 讀值、Run 退回 Config);`tests/Unit/activate-timeout.ps1`:Activate deadline 的 mock 測試,不需 IDE。`tests/Unit/blocked-solution-ide.ps1`:`Connect-TcIde -SolutionPath` 遇到被擋住的 IDE(#29:session record / dialog 路徑 / 視窗標題、attach 與否、證據矛盾、pid 重用、失敗不留舊連線、不另開 IDE)的 mock 測試,不需 IDE。`tests/Unit/clear-project.ps1`:`Clear-TcProject` 讀回(`cleanVerified`、`LIBRARY_UNRESOLVED` 與 `-AllowUnresolvedLibrary`、`CLEAN_UNVERIFIED`、`CLEAN_FAILED`、`CLEAN_TIMEOUT`、`nullReads` 逾時)的 mock 測試,不需 IDE。`tests/Unit/platform-project-mismatch.ps1`:solution platform / project platform 檢查(`PLATFORM_PROJECT_MISMATCH`、.sln index 對應、讀回失敗還原)的 mock 測試,不需 IDE。

- `lifecycle-smoke.ps1 -AllowUnresolvedLibrary`:`03a` 的 `Clear-TcProject` 帶 `-AllowUnresolvedLibrary`,給已知缺 library 的複本用(A 組 Festo NoVisu,見「CLEAN_LIBRARY_UNRESOLVED」)。
- `lifecycle-smoke.ps1 -StopAfterBuild`:只跑到 `03b`(Connect、target、`Clear-TcProject`、Build),不 Activate。runtime 不能 Activate 時用(例如 license 過期:Activate 失敗的「Target system reports a fatal error」會跳到**所有**連這個 target 的 XAE,別的 session 的也會,實測 2026-10-25,4024 32-bit XAE Shell 與 4026 VS2022 同時連本機 UmRT)。
- `lifecycle-smoke.ps1 -SolutionPlatform '<name>'`:在 Connect 與 Build 之間多一步 `02b-platform`(`Set-TcTarget -Platform`);`02-set-target` 改帶 `-NoPlatformSwitch`(只換 NetId,不會因 `PLATFORM_UNKNOWN` 失敗)。UmRT 必帶 `'TwinCAT OS (x64)'`(B 組 35/35;這台 UmRT 不支援 TARGETINFO)。smoke 與 `multi-ide.ps1` 的 Clean 都改成 `Clean($false)` + 輪詢(VS2022 的 wait 版不返回)。
- `mcp-server/scripts/lifecycle-client.mjs`(手動,需真 IDE + runtime):經 MCP server 跑 `RunLifecycle` → `GetSystemState` → 兩次 `ReadVariable`(task cycle counter 必須增加)→ `DisconnectIde Quit=true`。參數 `--sln`(必填)、`--progid`(預設 `VisualStudio.DTE.17.0`)、`--netid`、`--platform`、`--read <path>`;`--expect-fail <CODE> [--fail-platform <platform>]` 先跑一次帶 `Platform=<fail-platform>` 的 `RunLifecycle` 並要求該 error code(例 `--expect-fail ACTIVATE_FAILED --fail-platform "TwinCAT RT (x64)"`)。環境變數 `TWINCAT_MODULE_PATH`、`TWINCAT_MCP_POWERSHELL`;exit code = 失敗步驟數。
