---
name: TwinCAT-AutomationInterface
description: Control TwinCAT 3 IDE, manage PLC projects, build and deploy programs, read/write PLC variables via ADS, modify Structured Text code, and run automated PLC tests. Requires Windows with TwinCAT 3 XAE installed.
---

# TwinCAT Automation Skill

用 TwinCATAutomation PowerShell 模組控制 TwinCAT 3 IDE(XAE)與 PLC runtime。全程無 dialog。

## Setup

任何操作前先匯入模組:
```powershell
Import-Module "<module-path>" -Force
```

## MCP server (alternative to Import-Module)

同一個模組也可以當 TcAuto MCP server 用(`mcp-server/`,stdio),不必在 shell 裡 `Import-Module`:每個 cmdlet 都是一個 MCP tool,tool 名 = CLI action 名(`ConnectIde`、`BuildProject`、`EnableConfig`、`ReadVariable`…,參數與 cmdlet 相同、以 JSON 傳),另加 4 個複合 tool:`RunLifecycle`(Connect→Build→Enable→ConnectAds 一鍵)、`QuickRead`(未連 ADS 時自動連再讀)、`GetStatus`(IDE/系統/PLC 狀態快照)、`GetIdeModalDialog`(偵測卡住 XAE 的 modal)。When the `tcauto` MCP tools are available in the session, prefer them over Import-Module; they keep the IDE/ADS connection across calls. IDE COM 參考與 ADS 連線在呼叫之間保留,錯誤碼與 `error.hint` 和本頁相同;server 另加的 `BRIDGE_TIMEOUT` 代表 PowerShell 子程序被重啟、狀態全失,要重新 `ConnectIde`;`BRIDGE_DIED` 是 PowerShell 子程序自己結束(下一次呼叫會自動重啟,同樣要重新 `ConnectIde`;訊息含 "not executed; safe to retry" 的表示該呼叫根本沒送進 PowerShell,可直接重試);`MODULE_IMPORT_FAILED` 是 `powershell.exe` 起不來或 `Import-Module` 失敗(檢查 `TWINCAT_MODULE_PATH` / `TWINCAT_MCP_POWERSHELL`,每次呼叫都會回這個碼直到修好)。設定與完整 tool 表見 `docs/setup-mcp.md` 與 `mcp-server/README.md`。

## Full Lifecycle(零 dialog、零 Start-Sleep)

```powershell
# 1. 連 IDE + 開 solution(多實例時依 -SolutionPath 挑;data.candidates[] 列出全部)
$r = Connect-TcIde -SolutionPath "C:\Projects\MyProject.sln"

# 2. Build(失敗回 BUILD_FAILED;data.errorItems[] 是 Error List 的錯誤明細:code/description/file/line)
Build-TcProject

# 3. Activate 一步到位:Config -> Activate -> 等系統 Run -> Login+Download -> 等 851 -> PLC Run -> 等 851 Run
#    已包含 Enter-TcPlcOnline 與 Set-TcPlcState Run,不要再加 Start-Sleep
Enable-TcConfig -Force

# 4. 連 ADS(AmsNetId 從 IDE target 自動偵測)
Connect-TcAds

# 5. 讀寫
Read-TcVariable -Path "MAIN.nCounter"
Write-TcVariable -Path "MAIN.bEnable" -Value $true
```

`Enable-TcConfig -Force` 細節:

| 項目 | 說明 |
|---|---|
| 流程 | Config → ActivateConfiguration → 等 port 10000 = Run → `Enter-TcPlcOnline`(download)→ 等 port 851 可達 → PLC Run → 等 851 = Run |
| PLC Run | 模組 ADS session 正好是 `<netId>:851` 才用 `Set-TcPlcState Run`;否則(例如 `Connect-TcAds -Port 10000` 或別台 NetId)用暫時的 851 client 送 Run,不動原 session |
| `-NoLogin` | 跳過 download / PLC Run;只等 851 最多 10 秒(有 boot project 才會出現),沒有也不算失敗(step detail `skipped (no PLC port, -NoLogin)`)。之後依下方手動順序 |
| `-TimeoutSec` | 整個流程的總上限(單一 deadline),預設 120;每步等待用剩餘時間,超過 deadline 還沒開始的步驟回 `CYCLE_TIMEOUT` |
| data | `steps[]`(每步結果)、`plcState`、`loggedIn`、`reconnected`(之前有 ADS 連線時自動重連;PLC Run 時已自動重連則 reconnect 步驟記 `already reconnected in step 6`) |
| 之後 | 若 Activate 前已 `Connect-TcAds`,不用手動重連;`Read/Write/Watch-TcVariable`、`Get/Set-TcPlcState` 也會自動重連,data 有 `reconnected` |

不想一步到位時的手動順序(每步都有 gating,不需 sleep):
```powershell
Enable-TcConfig -Force -NoLogin     # 系統 Run 後才返回
Enter-TcPlcOnline                   # Login(REGULAR=1)+ 全域 SilentMode:空 runtime 會建 app 並下載,已有 app 就 attach;之後 port 851 才存在(不要加 SILENT 旗標 257,會跳過建 app)
Connect-TcAds                       # 先連 ADS,Set-TcPlcState 沒連線會回 NOT_CONNECTED
Set-TcPlcState -State Run           # 等 851 = Run 才返回(逾時回 PLC_RUN_TIMEOUT);PLC 未下載回 PLC_NOT_LOADED
```

## Cmdlet 清單(36)

**清單以外的名字不存在,例如沒有 `Get-TcVariable`,讀 symbol 用 `Get-TcSymbols`。**

| Cmdlet | 用途 |
|---|---|
| `Connect-TcIde [-SolutionPath <sln>] [-ProgId <id>] [-NoLaunch]` | 連 IDE(ROT 列舉全部實例);給 -SolutionPath 只接已開該 sln 的實例(`selectedBy=solution-match`),否則啟動新實例(`launched`),不會拿別人的空 IDE 來開;回 `amsNetId`、`ideProcessId`、`candidates[]`;連上後會開啟 `ITcAutomationSettings.SilentMode`,`data.silentMode` 回報結果 |
| `Disconnect-TcIde` | 釋放 IDE COM 參考 |
| `Reset-TcSolution [-SolutionPath <sln>] [-TimeoutSec 120]` | 關掉 reload 提示(若正在跳)→ `Documents.CloseAll`(不存檔)→ `Solution.Close` → 同一個 IDE `Solution.Open` → `Connect-TcIde -SolutionPath` 重連(實測約 20~25 s:Open 7~9 s + 重連 12~13 s),讓 XAE 重新從磁碟載入所有專案檔。磁碟直接改 .TcPOU 且該檔開在編輯器時用(見「重要注意」11);其他 modal 會回 `IDE_MODAL_DIALOG`;data 有 `dismissedReloadPrompt`、`closedDocuments`、`sameIde`、`closeSec`、`openSec`、`connectSec`、`totalSec` |
| `Get-TcIdeInfo` | IDE 版本、solution 路徑、連線狀態 |
| `New-TcProject -Name <n> [-Path <dir>]` | 建新 solution + PLC 專案 + MAIN |
| `Open-TcProject -Path <sln>` | 開既有 solution |
| `Get-TcProjectTree` | 專案樹 JSON |
| `Add-TcPou -Name <n> -Type <Program\|FunctionBlock\|Function> [-ReturnType <t>]` | 新增 POU |
| `Add-TcGvl -Name <n> [-Variables @{var=type}]` | 新增 GVL |
| `Add-TcDut -Name <n> -DutType <Struct\|Enum\|Alias\|Union>` | 新增 DUT |
| `Add-TcLibrary -Name <lib>` | 加 library 參考 |
| `Get-TcPouCode -PouName <n> [-PouPath <treePath>]` | 讀 POU declaration + implementation |
| `Write-TcPouCode -PouName <n> [-PouPath <treePath>] [-Declaration <st>] [-Implementation <st>]` | 寫 POU 程式碼 |
| `Invoke-TcIoScan` | 掃 EtherCAT 裝置 |
| `Get-TcIoTree` | I/O 裝置樹 |
| `Set-TcVariableLink -Variable <v> -Channel <c>` | PLC 變數連 I/O channel |
| `Build-TcProject` | Build(COM busy 自動重試);data:`errors`(Error List 錯誤數)、`failedProjects`(LastBuildInfo)、`errorItems[]`(severity/code/description/project/file/line/column) |
| `Get-TcBuildErrors [-IncludeWarnings] [-IncludeMessages] [-TimeoutSec 30]` | 用 UI Automation 讀 XAE Error List:`counts{errors,warnings,messages}`、`errors[]`(含 `-IncludeWarnings` → `warnings[]`、`-IncludeMessages` → `messages[]`)、`truncated`;`code` 由描述推得(Error List 沒有 Code 欄),可能為 null |
| `Set-TcTarget -AmsNetId <id>` | 設定 target system |
| `Enable-TcConfig [-Force] [-NoLogin] [-TimeoutSec <n>]` | Activate;-Force = 完整 Config→Run→Login→PLC Run,-TimeoutSec 為總上限 |
| `Send-TcPlcProgram` | 上傳程式到 PLC(不 login) |
| `Connect-TcAds [-AmsNetId <id>] [-Port 851]` | 連 ADS;data 有 `adsBackend` |
| `Disconnect-TcAds` | 斷 ADS |
| `Read-TcVariable -Path <sym>` | 讀變數(自動重連);`value` 依型別轉換,TIME/DATE 類回 IEC 字面(`"T#6s"`)另附 `ms`/`ns`/`unix` 整數、enum 另回 `name`、STRUCT 回 byte 陣列加 `size`(見下「型別對照」) |
| `Write-TcVariable -Path <sym> -Value <v>` | 寫變數:BOOL、整數型、REAL/LREAL、STRING、TIME/LTIME/TOD/DATE/DT/LDT(IEC 字面 `T#6s`、`DT#2026-10-20-12:30:00`,整數 ms/ns/秒也收)、enum(整數或成員名);`data.written` 是實際寫入的轉換值(時間類回正規化字面,`T#6000ms` → `T#6s`);STRUCT/ARRAY 回 `TYPE_MISMATCH`(自動重連) |
| `Watch-TcVariable -Path <sym> -IntervalMs <ms> [-Until <sb>] [-DurationMs <ms>] [-TimeoutMs <ms>]` | 輪詢直到條件成立或時間到(自動重連);samples 與 Read 同樣轉換(含 `ms`/`ns`/`unix`/`name`) |
| `Get-TcSymbols [-Filter <wildcard>]` | 列 symbol,例如 `"MAIN.*"`;enum 型別多回 `enumValues`(成員名→值) |
| `Get-TcPlcState` | PLC 狀態(port 851;自動重連) |
| `Set-TcPlcState -State <Run\|Stop\|Reset> [-TimeoutSec <n>]` | 設 PLC 狀態,Run/Stop 輪詢到目標(預設 30 秒,Run 逾時回 `PLC_RUN_TIMEOUT`);Reset 對 UmRT 危險(見下) |
| `Enter-TcPlcOnline [-PlcProjectPath <p>] [-LoginMode Regular\|Download\|OnlineChange] [-SilentFlag]` | `ITcPlcIECProject::Login(PLC_LOGIN_FLAGS)`:Regular=1、Download=4(full download)、OnlineChange=2,**預設不加 SILENT(256)**;提示框由 `Connect-TcIde` 開的全域 `ITcAutomationSettings.SilentMode` 以預設答案(Yes)處理。`-SilentFlag` 才會 OR 256,但實測旗標 SILENT 的語意是「遇到要問的就跳過不做」:257(REGULAR\|SILENT)在空 runtime 0.5 s 返回、**不建 app 不下載**、851 仍 Invalid,所以不要預設用。`Enable-TcConfig -Force` 的 login 步用 `-LoginMode Regular`(=1,XAE 自行決定是否下載;空 runtime 會建 app 並下載,實測 26 s、lifecycle 37/37);只有 `Send-TcPlcProgram` 用 Download(=4),已登入且 PLC 在跑時再做 full download;260(FORCEDOWNLOAD\|SILENT)實測下載成功,下一輪 Activate 時 32-bit XAE OutOfMemory crash(Visu 引擎,事件 1026),與旗標無關。**不要用 3**(REGULAR\|FORCEONLINECHANGE 互斥,下載時會 abort)。SilentMode 開啟時,對已在 Run 且程式不一致的 PLC 直接呼叫 `Enter-TcPlcOnline`,XAE 會自動採用 online change/download 提示的預設答案;要明確控制就帶 `-LoginMode Download` 或 `OnlineChange`。`Enable-TcConfig` 不受影響。 |
| `Exit-TcPlcOnline` | Logout |
| `Get-TcSystemState [-AmsNetId <id>]` | 系統狀態(port 10000)。省略 `-AmsNetId` 時依序用 IDE target → ADS session → local `127.0.0.1.1.1`,`data.netIdSource` 回報實際來源(`local` 代表讀的是本機 TcSysSrv,通常不是你的 target) |
| `Set-TcSystemState -State <Run\|Config> [-AmsNetId <id>] [-TimeoutSec <n>]` | 設系統狀態,輪詢到目標才返回。省略 `-AmsNetId` 時依序用 IDE target → ADS session,兩者皆無回 `AMS_NETID_REQUIRED`(不 fallback 到 local),`data.netIdSource` 回報來源 |
| `New-TcTestCase -Name <n> [-Setup @()] [-WaitMs <ms>] -Assertions @() [-Teardown @()]` | 定義測試 |
| `Invoke-TcTest -TestCase <tc>` | 跑單一測試 |
| `Invoke-TcTestCycle -TestCases @() [-SkipBuild] [-KeepRunning]` | Build→Activate→Login→Run→Test→Stop,每步 gating |

### 型別對照(Read/Write/Watch-TcVariable)

| PLC 型別 | 線上格式 | Read 回傳 | Write 接受 |
|---|---|---|---|
| TIME、TOD | UINT32 ms | `value` = `"T#6s"`、`"TOD#12:30:00"` + `ms` 整數 | `T#6s`、`T#1m30s500ms`、`TOD#12:30:00.500`(整數 ms 也收);`written` 回正規化字面 |
| LTIME、LTOD | UINT64 ns | `value` = `"LTIME#1us"` + `ns` 整數 | `LTIME#…`、`LTOD#…`(整數 ns 也收) |
| DATE、DT | UINT32 秒(1970 起) | `value` = `"D#2026-10-20"`、`"DT#2026-10-20-12:30:00"` + `unix` 整數 | `D#…`/`DT#…`、ISO 8601(含時區偏移會換成 UTC;整數 UNIX 秒也收) |
| LDATE、LDT | UINT64 ns(1970 起) | `value` = `"LDT#…"` + `ns` 整數 | `LDT#…`、ISO 8601(整數 ns 也收) |
| enum | 基底整數(預設 INT) | `value` 整數 + `name`(成員名;拿不到時 null + `hint`) | 整數或成員名(`"READY"`) |
| STRUCT / ARRAY | raw bytes | `value` byte 陣列 + `size` | 不支援整筆寫(`TYPE_MISMATCH`),改寫個別成員 |

## Testing Example

```powershell
$test1 = New-TcTestCase -Name "Initial state" -Assertions @(
    @{ Path = "MAIN.bReady"; Operator = "IsTrue"; Expected = $null }
    @{ Path = "MAIN.nCount"; Operator = "Equal"; Expected = [uint16]0 }
)

$test2 = New-TcTestCase -Name "Trigger and verify" `
    -Setup @( @{ Path = "MAIN.bStart"; Value = $true } ) `
    -WaitMs 2000 `
    -Assertions @(
        @{ Path = "MAIN.bDone"; Operator = "IsTrue"; Expected = $null }
    ) `
    -Teardown @( @{ Path = "MAIN.bStart"; Value = $false } )

Invoke-TcTestCycle -TestCases @($test1, $test2)
```

Assertion operators:`Equal`、`GreaterThan`、`LessThan`、`IsTrue`、`IsFalse`

## Output Format

所有 cmdlet 回 JSON。失敗時 `error.hint` 為可選欄位,有就照它做:
```json
{"success": true, "data": {"path": "MAIN.nCounter", "value": 42, "type": "UDINT", "reconnected": false}}
{"success": false, "error": {"message": "...", "code": "ADS_PORT_NOT_FOUND", "hint": "PLC runtime port 851 不存在:..."}}
```

## Troubleshooting

先看 `error.code`,再看 `error.hint`。詳細版:`docs/troubleshooting.md`。

| error.code | 根因 | 下一步 |
|---|---|---|
| `IDE_BUSY` | XAE 被 modal dialog / license 視窗擋住,COM 回 RPC_E_CALL_REJECTED(0x80010001)或 RETRYLATER(0x8001010A);模組已重試 1/2/4/8/16s 仍失敗 | 關掉 XAE 的 dialog,重跑同一個 cmdlet;不用重新 `Connect-TcIde` |
| `IDE_MODAL_DIALOG` | XAE/VS 有 modal 視窗(Assertion Failed、VS 帳戶設定、Target system reports a fatal error、trial license security code…)。這類視窗讓 DTE 呼叫**無限阻塞**(不是回 0x80010001),模組在 Build / Activate / Login / Solution.Open 前用 UI Automation 先檢查,有就直接回這個 code,`data.dialogTitle` / `dialogText` 是視窗內容 | 手動關閉 dialog 後重跑同一個 cmdlet;關不掉就 kill IDE(`Stop-Process -Id <data.ideProcessId>`)後重新 `Connect-TcIde`。模組不會自動關任何視窗;**已經被 modal 卡住的呼叫無法中斷**(見「已知 modal dialog」)。`data.dialogKind` = `reload-prompt`(「File has been changed outside the environment」,磁碟改檔觸發)時:直接 `Reset-TcSolution`,它會自己關掉提示並重開 solution,見「重要注意」11 |
| `IDE_CRASHED` | RPC 失敗(0x800706BE / 0x800706BA / 0x80010108)且 IDE 行程已不存在:XAE 崩潰(多為 32-bit XAE 於 Activate 時 OutOfMemoryException,Visu 引擎,事件 1026);模組已把 IDE 狀態重設為未連線 | 重新 `Connect-TcIde -SolutionPath ...`,再從 Build / `Enable-TcConfig` 開始;長流程輪次間用 `Disconnect-TcIde -Quit` |
| `IDE_TIMEOUT` | DTE 呼叫超過 `Invoke-TcComRetry -TimeoutSec`(預設 120 s,Build 600 s,Activate/Login 300 s)才失敗返回;通常是 IDE 被 dialog 卡住或長操作 | 看 XAE 畫面有沒有 dialog;必要時 kill IDE 後重新 `Connect-TcIde` |
| `NOT_CONNECTED` | 沒 `Connect-TcAds`,或 `Enable-TcConfig` 重啟後自動重連也失敗 | `Connect-TcAds`;剛 Activate 的話先 `Get-TcSystemState` 確認 Run |
| `ADS_PORT_NOT_FOUND` | port 851 不存在:程式尚未下載或 PLC 未啟動(ADS 0x6) | `Enter-TcPlcOnline` → `Set-TcPlcState -State Run`,或直接 `Enable-TcConfig -Force` |
| `ADS_TARGET_NOT_FOUND` | AmsNetId 無回應:TwinCAT 正在重啟,或 NetId 錯(ADS 0x7) | 等 `Get-TcSystemState` 回 Run 再 `Connect-TcAds`;NetId 用 `Connect-TcIde` 回的值 |
| `ADS_SYMBOL_NOT_FOUND` | 符號不存在:新程式尚未下載,或路徑拼錯(ADS 0x710) | `Get-TcSymbols -Filter "MAIN.*"` 確認;必要時 `Enter-TcPlcOnline` |
| `SYMBOL_NOT_FOUND` | `Read-TcVariable` 單一路徑讀不到(沿用舊 code,hint 同 `ADS_SYMBOL_NOT_FOUND`) | 同上 |
| `ADS_INVALID_STATE` | PLC 狀態不允許此操作,例如系統在 Config 模式就叫 PLC Run(ADS 0x712) | 順序 `Enable-TcConfig` → `Enter-TcPlcOnline` → `Set-TcPlcState Run` |
| `ADS_TIMEOUT` | ADS 逾時:目標忙碌或網路問題(ADS 0x745) | 稍後重試;`Get-TcSystemState` 看目標是否活著 |
| `PLC_NOT_LOADED` | `Set-TcPlcState Run` 時 PLC 內沒有程式(未 download;port 851 不存在,含自動重連時才發現的情況) | 先 `Enter-TcPlcOnline` 再 Run,或用 `Enable-TcConfig -Force` |
| `PLC_RUN_TIMEOUT` | 已送 Run,但 851 在時限內沒進 Run | `Get-TcPlcState` 看狀態;Error/Stop 時查 PLC 例外或 build 錯誤,重新 `Enter-TcPlcOnline` |
| `CYCLE_TIMEOUT` | `Enable-TcConfig -Force` 的 `-TimeoutSec` 總預算在某步開始前用完 | 看 `data.steps[]` 卡在哪步;加大 `-TimeoutSec` |
| `AMS_NETID_REQUIRED` | 沒有 IDE 連線可推 AmsNetId,又沒給 `-AmsNetId` | `Connect-TcIde -SolutionPath <sln>`,AmsNetId 自動偵測 |
| `PROJECT_OPEN_TIMEOUT` | Solution 在時限內沒載完:.sln 不含 TwinCAT 專案,或 XAE 被 dialog 擋 | 關 dialog,重跑 `Connect-TcIde -SolutionPath <sln>` |
| `SYSTEM_STATE_TIMEOUT` | `Set-TcSystemState` 輪詢逾時,系統沒切到目標狀態 | `Get-TcSystemState` 看目前狀態;檢查 XAE / TwinCAT System Service 錯誤;UmRT 可能要重啟 `TcSystemServiceUm`。若 target 是 UmRT 且剛 Activate 就停在 Config,常見原因是 license 不足(trial 未涵蓋專案用到的 TF),請在 XAE 的 License 節點確認 |
| `BUILD_FAILED` | 編譯錯誤(`data.failedProjects` > 0);`error.message` 含前 3 筆錯誤摘要,`data.errorItems[]` 是 Error List 全部錯誤(code/description/project/file/line) | 看 `data.errorItems`,修 code 後 `Build-TcProject`;不要在沒改東西的情況下重跑。若 `data.errorListError` = `ERRORLIST_UNAVAILABLE`,`errors` 退回 LastBuildInfo,改手動看 Error List |
| `ERRORLIST_UNAVAILABLE` | `Get-TcBuildErrors` 的 UI Automation 找不到 Error List 視窗或逾時(視窗被 auto-hide / 關閉、IDE pid 未知、UIA 被 modal 卡住) | 確認 XAE 視窗可見、Error List 沒 auto-hide;手動 View > Error List 後重試;加大 `-TimeoutSec` |
| `PROJECT_OPEN_FAILED` | .sln 路徑錯、檔案損壞、或該 IDE 沒有 TwinCAT 整合 | 確認路徑;用對應版本的 ProgID(見「環境」) |
| `POU_CREATE_FAILED` | 0x98510001 = .plcproj 列了檔案但磁碟缺檔 | 從 .plcproj 移除缺檔的 `<Compile Include>`,或補回檔案;重開 solution |
| `LOGOUT_FAILED` | Logoff COM 呼叫失敗:PLC 未 login、IDE busy、或 modal dialog。4026 上方法名是 **`Logoff()`**(不是 `Logout()`),`Exit-TcPlcOnline` 依序試 `TIPC^<Plc>` 節點與 `<Plc> Project` 節點的 Logoff/Logout,`data.logoutVia` 說明實際走哪條;舊版 `TIPC.Child(1).Object` 在 4026 永遠是 null,已不用 | `Get-TcPlcState` 確認;關 dialog 重試;重啟後直接重跑即可,不用重連 IDE |
| `NO_PROJECT` | 已連 IDE 但沒載入 TwinCAT 專案 | `Open-TcProject -Path <sln>` 或 `Connect-TcIde -SolutionPath <sln>` |
| `LOGIN_FAILED` | `Login(flags)` 失敗:系統在 Config、build 沒過、license dialog、或旗標互斥(`Conflicting flag settings`= 同時給 REGULAR 與 FORCEONLINECHANGE) | `Get-TcSystemState` 需為 Run;`Build-TcProject` 成功;關 dialog |
| `ADS_CONNECT_FAILED` | ADS client 連不上 | 確認 AmsNetId / route;`Get-TcSystemState` |
| `ADS_ASSEMBLY_NOT_FOUND` | 找不到 TwinCAT.Ads.dll | 確認 TwinCAT XAE 安裝;`Connect-TcAds` 的 `data.adsBackend` 看用了哪個 DLL |
| `TYPE_MISMATCH` | `Write-TcVariable` 值型別與 symbol 不符 | `Get-TcSymbols` 看 type,轉型後再寫 |
| `ACTIVATION_FAILED` | ActivateConfiguration COM 失敗:專案有錯、target 沒 license、或 dialog | Build 成功、IDE 無 dialog 後重跑;看 `data.steps[]` 停在哪一步 |

## 環境

| IDE | ProgID | 備註 |
|---|---|---|
| 32-bit XAE Shell | `TcXaeShell.DTE.15.0` | TwinCAT 4024 |
| 64-bit XAE Shell | `TcXaeShell.DTE.17.0` | TwinCAT 4026 |
| VS2022 + TwinCAT 整合 | `VisualStudio.DTE.17.0` | TwinCAT 4026(與 64-bit XAE Shell 同一套 XAE;需本機已有 VS2022) |

- 版本對應:32-bit XAE Shell(`TcXaeShell.DTE.15.0`)= **TwinCAT 4024**;64-bit XAE Shell(`TcXaeShell.DTE.17.0`)與 VS2022(`VisualStudio.DTE.17.0`)= 4026,後兩者是同一套 XAE。Runtime:本機只有一個 UmRT_Default,三種 IDE 共用;UmRT 本身沒有版本,它是本機安裝的 TwinCAT runtime 跑在 user mode(`TcSystemServiceUm.exe` 檔案版本 3.1.4026.21 只是識別用;`TCATSysSrv` 4026.22)。 ADS DLL 在 4024 為 TwinCAT 安裝目錄下的 TwinCAT.Ads.dll,4026 為 package 內的版本(`Connect-TcAds` 的 `data.adsBackend` 會顯示實際載入的)。
- Automation Interface(ITcSysManager、EnvDTE)三者相同;差別只在 IDE 抓取(ProgID)與 ADS DLL。
- `Connect-TcIde` 嘗試順序:`TcXaeShell.DTE.15.0` → `TcXaeShell.DTE.17.0` → `VisualStudio.DTE.17.0`;指定 `-ProgId` 可鎖定。自行啟動 IDE 時會輪詢到 DTE 就緒(最長 60 s)才返回,失敗會回收孤兒程序並回 `IDE_LAUNCH_FAILED`;`data.ideProcessId` 是連上的 IDE pid。
- `Enable-TcConfig -Force` 在 UmRT 上第一次需要 license 齊全(trial 要涵蓋專案用到的 TF),否則系統停在 Config 直到 `SYSTEM_STATE_TIMEOUT`。
- 換 target(本機 UmRT ↔ 遠端 CX、或換 IDE)後要重新 `Connect-TcIde`,AmsNetId 會變。

### 已知 modal dialog

這些視窗會讓 DTE 呼叫無限阻塞;模組只偵測(`IDE_MODAL_DIALOG`)不自動關閉。

| 視窗 | 何時出現 | 解法 |
|---|---|---|
| `Assertion Failed: Abort=Quit, Retry=Debug, Ignore=Continue` | Build 時 CODESYS 優化器處理 visu 元素的內部錯誤(NullReference / DivideByZero),**間歇性**:反覆開關 solution 後、或全新專案第一次全編譯都可能出;Clean 無效,清 `_CompileInfo` 也不保證 | 這個 modal 會讓 DTE 呼叫無限阻塞,只能 `Stop-Process` 該 IDE,重開 solution 再 Build(通常第二次就過)。Build 前 `Get-TcIdeModalDialog` 會偵測到並回 `IDE_MODAL_DIALOG` |
| Microsoft Visual Studio 帳戶設定 | VS2022 未登入時 | 登入一次,或手動關閉視窗 |
| `Target system reports a fatal error` | Activate 的設定在 target 上無法啟動 | 看 XAE Output / Error List;UmRT 多半是 license 或 I/O 設定問題 |
| Trial license security code | 7 天 trial 到期或首次啟用 | 需人工輸入驗證碼,模組無法代勞 |
| `File has been changed outside the environment. Reload the new file?`(VS2022 寫法 `... changed outside the source editor. Do you want to reload it?`) | 開在編輯器裡的檔案(.TcPOU 等)被磁碟上的工具(AI 編輯器、git checkout、產生器)改了,約 1 s 後出現;VS 選項 `AutoloadExternalChanges` 壓不掉。沒開在編輯器的檔案 XAE 約 5 s 內自動重載、不跳框(2026-10-20 `reload-experiment.ps1`) | `Get-TcIdeModalDialog` 回 `Kind = reload-prompt`(結果 `data.dialogKind`),hint 指向 `Reset-TcSolution`,它會對這個提示送 WM_CLOSE、`Documents.CloseAll`、`Solution.Close`、同一個 IDE `Solution.Open`、`Connect-TcIde` 重連(約 20~25 s);之後改磁碟後立刻 `Reset-TcSolution` 即可。見「磁碟改檔的正確做法」 |
| `Application 'Port_851' does not exist on device ... create it and proceed with download?` | 空 runtime 上 Login 時全域 `SilentMode` 沒開(例如沒經 `Connect-TcIde` 連線) | `Connect-TcIde` 連上就開 `ITcAutomationSettings.SilentMode`,XAE 自動答 Yes,不應再出現;手動點 Yes 即可。**不要**改用旗標 SILENT(257)壓框:它會跳過建 app,851 仍 Invalid |
| `Login aborted: Conflicting flag settings` | Login 旗標 3(REGULAR\|FORCEONLINECHANGE 互斥) | 不要用 3;用 `-LoginMode Regular\|Download\|OnlineChange`(1/4/2,不 OR SILENT) |

### 驗證紀錄 2026-10-18

環境:32-bit XAE 4024 + 本機 UmRT_Default(199.5.42.250.1.1)。

2026-10-19:空 UmRT(沒有 application)情況下,`Enable-TcConfig -Force` 以 `Login(REGULAR)`(=1)+ 全域 `SilentMode` 建立 app 並下載(26 s),lifecycle-smoke 37/37;`-NoLogin` 後直接 `Set-TcPlcState Run` 正確回 `PLC_NOT_LOADED`。同日 23:27 對照:`Login(257)`(REGULAR|SILENT)0.5 s 返回但不建 app、851 仍 Invalid;`Login(260)`(FORCEDOWNLOAD|SILENT)下載 28 s 成功,但下一輪 `ActivateConfiguration()` 耗 250 s 後失敗,實為 32-bit XAE OutOfMemory crash(Visu 引擎,事件 1026),與旗標無關;`Login(3)` 旗標互斥 abort。

| 組 | 專案 | IDE | 結果 |
|---|---|---|---|
| A | 4024.71 專案 | 32-bit XAE Shell(`TcXaeShell.DTE.15.0`) | 完整 lifecycle 通過(Connect → Build → Enable-TcConfig -Force → Connect-TcAds → 讀寫 → Logout) |
| B | 4026.24 Robust 專案 | VS2022(`VisualStudio.DTE.17.0`) | Activate 後 target 回 `Target system reports a fatal error`,未通過(原因待查) |

## 重要注意

1. **AmsNetId 是動態的**:不要寫死,從 `Connect-TcIde` 的 `data.amsNetId` 或 `Connect-TcAds` 自動偵測取得。
2. **Lifecycle 順序**:Build → `Enable-TcConfig -Force`(含 Login + PLC Run)→ `Connect-TcAds` → Read/Write/Test。port 851 只在 download 後存在。
3. **Activate 後不要重連 IDE**:原 COM 參考在 TwinCAT XAR 重啟後仍有效;ADS 則會自動重連(看 `reconnected`)。
4. **測 FB 時寫 MAIN 層級變數**:PLC 每個 scan 都會覆寫 FB 的 `VAR_INPUT`,ADS 寫進去馬上被蓋掉;在 MAIN 宣告獨立變數餵給 FB。
5. **`Get/Write-TcPouCode` 用 `-PouPath`**:格式 `TIPC^<PlcName>^<PlcName> Project^POUs^<PouName>`。
6. **UmRT 假 Run**:本機 UmRT 跑約 30 分鐘後 task 可能停止循環但 ADS 仍顯示 Run;驗證時讀 `TwinCAT_SystemInfoVarList._TaskInfo[1].CycleCount` 兩次,沒動就是停了,重啟 `TcSystemServiceUm` 後重做 `Enable-TcConfig -Force`。
7. **UmRT 不要 Reset**:對 UmRT 送 `Set-TcPlcState -State Reset` 會直接結束 `TcSystemServiceUm`,要手動重啟 service;要清狀態改用 Stop → `Enter-TcPlcOnline` 重新 download。
8. **Build 失敗看 `data.errorItems`**:`Build-TcProject` 會用 UI Automation 讀 XAE Error List(`Get-TcBuildErrors`),每筆有 description/file/line;`code`(Cxxxx)是由描述推得,Error List 本身沒有 Code 欄,可能為 null。Build 成功時 `errorItems` 仍可能列出非 PLC code 的項目(例如 Library Manager 的「Could not open library '#System_VisuElem…'」placeholder 錯誤),看 `file` 分辨。注意 XAE 在 Build 前會自動存檔(Save all before build),`Write-TcPouCode` 後 Build 會寫到磁碟。不要盲目重跑 Build。
9. **重新 download 後 index offset 會變**:不要快取 symbol 的 indexGroup/indexOffset;懷疑錯位時比對 `TwinCAT_SystemInfoVarList._AppInfo.AppTimestamp`。
10. **`error.hint` 有就照做**:它是模組對該 code 的建議下一步。
11. **直接改磁碟上的 .TcPOU / .plcproj 時**(不經 `Write-TcPouCode`):該檔**沒開**在 XAE 編輯器 → XAE 約 5 s 內自動重載、不跳框,改完等 5 s 再呼叫 DTE;該檔**開著** → 約 1 s 後跳 modal「File has been changed outside the environment. Reload the new file?」,所有 DTE 呼叫阻塞、VS 選項壓不掉,所以改完**立刻** `Reset-TcSolution`:它會先關掉這個提示(WM_CLOSE,`data.dismissedReloadPrompt`)、`Documents.CloseAll`(不存檔,`data.closedDocuments`;XAE 重開 solution 時會還原上次的編輯視窗,不關的話下次改磁碟又跳)、`Solution.Close`、在**同一個** IDE `Solution.Open` 再 `Connect-TcIde -SolutionPath`(solution-match 接回同 pid,`data.sameIde`),實測約 20~25 s。其他種類的 modal 它只回 `IDE_MODAL_DIALOG`。`Write-TcPouCode` 走 COM 寫進 IDE 的編輯 buffer(磁碟檔案的 mtime/hash **不變**,要到存檔或 Build 的 Save all 才落地),不會跳框,能用就優先用它;要讓磁碟同步就接著 `Build-TcProject`。
