# TcAuto MCP 實戰問題清單 — GantryCylinder MAIN watchdog(2026-10-20)

**摘要**:在 GantryCylinder 專案(TwinCAT 4024、32-bit `TcXaeShell.DTE.15.0`、本機 UmRT `199.5.42.250.1.1`、中文 Windows 11)實作 MAIN 的 move watchdog,從 `ConnectIde` → Build → `EnableConfig` → `ConnectAds` → UmRT `bSimulation` 模擬驗證全程只走 TcAuto MCP tool。
30 次呼叫(含 2 次手動介入)中 **22 次成功、6 次失敗(錯誤回傳或功能缺口)、2 次成功但結果不可用**(#9 quit:false、#23 TIME/enum 回 bytes);5 個模擬驗證情境全部通過。
最重要的 3 個問題:(1) `plcproj` 的 reload prompt 被判 `unknown`,`ResetSolution` 拒絕處理、`DisconnectIde Quit` 又關不掉 IDE,只能手動 kill;(2) `GetPouCode`/`WritePouCode` 不給 `PouPath` 時在 4024 專案樹 `TIPC^plc^plc Project^POUs` 找不到 POU,錯誤碼還是 `POU_READ_FAILED`;(3) ADS 層對 `TIME` 與 enum 的讀寫支援不完整(讀回 raw bytes、`TIME` 不能寫)。

---

## 1. 問題清單(依嚴重度)

嚴重度定義:**Blocker** = 流程卡住只能 kill IDE;**Major** = 功能缺口,必須繞路;**Minor** = 回傳格式或 hint 品質。
原始碼路徑以 `src/TwinCATAutomation/` 與 `mcp-server/` 為根。

### Blocker

| # | 工具 | 情境 | 實際回傳 | 影響 | 建議改法 |
|---|------|------|----------|------|----------|
| B1 | `GetIdeModalDialog` → `ResetSolution` | gen.py 重寫 `plc.plcproj`(內容相同、mtime 改變),XAE 跳「The project file ... has been modified outside of TwinCAT XAE. Do you want to reload the project?」(log #7、#8、#14) | `GetIdeModalDialog` → `dialog.kind = "unknown"`;`ResetSolution` → `IDE_MODAL_DIALOG`、`dismissedReloadPrompt=false`、not attempted;hint 只說手動處理或 kill IDE | 所有 DTE 呼叫被擋,`ResetSolution` 這條唯一的無對話框出路直接拒絕,最後只能 `Stop-Process`(log #10)重開 IDE(約 45 s + 重新 Connect/Build/Activate) | **(a)** `Private/Get-TcIdeModalDialog.ps1:259` 的 `$script:TcReloadPromptPattern` 加上 plcproj 版本:`'(?i)changed outside the (environment\|source editor)\|Reload the new file\|want to reload it\|modified outside of TwinCAT XAE\|want to reload the project'`;`Get-TcModalDialogKind`(`:261-264`)對後兩個 pattern 回新的 kind `'reload-project-prompt'`(或同樣回 `'reload-prompt'` 再用 `Text` 區分),`New-TcModalDialogResult`(`:455`)對兩種 kind 都用 `IDE_MODAL_DIALOG_RELOAD` hint。<br>**(b)** `Public/Reset-TcSolution.ps1:121-136`:`if ($dialog.Kind -eq 'reload-prompt')` 改為 `-in @('reload-prompt','reload-project-prompt')`;對 project prompt 用 B2 的 `Close-TcMessageBox -Answer Yes`(按 Yes 後 XAE 自己 reload project,**可以不必**走 Documents.CloseAll + Solution.Close/Open),按完後 `LookupTreeItem('TIPC')` 探測 SysManager 是否仍有效,無效才 fall through 到既有 step 2-5。<br>**(c)** `Private/ConvertTo-TcAdsErrorCode.ps1:12` 的 `IDE_MODAL_DIALOG` hint 改成「先 `GetIdeModalDialog` 看 `kind`;reload 類直接 `ResetSolution`;其他才手動/`DisconnectIde Quit=true`/kill」,`:13` 的 `IDE_MODAL_DIALOG_RELOAD` hint 補一句「`.plcproj` 被改也算,`ResetSolution` 會按 Yes」。<br>**(d)** `mcp-server/bridge/bridge.ps1:630-632`(`Invoke-OpModal` 的 kind 註解;`:677/:683` 的 `op:state` lastDialog 輸出同樣多帶 kind)與 `tools.json` `ResetSolution.description` 同步更新字樣。 |
| B2 | `ResetSolution`(dismisser)、手動 UIA(log #16) | 中文 Windows 11 的 XAE 訊息框:ClassName `#32770`,按鈕在 UIA 是 **Pane**(ClassName `Button`)不是 `ControlType.Button`,Name 是「是(Y)」「否(N)」,AutomationId **6 / 7**(= Win32 `IDYES` / `IDNO`) | 目前 `Private/Close-TcReloadPrompt.ps1:61-64` 只會送 `WM_CLOSE`(等於按 ✕ / No)。任何「要按 Yes」的 dismisser 若比對英文 `"Yes"` 或 `ControlType.Button` 在中文 UI 一定失敗 | 對 project reload prompt 送 `WM_CLOSE` 等於回答 No,project 不 reload,還是要走完整 close/reopen;真正省時間的是按 Yes(log #16 實測可行,按完 project 自動 reload) | 新增 `Private/Close-TcMessageBox.ps1`(或在 `Close-TcReloadPrompt` 加 `-Answer Yes\|No\|Close` 參數,預設 `Close` 保持現有行為):<br>1. 沿用 `:42-50` 的 Add-Type 區塊,補 P/Invoke `GetDlgItem(IntPtr hDlg, int nIDDlgItem)`、`SendMessage(IntPtr, uint, IntPtr, IntPtr)`。<br>2. `$hBtn = GetDlgItem($hwnd, 6)`(IDYES=6、IDNO=7、IDOK=1、IDCANCEL=2);`$hBtn -ne 0` 時 `SendMessage($hBtn, BM_CLICK=0x00F5, 0, 0)`;fallback `PostMessage($hwnd, WM_COMMAND=0x0111, MAKEWPARAM(6, BN_CLICKED=0), $hBtn)`。<br>3. **完全不碰 UIA Name / ControlType**,只認 control id,語系無關。<br>4. 既有 `:67-75` 的 poll 改成對 `Kind` 清單判斷(`reload-prompt`、`reload-project-prompt` 都算「還在」)。<br>5. `Get-TcIdeModalDialog.ps1:226-232` 的 scan 輸出多回 `Buttons = @(@{ Id; Name })`(從 `#32770` 子視窗 `GetDlgCtrlID` 取),讓 `GetIdeModalDialog` 的 `data.dialog.buttons` 給 AI 看得到可按什麼(Minor,但同一支程式順手做)。 |
| B3 | `DisconnectIde Quit=true` | IDE 被 modal 擋住時要求 Quit(log #9) | `success:true`,但 `data.quit=false`、`quitError=RPC_E_CALL_REJECTED`、`solutionClosed=false`;IDE 進程仍活著 | AI 讀到 `success:true` 以為 IDE 已關,下一個 `ConnectIde` 又黏回同一個被擋住的 IDE(`selectedBy=solution-match`)。這次是人看了 `quit:false` 才手動 `Stop-Process 31468` | `Public/Disconnect-TcIde.ps1`:<br>1. `:84-97` 結果組裝:`$Quit -and -not $quitResult.quit -and $quitResult.reason -ne 'not connected'` 時回 `New-TcResult -Success $false -ErrorCode 'IDE_QUIT_FAILED' -Data $data -Hint (Get-TcErrorHint 'IDE_QUIT_FAILED')`(COM 參考照樣釋放,`data` 保留 `solutionClosed/quit/quitError/ideProcessId`)。<br>2. 加 `[switch]$Kill`:`DTE.Quit` 失敗(或 `Get-TcIdeModalDialog` 事先回報有 dialog)時 `Stop-Process -Id $script:TcIdeProcessId -Force`,再 poll `Get-Process` 消失(≤10 s),`data.killed=true`。只在 `$script:TcIdeSelectedBy -eq 'launched'` 時允許,否則回 `IDE_NOT_OWNED`(避免殺使用者自己開的 IDE,對齊 `tools.json` 的 destructiveHint 說明)。<br>3. `:21-23` 進入 Quit 前先 `Get-TcIdeModalDialog`,有 dialog 且 `-Kill` 未給 → 直接回 `IDE_MODAL_DIALOG`(用 `New-TcModalDialogResult`),不要白跑 60 s 的 `Solution.Close` retry。<br>4. `Private/ConvertTo-TcAdsErrorCode.ps1:5-29` 新增 `IDE_QUIT_FAILED` hint:「IDE 仍在(pid N);有 dialog 先 `GetIdeModalDialog`;確定是本 session 啟動的 IDE 可 `DisconnectIde Quit=true Kill=true`」。<br>5. `tools.json` `DisconnectIde` 加 `Kill` boolean 參數。 |

### Major

| # | 工具 | 情境 | 實際回傳 | 影響 | 建議改法 |
|---|------|------|----------|------|----------|
| M1 | `GetPouCode` / `WritePouCode`(無 `PouPath`) | 4024 專案樹是 `TIPC^plc^plc Project^POUs^MAIN_GantryCylinder`(log #18、#19) | `POU_READ_FAILED` "Item not found";給 `PouPath` 才成功 | 自動偵測在所有 4024 專案一律失敗;錯誤碼不是 `POU_NOT_FOUND`,AI 無法分辨「路徑猜錯」和「COM 壞掉」 | `Public/Get-TcPouCode.ps1:36-44`、`Public/Write-TcPouCode.ps1:47-55`(兩處邏輯相同,`Add-TcPou.ps1:53-54` 也是):<br>1. `$plcConfig.Child(1)` 拿到的是 PLC 節點 `TIPC^plc`,不是 project 節點;`LookupChild('POUs')` 在這一層丟 COM 例外,`:49` 的 `$null` 檢查與 `:42-44` fallback 都走不到,直接進 `:61-63` 的 catch。<br>2. 改用既有 `Private/Resolve-TcPlcProjectPath.ps1`(已處理 4024/4026 兩種樹):`$projPath = Resolve-TcPlcProjectPath -SysManager $sm`,再依序 `LookupTreeItem("$projPath^POUs^$PouName")`、`"$projPath^$PouName"`、最後 `"$projPath^Libs^DUTs^$PouName"`/`"$projPath^GVLs^$PouName"`;每個 `LookupTreeItem` 包在 `try { } catch { $null }`,全部 `$null` 才回 `POU_NOT_FOUND`。<br>3. `POU_NOT_FOUND` 的 message 列出嘗試過的路徑,並加 hint(`ConvertTo-TcAdsErrorCode.ps1` 表)「用 `GetProjectTree` 找完整路徑後給 `PouPath`;4024 格式 `TIPC^<plc>^<plc> Project^POUs^<name>`」。<br>4. `:49-51` 與 catch 區分:只有 `LookupTreeItem` 之外的 COM 例外(讀 `DeclarationText` 失敗等)才是 `POU_READ_FAILED`。<br>5. `tools.json` `GetPouCode`/`WritePouCode` 的 `PouPath.description` 寫明 4024 路徑格式與 DUT 路徑(`...^Libs^DUTs^<name>`,`implementation` 為 null)。 |
| M2 | `WriteVariable` | 寫 `MAIN_GantryCylinder.tMoveTimeout : TIME`,Value 5000(log #28) | `TYPE_MISMATCH` "Unsupported type for write: TIME" | 所有 `TIME`/`TOD`/`DATE`/`DT`/`LTIME` 參數不能用 MCP 調,只能在程式裡額外準備 LREAL 替代變數(`fMoveWdFactor`)繞過 | `Public/Write-TcVariable.ps1:37-57` 的 `switch -Regex`:<br>1. 加 `'^(TIME\|TOD\|TIME_OF_DAY\|DATE\|DT\|DATE_AND_TIME)$'` → `WriteAny($handle, [uint32]$ms)`,`'^(LTIME\|LTOD\|LDATE\|LDT)$'` → `[uint64]` ns。<br>2. 值轉換:數字 = 毫秒(LTIME 為 ns);字串允許 IEC literal `T#5s`、`T#1m30s500ms`、`5000ms`(寫一個 `Private/ConvertFrom-TcTimeLiteral.ps1`,regex `(\d+)(d\|h\|m\|s\|ms)` 累加)。<br>3. `'^BOOL$'` 之外補 `'^WSTRING'`(`WriteAny([string], @($len))` 已可用)。<br>4. `default` 分支改用 `$symInfo['DataTypeId']`(`Private/TcAdsHelper.cs:53` 已回傳)當 fallback:enum(DataTypeId 2/18 = INT16/UINT16、size 2)可以寫整數,不要再回 `TYPE_MISMATCH`;message 補上 size 與 typeId 方便除錯。<br>5. `tools.json` `WriteVariable.Value.description` 補「TIME/LTIME 給毫秒或 `T#...` 字串;enum 給整數」。 |
| M3 | `ReadVariable` | 13 筆 Path 含 `TIME` 與 enum `E_GantryState`(log #23) | `TIME` → `{"value":[32,78,0,0],"Count":4}`(其實是 20000 ms);enum → `[20,0]`;其餘型別正常 | AI 得自己解 little-endian;enum 連數值都要手算,更沒有名稱;WatchVariable 跟著一起回 bytes | `Public/Read-TcVariable.ps1:38-60`:<br>1. 加 `'^(TIME\|TOD\|TIME_OF_DAY\|DATE\|DT\|DATE_AND_TIME)$'` → `ReadAny($handle,[uint32])`,`'^(LTIME\|...)$'` → `[uint64]`;`TIME` 另外附 `display = "T#20s"`(或 `valueMs`)。<br>2. `default` 分支先看 `$symInfo['DataTypeId']`(ADST_INT8=16、UINT8=17、INT16=2、UINT16=18、INT32=3、UINT32=19、INT64=20、UINT64=21、REAL32=4、REAL64=5):有對應就 `ReadAny` 成該整數型別並在結果加 `typeId`、`isEnum = $true`(typeName 不在內建清單但 typeId 是整數型 ⇒ enum);只有真的 struct/array(BIGTYPE=65)才回 bytes,而且 bytes 要回 `[int[]]` 而不是 PSCustomObject `{value, Count}`。<br>3. 進階(可選):`TcAdsHelper.cs` 加 `GetDataTypeInfo(client, typeName)`(ADSIGRP_SYM_DT_UPLOAD `0xF00E`)解析 enum 成員,回 `valueName = "MOVING"`;結果快取在 `$script:TcAdsEnumCache`,`Connect-TcAds` 時清掉。<br>4. `Watch-TcVariable.ps1:48/83` 直接呼叫 `Read-TcVariable`,改完自動受益。 |
| M4 | `BuildProject` / `GetBuildErrors` | 改後 build 有 1 個 warning(log #12、#13) | `BuildProject.data.warnings=1` 但 `errorItems[]` 沒有 warning 項;`GetBuildErrors.counts.warnings=1`,`errors[]` 只有 7 筆 lib error | 看不到 warning 內容(本次是新變數的 unused warning),要開 XAE 看 | 1. `Public/Build-TcProject.ps1:119`:兩個 `Get-TcBuildErrors` 呼叫都加 `-IncludeWarnings`;`:161-169` 的 data 加 `warningItems = @($el.data.warnings)`(`errorItems` 保持只有 error,不破壞既有消費者)。<br>2. `Public/Get-TcBuildErrors.ps1`:`-IncludeWarnings` 預設改為 on 比較符合 MCP 使用(或 `tools.json` 的 `GetBuildErrors.IncludeWarnings.default = true`);UIA 多一輪 toggle 約 +1~2 s,可接受。<br>3. `Private/Get-TcIdeErrorList.ps1:108-110` 的按鈕 regex 目前只認英文 `N Warnings`;這次是英文 UI 所以能讀,但中文 XAE 會整個 `ERRORLIST_UNAVAILABLE`,順手把 regex 放寬到 `'^\s*\d+(\s+of\s+\d+)?\s+(Warnings?\|個警告\|警告)\s*$'` 之類(同理 Errors/Messages),至少讓 count 讀得到。 |
| M5 | `WatchVariable` | 等 `bMoveTimeout` 變 TRUE / `iStep` 回 0(log #26、#27) | `DurationSec` → `INVALID_PARAMS`(hint 列出 Allowed,好);`DurationMs/IntervalMs` → `samples[]` 全列(50 筆 × 13 變數就很佔 context) | 沒有「等到某值就停」:只能猜一個夠長的 Duration 整段採樣,或改成重複 `ReadVariable`;timing 短的情境(halt 中 Jog 被擋、逾時中 EStop)根本測不到 | `Public/Watch-TcVariable.ps1`(`-Until` 是 scriptblock,`tools.json` 已註明 MCP 不可用):<br>1. 新增 `[object]$UntilValue`、`[ValidateSet('eq','ne','gt','lt','ge','le','changed')][string]$UntilOp = 'eq'`、`[switch]$OnlyChanges`。`:42` 的 `if ($Until)` 改為 `if ($Until -or $PSBoundParameters.ContainsKey('UntilValue') -or $UntilOp -eq 'changed')`,條件判斷用 `switch ($UntilOp)` 比較 `$readResult.data.value`(數值用 `[double]`、BOOL 用 `[bool]`、字串用 `-eq`);`changed` 以第一筆為基準。<br>2. `-OnlyChanges`:`:54`/`:85` 的 `$samples +=` 前比對上一筆 value,相同就只更新 `lastSeen` 不新增;回傳加 `firstValue/finalValue/changeCount`。<br>3. `:93-99` duration 模式的回傳加 `summary = @{ min; max; distinct }`,`samples` 超過 200 筆自動 `OnlyChanges`(回 `truncatedToChanges=true`)。<br>4. `-Path` 改 `[string[]]`,多變數同時 watch 一次回一組 timestamp(本次 13 個變數得叫 13 次)。<br>5. `tools.json` `WatchVariable` 加對應參數;`mcp-server/lib/tools.js:164-177` 的 `computeTimeoutMs` 已把 `TimeoutMs+DurationMs+30 s` 算進去,不用改。 |
| M6 | `GetProjectTree` | 4024 專案(log #4) | PLC 節點只列到 `plc Instance`,看不到 `plc Project` 以下的 POUs/DUTs/GVLs;沒有 NC 節點(專案本身沒 Motion,正常) | AI 沒辦法用它找 `PouPath`,M1 的錯誤又沒 hint,只能靠人知道 4024 路徑格式 | `Public/Get-TcProjectTree.ps1`:<br>1. `:34-47` 用 `ChildCount/Child(i)` 枚舉,4024 的 PLC 節點枚舉會**藏掉** project 節點(`Private/Resolve-TcPlcProjectPath.ps1:6-9` 的註解已記錄這個行為,所以它用 `LookupTreeItem` 直接命中)。<br>2. `:57-63` 讀完 `TIPC` 後,對每個 PLC 子節點做 `$projPath = "TIPC^$($plc.name)^$($plc.name) Project"` → `try { $sm.LookupTreeItem($projPath) }`,成功且 `children` 裡沒有同名節點就 `Read-TreeItem` 後 graft 進 `children`。<br>3. 加 `[switch]$PlcOnly` / `[int]$MaxDepth`(預設 10 太深,CX 的 I/O 樹會爆 context)與 `[string]$Root`(例如 `TIPC^plc^plc Project^POUs`),`tools.json` 同步。<br>4. 節點加 `kind` 欄位(`ItemSubType` 對 POU=604、DUT=606、GVL=615 ... 的對照表),AI 不用猜。 |
| M7 | 同回合平行呼叫(`WriteVariable` + `WatchVariable` + `ReadVariable`) | 同一個 assistant turn 平行送 3 個 tool call(log #29) | `ReadVariable` 比 `WatchVariable` 先完成;watch 的採樣錯過寫入當下 | 「寫參數 → 下命令 → 觀察」的時序驗證結果不可信;AI 沒有任何回傳能看出順序被打亂 | **bridge 確實有 queue**:`mcp-server/lib/bridge.js:319-358` `call()` push 進 `_queue`,`:360-380` `_pump()` 一次只送一筆給 powershell.exe,FIFO 正確(`README.md:286`、`PROTOCOL.md:259` 也寫了)。問題在 **FIFO 的順序 = MCP request 到達順序**,而 client 平行發出的 tool call 到達順序不保證,server 端無從得知 AI 的「意圖順序」。改法:<br>1. 文件層:`tools.json` 的 `WriteVariable`/`WatchVariable`/`SetPlcState` description 加「Do not issue this in the same turn as calls that depend on it; the server executes tool calls in arrival order」;`adapters/claude-code/SKILL.md` 加同樣規則。<br>2. 功能層:新增 composite `WriteThenWatch`(`mcp-server/lib/composites.js`,仿 `RunLifecycle` 的 `ctx.callTool` 串接):參數 `Writes[]`(path/value)、`Watch`(path、UntilValue、TimeoutMs)、`ReadAfter[]`,一個 call 內依序執行,回 `steps[]`。這是 PLC 測試最常見的 pattern,一次解掉時序問題。<br>3. 可選:`index.js:395` 的 `CallToolRequestSchema` handler 在 result 加 `data.seq`(bridge `_nextId`),AI 至少能事後看出實際執行順序。 |

### Minor

| # | 工具 | 情境 | 實際回傳 | 影響 | 建議改法 |
|---|------|------|----------|------|----------|
| N1 | 所有 hint | `GetSymbols` 未 `ConnectAds`(log #6)、`IDE_MODAL_DIALOG`、`ADS_PORT_NOT_FOUND` 等 | hint 寫 PowerShell cmdlet 名(`呼叫 Connect-TcAds`、`Enter-TcPlcOnline`、`Reset-TcSolution`),MCP 端的 tool 叫 `ConnectAds`/`PlcLogin`/`ResetSolution` | AI 要自己對照;`PlcLogin` ≠ `Enter-TcPlcOnline` 這種不是機械轉換,會猜錯 | hint 表在 `Private/ConvertTo-TcAdsErrorCode.ps1:5-29`,bridge 只在 `mcp-server/bridge/bridge.ps1:194-207` `Get-BridgeHint` 對 IDE 版 `NOT_CONNECTED` 特判。正確位置是 Node 端,因為只有它有 cmdlet→tool 對照:<br>1. `mcp-server/lib/tools.js:9-28` `loadToolCatalog` 多建 `map.byCmdlet = new Map(cmdlet → name)`。<br>2. 新增 `rewriteHintCmdletNames(result, catalog)`:對 `result.error.hint`(與 composite `steps[].result.error.hint`)做 regex `/\b(Connect\|Disconnect\|Enable\|Enter\|Exit\|Get\|Set\|Build\|Reset\|Read\|Write\|Watch\|Open\|New\|Add\|Send\|Invoke)-Tc[A-Za-z]+\b/g` → `byCmdlet.get(m) ?? m`,並把 `-SolutionPath <sln>` 這類參數寫法改成 `SolutionPath=<sln>`。<br>3. 在 `index.js:320-342` `callCatalogTool` 的 `return decorateBridgeLoss(result)` 前套用。<br>4. 加單元測試 `mcp-server/test/tools.test.js`:`Enter-TcPlcOnline` → `PlcLogin`、`Reset-TcSolution` → `ResetSolution`。 |
| N2 | `WriteVariable` | 寫 LREAL `fMoveWdFactor`(log #25) | `written` 時而字串 `"70.0"` 時而數字 `0.1` | 回傳型別不穩定,AI 做 round-trip 比對要多一層轉換 | `Public/Write-TcVariable.ps1:63` `written = $Value` 直接 echo 輸入(client 傳 `"70.0"` 字串就回字串;bridge `ConvertTo-BridgeValue` 對 `[object]` 參數不轉型)。改成 echo **實際寫入的轉型值**:在 `:38-52` 每個分支先 `$typed = [double]$Value` 再 `WriteAny($handle, $typed)`,`:63` 回 `written = $typed`;`TIME` 分支回毫秒整數。順便在 `:35` 前對 `STRING` 以外的型別做 `[string]$Value -match '^-?\d'` 檢查,不是數字就回 `TYPE_MISMATCH` 並說明。 |
| N3 | `ConnectIde` | 啟動 IDE(log #2) | 回傳有 `selectedBy=launched`、`pid`、`amsNetId`,沒有耗時 | 無法比較「重用 vs 啟動」成本,也無法判斷這台機器 IDE 啟動是否異常慢 | `Public/Connect-TcIde.ps1` 在進入點 `Stopwatch.StartNew()`,data 加 `launchSec`(launch 到 DTE ready)、`connectSec`(總計);`Reset-TcSolution.ps1:187-189` 已經在外面量 `connectSec`,統一由 Connect-TcIde 回報後可拿掉。`EnableConfig` 的 `steps[]` 格式是好範本。 |
| N4 | `GetIdeModalDialog` | 關掉 dialog 後再查(log #17)、modal 期間(log #7) | `dialog:null` 正確;有 dialog 時只回 `title/text/kind`,沒有 `hwnd`、按鈕清單 | 人要手動 UIA 才知道按鈕 id(log #16) | `mcp-server/bridge/bridge.ps1:625-632` `Invoke-OpModal` 已拿到 `Hwnd`(`Get-TcIdeModalDialog.ps1:388-394` 有回),但沒輸出;加 `hwnd`、`className`、`buttons`(見 B2 第 5 點)。`mcp-server/lib/composites.js:185-222` 的 `GetIdeModalDialog` description 補「kind 清單:reload-prompt / reload-project-prompt / unknown;reload 類直接 `ResetSolution`」。 |
| N5 | `GetPouCode` with DUT path | `TIPC^plc^plc Project^Libs^DUTs^E_GantryState`(log #19) | success,`implementation=null`,`pou` 欄位仍叫 `pou` | 可用但語意含糊,AI 不知道 null 是「沒有實作段」還是「讀失敗」 | `Public/Get-TcPouCode.ps1:53-59`:`$implText` 的 `catch { '' }` 吞掉錯誤,改為 `catch { $implError = $_.Exception.Message; $null }`,data 加 `itemKind = 'POU'\|'DUT'\|'GVL'`(從 `ItemSubType`)與 `implementationError`(有才加)。 |

---

## 2. 這次好用的部分

- `EnableConfig Force` 一次做完 Config → Activate → Run → Login+Download → port 851 → PLC Run,32 s,`data.steps[]`(set-config 1.7 / activate 17.3 / set-run 1.6 / login 11.2)每一步耗時清楚,`plcState`/`ideMemoryMB` 都在;全程沒有 dialog。
- `INVALID_PARAMS` 的 hint 直接列 `Allowed` 參數(`DurationSec` → 改 `DurationMs`),一次就修對。
- `GetSymbols Filter=MAIN_GantryCylinder.*MoveWd*` 含 `comment`,等於直接拿到程式裡的參數說明。
- `IDE_MODAL_DIALOG` 擋住後續 COM 呼叫的行為正確:`GetPouCode` 在 modal 期間回 `IDE_MODAL_DIALOG`/`RPC_E_CALL_REJECTED`(log #15),不會卡 120 s 等 `BRIDGE_TIMEOUT`。
- `BuildProject` 的 `codeErrors` 正確把 7 筆 Library Manager 環境錯誤排除,`decidedBy=LastBuildInfo` 說明判定依據。
- `ReadVariable` 支援 `Path[]` 一次 13 筆;`ConnectAds` 自動偵測 AmsNetId,`reconnected` 全程 false(UmRT 這次沒 crash)。
- `GetStatus` 未連線時 `data.bridge` 欄位完整,hint「Run ConnectIde first」用的是 tool 名(bridge 特判,N1 要推廣的就是這個)。

---

## 3. 工作流程建議

1. **磁碟改檔 + gen.py 的專案一定會碰 `plcproj` reload prompt**:gen.py 每次都重寫 `plc.plcproj`(內容相同也寫),XAE 跳的是「project file ... modified outside of TwinCAT XAE」,不是 `.TcPOU` 那種。在 B1 修好前:gen.py 跑完 **立刻** 用 `GetIdeModalDialog` 確認,然後手動按 Yes(或 `Stop-Process` 重連);B1 修好後改成 gen.py → `ResetSolution` 一步。
2. **還原 mtime 無效**(log #14):XAE 用 file watcher 的寫入事件偵測,不比 mtime。要避免 prompt 只有兩條路:gen.py 內容相同就不寫(`if new != old: write`),或改用 `WritePouCode`(走 COM 寫編輯 buffer,永不跳框)。
3. **改寫參數後再下命令要分回合**(M7):`WriteVariable`(參數)→ 下一回合 `WriteVariable`(命令 bGoto/bCycle)+ `WatchVariable`;同一回合平行送的 tool call 到達順序不保證。在 `WriteThenWatch` composite 做出來前,一律一回合一個因果步驟。
4. **`TIME` 參數目前只能用 LREAL 替代變數繞過**(M2):程式裡保留 `fMoveWdFactor : LREAL` 之類的縮放係數讓 watchdog limit 可調;`ReadVariable` 讀回的 `TIME` bytes 用 little-endian `b0 + b1*256 + b2*65536 + b3*16777216` 還原毫秒(`[32,78,0,0]` = 20000)。
5. **4024 專案的 POU 路徑一律給 `PouPath`**(M1):`TIPC^<plc>^<plc> Project^POUs^<name>`,DUT 在 `^Libs^DUTs^`,GVL 在 `^GVLs^`;`GetProjectTree` 目前看不到這層(M6)。
6. **`DisconnectIde Quit=true` 回來要看 `data.quit`,不要看 `success`**(B3);`quit:false` 就 `Stop-Process <pid>`,pid 在 `ConnectIde` 回傳與 `GetStatus.data.lastIde`。
7. 觀察期較長的驗證(本次 Cycle 15 s × 5 次)用 `WatchVariable IntervalMs=500 DurationMs=20000` 一次拿完,比連續 `ReadVariable` 省回合;但 samples 會很長,只挑 1~2 個關鍵變數 watch,其餘事後 `ReadVariable Path[]` 一次讀。

---

## 附錄 A:30 筆呼叫原始 log

### IDE / Build 階段

| # | 工具 | 情境 | 結果 | 備註 |
|---|------|------|------|------|
| 1 | GetStatus | 未連線 | NOT_CONNECTED,hint「Run ConnectIde first」 | hint 有用;data.bridge 有完整欄位 |
| 2 | ConnectIde SolutionPath+ProgId 15.0 | 無 IDE | success,selectedBy=launched,pid 31468,amsNetId 已是 199.5.42.250.1.1 | 回傳沒有耗時欄位 |
| 3 | SetTarget | 已是同一 NetId | success | 冪等 |
| 4 | GetProjectTree | | success | PLC 節點只到「plc Instance」,看不到 POU;無 NC 節點(專案本身沒有 Motion) |
| 5 | BuildProject(基準) | | buildSucceeded,errors 7(Library Manager),codeErrors [],decidedBy LastBuildInfo | 7 筆 lib 錯誤是環境問題,codeErrors 正確為空 |
| 6 | GetSymbols Filter | 未 ConnectAds | NOT_CONNECTED,hint「呼叫 Connect-TcAds」 | hint 用 PowerShell cmdlet 名,MCP 端應顯示 ConnectAds |
| 7 | GetIdeModalDialog | gen.py 重寫 plc.plcproj(內容不變、mtime 變)後 XAE 跳「The project file ... has been modified outside of TwinCAT XAE. Do you want to reload the project?」 | success,dialog.kind=**unknown** | reload-guard 只認 .TcPOU 的「File has been changed outside the environment」 |
| 8 | ResetSolution | 同上 modal | IDE_MODAL_DIALOG,not attempted,dismissedReloadPrompt=false | 應把 plcproj reload prompt 也歸為 reload-prompt 並回答 Yes;hint 只叫人手動處理或 kill IDE |
| 9 | DisconnectIde Quit=true | 同上 modal | **success:true** 但 quit:false,quitError=RPC_E_CALL_REJECTED,IDE 進程仍活著 | success 旗標與結果不一致;建議 Quit 失敗時回 partial/false,或加 Kill 選項 |
| 10 | (手動)Stop-Process 31468 | | OK | 必須自己 kill |
| 11 | ConnectIde(第二次) | | success,pid 91096 | |
| 12 | BuildProject(改後) | | buildSucceeded,codeErrors [],warnings 1 | warnings 只有 count,errorItems 沒有 warning 項目 |
| 13 | GetBuildErrors | | counts.warnings=1,但 errors[] 只有 7 筆 Error,無 warning 項 | source=ErrorList(UIA);warning 讀不到 |
| 14 | (第二輪磁碟改檔)gen.py 後還原 plcproj 等 13 檔的 mtime | | XAE **仍然**跳 plcproj reload prompt | XAE 用 file watcher 的寫入事件偵測,還原 mtime 沒用 |
| 15 | GetPouCode(modal 期間) | | IDE_MODAL_DIALOG,RPC_E_CALL_REJECTED | 行為正確,hint 仍只說手動/kill |
| 16 | (手動 UIA)找對話框 | | 對話框是 #32770,按鈕在 UIA 是 **Pane** 不是 Button,名稱為中文「是(Y)」「否(N)」,AutomationId 6/7 | dismisser 不能比對英文 "Yes"/ControlType.Button;要用 AutomationId=6 + BM_CLICK(hwnd),這樣就關得掉且 project 會 reload |
| 17 | GetIdeModalDialog(關掉後) | | dialog:null | OK |
| 18 | GetPouCode PouName=MAIN_GantryCylinder(無 PouPath) | 4024 專案 | POU_READ_FAILED "Item not found" | 自動偵測走 TIPC^plc^POUs,但 4024 樹是 TIPC^plc^**plc Project**^POUs;LookupChild('POUs') 丟例外,連 fallback 都走不到;錯誤碼也不是 POU_NOT_FOUND |
| 19 | GetPouCode PouPath=TIPC^plc^plc Project^POUs^MAIN_GantryCylinder | | success,declaration/implementation 完整,含新變數 | 明確路徑可用;DUT 路徑 TIPC^plc^plc Project^Libs^DUTs^E_GantryState 也可用,implementation=null |
| 20 | BuildProject(修 review 後) | | buildSucceeded,codeErrors [] | |

工作流程發現:專案的 gen.py 會重寫 plcproj(即使內容相同),所以「改磁碟 + 等 XAE 自動 reload」路徑一定會碰到 plcproj 的 reload prompt,不是 .TcPOU 的那種。

### Runtime 階段

| # | 工具 | 情境 | 結果 | 備註 |
|---|------|------|------|------|
| 21 | EnableConfig Force | 重開後第一次 Activate,含 Visu | success,32 s(set-config 1.7 / activate 17.3 / set-run 1.6 / login 11.2),plcState Run,ideMemoryMB 840,steps[] 清楚 | 很好用;無 dialog |
| 22 | ConnectAds | | success,port 851 Run,adsBackend 4.3.32 compiled | |
| 23 | ReadVariable Path[] 13 筆 | | success | **TIME 回 raw bytes** `{value:[32,78,0,0],Count:4}`(=20000 ms);**enum E_GantryState 回 `[20,0]`** 而非整數/名稱;BOOL/LREAL/UINT/UDINT/DWORD/WORD 正常 |
| 24 | GetSymbols Filter=MAIN_GantryCylinder.*MoveWd* | ADS 已連 | success,含 comment | 好用 |
| 25 | WriteVariable BOOL/LREAL | | success | LREAL 的 written 回字串 "70.0" 而非數字(fMoveWdFactor=0.1 時卻回數字 0.1),不一致 |
| 26 | WatchVariable DurationSec | | INVALID_PARAMS,hint 列出 Allowed 參數 | hint 有用 |
| 27 | WatchVariable DurationMs/IntervalMs | | success,samples[] 全列 | 沒有「等到某值就停」的條件,只能定時採樣;samples 多時很占 context,建議加 UntilValue / 只回變化點 |
| 28 | WriteVariable TIME(Value 5000) | tMoveTimeout | **TYPE_MISMATCH "Unsupported type for write: TIME"** | TIME 不能寫;改寫 fMoveWdFactor 繞過 |
| 29 | 同一回合平行送 WriteVariable + WatchVariable + ReadVariable | | ReadVariable 先於 WatchVariable 完成 | bridge 不保證同回合呼叫順序;「寫參數→下命令」要分回合 |
| 30 | 全程 ADS | | reconnected 一律 false,無斷線 | UmRT 這次沒 crash |

## 附錄 B:5 個驗證情境結果(bSimulation 模式,UmRT)

| # | 情境 | 結果 |
|---|------|------|
| 1 | 0 → 70 mm @ 150 mm/s | iStep 200 → 210 → 0,bMoveTimeout FALSE,count 0 ✔ |
| 2 | 70 → 10 mm @ 5 mm/s,factor 0.1 → limit 5000 ms | 動作中讀到 limit 5000 / dist 60 / vel 5 / elapsed 4459;5 s 後 iStep 0、bMoveTimeout TRUE、count 1、bGoto FALSE、InMotion FALSE、停在 45.0 mm、FB READY 無 Error、lamp 0xFFE53935 ✔ |
| 3 | Cycle @ 2 mm/s | 510 持續 5 s → 0,bCycle 自動 FALSE,count 2,CycleCount 0,停在 55.0 mm ✔ |
| 4 | bReset | bMoveTimeout FALSE ✔ |
| 5 | 預設參數 Cycle 15 s | CycleCount 0 → 5,bMoveTimeout FALSE,count 仍 2,FB 無 Error ✔ |

未以 ADS 驗證(時序太短,M5 修好 `UntilValue` 後可補):halt 減速中立刻下 Jog 被擋、逾時中按 EStop。
程式小缺點(非 MCP 問題):離開動作段時 `tMoveWdLimit`/`fMoveWdDist`/`fMoveWdVel` 被 ELSE 清成預設,事後看不到當次 limit。
