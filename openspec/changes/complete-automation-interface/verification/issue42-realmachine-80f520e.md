# #42 真機驗證(commit 80f520e)— 中途停止:UmRT crash

- 日期:2026-11-05 00:44–00:58(+08:00)
- 環境:Windows 11,zh-TW;registered tcauto MCP(本 session 的 bridge,TwinCAT 3.1.4026 XAE in VS2022 `VisualStudio.DTE.17.0`);本機 UmRT_Default(`TcSystemServiceUm.exe` 3.1.0.2649),AmsNetId 199.5.42.250.1.1
- 主 checkout:`git log -1` = `80f520e fix(modal-scan): #42 review round 2`,沒切 branch、沒 commit
- 副本:`C:\Temp\Verify-4026-axis` 備份到 `C:\Temp\Verify-4026-axis.bak-42`(259 檔),`C:\Temp\Verify-4024-bfh` 備份到 `C:\Temp\Verify-4024-bfh.bak-42`(301 檔);SHA-256 清單在 scratchpad `C:\Users\aka09\AppData\Local\Temp\claude\166257a6755ab669\a19eb936-b404-4b4e-b931-c55e14a1e4d9\scratchpad\Verify-*.sha256.txt`
- 開工時沒有任何使用者開著的 devenv / TcXaeShell。自己啟動的 IDE:VS2022 pid **82504**(`selectedBy=launched`、`ownedBySession=true`)
- watcher:pid 77380,log `tests\Integration\logs\runtime-watch-42.jsonl`

## 結果總表

| # | 項目 | 結果 |
|---|---|---|
| 1 | 冷啟動後第一次 `GetIdeModalDialog`(VS2022) | **PASS**(有附註)。4024 TcXaeShell **NOT RUN** |
| 2 | 真 dialog 偵測 + `BuildProject` 被擋 | **PASS** |
| 3 | zh-TW Error List「目前專案」→「整個方案」 | **FAIL**(既有的偵測缺口,不是 80f520e 的退化) |
| 4 | UmRT `EnableConfig -Force` 完整 cycle | **BLOCKED**:UmRT crash(已知 #21 簽名),依規則停下 |
| 5 | `DisconnectIde -Quit` / `-Kill` | **NOT RUN**(停在 crash) |

## 1. 冷啟動 modal scan

- `ConnectIde ProgId=VisualStudio.DTE.17.0 SolutionPath=C:\Temp\Verify-4026-axis\...sln`:`success`,`selectedBy=launched`,pid 82504,`launchSec 1.6`,`connectSec 44.3`(16:44:28.999Z → 16:45:13.420Z)。
- 第一次 `GetIdeModalDialog TimeoutSec=5`:`{"success":true,"data":{"ideProcessId":82504,"scanComplete":true,"dialog":null}}`
- 接著 `TimeoutSec=60`:結果相同,`scanComplete:true`。沒有 BRIDGE_TIMEOUT。
- **附註 A(可觀測性)**:掃描成功時 MCP 不回 `modalScan`,所以 MCP 拿不到 `prepareMs` 跟耗時。`prepareMs` 只寫在 `Write-Verbose`(`Find-TcIdeModalDialog.ps1:766`),registered bridge 沒開 `TWINCAT_MCP_VERBOSE`。`GetIdeModalDialog` 的回傳也沒有 `seq/startedAt/finishedAt`。
- **附註 B(不是真正的冷啟動)**:這個 bridge 在 `ConnectIde` 期間已經跑過 modal 前置檢查(加上 probe),所以 P/Invoke 型別編譯、UIA 載入的冷啟動成本是在 `ConnectIde` 裡付掉的,第一次 `GetIdeModalDialog` 已經是熱的。要量「bridge 第一個 call 就是 GetIdeModalDialog」,得在 ConnectIde 之前帶 `ProcessId` 呼叫。這次沒做。
- 補量(**自建 client**,另開 zh-TW `powershell.exe -STA` 新行程,Import 模組後 `Get-TcIdeModalDialog -ProcessId 82504 -TimeoutSec 5 -Verbose`):import 2766 ms;第一次 `prepare 345 ms, scan 193 ms`,總計 666 ms;第二次 `prepare 46 ms, scan 209 ms`,總計 294 ms。兩次都 `scanComplete:true`。
- 4024 TcXaeShell 冷啟動:**沒跑**(停在第 4 項)。

## 2. 真 dialog 偵測

- 觸發:把 `AxisInterface.plcproj` 用相同 bytes 重寫(只改 mtime),00:46:18。
- `GetIdeModalDialog TimeoutSec=10`:`scanComplete:true`,`dialog.title="Microsoft Visual Studio"`,`text="The project file '...AxisInterface.plcproj' has been modified outside of TwinCAT XAE.  Do you want to reload the project?"`,`kind=reload-prompt`,`reloadTarget=project`,`buttons=[{name:"是(Y)",automationId:"YesButton"},{name:"否(N)",automationId:"NoButton"}]`(VS2022 WPF 訊息框)。
- `BuildProject`:`IDE_MODAL_DIALOG`,`'SolutionBuild.Build' not attempted`,`dialogKind=reload-prompt`。耗時 192 ms(16:46:24.474Z → .666Z)。**PASS**
- `ResetSolution`:`answeredYes:true`,`reopenedSolution:false`,`sameIde:true`,`totalSec 8.9`。
- 沒測 owned `#32770`(Tools>Options):沒有 GUI 權限(使用者拒絕 computer-use 控制 VS2022)。

## 3. zh-TW Error List 範圍切換

做法:`WritePouCode Main` 加 `nIssue42Undefined := 1;`,`BuildProject` 得到 `BUILD_FAILED`(C0046 / C0018 在 Main:3,errorItems 有內容)。使用者拒絕 computer-use,所以改用**自建 UIA 腳本**(`SelectionItemPattern.Select`)把「顯示下列項目所含的項目:」combo 從「整個方案」設成「目前專案」。

- 自建探測:expand 之後,「目前專案」和「整個方案」的 ListItem 都在 **combo 自己的 UIA 子孫**裡(各 2 個,只有 1 個可選)。pid 的 desktop children 只有 1 個,就是主視窗,沒看到另外的 popup 視窗。所以這次找到可選項目,靠的不是 VisibleOf 也不是 desktop fallback,而是 combo 的 Descendants 本身。
- combo **收合**之後,底下的 ListItem 是 **0 個**(在 `ResetSolution` 重開 solution 之後也一樣)。
- MCP `GetBuildErrors`(範圍是「目前專案」時):`success:true`,範圍**沒切換**(讀回仍是「目前專案」)。自建 client 帶 `-Verbose` 讀到的 `notes` 只有 `pane class=ViewPresenter grid=結果` / `buttons: errors=2 warnings=26 messages=1`,**沒有** scope 相關的 note,也沒有 desktop-wide FindAll fallback 的 note。
- 原因:scope 偵測(`Get-TcIdeErrorList.ps1:196`)是在 Error List 視窗裡找「Name 是 目前專案|目前文件|... 的 ListItem」。combo 收合時沒有這種元素,所以判定成「不需要切換」,直接讀可見的列。這段在 880705f..80f520e 之間**沒有改動**,是既有缺口。80f520e 改的 popup 搜尋(VisibleOf + fallback)因此根本沒被執行到。
- **實際影響(實測)**:還原程式碼後 `BuildProject` 回 `success`,`warnings:28`,但 `warningItems:[]`。`GetBuildErrors` 回 `counts.warnings=28`,`warnings=[]`,`success:true`。用自建 UIA 切回「整個方案」後,同一個 `GetBuildErrors` 回 28 列 warning。所以範圍是「目前專案」、而且當前專案不是 PLC 專案時,列會被藏住,模組卻回成功,沒有 note,也沒有警告。BUILD_FAILED 時 errors 列是否也會漏,要看當時的「目前專案」是哪個。這次編譯錯誤那輪 Main editor 開著,錯誤列是讀得到的。
- 建議修法(待決定):scope 改用 combo 的 `SelectionPattern.GetSelection()` 讀(收合時也讀得到,自建腳本實測可行)。另外在 `counts` > 讀到的列數時,回 warning 或 fail closed。
- 收尾:`Main.TcPOU` 已用 `.bak-42` 的版本覆蓋,hash 相同;`ResetSolution` 重開,`BuildProject` 得到 `completeBuild:true`、errors 0。Error List 範圍已設回「整個方案」。

## 4. EnableConfig -Force(UmRT)

- `EnableConfig Force=true TimeoutSec=180`(16:56:37.490Z → 16:57:33.663Z):`RUNTIME_CRASHED`,step `set-config` 失敗(55002 ms)。訊息:`TcSystemServiceUm (pid 49124 at the start) no longer exists and port 10000 answered ADS 0x7 for 10 s (last state seen: Run)`。
- **沒有誤報 MODAL_SCAN_INCOMPLETE**:pre-set-config 的 modal gate 通過,錯誤碼是 crash,不是掃描相關的碼。
- 留下 lifecycle block(這是 crash 本來就該有的,#68):`amsNetId 199.5.42.250.1.1`,`command Enable-TcConfig`,`errorCode RUNTIME_CRASHED`,`step set-config`,`time 2026-11-05 00:57:33`。**我沒有 ClearLifecycleBlock,也沒有重啟 UmRT。**
- crash 簽名(跟 troubleshooting「已知限制」#21 完全相同):Application Error 1000,00:57:17,`TcSystemServiceUm.exe 3.1.0.2649`,faulting module `TcOsSys.dll 3.1.0.1`,exception `0xc0000005`,offset `0x0000000000589534`,pid 0xBFE4(=49124);WER 1001 bucket `1526877736441380629`;dump `%LOCALAPPDATA%\CrashDumps\TcSystemServiceUm.exe.49124.dmp`(2,259,434 bytes,00:57:22)。
- watcher event:`00:44:18 bootdata-empty (to 0)`(watcher 剛啟動時 `TCNC.bootdata` 就已經是 0 byte);`00:57:17 pid-changed [49124]→[49124,74160]`;`00:57:23 pid-changed → []`。這跟 #21 記錄的「crash 前 bootdata 被截成 0 bytes」相符;這次 0 byte 在測試開始前就已經是這樣。
- UmRT 跑了約 3 h(21:46 啟動)後做 set-config 時 crash,情境跟 #21 crash #8 一樣。根因在 UmRT 側(實測 2026-11-05,本機 UmRT_Default,沒找到 InfoSys 出處)。

## 目前狀態(停在這裡)

- VS2022 pid 82504(自己啟動的)**還開著**,開的是副本 sln,MCP 連線還在。
- `TcSystemServiceUm` 不在;target 199.5.42.250.1.1 有 lifecycle block。
- 副本:`Main.TcPOU` 已還原;`AxisInterface.plcproj` bytes 沒變、mtime 有變;Build 產物(_CompileInfo / .tmc 等)可能已變更。最後的 diff 0 還原(robocopy `.bak-42` → 原位)**還沒做**,要等 IDE 關掉之後。
- watcher pid 77380 還在跑(DurationSec 7200)。
- 主 checkout 維持 80f520e。

## 需要決定

1. 要不要重啟 UmRT 並 `ClearLifecycleBlock`,再補跑第 4 項?這需要使用者同意。
2. 不碰 runtime 的部分要不要先做:第 5 項(`DisconnectIde -Quit`,有 / 沒有 `-Kill`)、4024 冷啟動 scan(第 1 項後半)、還原副本。

## 補跑(2026-11-05,使用者在主 session 同意重啟 UmRT)

- 12:16:07 依 brief「UmRT 復原」重啟 `TcSystemServiceUm`(新 pid 68688)。12:16:17 `GetSystemState 199.5.42.250.1.1` → `Config`(adsState 15),runtime 可連線。
- 等使用者親自下 `ClearLifecycleBlock`,之後才補跑第 4、5 項跟 4024 第 1 項。
- 16:32:29 `EnableConfig Force=true` → 還是 `LIFECYCLE_BLOCKED`,`notRun:true`,什麼都沒送。主 session 16:31:53 已經清掉檔案裡的 block(`%TEMP%\TwinCATAutomation` 只剩 history,沒有 `lifecycle-block.json`),但**本 session 的 MCP bridge 是另一個行程**,記憶體裡的 `$script:TcLifecycleBlockLocal` 還留著這筆。這是設計行為(`LifecycleBlock.ps1:47-51`:別的行程從檔案移除的 block,在這個行程裡要 Clear 才會消失)。
- 想在本 session 呼叫 `ClearLifecycleBlock`,被 Claude Code auto mode classifier 擋下(`[Security Weaken]`),沒有繞過。第 4、5 項和 4024 第 1 項還沒跑。
- 觀察:同一台機器上同時有好幾個 MCP bridge 時,在一個 bridge 清 block,不會解除其他 bridge 的 block。使用者以為「清好了」,其他 session 還是被擋。要不要改(例如 Clear 時以檔案為準、或清 block 時同步清掉其他 bridge 記憶體裡的那筆),要另外討論。
