# Troubleshooting

本頁與 `adapters/claude-code/SKILL.md` 的 Troubleshooting 表同源,這裡多了「為什麼會發生」。錯誤碼與 `error.hint` 文字的中央表在 `src/TwinCATAutomation/Private/ConvertTo-TcAdsErrorCode.ps1`(`$script:TcErrorHints`)。

過去兩個月 701 次自動化失敗的根因分布:

| 根因 | 佔比 | 對應錯誤碼 | 本輪修法 |
|---|---|---|---|
| Activate 後 ADS 連線失效沒重連 | 41% | `NOT_CONNECTED`、`ADS_TARGET_NOT_FOUND` | Read/Write/Watch-TcVariable、Get/Set-TcPlcState 自動重連,data 回 `reconnected` |
| COM 被 modal dialog 擋(RPC_E_CALL_REJECTED) | 29% | `IDE_BUSY` | 所有 DTE/COM 呼叫包 retry(1/2/4/8/16s),耗盡才回 `IDE_BUSY` |
| Lifecycle 順序沒 gating | 29% | `ADS_PORT_NOT_FOUND`、`ADS_INVALID_STATE`、`PLC_NOT_LOADED`、`SYSTEM_STATE_TIMEOUT` | `Set-TcSystemState`、`Enable-TcConfig -Force`、`Invoke-TcTestCycle` 每步輪詢到目標狀態才返回 |

## Lifecycle 正確順序

一鍵版本:`Start-TcLifecycle`(MCP `RunLifecycle`,#27)照下圖順序跑 Connect-TcIde → [Set-TcTarget] → Build-TcProject → Enable-TcConfig -Force → Connect-TcAds → Get-TcPlcState 讀回(沒有 `-NoLogin` 時必須是 Run,否則 `RUNTIME_STATE_MISMATCH`),第一個失敗的步驟就停(fail closed,error 原樣、`data.steps` / `data.failedStep`)。多 PLC:`-PlcProjectPath FrameworkUnitTest -ExpectedProject FrameworkUnitTest -AdsPort 852`(`-AdsPort` 省略時 `data.plcs` 去重後只有一個 port 就用它，否則 851;有 `-PlcProjectPath` 時 `-AdsPort` 不是選中 PLC 的 port 之一 → `PLC_PORT_MISMATCH`)。要逐步控制或除錯時用下面的分步 cmdlet。

```
Connect-TcIde -SolutionPath <sln>
      │  回 amsNetId、candidates[]、solutionPlatform / solutionConfiguration
      ▼
Set-TcTarget -AmsNetId <id> [-Platform <name>] (平台由 target 決定:UmRT / BSD = 'TwinCAT OS (x64)',
      │                                          Windows RT = 'TwinCAT RT (x64)';target 有 TARGETINFO
      │                                          就自動對齊,沒有(ADS 0x702)要帶 -Platform,只換 NetId
      │                                          用 -NoPlatformSwitch。切換前檢查 .tsproj 的 project
      │                                          platform,不符 → PLATFORM_PROJECT_MISMATCH;每個 PLC
      │                                          的 build selection 會變 → BUILD_SELECTION_CHANGED)
      ▼
Build-TcProject [-ExpectedProject <PLC>]
      │  BUILD_FAILED → 看 data.errorItems(Error List 明細);BUILD_TIMEOUT → 看 dialog
      │  data.projects[] / coverageComplete;PLC project 沒在 Build 清單 → PROJECT_SKIPPED_BY_CONFIGURATION
      │  不是完整成功(LIBRARY_UNRESOLVED、BUILD_FAILED、completeBuild = false…)→ 記下 BUILD_REQUIRED(#56),
      │  之後 Enable-TcConfig / Enter-TcPlcOnline 回 BUILD_REQUIRED,直到一次完整成功的 Build
      │  完整 Build 之後再 Write-TcPouCode / Add-TcPou / ... 改程式碼 → 同樣記下(code-changed,#65),要再 Build
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
- **Fail closed(#68)**:`success: true` 才代表狀態已讀回到達。任何 lifecycle 步驟回 `success: false` 就停下，後續步驟標 NOT RUN、回報使用者;runtime 改變請求送出後的失敗(`Set-TcSystemState` WriteControl 後的任何失敗含 `RUNTIME_CRASHED`;`Enable-TcConfig` set-config / Activate 送出後除巢狀 `LIFECYCLE_BLOCKED` 以外的任何 code;`Set-TcPlcState` Run / Stop 沒到)會記 lifecycle block,之後會改 runtime 的命令都回 `LIFECYCLE_BLOCKED`,直到使用者同意後 `Clear-TcLifecycleBlock`。見下方「LIFECYCLE_BLOCKED」與 `adapters/claude-code/SKILL.md`「Failure contract」。
- `Invoke-TcTestCycle` 內部就是上面的流程,每步同樣 gating。Activate 之後不再 `Connect-TcIde`(#68)。
- `SetTargetNetId` 本身**不會**改 solution platform(實測,見「ACTIVATE_FAILED」的「platform 怎麼來的」)。`Set-TcTarget` 設完 NetId 後讀 target 的 TARGETINFO(見「Target platform(TARGETINFO)」),讀得到就自動切 solution platform;讀不到又沒給 `-Platform` → `PLATFORM_UNKNOWN`(NetId 已設好)。目前這台的 UmRT / Windows XAR 都回 0x702,所以換 target 或 tsproj 的 target 連不到時,要加 `-Platform`(或 `Enable-TcConfig -Platform`;`Connect-TcIde` 的 `data.solutionPlatform` 看現在是哪個)。見 `ACTIVATE_FAILED`。

## 環境矩陣

| IDE | ProgID | ADS DLL | 備註 |
|---|---|---|---|
| 32-bit XAE Shell | `TcXaeShell.DTE.15.0` | 4024:TwinCAT 安裝目錄下 Components\Base;4026:package | 用來開 4024 專案(XAE 本身 4026.x + Remote Manager 4024.x) |
| 64-bit XAE Shell | `TcXaeShell.DTE.17.0` | 4026 package | TwinCAT 4026 |
| VS2022 + TwinCAT 整合 | `VisualStudio.DTE.17.0` | 4026 package | TwinCAT 4026(與 64-bit XAE Shell 同一套 XAE;需本機已有 VS2022) |

- 分工(使用者 2026-11-12 確認,#225):32-bit XAE Shell(`TcXaeShell.DTE.15.0`)**用來開 4024 專案**(XAE 本身 4026.x + Remote Manager 4024.x;這台三個 IDE 的 XAE Base 都是 3.1.4026.22,4024 靠 `<TwinCATDir>\3.1\Components\Base\Build_4024.71`);64-bit XAE Shell(`TcXaeShell.DTE.17.0`)與 VS2022(`VisualStudio.DTE.17.0`)開 4026 專案,後兩者是同一套 XAE。模組不會自動用 64-bit XAE Shell / VS2022 開 4024 專案(build 4024 以前要整合在 TwinCAT XAE Shell 或 Visual Studio 2017/2019,[Managing TwinCAT Remote Manager versions](https://infosys.beckhoff.com/content/1033/tc3_installation/20646415115.html))。Runtime:本機只有一個 UmRT_Default,三種 IDE 共用;UmRT 本身沒有版本,它是本機安裝的 TwinCAT runtime 跑在 user mode(Usermode Runtime;`TcSystemServiceUm.exe` FileVersion 3.1.0.2649 / ProductVersion 3.1.4026.21 只是識別用;`TCATSysSrv` 4026.22)。
- Automation Interface(`ITcSysManager`、`EnvDTE`)在各組合完全相同;差別只在 IDE 抓取(ProgID)與 ADS DLL 位置。
- **4026 與 4024 的差異**(2026-10-20/21 B 組實測):
  - 相同:PLC 樹路徑 `TIPC^<plc>^<plc> Project^POUs`(例 `TIPC^Untitled1^Untitled1 Project`);`Login(1)` + `SilentMode`;ADS DLL(GAC `TwinCAT.Ads.dll` 4.3.32.0);三個 host 的 XAE Base extension 都是 3.1.4026.22。
  - 不同:(1) 實測 4026 XAE 在 Activate 時檢查 solution platform 與 target platform 是否一致,不一致 → `ACTIVATE_FAILED`(A 組 4024 XAE 沒觀察到這個檢查;這是觀察紀錄,不是選平台的規則:平台一律由 target 決定,UmRT(Usermode Runtime)是 `TwinCAT OS (x64)`)。(2) VS2022 的 `SolutionBuild.Build($true)`(等待)永遠不返回,模組改 `Build($false)` + 輪詢 `BuildState`(`Clean` 同理)。(3) VS2022 的訊息框是 WPF(見「已知 modal dialog」)。(4) zh-TW VS2022 的 Error List 視窗名 `錯誤清單`、預設 scope `目前專案` 會藏其他專案的列,模組自動切到 `整個方案`。
  - VS2022 時間參考:`Connect-TcIde` 自啟 1.5~2.3 s、含開 solution 總計 25~63 s;solution-match 重連 1~1.5 s;`Reset-TcSolution` 8~11 s。
- 實測紀錄(smoke / MCP / multi-ide 的 B 組結果)見「驗證紀錄」的「B 組 2026-10-20/21」。
- **真機測試預設專案(2026-10-28 起)**:取代舊 A 組 Festo(`C:\Temp\Verify-f7e-a`)與舊 B 組 Robust(`C:\Temp\Verify-f7e-b`),舊的只留歷史紀錄;共同規則與細節見 `docs/agent-brief-realmachine.md`「環境」。
  - 4024 組:`TcXaeShell.DTE.15.0`,`C:\Temp\Verify-4024-bfh\BFH-1650.sln`。solution platform 只有 `CE7 (ARMV7)` / `OS (ARMT2)` / `RT (x64)` / `RT (x86)`,`-Platform 'TwinCAT OS (x64)'` → `PLATFORM_NOT_FOUND`,不帶 `-Platform` → `PLATFORM_UNKNOWN`。把 EtherCAT Device 1 / 5 設成 Disabled 後(2026-10-28 11:16),`-NoPlatformSwitch`(平台維持 `TwinCAT RT (x64)`)全 lifecycle PASS:Build → `Enable-TcConfig -Force`(851 Run、bootPackage match、platformCheck skipped 0x702)→ `Connect-TcAds` → `Read-TcVariable`,`_TaskInfo[1].CycleCount` 持續增加。**觀察(實測,未查到 InfoSys 出處,只是這個 4024 專案,不是通則):** 4024 的 `TwinCAT RT (x64)` 在 UmRT 上 Activate 成功、沒有 `ACTIVATE_FAILED`,與 4026 要用 `TwinCAT OS (x64)` 不同。歷史:Device 未 Disabled 時 `Enable-TcConfig` 在 IO 階段被 CCAT PCI INIT→PREOP 0x98110700 擋下(`IDE_MODAL_DIALOG`、bridge 重啟)。(實測 2026-10-28)
  - 4026 組:`TcXaeShell.DTE.17.0` 與 `VisualStudio.DTE.17.0` 輪流用 `C:\Temp\Verify-4026-axis\AxisInterface_Type01_Library.sln`,`'TwinCAT OS (x64)'` 全 lifecycle PASS(Build → `Enable-TcConfig -Force` → `Connect-TcAds` → `Read-TcVariable`)。(實測 2026-10-28,本機 UmRT)
- **Solution platform ≠ project platform**(專案設定,與 XAE 版本無關):平台由目標對象決定(UmRT / TwinCAT/BSD = `TwinCAT OS (x64)`,Windows RT = `TwinCAT RT (x64)`,CX ARM = 對應的 ARM 平台;[InfoSys TARGETINFO](https://infosys.beckhoff.com/content/1033/tc170x_tc3_usermode_runtime/11687997963.html)),但 solution platform 名稱可以對到別的 project platform。A 組 Festo .sln 的 solution `Release|TwinCAT OS (x64)` 底下 .tsproj 與 .plcproj 都對到 project platform `TwinCAT OS (ARMT2)` 且沒有 `Build.0`(ShouldBuild=False),選它什麼都不 build(實測:Build 1.4 s「成功」、Activate 不回 `ACTIVATE_FAILED`,851 維持 Invalid `PLC_NOT_LOADED`)。target platform 決定 configuration 編給哪種 target,Configuration Manager 決定子專案是否參與 build([InfoSys「Setting the TwinCAT target platform」](https://infosys.beckhoff.com/content/1033/tc3_automationinterface/650882187.html))。模組切換前檢查 .tsproj 的 project platform,不符就回 `PLATFORM_PROJECT_MISMATCH`(`data.platformMap`),見該節。
- `Connect-TcIde` 嘗試順序:`TcXaeShell.DTE.15.0` → `TcXaeShell.DTE.17.0` → `VisualStudio.DTE.17.0`;多實例時依 `-SolutionPath` 挑:只接已開該 sln 的實例(`data.selectedBy=solution-match`),沒有就啟動新實例(`launched`);別人開的空 IDE 或開著其他 sln 的 IDE 一律不碰,`Disconnect-TcIde -Quit` 只關本 session 啟動的那個 pid,其他 IDE 回 `IDE_NOT_OWNED`(#227)。`data.candidates[]` 列出所有看到的實例,`data.ideProcessId` 是連上的 IDE pid(`Get-TcIdeModalDialog` 只掃這個 pid 的視窗)。真機驗證:`tests/Integration/multi-ide.ps1`。ROT 裡正在關閉的舊實例(讀 `Version` / `Solution` 回 0x800706BA / 0x80004005)會被跳過。
- `Connect-TcIde` 自行啟動 IDE 時:`CreateInstance` 後**不碰** `MainWindow.Visible`(此時會丟 property not found),改輪詢 `Version` + `Solution`(500 ms,最長 60 s),就緒後設 `UserControl = $true` 讓 IDE 可見且不隨 COM 釋放關閉;逾時則 `Quit()` 並 kill 啟動時刻之後出現的 `TcXaeShell.exe` / `devenv.exe`,回 `IDE_LAUNCH_FAILED`。
- `Connect-TcAds` 的 `data.adsBackend` 顯示實際載入的 ADS 後端(DLL 路徑 / 反射 fallback)。
- `Enable-TcConfig -Force` 在 UmRT 上需要 license 齊全(trial 要涵蓋專案用到的 TF)。Activate 前**無法**預檢(InfoSys 沒有文件化的唯讀方法,#49);Activate 後 runtime 回報 license 不足(XAE「Target system reports a fatal error: 'TwinCAT System' (10000) >> license not found <<」)時回 `LICENSE_MISSING`(lifecycle block 照記,dialog 不按),見 `docs/troubleshooting.md`「LICENSE_MISSING」。
- 換 target(本機 UmRT ↔ 遠端 CX)或換 IDE 後要重新 `Connect-TcIde`,AmsNetId 會變;solution platform 要對齊新 target 的平台(`Set-TcTarget` 讀得到 TARGETINFO 時自動,否則 `-Platform`)。
- **已知未解**:IDE 被 modal dialog 擋住時,它的 DTE `Version` 讀成空字串,`Connect-TcIde` 把該 ROT 項目當過期實例,帶 `-SolutionPath` 時會**另外啟動第二個 IDE**(VS2022 出現過一次)。重連前先 `Get-TcIdeModalDialog`(MCP `GetIdeModalDialog`)確認 IDE 沒被擋,有 dialog 先處理。

## 已知 modal dialog

與 `IDE_BUSY`(COM 回 0x80010001,可重試)不同,下面這些視窗讓 DTE 呼叫**無限阻塞**、永不返回。模組在 Build / Activate / Login / Solution.Open 之前用 UI Automation(`Find-TcIdeModalDialog`)檢查一次,有就回 `IDE_MODAL_DIALOG`,掃描沒完成就回 `MODAL_SCAN_INCOMPLETE`(未知不當成沒有,見該節);呼叫進行中另有 watchdog 每 2 s 掃一次,呼叫失敗返回時若看過 dialog 也回 `IDE_MODAL_DIALOG`。模組只偵測,唯一會主動回答的是 reload 提示(`Reset-TcSolution`,見下表);其他已經被卡住的呼叫無法中斷,只能手動關 dialog 或 kill IDE(本 session 啟動的 IDE 可用 `Disconnect-TcIde -Quit -Kill`)。

**中文 UI 的訊息框**:中文 Windows 上 XAE 的訊息框是 Win32 `#32770`,按鈕在 UIA 裡是 `ControlType.Pane`(ClassName `Button`,不是 `ControlType.Button`),Name 是「是(Y)」「否(N)」,AutomationId 是 control id 6 / 7(= `IDYES` / `IDNO`)。比對英文 "Yes" 或 `ControlType.Button` 一定失敗;模組(`Close-TcMessageBox`)對 Win32 訊息框只用 control id:`GetDlgItem(hwnd, 6)` + `BM_CLICK`(`SendMessageTimeout`,5 s),語系無關。`BM_CLICK` 被處理不代表有按到:dialog 不是 active 時 `BM_CLICK` 可能失敗([Microsoft Learn BM_CLICK Remarks](https://learn.microsoft.com/en-us/windows/win32/controls/bm-click))。#64 在 CI(run 40185005290)上只看到 send 成功、但測試 host 沒印出答案(`host answered Yes (host: [])`);「dialog 沒關」是依上面 Remarks 的推論，沒有實際觀察到。所以送出後 2 s 內 dialog 還在(或 send 失敗 / 逾時)就改 post `WM_COMMAND`(wParam = control id、lParam = 按鈕 handle,跟真的按下去送給 dialog 的通知一樣),結果的 `Closed` 表示 dialog 有沒有在 2 s 內消失。補送前(send 有處理或逾時兩條路都一樣)先檢查:dialog 被 disable 或有 enabled popup(自訂 #32770 dialog 的 Yes 處理又開了一層 modal,表示已經按到；這時 BM_CLICK 同步送出的 BN_CLICKED 回不來，send 就會逾時)→ 不補送，回 `Sent = true`、`Method BM_CLICK`、`Closed = false`。dialog 已經不在(補送前就不在，或 PostMessage 因 dialog 剛好關掉而失敗):只有 BM_CLICK **有被處理**時才算 `BM_CLICK` 成功、`Closed = true`;send **逾時**後 dialog 不在，不知道是誰關的(使用者按了 No、XAE 自己關、執行緒卡住),回 `Sent = false`、Reason `dialog already gone`(`Close-TcReloadPrompt` 視為 Dismissed、沒有回答，`Reset-TcSolution` 會走 NeedReopen)。`Find-TcIdeModalDialog` 的 `Buttons`(MCP `data.dialog.buttons`)列出 `#32770` 的按鈕 `{id, name}`。

**VS2022 的訊息框是 WPF**(AutomationId `Microsoft.VisualStudio.MessageBox`,2026-10-21):內文在 AutomationId `Text` 的元素,按鈕是真的 `ControlType.Button`,AutomationId `OKButton` / `YesButton` / `NoButton` / `CancelButton`,**沒有** Win32 control id。`Find-TcIdeModalDialog` 回完整內文與按鈕(`Buttons[]` 多 `automationId`,MCP `data.dialog.buttons[].automationId`);`Close-TcMessageBox` 沒有 control id 時退到 UI Automation `InvokePattern.Invoke()`(回傳 `Method = UIA_INVOKE`,STA runspace、10 s 逾時),不依賴語系與 hwnd(`-Hwnd 0` 時依 AutomationId 在 IDE 主視窗下找)。所以「只靠 control id 回答」只適用 `#32770`。

| 視窗 | 何時出現 | 解法 |
|---|---|---|
| `Assertion Failed: Abort=Quit, Retry=Debug, Ignore=Continue` | Build 時 CODESYS 優化器處理 visu 元素的內部錯誤(NullReference / DivideByZero),**間歇性**:反覆開關 solution 後、或全新專案第一次全編譯都可能出;Clean 無效,清 `_CompileInfo` 也不保證 | 這個 modal 會讓 DTE 呼叫無限阻塞,只能 `Stop-Process` 該 IDE,重開 solution 再 Build(通常第二次就過) |
| Microsoft Visual Studio 帳戶設定 | VS2022 未登入時 | 登入一次,或手動關閉視窗 |
| `Target system reports a fatal error` | Activate 的設定在 target 上無法啟動。2026-10-18 B 組那次的根因是 **solution platform 錯**(`TwinCAT RT (x64)` 對 UmRT),見 `ACTIVATE_FAILED`;不是 license、isolated core(`<Settings NonWinCpus/Cpu CpuId>`)、tsproj `TcVersion`、UmRT `TargetFeatures.xml`(都試過、無影響) | 先 `Get-TcIdeInfo` 看 `solutionPlatform`,不對就 `Set-TcTarget -Platform`;再看 XAE Output / Error List,UmRT 其次才是 license 或 I/O 設定問題 |
| `Active solution platform 'TwinCAT RT (x64)' differs from current target platform 'TwinCAT OS (x64)'! Adjust solution platform and retry.`(WPF 訊息框) | 4026 Activate 時 solution platform 與 target platform 不一致。`SilentMode` 關閉時訊息框一直在、`ActivateConfiguration()` 阻塞到框被關(實測 102 s);`SilentMode` 開著(`Connect-TcIde` 預設)時 XAE 自動關框、`ActivateConfiguration()` 約 2 s 無例外返回,Output 只有「Check config failed!」 | `Enable-TcConfig` 以 `LastBuildInfo > 0` 偵測並回 `ACTIVATE_FAILED`;`Set-TcTarget -AmsNetId <id> -Platform 'TwinCAT OS (x64)'` 後重跑 Build + `Enable-TcConfig -Force` |
| Trial license security code | 7 天 trial 到期或首次啟用 | 需人工輸入驗證碼,模組無法代勞 |
| `Target system reports a fatal error: 'TwinCAT System' (10000) >> license not found <<` | Activate / 切 Run 後 target 的 license 不足(trial 到期、沒涵蓋專案用到的 TF) | 模組回 `LICENSE_MISSING`,不按 dialog;使用者在 XAE 處理 license 後清 block,見「LICENSE_MISSING」 |
| `Application 'Port_851' does not exist on device ... create it and proceed with download?` | 空 runtime 上 Login 時全域 `SilentMode` 沒開(例如沒經 `Connect-TcIde` 連線) | `Connect-TcIde` 連上就開 `ITcAutomationSettings.SilentMode`,XAE 自動答 Yes,不應再出現;手動點 Yes 即可。**不要**改用旗標 SILENT(257)壓框:它會跳過建 app,851 仍 Invalid |
| `Login aborted: Conflicting flag settings` | Login 旗標 3(REGULAR\|FORCEONLINECHANGE 互斥) | 不要用 3;用 `-LoginMode Regular\|Download\|OnlineChange`(1/4/2,不 OR SILENT) |
| `File has been changed outside the environment. Reload the new file?`(VS2022 寫法 `... changed outside the source editor. Do you want to reload it?`) | 開在編輯器裡的檔案(.TcPOU 等)被磁碟上的工具(AI 編輯器、git checkout、產生器)改了,約 1 s 後出現;VS 選項 `AutoloadExternalChanges` 壓不掉。沒開在編輯器的檔案 XAE 約 5 s 內自動重載、不跳框(2026-10-20 `reload-experiment.ps1`) | `Find-TcIdeModalDialog` 回 `Kind = reload-prompt`(結果 `data.dialogKind`),hint 指向 `Reset-TcSolution`,它會對這個提示送 WM_CLOSE、`Documents.CloseAll`、`Solution.Close`、同一個 IDE `Solution.Open`、`Connect-TcIde` 重連(約 20~25 s);之後改磁碟後立刻 `Reset-TcSolution` 即可。見「磁碟改檔的正確做法」 |
| `The project file '...\plc.plcproj' has been modified outside of TwinCAT XAE. Do you want to reload the project?` | `.plcproj` 在磁碟上被改寫(產生器每次都重寫,內容相同、只有 mtime 變也會跳);2026-10-20 gantry-watchdog dogfooding | `Find-TcIdeModalDialog` 回 `Kind = reload-prompt`、`ReloadTarget = project`(結果 `data.dialogKind` / `data.dialogReloadTarget`,MCP `data.dialog.reloadTarget`)。直接 `Reset-TcSolution`:它對這個提示按 **Yes**(Win32 框用 control id 6、VS2022 WPF 框用 UIA Invoke `YesButton`,皆語系無關),XAE 自己 reload 專案,模組只重新 `Connect-TcIde` 並用 `LookupTreeItem('TIPC')` 確認 `ITcSysManager` 可用,不做 close/reopen(`data.answeredYes = true`、`data.reopenedSolution = false`)。按 Yes 失敗(#135 F4):再按一次 Yes;仍失敗就按 **No**(control id 7)再走 close/reopen 從磁碟讀;No 也失敗回 `IDE_MODAL_DIALOG`,**不送** WM_CLOSE。原因:XAE 這個提示是 Win32 `MB_YESNO`,**`MB_YESNO` 對 WM_CLOSE 不關**(實測 2026-11-07,Windows 11 26200:`MB_YESNO` 3 s 後仍在,`MB_YESNOCANCEL` 會關;[MessageBox 文件](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-messagebox):沒有 Cancel 鈕時 ESC / 關閉無效),舊的 fallback 必然 8 s 後「dialog still shown」。每次嘗試記在 `data.reloadPromptAttempts`(`answer`、`sent`、`method`、`controlId`、`bmClick`、`wmCommand`、`dismissed`、`reason`、`sendReason`、`timeoutSec`、`sec`);每次等待 = Min(15 s, `-TimeoutSec` 剩下的時間),剩不到 1 s 就不再嘗試、回 `IDE_MODAL_DIALOG`。只要有一次 Yes 送出(`data.possiblyReloaded`),之後任何失敗都記 code-changed。探測失敗才退回 close/reopen |
| 方案層級 reload 提示:標題「偵測到檔案修改」,內文「方案 'X' 已在環境外部修改。…」(VS2022 zh-TW,class `#32770`,按鈕 control id 259 = 重新載入(&R)、1412 = 忽略(&I)) | `.sln` 在磁碟上被改寫(#106,實測 2026-11-03,4026 VS2022 zh-TW) | 依按鈕 control id **259 + 1412** 分類(語系無關,不比對文字;TcXaeShell 與其他語系**未驗證**):`Kind = reload-prompt`、`ReloadTarget = solution`。`Reset-TcSolution` 按 **忽略**(control id 1412,`Close-TcReloadPrompt -Answer Ignore`),再走完整 close/reopen(`Solution.Close($false)` 不存)從磁碟讀;按不到就 WM_CLOSE,仍關不掉回 `IDE_MODAL_DIALOG`。不按「重新載入」(259) 的原因(實測 2026-11-07,4026 VS2022 zh-TW):按了之後 VS 立刻跳「儲存對下列項目的變更? X.sln X.tsproj* 儲存/不要儲存/取消」(`Set-TcTarget` 讓 .tsproj 在記憶體裡是 dirty),又是一個 modal;`Set-TcTarget` 之後直接 `Solution.Close($false)` 則沒有跳框;那次 BM_CLICK 沒關掉、WM_COMMAND 才關掉方案提示。以前分成 `unknown`;使用者手動按「重新載入」後模組 cache 的 `ITcSysManager` 已失效(下一次 Reset 步驟 1b 丟「System Manager already disposed!」),現在步驟 1b 一律用 `Get-TcSysManager -Refresh` |
| `TwinCAT PLC Control`(class `#32770`) | 2026-10-18 經 MCP server 跑 `BuildProject` 時出現一次;成因未定,懷疑 OneDrive 檔案鎖或新啟動的 IDE 第一次 build。標題不在已知清單,靠 `#32770` class 偵測 | DTE 呼叫無限阻塞,等到 `BRIDGE_TIMEOUT`(Build 600 s)才 kill bridge;IDE 本身不會退出,只能 kill 該 IDE(MCP 結果的 `data.lastIde.ideProcessId` / `error.hint` 會給 pid 與 `taskkill` 指令),重新 `ConnectIde` 再 Build |

## 磁碟改檔的正確做法(.TcPOU / .TcGVL / .plcproj 直接改檔案)

`Write-TcPouCode` / `Add-TcPou` 走 COM(`ITcSmTreeItem.DeclarationText` / `ImplementationText`)寫進 IDE,**不會**跳框,優先用它。寫入當下 XAE 就把 .TcPOU 寫到磁碟:實測 2026-10-28(4026 VisualStudio.DTE.17.0,`C:\Temp\Verify-repro-axis`)`WritePouCode` 後不 Build,磁碟 .TcPOU 的 LastWriteTime 與 `WritePouCode` 同一秒、檔內已有新內容,開著 editor 時也一樣([#69 實測留言](https://github.com/Lance0901/AI-TwinCAT-Skill/issues/69#issuecomment-6460378071));4024 未測。(早期 2026-10-20 在 4024 32-bit XAE 記錄過「mtime/hash 不變、要到存檔或 Build 才落地」,與 #69 的 4026 實測不同,4024 尚未重測。)新建物件的 `.plcproj` 項目則不會自己落地,見下方「新物件與 .plcproj(#76)」。AI 或其他工具直接改磁碟上的檔案時,決定一切的是「該檔案有沒有開在 XAE 的文件視窗」(2026-10-20 `tests/Integration/reload-experiment.ps1`,4024 32-bit XAE,log 在 `tests/Integration/logs/reload-S*.log`):

| 情境 | XAE 行為 | 正確做法 |
|---|---|---|
| 檔案**沒有**開在編輯器 | 約 5 s 內自動偵測並重載,`Get-TcPouCode` 讀到新內容、Build 用新檔;不跳任何框 | 改完等 5 s 再呼叫 DTE(或直接 `Reset-TcSolution` 確保一致) |
| 檔案**開著** | 約 1 s 後跳 modal「File has been changed outside the environment. Reload the new file?」,所有 DTE 呼叫阻塞;`Tools > Options > Environment > Documents > AutoloadExternalChanges` 壓不掉 | 改完**立刻** `Reset-TcSolution`:提示已經跳出來也沒關係,它會先把提示關掉(`dismissedReloadPrompt = true`),並 `Documents.CloseAll`,所以 reset 後檔案不再開在編輯器、下次改磁碟不會再跳(XAE 重開 solution 時會還原上次的編輯視窗,不關就會再跳) |
| `.plcproj` 被改寫(產生器、git checkout) | 跳 modal「The project file ... has been modified outside of TwinCAT XAE. Do you want to reload the project?」(`reload-prompt`、`ReloadTarget = project`),內容相同也會跳 | 改完**立刻** `Reset-TcSolution`:它對 project 提示按 Yes,XAE 自己 reload 專案,只重連不 close/reopen,比檔案提示的流程快(`data.answeredYes = true`、`data.reopenedSolution = false`);若同時還有 .TcPOU 的檔案提示,它會接著關掉並走完整 close/reopen。提示在呼叫之後才跳出(XAE 偵測檔案變更有延遲)時,讀 `Solution.FullName` 的輪詢會偵測到並照樣處理(#87,程式邏輯,待真機驗證;見「RESET_SOLUTION_UNVERIFIED」) |
| `Project.UnloadProject` / `ReloadProject` | 回「not available」、`GetItem` 為 null | 不可行,Automation Interface 沒有 reload 命令 |

**`Reset-TcSolution` 與 IDE 的未存變更(#175)**:重開前會讀 IDE 有沒有未存的文件 / 專案 / solution,有就回 `UNSAVED_CHANGES`、什麼都不關,要使用者同意才 `-Force`。磁碟改檔不會讓 IDE 那份變成未存,所以這個流程平常不會被擋;會擋的是 IDE 自己的未存變更,例如 `Set-TcTarget` 之後還沒 `Build-TcProject`(實測 2026-11-12,見「UNSAVED_CHANGES」)。

**新物件與 .plcproj(#76)**:`CreateChild` 建的 POU / DUT / GVL 會立刻寫出自己的 .TcPOU / .TcDUT / .TcGVL,但 `.plcproj`(新物件的 `<Compile Include>`;新增 library 的 `<LibraryReference>` 也是)只改在 XAE 記憶體,要等存檔(或 Build;實測 2026-10-28 該副本的 .plcproj 最後寫入時間 = 第一次 Build,見 [#76](https://github.com/Lance0901/AI-TwinCAT-Skill/issues/76))才落地;`Reset-TcSolution` 的 `Solution.Close($false)` 之後重開,新物件就從專案消失(實測 2026-10-28,4026 VisualStudio.DTE.17.0,`C:\Temp\Verify-repro-axis`)。現在 `Add-TcPou` / `Add-TcDut` / `Add-TcGvl` / `Add-TcLibrary` 建好後會只存專案檔(有 deadline,逾時見「PROJECT_SAVE_TIMEOUT」),並從磁碟讀回 .plcproj 確認有新項目(含相對路徑,如 `POUs\FB_X.TcPOU`)才回 success(`data.projectSaved`:`verifiedFiles[].preExisting` 表示存檔前就已在、`plcprojChanged` 是存檔前後 SHA256 是否不同;失敗見「PROJECT_SAVE_FAILED」);`Reset-TcSolution` 關閉前也會比對,但預設不存(見下方步驟 (1b))。存檔用的 API(實測 2026-10-28,4026 VisualStudio.DTE.17.0):

| 候選 | 結果 |
|---|---|
| DTE `Project.Save()`(.tsproj 那個 project;[InfoSys「Accessing TwinCAT configuration」](https://infosys.beckhoff.com/content/1033/tc3_automationinterface/242721803.html) 的 C# / PowerShell 範例呼叫 `project.Save()`,2026-10-28 核對過頁面) | 寫出 .tsproj 與巢狀的 .plcproj(新 `<Compile Include>` 出現),約 0.1-0.2 s;IDE 裡未存的一般文字文件**沒有**被存。採用 |
| `ITcSysManager.SaveConfiguration(<tsproj>)` | 丟例外「SaveConfiguration only supported in Automation Legacy Mode!. Please use standard DTE. Solution features for Project persistance instead!」 |
| DTE `File.SaveAll` | 也會存 .plcproj,但同時把 IDE 裡未存的文件寫到磁碟。不用 |
| DTE `Project.Saved` / `IsDirty`、`Solution.Saved` / `IsDirty` | 未存的 `CreateChild` 之後仍是 True / False,不能拿來判斷 dirty;巢狀 PLC project 也不在 `Project.ProjectItems` 裡 |

**實測 2026-10-28(4026 VisualStudio.DTE.17.0):一般文字文件不會被存;PLC editor 中未存的 POU 內容是否會被寫出未驗證**(不經 GUI 做不出 dirty 的 PLC editor buffer)。這同時適用於 `Add-*` 的自動存檔與 `Reset-TcSolution -SaveProjectChanges`。

**找 .plcproj(`Get-TcPlcProjectFile`)**:讀 solution 裡每個 .tsproj 的 `<Project Name="<Plc>" PrjFilePath="...plcproj">`(4024 / 4026 實測有,路徑相對 .tsproj 所在資料夾)。多個 .tsproj 列了同名 PLC 時取第一個,`data.projectSaved.warning` / `projectCheck.plcs[].warning` 說明。PLC 存成獨立專案檔(.xti,[InfoSys「Enabling and disabling an Independent Project File」](https://infosys.beckhoff.com/content/1033/tc3_automationinterface/21842602763.html))時,InfoSys 沒寫 .xti 放哪、PrjFilePath 相對於誰;模組退而搜尋 .tsproj 資料夾下的 *.xti,PrjFilePath 先相對 .tsproj、再相對 .xti 資料夾,只接受實際存在的 .plcproj(**未驗證**,本機沒有這種專案)。仍找不到:`Reset-TcSolution` 把該 PLC 標 `checked = false` + `reason` 並跳過比對(不擋 Reset);`Add-*` 回 `PROJECT_SAVE_FAILED`,hint 請使用者在 XAE 手動存該 PLC 專案。

`Reset-TcSolution [-SolutionPath <sln>] [-TimeoutSec 120] [-SaveProjectChanges | -DiscardProjectChanges]` 的步驟:(1) `Find-TcIdeModalDialog`(連續出現的 reload 提示最多處理 5 個):`ReloadTarget = project` 就按 Yes(`Close-TcMessageBox -Answer Yes`,等最多 15 s 消失,`data.answeredYes = true`;Yes 關掉提示後步驟 (1) 不再立刻掃 dialog(#174:實測 2026-11-08 4026 VS2022,Yes 之後 UI Automation 掃描 5 s 逾時;原因推測是 XAE 正在 reload 專案(推論)),Yes 之後的第一個 DTE 讀取(Yes 路徑的等待，或路徑 / guard 的 `Solution.FullName`)改成先掃描、掃描完整且沒有 modal 才讀，不完整的掃描當作未知、繼續等，不 fail(被 modal 擋住的 DTE 呼叫永遠不會返回));`ReloadTarget = file`(或 Yes 失敗的 project 提示)就對該視窗(只接受自己 IDE pid 的)送 WM_CLOSE,等它消失(真機 2 s);兩者都設 `data.dismissedReloadPrompt = true`、`data.reloadTarget`;其他 modal 回 `IDE_MODAL_DIALOG`,因為 `Solution.Close` 也會被擋。只按過 Yes(沒有用 WM_CLOSE 關過檔案提示)時跳過 (2)~(4),直接 (5) 重連並探測 `LookupTreeItem('TIPC')`,成功就回傳(`data.reopenedSolution = false`),探測失敗才繼續 (2)~(5)。(1b)(#76,`-DiscardProjectChanges` 跳過)比對每個 PLC 在 XAE 裡的頂層物件(POU / DUT / GVL / ITF)與磁碟 .plcproj 的 `<Compile Include>`(`data.projectCheck`:每個 PLC 的 `checked` / `reason`、`missingOnDisk[]`(`file`、`relativePath`、`fileExists`)、`extraOnDisk`(只拿有副檔名對應的物件檔名比,不拿資料夾名)、`complete`;樹走訪有 5000 節點 / 60 s 上限,超過就 `complete = false` + `reason`)。「XAE 有、磁碟 .plcproj 沒列」與「有人在磁碟上刪了物件」分不出來,所以**預設不存**:有 `missingOnDisk` → `PROJECT_UNSAVED_CHANGES`,不存、不關 solution(只有 `extraOnDisk` 不擋：重開就載入磁碟版本,XAE 不會掉東西)。`-SaveProjectChanges`(保留 XAE 版本)才只存專案檔(DTE `Project.Save()`,有 deadline)並以相對路徑讀回,`data.savedProjects` 列出;但步驟 (1) 處理過 reload 提示、`missingOnDisk` 的物件檔在它的相對路徑上不存在，或同一個 .tsproj 的任一 PLC(`Project.Save` 會寫整個 .tsproj 與其下所有 .plcproj;.tsproj 不明的也算)`checked = false`、比對不完整或 `extraOnDisk` 非空時仍拒絕存(`PROJECT_UNSAVED_CHANGES`,`data.saveRefused`)。存檔失敗回 `PROJECT_SAVE_FAILED` / `PROJECT_SAVE_TIMEOUT`,不關 solution。兩個開關同時給回 `INVALID_PARAMS`。未存的 library reference / task / I/O 變更偵測不到。(2) `Documents.CloseAll(vsSaveChangesNo)`,`data.closedDocuments`。(3) `Solution.Close($false)`、釋放舊 `ITcSysManager`。(4) 在**同一個** `$dte` 上 `Solution.Open(<sln>)`(真機 7~9 s,`data.openSec`):`Connect-TcIde -SolutionPath` 不會接沒開 solution 的 IDE(那是別人的,見 PR #9),所以必須在手上這個實例重開。(5) `Connect-TcIde -SolutionPath <sln> -ProgId <同一個> -NoLaunch`,以 solution-match 接回同 pid、重取 `ITcSysManager`、重開 SilentMode(真機 12~13 s,`data.connectSec`);`data.sameIde` 回報。全程 `data.totalSec` 實測 22~25 s(2026-10-20 真機 10/10 PASS,含 reload 框跳著時呼叫的情境)。ADS 連線不受影響;`Enable-TcConfig` 後的 PLC 不受影響。solution 路徑由 `Connect-TcIde` / `Open-TcProject` 記住(`$script:TcSolutionPath`),`Disconnect-TcIde` 清掉。中途失敗時 `data.closed` / `data.reopened` 說明做到哪一步。

`Find-TcIdeModalDialog` 的結果現在多 `Kind`(`reload-prompt` / `unknown`)、`ReloadTarget`(`file` / `project` / `$null`)與 `Buttons`,`IDE_MODAL_DIALOG` 結果多 `data.dialogKind` / `data.dialogReloadTarget` / `data.dialogButtons` 與 `data.dialog`(`{title, text, kind, reloadTarget, buttons}`);MCP 的 `GetIdeModalDialog` 回 `data.dialog.kind` / `reloadTarget` / `hwnd` / `buttons`。`reload-prompt` 的 `error.hint` 直接寫這段流程。VS2022 WPF 訊息框(見上)的 `Buttons[]` 多 `automationId`,`text` 是完整內文。

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
| 鎖住 target `Boot\CurrentConfig.xml` 後 Activate(舊版程式碼) | `ActivateConfiguration()` 掛 17 分鐘;因此加了 `ACTIVATE_TIMEOUT`(mock 測試 `tests/Unit/activate-timeout.ps1`;回傳時間上限見 #153) |
| lifecycle-smoke B(VS2022,RobustDemo-b,`TwinCAT OS (x64)`) | 37/37 |
| lifecycle-smoke A(32-bit XAE 4024,TcFestoNoVisu) | 34/34 |

## 錯誤碼

### IDE_BUSY

- **現象**:任何走 COM 的 cmdlet(Build、Add-TcPou、Enter-TcPlcOnline…)回 `IDE_BUSY`。
- **為什麼**:XAE 正在顯示 modal dialog(license、「專案已修改」、build 確認)或在跑長操作,COM 回 `RPC_E_CALL_REJECTED`(0x80010001)或 `RPC_E_SERVERCALL_RETRYLATER`(0x8001010A)。模組已退避重試 1/2/4/8/16 秒(共約 31 秒)仍被拒。
- **下一步**:先 `Get-TcIdeModalDialog -ProcessId <data.ideProcessId>`(MCP `GetIdeModalDialog ProcessId=...`)看是哪個視窗(`reload-prompt` → `Reset-TcSolution`),切到 XAE 關掉 dialog,重跑同一個 cmdlet。IDE COM 參考仍有效,不用 `Connect-TcIde`。常見 dialog 來源:license 試用到期提示、Activate 時的「Restart TwinCAT System」(用 `-Force` 走 ADS 就不會出現)。
- **`Connect-TcIde -SolutionPath` 回 `IDE_BUSY`(#29)**:開著這個 sln 的 IDE 被認出來(證據見「IDE_MODAL_DIALOG」的 #29 條目),但它拒絕 DTE 呼叫而且 UI Automation 找不到 dialog。強證據(`module-state` / `session-record` / `dialog-path`)時,沒有 dialog 也會回 `IDE_BUSY` 並 attach(`data.attached = true`);只有標題、證據矛盾、或兩個 IDE 都符合時不 attach(hint `IDE_BLOCKED_SAME_NAME`,見該節)。兩種情況都**不另開 IDE**(有沒有 `-NoLaunch` 都一樣),`data.ideProcessId` / `rotDisplayName` / `windowTitle` / `matchedBy` / `probe` / `notAttachedReason` 說明判斷依據。等它忙完(或關掉 dialog)再重跑同一個 `Connect-TcIde`;確定那不是你的 IDE 就加 `-LaunchIfBlocked` 另開。

### IDE_BLOCKED_SAME_NAME

- **碼與 hint**:hint key;錯誤碼是 `IDE_MODAL_DIALOG`(有 dialog)、`IDE_BUSY`(掃描完成、沒有 dialog)或 `MODAL_SCAN_INCOMPLETE`(掃描沒完成,`data.modalScan`,#42),`error.message` 以 `IDE_BLOCKED_SAME_NAME:` 開頭,`data.attached = false`。
- **為什麼(#29)**:`Connect-TcIde -SolutionPath` 找不到開著這個 .sln 的可讀 IDE,有個被擋住的 IDE 可能開著它,但證據不夠或互相矛盾(`data.notAttachedReason`):只有主視窗標題同名、session record / module-state 與標題或 dialog 路徑矛盾,或兩個 IDE 都有強證據(見「IDE_MODAL_DIALOG」的 #29 條目)。可能就是你的 IDE,也可能是別處的同名複本(實測 2026-10-25,4024 32-bit XAE Shell:別的 agent 的 `C:\Temp\Pou-A\TwinCAT_Festo.sln` 被 runtime 的 fatal error 擋住時就這樣)。模組不另開 IDE、也不 attach。
- **下一步**:是你的 → 關掉 `data.dialog`(`Get-TcIdeModalDialog -ProcessId <data.ideProcessId>`)後重跑同一個 `Connect-TcIde`;確定不是你的 → `Connect-TcIde -SolutionPath <sln> -LaunchIfBlocked`(MCP `ConnectIde LaunchIfBlocked=true`)另開一個。

### IDE_BLOCKED_OWN

- **碼與 hint**:hint key;錯誤碼是 `IDE_MODAL_DIALOG`、`IDE_BUSY` 或 `MODAL_SCAN_INCOMPLETE`,情況同「IDE_BLOCKED_SAME_NAME」,但 `data.launchedBySession = true`:被擋住的 IDE 是本 session 啟動的。
- **為什麼**:那很可能就是你的 IDE,只是證據不夠 attach;`-LaunchIfBlocked` 會再開一個 IDE 開同一個 .sln,所以這個 hint 不建議它。
- **下一步**:處理 `data.dialog`(`Get-TcIdeModalDialog -ProcessId <data.ideProcessId>`;MCP `GetIdeModalDialog ProcessId=<data.ideProcessId>`)後重跑同一個 `Connect-TcIde`(MCP `ConnectIde SolutionPath=<sln>`);卡死就 `Stop-Process -Id <data.ideProcessId>`(只限本 session 啟動的;MCP 沒有這個工具,要在 MCP 之外手動做)再重新 `Connect-TcIde`。

### IDE_MODAL_DIALOG / IDE_MODAL_DIALOG_RELOAD

- **碼與 hint**:錯誤碼都是 `IDE_MODAL_DIALOG`;`IDE_MODAL_DIALOG_RELOAD` 只是 `kind = reload-prompt` 時用的 hint key(`error.hint` 指向 `Reset-TcSolution`)。
- **現象**:`Build-TcProject`、`Enable-TcConfig`、`Enter-TcPlcOnline`、`Connect-TcIde`、`Reset-TcSolution` 回 `IDE_MODAL_DIALOG`(`Disconnect-TcIde -Quit` 遇到 modal 回的是 `IDE_QUIT_FAILED`,見下),`data.dialogTitle` / `dialogText` 是視窗標題與內文,`data.dialogKind` 是分類:`reload-prompt`(磁碟改檔的 reload 提示,hint 指向 `Reset-TcSolution`,見「磁碟改檔的正確做法」)或 `unknown`;`data.dialogReloadTarget` 區分 `file`(.TcPOU 等開著的檔案,「File has been changed outside the environment」)、`project`(.plcproj 被改寫,「The project file ... has been modified outside of TwinCAT XAE. Do you want to reload the project?」)與 `solution`(.sln 被改寫的方案提示,依按鈕 control id 259 + 1412 認出,#106,見「已知 modal dialog」)。
- **為什麼**:XAE / VS 有 modal 視窗(見「已知 modal dialog」)。這類視窗不會讓 COM 回 `RPC_E_CALL_REJECTED`,而是讓 DTE 呼叫無限阻塞,retry 救不了,所以模組在每個主要 COM 步驟前先用 UI Automation 掃 IDE 程序(`data.ideProcessId`)的頂層視窗。`Build-TcProject` 輪詢 `BuildState` 期間也每輪掃,build 中跳出的 dialog 回這個碼(不再等到逾時)。
- **下一步**:先 `Get-TcIdeModalDialog`(MCP `GetIdeModalDialog`)看 `kind`:`reload-prompt`(兩種 target 都算)→ 直接 `Reset-TcSolution`(project 提示按 Yes、solution 提示按忽略(1412)+ close/reopen、檔案提示 WM_CLOSE + close/reopen);其他手動處理 dialog 後重跑同一個 cmdlet,關不掉就 `Disconnect-TcIde -Quit -Kill`(只限本 session 啟動的 IDE)或 `Stop-Process -Id <ideProcessId>`,再重新 `Connect-TcIde -SolutionPath <sln>`。除了 reload 提示,模組不會自動關閉任何視窗。
- **限制**:已經被 modal 擋住、正在阻塞中的呼叫無法從模組中斷;偵測靠視窗的 `IsModal` / `#32770` class / 已知標題,偵測不到時仍可能卡住。
- **`Reset-TcSolution` reopen 後重連時跳 reload 提示(#180)**:實測 2026-11-08(4026 `VisualStudio.DTE.17.0` zh-TW,registered tcauto):`Solution.Open` 尾段有外部程序改寫 `.plcproj`(實測觸發法：背景以相同 bytes 重寫),提示落在 reopen 後的 `Connect-TcIde`,以前直接回 `IDE_MODAL_DIALOG`(`data.reconnectAttempts` = `[{step: reopen, code: IDE_MODAL_DIALOG}]`)。現在 `Connect-TcIde` 回 `IDE_MODAL_DIALOG` 且 `dialogKind = reload-prompt`、這次呼叫處理過的提示還不到 5 個時，用重連前記下的 pid 重新掃描重開 solution 的那個 IDE(`Connect-TcIde` 在 modal 檢查失敗前已綁定它選中的 IDE):還是 reload 提示才把模組的 IDE 狀態還原成那個 IDE,回到步驟 (1) 回答它(和 #176 讀回時一樣，共用 5 個上限;回答照原規則，含 #64 disabled 提示不再回答、Yes 之後先掃描再讀 DTE);重掃看到其他 dialog 就回那個 dialog 的 `IDE_MODAL_DIALOG`,掃描未完成回 `MODAL_SCAN_INCOMPLETE`,提示已消失或 pid 不明就照舊回重連的 `IDE_MODAL_DIALOG`;都 fail closed、記 code-changed。失敗後模組不還原，維持 `Connect-TcIde` 留下的狀態:它在 modal 檢查失敗前已綁定它選中的 IDE(一般就是重開 solution 的那個,`selectedBy` solution-match),所以模組仍連著重開的 IDE,`Get-TcIdeModalDialog` / `Reset-TcSolution` 可直接對它操作。同一類情況也發生在 Yes-only 路徑：回答 Yes 後的重連(`reconnectAttempts` step `reload-path`)失敗時，接下來的 guard 會先掃 modal 再讀 `Solution.FullName`(reload 提示回步驟 (1),其他 dialog 回 `IDE_MODAL_DIALOG`),不會在 dialog 開著時讀 DTE(PR #185 review)。
- **`Connect-TcIde -SolutionPath` 遇到被 modal 擋住的 IDE(#29)**:以前 ROT 探測讀不到被擋住那個 IDE 的 solution,就把它跳過:帶 `-NoLaunch` 回 `IDE_NOT_FOUND`(更舊的版本回 `PROJECT_OPEN_FAILED` null-valued expression),不帶就**再開一個 IDE** 開同一個 .sln。實測 2026-10-25(4024 32-bit XAE Shell,磁碟改寫 `plc.plcproj` 觸發 XAE「The project file ... has been modified outside of TwinCAT XAE」):被擋住時 `DTE.Version` 回**空字串**(不是 `RPC_E_CALL_REJECTED`)。現在對讀不到(忙碌或回空值)、pid 已知的 ROT 項目不呼叫 COM,module-state / session-record 必須**沒有矛盾、而且有當下事實佐證**(標題以 solution 名稱開頭,或 dialog 路徑在資料夾內)才算強證據;依序看四種證據:(0) 模組自己上一次連的就是這個行程且是同一個 .sln(`module-state`);(1) session record:先前任何一次 `Connect-TcIde` 成功連上同一個行程(pid + 啟動時間)並開著這個 .sln(`%LOCALAPPDATA%\TwinCATAutomation\ide-solutions.json`;測試設了 `TCAUTO_STATE_DIR` 時改放 `<TCAUTO_STATE_DIR>\ide-solutions.json`,mutex 名稱也加上該目錄的 hash,#118。有設和沒設 `TCAUTO_STATE_DIR` 的行程用的是不同的檔案和不同的鎖，彼此看不到對方的 record,同一組 IDE 不要混用兩種設定;每次帶 solution 連線成功就寫;記錄是別的 .sln 就排除。寫入是 read-modify-write,在 named mutex `Local\TwinCATAutomation-ide-solutions` 下進行(等待上限約 2 秒,拿不到就略過這次寫入、不丟錯;#123 起不再靜默:這個 IDE 行程(pid + 啟動時間)的舊 record 在本 session 視為不可信,`Get-TcIdeSolutionRecord` 不再回它,對該行程的任何比對一律降成弱證據(`Contradiction` 為警告文字、不 attach),`Connect-TcIde` / `Open-TcProject` / `New-TcProject` 的 `data.sessionRecordWarning` 帶原因;沒寫成的內容(本行程原本要寫的 record / 要刪的 record,不是檔案裡的舊 record)留成 pending,之後 `Connect-TcIde` 開頭、`Find-TcBlockedSolutionIde`、`Get-TcIdeSolutionRecord` 每次先短暫(250 ms)再試一次拿鎖，寫成就恢復可信(IDE 被 modal 擋住、不會再有新的 Save 時也能恢復,#127 F1);每筆 record 帶 `writtenAt`(UTC),鎖內發現檔案裡同一 pid 的 record 比 pending 晚寫(別的行程寫了較新的),就丟掉 pending、不寫入並恢復可信，所以 pending 晚寫回不會蓋掉別人的新 record(沒有 `writtenAt` 的舊格式視為較舊;但舊格式 record 的 solution 和 pending 不同時採保守做法：不寫回、維持不可信，等本模組下一次 Save 成功。已知限制:`writtenAt` 是 wall-clock 時間，系統時鐘往回跳時比較可能出錯);同一行程寫入成功也恢復。限制：只在同一個 module instance 內有效，其他 PowerShell / MCP 行程仍讀得到檔案裡的舊 record),並用 `[IO.File]::Replace` 原子取代檔案,多個 PowerShell / MCP 行程同時寫不會互相蓋掉記錄,#51),`matchedBy = session-record`;(2) UI Automation 掃到的 dialog 內文路徑落在 .sln 資料夾內(`dialog-path`;路徑都在別處就排除);(3) 主視窗標題以 solution 名稱開頭(`window-title`,弱證據)。符合就回 `IDE_MODAL_DIALOG`(`data.ideProcessId`、`rotDisplayName`、`windowTitle`、`matchedBy`、`probe`、`attached`、`data.dialog`),**不另開 IDE**。(0)(1) 要有當下事實佐證(`data.corroboratedBy`:`dialog-path`,或標題以 solution 名稱開頭且沒有已知的同名 .sln 開在別處時的 `window-title`)且沒有矛盾,或是沒有矛盾的 (2),才 attach:模組連線同時指向該 IDE(`attached = true`),接著 `Get-TcIdeModalDialog` / `Reset-TcSolution` 可以直接用(reload 提示 → `Reset-TcSolution` 按 Yes 後自己重連);只有 (3) 時不 attach(`attached = false`,理由見「IDE_BUSY」);關掉 dialog 後重跑同一個 `Connect-TcIde` 就是 `solution-match`。只回空值而沒有 dialog 的 IDE 視為正在關閉,照舊跳過。 **證據互相矛盾時不 attach**:session record / module-state 可能過期(例如在 GUI 換開別的 solution),所以 dialog 內文的專案檔都在別處,或標題非空卻不以 solution 名稱開頭時,降成弱證據;`Open-TcProject` / `New-TcProject` 換 solution 時也會更新 record。module-state 比對 pid **和**啟動時間(pid 重用不算)。兩個以上 IDE 都有強證據時一個都不 attach(`data.blockedCandidates` 全列)。失敗的 `Connect-TcIde` 不會留下上一個 IDE 的連線(`TcDte` 等一律清掉),所以 hint 叫你接 `Reset-TcSolution` 時只會作用在 attach 的那個 IDE。路徑比對(#63):`-SolutionPath`、session record、module state、已知 solution、dialog 內文路徑一律先過 `Get-TcLongPath` 展開 8.3 短名(`C:\Users\RUNNER~1\...`、`AXISIN~1.SLN`)再不分大小寫比對,所以給短名或長名結果相同,`data.solution` / 模組記住的 solution 路徑一律是長名。限制:UNC 路徑以文字比對;dialog 裡指向已不存在檔案的 8.3 路徑只能展開最長的已存在上層目錄,可能比不出 `inside`。殘留風險:dialog 沒有路徑時只剩標題能佐證;已知(ROT 讀得到、或有 session record)的同名 .sln 開在別處時標題不算佐證,但若同名的另一份是在同樣被擋住、沒有記錄的 IDE 裡(例如使用者手動開的),標題分不出兩者,record 仍可能被標題佐證而 attach。

### MODAL_SCAN_INCOMPLETE

- **現象(#42)**:modal dialog 的 UI Automation 掃描沒有完成,所以「IDE 有沒有 dialog」是**未知**。`Get-TcIdeModalDialog`(MCP `GetIdeModalDialog`)回 `success: false`、`data.scanComplete = false`、`data.dialog = null`、`data.modalScan`(`reason`:`timeout` = 掃描超過 `-TimeoutSec`;`prepare-timeout` = 載入 UIA / 編譯掃描用的 P/Invoke 型別超過 60 s;`error` = 掃描丟例外或寫了錯誤卻沒有結果;另有 `timeoutSec`、`elapsedMs`、`prepareMs`、`message`)。掃描完成時 `data.scanComplete = true`,`dialog = null` 才代表沒有 dialog。COM 步驟前的檢查(`Build-TcProject`、`Clear-TcProject`、`Connect-TcIde`、`Enter-TcPlcOnline`、`Test-TcPlcProject`、`Reset-TcSolution`、`Add-Tc*` / tree tools、`Disconnect-TcIde -Quit`、`Enable-TcConfig` 的 set-config / activate / login 步驟)遇到未完成的掃描**不做那個操作**,回這個碼。`Enable-TcConfig -Force` 在送出 set-config(切 Config)之前先檢查一次:這裡未完成就停下,target 沒被動過,不記 lifecycle block;set-config 已送出之後(activate / login 前、verify)的未完成掃描會記 lifecycle block(runtime 已經改過,#68),要 `Clear-TcLifecycleBlock` 才能再跑。`Disconnect-TcIde -Quit -Kill` 遇到未完成的掃描照 dialog 的情況走 kill。`Enable-TcConfig` 最後的讀回(verify)掃描未完成時再掃一次(上限 Min(15 s, 整個呼叫 `-TimeoutSec` 剩下的時間),剩不到 1 s 就不再掃),仍未完成就失敗;失敗結果的診斷沿用這次掃描,不再多掃(只有這項不符時碼是 `MODAL_SCAN_INCOMPLETE`,否則 `RUNTIME_STATE_MISMATCH`;runtime 已改過所以會記 lifecycle block)。輪詢中的掃描(`Build-TcProject` / `Clear-TcProject` 等 `BuildState`、`Reset-TcSolution` 等 `Solution.FullName`)未完成時繼續輪詢,結果由被輪詢的值決定;逾時的 `BUILD_TIMEOUT` / `CLEAN_TIMEOUT` 帶 `data.modalScan`。逾時後的診斷(`data.activateDiagnostics`、`data.saveDiagnostics`、`data.diagnostics`)多 `dialogScanComplete`。`Reset-TcSolution` 重連(步驟 5,與 Yes / Reload 路徑的重連)時 `Connect-TcIde` 回 `MODAL_SCAN_INCOMPLETE`:在 `-TimeoutSec` 用完前用同樣參數立刻重試,最多 3 次(實測 2026-11-07,4024 XAE:`Solution.Open` 成功後重連的 UIA 掃描 5 s 逾時、`prepareMs` 187,接著 Build 正常),不另外等待(掃描本身就會花時間);每次記在 `data.reconnectAttempts`(`step`、`code`、`sec`),其他錯誤碼不重試,重試仍未完成就照樣回 `MODAL_SCAN_INCOMPLETE`(fail closed)。`Connect-TcIde -SolutionPath` 遇到被擋住的 IDE 而掃描未完成時:attach 了就回 `MODAL_SCAN_INCOMPLETE`;沒 attach(弱證據)時錯誤碼也是 `MODAL_SCAN_INCOMPLETE`(hint 仍是 `IDE_BLOCKED_*`),不是 `IDE_BUSY`。
- **為什麼**:以前逾時的掃描回 `$null`,跟「沒有 dialog」一樣,前置檢查就照常往下做。實測 2026-10-28(Windows 11,16 logical CPU,Windows PowerShell 5.1,repo 27ca205,fixture 視窗是另一個 `powershell.exe` 的 `MessageBox`):新行程的第一次掃描閒置時 1.1~1.3 s,32 個 CPU 迴圈時 4.0~5.5 s,48 個時 3 次有 2 次超過預設 5 s 回 `null`,而 dialog 明明在;同一行程的第二次掃描 0.1~1.2 s 都找得到。第一次掃描的成本大多是編譯 P/Invoke 型別(`Add-Type` 會跑 C# 編譯器 csc.exe,另一個行程,最多三次)與載入 UIA。現在掃描分兩段:先在同一個 STA runspace 載入 UIA、用**一次** `Add-Type -TypeDefinition` 編譯所有缺的型別(不碰任何視窗,不會被 IDE 擋住,上限 60 s,不算在 `-TimeoutSec` 內;MCP bridge 把準備上限壓到 90 s 工具逾時 - 15 s 餘裕 - `TimeoutSec`,例如 `TimeoutSec=60` 時 15 s,整次呼叫不會超過 `GetIdeModalDialog` 的 90 s 而觸發 `BRIDGE_TIMEOUT`),再做有 `-TimeoutSec` 上限的掃描。實測 2026-11-04(同一台機器,Windows PowerShell 5.1,掃 explorer 的 pid,每回合新的 `powershell.exe`):閒置時準備 0.4~0.5 s、第一次掃描本體 0.1~0.17 s(第二次 0.03 s);32 個 CPU 迴圈時準備 1.0~3.2 s、第一次掃描本體 0.3~2.0 s,都在 5 s 內,所以預設仍是 5 s。視窗清單是 `EnumWindows` + pid 過濾再 `AutomationElement.FromHandle`(#24 / PR #44),dialog 掃描裡已經沒有桌面層級的 `RootElement.FindAll`;Error List 掃描(`Get-TcBuildErrors`)也改用同一份清單(型別缺時才退回 `FindAll`;型別在掃描前於另一個有上限的 runspace 編譯);切換範圍的下拉選單候選則搜尋同 pid 的所有可見視窗(含 owned popup,`UiaScanPidWindows.VisibleOf`),找不到可選的「整個方案 / Entire Solution」才退回一次桌面 `FindAll`。
- **下一步**:`Get-TcIdeModalDialog -TimeoutSec 15`(MCP `GetIdeModalDialog TimeoutSec=15`)再掃一次:`scanComplete = true` 且 `dialog = null` → 重跑原本的指令;有 dialog → 依「IDE_MODAL_DIALOG」處理。機器滿載時掃描本身會變慢,仍未完成就等負載降下來再掃。不要把未完成的掃描當成沒有 dialog 繼續做(#68 fail closed)。
- **IDE 剛啟動後的第一次掃描(#230)**:`Connect-TcIde`(`Solution.Open` 前)與 `Build-TcProject`(建置前)的單次檢查，第一次掃描逾時(`reason = timeout`)時自動用 15 s 再掃一次(prepare 上限 5 s,總共最多約 20 s),仍未完成才回 `MODAL_SCAN_INCOMPLETE`;其他 reason 不重掃。成功結果的 `data.modalScanRetried` 表示這次有沒有重掃。實測 2026-11-11(Windows 11 zh-TW、4026):TcXaeShell 64-bit 模組啟動後第一次 `Build-TcProject` 前的掃描 3/3 次 5000~5001 ms 逾時(`prepareMs` 82~154),同一行程第二次約 3 s、之後約 0.2 s;VS2022 由 `Connect-TcIde` 冷啟動後 `Solution.Open` 前的掃描 5008 ms 逾時(`prepareMs` 556)。所以逾時在掃描本體(第一次 UIA 走訪 IDE 視窗),不在 prepare。
- **待真機驗證**:以上 2026-11-04 的數字是掃 explorer、不是 XAE;冷啟動的 IDE + MCP bridge 第一次 `GetIdeModalDialog` 的時間、以及實際 dialog 在 VS2022 / TcXaeShell 上的偵測還沒用 tcauto MCP 重測;zh-TW VS2022 Error List 的範圍下拉選單(WPF popup 推測是 owned 視窗,未實測)在 EnumWindows 版本下是否仍切得到「整個方案」也待驗證。

### IDE_QUIT_FAILED

- **現象**:`Disconnect-TcIde -Quit` 回 `success: false`、`IDE_QUIT_FAILED`;`data.quit = false`,`data.quitError` 是原因(`modal dialog is up: <title>`,或 `DTE.Quit: ... RPC_E_CALL_REJECTED`);有 modal 時 `data.dialog = {title, text, kind, reloadTarget}`,`data.solutionClosed`、`data.ideProcessId`、`data.selectedBy`、`data.ownedBySession` 照給。**IDE 行程還活著**。
- **為什麼**:IDE 被 modal dialog 擋住或忙碌,`Solution.Close` / `DTE.Quit` 失敗。以前這種情況回 `success: true`,AI 以為 IDE 已關,下一個 `Connect-TcIde` 又以 solution-match 黏回同一個被擋住的 IDE(2026-10-20 dogfooding B3)。
- **下一步**:有 modal(`data.dialog`)時連線仍在:`kind = reload-prompt` → `Reset-TcSolution`,再 `Disconnect-TcIde -Quit`;其他 dialog 或 DTE.Quit 失敗 → `Disconnect-TcIde -Quit -Kill`(`Stop-Process -Force` 後等最多 10 s,`data.killed = true`)。不是本 session 啟動的 IDE 不會走到這裡:`-Quit` 一開始就回 `IDE_NOT_OWNED`(#227)。`-Kill` 之後 10 s 行程還在也回這個碼(`killed = false`)。
- 呼叫 `-Quit` 前若已偵測到 modal dialog,模組不會白跑 60 s 的 `Solution.Close` retry,直接回 `IDE_QUIT_FAILED`(`data.dialog`、`data.quit = false`、`data.disconnected = false`),而且**什麼都不釋放**:DTE / `ITcSysManager` / 連線狀態原封不動(quit 根本沒嘗試,DTE 仍有效),所以可以接 `Reset-TcSolution` 再 `-Quit`,或 `-Quit -Kill`;加 `-Kill` 則直接走 kill。
- **狀態保留**:真的嘗試過 quit(或走 kill)的路徑會釋放 COM 參考,但失敗時(`IDE_QUIT_FAILED`、`IDE_NOT_OWNED`)模組保留 IDE 的 pid / `selectedBy` / solution 路徑,所以可以**直接**接 `Disconnect-TcIde -Quit -Kill`,不用(也沒辦法,modal 還在)重新 `Connect-TcIde`。成功 quit / kill、不帶 `-Quit` 的 disconnect、或下一次 `Connect-TcIde` 才會清掉。kill 前會確認該 pid 仍是 `TcXaeShell` / `devenv`,且啟動時間與 `Connect-TcIde` 記下的相同(±2 s);不是(pid 被回收)就不殺、忘掉該 pid,回 `IDE_QUIT_FAILED`(`killed = false`)。pid 已經不存在(IDE 自己結束了)則回 `success: true`、`killed = false`、`alreadyExited = true`。
- `-Kill` 看的是 `data.ownedBySession`(本 session 啟動的 IDE),`Reset-TcSolution` 內部重連後 `selectedBy` 會變成 `solution-match`,但 `ownedBySession` 仍為 true,`-Kill` 照樣允許。

### IDE_NOT_OWNED

- **現象**:`Disconnect-TcIde -Quit`(帶不帶 `-Kill` 都一樣)回 `IDE_NOT_OWNED`,`data.ownedBySession = false`(`data.selectedBy` 例如 `solution-match`、`process-id`),`data.quit = false`、`data.disconnected = false`、`data.reason = 'not launched by this session'`。
- **為什麼**:`-Quit` / `-Kill` 只對本 session 用 `Connect-TcIde` 啟動的 IDE,不關也不殺使用者自己開的 IDE。#227 之前只有 `-Kill` 會檢查,單純 `-Quit` 會對 solution-match 接到的使用者 IDE 跑 `Solution.Close($false)` + `DTE.Quit()`;現在在 modal 檢查、`Solution.Close`、`DTE.Quit` 之前就拒絕,什麼都不關,連線保留。`Reset-TcSolution` 重連到同一個 pid 時仍算 launched;bridge 重啟、`ReloadModule`、`Import-Module -Force` 之後也仍算(#73,見「啟動紀錄持久化(#73 / #149)」)。啟動紀錄檔讀不到或壞掉時一律不算 owned,這時也會回這個碼。
- **下一步**:不再需要連線就 `Disconnect-TcIde`(不帶 `-Quit`)放開;那個 IDE 由使用者自己決定要不要關。再呼叫一次 `-Quit` / `-Quit -Kill` 結果不變(仍 `IDE_NOT_OWNED`)。

### IDE_PID_NOT_FOUND

- **現象**:`Connect-TcIde -ProcessId <pid>`(#210)回 `IDE_PID_NOT_FOUND`,`data.reason`:`process-not-found`(沒有這個行程)、`not-in-rot`(行程在,`data.processName`,但 ROT 沒有它的 DTE,例如 notepad 或還在啟動的 IDE)、`invalid-pid`(≤ 0)。`data.attached = false`、`data.launched = false`,`data.candidates` 是 ROT 裡所有 DTE。
- **為什麼**:`-ProcessId` 只綁定那一個 IDE 行程:不啟動新 IDE,也不改接其他實例。
- **下一步**:從 `data.candidates` 找正確的 pid 再呼叫;不確定就問使用者。不要拿掉 `-ProcessId` 重跑(會依 solution-match 選別的實例或啟動新的)。

### IDE_PID_MISMATCH

- **現象**:`Connect-TcIde -ProcessId <pid>` 回 `IDE_PID_MISMATCH`,`data.reason = 'progid'`(ROT 登記的 `data.progId` 不是 `-ProgId`)或 `'solution'`(那個 IDE 開著 `data.solution`,不是 `-SolutionPath` = `data.requestedSolution`)。沒有 attach,沒有改它開的 solution。
- **為什麼**:`-ProcessId` 連同 `-ProgId` / `-SolutionPath` 一起給時,條件全部要符合。那個 IDE 沒開任何 solution 時,`-SolutionPath` 會照一般規則開進去;已經開著別的 solution 就不替使用者換。
- **下一步**:確認 pid 是否選錯;要在那個 IDE 換 solution 先問使用者。

### IDE_PID_BLOCKED

- 不是錯誤碼,是 hint key:`Connect-TcIde -ProcessId` 找到的 IDE 的 DTE 被擋住(`RPC_E_CALL_REJECTED` 或空的 Version)時,錯誤碼照一般規則是 `IDE_MODAL_DIALOG`(有 dialog)、`MODAL_SCAN_INCOMPLETE` 或 `IDE_BUSY`,hint 用這一節。
- solution 讀不到,所以**不 attach**(`data.attached = false`、`data.ownedBySession = false`),跟不帶 `-ProcessId` 時 strong evidence 會 attach 的 #29 路徑不同。
- **下一步**:請使用者在那個 IDE 關掉 dialog(`Get-TcIdeModalDialog -ProcessId <data.ideProcessId>` 看內容),或等它忙完,再重跑同一個 `Connect-TcIde -ProcessId`。

### IDE_LAUNCH_FAILED

- **現象**:`Connect-TcIde` 找不到可接的 IDE、自己啟動一個,但 60 s 內 DTE 沒有就緒,回 `IDE_LAUNCH_FAILED`(啟動的行程會被收掉,不留孤兒)。
- **為什麼**:XAE / VS 卡在首次啟動精靈、帳戶登入視窗、license 提示,或該 ProgId 對應的 IDE 沒裝好。
- **下一步**:手動開一次該 IDE 確認能正常進到主畫面;或改用 `-ProgId` 指定另一個 IDE,或先手動開好 IDE(含 solution)再 `Connect-TcIde -SolutionPath <sln>`。

### 啟動哪個 IDE(#72):progIdSelectedBy

`Connect-TcIde` 要自己啟動 IDE、又沒給 `-ProgId` 時，不再挑「第一個註冊的 ProgID」(那會讓 4026 的 solution 被 32-bit TcXaeShell 打開，在 `.vs\<sln>\v15` 留下另一份 `.suo`,與之後 64-bit 載入卡住高度相關(#72 實測))。`data.progIdSelectedBy` 說明怎麼選的:

| 值 | 意思 |
|---|---|
| `explicit` | 呼叫端給了 `-ProgId` |
| `running-instance` | 接上 ROT 裡已在跑的 IDE(沒有啟動) |
| `tsproj-version` | 從 solution 引用的**每一個** `.tsproj` 根節點 `TcVersion` 判斷(證據在 `data.solutionVersion`:每個 .tsproj 的 `tcVersion` / `build` / `error`、`.sln` 的 `visualStudioVersion` 只當參考、沒選到時的 `xaeInstall`) |
| `remote-manager-match` | (#225)4026 以前的專案沒有 XAE 版本完全相等的 IDE,但 32-bit TcXaeShell(XAE ≥ 4026)已註冊、本機有**完全等於**專案版本的 Remote Manager 資料夾(資料夾名完全是 `Build_<build>.<revision>`,而且裡面直接有至少一個 `.dll`;空資料夾或 `Build_4024.71_old` 這類名稱不算):開 `TcXaeShell.DTE.15.0`,開完方案後讀回 IDE 的 `TcRemoteManager.Version`(`data.remoteManagerVerified` / `data.remoteManagerVersion`,不符 → `REMOTE_MANAGER_MISMATCH`)。實際找到的資料夾在 `data.solutionVersion.remoteManager`(`build` / `path` / `xaeVersion` / `progId`;`Get-TcProjectVersion` 是 `data.launch.remoteManager`) |
| `only-one-registered` | 沒給 `-SolutionPath`,或 solution 根本沒引用 .tsproj,而三個已知 ProgID 只註冊了一個 |

- **版本存在哪**:InfoSys 說專案檔記著最後存檔的 TwinCAT 版本([Selection of a TwinCAT 3 version before loading a project](https://infosys.beckhoff.com/content/1033/tc3_remote_manager/3154642571.html)),但沒寫欄位名。實測(2026-11-06,唯讀):`C:\Temp\Verify-4026-axis` 的 `.tsproj` 根節點是 `<TcSmProject ... TcVersion="3.1.4026.22">`,`C:\Temp\Verify-4024-bfh` 的是 `TcVersion="3.1.4024.71"`。只讀 `.tsproj`。有一個 .tsproj 缺檔、XML 壞掉或沒有 `TcVersion`,就不判斷(`PROGID_REQUIRED`)。
- **哪個 IDE 能開哪個 build**:TcXaeShell 是 Visual Studio 2017 Shell、TcXaeShell64 是 Visual Studio 2022 Shell,TcXaeShell64 從 build 4026 起才有([System requirements](https://infosys.beckhoff.com/content/1033/tc3_overview/6162419083.html));build 4024 以前要整合在 TwinCAT XAE Shell 或 Visual Studio 2017/2019([Managing TwinCAT Remote Manager versions](https://infosys.beckhoff.com/content/1033/tc3_installation/20646415115.html))。
- **ProgID 對到哪個 IDE、裝了哪個 XAE**:實測(2026-11-06,Windows 11,TwinCAT XAE 3.1.4026.22):
  - 從 `HKCR\<ProgID>\CLSID` → `CLSID\{clsid}\LocalServer32` 找到的 exe:
    - `TcXaeShell.DTE.15.0`:`C:\Program Files (x86)\Beckhoff\TcXaeShell\...\TcXaeShell.exe`(32-bit TcXaeShell)。
    - `TcXaeShell.DTE.17.0`:`C:\Program Files\Beckhoff\TcXaeShell\...\TcXaeShell.exe`(64-bit,即 TcXaeShell64;#72 記錄的 ProductVersion 是 17.0.0.0)。
    - `VisualStudio.DTE.17.0`:VS2022 的 `devenv.exe`。
  - 三個安裝根目錄下都有 `Common7\IDE\Extensions\Beckhoff Automation GmbH\TwinCAT XAE Base\extension.vsixmanifest`,Identity Version 都是 3.1.4026.22。模組用這個 manifest 判斷「這個 IDE 有整合 TwinCAT XAE,是哪個 build」:沒有這個 manifest 的 VS2022 不算 TwinCAT IDE。
  - `<TwinCATDir>\3.1\Components\Base\Build_<build>` 資料夾(這台有 4024.59、4024.71、4026.19、4026.20、4026.22):模組把它當成已安裝的 Remote Manager 版本。這是從資料夾內容推論的，不是 InfoSys 的說法。
- **規則**:
  - 候選:build ≥ 4026 → `TcXaeShell.DTE.17.0`,其次 `VisualStudio.DTE.17.0`(兩者都要讀得到 XAE Base ≥ 4026,也就是有整合 TwinCAT XAE)。不用 32-bit shell(#72)。build < 4026 → `TcXaeShell.DTE.15.0`。
  - 候選的 XAE Base 版本要**完全等於**專案的 `TcVersion`(含 revision,`3.1.4024.59` ≠ `3.1.4024.71`)才啟動。
  - (#225)build < 4026 的專案沒有完全相等的 XAE 時:`TcXaeShell.DTE.15.0` 已註冊、它的 XAE Base 讀得到且 ≥ 4026、`<TwinCATDir>\3.1\Components\Base\Build_<build>.<revision>` 與專案 `TcVersion` 完全相等(含 revision)→ 開 32-bit TcXaeShell(`remote-manager-match`)。`TcXaeShell.DTE.15.0` 沒註冊 → `IDE_VERSION_NOT_REGISTERED`。64-bit XAE Shell / VS2022 不會被自動選來開 4024 專案。
  - Remote Manager 資料夾:registry `TwinCATDir` 先看 WOW6432Node、再看 native view,用第一個有 `Build_*` 資料夾的 view。資料夾要名字完全是 `Build_<build>.<revision>`、且直接含 `.dll`(實測 2026-11-12:32-bit TcXaeShell 的原生 DLL 直接從 `Build_4024.71` 載入)。找不到時 `data.solutionVersion.xaeInstall.remoteManagerReason` 說明原因:`dir-not-found`(沒有 `TwinCATDir` 或資料夾不存在)、`no-build-folders`(沒有合格的 `Build_*`)、`read-failed`(registry / 資料夾讀取失敗);`remoteManagerSearched[].ignored` 列出不算的資料夾與原因(`name` / `no-dll` / `read-failed`)。
  - (PR #255 review,fail closed)資料夾存在不代表 IDE 真的用那個版本(例如 32-bit Shell 在 Remote Manager 被手動切到別的版本)。所以 `remote-manager-match` 開完方案後讀回 `TcRemoteManager.Version`(只讀):等於 `3.1.<build>.<revision>` → `data.remoteManagerVerified = true`;讀不到 → 仍 success,`remoteManagerVerified = false` 加 `data.remoteManagerWarning`;不同 → `REMOTE_MANAGER_MISMATCH`(見下)。`tsproj-version` / `explicit` 不讀回。
  - 其他情況一律 `PROGID_REQUIRED`:4026 專案版本不同、XAE Base 讀不到、沒有完全相等的 Remote Manager 資料夾(例如只有 `Build_4024.59` 卻是 4024.71 的專案)、找不到 TwinCAT 目錄。hint 寫明上面的分工。
  - 沒有註冊 / 沒整合 XAE 的候選 → `IDE_VERSION_NOT_REGISTERED`。
- **已知限制**:
  - revision 嚴格比較：查不到 Beckhoff 對「同 build 不同 revision」的相容規則(Remote Manager 頁只說 pin 的專案在原版本沒裝時會「提供」同 release 最新的 revision,要人選)。所以 `3.1.4026.19` 的專案在 XAE `3.1.4026.22` 的機器上也要帶 `-ProgId`。
  - XAE 開「沒有 pin 版本」的專案時用哪個 Remote Manager 版本,InfoSys 沒寫([Selection of a TwinCAT 3 version before loading a project](https://infosys.beckhoff.com/content/1033/tc3_remote_manager/3154642571.html) 只講 pin 的專案)。`Get-TcIdeInfo` 的 `data.remoteManagerVersion` 讀 `DTE.GetObject('TcRemoteManager').Version`(只讀,不設;[Accessing TwinCAT Remote Manager](https://infosys.beckhoff.com/content/1033/tc3_automationinterface/2507904267.html)),讀不到時 `data.remoteManagerError` 寫原因。實測 2026-11-12(本機,XAE 3.1.4026.22,registered tcauto,副本 `C:\Temp\Verify-4024-bfh`,`TcVersion="3.1.4024.71"`):`Connect-TcIde` 不帶 `-ProgId` → `TcXaeShell.DTE.15.0`(`remote-manager-match`),`data.remoteManagerVersion = 3.1.4024.71`;IDE 行程載入的原生 DLL 來自 `...\Components\Base\Build_4024.71`(沒有其他 `Build_*` 資料夾);Build 0 error;`.tsproj` 開啟、建置、關閉後 SHA256 不變(沒有被升版)。
  - 只裝 4026 32-bit TcXaeShell 的機器，開 4026 專案會回 `IDE_VERSION_NOT_REGISTERED`,要帶 `-ProgId 'TcXaeShell.DTE.15.0'`。
  - 不帶 `-SolutionPath`、又註冊了多個 IDE 時，現在回 `PROGID_REQUIRED`,不再預設開第一個(多 IDE 的機器要帶 `-ProgId`,或帶 `.tsproj` `TcVersion` 讀得到的 `-SolutionPath`)。

### PROGID_REQUIRED

- **現象**:`Connect-TcIde` 沒啟動任何 IDE,回 `PROGID_REQUIRED`。`data.registeredProgIds` 是註冊了的 ProgID,`data.solutionVersion.reason` 是無法決定的原因:沒給 `-SolutionPath`、某個 .tsproj 缺檔 / XML 壞掉 / 沒有 `TcVersion`、多個 .tsproj 的 build 不同，或沒有任何候選 IDE 的 XAE 版本完全等於專案的 `TcVersion`(含 revision;XAE Base 讀不到也算)。
- **為什麼**:不帶 `-ProgId` 又無法確定該用哪個 IDE 時，模組不猜(#72)。
- **下一步**:帶 `-ProgId` 重跑:4024 專案 → `TcXaeShell.DTE.15.0`(32-bit XAE Shell,XAE 4026.x + Remote Manager 4024.x);4026 專案 → `TcXaeShell.DTE.17.0` 或 `VisualStudio.DTE.17.0`。4024 專案沒自動選到 32-bit Shell,通常是沒裝完全相同版本的 Remote Manager(`data.solutionVersion.xaeInstall.remoteManagerBuilds`)。這時 hint 會附上 `Get-TcPackageInfo` / `Install-TcPackage` 的建議(`data.remoteManagerInstall`,#229,見「tcpkg:查 / 裝 XAE 與 Remote Manager 版本」),只提示、不會自動安裝。

### REMOTE_MANAGER_MISMATCH

- **現象(#225,PR #255 review)**:`Connect-TcIde` 不帶 `-ProgId`,依 Remote Manager 資料夾(`remote-manager-match`)開了 32-bit XAE Shell,但開完方案後讀回的 `TcRemoteManager.Version`(`data.actual`)不等於專案的 `TcVersion`(`data.expected`,`3.1.<build>.<revision>`)。`data.remoteManagerVerified = false`、`data.connected = false`。
- **為什麼**:選 IDE 只看 `Build_<build>.<revision>` 資料夾在不在;IDE 實際用哪個 Remote Manager 版本開「沒有 pin 版本」的專案,InfoSys 沒寫([Selection of a TwinCAT 3 version before loading a project](https://infosys.beckhoff.com/content/1033/tc3_remote_manager/3154642571.html) 只講 pin 的專案)。版本不同時在這個 IDE 裡 Build / 存檔,專案可能被升版,所以 fail closed。
- **模組做了什麼**:沒有存檔、沒有任何寫檔動作;立刻釋放 COM 連線(之後的 IDE 工具回 `NOT_CONNECTED`),IDE 還開著，歸本 session(pid 保留，和啟動中的 IDE 一樣)。
- **下一步**:`Disconnect-TcIde -Quit -Kill`(MCP:`DisconnectIde Quit=true Kill=true`)關掉它(不存檔)。再請使用者在 XAE 的 Remote Manager 工具列確認 / 切到 `data.expected`,或確認要用哪個 IDE 後帶 `-ProgId` 重開。

### IDE_VERSION_NOT_REGISTERED

- **現象**:`.tsproj` 的 `TcVersion` 讀得到(`data.solutionVersion.tsprojects`),但對應的 IDE ProgID 沒註冊，或沒有確認到它整合了夠新的 TwinCAT XAE(XAE Base manifest,見「啟動哪個 IDE(#72)」),沒啟動任何 IDE。
- **為什麼**:用別的版本的 XAE 開，專案可能被改寫或降版(#72),所以不自動換一個。
- **下一步**:確定要用某個 IDE 就帶 `-ProgId` 重跑;否則先安裝對應 build 的 XAE。見「啟動哪個 IDE(#72)」的已知限制。

### SOLUTION_NOT_FOUND

- **現象(#214)**:`Get-TcProjectVersion`(MCP `GetProjectVersion`)回 `SOLUTION_NOT_FOUND`:`-SolutionPath` 不存在、是資料夾,或 .sln 讀不了(訊息有原因)。
- **為什麼**:這個 cmdlet 只讀 .sln / .tsproj 檔,沒有 IDE 可以問。
- **下一步**:確認 `-SolutionPath` 是 .sln 的路徑(相對路徑從目前工作目錄解析)再重跑。

### TSPROJ_NOT_FOUND

- **現象(#214)**:`Get-TcProjectVersion` 回 `TSPROJ_NOT_FOUND`:.sln 裡沒有任何 `Project(...)` 行引用 .tsproj,所以沒有 `TcVersion` 可讀(只看 .tsproj,見「啟動哪個 IDE(#72)」)。
- **下一步**:確認 `-SolutionPath` 指到 TwinCAT 的 .sln,不是只含 PLC 專案(.plcproj)或其他類型的 solution。

### TCVERSION_UNKNOWN

- **現象(#214)**:`Get-TcProjectVersion` 回 `TCVERSION_UNKNOWN`:至少一個被引用的 .tsproj 的版本讀不到。能讀的專案照樣列在 `data.projects`,讀不到的看 `data.projects[].error`。
- **為什麼**:`Connect-TcIde` 對同樣的專案也無法依版本選 IDE,會回 `PROGID_REQUIRED`(#72)。
- **下一步(依 `data.projects[].error`)**:
  - `file not found`:.sln 的 `Project(...)` 引用路徑不對或檔案被移走,修正 .sln 裡的引用。
  - `unreadable`:.tsproj 不是合法 XML(壞掉或被截斷),從版控還原。
  - `no TcVersion attribute on the root element`,或 `TcVersion` 不是 `3.1.<build>.<revision>`(`error` 為 null、`build` 為 null):不要猜版本。要用專案原本 build 的 XAE 開啟(#72)。「用 XAE 開啟並存檔會補上 `TcVersion`」沒有 InfoSys 說明也沒實測過,所以這裡不建議。在那之前 `Connect-TcIde` 要帶 `-ProgId`,先問使用者。

### tcpkg:查 / 裝 XAE 與 Remote Manager 版本(#229)

- **兩個 cmdlet**:`Get-TcPackageInfo`(MCP `GetPackageInfo`,唯讀)與 `Install-TcPackage`(MCP `InstallPackage`,預設只回計畫)。都只呼叫 TwinCAT Package Manager 的命令列工具 `tcpkg`([Working with the command line](https://infosys.beckhoff.com/content/1033/tc3_installation/15698626059.html)),feed 與 myBeckhoff 帳號由使用者自己在 Package Manager 設定,模組不讀、不存、不傳帳號密碼。
- **查詢**:`tcpkg list -i --as-json`(已安裝)與 `tcpkg list <id> -a --as-json`(feed 上所有版本,每個 id 一次,走網路)([tcpkg list](https://infosys.beckhoff.com/content/1033/tc3_installation/21007205899.html))。預設 id:`TwinCAT.Standard.XAE`、`TwinCAT.Standard.XAR`、`TwinCAT.StandardRM.XAE`(Remote Manager)。每個 `TwinCAT.StandardRM.XAE` 版本附 `buildFolder`(`Build_<a>.<b>`)與 `buildFolderExists`(資料夾裡有 .dll,和 `Connect-TcIde` 選 IDE 用的同一個檢查)。
- **安裝**:`Install-TcPackage -PackageId <id> -Version <ver>` 不帶 `-Approved` 時什麼都不裝,回 `data.executed = false`、`data.plan`(完整指令 `tcpkg install <id>=<ver> -y`、需要系統管理員、要關的 IDE / tcpkg 與 pid、`blockers`)和 `data.planToken`。把 `data.plan` 給使用者看,同意後才帶 `-Approved -PlanToken <data.planToken>`(MCP `Approved=true PlanToken=...`)。token 只能用一次、約 10 分鐘、只在同一個 PowerShell / MCP bridge 行程內有效,而且綁定計畫當下的指令與狀態(見「TCPKG_PLAN_REQUIRED」)。只執行 `%ProgramData%\Beckhoff\TcPkg\TcPkg.exe`,且要有 Beckhoff 的有效 Authenticode 簽章(見「TCPKG_SIGNATURE_INVALID」);`Get-TcPackageInfo` 找不到時才退回 PATH。之後讀回 `tcpkg list -i`,列出該版本才算成功(fail closed)。`-PackageId` 只接受 `TwinCAT.Standard.XAE` / `TwinCAT.StandardRM.XAE`(拒絕 runtime 的 XAR);但 tcpkg 會自己解析相依套件,`-y` 也一併確認,計畫只列目標套件。裝完 `data.changedPackages` 是前後 `list -i` 的差異,目標以外的變動列在 `data.unexpectedChanges` / `data.warnings`。Remote Manager 裝完找不到 `Build_` 資料夾也會進 `data.warnings`。`ID=版本`、`-y`、需要系統管理員、XAE Shell / Visual Studio 可能要關:[tcpkg install](https://infosys.beckhoff.com/content/1033/tc3_installation/21007208203.html)。
- **實測(2026-11-12,Windows 11 zh-TW,TcPkg 2.4.18,只跑唯讀 list / source list / --help)**:`list -i` 約 1.7 MB、1.4–1.7 s;`list <id> -a` 每次 3–9 s;`TcPkg.exe` 的 Authenticode 簽章 Valid,簽署者 `O=Beckhoff Automation GmbH & Co. KG`;開始功能表「TwinCAT Package Manager」捷徑指向 `C:\ProgramData\Beckhoff\TcPkgUi\Gui\TwinCAT.Package.Manager.GUI.exe`(UI 行程名稱依此推定,沒看過它執行中的行程);`TwinCAT.StandardRM.XAE 4024.71.2` 對應 `Build_4024.71`(資料夾去掉第三段);已安裝的 4024.71.2 不在 feed(feed 只有 4024.71.5);不存在的 id 回 exit 144、純文字(不是 JSON)。`install` 本身沒有在真機執行過,只有單元測試的 mock。
- **`PROGID_REQUIRED` 的安裝建議**:4024 專案只缺「完全相同版本」的 Remote Manager 資料夾時,`Connect-TcIde` / `Get-TcProjectVersion` 的 hint 附上 `Get-TcPackageInfo` / `Install-TcPackage` 的用法,`data.remoteManagerInstall`(`Get-TcProjectVersion` 在 `data.launch.remoteManagerInstall`)有 `build` / `buildFolder` / `versionPrefix`。只是提示,不會自動查或裝。

### TCPKG_NOT_FOUND

- **現象**:`Get-TcPackageInfo` / `Install-TcPackage` 回 `TCPKG_NOT_FOUND`:PATH 上沒有 `tcpkg`,也沒有 `%ProgramData%\Beckhoff\TcPkg\TcPkg.exe`(實測 2026-11-12 的安裝位置)。什麼都沒查、沒裝。
- **下一步**:請使用者安裝 TwinCAT Package Manager([Package Manager](https://infosys.beckhoff.com/content/1033/tc3_installation/15698617995.html))並設定 feed,或自己安裝需要的 XAE / Remote Manager 版本。

### TCPKG_TIMEOUT

- **現象**:某個 `tcpkg` 呼叫在 `-TimeoutSec`(查詢預設每次 60 s、最多 120 s;`Install-TcPackage` 的安裝預設 1800 s、最多 6600 s,list 每次 120 s)內沒結束。`data.runs` / `data.steps` 有指令與耗時。查詢的 `list` 會被停掉;**安裝不會**,留著它跑,`data.installProcessId` 是它的 pid,不讀回。設計考量(未實測):tcpkg 會不會另外啟動安裝程式沒有驗證過;如果會,停掉 tcpkg.exe 停不了它們(.NET Framework 沒有停整個行程樹的 API),而半途被殺的安裝比讓它跑完更難收拾。
- **下一步**:查詢 → feed 是網路查詢,先用 `Get-TcPackageInfo -NoAvailable` 看已安裝的,或加大 `-TimeoutSec`。安裝逾時 → 可能還在背景安裝、狀態未知,不要重跑;等 `data.installProcessId` 結束後再 `Get-TcPackageInfo -PackageId <id>` 讀回,把結果給使用者看,請使用者在 Package Manager UI 確認。

### TCPKG_LIST_FAILED

- **現象**:`tcpkg list` 的 exit code 不是 0,或輸出不是 JSON 陣列。`data.runs[].stderrTail` / `stdoutTail` 是 tcpkg 的訊息。
- **為什麼**:套件名稱要完全相同(不存在的 id:exit 144,實測 2026-11-12)。feed 連不到、沒登入 myBeckhoff 時的行為沒有實測過,看 tcpkg 的訊息。
- **下一步**:請使用者在 Package Manager 確認 feed(`tcpkg source list`);只需要已安裝清單時用 `-NoAvailable`。

### TCPKG_ELEVATION_REQUIRED

- **現象**:`Install-TcPackage -Approved`,但這個 PowerShell / MCP server 沒有系統管理員權限。什麼都沒裝,模組也不會自己跳 UAC 提權。
- **下一步**:請使用者自己用系統管理員身分執行 `data.command`(或在 Package Manager UI 安裝),再用 `Get-TcPackageInfo -PackageId <id>` 讀回。

### TCPKG_IDE_RUNNING

- **現象**:`Install-TcPackage -Approved`,但有 `TcXaeShell` / `devenv` 在跑(`data.runningIdes`:pid、路徑、視窗標題)。什麼都沒裝。
- **下一步**:把清單給使用者看,由使用者自己存檔、關掉;不要自己關或 kill(本 session 開的 IDE 也要先經使用者同意才 `Disconnect-TcIde -Quit`)。都關掉後再帶 `-Approved` 重跑。

### TCPKG_VERSION_NOT_FOUND

- **現象**:`Install-TcPackage -Approved` 的 `-Version` 不在任何已設定的 feed 上(`data.availableVersions`)。什麼都沒裝。
- **為什麼**:feed 不一定還有原本那一版(實測 2026-11-12:已安裝的 4024.71.2 不在 feed,只有 4024.71.5;4024.x 的 Remote Manager 版本列在 Beckhoff Outdated Feed)。
- **下一步**:從 `data.availableVersions` 選版本給使用者確認,再跑 `Install-TcPackage`(先不帶 `-Approved` 看計畫)。沒有 Outdated Feed 時請使用者自己加。

### TCPKG_INSTALL_FAILED

- **現象**:`tcpkg install` 回非 0 的 exit code,或無法啟動。`data.steps` 的 install 步驟有 `stdoutTail` / `stderrTail`,`data.installedVersions` 是讀回的已安裝版本;`error.message` 註明讀回時目標版本有沒有列出(listed / not listed / unknown)。
- **下一步**:不要自己重試或改參數;把訊息給使用者看,請使用者在 Package Manager UI 檢查(feed 登入、磁碟空間、被鎖住的檔案)。

### TCPKG_PLAN_REQUIRED

- **現象(#229 PR #257 review)**:`Install-TcPackage -Approved`(MCP `Approved=true`)沒有執行任何東西。`data.reason`:`missing`(沒帶 `-PlanToken`)、`unknown`(不認得或已經用過:token 只能用一次,server / bridge 重啟、`ReloadModule` 後全部失效)、`expired`(約 10 分鐘)、`command`(token 是別的套件 / 版本的計畫)、`state`(token 有效但計畫之後狀態變了:權限、blockers、IDE / tcpkg 的 pid、feed、已安裝;訊息會列出計畫與現在的狀態)。過期用單調時鐘(`Stopwatch.GetTimestamp`)判斷,改系統時間不會延長或縮短;`data.plan.expiresAtUtc` 只是顯示用。
- **為什麼**:使用者規則是「詢問後,得到許可才安裝」。token 把同意綁在使用者看過的那份計畫上,agent 不能跳過計畫直接帶 `Approved=true`。
- **下一步**:不帶 `-Approved` 重新產生計畫,把 `data.plan` 給使用者看,使用者同意後才帶 `-Approved -PlanToken <新的 data.planToken>`。

### TCPKG_SIGNATURE_INVALID

- **現象**:`Install-TcPackage`(計畫或執行)回 `TCPKG_SIGNATURE_INVALID`:`%ProgramData%\Beckhoff\TcPkg\TcPkg.exe` 的 Authenticode 狀態不是 `Valid`、簽署者的 `O=` 不是 `Beckhoff Automation GmbH & Co. KG`,或簽章檢查本身失敗(一律當成不通過,fail closed)。什麼都沒執行,也沒有 token。
- **為什麼**:安裝要用系統管理員權限跑,只能跑確定是 Beckhoff 的那一個檔案;`Install-TcPackage` 不用 PATH 上的 tcpkg,資料夾用 `[Environment]::GetFolderPath('CommonApplicationData')`,不看可被呼叫端改掉的 `$env:ProgramData`。簽署者從憑證 Subject 的 DER 編碼逐個 RDN 讀,必須剛好一個 `O`(organizationName)且完全等於 `Beckhoff Automation GmbH & Co. KG`;不解析顯示字串,所以帶引號的 CN / OU 裡藏 `, O=Beckhoff...` 騙不過。發行者(實測:`CN=DigiCert Trusted G4 Code Signing RSA4096 SHA384 2021 CA1, O="DigiCert, Inc.", C=US`)只回報在 `data.signature.issuer`,不鎖定:`Valid` 已要求鏈到受信任的根,鎖 CA 會擋掉 Beckhoff 換 CA 後的下一張憑證。實測 2026-11-12:TcPkg 2.4.18 的簽章 Valid,簽署者 `CN=Beckhoff Automation GmbH & Co. KG, O=Beckhoff Automation GmbH & Co. KG, L=Verl, S=Nordrhein-Westfalen, C=DE`。
- **下一步**:不要改用別的路徑;把 `error.message`(狀態、簽署者)給使用者看,請使用者確認 TwinCAT Package Manager 的安裝。
- **已知風險(實測 2026-11-12,`icacls`,未處理,#260)**:`C:\ProgramData\Beckhoff\TcPkg` 繼承了 `BUILTIN\Users:(I)(CI)(WD,AD,WEA,WA)`,一般使用者可以在 `TcPkg.exe` 旁新增檔案。簽章只驗 `TcPkg.exe` 本身,以系統管理員執行時有 DLL 側載的可能(推論,載入順序沒驗證)。是否在安裝前檢查資料夾 ACL 由 #260 評估。

### TCPKG_RUNNING

- **現象**:`Install-TcPackage -Approved`,但有 `TcPkg`(另一個 tcpkg)或 `TwinCAT.Package.Manager.GUI`(Package Manager UI)在跑(`data.runningPackageManager`)。什麼都沒裝。UI 的行程名稱取自開始功能表捷徑的目標 exe(2026-11-12),沒看過它執行中的行程。
- **下一步**:請使用者等它結束或自己關掉 UI,不要自己 kill;再重新產生計畫、取得同意。

### TCPKG_PRECHECK_FAILED

- **現象**:列舉執行中的 IDE / tcpkg 行程時出例外(`data.processScanError`),計畫的 `blockers` 有 `process-scan-failed`。`-Approved` 時什麼都沒裝。
- **為什麼**:讀不到清單不等於沒有 IDE 在跑,所以當成 blocker(fail closed)。
- **下一步**:把訊息給使用者看,確認權限 / 環境後重新產生計畫再試。

### TCPKG_INSTALL_UNVERIFIED

- **現象**:`tcpkg install` 回 exit 0,但讀回的 `tcpkg list -i` 沒有這個版本(`data.steps` 的 readback 步驟)。不算成功(fail closed)。原因未知,沒有實測過。
- **下一步**:先 `Get-TcPackageInfo -PackageId <id>` 再讀一次,把結果給使用者看;不要直接再裝一次。

### IDE_LAUNCH_PENDING

- **現象(#136)**:`Connect-TcIde` 回 `IDE_LAUNCH_PENDING`,沒有啟動第二個 IDE。`data.ideProcessId` / `data.ideStartTime` 是本 session 為同一個 .sln 啟動的 IDE(`data.pidConfirmed = false` 時是 0),`data.waitedSec` 是這次等了多久(最多 60 s,`-NoLaunch` 也會等)。`data.probe` 是原因:
  - `not-in-rot`:還沒登記到 ROT。
  - `busy`:RPC_E_CALL_REJECTED。
  - `unreadable`:DTE.Version 空白。
  - `scan-incomplete`:modal 掃描沒完成，所以沒讀 DTE(帶 `data.modalScan`)。
  - `pid-unconfirmed`:pid 無法確認，見下面 M2。
  - `progid-mismatch`:它是用別的 ProgID 啟動的(`data.progIdMismatch = { requested; launched }`)。
  - `other-session`:是另一個 TcAuto session(bridge)啟動的(`data.otherSession = { hostPid; hostState; ownerPid; ownerState; moduleInstanceId; processId; pidSource }`),不 attach、不算 owned、`data.ideProcessId = 0`,見「啟動紀錄持久化(#73 / #149)」。`hostState = 'alive'`:那個 bridge 還在(或無法確認);`'gone'`:那個 bridge 不在了。`hostState = 'gone'` 而且 `ownerState` 是 `gone`(MCP server 也結束了)或 `none`(手動 PowerShell 的紀錄，沒有 owner)時，訊息寫「has ended」,hint 會提到 `-TakeOverOrphan`(見下面「孤兒 IDE 接管」);`ownerState = 'alive' / 'unverifiable'` 時只是 bridge 重開過，那個 session 可能還在，不會提 `-TakeOverOrphan`。
  - 那個 IDE 有 modal dialog 時改回 `IDE_MODAL_DIALOG`。
- **為什麼**:VS2022 冷啟動時，第一次 `Connect-TcIde` 可能在開 solution 前就回 `MODAL_SCAN_INCOMPLETE`;舊版重試時找不到「開著這個 .sln 的 IDE」,又多開一個 VS2022。現在模組記下本 session 為哪個 .sln 啟動了哪個 IDE:DTE 物件、ProgID、確認過的 pid + StartTime。重試時:
  - 那個行程還在(pid 與 StartTime 都相同，回收的 pid 不算),就先掃 modal dialog,再讀 DTE,回應了就 attach(`data.selectedBy = 'session-launched'`,`ownedBySession = true`)。
  - **同一個 .sln 在本 session 有啟動中的 IDE 時，絕不再啟動第二個**,`-LaunchIfBlocked`、`-NoLaunch` 也一樣。
  - 只有那個 IDE 已改開別的 solution，或行程已結束，才放行。
  - 這份紀錄也寫進 `launched-ides.json`(#149),bridge 重啟 / `ReloadModule` 之後一樣有效，見「啟動紀錄持久化(#73 / #149)」。
- **pid 怎麼確認(#147 M2)**:
  - 啟動後，從 ROT 找「物件就是這個 DTE」的項目，pid 取 moniker `!<ProgId>:<pid>`(`data.pidSource = 'rot-identity'`);或用 DTE 自己的主視窗(`main-window`)。
  - 只能用「啟動時間之後最新的 IDE 行程」猜的 pid(`start-time`)可能是同時冒出來的使用者 IDE:這種 pid 不記錄、不 attach、不算 `ownedBySession`,直接回 `IDE_LAUNCH_PENDING`(`probe = 'pid-unconfirmed'`,`data.guessedProcessId` 只供參考)。
  - 之後 ROT 出現同一個 DTE 物件時才確認 pid。啟動後沒有任何同 exe 的新行程還活著時，記錄才丟掉。
- **下一步**:
  - `Get-TcIdeModalDialog -ProcessId <data.ideProcessId>` 看有沒有 dialog,關掉後重跑同一個 `Connect-TcIde`;還在啟動就稍後重跑。
  - 要換 ProgId，或 IDE 卡死:`data.ownedBySession = true` 時 `Disconnect-TcIde -Quit -Kill`(只殺本 session 確認過的這個 pid)後再 `Connect-TcIde`。
  - `pid-unconfirmed` 時模組不殺任何行程：自己確認並關掉那個 IDE(或確定它已不在),再 `Disconnect-TcIde -ForgetPendingLaunch`(MCP `DisconnectIde ForgetPendingLaunch=true`;只清掉 pid 未確認的啟動紀錄，不關 IDE、不動連線，回 `data.forgottenLaunches`),然後重跑 `Connect-TcIde`。
  - `other-session` 且 `hostState = 'gone'`:`gone` 只代表 bridge 不在了，session 有沒有結束要看 `data.otherSession.ownerState`。只有 `ownerState` 是 `gone` 或 `none` 才代表那個 session 已結束，見下面「孤兒 IDE 接管」(使用者確認沒人在用後才加 `-TakeOverOrphan`);`ownerState` 是 `alive` 或 `unverifiable` 時，那個 session 只是 bridge 重開過，可能還在用，不要接管。
- **孤兒 IDE 接管(#196)**:
  - **現象**:worker session(例如 headless `claude -p`)用 ConnectIde 啟動 IDE 後沒 Quit 就結束了。之後其他 session 的 `Connect-TcIde -SolutionPath <sln>`:IDE 有 dialog 時回 `IDE_LAUNCH_PENDING`(`probe = 'other-session'`、`hostState = 'gone'`);dialog 關掉之後,solution-match 會以 not owned 的身分 attach(未實測),但不能用模組 `-Quit -Kill` 關掉它。`-TakeOverOrphan` 是用來取得它的 ownership 的(`IDE_LAUNCH_PENDING` 部分實測 2026-11-08,registered tcauto master d3644b6,本機 VS2022 devenv 與 4024 TcXaeShell 各一,`pidSource = 'rot-identity'`)。
  - **預設仍 fail closed**:不帶參數時行為不變，不會自動接管(那個 IDE 可能已經有使用者在用、有未存檔的修改)。
  - **明確接管**:先問使用者那個 IDE 沒人在用，再重跑同一個 `Connect-TcIde -SolutionPath <sln> -TakeOverOrphan`(MCP `ConnectIde TakeOverOrphan=true`)。全部成立才接管:
    1. 有 `-SolutionPath`,而且 `launched-ides.json` 有這個 sln(同一套路徑正規化比較)的有效紀錄(IDE 的 pid、StartTime、image name 都和紀錄相同);
    2. 紀錄的 host 已不在(`hostState = 'gone'`:`hostPid` 不存在，或存在但 StartTime 和 `hostStartTime` 不同，所以回收的 pid 不會被當成原 host);
    2b. 紀錄的 owner(MCP server)也已不在(#196 review B1)。host 只是 bridge(PowerShell 子行程):同一個 MCP server 遇到 `BRIDGE_TIMEOUT`、`IDE_MODAL_DIALOG` 或 `ReloadModule` 會重開 bridge,`ownerId` 不變但 pid 換了，所以單看 host 會把還在用的 session 當成結束。MCP server 把 owner 行程的 pid 用 `TCAUTO_OWNER_PID` 傳給 bridge(launcher 啟動時是 launcher 的 pid,它跨 `ReloadRuntime` 不變;否則是 index.js 自己),模組 import 時讀它的 StartTime,寫成紀錄的 `ownerPid` / `ownerStartTime`。`ownerPid` 不存在或 StartTime 不同 = gone;還在 = 拒絕 `owner-alive`;紀錄有 `ownerId` 卻沒有 `ownerPid` / `ownerStartTime`(修正前寫的紀錄)或讀不到它的 StartTime = 拒絕 `owner-unverifiable`;沒有 `ownerId` 的紀錄(手動 PowerShell)沒有 owner,只看 host;
    3. pid 已確認(`pidSource` 是 `rot-identity` / `main-window`),`-ProgId`(有給的話)和啟動時的相同;
    4. ROT 裡那個 pid 的 DTE 可以回應，而且開著這個 sln;
    5. 那個 IDE 沒有 modal dialog,掃描也完成。
  - **成功**:attach 那個 IDE(`data.selectedBy = 'orphan-takeover'`、`data.takenOver = true`、`data.previousOwner = { hostPid; hostStartTime; moduleInstanceId; ownerId; hostState; ownerPid; ownerState }`、`data.ownedBySession = true`),之後 `Disconnect-TcIde -Quit` / `-Quit -Kill` 都可以用。紀錄在 attach、modal 檢查和專案掃描(ITcSysManager)都通過**之後**才改寫(#196 review M2:中途失敗回 `success: false` 時擁有權不會轉移),改寫前在鎖內重新確認(同一個 IDE 行程、同一個舊 host、host 和 owner 仍不在):擁有者換成本行程(`hostPid` / `hostStartTime` / `moduleInstanceId` / `ownerId` / `ownerPid` / `ownerStartTime`),`takeovers[]` 加一筆(`takenOverAt`、`reason = 'orphan-takeover'`、`previousHostPid` / `previousHostStartTime` / `previousModuleInstanceId` / `previousOwnerId` / `previousOwnerPid`、新的 `hostPid` / `moduleInstanceId`)。鎖內確認不過(`record-changed` / `host-not-gone` / `owner-alive` / `owner-unverifiable`)、本行程的 owner StartTime 讀不到(`owner-start-time-unreadable`,寫了會讓這筆紀錄以後永遠 unverifiable)、寫不進去，或 attach 之後任何一步失敗(dialog、`PROJECT_OPEN_*`、`IDE_CRASHED`)時，剛才的 attach 會放掉，不留連線。SilentMode 不還原(那時可能已經有別的 session 接管、依賴它是 true;啟動那個 IDE 的 session 本來就把它設成 true)。
  - **不成立**:不 attach、不改紀錄，回 `ORPHAN_TAKEOVER_REFUSED`(`data.reason`,`data.otherSession` 照帶);有 dialog 回 `IDE_MODAL_DIALOG`、掃描沒完成回 `MODAL_SCAN_INCOMPLETE`;紀錄檔讀不到或寫不進去回 `LAUNCH_RECORD_UNAVAILABLE`(fail closed)。不會退回其他選 IDE 的路徑。
  - **限制**:ROT 裡看不到那個 IDE(例如權限層級不同)、或它忙碌時，接管被拒(`not-in-rot` / `ide-busy`),只能請使用者自己關。單元測試:`tests/Unit/orphan-takeover-196.ps1`。
  - **實測 2026-11-08**(本機 UmRT、4026 副本 `C:\Temp\Verify-4026-axis`、VS2022 `VisualStudio.DTE.17.0`、registered tcauto 跑 branch runtime commit 49276ed,review 第二輪修正後在 519b0cc 重跑兩個情境結果相同):
    - 接管成功:headless `claude -p` session 用 ConnectIde 啟動 VS2022(pid 49128)後沒 Quit 就結束(host 50692、owner 49808 都不在);另一個 `claude -p` session `ConnectIde TakeOverOrphan=true` → `success`、`selectedBy = 'orphan-takeover'`、`takenOver = true`、`previousOwner.hostState = ownerState = 'gone'`,接著 `DisconnectIde Quit=true` 成功關掉。
    - 拒絕(bridge 重開、server 還在):session A 啟動 VS2022(pid 1996)後呼叫 `ReloadModule`(舊 bridge 31332 已不在,owner 56904 還在),另一個 `claude -p` session `TakeOverOrphan=true` → `ORPHAN_TAKEOVER_REFUSED (owner-alive)`,紀錄沒變;session A 再 ConnectIde 仍是 `ownedBySession = true`,`DisconnectIde Quit=true` 成功。

### 啟動紀錄持久化(#73 / #149)

- **現象(修正前)**:MCP bridge 重啟(`BRIDGE_TIMEOUT`、`IDE_MODAL_DIALOG` 之後的重啟)、`ReloadModule` 或 `Import-Module -Force` 之後，本 session 啟動的 IDE 的 launch / ownership 紀錄只在舊的模組記憶體裡，跟著消失:
  - `Connect-TcIde` 再連到同一個 pid 時 `ownedBySession = false`,`Disconnect-TcIde -Quit -Kill` 回 `IDE_NOT_OWNED`(#73,實測 2026-11-05,4024 TcXaeShell 32-bit,PR #129 ReloadModule 驗證)。
  - 那個 IDE 還在冷啟動時，重試的 `Connect-TcIde -SolutionPath` 可能再開第二個 IDE(#149)。
- **現在**:每次啟動 IDE、拿到 pid(確認的或猜的)時，寫一筆紀錄到 `<Get-TcStateDir>\launched-ides.json`(`TCAUTO_STATE_DIR`,沒設就是 `%TEMP%\TwinCATAutomation`)。
  - 欄位:`launchId`、`pid`、`startTime`(UTC)、`imageName`(行程名稱，不含 .exe)、`progId`、`solution`、`pidSource`、`launchedAt` / `createdAt` / `updatedAt`(UTC)、`moduleInstanceId`(寫入的模組 instance)、`hostPid` + `hostStartTime`(寫入或接手這筆紀錄的 PowerShell / bridge 行程)、`ownerId`(寫入時的 `TCAUTO_OWNER_ID`)。
  - `TCAUTO_OWNER_ID`:MCP server(node)啟動時產生一個 GUID,傳給它 spawn 的每個 PowerShell bridge(第一次啟動、`BRIDGE_TIMEOUT` / `IDE_MODAL_DIALOG` 之後的重啟、`ReloadModule` 都是同一個值);另一個 MCP server / 對話的值不同。手動開的 PowerShell 沒有這個值。
  - 經 launcher 啟動時(#162):GUID 改由 launcher 產生，一個 launcher 行程一個值，傳給它啟動的每個 runtime(`TCAUTO_LAUNCHER_OWNER_ID`,加上 `TCAUTO_LAUNCHER_PID` = launcher 自己的 pid);`index.js` 只在 `TCAUTO_LAUNCHER_PID` 等於自己的父行程 pid 時採用，否則照舊自己產生。所以 `ReloadRuntime` 前後的 bridge 是同一個 owner,可以接手前一個 runtime 啟動的 IDE;client 重連(新的 launcher 行程)仍是新的值。接手規則本身沒有放寬(仍要 host 已不在 + ownerId 相同):`ReloadRuntime` 會等舊 runtime 的 PowerShell 結束後才啟動新 runtime。
  - 鎖的做法和 `ide-solutions.json` 一樣:read-modify-write 在 named mutex `Local\TwinCATAutomation-launched-ides` 下進行;設了 `TCAUTO_STATE_DIR` 時，名稱加上該目錄的 hash。`[IO.File]::Replace` 原子取代檔案。
  - 模組記憶體只當快取。記憶體沒有的，就讀檔案。
- **讀回時一定驗證**:pid 存在、StartTime 和 image name 都和紀錄相同，而且 image name 是 IDE(`TcXaeShell` / `devenv`),才算數，所以回收的 pid 不會被當成自己的。不符的紀錄不用。
- **寫入時清理(#152 m3)**:只丟「確定不是同一個行程」的紀錄：行程不存在，或 StartTime 讀得到但不符(以及 pid / StartTime 根本無法解析的格式錯誤紀錄)。StartTime 讀不到(例如權限)的紀錄保留原樣。
- **去重(#152 m1)**:同一個 `launchId`,或同一個 pid 且新紀錄是 confirmed,才取代舊紀錄。unconfirmed 的寫入不覆蓋 confirmed 的紀錄。
- **誰能恢復 ownership**:只有 `pidSource` 是 `rot-identity` 或 `main-window` 的紀錄可以(`Test-TcLaunchedIde` → `data.ownedBySession = true`,`-Kill` 允許),而且還要是自己的(#152 M1):
  - host 是自己:`hostPid` 等於本行程(`$PID`)而且 `hostStartTime` 相同。紀錄沒有 `hostStartTime`,或讀不到自己的 StartTime 時，不算自己(fail closed,#152 N2)。
  - 或 `hostPid` + `hostStartTime` 對應的行程已經不在(pid 不存在，或 StartTime 不同),**而且** `ownerId` 和本行程的 `TCAUTO_OWNER_ID` 相同(同一個 MCP server 的 bridge 重啟 / `ReloadModule`,#152 N1)。這種情況在鎖內改寫 host 欄位、接手這筆紀錄，另一個 bridge 就不會再搶。寫不進去就不接手(fail closed)。
  - 為什麼要 `ownerId`:對話 A 啟動 IDE(`UserControl = true`,IDE 留著)後結束，使用者接著在那個 IDE 手動改、還有未存檔的變更;隔天對話 B 的 `ConnectIde` 如果只看「host 已不在」就接手，`-Quit -Kill` 會丟掉使用者的變更。現在對話 B 的 `ownerId` 不同，不接手。
  - 其他情況(另一個還活著的 TcAuto session、別的 MCP server / 已結束的對話、沒有 `ownerId`、host 無法確認)一律視為別的 session 啟動的(`data.otherSession.hostState` 是 `alive` 或 `gone`):**仍擋住同一個 .sln 的第二次啟動**(`IDE_LAUNCH_PENDING`,`probe = 'other-session'`),但不 attach、不算 owned,`-Kill` 被拒(`IDE_NOT_OWNED`)。
  - 多個 bridge 共用同一個紀錄檔時，靠這個判斷不會認領對方啟動的 IDE。
  - **別的 session 的紀錄不會永久擋住這個 .sln(#152 R3-1)**:`Connect-TcIde` 選 IDE 時已從 ROT 讀到每個 IDE 的 pid 和開著的 solution(不多做 COM 呼叫)。紀錄的 pid 在其中而且開著**別的** solution(使用者在那個 IDE 關掉 X、改開 Y)→ 不擋，照常啟動;host 已不在時，那個 IDE 沒開任何 solution 也不擋。host 還活著而 solution 是空的(對方可能還在冷啟動)、或那個 IDE 忙碌 / 讀不到 → 仍擋。
  - `pid-unconfirmed`(pid 只是用啟動時間猜的，#147 M2)**永遠不恢復 ownership**。跨行程時沒有 DTE 物件可比對，也無法事後確認。
  - **猜到的 pid 仍會寫入**,只用來擋住同一個 .sln 的第二次啟動(`IDE_LAUNCH_PENDING`,`probe = 'pid-unconfirmed'`,猜的 pid 放在 `data.guessedProcessId`,`data.ideProcessId = 0`),不給 ownership。直到那個行程(檔案裡的 pid + StartTime)結束，或 `Disconnect-TcIde -ForgetPendingLaunch`(會一起清掉檔案裡的這筆;另一個還活著的 session 的紀錄不清，列在 `data.otherSessionLaunches`)。
  - 從檔案恢復的這種紀錄沒有 DTE 物件，永遠無法確認，所以不等待(不跑 60 s 的 wait),直接回 `pid-unconfirmed`。
  - **和 #149 原規格不同**:#149 寫「只寫入確認過的 pid」「未確認的記錄不能沿用」。這裡改成寫入、但只拿來擋啟動：#149 的目的就是 bridge 重啟後不要再開第二個 IDE,丟掉這筆就會再開;不給 ownership,所以不會殺錯或接錯使用者的 IDE。代價：如果猜到的其實是使用者的 IDE,它開著的期間這個 .sln 不會自動再啟動，要用 `-ForgetPendingLaunch` 解開。
- **清除**:`Disconnect-TcIde -Quit` 成功、`-Quit -Kill` 殺掉，或發現行程已結束(`alreadyExited`)時，刪掉該 pid 的紀錄(寫不進去時結果帶 `data.launchRecordWarning`)。IDE 改開別的 solution 時，紀錄保留 ownership,但 `solution` 清成 null。
- **fail closed**:紀錄檔讀不到(被鎖住、權限)或內容壞掉時，**不把任何 IDE 當成 owned**,也不拿它擋啟動;正常的 `ConnectIde` attach(solution-match 等)照常進行,`data.ownedBySession = false`。
  - 這次呼叫讀寫失敗時，`Connect-TcIde` / `Disconnect-TcIde` 的結果帶 `data.launchRecordWarning`。
  - 紀錄沒寫成也一樣(#152 N4):pid 不在、StartTime / image name 讀不到、image 不是 IDE、unconfirmed 被同 pid 的 confirmed 紀錄擋下、沒有 pid 可寫。這時這次啟動在 bridge 重啟後不受保護。
  - 下一次寫入時，壞掉的檔案改名成 `launched-ides.json.corrupt-<time>`,裡面的紀錄不再算數。
- **限制**:
  - 本 module instance 自己啟動的 IDE 記在記憶體，檔案壞掉也仍算 owned;從檔案恢復的也快取在記憶體。
  - 有設和沒設 `TCAUTO_STATE_DIR` 的行程用不同的檔案，彼此看不到。
  - **只涵蓋同一個 MCP server 內的 bridge 重啟與 `ReloadModule`,以及同一個 launcher 內的 `ReloadRuntime`(#152 R3-2、#162)**。MCP server 本身重啟(Claude Code 重連、server crash、重開 Claude Code)會產生新的 `TCAUTO_OWNER_ID`,之前啟動的 IDE 變成別的 session 的(fail closed):不算 owned、`-Kill` 被拒，仍擋同一個 .sln 的第二次啟動，直到那個 IDE 改開別的 solution 或結束。
  - 舊 bridge 行程在重啟後仍殘留(沒結束)時，新 bridge 不會接手它的紀錄(視為另一個還活著的 session,`hostState = 'alive'`)。**孤兒 bridge 的出路(#152 N3)**:`data.otherSession.hostPid` 是 `powershell.exe`,而且它所屬的 MCP server 已經不在時，請使用者確認後結束那個行程，再重跑 `Connect-TcIde`(之後同一個 MCP server 的 bridge 才能接手;別的 MCP server 仍然不會)。
  - 別的 MCP server / 已結束的對話啟動的 IDE(`hostState = 'gone'`,`ownerId` 不同)不會被自動接手：請使用者確認那個 IDE 不再需要後自己關掉，紀錄就會失效;或使用者同意後用 `Connect-TcIde -SolutionPath <sln> -TakeOverOrphan` 明確接管(#196,見「IDE_LAUNCH_PENDING」的孤兒 IDE 接管)。
  - 手動開的 PowerShell(沒有 `TCAUTO_OWNER_ID`)只認 host 是自己的紀錄:`Import-Module -Force` 之後仍算 owned,換一個 PowerShell 就不算。
  - **禁止的繞道**:不要手動刪改這個檔案;也不要在使用者 / 系統環境變數或手動 PowerShell 裡設 `TCAUTO_OWNER_ID`、`TCAUTO_LAUNCHER_OWNER_ID` / `TCAUTO_LAUNCHER_PID`(#152 R3-3、#162)。這個值只能由 MCP server 產生並傳給它的 bridge,自己設等於讓不同的 session 互相認領對方的 IDE。
- **需真機**:`ReloadModule` 之後，`Disconnect-TcIde -Quit -Kill` 仍能關掉本 session 啟動的 IDE。目前只有 mock 驗證(`tests/Unit/launch-record-persist-73.ps1`)。

### SilentMode 原值持久化(#233)

`Connect-TcIde` 把 IDE 的 `TcAutomationSettings.SilentMode` 設成 true 前,先記下原值,`Disconnect-TcIde` 還原。原值除了存在行程記憶體,也在**設 true 之前**寫進 `<TCAUTO_STATE_DIR 或 %TEMP%\TwinCATAutomation>\silent-originals.json`(`[{ pid; startTime; imageName; original; recordedAt }]`,key = IDE pid + 行程啟動時間,pid 重用不會對上;tmp + replace 原子寫入、具名 mutex;IDE 行程已不在的紀錄在每次寫入時清掉;還原成功後刪掉該筆)。所以前一個行程(agent 的上一次工具呼叫、重啟前的 MCP bridge)沒 `Disconnect-TcIde` 就結束時,下一個行程仍還原真正的原值。

- **Connect 的 data**:`silentModeOriginal` = 已知的原值(`true` / `false`);原值未知時是 `null`,這時看 `silentModeOriginalUnknown = true`,Disconnect 會還原成 false。`silentModeOriginalSource`:`read`(這次讀到 false)、`memory` / `state-file`(先前記下的)、`unknown-was-true`(沒有紀錄卻讀到 true)、`unreadable`(getter 失敗)。
- **原值未知 → 還原成 false**:沒有紀錄卻讀到 true(可能是先前某個 TcAuto 行程設的、沒還原),或 getter 讀不到(PR #266 review 1:setter 仍會設 true,不還原就會永遠停在 true)。紀錄寫成 `assumed-false`,之後每個行程都仍是 unknown。舊版寫的 `unknown` 紀錄也照這條處理。setter 本身失敗時 IDE 沒被改,這次寫的紀錄會撤回,Disconnect 不寫入。
  - 為什麼是 false:InfoSys 的 [Silent Mode 頁](https://infosys.beckhoff.com/content/1033/tc3_automationinterface/2489025803.html) 沒寫預設值、範圍或是否持久化。新啟動的 IDE 實測都是 false(2026-11-13,XAE 4026:`TcXaeShell.DTE.15.0` 32-bit 開 4024 專案、`VisualStudio.DTE.17.0`、`TcXaeShell.DTE.17.0` 64-bit)。還原成 false 是安全的一邊:XAE 的提示改回給使用者看,不會被自動用預設鈕回答。代價:使用者自己設成 true 的 IDE,Disconnect 後會變 false。
- **Disconnect 的 data**:`silentModeRestored` = 這次寫入的值(`null` = 沒有寫入),`silentModeOriginalUnknown`,失敗時 `silentModeRestoreError`(另有 Warning,message 也會提到)。還原失敗時紀錄保留,下一次 `Connect-TcIde` + `Disconnect-TcIde` 再還原。
- **會還原的路徑**:`Disconnect-TcIde`(不帶 `-Quit`);`-Quit` 但 `DTE.Quit` 失敗、又沒有 `-Kill`(IDE 還在跑,PR #266 review 5)。`-Quit` 遇到 modal dialog 時直接回 `IDE_QUIT_FAILED`、什麼都不做(那時 setter 呼叫會被 dialog 卡住)。
- **不會還原、要等下一次 `Connect-TcIde` + `Disconnect-TcIde` 的路徑**:行程沒 `Disconnect-TcIde` 就結束(紀錄在狀態檔,下一個行程能還原);同一行程直接 `Connect-TcIde` 另一個 IDE(只清變數,#271);#196 takeover 失敗的 `Reset-TcOrphanTakeoverAttach`(刻意不動,別的 session 可能已接管並依賴 true);`IDE_CRASHED` 後(IDE 已不在)。
- **多個 session 連同一個 IDE(現況,#270)**:紀錄是每個 IDE 一筆、所有 session 共用。先 `Disconnect-TcIde` 的 session 就還原成原值、刪掉紀錄;另一個還連著的 session 之後遇到 XAE 提示時不會被自動回答,可能卡在 modal dialog(`IDE_MODAL_DIALOG`)。它自己 Disconnect 時用記憶體的原值再寫一次(無害)。
- **狀態檔讀寫失敗(fail closed)**:讀不到 / 損毀 → 當作沒有紀錄(讀到 true 就走 unknown → false),`data.silentModeStateWarning` 說明;損毀檔在下次寫入時改名成 `.corrupt-<時間>` 保留,**檔裡其他 IDE 的紀錄也一起失去**(那些 IDE 下次連線時讀到 true 就成為 unknown → false)。寫不進去 → 本行程記憶體照常還原、`data.silentModeStateWarning`;之後的行程最壞是 unknown → false,不會把 true 當原值。IDE 的 pid 或行程啟動時間讀不到時不寫檔,只留在記憶體,同樣回 `silentModeStateWarning`。

### LAUNCH_RECORD_UNAVAILABLE

- **現象**:`Disconnect-TcIde -ForgetPendingLaunch` 回 `LAUNCH_RECORD_UNAVAILABLE`,帶 `data.launchRecordWarning`。`Connect-TcIde -TakeOverOrphan`(#196)讀不到紀錄檔(`data.reason = 'launch-record-unavailable'`)或接管寫不進去(`'launch-record-write-failed'`)時也回這個碼：沒有 attach、沒有接管。
- **為什麼**:模組記憶體裡 pid 未確認的紀錄已清掉，但 `launched-ides.json` 讀不到或寫不進去。可能原因：鎖被另一個 TcAuto 行程佔用(等待上限 2 s)、權限不足、檔案被其他程式開著。檔案裡的那筆還在，重啟後的 bridge 仍可能因此回 `IDE_LAUNCH_PENDING`。
- **下一步**:稍後重跑同一個 `Disconnect-TcIde -ForgetPendingLaunch`(或同一個 `Connect-TcIde -TakeOverOrphan`)。不要手動刪改這個檔案。

### ORPHAN_TAKEOVER_REFUSED

- **現象(#196)**:`Connect-TcIde -SolutionPath <sln> -TakeOverOrphan` 沒接管：沒 attach、沒改 `launched-ides.json`,`data.takenOver = false`,`data.otherSession` 照帶(有紀錄時)。
- **`data.reason`**:
  - `solution-path-required`:沒給 `-SolutionPath`。
  - `no-launch-record`:沒有這個 sln、而且 IDE 行程還在的啟動紀錄。不帶 `-TakeOverOrphan` 重跑。
  - `owned-by-this-session`:本 session 自己啟動的，沒有東西要接管。不帶 `-TakeOverOrphan` 重跑。
  - `host-alive`:啟動它的 TcAuto session 還在，或無法確認(`hostPid` 存在且 StartTime 相同、紀錄沒有可解析的 `hostStartTime`、沒有 `hostPid`)。不能接管，照「IDE_LAUNCH_PENDING」處理。
  - `pid-unconfirmed`:那次啟動的 pid 從沒確認過，認不出是哪個 IDE。使用者自己關掉它後 `Disconnect-TcIde -ForgetPendingLaunch`。
  - `progid-mismatch`:`-ProgId` 和啟動時的不同。拿掉 `-ProgId` 或改成啟動時的。
  - `not-in-rot` / `solution-mismatch`(`data.rotSolution`)/ `ide-busy`:ROT 裡沒有那個 pid 可回應、開著這個 sln 的 DTE。等它載入完、或關掉 dialog(`Get-TcIdeModalDialog -ProcessId <data.ideProcessId>`)後重跑。
  - `record-changed` / `host-not-gone`:在鎖內改寫時，紀錄已被另一個 session 改掉(例如它先接管了)或 host 又被認為還在。重跑同一個 `Connect-TcIde` 看最新狀態。
  - `host-start-time-unreadable`:讀不到本行程的 StartTime,無法記錄新擁有者(之後也認不出是自己)。重跑一次，還是失敗就回報。
- **有 dialog 時**不是這個碼：已知的 reload 提示先由模組回答(見下一節 `IDE_MODAL_DIALOG_ORPHAN`);其他 dialog 或回答後還在，回 `IDE_MODAL_DIALOG`(hint key `IDE_MODAL_DIALOG_ORPHAN`)/ `MODAL_SCAN_INCOMPLETE`(`data.reason = 'modal-dialog'` / `'modal-scan-incomplete'`),一樣沒有接管。attach 之後的 dialog 檢查(Solution.Open / 專案掃描前)發現 dialog 也用 `IDE_MODAL_DIALOG_ORPHAN` hint(attach 已釋放)。
- **接管的每個失敗出口與成功都帶同樣欄位(PR #209 review M2)**:`data.reloadPromptAttempts`(這次呼叫的每次嘗試，含 `sent = false` 沒送出的)、`data.resetRequired`(這個 .sln 的 reset-required 紀錄存在 = 提示已經被答成「不重新載入」,這次或之前的接管;判斷「答過沒」只看它是否存在，不看 `reloadPromptAttempts`)、`data.stateWarning`。
- **禁止的繞道**:不要手動改 `launched-ides.json`、不要 `Stop-Process` 別的 session 的 IDE、不要設 `TCAUTO_OWNER_ID` 冒充那個 session。

### IDE_MODAL_DIALOG_ORPHAN

- **碼與 hint**:錯誤碼仍是 `IDE_MODAL_DIALOG`;`IDE_MODAL_DIALOG_ORPHAN` 是 `Connect-TcIde -TakeOverOrphan` 停在 dialog 時用的 hint key(#201)。
- **現象(#201,修正前)**:孤兒 IDE(啟動它的 session 已結束)開著 reload 提示時,`-TakeOverOrphan` 回 `IDE_MODAL_DIALOG`,hint 卻叫你直接 `Reset-TcSolution`;但 `-TakeOverOrphan` 沒有 attach,`Reset-TcSolution` 回 `NOT_CONNECTED`,`Disconnect-TcIde -Quit` 也不適用，形成死循環(實測 2026-11-08 / 2026-11-09,4024 32-bit TcXaeShell 英文 UI,方案提示 `File Modification Detected` 按鈕 `259 &Reload` / `1412 &Ignore`)。
- **什麼時候模組會回答提示**:下列條件**全部**成立才回答，否則一個按鈕都不按:(1) 有 `-SolutionPath`;(2) `launched-ides.json` 有這個 .sln 的啟動紀錄;(3) 紀錄的 host 行程已結束;(4) owner 行程(MCP server)已結束，或紀錄沒有 ownerId;(5) pid 已確認(`pidSource` rot-identity / main-window);(6) 有給 `-ProgId` 時與啟動時相同;(7) ROT 有那個 pid 的 DTE;(8) 那個 IDE 開的就是這個 .sln:DTE 讀得到時 `Solution.FullName` 相同(不同 → `ORPHAN_TAKEOVER_REFUSED solution-mismatch`);DTE 被提示擋住讀不到時，提示內文要有證據 — 內文裡的專案檔路徑全部落在 .sln 的資料夾內(中間沒有別的 .sln,同 #29 的 dialog-path),或內文**沒有任何磁碟路徑**(`X:\` 都沒有;不是專案檔的路徑如 `C:\Other\BFH-1650\notes.txt`、被截斷的路徑都讓名稱規則失效)且有加引號的 solution 名稱 `'BFH-1650'`(VS 方案提示 "The solution 'BFH-1650' has been modified outside the environment" 的實測文字;沒加引號的名稱不算);(9) `kind = reload-prompt`。回答一律「不重新載入」,最多 5 個:solution → 只按忽略(1412;按不掉就停下回 `IDE_MODAL_DIALOG_ORPHAN`,不改送 WM_CLOSE:它對這個提示的效果沒實測。`Reset-TcSolution` 自己的 忽略 → WM_CLOSE 順序不變);project → No(IDNO 7;XAE 的 MB_YESNO 不吃 WM_CLOSE);file → WM_CLOSE。每次嘗試記在 `data.reloadPromptAttempts`(target / answer / method / controlId / dismissed / evidence)。
- **送出第一個回答就記 reset-required**:模組立刻為這個 .sln 記下 BUILD_REQUIRED kind `reset-required`(`build-required.json`,不管之後接管成功或失敗;`data.resetRequired`)。之後 `Build-TcProject`、`Enable-TcConfig`、`Enter-TcPlcOnline` / `Send-TcPlcProgram`、`New-TcBootProject`、`Save-TcPlcLibrary` 回 `RESET_REQUIRED`,直到 `Reset-TcSolution` 從磁碟重新開啟這個 .sln 且沒有存任何東西(見「RESET_REQUIRED」)。回答後重新讀 DTE(讀不到 → `ORPHAN_TAKEOVER_REFUSED ide-busy`,不是這個 .sln → `solution-mismatch`)再照原本流程接管。成功時 `data.reloadPromptAttempts`、`data.diskChangesNotLoaded = true`、`data.resetRequired`、`data.nextStep`;重跑接管(提示已被前一次答掉)時 `diskChangesNotLoaded` / `resetRequired` 一樣會出現(讀的是持久化的紀錄)。不按 Reload / Yes 的原因：接管本身不丟任何東西，要不要用磁碟版本交給接下來的 `Reset-TcSolution`。但 `Reset-TcSolution` 的 `Documents.CloseAll(vsSaveChangesNo)` **會**丟掉 IDE 裡未存的編輯器內容，所以(PR #209 review M1)接管成功時列出 `Document.Saved = false` 的文件(`data.dirtyDocuments`,讀不到 → `data.dirtyDocumentsError`,接管不因此失敗),而 `Reset-TcSolution` 遇到這種文件(或讀不到狀態)回 `UNSAVED_CHANGES`、什麼都不關，使用者同意後 `-Force` 才繼續(#175,不論有沒有 reset-required)。
- **回答之後 IDE 的狀態(實測 2026-11-09,4024 32-bit TcXaeShell `TcXaeShell.DTE.15.0`,複本 `C:\Temp\Verify-4024-bfh`,本機 UmRT,獨立 `TCAUTO_STATE_DIR`;在磁碟檔尾加一行 XML 註解觸發提示)**:project 提示(`PLC1.plcproj`)→ No(BM_CLICK,id 7)關閉;file 提示(`MAIN.TcPOU`,用 `ItemOperations.OpenFile` 開在 Miscellaneous Files,不是從 PLC 專案樹開的編輯器;按鈕 是/否/取消)→ WM_CLOSE 關閉。兩種情況 `Solution.Saved`、頂層 `Project.Saved`、`MAIN.TcPOU` 的 `Document.Saved` 都維持 True(沒有變 dirty);`Build-TcProject` 回 `RESET_REQUIRED`;改用 DTE `SolutionBuild.Build($false)` 直接建置(只為量測)→ `LastBuildInfo = 0`,磁碟上的檔案**沒有**被寫回(註解還在、mtime 不變)。所以實測到的風險是「編譯並下載記憶體裡的舊版本」,不是覆寫磁碟;巢狀 `.plcproj` 的 dirty 狀態、從 PLC 編輯器開的 POU 沒有量測。接著 `Reset-TcSolution -DiscardProjectChanges` 成功重開並清掉紀錄(`resetRequiredCleared = true`)。
- **還是回這個 hint 時**:`data.attached = false`,沒有任何東西 attach,所以 `Reset-TcSolution` / `Disconnect-TcIde` / `Get-TcIdeInfo` 都會回 `NOT_CONNECTED`。(a) `kind = reload-prompt` 但回答後還在(看 `data.reloadPromptAttempts` 的 `reason`)或連續超過 5 個 → 請使用者在 XAE 按 Ignore / No 或關掉那個 IDE;(b) `kind = reload-prompt` 但 DTE 讀不到、內文沒有證據(`data.reloadPromptEvidence = none`,沒有 `reloadPromptAttempts`)→ 模組沒按任何按鈕，請使用者確認那個 IDE 開的是這個 .sln 後在 XAE 處理;(c) 其他 dialog(`kind = unknown`)→ 模組不自動按(license / security code 視窗一律由使用者處理)。處理完 `Get-TcIdeModalDialog -ProcessId <data.ideProcessId>` 確認沒有 dialog,再重跑同一個 `Connect-TcIde -TakeOverOrphan`。`data.resetRequired` 存在就代表提示已被答成「不重新載入」、reset-required 已記下(`data.reloadPromptAttempts` 含沒送出的嘗試，不能拿來判斷):重跑接管成功後先 `Reset-TcSolution`。不要 `Stop-Process` 那個 IDE:接管成功前它不屬於本 session。

### IDE_MODAL_DIALOG_EMPTY_ORPHAN

- **碼與 hint**:錯誤碼仍是 `IDE_MODAL_DIALOG`(或 `MODAL_SCAN_INCOMPLETE`);`IDE_MODAL_DIALOG_EMPTY_ORPHAN` 是 `Connect-TcIde -SolutionPath` 想重用「已結束 session 留下的空 IDE」卻遇到 dialog 時用的 hint key(#235)。
- **背景(#235,實測 2026-11-11,VS2022 4026,本機 UmRT)**:session A 的 `ConnectIde` 冷啟動 IDE 後,Solution.Open 前的 modal 掃描逾時(`MODAL_SCAN_INCOMPLETE`,#230),對話結束;session B 同參數 `ConnectIde` 以前會**再開第二個 IDE**,第一個空 IDE tcauto 收不掉(不是本 session 的 → `IDE_NOT_OWNED`;`-TakeOverOrphan` 要求它已開著這個 .sln)。
- **現在的行為**:不帶 `-TakeOverOrphan` 也會重用那個空 IDE,條件**全部**成立才重用:(1) `launched-ides.json` 有這個 .sln 的啟動紀錄,pid + 啟動時間 + image 名稱仍是同一個行程;(2) pid 已確認(`pidSource` rot-identity / main-window);(3) host 行程(bridge)與 owner 行程(MCP server)都已結束(或紀錄沒有 ownerId);(4) 有給 `-ProgId` 時等於啟動時的 ProgID;(5) ROT 有那個 pid 的 DTE,可回應且**沒有開任何 solution**;(6) **TcAuto 從沒在它上面開過 solution**(PR #268 review S1:啟動紀錄沒有 `solutionOpened = true`,`ide-solutions.json` 也沒有這個 pid + 啟動時間的紀錄;成功開過 solution 的連線會把啟動紀錄標成 `solutionOpened = true`);(7) dialog 掃描完成且沒有 dialog(`Find-TcIdeModalDialogColdRetry -ProcessId`,#230 的冷啟動重掃);(8) `DTE.Documents.Count` 讀得到且為 0;(9) 這次若要另開 IDE 會選的 ProgID(`Resolve-TcLaunchProgId`:#72 TcVersion / #225 Remote Manager)等於紀錄的 ProgID(review S2)。重用時:先在鎖內把啟動紀錄的擁有者改成本 session(`takeovers[]` reason `empty-orphan-reuse`,改寫前再確認紀錄沒被別人改過、host / owner 仍不在;review S3:兩個 session 同時判定可重用時只有一個拿到,另一個回 `IDE_LAUNCH_PENDING` 什麼都不開)→ attach → 照常 modal 掃描 → `Solution.Open` → 專案掃描 → 平台讀回(`solutionPlatform` 一開始讀到 null 時在 15 s 內重讀到有值,仍沒有就 `data.solutionPlatformWarning`;review N3,實測 2026-11-13 VS2022 重用後第一次讀到 null)。#225 選到 remote-manager-match 時,重用路徑一樣讀回 Remote Manager(不符 → `REMOTE_MANAGER_MISMATCH`)。成功回 `selectedBy = 'empty-orphan-reuse'`、`data.reusedEmptyOrphan = true`、`data.previousOwner`、`ownedBySession = true`,之後 `Disconnect-TcIde -Quit` 可以關它。
- **擁有者寫入後才失敗**(dialog、`Solution.Open` 失敗 / 逾時、`IDE_CRASHED`,review N1):那個 IDE 已經屬於本 session、仍是 attach 狀態(和本次 launch 的 IDE 失敗時一樣),結果帶 `data.reusedEmptyOrphan = true`、`ownedBySession = true`、`previousOwner`;不會另開第二個。處理完原因後重跑同一個 `Connect-TcIde`(會以 session-launched 接上),或 `Disconnect-TcIde -Quit`(有 dialog 時 `-Quit -Kill`)關掉它。
- **不重用、照舊另開一個 IDE**:沒有啟動紀錄(使用者自己開的空 IDE 絕不重用)、pid 未確認、pid 被重用(啟動時間不同)、`-ProgId` 不同、選出的 ProgID 和紀錄不同(review S2,另開選出的那個)、有開任何文件(或讀不到 `Documents`)。`Resolve-TcLaunchProgId` 本身拒絕(`PROGID_REQUIRED` 等)時不重用,回那個錯誤。
- **不重用、也不另開**:**DTE 忙碌**(review S5:solution 讀不到,不放行,照舊 `IDE_LAUNCH_PENDING` other-session)、owner / host 還在或無法確認(`IDE_LAUNCH_PENDING` other-session)、**TcAuto 曾在它上面開過 solution**(review S1:可能是 session 結束後留給使用者繼續用的視窗;`IDE_LAUNCH_PENDING` other-session、`data.notReusedReason = 'solution-was-opened'`,hint 要先問使用者、同意後 `-TakeOverOrphan`)、另一個 session 同時搶先接管(review S3,`IDE_LAUNCH_PENDING`,`data.reason` = `record-changed` 等)、有 dialog(`IDE_MODAL_DIALOG` + 這個 hint)、掃描不完整(`MODAL_SCAN_INCOMPLETE`,hint 附重掃與重跑的說明;**重掃仍不完整時由使用者確認那個視窗,或手動關掉那個 IDE 後再重跑**,模組不會關它,review S4。沒有改用 `-LaunchIfBlocked` 跳過重用:那個開關的意思是「忽略只靠標題比對到的別人 IDE」,拿來另開第二個 IDE 正是 #235 要避免的)。這幾種都沒有 attach(`data.attached = false`、`data.reusedEmptyOrphan = false`),啟動紀錄沒改。
- **下一步**:模組不會替這個 IDE 按任何按鈕(不同於 `-TakeOverOrphan` 對 reload 提示的處理)。請使用者處理 dialog(license / security code 一律由使用者處理),`Get-TcIdeModalDialog -ProcessId <data.ideProcessId>` 確認沒有 dialog 後,重跑**同一個** `Connect-TcIde`(MCP:`ConnectIde` 同參數)。不要 `Stop-Process` 那個 IDE。
- **改寫擁有者失敗**:寫不進去 → `LAUNCH_RECORD_UNAVAILABLE`;被別人搶先 → `IDE_LAUNCH_PENDING`。兩者都在 attach 之前,什麼都沒開、沒 attach。

### RESET_REQUIRED

- **現象(PR #209 review)**:`Build-TcProject`、`Enable-TcConfig`、`Enter-TcPlcOnline`(`Send-TcPlcProgram`、`Invoke-TcTestCycle` 經過它)、`New-TcBootProject`、`Save-TcPlcLibrary`,以及會存專案檔(DTE `Project.Save`)的 `Add-TcPou`、`Add-TcDut`、`Add-TcGvl`、`Add-TcInterface`、`Add-TcLibrary`、`Add-TcLibraryPlaceholder`、`Add-TcPlcTask`、`Import-TcPlcOpen`、`Lock-TcLibraryPlaceholder`、`Remove-TcLibraryReference`、`Set-TcIndependentFile`(後五個只在 `-DryRun $false`)回 `RESET_REQUIRED`,`data.resetRequired = {reason, solution, at, stateFile, stateUnreadable}`,什麼都沒做(存檔類 cmdlet 在改動 XAE 之前就擋;共同的 `Invoke-TcPlcObjectSave` / `Invoke-TcProjectSaveWithDeadline` 再擋一次，不呼叫 `Project.Save`)。
- **為什麼**:`Connect-TcIde -TakeOverOrphan` 把孤兒 IDE 的 reload 提示答成「不重新載入」(見「IDE_MODAL_DIALOG_ORPHAN」),IDE 記憶體裡還是舊的 solution,磁碟上的檔案已被改過。Build 會編譯這份舊內容,Activate / Login 會下載它;`Project.Save()` 會把記憶體裡的整個 .tsproj 與其下所有 .plcproj 寫回磁碟、蓋掉磁碟上的改動。Build 會不會一併存 PLC editor buffer 是**推論、未實測**;2026-11-09 4024 實測 raw `SolutionBuild.Build($false)` 沒有把檔案寫回磁碟(見「IDE_MODAL_DIALOG_ORPHAN」)。記錄在 `build-required.json` 的 kind `reset-required`(和 BUILD_REQUIRED 共用檔案與鎖;完整 Build 不會清掉它，因為 Build 本身就被擋)。**以 .sln 為 key,不分 IDE pid**:同一個 .sln 換一個 IDE 開也一樣擋(只會多擋，方向安全)。**讀不到狀態檔(被鎖、讀取失敗)或有 `<corrupt>` 項目時 fail closed**:回 `RESET_REQUIRED`,`data.resetRequired.stateUnreadable = true`、reason 以 `state unreadable` 開頭;被其他行程鎖住就稍後重試,`<corrupt>` 照「BUILD_REQUIRED」處理。`Reset-TcSolution` 不帶 `-SaveProjectChanges` 時不會因此被擋(它是出口)。`Test-TcPlcProject`(CheckAllObjects)只檢查、不寫檔不下載，沒有擋。
- **下一步**:`Reset-TcSolution`(MCP `ResetSolution`)。它把這筆紀錄當成「已處理過 reload 提示」:一定走 Documents.CloseAll / Solution.Close / Solution.Open,`-SaveProjectChanges` 遇到 project check 差異時一樣回 `PROJECT_UNSAVED_CHANGES`(`data.saveRefused` 的 `plc = '*'`);IDE 有未存的文件 / 專案 / solution(或讀不到狀態)時回 `UNSAVED_CHANGES`(`data.unsavedCheck`,見「UNSAVED_CHANGES」),什麼都不關:請使用者先在 XAE 看過，同意丟掉才 `-Force`。重開成功且沒有存任何專案檔 → 清掉紀錄(`data.resetRequiredCleared = true`),之後照常 `Build-TcProject`(Reset 本身會記 code-changed)。不需要這個 IDE 就 `Disconnect-TcIde -Quit`;紀錄留著，下次開這個 .sln 一樣先 `Reset-TcSolution`。不要手動改 `build-required.json`。

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

### NOT_CONNECTED_IDE

- **現象**:`Export-TcPlcOpen`、`Import-TcPlcOpen`、`New-TcBootProject`、`Save-TcPlcLibrary`、`Save-TcArchive` 回 `NOT_CONNECTED`,hint 是這一節:還沒 `Connect-TcIde`,或 IDE 連線已斷(不是 ADS 的 `NOT_CONNECTED`)。
- **下一步**:`Connect-TcIde`(要開特定 solution 加 `-SolutionPath <sln>`),再重跑同一個 cmdlet。

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

### PARTIAL_READ_FAILED

- **現象**:多路徑 `Read-TcVariable`(MCP `ReadVariable` / `QuickRead`,Path 有兩個以上)至少一個 path 讀不到。以前整筆仍回 `success: true`,頂層沒有任何標記，只看 `success` 會漏掉(#60,實測 2026-10-28 registered tcauto:部分或全部 path 是 `ADS_SYMBOL_NOT_FOUND` 都回 `success: true`)。
- **現在(fail closed)**:任一 path 失敗 → `success: false`、`error.code = PARTIAL_READ_FAILED`,message 列出 `<path> (<code>)`。`data` 仍是每個 path 一筆的陣列(順序同輸入，讀到的值照常在裡面;讀不到的那筆是 `{path, error, code, hint}`)。結果頂層另有 `partial`(有 path 失敗就是 `true`)與 `failedPaths`(失敗的 path,依輸入順序);全部成功時是 `success: true`、`partial: false`、`failedPaths: []`。`data` 是陣列，所以這兩個欄位放在頂層，不在 `data` 裡。單一路徑不變(讀不到回 `SYMBOL_NOT_FOUND`,沒有 `partial` / `failedPaths`)。
- **下一步**:看 `failedPaths` 與 `data` 裡那幾筆的 `code`:`ADS_SYMBOL_NOT_FOUND` 見上節(`Get-TcSymbols` 確認路徑，新變數要先下載);連線類(`ADS_TARGET_NOT_FOUND` / `ADS_PORT_NOT_FOUND` / `ADS_TIMEOUT`)先 `Get-TcPlcState` 確認狀態再只重讀 `failedPaths`。
- **Watch**:`Watch-TcVariable` 讀不到時是另一個碼 `WATCH_READ_FAILED`,見下節(#139)。

### WATCH_READ_FAILED

- **現象**:`Watch-TcVariable`(MCP `WatchVariable`)監看期間，至少一個 path 至少有一輪讀不到。以前讀不到的值記成 `null`、沒有 error / code,整筆仍回 `success: true`,和「值真的是 null」分不出來;`Until` 的 path 讀不到時只回 `untilMet: false`(#139,實測 2026-10-28 registered tcauto,`Main.NoSuchVar_Repro60` 那一路是 `null`)。
- **現在(fail closed,比照 `PARTIAL_READ_FAILED`)**:任一 path 有任一輪讀不到 → `success: false`、`error.code = WATCH_READ_FAILED`,message 列出 `<path> (<code>, <n> of <m> rounds)`。單一路徑和多路徑規則一樣。`data` 照常完整(`samples`、`sampleCount`、`untilMet`、`untilSample`、`finalValue(s)` …),另加 `failedReads`(path → 讀不到的輪數)與 `lastErrors`(path → 最後一次的 `{error, code, hint}`)。讀不到的那一輪在 sample 裡仍是 `null`,但旁邊有錯誤：多路徑是 `sample.errors.<path>`,單一路徑是 `sample.error` / `code`(`hint` 只放在 `data.lastErrors`,免得 `KeepLast` 筆 sample 每筆重複一次)。同一個 path 在 `-Path` 給了兩次(不分大小寫)只讀一次。結果頂層有 `partial` 與 `failedPaths`(依 `-Path` 順序);全部讀到時是 `success: true`、`partial: false`、`failedPaths: []`。
- **為什麼整筆算失敗**:監看的用途是拿值去判斷;有一輪讀不到，那一輪的 `null` 就不是 PLC 的值，只看 `success` 的呼叫端不能把它當成正常結果(#68 fail closed 的方向)。只有一輪暫時讀不到(例如重啟中 `ADS_TIMEOUT`)也一樣回 `WATCH_READ_FAILED`,`failedReads` 會告訴你是幾輪。
- **Until**:`untilMet: true` 一定來自一次讀到的值(`untilSample`)。`Until` 的 path 讀不到而 `untilMet: false` 時，message 會寫出來：這不代表條件在 PLC 上沒成立。
- **下一步**:看 `data.lastErrors` 的 `code`:`SYMBOL_NOT_FOUND` / `ADS_SYMBOL_NOT_FOUND` 見「ADS_SYMBOL_NOT_FOUND」(`Get-TcSymbols` 確認路徑，新變數要先下載);連線類(`ADS_TARGET_NOT_FOUND` / `ADS_PORT_NOT_FOUND` / `ADS_TIMEOUT`)先 `Get-TcPlcState` 確認狀態，再重新監看。

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

### LIFECYCLE_BLOCKED

- **為什麼**:這個 target(AmsNetId)之前有一個會改變 runtime 的請求已經送出，但讀回沒有到達要求的狀態(#68,#32 的情境:WriteControl 沒丟例外、讀回仍是 Config)。模組把它記成 lifecycle block(`data.lifecycleBlock`:`amsNetId`、`command`、`errorCode`、`message`、`requestedState`、`reachedState`、`step`、`time`),之後 fail closed:會改 runtime 的命令都不執行。
- **誰會記**:`Set-TcSystemState` 在 WriteControl 送出後的任何失敗(`SYSTEM_STATE_TIMEOUT`、`SYSTEM_STATE_MISMATCH`、`RUNTIME_CRASHED`、送出後的 ADS 例外);`Enable-TcConfig` 在 set-config(內部 `Set-TcSystemState` 真的送出 WriteControl)或 `ActivateConfiguration()` 送出之後的**任何**失敗(`ACTIVATE_TIMEOUT`、`ACTIVATE_FAILED`、`IDE_CRASHED`、`IDE_MODAL_DIALOG`、`CYCLE_TIMEOUT`、`LOGIN_FAILED`、`STATE_SET_FAILED`、`ADS_RECONNECT_FAILED`、`SYSTEM_STATE_*`、`RUNTIME_STATE_MISMATCH`、`BOOT_PACKAGE_MISMATCH`、`PLC_*`,以及 login 步驟巢狀 `Enter-TcPlcOnline` 回的 `NOT_CONNECTED` / `BUILD_REQUIRED`…),只有巢狀命令回的 `LIFECYCLE_BLOCKED` 不再重記;set-config 是否送出看 `Set-TcSystemState` 的 `data.requestSent`;`-PlcProjectPath` 找不到的 `PLC_PROJECT_NOT_FOUND` 在 set-config 之前就回，不記;`Set-TcPlcState` 送出後 Run 沒到(`PLC_RUN_TIMEOUT`)或 Stop 沒到(`STATE_SET_FAILED`)。什麼都還沒送出前的前置條件失敗不記。成功的命令**不會**自動清掉 block。`Invoke-TcTestCycle` 的 PLC Run 失敗會立即回傳(其餘步驟 `status = NOT RUN`),PLC Stop 失敗讓整個 cycle `success: false`。
- **行程在請求途中被殺(#236)**:上面那些都是命令自己寫的;PowerShell 行程在請求還沒回來時就死掉(MCP server 的 modal probe 看到 dialog 而殺掉 bridge 回 `IDE_MODAL_DIALOG` 且 `bridgeRestarted = true`、`BRIDGE_TIMEOUT`、crash)就沒機會寫。實測 2026-11-11(VS2022 + 4026 + 本機 UmRT,v0.6.1-beta-rc1):`EnableConfig` 在 Activate 之後跳「license not found」fatal error,bridge 被殺,沒有 `lifecycle-block.json`,runtime 停在 Config,下一個 `EnableConfig` 沒被擋。現在 `Set-TcSystemState`(WriteControl 前)、`Set-TcPlcState`(WriteControl 前，涵蓋 `RunTestCycle`)與 `Enable-TcConfig`(set-config / `ActivateConfiguration()` 前)先寫 in-flight 標記 `lifecycle-inflight.<pid>.<guid>.json`(同一目錄;`pid`、行程名稱、行程 StartTime、`command`、`amsNetId`、`requestedState`;先寫 `.tmp` 再 rename,不會被讀到半截),返回時(不論結果)刪掉。之後**任何行程**的 lifecycle 檢查(被擋的命令、`Clear-TcLifecycleBlock`;約 300 ms 的提示路徑不轉)先把擁有者已不在的標記(沒有那個 pid;或 pid 被重用：行程名稱不同、或 StartTime 不同，自己的 pid 也一樣比;名稱相同但讀不到 StartTime 時只看 pid;標記讀不了時看檔名裡的 pid,還活著就不動)轉成 block,檢查、寫入、刪標記在同一把 mutex 內做;多個標記照送出時間由舊到新處理，所以被殺的 `Enable-TcConfig` 記的是外層 `Enable-TcConfig`(`requestedState` 是整個呼叫的目標),巢狀 `Set-TcSystemState` 的標記較舊於那筆紀錄、只刪掉:`errorCode = INTERRUPTED`、`command` / `amsNetId` / `requestedState` 照標記,`reachedState` 空,message 寫出死掉的 PID 與送出時間。同一 target 在標記之後已有較新的紀錄就保留那筆;讀不了且擁有者已不在的標記記成 `<unknown>`(擋所有 target);擁有者已不在、卻轉不成 block(鎖不到、寫不了)或標記目錄列不出來時，所有 target 都擋(`errorCode = state-unreadable`),標記留著下次再轉。擁有者還活著的標記(另一個 bridge 正在跑)不動。`Enable-TcConfig` 送出請求後若有例外直接丟出，先記 `errorCode = UNHANDLED_EXCEPTION` 的 block 再把例外丟出去;`Enable-TcConfig` 與 `Set-TcSystemState` 送出後 pipeline 被停掉(Ctrl+C)時在 finally 記 `INTERRUPTED`。MCP 的 `IDE_MODAL_DIALOG` / `BRIDGE_TIMEOUT` hint 也改成：被中斷的 EnableConfig / SetSystemState 已記 block,不要重跑。處理方式同其他 block:回報使用者、唯讀診斷、同意後 `Clear-TcLifecycleBlock`。
- **誰會被擋**:`Set-TcSystemState`、`Enable-TcConfig`(有無 `-Force`)、`Enter-TcPlcOnline`、`Send-TcPlcProgram`、`Set-TcPlcState`(所有 State)、`Write-TcVariable`、`Invoke-TcTest`、`Invoke-TcTestCycle`(連 Build 都不跑)、`Set-TcComModuleParameter -Online -DryRun $false`;MCP 的 `RunLifecycle` 在 EnableConfig 步驟被擋(前面的 ConnectIde / SetTarget / BuildProject 仍會跑)。唯讀 / 診斷命令(`Get-TcSystemState`、`Get-TcPlcState`、`Read-TcVariable`、`Get-TcSymbols`、`Connect-TcAds`、`Build-TcProject`、`Get-TcIdeModalDialog`、`Get-TcBuildErrors`)不擋。`Exit-TcPlcOnline` 目前也不擋(它對 runtime 狀態的影響未查證)。
- **唯讀命令的 hint**:失敗那個呼叫的 target(呼叫端知道就用它，例如 `Get-TcSystemState -AmsNetId`、`Connect-TcAds`、`Set-TcSystemState`、`Enable-TcConfig`;否則用 ADS session 的 AmsNetId)有 block 時,`ADS_TARGET_NOT_FOUND`、`ADS_PORT_NOT_FOUND`、`NOT_CONNECTED`、`PLC_NOT_LOADED`、`ADS_INVALID_STATE` 的 hint(平常會叫你去 `Set-TcSystemState` / `Enter-TcPlcOnline` / `Set-TcPlcState`,都被擋)改以「此 target 有 LIFECYCLE_BLOCKED」開頭(回報使用者、只做唯讀診斷),原本的建議接在後面並標明 Clear 之前不要照做，同時附 `data.lifecycleBlock`;`ADS_SYMBOL_NOT_FOUND` / `SYMBOL_NOT_FOUND` 的 hint 不換(本來就是唯讀步驟),只附 `data.lifecycleBlock`。規則:原本的 hint 會叫你做被擋的命令才加前綴;原本就是唯讀步驟的只附 block(新的 code 依這條規則放進 `LifecycleBlock.ps1` 兩個清單之一)。呼叫端與 ADS session 都不知道 target 時(例如還沒 `Connect-TcAds` 的 `NOT_CONNECTED`),改看已連線 IDE 的 target(#114;只用先前命令從 IDE 讀到並快取的 NetId,提示路徑**不呼叫 COM**:對卡住的 XAE 做同步 `GetTargetNetId` 沒有 deadline):它有 block 就同樣換成「此 target 有 LIFECYCLE_BLOCKED」並附 `data.lifecycleBlock`;IDE target 也不明、或它沒有 block 而是別的 target 有時 hint 不換，只在後面加一句「另有 target 存在 lifecycle block」。這條提示路徑只等鎖約 300 ms,等不到就不加註(真正的擋點 `LIFECYCLE_BLOCKED` 仍照常 fail closed)。
- **紀錄內容**:`requestedState` 是失敗那一步實際要求的狀態(set-config = Config、activate = Activated、set-run 起 = Run);`RUNTIME_CRASHED` 的 `reachedState` 是空的(runtime 已不在，死前最後讀到的值只寫在 `step`),`LIFECYCLE_BLOCKED` 的訊息寫成「did NOT succeed … system state read back afterwards: nothing (runtime gone)」。`SYSTEM_STATE_TIMEOUT` / `SYSTEM_STATE_MISMATCH` 最後讀取失敗時也一樣是空的(#114,紀錄的 `readbackNote` = `unreachable`,crash 是 `runtime-gone`;訊息「nothing (port 10000 unreachable)」);`Enable-TcConfig` 重記 block 時保留同一個 `readbackNote`,verify 讀不到 port 10000 時 `reachedState` 也是空的(不再寫 `Unreachable`)。每個命令被擋時的 `LIFECYCLE_BLOCKED` 都有 `data.notRun = true`、`data.requestSent = false`(#114,以前只有 `Set-TcSystemState` 有 `requestSent`)。
- **存在哪**:`%TEMP%\TwinCATAutomation\lifecycle-block.json`(測試用 `TCAUTO_STATE_DIR`),以 AmsNetId 為 key,不同 target 互不影響;跨 `Import-Module -Force`、MCP bridge 重啟仍有效。寫入用 named mutex + `[IO.File]::Replace`(同 `build-required.json`),寫不了檔時至少在本行程的記憶體裡擋(`data.lifecycleBlock.stateWarning`)。檔案解析不了、或內容不是 JSON 物件(`null`、陣列、字串、某筆紀錄不是物件)→ 舊檔以 `[IO.File]::Replace` 一步換成 `lifecycle-block.json.corrupt-<時間>`,新檔留一筆 `<corrupt>` 紀錄擋所有 target,之後寫入的 block 加在它旁邊;換檔也失敗或鎖不到 → 所有 target 都擋(`errorCode = state-unreadable`)。命令解析不出自己的 target AmsNetId,或 target 是 loopback NetId(`127.x.x.x.y.z`,例如 `127.0.0.1.1.1`:它指「這台機器」,和本機實際 AmsNetId 無法比對)時，任何 block 都擋;寫給這類 NetId 的 block 存成 `<unknown>`,擋所有 target。記憶體副本只在本行程有效：檔案寫不了時別的行程 / MCP bridge 重啟後看不到;**跨 bridge 同步(#113)**:別的行程(另一個 MCP bridge / PowerShell session)`Clear-TcLifecycleBlock` 後，本行程下次檢查時，若檔案已沒有這個 key,且 `lifecycle-block-history.jsonl` 有**這一筆紀錄本身**的 receipt(同 key、`cleared` 不是 null、`cleared.createdAtUtc` 與 `cleared.command` 都和這筆紀錄相同、`clearedAtUtc` 晚於 `createdAtUtc` 且不比本機時間晚 5 s 以上),就丟掉自己記憶體裡那份。其餘情況照擋(fail closed):手動刪檔(沒有 receipt)、只有 key 的偽造行、未來時間的 receipt(時鐘偏快或偽造)、同 key 較舊紀錄的 receipt(第二次 crash 不會被舊 receipt 放行)、no-op Clear(`cleared = null`)、history 不存在 / 讀不到、有一行不是 `{...}` 形狀或提到這個 key 的行解析失敗、舊版模組寫的紀錄沒有 `createdAtUtc`。保留時回傳的紀錄帶 `syncNote`(原因，並說明要在**仍在擋的這個** bridge / 行程 `Clear-TcLifecycleBlock`),`LIFECYCLE_BLOCKED` 的 message 也會附上。**history 不是防竄改紀錄**:有檔案寫入權的人可以改它，這個同步只是為了方便，不是安全邊界;真正的放行仍要使用者同意後的 Clear。讀 history 用 `FileShare.ReadWrite | Delete`,不會讓別的行程 append 失敗;Clear 在同一把 mutex 內短重試 append receipt,還是寫不進去時 Clear 仍成功(紀錄已移除)但 `data.receiptWritten = false`、`data.historyWarning`,message 註明其他 bridge 不會同步。效能:3000 行 history 一次檢查約 0.1-0.2 s(只有提到該 key 的行才解析;3000 行全是同 key 的極端情況約 1.1 s,2026-11-05 實測，本機 Windows PowerShell 5.1)。
- **下一步(人工核准流程)**:
  1. 停止，後續步驟標示 NOT RUN,把 `data.lifecycleBlock` 與當時的 result 原樣回報使用者。
  2. 只做唯讀診斷:`Get-TcSystemState`、`Get-TcPlcState`、`Get-TcIdeModalDialog`、`Get-TcBuildErrors`、XAE License 節點。
  3. **不要**自行改用其他控制通道:直接 `TcAdsClient.WriteControl`、`ITcSysManager` 的 StartRestart 方法、`DTE.ExecuteCommand("TwinCAT.*")`、Activate 後重新 `Connect-TcIde`、GUI 點 toolbar、`TcSystemServiceUm` console 的 `r` / `c`、寫死或沿用聊天裡的 AmsNetId、自動改 Platform / Target / Route / ShouldBuild / PLC Disabled。
  4. 使用者確認原因並同意後:`Clear-TcLifecycleBlock -Reason '<使用者的理由>' -FallbackMethod '<繼續的方法>' -AllowedSideEffects '<副作用>'[,...] -MaxVerifyLevel <層級>`(#113 結構化 receipt,四個欄位都必填、照使用者的話填，缺、空或不合法回 `LIFECYCLE_RECEIPT_INCOMPLETE`,見下一節;`-MaxVerifyLevel` = 清除後這次驗證會做到的最高層;結果不得宣稱超過它(The highest layer the verification after this clear will reach; results must not claim more than it.);MCP `ClearLifecycleBlock`;預設目前 IDE target,別的 target 帶 `-AmsNetId`;`<unknown>` / `<corrupt>` 紀錄用 `-AmsNetId '<unknown>'` / `-AmsNetId '<corrupt>'`;`<corrupt>` 清掉後，損毀檔裡原本的紀錄不會再擋，使用者要先看過 `.corrupt-*` 檔)。回傳 `data.cleared`、`data.receipt`(`clearedAt`、`clearedAtUtc`、`amsNetId`、`key`、`netIdSource`、`reason`、`fallbackMethod`、`allowedSideEffects`、`maxVerifyLevel`、`pid`、`cleared`,附加到同目錄的 `lifecycle-block-history.jsonl`);還有擋所有 target 的紀錄時 `data.stillBlocking` / `data.next` 與 message 會寫出要帶哪個 `-AmsNetId`。
  5. 照 `-FallbackMethod` 核准的方法從頭重跑 lifecycle(`Build-TcProject` → `Enable-TcConfig -Force` → …),副作用不超出 `-AllowedSideEffects`,驗證最多做到 `-MaxVerifyLevel`,回報結果不得宣稱超過它。
- **失敗回傳的欄位**:`Enable-TcConfig` 回 `success: false` 時 `activated`、`restarted`、`loggedIn`、`reconnected`、`platformFixed` 一律是 `false`;實際送了什麼看 `activateSent`、`activateReturned`、`runSent`、`runReached`、`loginCompleted`、`platformSwitched`、`requestedState`、`reachedState`(最後讀回的 port 10000 狀態)。
- **靜態檢查**:`scripts/check.ps1` 的 `forbidden` 檢查 `src/`、`mcp-server/`、`tests/Integration/` 程式碼(含字串，不含註解)裡寫死的 AmsNetId、StartRestart 方法、任何 `ExecuteCommand` 與任何 `WriteControl` / `WriteControlAsync`;合法用途要在該行或正上方只有註解的那行，以**註解**寫 `tcauto-allow(<rule>): <理由>`(字串裡的標記不算)(`scripts/forbidden-patterns.ps1`,單元測試 `tests/Unit/forbidden-lint.ps1`)。
- **測試**:`tests/Unit/lifecycle-block.ps1`(mock,#32 regression:Set-TcSystemState 讀回 Config → block,之後 Login / PLC Run / ADS Write / Enable-TcConfig 全擋且沒呼叫底層 COM / ADS,Clear 後恢復，不同 AmsNetId 不互擋;Enable-TcConfig verify 讀回 Config → block 且 `restarted` / `activated` 不是 true;`Invoke-TcTestCycle` Activate 後不呼叫 `Connect-TcIde`,PLC Run / Stop 失敗讓 cycle 失敗;`ACTIVATE_TIMEOUT` / `CYCLE_TIMEOUT` 記 block;`Set-TcSystemState` WriteControl 後的例外記 block;loopback NetId、損毀 state 檔仍擋;ADS 命令未連線回 `NOT_CONNECTED`)、`tests/Unit/runtime-crashed.ps1`(`RUNTIME_CRASHED` 記 block)、`tests/Unit/lifecycle-receipt-113.ps1`(#113:receipt 欄位缺漏、history 內容、跨行程同步的有 receipt / 沒 receipt / history 損壞)。真機尚未驗證。

### LIFECYCLE_RECEIPT_INCOMPLETE

- **為什麼**:`Clear-TcLifecycleBlock`(MCP `ClearLifecycleBlock`)的結構化 receipt 不完整(#113)。`data.missing`:缺少或空白的欄位(`Reason`、`FallbackMethod`、`AllowedSideEffects`、`MaxVerifyLevel`);`data.invalid`:值不合法(`MaxVerifyLevel` 不是 `None` / `SystemState` / `PlcState` / `VariableRead` / `TestObserved`;`AllowedSideEffects` 有 `none` 又有其他項)。`data.allowedVerifyLevels` 是合法層級。什麼都沒清,block 還在，也不寫 history。
- **MCP 與 cmdlet 的差別**:MCP 呼叫時 tools.json 的 schema 先檢查：沒帶參數(`Missing required parameter`)、`AllowedSideEffects` 是空陣列、`MaxVerifyLevel` 不在 enum(大小寫要一致)時，在進 bridge 前就回 `INVALID_PARAMS`,同樣什麼都沒清;通過 schema 但內容是空字串 / 只有空白，或 `none` 和其他項並列，才由 cmdlet 回這個 code。直接呼叫 cmdlet / CLI 時一律是這個 code(四個參數刻意不設 PowerShell `Mandatory`,避免互動提示或 binding error)。
- **欄位意義**:`-Reason` 是使用者同意解除的理由;`-FallbackMethod` 是使用者核准的繼續方法(例如「經 tcauto 重跑 Enable-TcConfig -Force」);`-AllowedSideEffects` 是允許的副作用，每項一個字串(例如 `TwinCAT restart`、`PLC download`、`PLC Run`;都不允許時只給 `none`,不能和其他項並列);`-MaxVerifyLevel` = 清除後這次驗證會做到的最高層;結果不得宣稱超過它(The highest layer the verification after this clear will reach; results must not claim more than it.)。層級由低到高 `None`(不驗證)→ `SystemState`(讀回 TwinCAT system state)→ `PlcState`(讀回 PLC port 狀態)→ `VariableRead`(讀回 PLC 變數)→ `TestObserved`(觀察到測試結果),名稱沿用 #68 的 lifecycle 用語。四個欄位都寫進 `lifecycle-block-history.jsonl` 的 receipt。
- **升級注意(#130 F1)**:已經在跑的 MCP server 用的是啟動時讀進來的 `tools.json`。#113 之前啟動的 server,`ClearLifecycleBlock` 的 schema 沒有 `FallbackMethod` / `AllowedSideEffects` / `MaxVerifyLevel`,Claude 送不出這三個欄位;bridge 重啟或 `ReloadModule` 換成新模組後，透過這個 server 就永遠清不掉 block。這時三個欄位全部「沒傳」(不是傳了空值),回傳會帶 `data.possibleStaleSchema = true`,hint 多一句請重啟 MCP server(開新 session)再 Clear。**merge #130 後，所有開著的 Claude session 都要重開**,才能用新的 Clear。模組不會退回「只用 Reason」清除，那會削弱 receipt。
- **下一步**:不要自己編內容。回去問使用者，照使用者的話補齊或改正後再呼叫一次 `Clear-TcLifecycleBlock`。

### ReloadModule(MCP,#41):做法與共同規則

- **用途**:同一個 MCP session 依序驗多個 sha:bridge 退場，新的 PowerShell bridge 重新 `Import-Module`。`ModulePath` 選填，不帶就重載目前載入的路徑。只有模組重載;`index.js`、`bridge.ps1`、tool 清單(`tools.json`)仍是執行中 server 的版本，新模組多出的 cmdlet / 參數要等 server 重啟才會出現在 `tools/list`。
- **做法**:先檢查 `ModulePath`,再把 bridge op `retire` 排進佇列(正在跑的呼叫先跑完)。bridge 依序做三件事:
  1. 確認記憶體裡沒有 lifecycle block(模組有 `Get-TcLifecycleBlockLocalForReload` 就用它;沒有(#41 之前的模組)就直接讀 `$script:TcLifecycleBlockLocal`,它必須存在、是 hashtable 而且是空的;兩者都沒有就拒絕，見 `RELOAD_LIFECYCLE_BLOCKED`)。
  2. 在 state 檔的 mutex 下，把 `$script:TcBuildRequiredLocal` 的每一筆用模組自己的 `Merge-TcBuildRequiredEntry` 合併進 `build-required.json`;檔案缺這筆、或 solution / reasons / build-selection guard 不同就寫回(`data.buildRequiredPersisted` 列出寫回的 key)。模組缺這些 helper 但有變數時，改用 bridge 自己的寫回邏輯：用模組的 `Get-TcBuildRequiredMutexName` 取得同一把鎖，只把檔案裡**沒有**的 key 原樣加進去(檔案裡已有的 key 本來就會擋那個 solution,bridge 不知道 merge 規則就不改它)。寫不了、讀不到、變數不存在、連 mutex 名稱都拿不到 → `RELOAD_BUILD_REQUIRED`。
  3. 執行 `Disconnect-TcAds`、`Disconnect-TcIde`(不帶 `-Quit`,IDE 保持開著),回覆後結束;Node 端再用新的 `-ModulePath` 啟動新的 bridge。

  沒有 bridge 行程在跑(從未啟動，或上次啟動失敗，例如 `RELOAD_FAILED` 且沒還原成功)時不送 `retire`,直接換路徑啟動：沒有行程就沒有記憶體狀態會丟。不在同一個行程裡 `Import-Module -Force`,原因是模組用 `Add-Type` 編進行程的 C# 型別(`TcAdsHelper`、`MessageBoxNative`)卸載不掉，新版改了也不會生效;舊的 COM 參考也會留在行程裡。
- **安裝版 runtime(#162)**:`GetStatus` 的 `data.bridge.runtime.source` 是 `installed` 時，只能重載目前的模組(不帶 `ModulePath`);`moduleCommit` / `moduleDirty` 取自該 runtime 的 `tcauto-source.json`(`moduleSource = 'installed'`)。換版本(連同 `index.js`、`bridge.ps1`、`tools.json`)用 `ReloadRuntime`。下面 `.git` 的讀法只適用 `moduleSource = 'git-checkout'`。
- **回傳**:`data.previous` / `data.current` = `{modulePath, moduleCommit, moduleDirty, moduleSource, loadedAt}`,`data.ideDisconnected`、`data.adsDisconnected`、`data.buildRequiredPersisted`、`data.reconnectRequired = true`。`moduleCommit` 是載入當時該 checkout 的 HEAD 指到的 sha,從 `.git` 檔案讀(`HEAD`、loose ref、`packed-refs`、worktree 的 `commondir`),不啟動 `git.exe`;不在 git checkout 裡時是 `null`。**它只代表 HEAD**:工作區裡還沒 commit 的改動不會反映出來，所以 git checkout 的 `moduleDirty` 一律是 `null`(不跑 git 判斷不了)。驗證特定 sha 時，請用乾淨的 worktree。讀法和 `Get-TcModuleCommit`(ReportIssue 的 commit 行)、install manifest 共用同一套規則(#148,PowerShell 端 `Read-TcGitCommit`,兩邊跑同一組 fixture `tests/fixtures/git-commit-148.json`):檔案一律以 UTF-8 解碼(UTF-8 BOM 會去掉；不偵測其他編碼,UTF-16 檔視為亂碼，和 git 一樣)、只 trim ASCII 空白、`gitdir:` / `ref:` 大小寫敏感、SHA-1 與 SHA-256 都收(大小寫都收，回傳小寫)、分支名可含非 ASCII 字元。讀不到 commit(結果是 `null`,不會給錯的 sha)的情況:ref 不符合 [git check-ref-format](https://git-scm.com/docs/git-check-ref-format) 或不在 `refs/` 底下(含 `..`、`\`、`:`、`~ ^ ? * [`、空白、控制字元、`@{`,某段以 `.` 開頭，結尾是 `.` 或 `.lock`)、symbolic ref 串接、repository 用 reftable(`extensions.refStorage = reftable`,沒有 loose ref / packed-refs)、`.git` 檔沒有 `gitdir:` 行或指到不存在的資料夾。ref 名稱一律逐字(Ordinal)比對:`.` 開頭、結尾是 `.` 的判斷不會略過軟連字號或零寬字元;`.lock` 區分大小寫,但 NTFS 不分大小寫，`main.LOCK` 兩邊(PS、JS)與 git 都接受。`GetStatus` 的 `data.bridge.modulePath` / `moduleCommit` / `moduleDirty` / `loadedAt` 是同一份資料。
- **之後**:IDE / ADS 連線已斷開，先 `ConnectIde`(必要時 `SetTarget`、`ConnectAds`)再做別的。lifecycle block 與 BUILD_REQUIRED 的狀態檔在新 bridge 照樣有效(同一個 `TCAUTO_STATE_DIR` / `%TEMP%\TwinCATAutomation`)。寫回 BUILD_REQUIRED 是偏保守的做法：如果別的行程已經用一次完整 build 把檔案裡的紀錄清掉，本行程記憶體裡那筆仍會被寫回，新 bridge 會要求再 build 一次。
- **Timeout**:210 s(`retire` 90 s + 新 bridge 啟動 60 s + 失敗時還原啟動 60 s)。
- **測試**:`mcp-server/test/reload.test.js`(假 repo 的 allow list 與 commit 讀取;mock bridge 走 stdio;真的 `bridge.ps1` 加 fixture 模組測 `retire`,fixture 會 dot-source 真的 `Private/Set-TcBuildRequired.ps1` 與 `Private/LifecycleBlock.ps1`;另有 #41 之前格式的 fixture `reload-module-old`(有變數、沒有 helper),測 reload 進去再 reload 出來、有 block 仍拒絕、BUILD_REQUIRED 退回邏輯)。registered tcauto 真機 reload 尚未驗證。

### RELOAD_PATH_NOT_ALLOWED

- **為什麼**:`ReloadModule` 的 `ModulePath` 不是允許的路徑。允許的只有兩種:server 啟動時的 `TWINCAT_MODULE_PATH` 所屬 repo 的主 checkout 的 `src\TwinCATAutomation\TwinCATAutomation.psm1`,以及 `<主 checkout>\.git\worktrees\*\gitdir` 登記、而且該 worktree 的 `.git` 檔指回同一筆登記的 worktree 裡的同一個相對路徑(也就是 `git worktree list` 列出、目錄還在的 worktree)。相對路徑、別的檔名、別的 repo、目錄已刪的 worktree、檔案不存在都拒絕。server 本身不是從 git checkout 啟動(安裝版，包括 `Install-TcAutoRuntime.ps1` 裝的 runtime,#162)時，任何 `ModulePath` 都拒絕;安裝版要換版本請重跑安裝腳本再呼叫 `ReloadRuntime`(見下方「ReloadRuntime」一節)。
- **下一步**:從 `data.allowed` 挑一個路徑重試，或不帶 `ModulePath` 重載目前的模組。什麼都沒有斷開或重載(`data.notRun = true`)。

### RELOAD_LIFECYCLE_BLOCKED

- **為什麼**:目前載入的模組記憶體裡有 lifecycle block(`$script:TcLifecycleBlockLocal` 不是空的,#68)。這份記憶體副本可能只存在這個行程(狀態檔寫不了時),reload 之後就看不到，所以一律拒絕，不讓 reload 變成繞過 fail closed 的方法。檢查集中在模組的 private 函式 `Get-TcLifecycleBlockLocalForReload`(`Private/LifecycleBlock.ps1`),bridge 只呼叫它。#41 之前的模組(例如要驗的 #42 / #114 / #119 / #120 / #122 / #127 branch)沒有這個函式，這時 bridge 直接讀 `$script:TcLifecycleBlockLocal`(#68 之後的模組都有),所以可以 reload 進那些 sha,也可以再 reload 出來;裡面有 block 時照樣拒絕。函式和變數都沒有(#68 之前的模組,`key = '<missing>'`),或函式丟例外、值不是 hashtable(`'<unreadable>'`)也當成有 block。目前它只看本行程的記憶體副本：別的 bridge 已經 Clear 掉的紀錄，這裡仍會擋(#130 的跨 bridge 同步 merge 後，這個函式會改成先同步再判斷)。`data.lifecycleBlocks` = `[{key, record}]`,什麼都沒有斷開或重載(`data.notRun = true`)。
- **下一步**:依 [LIFECYCLE_BLOCKED](#lifecycle_blocked) 的人工核准流程：停止、把 `data.lifecycleBlocks` 回報使用者;使用者同意後才 `ClearLifecycleBlock`,再重跑 `ReloadModule`。不要用重啟 MCP server / kill bridge 的方式繞過。

### RELOAD_BUILD_REQUIRED

- **為什麼**:目前載入的模組記憶體裡有 BUILD_REQUIRED 紀錄(`$script:TcBuildRequiredLocal`),但沒辦法確認它們都已經寫進 `build-required.json`:鎖不到、檔案讀不到或寫不了、變數不存在，或模組缺寫檔 helper 而且連 `Get-TcBuildRequiredMutexName` 也沒有(bridge 的退回邏輯拿不到同一把鎖)。reload 會丟掉記憶體副本，等於繞過 build gate(#61 / #65),所以拒絕。`data.buildRequiredKeys` 列出記憶體裡的 solution key,`data.error` 是原因，什麼都沒有斷開或重載(`data.notRun = true`)。只要記憶體紀錄都能寫進檔案，就不會拒絕。
- **下一步**:`BuildProject` 跑到 `data.completeBuild = true`(會把紀錄清掉),或讓 state 目錄恢復可寫，再 `ReloadModule`。不要用重啟 MCP server / kill bridge 的方式繞過。

### RELOAD_FAILED

- **為什麼**:舊 bridge 已退場(IDE / ADS 已斷開),但新的 `ModulePath` 匯入失敗(`data.importError`,例如語法錯誤、檔案在 Windows PowerShell 5.1 下 parse 不過)。
- **下一步**:`data.restored = true` 表示已重新載入原本的路徑(`data.current`),修好模組後再 `ReloadModule`;之後要重新 `ConnectIde`。`data.restored = false`(`data.restoreError`;重載的就是原本的路徑時也不會還原)時目前沒有模組，一般呼叫都回 `MODULE_IMPORT_FAILED`;這時 `ReloadModule` 換到一條能匯入的白名單路徑就會恢復(沒有 bridge 行程時不送 `retire`,直接換路徑啟動),或重啟 server。

### OneDrive 與 hydration(MCP,#162 / #158)

- **現象**:MCP 註冊直接指向 OneDrive 裡的 `<repo>\mcp-server\index.js` 時，client 重開後第一個呼叫回 `MODULE_IMPORT_FAILED`(`Bridge exited before ready (code 1)`),bridge 的 stderr 是 `The cloud sync provider failed to validate the downloaded data.`(雲端檔案提供者錯誤 383,#162,2026-11-06 Codex 回報)。同一份 repo 在 OneDrive 路徑下 `Import-Module` 要 52–65 s,複製到 `%TEMP%` 約 6 s(實測 2026-11-06,Windows 11、PS 5.1,#158),貼著 bridge 的啟動 timeout 60 s。
- **原因**:OneDrive「檔案隨選」只在本機留 placeholder,第一次讀取才下載(hydration)。下載驗證失敗時讀檔直接出錯;成功時，每個被 dot-source 的小檔也都要先經過 cloud file provider。另外 client 跑的是 checkout 當下所在的分支。
- **做法**:不要讓 MCP client 從 OneDrive 執行 runtime。用 `scripts\Install-TcAutoRuntime.ps1` 把 runtime 裝到 `%LOCALAPPDATA%\TwinCATAutomation\runtime\<version>\`,client 只註冊 launcher(`docs/setup-mcp.md`)。安裝腳本自己會從 OneDrive 讀檔(只複製 `git ls-files -co --exclude-standard` 列出的檔案，被 gitignore 的檔案不會進 runtime),讀不到時回 `COPY_FAILED`:在檔案總管對 checkout 資料夾按右鍵 →「一律保留在此裝置上」,等 OneDrive 下載完再跑一次。
- **還沒做的**:bridge 啟動前預讀檔案、`MODULE_IMPORT_FAILED` 帶出 cloud provider 的 stderr 原文(#162 建議 2–3)不在這次範圍;直接從 OneDrive checkout 跑 `index.js`(開發用)仍會遇到上述延遲。

### ReloadRuntime(MCP launcher,#162):做法與共同規則

- **用途**:換到 `runtime\current.json` 指定的版本(先跑 `Install-TcAutoRuntime.ps1`),不用重連 MCP client。整個 runtime(`index.js`、`bridge.ps1`、`tools.json`、模組)一起換;`ReloadModule` 只換 PowerShell 模組。這個 tool 是 launcher(`mcp-server\launcher\tcauto-launcher.mjs`)自己加進 `tools/list` 的，只有經 launcher 啟動時才有。
- **做法**(launcher):
  1. 有還沒回應的 `tools/call` → `RUNTIME_RELOAD_BUSY`,什麼都不做(lifecycle 操作不能被切斷)。`current.json` 讀不到 / 版本資料夾不完整 → `RUNTIME_NOT_INSTALLED`,什麼都不做。
  2. 對舊 runtime 送 launcher 專用的 request `tcauto/retire`:`index.js` 讓 bridge 走和 `ReloadModule` 相同的 `retire`(記憶體裡有 lifecycle block → `RELOAD_LIFECYCLE_BLOCKED`;BUILD_REQUIRED 寫不回檔案 → `RELOAD_BUILD_REQUIRED`;兩者都是什麼都沒變，舊 runtime 照常服務)。成功時 IDE / ADS 連線釋放(IDE 保持開著),`index.js` 等 PowerShell 結束後才回覆，之後的 tool call 一律回 `RUNTIME_RETIRED`。這個 request 只有 `TCAUTO_LAUNCHER_PID` 等於父行程 pid 的 `index.js` 才接受;client 直接送 `tcauto/...` 會被 launcher 回 Method not found。
  3. 關閉舊 runtime 的 stdin(正常 shutdown;20 s 內沒結束才 kill)。
  4. 啟動新 runtime,重送 client 當初的 `initialize`(回應吞掉)與 `notifications/initialized`,回覆 tool call,再送 `notifications/tools/list_changed`。launcher 的 `initialize` 回應一律標 `capabilities.tools.listChanged = true`。
  5. 新 runtime 起不來 → `RUNTIME_START_FAILED`,自動重啟舊版本(`data.restored`)。
- **重載中的請求**:立刻回 `RUNTIME_RELOADING`(tool call 回 tool error,其他 request 回 JSON-RPC error),不排隊、不丟失;`ping` 由 launcher 自己回。
- **runtime 意外結束**:它還沒回應的 request 全部回 `RUNTIME_DIED`;下一個 request 自動用同一個版本重啟(重送 `initialize`)。
- **環境變數**:launcher 不把 `TWINCAT_MODULE_PATH`、`TWINCAT_MCP_TOOLS_JSON`、`TWINCAT_MCP_PROBE_SCAN_SCRIPT` 傳給 runtime(stderr 會記一行),安裝版 runtime 一律用自己的模組與 `tools.json`,不會悄悄載入 OneDrive checkout 的模組。`installed` 的判定要求 `tcauto-source.json` 的 `kind` 是 `tcauto-runtime`(#20 的 release stamp 不算)。
- **owner id**:一個 launcher 行程一個 GUID,傳給每個 runtime,所以 `ReloadRuntime` 前後啟動的 IDE 都算同一個 session 的(見「啟動紀錄持久化(#73 / #149)」)。
- **回傳**:`data.previous` / `data.current` = `{version, commit, dirty, branch, installedAt, runtimeDir}`,`data.retired`(bridge retire 的 data,例如 `ideWasConnected`),`data.reconnectRequired = true`。之後先 `ConnectIde`。
- **client 端**:收到 `notifications/tools/list_changed` 後會不會重抓 tool 清單由 client 決定(Claude Code / Claude Desktop / Codex 未實測)。沒重抓時，新版本新增的 tool / 參數要重連 client 才看得到;既有 tool 的呼叫已經送到新 runtime。
- **測試**:`mcp-server/test/launcher.test.js`(mock runtime:轉送、重放 initialize、list_changed、重載中請求、有進行中呼叫時拒絕、retire 被拒、runtime 掛掉、新版本起不來;以及兩份真的 `index.js` 複本 + mock bridge)、`mcp-server/test/runtime-info.test.js`、`mcp-server/test/install-runtime.test.js`。registered tcauto 真機驗證尚未做。

### RUNTIME_NOT_INSTALLED

- **為什麼**:launcher 找不到可用的 runtime:`<install root>\runtime\current.json` 不存在、不是 JSON、`version` 不是 runtime 資料夾名稱，或該版本的 `mcp-server\index.js` 不存在。install root 是 `TCAUTO_RUNTIME_ROOT`,沒設就是 launcher 所在資料夾的上一層。
- **下一步**:在 checkout 跑 `powershell -NoProfile -File scripts\Install-TcAutoRuntime.ps1`,再重試(或 `ReloadRuntime`)。`ReloadRuntime` 回這個碼時什麼都沒變(`data.notRun = true`)。

### RUNTIME_RELOAD_BUSY

- **為什麼**:`ReloadRuntime` 時還有 tool call 在 runtime 裡跑(`data.running` 列出名稱),或 runtime 正在啟動。什麼都沒變。
- **下一步**:等那些呼叫回來，再 `ReloadRuntime`。不要為了 reload 中斷 `BuildProject` / `EnableConfig` / `RunLifecycle`。

### RUNTIME_RELOADING

- **為什麼**:呼叫送到時 `ReloadRuntime` 正在換 runtime,這個呼叫沒有執行;或某個 request 在 reload 退場的 runtime 裡沒被回應。
- **下一步**:等 `ReloadRuntime` 回來後再呼叫(reload 會釋放 IDE 連線，先 `ConnectIde`)。

### RUNTIME_RETIRED

- **為什麼**:這個 runtime 已經被 launcher 的 retire 收掉(通常是 `ReloadRuntime` 的 retire 超時後才完成),不再接受呼叫。
- **下一步**:再呼叫一次 `ReloadRuntime`(launcher 會啟動 `current.json` 指定的 runtime),然後 `ConnectIde`。

### RUNTIME_DIED

- **為什麼**:runtime 行程(node)在回應前結束了(`error.message` 帶 exit code)。呼叫可能跑了，也可能沒跑。
- **下一步**:下一個呼叫會自動重啟同一個版本(IDE / ADS 狀態全部遺失)。改變機器狀態的呼叫重做前先 `GetStatus` / `GetPlcState` 確認，再 `ConnectIde`。原因看 launcher 的 stderr(client 的 MCP log)。

### RUNTIME_START_FAILED

- **為什麼**:runtime 起不來或沒回應重送的 `initialize`(例如安裝不完整、`node_modules` 缺檔、`tools.json` 壞掉)。`ReloadRuntime` 時舊 runtime 已退場;`data.restored = true` 表示已重新啟動舊版本。
- **下一步**:重跑 `Install-TcAutoRuntime.ps1` 再 `ReloadRuntime`;不管有沒有還原都要重新 `ConnectIde`。`data.restored = false` 時下一個呼叫會試著啟動 `current.json` 指定的版本。

### RUNTIME_RETIRE_TIMEOUT / RUNTIME_RETIRE_UNSUPPORTED / RUNTIME_RETIRE_FAILED

- **為什麼**:舊 runtime 沒在時間內回應 `tcauto/retire`(`TIMEOUT`,舊 runtime 繼續跑)、不認得這個 request(`UNSUPPORTED`,比 launcher 舊的 runtime),或回了 JSON-RPC 錯誤(`FAILED`)。三者都沒有切換,launcher 也不會硬殺舊 runtime(不能跳過 bridge 的 fail-closed retire)。
- **下一步**:`TIMEOUT`:先 `GetStatus`,稍後再 `ReloadRuntime`(若之後回 `RUNTIME_RETIRED`,表示 retire 晚到完成，再 `ReloadRuntime` 一次)。`UNSUPPORTED`:重連 MCP client(Claude Code 用 `/mcp` reconnect),bridge 會走正常 shutdown。`FAILED`:回報錯誤內容。

### 安裝器錯誤碼(Install-TcAuto.ps1 / Install-TcAutoRuntime.ps1 / Build-TcAutoRelease.ps1,#162 #20 #165)

三支腳本最後一行都是 `TCAUTO_INSTALL_RESULT {json}`(`success`、`data` 或 `error.code` + `hint`),exit code 0 / 1。這些碼不是模組的 `error.code`,不在 `TcErrorHints`。安裝步驟見 `docs/setup-mcp.md`。

**兩支安裝腳本共用**

- `INSTALL_PACKAGED_CONTEXT`(#170):安裝根目錄在 `%LOCALAPPDATA%` / `%APPDATA%` 之下,而執行安裝的 PowerShell 跑在 MSIX 套件裡(典型:在 Claude Desktop 的「Code」分頁裡執行安裝)。套件內程序寫 AppData 會被 Windows 重導到 `%LOCALAPPDATA%\Packages\<套件>\LocalCache\{Local,Roaming}\`([MSIX: Behind the scenes](https://learn.microsoft.com/windows/msix/desktop/desktop-to-uwp-behind-the-scenes)),只有該套件看得到;套件外的 Claude Code / Codex 拿到的路徑不存在,啟動時 `CONNECTION_CLOSED`(實測 2026-11-07,Windows 11,Claude Desktop MSIX `Claude_pzs8sxrjxfjjc`:檔案只在 `Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local\TwinCATAutomation\`,Claude Code 的 `node.exe` spawn `ENOENT`)。偵測兩道:先看 package identity(`data.detectedBy = 'packageIdentity'`、`data.packageFullName`);沒有 identity 時,在安裝根目錄的上一層寫一個 GUID 命名的探針檔,看它有沒有出現在 `Packages\*\LocalCache\{Local,Roaming}\` 底下(`data.detectedBy = 'probe'`、`data.packageFolder`、`data.redirectedTo`),兩邊的探針都會刪掉。只靠 identity 不夠:實測 2026-11-08 同一環境,Code 分頁 shell 的 `powershell.exe` 沒被判出 identity,照常安裝且檔案被重導。同一次實測,寫到 `%TEMP%`(`AppData\Local\Temp`)不受影響,落在真實路徑。什麼都沒寫。請改從一般的 PowerShell 視窗(開始功能表 / Windows Terminal)重跑同一指令。之前已在套件內裝過的,Claude Desktop 仍用 LocalCache 那份;套件外重裝一次後 Claude Code 就連得上。
- `INSTALL_PROBE_FAILED`(#170):上面的探針寫不進去、檢查失敗或刪不掉,無法判斷檔案會不會被重導,fail closed 不安裝。`data.leftover` 列出沒刪掉的探針(`.tcauto-probe-*`,可手動刪)。確認安裝根目錄的上一層存在且可寫,從一般 PowerShell 視窗重跑。

**Install-TcAuto.ps1(客戶 zip)**

- `PACKAGE_INCOMPLETE`:不是完整的 release 資料夾(缺 `tcauto-release.json` / `node\node.exe` / launcher / `lib\tcauto-client-config.mjs`,或 `runtime\` 不是剛好一個版本,或該版本的 `tcauto-source.json` 不符)。整個 zip 重新解壓縮、核對 SHA256 後從解壓縮資料夾執行;在 checkout 裡改用 `scripts\Install-TcAutoRuntime.ps1`。
- `CLIENT_CONFIG_FAILED`:檔案已裝好,但某個 client 設定檔改不了(JSON 壞掉;Codex 的 `tcauto` 寫成 key 或 `[[mcp_servers.tcauto]]` array of tables,而不是一個 `[mcp_servers.tcauto]` table;改完讀回不對，例如 table 裡有兩個 `command`(#204);檔案被鎖),原因在 `error.message` 與 `data.clients[]`(該檔案沒被改)。修好那個檔案再執行一次;`-Uninstall` 也可能回這個碼,處理方式相同。
- `INSTALL_SHARED`:`-Uninstall` 發現某個 client 的 `tcauto` 雖然 command 不在安裝根目錄下,但 args 仍指到安裝根目錄(例如開發者註冊的 `node <root>\launcher\tcauto-launcher.mjs`)。為了不弄壞那個 client,什麼都沒刪。先改掉或移除那個註冊(`claude mcp remove tcauto -s user`)再 `-Uninstall`;確定要一起移除就加 `-Force`。
- `INSTALL_IN_USE`:`-Uninstall` 時 `runtime\` / `launcher\` / `node\` 有資料夾被使用中(Claude Code、Claude Desktop、Codex 都在跑 launcher)。改名失敗(Access denied、sharing violation)會先重試數秒(`runtime\`、`launcher\`、`node\` 三個資料夾共用約 5 秒，間隔逐步拉長;client 真的佔著時約 5 秒後回錯),例如剛跑完 `-Verify` 的 node.exe 還在結束、或防毒還握著 handle 時會自己過;仍失敗才回這個碼(#208)。關掉這些 client 再執行。
- `NODE_IN_USE`:要換新的 `node.exe`,但舊的被執行中的 client 佔住,舊檔沒動。關掉 client 再執行。
- `COPY_FAILED`:複製 `node.exe` 或其他檔案失敗(磁碟空間、目錄不可寫,或雲端同步資料夾下載不了)。訊息說明舊 `node.exe` 是否已放回。
- `RUNTIME_DAMAGED`:複製後 `runtime\<version>\` 不完整(沒有 `node_modules` 或 `index.js`)。重新下載 zip、核對 SHA256 後再執行。
- `VERIFY_FAILED`:`-Verify`(或安裝最後那一步)啟動安裝的 `node.exe` + launcher、送 `initialize` + `tools/list` 失敗。訊息含 launcher 的 stderr;再跑一次 `-Verify`,仍失敗就回報訊息。
- `TCAUTO_REAL_STATE_REFUSED`:只在測試環境(`TCAUTO_TEST_FORBID_REAL_STATE=1`)出現。#165 之後 Claude Desktop 的設定檔有兩處(標準版 `%APPDATA%\Claude\`、MSIX 版 `%LOCALAPPDATA%\Claude-Data\claude_*\`),只要目標檔案落在這兩個真實資料夾之下就拒絕寫入(例如測試沒傳 `-ClaudeDesktopConfig`,或沒用 `-LocalAppDataRoot` / `-AppDataRoot` 指到暫存資料夾)。測試要傳其中之一;一般使用者不會碰到(不設該環境變數)。
- `BAD_ARGUMENT`:`-Clients` 有不認得的名稱(可用 `ClaudeCode`、`ClaudeDesktop`、`Codex`),或 `-Uninstall` 與 `-Verify` 一起用。
- `INSTALL_FAILED`:其他未預期的錯誤(訊息含出錯的檔案與行號);這一步之後的事都沒做,再執行一次,同樣失敗就回報訊息。

**Build-TcAutoRelease.ps1(打包 zip)**

- `NODE_HASH_MISMATCH`:下載的 `node-v<ver>-win-x64.zip`、zip 裡的 `node.exe`、或 `-NodeExePath` 指定的 `node.exe` 的 SHA256 與腳本固定的值(或該 Node 版本 `SHASUMS256.txt` 那一行)不同,什麼都沒打包。不要改腳本裡的 hash 來繞過;重新下載,檢查網路 / proxy 是否改了內容。
- `NODE_DOWNLOAD_FAILED` / `NODE_NOT_FOUND`:下載 Node.js 失敗(檢查網路 / proxy,或自己下載後用 `-NodeExePath <node.exe>`);`-NodeExePath` 指到的檔案不存在。
- `NPM_CI_FAILED`:runtime 暫存複本裡的 `npm ci --omit=dev` 失敗。
- `GIT_FAILED` / `WORKTREE_DIRTY` / `BAD_ARGUMENT`:git 讀不到、有未 commit 的改動(`-AllowDirty` 才打包,版本名帶 `-dirty`)、`-Version` 含檔名不該有的字元。
- `BUILD_FAILED`:其他未預期的錯誤。

**Install-TcAutoRuntime.ps1(開發者)**

- `WORKTREE_DIRTY`:`mcp-server\`(不含 `test\`)或 `src\TwinCATAutomation\` 有未 commit 的改動(`data.changes`),什麼都沒寫。commit 後重跑,或加 `-AllowDirty`(版本名 `<commit>-dirty-<UTC 時間>`,`dirty: true`)。
- `COPY_FAILED`:某個檔案複製失敗,多半是 OneDrive 檔案下載不了(見上方「OneDrive 與 hydration」)。
- `NPM_CI_FAILED`:暫存複本裡的 `npm ci --omit=dev` 失敗(Node / npm 不在 PATH、registry 連不到)。暫存複本會刪掉,`current.json` 不變。
- `RUNTIME_DAMAGED` / `RUNTIME_IN_USE`:同名版本資料夾不完整;是 current 就不動它(可能正在跑),否則刪不掉(被使用中)。
- `GIT_NOT_FOUND` / `GIT_FAILED` / `SOURCE_INCOMPLETE` / `RENAME_FAILED` / `CURRENT_WRITE_FAILED` / `LAUNCHER_WRITE_FAILED`:訊息裡有路徑與原因;`current.json` 只在新版本完整就位後才換。
- `TCAUTO_REAL_STATE_REFUSED`:測試環境(`TCAUTO_TEST_FORBID_REAL_STATE=1`)指到真的 `%LOCALAPPDATA%\TwinCATAutomation`,拒絕寫入(#118)。

### SYSTEM_STATE_TIMEOUT

- **為什麼**:`Set-TcSystemState` 透過 ADS WriteControl 要求切換後,輪詢 port 10000 在 `-TimeoutSec` 內沒到目標狀態。原因:TwinCAT System Service 報錯(license、config 錯)、UmRT service 掛掉、或 target 無回應。UmRT 還有一種:process 活著、CPU idle,但對 199.5.42.250.1.1 的每個 ADS 呼叫都回 **0x502「Mailbox is full」**(本機 TcSysSrv 正常)→ `Enable-TcConfig` 等 180 s 回 `SYSTEM_STATE_TIMEOUT`(2026-10-21 實測,見「已知限制」)。若 target 是 UmRT 且剛 Activate 就停在 Config,常見原因是 license 不足(trial 未涵蓋專案用到的 TF),請在 XAE 的 License 節點確認。
- **回報的狀態**(#114):最後一次讀取失敗(ADS 錯誤，例如 0x7)時 `data.finalState` / `currentState` 是 `Unreachable`,不是之前最後讀到的狀態(那個在 `data.lastState`,錯誤在 `data.lastError`),message 寫「last state: unreachable (last state read: …)」,lifecycle block 的 `reachedState` 是空的(`step` 寫 unreachable),`LIFECYCLE_BLOCKED` 訊息寫「read back afterwards: nothing (port 10000 unreachable)」;這時不讀授權。本機 UmRT 會另附 `servicePidAtStart`、`runtimeName`、`unreachableMs`、`deadlineCheck`,失敗時都附 `probeErrors`(失敗的探測，連續相同的合成一段：`fromMs`、`toMs`、`count`、`code`(對應的模組錯誤碼,`null` = 沒對應到)、`adsCode`、`hresult` 與 `message`(取最內層例外，不是 PowerShell 外層 MethodInvocationException 的在地化訊息)、`pidAlive`;最多 50 段(前 10 段 + 最後 40 段),中間丟掉的段數在 `probeErrorsDropped`),供判斷是不是 crash(最後讀取失敗且該 runtime 已沒有行程會直接回 `RUNTIME_CRASHED`,見該節)。
- **停在 Config 的診斷(#194)**:要 Run 卻停在 Config(最後讀到 Config 的 `SYSTEM_STATE_TIMEOUT`,以及退回 Config 的 `SYSTEM_STATE_MISMATCH`)時,除了 `data.licenses` 也帶 `data.diagnostics`,欄位和 `Enable-TcConfig` 的一樣(`Get-TcRuntimeFailureDiagnostics`):`dialog`(XAE modal 標題/內文)、`dialogScanComplete`、`errorList`(Error List 前 10 筆錯誤;有 dialog 時刻意不讀，這時 `errorListError` 寫 `unavailable: not read while a modal dialog is up ...`,不會是空陣列配 `null`,#198;dialog 掃描沒完成也當成狀態未知，一律不呼叫 DTE(含 `View.ErrorList`),`errorListError` 寫 `unavailable: modal scan incomplete`,CODING_STANDARDS §1、同 #181)、`errorListError`、`bootPackage`(本機 target 的 Boot 比對)、掃描沒完成時的 `modalScan`。沒有 IDE 連線(只用 ADS)時 dialog / Error List 不讀:`dialogScanComplete = false`、`modalScan.reason = no-ide`、`errorListError = "unavailable: no IDE connection"`。收集失敗只記在這些欄位,錯誤碼不變。只有 `-State Run` 才收集(`Enable-TcConfig` 的 set-config 不收集)。順序(PR #200 review,#68 fail closed):先寫 lifecycle block,再讀授權、診斷、改 hint;先掃 modal dialog,有 dialog 或掃描沒完成就不碰 DTE(被 dialog 擋住的 DTE 呼叫可能不返回),platform 改用最近一次 `Connect-TcIde` / `Set-TcTarget` 讀到的值、PLC port 與 CurrentProjectVariant 不讀,`bootPackage.warnings` 會寫明;整個收集在「送出請求 + `-TimeoutSec` + 10 s」內結束(剩不到 5 s 時 Error List 不讀，寫 `skipped: -TimeoutSec budget exhausted`),不會超過 MCP 給 SetSystemState 的 `max(180 s, TimeoutSec + 30 s)`。`error.hint` 依診斷決定:dialog 或 Error List 有 `AdsError: 1809` / `0x711` / `symbol version invalid` / `symbol description does not match`(不分大小寫;單獨的 `1809` 不算)→ ADS 1809 說明(見「ADS_SYMBOL_VERSION_INVALID」),原因依 `bootPackage.status`:`mismatch` 才斷言是 Boot 的 CurrentConfig 與 PLC `.app` 不一致,`match` 說不是 CurrentConfig 舊版造成,`unavailable` 只寫「可能是」;其他 dialog → 引用它的內容(截到 300 字);授權伺服器讀到至少一個授權且全部有效時不會說是 license 不足，寫「已讀到的 N 個授權都有效;沒列出的 TF 授權不在這次判斷範圍內」,一個都沒讀到不算有效;有過期 / 無效授權且沒有 dialog → 原本的授權 hint。實測 2026-11-08(4026 64-bit XAE Shell + 本機 UmRT,#194):授權全部有效,真正原因是 XAE 的「Target system reports a fatal error ... AdsError: 1809 (0x711, ADS ERROR: symbol version invalid)」。`Enable-TcConfig -Force` 的 set-run 內不另外收集(它自己的 `data.diagnostics` 照舊)。
- **下一步**:`Get-TcSystemState` 看現在的狀態;看 `data.diagnostics`、XAE 的 TwinCAT 圖示、License 節點與 Windows 事件檢視器;UmRT 重啟 `TcSystemServiceUm`(0x502 的唯一解法;重啟後停在 Config,再 `Enable-TcConfig -Force`)。

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
- **原狀態 = 目標**(Run → Run 重啟、Config → Config):送出後必須先看到 port 10000 離開該狀態(別的狀態或連不上,每 100 ms 讀,最多 10 s)才開始等目標;看不到就是 `SYSTEM_STATE_MISMATCH`(`data.leftOriginal = false`),不把舊狀態當成重啟完成。`data.leftOriginal` 只在某次讀取**真的讀到**和 `originalState` 不同的狀態時才是 `true`(#114;讀取失敗不算狀態，送出後的讀取失敗(離開檢查、等待或 settle 任一次)記在 `data.unreachableSeen`;`originalState` 讀不到時是 `null`)。所以只看到「連不上 → 回到 Run」的 Run → Run 重啟是 success、`leftOriginal = false`、`unreachableSeen = true`。data 另有 `originalState`、`finalState`、`reached`、`held`、`latencyMs`。
- **授權診斷**:`SYSTEM_STATE_TIMEOUT` / `SYSTEM_STATE_MISMATCH` 且狀態是 Config 時,讀 target 的授權伺服器(ADS port 30,[InfoSys AmsPort「R0_LicenseServer 30」](https://infosys.beckhoff.com/content/1033/tc3_ads.net/9408352011.html);同樣的資料 PLC 端用 [FB_GetLicenses](https://infosys.beckhoff.com/content/1031/tcplclib_tc2_utilities/1876715915.html) 讀)。有過期或無效的授權就寫進 `error.hint`,清單在 `data.licenses`(name / expires / status / valid / expired);讀不到就略過,不會變成新錯誤。同時帶 `data.diagnostics`,hint 規則見上面 `SYSTEM_STATE_TIMEOUT` 的「停在 Config 的診斷(#194)」。index group(0x01010006 有效、0x0101000A 無效、0x0101000C 名稱)InfoSys 未記載,是實測(本機 UmRT:9 個 trial 授權,到期 2026-10-25)。

### RUNTIME_CRASHED

- **現象**:`Set-TcSystemState`(以及呼叫它的 `Enable-TcConfig -Force` 的 set-config / set-run)等狀態切換時，本機 UmRT 的 `TcSystemServiceUm` 行程不見了。以前會一直輪詢到 `-TimeoutSec` 才回 `SYSTEM_STATE_TIMEOUT`(message 還寫「last state: Run」);實測 2026-10-29(4026 VS2022,本機 UmRT,`tests/Integration/logs/phase0-1.7-results.md` 發現 1、2):set-config 開始約 40 s 行程就消失，之後每次都是 ADS 0x7,等滿 300 s。
- **觸發條件**(`Wait-TcAdsState -DetectRuntimeCrash`,三個都成立才回):
  1. target 是**本機 UmRT**:target AmsNetId 等於本機 `%ProgramData%\Beckhoff\TwinCAT\3.1\Runtimes\<name>\3.1\TcRegistry.xml` 的 `AmsNetId`(`Resolve-TcTargetBootDir` 回 `umrt:<name>`;檔案格式 InfoSys 未記載，實測 2026-10-21),而且開始等待時有命令列含 `-n "<name>"` 的 `TcSystemServiceUm.exe`(`Get-TcLocalUmRtProcess`;命令列讀不到時改用讀不到命令列的那幾個 `TcSystemServiceUm.exe`)。
  2. port 10000 連續回 **ADS 0x7**(`ADS_TARGET_NOT_FOUND`,target machine not found)至少 10 s;中間只要有一次別的結果就重新計時。
  3. 開始等待時記下的 pid(`data.servicePidAtStart`)全部已經不存在。
  遠端 target、本機 XAR、開始時沒有 UmRT 行程：不偵測，行為不變(等到 `-TimeoutSec`)。
  **到 deadline 時再判一次**(#114,`data.crashDetectedBy = 'deadline'`;提早結束的是 `'streak'`):實測那次 10 s 為什麼沒觸發**未確認**(沒有逐次探測紀錄)。程式上可能的原因:(a) 10 s 從**第一次讀到 0x7 的探測**起算、中間有別的結果就重來，到 deadline 還湊不滿;(b) 例外沒被 `ConvertTo-TcAdsErrorCode` 對應成 `ADS_TARGET_NOT_FOUND`,根本不開始計時;(c) `Test-TcProcessAlive` 對開始時的 pid 仍回 true。實測 2026-11-04(4026 VS2022,本機 UmRT,`TcSystemServiceUm.exe` 3.1.0.2649):60 s 的等待在第 46 s 行程消失，之後一直 0x7,到 deadline 只有 14.7 s,舊版回 `SYSTEM_STATE_TIMEOUT`(`openspec/changes/complete-automation-interface/verification/issue68-reverify-077d51e.md` 旁支 1)。現在逾時當下若最後一次探測失敗(任何錯誤，涵蓋 a、b)、`Get-TcLocalUmRtProcess` 讀得到行程清單(`ProcessListReadable`;讀不到不算消失)且找不到這個 runtime 的任何 `TcSystemServiceUm`(排除以新 pid 重啟中的情況;開始時 pid 的 `Test-TcProcessAlive` 結果不當條件，涵蓋 c,只記在 `data.deadlineCheck.startPidsAlive`),也回 `RUNTIME_CRASHED`。下次真機發生時看 `data.probeErrors`(每段的 `code`、`adsCode`、`pidAlive`、時間)就能分辨是 a、b 還是 c。**限制**:deadline 判定的意思只是「到期時讀取失敗，而且這個 runtime 沒有任何行程」,分不出是 crash、使用者自己停掉 UmRT,還是重啟中剛好沒有行程的空檔;要看 Windows 事件 1000 / crash dump 確認。
- **data**:`lastError`(最後一次 ADS 錯誤)、`lastState`(等待中最後讀到的狀態，沒讀到就是送出前的狀態)、`servicePidAtStart`、`runtimeName`、`unreachableMs`、`crashDetectedBy`(`streak` / `deadline`)、`probeErrors` / `probeErrorsDropped`、`deadlineCheck`(`startPidsAlive`、`pidsNow`、`processListReadable`、`lastProbeCode`);`finalState` / `currentState` 是 `Unreachable`(#114,不是死前讀到的狀態),其餘同 `Set-TcSystemState`。`Enable-TcConfig -Force` 原樣回 code 與 hint,crash 資料在 `data.runtimeCrash`;`Invoke-TcTestCycle` 也原樣回 `RUNTIME_CRASHED`(不改成 `ACTIVATION_FAILED`),附 `data.runtimeCrash`。
- **下一步**:不要重試同一步。這個 target 已記錄 lifecycle block(#68,見「LIFECYCLE_BLOCKED」):停止，把 `data` 回報使用者，由使用者決定是否重啟 `TcSystemServiceUm`;AI agent 不要自行重啟 service、`Stop-Process` 或操作 console。使用者重啟(指令見上面 `SYSTEM_STATE_TIMEOUT` 的 UmRT 重啟指令;重啟後 runtime 停在 Config)並同意後，才 `Clear-TcLifecycleBlock`,再 `Enable-TcConfig -Force`(MCP `EnableConfig Force=true`)。crash 簽名(Windows 事件 1000 的 faulting module / exception code、`%LOCALAPPDATA%\CrashDumps\TcSystemServiceUm.exe.<pid>.dmp`)對照「已知限制」的 UmRT crash(#21);簽名不同就記下 dump 開 issue。

### RUNTIME_STATE_MISMATCH

- **為什麼**:`Enable-TcConfig -Force` 前面每一步都過了,最後的 `verify` 步驟讀回 port 10000 不是 Run、某個 PLC port(851、852…)不是 Run,或 IDE 有 modal dialog(`data.finalCheck = { systemState, plcs[], dialog, ok }`)。多 PLC solution 以前只看 851,852 起不來也回 success。
- **data.diagnostics**(Activate 之後任何一步失敗都會附):`dialog`(modal 標題/內文)、`errorList`(XAE Error List 前 10 筆錯誤描述;有 dialog 時不讀)、`bootPackage`(重新比對一次)。
- **下一步**:看 `diagnostics`;Boot package 不一致見下;dialog 是 fatal error 時看 Error List 的訊息(例如「The loaded symbol description does not match the plc application」)。

### BOOT_PACKAGE_MISMATCH

- **為什麼**:Activate 後專案 `_Boot\<platform>` 與 target Boot 目錄的檔案不一致,代表 Activate 沒把新 configuration 寫到 target,runtime 會用舊 package 啟動。比對 `CurrentConfig.xml`、`CurrentConfig.tszip`、`CurrentConfig\*.tpzip`、`Plc\Port_*.app`(只比本機 package 有的檔;target 多出來的 tpzip 列在 `extraOnTarget`,不算不一致),`data.bootPackage.files[]` 每檔有 local / target 的 `size`、`lastWriteTime`、`sha256`。
- **Variant 專案(#89)**:有 current variant 時本機 package 在 `_Boot\<Variant>\<platform>`(XAE 寫到那裡，自建 client 實測 2026-11-01 4026 VS2022,phase3-probe 第 18 題),這個資料夾存在時**只比它**(review S1:不能讓比較新的 `_Boot\<platform>` 蓋掉過期的 variant 包),不存在才退回 `_Boot\<platform>` 並在 `data.bootPackage.warnings` 說明;`.tsproj` 明寫 `SpecificLocalBootFolder="false"` 時只看 `_Boot\<platform>`。讀 `CurrentProjectVariant` 失敗回 `VARIANT_READ_FAILED`,不當成沒有 variant;`data.bootPackage.variant` 是比對時的 variant。修正前 variant 專案一律誤報這個碼。
- **只對本機 runtime**:UmRT 依 `%ProgramData%\Beckhoff\TwinCAT\3.1\Runtimes\<name>\3.1\TcRegistry.xml` 的 `AmsNetId`(BIN,`C7052AFA0101` = 199.5.42.250.1.1)找到 `<name>\3.1\Boot`(InfoSys 未記載,實測);本機 XAR 是 `%ProgramData%\Beckhoff\TwinCAT\3.1\Boot`([InfoSys 4026 起的 Boot 目錄](https://infosys.beckhoff.com/content/1033/tc3_grundlagen/4291093003.html),4026 前是 `C:\TwinCAT\3.1\Boot`)。遠端 target `status = unavailable`,不阻擋流程。
- **實測**(2026-10-21,4026 + VS2022,本機 UmRT):正常 Activate 後 6 個檔(2 個 CurrentConfig、2 個 tpzip、Port_851.app、Port_852.app)SHA-256 全相同。把 target 的 CurrentConfig 三個檔換回前一版、保留新的 Port_852.app 後 `Set-TcSystemState -State Run`:system 照樣進 Run 並停住,但 851 / 852 都是 Invalid(PLC 沒載入)→ 只看 system state 會誤判,`Enable-TcConfig -Force` 由 `verify` 擋下。
- **下一步**:重跑 `Enable-TcConfig -Force`(Activate 會重寫 Boot);仍不一致時先備份 target Boot 目錄,再把 `_Boot\<platform>` 的上述檔案複製過去並比對 SHA-256。模組只讀不寫,不會自動覆寫 target 檔案。

### ACTIVATE_TIMEOUT

- **為什麼**:`ActivateConfiguration()` 在 `-ActivateTimeoutSec`(預設 180 s;`-Force` 時再受 `-TimeoutSec` 剩餘時間限制)內沒返回。以前這個 COM 呼叫在呼叫端執行緒同步執行,`Invoke-TcComRetry` 的 `-TimeoutSec` 只能在呼叫「失敗返回後」歸類成 `IDE_TIMEOUT`,中斷不了:2026-10-21 實測 target Boot 檔被鎖住時掛了 17 分鐘,VS2022 最後被 Windows 判定沒回應關掉,UmRT 也一起消失。現在 Activate 在另一個 STA runspace 執行(依 IDE pid 從 Running Object Table 取同一個 DTE,`Solution.Projects(i).Object` 取 `ITcSysManager`),主執行緒限時等待、每 2 s 掃 modal;逾時就放棄等待(呼叫本身停不掉,XAE 內部可能還在跑)。
- **回傳時間上限(#153)**:`ACTIVATE_TIMEOUT` 最晚在 `-ActivateTimeoutSec` + 診斷預算(`$script:TcActivateDiagBudgetSec`,預設 10 s)+ 不到 1 s 的收尾內回傳。期限內的 modal 掃描只用剩餘時間(prepare + scan 合計 ≤ 剩餘秒數,剩不到 2 s 就不掃);逾時後的診斷(dialog 掃描、`TcSystemServiceUm` 查詢、port 10000 讀狀態)共用那 10 s,用完的步驟不做並寫明 `skipped`(dialog 掃描則 `dialogScanComplete = false` + `modalScan`,`modalScan.reason = no-budget`;port 10000 的 ADS client `Timeout` 設最多 2 s,單位 ms:[InfoSys TcAdsClient.Timeout](https://infosys.beckhoff.com/content/1033/tcadsnetref/7313415307.html))。背景 runspace 只 `BeginStop`、不等待也不 Dispose:Activate 呼叫仍在 XAE 內跑,所以 `ACTIVATE_TIMEOUT` 一律記 lifecycle block,不能當成「沒送出」。實測 2026-11-06(本機,32 個 busy loop 壓 16 核):舊版期限內那次冷啟動 UIA 掃描(Add-Type 編譯)佔 2.1–3.7 s,`-TimeoutSec 3` 的 mock 在 5.9–8.7 s 才回;CI run 42136357332 的 `elapsedSec = 29` 表示多出的 26 s 都在期限迴圈內(推論:耗在那次冷啟動掃描,其 prepare 上限原本 60 s;CI 上沒有逐段計時)。逾時後的收尾(`BeginStop`)實測 < 0.6 s,不是原因。測試:`tests/Unit/activate-timeout.ps1`(預算切分、每次掃描都用滿上限的最壞情況)。
- **Activate 期間看到的對話框(#231)**:成功或失敗,`Enable-TcConfig` 都把 Activate 期間 watchdog(約每 2 s 掃一次)看到的 modal dialog 放在 `data.dialogsSeen`(`title`、`text`、`buttons`、`firstSeen` / `lastSeen`(ISO 8601)、`durationSec`、`scans`;連續掃到同一個(標題 + 內文相同)只記一筆;沒看到是 `[]`;最多 20 筆,超過的不記、只計數在 `data.dialogsDropped`,沒丟是 0),成功時 activate 步驟的 detail 附 `dialogs seen during Activate: N ('<標題>' <秒> s, ...)`(只列前 3 個標題,其餘寫 `+N more`,N 含沒記的)。`durationSec` 是第一次到最後一次掃到的間隔，是下限，最多少算約兩個掃描間隔(~4 s)。模組只記錄，不按按鈕;Activate 很慢時先看這裡是不是有人按掉了對話框(例如 issue #231 的 vmx86.sys real-time start diagnostic,回報者實測(#231,2026-11-11,4026.27 TcXaeShell 64-bit、本機 XAR))。測試:`tests/Unit/activate-dialog-log-231.ps1`(mock)。
- **data.activateDiagnostics**:`dialog`(modal 標題/內文;逾時後那次掃描沒看到或沒掃完時，填期限內看到的那個)、`dialogSeenDuringWait`(`true` = `dialog` 來自期限內的掃描，不是最後一次)、`ideAlive`、`ideResponding`(Windows 的「沒有回應」)、`runtimeAlive`(本機 UmRT 的 `TcSystemServiceUm.exe` 是否還在;`null` 時看 `runtimeCheck`)、`runtimeCheck`(`checked` / `not-local-umrt` / `skipped: diagnostics budget used up` / `error: <訊息>`;沒給 AmsNetId 為 null)、`systemState`(port 10000 的 AdsState、unreachable,或診斷預算用完時 `skipped: ...`)、`elapsedSec`(期限迴圈結束時的秒數)、`diagnosticsSec`(診斷本身花的秒數)。
- **下一步**:依診斷處理:dialog → 處理視窗;`ideResponding = false` → `Disconnect-TcIde -Quit -Kill`(本 session 啟動的)後重新 `Connect-TcIde`;`runtimeAlive = false` → 照 `SYSTEM_STATE_TIMEOUT` 的指令重啟 UmRT 後 `Enable-TcConfig -Force`。

### ADS_SYMBOL_VERSION_INVALID(ADS 0x711 / 1809)

- **為什麼**:[InfoSys ADS Return Codes](https://infosys.beckhoff.com/content/1033/tc3_c/374277003.html):0x711 = `ADSERR_DEVICE_SYMBOLVERSIONINVALID`「Invalid symbol version. This can occur due to an online change. Create a new handle.」;Activate 後出現時通常是 PLC application 與 symbol description 不同版(#32)。
- **重新 download 後(#26,實測 2026-11-08,4026 VS2022 + 本機 UmRT,`AxisInterface` 副本)**:在 `Main` 宣告最前面加 `ARRAY[0..63] OF LREAL` 後 Build + `Enable-TcConfig -Force`,`_AppInfo.AppTimestamp` 03:41:32 → 03:45:44、symbol version(0xF008)50 → 51。download 前建立的 variable handle 讀取回 **0x711**,不是讀到別的變數;同一條 ADS 連線裡對**同一個 symbol 名稱**再 `CreateVariableHandle` 會拿到**同一個 handle 號碼**,所以新 handle 的讀寫也回 0x711;釋放舊 handle(`DeleteVariableHandle` 本身也回 0x711,但之後就正常)或重開連線後恢復,其他 symbol 一直正常(第二次實測 04:21,symbol version 51 → 52)。`Main.PaperLength` 的 indexGroup / indexOffset(0x4040 / 0x694A8)download 前後相同,用舊 offset 直接讀仍是正確值 400。
- **模組怎麼處理**:`Read-TcVariable` / `Write-TcVariable` 每次呼叫都重新查 symbol(`ADSIGRP_SYM_INFOBYNAMEEX`)並用完即刪 handle,不快取 indexGroup / indexOffset;enum 表以 symbol version 為 key 快取，版本變了就重載。遇到 0x711 會用同一個 AmsNetId / port 重開 ADS session 再讀寫一次(`data.symbolsReloaded = true`);再失敗才回這個錯誤碼。重試這條路徑的真機實測(2026-11-08 04:24)是用 branch 模組的長駐 PowerShell 自己留一個舊 handle 觸發的,經 MCP 的一般呼叫不會留 handle,觸發不到。寫入重試假設被 0x711 拒絕的寫入沒有生效(推論,沒有讀回驗證)。
- **`Set-TcSystemState` 停在 Config(#194)**:XAE fatal dialog 或 Error List 出現 `AdsError: 1809 (0x711, ADS ERROR: symbol version invalid)` 時,`SYSTEM_STATE_TIMEOUT` / `SYSTEM_STATE_MISMATCH` 的 hint 改指這一段;`data.diagnostics.bootPackage` 比出不一致時才斷言是 target Boot 裡的 configuration package(CurrentConfig)與 PLC `.app` 不一致(比對一致時說不是這個原因，沒比對時寫「可能是」)。處置:`Build-TcProject` 後 `Enable-TcConfig -Force` 讓 Activate 重寫 Boot(lifecycle block 要先由使用者同意清除),仍不一致見「BOOT_PACKAGE_MISMATCH」。
- **下一步**:`Read-TcVariable` / `Write-TcVariable` 回這個碼時已經重開過 session 重試一次;用 `Get-TcPlcState` 看 PLC 狀態,Activate 後才出現就看 `Enable-TcConfig` 的 `data.bootPackage` / `diagnostics`。其他 cmdlet 或自己的 ADS client:`Connect-TcAds` 重取 handle。重開 session 失敗時回 `NOT_CONNECTED`,訊息寫明是 0x711 後重開失敗。

### CYCLE_TIMEOUT

- **現象**:`Enable-TcConfig -Force` 回 `CYCLE_TIMEOUT`,訊息 `exceeded -TimeoutSec N s before step '<step>'`。
- **為什麼**:`-TimeoutSec`(預設 120 s)是整個 lifecycle 的總預算,每一步開始前檢查剩餘時間;用完就停在那一步之前,不再往下做。
- **下一步**:看 `data.steps` 卡在哪一步;用 `Get-TcSystemState` / `Get-TcPlcState` 確認目前狀態,加大 `-TimeoutSec` 後重跑 `Enable-TcConfig -Force`。

### PLC_RUN_TIMEOUT

- **現象**:`Set-TcPlcState -State Run`(或 `Enable-TcConfig -Force` 的 PLC Run 步)回 `PLC_RUN_TIMEOUT`(Stop / Reset 對應的是 `STATE_SET_FAILED`)。
- **為什麼**:送出 Run 後 PLC 在 `-TimeoutSec` 內沒有進入 Run(PLC 例外、程式沒載入、runtime 狀態不對)。
- **下一步**:`Get-TcPlcState` 看目前狀態;Error / Stop 就檢查 PLC 例外或 Build 錯誤,再 `Enter-TcPlcOnline` 後重試;851 是 Invalid 見 `PLC_NOT_LOADED`。
- **回報的狀態**(#131,與 `Set-TcSystemState` 的 #114 同規則;Run / Stop 都適用，含 `STATE_SET_FAILED`):等待中最後一次讀 PLC port 失敗(ADS 錯誤，例如 runtime crash 讓 port 消失)時,`data.currentState` / `finalState` 是 `Unreachable`,不是之前最後讀到的狀態;那個在 `data.lastState`(等待中一次都沒讀到就是送出前的狀態),錯誤在 `data.lastError`(最後一次讀取成功時是 `null`)。`data.originalState` 是送出前讀到的狀態(讀不到是 `null`);`data.leftOriginal` 只在某次讀取**真的讀到**和 `originalState` 不同的狀態時才是 `true`(讀取失敗不算狀態;`originalState` 是 `null` 時為 `null`);等待中有任何讀取失敗記在 `data.unreachableSeen`(`currentState` 是 `Unreachable` 時一定是 `true`,包括等待根本沒能讀，例如找不到 TwinCAT.Ads.dll);PLC 已經在 Run 時 `-State Run` 不送出(`alreadyInState`),這些欄位照樣都有。失敗時另附 `probeErrors` / `probeErrorsDropped`(格式同 `SYSTEM_STATE_TIMEOUT`),lifecycle block 的 `reachedState` 是空的(`readbackNote = unreachable`,`step` 寫 unreachable 與之前最後讀到的狀態),`LIFECYCLE_BLOCKED` 訊息寫「read back afterwards: nothing (PLC port unreachable)」。`Set-TcPlcState` 的等待**沒有** `RUNTIME_CRASHED` 偵測(只有 `Set-TcSystemState` 有);crash 路徑在真機上無法故意觸發，只有 unit test(`tests/Unit/plc-state-unreachable-131.ps1`)。

### PLC_PROJECT_NOT_FOUND

- **現象**:`Enter-TcPlcOnline` / `Exit-TcPlcOnline` / `Get-TcPouCode` / `Write-TcPouCode` / `Enable-TcConfig` 回 `PLC_PROJECT_NOT_FOUND`。
- **為什麼**:`TIPC` 下找不到 `<Plc> Project` 節點(solution 沒有 PLC 專案、`-PlcProjectPath` 名稱打錯,或剛 Activate / 重啟後樹還沒就緒)。
- **下一步**:`Get-TcProjectTree -PlcOnly` 確認 PLC 名稱(`data.plcProjects` 列出候選),`-PlcProjectPath` 給 PLC 名稱(`FrameworkUnitTest`)或樹路徑(`TIPC^FrameworkUnitTest^FrameworkUnitTest Project`);剛重啟可重試一次。

### PLC_PROJECT_AMBIGUOUS

- **為什麼**:`Enter-TcPlcOnline` / `Exit-TcPlcOnline` 沒給 `-PlcProjectPath`,solution 卻有多個 PLC project。以前直接拿 `TIPC` 的第一個 child,多 PLC 時登入/登出錯的 PLC(#32)。
- **下一步**:`-PlcProjectPath FrameworkUnitTest`(PLC 名稱)、`TIPC^FrameworkUnitTest` 或 `TIPC^FrameworkUnitTest^FrameworkUnitTest Project` 都可以;`data.plcProjects` 列出 name / projectPath / adsPort。ADS port 取自 PLC 節點 `ProduceXml` 的 `<AdsPort>`(InfoSys 未記載,實測 851 / 852)。

### PLC_PORT_MISMATCH

- **為什麼(#27)**:`Start-TcLifecycle`(MCP `RunLifecycle`)同時給了 `-PlcProjectPath` 與 `-AdsPort`,而 `-AdsPort` 不是 `Enable-TcConfig` 回的 `data.plcs` 裡任何一個 PLC 的 `adsPort`(同一個 PLC 寫兩次只算一個 port;例如 `-PlcProjectPath FrameworkUnitTest -AdsPort 851`,但 FrameworkUnitTest 在 852)。ConnectAds 步驟直接失敗,ADS **沒有連線**,message 列出允許的 port。前面的 Enable-TcConfig 已成功：已 activate;沒有 `-NoLogin` 時也已 login / Run。不記 lifecycle block。沒給 `-AdsPort` 時不會有這個碼:`data.plcs` 只有一個 port 就用它，否則 851。
- **data**:ConnectAds 步驟的 `result.data`:`adsPort`(給的)、`allowedPorts`、`plcs`(name / projectPath / adsPort);整體 `data.plcProjects` 是 `Enable-TcConfig` 的 `data.plcs`。
- **下一步**:不用重跑整個 lifecycle:`Connect-TcAds -Port <allowedPorts 其中一個>`(MCP `ConnectAds Port=<port>`)再 `Get-TcPlcState`(MCP `GetPlcState`)讀回;下次拿掉 `-AdsPort` 或改成允許的 port。

### PROJECT_SKIPPED_BY_CONFIGURATION

- **為什麼**:solution Build 只編 active solution configuration 裡勾了 Build 的 project(.sln 的 `{guid}.<Config>|<Platform>.Build.0`)。PLC project 少了這行時 XAE 默默跳過、仍顯示 Build succeeded,Port 852 的產物還是舊的(#28)。`Build-TcProject` 在 Build 前讀 DTE `Solution.SolutionBuild.ActiveConfiguration.SolutionContexts`,每個 `.plcproj` 看 `ShouldBuild`([Microsoft Learn: SolutionContext.ShouldBuild](https://learn.microsoft.com/en-us/previous-versions/visualstudio/visual-studio-2013/1a52ztxh(v=vs.120))「whether the current project is built when the solution configuration associated with this SolutionContext is selected」),不解析 .sln 文字。
- **回傳**:`data.projects[]`(name、uniqueName、configuration、platform、shouldBuild、status = `built` / `skipped` / `failed` / `unknown` / `disabled`、disabled)、`data.skippedProjects[]`、`data.disabledProjects[]`、`data.coverageComplete`(除了 `disabled` 以外的 PLC project 都是 built,而且至少有一個，才是 true)。沒帶 `-ExpectedProject`:success 照 build 結果,另外 `data.warningCode = PROJECT_SKIPPED_BY_CONFIGURATION` + `data.warning`(也會 Write-Warning)。帶 `-ExpectedProject FrameworkUnitTest` 且它被跳過:不開始 Build,直接 `success = false`、這個 code。
- **有 project 被跳過時 `codeVerified` 不是 true(#58)**:被跳過的 PLC 程式碼沒有被編譯,Error List 乾淨也證明不了它,所以 `data.codeVerified = false`,`data.warningCodes` 是 `["PROJECT_SKIPPED_BY_CONFIGURATION", "CODE_NOT_VERIFIED"]`(全部被跳過 = 這次沒有編譯任何 PLC 程式碼,`data.warning` 的 CODE_NOT_VERIFIED 文字會寫 all skipped)。solution 裡沒有 PLC project 也是 `codeVerified = false`;PLC project 清單讀不到(`data.coverageError`)是 `codeVerified = null`。
- **Disabled 的 PLC project 不算被跳過(#104)**:TwinCAT 專案裡被 Disable 的 PLC(.tsproj `<Project Disabled="true" ...>`,Automation Interface 的 `ITcSmTreeItem.Disabled`,[InfoSys: How to disable/enable a tree item](https://infosys.beckhoff.com/content/1033/tcautomationinterface/12425861515.html))不會被 Activate,`Enable-TcConfig` 本來就跳過它(`Get-TcPlcProjectList` 的 `disabled`)。`Build-TcProject` 用同一份清單:configuration 沒 build 它(`ShouldBuild = false`)又是 disabled → `status = 'disabled'`、`disabled = true`,列在 `data.disabledProjects[]`,**不**列在 `skippedProjects`、不觸發 `PROJECT_SKIPPED_BY_CONFIGURATION`、不讓 `coverageComplete` / `codeVerified` / `completeBuild` 變 false。**enabled 但被跳過的 project 行為不變**(仍是這個 warning,`completeBuild = false`,#28)。disabled 但 configuration 有 build 它的 → 照一般 project 算(`built` / `failed` / `unknown`),只多 `disabled = true`。對應方式(`data.disabledMatchBy` = `path` / `name` / `null`):**先比 .plcproj 路徑**:PLC 節點(TIPC 子節點)`ProduceXml` 裡的 `PlcProjectDef/ProjectPath` 是 `.plcproj` 絕對路徑(**實測 2026-11-03,4026 VS2022 + 本機 UmRT,registered tcauto**;`Get-TcPlcProjectList` 的 `projectFile`),跟 coverage entry 的 `uniqueName` 接上 solution 目錄比，兩邊都先經 `Get-TcLongPath`(`GetFullPath` + 8.3 短名轉長名)、不分大小寫。每個 PLC 節點都有 ProjectPath、每個節點剛好對到一個 entry、沒有 entry 被兩個節點對到時才用路徑；否則退回**名稱**對應:`data.projects[].name`(.plcproj 檔名不含副檔名)跟 TIPC 下的 PLC 節點名稱比(不分大小寫);對不到的 project 當作 enabled(照舊擋)。名稱對調(enabled 節點 `Main` 用 `Legacy.plcproj`、disabled 節點 `Legacy` 用 `Main.plcproj`)只有路徑對應分得出來。名稱不是可靠的鍵(兩個資料夾都有 `PLC.plcproj`;enabled 節點 `Main` 的檔案叫 `Legacy.plcproj`、旁邊又有 disabled 節點 `Legacy`),所以對應必須一對一，否則 fail closed:有 disabled 節點對到超過 1 個 entry、有 enabled 節點一個 entry 都對不到、或有 entry 對到超過 1 個節點 → 整批當 enabled(行為同修改前),`data.disabledCheckError` 寫原因(沒有任何 disabled 節點時不做這個檢查)。PLC 清單讀不到時也全部當 enabled(照舊行為),`data.disabledCheckError` 放錯誤訊息。全部 PLC 都是 disabled 且沒 build → 這次沒編任何 PLC 程式碼:`coverageComplete = false`、`codeVerified = false`(`CODE_NOT_VERIFIED`)、`completeBuild = false`,比照「solution 裡沒有 PLC project」:**不記** BUILD_REQUIRED(沒有 PLC 程式碼會被 Activate),但也不會清掉既有的紀錄(要清見本文件 BUILD_REQUIRED「手動解除」)。`-ExpectedProject` 指到 disabled project → `EXPECTED_PROJECT_DISABLED`。**未實測，待真機驗證**:.tsproj `<Project Disabled="true">` 在 PLC 節點上讀回來是 `ITcSmTreeItem.Disabled ≠ 0`(InfoSys 只寫 tree item 的 Disabled 屬性，沒有針對 PLC 節點的實測)。
- **`data.solutionConfiguration` 是 solution platform(#58)**:`'<Configuration>|<solution platform>'`,讀法同 `Get-TcIdeInfo`(`Solution.Properties('ActiveConfig')`),`data.solutionPlatform` 等於 `Get-TcIdeInfo` 的 `solutionPlatform`,`data.projectPlatform` 是其下 .tsproj 的 project platform;每個 PLC project 的 project platform 在 `data.projects[].platform`。`data.platformSource` 寫 solution platform 的讀法(`ActiveConfig` / `PlatformName` / `context`);是 `context`(只讀得到 SolutionContext 的 platform,那是 project platform)時,`solutionConfiguration` 只放 configuration 名稱。以前這欄用 PLC context 的 platform 拼,會顯示 project platform(實測 2026-10-26,VisualStudio.DTE.17.0,TwinCAT_Festo 4026 複本:solution `Release|TwinCAT OS (x64)` 被顯示成 `Release|TwinCAT OS (ARMT2)`)。
- **solution Build、單一 project Build、compiler coverage 的差別**:solution Build(`Build-TcProject`)= 只編 `ShouldBuild = true` 的 project;單一 project Build(XAE 右鍵 Build / `SolutionBuild.BuildProject`)不受 Build.0 影響;compiler coverage = 這次 Build 實際編到哪些 PLC,看 `data.projects[].status`。
- **下一步**:XAE Configuration Manager 把該 PLC project 的 Build 勾起來並存檔(會補回 Build.0),再 `Build-TcProject -ExpectedProject <name>`。那個 project 是刻意 Disable 的(不需要 Activate)時，不用處理:#104 起它是 `disabled`,不會出現在這個 warning。

### EXPECTED_PROJECT_DISABLED

- **為什麼**:`-ExpectedProject` 指定的 PLC project 在 TwinCAT 專案裡是 disabled(`ITcSmTreeItem.Disabled`,.tsproj `Disabled="true"`,見上一節 #104)。disabled 的 PLC 不會被 Activate / Login,把它當成「一定要編到」的 project 是設定錯誤，所以不管 configuration 有沒有 build 它，都不開始 Build,直接 `success = false`、這個 code(#104;以前它被當成 `skipped` → `PROJECT_SKIPPED_BY_CONFIGURATION`)。
- **回傳**:同 `PROJECT_SKIPPED_BY_CONFIGURATION` 的 Build 前資料(`data.projects[]`、`data.skippedProjects`、`data.disabledProjects`、`data.expectedProjects`)。PLC 清單讀不到時(`data.disabledCheckError`)判斷不出 disabled,不會回這個 code。
- **下一步**:從 `-ExpectedProject` 拿掉它；真的要用這個 PLC,先在 XAE 的 PLC 節點取消 Disable 並存檔，再 Build。

### EXPECTED_PROJECT_NOT_FOUND / BUILD_COVERAGE_UNKNOWN

- **EXPECTED_PROJECT_NOT_FOUND**:`-ExpectedProject` 的名稱不是這個 solution 的 PLC project(比對 .plcproj 檔名,不含副檔名;也收 `TIPC^<Plc>`),沒有開始 Build。用 `data.projects` 的 name。
- **BUILD_COVERAGE_UNKNOWN**:帶了 `-ExpectedProject` 但無法確認它有被編到:SolutionContexts 讀不到(`data.coverageError`),或 Build 結果不是成功、Error List 又沒有那個 project 的列(status `unknown`)。不要當成 Build 成功。另外，不論有沒有 `-ExpectedProject`,只要某個 PLC project 的 ShouldBuild 讀不到(不是真正的 bool,status `unreadable`,#67)就不開始 Build,`data.unreadableProjects` 列出名稱:它既不能算 built 也不能算 skipped。

### BUILD_FAILED / BUILD_FAILED_COMPILE

- **碼與 hint**:錯誤碼是 `BUILD_FAILED`;`BUILD_FAILED_COMPILE` 是讀到 Error List 錯誤列時用的 hint key(看 `data.errorItems`)。
- **為什麼**:成功與否依序判定:(a) `SolutionBuild.LastBuildInfo`(= build 失敗的專案數,回在 `data.failedProjects`)讀得到就用它(> 0 = 失敗);(b) 讀不到(`failedProjects = null`)就看 Error List:有任何**非 Library Manager** 的 Error(file 不像 `*Library Manager`、line > 0)就算失敗;(c) 兩者都讀不到 → `BUILD_STATUS_UNKNOWN`(見下)。TwinCAT 的 PLC 編譯訊息**不走** DTE(`ErrorList.ErrorItems.Count` 永遠 0、`OutputWindow.OutputWindowPanes` 空),所以模組用 UI Automation 讀 XAE 的 Error List 視窗(`Get-TcBuildErrors`),`data.errorItems[]` 是 Error List 全部錯誤(執行期 / 系統 log 列除外，它們在 `data.runtimeMessages[]`,見下一節「執行期 / 系統 log 列不是 build error」),每筆 `{ severity, code, description, project, file, line, column, category }`;`category`(#23)是 `library`(file 像 `*Library Manager` 且無 line,或無 line 的「Could not open library」訊息)、`code`(有 file)、`other`(沒有 file,例如 build 摘要列)。`data.errors` **只算 code error**(= `data.codeErrors[]` 筆數),library 項另計在 `data.libraryErrors` / `data.libraryErrorItems[]`(有 library 錯誤時見 `LIBRARY_UNRESOLVED`);`data.buildSucceeded` 是判定結果,`data.decidedBy` 說明由誰判定(`LastBuildInfo` / `ErrorList`),`error.message` 含 code error 數(括號補 library 數)與前 3 筆非 library 錯誤摘要。
- **下一步**:看 `data.codeErrors`(file + line 直接指到 POU),改 code 後 `Build-TcProject`。不要在沒改東西的情況下重跑 Build。`data.errorListError` 出現時表示 Error List 讀不到(見 `ERRORLIST_UNAVAILABLE`),`errors` 退回 `failedProjects`、`libraryErrors` 為 null。

### BUILD_FAILED_PLC_ONLINE

- **現象(實測 2026-11-06,VS2022 4026 + 本機 UmRT,RobustSolutionFrameworkDemo 含 TcUnit;InfoSys 未查到出處)**:PLC logged in 時 `Build-TcProject` 根本沒編譯(0.8 s、`failedProjects` 2、`projects[].status = unknown`),Error List 沒有真的編譯錯誤(MAIN 的未宣告變數 C0046 不在),只有 runtime / system log 列與 `'TwinCAT XAE': Project '...' build for platform '...' failed.` 這筆 warning。`PlcLogout` 後再 Build 才列出 C0046 / C0018。
- **沒有 runtime log 列的版本(#188,實測 2026-11-08,4026 VS2022 + 本機 UmRT,AxisInterface)**:`EnableConfig -Force`(PLC 登入)→ `WritePouCode` 改宣告 → `BuildProject` 回 `BUILD_FAILED`「0 code error(s) (2 project(s) failed; no code error listed in the Error List)」,`errorItems` 與 `runtimeMessages` 都是空的,Error List 只有一筆 `<時間戳> | 'TwinCAT XAE': Project 'AxisInterface' build for platform 'TwinCAT OS (x64)' failed.` warning。#188 之前這種結果是 `plcOnlineSuspected = false`、`codeVerified = true`(錯的)。`PlcLogout` 後同一份程式 Build 成功。
- **模組怎麼回**:錯誤碼仍是 `BUILD_FAILED`(BUILD_REQUIRED 也照記)。前提:Error List 讀得到、**完全沒有錯誤列**(沒有 code、library,也沒有任何其他錯誤列:有 code 沒 file 的 `C0077`、沒有 code 的 XAE 錯誤如「Error writing file ...」都算,review #150 round 3)。這時:
  - `data.codeVerified` 一律不是 `true`(原本 `true` 的改成 `null`;因為被 configuration 跳過等原因已是 `false` 的保持 `false`):沒有錯誤列的失敗 build 證明不了程式碼。
  - 對每個有 build 的 PLC project(不是 `skipped` / `disabled`)讀 login 狀態,結果在 `data.plcLoginState[]`:`{ plc, loggedIn (true / false / null = 讀不到), source ('IsLoggedIn' / 'ProduceXml' / null), error }`。只在這條路徑讀，成功的 build 不多做 COM 呼叫(`plcLoginState = null`)。讀法:
    1. PLC 節點 `TIPC^<Plc>` 的 `ITcPlcOnline.IsLoggedIn`(VARIANT_BOOL,唯讀，「Returns VARIANT_FALSE if not connected」;TE1000 TC3 Automation Interface v1.7.0 §5.21.1 ITcPlcOnline,p.108,https://download.beckhoff.com/download/document/automation/twincat3/TC3_Automation_Interface_EN.pdf)。4026 的 online 方法(Login / Logoff)掛在這個節點(`Exit-TcPlcOnline`,實測 2026-10-18)。只接受真正的 bool:不存在的 COM property 在 PowerShell 讀回 `null` 不丟例外，所以 `null` 也改走第 2 種。**實測 2026-11-08,4026 VS2022(VisualStudio.DTE.17.0,本機 UmRT,PLC 登入中)**:`TIPC^<Plc>` 的 `IsLoggedIn` 讀回 `null`,實際由第 2 種 ProduceXml `IECProjectDef/OnlineSettings/LoggedIn` 判定(`source = 'ProduceXml'`,`error` 寫「IsLoggedIn: not readable ... (read back null)」)。
    2. `TIPC^<Plc>^<Plc> Project` 的 `ProduceXml()` 裡 `TreeItem/IECProjectDef/OnlineSettings/LoggedIn`(`true` / `false`)。TE1000 §6.5.13(p.240)記載 PLC project 的 OnlineSettings / Commands 經 ProduceXml / ConsumeXml 存取;`LoggedIn` 這個元素是**實測 2026-11-08,4026 VS2022**(登入時 `<LoggedIn>true</LoggedIn>`,旁邊有 `<PlcAppState>Run</PlcAppState>`)。4024 TcXaeShell 的 ProduceXml 也有 `OnlineSettings/LoggedIn`(未登入讀到 `false`,實測 2026-11-08,BFH-1650 副本);4024 登入中未實測。
    3. 兩者都讀不到 → `loggedIn = null`(不猜),`error` 寫原因。`IDE_MODAL_DIALOG` / `IDE_TIMEOUT` / `IDE_BUSY` / `IDE_CRASHED` 不吞，整個 Build 回那個錯誤碼。
  - 任何一個 `loggedIn = true` → `data.plcOnlineSuspected = true`、`data.plcOnlineEvidence = 'login-state'`、`codeVerified = null`,message 後面接「XAE listed no compiler error row at all and PLC project(s) ... are logged in (data.plcLoginState) ...」。
  - 否則，每個有 build 的 PLC project 都是 `unknown` 且 `data.runtimeMessages` 不是空的(#66 原規則)→ `plcOnlineSuspected = true`、`plcOnlineEvidence = 'runtime-log'`、`codeVerified = null`,message 後面接「XAE listed no compiler error row at all: the PLC is probably logged in, so XAE probably did not compile ...」。
  - 讀到 `loggedIn = false` **不會**排除 runtime-log 證據，只寫進 message(`plc=false`):登入中讀到 false 從沒實測過(4026 VS2022 的 `IsLoggedIn` 從未讀到 bool;4024 登入中未測),不夠 fail closed(#188 review)。
  - 兩者都不成立:`plcOnlineSuspected = false`、`plcOnlineEvidence = null`,message 後面寫各 PLC 的 login 狀態(`<plc>=true|false|unknown`)。
  - `plcOnlineSuspected = true` 時 hint 是這個 key:先用 MCP `PlcLogout`(cmdlet `Exit-TcPlcOnline`)登出，再重跑 `BuildProject`(`Build-TcProject`)。`plcOnlineSuspected`、`plcOnlineEvidence`、`plcLoginState` 三個 key 在 Build 結果一律存在。
- **實測(#188 修正後,2026-11-08 04:43,4026 VS2022 + 本機 UmRT,registered tcauto)**:登入中改宣告 → `BUILD_FAILED`、`plcOnlineSuspected = true`、`plcOnlineEvidence = 'login-state'`、`codeVerified = null`、`plcLoginState = [{ plc: AxisInterface, loggedIn: true, source: ProduceXml }]`;`PlcLogout` 後 Build 成功、`completeBuild = true`、`plcLoginState = null`。
- **限制**:`runtime-log` 只是推測:Logout 後舊的 log 列會留在 Error List(#66 實測),所以 message 和 hint 對它寫「probably / suspected」;`login-state` 是讀回的狀態。只要 Error List 有任何一筆錯誤列(真的編譯錯誤、沒有 file 的 code 列、XAE 自己的錯誤),就不讀 login 狀態、也不是這個情況：那一列可能才是原因，叫人 Logout 只會繞圈。`IsLoggedIn` 在 4024 是否可讀未實測;4024 登入中 `LoggedIn` 是否讀到 `true` 未實測(讀不到就是 `null`)。
- **下一步**:`Exit-TcPlcOnline`(MCP `PlcLogout`),在 XAE 清掉 Error List 的舊 log 列，再 `Build-TcProject`(MCP `BuildProject`)。

### 執行期 / 系統 log 列不是 build error(data.runtimeMessages,#66)

- **現象**:PLC 已 login、程式在跑(例如 TcUnit 測試)時 Build,Error List 的 Error 列混著執行期 / 系統 log,例如 `'PlcTask' (350): | Successful tests: 6`、`'TCOM Server' (10): ...`、`'TwinCAT System' (10000): ...`。#66 之前這些列進了 `data.errorItems`(category `other`),`BUILD_FAILED` 的 message 摘要列的是 log,看起來像編譯錯誤。
- **出處**:PLC 程式用 `ADSLOGSTR` 等函式寫出的訊息會顯示在 TwinCAT XAE 的 Error List(InfoSys TF6500「Debug messages in TwinCAT->Error List」,https://infosys.beckhoff.com/content/1033/tf6500_tc3_iec60870_5_10x/984578315.html)。`ADSLOGSTR` 有 `ADSLOG_MSGTYPE_ERROR` / `_WARN`(訊息類型 error / warning,InfoSys Tc2_System ADSLOGSTR,https://infosys.beckhoff.com/content/1033/tcplclib_tc2_system/31033611.html);它對應到 Error List 的 Error / Warning 嚴重度是**推論**(該頁沒寫),與 #66 實測 TcUnit 列被讀成 Error 一致。編譯訊息的 File / Line 欄是「含有問題的檔案 / 行號」(Microsoft Learn Error List 欄位說明,https://learn.microsoft.com/en-us/visualstudio/ide/error-list-window)。
- **實測**:log 列的文字格式 `'<source>' (<數字>): <訊息>`、沒有 file / line(#66,2026-10-27,VS2022 4026、本機 UmRT、RobustSolutionFrameworkDemo 含 TcUnit)。**括號內容的語意未確認**:不一定是 ADS port(實測反例:`'TwinCAT Measurement' (22:30:40.881): Error creating Archive`,括號裡是時間，不符合規則，照舊分類)。其他語系、其他 XAE 版本未實測。Error List 的 Source 欄(Build / IntelliSense)模組沒有讀，不拿來判斷。
- **規則**(`Get-TcRuntimeLogKind`;只有 `Build-TcProject` 與 `Test-TcPlcProject` 拆分，它們呼叫 `Get-TcErrorListSummary -SplitRuntimeLog`):
  - **時間戳前綴(實測 2026-11-06,VS2022 4026 + 本機 UmRT,PR #150 head c35694b)**:真機讀到的列是 `11/6/2026 9:11:28 AM 520 ms | 'PlcTask' (350): | Successful tests: 6`,前面多了 `<時間戳> | `。**實測**:UI 語言 zh-TW、regional format en-US 時，時間戳是 en-US 格式。時間戳跟著 regional format(不是 UI 語言)走是**推論**,zh-TW regional format 的樣子(例如 `2026/11/6 上午 09:11:28 520 毫秒 | `)也是推論、未實測，所以不解析它：可選前綴是「行首到第一個 ` | ` 為止、含數字、不含 `'` 與 `|` 的字元」,而且有長度上限(第一個數字前最多 40 個非數字字元、之後最多 60 個，避免回溯)。取捨：真的編譯訊息要被誤判，必須文字剛好以「含數字的一段 + ` | ` + `'<名稱>' (<數字>):`」開頭(而且 `'<名稱>'` 是整行第一個引號),並且沒有 file、line、compiler code、library 訊息——任何一項存在就是 `ambiguous`,照舊算 error。c35694b 之前的 fixture 全是無前綴格式，所以單元測試沒抓到真機的失敗。
  - `runtime`:description 以 `'<名稱>' (<數字>):` 開頭(前面可有上述時間戳前綴),**而且**沒有 file、沒有 line(> 0)、沒有 compiler code、不是 library 訊息(「Could not open library」/「has not been installed」)→ 移到 `data.runtimeMessages[]`(同樣的欄位,`category = 'runtime'`,保留 `severity`)。不在 `errorItems` / `warningItems` / `codeErrors` / `codeWarnings`,不計入 `data.errors`。
  - 分不清楚(`ambiguous`):有這個開頭，但同時有 file、line、compiler code 或 library 訊息 → **照舊**留在 `errorItems` / `warningItems`(fail closed,照原本的 category 算 error),該列多一個 `note`,`data.runtimeMessageNote` 說有幾列。
  - 其他列(沒有這個開頭):分類不變(`code` / `library` / `other`)。真機上會看到兩種(實測 2026-11-06,報告附錄):`'TwinCAT Analytics Workbench' (11/6/2026 9:08:16 AM): ...`(Message,沒有時間戳前綴，括號內是日期,`line` 是 0)不符合規則;`<時間戳> | 'TwinCAT XAE': Project '...' build for platform '...' failed.`(Warning,沒有 `(<數字>)`)**刻意不分類成 runtime**:它是 XAE 自己的 build 摘要，不是執行期 log,照舊留在 `warningItems`(沒有 file,所以不在 `codeWarnings`),也是上面 `BUILD_FAILED_PLC_ONLINE` 情境裡唯一的 build 列。
  - `Save-TcArchive`、`New-TcBootProject` **不拆分**:Save-TcArchive 比對呼叫前後的錯誤列，新出現的任何列都要看得到(review #150 F1)。`GetBuildErrors` 也照原樣列出，它的 `errors` / `warnings` 會含這類列。
- **成功判定**:照舊由 `LastBuildInfo` 決定。`LastBuildInfo` 讀不到、改由 Error List 判定(`data.decidedBy = ErrorList`)而 `data.runtimeMessages` 不是空的時,`codeVerified = null`,成功的 build 加 `CODE_NOT_VERIFIED`(why:「runtime log rows present (PLC online, or rows left from an earlier online session) (#66)」),`completeBuild = false`、BUILD_REQUIRED 不清除：#66 實測過 PLC online 時 build 失敗、編譯錯誤卻不在 Error List,這時 Error List 不能當證據(review #150 F3)。#66 也實測過 Logout 後舊的 TcUnit 列仍留在 Error List,所以這些列不一定代表 PLC 現在 online。下一步：先 `Exit-TcPlcOnline`,在 XAE 清掉 Error List 的舊 log 列，再 `Build-TcProject`。
- **`data.warnings`** 仍是 Error List 按鈕上的總數(含 warning 等級的 log 列),`data.warningItems` 才是去掉 log 列後的內容。
- **BUILD_FAILED 但 `codeErrors` 是空的、只有 `runtimeMessages`**:這就是 #66 的實測情境:PLC login 中 XAE 不編譯(實測 2026-11-06,Logout 後再 Build 才列出 C0046 / C0018)。PLC project 都是 `unknown` 時回 `data.plcOnlineSuspected = true`(`plcOnlineEvidence = 'runtime-log'`,讀到 login 狀態為登入時是 `'login-state'`)與 hint `BUILD_FAILED_PLC_ONLINE`(見上一節);其他情況 message 寫「no code error listed in the Error List」並說明有幾列 log 被排除。不要把 log 當成失敗原因。
- **需真機確認**:含 TcUnit 的專案在 login 狀態下 Build,`data.runtimeMessages` 有 log 列、`data.errorItems` 沒有。

### LIBRARY_UNRESOLVED

- **`data.errors` 語意變更(#23,breaking)**:`errors` 不再含 Library Manager 列,只算 code error;library 列在 `libraryErrors` / `libraryErrorItems[]`。分類只認英文 UI 的 file `*Library Manager`(無 line)與訊息「Could not open library」/「has not been installed」(2026-10-18 英文 XAE 實測);**zh-TW 等其他語系的 Library Manager file 名稱與訊息未實測**:那些列會被分成 `code`,但沒有行號,所以 `codeVerified = false` 並回 `CODE_NOT_VERIFIED`(見下),不會被當成驗證過的成功。

- **為什麼**:Error List 有 library 錯誤(`data.libraryErrorItems[]`:Library Manager 的「Could not open library」placeholder 無法解析、「has not been installed」),而 build 本來會判成功。這時 PLC 程式碼可能根本沒被編譯:**實測 2026-10-25**(TcXaeShell 4024,TwinCAT_Festo 複本,缺 7 個 library,#45)在 POU 裡寫未宣告的識別字,Build 仍是 `LastBuildInfo = 0`、Error List 沒有 C0046;同樣的改法在沒有缺 lib 的專案上是 `BUILD_FAILED` + C0046。所以 `Build-TcProject` 不再把它當成功:`success = false`、`data.buildSucceeded = null`、`data.codeVerified = false`、`data.projects[].status = unknown`。`data.codeVerified = true` 表示 Error List 讀得到且沒有 library 錯誤。
- **下一步**:在 XAE 的 Library Manager 安裝缺的 library(名稱 / 版本在 `data.libraryErrorItems[].description`),再 `Build-TcProject`。使用者確定要接受「程式碼可能沒編譯」時才用 `Build-TcProject -AllowUnresolvedLibrary`(MCP:`BuildProject` `AllowUnresolvedLibrary: true`):回 success,`data.warningCodes[]` 含 `LIBRARY_UNRESOLVED`(`data.warningCode` 是第一個,`PROJECT_SKIPPED_BY_CONFIGURATION` 排前面)+ `data.libraryWarning`;這時 `data.projects[].status` 仍是 `built`(build 的結果),程式碼沒被證實有編譯由 `codeVerified = false` 表示。有 code error 時照常是 `BUILD_FAILED`。**#61 起這種 build 永遠不算完整**(`data.completeBuild = false`):`Build-TcProject` 記下 / 保留 BUILD_REQUIRED(unverified-build),`Enable-TcConfig` / `Enter-TcPlcOnline` 照樣拒絕 Activate / Login / Download / Run——module 記錄到 codeVerified 不是 true 的 build 之後，不會 Activate / Download / Run(範圍:只擋經 module build 或改動過的 solution；從未經 module build 的 solution 不擋，見本文件 BUILD_REQUIRED)。所以 `-AllowUnresolvedLibrary` 只適合「只想看 build 結果 / Error List」;要 Activate 就得先把 library 裝好。`Enable-TcConfig`、`Invoke-TcTestCycle`、MCP `RunLifecycle` / `RunTestCycle` 已經**沒有** `-AllowUnresolvedLibrary`(#61 移除;留著會讓人以為能放行)。

### CODE_NOT_VERIFIED

- **為什麼**:`Build-TcProject` 判定成功,但沒辦法證明 PLC 程式碼有被編譯:Error List 讀不到(`data.errorListError`,例如 `ERRORLIST_UNAVAILABLE`;`codeVerified = null`、`libraryErrors = null`,`errors` 退回 `failedProjects`),或 Error List 有「有 file、沒有行號」的 code 列(`codeVerified = false`;可能是分類規則不認得的語系的 Library Manager 列),或有 PLC project 被 active solution configuration 跳過(`codeVerified = false`,排在 `PROJECT_SKIPPED_BY_CONFIGURATION` 之後,#58;見上一節),或 `LastBuildInfo` 讀不到、改由 Error List 判定(`data.decidedBy = ErrorList`)時有 runtime / system log rows present(`data.runtimeMessages` 不是空的,`codeVerified = null`,#66;見「執行期 / 系統 log 列不是 build error」)。這是 warning,不是錯誤:`success = true`,`data.warningCodes[]` 含 `CODE_NOT_VERIFIED`,`data.warning` 說明原因。
- **`data.warningCodes` 的順序與並存(#56)**:依序 `PROJECT_SKIPPED_BY_CONFIGURATION`、`LIBRARY_UNRESOLVED`(只在加了 `-AllowUnresolvedLibrary` 時)、`CODE_NOT_VERIFIED`;`data.warningCode` / `data.warning` 是第一個，每個碼都會 Write-Warning。同一次 build 同時有 library 錯誤和「沒有行號的 code 列」時，兩個都放進去:`["LIBRARY_UNRESOLVED", "CODE_NOT_VERIFIED"]`(兩個是獨立的缺口:library 錯誤讓程式碼可能沒編譯，沒行號的 code 列是分類規則不認得的列),而且 `completeBuild = false`(加了 `-AllowUnresolvedLibrary` 的 build 本來就永遠不完整,#61)。只有 library 錯誤、沒有沒行號的列時只有 `LIBRARY_UNRESOLVED`(它已經說明程式碼沒被證實);有 project 被跳過又有 library 錯誤時是 `["PROJECT_SKIPPED_BY_CONFIGURATION", "LIBRARY_UNRESOLVED"]`。沒加 `-AllowUnresolvedLibrary` 時有 library 錯誤就是 `LIBRARY_UNRESOLVED` 錯誤，不會有 warningCodes 的 CODE_NOT_VERIFIED。
- **solution 裡沒有 `.plcproj`(只有 I/O 或 NC 設定)時，出現這個碼是預期結果**:沒有 PLC 程式碼可以驗證,`codeVerified = false`,不代表 build 有問題。
- **下一步**:看 XAE 的 Error List;Error List 讀不到時照 `ERRORLIST_UNAVAILABLE` 處理、讀不完整時照 `ERRORLIST_INCOMPLETE` 處理後重跑 `Build-TcProject`;project 被跳過時照 `PROJECT_SKIPPED_BY_CONFIGURATION` 處理;有 runtime / system log 列時先 `Exit-TcPlcOnline`,在 XAE 清掉 Error List 的舊 log 列，再 `Build-TcProject`(#66 實測過 Logout 後舊 TcUnit 列仍留在 Error List,所以只 Logout 不夠)。在確認之前不要把它當成「程式沒問題」。

### BUILD_REQUIRED

- **為什麼(三種記錄，同一個狀態檔、同一個解除條件)**:
  - **platform-switch**:solution platform 切換過(`Set-TcTarget -Platform`、`Enable-TcConfig` 的自動 platform-fix,或一次失敗且還原不回去的切換),之後還沒有一次**完整成功**的 `Build-TcProject`,編譯產物可能還是舊平台的(推論,未實測)。典型情境:platform-fix 後的 platform-fix-build 停在 `LIBRARY_UNRESOLVED`,平台已切換,再跑一次 `Enable-TcConfig` 會發現平台一致、不再 build,若不擋就會 Activate 舊平台的產物。
  - **unverified-build(#56)**:這個 solution 最後一次 `Build-TcProject` 跑完了但不是完整成功:`LIBRARY_UNRESOLVED`(加不加 `-AllowUnresolvedLibrary` 都算,#61)、`BUILD_FAILED`、`BUILD_STATUS_UNKNOWN`、build 之後的 `BUILD_COVERAGE_UNKNOWN`、success 但 `data.completeBuild = false`,以及 build 開始後沒跑完的 `BUILD_TIMEOUT`、build 中出現的 `IDE_MODAL_DIALOG`、build 過程的例外。Activate 和 Login 會自己再編譯一次([InfoSys: Command Login](https://infosys.beckhoff.com/content/1033/tc3_plc_intro/2531393419.html)「If a PLC project has not been compiled since its last change, TwinCAT compiles the project before logging in」;[Command Download](https://infosys.beckhoff.com/content/1033/tc3_plc_intro/2531438987.html)),但沒有人檢查那次編譯的結果:**實測 2026-10-26**(registered tcauto,master f7e41a4,TcXaeShell.DTE.15.0 + 本機 UmRT,TwinCAT_Festo 複本缺 7 個 library)`BuildProject` 回 `LIBRARY_UNRESOLVED` 後 `EnableConfig Force=true` 照樣 Activate + Download + Run 並回 success,沒有任何 warning;Port_851.app 是 Enable 期間寫的(Activate 自己編譯了),而缺 lib 時程式碼可能根本沒被編譯(#45)。`Build-TcProject` 的結果裡 `data.buildRequired` 是這次記下的原因。
  - **code-changed(#65)**:上一次完整 build 之後，模組的 cmdlet 改了 PLC 程式碼或專案內容:`Write-TcPouCode`(有寫入 declaration / implementation 時)、`Add-TcPou`、`Add-TcDut`、`Add-TcGvl`、`Add-TcLibrary`、`New-TcProject`(記在新的 .sln)、`Reset-TcSolution`(從磁碟重新載入，檔案可能被外部工具改過)。原因同上:Activate / Login 會編譯改過的程式碼([InfoSys: Command Login](https://infosys.beckhoff.com/content/1033/tc3_plc_intro/2531393419.html)),但沒人檢查結果。reason 寫是哪個 cmdlet 改了哪個物件,例如 `PLC code changed by Write-TcPouCode MAIN [implementation] | Add-TcPou FB_Axis`(改動之間用 ` | ` 分隔:`|` 不會出現在 Windows 檔名或 IEC 名稱裡，記錄時也把 `|` 換成 `/`;同一筆只列最後 8 個改動，更早的寫成 `(+N earlier)`,N 是近似值，可能偏少)。這些 cmdlet 的結果有 `data.buildRequired`(這次記下的原因);狀態檔寫不進去時另有 `data.stateWarning`(跟 `Build-TcProject` 同形狀),記錄仍留在這個 process 的記憶體裡照樣擋，不會變成「沒記」(連寫記憶體那一步都失敗時，退而在記憶體記一筆 `<unknown>`,擋所有 solution)。失敗路徑的規則:物件可能已經改了才記:
    - `Write-TcPouCode` 某個 setter 丟例外(reason 寫已寫入的部分加 `write failed`,例如 `[declaration+write failed]`);
    - `Add-TcPou` / `Add-TcDut` / `Add-TcGvl` 在 CreateChild 之後的 lookup / kind / language / declare 失敗，或 CreateChild 以 IDE_BUSY / IDE_CRASHED / IDE_MODAL_DIALOG / IDE_TIMEOUT 失敗(呼叫可能已在 XAE 裡執行);CreateChild 本身回錯誤(XAE 拒絕，例如 `PLC_LOGGED_IN`)不記;`Add-TcLibrary` 的 AddLibrary 失敗(沒安裝 / 已有同名 reference 不記);
    - `New-TcProject` 在 `Solution.Create` 之後失敗:IDE 已經開著新的、沒存也沒 build 過的 solution(`$script:TcSysManager` 可能已經是它),而它的 .sln 路徑不確定，所以模組的 solution 路徑設成未知、清掉該 IDE 的 #29 session record、記在 `<unknown>`(擋所有 solution,直到一次完整 build);
    - `Reset-TcSolution`:XAE 已經從磁碟重新載入 project(`data.answeredYes = true`)之後的任何失敗(之後的 modal、reload 提示處理、重連、solution 比對、`Documents.CloseAll`、`Solution.Close`、`Solution.Open`);`PROJECT_OPEN_FAILED` 一律記(solution 可能開到一半);`Solution.Open` 之後重連失敗。記在這次要重開的 .sln;回答 Yes 之後(成功或失敗)不確定 XAE 重新載入的是哪一個 solution,所以候選的全部都記：要重開的 .sln(`-SolutionPath`)、模組原本的 .sln、`RESET_SOLUTION_MISMATCH` 讀到 IDE 開著的那個(去掉空的，同一個 .sln 只記一次)。
    - 還沒動到專案就停下的不記:`INVALID_PARAMS`、`POU_NOT_FOUND`、`exists`、CreateChild 前的 modal、`REFS_NOT_FOUND`、`New-TcProject` 在 `Solution.Create` 之前或當下失敗、`Reset-TcSolution` 沒有回答 Yes 時的 dialog / `RESET_SOLUTION_*` / close 失敗。
  - 可以同時存在(同一筆的 `reasons`),message 與 hint 都列出來;hint 開頭是 `Recorded: <kind> (<reason>); ...`,所以看得出是 code-changed、哪個 cmdlet。這一筆的 `kind` 取最嚴重的那種(platform-switch > unverified-build > code-changed),之後再記 code-changed 不會蓋掉前面的語意。`Enable-TcConfig` 在 Activate 之前檢查,拒絕啟用(`data.steps` 的 `build-required` 步驟寫原因、時間與 .sln);`Enter-TcPlcOnline`(MCP `PlcLogin` / `SendPlcProgram`)在 Login 之前檢查,**每一種 LoginMode** 都擋(Regular 也可能下載:XAE 判斷要不要 download;SilentMode 下編譯錯誤時「不載入程式就登入?」的問題應該是由 XAE 用預設鈕回答，**推論，未實測**)。狀態檔讀不到(拿不到鎖)時 `Enter-TcPlcOnline` 也擋，訊息以 `STATE UNREADABLE` 開頭，跟 build 無關，重試即可。
- **已知範圍(不擋)**:完全沒透過模組 build 過、也沒透過模組改過程式碼就直接 `Enable-TcConfig` / `Enter-TcPlcOnline`:沒有記錄，不擋,Activate / Login 會自己編譯，結果同樣沒人檢查(上面的實測情境，只是前面沒有 build)。要有保證就先跑 `Build-TcProject`。solution 裡沒有 PLC project(只有 I/O / NC)時 `Build-TcProject` 不寫 unverified-build(沒有 PLC 程式碼要驗證，寫了也永遠解不開)。在 XAE 手動 build 不會更新狀態;`Clear-TcProject` 不寫也不清。**完整 build 之後又改了程式碼**:透過模組 cmdlet 改的(`Write-TcPouCode`、`Add-TcPou` 等)**已處理**,記成 code-changed 並擋下(#65,見上)。仍然看不到的:在 XAE 編輯器手動改、或磁碟上的檔案被外部工具改了而 XAE 自己重新載入(檔案沒開在編輯器時 XAE 約 5 s 內自動載入、不跳框，**實測 2026-10-20**,4024 32-bit XAE,見 `Reset-TcSolution` 說明),沒有經過 `Reset-TcSolution` 就不會記;這種情況改完先跑 `Build-TcProject`。磁碟上已經被改過的 solution 用 `Open-TcProject` 或 `Connect-TcIde -SolutionPath` 重新開啟也不會記(模組不知道上次完整 build 之後檔案有沒有變),開完先跑 `Build-TcProject`。`New-TcTestCase` 只建一個測試定義物件、不碰 PLC 專案;`Set-TcVariableLink`(I/O 對應)、`Open-TcProject`、`Clear-TcProject`、`Invoke-TcIoScan` 不改 PLC 原始碼(I/O 對應、開既有 solution、清掉編譯產物、掃 I/O 裝置),也不記;`Send-TcPlcProgram` 是 `Enter-TcPlcOnline -LoginMode Download`,本身就被擋。build 開始後才中斷的情況(`BUILD_TIMEOUT`、build 中出現的 `IDE_MODAL_DIALOG`、build 過程的例外)會記成 unverified-build;build 前就停下的(build 前的 modal、`-ExpectedProject` 檢查、`Build($false)` 被拒的 `IDE_BUSY`)不記。
- **#61(已修)**:以前 `Enable-TcConfig -Force -AllowUnresolvedLibrary` 自動切換平台後的 platform-fix-build 只要回 success(codeVerified = false、只有 library 錯誤)就被當成完整 build,清掉 BUILD_REQUIRED(連前一次獨立 `Build-TcProject` 記下的那筆一起清),接著 Activate + Download + PLC Run,回 success 且頂層 `warning = null`(**實測 2026-10-28**,registered tcauto,TcXaeShell.DTE.15.0 + 本機 UmRT,BFH-1650 複本注入不存在的 library)。現在:`completeBuild` 只在 `coverageComplete` 且 `codeVerified = true` 時成立;`Enable-TcConfig` 移除 `-AllowUnresolvedLibrary`,platform-fix-build 回 success 但 `data.completeBuild` 不是 true 時,`platform-fix-build` 步驟記 ok=false,在 set-config 之前回 `BUILD_REQUIRED`(message 寫 codeVerified / warningCodes),不 Activate;platform-fix-build 本身失敗(例如 `LIBRARY_UNRESOLVED`)時照舊回該 build 的錯誤碼。
- **「完整成功」的條件(#58 後收緊)**:`success = true`、`data.coverageComplete = true`(每個 PLC project 都是 built——disabled 且沒 build 的 `disabled` project 不算在內(#104)——PLC project 清單讀得到，且 solution 裡至少有一個 PLC project),而且 `data.codeVerified = true`。沒有例外:`-AllowUnresolvedLibrary` 接受的 build(codeVerified = false)也不算(#61;以前算，結果未驗證的程式被 Activate)。以下情況 build 回 success 也**不會**清掉:有 project 被 `PROJECT_SKIPPED_BY_CONFIGURATION` 跳過、PLC project 清單讀不到(`coverageError`,`codeVerified = null`)、Error List 讀不到、有無行號的 code 列、solution 裡沒有 PLC project(只有 I/O 或 NC;這種 solution 切換平台後只能用下面的手動解除)。`Build-TcProject` 的 success 結果有 `data.completeBuild`(這次算不算完整成功);`Enable-TcConfig` 回 `BUILD_REQUIRED` 時,message 和 `platform-fix-build` 步驟的 detail 會寫上一次成功的 build 為什麼不算(`completeBuild=false, codeVerified=..., coverageComplete=..., warningCodes=[...]`),所以看得出原因;platform-fix-build 回 success 但不完整時,那一步是 ok=false、錯誤碼 `BUILD_REQUIRED`(#61)。
- **狀態存成檔案,而且 fail-closed**(實作:`Private/Set-TcBuildRequired.ps1`):`%TEMP%\TwinCATAutomation\build-required.json`(測試用 `TCAUTO_STATE_DIR` 改目錄),每個 .sln 一筆,key 是正規化的完整路徑(小寫,可含非 ASCII,檔案是 UTF-8)。不是模組變數:`Import-Module -Force`、CLI 每次一個 process、MCP bridge 重啟都不會弄丟。切換時寫入,完整成功的 `Build-TcProject` 刪掉該 .sln 的那筆(檔案空了就刪檔)。
  - 每筆的格式:`{ solution, kind, reason, reasons: { "platform-switch": "...", "unverified-build": "...", "code-changed": "..." }, at }`;#56 以前寫的筆沒有 `kind` / `reasons`,讀成 platform-switch。
  - 讀-改-寫用 named mutex 保護(逾時 3 s):預設目錄用固定名稱 `Local\TwinCATAutomation.BuildRequired`(`%TEMP%` 在不同 process 可能一個是 8.3 短名、一個是長名，用路徑 hash 會變成兩把鎖);`TCAUTO_STATE_DIR` 有設時是 `Local\TwinCATAutomation.BuildRequired.<GetFullPath 後小寫路徑的 hash>`(相對路徑先轉成完整路徑、8.3 短名展開，測試用)。有設和沒設 `TCAUTO_STATE_DIR` 的 process 即使指向同一個目錄，也用不同的 mutex,同一個狀態目錄不要混用兩種設定。.sln 的 key 也會展開 8.3 短名(GetLongPathName,套在最長的已存在上層目錄),所以 `Connect-TcIde -SolutionPath` 給短名或長名都對到同一筆。`Local\` mutex **只在同一個登入 session 內互斥**:別的使用者或 session 0 的服務拿的是另一把鎖，檔案替換仍是原子的，但同時讀-改-寫可能丟掉其中一筆更新。檔案用 `[IO.File]::Replace` 換掉(不會有「沒有檔案」的空窗),失敗會短暫重試並清掉 `.tmp`。
  - 每一筆也同時記在模組的記憶體裡;檔案寫不進去(別的 process 或防毒開著它、目錄建不起來)或拿不到鎖時,這個 process 仍然擋,`Set-TcTarget` / `Enable-TcConfig` 的 `data.warning`、`Build-TcProject` 的 `data.stateWarning` 寫明「只記在這個 process」(MCP 端到端測試:`mcp-server/test/build-result.test.js` 狀態目錄不可寫的情境)。拿不到鎖時 `Enable-TcConfig` / `Enter-TcPlcOnline` 直接擋。
  - **記憶體那筆會比檔案擋得久**:它只會被這個 process 裡一次完整成功的 `Build-TcProject` 清掉。手動刪檔、或別的 process 的 build 清掉了檔案那筆，這個 process(例如還在跑的 MCP bridge)仍然擋;要解除就在這個 process(同一個 MCP server)跑一次完整的 `Build-TcProject`,或重啟 MCP bridge / 開新的 PowerShell session。
  - 保守規則:記錄當下不知道 .sln 路徑 → 記在 `<unknown>`,對所有 .sln 都擋(任何一次完整成功的 build 會清掉它:它只會來自不知道自己 .sln 的 session,通常接著 build 的就是同一個 solution;留到手動才清會永久擋住其他 solution);`Enable-TcConfig` / `Enter-TcPlcOnline` 時不知道 .sln 路徑 → 有任何一筆就擋;檔案壞掉(JSON 讀不出來)→ 用 `[IO.File]::Replace(tmp, 檔案, build-required.json.corrupt-<時間>)` 一步換成一筆 `<corrupt>`(原檔留成 .corrupt-<時間>),對所有 .sln 都擋,build 成功也**不會**清掉它(壞掉的檔可能有別的 solution 的記錄);這一步換不掉(檔案被鎖)時壞檔原封不動，每次檢查都當成讀不到而擋(fail-closed)。
- **手動解除**:刪掉 `%TEMP%\TwinCATAutomation\build-required.json`,或只刪掉該 .sln(或 `<corrupt>`)那一筆。只在你確定編譯產物對應目前的 solution platform 時才這樣做,例如:PLC 專案被刻意設成不 build(Configuration Manager 沒勾 Build,所以每次 build 都有 `PROJECT_SKIPPED_BY_CONFIGURATION`、永遠不算完整成功),而它的產物已經用別的方式為目前平台建好;solution 裡沒有 PLC project(只有 I/O / NC 設定);或 `<corrupt>` 之後已經把每個 solution 都 build 過一次。不確定時就跑一次完整的 `Build-TcProject`。
- **下一步**:`Build-TcProject` 完整成功(缺 library 時先在 Library Manager 安裝——`-AllowUnresolvedLibrary` 解不開 BUILD_REQUIRED,#61;有 project 被跳過時先在 Configuration Manager 勾回 Build;`BUILD_FAILED` 先修程式碼)後再 `Enable-TcConfig` / `Enter-TcPlcOnline`。

### BUILD_STATUS_UNKNOWN

- **為什麼**:`Build-TcProject` 的 build 呼叫有返回,但 `LastBuildInfo` 讀不到(COM 例外),而 Error List 也讀不到(或讀到的列 severity 無法判定:`data.severityUnknown`),所以無法判定 build 是成功還是失敗。`success = false`、`data.buildSucceeded = null`。以前這種情況會被當成 `failedProjects = 0` 回 success,現在不會。
- **下一步**:看 XAE 的 Error List 後再決定;處理 IDE 的 dialog(`Get-TcIdeModalDialog`)或讓 Error List 可見後重跑 `Build-TcProject`(或單獨 `Get-TcBuildErrors`)。
- **`code` 可能是 null**:TcXaeShell 15.0 的 Error List 沒有 Code 欄(右鍵表頭 Show Columns 只有 Severity / Description / Project / Project Rank / Path / File / Line / Column / Source),描述文字也不含 Cxxxx。模組只對幾個常見訊息推回編碼(C0046 `Identifier 'x' not defined`、C0018 `'x' is no valid assignment target`、C0032、C0035、C0037、C0077、C0080;表在 `Private/Get-TcIdeErrorList.ps1` 的 `$script:TcCompilerCodePatterns`),靜態分析訊息 `SAxxxx` 則直接在描述裡。
- **Build 成功時 `errorItems` 不一定空**:Error List 會留著非 PLC code 的項目。2026-10-18 實測 GantryCylinder 專案 build 成功仍有 7 筆 Error,全部是 `file = plc.Library Manager`、`line = 0` 的「Could not open library '#System_VisuElem3DPath' / '#System_VisuElemTrace' / '#System_VisuElemCamDisplayer' / '#System_VisuElemsAlarm' / '#System_VisuElemsDateTime'(placeholder 無法解析)」與「'#Analyzation' 3.5.2.0 / '#IecSfc' 3.4.2.0 has not been installed」——是機器上缺 visu/分析函式庫,不影響 `failedProjects`,但**可能影響程式碼有沒有被編譯**(4024 Festo 實測 2026-10-25;4026 GantryCylinder 未驗證,#45;見 `LIBRARY_UNRESOLVED`)。這些列的 `category` 是 `library`,只算進 `libraryErrors`(#23 以前算進 `errors`)。
- **XAE Build 會先存檔**:VS 的 Save all before build 預設開啟,`Write-TcPouCode` 後 `Build-TcProject` 會把 POU 寫進磁碟;要試錯請用複本。
- **Warning 也讀得到內容**(2026-10-20):`Build-TcProject` 的 `data.warningItems[]`(與 errorItems 同格式)與 `data.codeWarnings[]`(排除 Library Manager 項),`Get-TcBuildErrors` 的 `-IncludeWarnings` 預設開(`-IncludeWarnings:$false` 省 1~2 s 的 toggle)。之前 `warnings=1` 卻沒有項目,就是這個開關沒開。按鈕計數的 regex 也認 zh-TW 的「3 個錯誤 / 1 個警告 / 2 則訊息」。
- **zh-TW VS2022 也讀得到**(2026-10-21,取代舊註記「需英文 UI」):窗格名 `錯誤清單`(英文 UI 是 `Error List`);摘要按鈕是 `0 / 2 錯誤` 的「顯示 / 總數」形式,取總數;VS2022 的 Error List 預設 scope 是 `目前專案`(Current Project),會藏其他專案的列,模組讀之前先切到 `整個方案`(Entire Solution);目前的 scope 從下拉選單本身的選取值讀(#117,見 `ERRORLIST_INCOMPLETE`)。其他語系仍回 `ERRORLIST_UNAVAILABLE`。
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
- **為什麼**:VS2022 上 `SolutionBuild.Build($true)`(wait)**永遠不返回**,所以模組改 `Build($false)` 再每輪輪詢 `BuildState`(到 3 = Done)。新增 `-TimeoutSec`(預設 600)是輪詢上限;逾時時 `BuildState` 還沒到 Done。輪詢期間也掃 modal dialog:有就回 `IDE_MODAL_DIALOG`,不會拖到逾時;掃描沒完成只是繼續輪詢,逾時時 `data.modalScan` 記下最後一次未完成的掃描(#42,見「MODAL_SCAN_INCOMPLETE」)。成功時 `data.buildSec` 是 `Build($false)` 到 Done 的秒數(VS2022 實測 6 s、首次含啟動約 9 s)。
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
- **回傳格式與 `Build-TcProject` 相同**(cd180df):`Clear-TcProject` 用同一個分類器(`Get-TcErrorItemCategory`)和 `Add-TcBuildWarning`,`data.errorItems[]` 每筆有 `category`(`code` / `library` / `other`)、`data.libraryErrorItems[]`,warning 放在 `data.warningCodes[]`(目前只會有 `LIBRARY_UNRESOLVED`)、`data.warningCode`(第一個)、`data.warning`。

### RESET_SOLUTION_MISMATCH

- **現象**:`Reset-TcSolution` 沒有動作,`data.openSolution` 與 `data.expectedSolution` 不同。
- **為什麼(#29)**:`Connect-TcIde` 可能依 session record 等證據 attach 了一個被擋住的 IDE;關掉 dialog 後讀得到的 `Solution.FullName` 若不是模組以為的 solution(模組最後連到 / 開啟的那個;沒有就用 `-SolutionPath`),關閉它會動到別人的工作,所以在 `Documents.CloseAll` / `Solution.Close` 之前就停下。`-SolutionPath` 指定另一個 .sln(換開)不算不一致:比對的是 IDE 目前開的與模組預期的。
- **下一步**:`Connect-TcIde -SolutionPath <你的 sln>` 連到正確的 IDE(找不到就加 `-LaunchIfBlocked`),再 `Reset-TcSolution`。

### RESET_SOLUTION_UNVERIFIED

- **現象**:`Reset-TcSolution` 沒有動作(什麼都沒關),`data.guardError` 是最後一次讀 `Solution.FullName` 的錯誤,`data.guardSec` 是等了多久。
- **為什麼(#29)**:關閉前的防呆(見「RESET_SOLUTION_MISMATCH」)要先讀到 IDE 目前開的 solution 才能比對;在 `-TimeoutSec` 內每 500 ms 重讀,一直丟例外或回 `$null`(例如 reload 後 XAE 還在忙)就 fail-closed,不關沒有比對過的 solution。讀回空字串(沒有開著的 solution)才放行。
- **reload 提示晚跳出來(#87)**:實測 2026-11-01(4026 `VisualStudio.DTE.17.0`,TwinCAT 3.1.4026.22,registered tcauto,副本 `C:\Temp\Verify-4026-axis`):XAE 開著時把 `.plcproj` 複製蓋回,立刻 `ResetSolution`,120.3 s 後回 `RESET_SOLUTION_UNVERIFIED`(`guardError` "Solution / Solution.FullName answered $null",120 s 就是 `-TimeoutSec` 預設值);之後 `GetIdeModalDialog` 看到 project reload 提示,再跑一次 `ResetSolution` 才 `answeredYes true`(10.4 s)。當時的程式只在開頭查一次 dialog,防呆輪詢 `Solution.FullName` 時不再查。現在的程式邏輯(**待真機驗證**):每次讀 `Solution.FullName` 沒得到答案(`$null` 或例外)就 `Get-TcIdeModalDialog` 一次;是 reload 提示就照步驟 1 處理(project 按 Yes 走 Yes-only 路徑,file 關掉後走 close/reopen)再重讀,是其他 dialog 立刻回 `IDE_MODAL_DIALOG`,不等滿 `-TimeoutSec`。沒有 `-SolutionPath`、模組也不知道 solution 時,讀 solution 路徑之前也先處理 dialog。提示到底是在呼叫前就在、還是期間才跳出,那次沒有確認。
- **prompt 在 guard 之後才跳出(#87 重測)**:實測 2026-11-02(4026 `VisualStudio.DTE.17.0`,registered tcauto,副本 `C:\Temp\Verify-4026-axis`,紀錄 `openspec/changes/complete-automation-interface/verification/issue87-smallbug.md`):改 `.plcproj` 後約 0.5 s 呼叫 `ResetSolution`,4 輪只有 1 輪成功(10.1 s,`answeredYes` true)。另外 3 輪:1 輪 0.8 s 回 `SOLUTION_CLOSE_FAILED`(projectCheck 的 PLC `checked` false、locate 失敗,`Solution.Close` 對 `$null` 呼叫方法),2 輪 3.7 s 回 `IDE_MODAL_DIALOG`(projectCheck 的 `TIPC.Child(1)` / object list 遇 `RPC_E_CALL_REJECTED`);之後 `GetIdeModalDialog` 都看得到 project reload 提示。提示已經在畫面上時呼叫，每次都成功(8~9 s)。現在的程式邏輯(**待真機驗證**):步驟 1b 丟例外或讀回不完整(有 PLC `checked` false、沒有 `ITcSysManager`)時、`Documents.CloseAll` 與 `Solution.Close` 之前、以及這兩者失敗時，都會再 `Get-TcIdeModalDialog`。`DTE.Solution` 讀回 `$null` 視為失敗，不對它呼叫方法。查到 reload 提示就回到步驟 1,整個流程重跑(只答過 project 提示就走 Yes-only 路徑);查到其他 dialog 就回 `IDE_MODAL_DIALOG`,不再回 `PROJECT_SAVE_FAILED` / `SOLUTION_CLOSE_FAILED`。整個呼叫共用「最多 5 個提示」的上限,`Solution.FullName` 的輪詢合計不超過 `-TimeoutSec`。`Solution.Close` 成功之後不再重跑。
- **下一步**:`Get-TcIdeModalDialog -ProcessId <data.previousIdeProcessId>`(MCP `GetIdeModalDialog ProcessId=<data.previousIdeProcessId>`)看有沒有 dialog 並處理;等 XAE 不忙後重跑 `Reset-TcSolution`(MCP `ResetSolution`;可加大 `-TimeoutSec`);仍讀不到就 `Connect-TcIde -SolutionPath <sln>`(MCP `ConnectIde SolutionPath=<sln>`)重新連線再試。

### SOLUTION_RELOAD_INCOMPLETE

- **現象**:`Reset-TcSolution` 回 `SOLUTION_RELOAD_INCOMPLETE`:reload 提示已處理 / solution 已重開並重連,但在 `-TimeoutSec` 內讀回不到「solution 已載入完成」。`data.loadCheck`:`complete`、`sec`、`polls`、`expectedFrom`(`disk` = .sln 引用的 .tsproj 列出的 PLC 名稱(`<Plc><Project Name>`,2026-11-07 唯讀核對 4024 / 4026 測試副本的 .tsproj);`memory` = .tsproj 沒列名稱(例如獨立專案檔 .xti,未驗證)時用 Reset 開始前 TIPC 底下的名稱;`.sln` 沒有 .tsproj 但 Reset 開始前 TIPC 底下有 PLC 時也用 `memory`(要求 TIPC,PR #173 review);`none` = .sln 沒有 .tsproj 且沒有記憶體基準(不要求 TIPC),或兩者都沒有(只要求 TIPC 至少 1 個子項))、`expectationSource`(同值;`none` 表示沒有預期的 PLC 名稱，讀回條件較弱)、`expected{requireTipc, plcs, minPlcCount, tsproj}`、`expectationError`、`last{fullName, isOpen, projectCount, solutionBuild, activeConfiguration, tipc, plcs}`(最後一次讀到的)、`lastError`(缺哪一項)。
- **為什麼(#135 F5)**:2026-11-05(4024 TcXaeShell 32-bit,registered tcauto)`ResetSolution` 成功後立刻 `BuildProject` 回 `BUILD_FAILED`,是模組丟出的 null 例外、不是編譯錯誤,重試一次就成功;推測 XAE 還在重新載入(**推論,未觀察到**)。現在兩條成功路徑(Yes 只重連、close/reopen)回 success 前都每 500 ms 讀一次,直到全部成立:`Solution.FullName` 等於這個 .sln、`Solution.IsOpen`、`Solution.Projects`(不算 Miscellaneous Files 專案;它只在開著零散檔案時存在,是推論、未實測)>= 1、`Solution.SolutionBuild` 與 `ActiveConfiguration` 非 null,需要時 `LookupTreeItem('TIPC')` 非 null 且期望的 PLC 都在。每次 DTE 讀取只試一次(`Invoke-TcComRetry -MaxRetries 1`,`Get-TcSysManager -MaxRetries 1`);`LookupTreeItem` 丟例外就丟掉快取的 `ITcSysManager`,下一次重新取;讀不到時、以及逾時前最後一次,掃 modal dialog:是 reload 提示且這次呼叫處理過的提示還不到 5 個，就回到步驟 (1) 回答它(#176;5 個上限涵蓋整次呼叫;提示的回答與 `Solution.FullName` / 讀回輪詢共用 `-TimeoutSec` 的剩餘預算,`Documents.CloseAll`、`Solution.Close`、`Solution.Open` 每次各自以 `-TimeoutSec` 為上限,所以迴圈重跑時總時間可能超過 `-TimeoutSec`;只有 NeedReopen(回答過 No / Ignore / WM_CLOSE,或提示自己消失)或 YesPathDone(Yes 路徑做過)時才走完整的 guard / (1b) / close / reopen,兩者都沒有時(例如一開始沒提示、reopen 後讀回才跳 project 提示並回答 Yes)走 Yes-only 路徑;`data.reloadPromptAttempts` 等欄位持續累積),其他 dialog 或已達上限就回 `IDE_MODAL_DIALOG`(`data.loadCheck` 一起帶);讀取遇到 `IDE_CRASHED` 立刻停,回 `IDE_CRASHED`。檔案可能已經重新載入,所以這兩種失敗都記 code-changed(`BUILD_REQUIRED`)。
- **下一步**:`Get-TcIdeModalDialog`(MCP `GetIdeModalDialog`)看有沒有 dialog 並處理,再重跑 `Reset-TcSolution`(MCP `ResetSolution`;可加大 `-TimeoutSec`);成功後才 `Build-TcProject`。不要直接接 Build。
- **待真機驗證**:讀回條件是依 #135 的現象設計,哪一項在 XAE 真的會晚到還沒在真機量過。

### CLEAN_FAILED

- **現象**:`Clear-TcProject` 回 `CLEAN_FAILED`:`data.failedProjects` > 0(Clean 完 `SolutionBuild.LastBuildInfo`,[失敗的 project 數](https://learn.microsoft.com/en-us/dotnet/api/envdte.solutionbuild.lastbuildinfo)),或 DTE 的 `Solution` / `SolutionBuild` 連續 15 s 都是 `$null`(`data.nullReads`),或 `Clean` / `BuildState` 的 COM 呼叫失敗。
- **為什麼(#18)**:lifecycle-smoke 的 `03a-clean` 以前在模組 scope 直接呼叫 `$script:TcDte.Solution.SolutionBuild.Clean(...)`,兩次在 `Connect-TcIde` 成功後 0.2 s 內丟「不可在值為 Null 的運算式上呼叫方法」(實測 2026-10-19、2026-10-20,4024 32-bit XAE Shell,log `A-login1-silentmode-final.log`、`master-1717e3e-run2.log`)。哪一段是 `$null`(`$script:TcDte`、`Solution` 或 `SolutionBuild`)log 沒記,**原因未確認**:同一秒的 `02b-verify-target` 用的是 `$script:TcSysManager`,不能證明 `TcDte` 非 null;較可能是剛開好 solution 的 XAE 短暫回 `$null`(`Connect-TcIde` 最後重讀 `Version` / `Solution.FullName` 也看過空值,實測,見其註解)。改用 `Clear-TcProject` 之後 2026-10-25 連跑 A 組(4024)、B 組(4026 VS2022)各 3 輪,`03a` 6/6 PASS,`data.nullReads` 全是 0(沒有重現)。`Clear-TcProject` 先輪詢到 `Solution` / `SolutionBuild` 都有值才 Clean,`$null` 有出現時 `data.nullReads` 會記下次數,再發生就能定位。
- **Library Manager 錯誤**:`LastBuildInfo` > 0 而 Error List 全是 library 解析失敗時回 `LIBRARY_UNRESOLVED`(見「CLEAN_LIBRARY_UNRESOLVED」),`-AllowUnresolvedLibrary` 才放行成 success + `warningCode`;`LastBuildInfo` 讀不到回 `CLEAN_UNVERIFIED`。實測 2026-10-25,4024 32-bit XAE Shell:去掉 Visu library 的 Festo 複本開好 solution 後第一次 Clean `LastBuildInfo = 1`,Error List 7 筆都是這種;Build 後再 Clean 是 0;4026 VS2022 RobustDemo 一律 0。其他錯誤、或 Error List 讀不到,是 `CLEAN_FAILED`。
- **下一步**:看 XAE Output 視窗;剛 `Connect-TcIde` 完就再跑一次 `Clear-TcProject`,仍失敗就 `Reset-TcSolution` 後再試。腳本不要再直接用模組內部的 `$script:TcDte` 做 Clean。

### ERRORLIST_UNAVAILABLE

- **為什麼**:`Get-TcBuildErrors` 的 UI Automation 在 `-TimeoutSec`(預設 30 s)內找不到 Error List(視窗名要是 `Error List` 或 zh-TW VS2022 的 `錯誤清單`,其他語系找不到;視窗被關閉 / auto-hide、IDE pid 未知、UIA 被 modal dialog 卡住)。模組會先 `View.ErrorList` 把視窗叫出來,但 auto-hide 的視窗仍讀不到。
- **下一步**:確認 XAE 主視窗可見、Error List 釘住(不是 auto-hide);手動 View > Error List 後重跑;IDE 若有 dialog 先處理(`Get-TcIdeModalDialog`)。`Build-TcProject` 遇到這個情況不會失敗,只把 `data.errorListError` 設為此 code 並讓 `errors` 退回 `failedProjects`。
- **逾時之後**:逾時的 scan 會被停下並在下一次 `Get-TcBuildErrors` / `Build-TcProject` 時清掉;thread 還沒停時回本 code 加 `data.scanBusy = true`,停了就照常掃描。#75 之前清理本身會丟 `ArgumentException`(「引數類型不相容」;實測 2026-10-28,PS 5.1.26100.9711:`New-Object` 建的 `List[object]` 被 `@()` 包住會丟,不是整個 5.1.26100 都會),一次逾時就讓同一個 bridge / PowerShell session 的 Build 與 Error List 永久失敗,只能重啟;現在清不掉的項目會被丟棄並在 `Get-TcBuildErrors` / `Build-TcProject` 的 `data.scanCleanupWarning` 註明,不會再卡住。
- **丟棄的 scan 可能還在跑**:被丟棄的項目若狀態讀不到、或整個清單走不了而被重設,舊 UIA thread 可能還在動 Errors / Warnings / Messages 篩選按鈕。這種情況下**該次呼叫不開新 scan**,回本 code,`data.scanBusy = false`、`data.scanMayBeRunning = true` 並帶 `data.scanCleanupWarning`;`Build-TcProject` 把 `scanCleanupWarning` 帶進自己的 `data`、`errorListError = ERRORLIST_UNAVAILABLE`、`codeVerified = null`(不會算成 verified,#61)。再呼叫一次才照常掃描。殘餘風險:被丟棄的舊 thread 已不再追蹤,第二次呼叫時它若仍在跑,還是可能跟新 scan 搶篩選按鈕(要 UIA thread 卡死、連清理本身也失敗才會發生,且只會出現在已拒絕過一次之後);無法在不追蹤的情況下確認它停了。

- **Build 的 Error List 預算(#107)**:`Build-TcProject` / `Test-TcPlcProject` / `Clear-TcProject` 不論成功或失敗，都給 Error List 完整的 30 s(`$script:TcBuildErrorListTimeoutSec`)。這是上限不是等待，讀完就返回。`Enable-TcConfig` 失敗診斷時讀 Error List,也用同一個預算，但不超過 `-TimeoutSec` 剩下的時間(最少 5 s)。以前成功路徑只給 8 s,而 Error List 的掃描(叫出窗格、切 scope、切 severity、讀 grid)要 16.5–17.8 s:實測 2026-11-03,TwinCAT 3.1 Build 4026、`TcXaeShell.DTE.17.0`(VS2022 XAE Shell),回報者見 #107。結果 build 成功卻回 `errorListError = ERRORLIST_UNAVAILABLE`、`CODE_NOT_VERIFIED`,接著 `Enable-TcConfig` 被 `BUILD_REQUIRED` 擋下。現在要 30 s 內仍讀不完才會回這個 code;單獨跑 `Get-TcBuildErrors -TimeoutSec 60` 可以確認是不是只是慢。MCP 的 `BuildProject` 在 `TimeoutSec` 之後多留 90 s、`CleanProject` 多留 60 s(`mcp-server/lib/tools.js` `TOOL_GRACE_MS`;預設 tool timeout 690 s / 360 s),避免 build / clean 用完 `TimeoutSec` 時，bridge 在讀 Error List 的途中被砍。

### ERRORLIST_INCOMPLETE

- **現象**:`Get-TcBuildErrors` 回 `success = false`、`error.code = ERRORLIST_INCOMPLETE`。data 內容:
  - `data.incomplete = true`。
  - `data.missingRows[]`:哪個 severity 少讀。每筆有 `severity`、`expected`(摘要按鈕上的總數)、`read`(讀到的列數);severity 無法隔離時只有一筆 `total`。
  - `data.errorsTotalUnknown`:Errors 按鈕的總數讀不到。
  - `data.scope = { before, after, entire, switched }`,`data.notes` 是掃描紀錄。
  - 讀到的部分列仍在 `data.errors` / `data.warnings`。
- **為什麼(#117)**:zh-TW VS2022 的 Error List scope 設成 `目前專案` 時,`BuildProject` 與 `GetBuildErrors` 都回 `warnings: 28`,但 `warningItems: []`,而且 `success: true`。實測 2026-11-05,VS2022 `VisualStudio.DTE.17.0` zh-TW、4026、`C:\Temp\Verify-4026-axis`,當時的目前專案不是 PLC 專案;切回 `整個方案` 後 28 列全讀到。原因是舊的 scope 判斷在 Error List 裡找名稱為 `目前專案` 等的 ListItem,而下拉選單**收合時沒有任何 ListItem**,模組就判定「不用切換」,把篩過的列當成整份清單。
  - Error List 的 scope 篩選有 Entire Solution / Open Documents / Current Project / Current Document 四種，見 [Microsoft Learn: How to view errors and warnings](https://learn.microsoft.com/en-us/visualstudio/ide/error-list-window) 的 "Filter the list by scope and source"。這是 VS 的視窗，不是 TwinCAT 的功能,InfoSys 沒有對應頁面。
- **現在的做法**:
  - **讀 scope**:從下拉選單**本身**讀，用 `SelectionPattern.GetSelection()` 取選取項目的名稱，讀不到再用 `ValuePattern`。收合時也讀得到(實測 2026-11-05,同一輪的 UIA probe)。
    - 只有選取值是已知 scope 名稱的 ComboBox 才算 scope 下拉。已知名稱是上面那四種的英文名，加上 `整個方案` / `目前專案`(實測)、`目前文件` / `開啟文件`(推論)。`Changed Documents` / `已變更的文件` 不在 Learn 的清單上，保守加入，未實測。
    - 另一個 `Build + IntelliSense` 下拉不算。
    - **清單外的名稱**(其他語系、未來新增的 scope)不會被認成 scope 下拉,`scope.entire = null`,這時只靠下面的列數檢查保護。都讀不到時才退回舊做法(展開中的 ListItem)。
  - **切換**:選取值不是 `整個方案` / `Entire Solution` 就切過去，切完**讀回**選取值。讀回仍是別的 scope → `data.scope.entire = false`;讀回讀不到 → `entire = null`。
  - **列數讀回檢查**:每個要讀的 severity,讀到的列數少於按鈕總數，就回本 code。errors 一定比;warnings 預設比,`-IncludeWarnings:$false` 不比;messages 只有 `-IncludeMessages` 才比。按鈕總數讀不到的 severity 不比。`scope.entire = false` 時一律回本 code。
  - **重複列**:同一頁出現多次的相同列算多列，只有跨捲動頁重複的才去重。限制：完全相同的兩列剛好分在相鄰兩頁時，看起來和捲動重疊一樣，只算一列，可能少於總數而觸發本 code;每頁的重複數記在 `data.notes`(`rows '<severity>' page N: ...`)。
  - **垃圾列與穩定讀取(#138 F1)**:實測 2026-11-06,4026 zh-TW VS2022(真機報告 pr138-e026472 F1)。scope 剛切回 `整個方案` 時，讀到一列 `project` / `file` / `line` 全是 null 的列，它的 description 是整列的 accessible name(`<訊息> : 警告. 專案: AxisInterface. 檔案: AxisInterface.plcproj. 行: 1`),看起來是格子還沒 realize。這一列被算進列數：第一次讀到 22/25,其實只有 21 條真的;第二次讀到 26/25 卻回 success。如果剛好漏一條、又多一條垃圾，數量就對上了(fail open)。現在的處理:
    - **垃圾列不算**:description 是空的，或沒有 project / file / line / code、而且 description 帶著那段 accessible-name 尾巴(`: 警告. 專案:`;英文 `: Warning. Project:` 是推論、未實測)的列，不算進列數，數量記在 `data.notes` 的 `junkRows`。沒有位置但 description 是一般文字的列(XAE 的 build-summary 列)仍是真的列，因為它也算在按鈕總數裡。
    - **穩定讀取**:切換過 scope、或這次讀到垃圾列時，同一個 severity 隔一個 settle 間隔(150 ms)再讀，要**連續兩次列數相同、而且等於按鈕總數**才採用;最多讀 4 次、最多 10 s。做不到就把該 severity 列為 unstable(`data.missingRows[].unstable = true`),結果是 `ERRORLIST_INCOMPLETE`,即使最後一次剛好對上。每次讀到的列數記在 `data.notes`(`stability reads: ...`)。每次都讀到 0 列、但總數 > 0 時，不標 unstable(列數沒有在跳),notes 寫 `no rows read`,`data.missingRows[].noRows = true`;結果一樣是 `ERRORLIST_INCOMPLETE`(#138 O5)。
    - **「切不回」只有 unit 覆蓋**:`scope.entire = false` 的情境在真機做不出來(4026 zh-TW 和 4024 英文都能自動切回)。
- **`Get-TcBuildErrors` 為什麼 fail closed**:總數 > 讀到的列，代表有列沒讀到，沒讀到的可能是 error。如果回 `success` 再加 note,呼叫端仍會把它當成 0 errors(`CODING_STANDARDS.md` §2,#68)。
- **Build / CheckAllObjects / Clean 怎麼處理(#138)**:它們用 `Get-TcErrorListReadState` 判斷 **error 列**完不完整，讀到的列一律保留:BUILD_FAILED 時 `codeErrors` / `errorItems` 仍列出讀到的部分。
  - 下列任一情況,`errorListError = ERRORLIST_INCOMPLETE`、`codeVerified = null`、`CODE_NOT_VERIFIED`、`completeBuild = false`,`Enable-TcConfig` 會回 `BUILD_REQUIRED`,下一步提示指向這一節:
    - errors 少讀;
    - severity 無法隔離、比的是 `total`;
    - Errors 總數讀不到;
    - `scope.entire = false` **而且**有列數對不上。
  - **只有 warnings 少讀**:不擋，見 `WARNINGS_INCOMPLETE`。
  - **`scope.entire = false` 但每個總數都對得上**:只有至少一個 severity 按鈕是 `X / Y` / `X of Y` 兩個數字的格式時(`data.countsTotalForm = true`,Y 是總數)才降成 `data.errorListNote`、不擋;按鈕都是單一數字(`9 Errors`、`3 個錯誤`)時，那個數字可能只是篩過的清單的數量，對得上也證明不了什麼，維持不完整(`codeVerified = null`,fail closed,#138)。
  - `Build-TcProject` 的 data 會帶 `errorListScope`、`missingRows` 與 `errorListNote`。
- **下一步**:
  1. 在 XAE 的 Error List 把 scope 下拉選成 `整個方案`(Entire Solution)、Errors / Warnings / Messages 三個按鈕都按下、清空 Error List 的搜尋框，再重跑 `Get-TcBuildErrors`;要解除 `BUILD_REQUIRED` 就重跑 `Build-TcProject`。
  2. 仍是本 code 時，看 `data.notes`(`scope: ...`、`buttons: ...`、`rows ... page ...`)與 `data.missingRows`,附在 issue 裡。不要把部分清單當成結果。

### WARNINGS_INCOMPLETE

- **現象**:`Build-TcProject` 回 success,`data.warningCodes` 含 `WARNINGS_INCOMPLETE`;`Test-TcPlcProject`(CheckAllObjects)沒有 warningCodes,只在 `data.warningTexts` 加一筆帶 `(WARNINGS_INCOMPLETE)` 的說明。`data.missingRows` 只列出 `warnings`(或 `messages`),`data.errorListNote` 寫著讀到幾列、總數幾列。
- **為什麼(#138)**:Error List 的 error 列完整(Errors 總數對得上，可隔離 severity),只有 warnings 讀得比按鈕總數少。`data.warningItems` 因此不是整份清單，但程式碼有沒有編譯是看 error 列，所以不影響 `codeVerified` / `completeBuild`,也不會留下 `BUILD_REQUIRED`。`Get-TcBuildErrors` 本身遇到同樣情況仍回 `ERRORLIST_INCOMPLETE`。
- **下一步**:需要完整的 warning 清單時，照 `ERRORLIST_INCOMPLETE` 的下一步(scope 切 `整個方案`、清空搜尋框)後重跑 `Get-TcBuildErrors`。

### PROJECT_LOAD_ERRORS

- **現象(#275)**:`Build-TcProject` 回 `success: false`、`error.code = PROJECT_LOAD_ERRORS`,`data.buildSucceeded = true`(build 本身沒失敗,build pane 是 `0 errors`)、`codeVerified = false`、`completeBuild = false`;`data.loadErrorItems[]` / `data.loadErrorFiles[]` 列出 XAE 載入失敗的列與檔案。`Test-TcPlcProject`(MCP `CheckAllObjects`)在 `CheckAllObjects()` 回 True 但有這種列時同樣回 `PROJECT_LOAD_ERRORS`,`data.passed = false`、`data.checkReturned = true`、`data.errorItems = data.loadErrorItems`。
- **為什麼**:PLC 物件檔在磁碟上被改壞(根元素改名、缺 `<Declaration>`、`Id` 格式錯、同一 POU 內子物件 GUID 重複…),XAE 載入時在 Error List 寫一條 Error,物件在樹上變成 itemType 0(無法編輯、不會被編譯)。物件沒被引用時編譯器不需要它,`LastBuildInfo` = 0、pane `0 errors`,以前 `Build-TcProject` 就回 success / `codeVerified` / `completeBuild` = true 但 `data.errors > 0`,`Test-TcPlcProject` 把列歸成 `staleErrorItems` 並 `passed: true`。**實測 2026-11-13**(VS2022 17.14 zh-TW + XAE 3.1.4026.22,registered tcauto master,`Verify-4026-axis` 的副本,三個沒被引用的 FB 由 `AddPou` 建立後在磁碟改壞,`ResetSolution` → `BuildProject` / `CheckAllObjects`):四條列全部 `severity Error`、`code null`、`file = FB_xxx.TcPOU`(只有檔名，沒有 `@<member>` / ` (Impl)`)、`line 1`,例如 `Parts of the XML data do not conform to the schema:`、`Tag 'Declaration' is missing in '...\FB_B275B.TcPOU' at line 7.`。把檔案還原、`ResetSolution` 重新載入後(還沒 build)Error List 就是 0 errors:這些列是**目前**的載入錯誤，不是上一次 build 的殘留。完整案例表:PR #276 `openspec/changes/add-semantic-linter/verification/xae-corrupt-file-behavior.md`。
- **判定規則**(`Test-TcProjectLoadErrorItem`):Error 等級、沒有編譯碼(`code` 空)、File 欄是單純的專案檔名(`.Tc<種類>` 如 `.TcPOU` / `.TcDUT` / `.TcGVL` / `.TcIO`,或 `.plcproj` / `.tsproj` / `.xti`),沒有 `@` 和括號。編譯器的列都有 `C0xxx` 和 `File.TcPOU@Member (Impl)` / `File.TcPOU (Impl)`;編譯碼沒讀到的編譯器列仍有 ` (Impl)` / ` (Decl)`,不會被當成載入錯誤。沒有 file 也沒有 code 的舊列(`Test-TcPlcProject` 的 `staleErrorItems`,例如 `'TwinCAT Measurement' ... Error creating Archive`)、Library Manager 列、warning 都不算。
- **與其他碼並存**:有編譯錯(`LastBuildInfo` > 0)時照舊是 `BUILD_FAILED`,`data.loadErrorItems` 一樣列出;有 library 錯誤時先回 `LIBRARY_UNRESOLVED`。`LastBuildInfo` 讀不到、由 Error List 判定時，載入錯誤列(line 1)不算編譯錯，結果仍是 `PROJECT_LOAD_ERRORS`。這次 build 記下 BUILD_REQUIRED(unverified-build),`Enable-TcConfig` / `Enter-TcPlcOnline` 會拒絕。
- **下一步**:從版本控制還原 `data.loadErrorFiles` 的檔案或修正其 XML(和版本控制比對找出被改壞的地方),改完磁碟檔後 `Reset-TcSolution` 重新載入，再 `Build-TcProject`。**不要**把這些列當成殘留而忽略、也不要繞過去直接 Activate(fail closed,#68)。

### STATIC_ANALYSIS_ERRORS

- **現象(#275 c)**:`Build-TcProject` 回 success,`data.warningCodes` 含 `STATIC_ANALYSIS_ERRORS`,`data.staticAnalysisItems[]` 是 code `SA<nnnn>` 的 Error 列;`codeVerified` / `completeBuild` 不受影響。
- **為什麼**:TE1200 Static Analysis Light 在編譯成功後才跑，違規以 Error 列進 Error List,但不讓 build 失敗([InfoSys: Static Analysis Light](https://infosys.beckhoff.com/content/1033/tc3_plc_intro/2527107467.html);實測 2026-11-13 PR #276 `verification/te1200-light.md`:pane `0 errors`,Error List 192 條 SA0033 / SA0167)。
- **待決定**:要不要讓 SA Error 列算 build 失敗，由 owner 決定(#275 PR);目前只是 warning。要處理就依 `data.staticAnalysisItems` 的 file / line 修改，或在 PLC 專案屬性 Static Analysis 關掉該規則。

### SOLUTION_CLOSE_FAILED / NO_SOLUTION

- **現象**:`Reset-TcSolution` 回 `SOLUTION_CLOSE_FAILED`(`Solution.Close` COM 呼叫失敗;被 dialog 擋住時是 `IDE_MODAL_DIALOG` / `IDE_BUSY`)或 `NO_SOLUTION`(沒有開啟的 solution、也沒給 `-SolutionPath`)。
- **下一步**:`Get-TcIdeModalDialog` 看有沒有 dialog;`NO_SOLUTION` 就 `Connect-TcIde -SolutionPath <sln>`。關掉之後重開失敗時,結果保留 `Connect-TcIde` 的 code / hint,`data.closed = true` 表示 solution 已關、要自己重連。

### LIBRARY_ADD_FAILED

- **做法(#80)**:`Add-TcLibrary` 對 `TIPC^<Plc>^<Plc> Project^References` 呼叫 `ITcPlcLibraryManager.AddLibrary(name, version, vendor)`(TE1000 v1.7.0 §6.5.14 "Managing PLC libraries and placeholders",p.241-243;§5.25.1.10 `AddLibrary`,p.118)。舊做法 `TIPC.Child(1).LookupChild('References')` + `CreateChild` 會回 `0x98510001`:在 4026 / 4024 副本上，連 `LookupChild('References')` 這一步就丟 `0x98510001`,因為 References 在 `<Plc> Project` 底下，不在 `<Plc>` 底下(實測 2026-10-28,4026 VS2022)。
- **沒安裝(`data.notInstalled = true`)**:AddLibrary 丟 `TSM_E_ITEMNOTFOUND`(手冊 §5.25.1.10:"Managed/default library not found"),實測為 `0x98510001` `"Managed Library '<name>, * (Beckhoff Automation GmbH)' not found!"`。模組不存檔,`.plcproj` 不變(4024 / 4026 都用 SHA256 確認，實測 2026-10-28),也不記 BUILD_REQUIRED。下一步：在 XAE 的 PLC > Library Repository 安裝該 library(或用 TwinCAT Package Manager 裝對應套件),確認名稱 / 版本 / 廠商，再重跑。
- **已有同名 reference**:不是錯誤。模組先讀 `ITcPlcLibraryManager.References` 的 `Name`(§5.25.1 p.113、§5.24.1 p.112;placeholder 列成 `#<name>`,實測),有 `<Name>` 或 `#<Name>` 就不呼叫 AddLibrary,回 success、`data.alreadyPresent = true`、`data.existingReference`,仍會存檔並讀回 `.plcproj` 驗證，不記 BUILD_REQUIRED。直接對已有的 library 呼叫 AddLibrary 會丟 `ArgumentException` `0x80070057` `"Managed Library '...' already contained!"`(手冊:"Library or placeholder is already included";實測 2026-10-28,4026),這個例外也對應成同樣的 alreadyPresent 結果。
- **其他失敗**:`LIBRARY_ADD_FAILED` 加原始訊息;保守起見記 BUILD_REQUIRED(`[failed after AddLibrary]`)。
- **`-Version '*'`**:預設值,`.plcproj` 寫成 `<LibraryReference Include="<name>,newest,<vendor>">`(實測 2026-10-28,4024 / 4026)。多個 PLC project 時要給 `-PlcProjectPath`,否則 `PLC_PROJECT_AMBIGUOUS`。

### Library Manager(task 3.1):做法與共同規則

- **做法**:`Get-TcLibraries`、`Add-TcLibraryPlaceholder`、`Remove-TcLibraryReference`、`Install-TcLibrary`、`Uninstall-TcLibrary`、`Lock-TcLibraryPlaceholder` 都在 `TIPC^<Plc>^<Plc> Project^References` 上呼叫 `ITcPlcLibraryManager`(TE1000 v1.7.0 §5.25.1 p.113-119、§6.5.14 p.241-244,和 `Add-TcLibrary` 同一個節點)。行為依據：實測 2026-10-31 4026 VS2022 XAE 3.1.4026.18(自建 client,`openspec/changes/complete-automation-interface/verification/phase2-probe.md` 3.1);registered tcauto 還沒驗證(task 3.8)。
- **placeholder 的欄位**:References 裡 placeholder 的 `Name` 帶 `#`,`LibraryName` / `Version` / `Distributor` 讀到空字串，模組改讀 `PlaceholderName` 和 `EffectiveResolution`(沒有時讀 `DefaultResolution`;visu placeholder 沒有 `EffectiveResolution`)。
- **frozen 只看得到 .plcproj**:`FreezePlaceholder` 只把 `.plcproj` 的 `<PlaceholderResolution><Resolution>` 從 `<lib>, * (...)` 改成實際版本，References 物件前後看起來一樣(實測 2026-10-31)。所以 `Get-TcLibraries` 的 `frozen` 與 `Lock-TcLibraryPlaceholder` 的讀回都讀**磁碟上**的 .plcproj(Lock 會先存專案)。
- **dry-run 與備份**:`Remove-TcLibraryReference`、`Install-TcLibrary`、`Uninstall-TcLibrary`、`Lock-TcLibraryPlaceholder` 預設 `DryRun=$true`,不呼叫任何寫入 API。改專案的兩個(Remove / Lock)實寫前把磁碟上的 .plcproj 複製到 `<sln 目錄>\.tcauto-backup\<時間>\`(`data.backupFiles[0]` 是原檔複本，關掉 solution 後覆蓋回去即可還原);只在 XAE 記憶體裡、還沒存的改動不在備份裡。Install / Uninstall 改的是整台機器的 library repository,不記 `BUILD_REQUIRED`;Install 不覆蓋所以不備份,Uninstall 實寫前把該版本的 repository 目錄整個複製到 `<sln 目錄>\.tcauto-backup\<時間>\library-repo\<name>\<version>\`(`data.backupPath`;還原：關掉 XAE 後把目錄複製回 `data.repositoryFolder`,XAE 不重新掃描能不能認得未實測，或用 `Install-TcLibrary` 安裝原始 .library)。目錄位置：先用 `ITcPlcLibraryManager.Repositories` 裡同名 repository 的 Folder(TE1000 §5.22 / §5.23;probe 時回 Count=0),`System` 再用實測路徑 `C:\ProgramData\Beckhoff\TwinCAT\PlcEngineering\Managed Libraries\<Distributor>\<Library>\<Version>`(實測 2026-10-31 4026 VS2022)。
- **共同防護**:每個寫入呼叫前查 modal dialog(`IDE_MODAL_DIALOG`);`IDE_*` 與 `PLC_LOGGED_IN` 照原碼回傳;改專案的三個(AddPlaceholder / Remove / Lock)和 `Add-TcPouMember` 一致：寫入 API 一呼叫就記 `BUILD_REQUIRED`(code-changed),成功、讀回不符、XAE 回錯(含 not found / 已存在)都記;呼叫之前就擋下的不記。錯誤訊息只比對完整的實測訊息(例如 `Specified library '...' not found!`),不用 `not found` 之類的片段。讀 .plcproj 一律用不處理 DTD 的 XmlReader(`Read-TcXmlFile`,含 DOCTYPE 的檔案直接讀失敗)。

### LIBRARY_READ_FAILED

- **現象**:`Get-TcLibraries` 讀 `References` 或 `ScanLibraries()` 時 COM 例外，什麼都沒改。.plcproj 找不到 / 讀不到不算失敗：仍回 success,`frozen = null`、`data.warnings` 寫原因。
- **下一步**:`Get-TcIdeModalDialog` 檢查 dialog;多個 PLC project 時加 `-PlcProjectPath`;再重跑 `Get-TcLibraries`。

### LIBRARY_INVALID_ARGUMENT

- **現象**:Library Manager cmdlet 在呼叫 XAE 之前就擋下，什麼都沒改。`data.reason`:`name` / `empty`(名稱空白)、`no-library-name`(`Add-TcLibraryPlaceholder` 給了 `-Version` / `-Distributor` 卻沒給 `-LibraryName`)、`ambiguous`(同名的 library 和 placeholder 同時存在，沒給 `#` 也沒給 `-Kind`)、`ambiguous-library-not-measured`(兩者並存時給了 `-Kind Library`:這時 `RemoveReference('<name>')` 會刪哪一個沒實測，所以不呼叫)、`kind-conflict`(`-Name '#x'` 又給 `-Kind Library`)、`not-placeholder`(`Lock-TcLibraryPlaceholder` 指到 library)、`target`(`-Placeholder` 與 `-All` 都給或都沒給)、`implicit-placeholder`(`-Placeholder` 指到 .plcproj 沒有 `<PlaceholderReference>` 的隱含 placeholder,XAE 不會寫它的 Resolution,實寫前就擋、不記 BUILD_REQUIRED;dry-run 給 warning)、`wildcard`(`Uninstall-TcLibrary` 的值含 `* ? [ ]`)、`path` / `extension` / `missing` / `repository`(`Install-TcLibrary` 的檔案或 repository 名稱)。
- **下一步**:照 `error.hint` 修正參數;`ambiguous` 要移除 placeholder 就給 `-Name '#<name>'`(或 `-Kind Placeholder`,模組會傳 `#<name>` 給 RemoveReference,實測可刪 placeholder);`ambiguous-library-not-measured` 請使用者在 XAE 的 Library Manager 手動移除 library。

### LIBRARY_NOT_FOUND

- **現象**:`Remove-TcLibraryReference` / `Lock-TcLibraryPlaceholder` 要的名稱不在 References(`data.references` / `data.placeholders` 列出現有的),或 XAE 自己回 not found(RemoveReference 的 `0x98510001` "Specified library '...' not found!"、FreezePlaceholder 的 `0x80004005` "Placeholder '...' not found. Cannot freeze!",實測 2026-10-31)。什麼都沒改；XAE 回 not found 時已經呼叫過寫入 API,所以照共同規則記 `BUILD_REQUIRED`。
- **下一步**:`Get-TcLibraries` 看 `name` / `placeholderName`(placeholder 寫成 `#<name>` 或不帶 `#` 都可以),拼對後重跑。

### LIBRARY_VERIFY_FAILED

- **現象**:寫入呼叫有返回，但讀回不符，不能當成功。`data.step` / `data.reason`:`references`(References 讀回沒有新增 / 還留著)、`library`(placeholder 解析到別的 library)、`project-file`(存檔後磁碟上的 .plcproj 不符)、`not-frozen`(`<Resolution>` 還是 `*`,`data.notFrozen`)、`not-listed`(安裝後 ScanLibraries 沒有新項目)、`still-installed`(解除安裝後 ScanLibraries 裡完全符合的筆數沒有減少；同一版本裝在多個 repository 時，少一筆就算成功，剩下的寫在 `data.warnings`)。
- **下一步**:`Get-TcLibraries`(repository 的用 `-Repository`)看實際狀態;專案的改動要還原就用 `data.backupFiles`(Remove / Lock)。原因確認後再重跑同一個 cmdlet。

### LIBRARY_BACKUP_FAILED

- **現象**:`Remove-TcLibraryReference` / `Lock-TcLibraryPlaceholder` 實寫前的 .plcproj 備份沒寫成(solution 路徑不明、找不到 .plcproj,或 `.tcauto-backup` 不能寫),什麼都沒改。`Uninstall-TcLibrary`:repository 裡該版本的目錄推不出來(`data.repositoryFolder = null`,message 列出試過的路徑)、solution 路徑不明，或複製失敗 / 檔案數不符，沒有解除安裝。
- **下一步**:`Connect-TcIde -SolutionPath <sln>`(或 `Open-TcProject`)讓模組知道 solution;先用預設的 dry-run 看 `data.projectFile`(Uninstall 看 `data.repositoryFolder`)有值，再 `-DryRun $false`。Uninstall 的目錄推不出來時(repository 不是 `System`、或不在實測路徑),模組不解除安裝；請使用者在 XAE 的 Library Repository 手動處理。

### LIBRARY_REMOVE_FAILED

- **現象**:`RemoveReference` 丟了 not found 以外的例外(或之後的步驟失敗),reference 可能已經移除，所以保守記 `BUILD_REQUIRED`。
- **下一步**:`Get-TcLibraries` 確認;要還原用 `data.backupFiles`;`Get-TcIdeModalDialog` 檢查 dialog 後重跑。

### PLACEHOLDER_ADD_FAILED

- **現象**:`Add-TcLibraryPlaceholder` 失敗。`data.reason = default-library-not-installed`:預設 library 沒有安裝(COMException `0x98510001` "Default Library '...' not found!",沒有建出 placeholder,實測 2026-10-31);`no-device-placeholder`:沒給 `-LibraryName` 時 XAE 找不到同名的 device placeholder(ArgumentException `0x80070057` "Default Placeholder '...' could not be found!",手冊寫 E_INVALIDARG,實測同值)。兩種都已經呼叫過 AddPlaceholder,和 `Add-TcPouMember` 一致記 `BUILD_REQUIRED`。沒有 reason:其他 COM 例外，也記。
- **已存在不是錯誤**:References 已有 `#<name>`,或 XAE 回 "Placeholder '...' already contained!" → success、`data.alreadyPresent = true`,和 `Add-TcLibrary` 一致。這時 `data.libraryName` / `version` / `distributor` 是既有 placeholder 讀到的值(DefaultResolution,沒有時 EffectiveResolution),`data.requested` 是這次的參數;預設 library 和 `-LibraryName` 不同時加 warning,不會改它。
- **下一步**:`Get-TcLibraries -Repository` 確認名稱 / 版本 / distributor,沒裝就 `Install-TcLibrary`;沒有 device placeholder 就給 `-LibraryName`。

### PLACEHOLDER_FREEZE_FAILED

- **現象**:`FreezePlaceholder` 丟了 not found 以外的例外。手冊(TE1000 p.244;InfoSys [FreezePlaceholder](https://infosys.beckhoff.com/content/1033/tc3_automationinterface/21841158667.html))寫 placeholder 沒有 EffectiveResolution 時回 E_FAIL(`Error_PlaceholderNotResoluted_CannotFreeze`);但實測(2026-10-31,4026 VS2022,registered tcauto,`verification/phase2-3.8.md` P2)`-All` 沒有丟例外，反而把沒有 EffectiveResolution 的 visu placeholder 凍結在 DefaultResolution 的版本。`-All` 時這類 placeholder 不做版本比對(`data.skipped[]` reason `no-effective-resolution`,也列在 `data.skippedUnresolved`);`.plcproj` 沒有 `<PlaceholderReference>` 的隱含 placeholder(例如 `Tc3_GlobalTypes`,XAE 不寫它的 Resolution)也跳過(reason `implicit`),不算 `notFrozen`。error.message 會列出沒有 EffectiveResolution 的 placeholder;`data.restore` 寫還原方式。
- **下一步**:`Get-TcLibraries` 看 `effectiveResolution`,是 null 的先讓它解析得到(安裝 library),或改用 `-Placeholder` 只鎖其他的;要還原就照 `data.restore`:把 `data.backupFiles` 的 `.plcproj` 複製回 `data.projectFile`,再 `Reset-TcSolution`。

### LIBRARY_VERSION_CHANGED

- **現象**:`Lock-TcLibraryPlaceholder` 凍結後，至少一個 placeholder 的 `<Resolution>`(library、版本、distributor)和呼叫前的 EffectiveResolution 不同。實測(2026-10-31,registered tcauto,`verification/phase2-3.8.md` P2):`FreezePlaceholder('')` 把每個 placeholder 凍結在 **DefaultResolution**,不是凍結前的 effective 版本(4026 `#Tc2_System` 3.10.1.0 → 3.9.1.0、`#CBML` 4.0.0.0 (CODESYS) → 3.5.13.0;4024 `VisuDialogs` 3.5.12.0 → 4.8.0.0),和手冊「凍結目前的 EffectiveResolution」不符。模組先對變動的 placeholder 呼叫 `SetEffectiveResolution(placeholder, library, version, distributor)`(InfoSys [SetEffectiveResolution](https://infosys.beckhoff.com/content/1033/tc3_automationinterface/21841216267.html);2026-11-01 registered tcauto 重測：4026 VS2022 釘回 `CBML`、`Tc2_System`,4024 XAE 釘回 `VisuDialogs`,讀回 `<Resolution>` 是凍結前的 effective 版本，`phase2-3.8-retest.md`)釘回原版本、再存檔讀回;仍不同(或 SetEffectiveResolution 丟例外，`pinError`)才回這個碼。比對對象：這次鎖的 placeholder 比凍結前的 EffectiveResolution;**每一個**凍結前就有固定 `<Resolution>` 的 placeholder(包括 `-All` 跳過的、`-Placeholder` 沒指名的)比它原本的 `<Resolution>`(`comparedWith` = `effective` / `resolution-before`)。專案**已經改了並存檔**:`data.versionChanges[]`(placeholder / before / after / comparedWith / pinCalled / pinError)、`data.changed[]`(和備份比，`<Resolution>` 有變的全部 placeholder)、`data.backupFiles`、`data.restore`。dry-run 的 `data.targets[].willFreezeTo` / `versionWillChange` 只是部分預告：只有 `-All` 且 DefaultResolution 有明確版本時才給值(willFreezeTo = 那個版本);DefaultResolution 是 `*` 或沒有、以及單一 `-Placeholder` 時都是 `null`(不知道。2026-11-01 重測：`All` 時 `* (3S)` / `* (System)` 的 `CBML`、`VisuDialogs` 舊預告 false 但實際變了;單一 `Tc2_System` 舊預告 true 但沒變，`phase2-3.8-retest.md` N5)。dry-run 一律加一條 warning:實寫會逐一比對並用 SetEffectiveResolution 釘回。
- **其他失敗也帶同樣的欄位**:呼叫 FreezePlaceholder 之後的每一種失敗(`LIBRARY_VERIFY_FAILED` not-frozen、`PLACEHOLDER_FREEZE_FAILED`、存檔失敗、例外)都有 `data.changed[]`、`data.restore`、`data.backupFiles`;not-frozen 同時有版本變動時也有 `data.versionChanges[]`。成功時也有 `data.changed[]`。
- **下一步**:照 `data.restore`:把 `data.backupFiles` 的 `.plcproj` 複製回 `data.projectFile`,再 `Reset-TcSolution`(見「磁碟改檔的正確做法」);`Get-TcLibraries` 確認 `effectiveResolution` 是 `before` 後 `Build-TcProject`。

### LIBRARY_ALREADY_INSTALLED

- **現象**:`Install-TcLibrary -DryRun $false` 什麼都沒裝:XAE 的 InstallLibrary 回 IOException `0x80131620` "Library already exists."(手冊寫會取消安裝，實際是丟例外，實測 2026-10-31 4026 VS2022 自建 client),`data.preCheck = xae`。模組一律 `bOverwrite = false`。
- **檔名只在 dry-run 參考**:Automation Interface 沒有從 .library 檔讀出名稱 / 版本的方法。dry-run 時，檔名 `<name>_<version>.library`(XAE SaveAsLibrary 產生的格式，實測 2026-10-31)在 ScanLibraries 有同名同版本，就回 `alreadyInstalled = true`、`data.installed` 加 warning;實寫時不拿檔名擋(檔案可能是另一個 distributor 的同名 library),交給 XAE 判斷。
- **下一步**:直接 `Add-TcLibrary` / `Add-TcLibraryPlaceholder` 把它加進專案;真的要換成新檔，先 `Uninstall-TcLibrary`(先 dry-run)再 `Install-TcLibrary`。

### LIBRARY_NOT_INSTALLED

- **現象**:`Uninstall-TcLibrary` 什麼都沒移除:ScanLibraries 沒有和 `-LibraryName` / `-Version` / `-Distributor` 完全相同(大小寫也要相同)的項目;`data.candidates` 列出同名(不分大小寫)的已安裝版本。
- **為什麼先查**:XAE 的 `UninstallLibrary` 遇到不存在的 library / 版本丟 NullReferenceException `0x80004003`(實測 2026-10-31),分不出是「不存在」還是別的錯誤。
- **下一步**:`Get-TcLibraries -Repository -Filter <name>` 查正確的值後重跑。

### LIBRARY_INSTALL_FAILED / LIBRARY_UNINSTALL_FAILED

- **現象**:`InstallLibrary` / `UninstallLibrary` 丟例外。`data.reason = null-reference`(Uninstall):XAE 丟 NullReferenceException,實測是「該 repository 裡沒有這個版本」時的錯誤；模組先用 ScanLibraries 確認過存在，所以多半是它裝在別的 repository。`data.reason = repository-not-found`:`-Repository` 不存在(COMException `0x98510001` "Could not find repository '...'",實測 2026-10-31 InstallLibrary;預設 repository 名稱 `System`,TE1000 §6.5.12)。`Install-TcLibrary` 的 dry-run 先查 repository(`verification/phase2-3.8.md` P8,`data.repositoryCheck` 的 `state` / `readable` / `listed`):`System` 或 `ITcPlcLibraryManager.Repositories` 有列出 → `known`;`Repositories` 有列出別的、沒有這個名稱 → 回這個碼與 reason(`not-found`,和實寫一樣);`Repositories` 一個都沒列(4026 實測 2026-10-31 列出 0 個)或讀不到 → `not-verified`,dry-run 仍 success 並加 warning,實寫時由 XAE 判斷。ScanLibraries 不回報每筆在哪個 repository,所以 `Uninstall-TcLibrary` 的預查證明不了它在 `-Repository` 裡;這時 XAE 可能丟 NullReferenceException。
- **下一步**:`Get-TcLibraries -Repository` 確認狀態,`Get-TcIdeModalDialog` 檢查 dialog,改正 `-Repository` 後重跑。

### CheckAllObjects(task 3.7):做法與 Build 的差別

- **做法**:`Test-TcPlcProject`(MCP `CheckAllObjects`)在 `TIPC^<Plc>^<Plc> Project` 上 late-bind 呼叫 `ITcPlcIECProject2.CheckAllObjects()`(TE1000 v1.7.0 §5.28.2 p.123-124、§6.5.7 p.233-234),呼叫前先查 modal dialog,之後讀 Error List(和 `Build-TcProject` 共用 `Get-TcErrorListSummary`,`errorItems` 每筆一樣是 `severity / code / description / project / file / line / column / category`)。PLC root `TIPC^<Plc>` 沒有這個方法，只有 `<Plc> Project` 有(實測 2026-10-31 4026 VS2022,自建 client,`openspec/changes/complete-automation-interface/verification/phase2-probe.md` 3.7)。
- **和 Build 的差別**:`Build-TcProject` 只編譯有被引用的物件。沒被引用的 FB 的 method 寫了語法錯(`M_Two := ;`)時，Build 回 success、errors 0;CheckAllObjects 回 `False`,Error List 有 `C0007 Expression expected instead of ';'`(file `FB_P2Probe.TcPOU@M_Two (Impl)`,line 1)(實測 2026-10-31 4026 VS2022,自建 client)。InfoSys 的 PLC 指令 "Check all objects" 也說它檢查所有物件、不產生 code:<https://infosys.beckhoff.com/content/1033/tc3_plc_intro/2531345035.html>。
- **不碰 BUILD_REQUIRED**:不產生 code、不改檔(實測 2026-10-31:呼叫前後 solution 目錄沒有任何檔案變動，含 `_Boot`、`_CompileInfo`),所以既不記也不清 `BUILD_REQUIRED`。成功也不能取代 `Build-TcProject`:`Enable-TcConfig` / `Enter-TcPlcOnline` 之前還是要完整 build。
- **Error List 的舊項目**:沒有 file、也沒有 code 的錯誤列會一直留在 Error List(實測 2026-10-31 4026 VS2022 XAE 3.1.4026.18,自建 client:失敗的 archive 留下 `'TwinCAT Measurement' ... Error creating Archive`),不算這次檢查的結果，放在 `data.staleErrorItems`。判斷條件是 **category 為 `other`(沒有 file)而且 code 是空的**;有 code 但沒有 file 的列仍算這次的錯誤，留在 `data.errorItems`。回 `True` 時 `data.errorItems` 一律是空陣列,Error List 上的錯誤列都放 `staleErrorItems` 並加 warning;warning 列照樣在 `data.warningItems` / `codeWarnings`。
- **沒有 deadline**:CheckAllObjects 是同步呼叫，模組只在呼叫前排除 dialog;probe 每次都在 0.7-2.2 s 內返回(實測 2026-10-31)。MCP tool 的 timeout 是 600 s。

### CHECK_FAILED

- **現象**:`CheckAllObjects()` 回 `False`(`data.passed = false`;語法錯是回 False,不是例外，實測 2026-10-31 4026 VS2022),`data.errorItems` 是 Error List 上除了舊項目(沒有 file 也沒有 code)以外的錯誤列(`codeErrors` / `libraryErrorItems` 分開列),message 列前三筆。`data.passed = null` 加 `data.callError`:CheckAllObjects 丟了例外(手冊 §5.28.2 列 `E_FAIL` `Error_CheckAllObjectsFailed`,probe 沒遇到)或沒回 bool。Error List 讀不到時 `data.errorListError` 有值,message 會寫。
- **下一步**:依 `data.errorItems` 的 file / line 用 `Get-TcPouCode -PouPath` 讀、`Write-TcPouCode -PouPath` 改，再重跑 `Test-TcPlcProject`;`errorItems` 是空的就用 `Get-TcBuildErrors` 讀 Error List。file 是 `<task>.TcTTO`、line 0 的列(`C0046` / `C0035` / `C0080` / `C0036`)代表 task 呼叫了不存在或不是 PROGRAM 的物件(實測 2026-10-31,`phase2-probe.md` 3.5),用 `Remove-TcTaskProgram -ProgramName <名稱> -PlcTask <task> -DryRun $false` 拿掉。

### CHECK_UNAVAILABLE

- **現象**:`<Plc> Project` 節點沒有 `CheckAllObjects` 方法(`ITcPlcIECProject2` 不可用;PowerShell 丟 `MethodNotFound`,英文 PowerShell 的訊息是 "does not contain a method named 'CheckAllObjects'",zh-TW 等語系的訊息不同，所以模組看 `FullyQualifiedErrorId = MethodNotFound`,不比對訊息文字)。4024 是否支援還沒實測(task 3.8)。
- **下一步**:改用 `Build-TcProject`(只編譯有被引用的物件)。

### PLC task 與 program 連結(task 3.5):做法與共同規則

- **做法**:`Add-TcPlcTask`(MCP `AddPlcTask`)、`Add-TcTaskProgram`(`LinkProgramToTask`)、`Remove-TcTaskProgram`(`UnlinkProgramFromTask`)都由通用 tree cmdlet 組成(`New-TcTreeItem`、`Set-TcTreeItemXml`、`Remove-TcTreeItem`),沿用它們的備份、modal dialog 檢查與讀回。三個都預設 `DryRun=$true`。行為依據：實測 2026-10-31 4026 VS2022 XAE 3.1.4026.18(自建 client,`openspec/changes/complete-automation-interface/verification/phase2-probe.md` 3.5);registered tcauto 還沒驗證(task 3.8),4024 沒測過。
- **新增 PLC task 要兩個物件**:先 `TIRT` 底下 CreateChild SubType 1(沒有 process image,TE1000 v1.7.0 §6.3.1 p.196),用 ConsumeXml 設 `TaskDef/CycleTime`(單位 100 ns,所以是 `CycleTimeUs * 10`;實測 2026-10-30 task 2.1)和 `Priority`,再在 `<Plc> Project` 底下用**同名** CreateChild 621。XAE 會自己把 `LinkedTask` 接到 `TIRT^<Name>`,並寫出 `<Name>.TcTTO`;TIRT 沒有同名 task 時 XAE 回 E_FAIL "No task '<Name>' found in Realtime-Settings!"(實測)。讀回檢查 TIRT task 的 CycleTime / Priority、PLC task 的 ItemType 621 與 `PlcTaskDef/LinkedTask`。
- **要存檔**(和 `Add-TcPou` 的 #76 一樣):CreateChild 621 當下只寫出 `<Name>.TcTTO`,`.tsproj` 的 TIRT task 和 `.plcproj` 的 `<Compile Include="<Name>.TcTTO">` 要 Project.Save 才會寫;沒存時 `Reset-TcSolution`(預設與 `-SaveProjectChanges`)都讓 task 消失(實測 2026-10-31 4026 VS2022,registered tcauto,`verification/phase2-3.8.md` P4)。所以 `Add-TcPlcTask` 讀回後存檔，從磁碟讀回 `.plcproj` 有 `<Name>.TcTTO`、`.tsproj` 有 `<Task><Name><Name></Name>` 才 success(`data.projectSaved`);存檔失敗回 `PROJECT_SAVE_FAILED` 等(物件留在 XAE 記憶體，同 `Add-TcPou`),`.tsproj` 沒有 task 回 `TASK_VERIFY_FAILED`(step `save-verify`)。`Add-TcTaskProgram` / `Remove-TcTaskProgram` 不需要存檔:650 的 CreateChild / DeleteChild 當下就改寫磁碟上的 `<task>.TcTTO`(實測 2026-10-31,`phase2-probe.md` 3.5)。
- **不留半套**:任何一步失敗(或讀回不符、或中途丟例外)就把這次建出來的物件刪掉，路徑優先用通用 cmdlet 回報的 `data.createdPath`(XAE 改了名字時才刪得到),先 PLC task 再 TIRT task,`Remove-TcTreeItem -AllowNoExport`(是剛建的物件)。PLC task 刪不掉時**不刪** TIRT task(PLC task 還連著它),那一筆標 `SKIPPED_DEPENDENT`,message 會寫「先刪 PLC task」。結果寫在 `data.rollback[]` / `data.rolledBack`,`data.steps` 列出每一步(例外路徑也有)。CreateChild 回來的名稱和 `-Name` 不同(大小寫也算)也算失敗。
- **650 XAE 完全不驗證**:在 PLC task 底下 CreateChild 650 時，同名第二次、大小寫不同、不存在的名稱、FB、GVL XAE 全部照收，當下就寫進 `<task>.TcTTO`,要到 CheckAllObjects / Build 才報 `C0046` / `C0035` / `C0080` / `C0036`(實測 2026-10-31)。所以 `Add-TcTaskProgram` 自己先檢查：用 `Resolve-TcPouPath` 找到物件、`Get-TcPlcObjectKind` 確認 ItemType 602(PROGRAM)、名稱大小寫完全相同、task 底下還沒有同名的呼叫。
- **備份**:`<Plc> Project^<task>`(621)的磁碟檔是 `<task>.TcTTO`,寫入前複製到 `<sln 目錄>\.tcauto-backup\<時間>\`(`data.backupFiles` / `data.taskBackupFiles`)。`Remove-TcTaskProgram` 另外用 ExportChild 把那個 650 匯出成 `.zip`(`data.exportPath`;650 節點能不能匯出還沒實測)。匯出失敗但 `.TcTTO` 有備份時照樣刪，並加一條 warning 寫 `.TcTTO` 備份的路徑和還原步驟：把它複製回 task 的 `.TcTTO`,再 `Reset-TcSolution`(**未實測，待 3.8**);`Remove-TcTreeItem` 那句「只剩 ProduceXml 備份」的通用 warning 在這個情境會誤導，所以拿掉。兩種備份都沒有就不刪(`TREEITEM_BACKUP_FAILED`)。
- **BUILD_REQUIRED**:寫入 API(CreateChild / ConsumeXml / DeleteChild)一呼叫就記(code-changed),成功或失敗都記。判斷依據是通用 cmdlet 在呼叫前一刻設的 `data.writeCalled`;呼叫之前就擋下的(參數、modal dialog、備份失敗、DeleteChild 的 parent-mismatch、呼叫前丟的例外)不記。
- **CycleCount 要在線上驗**:不在 cmdlet 裡做。`Enable-TcConfig -Force` 之後，用 `Read-TcVariable` 讀 `TwinCAT_SystemInfoVarList._TaskInfo[n].TaskName` 找到 n,再讀兩次 `TwinCAT_SystemInfoVarList._TaskInfo[n].CycleCount`,數字要增加。n 是 PLC 自己的 task index(從 1 開始),不是 TIRT 底下的順序(InfoSys PlcTaskSystemInfo:<https://infosys.beckhoff.com/content/1033/tc3_plc_intro/714821259.html>)。`Add-TcPlcTask` 成功時 `data.verifyHint` 寫同一件事。陣列順序是不是等於 PLC project 裡 task 物件的順序還沒實測。

### TASK_ALREADY_EXISTS / TASK_ALREADY_EXISTS_TIRT

- **現象**:`Add-TcPlcTask` 的 `-Name` 已經是 `TIRT` 底下的 task 或 `<Plc> Project` 底下的物件(不分大小寫;`data.existingIn` = `TIRT` / `plc`),什麼都沒建。
- **下一步**:hint 依 `data.existingIn` 分兩種(`TASK_ALREADY_EXISTS_TIRT` 是只有 TIRT 時用的 hint key,錯誤碼仍是 `TASK_ALREADY_EXISTS`)。只有 `TIRT`:沒有可以沿用的 PLC task,換一個 `-Name` 重跑 `Add-TcPlcTask`。含 `plc`:要用那個 PLC task 就直接 `Add-TcTaskProgram -ProgramName <program> -PlcTask <Name>`,要新的 task 就換名稱。

### TASK_NOT_FOUND

- **現象**:`Add-TcTaskProgram` / `Remove-TcTaskProgram` 的 `-PlcTask` 不在 `<Plc> Project` 底下(`data.reason = not-found`),或那個節點不是 PLC task(ItemType 不是 621,`not-a-task`)。`data.plcTasks` 列出該 PLC project 的 PLC task。什麼都沒改。
- **下一步**:用 `data.plcTasks` 裡的名稱重跑;要新的 task 先 `Add-TcPlcTask -Name <Name> -CycleTimeUs <us> -DryRun $false`。

### TASK_PROGRAM_INVALID

- **現象**:`Add-TcTaskProgram` 在呼叫 XAE 之前擋下，什麼都沒連。`data.reason`:`not-found`(PLC project 裡沒有這個名稱的物件;只有 task 底下同名的 650 不算)、`not-a-program`(是 FB / FUNCTION / GVL 等，`data.objectKind`、`data.itemType`、`data.pouType`)、`case-mismatch`(有這個 PROGRAM,但大小寫不同，`data.actualName`)。XAE 自己不檢查，這些都會被寫進 `.TcTTO`,到 build 才報錯(見上面「做法」)。
- **下一步**:`not-found` 先 `Add-TcPou -Name <Name> -Type Program`;`not-a-program` 改給 PROGRAM;`case-mismatch` 改用 `-ProgramName <data.actualName>`。再重跑 `Add-TcTaskProgram`。

### TASK_PROGRAM_ALREADY_LINKED

- **現象**:task 底下已經有這個名稱的呼叫(不分大小寫，`data.existingLink`),什麼都沒連。XAE 會照收第二個，program 就每個 cycle 被呼叫兩次(實測 2026-10-31:沒有編譯錯誤)。
- **下一步**:不用再連;要換 task 先 `Remove-TcTaskProgram -ProgramName <data.existingLink> -PlcTask <舊 task> -DryRun $false`,再 `Add-TcTaskProgram -ProgramName <data.existingLink> -PlcTask <新 task>`。

### TASK_PROGRAM_NOT_LINKED

- **現象**:`Remove-TcTaskProgram` 在 task 底下找不到名稱完全相同(大小寫也要相同)的呼叫;`data.linkedPrograms` 列出現有的，`data.caseMatches` 列出只差大小寫的。什麼都沒刪。
- **下一步**:用 `data.linkedPrograms` 裡的名稱當 `-ProgramName` 重跑。

### TASK_CREATE_FAILED

- **現象**:`Add-TcPlcTask` 在 `data.step` 失敗:`tirt-create`(TIRT 底下 CreateChild)、`cycle-time`(ConsumeXml 或它的讀回)、`plc-create`(`<Plc> Project` 底下 CreateChild 621)。`data.stepError` 是那一步的原始錯誤，`data.steps` 是每一步的結果。已建的物件已回滾(`data.rollback[]`;`data.rolledBack = false` 表示有東西沒刪掉，message 會寫 `ROLLBACK INCOMPLETE`;PLC task 刪不掉時 TIRT task 標 `SKIPPED_DEPENDENT`,沒有刪)。IDE_* / PLC_LOGGED_IN 保留原碼，不用這個碼。
- **下一步**:`rolledBack = true`:排除 `stepError` 的原因後重跑 `Add-TcPlcTask`。`false`:**先刪 PLC task**(`data.rollback` 裡 removed = false、code 不是 `SKIPPED_DEPENDENT` 的 path),再刪 `SKIPPED_DEPENDENT` 的 TIRT task,都用 `Remove-TcTreeItem -Path <path> -ConfirmName <Name> -DryRun $false -AllowNoExport`,再重跑。

### TASK_VERIFY_FAILED / TASK_VERIFY_FAILED_DISK

- **save-verify 之後的回滾**(`TASK_VERIFY_FAILED_DISK` 是這種情況用的 hint key,錯誤碼仍是 `TASK_VERIFY_FAILED`):失敗前專案已存檔，磁碟上的 `.plcproj` 已列出 `<Name>.TcTTO`。回滾刪掉物件後模組再存一次檔，從磁碟讀回 `.plcproj` 確認已沒有 `<Name>.TcTTO`(`data.diskState`:plcproj、tcttoListed、saved、saveError)。存檔失敗或還列著 → `data.rolledBack = false`,hint 改成：先 `Get-TcProjectTree -PlcOnly` 確認 task 已不在，再 `Reset-TcSolution -SaveProjectChanges` 存回磁碟並確認 `.plcproj`。只有單元測試，未實測。`.tsproj` 用 `<Task File=...>` 把 task 存在獨立檔案時，模組從 `.tsproj` 資料夾或 `_Config` 底下找那個檔案讀回(位置規則未實測)。
- **現象**:`Add-TcPlcTask` 每一步都返回了，但讀回不符(`data.mismatches`:`TaskDef/CycleTime`、`TaskDef/Priority`、`PLC task ItemType`、`PlcTaskDef/LinkedTask`,或物件找不到;`data.step = save-verify`:專案已存檔，但磁碟上的 `.tsproj` 沒有 `<Task><Name><Name></Name>`,field `.tsproj TIRT task`)。已建的物件已回滾，同 `TASK_CREATE_FAILED`。
- **下一步**:先看 `data.mismatches`(field / expected / actual);要看完整 XML 用 `Get-TcTreeItemXml -Path <data.tirtTaskPath>` / `<data.plcTaskPath>`。`rolledBack = false` 時照 `TASK_CREATE_FAILED` 的順序(先 PLC task 再 TIRT task)刪掉留下的 path,再重跑 `Add-TcPlcTask`。

### PLCopen XML(task 3.3):做法與共同規則

- **做法**:`Export-TcPlcOpen`(MCP `ExportPlcOpen`)與 `Import-TcPlcOpen`(`ImportPlcOpen`)在 `<Plc> Project` 節點上呼叫 `PlcOpenExport(file, selection)` / `PlcOpenImport(file, option, '', $true)`(TE1000 v1.7.0 §5.20 p.105–108,範例 §6.5.4 p.228–229;`PLCIMPORTOPTIONS` §5.46.7 p.161:NONE 0、REPLACE 1、RENAME 2、SKIP 3)。行為依據：實測 2026-10-31 4026 VS2022 XAE 3.1.4026.18(自建 client,`openspec/changes/complete-automation-interface/verification/phase2-probe.md` 3.3);registered tcauto 還沒驗證(task 3.8),4024 沒測過。
- **selection 寫法**:每個 `-Selection` 元素是一個物件或資料夾，資料夾層級用 `.`(`POUs.FB_A`、`LIB.AxisControl.FB_AxisControl`,含空白的資料夾名稱可以),模組用 `;` 串起來交給 XAE;只給名稱(`FB_A`)XAE 也找得到;不給 selection = 整個 project。用 `^` 時 XAE 回 COMException `0x98510008` "Selection '...' not found!",所以模組先擋(`PLCOPEN_FAILED` reason `invalid-selection`)。
- **子物件不能單獨匯出**:method / property / action / accessor 單獨選時 XAE 回 ArgumentException "Couldn't create ExportObjects"。模組先用 `LookupTreeItem` / `Resolve-TcPouPath` 找到節點、看 ItemType(608–616、654、655),是子物件就回 `PLCOPEN_FAILED` reason `member-selection`,`data.memberSelection.suggestedSelection` 是所屬物件。PlcOpenExport 一定連子樹一起匯出(FB 含 method、property、action)。interface 的 property(沒有 Get / Set 時)不會被匯出，只有 method。
- **檔案已存在**:XAE 丟 ArgumentException "File '...' already exists!"(原檔不變)。模組先檢查：沒有 `-Overwrite` 回 `PLCOPEN_FILE_EXISTS`;有 `-Overwrite` 時先把舊檔改名成 `<檔名>.bak`(已存在就 `.bak-2`…,`data.previousFile`),匯出或讀回失敗時把新檔改名成 `<檔名>.failed`、舊檔改回原名(`data.restore`)。
- **Import 的四種 Option(實測)**:

  | Option | XAE 的行為 | 模組怎麼處理 |
  |---|---|---|
  | `None` | 有衝突就丟例外("Creation of object 'X' failed. Reason: Import conflict!"),什麼都沒匯入 | dry-run 的衝突檢查有衝突就回 `PLCOPEN_CONFLICT`,實寫時不呼叫 XAE |
  | `Skip` | 衝突的物件靜默跳過，不回報 | 匯入後 `data.skipped[]` 列出跳過的物件，並比對它們磁碟檔的 SHA-256(`unchanged`);有檔案變了 → `PLCOPEN_VERIFY_FAILED` reason `skip-changed` |
  | `Replace` | 整個物件覆蓋：檔案裡沒有的子物件會被刪掉(ITF 原本的 property 被刪) | dry-run 的 `data.willReplace[].deletedChildren` 列出會被刪的直接子物件;實寫前先把會被覆蓋的物件匯出成 PLCopen XML 備份，失敗就不匯入(`PLCOPEN_BACKUP_FAILED`);讀回 `data.replaced[].deletedChildren` |
  | `Rename` | 匯入的物件加 `_1` 後綴，原物件不變 | dry-run 預告 `<名稱>_1`(該名稱也存在時加 warning:實際名稱沒測過);讀回在新增的物件裡找 `<名稱>_<n>`(`data.renamed`) |

- **衝突怎麼判斷**:檔案用 `Read-TcXmlFile` 解析(不處理 DTD,防 XXE),列出 POU(`types/pous/pou`)、DUT(`types/dataTypes/dataType`)、ITF(`addData/data/Interface`)、GVL(`globalVars`);再走一次 `<Plc> Project` 和所有 PLC 資料夾，名稱相同(不分大小寫)就算衝突。同名物件在別的資料夾時 XAE 算不算衝突沒實測。超過 3000 個節點、或有節點讀不到時檢查不完整(`data.indexComplete = false`,`data.warnings` 會寫);這時 `-Option Replace -DryRun $false` 直接回 `PLCOPEN_BACKUP_FAILED` reason `index-incomplete`,不呼叫 PlcOpenImport(要備份的物件可能沒找齊),dry-run 也會加 warning。
- **REPLACE 的備份**:**必要**的是一份 PLCopen XML:用 `PlcOpenExport` 把所有會被覆蓋的物件匯出到 `<sln 目錄>\.tcauto-backup\<時間>\plcopen-replace.xml`(`data.backup.xmlPath`)。PlcOpenExport 會連子樹一起匯出，**例外是沒有 Get / Set 的 interface property,它不會被匯出**(實測 2026-10-31)。還原用 `Import-TcPlcOpen -FilePath <data.backup.xmlPath> -Option Replace -DryRun $false`(`data.backup.restore` 就是這行指令),只能還原 XML 裡有的部分。這份檔案沒寫出來、讀不了或少了物件 → `PLCOPEN_BACKUP_FAILED`,不匯入。模組會比對每個物件在專案裡的子物件和 XML 的 members:有子物件不在 XML 裡(`data.backup.diskOnly`,例如 ITF 的 property)時，那個物件的 ProduceXml + 磁碟檔備份(`.TcIO` / `.TcPOU`)就變成**必要**,沒做成 → `PLCOPEN_BACKUP_FAILED` reason `disk-backup-failed`。這些子物件只能從磁碟檔副本或 `.zip` 還原:XML 還原後，把 `data.backup.diskOnly[].diskFileCopy` 複製回 `diskFile` 再 `Reset-TcSolution`,或 `Import-TcTreeItem` 匯回 `.zip`(**都未實測**;`data.backup.restoreNote` 有寫)。**盡力而為**的是其他物件的同一套備份和每個物件的 ExportChild `.zip`(`data.backup.objectBackups`;POU 節點的 ExportChild 未實測),失敗只加 warning。Replace 後會比對磁碟檔前後的 hash(`data.replaced[].diskFileChanged`),沒變就加 warning;匯入後新增的物件裡有和衝突物件同名的(在別的資料夾)會列在 `data.conflictsAdded` 並加 warning。
- **磁碟與存檔**:匯入當下 XAE 就寫物件檔(`.TcPOU` / `.TcIO`),`.plcproj` 要等專案存檔才寫(實測)。所以讀回成功後模組照 `Add-TcPou` 的做法存檔(`Invoke-TcPlcObjectSave`:DTE `Project.Save`,再從磁碟讀回 `.plcproj`,每個新增物件都要有 `<Compile Include>`,`data.expectedProjectFiles` / `data.projectSaved`)。存檔失敗回它自己的碼(`PROJECT_SAVE_FAILED` / `PROJECT_SAVE_TIMEOUT` / `IDE_MODAL_DIALOG`,`data.projectSave`),BUILD_REQUIRED 照樣記。
- **BUILD_REQUIRED**:`PlcOpenImport` 一呼叫就記 code-changed(成功、失敗、讀回不符都記);呼叫前擋下的不記。`Export-TcPlcOpen` 不改專案，不記。

### PLCOPEN_FAILED

- **現象**:`data.reason`:`invalid-selection`(selection 元素是空的、用了 `^`、元素裡有 `;`、有空層級)、`member-selection`(指到 method / property / action / accessor,`data.memberSelection`)、`selection-not-found`(XAE 回 `0x98510008`)、`invalid-argument`(XAE 丟 ArgumentException)、`export-failed` / `import-failed`(其他例外，`data.xaeMessage`、`data.hresult`)、`not-absolute` / `invalid-path` / `folder-missing` / `file-missing`(路徑)、`invalid-file` / `no-objects`(匯入檔不是 PLCopen XML 或沒有物件)、`overwrite-move-failed`(舊檔改名失敗)。除了 `import-failed`,都沒有改專案。
- **下一步**:依 `data.reason` 修正後重跑:selection 每個元素一個物件、用 `.` 分層(`-Selection 'POUs.FB_A','DUTs.ST_B'`);member-selection 改成 `data.memberSelection.suggestedSelection`;selection-not-found 用 `Get-TcProjectTree -PlcOnly` 查名稱;其他看 `data.xaeMessage`,用 `Get-TcIdeModalDialog` 檢查 dialog。

### PLCOPEN_FILE_EXISTS

- **現象**:`Export-TcPlcOpen` 的 `-FilePath` 已存在，沒加 `-Overwrite`;什麼都沒寫(XAE 本來也會拒絕，實測)。
- **下一步**:換一個 `-FilePath`,或加 `-Overwrite`(舊檔先改名成 `.bak`)。

### PLCOPEN_CONFLICT

- **現象**:`Import-TcPlcOpen -Option None`,檔案裡有物件和專案同名(`data.conflicts`:name、existingPath);dry-run 也回這個碼，實寫時沒有呼叫 XAE。XAE 自己回 "Import conflict!" 時也用這個碼(`data.xaeConflicts`,這時已呼叫 XAE,會記 BUILD_REQUIRED)。
- **下一步**:依 `data.conflicts` 選 `-Option Skip` / `Rename` / `Replace`,先 `-DryRun $true` 看預告;`Replace` 會刪掉檔案裡沒有的子物件，先看 `data.willReplace[].deletedChildren`。

### PLCOPEN_VERIFY_FAILED

- **現象**:呼叫返回了，但讀回不符。Export:`data.reason` = `file-not-written`(檔案不存在或是空的)、`invalid-file`(不是 PLCopen XML)、`selection-missing`(`data.missingSelections` 的物件 / 資料夾不在檔案裡);有 `-Overwrite` 時舊檔已還原。Import:`data.reason = missing`:`data.missing` 的物件匯入後找不到(Rename 時是找不到 `<名稱>_<n>`),`data.added` 是實際新增的物件;`skip-changed`:`-Option Skip` 但被跳過物件的磁碟檔在匯入期間變了(`data.skipped[].unchanged = false`)。
- **下一步**:用 `Get-TcProjectTree -PlcOnly` 確認專案現況;Replace 的原物件要還原就執行 `data.backup.restore`(`Import-TcPlcOpen -FilePath <data.backup.xmlPath> -Option Replace -DryRun $false`)。

### PLCOPEN_BACKUP_FAILED

- **現象**:`Import-TcPlcOpen -Option Replace` 實寫前的備份沒做成(`data.reason`:`backup-failed` = solution 路徑不明或 `.tcauto-backup` 寫不進去;`plcopen-backup-failed` = PlcOpenExport 備份失敗、沒寫出來、讀不了或少了物件;`disk-backup-failed` = 物件有 XML 裡沒有的子物件(例如沒有 Get / Set 的 ITF property),但它的磁碟檔備份沒做成;`index-incomplete` = 專案物件索引不完整，要備份的物件可能沒找齊;`data.backupObject` 是要備份的物件),`PlcOpenImport` 沒有呼叫，什麼都沒改。ExportChild `.zip` 失敗不會走到這裡，只是 warning。
- **下一步**:先 `Connect-TcIde -SolutionPath <sln>`(或 `Open-TcProject`)、確認目錄可寫;`plcopen-backup-failed` 時用 `Export-TcPlcOpen -Selection <物件> -FilePath <新的 .xml>` 試匯出找原因，再重跑;`disk-backup-failed` 先確認物件的 `.TcIO` / `.TcPOU` 在 solution 目錄底下只有一份;`index-incomplete` 用 `Get-TcProjectTree -PlcOnly` 找出讀不到的資料夾;不需要覆蓋時改用 `-Option Rename`。

### Boot project(task 3.2):做法

- **做法**:`New-TcBootProject`(MCP `GenerateBootProject`)在 PLC root `TIPC^<Plc>` 上呼叫 `GenerateBootProject($false)`(TE1000 v1.7.0 §5.17 p.102–103,範例 §6.5.13 p.241)。只在 PLC root 有這個方法，`<Plc> Project` 上沒有(實測 2026-10-31 4026 VS2022 XAE 3.1.4026.18,自建 client,`phase2-probe.md` 3.2)。`bActivate = $true` 沒實測，不提供;要寫到 target 用 `Build-TcProject` 加 `Enable-TcConfig -Force`。
- **寫了哪些檔(實測)**:只寫專案的 `<tsproj 目錄>\_Boot\<solution platform>\Plc\Port_<adsPort>.app` / `.autostart` / `.cid` / `.crc` / `.occ` / `.ocm` 和 `Port_<adsPort>_boot.tizip`;`%ProgramData%\Beckhoff\TwinCAT\3.1\Boot` 和 UmRT 的 Boot 目錄都沒變。`_Boot` 裡的 `CurrentConfig.*` 是 Build 寫的，不是它。
- **它會存檔**:記憶體裡尚未存檔的修改會被寫進 `.plcproj` / `.tsproj`(實測);每次呼叫 `data.warnings` 都會寫。
- **不用先 Build**:它自己編譯。有編譯錯誤時回 COMException E_FAIL(`0x80004005`),訊息沒有資訊，模組接著讀 Error List(和 `Build-TcProject` 同一套分類)。
- **讀回**:呼叫前後列出 `Port_<port>.*`,`Port_<port>.app` 要存在且修改時間比呼叫前新;`data.bootFiles` 列出路徑、大小、時間、`updated`。目錄同時查 solution platform 和 `.tsproj` 的 project platform(`data.bootDirs`;**兩者不同時 XAE 寫哪一個資料夾未實測**,probe 兩者都是 `TwinCAT OS (x64)`),任一個的 `.app` 變新就算。solution platform、ADS port 或 `.tsproj`(含路徑是空的)推不出來時，改列 solution 目錄底下所有 `_Boot\*\Plc\Port_*`,加 warning;這時至少要有一個 `Port_*.app` 變新(只有 `.autostart` 之類變新不算),ADS port 不明時 `data.bootPorts` 列出變新的 `.app` 的 port。失敗時 Error List 裡沒有 severity 的列放在 `data.unclassified`,訊息也會寫。
- **BUILD_REQUIRED**:不改。Activate 仍然要走 `Build-TcProject`(完整成功才清掉)和 `Enable-TcConfig`;這個呼叫不能證明 build 完整。
- **BOOT_PACKAGE_MISMATCH**:這裡只產生本機 `_Boot`,不寫 target,所以不影響 Activate 後 `Enable-TcConfig` 做的比對。

### BOOTPROJECT_FAILED

- **現象**:`GenerateBootProject($false)` 丟例外。`data.reason = generate-failed`:多半是編譯錯誤(XAE 回 E_FAIL,訊息沒資訊，實測),`data.errorItems` 是 Error List 上有 file 或 code 的錯誤列(`codeErrors` / `libraryErrorItems` 分開列，沒有 file 也沒有 code 的舊列在 `staleErrorItems`);`data.xaeMessage` / `data.hresult` 是原始例外。`no-method`:這個節點沒有 `GenerateBootProject`。失敗時專案檔仍可能已被存檔(實測：有編譯錯誤時 `.tsproj` 也被改寫)。
- **下一步**:依 `data.errorItems` 的 file / line 用 `Get-TcPouCode -PouPath` 讀、`Write-TcPouCode -PouPath` 改，再重跑 `New-TcBootProject`;`errorItems` 是空的就 `Get-TcBuildErrors` 或 `Build-TcProject` 看錯誤。

### BOOTPROJECT_VERIFY_FAILED

- **現象**:`GenerateBootProject` 返回了，但讀回不符。`data.reason = not-updated`:`_Boot\<platform>\Plc\Port_<port>.app` 不存在或沒有比呼叫前新;`boot-dir-unknown`:boot 目錄推不出來(warning 寫原因),solution 目錄底下也找不到變新的 `Port_*` 檔。`data.bootFiles` 是找到的檔案。
- **下一步**:用 `Get-TcIdeInfo` 確認 `solutionPlatform`,看 `data.bootFiles`;重跑一次，仍沒更新就改用 `Build-TcProject` 加 `Enable-TcConfig -Force`。

### SaveAsLibrary 與 archive(task 3.4):做法

- **Library**:`Save-TcPlcLibrary`(MCP `SaveAsLibrary`)在 `<Plc> Project` 上呼叫 `SaveAsLibrary(path, $false)`(TE1000 v1.7.0 §5.28.1.1 p.123,範例 §6.5.13 p.240),**不安裝**;要安裝用 `Install-TcLibrary -LibraryPath <檔案>`。加密(`SaveAsLibrary2` 的 bEncrypt)不提供：沒有接 software protection / user database 時 XAE 拒絕("No Software-Protection/User-Database is connected ... Cannot save library with encryption!")。`.library` 與 `.compiled-library` 都可以，每次約 5.5–7 s,沒有 dialog(實測 2026-10-31 4026 VS2022 XAE 3.1.4026.18,自建 client,`phase2-probe.md` 3.4)。**會存 .plcproj**:XAE 記憶體裡還沒存的改動(例如用 `Set-TcTreeItemXml` 暫時改的 project info)在呼叫後就出現在磁碟上的 .plcproj,LastWriteTime 是呼叫時刻(registered tcauto 實測 2026-10-31 4026 VS2022、4024 XAE,`verification/phase2-3.8.md` P7;自建 client 那次只看到 `.~u` 變,因為沒有未存的改動)。回傳 `data.projectSaved`(= `data.projectFileWritten`:呼叫前後 `data.projectFile` 的 LastWriteTime 不同 → true,相同 → false,找不到 .plcproj → null)。從沒 build 過的專案會不會跳 dialog 沒測。
- **Archive**:`Save-TcArchive`(MCP `SaveArchive`)。`-Kind Solution` 用 `DTE.GetObject("TcArchivePersist").SaveAsArchive(path)` 存 `.tnzip`(§5.44 p.156–157、§6.3.7 p.209);`-Kind Configuration` 用 `ITcSysManager9.SaveAsArchive(path)` 存 `.tszip`(§5.1.8 p.49–50、§6.5.13 p.241)。實測:`.tnzip` 含 `.sln`、TwinCAT 專案放在同名資料夾下，並嘗試包含 Scope 等其他專案;`.tszip` 只有 TwinCAT 專案(`.tsproj` 加 PLC 專案與 `_Libraries`),沒有 `.sln`。兩者都打包 **XAE 記憶體裡的狀態**,不是磁碟上的檔案(還沒存進 `.plcproj` 的物件也在 archive 裡),也都不存檔。只做產生，不做載入(載入會換掉目前的 solution)。
- **回 S_OK 也可能少東西**:實測 `.tnzip` 少了 `A10_Scope`,`SaveAsArchive` 仍回 S_OK,錯誤只出現在 Error List("'TwinCAT Measurement' (...): Error creating Archive -> ...")。所以模組在呼叫前後各讀一次 Error List,以「code + 描述 + 檔案 + 專案」計數比對(同樣的文字多一次也算新的,沒有 severity 的列也一起算),新出現的錯誤列 → `ARCHIVE_INCOMPLETE`。呼叫後 Error List 被截斷(`data.errorListTruncated`)或有沒有 severity 的列(`data.unclassified`)時，無法確認 → `ARCHIVE_UNVERIFIED`;但新出現的 unclassified 列含 "Error creating Archive" 時回 `ARCHIVE_INCOMPLETE`。這個錯誤列是在 `SaveAsArchive` 返回前同步出現、還是之後非同步出現，**未實測**;模組只在呼叫後立刻讀一次。
- **讀回**:檔案存在、不是空的、修改時間在這次呼叫之後;用 `System.IO.Compression.ZipFile` 開啟,`data.entries` 列出名稱與大小(最多 200 筆，超過時 `data.entriesTruncated = true`、`data.entryCount` 是總數)。
- **檔案已存在**:三個 API 都丟 ArgumentException(實測),模組先擋(`LIBRARY_SAVE_FILE_EXISTS` / `ARCHIVE_FILE_EXISTS`);`-Overwrite` 先把舊檔改名成 `<檔名>.bak`,失敗時新檔改名成 `<檔名>.failed`、舊檔改回原名(`data.restore`)。
- **BUILD_REQUIRED**:兩者都不改專案，不記。

### LIBRARY_SAVE_FILE_EXISTS

- **現象**:`Save-TcPlcLibrary` 的 `-FilePath` 已存在，沒加 `-Overwrite`;什麼都沒寫(XAE 本來也會拒絕，實測)。
- **下一步**:換一個 `-FilePath`,或加 `-Overwrite`。

### LIBRARY_SAVE_FAILED

- **現象**:`data.reason`:`extension`(不是 `.library` / `.compiled-library`)、`not-absolute` / `invalid-path` / `folder-missing`、`overwrite-move-failed`、`save-failed`(XAE 丟例外，`data.xaeMessage` / `data.hresult`)、`not-written`(返回了但檔案不存在、是空的或不是這次寫的)。有 `-Overwrite` 時舊檔已還原(`data.restore`)。
- **下一步**:依 `data.reason` 修正後重跑 `Save-TcPlcLibrary`;`save-failed` 先用 `Get-TcIdeModalDialog` 檢查 dialog。

### ARCHIVE_FILE_EXISTS

- **現象**:`Save-TcArchive` 的 `-FilePath` 已存在，沒加 `-Overwrite`;什麼都沒寫(XAE 本來也會拒絕 "Archive file already exists!",實測)。
- **下一步**:換一個 `-FilePath`,或加 `-Overwrite`。

### ARCHIVE_FAILED

- **現象**:`data.reason`:`extension`(`-Kind Solution` 要 `.tnzip`、`Configuration` 要 `.tszip`)、`not-absolute` / `invalid-path` / `folder-missing`、`overwrite-move-failed`、`no-archive-object`(`DTE.GetObject('TcArchivePersist')` 沒回東西)、`save-failed`(XAE 丟例外)、`not-written`、`not-a-zip`(寫出的檔案打不開)。有 `-Overwrite` 時舊檔已還原。
- **下一步**:依 `data.reason` 修正後重跑 `Save-TcArchive`。

### ARCHIVE_INCOMPLETE

- **現象**:`SaveAsArchive` 回 S_OK、檔案也寫出來了，但 Error List 在呼叫期間多了錯誤列(`data.errorItems`;實測是 Scope 專案 "Error creating Archive")。檔案**保留**(`data.filePath`、`data.entries`),`data.warnings` 寫明不完整。呼叫前的 Error List 讀不到時，只有內容含 "Error creating Archive" 的列會算，舊的同樣錯誤也會被算進來(warning 會寫)。
- **下一步**:看 `data.errorItems` 是哪個專案;只要 TwinCAT 專案就改用 `-Kind Configuration`(`.tszip`);要完整 solution 就先在 XAE 修好或移除那個專案，再加 `-Overwrite` 重跑。

### ARCHIVE_UNVERIFIED

- **現象**:archive 寫出來了(檔案保留),但呼叫後 Error List 讀不到、被截斷(`data.errorListTruncated`),或有沒有 severity 的列(`data.unclassified`),無法確認有沒有專案沒被打包。
- **下一步**:確認 XAE 的 Error List 視窗可見，用 `Get-TcBuildErrors` 讀，找 "Error creating Archive" 的列;沒有就可以用這個檔案。

### PROJECT_SAVE_FAILED

- **現象**:`Add-TcPou` / `Add-TcDut` / `Add-TcGvl` / `Add-TcLibrary` 建好物件後存專案檔失敗,或存完從磁碟讀回的 .plcproj 沒有新的 `<Compile Include>`(含相對路徑,如 `POUs\FB_X.TcPOU`)/ library reference;`data.objectPath`、`createdInMemory = true`、`savedToDisk = false`。找不到該 PLC 的 .plcproj(例如獨立專案檔 .xti,未驗證)時也回此碼,hint 改成請使用者手動存檔。`Reset-TcSolution -SaveProjectChanges` 步驟 (1b) 比對或存檔失敗時也回此碼,solution 沒有關。
- **為什麼(#76)**:`CreateChild` 只改 XAE 記憶體裡的 .plcproj,不存就關 solution(`Reset-TcSolution -DiscardProjectChanges`、`Disconnect-TcIde -Quit`)物件會消失,所以讀回不到不能回 success。存檔用 DTE `Project.Save()`(見「磁碟改檔的正確做法」的比較表)。
- **下一步**:不要 `-DiscardProjectChanges`。(1) `Get-TcIdeModalDialog` 看有沒有 dialog,確認 .plcproj / .tsproj 不是唯讀 / 被鎖,再 `Reset-TcSolution -SaveProjectChanges`(只存專案檔並讀回;磁碟也被改過時會拒絕)。(2) 仍失敗:請使用者在 XAE 手動存該 PLC 專案;或 `Build-TcProject`,但它會一併存 editor buffer(可能蓋掉磁碟上的 .TcPOU 改動)。Build 會存 .plcproj 是實測 2026-10-28 的觀察(4026 VisualStudio.DTE.17.0:該副本 .plcproj 的最後寫入時間 = 第一次 Build,見 [#76](https://github.com/Lance0901/AI-TwinCAT-Skill/issues/76)),不是官方說明。最後 `Get-TcProjectTree -PlcOnly` 確認物件還在。

### PROJECT_SAVE_TIMEOUT

- **現象**:`Add-*` 或 `Reset-TcSolution -SaveProjectChanges` 呼叫的 DTE `Project.Save()` 在期限內沒返回(`Add-*` 60 s);模組已放棄等待(呼叫放在另一個 STA runspace,和 `ACTIVATE_TIMEOUT` 同一種做法,CODING_STANDARDS.md 規則 1),XAE 內部可能仍在存。`data.saveDiagnostics`:`dialog`(標題 / 內文)、`ideAlive`、`ideResponding`、`readOnlyFiles`(.tsproj / .plcproj 有唯讀屬性者)、`elapsedSec`。
- **唯讀 .plcproj**:XAE 遇到唯讀 .plcproj 時會跳 dialog、逾時還是直接回錯,**未實測**(本輪真機沒有跑這一步);模組的處理不依賴它:跳 dialog → `IDE_MODAL_DIALOG` 或逾時時 `data.saveDiagnostics.dialog`,回錯 → `PROJECT_SAVE_FAILED`,存了但讀回沒有 → `PROJECT_SAVE_FAILED`。
- **下一步**:`dialog` 有值 → `Get-TcIdeModalDialog` 看內容並處理(模組不會替你按);`readOnlyFiles` 有值 → 解除唯讀後 `Reset-TcSolution -SaveProjectChanges`;`ideResponding = false` → XAE 卡死,`Disconnect-TcIde -Quit -Kill`(只限本 session 啟動的)後重新 `Connect-TcIde`,未存的新物件會遺失。

### PROJECT_UNSAVED_CHANGES

- **現象**:`Reset-TcSolution` 沒有存也沒有關 solution:某個 PLC 在 XAE 裡有、磁碟 .plcproj 沒列的物件(`data.projectCheck.plcs[].missingOnDisk`)。只有 `extraOnDisk`(.plcproj 有、XAE 沒有)**不擋**:重開本來就載入磁碟版本,XAE 不會掉東西,只記在 `data.projectCheck`。帶 `-SaveProjectChanges` 時,若磁碟有被改過的跡象也回此碼,`data.saveRefused` 列出原因(`plc = '*'` 表示不屬於單一 PLC):步驟 (1) 處理過 reload 提示、`missingOnDisk` 的物件檔在它的相對路徑上不存在;以及因為 `Project.Save()` 會寫整個 .tsproj 與其下**所有** .plcproj,與要存的 PLC 共用同一個 .tsproj 的任何 PLC(.tsproj 不明的也算)`checked = false`、`complete = false` 或 `extraOnDisk` 非空。
- **已知限制**:比對只走 PLC 資料夾(ItemType 601)往下;不是 601 的容器節點底下的物件不會被列入,這類物件的差異偵測不到。
- **為什麼(#76)**:「XAE 建了沒存」和「有人在磁碟上刪了」看起來一樣;自動存檔會把磁碟上的改動蓋回去(不可逆),直接關掉會丟掉 XAE 的物件,模組不替你選。
- **IDE 的未存文件 / 專案**:不再回此碼,改由 `UNSAVED_CHANGES` 擋(#175;以前只在 reset-required 時檢查文件,回此碼的 `data.dirtyDocuments`)。
- **下一步**:(1) 保留 XAE 版本 → `Reset-TcSolution -SaveProjectChanges`(MCP `ResetSolution SaveProjectChanges=true`);(2) 以磁碟為準 → `Reset-TcSolution -DiscardProjectChanges`;(3) 兩邊都要 → 先在磁碟上補回需要的檔案 / `<Compile Include>`,再走 (1) 或 (2)。不要用 `Build-TcProject` 解：它不替你選邊(Build 會不會一併存 PLC editor buffer 是推論、未實測)。

### UNSAVED_CHANGES

- **現象**:`Reset-TcSolution` 沒有存也沒有關 solution(#175):IDE 有未存的變更,重開 solution(`Documents.CloseAll(vsSaveChangesNo)` + `Solution.Close($false)`)會不存檔丟掉它們。`data.unsavedCheck`:`documents`(`Document.Saved = false` 的文件 FullName)、`projects`(`Project.Saved = false` 的頂層專案 `{name, file}`)、`solution`(`Solution.Saved = false` 時的 .sln)、`unchecked`(模組問不到的專案,不擋)、`error`(讀不到,fail closed)、`forced`、`forceRequested`、`sec`。只讀到一半就碰到 IDE 忙碌(`IDE_BUSY`)、RPC 斷線(`IDE_CRASHED`)、modal dialog 或逾時時不回此碼,照原樣回那些錯誤碼(`-Force` 也一樣),什麼都沒關(PR #256 review S1)。`Document.Saved`、`Solution.Saved` 或可辨識專案的 `Project.Saved` 讀回 null 都算讀不到(fail closed)。
- **誰會留下未存變更(實測 2026-11-12,4026 VS2022 `VisualStudio.DTE.17.0`,複本 `C:\Temp\Verify-4026-axis`,registered tcauto + 唯讀 ROT probe)**:`Set-TcTarget`(即使 NetId 沒變)讓 .tsproj 變成 `Project.Saved = False` / `IsDirty = True`;之後 `Build-TcProject` 會把它存回(`Saved = True`)。`Write-TcPouCode` 當下就把物件檔寫到磁碟,之後沒有任何 Document / Project / Solution 報未存。在 XAE 編輯器裡手動改、沒存的文件是 `Document.Saved = false`([EnvDTE Document.Saved](https://learn.microsoft.com/en-us/dotnet/api/envdte.document.saved))。
- **磁碟改檔流程不會被誤擋**:檔案在磁碟上被改,IDE 那份不會因此變成未存;只有 IDE 自己有未存變更時才擋(典型:`Set-TcTarget` 之後沒 Build 就 `Reset-TcSolution`)。正常 lifecycle(`Set-TcTarget` → `Build-TcProject` → 磁碟改檔 → `Reset-TcSolution`)不會擋(實測 2026-11-12,同上環境)。
- **unchecked**:4026 測試 solution 裡的 TwinCAT Scope 專案(`A10_Scope.tcmproj`)在 DTE 上 `Kind` / `FullName` / `Saved` 全部讀回 null、不丟例外(實測 2026-11-12),模組問不到它,只列在 `unchecked`、不擋;它開著的 `.tcscopex` 文件仍由 `documents` 檢查。成功時 `data.stateWarning` 會點名這些沒檢查的專案;帶 `-Force` 時它們列進 `data.discardedChanges`、標「may have been dropped」。`Solution.Saved` 在同一環境讀回 True(實測 2026-11-12),讀回 null 時 fail closed。
- **只讀頂層專案(已知限制)**:只讀 `Solution.Projects` 的頂層項目;solution folder 裡的專案(`ProjectItems` 的 `SubProject`)和 .tsproj 底下巢狀的 .plcproj 的 `Saved` 都不讀(巢狀 PLC 專案也不在 `Project.ProjectItems` 裡,見「磁碟改檔的正確做法」的比較表)。
- **沒涵蓋**:`CreateChild` 建了沒存的物件 DTE 不報(那是 `PROJECT_UNSAVED_CHANGES` 的 project check,#76);XAE 跳 project reload 提示時走 Yes 路徑(XAE 自己 reload),不讀未存狀態(提示擋住 DTE;那時 XAE 會不會先問要不要存未實測)。
- **下一步**:先問使用者要不要丟掉 `data.unsavedCheck` 列的變更。同意 → `Reset-TcSolution -Force`(MCP `ResetSolution Force=true`),`data.discardedChanges` 列出丟掉的檔案(丟的若是 `Set-TcTarget` 的設定,重開後再 `Set-TcTarget` 一次);讀不到狀態時是 `discardedChanges = null`、`discardedUnknown = true` 加原因,表示不知道丟了什麼。Yes 路徑(XAE 自己 reload project)不讀未存狀態,`data.unsavedCheck.checked = false`、`forced = false`、`forceRequested` = 有沒有帶 `-Force`。要保留 → 先存檔再跑不帶 `-Force` 的 `Reset-TcSolution`:專案檔可用 `Build-TcProject`(建置前會存 .tsproj,實測同上)或請使用者在 XAE 按 File > Save All;但磁碟上的檔案剛被別的工具改過時,存檔會把 IDE 記憶體裡的舊內容寫回、蓋掉磁碟上的改動,這時請使用者在 XAE 自己決定。**reset-required 時**(`Connect-TcIde -TakeOverOrphan` 答過 reload 提示)`Build-TcProject` 與存專案檔都會回 `RESET_REQUIRED`,不能拿來保留:只剩「使用者在 XAE 自己把內容複製出來保留(不要存檔)」或「使用者同意後 `-Force`」。`-DiscardProjectChanges` 不算同意(它只決定 project check 以磁碟為準);`-Force` 與 `-SaveProjectChanges` 互斥(`INVALID_PARAMS`)。

### PROJECT_OPEN_FAILED

- **為什麼**:`Open-TcProject` / `Connect-TcIde -SolutionPath` 開 .sln 失敗。路徑錯、檔案損壞、或連到的 IDE 沒有 TwinCAT 整合(例如抓到沒裝 TwinCAT 的 VS)。
- **下一步**:確認路徑;指定 `-ProgId` 對應正確的 IDE(見環境矩陣)。開著這個 .sln 的 IDE 被 modal 擋住時現在回 `IDE_MODAL_DIALOG` / `IDE_BUSY`,不再是這個碼(#29,見「IDE_MODAL_DIALOG」)。

### POU_NOT_FOUND

- **現象**:`Get-TcPouCode` / `Write-TcPouCode` 回 `POU_NOT_FOUND`。(`PLC_PROJECT_NOT_FOUND` 是 TIPC 下找不到 `<Plc> Project` 節點,處理方式相同。)
- **為什麼**:4024 與 4026 的 PLC 樹格式相同:`TIPC^<Plc>^<Plc> Project^POUs^<name>`(DUT 在 `^DUTs^`、GVL 在 `^GVLs^`)。不給 `-PouPath` 時依序試 `<Plc> Project^POUs^<name>`、`<Plc> Project^<name>`,最後遞迴走 project 子樹(深度 4)比對名稱;給了 `-PouPath` 但找不到也會改用名稱自動找。都沒命中才回此碼。子物件(task 3.6):`-PouPath <POU path>^<member>`、accessor `^<property>^Get`;`-PouName` 也接受 `FB_X.M_Run`、`FB_X.P_Value.Get`(先照原字串找，找不到才把 `.` 換成 `^`,因為資料夾名稱可能有 `.`;`-PouPath` 只轉最後一段)。走樹時命中多個(例如兩個 FB 都有 `M_Run`)回 `POU_AMBIGUOUS`,不再靜默取第一個(實測 2026-10-31 4026 VS2022 自建 client 確認舊行為會取第一個)。
- **下一步**:`error.message` 列出試過的路徑(`data.tried[]`),`error.hint` 說明格式並列出 `<Plc> Project` 第一層子節點(例如 `POUs, DUTs, GVLs, VISUs`,另見 `data.projectChildren[]`)。用 `Get-TcProjectTree -PlcOnly` 查節點 `path` 後給 `-PouPath`。與 `POU_READ_FAILED` / `POU_WRITE_FAILED` 不同:後兩者只在 COM 例外(例如讀 DeclarationText 失敗)時回,代表 POU 找到了但存取失敗。
- **DUT / GVL 的讀寫語意**(#22):`Get-TcPouCode` 回 `data.objectKind`(POU / DUT / GVL / ITF / METHOD / ACTION / PROPERTY …,由樹節點的 `ItemType` 判斷,數值見 [InfoSys「ITcSmTreeItem Item Types」](https://infosys.beckhoff.com/content/1033/tcautomationinterface/12425810699.html);PLC 物件的 `ItemSubType` 一律是 0,`ItemSubTypeName` 是 `TREEITEMTYPE_*` 名稱,實測 2026-10-25 4024 / 4026)、`data.language`(`ITcSmTreeItem.Language`:ST 1 / FBD 4 / LD 6 …,DUT / GVL / ITF 為 null,實測同上)、`data.hasImplementation`、`data.implementationReadable`。`hasImplementation` 實測過的(2026-10-25,讀 `ImplementationText`):有實作段 = POU 602 / 603 / 604(4024、4026)、action 608(4024、4026)、method 609(4026,空的 ST 本體讀回 `''`);沒有 = DUT 605 / 606(4024、4026)、union 607 / alias 623(4026)、GVL 615、interface 618(4024、4026)、interface method 610(4026)、property 611(4024、4026,`CreateChild 611` 不會建 Get / Set 子項)。interface property 612、property get / set 613 / 614、transition 616 未實測:`hasImplementation` 先當未知,讀 `ImplementationText` 決定(和未知 ItemType 一樣)。沒有實作段時 `implementation=null`、`implementationReadable=null`,整份原始碼在 `declaration`。有實作段卻讀回 null 時 `implementationReadable=false`,沒有實作段時 `implementationReadable=null`。屬性讀取失敗會以 null / `implementationReadable=false` 呈現:Windows PowerShell 對丟例外的 getter 回 `$null`(實測 2026-10-25,PS 5.1.26100,.NET property;COM adapter 未驗)。declaration 讀回 null 回 `POU_READ_FAILED`(action 608 例外,它本來就沒有 declaration,實測 2026-10-25 4024 / 4026;未實測的 transition 616 也放行);LD / FBD 的 `implementation` 是 XAE 的 XML(`<NWL><XmlArchive>…`),不是 ST 文字(實測 2026-10-25 4024 / 4026)。COM 呼叫本身丟例外回 `POU_READ_FAILED`。`Write-TcPouCode` 對沒有實作段的物件給 `-Implementation` 回 `INVALID_PARAMS`、什麼都不寫(ItemType 未知時先讀 `ImplementationText`,null 就同樣擋下),只給 `-Declaration`(完整的 `TYPE ... END_TYPE` / `VAR_GLOBAL ... END_VAR`);property 的 hint 指向 `<path>^Get` / `^Set`。

### POU_READ_FAILED

- **現象**:`Get-TcPouCode` 找到了物件,但讀不出內容:COM 呼叫丟例外,或 `DeclarationText` 讀回 null。實測過的類型(POU、DUT、GVL、ITF、method、ITF method、property)都有 declaration;action 608 沒有(實測 2026-10-25),612-616 未實測,其中 transition 616 比照 action 放行,不回此碼。和 `POU_NOT_FOUND` 不同,物件存在。
- **下一步**:`Get-TcIdeModalDialog` 看 XAE 有沒有 dialog;沒有就重試 `Get-TcPouCode -PouPath <path>`,仍失敗就 `Reset-TcSolution` 後再讀。

### POU_CREATE_FAILED / DUT_CREATE_FAILED / GVL_CREATE_FAILED

- **現象**:`Add-TcPou` / `Add-TcDut` / `Add-TcGvl` 回失敗(`Add-TcInterface` 也回 `POU_CREATE_FAILED`,步驟相同;interface 是 CreateChild 618,vInfo `$null` 或 `-Extends` 字串，陣列會被 XAE 拒絕，實測 2026-10-31 4026 VS2022 自建 client)。`error.message` 在 `Failed to add ...:` 後標出失敗步驟:`exists:`(目標 PLC project 裡已有同名的頂層物件,訊息帶它的 path;什麼都沒建)、`lookup:`(`CreateChild` 回來了但目標路徑讀不到)、`kind:`(新物件的 ItemType 不對)、`language:`(POU 讀回的語言不是 ST)、`declare:`(寫入 / 讀回 declaration 失敗或內容不同;Function 讀回的 header 沒有 `: <ReturnType>`)。從 `lookup` 起物件已經建立、留在樹上,訊息會說明;沒標步驟就是 `CreateChild` 本身的 XAE 訊息。IDE 有 modal dialog 時不呼叫 `CreateChild`,直接回 `IDE_MODAL_DIALOG`(同 `Build-TcProject`)。
- **怎麼建**:`ITcSmTreeItem::CreateChild(name, subType, '', vInfo)`,父節點是 PLC folder(`TIPC^<Plc>^<Plc> Project^POUs` / `^DUTs` / `^GVLs`,4024 與 4026 相同)。subType 用 [InfoSys「ITcSmTreeItem Item Types」](https://infosys.beckhoff.com/content/1033/tcautomationinterface/12425810699.html) 頁的 ItemType 值:Program 602、Function 603、Function block 604、DUT enum 605 / struct 606 / union 607 / alias 623、GVL 615;[InfoSys `ITcSmTreeItem::CreateChild`](https://infosys.beckhoff.com/content/1033/tcautomationinterface/12425844363.html) 頁確認 603 / 604 也是 CreateChild 的 sub type,其餘實測(2026-10-25,4024 / 4026)。vInfo 依 CreateChild 頁:FB = IEC 語言整數,Function = string[2] {語言, 回傳型別};Program 也吃同一個整數(實測 2026-10-25,4024 / 4026)。`IECLANGUAGE_ST` = 1(TCatSysManagerLib 3.4.0.0 interop 的 `IECLANGUAGETYPES`,reflection 讀出,2026-10-25;6 是 LD)。DUT / GVL 不帶 vInfo 建立,再寫 `DeclarationText` 並讀回比對;alias 例外,vInfo 要給基底型別。成功只在讀回新物件(ItemType 相符、POU 語言是 ST、Function header 含回傳型別、DUT / GVL declaration 相符)之後才回。
- **同名檢查(`exists`)**:目標路徑本身,加上目標所在的 `<Plc> Project`(父路徑中第一個「等於前一段 + ` Project`」的段,所以 PLC 名稱本身以 ` Project` 結尾也對;多 PLC 的 solution 只查自己那個 PLC)裡所有 PLC folder(ItemType 601,含巢狀)的直接子項。父路徑不在 `<Plc> Project` 底下時只查目標路徑,`data.duplicateCheckScope = folder`,`data.duplicateCheckNote` 說明原因。只有頂層物件算衝突:POU 602 / 603 / 604、DUT 605 / 606 / 607 / 623、GVL 615、ITF 618;method、action、property、accessor 與資料夾同名不算,也不往 POU 底下走。名稱比對不分大小寫,所有命中都列在訊息裡。讀不到的節點計入 `data.duplicateCheckSkippedNodes`(對它不擋,fail-open);RPC busy(0x80010001 / 0x8001010A)與 IDE_* 不算讀不到,會整段重試(`Invoke-TcComRetry`),仍失敗回 `IDE_BUSY` 等。節點超過 3000 個就停止走樹:已找到的同名仍會擋下(`exists`),其餘部分沒查,`data.duplicateCheckScope = folder`(正常是 `project`)、`data.duplicateCheckNote` 說明,另有 PowerShell warning。耗時(實測 2026-10-25,target 127.0.0.1.1.1):TwinCAT_Festo 4024 複本 47 個節點,第一次 587 ms、之後 84 / 150 ms;RobustDemo 4026 複本 63 個節點,446 / 68 / 61 ms(第一次含 COM 暖機)。約 1-1.5 ms 一個節點,3000 個約 3-5 s。
- **#17 之前為什麼失敗**(實測 2026-10-25,4024 TcXaeShell.DTE.15.0;修正後的呼叫在 4026 VisualStudio.DTE.17.0 也驗過):HRESULT 都是 `0x80004005`(E_FAIL),原因在訊息裡。POU:vInfo 傳了 `<Declaration><![CDATA[...]]>` 字串,XAE 把它當語言名稱解析,回「Requested value '<Declaration>...' was not found.」;而且 Program / FB 的 subType 對調(604 = FB,602 = Program)。DUT:用了 610-613,那是 interface method / property,回「Creating the child type 'TREEITEMTYPE_PLCITFMETH' is not possible on parent node type 'TREEITEMTYPE_PLCFOLDER' (SubType mismatch)」。GVL:615 正確所以「成功」,但字串 vInfo 被原樣當成 declaration,`<Declaration><![CDATA[` 外殼留在 GVL 原始碼裡,Build 才會壞。alias 不給 vInfo 回「Base class not specified! Parameter name: baseClass」。
- **下一步**:`exists` → 換 `-Name`,或用 `Write-TcPouCode -PouPath <訊息裡的 path>` 改既有的。「not possible on parent node type」→ 父節點不是 PLC folder,`Get-TcProjectTree -PlcOnly` 查 `<Plc> Project^POUs` 的 path 後給 `Add-TcPou -PlcProjectPath`。`0x98510001` → .plcproj 的 `<Compile Include>` 列了磁碟上沒有的檔案,從 .plcproj 移除或補回檔案,`Reset-TcSolution` 後再試。`lookup` → 物件可能建在別的路徑,`Get-TcProjectTree -PlcOnly` 找到後用 `Write-TcPouCode` 修正或在 XAE 刪掉。`kind` / `language` / `declare` → 物件已建立、留在樹上:用 `Get-TcPouCode -PouPath <path>` 看內容,以 `Write-TcPouCode -PouPath <path>` 修正,或在 XAE 刪掉後再 Add(同名會被 `exists` 擋下)。`IDE_MODAL_DIALOG` → 先處理 dialog(`Get-TcIdeModalDialog`),什麼都沒建。
- **驗證**:`mcp-server/scripts/pou-client.mjs` 經 MCP server 跑 Add* / GetPouCode / WritePouCode / BuildProject(含一次注入未宣告識別字、預期 `BUILD_FAILED` 的對照)。2026-10-25 在全新 4024 專案(Standard PLC Template,TcVersion 3.1.4024.71)與 4026 RobustDemo 複本都全數通過(最後一輪 26/26,含同名跨資料夾的 `exists` 檢查;target 設為 127.0.0.1.1.1,沒有 Activate)。TwinCAT_Festo(4024)複本缺 library 時 PLC 程式碼不會被編譯,Build 仍回 success,不能拿來驗證(#45)。

### POU_AMBIGUOUS

- **現象**(task 3.6):`Get-TcPouCode` / `Write-TcPouCode` / `Add-TcPouMember` 只給名稱，走 `<Plc> Project` 子樹時有多個物件同名(兩個 FB 都有 `M_Run`、兩個 property 都有 `Get`),回 `POU_AMBIGUOUS`,`data.candidates` 列出每個的完整路徑，什麼都沒讀 / 沒改。以前靜默回第一個(實測 2026-10-31 4026 VS2022 自建 client,`openspec/changes/complete-automation-interface/verification/phase2-probe.md` 3.6)。同名的 task reference(ItemType 650,`PlcTask^<POU>`)或資料夾不算第二個候選;ItemType 讀不到的命中仍算候選。名稱有 `.` 時，走樹之前先直接試 `<Plc> Project^POUs^<前半>^<後半>` 和 `<Plc> Project^<前半>^<後半>`。已知限制：命中的項目不再往下找，所以資料夾和它底下的物件同名時只會回傳資料夾。`<Plc> Project^POUs^<name>`、`<Plc> Project^<name>` 直接命中時不走樹，不會回此碼。
- **下一步**:從 `data.candidates` 選一個當 `-PouPath`(`Add-TcPouMember` 是 `-ParentPath`),或寫 `FB_X.M_Run`(前半段本身同名多個時，只有一個候選底下有這個子物件就用它，否則仍回此碼)。

### POU_MEMBER_INVALID / POU_MEMBER_EXISTS / POU_MEMBER_CREATE_FAILED

- **怎麼建**(task 3.6):`Add-TcPouMember` 在父節點呼叫 `ITcSmTreeItem::CreateChild(name, subType, '', vInfo)`。subType 依 TE1000 v1.7.0 §6.5.5(p.229-231)與 enum §5.46.22:PROGRAM / FB 底下 Method 609、Property 611、Action 608;INTERFACE 底下 Method 610、Property 612;property 底下 Get 613、Set 614。vInfo 一律 `string[]`,第 0 個是 IEC language(`IECLANGUAGETYPES` ST 1、IL 2、SFC 3、FBD 4、CFC 5、LD 6,§5.46.5):Method `{lang, returnType, access}`、Property `{lang, type, access}`、Get / Set `{lang, access}`、Action `{lang}`;610 / 612 只給回傳型別(名稱放進陣列會被接成回傳型別，語法錯)。手冊 §6.5.5 範例的 `{name, returnType}` 會回「Language type not supported!」(以上 vInfo 全部實測 2026-10-31 4026 VS2022 XAE 3.1.4026.18,自建 client,`verification/phase2-probe.md` 3.6)。沒有回傳型別的 method 用 vInfo `$null`(實測：宣告 `METHOD M_Null`,沒有 language / access),所以這時只接受 Access PUBLIC + Language ST。Property 不會自動建 Get / Set(實測 2026-10-25、2026-10-31),要另外用 `-Kind Get` / `-Kind Set`。子物件建立時 XAE 當下就寫父物件的 `.TcPOU` / `.TcIO`,`.plcproj` 不變(實測 2026-10-31),所以不存專案檔。
- **POU_MEMBER_INVALID**:參數或父節點不合法，什麼都沒建(`data.reason`):`name`(不是 IEC 識別字;Get / Set 的名稱固定)、`access`(不是 PUBLIC / PRIVATE / PROTECTED / INTERNAL:XAE 收到其他值會**靜默當成 PUBLIC**,實測 2026-10-31,所以模組先擋;interface 成員和 action 不吃 access)、`language`、`return-type`(Property 必填,Action / Get / Set 不能給)、`parent-kind`(Method / Property / Action 的父節點要是 PROGRAM 或 FB,Method / Property 也可以是 INTERFACE;Get / Set 的父節點要是 property;interface 沒有 action)。
- **POU_MEMBER_EXISTS**:父節點底下已經有同名子物件(不分大小寫,`data.existingPath`),什麼都沒建。XAE 自己的錯誤是「An object with the name '...' already exists within the corresponding namespace」,重複建 Get 則是「... (SubType mismatch)」,看不出是重複(實測 2026-10-31),所以模組先查。名稱和 FB 內其他子物件不同就能建。
- **POU_MEMBER_CREATE_FAILED**:CreateChild 被 XAE 拒絕(沒標步驟，什麼都沒建，不記 `BUILD_REQUIRED`),或之後的讀回失敗:`lookup`(找不到新路徑)、`kind`(ItemType 不是 subType)、`language`(method / action 讀回的語言不同)、`declare`(宣告讀回沒有名稱 / access / 型別;action 沒有宣告，不讀)。從 `lookup` 起子物件已建立、留在樹上，記 `BUILD_REQUIRED` code-changed。
- **下一步**:`POU_MEMBER_INVALID` 照 `error.hint` 改參數重跑;`POU_MEMBER_EXISTS` 換 `-Name` 或 `Write-TcPouCode -PouPath <data.existingPath>`;`POU_MEMBER_CREATE_FAILED` 用 `Get-TcPouCode -PouPath <path>` 看內容，以 `Write-TcPouCode` 修正或在 XAE 刪除後再 `Add-TcPouMember`。

### POU_MEMBER_UNSUPPORTED

- **現象**(task 3.6):模組刻意不碰的物件，什麼都沒建 / 讀 / 寫。`data.reason`:
  - `itf-property-accessor`:interface property 的 Get / Set(ItemType 654 / 655)。`Add-TcPouMember` 不建立,`Get-TcPouCode` / `Write-TcPouCode` 只讀 ItemType 就回此碼。原因：在 ITF property 底下 `CreateChild('Get', 654, '', $null)` 成功後，讀它的 `DeclarationText` 讓 VS2022 crash 兩次(卡約 48 s 後 RPC `0x800706BA`;事件檢視器 Application 1000:`devenv.exe 17.14.36811.4`,faulting module `KERNELBASE.dll 10.0.26100.9711`,exception code `0xe06d7363`,offset `0x00000000000c408a`)。`ChildCount`、`LookupTreeItem`、`ItemType`、`ProduceXml` 正常。實測 2026-10-31 4026 VS2022 自建 client,細節見 `openspec/changes/complete-automation-interface/verification/phase2-probe.md`。655 沒測到;64-bit XAE Shell、4024 是否一樣未知。
  - `method-no-return-type`:沒有 `-ReturnType` 的 method 只實測過 vInfo `$null`(Access PUBLIC、Language ST),`{lang, '', access}` 沒測。這時 vInfo 不帶 language,讀回的語言只回報在 `data.language`,不比對。
  - `accessor-not-measured`:Get / Set 只實測過 vInfo `{'1', 'PUBLIC'}`(實測 2026-10-31 4026 VS2022 自建 client),其他 access 或 language 在 CreateChild 之前就擋。
  - 走樹解析名稱時，命中的項目先讀 ItemType,是 654 / 655 就用「父路徑 + `^Name`」當路徑，不讀它的 `PathName`(`Resolve-TcPouPath`)。
- **下一步**:interface property 的 accessor 改在實作該 interface 的 FB 裡建(`Add-TcPouMember -ParentPath <FB path>^<property> -Kind Get`)並讀寫 `<FB path>^<property>^Get`;method 給 `-ReturnType`,或拿掉 `-Access` / `-Language`;accessor 拿掉 `-Access` / `-Language`,之後需要再用 `Write-TcPouCode` 改。

### POU_WRITE_FAILED

- **現象**:`Write-TcPouCode` 沒寫成。`data.reason`:
  - `empty-not-supported`:`-Declaration ''`(或只有空白)。清空 declaration 沒有實測過，什麼都不寫。以前 `-Implementation ''` / `-Declaration ''` 都回 success、`updated=[]`,實際什麼都沒寫(實測 2026-10-31 4026 VS2022 自建 client)。
  - `empty-not-applied`:`-Implementation ''` 會真的寫入 `ImplementationText = ''` 並讀回(實測 2026-10-31 4026 VS2022 自建 client:COM `ImplementationText = ''` 讀回空字串),讀回不是空的才回此碼(記 `BUILD_REQUIRED`,因為已經呼叫過 setter)。成功時 `data.cleared = true`。
  - `itemtype-unreadable`:讀不到目標的 ItemType,無法排除它是 interface property 的 accessor(654 / 655),所以什麼都不寫(fail-closed)。`Get-TcPouCode` 同樣情況回 `POU_READ_FAILED`、同一個 reason。
  - 沒有 reason:setter 的 COM 例外(檔案唯讀、物件保護、非 ST 物件寫 `ImplementationText` 等，TE1000 §5.29)。setter 已經呼叫過，edit buffer 可能已改，所以照 #65 保守記 `BUILD_REQUIRED`(`[write failed]`,前一段已寫入時 `[declaration+write failed]`)。在呼叫 setter 之前就擋下的(`INVALID_PARAMS`、空的 `-Declaration`、`POU_AMBIGUOUS` 等)不記。
- **下一步**:給完整的 declaration,或不給 `-Declaration`;`Get-TcPouCode -PouPath <path>` 確認內容;COM 例外先 `Get-TcIdeModalDialog` 看 XAE 有沒有 dialog 再重試。action 沒有 declaration(給 `-Declaration` 回 `INVALID_PARAMS`)。

### PLC_LOGGED_IN

- **現象**:`Add-TcPou` / `Add-TcDut` / `Add-TcGvl`(`Add-TcInterface` / `Add-TcPouMember` 走同一個 `CreateChild`,同樣處理，未在真機測)時 PLC 還在 login(online)中,XAE 的 `CreateChild` 回「Cannot add an object because it affects a device you are currently logged into」,什麼都沒建立(實測 2026-10-29,4026 XAE in VS2022,`Add-TcGvl` 接在 `Enable-TcConfig -Force` 之後;`tests/Integration/logs/phase0-1.7-results.md` 發現 4。`Add-TcPou` / `Add-TcDut` 走同一個 `CreateChild`,同樣處理，未在真機測)。以前回 `GVL_CREATE_FAILED`,hint 沒提 login,還記了 `BUILD_REQUIRED`。`Enable-TcConfig -Force` 與 `Invoke-TcTestCycle` 結束時都保持 login,所以 lifecycle 之後直接 Add 很常遇到。`Add-TcLibrary` 在 login 中可以成功。
- **判斷**:`New-TcPlcObject` 以英文關鍵字比對 `CreateChild` 的錯誤訊息(`affects a device you are currently logged in`,或 `cannot add an object ... logged in`);在地化的 XAE 若用別的字句，仍回 `*_CREATE_FAILED`。`CreateChild` 本身回錯誤(不是 IDE_BUSY / IDE_CRASHED / IDE_MODAL_DIALOG / IDE_TIMEOUT)時 XAE 已拒絕、沒有建立物件，所以不記 `BUILD_REQUIRED`(沒有 `data.buildRequired`)。
- **下一步**:先 `Exit-TcPlcOnline`(MCP `PlcLogout`)再重跑同一個 `Add-*`;加完 `Build-TcProject`,再 `Enable-TcConfig -Force` 或 `Enter-TcPlcOnline` 下載。

### MEMBER_ORDER_MISMATCH

- **現象**(#47):`Add-TcDut`(Struct / Union / Enum)或 `Add-TcGvl` 建立物件並存檔後,讀回 XAE 的 declaration、解析出的成員順序(`data.actualOrder`)與輸入順序(`data.expectedOrder`)不同。物件已經在樹上、也存進 .plcproj,並記成 `code-changed`(`BUILD_REQUIRED`)。成功時 `data.memberOrder` 是讀回的順序。
- **為什麼要檢查**:#47 之前成員參數是 `[hashtable]`,PowerShell hashtable 的列舉順序是雜湊順序,STRUCT / GVL / ENUM 成員順序與輸入不同卻回 success(實測 2026-10-28,4026 VS2022 + 本機 UmRT,registered tcauto)。STRUCT 成員順序決定記憶體配置。
- **輸入格式**:成員一律有序:MCP 用陣列 `Fields` / `Variables` = `[{"name":"bStart","type":"BOOL","init":"TRUE","comment":"..."}, ...]`,Enum 為 `[{"name":"eIdle","value":0}, ...]`;PowerShell 另可用 `[ordered]@{ bStart = 'BOOL' }`。一般 `[hashtable]` 超過一個成員 → `INVALID_PARAMS`(不猜順序,什麼都沒建);只有一個成員的 hashtable 可接受。舊的 MCP object 格式(`{"bStart":"BOOL",...}`)已移除,JSON schema 驗證直接回 `INVALID_PARAMS`(JS 的 object key 順序對整數型 key 也不保證)。
- **下一步**:`Write-TcPouCode -PouPath <data.path> -Declaration <正確順序>` 改寫,`Get-TcPouCode` 確認,再 `Build-TcProject`。

### TEMPLATE_NOT_FOUND

- **現象**(#70):`New-TcProject` 找不到 XAE 專案 template `TwinCAT Project.tsproj`,回此碼與 `data.searched`(已查的完整路徑),沒有呼叫 `Solution.Create`(IDE 目前的 solution 沒被關,也不記 `BUILD_REQUIRED`)。
- **為什麼**:`AddFromTemplate` 要完整的 template 檔案路徑。以前傳空字串,4026 回 `STG_E_FILENOTFOUND`、4024 回 `ArgumentException`(實測 2026-10-28,見 #70)。InfoSys「Accessing TwinCAT configuration」的範例用 `C:\TwinCAT\3.1\Components\Base\PrjTemplate\TwinCAT Project.tsproj`,並說明要依環境調整([InfoSys](https://infosys.beckhoff.com/content/1033/tc3_automationinterface/242721803.html))。本機實測 2026-11-05(唯讀查檔案系統):檔案在 `C:\Program Files (x86)\Beckhoff\TwinCAT\3.1\Components\Base\PrjTemplate\`,4024 與 4026 build 並存於同一個 `Components` 下。模組依序找 `$env:TWINCAT3DIR`、registry `HKLM\SOFTWARE\WOW6432Node\Beckhoff\TwinCAT3\TwinCATDir`、Program Files (x86)、Program Files、`C:\TwinCAT\3.1`。PLC 專案的 `CreateChild` 只傳 template 名稱 `Standard PLC Template`(InfoSys「How to create a PLC project」:標準 Beckhoff template 只用名稱,[InfoSys](https://infosys.beckhoff.com/content/1033/tc3_automationinterface/21842439947.html))。
- **下一步**:確認 TwinCAT XAE 已安裝,或把 `TWINCAT3DIR` 設成 TwinCAT 的 `3.1` 目錄後重跑。
- **真機實測 2026-11-05**(4024 32-bit XAE Shell 與 4026.22 XAE in VS2022):建專案用自建 client,Build 用 registered tcauto;兩版都建立成功、`BuildProject` completeBuild、約 5 s、沒有 dialog,新 `.plcproj` 與 Standard PLC Template 的 Compile / Folder / PlaceholderReference 相同。template 是版本中立的 67 bytes 骨架,在共用的 `Components\Base\PrjTemplate` 底下。

### PROJECT_DIR_EXISTS

- **檢查順序**:solution 已開(`SOLUTION_ALREADY_OPEN`)-> template(`TEMPLATE_NOT_FOUND`)-> 資料夾已存在(此碼)-> `Solution.Create`。IDE 開著 solution 又撞到既有資料夾時,先回 `SOLUTION_ALREADY_OPEN`;兩者都不會動到 IDE 或資料夾。
- **現象**(#70):`<Path>\<Name>` 已存在,`New-TcProject` 直接回此碼(`data.path`),沒有呼叫 `Solution.Create`,IDE 的 solution 沒動。
- **為什麼**:template 會把檔案寫進這個資料夾,不重用既有資料夾,避免覆蓋別人的檔案。
- **下一步**:換 `-Name` / `-Path`,或確認舊資料夾沒用後自行刪除再重跑。

### PROJECT_CREATE_UNVERIFIED

- **現象**(#70):`Solution.Create` / `AddFromTemplate` / `CreateChild` / `SaveAs` 都沒丟錯,但讀回缺東西:`.sln`、`.tsproj`、`.plcproj` 不在磁碟上,`.tsproj` 內容沒有 `<Plc>` 節點與指向 `<Name>_Plc.plcproj` 的 `PrjFilePath`(專案沒存檔),或 `TIPC^<Name>_Plc` 找不到。`data.missing` 列出缺的項目。這時 IDE 已開著半成品 solution:模組把 solution 路徑設為未知、移除 #29 session record,並記 `BUILD_REQUIRED`(`<unknown>`,擋所有 solution 直到完整 Build)。
- **為什麼**:以前只要呼叫沒丟錯就回 success,不確定新專案真的存在。實測 2026-11-05(4024 與 4026.22 重驗):`CreateChild` 之後 `.tsproj` 還是 329 bytes 的空骨架、沒有 `<Plc>`,PLC 專案只在 XAE 記憶體,要到第一次 Build 才寫進檔案;success 後不存檔就關 solution,PLC 專案會消失(Build 回 no PLC project)。所以現在先 `Project.Save()` 再 `Solution.SaveAs`(InfoSys「Accessing TwinCAT configuration」範例的順序:[InfoSys](https://infosys.beckhoff.com/content/1033/tc3_automationinterface/242721803.html)),讀回檢查 `.tsproj` 內容而不只是檔案存在。成功判定現在要讀回(fail closed)。這些 COM 呼叫沒有加 wall-clock deadline:它們是無法從外面取消的同步 STA 呼叫,加 deadline 只會放棄一個 IDE 仍在執行的呼叫;整個建立在兩版 XAE 上約 5 s(實測 2026-11-05)。
- **下一步**:`Get-TcIdeModalDialog` 看有沒有 dialog,在 XAE 檢查 `data.path`;通常要關掉 solution、刪掉該資料夾後重跑。

### SOLUTION_ALREADY_OPEN

- **現象**(#70):`New-TcProject` 發現 IDE 已開著 solution(`DTE.Solution.IsOpen` 或 `FullName` 非空;讀不到也當成開著,fail-closed;IDE 回 RPC busy 時改回 `IDE_BUSY`),直接拒絕,沒有呼叫 `Solution.Create`。`data.openSolution` 是目前的 solution(讀不到時為 null)。
- **為什麼**:`Solution.Create` 會不經提示關掉目前的 solution,未存的改動會丟掉(實測 2026-10-28,見 #70:TwinCAT 3.1.4026.22 XAE in VS2022 與 4024 32-bit XAE Shell,registered tcauto,兩者呼叫後 `GetIdeInfo` 的 solution 都變成空字串);template 路徑已改成從安裝目錄解析(見 `TEMPLATE_NOT_FOUND`),2026-11-05 實測 4024 32-bit XAE Shell 與 4026.22 XAE in VS2022 建專案與 Build 成功(建專案用自建 client,Build 用 registered tcauto)。MCP 仍不提供 `NewProject` tool、只保留 cmdlet,剩下的原因是:`Solution.Create` 會關掉 IDE 目前的 solution,而且 cmdlet 還沒有經過 tcauto 本身驗證。
- **下一步**:建議在 XAE 手動建立新專案,再 `Connect-TcIde -SolutionPath <新 .sln>` 接上(MCP 沒有 `NewProject`)。要用 `New-TcProject` 時,先在 XAE 存好並關掉目前的 solution(IDE 不開任何 solution)再呼叫。

### IO_SCAN_REQUIRES_CONFIG / IO_SCAN_FAILED / IO_SCAN_VERIFY_FAILED

- **現象**:`Invoke-TcIoScan` 先讀 system state(ADS port 10000),不是 Config 就回 `IO_SCAN_REQUIRES_CONFIG`(`data.state`),沒有掃描。`IO_SCAN_FAILED` = `ProduceXml(false)` / `CreateChild` / `ConsumeXml` 丟例外;`IO_SCAN_VERIFY_FAILED` = `-Apply` 建立的 device 讀回 I/O tree 時找不到。
- **為什麼**:TE1000 v1.7.0 §6.6.2「Performing a device scan」(p.247)的 Requirements 寫 TwinCAT 要在 Config mode;scan 是在 `TIID` 呼叫 `ProduceXml(false)`,找到的裝置在 `TreeItem/DeviceGrpDef/FoundDevices/Device`。手冊沒寫 Run mode 的行為:實測 2026-10-28(4026 XAE in VS2022,本機 UmRT,自建 client)Run mode 下 `ProduceXml(false)` 不丟錯、立即回空的 `FoundDevices`,看起來像「沒有裝置」,所以模組先檢查狀態。舊版呼叫的 `ProduceScan()` 在手冊裡不存在(`IO_SCAN_FAILED`「未包含名為 'ProduceScan' 的方法」)。
- **下一步**:`Set-TcSystemState -State Config` 後重跑;預設只回 `data.devices`,不改 tree,要加進 tree 用 `-Apply`(CreateChild + AddressInfo + ScanBoxes,依 §6.6.2)。沒有裝置時回 success、`devices = @()` 加 `data.warning`。本機 UmRT 切 Config 可能觸發 #21 crash(見「已知限制」)。

### TREEITEM_NOT_FOUND

- **現象**:`Set-TcVariableLink` / `Remove-TcVariableLink` 呼叫前用 `LookupTreeItem` 檢查兩端;找不到就回這個碼,`data.missingEnd` 與 hint 指出是 `PlcVariable` 還是 `IoChannel`。
- **為什麼**:`LinkVariables` 要完整 tree path(TE1000 v1.7.0 §5.1.1.2,p.38:"The full path name is required")。`MAIN.bIn` 這種 PLC symbol 名稱不是 tree path。`TSM_E_ITEMNOTFOUND` 的數值手冊沒寫,實測 2026-10-28 是 `0x98510001`(4026 XAE in VS2022,訊息 `Item '...' not found`)。
- **下一步**:PLC 端 `TIPC^<Plc>^<Plc> Instance^PlcTask Inputs^MAIN.bIn`(`AT %I*` / `%Q*` 變數,要先 Build 才出現);I/O 端到 variable 那層,例如 `TIID^<Device>^<Box>^<Term>^Channel 1^Input`。用 `Get-TcIoTree` 查 I/O 路徑。
- **通用 tree tool**(`LookupTreeItem` / `ProduceXml` / `CreateChild` / `ConsumeXml` / `DeleteChild` / `ExportChild` / `ImportChild`,cmdlet `Get-TcTreeItem` 等):找不到時往上找最接近的上層路徑,`error.hint` 和 `data.nearestPath` / `data.nearestChildren` 列出它和它的子節點名稱;連第一段都不存在時列出解析得到的頂層節點(TIPC、TIID、TIRC、TIRS、TIRT、TINC 中存在的)。照 hint 改路徑,或對 `nearestPath` 呼叫 `LookupTreeItem` 往下查。hint 裡只寫 cmdlet 名稱(`Get-TcTreeItem -Path '...'`),MCP server 會換成 tool 名稱(`LookupTreeItem Path='...'`);以前寫成「LookupTreeItem (Get-TcTreeItem)」,替換後變成重複的「LookupTreeItem (LookupTreeItem)」(phase1-2.8 #5)。

### 通用 tree tool 的防護與備份(第 1 期,未實測)

`LookupTreeItem`(`Get-TcTreeItem`)、`ProduceXml`(`Get-TcTreeItemXml`)、`CreateChild`(`New-TcTreeItem`)、`ConsumeXml`(`Set-TcTreeItemXml`)、`DeleteChild`(`Remove-TcTreeItem`)、`ExportChild`(`Export-TcTreeItem`)、`ImportChild`(`Import-TcTreeItem`)直接對應 `ITcSysManager::LookupTreeItem`(TE1000 v1.7.0 §5.1.1.3,p.38)與 `ITcSmTreeItem` 的方法(§5.2.1.1~5.2.1.8,p.57~61;[TE1000 PDF](https://download.beckhoff.com/download/document/automation/twincat3/TC3_Automation_Interface_EN.pdf))。共用函式在 `src/TwinCATAutomation/Private/TreeItem/`。

- **防護**(design D2):修改類(`CreateChild`、`ConsumeXml`、`DeleteChild`、`ImportChild`)預設 `DryRun=true`,dry-run 不呼叫任何修改 API;`DryRun=false` 先把 `ProduceXml` 備份到 `<solution 目錄>\.tcauto-backup\<yyyyMMdd-HHmmss>\<路徑安全化>.xml`(`data.backupPath`),再修改,再讀回驗證(`data.verified`)。`Path` 必須是完整路徑,不接受 `*` `?`。`DeleteChild` 要帶 `ConfirmName`。MCP 端修改類標 `destructiveHint: true`。
- **磁碟檔備份**:XAE 改 Task 時會立刻改寫 PLC 專案資料夾裡的 `<task>.TcTTO`(實測 2026-10-30,4026 VS2022,task 2.1,沒有存 solution 也會寫),所以節點對應磁碟檔時一併複製到備份資料夾(`data.backupFiles`)。規則表 `$script:TcTreeItemDiskFileRules`:`TIRT^<task>` → `<task>.TcTTO`;TIPC 底下 ItemType 602/603/604 → `.TcPOU`、606 → `.TcDUT`、615 → `.TcGVL`(檔名慣例,PLC 物件會不會被這些操作改寫未實測)。在 solution 目錄下剛好找到一個同名檔才複製;有多個就不複製,`data.warnings` 說明;找不到時 `.TcPOU` / `.TcDUT` / `.TcGVL` 也會留 warning。Task 找不到 `.TcTTO` 時,掃 solution 目錄下所有 `.plcproj` / `.tsproj` 有沒有提到 `<task>.TcTTO`(字串比對，大小寫不分;PLC Task 在 `.plcproj` 列成 `<Compile Include="PlcTask.TcTTO">`,2026-10-30 讀 4026 副本):有參照但檔案不在 → warning;完全沒有參照 → 不發(`TIRT` 底下直接建立、沒有 PLC 專案的 Task 本來就沒有 `.TcTTO`,registered tcauto 實測 2026-10-30 4026 VS2022,phase1-2.8 #3);掃描失敗 → warning。
- **`.tcauto-backup` 資料夾**會留在 solution 目錄裡,模組不會自動清;不要把它加進版本控制。
- **ConsumeXml 只送片段**(design D3,實測 2026-10-30):XAE 本身就是合併語意,沒列到的欄位保留原值,所以模組直接傳片段,不做整份合併。片段的每個最底層元素路徑都要在目前的 `ProduceXml` 裡找得到(重複的同名元素依位置比對,`CPU[2]`)。讀回比對排除 `TcModuleInstance` 底下的 `Context`、`ParameterValues`(XAE 自己跟著改的衍生欄位,`data.skippedDerived`)。
- **XAE 行為未實測的片段一律在送出前擋掉**(`XML_MERGE_FAILED`,見該節的 `data.reason`):有 attribute、值放在有子元素的節點上、重複元素數量和目前不同、有變動的欄位全是衍生欄位。不猜 XAE 會怎麼合併。
- **寫入後全量比對**:`ConsumeXml` 之後把寫入前、寫入後兩份 `ProduceXml` 全部攤平(element 值和 attribute)比對,片段以外、非衍生的欄位有任何差異就回 `TREEITEM_VERIFY_FAILED`(`data.unexpectedChanges`)。`CreateChild` / `ImportChild` 對父節點做同樣的比對,但只允許「多出來」(新子節點可能出現在父節點 XML 裡,`-Before` 插入會讓 `[n]` 位移),原有的值少了或變了就回 `TREEITEM_VERIFY_FAILED`(`data.parentUnchanged=false`)。例外:父節點的 `TreeItem/ChildCount` 新增一個子節點後一定 +1(registered tcauto 實測 2026-10-30 4026 VS2022 XAE 3.1.4026.22,TIRT 與 TIPC 父節點,phase1-2.8 #1),剛好 +1 不算異動,+2 或其他變化仍然回 `TREEITEM_VERIFY_FAILED`(`kind` = `changed`)。其他欄位沒看到變化。淨值 +1 也可能是「刪一個、加兩個」,所以另外比對子節點名稱：原有名稱都要還在、剛好多一個(`data.childrenAfter`),不符回 `TREEITEM_VERIFY_FAILED`(`data.missingChildren` / `addedChildren`);子節點清單被 `$script:TcTreeItemMaxChildNames` 截斷時跳過這個比對並留 warning。
- **同步 COM 修改呼叫沒有 deadline**(`ConsumeXml`、`CreateChild`、`DeleteChild`、`ExportChild`、`ImportChild`):照 `New-TcPlcObject` 的 `CreateChild` 做法(CODING_STANDARDS §1 的「註解寫明為何不需要」),每次呼叫前先 `Find-TcIdeModalDialog`,有 dialog 就回 `IDE_MODAL_DIALOG`、不呼叫;`Connect-TcIde` 開的 `SilentMode` 讓 XAE 自己用預設值回答提示。這些呼叫的耗時還沒量(task 2.8)。
- **PLC login 中**:XAE 拒絕時回 `PLC_LOGGED_IN`,`error.hint` 是「先 `Exit-TcPlcOnline`(MCP:`PlcLogout`),再重跑同一個 tool」並帶出失敗的操作。`IDE_MODAL_DIALOG`、`IDE_CRASHED`、`IDE_TIMEOUT`、`IDE_BUSY`、`PLC_LOGGED_IN` 這份清單(`$script:TcTreeItemPassThroughCodes`)在錯誤結果和備份步驟共用,一律保留原碼。

### TREEITEM_PATH_INVALID

- **現象**:通用 tree tool 的 `Path` 是空的、有 `*` / `?`、有空段(開頭 / 結尾的 `^` 或 `^^`),或 `DeleteChild` 指到頂層節點。什麼都沒呼叫。
- **為什麼**:修改類 tool 只接受單一、明確的節點(design D2),不做 pattern 比對;`DeleteChild` 是父節點的方法(TE1000 §5.2.1.3),頂層節點沒有父節點。
- **下一步**:用 `LookupTreeItem`(`Get-TcTreeItem`)或 `GetProjectTree`(`Get-TcProjectTree`)查到完整路徑再重試。

### TREEITEM_READ_FAILED

- **現象**:`LookupTreeItem` 找得到節點,但讀它的屬性、子節點或 `ProduceXml` 時 COM 丟例外(不是 IDE_BUSY / IDE_CRASHED / IDE_MODAL_DIALOG,那些會回各自的碼)。什麼都沒改。
- **下一步**:`Get-TcIdeModalDialog` 檢查 dialog,重跑一次;一直失敗就用 `GetProjectTree` 確認節點還在。

### TREEITEM_ALREADY_EXISTS

- **現象**:`CreateChild` 的 `Path^Name`,或 `ImportChild` 帶的 `Name`,已經存在。什麼都沒建立。`ImportChild` 沒帶 `Name` 時,模組從 .xti 推出預期名稱(`data.expectedName`:項目的 `<Name>`,`__FILENAME__` 換成檔名去掉副檔名;.zip 推不出來就跳過，並在 `data.warnings` 說明沒有做撞名檢查;讀檔禁止 DTD、不解析外部 entity,帶 DOCTYPE 的檔案一律當成推不出名稱)做同樣的檢查,dry-run 也會檢查:XAE 遇到撞名會自己改名(`Task28` → `Task28_1`,registered tcauto 實測 2026-10-30 4026 VS2022,phase1-2.8 #4)。實際匯入後名稱和預期不同時寫進 `data.warnings`。
- **為什麼**:手冊沒寫同名時 XAE 會怎麼做(TE1000 §5.2.1.2 / §5.2.1.6 只列 E_NOTIMPL、E_ACCESSDENIED 等),所以模組先擋,不讓 XAE 自己改名或覆蓋。
- **下一步**:換名稱;真的要取代就先 `DeleteChild`(先 dry-run)再建。

### TREEITEM_CREATE_FAILED

- **現象**:`CreateChild` 被 XAE 拒絕。`data.backupPath` 是呼叫前父節點的備份。
- **為什麼**:TE1000 §5.2.1.2(p.57):`E_NOTIMPL` = 這個節點不支援新增子節點;`E_ACCESSDENIED` = 對應的檔案不能編輯。`SubType` / `VInfo` 的意義依父節點而定,沒有完整的公開清單;手冊有寫的例子:`TIRT` 下 Task `SubType` 0 = 有 process image、1 = 沒有(§6.3.1,p.196);`TIID` 下 EtherCAT master 111、box 9099 + `VInfo` 產品型號(§6.6.1,p.244)。
- **下一步**:確認 `Path` 是父節點、`SubType` / `VInfo` 是手冊或 InfoSys 寫的值;有專用 tool(`AddPou`、`AddDut`、`AddGvl`、`IoScan`)就改用它。PLC 在 login 中時會回 `PLC_LOGGED_IN`。

### TREEITEM_VERIFY_FAILED

- **現象**:修改呼叫有返回,但讀回不符:`ConsumeXml` 讀回的值和片段不同(`data.mismatches` 的 `expected` / `actual`),或片段以外的非衍生欄位變了(`data.unexpectedChanges`:`path`、`kind` = `changed` / `removed` / `added`、`before`、`after`;重複元素數量變了會顯示成 removed / added);`CreateChild` / `ImportChild` 之後找不到新節點,或父節點原有的值少了 / 變了(`data.parentUnchanged=false`、`data.unexpectedChanges`,這時新節點已經建立);`DeleteChild` 之後節點還在。`success` 一定是 false。
- **為什麼**:XAE 對未知元素、錯的路徑會回 S_OK 但什麼都不改(實測 2026-10-30,task 2.1);不讀回就會誤報成功(#28 / #32)。
- **密碼欄位**:備份與 ProduceXml 裡的密碼欄位都是 `***`(第 3 期 review S5),**不能拿備份還原密碼**,要在 XAE 重新輸入。
- **下一步**:`ProduceXml` 看目前內容;`data.backupPath` 是寫入前的 XML,`data.backupFiles` 是磁碟檔副本。要還原欄位就把備份裡對應的元素做成片段再 `ConsumeXml`(先 dry-run);刪錯的節點用 `ImportChild` 匯入 `data.exportPath`。

### TREEITEM_DELETE_NAME_MISMATCH

- **現象**:`DeleteChild` 的 `ConfirmName` 是空的,或和節點名稱不同(大小寫也要一樣,`data.nodeName`)。什麼都沒刪,也沒備份。
- **為什麼**:防止路徑打錯或複製錯時刪掉別的節點(design D2)。
- **下一步**:`LookupTreeItem` 確認 `Path` 指到的就是要刪的節點,`ConfirmName` 設成 `data.nodeName`,先 dry-run 再 `DryRun=false`。

### TREEITEM_DELETE_FAILED

- **現象**:`DeleteChild` 被 XAE 拒絕,節點還在。或 `data.reason` = `parent-mismatch`:節點自己回報的 `PathName` 上層(`data.itemParentPath`)和從 `Path` 推算的父節點不同(大小寫也算),沒有呼叫 `DeleteChild`,dry-run 也會擋。
- **為什麼**:TE1000 §5.2.1.3(p.58):`E_NOTIMPL` = 父節點不支援刪除;`E_ACCESSDENIED` = 檔案不能編輯。`DeleteChild(name)` 是父節點的方法,只靠名稱;父節點對不上時可能刪到別的節點底下的同名子節點,所以先擋。
- **下一步**:`Get-TcIdeModalDialog` 檢查 dialog;有專用 tool 就用它。刪除前的備份在 `data.backupPath` / `data.exportPath`。`parent-mismatch`:用 `LookupTreeItem` 確認實際路徑,用節點回報的完整路徑重跑(先 dry-run)。

### TREEITEM_INVALID_VALUE

- **現象**:`ConsumeXml` 片段裡的已知欄位值不合法(`data.invalidFields`:path、value、rule、reason)。什麼都沒送。
- **為什麼**:XAE 不驗證值:`TaskDef/CycleTime` 給 0、負數、文字都會寫入,文字變成 0,負數讓衍生的 UDINT 溢位(實測 2026-10-30,4026 VS2022,task 2.1)。模組用可擴充的規則表 `$script:TcTreeItemFieldRules`(`Private/TreeItem/TreeItemXml.ps1`)自己擋;目前規則:`TreeItem/TaskDef/CycleTime` 必須是 1~4294967295 的整數(單位 100 ns,20000 = 2 ms)。沒有對齊 base time 的值(例如 12345)XAE 也照收,模組不擋(base time 由 target 決定,沒有讀)。
- **下一步**:改成合法的值再送。

### TREEITEM_BACKUP_FAILED

- **現象**:修改前的備份沒寫成:模組不知道 solution 路徑,或 `<solution 目錄>\.tcauto-backup` 無法寫入,或備份前的 `ProduceXml` 失敗。什麼都沒改。`DeleteChild`(`Remove-TcTreeItem`)還要求 `ExportChild` 的備份(`.xti`;`TIPC` 底下一律用 `.zip`:XAE 對 PLC folder 的 `.xti` 檔名回 "doesn't specify a zip archive",registered tcauto 實測 2026-10-30 4026 VS2022 僅 PLC folder;其他 TIPC 節點未測;猜錯時 export 失敗、不會刪,phase1-2.8 #2):`ExportChild` 丟例外(`data.reason` = `export-failed`)或返回了但檔案不存在(`export-missing`)也回這個碼,不刪。備份步驟遇到 `IDE_*` / `PLC_LOGGED_IN` 時回那個碼,不是這個。
- **為什麼**:`DeleteChild` 刪掉的是整個子樹;`ProduceXml` 備份(`DeleteChild` 前用 recursive,含子樹)只能看,不能用 `ImportChild` 還原,只有 `.xti` / `.zip` 能。
- **下一步**:`Connect-TcIde -SolutionPath <sln>`(或 `Open-TcProject`)讓模組記住 solution 路徑,確認目錄可寫,再重試。`export-failed` / `export-missing`:先用 `ExportChild`(`Export-TcTreeItem`)匯出同一個節點找原因;確定只要 `ProduceXml` 備份就夠時,才加 `AllowNoExport=true`(cmdlet:`-AllowNoExport`)重跑,結果的 `data.warnings` 會註明刪除時沒有 `.xti`。

### TREEITEM_EXPORT_FAILED

- **現象**:`ExportChild` 沒產生檔案。`data.reason`:`not-absolute`、`invalid-path`(路徑有 `< > | " * ?` 等非法字元、`GetFullPath` 不接受,或沒有檔名,例如 `C:\`)、`file-exists`、`folder-missing`(這四個在呼叫 XAE 前就擋,路徑檢查不會變成 `EXECUTION_ERROR`)、`plc-requires-zip`(查到節點後:`TIPC` 底下的 PLC folder,ItemType 601,但 `FilePath` 不是 `.zip`;`data.itemType`;其他 TIPC 節點不擋，交給 XAE)、`file-not-written`(XAE 返回了但檔案不存在或是空的),或 XAE 丟例外。
- **為什麼**:TE1000 §5.2.1.4(p.58):目標資料夾必須存在、檔案不能已存在,否則 `E_INVALIDARG`;空路徑的行為手冊只寫「default behavior」,所以模組要求絕對路徑。`TIPC` 底下的 PLC folder XAE 只接受 `.zip` 檔名,`.xti` 會回 "The filename '...' doesn't specify a zip archive!";同一節點匯出成 `.zip` 再 `ImportChild` 可以匯回(registered tcauto 實測 2026-10-30 4026 VS2022 僅 PLC folder;其他 TIPC 節點未測,XAE 3.1.4026.22;TE1000 §5.2.1.4 沒寫)。
- **下一步**:換一個新的檔名重試:一般節點用 `.xti`,PLC folder 用 `.zip`(`plc-requires-zip` 的 hint 直接給出改好的檔名);其他 TIPC 節點 XAE 回 zip 的錯誤時也改用 `.zip`。

### TREEITEM_IMPORT_FAILED

- **現象**:`ImportChild` 沒有匯入:`data.reason` 是 `not-absolute` / `invalid-path`(非法字元、沒有檔名,例如 `C:\`)/ `file-missing`,或 XAE 拒絕。
- **為什麼**:TE1000 §5.2.1.6(p.59):`NTE_NOT_FOUND` = 沒有可匯入的項目,`TSM_E_ITEMNOTFOUND` = `Before` 找不到,`E_FAIL` = XML 載入、類別檢查或插入失敗(細節在 COM 錯誤訊息)。
- **下一步**:確認檔案是 `ExportChild` 匯出的(PLC folder 是 `.zip`,實測 2026-10-30 4026 VS2022 僅 PLC folder;其他 TIPC 節點未測),`Path` 是能放這種節點的父節點(例如 Task 匯入到 `TIRT`,I/O device 到 `TIID`,§6.3.2)。

### XML_MERGE_FAILED

- **現象**:`ConsumeXml` 的片段沒有送出,或送出後 XAE 拒絕。`data.reason`:`syntax`(XML 語法錯)、`root`(根元素不是 `<TreeItem>`)、`empty`(沒有任何元素)、`paths-not-in-current-xml`(`data.missingPaths` 裡的元素路徑在目前的 `ProduceXml` 不存在);XAE 拒絕時沒有 `reason`,`data.written=false`,`data.backupPath` 有備份。以下四種 XAE 怎麼合併未實測,模組在送出前就擋(dry-run 也擋),不猜:
  - `attributes-not-supported`:片段有 XML attribute(含 `xmlns`,`data.attributePaths`)。目前只支援 element 值。
  - `structure-mismatch`:片段的最底層元素在目前的 XML 是有子元素的節點,例如 `<TreeItem><TaskDef/></TreeItem>`、`<TaskDef>123</TaskDef>`;或片段在有子元素的元素裡放了文字(`data.structurePaths`)。
  - `repeated-count-mismatch`:同名重複元素的數量和目前的 XML 不同,例如目前有兩個 `CPU`,片段只放一個(`data.repeatedCountMismatches`:`path`、`fragmentCount`、`currentCount`)。
  - `secret-only`:片段有變動的欄位全是密碼欄位(元素或 attribute 名稱含 `password` / `passwd` / `pwd`,`data.secretPaths`)。所有 ProduceXml 都把密碼遮成 `***`,寫入後無法讀回，片段值是 `***` 也不能當成「沒變」(送出會把密碼改成 `***`),所以不送。片段裡同時有可驗證的欄位時照送，密碼欄位不比對、寫進 `data.warnings` / `data.skippedSecret`,`data.changes` 的值一律是 `***`。
  - `derived-only`:片段有變動的欄位全是 `TcModuleInstance` 底下的 `Context` / `ParameterValues`(`data.derivedPaths`);XAE 會依來源欄位重算,讀回也不比對,所以等於沒驗證。片段裡同時有來源欄位和衍生欄位時照送,`data.warnings` 註明衍生欄位不驗證。
- **值的比對**(讀回、全量比對):先去頭尾空白做 Ordinal(區分大小寫)比對;不同時,兩邊都能解析成數字才比數值(十進位,或 `#x` 十六進位,前綴不分大小寫,例如 `#x1E` = `#x1e` = `30`);其他文字一律區分大小寫。
- **為什麼**:實測 2026-10-30(4026 VS2022,task 2.1):根元素錯回 `E_FAIL`「No TreeItem found.」,語法錯回 `E_FAIL`,都不會部分寫入;**未知元素或錯的路徑回 S_OK 但什麼都不改**,呼叫端看不出來,所以模組在送出前先比對路徑。
- **下一步**:先 `ProduceXml`,路徑照抄,只放要改的欄位,例如 `<TreeItem><TaskDef><CycleTime>40000</CycleTime></TaskDef></TreeItem>`。`repeated-count-mismatch` 時把那一組重複元素照目前的數量和順序全部抄進片段;`attributes-not-supported` 時拿掉 attribute;`derived-only` 時改送來源欄位(例如 `TaskDef/CycleTime`)。

### LINK_INVALID_ITEM_TYPE / LINK_TYPE_MISMATCH / LINK_FAILED / UNLINK_FAILED

- **為什麼**:TE1000 §5.1.1.2(p.38)列出 `LinkVariables` 的錯誤:`TSM_E_INVALIDITEMTYPE`(有一端不是 variable)→ `LINK_INVALID_ITEM_TYPE`;`TSM_E_MISMATCHINGITEMS`(型別 / 大小不相容)→ `LINK_TYPE_MISMATCH`。這兩個的數值手冊沒寫,模組用 HRESULT 名稱或訊息文字判斷;都不符時回 `LINK_FAILED`(Unlink 是 `UNLINK_FAILED`)。`0x98510004` "'<a>' and '<b>' do not match"(input 接 input)也對到 `LINK_TYPE_MISMATCH`(自建 client 實測 2026-11-01 4026 VS2022,phase3-probe 第 5 題)。
- **下一步**:I/O 端給 `^Channel 1^Input` 而不是 `^Channel 1`;兩端型別大小要相同。

### LINK_VERIFY_FAILED

- **現象**:`LinkVariables` / `UnlinkVariables` 有返回,但 `ProduceMappingInfo()` 讀回的 mapping 沒有這條 link(或刪除後還在,`data.remainingLinks`),或 mapping 讀不到。
- **為什麼**:不讀回就回 `linked = true` 是假成功(#28 / #32)。`ProduceMappingInfo` 出處:TE1000 §5.1.3.4(p.45);XML 是 `<VarLinks><OwnerA Name><OwnerB Name><Link VarA VarB/>`,VarA / VarB 是相對 Owner 的路徑(§6.3.14,p.218)。
- **下一步**:在 XAE 看該變數的 link,或重跑一次;不要當成功。

### LOGOUT_FAILED

- **為什麼**:`Exit-TcPlcOnline` 的 Logoff COM 呼叫丟例外(IDE busy、modal dialog),或呼叫返回後讀回的登入狀態(`Get-TcPlcLoginState`:`ITcPlcOnline.IsLoggedIn`,讀不到改用 `<Plc> Project` 的 ProduceXml `IECProjectDef/OnlineSettings/LoggedIn`)仍是 true 或讀不到(`data.loggedIn` = true / null;CODING_STANDARDS §2:沒有讀回就不算成功,#232)。PLC 已登出**不會**造成這個錯誤:先讀回是 false 就直接回 success、`data.alreadyLoggedOut = true`、不送 Logoff;未登入時呼叫 `Logoff()` 本身也不報錯。
- **方法在哪個節點**:方法名是 `Logoff()`(不是 `Logout()`)。實測 2026-11-13(TwinCAT 3.1.4026.22、VS2022、本機 UmRT):`Get-Member` 在 `TIPC^<Plc>` 列出 Login / Logoff、`<Plc> Project` 沒有 Log* 方法,但實際呼叫 `TIPC^<Plc>.Logoff()` 失敗(does not contain a method named 'Logoff'),`<Plc> Project`.Logoff() 才登出(LoggedIn true → false)。Ming 的結果相同(實測 2026-11-11,4026.27 TcXaeShell 64-bit、本機 XAR(Windows RT target),#232)。2026-10-18 的舊紀錄只看了 `Get-Member`,結論相反,已更正。`data.logoutVia` 說明實際走哪條;舊版 `TIPC.Child(1).Object.Logout()` 永遠失敗。4024 專案(BFH-1650 副本、32-bit TcXaeShell `TcXaeShell.DTE.15.0`、本機 UmRT,實測 2026-11-13)結果相同:`TIPC^<Plc>.Logoff()` 丟例外,`<Plc> Project`.Logoff() 登出;未登入時呼叫 `<Plc> Project`.Logoff() 也不報錯。
- **下一步**:`Get-TcPlcState` 確認;IDE 有 dialog 就關掉再試;不用重連 IDE。

### NO_PROJECT

- **為什麼**:已連 IDE,但 `ITcSysManager` 拿不到(solution 內沒 TwinCAT 專案,或還沒開 solution)。
- **下一步**:`Open-TcProject -Path <sln>` 或重跑 `Connect-TcIde -SolutionPath <sln>`。

### LOGIN_FAILED

- **為什麼**:`Enter-TcPlcOnline` 的 `ITcPlcIECProject::Login(PLC_LOGIN_FLAGS)` 失敗。系統在 Config 模式、上次 build 沒過、target 沒有 PLC license、跳出 dialog、或旗標互斥。
- **讀回(#232)**:`Login()` 沒丟例外不算登入。返回後用 `Get-TcPlcLoginState` 讀回,`data.loggedIn` = true 才 success;false 或讀不到(null)都回 `LOGIN_FAILED`(fail closed,CODING_STANDARDS §2)。實測 2026-11-13(4026.22 VS2022、本機 UmRT、PLC 已在 Run):`-SilentFlag`(Login 257)回來後 LoggedIn 仍是 false,舊版會回 success。`Enable-TcConfig` 的 login 步驟沿用這個讀回值(`data.plcs[].loggedIn`)。
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

### LICENSE_MISSING

- **碼與 hint**:`LICENSE_MISSING`(#49)。以 `error.code` 為準;`error.message` 開頭加上 `LICENSE_MISSING: `,後面是原本的訊息(PR #259)。`data.licenseMissing.evidence` 是認出它的文字(dialog 標題 + 內文,或這次步驟的錯誤訊息,最多 300 字),`data.licenseMissing.originalCode` 是原本會回的碼(`IDE_MODAL_DIALOG`、`SYSTEM_STATE_TIMEOUT`、`SYSTEM_STATE_MISMATCH`、`RUNTIME_STATE_MISMATCH`…)。
- **現象**:Activate / 切 Run 之後 target 的 runtime 回報 license 不足,XAE 跳「Target system reports a fatal error」,內文是 runtime 自己的訊息,實測 2026-11-11(VS2022 + 4026 + 本機 UmRT,trial 到期):`Target system reports a fatal error: 'TwinCAT System' (10000) >> license not found << checking TwinCAT Licenses!`。這個 dialog 會跳到**所有**連這個 target 的 XAE(實測 2026-10-25,4024 32-bit XAE Shell 與 4026 VS2022 同時連本機 UmRT)。
- **怎麼認(不依賴 XAE 介面語言)**:文字裡同時有 `(10000)`(接在 `'TwinCAT System'` 後面,半形或全形括號;這個數字和 TwinCAT system service 的 ADS port 同號,XAE 用它代表什麼 InfoSys 沒寫,未確認)**和** license 字樣(`license` / `licence` / `Lizenz` / 授權 / 授权 / ライセンス,不分大小寫)。實測過的只有上面的英文 runtime 文字(zh-TW VS2022 也是英文);德文 / 中文 / 日文字樣是推論,只有單元測試。只有 `(10000)` 不算:ADS 1809 的 fatal error 也是 `'TwinCAT System' (10000)` 開頭(#194);沒括號的 10000(例如「ADS port 10000」)也不算。同一條規則在模組(`Private/LicenseMissing.ps1`)和 MCP server(`lib/modal-probe.js` 的 `licenseDialogEvidence`)。
- **哪裡會回**:
  - `Enable-TcConfig`(含 `Start-TcLifecycle` / MCP `RunLifecycle` 的 EnableConfig 步驟):Activate 期間 watchdog 看到的 dialog、set-run 失敗後 `data.diagnostics` 的 dialog、login 前 / `verify` 的 dialog 檢查。碼在**寫 lifecycle block 之前**就換掉,所以 block 的 `errorCode` 也是 `LICENSE_MISSING`;`IDE_CRASHED` / `RUNTIME_CRASHED` 不換。判斷時 dialog、步驟原本的錯誤訊息各自看,不會把不同來源拼在一起湊出 `(10000)` + license。set-config 之前 dialog 就已經在:什麼都沒送,回 `LICENSE_MISSING` 但不記 block。
  - `Set-TcSystemState -State Run`(MCP `SetSystemState`):停在 Config 的診斷(#194)看到 license 的 dialog 時。block 在診斷之前已經寫好(PR #200 的順序),所以 block 的 `errorCode` 仍是原本的 `SYSTEM_STATE_TIMEOUT` / `SYSTEM_STATE_MISMATCH`,回傳的 `error.code` 是 `LICENSE_MISSING`。hint 先放 license 的處理,診斷自己的 hint 接在後面(`Diagnostics hint:`),不會被丟掉。
  - **Error List 的 license 列只當參考,不改碼(PR #259)**:Error List 的 runtime log 列可能是之前 Activate 留下的(跨 Activate 會不會保留沒有實測),拿它改碼會把後來別的失敗(`BOOT_PACKAGE_MISMATCH`、ADS 1809、`RUNTIME_STATE_MISMATCH`…)誤報成 license、還丟掉原本的 hint。所以只有**現在跳著的 dialog** 或**這次步驟的錯誤訊息**才改碼;Error List 有 license 列時,碼和 hint 照原樣,只加 `data.licenseErrorListEvidence`(那一列),hint 最後加一段參考說明。dialog 跳著時 Error List 本來就不讀(#198)。實際 license 不足時 XAE 會跳 dialog(實測 2026-11-11),所以這條路徑仍會回 `LICENSE_MISSING`。
  - **模組直接呼叫 vs MCP**:直接呼叫模組時,只有 `Enable-TcConfig` / `Set-TcSystemState -State Run` 回 `LICENSE_MISSING`;其他 cmdlet(`Build-TcProject`、`Enter-TcPlcOnline`、tree / library 工具…)遇到同一個 dialog 照舊回 `IDE_MODAL_DIALOG`(`ConvertTo-TcAdsErrorCode` 不改碼,各處「IDE 被擋住」的碼清單才維持有效);只有上面兩條 lifecycle 路徑和 MCP modal probe 會回 `LICENSE_MISSING`。透過 MCP 時,probe 涵蓋的工具(下一條)在 bridge 被 dialog 卡住時也回 `LICENSE_MISSING`;沒被 probe 涵蓋、或模組自己先掃到 dialog 而回的 `IDE_MODAL_DIALOG`(例如 `BuildProject` 開始前的 dialog 檢查)碼不變。`data.dialogText` 有 license 字樣時一樣照本節處理。
  - MCP server 的 modal probe(`BuildProject`、`EnableConfig`、`PlcLogin`、`SendPlcProgram`、`RunTestCycle`、`OpenProject`、`ConnectIde`):照舊殺掉 bridge(`data.bridgeRestarted = true`),只是回 `LICENSE_MISSING` 而不是 `IDE_MODAL_DIALOG`,`data.licenseMissing.originalCode = IDE_MODAL_DIALOG`;MCP log(`notifications/message`)也帶 `licenseMissing.evidence`。被殺的 EnableConfig / SetSystemState 在下一次 lifecycle 檢查轉成 `errorCode = INTERRUPTED` 的 block(#236,見「LIFECYCLE_BLOCKED」),不會因為改了碼就被繞過。
- **不按 dialog**:license / security code 類視窗一律由使用者處理,模組與 MCP server 都不按、不關、不續 trial。
- **下一步**:停下回報使用者(Failure contract),不要重跑 `Enable-TcConfig` / `Set-TcSystemState`,也不要用 raw ADS / COM / GUI 繞過。使用者在 XAE 關掉 fatal error 視窗(關掉後被中斷的 Activate 可能還會跑完或只套用一部分),到 SYSTEM > License > Order Information (Runtime) 分頁按「7 Days Trial License...」,照對話框顯示的 security code 輸入([InfoSys: Creating trial licenses manually](https://infosys.beckhoff.com/content/1033/tc3_licensing/3510308491.html))或啟用正式授權;之後 `Get-TcSystemState` 讀回,使用者同意後 `Clear-TcLifecycleBlock -Reason ...`(MCP `ClearLifecycleBlock`),再 `Enable-TcConfig -Force`。不要改 license 檔。
- **為什麼不在 Activate 前預檢**:InfoSys 沒有「Activate 前從工程端唯讀得知 target license 夠不夠」的方法。license 檢查是 runtime 啟動的一部分,沒在跑的 runtime 沒有目前的 license 資訊([InfoSys: Querying the OEM application license in a PLC application,「The license check is part of the TwinCAT Runtime startup process」](https://infosys.beckhoff.com/content/1033/tc3_security_management/3297369483.html));license server port 30 只記了 port 號,IG / IO 沒有記載([InfoSys: ADS port 30](https://infosys.beckhoff.com/content/1033/tc3_ads_intro/116159883.html),`Get-TcLicenseDiagnosis` 用的 IG 是實測);專案需要哪些 license 只有 XAE 的 Project Licenses 分頁([InfoSys](https://infosys.beckhoff.com/content/1033/tc3_licensing/2537314187.html)),沒有 AI / ADS 介面。所以無法判定「確定不足」,只做事後分類。查證紀錄見 #49。
- **驗證**:license 失效路徑只有單元測試(`tests/Unit/license-missing-49.ps1`、`systemstate-diagnostics-194.ps1` case N / N2 / N3、`mcp-server/test/server.test.js` / `modal-probe.test.js` 的 #49 case),不在真機上讓 license 失效。

### ACTIVATE_FAILED

- **現象**:`Enable-TcConfig`(含 `-Force` 流程,停在 activate 那一步,`data.steps[]` 看得到;`data.solutionPlatform` 是當時的 active solution platform)回 `ACTIVATE_FAILED`。`ActivateConfiguration()` 約 2 s 無例外返回,XAE Output 視窗只有「Check config failed!」,`SolutionBuild.LastBuildInfo` 由 0 變 1;target 上什麼都沒寫(UmRT 的 `Boot\CurrentConfig.xml` 沒更新,只有 `Boot\Plc\Port_851.*`),port 851 維持 Invalid(不經此檢查就會變成 `PLC_NOT_LOADED`)。
- **為什麼**:4026 XAE 在 Activate 時檢查 active solution platform 與 target platform。本機 UmRT_Default 是 user mode 的 TcOsSys(Usermode Runtime),target platform 是 `TwinCAT OS (x64)`;solution platform 卻是 `TwinCAT RT (x64)` 時 XAE 顯示訊息框「Active solution platform 'TwinCAT RT (x64)' differs from current target platform 'TwinCAT OS (x64)'! Adjust solution platform and retry.」。`SilentMode` 開著時框被自動關掉,於是只剩 `LastBuildInfo > 0`(模組據此回這個碼);`SilentMode` 關著時框一直在,`ActivateConfiguration()` 阻塞到框被關(實測 102 s)。
- **platform 怎麼來的**(實測,issue #16 調查,4026 XAE;只有下面這組對照,沒有官方出處):原專案的 target 199.4.42.250.1.1 在這台 PC 連不到 → 選 `TwinCAT RT (x64)`;tsproj target 改成 199.5.42.250.1.1(UmRT)→ 選 `TwinCAT OS (x64)`(只翻 `TargetNetId` + 刪 `.vs` 驗證)。`Set-TcTarget`(`SetTargetNetId`)**不會**事後改 platform。這就是 2026-10-18 B 組「Target system reports a fatal error」的根因(issue #16)。已試過、無影響:`<Settings NonWinCpus/Cpu CpuId>` isolated core、tsproj `TcVersion`、UmRT `TargetFeatures.xml`。
- **模組現在先擋**:`Enable-TcConfig` 在 Activate 前比對 solution platform 與 target platform(target 的 TARGETINFO,讀不到時用 `-Platform`),不一致就切換並重新 Build(`platform-fix` / `platform-fix-build`)。所以這個碼現在只會出現在 `data.platformCheck = 'skipped'`(target 不支援 TARGETINFO、又沒給 `-Platform`;`data.warning` 有說明)或其他 Check config 失敗原因。
- **lifecycle block(#68)**:`Enable-TcConfig` 回 `ACTIVATE_FAILED` 時 Activate 已送出，會留 lifecycle block(見「LIFECYCLE_BLOCKED」)。換 platform 重跑前先回報使用者，使用者同意後 `Clear-TcLifecycleBlock -Reason '<理由>' -FallbackMethod '<方法>' -AllowedSideEffects '<副作用>' -MaxVerifyLevel <層級>`,否則下一次 `Enable-TcConfig` 回 `LIFECYCLE_BLOCKED`。
- **下一步**:(先完成上面的核准與 Clear)`Enable-TcConfig -Force -Platform 'TwinCAT OS (x64)'`(會自己切換 + Build),或 `Set-TcTarget -AmsNetId <id> -Platform 'TwinCAT OS (x64)'`(Windows RT target 用 `'TwinCAT RT (x64)'`)再 `Build-TcProject` + `Enable-TcConfig -Force`。MCP:`RunLifecycle` 加 `Platform`,或 `SetTarget` / `EnableConfig` 的 `Platform`。
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
- **為什麼**:名稱拼錯,或 solution 沒有這個 solution platform。列的是真正的 solution platform(`SolutionConfiguration2.PlatformName`,[Microsoft Learn](https://learn.microsoft.com/en-us/dotnet/api/envdte80.solutionconfiguration2?view=visualstudiosdk-2022);VS2022 經 PowerShell 讀回 `$null` 時改依 index 對應 .sln 的 `SolutionConfigurationPlatforms`,只在行數與 configuration 名稱都對得上、solution 已存檔、active 那行等於 ActiveConfig 時採用,否則候選比對退回舊做法:第一個 SolutionContexts 的 project platform,`data.platformMatchedBy = 'projectPlatform'`;這時 `availablePlatforms` 只列讀得到的 solution platform(可能是空的),見下方「platformMap 不可靠」)。實測 2026-10-22(TcXaeShell 15.0 / VS2022,TwinCAT 3.1.4026.22)。名稱存在但 .tsproj 對到別的 project platform 的是 `PLATFORM_PROJECT_MISMATCH`,不是這個碼。platform 是 target 回報的時候,message / hint 會註明「read from the target」。
- **下一步**:用 `availablePlatforms` 的名稱重跑 `Set-TcTarget -AmsNetId <id> -Platform <name>`;UmRT(Usermode Runtime)是 `'TwinCAT OS (x64)'`,Windows RT 是 `'TwinCAT RT (x64)'`;`-Configuration` 預設 `Release`。solution 沒有該平台就在 Configuration Manager 新增(.tsproj 與 PLC 專案對到同名 project platform)。

### PLATFORM_PROJECT_MISMATCH

- **現象**:`Set-TcTarget -Platform <name>`(或 target 回報的平台、`Enable-TcConfig` 的自動切換 `platform-fix`)回 `PLATFORM_PROJECT_MISMATCH`;**什麼都沒切換**(目標已經是 active 也照樣檢查)。`data.projectCheck = 'mismatch'`、`data.requestedProjectPlatform`(目標 solution platform 底下 .tsproj 的 project platform)、`data.platformMap`(該 configuration 每個 solution platform → `{ solutionPlatform; solutionPlatformSource; projectPlatform; projectPlatforms = [{ project; platform; shouldBuild }] }`;讀不到 solution platform 的項目 key 是 `<unknown #N>`,見下方「platformMap 不可靠」),hint 列出 .tsproj 真的編給目標平台的 solution platform。
- **為什麼**:solution platform 名稱對了,但 Configuration Manager 把它底下的 TwinCAT 專案(.tsproj)對到另一個 project platform。實例(A 組 Festo,實測 2026-10-22,TcXaeShell.DTE.15.0):solution `Release|TwinCAT OS (x64)` → `TwinCAT_Festo.tsproj` 與 `plc.plcproj` 都是 project platform `TwinCAT OS (ARMT2)`、ShouldBuild=False。切過去 Build「成功」卻什麼都沒編,Activate 不回 `ACTIVATE_FAILED`,851 維持 Invalid。target platform 決定 configuration 編給哪種 target,Configuration Manager 決定子專案是否參與 build:[InfoSys「Setting the TwinCAT target platform」](https://infosys.beckhoff.com/content/1033/tc3_automationinterface/650882187.html)。solution platform 與 project platform 的差別:`SolutionConfiguration2.PlatformName` 是 solution platform,`SolutionContext.PlatformName` 是 project platform([Microsoft Learn](https://learn.microsoft.com/en-us/dotnet/api/envdte.solutioncontext.platformname?view=visualstudiosdk-2022))。
- **下一步**:XAE 的 Build > Configuration Manager,選該 solution platform,把 TwinCAT 專案(.tsproj)與 PLC 專案的 Platform 欄改成正確的 project platform(沒有就 `<New...>` 新增)並勾 Build,存檔後重跑 `Set-TcTarget -AmsNetId <id> -Platform '<platform>'`;或改選 `data.platformMap` 裡 project platform 正確的 solution platform。專案不能改、只想照目前平台跑:`Set-TcTarget -NoPlatformSwitch`(`Enable-TcConfig -NoPlatformFix` 則回 `PLATFORM_MISMATCH`)。
- **沒有 .tsproj context**(讀不到 TwinCAT 專案)時不擋:`data.projectCheck = 'no-tsproj'`,照舊切換。
- **`Enable-TcConfig` 刻意擋下**:target 有 TARGETINFO(或給了 `-Platform`)時,`Enable-TcConfig` 的自動切換同樣回這個碼,且沒有逃生口(`-NoPlatformFix` 時:solution platform 名稱不同回 `PLATFORM_MISMATCH`,名稱相同只差 project platform 也回 `PLATFORM_PROJECT_MISMATCH`),只能修專案設定。target 沒有 TARGETINFO 時:`Set-TcTarget -NoPlatformSwitch` 只設 NetId、`Enable-TcConfig` 不帶 `-Platform`,照專案目前的平台跑。
- **data**:`data.projectPlatform` 是操作後實際 active 的 .tsproj project platform(這個碼:沒動的那個),`data.requestedProjectPlatform` 是目標 solution platform 底下的(Festo:`TwinCAT OS (ARMT2)`)。

### platformMap 不可靠(platformMapReliable = false)

- **現象**:`Set-TcTarget` / `Enable-TcConfig` 的 `data.platformMapReliable = false`,`data.platformMapReason` 說實際原因(依 `SlnUnusableReason`,例 `Solution.Saved read back False, ...; SolutionConfiguration2.PlatformName read back empty`);`data.platformMap` 有 `<unknown #N>` key(N = 該項在 SolutionConfigurations 的 index),項目的 `solutionPlatform = null`、`solutionPlatformSource = 'unknown'`,`projectPlatform` 是第一個 context 的 project platform(只供參考,**不是** solution platform 名稱);`data.availablePlatforms` 只列讀得到的 solution platform(可能是空的);`data.platformMatchedBy = 'projectPlatform'`。同一個 configuration 名稱有兩項回報同一個 solution platform 時(實際 solution 沒見過),第二項 key 為 `<duplicate #N>`,`platformMapReliable = false`(reason 對應 `duplicate-platform`)。全部讀得到且不重複時 `platformMapReliable = true`、`platformMapReason = null`。
- **為什麼**:VS2022 經 PowerShell 讀不到 `SolutionConfiguration2.PlatformName`(實測 2026-10-22,VisualStudio.DTE.17.0),模組改依 index 對應磁碟上 .sln 的 `SolutionConfigurationPlatforms`。對應不上就不採用(原因與 `Get-TcSolutionConfigurations` 的 `SlnUnusableReason` 一致):solution 未存檔(`unsaved`,磁碟上的 .sln 可能不是 IDE 載入的那份)、.sln 或該 section 讀不到(`sln-unreadable`)、行數或 configuration 名稱不符(`sln-mismatch`)、active 那行不等於 ActiveConfig(`anchor-mismatch`)。實例(#110,實測 2026-11-03,VS2022 zh-TW + TwinCAT 4026):`ConsumeXml TIPC^<PLC> <Disabled>false</Disabled>` 後呼叫 `SetTarget`,9 個 solution platform 全部變 unknown。原因是 `Solution.Saved = False`:實測 2026-11-04(VS2022 VisualStudio.DTE.17.0 + TwinCAT 4026,registered tcauto,[紀錄](../openspec/changes/complete-automation-interface/verification/issue110-realmachine.md))`ConsumeXml <Disabled>false</Disabled>` 後不存檔呼叫 `SetTarget`,`platformMapReason` 讀回 unsaved(不是 anchor-mismatch / sln-mismatch),key `<unknown #9>`~`<unknown #17>`、`availablePlatforms = []`,切換本身成功(projectCheck ok);接著 `BuildProject` 寫回 .sln(mtime = Build 開始時刻),再 `SetTarget` 回到 reliable = true、9 個平台。不是每種修改都會讓 Saved 變 False(未存的 `CreateChild` 之後 `Solution.Saved` 仍是 True,見「磁碟改檔的正確做法」的表),所以 `platformMapReason` 照實際的 `SlnUnusableReason` 給,不預設是 unsaved。舊版把這些項目用 project platform 名稱當 key(撞名加 `(#N)`),`availablePlatforms` 也混進 project platform 名稱;現在改成 `<unknown #N>` 並標示不可靠。TcXaeShell 15.0 讀得到 `PlatformName`(實測 2026-10-22);64-bit XAE Shell(`TcXaeShell.DTE.17.0`)已存檔時 9 項的 source 都是 `sln`(實測 2026-11-04,同上紀錄),也就是同樣依 .sln 對應，未存檔時的行為沒測。
- **切換行為不變**:候選仍依 project platform 比對(`platformMatchedBy = 'projectPlatform'`),每個候選切換後讀回 solution platform 與 .tsproj project platform 驗證,讀回不符就換下一個 / 還原(`PLATFORM_SET_FAILED`)。所以切換結果仍可信,只有 `platformMap` / `availablePlatforms` 這份「清單」不完整。
- **下一步**:要完整的 map 時先存檔再重跑 `Set-TcTarget`:XAE File > Save All,或 `Build-TcProject`(實測 2026-11-04,VS2022 VisualStudio.DTE.17.0 + TwinCAT 4026,registered tcauto:Build 寫回 .sln,之後 `Set-TcTarget` 回到 reliable = true;XAE Shell 沒測這一步)。模組不會自己存檔。`PLATFORM_NOT_FOUND` / `PLATFORM_PROJECT_MISMATCH` / `PLATFORM_MISMATCH`(`Enable-TcConfig -NoPlatformFix`)的 hint 在不可靠時會附上原因與這個建議。

### PLATFORM_SET_FAILED

- **為什麼**:`SolutionConfiguration.Activate()` 之後(實測同步生效,~30 ms),最多 3 s 內讀回的 solution platform(`Solution.Properties('ActiveConfig')`)或 .tsproj 的 project platform 不是要求的那個(切換沒生效,或 XAE 有 dialog)。模組會 `Activate()` 切換前的 configuration 還原,`data.restored = true/false`(已是 active、沒切換時為 null)。只要 solution platform 讀得到(`ActiveConfig` / `PlatformName`),讀回就一律要求它等於目標;solution platform 未知(VS2022 且 .sln 對不上)時依 project platform 找到的候選會逐一 Activate 驗證。
- **下一步**:`Get-TcIdeInfo` 看 `solutionPlatform`;`Get-TcIdeModalDialog` 檢查 dialog;必要時在 XAE 工具列的 Solution Platforms 下拉手動選,再重跑 `Set-TcTarget -Platform`。

### PLC Disabled = active configuration 的 Build.0(#67)

- **機制(實測 2026-11-03,4026 VS2022 + TcXaeShell 64-bit,registered tcauto,[紀錄](../openspec/changes/complete-automation-interface/verification/issue67-realmachine.md))**:4026 的 PLC `Disabled`(`ITcSmTreeItem.Disabled`、ProduceXml `TreeItem/Disabled`)不是獨立屬性，是「目前 active solution configuration 有沒有該 .plcproj 的 `Build.0`」(DTE `SolutionContext.ShouldBuild`)。XAE 停用 PLC 時只拿掉 **active configuration** 的 `Build.0`,其他 configuration 的 `Build.0` 都還在;.tsproj 的 `Disabled="true"` 只是存檔時依 active configuration 寫出來的。
- **後果**:切 solution platform 後 `Disabled` 跟著目標 configuration 的 ShouldBuild 變(切換本身不寫磁碟);之後 Build 會把 .tsproj 的 `Disabled` 改寫到磁碟。所以只能在**切換前**擋。實害(master 6b672fe):使用者在 `TwinCAT RT (x64)` 停用的 PLC,`Enable-TcConfig -Force -Platform 'TwinCAT OS (x64)'` 的 platform-fix 把它重新 enable、build、download 到 852 並 Run,回 success、沒有 warning。
- **InfoSys**:只說明 SolutionContexts 的 `ShouldBuild` 是 per configuration 開關子專案 build([Setting the TwinCAT target platform](https://infosys.beckhoff.com/content/1033/tc3_automationinterface/650882187.html));沒有 Disabled ↔ Build.0 綁定的說明，上面的綁定是實測。
- **模組做法**:`Set-TcTarget` 與 `Enable-TcConfig` 的 platform-fix(共用 `Set-TcSolutionPlatform`)切換前比對每個 PLC 在目前 active configuration 的 ShouldBuild / Disabled 與目標 configuration(同 configuration 名稱、目標平台)的 ShouldBuild:目標 ShouldBuild ≠ 目前 ShouldBuild,或目前 disabled 而目標會 build(即使目前 ShouldBuild 是 true 也算，fail closed)→ `BUILD_SELECTION_CHANGED`;讀不到 → `BUILD_SELECTION_UNKNOWN`;兩者都不切。切換後讀回不同 → 切回原平台並回 `BUILD_SELECTION_CHANGED`;切回失敗 → 記下 guard(見 `BUILD_SELECTION_CHANGED`)。成功時 `data.buildSelection` 列出每個 PLC 的 before / target / after。
- **讀不到不當成 false / enabled**:ShouldBuild 只接受真正的 bool(COM getter 失敗時是 `$null`,`[bool]$null` 會變成 False,所以不轉型);PLC 節點的 Disabled 讀不到是 `$null`(以前當成 0 = enabled)。平台切換遇到 `$null` 一律 `BUILD_SELECTION_UNKNOWN`;`Build-TcProject` 遇到 ShouldBuild `$null` 不開始 Build(`BUILD_COVERAGE_UNKNOWN`,`data.unreadableProjects`),遇到 Disabled `$null` 當 enabled(留在 coverage 裡，只會讓 coverage 檢查更嚴);`Enable-TcConfig` 遇到任何 PLC 的 Disabled `$null` 在做任何事之前(platform check、Activate、Login 之前)就拒絕,`BUILD_SELECTION_UNKNOWN`、`data.plcsWithoutDisabled`、`data.activated = false`;`Resolve-TcPlcProjectPath` 把它留在候選裡。

### BUILD_SELECTION_CHANGED

- **現象**:`Set-TcTarget`(`-Platform` 或 target 回報的平台)或 `Enable-TcConfig` 的自動切換 `platform-fix` 回 `BUILD_SELECTION_CHANGED`。切換前發現的:**什麼都沒切換**;`Enable-TcConfig` 停在 `platform-fix`(ok=false),沒有 Build、Activate、Login。切換後讀回才發現的:已切回原 configuration(`data.restored = true/false`)。
- **data**:`data.buildSelectionChanges[]`:每個會改變的 PLC `{ plc; project(.plcproj unique name); nodePath; configuration(目標 '<Configuration>|<Platform>'); current = { configuration; shouldBuild; disabled }; target = { shouldBuild }; after = { shouldBuild; disabled }(切換後讀回的，切換前擋下時為 null); changed }`。`data.buildSelection[]` 是全部 PLC(同一格式)。
- **為什麼**:目標 configuration 的 ShouldBuild 跟目前不同：在一個平台停用的 PLC,換平台後會被 build、download、Run(或反過來，目前有 build 的 PLC 在目標平台不 build)。見「PLC Disabled = active configuration 的 Build.0」。
- **比對方式**:目前 = active configuration 每個 .plcproj SolutionContext 的 ShouldBuild(`Get-TcBuildCoverage`)+ 每個 PLC 樹節點的 Disabled(`Get-TcPlcProjectList`),兩者對應沿用 Build-TcProject(#104)的 .plcproj path 優先、名稱次之、不一對一就 fail closed(只在有 PLC 被 disabled 時要求);目標 = `Get-TcSolutionConfigurations` 裡會被 `Activate()` 的那一項(同 configuration 名稱、目標 solution platform)每個 .plcproj context 的 ShouldBuild,用 project unique name 對應。目標 ShouldBuild ≠ 目前 ShouldBuild 就是改變;目前 disabled 而目標 ShouldBuild = true 也算改變(即使目前 ShouldBuild 也是 true:Disabled 與 Build.0 不一致時不猜,fail closed)。solution platform 未知、有多個候選時，會改變的候選不會被 Activate;剩下的候選讀回失敗時,`PLATFORM_SET_FAILED` 的 message 會列出被排除的候選與其改變(`data.buildSelectionChanges`);全部被排除時，只要有一個候選是「改變」就回 `BUILD_SELECTION_CHANGED`(優先於讀不到的 `BUILD_SELECTION_UNKNOWN`)。
- **切回失敗(`data.restored = false`)與 guard**:切換後讀回發現改變(或讀不到)、又無法 `Activate()` 回原 configuration 時,XAE 停在目標 configuration,build selection 已不是使用者選的。這時:
  - hint 不說「已切回」,改寫明停在哪、哪些 PLC 改變，與下一步 `Set-TcTarget -AmsNetId <id> -Platform '<原平台>' -Configuration '<原 configuration>'`(或 XAE 工具列手動切回),並說不要 Build / Enable。
  - 記下 BUILD_REQUIRED 的 kind `build-selection`(同一個狀態檔 `build-required.json`,reason 含原 configuration 與改變的 PLC)。
  - **誰被擋**:`Build-TcProject` 與 `Enable-TcConfig` 一開始就回 `BUILD_SELECTION_CHANGED`(`data.buildSelectionGuard = { previousConfiguration; previousPlatform; previous; leftConfiguration; changes; legacy; reason; solution; at; stateFile }`),什麼都不做，hint 是 guard 專用的(停在哪、怎麼切回);`Enter-TcPlcOnline` 由同一筆紀錄的 BUILD_REQUIRED 擋下。`Clear-TcBuildRequired`(完整 Build 成功)永遠保留 `build-selection`,只清其他 kind。
  - **原 configuration 存成獨立欄位**(狀態檔 entry 的 `buildSelectionGuard.previousConfiguration` / `previousPlatform`),不從 reason 文字解析;原 configuration 沒有名稱時只比對平台。沒有這個欄位的舊紀錄(`legacy = true`)模組不會自動解除:hint 寫手動步驟(確認 XAE 已切回、結束所有 TcAuto session / MCP server,編輯 `%TEMP%\TwinCATAutomation\build-required.json`(或 `TCAUTO_STATE_DIR`)刪掉這個 solution 的項目)。
  - **何時清除**:`Set-TcSolutionPlatform`(`Set-TcTarget`)成功後 active configuration 等於 guard 記的原 configuration:切回原 configuration(這個切換一律允許：不做 build selection 阻擋，切換前讀不到 build selection 或候選比對出錯也不擋，只回報 `data.buildSelectionError`;只有 `IDE_BUSY` / `IDE_CRASHED` / `IDE_MODAL_DIALOG` 照擋，hint 附「IDE 恢復後重跑，或在 XAE 手動切回後重跑同一個 Set-TcTarget」;讀回只回報)或原 configuration 已是 active(在 XAE 手動切回後跑同一個 `Set-TcTarget`)。只清 `build-selection` 這一種，切回造成的 `platform-switch` 仍要一次完整 Build。
  - 狀態檔讀不到時 guard 本身讀不到(不擋 Build),但 `Enable-TcConfig` / `Enter-TcPlcOnline` 仍被 BUILD_REQUIRED 的 fail closed 擋下。
- **下一步**:XAE 的 Build > Configuration Manager,選目標 configuration(`data.buildSelectionChanges[].configuration`),讓每個 PLC 的 Build 勾選與目前一致(在目前平台停用的 PLC,在目標平台也取消勾選),存檔後重跑;確定要改 build 範圍，就先在目前平台調整(停用 / 啟用 PLC)再切。

### BUILD_SELECTION_UNKNOWN

- **現象**:同上兩個 cmdlet,切換前讀不到比對所需的資料，**什麼都沒切換**(fail closed);或切換後讀回失敗，已切回原平台(`data.restored`)。
- **為什麼**:active configuration 的 SolutionContexts 讀不到;有 .plcproj context 但讀不到 TwinCAT 專案(ITcSysManager)或 PLC 樹(TIPC);有 PLC 樹節點但 active configuration 沒有任何 .plcproj context;有 PLC 被 disabled、但 PLC 節點與 .plcproj 對不成一對一(節點沒有 PlcProjectDef/ProjectPath、名稱與 .plcproj 檔名不同);目標 configuration 少了某個 .plcproj、某個重複、ShouldBuild 讀不到，或只有目標有的 .plcproj。IDE 層的錯誤保留原碼(`IDE_BUSY`、`IDE_CRASHED`、`IDE_MODAL_DIALOG`)。
- **讀不到的值**:ShouldBuild 不是真正的 bool(COM getter 失敗)、PLC 節點的 Disabled 讀不到(`$null`)也算讀不到，不會當成 false / enabled。切換後讀回時遇到 `IDE_BUSY` / `IDE_CRASHED` / `IDE_MODAL_DIALOG`,回的是那個碼和它的 hint(一樣已嘗試切回)。
- **下一步**:看 `error.message` 的原因。IDE 忙就重試;PLC 名稱與 .plcproj 檔名不一致時改成一致;或在 XAE 手動切平台，確認 Configuration Manager 每個 PLC 的 Build 勾選後 `Build-TcProject`。

### 成功時的 Set-TcTarget data

`Set-TcTarget -AmsNetId <id> [-Platform <name>] [-Configuration Release] [-NoPlatformSwitch]` 的 data:`amsNetId`、`targetSet`、`platformCheck`、`targetPlatform`、`targetPlatformSource`、`adsError`、`platform`(solution platform)、`projectPlatform`(操作後 active 的 .tsproj project platform,沒有 .tsproj 為 null)、`platformChanged`(bool);有切換時另有 `requestedProjectPlatform`、 `configuration`、`previousPlatform`、`availablePlatforms`、`projectCheck`(`ok` / `mismatch` / `no-tsproj`)、`platformMatchedBy`、`platformMap`、`platformMapReliable` / `platformMapReason`(#110,見「platformMap 不可靠」)、`buildSelection`(每個 PLC 的 before / target / after,沒有 PLC 為空陣列)、`buildSelectionChanges`(#67)。`Enable-TcConfig` 的 data 一律有 `targetPlatform`、`targetPlatformSource`、`solutionPlatform`、`projectPlatform`、`platformFixed`、`platformCheck`(skipped 時加 `warning`;自動切換失敗時加 `platformMap`、`platformMapReliable` / `platformMapReason`、`requestedProjectPlatform`)。`Connect-TcIde` / `Get-TcIdeInfo` 的 data 多 `solutionPlatform`、`solutionConfiguration`、`projectPlatform`。MCP `SetTarget` 有 `Platform` / `Configuration` / `NoPlatformSwitch` 參數,`EnableConfig` 有 `Platform` / `NoPlatformFix`;`RunLifecycle` 的 `Platform` 給 SetTarget 步驟(在 Build 之前切換,沒給 `TargetAmsNetId` 用 `ConnectIde` 回的 AmsNetId),也原值傳給 EnableConfig(比對結果相同,不再出現「-Platform was not given」的 `data.warning`;target 有回報 TARGETINFO 時仍以 target 為準),沒給 `Platform` 時 SetTarget 帶 `NoPlatformSwitch=true`,platform 交給 EnableConfig 檢查。MCP 的 hint 改寫保留引號內的值:`Set-TcTarget -Platform 'TwinCAT OS (x64)'` → `SetTarget Platform='TwinCAT OS (x64)'`。

## 第 3 期系統組態(task 4.1–4.5)

共同規則(和第 2 期相同):修改類 tool 預設 `DryRun = true`;寫入前備份到 `<sln 目錄>\.tcauto-backup\<時間>\`(`data.backupPath` / `data.backupFiles`);每個修改的 COM 呼叫前查 modal dialog(有就 `IDE_MODAL_DIALOG`,什麼都不送);寫入後讀回，不符就回錯誤碼，不報成功;寫入 API 一呼叫就記 `BUILD_REQUIRED`(code-changed),呼叫前就擋下的不記。下列行為除非另外註明，都是**自建 client 實測 2026-11-01 4026 VS2022(XAE 3.1.4026.22)/ 4024 XAE Shell(3.1.4024.71)**,見 [phase3-probe.md](../openspec/changes/complete-automation-interface/verification/phase3-probe.md);這些 tool 目前**只有單元測試**,registered tcauto 驗證是 task 4.6。

### NC(task 4.1):做法

- **NC task**:`Add-TcNcTask`(MCP `AddNcTask`)= `TINC` 上 `CreateChild(<name>, 1)`(TE1000 v1.7.0 §6.10.1 p.293)。一個 TINC 只能有一個 NC task:第二個一律 `0x98510002 Item already exists!`(probe 第 1 題),所以模組先看 TINC 有沒有 ItemType 1 的子節點。XAE 會在名稱後加 ` SAF`,名稱一律從讀回取得(`data.taskPath`,不同時寫進 `data.warnings`)。
- **軸**:`Add-TcNcAxis`(`AddNcAxis`)= `<task>^Axes` 上 `CreateChild(<name>, <subType>)`:Continuous 1、Discrete 2、Stepper 3、Encoder 5(0、8 被 XAE 拒絕);新軸預設就是模擬軸(Enc = Simulation encoder subType 1、Drive = KL4XXX 5、Ctrl = P 1,probe 第 2 題),模組讀回確認 encoder 是 EncType 0 / 1。**XAE 不擋同名**,同名會建出第二支，所以模組自己先查(`NC_AXIS_ALREADY_EXISTS`)。`data.axisId` 是 ProduceXml 的 `ItemId`(NC ADS index group `0x4100 + id`,[InfoSys tc3_ads_intro 713094155](https://infosys.beckhoff.com/content/1033/tc3_ads_intro/713094155.html))。
- **參數**:`Set-TcNcAxisParameter`(`SetNcAxisParameter`)只開放 ProduceXml 裡有的欄位：`MaxVelocity` = `NcAxisDef/AxisParam/Velo/Maximum`、`Acceleration` / `Deceleration` / `Jerk` = `AxisParam/Dynamic/*`、`EncoderType` / `DriveType` / `ControllerType` = `Encoder/EncType`、`Drive/DrvType`、`Controller/CtrType`(probe 第 3、4 題;實際寫入讀回過的只有 Velo/Maximum、Dynamic/Acceleration 和三種型別欄位)。ConsumeXml 對錯值一律回 S_OK(`abc` 變 0、不存在的元素被忽略、不存在的型別號碼照存但 `ItemSubTypeName` 是空的),所以送出前檢查(數值有限、> 0,Jerk ≥ 0,≤ 1e12;型別號碼只收 XAE 有名稱的),寫入後逐欄讀回;`ChangeChildSubType` 是 E_NOTIMPL,不用。
- **PLC link**:`Connect-TcNcAxisToPlc`(`LinkNcAxis`)用 `LinkVariables` 整個 struct link:PLC `<Plc> Instance^<task> Inputs^<var>.NcToPlc` ↔ NC `<axis>^Outputs^ToPlc`,NC `<axis>^Inputs^FromPlc` ↔ PLC `<task> Outputs^<var>.PlcToNc`(probe 第 5 題;TE1000 §5.1.1.2 p.38、§6.3.14 p.217)。`<task> Inputs` 的名稱不寫死：先用 PLC instance 列舉得到的 `* Inputs` / `* Outputs`,再用 `TIRT` 底下每個 task(以及 PLC project 的 PLC task)拼 `<instance>^<task> Inputs` / `Outputs` 直接 `LookupTreeItem`。**真 COM 上 PLC instance(ItemType 57)列舉不到子節點**(`ChildCount 0`),但完整 path 可以 lookup(registered 實測 2026-11-01,4026.22 VS2022 與 4024.71 XAE Shell,[phase3-4.6.md](../openspec/changes/complete-automation-interface/verification/phase3-4.6.md) B1,已修)。讀回用 `ProduceMappingInfo`(和 `Set-TcVariableLink` 相同)。備份是 `ProduceMappingInfo` 全文(`MappingInfo.xml`)。

- **review 修正(第 3 期)**:XAE 的錯誤用 HRESULT 判斷(`New-TcTreeItem` 的 `data.hresult` / `hresultHex`;0x98510002 → `NC_TASK_ALREADY_EXISTS`、0x98510009 → `TCCOM_CLASS_NOT_FOUND`,英文訊息只當備援)。給 tree path 時也檢查同 path 的重複軸(`NC_AXIS_AMBIGUOUS`)。和同份 ProduceXml 其他欄位矛盾的值(Acceleration > AccelerationMaximum、Deceleration > DecelerationMaximum、MaxVelocity 低於 Velo/Fast、FastManual、SlowManual、RefSearch、RefSync)只列在 `data.warnings`、照寫(NC 怎麼處理未實測)。型別還原後會讀回號碼與 `ItemSubTypeName`,讀不回 `data.reverted = false`。LinkNcAxis:PLC instance 從樹上找(TIPC^<Plc> 底下有 process image 的子節點);struct 成員(`<var>.NcToPlc.ActPos`)已單獨 link 也算已 link;第二條 link 前出現 modal dialog 時，第一條會解掉並讀回 mapping(`data.partialLinks`,`data.rolledBack` 只在 mapping 確認沒有了才是 true)。

### NC_TASK_NOT_FOUND

- **現象**:專案沒有 `TINC`、TINC 底下沒有 NC task,或 `-Task` 不是現有的 NC task(`data.ncTasks`)。什麼都沒改。
- **下一步**:`Add-TcNcTask -DryRun $false` 建 task,再重跑;或用 `data.ncTasks` 的值當 `-Task`。

### NC_TASK_AMBIGUOUS

- **現象**:有多個 NC task 又沒給 `-Task`。XAE 一個 TINC 只允許一個(probe 第 1 題),所以實際上不會發生，保留但未實測。
- **下一步**:用 `data.ncTasks` 其中一個當 `-Task`。

### NC_TASK_ALREADY_EXISTS

- **現象**:TINC 已經有 NC task(`data.existingTasks`),或 XAE 回 `0x98510002 Item already exists!`。什麼都沒建(XAE 拒絕時 CreateChild 已呼叫，會記 BUILD_REQUIRED)。
- **下一步**:直接用現有的 task:`Add-TcNcAxis -Name <axis> -Task <data.existingTasks[0]>`。

### NC_TASK_VERIFY_FAILED

- **現象**:CreateChild 有返回，但讀回找不到 task、ItemType 不是 1,或沒有 `<task>^Axes`。模組會把它刪掉(`data.rollback`、`data.rolledBack`)。
- **下一步**:`rolledBack = false` 時用 `Remove-TcTreeItem -Path <data.taskPath> -ConfirmName <名稱> -DryRun $false` 刪掉，再用 `Get-TcTreeItem -Path TINC` 確認。

### NC_AXIS_ALREADY_EXISTS

- **現象**:`<task>^Axes` 已經有同名的軸(不分大小寫,`data.existingAxes`)。XAE 自己不擋(實測同名會建出第二支),所以模組擋。什麼都沒建。
- **下一步**:換 `-Name`,或直接用現有的軸。

### NC_AXIS_NOT_FOUND

- **現象**:`-Axis` 的名稱不在任何 NC task 的 Axes 底下(`data.ncAxes` 列出全部),或給的 tree path 不是 NC axis(ItemType 不是 22)。
- **下一步**:用 `data.ncAxes` 的值重跑。

### NC_AXIS_AMBIGUOUS

- **現象**:有多支軸叫這個名稱(XAE 允許同名)。從名稱分不出是哪一支，link 也分不出(probe 第 5 題)。
- **下一步**:改用完整 tree path;最好先把重複的軸改名或刪掉。

### NC_AXIS_VERIFY_FAILED

- **現象**:軸建好了，但讀回的 ItemType / subType 不對，或 encoder 不是 Simulation encoder(`data.mismatches`)。模組會刪掉這支軸(`data.rolledBack`)。目前只有 Continuous 在 probe 裡建立並 Activate 過，其他 AxisType 的預設 encoder 沒實測。
- **下一步**:`rolledBack = false` 時用 `Remove-TcTreeItem` 刪掉 `data.axisPath`,再重跑。

### NC_INVALID_SUBTYPE

- **現象**:`EncoderType` / `DriveType` / `ControllerType` 不是 XAE 有名稱的號碼(`data.allowedTypes`;什麼都沒寫),或寫入後子節點的 `ItemSubTypeName` 是空的(XAE 照存了沒有名稱的號碼):模組把原本的型別號碼送回去(`data.reverted`、`data.unnamedTypes`)。
- **為什麼**:不存在的型別也回 S_OK(probe 第 4 題:Drive 18、19、25–40;Enc 9、22、23、30–40;Ctrl 0、4、15–40)。
- **下一步**:改用 `data.allowedTypes` 的號碼。

### NC_AXIS_PARAM_NOT_FOUND

- **現象**:這支軸的 ProduceXml 沒有要改的欄位(`data.missingFields`)。XAE 會靜默忽略不存在的元素，所以模組不送。
- **下一步**:`Get-TcTreeItemXml -Path <data.axisPath>` 看 `NcAxisDef` 的實際結構。

### NC_AXIS_PARAM_WRITE_FAILED

- **現象**:ConsumeXml 被 XAE 拒絕(例外)。`data.backupPath` 是寫入前的 ProduceXml。
- **下一步**:`Get-TcIdeModalDialog` 檢查 dialog,`Get-TcTreeItemXml` 確認目前值後重跑。

### NC_AXIS_PARAM_VERIFY_FAILED

- **現象**:ConsumeXml 有返回，但讀回的值和要寫的不同(`data.mismatches`)。不要當成功。
- **下一步**:`Get-TcTreeItemXml -Path <data.axisPath>` 看實際值;要還原就用 `data.backupPath` 裡的值再跑一次(先 dry-run)。

### NC_PLC_VARIABLE_NOT_FOUND

- **現象**:試過的 process image 底下都找不到 `<PlcVariable>.NcToPlc` / `.PlcToNc`。`data.triedPaths` 列出每一個 lookup 過的完整 path(`<instance>^<task> Inputs^<var>.NcToPlc` …),`data.tasks` 是拿來拼 path 的 task 名稱(`TIRT` 的子節點 + PLC project 的 PLC task;`TIRT` 在真 COM 上列舉得到、名稱和 `<task> Inputs` 相同：實測 2026-11-01 e3cf28c,4026 VS2022 `PlcTask`、4024 XAE Shell `PlcTask` + `MotionTask`,registered tcauto,phase3-4.6.md「Retest(e3cf28c)」)。`NcToPlc` 和 `PlcToNc` 必須來自**同一個 task**(review S4):只找到一邊，或兩邊分在不同 task,也回這個碼，`data.foundPaths` 列出找到的那些 path。AXIS_REF 要 build 過才會出現在 process image。4.6 B1 之前這裡回 `data.instanceChildren`(真 COM 上一律是空的，已移除)。
- **下一步**:確認 `-PlcVariable` 是 AXIS_REF 本身(例如 `MAIN.axis`,不要加 `.NcToPlc`),`Build-TcProject`(MCP `BuildProject`)後重跑。`data.tasks` 是空的就是 `TIRT` 底下沒有 task,先 `Get-TcTreeItem -Path TIRT` 確認;要看 image 底下實際的名稱用 `Get-TcTreeItem -Path '<data.triedPaths 去掉最後一段>'`。

### NC_AXIS_ALREADY_LINKED

- **現象**:四個端點之一已經 link 到別處(`data.existingLinks`)。`LinkVariables` 對已 link 的變數會怎樣沒有實測，所以模組不送。
- **下一步**:`Remove-TcVariableLink` 解掉舊的 link,再重跑 `Connect-TcNcAxisToPlc`。

### TcCOM(task 4.2):做法

- **建立**:`Add-TcComModule`(MCP `AddTcComModule`)= `TIRC^TcCOM Objects` 上 `CreateChild(<name>, 0, '', <GUID 或型別名稱>)`(TE1000 v1.7.0 §6.7.1 p.274–275;subType 0 / 1、GUID 有沒有大括號都可以，probe 第 9 題)。XAE 一律改名成 `<name> (<ModuleTypeName>)`,同名時再加 `_ObjN`(4024 第一次就加),都不報錯，所以模組先查同名，名稱和 path 一律從讀回取得(`data.createdPath` / `createdName`)。module 要放在 `CustomConfig\Modules` 或 `Config\Io\TcModuleFolders.xml` 列出的資料夾(手冊 p.274)。TMC 沒寫 `<Licenses>` 不代表 runtime 不檢查授權;probe 只 Activate 過 `TcNtpExternalTimeProvider`(`{7e6d2fda-2d37-4998-a31f-36958d3a2c8a}`,測試前要先把 `ClientEnable` 設 FALSE,否則會連 `ntp.beckhoff-cloud.com`)。
- **找 module**:tree path,或實例名稱(`ITcModuleManager.Modules.Item(i)`,i 從 0;`foreach` 列舉不到、`LookupModule`(v2)late binding 叫不到、`ClassID` 是空的，probe 第 11 題)加 `TIRC^TcCOM Objects` 的子節點名稱。
- **參數**:清單和 id(`PTCID`)、`BitSize`、`BaseType` 來自 ProduceXml `Module/Parameters/Parameter`,專案值來自 `ParameterValues/Value`(probe 第 10 題)。離線讀寫 `GetModulePara` / `SetModulePara(pid, byte[])`(大小不符 `0x98110705`);值一律先轉成剛好大小的 bytes 並檢查範圍(enum 依 BitSize 當整數;struct / array 只回 `rawHex`)。**TIME**(phase3-4.6 N2,已修):32 bit、1 ms 解析度、內部是 UDINT([InfoSys TIME/LTIME](https://infosys.beckhoff.com/content/1033/tc3_plc_intro/12189021579.html)),讀取的 `value` 是 ms 數字;寫入收整數 ms 或 IEC literal(`T#5S`、`T#1m30s`、`TIME#250ms`,可有 `_`,只有最後一段可帶小數),必須是整數 ms、範圍 0..4294967295。4.6 實測 `TcNtpExternalTimeProvider.PollInterval` 是 TIME(registered tcauto 2026-11-01,4026.22 VS2022,`rawHex E8030000` = 1000)。可寫入的型別：BOOL、整數型別、REAL / LREAL、STRING(n)、TIME、DataTypes 確認是 enum 的型別。離線寫入只改 XAE 記憶體(要存檔才進 `.tsproj` / `.xti`),會記 BUILD_REQUIRED。
- **Online**:`-Online` 走 `ITcModuleManager.Get/SetOnlineModulePara(oid, pid, ...)`(手冊 §5.31.1.1 p.130:ADS port `AMSPORT_R0_TCOMSERVER` = 10、IG = oid、IO = pid;probe 第 13 題用 raw ADS port 10 讀到相同值)。**online 寫入不改專案**(下次 Activate 就還原),不記 BUILD_REQUIRED;寫入前的 online 值在 `data.previousHex` 和備份檔。
- **Context**:`Set-TcComModuleContext`(MCP `SetTcComContext`)的 index 是 TMC 的 Context `Id`(NTP 是 1,**不是 0**;probe 第 12 題、手冊 §5.33.2 p.140–141),合法值從 ProduceXml `Module/Contexts/Context/Id` 讀;task oid 是 task ProduceXml 的 `TreeItem/ObjectId`。

### TCCOM_MODULE_ALREADY_EXISTS

- **現象**:`TIRC^TcCOM Objects` 已有 `<Name>` 或 `<Name> (...)` 的子節點(`data.existingModules`)。XAE 會靜默改名成 `<Name>_ObjN`,模組先擋。什麼都沒建。
- **下一步**:換 `-Name`,或用現有的實例。

### TCCOM_CLASS_NOT_FOUND

- **現象**:XAE 回 `0x98510009 TCOM Module / TCOM Configuration with GUID '%s' not found!`(訊息裡的 `%s` 沒被替換，實測)。
- **下一步**:確認 GUID / 型別名稱和 TMC 的 `<Module GUID=...>` 一致，module 有裝在 TwinCAT 找得到的資料夾。

### TCCOM_VERIFY_FAILED

- **現象**:實例建好了，但 ProduceXml 的 `Module/@GUID` / `Module/Name` 和要求的不同，或沒有 `TcModuleInstance`(`data.mismatches`)。模組會刪掉它(`data.rolledBack`)。
- **下一步**:`rolledBack = false` 時用 `Remove-TcTreeItem -Path <data.createdPath> -ConfirmName <data.createdName> -DryRun $false` 刪掉。

### TCCOM_MODULE_NOT_FOUND

- **現象**:`-Module` 的名稱 / path 找不到，或那個節點不是 TcCOM 實例(ProduceXml 沒有 `TcModuleInstance/Module`)。`data.modules` 是 ModuleManager 的實例名稱。
- **下一步**:用 `data.modules` 的名稱，或 `Get-TcTreeItem -Path 'TIRC^TcCOM Objects'` 查到的完整 path。

### TCCOM_PARAM_NOT_FOUND

- **現象**:ProduceXml 沒有這個參數名稱 / id(`data.parameters` 列出 `名稱 id`),或 XAE 對 pid 回 E_FAIL(離線)/ `0x98110703`(online)。
- **下一步**:`Get-TcComModuleParameter -Module <module>` 看清單後重跑。

### TCCOM_PARAM_INVALID_VALUE

- **現象**:值轉不成參數型別，或超出範圍(例如 UINT 70000、DINT `abc`)。什麼都沒寫。XAE 自己對錯值不一定報錯(NC 的 ConsumeXml `abc` 變 0),所以模組擋。
- **下一步**:數字用 `.` 當小數點、BOOL 用 `true` / `false` / `1` / `0`、STRING 只收可列印 ASCII 且長度要小於參數大小。

### TCCOM_PARAM_UNSUPPORTED_TYPE

- **現象**:參數的型別(`data.paramType`;message 有型別名稱與大小)不在可寫入的清單裡(BOOL、整數型別、REAL / LREAL、STRING(n)、TIME、DataTypes 確認是 enum 的型別):struct / array、DataTypes 沒確認是 enum 的具名型別、LTIME / DATE / TOD / DT 等沒支援的型別。只能讀 `rawHex`,什麼都沒寫。4.6 N2 之前 TIME 也落在這裡，而且 hint 一律說「不是基本型別(struct / array)」,和 message 不一致;現在 TIME 可以寫，hint 改成列出可寫入的型別。
- **下一步**:`Get-TcComModuleParameter`(MCP `GetTcComParameter`)讀 `rawHex`;要改值在 XAE 設定，或改寫它的成員參數(TMC 有獨立成員參數時，例如 ProduceXml 裡 `ServerPara.bEnable` 這種點號名稱)。

### TCCOM_PARAM_SIZE_MISMATCH

- **現象**:XAE 回 `0x98110705`(ADS_E_INVALIDSIZE):送出的 bytes 和參數大小不同。online 寫入 8-byte scalar 也會這樣(probe 第 13 題),所以模組一律送 bytes。
- **下一步**:`Get-TcComModuleParameter` 看 `bitSize` / `paramType`,確認 ProduceXml 的 `BitSize` 正確。

### TCCOM_PARAM_READ_FAILED

- **現象**:`GetModulePara` / `GetOnlineModulePara` 丟了其他例外。
- **下一步**:`Get-TcIdeModalDialog` 檢查 dialog 後重跑;`-Online` 時先 `Get-TcSystemState` 確認是 Run。

### TCCOM_PARAM_WRITE_FAILED

- **現象**:`SetModulePara` / `SetOnlineModulePara` 丟了其他例外。`data.backupPath` 是寫入前的備份。
- **下一步**:`Get-TcIdeModalDialog` 檢查 dialog,`Get-TcComModuleParameter` 確認目前值後重跑。

### TCCOM_PARAM_VERIFY_FAILED

- **現象**:寫入有返回，但讀回的 bytes(`data.readbackHex`)和要寫的(`data.plannedHex`)不同。不要當成功。
- **下一步**:`Get-TcComModuleParameter` 確認;要還原就把 `data.previousHex` 對應的值再寫一次(先 dry-run)。

### TCCOM_OBJECT_NOT_FOUND

- **現象**:`-Online` 時 target 上沒有這個 object(`0x9811071D`):組態沒 Activate、runtime 不在 Run,或 module 是 Activate 之後才加的。
- **下一步**:`Enable-TcConfig -Force`,再重跑 `-Online`。

### TCCOM_ONLINE_CONFIG_MISMATCH

- **現象**:`Set-TcComModuleParameter -Online`(dry-run 也一樣)之前，專案的 boot package 和 target 的 Boot 目錄比對不是 `match`(`data.bootPackage`;`Get-TcBootPackageDiff`,variant 專案比 `_Boot\<Variant>\<Platform>`)。target 跑的可能是舊的或別的組態，同一個 oid / pid 可能是另一個 object,所以不寫(review S11)。遠端 target 無法比對(`unavailable`),也一律不寫。
- **下一步**:`Build-TcProject`、`Enable-TcConfig -Force` 讓 target 跑這個專案，再重跑 `-Online`。

### TCCOM_CONTEXT_INVALID

- **現象**:module 沒有 context(例如 TcJobPool)、`-ContextId` 不是 TMC 的 Context Id(`data.contextIds`;0 不是預設)、有多個 context 卻沒給 `-ContextId`、`-Task` 沒有 ObjectId,或 XAE 回 `0x80070057`(index 錯)/ E_FAIL(oid 不是這個 context 合法的 task;實測 axis oid、不存在的 oid 都是 E_FAIL)。
- **下一步**:用 `data.contextIds` 的值當 `-ContextId`,`-Task` 給 TIRT / TINC 底下的 task。

### TCCOM_CONTEXT_WRITE_FAILED

- **現象**:`SetModuleContext` 丟了其他例外。
- **下一步**:`Get-TcIdeModalDialog` 檢查 dialog 後重跑。

### TCCOM_CONTEXT_VERIFY_FAILED

- **現象**:`SetModuleContext` 有返回，但 `GetModuleContext(id)` 讀回的 oid(`data.readbackOidHex`)不是要設的 task。
- **下一步**:`Get-TcTreeItemXml` 看 module 的 `Contexts`(`ManualConfig/OTCID`),再重跑。

### Variant(task 4.3):做法

- **API**:`ITcSysManager14.CurrentProjectVariant` / `ProjectVariantConfig` / `ProjectVariantItems`(TE1000 v1.7.0 §5.1.13 p.52、§6.12.1 p.296;[InfoSys 8204600715](https://infosys.beckhoff.com/content/1033/tc3_automationinterface/8204600715.html))。variant management 從 4024 起([InfoSys Variant management Concept](https://infosys.beckhoff.com/content/1033/variant_management/6325752587.html));4024.71 的 32-bit XAE Shell 也能 late-bind(probe 第 15 題)。沒有 variant 時 4026 回空字串、4024 的 Config / Items 回 `$null`,`Get-TcProjectVariants`(MCP `GetVariants`)都轉成空陣列。
- **整份覆蓋**:寫 `ProjectVariantConfig` 會取代整份文件(不合併、不自動加 `[All]`、current 不會被清掉，probe 第 17 題),所以 `Set-TcProjectVariantConfig`(`SetVariantConfig`)讀出 → 在原本的 DOM 上增刪 `<Variant>` / `<Member>`(模組不認得的元素與 attribute 原樣保留，review S6)→ 整份寫回 → 讀回整份文件正規化後比對。`-Group` 和 variant 名稱一樣不分大小寫比對。移除目前的 variant 會擋(`VARIANT_IS_CURRENT`)。寫前備份舊文件和 `.tsproj`(存檔後 variant 存在 `.tsproj` 的 `<Variants>` 與根元素 `TcProjectVariant` attribute,item 層的設定存在 item 所在的檔，例如 `_Config\NC\NC.xti`,probe 第 18 題)。
- **切換**:`Set-TcCurrentVariant`(`SwitchVariant`)名稱大小寫敏感;不存在、大小寫錯、`[All]` 在 XAE 都是 E_FAIL,模組先查;`[Group1]` 可以設、`''` 清掉。
- **Boot 目錄(#89)**:有 current variant 時 XAE 把 boot 包寫到 `_Boot\<Variant>\<Platform>\`(group 是 `_Boot\[Group1]\<Platform>\`;`.tsproj` 有 `<Variants SpecificLocalBootFolder="true">`)。`Enable-TcConfig` 的 boot-package 比對與 `New-TcBootProject` 的 boot 檔讀回都會看這個資料夾(存在時只用它，不存在才退回 `_Boot\<Platform>\` 並加 warning;`.tsproj` 明寫 `SpecificLocalBootFolder="false"` 時不看);修正前一律誤報 `BOOT_PACKAGE_MISMATCH` 並停在 Config(probe 第 18 題實測 target 的 boot 檔 SHA-256 和 `_Boot\Variant1\TwinCAT OS (x64)\` 相同)。

### VARIANT_NOT_SUPPORTED

- **現象**:讀 `CurrentProjectVariant` 丟例外，或讀到 `$null` 而且物件沒有這個成員(late binding 對不存在的名稱回 `$null` 不報錯;4024.71 / 4026.22 實測都回字串)。
- **下一步**:XAE 要 4024 以上;否則在 XAE 的 Project Variants 工具列手動操作。

### VARIANT_CONFIG_INVALID

- **現象**:`ProjectVariantConfig` 不是 `<ProjectVariants>` 文件，或 XAE 拒絕寫入的文件(E_FAIL,原值不變，probe 第 17 題)。
- **下一步**:`Get-TcProjectVariants` 看 `data.configXml`。

### VARIANT_ALREADY_EXISTS

- **現象**:`-AddVariant` 的名稱已存在(不分大小寫比對，避免只差大小寫的兩個 variant)。什麼都沒寫。
- **下一步**:換名稱。

### VARIANT_NOT_FOUND

- **現象**:`-RemoveVariant` / `-Name` 不在 `ProjectVariantConfig`(大小寫要完全相同;只差大小寫時訊息會寫出正確的名稱),group 要寫成 `[Group1]`;或 XAE 對 `CurrentProjectVariant` 回 E_FAIL。
- **下一步**:用 `data.variants` / `data.groups` 的名稱重跑。

### VARIANT_IS_CURRENT

- **現象**:要移除目前的 variant,或移除後目前的 group 會沒有成員。XAE 不會自己改 current(probe 第 17 題),所以模組擋。
- **下一步**:`Set-TcCurrentVariant -Name <另一個> -DryRun $false`,再重跑。

### VARIANT_VERIFY_FAILED

- **現象**:寫入後讀回的 variant / group 清單和預期不同(`data.readback` vs `data.after`),或其餘內容(模組不認得的元素 / attribute,review S6)沒有讀回。不同的部分列在 `data.verifyDifferences`(`variants`、`groups`、`document`、`readback does not parse`)。比的是語意,不是 XML 字串:`''` / `$null` 和空的 `<ProjectVariants/>` 視為相同(4.6 N6:移除最後一個 variant 後 XAE 讀回空字串,實測 2026-11-01 4026 VS2022,phase3-4.6.md Retest;這種情況不回此碼)。
- **下一步**:`Get-TcProjectVariants` 確認;還原用 `data.backupPath`(舊文件)。

### VARIANT_SWITCH_FAILED

- **現象**:設了 `CurrentProjectVariant`,讀回卻是別的值(`data.current`)。
- **下一步**:`Get-TcProjectVariants` 確認後重跑。

### VARIANT_READ_FAILED

- **現象**:`Enable-TcConfig` / `New-TcBootProject` 讀 `CurrentProjectVariant` 失敗(屬性存在但讀取丟例外;IDE_BUSY / IDE_CRASHED / IDE_MODAL_DIALOG 仍回各自的碼)。不當成「沒有 variant」,因為 boot 目錄和 group 檢查都依它決定(review S2)。什麼都沒做。
- **下一步**:`Get-TcIdeModalDialog` 檢查 dialog,`Get-TcProjectVariants` 確認讀得到，再重跑。

### VARIANT_GROUP_ACTIVE

- **現象**:`Enable-TcConfig` 時 current variant 是 group(`[Group1]`)。group 不能 Activate(VM 手冊 v1.4 p.7:不同 variant 的值會變成未定義),XAE 自己不擋(Build / Activate 都會跑，probe 第 18 題),所以模組在任何檢查與 Activate 之前回這個碼，什麼都沒做。
- **下一步**:`Set-TcCurrentVariant -Name <variant> -DryRun $false`、`Build-TcProject`,再 `Enable-TcConfig -Force`。

### Independent project file(task 4.4):做法

- `Set-TcIndependentFile`(MCP `SetIndependentFile`)設 `ITcSmTreeItem6.SaveInOwnFile`(TE1000 v1.7.0 §5.2.4 p.62–63、§6.3.9 p.210;[InfoSys 21842602763](https://infosys.beckhoff.com/content/1033/tc3_automationinterface/21842602763.html))。手冊寫明不支援的 item「setter 什麼都不做、回 S_OK」(p.62),實測 PlcTask、Axes、TINC、TIRR 就是這樣;PLC project、NC 軸、NC task、TcCOM 實例(4024 另有 I/O device)可以(probe 第 20 題)。
- **setter 當下就寫 `.xti`**(還沒存檔就出現在 `_Config\...`),所以備份(ProduceXml、`.tsproj`、這個 item 現有的 `.xti`)一定在 setter 之前。檔名:`<名稱>.xti`,NC task 是 `_Config\NC\NC.xti`。
- **存哪一個 `.tsproj`**(phase3-4.6 B2,已修):依序看 (1) DTE `Solution.Projects` 裡 `FullName` 是 `.tsproj` 的專案、(2) `.sln` 參照的 `.tsproj`(`Project("{...}") = "<名稱>", "<相對路徑>.tsproj", ...`)、(3) solution 資料夾底下的 `.tsproj`(深度 3,`.tcauto-backup` 除外);第一個有結果的來源決定(`data.tsprojSource` = `dte` / `sln` / `folder`)。4.6 實測時 4026 副本資料夾有 3 個 `.tsproj`(兩個舊副本),`.sln` 只參照一個，舊版只掃資料夾所以回 `INDEPENDENT_FILE_TSPROJ_AMBIGUOUS`。`Set-TcProjectVariantConfig` / `Set-TcCurrentVariant` 與 `Add-TcAdsRoute -ProjectRoute` 的備份也只複製這一個 `.tsproj`。`.sln` 裡的絕對路徑直接採用、相對路徑以 `.sln` 資料夾為基準，解析失敗的那一行跳過、不影響其他行(review S3)。來源是 `dte` 時，存檔用 DTE 回報的 `FullName` 原樣去找專案，比對時兩邊都展開 8.3 短檔名(`ConvertTo-TcPathKey`,review S2),`data.tsproj` / `projectSaved` 一律是長檔名。
- 之後模組用有 deadline 的 `Project.Save`(`Invoke-TcProjectSaveWithDeadline`)存檔,`.tsproj` 才會改成 `<... File="<x>.xti"/>`;關閉(False)要存檔 XAE 才會刪 `.xti` 和它的 `.bak`。最後比對存檔前後的 `.xti` 清單(`data.createdFiles` / `removedFiles`)。
- ProduceXml 沒有對應欄位(`Set-TcTreeItemXml` 做不到);PLC project 獨立存檔後它的 mapping 改存到 `_Config\PLC\<Plc>.xti` 的 `<Mappings>`(probe 第 21 題,[InfoSys 7738192779](https://infosys.beckhoff.com/content/1033/tc3_userinterface/7738192779.html))。XAE 自己寫的檔，不需要 `Reset-TcSolution`。

### INDEPENDENT_FILE_UNSUPPORTED

- **現象**:`SaveInOwnFile` 讀不到，或 setter 回 S_OK 但讀回不變(這個 item 不能獨立存檔;`data.readback`)。磁碟沒有變。setter 已呼叫，所以有記 BUILD_REQUIRED。
- **下一步**:改用可以獨立存檔的節點(PLC project `TIPC^<Plc>`、NC 軸、NC task、TcCOM 實例)。

### INDEPENDENT_FILE_WRITE_FAILED

- **現象**:setter 丟例外。`data.backupPath` / `backupFiles` 是改之前的備份。
- **下一步**:`Get-TcIdeModalDialog` 檢查 dialog,再重跑。

### INDEPENDENT_FILE_SAVE_FAILED

- **現象**:讀回已經是要的值(開啟時 `.xti` 已寫出),但 `Project.Save` 失敗或逾時,`.tsproj` 還沒更新;改動在 XAE 記憶體。
- **下一步**:`Get-TcIdeModalDialog` 檢查 dialog、確認 `.tsproj` 不是唯讀，再用同樣參數重跑(讀回相同會直接回 `written = false`,這時改用 XAE 的 Save All 或 `Reset-TcSolution -SaveProjectChanges`)。

### INDEPENDENT_FILE_TSPROJ_AMBIGUOUS

- **現象**:決定不了要存哪個 `.tsproj`。來源依序是 DTE 載入的專案、`.sln` 參照的 `.tsproj`、solution 資料夾底下的 `.tsproj`(見上面「做法」);第一個有結果的來源列出不只一個檔(`data.tsprojSource` 是那個來源,`data.tsprojFiles` 是它列出的檔)。設定之後要存檔，所以在備份與 setter 之前就停下(review S12),什麼都沒改。只有資料夾裡有舊副本、但 DTE 或 `.sln` 只指到一個時**不會**再回這個碼(4.6 B2)。
- **下一步**:`tsprojSource` = `dte` / `sln`:solution 真的有多個 TwinCAT 專案，請在 XAE 手動勾 Independent Project File。`folder`(沒有 DTE 連線，`.sln` 也沒參照 `.tsproj`):先 `Connect-TcIde`(MCP `ConnectIde`)連上開著這個 solution 的 IDE 再重跑;仍是 `folder` 就把多餘的 `.tsproj` 移出 solution 資料夾後重跑。

### INDEPENDENT_FILE_VERIFY_FAILED

- **現象**:讀回對、也存檔了，但磁碟不符：開啟後 `_Config` 底下的 `data.expectedFile` 不是新寫出、大小 / LastWriteTime 也沒變(別的新 `.xti` 或原本就在、沒動過的同名檔都不算;`data.writtenFiles`);或關閉後原本的 `.xti` 還在。
- **下一步**:看 solution 的 `_Config` 目錄;要還原就把 `data.backupFiles` 複製回去再 `Reset-TcSolution`。

### ADS route(task 4.5):做法

- **節點**:`TIRR`(ItemName `Routes`,ItemType 31;TE1000 v1.7.0 §6.3.11 p.211、§6.3.17 p.220–221、§6.4 p.222–225)。ProduceXml 是**目前 target**(`Set-TcTarget`)的 route 表:`RoutePrj/Target`、`ActualRoutes`、`StaticRoutes`(Name、Address、NetId、Type、有時 Flags)、`ProjectRoutes`、`TargetList`(probe 第 22 題)。`Get-TcAdsRoutes`(MCP `GetAdsRoutes`)唯讀。
- **搜尋**:`Find-TcAdsTarget`(`FindAdsTargets`)送 `BroadcastSearch` 或 `Search`(4020.10 起)。**target 不是本機 system 時 XAE 直接拒絕**(本機 UmRT 也算不是;probe 第 23 題),模組不會自動切 target,回 `ROUTE_SEARCH_REQUIRES_LOCAL_TARGET`。本機時同步約 4.05 s;probe 一台都沒找到，所以空清單不代表網路上沒有 target。
- **新增**:`Add-TcAdsRoute`(`AddAdsRoute`)送 `AddRoute`(要遠端帳密)或 `-ProjectRoute` 的 `AddProjectRoute`(只寫專案)。**未實測**(沒有第二台 target,probe 第 24、25、27 題)。密碼只收 `-PasswordEnv`(環境變數名稱，只讀 Process scope,名稱一定要是 `TCAUTO_ROUTE_PW` 或 `TCAUTO_ROUTE_PW_<後綴>`,其他名稱回 `INVALID_PARAMS`,避免拿它讀別的環境變數;MCP 要在 client 設定的 server `env` 裡設)或 PowerShell 的 `SecureString`,回傳、錯誤訊息、hint、log、備份都不含密碼與 XML。AddRoute 的帳密在網路上只用固定 key 保護(Beckhoff Security Advisory 2017-002,CVE-2017-16718),只在可信網路用。只能建未加密的 route(手冊 p.220)。
- **密碼遮罩**:所有 tree tool 的 ProduceXml(`Get-TcTreeItemXmlText`)、備份檔、錯誤訊息都把 `*Password` / `*Pwd` 元素與 attribute 的值換成 `***`(AddRoute 的 `<Password>` 是明文,TISY 的 `<LogonPassword>`「stored in the project」,手冊 p.220、p.222)。
- **刪除 route:不支援**。手冊 p.220:「It is not possible to delete items directly via the Automation Interface」,只能改 `StaticRoutes.xml` 再重啟 TwinCAT service——重啟會把本機 UmRT(`TcSystemServiceUm`)一起停掉，所以沒有做成 tool。實際路徑(probe 第 26 題，實測 2026-11-01 本機 TwinCAT 3.1 / Windows 11):
  - XAR(TcSysSrv):`%TWINCAT3DIR%\Target\StaticRoutes.xml` = `C:\Program Files (x86)\Beckhoff\TwinCAT\3.1\Target\StaticRoutes.xml`,一般使用者只有讀(要 admin)。
  - UmRT:`C:\ProgramData\Beckhoff\TwinCAT\3.1\Runtimes\<name>\3.1\Target\StaticRoutes.xml`(例如 `UmRT_Default`),一般使用者可寫([InfoSys TF6310 UmRT 範例路徑](https://infosys.beckhoff.com/content/1033/tc170x_tc3_usermode_runtime/15569027467.html))。
  - 手冊寫的 `C:\TwinCAT\3.1\Target\StaticRoutes.xml` 在這台不存在，不要寫死。
  - 手動刪除：先備份該檔，刪掉對應的 `<Route>`(Name + NetId),存檔後重啟 TwinCAT service(UmRT 要再照 [agent-brief-realmachine.md](agent-brief-realmachine.md)「UmRT 復原」啟動,`Enable-TcConfig -Force`)。

### ROUTE_READ_FAILED

- **現象**:`TIRR` 的 ProduceXml 沒有 `TreeItem/RoutePrj`。
- **下一步**:`Get-TcIdeModalDialog` 檢查 dialog、`Get-TcTreeItem -Path TIRR` 確認後重跑。

### ROUTE_SEARCH_REQUIRES_LOCAL_TARGET

- **現象**:目前 target(`data.target`)不是本機 system(`data.localNetId`,registry `HKLM\SOFTWARE\[WOW6432Node\]Beckhoff\TwinCAT3\System` 的 AmsNetId),或 XAE 回 "Broadcast search only works on local target system"。什麼都沒送;模組不會自動切 target。
- **下一步**:`Set-TcTarget -AmsNetId <data.localNetId> -NoPlatformSwitch` → `Find-TcAdsTarget` → `Set-TcTarget -AmsNetId <data.target>` 切回來(切回時平台檢查照常)。

### ROUTE_SEARCH_FAILED

- **現象**:搜尋的 ConsumeXml 丟了其他例外。
- **下一步**:`Get-TcIdeModalDialog` 檢查 dialog 後重跑。

### ROUTE_ALREADY_EXISTS

- **現象**:TIRR(目前 target 的 route 表)已經有這個 NetId 的 route(`data.existingRoutes`)。什麼都沒送。
- **下一步**:`Get-TcAdsRoutes` 確認;不需要再加。

### ROUTE_PASSWORD_MISSING

- **現象**:AddRoute 沒有密碼來源(或 PowerShell 同時給了 `-PasswordEnv` 和 SecureString 密碼),或 `-PasswordEnv` 指的環境變數在這個行程(Process scope,不看 User scope)是空的。message 只把 `-PasswordEnv` 寫成參數(MCP 端由 `mcp-server/lib/tools.js` 的 `rewriteResultHints` 改寫成 `PasswordEnv`);SecureString 密碼只有 PowerShell 有：沒給密碼來源的 message 完全不提它(MCP 也會看到這條),只有「兩個都給」(只有 PowerShell 能觸發)的 message 用文字提到，不寫成 `-Password`(phase3-4.6 N4 / review N5,已修:之前 MCP 會讀到不存在的 `-Password` 參數)。
- **下一步**:在執行模組的行程設定環境變數(MCP:client 設定裡 server 的 `env`),變數名稱是 `TCAUTO_ROUTE_PW` 或 `TCAUTO_ROUTE_PW_<後綴>`,再 `Add-TcAdsRoute -PasswordEnv <名稱>`(MCP `AddAdsRoute PasswordEnv=<名稱>`);不要把密碼當參數值傳。

### ROUTE_ADD_FAILED

- **現象**:XAE 拒絕 AddRoute / AddProjectRoute。訊息已去掉密碼與 XML(`Protect-TcSecretText`)。
- **下一步**:確認遠端 IP / NetId / 帳號與網路,`Get-TcIdeModalDialog` 檢查 dialog,`Get-TcAdsRoutes` 看目前狀態。

### ROUTE_VERIFY_FAILED

- **現象**:指令有返回，但 TIRR 讀回沒有這個 NetId(AddRoute 看 StaticRoutes / ActualRoutes,project route 看 ProjectRoutes)。TIRR 只顯示目前 target 的 route 表;AddRoute 實際改的是哪一端的表沒實測。
- **下一步**:`Get-TcAdsRoutes`;必要時 `Set-TcTarget` 切到另一端再看。

### 安裝 manifest(#30):做法

- `TwinCATSetup-Claude.ps1` / `-Codex.ps1` / `-Antigravity.ps1` 安裝(或更新安裝)時,在 skill 目錄(`SKILL.md` 旁)寫 `tcauto-install-manifest.json`(UTF-8 無 BOM,唯讀屬性;三個 installer 同一個 schema,共用 `src/TwinCATAutomation/Private/InstallManifest.ps1`):`schemaVersion`(1)、`name`(SKILL.md frontmatter)、`module`、`sourceUrl`(.psd1 的 `ProjectUri`)、`version`(.psd1 的 `ModuleVersion`)、`release`、`commit`、`ref`、`commitSource`、`installer`(`claude-code` / `codex` / `antigravity`)、`installedAt`(UTC ISO-8601)、`sourcePath`、`hashAlgorithm`(`SHA256`)、`warnings`(安裝時讀不到的來源資訊，例如 commit 為何是 null)、`files[]`(`path` 以 `/` 分隔的相對路徑、`sha256` 小寫、`size`;`SKILL.md` 與 `TwinCATAutomation/` 全部檔案,不含 manifest 本身,也不含 Codex 的 `~/.codex/AGENTS.md`)。
- **commit 從哪來**(`commitSource`):先讀 checkout 的 `.git` 檔案(`HEAD`、`refs/heads/*`、`packed-refs`;linked worktree 的 `.git` 檔 + `commondir`)→ `git`;沒有 `.git` 才讀來源根目錄的 `tcauto-source.json` → `release-stamp`(**保留給 #20 的 release zip**,build 時寫入 `sourceUrl`、`commit`、`ref`、`release`,格式由 #20 定;commit 必須是 40 / 64 位 hex,否則忽略並警告);都沒有 → `unknown`、`commit = null`。**不啟動 git**,所以也看不出 working tree 有沒有未 commit 的改動:`commit` 是 HEAD,檔案內容以 `files[].sha256` 為準。symbolic ref 串接、reftable 格式的 repo 讀不到 commit(`commit = null`,原因放在 `warnings`);`.git` 存在但無法使用(亂碼 `.git` 檔、gitdir 不存在、檔案讀不到)時也會印警告，並改讀 `tcauto-source.json`。`.git` 的讀法與 `Get-TcModuleCommit`、MCP server 的 `moduleCommit` 共用同一套規則(`Read-TcGitCommit`,#148)。讀不到 .psd1 / stamp 不會讓安裝失敗，只會缺值並印警告。`Get-TcAutomationVersion` 在 source tree 只有模組資料夾確實是 `<root>\src\TwinCATAutomation`、且 `<root>` 有 `TwinCATSetup-Claude.ps1` 與 `adapters\claude-code\SKILL.md`(確定是這個 repo)時才讀 `<root>` 的 commit,否則 `commitSource = unknown`。兩種模式的 `data.warnings` 都是陣列(安裝副本來自 manifest)。
- **讀**:`Get-TcAutomationVersion`(MCP `GetAutomationVersion`,唯讀)。裝出來的副本回 `data.installed = true`、`source = install-manifest` 與 manifest 欄位;直接從 repo / 解開的 release 載入的模組(例如從 repo 啟動的 MCP server)回 `installed = false`、`source = source-tree`,version / commit 當場從 .psd1 與 stamp / `.git` 讀。
- **驗證**:`Get-TcAutomationVersion -Verify` 比對安裝的檔案與 manifest 的 SHA256(`data.verify`);installer 的 `-Verify`(`-SkillDir` 指定目錄)另外印出 manifest、再和「從這份來源安裝會寫出的內容」比對,commit 不同但檔案相同只標 `[DIFFERENT]`、不算 mismatch。測試用 `-SkillDir <暫存目錄> -SkipPrerequisites`(Codex 另有 `-CodexHome`),不碰使用者 profile;相對路徑以目前 PowerShell 位置為準並展開成實際拼法(大小寫、8.3 短名),安裝與 `-Verify` 寫進 SKILL.md 的模組路徑因此一致。installer 本身失敗(前置檢查沒過、helper 不見、複製或寫檔失敗、Codex 的 AGENTS.md 寫不進去、驗證過程出錯、`-Uninstall` 刪不掉)一律 exit 1,不會印「Installation Complete」。`-SkillDir` 不接受萬用字元(`*`、`?`)與非檔案系統路徑(`HKCU:\` 等);磁碟根目錄保持 `C:\`。`-Uninstall` 只刪 installer 寫過的目錄:要有 `SKILL.md`,再加上「讀得出來、由已知 installer(`claude-code` / `codex` / `antigravity`)寫的 manifest」或 `TwinCATAutomation\TwinCATAutomation.psd1`;其他目錄(例如只有一個空的 `{}` manifest 加上使用者檔案)拒絕並 exit 1。

### INSTALL_MANIFEST_NOT_FOUND

- **現象**:`Get-TcAutomationVersion -Verify` 找不到 `tcauto-install-manifest.json`(模組資料夾的上一層)。
- **為什麼**:模組是從 repo / 解開的 release 直接載入(`data.source = source-tree`,本來就沒有 manifest),或 skill 是舊版 installer 裝的。
- **下一步**:不帶 `-Verify` 呼叫 `Get-TcAutomationVersion` 看 `data.commit` / `data.commitSource`;要 manifest 就在來源 repo 重跑 `TwinCATSetup-<工具>.ps1`。

### INSTALL_MANIFEST_INVALID

- **現象**:manifest 讀不出來:JSON 壞掉、缺 `schemaVersion` / `files`,`schemaVersion` 比這個模組認得的新，某個 `files[].sha256` 不是 64 位 hex,或某個 `files[].path` 會離開安裝目錄(含 `..`、絕對路徑、`:`、`\`;這種 manifest 不拿來讀任何檔案)。
- **下一步**:不要手動修 manifest;在來源 repo 重跑 `TwinCATSetup-<工具>.ps1`(會覆寫 manifest)。

### INSTALL_MANIFEST_MISMATCH

- **現象**:`Get-TcAutomationVersion -Verify` 發現安裝的檔案與 manifest 的 SHA256 不同:`data.verify.mismatched`(內容不同,含 expected / actual)、`missing`(少檔)、`extra`(`TwinCATAutomation/` 底下多出 manifest 沒列的檔)、`unreadable`(檔案在但讀不到，例如被其他行程鎖住或沒有權限,`error` 是原因;讀不到不算通過)。
- **為什麼**:安裝後有人改過檔案、只複製了一部分,或用舊方式手動覆蓋。
- **下一步**:把 `data.verify` 回報給使用者;在來源 repo 跑 `TwinCATSetup-<工具>.ps1 -Verify` 看與來源的差異,再重跑 installer。不要自己把檔案改回去。

## 已知限制

使用者向的已知限制清單(現象、影響、繞過方式、issue)與真機驗證範圍:[known-limitations.md](known-limitations.md)。

| 限制 | 說明 | 繞法 |
|---|---|---|
| Build 錯誤沒有編碼 | Error List 沒有 Code 欄,`errorItems[].code` 只對常見訊息推得(C0046 等),其餘 null | 用 description + file + line 判斷;需要編碼時查 InfoSys compiler errors |
| UmRT 假 Run(舊版曾回報,2026-11-08 實測未重現) | 舊版紀錄:本機 UmRT 跑約 30 分鐘後 task 停止循環,但 ADS 仍回 Run;原始紀錄沒有日期與環境。實測 2026-11-08 #26:4026 VS2022 + 本機 UmRT,`TcSystemServiceUm` 行程跑 47 分、Activate 後 32 分,每 60 s 讀 `_TaskInfo[1].CycleCount` 都增加約 25000,PLC state 一直是 Run。47 分是這次測的上限,更長時間沒測 | 不需要特別處理。長時間測試仍可讀 `TwinCAT_SystemInfoVarList._TaskInfo[1].CycleCount` 兩次確認有在增加;沒動就當 runtime 異常,重啟 `TcSystemServiceUm` 後 `Enable-TcConfig -Force` |
| Reset 殺 service(舊版曾回報,2026-11-08 實測未重現) | 舊版紀錄:對 UmRT 送 `Set-TcPlcState -State Reset` 會直接結束 `TcSystemServiceUm`;原始紀錄沒有日期與環境。實測 2026-11-08 #26:4026 VS2022 + 本機 UmRT,registered tcauto 534f1d2,port 851 Reset 兩次都回 `currentState = Stop`,`TcSystemServiceUm` 同一個 pid 持續存在 60 s 以上,system 仍 Run,`Set-TcPlcState Run` 可恢復。因此模組沒有對 UmRT 的 Reset 加 `-Force` 擋 | Reset 後 PLC 停在 Stop,下 `Set-TcPlcState -State Run` 恢復;要重新載入程式則 Stop → `Enter-TcPlcOnline`。若 `TcSystemServiceUm` 真的消失,走 `RUNTIME_CRASHED`(#21)的處理 |
| UmRT crash(`TcSystemServiceUm` 消失,issue #21) | 簽章固定:`TcOsSys.dll` c0000005,offset 0x589534,bucket 1526877736441380629(dump `TcSystemServiceUm.exe.86180.dmp` / `.58132.dmp`)。crash #7 2026-10-20 22:09:40、#8 2026-10-21 00:57:15,兩次都在 6~9 s 前 `Boot\TCNC.bootdata` 被截成 0 bytes;#8 發生在已跑約 1 h 的 UmRT 做 set-config(port 10000 Config)時 | 重啟 `TcSystemServiceUm` 後 `Enable-TcConfig -Force`;根因在 UmRT 側,模組無法避免 |
| UmRT ADS 0x502「Mailbox is full」 | 2026-10-21 約 01:02 新現象:UmRT process 活著、CPU idle,對 199.5.42.250.1.1 的**每個** ADS 呼叫都回 0x502(本機 TcSysSrv 正常),`Enable-TcConfig` 180 s 後回 `SYSTEM_STATE_TIMEOUT`。先 `Get-TcSystemState -AmsNetId 127.0.0.1.1.1` 對照本機 TcSysSrv 正常、target 不正常即是 | kill 並重啟 `TcSystemServiceUm`,再 `Enable-TcConfig -Force` |
| solution platform 對到別的 project platform 的專案跑不到 UmRT | 專案設定(與 XAE 版本無關):A 組 Festo .sln 的 `Release\|TwinCAT OS (x64)` 對到 project platform `TwinCAT OS (ARMT2)` 且沒有 Build.0;Build「成功」(1.4 s)什麼都沒 build、Activate 無 `ACTIVATE_FAILED`、851 維持 Invalid(`PLC_NOT_LOADED`)。`Set-TcTarget -Platform 'TwinCAT OS (x64)'` 現在在切換前回 `PLATFORM_PROJECT_MISMATCH` | 在 Configuration Manager 讓 `TwinCAT OS (x64)` 底下的 .tsproj / PLC 專案對到真正的 `TwinCAT OS (x64)` project platform(沒有就新增)再 Build |
| 被 modal 擋住的 IDE 會被當過期實例 | IDE 被 modal 擋住時 DTE `Version` 讀空字串,`Connect-TcIde` 當 ROT 過期項目,帶 `-SolutionPath` 會另外啟動第二個 IDE(VS2022 出現過一次,**未修**) | 重連前先 `Get-TcIdeModalDialog` / MCP `GetIdeModalDialog`;有 dialog 先處理;已多開就用 `data.candidates[]` / `Stop-Process` 收掉多的那個 |
| 重新 download 後舊 handle 失效 | download 前建立的 variable handle 在 download 後回 ADS 0x711(實測 2026-11-08,#26;沒有讀到別的變數)。`TwinCAT_SystemInfoVarList._AppInfo.AppTimestamp`(DT,PLC application 編譯時間,[InfoSys PlcAppSystemInfo](https://infosys.beckhoff.com/content/1033/tc3_plc_intro/714818699.html))會變 | 模組每次讀寫都重查 symbol、用完刪 handle,遇 0x711 自動重開 session 重試一次(`data.symbolsReloaded`);自己寫的 ADS client 不要長期保留 handle |
| UIA 看不到的 dialog 仍會擋 quit | 標題為空等 UIA 掃描抓不到的 modal,`Disconnect-TcIde -Quit` 的事前檢查看不到,`Solution.Close` / `DTE.Quit` 照樣無限阻塞;經 MCP 時會先撞到 `BRIDGE_TIMEOUT`,走不到 `-Kill` | `Stop-Process -Id <data.ideProcessId>`(MCP 結果的 `data.lastIde.ideProcessId`),再重新 `Connect-TcIde` |
| Activate 前無法預檢 license(#49) | InfoSys 沒有 Activate 前唯讀判定 target license 是否足夠的方法(license 檢查是 runtime 啟動的一部分);只能在 Activate 後由 runtime 的 fatal error 認出 `LICENSE_MISSING`,這時 dialog 已經跳到所有連這個 target 的 XAE | 開始 lifecycle 前請使用者在 XAE 確認 License 節點;出現 `LICENSE_MISSING` 照該節處理 |
| FB `VAR_INPUT` 寫不進去 | PLC 每個 scan 覆寫 FB 輸入 | 在 MAIN 宣告獨立變數餵 FB,寫 MAIN 層級變數 |
| `Watch-TcVariable` 的 `samples` 被截短 | 預設只回最後 `-KeepLast` 筆(有 `-Until` 20、沒有 50),免得 50 筆 × 多變數塞爆 AI context;`sampleCount` 仍是總數,`truncated=true` 表示有丟 | 要全部就給大一點的 `-KeepLast`;等某個值用 `-Until "<Path> <op> <value>"`(`== != > < >= <=`,`<Path>` 要在 -Path 內,否則 `INVALID_PARAMS`),命中立刻返回 `untilMet=true` / `untilSample` / `elapsedMs` |
| `New-TcTestCase` / `Invoke-TcTest` 的 `-WaitMs` 是固定盲等 | 不建議使用(deprecated):不管 PLC 多快都等滿,太短又會誤判 | 改用 `-WaitUntil @{Path;Operator;Expected}` + `-WaitTimeoutMs`(預設 5000):條件成立立刻跑 assertions;逾時該 case 判 Fail,結果 `waitTimedOut=true`、`lastValues`(最後讀到的值)、`waitMs`(實際等待)。`WaitUntil` 格式錯(未知 key / Operator、缺 Path 或 Expected、`WaitTimeoutMs` 不在 1..600000)回 `INVALID_PARAMS`,不寫任何 setup |
| MCP 同回合平行 tool call 順序 | client 平行送出的 call 到達 server 的順序不保證;bridge 嚴格 FIFO 一次執行一個,但 FIFO 的順序 = 到達順序 | 看每個結果的 `order.seq` / `order.startedAt` / `order.finishedAt` 判斷實際順序(data 是物件時 `data.seq` 等也有;data 是陣列時只在 `order`,#57);有因果的步驟(寫參數 → 下命令 → 觀察)分回合送 |

## 真機驗證腳本

`tests/Integration/` 的手動腳本需要真實環境:`bool-write.ps1`、`write-verify.ps1`、`list-symbols.ps1`、`full-cycle.ps1`、`lifecycle-smoke.ps1`、`login-logout.ps1`、`build-errors.ps1`(注入 C0046 錯誤驗證 `Build-TcProject` 的 `errorItems`,只對複本跑)、`reload-experiment.ps1`(磁碟改 .TcPOU 的 reload 行為,S0a/S0b/S2a/S2b/S3/S3b 六種情境,只對複本跑)。用法見 `tests/Integration/README.md`。`false-success.ps1`:#28 / #32 的真機情境(少 Build.0、多 PLC readback、nested 讀值、Run 退回 Config);`tests/Unit/activate-timeout.ps1`:Activate deadline 的 mock 測試,不需 IDE。`tests/Unit/blocked-solution-ide.ps1`:`Connect-TcIde -SolutionPath` 遇到被擋住的 IDE(#29:session record / dialog 路徑 / 視窗標題、attach 與否、證據矛盾、pid 重用、失敗不留舊連線、不另開 IDE)的 mock 測試,不需 IDE。`tests/Unit/clear-project.ps1`:`Clear-TcProject` 讀回(`cleanVerified`、`LIBRARY_UNRESOLVED` 與 `-AllowUnresolvedLibrary`、`CLEAN_UNVERIFIED`、`CLEAN_FAILED`、`CLEAN_TIMEOUT`、`nullReads` 逾時)的 mock 測試,不需 IDE。`tests/Unit/platform-project-mismatch.ps1`:solution platform / project platform 檢查(`PLATFORM_PROJECT_MISMATCH`、.sln index 對應、讀回失敗還原)的 mock 測試,不需 IDE。

- `lifecycle-smoke.ps1 -AllowUnresolvedLibrary`:`03a` 的 `Clear-TcProject` 帶 `-AllowUnresolvedLibrary`,給已知缺 library 的複本用(A 組 Festo NoVisu,見「CLEAN_LIBRARY_UNRESOLVED」)。
- `lifecycle-smoke.ps1 -StopAfterBuild`:只跑到 `03b`(Connect、target、`Clear-TcProject`、Build),不 Activate。runtime 不能 Activate 時用(例如 license 過期:Activate 失敗的「Target system reports a fatal error」會跳到**所有**連這個 target 的 XAE,別的 session 的也會,實測 2026-10-25,4024 32-bit XAE Shell 與 4026 VS2022 同時連本機 UmRT)。
- `lifecycle-smoke.ps1 -SolutionPlatform '<name>'`:在 Connect 與 Build 之間多一步 `02b-platform`(`Set-TcTarget -Platform`);`02-set-target` 改帶 `-NoPlatformSwitch`(只換 NetId,不會因 `PLATFORM_UNKNOWN` 失敗)。UmRT 必帶 `'TwinCAT OS (x64)'`(B 組 35/35;這台 UmRT 不支援 TARGETINFO)。smoke 與 `multi-ide.ps1` 的 Clean 都改成 `Clean($false)` + 輪詢(VS2022 的 wait 版不返回)。
- `mcp-server/scripts/lifecycle-client.mjs`(手動,需真 IDE + runtime):經 MCP server 跑 `RunLifecycle` → `GetSystemState` → 兩次 `ReadVariable`(task cycle counter 必須增加)→ `DisconnectIde Quit=true`。參數 `--sln`(必填)、`--progid`(預設 `VisualStudio.DTE.17.0`)、`--netid`、`--platform`、`--read <path>`;`--expect-fail <CODE> [--fail-platform <platform>]` 先跑一次帶 `Platform=<fail-platform>` 的 `RunLifecycle` 並要求該 error code(例 `--expect-fail ACTIVATE_FAILED --fail-platform "TwinCAT RT (x64)"`)。環境變數 `TWINCAT_MODULE_PATH`、`TWINCAT_MCP_POWERSHELL`;exit code = 失敗步驟數。
