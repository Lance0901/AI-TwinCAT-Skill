# Issue #87 實測:ResetSolution 在 .plcproj 剛被改寫時

## 環境(共用)

- 日期:2026-11-02 03:23~03:28(UTC+8)
- IDE:VS2022 `VisualStudio.DTE.17.0`(4026 XAE),由 `ConnectIde` 自己啟動(pid 79440,`ownedBySession` true),測完 `DisconnectIde Quit=true`
- 副本:`C:\Temp\Verify-4026-axis\AxisInterface_Type01_Library.sln`(8.3 短名 `C:\temp\VE569A~1\AXISIN~1.SLN`);測前 robocopy `/MIR` 備份到 `C:\Temp\Verify-4026-axis-baseline-smallbug`(259 檔 + SHA-256 manifest),測後還原、逐檔比對 0 差異
- target:本機 UmRT `199.5.42.250.1.1`(本次沒有 Activate)
- registered tcauto:主 checkout 停在整合 branch `test/smallbug-batch` `4d026a0`(#86 + #51 + #63 + #87 合併)。本 session 第一次 tcauto 呼叫時 bridge 啟動(03:23:35),同一份模組 `Import-Module` 後 `Get-Command -Module TwinCATAutomation` = 78、含 `Get-TcIdeModalDialog`
- `tests/Integration/Watch-Runtime.ps1` 背景監看,沒有 event 行

## 步驟

每輪:`[IO.File]::AppendAllText` 在副本 `AxisInterface.plcproj` 末尾加一行 XML 註解,約 0.5 s 後 registered tcauto `ResetSolution`(預設參數)。

## 實際回傳

| 輪 | 回傳 | 耗時 | 說明 |
|---|---|---|---|
| 修前(2026-11-01,phase2-3.8-retest N2) | `RESET_SOLUTION_UNVERIFIED` | 120.3 s | issue 原文 |
| 1 | success,`answeredYes` true、`reloadTarget` project、`reopenedSolution` false | 10.1 s | prompt 在 guard 期間處理 |
| 2 | `SOLUTION_CLOSE_FAILED`「Solution.Close failed: 不可在值為 Null 的運算式上呼叫方法」,projectCheck locate 失敗 | 0.8 s | prompt 在 guard 之後才跳出,Close 前沒再檢查 dialog;錯誤碼不對 |
| 3 | `IDE_MODAL_DIALOG`(projectCheck `TIPC.Child(1)` RPC_E_CALL_REJECTED),nothing closed | 3.7 s | prompt 在 projectCheck 期間跳出 |
| 4 | `IDE_MODAL_DIALOG`(projectCheck object list),nothing closed | 3.7 s | 同上 |
| prompt 已在畫面時再呼叫(3 次) | success,`answeredYes` true | 8.2~9.3 s | |

## 結論

FAIL(不開 PR):不再白等 120 s,但 4 輪只有 1 輪自動處理成功。XAE 偵測檔案變更有延遲,prompt 常在 guard 讀到 `Solution.FullName` 之後才跳出;projectCheck 與 `Solution.Close` 遇到 dialog 時沒有回到 dialog 步驟。要修:projectCheck / CloseAll / Close 失敗時先查 `Find-TcIdeModalDialog`,是 reload prompt 就回到步驟 1 重跑。

## #87 Retest (123ad3c)

### 環境

- 日期:2026-11-03 10:35~10:39(UTC+8)
- registered tcauto:主 checkout detached 在 `123ad3c`(branch `fix/87-reset-solution-reload-first`,不含 #100~#102);本 session 第一次 tcauto 呼叫時 bridge 載入這版模組
- IDE:VS2022 `VisualStudio.DTE.17.0`(4026 XAE),`ConnectIde` 自己啟動(pid 118984,`selectedBy` launched、`ownedBySession` true,48.9 s),測完 `DisconnectIde Quit=true`
- 副本:`C:\Temp\Verify-4026-axis\AxisInterface_Type01_Library.sln`;測前 robocopy `/MIR` 備份到 `C:\Temp\Verify-4026-axis-baseline-87retest`(259 檔),測後還原,SHA-256 逐檔比對 0 差異
- target:本機 UmRT `199.5.42.250.1.1`(沒有 Activate);`TcSystemServiceUm` pid 102904 全程不變
- `tests/Integration/Watch-Runtime.ps1` 背景監看(`tests/Integration/logs/runtime-watch-87retest.jsonl`,234 行),沒有 event 行

### 步驟

與上次相同:每輪 `[IO.File]::AppendAllText` 在副本 `AxisInterface.plcproj` 末尾加一行 XML 註解,接著 registered tcauto `ResetSolution`(預設參數)。append 到 ResetSolution 開始約 0.35~0.45 s(工具往返);第 3 輪在 append 後多等 1.5 s。

### 實際回傳

| 輪 | 回傳 | totalSec | 走的路徑(由 data 判斷) |
|---|---|---|---|
| 1 | success,`dismissedReloadPrompt` / `answeredYes` true、`reloadTarget` project、`reopenedSolution` false | 13.5 | data 有 `projectCheck: null`:跑到 1b 時 projectCheck 丟例外(prompt 在 guard 之後跳出,上次第 3、4 輪的情境)→ 查到 reload prompt → 重跑 → Yes 路徑 |
| 2 | 同上 | 12.4 | 同第 1 輪 |
| 3(多等 1.5 s) | 同上 | 8.1 | data 沒有 `projectCheck`:prompt 在步驟 1 就已出現,直接 Yes 路徑 |
| 4 | 同上 | 8.2 | `projectCheck.plcs[0].checked` false(`locate: no .tsproj ... lists PLC 'AxisInterface'`,上次第 2 輪 → `SOLUTION_CLOSE_FAILED` 的情境)→ CloseAll 前的 dialog 檢查查到 reload prompt → 重跑 → Yes 路徑 |
| 5 | 同上 | 9.1 | 同第 4 輪 |
| 6 | 同上 | 9.0 | 同第 4 輪 |

6 輪都沒有 `SOLUTION_CLOSE_FAILED` / `IDE_MODAL_DIALOG` / `RESET_SOLUTION_UNVERIFIED`;`closedDocuments` 0、`closed` false(沒有 Solution.Close),`sameIde` true、`ownedBySession` 維持 true。每輪都回 `buildRequired`(#65)。

之後:

| 步驟 | 回傳 |
|---|---|
| `GetIdeModalDialog` | `dialog` null |
| `BuildProject` | success,`buildSucceeded` / `codeVerified` / `coverageComplete` / `completeBuild` true,errors 0、libraryErrors 0、warnings 26(C0xxx 與 TMC version 訊息,跟基準相同),10 s |
| `DisconnectIde Quit=true` | success,`quit` true,pid 118984 已結束 |

路徑判斷依據:`Reset-TcSolution.ps1` 只在步驟 1b 設定 `projectCheck` / `savedProjects`(約 600 行),Yes 路徑直接回傳時不會有這兩個鍵;回傳 data 沒有重跑次數欄位,所以「重跑」是從這兩個鍵推回來的,沒有 Verbose log 佐證。

### 結論

PASS:上次 FAIL 的兩種情境(projectCheck 中途被 prompt 擋住、projectCheck locate 失敗後走到 Close)都在本次重現,修正後都回到 dialog 步驟並 success;之後 Build 正常。可以開 PR。
