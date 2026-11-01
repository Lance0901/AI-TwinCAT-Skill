# Issue #86 實測:hint 指向的 Get-TcIdeModalDialog

## 環境(共用)

- 日期:2026-11-02 03:23~03:28(UTC+8)
- IDE:VS2022 `VisualStudio.DTE.17.0`(4026 XAE),由 `ConnectIde` 自己啟動(pid 79440,`ownedBySession` true),測完 `DisconnectIde Quit=true`
- 副本:`C:\Temp\Verify-4026-axis\AxisInterface_Type01_Library.sln`(8.3 短名 `C:\temp\VE569A~1\AXISIN~1.SLN`);測前 robocopy `/MIR` 備份到 `C:\Temp\Verify-4026-axis-baseline-smallbug`(259 檔 + SHA-256 manifest),測後還原、逐檔比對 0 差異
- target:本機 UmRT `199.5.42.250.1.1`(本次沒有 Activate)
- registered tcauto:主 checkout 停在整合 branch `test/smallbug-batch` `4d026a0`(#86 + #51 + #63 + #87 合併)。本 session 第一次 tcauto 呼叫時 bridge 啟動(03:23:35),同一份模組 `Import-Module` 後 `Get-Command -Module TwinCATAutomation` = 78、含 `Get-TcIdeModalDialog`
- `tests/Integration/Watch-Runtime.ps1` 背景監看,沒有 event 行

## 步驟與實際回傳

1. 從磁碟改寫副本 `.plcproj`(加一行 XML 註解),緊接著 registered tcauto `ResetSolution`:XAE 在呼叫期間才跳 reload prompt,回 `SOLUTION_CLOSE_FAILED`。MCP 收到的 hint:

   > Solution.Close 失敗:用 GetIdeModalDialog 看 XAE 有沒有 dialog;必要時 DisconnectIde Quit=true(或 kill IDE)後重新 ConnectIde SolutionPath=<sln>

   模組原文(`ConvertTo-TcAdsErrorCode.ps1` `SOLUTION_CLOSE_FAILED`)是「用 Get-TcIdeModalDialog 看 ...」:MCP 端已改寫為 `GetIdeModalDialog`,沒有殘留 cmdlet 名。
2. `GetIdeModalDialog`(composite,bridge 內部改呼叫 `Find-TcIdeModalDialog`):success,`data.dialog.kind` reload-prompt、`reloadTarget` project、buttons `YesButton` / `NoButton`(VS2022 WPF,id 0)。
3. CLI 補充(**不是 MCP**:獨立 `powershell.exe` `Import-Module` 主 checkout 模組):`Get-TcIdeModalDialog -ProcessId 79440` → `{"success":true,"data":{"processId":79440,"dialog":{"title":"Microsoft Visual Studio","text":"The project file '...AxisInterface.plcproj' has been modified outside of TwinCAT XAE.  Do you want to reload the project?","kind":"reload-prompt","reloadTarget":"project","hwnd":277286638,"buttons":[...]}}}`;不帶 pid → `NOT_CONNECTED`,hint「先 Connect-TcIde ...」。修前同一呼叫是 `CommandNotFoundException`(issue 原文)。
4. 之後 `ResetSolution` 回答 Yes 清掉 prompt(answeredYes true,8.5 s)。

## 結論

PASS:CLI 照 hint 呼叫 `Get-TcIdeModalDialog` 可用且回 JSON;MCP 端 hint 顯示 `GetIdeModalDialog`。
