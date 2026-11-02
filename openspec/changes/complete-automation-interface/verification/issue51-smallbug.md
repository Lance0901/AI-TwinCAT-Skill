# Issue #51 實測:ide-solutions.json 加 lock

## 環境(共用)

- 日期:2026-11-02 03:23~03:28(UTC+8)
- IDE:VS2022 `VisualStudio.DTE.17.0`(4026 XAE),由 `ConnectIde` 自己啟動(pid 79440,`ownedBySession` true),測完 `DisconnectIde Quit=true`
- 副本:`C:\Temp\Verify-4026-axis\AxisInterface_Type01_Library.sln`(8.3 短名 `C:\temp\VE569A~1\AXISIN~1.SLN`);測前 robocopy `/MIR` 備份到 `C:\Temp\Verify-4026-axis-baseline-smallbug`(259 檔 + SHA-256 manifest),測後還原、逐檔比對 0 差異
- target:本機 UmRT `199.5.42.250.1.1`(本次沒有 Activate)
- registered tcauto:主 checkout 停在整合 branch `test/smallbug-batch` `4d026a0`(#86 + #51 + #63 + #87 合併)。本 session 第一次 tcauto 呼叫時 bridge 啟動(03:23:35),同一份模組 `Import-Module` 後 `Get-Command -Module TwinCATAutomation` = 78、含 `Get-TcIdeModalDialog`
- `tests/Integration/Watch-Runtime.ps1` 背景監看,沒有 event 行

## 步驟與實際回傳

1. registered tcauto `ConnectIde`(8.3 短名,見 issue63-smallbug.md 步驟 1):success,pid 79440。
2. 讀 `%LOCALAPPDATA%\TwinCATAutomation\ide-solutions.json`(03:25:14 寫入,192 bytes):

   ```json
   [
       {
           "pid":  79440,
           "startTime":  "2026-11-02T03:24:16.0313522+08:00",
           "solution":  "C:\\temp\\Verify-4026-axis\\AxisInterface_Type01_Library.sln"
       }
   ]
   ```

   mutex + `[IO.File]::Replace` 路徑在真機寫入正常,solution 為長名(#63)。
3. 並行(兩個寫入者同時寫)無法經 MCP 觸發(私有函式):由單元測試 `tests/Unit/ide-solutions-lock.ps1` 覆蓋:兩個 runspace 各寫 50 筆不同 pid,修前(origin/master)只剩 11 筆、存活卻遺失 89 筆;修後存活遺失 0(另 1 筆是測試期間結束的 process,判為可排除)。Remove 與 Save 並行遺失 0;mutex 被佔住時 Save 約 2 s 後略過並寫 verbose、不 throw。

## 結論

PASS(真機寫入路徑經 registered tcauto;並行行為由單元測試驗證,非 MCP)。
