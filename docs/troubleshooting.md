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
- **真機測試預設專案(2026-10-28 起)**:取代舊 A 組 Festo(`C:\Temp\Verify-f7e-a`)與舊 B 組 Robust(`C:\Temp\Verify-f7e-b`),舊的只留歷史紀錄;共同規則與細節見 `docs/agent-brief-realmachine.md`「環境」。
  - 4024 組:`TcXaeShell.DTE.15.0`,`C:\Temp\Verify-4024-bfh\BFH-1650.sln`。solution platform 只有 `CE7 (ARMV7)` / `OS (ARMT2)` / `RT (x64)` / `RT (x86)`,`-Platform 'TwinCAT OS (x64)'` → `PLATFORM_NOT_FOUND`,不帶 `-Platform` → `PLATFORM_UNKNOWN`。把 EtherCAT Device 1 / 5 設成 Disabled 後(2026-10-28 11:16),`-NoPlatformSwitch`(平台維持 `TwinCAT RT (x64)`)全 lifecycle PASS:Build → `Enable-TcConfig -Force`(851 Run、bootPackage match、platformCheck skipped 0x702)→ `Connect-TcAds` → `Read-TcVariable`,`_TaskInfo[1].CycleCount` 持續增加。**觀察(實測,未查到 InfoSys 出處,只是這個 4024 專案,不是通則):** 4024 的 `TwinCAT RT (x64)` 在 UmRT 上 Activate 成功、沒有 `ACTIVATE_FAILED`,與 4026 要用 `TwinCAT OS (x64)` 不同。歷史:Device 未 Disabled 時 `Enable-TcConfig` 在 IO 階段被 CCAT PCI INIT→PREOP 0x98110700 擋下(`IDE_MODAL_DIALOG`、bridge 重啟)。(實測 2026-10-28)
  - 4026 組:`TcXaeShell.DTE.17.0` 與 `VisualStudio.DTE.17.0` 輪流用 `C:\Temp\Verify-4026-axis\AxisInterface_Type01_Library.sln`,`'TwinCAT OS (x64)'` 全 lifecycle PASS(Build → `Enable-TcConfig -Force` → `Connect-TcAds` → `Read-TcVariable`)。(實測 2026-10-28,本機 UmRT)
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

`Write-TcPouCode` / `Add-TcPou` 走 COM(`ITcSmTreeItem.DeclarationText` / `ImplementationText`)寫進 IDE,**不會**跳框,優先用它。寫入當下 XAE 就把 .TcPOU 寫到磁碟:實測 2026-10-28(4026 VisualStudio.DTE.17.0,`C:\Temp\Verify-repro-axis`)`WritePouCode` 後不 Build,磁碟 .TcPOU 的 LastWriteTime 與 `WritePouCode` 同一秒、檔內已有新內容,開著 editor 時也一樣([#69 實測留言](https://github.com/Lance0901/AI-TwinCAT-Skill/issues/69#issuecomment-6460378071));4024 未測。(早期 2026-10-20 在 4024 32-bit XAE 記錄過「mtime/hash 不變、要到存檔或 Build 才落地」,與 #69 的 4026 實測不同,4024 尚未重測。)新建物件的 `.plcproj` 項目則不會自己落地,見下方「新物件與 .plcproj(#76)」。AI 或其他工具直接改磁碟上的檔案時,決定一切的是「該檔案有沒有開在 XAE 的文件視窗」(2026-10-20 `tests/Integration/reload-experiment.ps1`,4024 32-bit XAE,log 在 `tests/Integration/logs/reload-S*.log`):

| 情境 | XAE 行為 | 正確做法 |
|---|---|---|
| 檔案**沒有**開在編輯器 | 約 5 s 內自動偵測並重載,`Get-TcPouCode` 讀到新內容、Build 用新檔;不跳任何框 | 改完等 5 s 再呼叫 DTE(或直接 `Reset-TcSolution` 確保一致) |
| 檔案**開著** | 約 1 s 後跳 modal「File has been changed outside the environment. Reload the new file?」,所有 DTE 呼叫阻塞;`Tools > Options > Environment > Documents > AutoloadExternalChanges` 壓不掉 | 改完**立刻** `Reset-TcSolution`:提示已經跳出來也沒關係,它會先把提示關掉(`dismissedReloadPrompt = true`),並 `Documents.CloseAll`,所以 reset 後檔案不再開在編輯器、下次改磁碟不會再跳(XAE 重開 solution 時會還原上次的編輯視窗,不關就會再跳) |
| `.plcproj` 被改寫(產生器、git checkout) | 跳 modal「The project file ... has been modified outside of TwinCAT XAE. Do you want to reload the project?」(`reload-prompt`、`ReloadTarget = project`),內容相同也會跳 | 改完**立刻** `Reset-TcSolution`:它對 project 提示按 Yes,XAE 自己 reload 專案,只重連不 close/reopen,比檔案提示的流程快(`data.answeredYes = true`、`data.reopenedSolution = false`);若同時還有 .TcPOU 的檔案提示,它會接著關掉並走完整 close/reopen |
| `Project.UnloadProject` / `ReloadProject` | 回「not available」、`GetItem` 為 null | 不可行,Automation Interface 沒有 reload 命令 |

**新物件與 .plcproj(#76)**:`CreateChild` 建的 POU / DUT / GVL 會立刻寫出自己的 .TcPOU / .TcDUT / .TcGVL,但 `.plcproj`(新物件的 `<Compile Include>`;新增 library 的 `<LibraryReference>` 也是)只改在 XAE 記憶體,要等存檔(或 Build;實測 2026-10-28 該副本的 .plcproj 最後寫入時間 = 第一次 Build,見 [#76](https://github.com/Lance0901/AI-TwinCAT-Skill/issues/76))才落地;`Reset-TcSolution` 的 `Solution.Close($false)` 之後重開,新物件就從專案消失(實測 2026-10-28,4026 VisualStudio.DTE.17.0,`C:\Temp\Verify-repro-axis`)。現在 `Add-TcPou` / `Add-TcDut` / `Add-TcGvl` / `Add-TcLibrary` 建好後會只存專案檔(有 deadline,逾時見「PROJECT_SAVE_TIMEOUT」),並從磁碟讀回 .plcproj 確認有新項目(含相對路徑,如 `POUs\FB_X.TcPOU`)才回 success(`data.projectSaved`:`verifiedFiles[].preExisting` 表示存檔前就已在、`plcprojChanged` 是存檔前後 SHA256 是否不同;失敗見「PROJECT_SAVE_FAILED」);`Reset-TcSolution` 關閉前也會比對,但預設不存(見下方步驟 (1b))。存檔用的 API(實測 2026-10-28,4026 VisualStudio.DTE.17.0):

| 候選 | 結果 |
|---|---|
| DTE `Project.Save()`(.tsproj 那個 project;[InfoSys「Accessing TwinCAT configuration」](https://infosys.beckhoff.com/content/1033/tc3_automationinterface/242721803.html) 的 C# / PowerShell 範例呼叫 `project.Save()`,2026-10-28 核對過頁面) | 寫出 .tsproj 與巢狀的 .plcproj(新 `<Compile Include>` 出現),約 0.1-0.2 s;IDE 裡未存的一般文字文件**沒有**被存。採用 |
| `ITcSysManager.SaveConfiguration(<tsproj>)` | 丟例外「SaveConfiguration only supported in Automation Legacy Mode!. Please use standard DTE. Solution features for Project persistance instead!」 |
| DTE `File.SaveAll` | 也會存 .plcproj,但同時把 IDE 裡未存的文件寫到磁碟。不用 |
| DTE `Project.Saved` / `IsDirty`、`Solution.Saved` / `IsDirty` | 未存的 `CreateChild` 之後仍是 True / False,不能拿來判斷 dirty;巢狀 PLC project 也不在 `Project.ProjectItems` 裡 |

**實測 2026-10-28(4026 VisualStudio.DTE.17.0):一般文字文件不會被存;PLC editor 中未存的 POU 內容是否會被寫出未驗證**(不經 GUI 做不出 dirty 的 PLC editor buffer)。這同時適用於 `Add-*` 的自動存檔與 `Reset-TcSolution -SaveProjectChanges`。

**找 .plcproj(`Get-TcPlcProjectFile`)**:讀 solution 裡每個 .tsproj 的 `<Project Name="<Plc>" PrjFilePath="...plcproj">`(4024 / 4026 實測有,路徑相對 .tsproj 所在資料夾)。多個 .tsproj 列了同名 PLC 時取第一個,`data.projectSaved.warning` / `projectCheck.plcs[].warning` 說明。PLC 存成獨立專案檔(.xti,[InfoSys「Enabling and disabling an Independent Project File」](https://infosys.beckhoff.com/content/1033/tc3_automationinterface/21842602763.html))時,InfoSys 沒寫 .xti 放哪、PrjFilePath 相對於誰;模組退而搜尋 .tsproj 資料夾下的 *.xti,PrjFilePath 先相對 .tsproj、再相對 .xti 資料夾,只接受實際存在的 .plcproj(**未驗證**,本機沒有這種專案)。仍找不到:`Reset-TcSolution` 把該 PLC 標 `checked = false` + `reason` 並跳過比對(不擋 Reset);`Add-*` 回 `PROJECT_SAVE_FAILED`,hint 請使用者在 XAE 手動存該 PLC 專案。

`Reset-TcSolution [-SolutionPath <sln>] [-TimeoutSec 120] [-SaveProjectChanges | -DiscardProjectChanges]` 的步驟:(1) `Get-TcIdeModalDialog`(連續出現的 reload 提示最多處理 5 個):`ReloadTarget = project` 就按 Yes(`Close-TcMessageBox -Answer Yes`,等最多 15 s 消失,`data.answeredYes = true`);`ReloadTarget = file`(或 Yes 失敗的 project 提示)就對該視窗(只接受自己 IDE pid 的)送 WM_CLOSE,等它消失(真機 2 s);兩者都設 `data.dismissedReloadPrompt = true`、`data.reloadTarget`;其他 modal 回 `IDE_MODAL_DIALOG`,因為 `Solution.Close` 也會被擋。只按過 Yes(沒有用 WM_CLOSE 關過檔案提示)時跳過 (2)~(4),直接 (5) 重連並探測 `LookupTreeItem('TIPC')`,成功就回傳(`data.reopenedSolution = false`),探測失敗才繼續 (2)~(5)。(1b)(#76,`-DiscardProjectChanges` 跳過)比對每個 PLC 在 XAE 裡的頂層物件(POU / DUT / GVL / ITF)與磁碟 .plcproj 的 `<Compile Include>`(`data.projectCheck`:每個 PLC 的 `checked` / `reason`、`missingOnDisk[]`(`file`、`relativePath`、`fileExists`)、`extraOnDisk`(只拿有副檔名對應的物件檔名比,不拿資料夾名)、`complete`;樹走訪有 5000 節點 / 60 s 上限,超過就 `complete = false` + `reason`)。「XAE 有、磁碟 .plcproj 沒列」與「有人在磁碟上刪了物件」分不出來,所以**預設不存**:有 `missingOnDisk` → `PROJECT_UNSAVED_CHANGES`,不存、不關 solution(只有 `extraOnDisk` 不擋：重開就載入磁碟版本,XAE 不會掉東西)。`-SaveProjectChanges`(保留 XAE 版本)才只存專案檔(DTE `Project.Save()`,有 deadline)並以相對路徑讀回,`data.savedProjects` 列出;但步驟 (1) 處理過 reload 提示、`missingOnDisk` 的物件檔在它的相對路徑上不存在，或同一個 .tsproj 的任一 PLC(`Project.Save` 會寫整個 .tsproj 與其下所有 .plcproj;.tsproj 不明的也算)`checked = false`、比對不完整或 `extraOnDisk` 非空時仍拒絕存(`PROJECT_UNSAVED_CHANGES`,`data.saveRefused`)。存檔失敗回 `PROJECT_SAVE_FAILED` / `PROJECT_SAVE_TIMEOUT`,不關 solution。兩個開關同時給回 `INVALID_PARAMS`。未存的 library reference / task / I/O 變更偵測不到。(2) `Documents.CloseAll(vsSaveChangesNo)`,`data.closedDocuments`。(3) `Solution.Close($false)`、釋放舊 `ITcSysManager`。(4) 在**同一個** `$dte` 上 `Solution.Open(<sln>)`(真機 7~9 s,`data.openSec`):`Connect-TcIde -SolutionPath` 不會接沒開 solution 的 IDE(那是別人的,見 PR #9),所以必須在手上這個實例重開。(5) `Connect-TcIde -SolutionPath <sln> -ProgId <同一個> -NoLaunch`,以 solution-match 接回同 pid、重取 `ITcSysManager`、重開 SilentMode(真機 12~13 s,`data.connectSec`);`data.sameIde` 回報。全程 `data.totalSec` 實測 22~25 s(2026-10-20 真機 10/10 PASS,含 reload 框跳著時呼叫的情境)。ADS 連線不受影響;`Enable-TcConfig` 後的 PLC 不受影響。solution 路徑由 `Connect-TcIde` / `Open-TcProject` 記住(`$script:TcSolutionPath`),`Disconnect-TcIde` 清掉。中途失敗時 `data.closed` / `data.reopened` 說明做到哪一步。

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

### IDE_BLOCKED_OWN

- **碼與 hint**:hint key;錯誤碼是 `IDE_MODAL_DIALOG` 或 `IDE_BUSY`,情況同「IDE_BLOCKED_SAME_NAME」,但 `data.launchedBySession = true`:被擋住的 IDE 是本 session 啟動的。
- **為什麼**:那很可能就是你的 IDE,只是證據不夠 attach;`-LaunchIfBlocked` 會再開一個 IDE 開同一個 .sln,所以這個 hint 不建議它。
- **下一步**:處理 `data.dialog`(`Get-TcIdeModalDialog -ProcessId <data.ideProcessId>`)後重跑同一個 `Connect-TcIde`;卡死就 `Stop-Process -Id <data.ideProcessId>`(只限本 session 啟動的)再重新 `Connect-TcIde`。

### IDE_MODAL_DIALOG / IDE_MODAL_DIALOG_RELOAD

- **碼與 hint**:錯誤碼都是 `IDE_MODAL_DIALOG`;`IDE_MODAL_DIALOG_RELOAD` 只是 `kind = reload-prompt` 時用的 hint key(`error.hint` 指向 `Reset-TcSolution`)。
- **現象**:`Build-TcProject`、`Enable-TcConfig`、`Enter-TcPlcOnline`、`Connect-TcIde`、`Reset-TcSolution` 回 `IDE_MODAL_DIALOG`(`Disconnect-TcIde -Quit` 遇到 modal 回的是 `IDE_QUIT_FAILED`,見下),`data.dialogTitle` / `dialogText` 是視窗標題與內文,`data.dialogKind` 是分類:`reload-prompt`(磁碟改檔的 reload 提示,hint 指向 `Reset-TcSolution`,見「磁碟改檔的正確做法」)或 `unknown`;`data.dialogReloadTarget` 區分 `file`(.TcPOU 等開著的檔案,「File has been changed outside the environment」)與 `project`(.plcproj 被改寫,「The project file ... has been modified outside of TwinCAT XAE. Do you want to reload the project?」)。
- **為什麼**:XAE / VS 有 modal 視窗(見「已知 modal dialog」)。這類視窗不會讓 COM 回 `RPC_E_CALL_REJECTED`,而是讓 DTE 呼叫無限阻塞,retry 救不了,所以模組在每個主要 COM 步驟前先用 UI Automation 掃 IDE 程序(`data.ideProcessId`)的頂層視窗。`Build-TcProject` 輪詢 `BuildState` 期間也每輪掃,build 中跳出的 dialog 回這個碼(不再等到逾時)。
- **下一步**:先 `Get-TcIdeModalDialog`(MCP `GetIdeModalDialog`)看 `kind`:`reload-prompt`(兩種 target 都算)→ 直接 `Reset-TcSolution`(project 提示按 Yes、檔案提示 WM_CLOSE + close/reopen);其他手動處理 dialog 後重跑同一個 cmdlet,關不掉就 `Disconnect-TcIde -Quit -Kill`(只限本 session 啟動的 IDE)或 `Stop-Process -Id <ideProcessId>`,再重新 `Connect-TcIde -SolutionPath <sln>`。除了 reload 提示,模組不會自動關閉任何視窗。
- **限制**:已經被 modal 擋住、正在阻塞中的呼叫無法從模組中斷;偵測靠視窗的 `IsModal` / `#32770` class / 已知標題,偵測不到時仍可能卡住。
- **`Connect-TcIde -SolutionPath` 遇到被 modal 擋住的 IDE(#29)**:以前 ROT 探測讀不到被擋住那個 IDE 的 solution,就把它跳過:帶 `-NoLaunch` 回 `IDE_NOT_FOUND`(更舊的版本回 `PROJECT_OPEN_FAILED` null-valued expression),不帶就**再開一個 IDE** 開同一個 .sln。實測 2026-10-25(4024 32-bit XAE Shell,磁碟改寫 `plc.plcproj` 觸發 XAE「The project file ... has been modified outside of TwinCAT XAE」):被擋住時 `DTE.Version` 回**空字串**(不是 `RPC_E_CALL_REJECTED`)。現在對讀不到(忙碌或回空值)、pid 已知的 ROT 項目不呼叫 COM,module-state / session-record 必須**沒有矛盾、而且有當下事實佐證**(標題以 solution 名稱開頭,或 dialog 路徑在資料夾內)才算強證據;依序看四種證據:(0) 模組自己上一次連的就是這個行程且是同一個 .sln(`module-state`);(1) session record:先前任何一次 `Connect-TcIde` 成功連上同一個行程(pid + 啟動時間)並開著這個 .sln(`%LOCALAPPDATA%\TwinCATAutomation\ide-solutions.json`,每次帶 solution 連線成功就寫;記錄是別的 .sln 就排除),`matchedBy = session-record`;(2) UI Automation 掃到的 dialog 內文路徑落在 .sln 資料夾內(`dialog-path`;路徑都在別處就排除);(3) 主視窗標題以 solution 名稱開頭(`window-title`,弱證據)。符合就回 `IDE_MODAL_DIALOG`(`data.ideProcessId`、`rotDisplayName`、`windowTitle`、`matchedBy`、`probe`、`attached`、`data.dialog`),**不另開 IDE**。(0)(1) 要有當下事實佐證(`data.corroboratedBy`:`dialog-path`,或標題以 solution 名稱開頭且沒有已知的同名 .sln 開在別處時的 `window-title`)且沒有矛盾,或是沒有矛盾的 (2),才 attach:模組連線同時指向該 IDE(`attached = true`),接著 `Get-TcIdeModalDialog` / `Reset-TcSolution` 可以直接用(reload 提示 → `Reset-TcSolution` 按 Yes 後自己重連);只有 (3) 時不 attach(`attached = false`,理由見「IDE_BUSY」);關掉 dialog 後重跑同一個 `Connect-TcIde` 就是 `solution-match`。只回空值而沒有 dialog 的 IDE 視為正在關閉,照舊跳過。 **證據互相矛盾時不 attach**:session record / module-state 可能過期(例如在 GUI 換開別的 solution),所以 dialog 內文的專案檔都在別處,或標題非空卻不以 solution 名稱開頭時,降成弱證據;`Open-TcProject` / `New-TcProject` 換 solution 時也會更新 record。module-state 比對 pid **和**啟動時間(pid 重用不算)。兩個以上 IDE 都有強證據時一個都不 attach(`data.blockedCandidates` 全列)。失敗的 `Connect-TcIde` 不會留下上一個 IDE 的連線(`TcDte` 等一律清掉),所以 hint 叫你接 `Reset-TcSolution` 時只會作用在 attach 的那個 IDE。限制:dialog 內文的路徑以文字比對(`GetFullPath` 後),8.3 短檔名與 UNC 路徑不會展開,可能比不出 `inside`。殘留風險:dialog 沒有路徑時只剩標題能佐證;已知(ROT 讀得到、或有 session record)的同名 .sln 開在別處時標題不算佐證,但若同名的另一份是在同樣被擋住、沒有記錄的 IDE 裡(例如使用者手動開的),標題分不出兩者,record 仍可能被標題佐證而 attach。

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

### RUNTIME_CRASHED

- **現象**:`Set-TcSystemState`(以及呼叫它的 `Enable-TcConfig -Force` 的 set-config / set-run)等狀態切換時，本機 UmRT 的 `TcSystemServiceUm` 行程不見了。以前會一直輪詢到 `-TimeoutSec` 才回 `SYSTEM_STATE_TIMEOUT`(message 還寫「last state: Run」);實測 2026-10-29(4026 VS2022,本機 UmRT,`tests/Integration/logs/phase0-1.7-results.md` 發現 1、2):set-config 開始約 40 s 行程就消失，之後每次都是 ADS 0x7,等滿 300 s。
- **觸發條件**(`Wait-TcAdsState -DetectRuntimeCrash`,三個都成立才回):
  1. target 是**本機 UmRT**:target AmsNetId 等於本機 `%ProgramData%\Beckhoff\TwinCAT\3.1\Runtimes\<name>\3.1\TcRegistry.xml` 的 `AmsNetId`(`Resolve-TcTargetBootDir` 回 `umrt:<name>`;檔案格式 InfoSys 未記載，實測 2026-10-21),而且開始等待時有命令列含 `-n "<name>"` 的 `TcSystemServiceUm.exe`(`Get-TcLocalUmRtProcess`;命令列讀不到時改用讀不到命令列的那幾個 `TcSystemServiceUm.exe`)。
  2. port 10000 連續回 **ADS 0x7**(`ADS_TARGET_NOT_FOUND`,target machine not found)至少 10 s;中間只要有一次別的結果就重新計時。
  3. 開始等待時記下的 pid(`data.servicePidAtStart`)全部已經不存在。
  遠端 target、本機 XAR、開始時沒有 UmRT 行程：不偵測，行為不變(等到 `-TimeoutSec`)。
- **data**:`lastError`(最後一次 ADS 錯誤)、`lastState`(等待中最後讀到的狀態，沒讀到就是送出前的狀態)、`servicePidAtStart`、`runtimeName`、`unreachableMs`,其餘同 `Set-TcSystemState`。`Enable-TcConfig -Force` 原樣回 code 與 hint,crash 資料在 `data.runtimeCrash`;`Invoke-TcTestCycle` 也原樣回 `RUNTIME_CRASHED`(不改成 `ACTIVATION_FAILED`),附 `data.runtimeCrash`。
- **下一步**:不要重試同一步。行程已不在就直接重新啟動 `TcSystemServiceUm`(指令見上面 `SYSTEM_STATE_TIMEOUT` 的 UmRT 重啟指令;還有殘留行程才先 `Stop-Process`),重啟後 runtime 停在 Config,再 `Enable-TcConfig -Force`(MCP `EnableConfig Force=true`)。crash 簽名(Windows 事件 1000 的 faulting module / exception code、`%LOCALAPPDATA%\CrashDumps\TcSystemServiceUm.exe.<pid>.dmp`)對照「已知限制」的 UmRT crash(#21);簽名不同就記下 dump 開 issue。

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
- **有 project 被跳過時 `codeVerified` 不是 true(#58)**:被跳過的 PLC 程式碼沒有被編譯,Error List 乾淨也證明不了它,所以 `data.codeVerified = false`,`data.warningCodes` 是 `["PROJECT_SKIPPED_BY_CONFIGURATION", "CODE_NOT_VERIFIED"]`(全部被跳過 = 這次沒有編譯任何 PLC 程式碼,`data.warning` 的 CODE_NOT_VERIFIED 文字會寫 all skipped)。solution 裡沒有 PLC project 也是 `codeVerified = false`;PLC project 清單讀不到(`data.coverageError`)是 `codeVerified = null`。
- **`data.solutionConfiguration` 是 solution platform(#58)**:`'<Configuration>|<solution platform>'`,讀法同 `Get-TcIdeInfo`(`Solution.Properties('ActiveConfig')`),`data.solutionPlatform` 等於 `Get-TcIdeInfo` 的 `solutionPlatform`,`data.projectPlatform` 是其下 .tsproj 的 project platform;每個 PLC project 的 project platform 在 `data.projects[].platform`。`data.platformSource` 寫 solution platform 的讀法(`ActiveConfig` / `PlatformName` / `context`);是 `context`(只讀得到 SolutionContext 的 platform,那是 project platform)時,`solutionConfiguration` 只放 configuration 名稱。以前這欄用 PLC context 的 platform 拼,會顯示 project platform(實測 2026-10-26,VisualStudio.DTE.17.0,TwinCAT_Festo 4026 複本:solution `Release|TwinCAT OS (x64)` 被顯示成 `Release|TwinCAT OS (ARMT2)`)。
- **solution Build、單一 project Build、compiler coverage 的差別**:solution Build(`Build-TcProject`)= 只編 `ShouldBuild = true` 的 project;單一 project Build(XAE 右鍵 Build / `SolutionBuild.BuildProject`)不受 Build.0 影響;compiler coverage = 這次 Build 實際編到哪些 PLC,看 `data.projects[].status`。
- **下一步**:XAE Configuration Manager 把該 PLC project 的 Build 勾起來並存檔(會補回 Build.0),再 `Build-TcProject -ExpectedProject <name>`。

### EXPECTED_PROJECT_NOT_FOUND / BUILD_COVERAGE_UNKNOWN

- **EXPECTED_PROJECT_NOT_FOUND**:`-ExpectedProject` 的名稱不是這個 solution 的 PLC project(比對 .plcproj 檔名,不含副檔名;也收 `TIPC^<Plc>`),沒有開始 Build。用 `data.projects` 的 name。
- **BUILD_COVERAGE_UNKNOWN**:帶了 `-ExpectedProject` 但無法確認它有被編到:SolutionContexts 讀不到(`data.coverageError`),或 Build 結果不是成功、Error List 又沒有那個 project 的列(status `unknown`)。不要當成 Build 成功。

### BUILD_FAILED / BUILD_FAILED_COMPILE

- **碼與 hint**:錯誤碼是 `BUILD_FAILED`;`BUILD_FAILED_COMPILE` 是讀到 Error List 錯誤列時用的 hint key(看 `data.errorItems`)。
- **為什麼**:成功與否依序判定:(a) `SolutionBuild.LastBuildInfo`(= build 失敗的專案數,回在 `data.failedProjects`)讀得到就用它(> 0 = 失敗);(b) 讀不到(`failedProjects = null`)就看 Error List:有任何**非 Library Manager** 的 Error(file 不像 `*Library Manager`、line > 0)就算失敗;(c) 兩者都讀不到 → `BUILD_STATUS_UNKNOWN`(見下)。TwinCAT 的 PLC 編譯訊息**不走** DTE(`ErrorList.ErrorItems.Count` 永遠 0、`OutputWindow.OutputWindowPanes` 空),所以模組用 UI Automation 讀 XAE 的 Error List 視窗(`Get-TcBuildErrors`),`data.errorItems[]` 是 Error List 全部錯誤,每筆 `{ severity, code, description, project, file, line, column, category }`;`category`(#23)是 `library`(file 像 `*Library Manager` 且無 line,或無 line 的「Could not open library」訊息)、`code`(有 file)、`other`(沒有 file,例如 build 摘要列)。`data.errors` **只算 code error**(= `data.codeErrors[]` 筆數),library 項另計在 `data.libraryErrors` / `data.libraryErrorItems[]`(有 library 錯誤時見 `LIBRARY_UNRESOLVED`);`data.buildSucceeded` 是判定結果,`data.decidedBy` 說明由誰判定(`LastBuildInfo` / `ErrorList`),`error.message` 含 code error 數(括號補 library 數)與前 3 筆非 library 錯誤摘要。
- **下一步**:看 `data.codeErrors`(file + line 直接指到 POU),改 code 後 `Build-TcProject`。不要在沒改東西的情況下重跑 Build。`data.errorListError` 出現時表示 Error List 讀不到(見 `ERRORLIST_UNAVAILABLE`),`errors` 退回 `failedProjects`、`libraryErrors` 為 null。

### LIBRARY_UNRESOLVED

- **`data.errors` 語意變更(#23,breaking)**:`errors` 不再含 Library Manager 列,只算 code error;library 列在 `libraryErrors` / `libraryErrorItems[]`。分類只認英文 UI 的 file `*Library Manager`(無 line)與訊息「Could not open library」/「has not been installed」(2026-10-18 英文 XAE 實測);**zh-TW 等其他語系的 Library Manager file 名稱與訊息未實測**:那些列會被分成 `code`,但沒有行號,所以 `codeVerified = false` 並回 `CODE_NOT_VERIFIED`(見下),不會被當成驗證過的成功。

- **為什麼**:Error List 有 library 錯誤(`data.libraryErrorItems[]`:Library Manager 的「Could not open library」placeholder 無法解析、「has not been installed」),而 build 本來會判成功。這時 PLC 程式碼可能根本沒被編譯:**實測 2026-10-25**(TcXaeShell 4024,TwinCAT_Festo 複本,缺 7 個 library,#45)在 POU 裡寫未宣告的識別字,Build 仍是 `LastBuildInfo = 0`、Error List 沒有 C0046;同樣的改法在沒有缺 lib 的專案上是 `BUILD_FAILED` + C0046。所以 `Build-TcProject` 不再把它當成功:`success = false`、`data.buildSucceeded = null`、`data.codeVerified = false`、`data.projects[].status = unknown`。`data.codeVerified = true` 表示 Error List 讀得到且沒有 library 錯誤。
- **下一步**:在 XAE 的 Library Manager 安裝缺的 library(名稱 / 版本在 `data.libraryErrorItems[].description`),再 `Build-TcProject`。使用者確定要接受「程式碼可能沒編譯」時才用 `Build-TcProject -AllowUnresolvedLibrary`(MCP:`BuildProject` `AllowUnresolvedLibrary: true`):回 success,`data.warningCodes[]` 含 `LIBRARY_UNRESOLVED`(`data.warningCode` 是第一個,`PROJECT_SKIPPED_BY_CONFIGURATION` 排前面)+ `data.libraryWarning`;這時 `data.projects[].status` 仍是 `built`(build 的結果),程式碼沒被證實有編譯由 `codeVerified = false` 表示。有 code error 時照常是 `BUILD_FAILED`。**#61 起這種 build 永遠不算完整**(`data.completeBuild = false`):`Build-TcProject` 記下 / 保留 BUILD_REQUIRED(unverified-build),`Enable-TcConfig` / `Enter-TcPlcOnline` 照樣拒絕 Activate / Login / Download / Run——module 記錄到 codeVerified 不是 true 的 build 之後，不會 Activate / Download / Run(範圍:只擋經 module build 或改動過的 solution；從未經 module build 的 solution 不擋，見本文件 BUILD_REQUIRED)。所以 `-AllowUnresolvedLibrary` 只適合「只想看 build 結果 / Error List」;要 Activate 就得先把 library 裝好。`Enable-TcConfig`、`Invoke-TcTestCycle`、MCP `RunLifecycle` / `RunTestCycle` 已經**沒有** `-AllowUnresolvedLibrary`(#61 移除;留著會讓人以為能放行)。

### CODE_NOT_VERIFIED

- **為什麼**:`Build-TcProject` 判定成功,但沒辦法證明 PLC 程式碼有被編譯:Error List 讀不到(`data.errorListError`,例如 `ERRORLIST_UNAVAILABLE`;`codeVerified = null`、`libraryErrors = null`,`errors` 退回 `failedProjects`),或 Error List 有「有 file、沒有行號」的 code 列(`codeVerified = false`;可能是分類規則不認得的語系的 Library Manager 列),或有 PLC project 被 active solution configuration 跳過(`codeVerified = false`,排在 `PROJECT_SKIPPED_BY_CONFIGURATION` 之後,#58;見上一節)。這是 warning,不是錯誤:`success = true`,`data.warningCodes[]` 含 `CODE_NOT_VERIFIED`,`data.warning` 說明原因。
- **`data.warningCodes` 的順序與並存(#56)**:依序 `PROJECT_SKIPPED_BY_CONFIGURATION`、`LIBRARY_UNRESOLVED`(只在加了 `-AllowUnresolvedLibrary` 時)、`CODE_NOT_VERIFIED`;`data.warningCode` / `data.warning` 是第一個，每個碼都會 Write-Warning。同一次 build 同時有 library 錯誤和「沒有行號的 code 列」時，兩個都放進去:`["LIBRARY_UNRESOLVED", "CODE_NOT_VERIFIED"]`(兩個是獨立的缺口:library 錯誤讓程式碼可能沒編譯，沒行號的 code 列是分類規則不認得的列),而且 `completeBuild = false`(加了 `-AllowUnresolvedLibrary` 的 build 本來就永遠不完整,#61)。只有 library 錯誤、沒有沒行號的列時只有 `LIBRARY_UNRESOLVED`(它已經說明程式碼沒被證實);有 project 被跳過又有 library 錯誤時是 `["PROJECT_SKIPPED_BY_CONFIGURATION", "LIBRARY_UNRESOLVED"]`。沒加 `-AllowUnresolvedLibrary` 時有 library 錯誤就是 `LIBRARY_UNRESOLVED` 錯誤，不會有 warningCodes 的 CODE_NOT_VERIFIED。
- **solution 裡沒有 `.plcproj`(只有 I/O 或 NC 設定)時，出現這個碼是預期結果**:沒有 PLC 程式碼可以驗證,`codeVerified = false`,不代表 build 有問題。
- **下一步**:看 XAE 的 Error List;Error List 讀不到時照 `ERRORLIST_UNAVAILABLE` 處理後重跑 `Build-TcProject`;project 被跳過時照 `PROJECT_SKIPPED_BY_CONFIGURATION` 處理。在確認之前不要把它當成「程式沒問題」。

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
- **「完整成功」的條件(#58 後收緊)**:`success = true`、`data.coverageComplete = true`(每個 PLC project 都是 built,PLC project 清單讀得到，且 solution 裡至少有一個 PLC project),而且 `data.codeVerified = true`。沒有例外:`-AllowUnresolvedLibrary` 接受的 build(codeVerified = false)也不算(#61;以前算，結果未驗證的程式被 Activate)。以下情況 build 回 success 也**不會**清掉:有 project 被 `PROJECT_SKIPPED_BY_CONFIGURATION` 跳過、PLC project 清單讀不到(`coverageError`,`codeVerified = null`)、Error List 讀不到、有無行號的 code 列、solution 裡沒有 PLC project(只有 I/O 或 NC;這種 solution 切換平台後只能用下面的手動解除)。`Build-TcProject` 的 success 結果有 `data.completeBuild`(這次算不算完整成功);`Enable-TcConfig` 回 `BUILD_REQUIRED` 時,message 和 `platform-fix-build` 步驟的 detail 會寫上一次成功的 build 為什麼不算(`completeBuild=false, codeVerified=..., coverageComplete=..., warningCodes=[...]`),所以看得出原因;platform-fix-build 回 success 但不完整時,那一步是 ok=false、錯誤碼 `BUILD_REQUIRED`(#61)。
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
- **回傳格式與 `Build-TcProject` 相同**(cd180df):`Clear-TcProject` 用同一個分類器(`Get-TcErrorItemCategory`)和 `Add-TcBuildWarning`,`data.errorItems[]` 每筆有 `category`(`code` / `library` / `other`)、`data.libraryErrorItems[]`,warning 放在 `data.warningCodes[]`(目前只會有 `LIBRARY_UNRESOLVED`)、`data.warningCode`(第一個)、`data.warning`。

### RESET_SOLUTION_MISMATCH

- **現象**:`Reset-TcSolution` 沒有動作,`data.openSolution` 與 `data.expectedSolution` 不同。
- **為什麼(#29)**:`Connect-TcIde` 可能依 session record 等證據 attach 了一個被擋住的 IDE;關掉 dialog 後讀得到的 `Solution.FullName` 若不是模組以為的 solution(模組最後連到 / 開啟的那個;沒有就用 `-SolutionPath`),關閉它會動到別人的工作,所以在 `Documents.CloseAll` / `Solution.Close` 之前就停下。`-SolutionPath` 指定另一個 .sln(換開)不算不一致:比對的是 IDE 目前開的與模組預期的。
- **下一步**:`Connect-TcIde -SolutionPath <你的 sln>` 連到正確的 IDE(找不到就加 `-LaunchIfBlocked`),再 `Reset-TcSolution`。

### RESET_SOLUTION_UNVERIFIED

- **現象**:`Reset-TcSolution` 沒有動作(什麼都沒關),`data.guardError` 是最後一次讀 `Solution.FullName` 的錯誤,`data.guardSec` 是等了多久。
- **為什麼(#29)**:關閉前的防呆(見「RESET_SOLUTION_MISMATCH」)要先讀到 IDE 目前開的 solution 才能比對;在 `-TimeoutSec` 內每 500 ms 重讀,一直丟例外或回 `$null`(例如 reload 後 XAE 還在忙)就 fail-closed,不關沒有比對過的 solution。讀回空字串(沒有開著的 solution)才放行。
- **下一步**:`Get-TcIdeModalDialog -ProcessId <data.previousIdeProcessId>` 看有沒有 dialog 並處理;等 XAE 不忙後重跑 `Reset-TcSolution`(可加大 `-TimeoutSec`);仍讀不到就 `Connect-TcIde -SolutionPath <sln>` 重新連線再試。

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

### SOLUTION_CLOSE_FAILED / NO_SOLUTION

- **現象**:`Reset-TcSolution` 回 `SOLUTION_CLOSE_FAILED`(`Solution.Close` COM 呼叫失敗;被 dialog 擋住時是 `IDE_MODAL_DIALOG` / `IDE_BUSY`)或 `NO_SOLUTION`(沒有開啟的 solution、也沒給 `-SolutionPath`)。
- **下一步**:`Get-TcIdeModalDialog` 看有沒有 dialog;`NO_SOLUTION` 就 `Connect-TcIde -SolutionPath <sln>`。關掉之後重開失敗時,結果保留 `Connect-TcIde` 的 code / hint,`data.closed = true` 表示 solution 已關、要自己重連。

### LIBRARY_ADD_FAILED

- **做法(#80)**:`Add-TcLibrary` 對 `TIPC^<Plc>^<Plc> Project^References` 呼叫 `ITcPlcLibraryManager.AddLibrary(name, version, vendor)`(TE1000 v1.7.0 §6.5.14 "Managing PLC libraries and placeholders",p.241-243;§5.25.1.10 `AddLibrary`,p.118)。舊做法 `TIPC.Child(1).LookupChild('References')` + `CreateChild` 會回 `0x98510001`:在 4026 / 4024 副本上，連 `LookupChild('References')` 這一步就丟 `0x98510001`,因為 References 在 `<Plc> Project` 底下，不在 `<Plc>` 底下(實測 2026-10-28,4026 VS2022)。
- **沒安裝(`data.notInstalled = true`)**:AddLibrary 丟 `TSM_E_ITEMNOTFOUND`(手冊 §5.25.1.10:"Managed/default library not found"),實測為 `0x98510001` `"Managed Library '<name>, * (Beckhoff Automation GmbH)' not found!"`。模組不存檔,`.plcproj` 不變(4024 / 4026 都用 SHA256 確認，實測 2026-10-28),也不記 BUILD_REQUIRED。下一步：在 XAE 的 PLC > Library Repository 安裝該 library(或用 TwinCAT Package Manager 裝對應套件),確認名稱 / 版本 / 廠商，再重跑。
- **已有同名 reference**:不是錯誤。模組先讀 `ITcPlcLibraryManager.References` 的 `Name`(§5.25.1 p.113、§5.24.1 p.112;placeholder 列成 `#<name>`,實測),有 `<Name>` 或 `#<Name>` 就不呼叫 AddLibrary,回 success、`data.alreadyPresent = true`、`data.existingReference`,仍會存檔並讀回 `.plcproj` 驗證，不記 BUILD_REQUIRED。直接對已有的 library 呼叫 AddLibrary 會丟 `ArgumentException` `0x80070057` `"Managed Library '...' already contained!"`(手冊:"Library or placeholder is already included";實測 2026-10-28,4026),這個例外也對應成同樣的 alreadyPresent 結果。
- **其他失敗**:`LIBRARY_ADD_FAILED` 加原始訊息;保守起見記 BUILD_REQUIRED(`[failed after AddLibrary]`)。
- **`-Version '*'`**:預設值,`.plcproj` 寫成 `<LibraryReference Include="<name>,newest,<vendor>">`(實測 2026-10-28,4024 / 4026)。多個 PLC project 時要給 `-PlcProjectPath`,否則 `PLC_PROJECT_AMBIGUOUS`。

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
- **下一步**:(1) 保留 XAE 版本 → `Reset-TcSolution -SaveProjectChanges`(MCP `ResetSolution SaveProjectChanges=true`);(2) 以磁碟為準 → `Reset-TcSolution -DiscardProjectChanges`;(3) 兩邊都要 → 先在磁碟上補回需要的檔案 / `<Compile Include>`,再走 (1) 或 (2)。不要用 `Build-TcProject` 解:Build 也會存 editor buffer,可能蓋掉磁碟上的 .TcPOU 改動。

### PROJECT_OPEN_FAILED

- **為什麼**:`Open-TcProject` / `Connect-TcIde -SolutionPath` 開 .sln 失敗。路徑錯、檔案損壞、或連到的 IDE 沒有 TwinCAT 整合(例如抓到沒裝 TwinCAT 的 VS)。
- **下一步**:確認路徑;指定 `-ProgId` 對應正確的 IDE(見環境矩陣)。開著這個 .sln 的 IDE 被 modal 擋住時現在回 `IDE_MODAL_DIALOG` / `IDE_BUSY`,不再是這個碼(#29,見「IDE_MODAL_DIALOG」)。

### POU_NOT_FOUND

- **現象**:`Get-TcPouCode` / `Write-TcPouCode` 回 `POU_NOT_FOUND`。(`PLC_PROJECT_NOT_FOUND` 是 TIPC 下找不到 `<Plc> Project` 節點,處理方式相同。)
- **為什麼**:4024 與 4026 的 PLC 樹格式相同:`TIPC^<Plc>^<Plc> Project^POUs^<name>`(DUT 在 `^DUTs^`、GVL 在 `^GVLs^`)。不給 `-PouPath` 時依序試 `<Plc> Project^POUs^<name>`、`<Plc> Project^<name>`,最後遞迴走 project 子樹(深度 4)比對名稱;給了 `-PouPath` 但找不到也會改用名稱自動找。都沒命中才回此碼。
- **下一步**:`error.message` 列出試過的路徑(`data.tried[]`),`error.hint` 說明格式並列出 `<Plc> Project` 第一層子節點(例如 `POUs, DUTs, GVLs, VISUs`,另見 `data.projectChildren[]`)。用 `Get-TcProjectTree -PlcOnly` 查節點 `path` 後給 `-PouPath`。與 `POU_READ_FAILED` / `POU_WRITE_FAILED` 不同:後兩者只在 COM 例外(例如讀 DeclarationText 失敗)時回,代表 POU 找到了但存取失敗。
- **DUT / GVL 的讀寫語意**(#22):`Get-TcPouCode` 回 `data.objectKind`(POU / DUT / GVL / ITF / METHOD / ACTION / PROPERTY …,由樹節點的 `ItemType` 判斷,數值見 [InfoSys「ITcSmTreeItem Item Types」](https://infosys.beckhoff.com/content/1033/tcautomationinterface/12425810699.html);PLC 物件的 `ItemSubType` 一律是 0,`ItemSubTypeName` 是 `TREEITEMTYPE_*` 名稱,實測 2026-10-25 4024 / 4026)、`data.language`(`ITcSmTreeItem.Language`:ST 1 / FBD 4 / LD 6 …,DUT / GVL / ITF 為 null,實測同上)、`data.hasImplementation`、`data.implementationReadable`。`hasImplementation` 實測過的(2026-10-25,讀 `ImplementationText`):有實作段 = POU 602 / 603 / 604(4024、4026)、action 608(4024、4026)、method 609(4026,空的 ST 本體讀回 `''`);沒有 = DUT 605 / 606(4024、4026)、union 607 / alias 623(4026)、GVL 615、interface 618(4024、4026)、interface method 610(4026)、property 611(4024、4026,`CreateChild 611` 不會建 Get / Set 子項)。interface property 612、property get / set 613 / 614、transition 616 未實測:`hasImplementation` 先當未知,讀 `ImplementationText` 決定(和未知 ItemType 一樣)。沒有實作段時 `implementation=null`、`implementationReadable=null`,整份原始碼在 `declaration`。有實作段卻讀回 null 時 `implementationReadable=false`,沒有實作段時 `implementationReadable=null`。屬性讀取失敗會以 null / `implementationReadable=false` 呈現:Windows PowerShell 對丟例外的 getter 回 `$null`(實測 2026-10-25,PS 5.1.26100,.NET property;COM adapter 未驗)。declaration 讀回 null 回 `POU_READ_FAILED`(action 608 例外,它本來就沒有 declaration,實測 2026-10-25 4024 / 4026;未實測的 transition 616 也放行);LD / FBD 的 `implementation` 是 XAE 的 XML(`<NWL><XmlArchive>…`),不是 ST 文字(實測 2026-10-25 4024 / 4026)。COM 呼叫本身丟例外回 `POU_READ_FAILED`。`Write-TcPouCode` 對沒有實作段的物件給 `-Implementation` 回 `INVALID_PARAMS`、什麼都不寫(ItemType 未知時先讀 `ImplementationText`,null 就同樣擋下),只給 `-Declaration`(完整的 `TYPE ... END_TYPE` / `VAR_GLOBAL ... END_VAR`);property 的 hint 指向 `<path>^Get` / `^Set`。

### POU_READ_FAILED

- **現象**:`Get-TcPouCode` 找到了物件,但讀不出內容:COM 呼叫丟例外,或 `DeclarationText` 讀回 null。實測過的類型(POU、DUT、GVL、ITF、method、ITF method、property)都有 declaration;action 608 沒有(實測 2026-10-25),612-616 未實測,其中 transition 616 比照 action 放行,不回此碼。和 `POU_NOT_FOUND` 不同,物件存在。
- **下一步**:`Get-TcIdeModalDialog` 看 XAE 有沒有 dialog;沒有就重試 `Get-TcPouCode -PouPath <path>`,仍失敗就 `Reset-TcSolution` 後再讀。

### POU_CREATE_FAILED / DUT_CREATE_FAILED / GVL_CREATE_FAILED

- **現象**:`Add-TcPou` / `Add-TcDut` / `Add-TcGvl` 回失敗。`error.message` 在 `Failed to add ...:` 後標出失敗步驟:`exists:`(目標 PLC project 裡已有同名的頂層物件,訊息帶它的 path;什麼都沒建)、`lookup:`(`CreateChild` 回來了但目標路徑讀不到)、`kind:`(新物件的 ItemType 不對)、`language:`(POU 讀回的語言不是 ST)、`declare:`(寫入 / 讀回 declaration 失敗或內容不同;Function 讀回的 header 沒有 `: <ReturnType>`)。從 `lookup` 起物件已經建立、留在樹上,訊息會說明;沒標步驟就是 `CreateChild` 本身的 XAE 訊息。IDE 有 modal dialog 時不呼叫 `CreateChild`,直接回 `IDE_MODAL_DIALOG`(同 `Build-TcProject`)。
- **怎麼建**:`ITcSmTreeItem::CreateChild(name, subType, '', vInfo)`,父節點是 PLC folder(`TIPC^<Plc>^<Plc> Project^POUs` / `^DUTs` / `^GVLs`,4024 與 4026 相同)。subType 用 [InfoSys「ITcSmTreeItem Item Types」](https://infosys.beckhoff.com/content/1033/tcautomationinterface/12425810699.html) 頁的 ItemType 值:Program 602、Function 603、Function block 604、DUT enum 605 / struct 606 / union 607 / alias 623、GVL 615;[InfoSys `ITcSmTreeItem::CreateChild`](https://infosys.beckhoff.com/content/1033/tcautomationinterface/12425844363.html) 頁確認 603 / 604 也是 CreateChild 的 sub type,其餘實測(2026-10-25,4024 / 4026)。vInfo 依 CreateChild 頁:FB = IEC 語言整數,Function = string[2] {語言, 回傳型別};Program 也吃同一個整數(實測 2026-10-25,4024 / 4026)。`IECLANGUAGE_ST` = 1(TCatSysManagerLib 3.4.0.0 interop 的 `IECLANGUAGETYPES`,reflection 讀出,2026-10-25;6 是 LD)。DUT / GVL 不帶 vInfo 建立,再寫 `DeclarationText` 並讀回比對;alias 例外,vInfo 要給基底型別。成功只在讀回新物件(ItemType 相符、POU 語言是 ST、Function header 含回傳型別、DUT / GVL declaration 相符)之後才回。
- **同名檢查(`exists`)**:目標路徑本身,加上目標所在的 `<Plc> Project`(父路徑中第一個「等於前一段 + ` Project`」的段,所以 PLC 名稱本身以 ` Project` 結尾也對;多 PLC 的 solution 只查自己那個 PLC)裡所有 PLC folder(ItemType 601,含巢狀)的直接子項。父路徑不在 `<Plc> Project` 底下時只查目標路徑,`data.duplicateCheckScope = folder`,`data.duplicateCheckNote` 說明原因。只有頂層物件算衝突:POU 602 / 603 / 604、DUT 605 / 606 / 607 / 623、GVL 615、ITF 618;method、action、property、accessor 與資料夾同名不算,也不往 POU 底下走。名稱比對不分大小寫,所有命中都列在訊息裡。讀不到的節點計入 `data.duplicateCheckSkippedNodes`(對它不擋,fail-open);RPC busy(0x80010001 / 0x8001010A)與 IDE_* 不算讀不到,會整段重試(`Invoke-TcComRetry`),仍失敗回 `IDE_BUSY` 等。節點超過 3000 個就停止走樹:已找到的同名仍會擋下(`exists`),其餘部分沒查,`data.duplicateCheckScope = folder`(正常是 `project`)、`data.duplicateCheckNote` 說明,另有 PowerShell warning。耗時(實測 2026-10-25,target 127.0.0.1.1.1):TwinCAT_Festo 4024 複本 47 個節點,第一次 587 ms、之後 84 / 150 ms;RobustDemo 4026 複本 63 個節點,446 / 68 / 61 ms(第一次含 COM 暖機)。約 1-1.5 ms 一個節點,3000 個約 3-5 s。
- **#17 之前為什麼失敗**(實測 2026-10-25,4024 TcXaeShell.DTE.15.0;修正後的呼叫在 4026 VisualStudio.DTE.17.0 也驗過):HRESULT 都是 `0x80004005`(E_FAIL),原因在訊息裡。POU:vInfo 傳了 `<Declaration><![CDATA[...]]>` 字串,XAE 把它當語言名稱解析,回「Requested value '<Declaration>...' was not found.」;而且 Program / FB 的 subType 對調(604 = FB,602 = Program)。DUT:用了 610-613,那是 interface method / property,回「Creating the child type 'TREEITEMTYPE_PLCITFMETH' is not possible on parent node type 'TREEITEMTYPE_PLCFOLDER' (SubType mismatch)」。GVL:615 正確所以「成功」,但字串 vInfo 被原樣當成 declaration,`<Declaration><![CDATA[` 外殼留在 GVL 原始碼裡,Build 才會壞。alias 不給 vInfo 回「Base class not specified! Parameter name: baseClass」。
- **下一步**:`exists` → 換 `-Name`,或用 `Write-TcPouCode -PouPath <訊息裡的 path>` 改既有的。「not possible on parent node type」→ 父節點不是 PLC folder,`Get-TcProjectTree -PlcOnly` 查 `<Plc> Project^POUs` 的 path 後給 `Add-TcPou -PlcProjectPath`。`0x98510001` → .plcproj 的 `<Compile Include>` 列了磁碟上沒有的檔案,從 .plcproj 移除或補回檔案,`Reset-TcSolution` 後再試。`lookup` → 物件可能建在別的路徑,`Get-TcProjectTree -PlcOnly` 找到後用 `Write-TcPouCode` 修正或在 XAE 刪掉。`kind` / `language` / `declare` → 物件已建立、留在樹上:用 `Get-TcPouCode -PouPath <path>` 看內容,以 `Write-TcPouCode -PouPath <path>` 修正,或在 XAE 刪掉後再 Add(同名會被 `exists` 擋下)。`IDE_MODAL_DIALOG` → 先處理 dialog(`Get-TcIdeModalDialog`),什麼都沒建。
- **驗證**:`mcp-server/scripts/pou-client.mjs` 經 MCP server 跑 Add* / GetPouCode / WritePouCode / BuildProject(含一次注入未宣告識別字、預期 `BUILD_FAILED` 的對照)。2026-10-25 在全新 4024 專案(Standard PLC Template,TcVersion 3.1.4024.71)與 4026 RobustDemo 複本都全數通過(最後一輪 26/26,含同名跨資料夾的 `exists` 檢查;target 設為 127.0.0.1.1.1,沒有 Activate)。TwinCAT_Festo(4024)複本缺 library 時 PLC 程式碼不會被編譯,Build 仍回 success,不能拿來驗證(#45)。

### PLC_LOGGED_IN

- **現象**:`Add-TcPou` / `Add-TcDut` / `Add-TcGvl` 時 PLC 還在 login(online)中,XAE 的 `CreateChild` 回「Cannot add an object because it affects a device you are currently logged into」,什麼都沒建立(實測 2026-10-29,4026 XAE in VS2022,`Add-TcGvl` 接在 `Enable-TcConfig -Force` 之後;`tests/Integration/logs/phase0-1.7-results.md` 發現 4。`Add-TcPou` / `Add-TcDut` 走同一個 `CreateChild`,同樣處理，未在真機測)。以前回 `GVL_CREATE_FAILED`,hint 沒提 login,還記了 `BUILD_REQUIRED`。`Enable-TcConfig -Force` 與 `Invoke-TcTestCycle` 結束時都保持 login,所以 lifecycle 之後直接 Add 很常遇到。`Add-TcLibrary` 在 login 中可以成功。
- **判斷**:`New-TcPlcObject` 以英文關鍵字比對 `CreateChild` 的錯誤訊息(`affects a device you are currently logged in`,或 `cannot add an object ... logged in`);在地化的 XAE 若用別的字句，仍回 `*_CREATE_FAILED`。`CreateChild` 本身回錯誤(不是 IDE_BUSY / IDE_CRASHED / IDE_MODAL_DIALOG / IDE_TIMEOUT)時 XAE 已拒絕、沒有建立物件，所以不記 `BUILD_REQUIRED`(沒有 `data.buildRequired`)。
- **下一步**:先 `Exit-TcPlcOnline`(MCP `PlcLogout`)再重跑同一個 `Add-*`;加完 `Build-TcProject`,再 `Enable-TcConfig -Force` 或 `Enter-TcPlcOnline` 下載。

### MEMBER_ORDER_MISMATCH

- **現象**(#47):`Add-TcDut`(Struct / Union / Enum)或 `Add-TcGvl` 建立物件並存檔後,讀回 XAE 的 declaration、解析出的成員順序(`data.actualOrder`)與輸入順序(`data.expectedOrder`)不同。物件已經在樹上、也存進 .plcproj,並記成 `code-changed`(`BUILD_REQUIRED`)。成功時 `data.memberOrder` 是讀回的順序。
- **為什麼要檢查**:#47 之前成員參數是 `[hashtable]`,PowerShell hashtable 的列舉順序是雜湊順序,STRUCT / GVL / ENUM 成員順序與輸入不同卻回 success(實測 2026-10-28,4026 VS2022 + 本機 UmRT,registered tcauto)。STRUCT 成員順序決定記憶體配置。
- **輸入格式**:成員一律有序:MCP 用陣列 `Fields` / `Variables` = `[{"name":"bStart","type":"BOOL","init":"TRUE","comment":"..."}, ...]`,Enum 為 `[{"name":"eIdle","value":0}, ...]`;PowerShell 另可用 `[ordered]@{ bStart = 'BOOL' }`。一般 `[hashtable]` 超過一個成員 → `INVALID_PARAMS`(不猜順序,什麼都沒建);只有一個成員的 hashtable 可接受。舊的 MCP object 格式(`{"bStart":"BOOL",...}`)已移除,JSON schema 驗證直接回 `INVALID_PARAMS`(JS 的 object key 順序對整數型 key 也不保證)。
- **下一步**:`Write-TcPouCode -PouPath <data.path> -Declaration <正確順序>` 改寫,`Get-TcPouCode` 確認,再 `Build-TcProject`。

### SOLUTION_ALREADY_OPEN

- **現象**(#70):`New-TcProject` 發現 IDE 已開著 solution(`DTE.Solution.IsOpen` 或 `FullName` 非空;讀不到也當成開著,fail-closed;IDE 回 RPC busy 時改回 `IDE_BUSY`),直接拒絕,沒有呼叫 `Solution.Create`。`data.openSolution` 是目前的 solution(讀不到時為 null)。
- **為什麼**:`Solution.Create` 會不經提示關掉目前的 solution,未存的改動會丟掉(實測 2026-10-28,見 #70:TwinCAT 3.1.4026.22 XAE in VS2022 與 4024 32-bit XAE Shell,registered tcauto,兩者呼叫後 `GetIdeInfo` 的 solution 都變成空字串);`New-TcProject` 的 template 路徑本身也還沒修(#70),所以 MCP 暫時不提供 `NewProject` tool,只保留 cmdlet。
- **下一步**:在 #70 修好之前,建議在 XAE 手動建立新專案,再 `Connect-TcIde -SolutionPath <新 .sln>` 接上。一定要用 `New-TcProject` 時,先在 XAE 存好並關掉目前的 solution(IDE 不開任何 solution)再呼叫。

### IO_SCAN_REQUIRES_CONFIG / IO_SCAN_FAILED / IO_SCAN_VERIFY_FAILED

- **現象**:`Invoke-TcIoScan` 先讀 system state(ADS port 10000),不是 Config 就回 `IO_SCAN_REQUIRES_CONFIG`(`data.state`),沒有掃描。`IO_SCAN_FAILED` = `ProduceXml(false)` / `CreateChild` / `ConsumeXml` 丟例外;`IO_SCAN_VERIFY_FAILED` = `-Apply` 建立的 device 讀回 I/O tree 時找不到。
- **為什麼**:TE1000 v1.7.0 §6.6.2「Performing a device scan」(p.247)的 Requirements 寫 TwinCAT 要在 Config mode;scan 是在 `TIID` 呼叫 `ProduceXml(false)`,找到的裝置在 `TreeItem/DeviceGrpDef/FoundDevices/Device`。手冊沒寫 Run mode 的行為:實測 2026-10-28(4026 XAE in VS2022,本機 UmRT,自建 client)Run mode 下 `ProduceXml(false)` 不丟錯、立即回空的 `FoundDevices`,看起來像「沒有裝置」,所以模組先檢查狀態。舊版呼叫的 `ProduceScan()` 在手冊裡不存在(`IO_SCAN_FAILED`「未包含名為 'ProduceScan' 的方法」)。
- **下一步**:`Set-TcSystemState -State Config` 後重跑;預設只回 `data.devices`,不改 tree,要加進 tree 用 `-Apply`(CreateChild + AddressInfo + ScanBoxes,依 §6.6.2)。沒有裝置時回 success、`devices = @()` 加 `data.warning`。本機 UmRT 切 Config 可能觸發 #21 crash(見「已知限制」)。

### TREEITEM_NOT_FOUND

- **現象**:`Set-TcVariableLink` / `Remove-TcVariableLink` 呼叫前用 `LookupTreeItem` 檢查兩端;找不到就回這個碼,`data.missingEnd` 與 hint 指出是 `PlcVariable` 還是 `IoChannel`。
- **為什麼**:`LinkVariables` 要完整 tree path(TE1000 v1.7.0 §5.1.1.2,p.38:"The full path name is required")。`MAIN.bIn` 這種 PLC symbol 名稱不是 tree path。`TSM_E_ITEMNOTFOUND` 的數值手冊沒寫,實測 2026-10-28 是 `0x98510001`(4026 XAE in VS2022,訊息 `Item '...' not found`)。
- **下一步**:PLC 端 `TIPC^<Plc>^<Plc> Instance^PlcTask Inputs^MAIN.bIn`(`AT %I*` / `%Q*` 變數,要先 Build 才出現);I/O 端到 variable 那層,例如 `TIID^<Device>^<Box>^<Term>^Channel 1^Input`。用 `Get-TcIoTree` 查 I/O 路徑。
- **通用 tree tool**(`LookupTreeItem` / `ProduceXml` / `CreateChild` / `ConsumeXml` / `DeleteChild` / `ExportChild` / `ImportChild`,cmdlet `Get-TcTreeItem` 等):找不到時往上找最接近的上層路徑,`error.hint` 和 `data.nearestPath` / `data.nearestChildren` 列出它和它的子節點名稱;連第一段都不存在時列出解析得到的頂層節點(TIPC、TIID、TIRC、TIRS、TIRT、TINC 中存在的)。照 hint 改路徑,或對 `nearestPath` 呼叫 `LookupTreeItem` 往下查。

### 通用 tree tool 的防護與備份(第 1 期,未實測)

`LookupTreeItem`(`Get-TcTreeItem`)、`ProduceXml`(`Get-TcTreeItemXml`)、`CreateChild`(`New-TcTreeItem`)、`ConsumeXml`(`Set-TcTreeItemXml`)、`DeleteChild`(`Remove-TcTreeItem`)、`ExportChild`(`Export-TcTreeItem`)、`ImportChild`(`Import-TcTreeItem`)直接對應 `ITcSysManager::LookupTreeItem`(TE1000 v1.7.0 §5.1.1.3,p.38)與 `ITcSmTreeItem` 的方法(§5.2.1.1~5.2.1.8,p.57~61;[TE1000 PDF](https://download.beckhoff.com/download/document/automation/twincat3/TC3_Automation_Interface_EN.pdf))。共用函式在 `src/TwinCATAutomation/Private/TreeItem/`。

- **防護**(design D2):修改類(`CreateChild`、`ConsumeXml`、`DeleteChild`、`ImportChild`)預設 `DryRun=true`,dry-run 不呼叫任何修改 API;`DryRun=false` 先把 `ProduceXml` 備份到 `<solution 目錄>\.tcauto-backup\<yyyyMMdd-HHmmss>\<路徑安全化>.xml`(`data.backupPath`),再修改,再讀回驗證(`data.verified`)。`Path` 必須是完整路徑,不接受 `*` `?`。`DeleteChild` 要帶 `ConfirmName`。MCP 端修改類標 `destructiveHint: true`。
- **磁碟檔備份**:XAE 改 Task 時會立刻改寫 PLC 專案資料夾裡的 `<task>.TcTTO`(實測 2026-10-30,4026 VS2022,task 2.1,沒有存 solution 也會寫),所以節點對應磁碟檔時一併複製到備份資料夾(`data.backupFiles`)。規則表 `$script:TcTreeItemDiskFileRules`:`TIRT^<task>` → `<task>.TcTTO`;TIPC 底下 ItemType 602/603/604 → `.TcPOU`、606 → `.TcDUT`、615 → `.TcGVL`(檔名慣例,PLC 物件會不會被這些操作改寫未實測)。在 solution 目錄下剛好找到一個同名檔才複製;找不到或有多個就不複製,`data.warnings` 說明。
- **`.tcauto-backup` 資料夾**會留在 solution 目錄裡,模組不會自動清;不要把它加進版本控制。
- **ConsumeXml 只送片段**(design D3,實測 2026-10-30):XAE 本身就是合併語意,沒列到的欄位保留原值,所以模組直接傳片段,不做整份合併。片段的每個最底層元素路徑都要在目前的 `ProduceXml` 裡找得到(重複的同名元素依位置比對,`CPU[2]`)。讀回比對排除 `TcModuleInstance` 底下的 `Context`、`ParameterValues`(XAE 自己跟著改的衍生欄位,`data.skippedDerived`)。
- **XAE 行為未實測的片段一律在送出前擋掉**(`XML_MERGE_FAILED`,見該節的 `data.reason`):有 attribute、值放在有子元素的節點上、重複元素數量和目前不同、有變動的欄位全是衍生欄位。不猜 XAE 會怎麼合併。
- **寫入後全量比對**:`ConsumeXml` 之後把寫入前、寫入後兩份 `ProduceXml` 全部攤平(element 值和 attribute)比對,片段以外、非衍生的欄位有任何差異就回 `TREEITEM_VERIFY_FAILED`(`data.unexpectedChanges`)。`CreateChild` / `ImportChild` 對父節點做同樣的比對,但只允許「多出來」(新子節點可能出現在父節點 XML 裡,`-Before` 插入會讓 `[n]` 位移),原有的值少了或變了就回 `TREEITEM_VERIFY_FAILED`(`data.parentUnchanged=false`)。父節點 `ProduceXml` 會不會因為新增子節點而改別的欄位(例如計數)未實測。
- **同步 COM 修改呼叫沒有 deadline**(`ConsumeXml`、`CreateChild`、`DeleteChild`、`ExportChild`、`ImportChild`):照 `New-TcPlcObject` 的 `CreateChild` 做法(CODING_STANDARDS §1 的「註解寫明為何不需要」),每次呼叫前先 `Get-TcIdeModalDialog`,有 dialog 就回 `IDE_MODAL_DIALOG`、不呼叫;`Connect-TcIde` 開的 `SilentMode` 讓 XAE 自己用預設值回答提示。這些呼叫的耗時還沒量(task 2.8)。
- **PLC login 中**:XAE 拒絕時回 `PLC_LOGGED_IN`,`error.hint` 是「先 PlcLogout,再重跑同一個 tool」並帶出失敗的操作。`IDE_MODAL_DIALOG`、`IDE_CRASHED`、`IDE_TIMEOUT`、`IDE_BUSY`、`PLC_LOGGED_IN` 這份清單(`$script:TcTreeItemPassThroughCodes`)在錯誤結果和備份步驟共用,一律保留原碼。

### TREEITEM_PATH_INVALID

- **現象**:通用 tree tool 的 `Path` 是空的、有 `*` / `?`、有空段(開頭 / 結尾的 `^` 或 `^^`),或 `DeleteChild` 指到頂層節點。什麼都沒呼叫。
- **為什麼**:修改類 tool 只接受單一、明確的節點(design D2),不做 pattern 比對;`DeleteChild` 是父節點的方法(TE1000 §5.2.1.3),頂層節點沒有父節點。
- **下一步**:用 `LookupTreeItem` 或 `GetProjectTree` 查到完整路徑再重試。

### TREEITEM_READ_FAILED

- **現象**:`LookupTreeItem` 找得到節點,但讀它的屬性、子節點或 `ProduceXml` 時 COM 丟例外(不是 IDE_BUSY / IDE_CRASHED / IDE_MODAL_DIALOG,那些會回各自的碼)。什麼都沒改。
- **下一步**:`Get-TcIdeModalDialog` 檢查 dialog,重跑一次;一直失敗就用 `GetProjectTree` 確認節點還在。

### TREEITEM_ALREADY_EXISTS

- **現象**:`CreateChild` 的 `Path^Name`,或 `ImportChild` 帶的 `Name`,已經存在。什麼都沒建立。
- **為什麼**:手冊沒寫同名時 XAE 會怎麼做(TE1000 §5.2.1.2 / §5.2.1.6 只列 E_NOTIMPL、E_ACCESSDENIED 等),所以模組先擋,不讓 XAE 自己改名或覆蓋。
- **下一步**:換名稱;真的要取代就先 `DeleteChild`(先 dry-run)再建。

### TREEITEM_CREATE_FAILED

- **現象**:`CreateChild` 被 XAE 拒絕。`data.backupPath` 是呼叫前父節點的備份。
- **為什麼**:TE1000 §5.2.1.2(p.57):`E_NOTIMPL` = 這個節點不支援新增子節點;`E_ACCESSDENIED` = 對應的檔案不能編輯。`SubType` / `VInfo` 的意義依父節點而定,沒有完整的公開清單;手冊有寫的例子:`TIRT` 下 Task `SubType` 0 = 有 process image、1 = 沒有(§6.3.1,p.196);`TIID` 下 EtherCAT master 111、box 9099 + `VInfo` 產品型號(§6.6.1,p.244)。
- **下一步**:確認 `Path` 是父節點、`SubType` / `VInfo` 是手冊或 InfoSys 寫的值;有專用 tool(`AddPou`、`AddDut`、`AddGvl`、`IoScan`)就改用它。PLC 在 login 中時會回 `PLC_LOGGED_IN`。

### TREEITEM_VERIFY_FAILED

- **現象**:修改呼叫有返回,但讀回不符:`ConsumeXml` 讀回的值和片段不同(`data.mismatches` 的 `expected` / `actual`),或片段以外的非衍生欄位變了(`data.unexpectedChanges`:`path`、`kind` = `changed` / `removed` / `added`、`before`、`after`;重複元素數量變了會顯示成 removed / added);`CreateChild` / `ImportChild` 之後找不到新節點,或父節點原有的值少了 / 變了(`data.parentUnchanged=false`、`data.unexpectedChanges`,這時新節點已經建立);`DeleteChild` 之後節點還在。`success` 一定是 false。
- **為什麼**:XAE 對未知元素、錯的路徑會回 S_OK 但什麼都不改(實測 2026-10-30,task 2.1);不讀回就會誤報成功(#28 / #32)。
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

- **現象**:修改前的備份沒寫成:模組不知道 solution 路徑,或 `<solution 目錄>\.tcauto-backup` 無法寫入,或備份前的 `ProduceXml` 失敗。什麼都沒改。`DeleteChild`(`Remove-TcTreeItem`)還要求 `ExportChild` 的 `.xti` 備份:`ExportChild` 丟例外(`data.reason` = `export-failed`)或返回了但檔案不存在(`export-missing`)也回這個碼,不刪。備份步驟遇到 `IDE_*` / `PLC_LOGGED_IN` 時回那個碼,不是這個。
- **為什麼**:`DeleteChild` 刪掉的是整個子樹;`ProduceXml` 備份(`DeleteChild` 前用 recursive,含子樹)只能看,不能用 `ImportChild` 還原,只有 `.xti` 能。
- **下一步**:`Connect-TcIde -SolutionPath <sln>`(或 `Open-TcProject`)讓模組記住 solution 路徑,確認目錄可寫,再重試。`export-failed` / `export-missing`:先用 `ExportChild`(`Export-TcTreeItem`)匯出同一個節點找原因;確定只要 `ProduceXml` 備份就夠時,才加 `AllowNoExport=true`(cmdlet:`-AllowNoExport`)重跑,結果的 `data.warnings` 會註明刪除時沒有 `.xti`。

### TREEITEM_EXPORT_FAILED

- **現象**:`ExportChild` 沒產生檔案。`data.reason`:`not-absolute`、`invalid-path`(路徑有 `< > | " * ?` 等非法字元、`GetFullPath` 不接受,或沒有檔名,例如 `C:\`)、`file-exists`、`folder-missing`(這四個在呼叫 XAE 前就擋,路徑檢查不會變成 `EXECUTION_ERROR`)、`file-not-written`(XAE 返回了但檔案不存在或是空的),或 XAE 丟例外。
- **為什麼**:TE1000 §5.2.1.4(p.58):目標資料夾必須存在、檔案不能已存在,否則 `E_INVALIDARG`;空路徑的行為手冊只寫「default behavior」,所以模組要求絕對路徑。
- **下一步**:換一個新的檔名(建議 `.xti`)重試。

### TREEITEM_IMPORT_FAILED

- **現象**:`ImportChild` 沒有匯入:`data.reason` 是 `not-absolute` / `invalid-path`(非法字元、沒有檔名,例如 `C:\`)/ `file-missing`,或 XAE 拒絕。
- **為什麼**:TE1000 §5.2.1.6(p.59):`NTE_NOT_FOUND` = 沒有可匯入的項目,`TSM_E_ITEMNOTFOUND` = `Before` 找不到,`E_FAIL` = XML 載入、類別檢查或插入失敗(細節在 COM 錯誤訊息)。
- **下一步**:確認檔案是 `ExportChild` 匯出的,`Path` 是能放這種節點的父節點(例如 Task 匯入到 `TIRT`,I/O device 到 `TIID`,§6.3.2)。

### XML_MERGE_FAILED

- **現象**:`ConsumeXml` 的片段沒有送出,或送出後 XAE 拒絕。`data.reason`:`syntax`(XML 語法錯)、`root`(根元素不是 `<TreeItem>`)、`empty`(沒有任何元素)、`paths-not-in-current-xml`(`data.missingPaths` 裡的元素路徑在目前的 `ProduceXml` 不存在);XAE 拒絕時沒有 `reason`,`data.written=false`,`data.backupPath` 有備份。以下四種 XAE 怎麼合併未實測,模組在送出前就擋(dry-run 也擋),不猜:
  - `attributes-not-supported`:片段有 XML attribute(含 `xmlns`,`data.attributePaths`)。目前只支援 element 值。
  - `structure-mismatch`:片段的最底層元素在目前的 XML 是有子元素的節點,例如 `<TreeItem><TaskDef/></TreeItem>`、`<TaskDef>123</TaskDef>`;或片段在有子元素的元素裡放了文字(`data.structurePaths`)。
  - `repeated-count-mismatch`:同名重複元素的數量和目前的 XML 不同,例如目前有兩個 `CPU`,片段只放一個(`data.repeatedCountMismatches`:`path`、`fragmentCount`、`currentCount`)。
  - `derived-only`:片段有變動的欄位全是 `TcModuleInstance` 底下的 `Context` / `ParameterValues`(`data.derivedPaths`);XAE 會依來源欄位重算,讀回也不比對,所以等於沒驗證。片段裡同時有來源欄位和衍生欄位時照送,`data.warnings` 註明衍生欄位不驗證。
- **值的比對**(讀回、全量比對):先去頭尾空白做 Ordinal(區分大小寫)比對;不同時,兩邊都能解析成數字才比數值(十進位,或 `#x` 十六進位,前綴不分大小寫,例如 `#x1E` = `#x1e` = `30`);其他文字一律區分大小寫。
- **為什麼**:實測 2026-10-30(4026 VS2022,task 2.1):根元素錯回 `E_FAIL`「No TreeItem found.」,語法錯回 `E_FAIL`,都不會部分寫入;**未知元素或錯的路徑回 S_OK 但什麼都不改**,呼叫端看不出來,所以模組在送出前先比對路徑。
- **下一步**:先 `ProduceXml`,路徑照抄,只放要改的欄位,例如 `<TreeItem><TaskDef><CycleTime>40000</CycleTime></TaskDef></TreeItem>`。`repeated-count-mismatch` 時把那一組重複元素照目前的數量和順序全部抄進片段;`attributes-not-supported` 時拿掉 attribute;`derived-only` 時改送來源欄位(例如 `TaskDef/CycleTime`)。

### LINK_INVALID_ITEM_TYPE / LINK_TYPE_MISMATCH / LINK_FAILED / UNLINK_FAILED

- **為什麼**:TE1000 §5.1.1.2(p.38)列出 `LinkVariables` 的錯誤:`TSM_E_INVALIDITEMTYPE`(有一端不是 variable)→ `LINK_INVALID_ITEM_TYPE`;`TSM_E_MISMATCHINGITEMS`(型別 / 大小不相容)→ `LINK_TYPE_MISMATCH`。這兩個的數值手冊沒寫,模組用 HRESULT 名稱或訊息文字判斷;都不符時回 `LINK_FAILED`(Unlink 是 `UNLINK_FAILED`)。
- **下一步**:I/O 端給 `^Channel 1^Input` 而不是 `^Channel 1`;兩端型別大小要相同。

### LINK_VERIFY_FAILED

- **現象**:`LinkVariables` / `UnlinkVariables` 有返回,但 `ProduceMappingInfo()` 讀回的 mapping 沒有這條 link(或刪除後還在,`data.remainingLinks`),或 mapping 讀不到。
- **為什麼**:不讀回就回 `linked = true` 是假成功(#28 / #32)。`ProduceMappingInfo` 出處:TE1000 §5.1.3.4(p.45);XML 是 `<VarLinks><OwnerA Name><OwnerB Name><Link VarA VarB/>`,VarA / VarB 是相對 Owner 的路徑(§6.3.14,p.218)。
- **下一步**:在 XAE 看該變數的 link,或重跑一次;不要當成功。

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

`Set-TcTarget -AmsNetId <id> [-Platform <name>] [-Configuration Release] [-NoPlatformSwitch]` 的 data:`amsNetId`、`targetSet`、`platformCheck`、`targetPlatform`、`targetPlatformSource`、`adsError`、`platform`(solution platform)、`projectPlatform`(操作後 active 的 .tsproj project platform,沒有 .tsproj 為 null)、`platformChanged`(bool);有切換時另有 `requestedProjectPlatform`、 `configuration`、`previousPlatform`、`availablePlatforms`、`projectCheck`(`ok` / `mismatch` / `no-tsproj`)、`platformMatchedBy`、`platformMap`。`Enable-TcConfig` 的 data 一律有 `targetPlatform`、`targetPlatformSource`、`solutionPlatform`、`projectPlatform`、`platformFixed`、`platformCheck`(skipped 時加 `warning`;自動切換失敗時加 `platformMap`、`requestedProjectPlatform`)。`Connect-TcIde` / `Get-TcIdeInfo` 的 data 多 `solutionPlatform`、`solutionConfiguration`、`projectPlatform`。MCP `SetTarget` 有 `Platform` / `Configuration` / `NoPlatformSwitch` 參數,`EnableConfig` 有 `Platform` / `NoPlatformFix`;`RunLifecycle` 的 `Platform` 給 SetTarget 步驟(在 Build 之前切換,沒給 `TargetAmsNetId` 用 `ConnectIde` 回的 AmsNetId),也原值傳給 EnableConfig(比對結果相同,不再出現「-Platform was not given」的 `data.warning`;target 有回報 TARGETINFO 時仍以 target 為準),沒給 `Platform` 時 SetTarget 帶 `NoPlatformSwitch=true`,platform 交給 EnableConfig 檢查。MCP 的 hint 改寫保留引號內的值:`Set-TcTarget -Platform 'TwinCAT OS (x64)'` → `SetTarget Platform='TwinCAT OS (x64)'`。

## 已知限制

使用者向的已知限制清單(現象、影響、繞過方式、issue)與真機驗證範圍:[known-limitations.md](known-limitations.md)。

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
| `New-TcTestCase` / `Invoke-TcTest` 的 `-WaitMs` 是固定盲等 | 不建議使用(deprecated):不管 PLC 多快都等滿,太短又會誤判 | 改用 `-WaitUntil @{Path;Operator;Expected}` + `-WaitTimeoutMs`(預設 5000):條件成立立刻跑 assertions;逾時該 case 判 Fail,結果 `waitTimedOut=true`、`lastValues`(最後讀到的值)、`waitMs`(實際等待)。`WaitUntil` 格式錯(未知 key / Operator、缺 Path 或 Expected、`WaitTimeoutMs` 不在 1..600000)回 `INVALID_PARAMS`,不寫任何 setup |
| MCP 同回合平行 tool call 順序 | client 平行送出的 call 到達 server 的順序不保證;bridge 嚴格 FIFO 一次執行一個,但 FIFO 的順序 = 到達順序 | 看每個結果的 `order.seq` / `order.startedAt` / `order.finishedAt` 判斷實際順序(data 是物件時 `data.seq` 等也有;data 是陣列時只在 `order`,#57);有因果的步驟(寫參數 → 下命令 → 觀察)分回合送 |

## 真機驗證腳本

`tests/Integration/` 的手動腳本需要真實環境:`bool-write.ps1`、`write-verify.ps1`、`list-symbols.ps1`、`full-cycle.ps1`、`lifecycle-smoke.ps1`、`login-logout.ps1`、`build-errors.ps1`(注入 C0046 錯誤驗證 `Build-TcProject` 的 `errorItems`,只對複本跑)、`reload-experiment.ps1`(磁碟改 .TcPOU 的 reload 行為,S0a/S0b/S2a/S2b/S3/S3b 六種情境,只對複本跑)。用法見 `tests/Integration/README.md`。`false-success.ps1`:#28 / #32 的真機情境(少 Build.0、多 PLC readback、nested 讀值、Run 退回 Config);`tests/Unit/activate-timeout.ps1`:Activate deadline 的 mock 測試,不需 IDE。`tests/Unit/blocked-solution-ide.ps1`:`Connect-TcIde -SolutionPath` 遇到被擋住的 IDE(#29:session record / dialog 路徑 / 視窗標題、attach 與否、證據矛盾、pid 重用、失敗不留舊連線、不另開 IDE)的 mock 測試,不需 IDE。`tests/Unit/clear-project.ps1`:`Clear-TcProject` 讀回(`cleanVerified`、`LIBRARY_UNRESOLVED` 與 `-AllowUnresolvedLibrary`、`CLEAN_UNVERIFIED`、`CLEAN_FAILED`、`CLEAN_TIMEOUT`、`nullReads` 逾時)的 mock 測試,不需 IDE。`tests/Unit/platform-project-mismatch.ps1`:solution platform / project platform 檢查(`PLATFORM_PROJECT_MISMATCH`、.sln index 對應、讀回失敗還原)的 mock 測試,不需 IDE。

- `lifecycle-smoke.ps1 -AllowUnresolvedLibrary`:`03a` 的 `Clear-TcProject` 帶 `-AllowUnresolvedLibrary`,給已知缺 library 的複本用(A 組 Festo NoVisu,見「CLEAN_LIBRARY_UNRESOLVED」)。
- `lifecycle-smoke.ps1 -StopAfterBuild`:只跑到 `03b`(Connect、target、`Clear-TcProject`、Build),不 Activate。runtime 不能 Activate 時用(例如 license 過期:Activate 失敗的「Target system reports a fatal error」會跳到**所有**連這個 target 的 XAE,別的 session 的也會,實測 2026-10-25,4024 32-bit XAE Shell 與 4026 VS2022 同時連本機 UmRT)。
- `lifecycle-smoke.ps1 -SolutionPlatform '<name>'`:在 Connect 與 Build 之間多一步 `02b-platform`(`Set-TcTarget -Platform`);`02-set-target` 改帶 `-NoPlatformSwitch`(只換 NetId,不會因 `PLATFORM_UNKNOWN` 失敗)。UmRT 必帶 `'TwinCAT OS (x64)'`(B 組 35/35;這台 UmRT 不支援 TARGETINFO)。smoke 與 `multi-ide.ps1` 的 Clean 都改成 `Clean($false)` + 輪詢(VS2022 的 wait 版不返回)。
- `mcp-server/scripts/lifecycle-client.mjs`(手動,需真 IDE + runtime):經 MCP server 跑 `RunLifecycle` → `GetSystemState` → 兩次 `ReadVariable`(task cycle counter 必須增加)→ `DisconnectIde Quit=true`。參數 `--sln`(必填)、`--progid`(預設 `VisualStudio.DTE.17.0`)、`--netid`、`--platform`、`--read <path>`;`--expect-fail <CODE> [--fail-platform <platform>]` 先跑一次帶 `Platform=<fail-platform>` 的 `RunLifecycle` 並要求該 error code(例 `--expect-fail ACTIVATE_FAILED --fail-platform "TwinCAT RT (x64)"`)。環境變數 `TWINCAT_MODULE_PATH`、`TWINCAT_MCP_POWERSHELL`;exit code = 失敗步驟數。
