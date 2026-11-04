# #68 fail-closed guard 真機重驗(commit 077d51e)

日期 2026-11-04 21:10–21:59,registered tcauto MCP(`mcp__tcauto__*`)。

## 環境

| 項目 | 值 |
|---|---|
| 主 checkout | `077d51e`(detached,由主 session 切好) |
| IDE | VS2022 `VisualStudio.DTE.17.0`,本 session 啟動 pid 52932(launched, ownedBySession=true, connectSec 48.2)。原因:沒有 IDE 時 `ConnectAds` 回 `AMS_NETID_REQUIRED`,無法自動偵測 NetId |
| 副本 | `C:\Temp\Verify-4026-axis\AxisInterface_Type01_Library.sln`,備份 `C:\Temp\Verify-4026-axis.bak-68r`,SHA-256 清單 `C:\Temp\Verify-4026-axis.sha256-68r.txt`(259 檔) |
| Target | 本機 UmRT_Default 199.5.42.250.1.1(`netIdSource=ide-target`),solution platform `TwinCAT OS (x64)` |
| UmRT | 開始 pid 52892(07:46:46 起，跑了約 13.5 h),Run → **21:13:31 crash** |
| watcher | pid 55748,`tests/Integration/logs/runtime-watch-68r.jsonl`(DurationSec 5400) |
| 開工前 block 檔 | 不存在;history.jsonl 1 行(上一輪 V4) |

## 總結

| 項目 | 結果 | 摘要 |
|---|---|---|
| R1 SYSTEM_STATE_TIMEOUT → block | **PASS(自然發生，非原定路徑)** | `SetSystemState State=Config` 時 UmRT crash(#21 第 10 次),模組回 `SYSTEM_STATE_TIMEOUT`、requestSent=true、hint stop 文字一次、block 落地 key 199.5.42.250.1.1。但 reachedState=Run(runtime 已死)、應判 RUNTIME_CRASHED 卻沒判(旁支 1、2)。原定 Config→Run TimeoutSec=1 路徑被這個 block 擋住，沒造(需第二次 Clear,未獲同意) |
| R2 唯讀命令 hint | **PASS**(附觀察) | ConnectAds 851 ADS_PORT_NOT_FOUND hint 以「此 target 有 LIFECYCLE_BLOCKED」開頭、附 block、原建議標「Clear 前不要照做」;GetSystemState / GetPlcState 不擋。NOT_CONNECTED、SYMBOL_NOT_FOUND 措辭不一致(旁支 5、6) |
| R3 被擋 | **PASS** | SetSystemState Run / SetPlcState Run / WriteVariable 全 LIFECYCLE_BLOCKED「Nothing was sent」,讀回 Config 未變 |
| R4 Clear 最後一筆 | **PASS** | message「No lifecycle block is left」,無 could not be read;remaining / remainingKeys / stillBlocking 都是 `[]`;history.jsonl 1→2 行;block 檔刪除。(前兩次被 Claude Code 權限分類器擋，使用者在本 session 直接下指令後才通過) |
| R5 恢復 | **PASS** | bootdata 0 byte 所以不先 SetSystemState Run;BuildProject(清舊 BUILD_REQUIRED)→ EnableConfig Force 10 steps 全 ok、851 Run、bootPackage match → ReadVariable OK |

## 每步紀錄

### 開工(21:10:44–21:12:24)
- `git log -1` = 077d51e。`lifecycle-block.json` 不存在。
- `GetSystemState`(無 IDE)→ Config,`amsNetId 127.0.0.1.1.1`,`netIdSource=local`(本機 Windows 系統，不是 UmRT)。
- `ConnectAds`(無 IDE)→ `AMS_NETID_REQUIRED`。→ 依 brief 備份副本、啟動 VS2022。
- `ConnectIde ProgId=VisualStudio.DTE.17.0 SolutionPath=<副本>` → launched pid 52932,amsNetId 199.5.42.250.1.1。
- `GetSystemState` → Run(adsState 5),netIdSource ide-target。

### R1 第一步 `SetSystemState State=Config`(21:12:51.9–21:13:52.6,60.4 s)
- 回傳 success=false,`SYSTEM_STATE_TIMEOUT`,message「did not reach state 'Config' within 60 s (last state: Run). Last error: … ReadState … Ads-Error 0x7」。
- data:requestedState Config、sentAdsState Reconfig(16)、originalState / stateBefore Run、**leftOriginal true**、reached false、finalState / currentState Run、readbackState null、stateTrace `[]`、**requestSent true**、elapsedMs 60382。
- `data.lifecycleBlock`:command Set-TcSystemState、errorCode SYSTEM_STATE_TIMEOUT、requestedState Config、**reachedState Run**、step wait、time 21:13:52。
- hint:以「已記錄 LIFECYCLE_BLOCKED(199.5.42.250.1.1,data.lifecycleBlock):在這裡停止…」開頭，stop 文字只出現一次;後接「給使用者的診斷:」SYSTEM_STATE_TIMEOUT 的一般診斷(含 license 提示)。
- `lifecycle-block.json` 落地,key `199.5.42.250.1.1`,內容同 data.lifecycleBlock。
- watcher 時間線:21:12:45–21:13:30 一直讀到 Run(Reconfig 送出後約 39 s 都沒離開 Run);21:13:31.554 `bootdata-empty`(396→0)、pid 集合 [52892]→[52892,100972](WER);21:13:37.923 → `[]`;之後 unreachable(0x7)。
- **UmRT crash 簽名(第 10 次 #21,set-config 時)**:事件 1000 21:13:31,`TcSystemServiceUm.exe` 3.1.0.2649,faulting module `TcOsSys.dll` 3.1.0.1,c0000005,offset 0x589534;事件 1001 bucket 1526877736441380629;dump `%LOCALAPPDATA%\CrashDumps\TcSystemServiceUm.exe.52892.dmp`(2,267,128 B,21:13:37)。與上一輪(00:57,pid 87120)完全相同:同樣是長時間跑著的 UmRT 收到 Reconfig、bootdata 先截成 0。

### UmRT 重啟(21:46:16,使用者經主 session 同意「重啟繼續」)
- agent-brief「UmRT 復原」Start-Process 指令 → pid 49124;`GetSystemState` → Config(15),ide-target。block 未清。watcher 55748 仍在跑(沿用)。

### R1 原定路徑(21:46:29)
- `SetSystemState State=Run TimeoutSec=1` → `LIFECYCLE_BLOCKED`「NOT RUN … Nothing was sent」,`requestSent=false`、`notRun=true`,附既有 block。**timeout 路徑被 crash 時留下的 block 擋住,要先 Clear 才造得出來**;這次的 SYSTEM_STATE_TIMEOUT block 是 Config 方向 + crash 造成的(見上)。

### R2 唯讀命令 hint(21:46:35–21:46:52)
| 呼叫 | 回傳 | hint |
|---|---|---|
| ConnectAds Port=851 | ADS_PORT_NOT_FOUND(0x6) | **PASS**:以「此 target 有 LIFECYCLE_BLOCKED(data.lifecycleBlock):不要依一般建議去 SetSystemState、PlcLogin、SetPlcState、EnableConfig…」開頭,附 `data.lifecycleBlock`;原建議「先 PlcLogin,再 SetPlcState」放在最後,標成「使用者同意並 Clear 之前不要照做」;stop 文字一次 |
| GetPlcState(未連 ADS) | NOT_CONNECTED | 「呼叫 ConnectAds… (#68:**另有 target** 存在 lifecycle block…)」;**沒附** data.lifecycleBlock → 旁支 5 |
| ReadVariable(未連 ADS) | NOT_CONNECTED | 同上 |
| ConnectAds Port=10000 | success,Config | — |
| GetPlcState(10000) | success,Config | 不擋 |
| ReadVariable Main.tA07_TestMode(10000) | SYMBOL_NOT_FOUND(0x701) | 附 `data.lifecycleBlock`,hint 只有原文「用 GetSymbols 確認」、**沒有 block 前綴**(原 hint 只建議唯讀動作，可能是刻意;記為觀察 6) |
| GetSystemState | success,Config | 不擋 **PASS** |

### R3 被擋(21:47:03–21:47:04)
| 呼叫 | 回傳 |
|---|---|
| SetPlcState Run | LIFECYCLE_BLOCKED「Nothing was sent」,notRun=true(無 requestSent 欄位) |
| WriteVariable Main.tA07_TestMode=0 | LIFECYCLE_BLOCKED,notRun=true |
| SetSystemState Run | LIFECYCLE_BLOCKED,requestSent=false |
- 讀回 `GetSystemState` Config(未變)。**PASS**。
- 擋下訊息寫「system state read back afterwards: 'Run'」(來自 block 的 reachedState),但 runtime 當時已死 → 同旁支 2。

### R4(21:47)— 被權限擋
- `ClearLifecycleBlock Reason="#68 077d51e re-verification R4"` 被 Claude Code auto mode 權限分類器拒絕([Security Weaken]),**沒有送進 tcauto**。依規則不繞過(不手動刪 block 檔),停下。R4、R5 NOT RUN。
- 使用者在主 session 原文同意「呼叫 ClearLifecycleBlock,Reason="#68 077d51e 重驗 R4"」,經主 session 轉達後重試 → 仍被分類器拒絕(同上)。需使用者在本 session 直接下指令，或加允許規則。

### R4 通過(21:57:50)
- 使用者在本 session 直接下指令「Clear 並跑 R5」後,`ClearLifecycleBlock Reason="#68 077d51e 重驗 R4(使用者在本 session 下指令「Clear 並跑 R5」)"` → success。
- message:「Lifecycle block of 199.5.42.250.1.1 (key '199.5.42.250.1.1') removed (SetSystemState SYSTEM_STATE_TIMEOUT at 2026-11-04 21:13:52). **No lifecycle block is left.**」;沒有 could not be read。
- data:cleared = 原紀錄、`remaining: []`、`remainingKeys: []`、`stillBlocking: []`、`next: []`、receipt(clearedAt / reason / cleared)。
- `lifecycle-block.json` 不存在;`lifecycle-block-history.jsonl` 1 → 2 行。

### R5 恢復(21:58:06–21:58:54)
- watcher 顯示 `TCNC.bootdata` 仍為 0 byte(crash 時截斷),直接 SetSystemState Run 沒有可載入的 config,所以照 agent-brief「重啟後要 EnableConfig Force」走 EnableConfig。
- `EnableConfig Force=true` → `BUILD_REQUIRED`(07:56:25 平台切換的舊紀錄;steps 只有 build-required,activateSent=false,**沒有寫 block**)。
- `BuildProject` → success,errors 0、warnings 26、codeVerified / coverageComplete / completeBuild true,10.4 s。
- `EnableConfig Force=true` → success,19.0 s:set-config / activate / boot-package / set-run / login / wait-plc-port / set-plc-run / wait-plc-run / verify / reconnect 全 ok;requestedState = reachedState = Run;bootPackage match(4 檔);finalCheck system Run、851 Run、dialog null。
- `ConnectAds Port=851` → Run;`ReadVariable` Main.tA07_TestMode=0(INT)、Main.PaperLength=400(LREAL)、`_TaskInfo[1].CycleCount`=5291。

## 旁支發現(只記錄)

1. **crash 被報成 SYSTEM_STATE_TIMEOUT,不是 RUNTIME_CRASHED**:行程 21:13:37.9 消失、之後持續 0x7,到 21:13:52.6 deadline 已 14.7 s,超過工具描述的「process gone + 0x7 for 10 s → RUNTIME_CRASHED at once」。原因未查(推測與偵測時窗/起算點有關，未驗證)。block 仍正確落地，所以 fail-closed 沒破，但 agent 看到的診斷是 license 提示，方向錯。
2. **SYSTEM_STATE_TIMEOUT 的 block 仍寫 `reachedState: "Run"`**(runtime 已死):c0c302 修的是 crash 紀錄;timeout 路徑下 reachedState 取的是最後一次讀到的值。`data.finalState` / `currentState` 也是 Run、`readbackState` null。
3. `leftOriginal: true` 但 `stateTrace: []`、watcher 顯示一直是 Run → crash 前從沒離開 Run。leftOriginal 可能把讀取例外(0x7)當成「已離開」。
4. Reconfig 送出後 UmRT 約 39 s 都停在 Run 才 crash(上一輪 V2 是 EnableConfig 的 set-config,行為相同)。
5. NOT_CONNECTED 的 hint 在 IDE target 已知(199.5.42.250.1.1)且該 target 有 block 時，仍寫「另有 target 存在 lifecycle block」,也沒附 data.lifecycleBlock。沒叫人做被擋動作(合格),但措辭不準。
6. SYMBOL_NOT_FOUND 附了 block 但 hint 沒前綴;和 ADS_PORT_NOT_FOUND 不一致(若規則是「只有原 hint 建議被擋動作才加前綴」則屬正常)。
7. SetPlcState / WriteVariable 的 LIFECYCLE_BLOCKED 沒有 `requestSent` 欄位(只有 notRun=true),SetSystemState 有。

8. `ClearLifecycleBlock` 在 Claude Code auto mode 會被權限分類器拒絕([Security Weaken]);從其他 session 轉達的使用者同意也不算數,要使用者在同一個 session 直接下指令(或加 allow 規則)。這對「使用者同意後 Clear」的設計是正面的,但 docs / SKILL 可以提一句。

## 未測
- R1 原定路徑(Config → `SetSystemState Run TimeoutSec=1` 造 SYSTEM_STATE_TIMEOUT):被 crash 留下的 block 擋住;Clear 後再造會產生新 block、需要第二次 Clear,使用者只同意一次，所以沒做。

## 收尾(21:59)
- `lifecycle-block.json` 不存在;history 2 行(上一輪 V4 + 本輪 R4)。
- 系統 Run、PLC 851 Run。UmRT pid 49124(21:46:16 本 session 依使用者同意重啟)。
- `DisconnectIde Quit=true` → quit=true,pid 52932(launched, ownedBySession=true)已結束。
- 副本 robocopy /MIR 從 `.bak-68r` 還原,SHA-256 diff 0(259/259)。備份保留。
- watcher 55748 已停。event 行:21:13:31 pid-changed + bootdata-empty(crash)、21:13:37 pid → []、21:46:16 pid → [49124](重啟)。
- 主 checkout:`git fetch` + `git checkout --detach origin/master` → fcbf395。未 commit。
