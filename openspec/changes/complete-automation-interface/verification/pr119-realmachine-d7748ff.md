# PR #119(fix/98-64-flaky-ci)真機驗證 — d7748ff

- 實測日期:2026-11-05 18:43–19:00(+08:00)
- 環境:Windows 11 zh-TW;registered tcauto MCP(server fa19124),`ReloadModule` → verify worktree @ d7748ff(moduleCommit `d7748ff5ef0d…`,loadedAt 10:43:33.843Z / 10:57:02.678Z)
- 觸發方式:用相同 bytes 重寫 `.plcproj`(只改 mtime)→ XAE 跳「The project file ... has been modified outside of TwinCAT XAE. Do you want to reload the project?」
- IDE:
  - 4024:TcXaeShell 32-bit(`TcXaeShell.DTE.15.0`)pid 94048(本 session 啟動),`C:\Temp\Verify-4024-bfh\BFH-1650.sln`
  - 4026:VS2022(`VisualStudio.DTE.17.0`)pid 82504,`C:\Temp\Verify-4026-axis\AxisInterface_Type01_Library.sln`。**不是本 session 啟動**:是 #42 驗證 session 00:44 啟動的副本 IDE(開的是副本，不是使用者原始專案);本 session 只 attach、沒 Quit,收尾只 `DisconnectIde`(不帶 Quit)。

| # | 項目 | 結果 |
|---|---|---|
| 1 | 4024 XAE(`#32770`)ResetSolution,XAE 在背景 | **PASS**(BM_CLICK 路徑) |
| 2 | 4026 VS2022 ResetSolution,背景 | **PASS** |
| 3 | 4026 VS2022 ResetSolution,前景 | **PASS**(前景只維持約 1.3 s,見附註) |

## 1. 4024 XAE `#32770`
- 18:43:50 重寫 `PLC1.plcproj` → `GetIdeModalDialog`:`title TcXaeShell`,`kind reload-prompt`,`reloadTarget project`,buttons `[{id 6,"是(&Y)"},{id 7,"否(&N)"}]`(Win32 message box)。前景視窗是 chrome(pid 81340),XAE 在背景。
- `ResetSolution`(tcauto):`dismissedReloadPrompt true`、`answeredYes true`、`reopenedSolution false`、`sameIde true`、`reloadWaitSec 0.3`、`totalSec 14.6`、`buildRequired` 已記錄。
- Method / Closed:MCP 回傳沒有這兩個欄位(只在 Verbose)。另用**自建 client**(zh-TW `powershell.exe -STA -File reset-verbose.ps1`,Import 同一份 verify 模組,對同一 IDE 再觸發一次)取 Verbose:`Close-TcMessageBox: BM_CLICK sent to control 6 (Yes) (hwnd 6363436, pid 94048).`,沒有出現 `posting WM_COMMAND` → BM_CLICK 直接生效,fallback 沒觸發;Reset 結果 success。
  - 同一次 Verbose 有兩行 `Find-TcIdeModalDialog: UIA scan of pid 94048 did not finish within 5 s.`(自建 client,Reset 過程中的 modal 掃描);沒造成錯誤,但跟 #42 的掃描逾時有關,記錄供參考。
- #127 驗證期間另外在 4024 跑了 3 次 tcauto `ResetSolution`(18:48:29、18:51:46,都是背景、answeredYes true、reopenedSolution false,13.6–17.3 s),全部 PASS。

## 2. 4026 VS2022 背景
- 18:57:24 重寫 `AxisInterface.plcproj`,前景 = chrome。`GetIdeModalDialog`:`title "Microsoft Visual Studio"`,`reload-prompt / project`,buttons `[{id 0,"是(Y)",automationId YesButton},{id 0,"否(N)",automationId NoButton}]`(VS2022 WPF 訊息框,非 `#32770`)。
- `ResetSolution`:`answeredYes true`、`reopenedSolution false`、`sameIde true`、`reloadWaitSec 0.1`、`totalSec 14.6`。

## 3. 4026 VS2022 前景
- 第一次嘗試(18:58:08)作廢:`AppActivate(82504)` 後 VS2022 有到前景,但 Reset 前前景已被 chrome 拿回(18:58:22 讀到 chrome)。該次 Reset 仍 success(answeredYes true,14.5 s),算成背景的第二筆。
- 正式一次(18:58:47 重寫):背景取樣器(`fg-sample.ps1`,每 250 ms 記前景 pid)先 `AppActivate(82504)`,緊接著 `ResetSolution`(10:59:16.391Z 開始)。取樣:18:59:16.816 起 VS2022(82504)是前景,到 18:59:18.078 後回到 chrome(使用者正在用 chrome,前景被搶回)。Reset 在 reload prompt 被回答後 `reloadWaitSec 0.1`,所以回答 Yes 落在 VS2022 前景的那段時間內(推論:回答時刻沒有單獨的時間戳)。結果:`answeredYes true`、`reopenedSolution false`、`sameIde true`、`totalSec 13.8`。

## 收尾
- 4026:`BuildProject` 第一次 `ERRORLIST_UNAVAILABLE` / `CODE_NOT_VERIFIED`(completeBuild false);第二次 completeBuild true、errors 0,BUILD_REQUIRED 已清。第二次只讀到 5 個 warning(之前記錄約 25 個 C0xxx),跟 #42 報告第 3 項「Error List 範圍是目前專案時漏列」的既有缺口一致,未深究。
- 4024:#130 階段 `BuildProject` completeBuild true(18:55),BUILD_REQUIRED 已清。
- 82504:`DisconnectIde`(不 Quit),IDE 保留原狀。
