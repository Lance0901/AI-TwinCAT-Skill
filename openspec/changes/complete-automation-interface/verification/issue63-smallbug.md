# Issue #63 實測:8.3 短名 SolutionPath

## 環境(共用)

- 日期:2026-11-02 03:23~03:28(UTC+8)
- IDE:VS2022 `VisualStudio.DTE.17.0`(4026 XAE),由 `ConnectIde` 自己啟動(pid 79440,`ownedBySession` true),測完 `DisconnectIde Quit=true`
- 副本:`C:\Temp\Verify-4026-axis\AxisInterface_Type01_Library.sln`(8.3 短名 `C:\temp\VE569A~1\AXISIN~1.SLN`);測前 robocopy `/MIR` 備份到 `C:\Temp\Verify-4026-axis-baseline-smallbug`(259 檔 + SHA-256 manifest),測後還原、逐檔比對 0 差異
- target:本機 UmRT `199.5.42.250.1.1`(本次沒有 Activate)
- registered tcauto:主 checkout 停在整合 branch `test/smallbug-batch` `4d026a0`(#86 + #51 + #63 + #87 合併)。本 session 第一次 tcauto 呼叫時 bridge 啟動(03:23:35),同一份模組 `Import-Module` 後 `Get-Command -Module TwinCATAutomation` = 78、含 `Get-TcIdeModalDialog`
- `tests/Integration/Watch-Runtime.ps1` 背景監看,沒有 event 行

## 步驟與實際回傳(registered tcauto)

| # | 呼叫 | 結果 |
|---|---|---|
| 1 | `ConnectIde ProgId=VisualStudio.DTE.17.0 SolutionPath=C:\temp\VE569A~1\AXISIN~1.SLN` | success,`selectedBy` launched,pid 79440,`data.solution` = `C:\temp\Verify-4026-axis\AxisInterface_Type01_Library.sln`(長名),connectSec 50 |
| 2 | `ConnectIde` 長名 `C:\Temp\Verify-4026-axis\AxisInterface_Type01_Library.sln` | success,`selectedBy` solution-match,pid 79440,`data.solution` 同上,0.6 s |
| 3 | `ConnectIde` 8.3 短名(再一次) | success,`selectedBy` solution-match,pid 79440,`data.solution` 同上,0.8 s |
| 4 | 從磁碟改寫 `.plcproj` 讓 XAE 跳 reload prompt 後,`ConnectIde` 8.3 短名 `NoLaunch=true` | `IDE_MODAL_DIALOG`,`matchedBy` module-state、`corroboratedBy` dialog-path(dialog 文字是長名路徑)、`attached` true、`data.solution` 長名、沒有另開 IDE |

## 結論

PASS:`-SolutionPath` 給 8.3 短名或長名,選到的 IDE 和 `data.solution` 相同;IDE 被 modal 擋住時,8.3 短名仍以 dialog-path 佐證比對成功。
