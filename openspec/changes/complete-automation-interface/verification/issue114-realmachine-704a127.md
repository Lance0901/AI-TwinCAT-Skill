# PR #114(fix/114-crash-as-timeout)真機驗證 — 704a127

- 實測日期:2026-11-05 18:40–18:43(+08:00)
- 環境:Windows 11 zh-TW;registered tcauto MCP(server fa19124),`ReloadModule` → verify worktree @ 704a127(GetStatus/Reload current moduleCommit `704a127a69e6…`,loadedAt 10:40:26.200Z)
- IDE:4024 TcXaeShell 32-bit(`TcXaeShell.DTE.15.0`),本 session 啟動 pid 94048,副本 `C:\Temp\Verify-4024-bfh\BFH-1650.sln`
- Runtime:本機 UmRT_Default(`TcSystemServiceUm.exe` 3.1.0.2649,pid 68688 全程沒變),199.5.42.250.1.1
- crash 路徑沒有觸發(無法故意製造),只驗一般路徑。

| # | 項目 | 結果 |
|---|---|---|
| 1 | SetSystemState Config 成功路徑讀回欄位 | **PASS** |
| 2 | SetSystemState Run 成功路徑讀回欄位 | **PASS** |
| 3 | 失敗路徑(timeout,非 crash)欄位與 block | **PASS** |
| 4 | hint 路徑:block 在 IDE target 本身時 NOT_CONNECTED 說「此 target」並附 lifecycleBlock | **PASS**(「不呼叫 COM」只能間接證明) |
| 5 | LIFECYCLE_BLOCKED 帶 `requestSent:false` | **PASS** |
| N3 | Set-TcPlcState 讀取失敗時 currentState 是否回舊值 | **未實測**;程式碼確認仍會回舊值(見下) |

## 1 / 2 成功路徑
- `SetSystemState Config TimeoutSec=60`(Run→Config):`originalState Run`、`leftOriginal true`、`unreachableSeen false`、`reached true`、`finalState Config`、`currentState Config`、`readbackState Config`、`held true`、`stateTrace [{ms:21,state:Config}]`、`requestSent true`、latency 1797 ms、elapsed 4898 ms。
- `SetSystemState Run`(Config→Run):`sentAdsState Reset(2)`、`leftOriginal true`、`unreachableSeen false`、`finalState/currentState/readbackState Run`、`held true`、latency 1492 ms。
- 成功時沒有 `lastState` 欄位(只在失敗時出現)。`Config TimeoutSec=1 SettleSec=0` 也成功(latency 1302 ms,elapsed 1317 ms,略超過 1 s 仍判成功;是 timeout 檢查在 poll 之後,非本 PR 範圍)。

## 3 失敗路徑(刻意製造)
- `SetSystemState Run TimeoutSec=1 SettleSec=0`(Config→Run):`SYSTEM_STATE_TIMEOUT`,`finalState Stop`、`currentState Stop`、`lastState Stop`、`lastError null`、`readbackState null`、`leftOriginal true`、`unreachableSeen false`、`unreachableMs 0`、`probeErrors []`、`deadlineCheck null`、`servicePidAtStart [68688]`、`runtimeName UmRT_Default`。
- block:`reachedState Stop`(不是過時的 Run)、`readbackNote null`、`step wait`、18:41:55。沒有被誤判成 RUNTIME_CRASHED(行程還在)。
- 附註:hint 仍附上 license 的通用說明(這是 SYSTEM_STATE_TIMEOUT 的固定 hint,非 crash 情境下合理)。

## 4 hint 路徑
- block 存在、ADS 未連時 `ReadVariable MAIN.LT_Read` → `NOT_CONNECTED`,hint 開頭「此 target 有 LIFECYCLE_BLOCKED(data.lifecycleBlock)」,`data.lifecycleBlock` 有附上(#114 minor 5 修正:以前說「另一個 target」、沒附 block)。耗時 93 ms(10:41:59.878→.971)。
- `SetPlcState Stop`(ADS 未連)→ 同樣的 NOT_CONNECTED + block hint,57 ms。
- 「不呼叫 COM」:回應 < 100 ms 且 IDE 正常連線,符合用快取的 NetId(`Resolve-TcLifecycleIdeNetId` 只讀 `$script:TcIdeTargetNetIdCache`)。沒有 hang 住的 XAE 可以直接證明沒呼叫 COM。

## 5 LIFECYCLE_BLOCKED
- `SetSystemState Run` → `LIFECYCLE_BLOCKED`,`notRun true`、`requestSent false`,訊息「system state read back afterwards: 'Stop'」。

## N3(Set-TcPlcState currentState)
- 程式碼(704a127 `Public/Set-TcPlcState.ps1:111-115`):`currentState = $wait.State`;`Wait-TcAdsState` 的 `State` 是「最後一次讀到的狀態，之後失敗的 probe 不會清掉」(`Private/Wait-TcAdsState.ps1:63,148,237`)。所以等待中 port 讀取失敗時，`Set-TcPlcState` 仍回舊值，而且沒有 `unreachableSeen` 之類的欄位。Set-TcSystemState 已改,Set-TcPlcState 沒改。
- 實機觸發不了:需要 PLC port 在 wait 期間消失(runtime crash);SetPlcState Reset 在 UmRT 會殺 `TcSystemServiceUm`,不做。依 brief 不開 issue。

## block 處理
- 測試 block 於 18:42:32 用 `ClearLifecycleBlock` 清除。前置:UmRT 沒當機(pid 68688),`GetSystemState` 18:42:15 讀回 Run(5)。Reason 寫明是測試製造、讀回狀態與授權來源。`remaining []`。
- 清除前順便驗 #129:有 block 時 `ReloadModule` → `RELOAD_LIFECYCLE_BLOCKED`,`notRun true`,`data.lifecycleBlocks` 列出該筆(704a127 沒有 `Get-TcLifecycleBlockLocalForReload`,走 fallback 讀 `$script:TcLifecycleBlockLocal`)。
