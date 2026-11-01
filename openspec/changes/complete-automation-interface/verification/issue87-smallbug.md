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
