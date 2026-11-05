# PR #42(fix/42-modal-scan-cold-start)補跑 — 80f520e

- 實測日期:2026-11-05 18:35–18:38(+08:00)
- 環境:Windows 11 zh-TW;registered tcauto MCP(server = 主 checkout fa19124 / PR #129),模組經 `ReloadModule` 載入 `.claude\worktrees\verify` @ 80f520e(GetStatus moduleCommit 80f520ee…,loadedAt 10:34:34Z / 10:36:46Z)
- IDE:4024 TcXaeShell 32-bit(`TcXaeShell.DTE.15.0`),本 session 啟動 pid 81276;副本 `C:\Temp\Verify-4024-bfh\BFH-1650.sln`
- Runtime:本機 UmRT_Default(`TcSystemServiceUm.exe` 3.1.0.2649,pid 68688),199.5.42.250.1.1
- watcher:pid 96488,log `C:\Temp\verify-reports\runtime-watch.jsonl`

| # | 項目 | 結果 |
|---|---|---|
| 4024-1 | 冷啟動後第一次掃描(TcXaeShell 32-bit) | **PASS**(附註) |
| 4 | UmRT `EnableConfig -Force` 完整 cycle | **PASS** |
| 5 | `DisconnectIde -Quit` | **PASS**(`-Kill` 未測) |

## 4024-1 冷啟動掃描
- `ConnectIde ProgId=TcXaeShell.DTE.15.0 SolutionPath=...BFH-1650.sln`:`selectedBy=launched`、`ownedBySession=true`、pid 81276、`launchSec 3.2`、`connectSec 84.4`。
- 緊接著 `GetIdeModalDialog TimeoutSec=5`:`{"success":true,"data":{"ideProcessId":81276,"dialog":null}}`,無 BRIDGE_TIMEOUT。
- **真冷啟動**(上次報告附註 B 沒做到的):`ReloadModule`(不帶參數)換新 bridge 行程,bridge 的**第一個 call** 就是 `GetIdeModalDialog ProcessId=81276 TimeoutSec=5` → `success`,`dialog:null`,沒有逾時、沒有 `MODAL_SCAN_INCOMPLETE`。
- 附註:MCP 回傳沒有 `scanComplete` / `modalScan` / 耗時欄位(上次報告的附註 A 仍成立),所以只能證明「5 s 內完成且沒報逾時」,拿不到 prepareMs。

## 4 UmRT EnableConfig -Force
- 前置:`GetSystemState` = Config(15);`SetTarget 199.5.42.250.1.1 NoPlatformSwitch=true`(0x702,platform 維持 `TwinCAT RT (x64)`);`BuildProject`:completeBuild / codeVerified / coverageComplete 全 true,errors 0,9 s。
- `EnableConfig Force=true TimeoutSec=180`:`success`,9 steps 全 ok(set-config 4716 ms、activate 9202、boot-package 257、set-run 4862、login 3239、wait-plc-port 22、set-plc-run 16、wait-plc-run 13、verify 251),plcState Run,bootPackage match(4 檔),`finalCheck.dialogScanComplete:true`,`ok:true`,23.9 s。沒有誤報 `MODAL_SCAN_INCOMPLETE`。
- 註:上次第 4 項是在 4026 VS2022 跑(UmRT crash);這次因 4026 VS2022 的 IDE(pid 82504)不是本 session 啟動,改在 4024 跑同一條 cycle。

## 5 DisconnectIde -Quit
- `DisconnectIde Quit=true`:`solutionClosed:true`、`quit:true`、`quitError:null`、`disconnected:true`,1.8 s;之後 `Get-Process -Id 81276` 不存在。
- 回傳 `ownedBySession:false`(見 PR #129 報告的發現:ReloadModule 後重新 ConnectIde 會失去 ownership)。`-Kill` 沒測(需要 Quit 失敗的情境)。

## 不在本次範圍
- 上次的第 3 項(zh-TW Error List「目前專案」漏列)是既有缺口,本次沒動。
