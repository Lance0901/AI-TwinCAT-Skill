# Coding Standards

審查(人或 `reviewer` agent)依這份判斷。這裡只放需要判斷的規則;機械項(PS 5.1 語法與檔案編碼、cmdlet 數與文件一致、禁用措辭、`src/` 與 `mcp-server/` 不用 `New-Object` 建 generic 集合(改用 `[System.Collections.Generic.List[object]]::new()`;實測 2026-10-28,PS 5.1.26100.9711:`New-Object` 建的 `List[object]` 被 `@()` 包住會丟 `ArgumentException`,#75)、錯誤碼在 troubleshooting 有一節、`tools.json` 同步、`tests/Unit/*.ps1`、`npm test`)由 `scripts/check.ps1` 檢查,pre-commit 與 CI 都會跑。

## 1. 可能無限阻塞的 COM / DTE 呼叫要有 deadline

每個同步 COM / DTE 呼叫(`ActivateConfiguration`、`Build`、`Login`、`Solution.Open`……)要有 deadline,或在註解寫明為何不需要。`Invoke-TcComRetry` 只能在呼叫返回後判斷(重試、分類錯誤),中斷不了一個不返回的同步呼叫;需要中斷時把呼叫放進背景 STA runspace,呼叫端等到 deadline 就放棄並回 `*_TIMEOUT` + 診斷。

正例:`src/TwinCATAutomation/Private/Invoke-TcActivateWithDeadline.ps1`(`Enable-TcConfig` 的 Activate);`src/TwinCATAutomation/Public/Build-TcProject.ps1`(非同步 `Build($false)` + 輪詢 `BuildState`)。

## 2. 「成功」只在讀回驗證後才回

`success: true` 只能在讀回確認目標狀態之後回傳:system state readback、每個 PLC port 的狀態、Boot package 比對。過程中做了什麼放 `data.steps[]`,不能拿「呼叫沒丟例外」當成功。

正例:`src/TwinCATAutomation/Public/Enable-TcConfig.ps1`(`verify` 步驟,`data.finalCheck`,不符回 `RUNTIME_STATE_MISMATCH`);`src/TwinCATAutomation/Public/Set-TcSystemState.ps1`(`SettleSec` + `readbackState`)。

## 3. 平台由目標對象決定,不以 XAE 版本判斷

solution platform 依 target 回報的平台(TARGETINFO)或使用者明確給的 `-Platform` 決定,不寫「4024 就用 X、4026 就用 Y」的分支;讀不到就回錯誤(`PLATFORM_UNKNOWN`)讓呼叫者決定,不要猜。

正例:`src/TwinCATAutomation/Private/Get-TcTargetPlatform.ps1`、`src/TwinCATAutomation/Public/Set-TcTarget.ps1`。

## 4. TwinCAT / ADS / XAE 行為斷言要有來源

新增的行為描述(程式註解、hint、文件)要附 InfoSys 連結(infosys.beckhoff.com),查不到官方說法的就標「實測」並寫日期、環境(XAE 版本、target)。不要把推測寫成事實。

正例:`src/TwinCATAutomation/Private/Get-TcTargetPlatform.ps1`(InfoSys TARGETINFO 連結);`docs/troubleshooting.md` 的「實測」條目。

## 5. 統一的回傳與 hint

回傳一律 `{success, data}` 或 `{success: false, error: {message, code, hint}}`(`New-TcResult`)。判斷的是 `hint` 的內容:要寫下一步該呼叫什麼(cmdlet / MCP tool 與參數),不是重述錯誤。(每個 hint key 在 `docs/troubleshooting.md` 有沒有一節,由 `scripts/check.ps1` 的 `errorcodes` 檢查。)

正例:`src/TwinCATAutomation/Private/New-TcResult.ps1`、`src/TwinCATAutomation/Private/ConvertTo-TcAdsErrorCode.ps1`(`$script:TcErrorHints`)。
