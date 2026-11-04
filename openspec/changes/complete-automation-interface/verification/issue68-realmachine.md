> 這份是 #68 在 commit 1b32f71 的真機驗證紀錄(原樣照抄);之後 commit 的修正(旁支發現 1-5)見 PR。

# #68 fail-closed guard 真機驗證(commit 1b32f71)

日期 2026-11-04(00:54–00:58 第一段、07:46–07:50 第二段),registered tcauto MCP(`mcp__tcauto__*`)。

## 環境

| 項目 | 值 |
|---|---|
| 主 checkout | detached `origin/fix/68-fail-closed-guard` = `1b32f71`(驗證後已切回 `origin/master` 3a22080) |
| tool 清單 | 有 `ClearLifecycleBlock`(bridge 載入 1b32f71) |
| IDE | VS2022 `VisualStudio.DTE.17.0`,本 session 啟動 pid 109756(launched, ownedBySession=true) |
| 副本 | `C:\Temp\Verify-4026-axis\AxisInterface_Type01_Library.sln`,備份 `C:\Temp\Verify-4026-axis.bak-68v`,SHA-256 清單 `C:\Temp\Verify-4026-axis.sha256-68v.txt`(259 檔) |
| Target | 本機 UmRT_Default 199.5.42.250.1.1,`SetTarget Platform='TwinCAT OS (x64)'` projectCheck ok |
| UmRT | 開始 pid 87120(Run)→ 00:57 crash → 07:46:46 重啟 pid 52892 |
| watcher | 第一段 pid 48088 `tests/Integration/logs/runtime-watch-68v.jsonl`(2 h 到期自行結束);第二段 pid 89840 `runtime-watch-68v-b.jsonl`(收尾時停) |
| block 檔 | `%TEMP%\TwinCATAutomation\lifecycle-block.json`、`lifecycle-block-history.jsonl` |

## 總結

| 項目 | 結果 | 摘要 |
|---|---|---|
| V1 正常成功路徑 | **PASS**(在 V4 後完成) | 第一次 EnableConfig 撞到 UmRT crash(見 V2);V4 Clear 後 EnableConfig Force 10 steps 全 ok,事實欄位全 true,ReadVariable OK,block 檔無本機紀錄 |
| V2 postcondition 失敗 → block | **PASS**(自然發生，非 SetSystemState timeout) | EnableConfig set-config 時 UmRT crash(#21)→ `RUNTIME_CRASHED`、activated/restarted=false、block 落地 key 199.5.42.250.1.1 |
| V3 被擋 | **PASS** | SetSystemState / EnableConfig / PlcLogin / SetPlcState Run+Stop / WriteVariable / RunTestCycle 全 `LIFECYCLE_BLOCKED`「Nothing was sent」;BuildProject / GetSystemState / GetPlcState / ConnectAds 不擋;runtime 讀回未變 |
| V4 解除 | **PASS** | ClearLifecycleBlock 回 cleared 紀錄 + receipt,history.jsonl 1 筆;block 檔刪除;之後 EnableConfig Force 成功 |
| V5 Invoke-TcTestCycle | **PASS** | steps Build/Activate/Login/ConnectAds/Run/Stop,無 Connect-TcIde;1/1 Pass;IDE target 仍 199.5.42.250.1.1 |
| V6 S-B | **PASS** | `PLC_PROJECT_NOT_FOUND`,steps 只有 `plc-project`,無 block,UmRT pid / Boot 檔時間未變 |
| V2 首選路徑(SetSystemState Config→Run 最短 timeout → `SYSTEM_STATE_TIMEOUT`) | **未測** | 見「未測」 |

## 每步紀錄

### 開工
- 備份 robocopy 259 檔,SHA-256 清單寫好。watcher 48088。
- `ConnectIde ProgId=VisualStudio.DTE.17.0 SolutionPath=<副本>` → launched pid 109756,ownedBySession=true,connectSec 47.9,amsNetId 199.5.42.250.1.1。
- `SetTarget AmsNetId=199.5.42.250.1.1 Platform='TwinCAT OS (x64)'` → ok,TARGETINFO 0x702,buildSelection 無變化。
- `BuildProject` → success,errors 0、warnings 26、codeVerified / coverageComplete / completeBuild true,10.4 s。

### V1 第一次 → 變成 V2(00:56:35–00:57:31)
- 前置：UmRT pid 87120,Boot `TCNC.bootdata` 396 B,block 檔不存在。
- `EnableConfig Force=true` → **success=false,`RUNTIME_CRASHED`**,55 s。
  - steps:只有 `set-config` ok=false(「UmRT 'UmRT_Default' disappeared while waiting for 'Config'… pid 87120 no longer exists… ADS 0x7 for 10 s」)。
  - data:activated / restarted / loggedIn / reconnected = false;activateSent / activateReturned / runSent / runReached / loginCompleted = false;requestedState Run、reachedState Run。
  - hint 以「已記錄 LIFECYCLE_BLOCKED(199.5.42.250.1.1,data.lifecycleBlock):在這裡停止…」開頭，明寫不要自行重啟 service / 改用其他通道。
  - `data.lifecycleBlock`:command Enable-TcConfig、errorCode RUNTIME_CRASHED、step set-config、time 2026-11-04 00:57:30。`data.runtimeCrash` 內含 Set-TcSystemState 的巢狀 block(requestSent=true,sentAdsState Reconfig 16)。
  - `lifecycle-block.json` 落地,key `199.5.42.250.1.1`。
- **UmRT crash 簽名(第 9 次 #21,set-config 時)**:事件 1000 00:57:15,`TcSystemServiceUm.exe` 3.1.0.2649,faulting module `TcOsSys.dll` 3.1.0.1,c0000005,offset 0x589534;事件 1001 bucket 1526877736441380629;dump `%LOCALAPPDATA%\CrashDumps\TcSystemServiceUm.exe.87120.dmp`(2,301,068 B,00:57:19)。watcher:00:57:14.784 `bootdata-empty`(396→0)、pid 集合 [87120]→[87120,88860],00:57:20 → []。與 troubleshooting「已知限制」#21 簽名完全相同(同樣 bootdata 先截成 0、同樣是長時間跑著的 UmRT 做 set-config)。
- 依 #68 hint 未自行重啟，回報主 session;主 session 轉達使用者同意「用 agent-brief UmRT 復原指令重啟一次、不 Clear block」。

### V3 第一段(UmRT 死掉時,00:57:58–00:58:16)
| 呼叫 | 回傳 |
|---|---|
| SetSystemState Run | LIFECYCLE_BLOCKED,requestSent=false |
| EnableConfig Force | LIFECYCLE_BLOCKED,activated=false |
| PlcLogin | LIFECYCLE_BLOCKED,online=false |
| SetPlcState Run | NOT_CONNECTED(ADS 沒連，未走到 block 檢查) |
| WriteVariable Main.tA07_TestMode=0 | NOT_CONNECTED(同上) |
| ConnectAds | ADS_TARGET_NOT_FOUND(唯讀、未擋) |
| GetSystemState | ADS_TARGET_NOT_FOUND(唯讀、未擋) |
| NewTestCase + RunTestCycle | LIFECYCLE_BLOCKED,steps=[](連 Build 都沒跑) |
- 讀回：TcSystemServiceUm 不存在,Boot 檔未變。

### UmRT 重啟(07:46:46)
- agent-brief「UmRT 復原」的 Start-Process 指令 → pid 52892,state Config(adsState 15)。block 未清。
- MCP bridge 在兩段之間重啟過:`ConnectIde NoLaunch=true` 接回 pid 109756(selectedBy solution-match,ownedBySession=false,同已知 #73;pid 與本 session 啟動的一致)。

### V3 第二段(block 仍在,07:47:11–07:47:32)
- `ConnectAds Port=10000`(851 不存在 → 回 ADS_PORT_NOT_FOUND,改連 10000 讓 ADS 命令能走到 block 檢查)。
| 呼叫 | 回傳 |
|---|---|
| SetPlcState Run | LIFECYCLE_BLOCKED「Nothing was sent」 |
| WriteVariable Main.tA07_TestMode=0 | LIFECYCLE_BLOCKED |
| SetPlcState Stop | LIFECYCLE_BLOCKED |
| BuildProject | success(未擋),completeBuild true |
| GetSystemState / GetPlcState | Config / Config(未擋) |
- 讀回：系統仍 Config,pid 52892。

### V4(07:47:38–07:48:19)
- `ClearLifecycleBlock Reason="#68 real-machine verification V4"` → success,`cleared` = 原 block 紀錄,`receipt` 有 clearedAt / reason / cleared,`stillBlocking=[]`,`remaining=null`;`lifecycle-block-history.jsonl` 1 行;`lifecycle-block.json` 被刪除。
  - message 尾巴多了「The remaining records could not be read: every target may still be blocked.」→ 旁支發現 1。
- `EnableConfig Force=true` → success,18.9 s:steps set-config / activate / boot-package / set-run / login / wait-plc-port / set-plc-run / wait-plc-run / verify / reconnect 全 ok;activated / restarted / loggedIn / reconnected = true;activateSent / activateReturned / runSent / runReached / loginCompleted = true;requestedState Run = reachedState Run;bootPackage match(4 檔);finalCheck system Run、851 Run、dialog null。
- `ConnectAds` 851 Run;`ReadVariable` Main.tA07_TestMode=0(INT)、Main.bEstop=true、Main.PaperLength=400(LREAL)、`_TaskInfo[1].CycleCount`=6209。block 檔不存在。

### V5(07:48:38–07:49:05)
- NewTestCase `V5-paperlength-and-cycle`(WaitUntil CycleCount>0;Assertions PaperLength=400、CycleCount>0)。
- `RunTestCycle` → success,21.9 s,steps Build / Activate / Login / ConnectAds / Run / Stop 全 success,1/1 Pass(CycleCount 3436,新一輪),沒有 Connect-TcIde 步驟。
- 之後 GetPlcState Stop、GetSystemState Run(netIdSource ide-target,199.5.42.250.1.1),GetIdeInfo 仍是副本 sln。

### V6(07:49:11)
- 前置:pid 52892,Boot 檔時間 07:48:43–07:48:52。
- `EnableConfig Force=true PlcProjectPath=["NoSuchPlc"]` → `PLC_PROJECT_NOT_FOUND`「nothing was changed」,steps 只有 `plc-project`(「not found before set-config」),activateSent / runSent=false,無 lifecycleBlock。
- 讀回：block 檔不存在,pid 52892,Boot 檔時間不變，系統 Run。

## 旁支發現(只記錄，未處理)

1. **Clear 最後一筆 block 時誤報「remaining records could not be read」**:`Clear-TcLifecycleBlock.ps1:76-83`,`$rest = Get-TcLifecycleBlockList` 在沒有剩餘紀錄時(推測回空陣列)被 PowerShell unroll 成 `$null`,於是 `$restKeys = $null` → 加上「every target may still be blocked」。同時 `stillBlocking=[]`、檔案已刪除，訊息互相矛盾，會誤導 agent 以為還要再 Clear。實測 2026-11-04,1b32f71,registered tcauto。
2. **RUNTIME_CRASHED 的 block 紀錄 `reachedState: "Run"`**:runtime 已死,`Run` 只是死前最後讀到的值;block 訊息顯示「requested 'Run', read back 'Run'」看起來像成功。Enable-TcConfig 外層的 requestedState 也寫 Run,但當時送出的是 Config(巢狀 block 才是 requestedState Config)。
3. **唯讀命令的 hint 沒考慮 block**:block 存在時 `GetSystemState` / `ConnectAds` 回 ADS_TARGET_NOT_FOUND 的 hint「等待 SetSystemState 回到 Run 後重新 ConnectAds」,`ConnectAds` 851 的 ADS_PORT_NOT_FOUND hint「先 PlcLogin,再 SetPlcState State=Run」—— 都在叫 agent 去做被擋的動作，和 stop 指示衝突。
4. **SetPlcState / WriteVariable 的檢查順序**:ADS 未連線時先回 NOT_CONNECTED,不回 LIFECYCLE_BLOCKED(文件有寫，行為正確;但 agent 看到 NOT_CONNECTED 的 hint「呼叫 ConnectAds」可能會先去連)。
5. V6 的 `PLC_PROJECT_NOT_FOUND` hint 寫「剛 Activate / 重啟後可重試一次」,對打錯名稱的情境不適用(小)。
6. 同一個 #21 crash 再次出現在「跑了很久(約 8.5 h)的 UmRT 做 set-config」;重啟後的新 UmRT 做兩次 set-config(V4、V5)都沒事。

## 未測

- **V2 首選路徑**(`SetSystemState State=Config` → `SetSystemState State=Run TimeoutSec=<最小>` 得 `SYSTEM_STATE_TIMEOUT`):V2 已由真實 `RUNTIME_CRASHED` 自然完成;主 session 指示「重啟後又 crash 就停」,而 #21 正好在 set-config 觸發，為了不再多一次 set-config 風險沒有加跑。`SetSystemState` 的 `TimeoutSec` 參數沒有 ValidateRange(MCP schema 也沒有 minimum),之後要測可以用 1。
- `SetPlcState` 送出後 Run / Stop 沒到(`PLC_RUN_TIMEOUT` / `STATE_SET_FAILED`)記 block 的路徑：本機 PLC 狀態切換只要 ~20 ms,自然逾時造不出來。
- `Invoke-TcTestCycle` PLC Run / Stop 失敗的路徑(同上)。
- `RunLifecycle` 在 EnableConfig 步驟被擋。

## 收尾

- `lifecycle-block.json` 不存在(無殘留);history 1 筆(V4 receipt)。
- 系統 Run,PLC 851 Run(V5 後 Stop,用 `SetPlcState Run` 恢復,success 22 ms)。UmRT pid 52892(07:46:46 由本 session 重啟)。
- `DisconnectIde Quit=true` → quit=true,IDE 109756 已結束(ownedBySession 顯示 false 是 bridge 重啟後的 #73 現象，pid 與本 session 啟動的一致)。
- 副本 robocopy /MIR 從備份還原,SHA-256 diff 0(259/259)。備份保留。
- watcher 89840 已停;48088 先前已到期結束。第二段 watcher 只有一行 event:07:46:56 `bootdata-empty`(重啟後、EnableConfig 前，延續 crash 時的 0 byte)。
- 主 checkout:`git fetch` + `git checkout --detach origin/master` → 3a22080。未 commit。
