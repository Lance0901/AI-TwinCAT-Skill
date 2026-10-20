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

同一個模組也可以當 TcAuto MCP server 用(`mcp-server/`,stdio),不必在 shell 裡 `Import-Module`:每個 cmdlet 都是一個 MCP tool,tool 名 = CLI action 名(`ConnectIde`、`BuildProject`、`EnableConfig`、`ReadVariable`…,參數與 cmdlet 相同、以 JSON 傳),另加 4 個複合 tool:`RunLifecycle`(Connect→[SetTarget]→Build→Enable→ConnectAds 一鍵;`Platform` 選填:EnableConfig 會依 target 的 TARGETINFO 自動對齊 solution platform,target 不支援 TARGETINFO(ADS 0x702,例如這台的 UmRT)時要帶 `Platform="TwinCAT OS (x64)"`;`SetTarget` 有 `Platform` / `Configuration` / `NoPlatformSwitch`,`EnableConfig` 有 `Platform` / `NoPlatformFix`)、`QuickRead`(未連 ADS 時自動連再讀)、`GetStatus`(IDE/系統/PLC 狀態快照)、`GetIdeModalDialog`(偵測卡住 XAE 的 modal)。When the `tcauto` MCP tools are available in the session, prefer them over Import-Module; they keep the IDE/ADS connection across calls. IDE COM 參考與 ADS 連線在呼叫之間保留,錯誤碼與 `error.hint` 和本頁相同;server 另加的 `BRIDGE_TIMEOUT` 代表 PowerShell 子程序被重啟、狀態全失,要重新 `ConnectIde`;`BRIDGE_DIED` 是 PowerShell 子程序自己結束(下一次呼叫會自動重啟,同樣要重新 `ConnectIde`;訊息含 "not executed; safe to retry" 的表示該呼叫根本沒送進 PowerShell,可直接重試);`MODULE_IMPORT_FAILED` 是 `powershell.exe` 起不來或 `Import-Module` 失敗(檢查 `TWINCAT_MODULE_PATH` / `TWINCAT_MCP_POWERSHELL`,每次呼叫都會回這個碼直到修好)。設定與完整 tool 表見 `docs/setup-mcp.md` 與 `mcp-server/README.md`;手動端到端腳本 `mcp-server/scripts/lifecycle-client.mjs`(用法見檔頭)。

## Full Lifecycle(零 dialog、零 Start-Sleep)

```powershell
# 1. 連 IDE + 開 solution(多實例時依 -SolutionPath 挑;data.candidates[] 列出全部)
$r = Connect-TcIde -SolutionPath "C:\Projects\MyProject.sln"

# 1b. 4026 XAE:solution platform 要等於 target platform,UmRT(Usermode Runtime)是 'TwinCAT OS (x64)'
#     (Connect-TcIde 的 data.solutionPlatform 看現在是哪個;4024 不需要)。Set-TcTarget 不帶 -Platform 時讀 target 的
#     TARGETINFO 自動切;這台的 UmRT / XAR 回 ADS 0x702(不支援)→ PLATFORM_UNKNOWN,所以帶 -Platform:
Set-TcTarget -AmsNetId <Connect-TcIde 回的 data.amsNetId> -Platform 'TwinCAT OS (x64)'
#     (或 Enable-TcConfig -Force -Platform 'TwinCAT OS (x64)':Activate 前比對,不一致就切換 + 重新 Build)

# 2. Build(失敗回 BUILD_FAILED,逾時回 BUILD_TIMEOUT;data.errorItems[] 是 Error List 的錯誤明細:code/description/file/line)
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
| `ACTIVATE_FAILED` | `ActivateConfiguration()` 返回後讀 `SolutionBuild.LastBuildInfo`,> 0 = XAE 的 Check config failed(target 上什麼都沒寫,多半 solution platform 與 target platform 不符),`-Force` 流程停在 activate 那一步;hint 給 `Set-TcTarget -Platform` 指令 |
| `-NoLogin` | 跳過 download / PLC Run;只等 851 最多 10 秒(有 boot project 才會出現),沒有也不算失敗(step detail `skipped (no PLC port, -NoLogin)`)。之後依下方手動順序 |
| `-TimeoutSec` | 整個流程的總上限(單一 deadline),預設 120;每步等待用剩餘時間,超過 deadline 還沒開始的步驟回 `CYCLE_TIMEOUT` |
| data | `steps[]`(每步結果)、`plcState`、`loggedIn`、`solutionPlatform`、`reconnected`(之前有 ADS 連線時自動重連;PLC Run 時已自動重連則 reconnect 步驟記 `already reconnected in step 6`) |
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
| `Connect-TcIde [-SolutionPath <sln>] [-ProgId <id>] [-NoLaunch]` | 連 IDE(ROT 列舉全部實例);給 -SolutionPath 只接已開該 sln 的實例(`selectedBy=solution-match`),否則啟動新實例(`launched`),不會拿別人的空 IDE 來開;回 `amsNetId`、`ideProcessId`、`ownedBySession`(本 session 啟動的 IDE,`-Kill` 允許)、`candidates[]`、`connectSec`(總耗時)、`launchSec`(只在 launched:啟動到 DTE 可用)、`solutionPlatform` / `solutionConfiguration`(active solution platform / configuration);連上後會開啟 `ITcAutomationSettings.SilentMode`,`data.silentMode` 回報結果 |
| `Disconnect-TcIde [-Quit] [-Kill]` | 釋放 IDE COM 參考。`-Quit`:先查 modal(有就直接回 `IDE_QUIT_FAILED`,`data.dialog`、`data.quit=false`、`disconnected=false`,不白等 60 s,**連線原封保留**:reload-prompt 就 `Reset-TcSolution` 再 `-Quit`;其他用 `-Quit -Kill` 或 `Stop-Process`),再 `Solution.Close`(不存檔)+ `DTE.Quit`;quit 失敗也回 `IDE_QUIT_FAILED`(`success:false`,`data.ideProcessId` / `quitError`,IDE 還活著)。失敗時模組保留 pid / `selectedBy`,可直接接 `-Quit -Kill`,不用重連。`-Quit -Kill`:quit 不了(modal 或 DTE.Quit 失敗)就 `Stop-Process -Force` 該 IDE 並等它消失(≤10 s,`data.killed=true`;kill 前確認 pid 仍是 TcXaeShell / devenv 且啟動時間相符,否則視為過期 pid、不殺;pid 已不存在回 `alreadyExited=true`);只限本 session 啟動的 IDE(`data.ownedBySession=true`;`Reset-TcSolution` 內部重連後 `selectedBy` 變 solution-match 也照樣允許),否則回 `IDE_NOT_OWNED` 不殺。`-Kill` 不帶 `-Quit` 回 `INVALID_PARAMS` |
| `Reset-TcSolution [-SolutionPath <sln>] [-TimeoutSec 120]` | 關掉 reload 提示(若正在跳)→ `Documents.CloseAll`(不存檔)→ `Solution.Close` → 同一個 IDE `Solution.Open` → `Connect-TcIde -SolutionPath` 重連(實測約 20~25 s:Open 7~9 s + 重連 12~13 s),讓 XAE 重新從磁碟載入所有專案檔。磁碟直接改 .TcPOU 且該檔開在編輯器時用(見「重要注意」11)。.plcproj 被改寫時 XAE 跳「The project file ... has been modified outside of TwinCAT XAE. Do you want to reload the project?」(`reloadTarget=project`):它按 **Yes**(Win32 框用 control id 6,VS2022 WPF 框用 UIA Invoke `YesButton`;語系無關),XAE 自己 reload 專案,只重連 + 探測 `LookupTreeItem('TIPC')`、不 close/reopen(`data.answeredYes=true`、`reopenedSolution=false`),失敗才退回完整流程;其他 modal 會回 `IDE_MODAL_DIALOG`;data 有 `dismissedReloadPrompt`、`reloadTarget`、`answeredYes`、`reopenedSolution`、`ownedBySession`、`closedDocuments`、`sameIde`、`closeSec`、`openSec`、`connectSec`、`totalSec` |
| `Get-TcIdeInfo` | IDE 版本、solution 路徑、連線狀態、`solutionPlatform` / `solutionConfiguration` |
| `New-TcProject -Name <n> [-Path <dir>]` | 建新 solution + PLC 專案 + MAIN |
| `Open-TcProject -Path <sln>` | 開既有 solution |
| `Get-TcProjectTree [-Depth 4] [-PlcOnly]` | 專案樹 JSON;含 `<Plc> Project` 下 POUs/DUTs/GVLs,節點 `path` 可直接當 `-PouPath`;`-PlcOnly` 只回 TIPC 子樹 |
| `Add-TcPou -Name <n> -Type <Program\|FunctionBlock\|Function> [-ReturnType <t>]` | 新增 POU |
| `Add-TcGvl -Name <n> [-Variables @{var=type}]` | 新增 GVL |
| `Add-TcDut -Name <n> -DutType <Struct\|Enum\|Alias\|Union>` | 新增 DUT |
| `Add-TcLibrary -Name <lib>` | 加 library 參考 |
| `Get-TcPouCode -PouName <n> [-PouPath <treePath>]` | 讀 POU declaration + implementation;省略 `-PouPath` 會自動找(`data.pouPath`/`resolvedBy`),找不到回 `POU_NOT_FOUND` |
| `Write-TcPouCode -PouName <n> [-PouPath <treePath>] [-Declaration <st>] [-Implementation <st>]` | 寫 POU 程式碼;省略 `-PouPath` 會自動找(同 Get),找不到回 `POU_NOT_FOUND` |
| `Invoke-TcIoScan` | 掃 EtherCAT 裝置 |
| `Get-TcIoTree` | I/O 裝置樹 |
| `Set-TcVariableLink -Variable <v> -Channel <c>` | PLC 變數連 I/O channel |
| `Build-TcProject [-TimeoutSec 600]` | Build(COM busy 自動重試):`Build($false)` + 輪詢 `BuildState`(VS2022 的 `Build($true)` 不返回),逾時回 `BUILD_TIMEOUT`,輪詢中跳出 modal 回 `IDE_MODAL_DIALOG`;data:`errors`(Error List 錯誤數)、`failedProjects`(LastBuildInfo)、`errorItems[]`(severity/code/description/project/file/line/column)、`buildSec` |
| `Get-TcBuildErrors [-IncludeWarnings:$false] [-IncludeMessages] [-TimeoutSec 30]` | 用 UI Automation 讀 XAE Error List:`counts{errors,warnings,messages}`、`errors[]`、`warnings[]`(`-IncludeWarnings` 預設開,`:$false` 省 1~2 s 的 toggle)、`-IncludeMessages` → `messages[]`、`truncated`;按鈕計數也認 zh-TW 的「N 個錯誤/個警告/則訊息」與 VS2022 的 `0 / 2 錯誤`(取總數);視窗名 `Error List` 或 `錯誤清單`(zh-TW VS2022 可用),VS2022 的 scope 會先切到 `整個方案`;`code` 由描述推得(Error List 沒有 Code 欄),可能為 null |
| `Set-TcTarget -AmsNetId <id> [-Platform <name>] [-Configuration Release] [-NoPlatformSwitch]` | 先設 target NetId(`data.targetSet = true`,錯誤結果也一樣),再讓 solution platform 跟 target:`-Platform` → 啟用它(`platformCheck = parameter`);沒給 → 讀 target 的 TARGETINFO(port 200 IG 0x700,[InfoSys](https://infosys.beckhoff.com/content/1033/tc170x_tc3_usermode_runtime/11687997963.html))讀得到就切過去(`target`),讀不到 → `PLATFORM_UNKNOWN`(不猜;`unknown`);`-NoPlatformSwitch` 只設 NetId(`disabled`)。比對依每個 SolutionConfiguration 第一個 SolutionContexts 項目的 platform,`SolutionConfiguration.Activate()` 後讀回驗證。4026 XAE 的 solution platform 必須等於 target platform,否則 Activate 靜默失敗:UmRT / TwinCAT/BSD = `'TwinCAT OS (x64)'`,Windows RT target = `'TwinCAT RT (x64)'`。data:`amsNetId`、`targetSet`、`platformCheck`、`targetPlatform`、`targetPlatformSource`(`adsTargetInfo` / `unavailable`)、`adsError`、`platform`、`platformChanged`,有切換時加 `configuration`、`previousPlatform`、`availablePlatforms`;錯誤 `PLATFORM_UNKNOWN`、`PLATFORM_NOT_FOUND`(hint 列可用的)、`PLATFORM_SET_FAILED` |
| `Enable-TcConfig [-Force] [-NoLogin] [-TimeoutSec <n>] [-Platform <name>] [-NoPlatformFix]` | Activate;-Force = 完整 Config→Run→Login→PLC Run,-TimeoutSec 為總上限。Activate 前先比對 solution platform 與 target platform(TARGETINFO;讀不到用 `-Platform`):不一致就切換 + `Build-TcProject`(steps `platform-fix` / `platform-fix-build`,`data.platformFixed = true`,不算進 -TimeoutSec);`-NoPlatformFix` 改回 `PLATFORM_MISMATCH`;兩者都沒有 → `platformCheck = skipped` + warning(`data.warning`),照舊 Activate。data 一律有 `targetPlatform`、`targetPlatformSource`、`solutionPlatform`、`platformFixed`、`platformCheck`。Check config 失敗回 `ACTIVATE_FAILED`(見下) |
| `Send-TcPlcProgram` | 上傳程式到 PLC(不 login) |
| `Connect-TcAds [-AmsNetId <id>] [-Port 851]` | 連 ADS;data 有 `adsBackend` |
| `Disconnect-TcAds` | 斷 ADS |
| `Read-TcVariable -Path <sym>` | 讀變數(自動重連);`value` 依型別轉換,TIME/DATE 類回 IEC 字面(`"T#6s"`)另附 `ms`/`ns`/`unix` 整數、enum 另回 `name`、STRUCT 回 byte 陣列加 `size`(見下「型別對照」) |
| `Write-TcVariable -Path <sym> -Value <v>` | 寫變數:BOOL、整數型、REAL/LREAL、STRING、TIME/LTIME/TOD/DATE/DT/LDT(IEC 字面 `T#6s`、`DT#2026-10-20-12:30:00`,整數 ms/ns/秒也收)、enum(整數或成員名);`data.written` 是實際寫入的轉換值(時間類回正規化字面,`T#6000ms` → `T#6s`);STRUCT/ARRAY 回 `TYPE_MISMATCH`(自動重連) |
| `Watch-TcVariable -Path <sym>[,<sym>] [-IntervalMs 100] [-DurationMs 2000] [-Until "<Path> <op> <value>"] [-UntilTimeoutMs 5000] [-KeepLast <n>]` | 輪詢(自動重連)。`-Until` 字串條件,op 為 `== != > < >= <=`,`<Path>` 必須在 -Path 內,例 `-Until "MAIN.fTarget == 123.5"`:命中立刻回 `untilMet=true`、`untilSample`、`elapsedMs`,逾時 `untilMet=false`;數字比數值、TRUE/FALSE 比布林、其餘不分大小寫比字串。`samples` 只留最後 `-KeepLast` 筆(預設有 Until 20、無 50),`sampleCount` 是總數、`truncated` 表示有丟;單一 path 的 sample 與 Read 同樣轉換(含 `ms`/`ns`/`unix`/`name`),條件值是數字時用該整數比、文字時用 IEC 字面或 enum 成員名比;多個 -Path 時 sample 是 `{timestamp, values{path=value}}` |
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
| `IDE_MODAL_DIALOG` | XAE/VS 有 modal 視窗(Assertion Failed、VS 帳戶設定、Target system reports a fatal error、trial license security code…)。這類視窗讓 DTE 呼叫**無限阻塞**(不是回 0x80010001),模組在 Build / Activate / Login / Solution.Open 前用 UI Automation 先檢查,有就直接回這個 code,`data.dialogTitle` / `dialogText` 是視窗內容 | 手動關閉 dialog 後重跑同一個 cmdlet;關不掉就 kill IDE(`Stop-Process -Id <data.ideProcessId>`)後重新 `Connect-TcIde`。模組不會自動關任何視窗;**已經被 modal 卡住的呼叫無法中斷**(見「已知 modal dialog」)。`data.dialogKind` = `reload-prompt`(「File has been changed outside the environment」或 .plcproj 的「modified outside of TwinCAT XAE. Do you want to reload the project?」,磁碟改檔觸發;`data.dialogReloadTarget` = `file` / `project`)時:直接 `Reset-TcSolution`,project 提示它按 Yes、檔案提示它關掉並重開 solution,見「重要注意」11。不知道是哪種就先 `Get-TcIdeModalDialog` 看 `Kind` |
| `IDE_QUIT_FAILED` | `Disconnect-TcIde -Quit` 沒關掉 IDE(被 modal 擋住時 `data.dialog` 有內容、quit 沒嘗試、連線保留 `disconnected=false`;或 DTE.Quit 失敗,`data.quitError`);以前這裡回 `success:true`,下一個 `Connect-TcIde` 會黏回同一個卡住的 IDE | reload 提示 → `Reset-TcSolution` 再 `Disconnect-TcIde -Quit`;其他 → 本 session 啟動的 IDE(`data.ownedBySession=true`)直接接 `Disconnect-TcIde -Quit -Kill`(不用重連,pid 有保留);否則手動 `Stop-Process -Id <data.ideProcessId>` |
| `IDE_NOT_OWNED` | `Disconnect-TcIde -Quit -Kill` 但 IDE 不是本 session 啟動的(`data.ownedBySession=false`),模組不殺使用者自己開的 IDE | 確定要關就自己 `Stop-Process -Id <data.ideProcessId>`,再重新 `Connect-TcIde` |
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
| `BUILD_TIMEOUT` | Build 在 `-TimeoutSec`(預設 600)內 `SolutionBuild.BuildState` 沒到 Done(3);VS2022 的 `Build($true)` 不返回,所以改輪詢。`data.buildState` / `buildSec` | `Get-TcIdeModalDialog` 檢查 dialog、看 XAE Output 的 build 進度;大型專案加大 `-TimeoutSec` 重跑;XAE 沒反應就 kill IDE 後重新 `Connect-TcIde` |
| `ERRORLIST_UNAVAILABLE` | `Get-TcBuildErrors` 的 UI Automation 找不到 Error List 視窗或逾時(視窗被 auto-hide / 關閉、IDE pid 未知、UIA 被 modal 卡住) | 確認 XAE 視窗可見、Error List 沒 auto-hide;手動 View > Error List 後重試;加大 `-TimeoutSec` |
| `PROJECT_OPEN_FAILED` | .sln 路徑錯、檔案損壞、或該 IDE 沒有 TwinCAT 整合 | 確認路徑;用對應版本的 ProgID(見「環境」) |
| `POU_NOT_FOUND` | POU 名稱或 `-PouPath` 在 `<Plc> Project` 下找不到;`error.hint` 列出 `<Plc> Project` 第一層子節點,`data.tried[]` 是試過的路徑 | `Get-TcProjectTree -PlcOnly` 查節點 `path` 後給 `-PouPath`;格式 `TIPC^<Plc>^<Plc> Project^POUs^<name>` |
| `POU_CREATE_FAILED` | 0x98510001 = .plcproj 列了檔案但磁碟缺檔 | 從 .plcproj 移除缺檔的 `<Compile Include>`,或補回檔案;重開 solution |
| `LOGOUT_FAILED` | Logoff COM 呼叫失敗:PLC 未 login、IDE busy、或 modal dialog。4026 上方法名是 **`Logoff()`**(不是 `Logout()`),`Exit-TcPlcOnline` 依序試 `TIPC^<Plc>` 節點與 `<Plc> Project` 節點的 Logoff/Logout,`data.logoutVia` 說明實際走哪條;舊版 `TIPC.Child(1).Object` 在 4026 永遠是 null,已不用 | `Get-TcPlcState` 確認;關 dialog 重試;重啟後直接重跑即可,不用重連 IDE |
| `NO_PROJECT` | 已連 IDE 但沒載入 TwinCAT 專案 | `Open-TcProject -Path <sln>` 或 `Connect-TcIde -SolutionPath <sln>` |
| `LOGIN_FAILED` | `Login(flags)` 失敗:系統在 Config、build 沒過、license dialog、或旗標互斥(`Conflicting flag settings`= 同時給 REGULAR 與 FORCEONLINECHANGE) | `Get-TcSystemState` 需為 Run;`Build-TcProject` 成功;關 dialog |
| `PLATFORM_UNKNOWN` | `Set-TcTarget` 沒給 `-Platform`,target 又不回 TARGETINFO(`data.adsError` 例 `0x702`;這台 UmRT `TcSystemServiceUm.exe` 3.1.0.2649 / TwinCAT 3.1.4026.21~22 與 Windows XAR 都是)。NetId **已經設好**(`data.targetSet = true`),solution platform 沒動 | 重跑帶 `-Platform '<平台>'`(UmRT / TwinCAT/BSD = `'TwinCAT OS (x64)'`);只換 NetId 用 `-NoPlatformSwitch` |
| `PLATFORM_MISMATCH` | `Enable-TcConfig -NoPlatformFix`:solution platform 與 target platform(或 `-Platform`)不同,Activate 前就停,什麼都沒 activate(`data.steps` 一筆 `platform-fix` ok=false) | `Set-TcTarget -AmsNetId <id> -Platform '<platform>'` 再 Build + Enable,或拿掉 `-NoPlatformFix` 讓它自己切換 + Build |
| `PLATFORM_NOT_FOUND` | `Set-TcTarget -Platform` 的名稱(或 target 回報 / `Enable-TcConfig -Platform` 的 platform)不在 solution 的 project-context platform 內(`data.availablePlatforms` / `availableConfigurations` 列出現有的)。4024 的 .sln 把 `TwinCAT OS (x64)` 對到 project platform `TwinCAT OS (ARMT2)`,對它要 OS (x64) 也是這個碼 | 用 `availablePlatforms` 的名稱重跑;UmRT = `'TwinCAT OS (x64)'`,Windows RT = `'TwinCAT RT (x64)'`;4024 專案要先在 Configuration Manager 新增真正的 `TwinCAT OS (x64)` project platform |
| `PLATFORM_SET_FAILED` | `SolutionConfiguration.Activate()` 後讀回的 active platform 不是要求的那個(未生效或有 dialog) | `Get-TcIdeInfo` 看 `solutionPlatform`;`Get-TcIdeModalDialog` 檢查 dialog;必要時在 XAE 工具列 Solution Platforms 下拉手動選再重跑 |
| `ADS_CONNECT_FAILED` | ADS client 連不上 | 確認 AmsNetId / route;`Get-TcSystemState` |
| `ADS_ASSEMBLY_NOT_FOUND` | 找不到 TwinCAT.Ads.dll | 確認 TwinCAT XAE 安裝;`Connect-TcAds` 的 `data.adsBackend` 看用了哪個 DLL |
| `TYPE_MISMATCH` | `Write-TcVariable` 值型別與 symbol 不符 | `Get-TcSymbols` 看 type,轉型後再寫 |
| `ACTIVATION_FAILED` | ActivateConfiguration COM 失敗(丟例外):專案有錯、target 沒 license、或 dialog | Build 成功、IDE 無 dialog 後重跑;看 `data.steps[]` 停在哪一步 |
| `ACTIVATE_FAILED` | `ActivateConfiguration()` 約 2 s 無例外返回,但 `SolutionBuild.LastBuildInfo > 0`:XAE 的「Check config failed!」(Output 視窗),target 上什麼都沒寫,851 維持 Invalid。最常見:4026 XAE 的 active solution platform 與 target platform 不一致(UmRT 是 `TwinCAT OS (x64)`,solution 卻是 `TwinCAT RT (x64)`);platform 由 XAE 載入 solution 時依 .tsproj 的 target 決定,`SetTargetNetId` 不會事後改。`Enable-TcConfig` 會先比對,但 target 不支援 TARGETINFO 又沒給 `-Platform` 時只能跳過(`platformCheck = skipped`,`data.warning`)。`data.solutionPlatform` 是當時的 platform | `Enable-TcConfig -Force -Platform 'TwinCAT OS (x64)'`(自己切換 + Build),或 `Set-TcTarget -AmsNetId <id> -Platform 'TwinCAT OS (x64)'`(Windows RT target 用 `'TwinCAT RT (x64)'`)再 `Build-TcProject` + `Enable-TcConfig -Force`;MCP:`RunLifecycle` / `SetTarget` / `EnableConfig` 的 `Platform`。4024 專案(project platform `TwinCAT OS (ARMT2)`)不會得到這個碼,只會 851 Invalid(`PLC_NOT_LOADED`) |

## 環境

| IDE | ProgID | 備註 |
|---|---|---|
| 32-bit XAE Shell | `TcXaeShell.DTE.15.0` | TwinCAT 4024 |
| 64-bit XAE Shell | `TcXaeShell.DTE.17.0` | TwinCAT 4026 |
| VS2022 + TwinCAT 整合 | `VisualStudio.DTE.17.0` | TwinCAT 4026(與 64-bit XAE Shell 同一套 XAE;需本機已有 VS2022) |

- 版本對應:32-bit XAE Shell(`TcXaeShell.DTE.15.0`)= **TwinCAT 4024**;64-bit XAE Shell(`TcXaeShell.DTE.17.0`)與 VS2022(`VisualStudio.DTE.17.0`)= 4026,後兩者是同一套 XAE。Runtime:本機只有一個 UmRT_Default,三種 IDE 共用;UmRT 本身沒有版本,它是本機安裝的 TwinCAT runtime 跑在 user mode(Usermode Runtime;`TcSystemServiceUm.exe` FileVersion 3.1.0.2649 / ProductVersion 3.1.4026.21 只是識別用;`TCATSysSrv` 4026.22)。這個 runtime 對 TARGETINFO(port 200 IG 0x700,InfoSys TC1700/TC170x 手冊 v1.6.1 2026-08 才有這一條,最低支援 build 未確認)回 ADS 0x702,Run 狀態也一樣,所以 platform 自動對齊在這台不會發生,要帶 `-Platform`。 ADS DLL 在 4024 為 TwinCAT 安裝目錄下的 TwinCAT.Ads.dll,4026 為 package 內的版本(`Connect-TcAds` 的 `data.adsBackend` 會顯示實際載入的)。
- Automation Interface(ITcSysManager、EnvDTE)三者相同;差別只在 IDE 抓取(ProgID)與 ADS DLL。
- 4026 vs 4024:相同 — PLC 樹路徑 `TIPC^<plc>^<plc> Project^POUs`(例 `TIPC^Untitled1^Untitled1 Project`)、`Login(1)` + `SilentMode`、ADS DLL(GAC `TwinCAT.Ads.dll` 4.3.32.0)、三個 host 的 XAE Base extension 都 3.1.4026.22。不同 — (1) 4026 在 Activate 檢查 solution platform 與 target platform(4024 不檢查),本機 UmRT 要 `TwinCAT OS (x64)`;(2) VS2022 的 `Build($true)` 不返回(模組用 `Build($false)` + 輪詢);(3) VS2022 訊息框是 WPF;(4) zh-TW VS2022 的 Error List 名 `錯誤清單`、預設 scope `目前專案`(模組切到 `整個方案`)。
- 4024 專案在 4026 XAE:4024 .sln 把 `Release|TwinCAT OS (x64)` 對到 project platform `TwinCAT OS (ARMT2)` 且沒有 Build.0 → 選 OS (x64) 什麼都不 build;XAE 自動選 ARMT2,Build 1.4 s「成功」、Activate 無 `ACTIVATE_FAILED`、851 維持 Invalid(`PLC_NOT_LOADED`)。需先在 Configuration Manager 新增真正的 `TwinCAT OS (x64)` project platform;`Set-TcTarget -Platform` 列的是 project-context platform,對這種 sln 回 `PLATFORM_NOT_FOUND`。已知限制,不是工具能補的。
- VS2022 時間參考:`Connect-TcIde` 自啟 1.5~2.3 s、含開 solution 25~63 s;solution-match 重連 1~1.5 s;`Reset-TcSolution` 8~11 s。
- `Connect-TcIde` 嘗試順序:`TcXaeShell.DTE.15.0` → `TcXaeShell.DTE.17.0` → `VisualStudio.DTE.17.0`;指定 `-ProgId` 可鎖定。自行啟動 IDE 時會輪詢到 DTE 就緒(最長 60 s)才返回,失敗會回收孤兒程序並回 `IDE_LAUNCH_FAILED`;`data.ideProcessId` 是連上的 IDE pid。
- `Enable-TcConfig -Force` 在 UmRT 上第一次需要 license 齊全(trial 要涵蓋專案用到的 TF),否則系統停在 Config 直到 `SYSTEM_STATE_TIMEOUT`。
- 換 target(本機 UmRT ↔ 遠端 CX、或換 IDE)後要重新 `Connect-TcIde`,AmsNetId 會變;4026 XAE 另要對齊 solution platform(target 支援 TARGETINFO 時 `Set-TcTarget` / `Enable-TcConfig` 自動,否則 `-Platform`)。
- 已知未解:IDE 被 modal 擋住時 DTE `Version` 讀空字串,`Connect-TcIde` 當過期 ROT 項目,帶 `-SolutionPath` 會**另外啟動第二個 IDE**(VS2022 出現過一次)。重連前先 `Get-TcIdeModalDialog`。

### 已知 modal dialog

這些視窗會讓 DTE 呼叫無限阻塞;模組只偵測(`IDE_MODAL_DIALOG`)不自動關閉,唯一例外是 reload 提示(`Reset-TcSolution`)。中文 Windows 的訊息框(`#32770`)按鈕在 UIA 是 `Pane`、Name「是(Y)」「否(N)」、AutomationId 6 / 7,不要用英文 "Yes" 或 `ControlType.Button` 去比對;模組(`Close-TcMessageBox`)對 Win32 框只認 control id(`GetDlgItem` + `BM_CLICK`)。**VS2022 的訊息框是 WPF**(AutomationId `Microsoft.VisualStudio.MessageBox`,內文在 AutomationId `Text`,按鈕是真的 `ControlType.Button`:`OKButton` / `YesButton` / `NoButton` / `CancelButton`,沒有 Win32 control id):`Get-TcIdeModalDialog` 回完整內文與 `Buttons[]`(含 `automationId`),`Close-TcMessageBox` 沒有 control id 時退到 UIA `InvokePattern.Invoke()`(`Method = UIA_INVOKE`)。

| 視窗 | 何時出現 | 解法 |
|---|---|---|
| `Assertion Failed: Abort=Quit, Retry=Debug, Ignore=Continue` | Build 時 CODESYS 優化器處理 visu 元素的內部錯誤(NullReference / DivideByZero),**間歇性**:反覆開關 solution 後、或全新專案第一次全編譯都可能出;Clean 無效,清 `_CompileInfo` 也不保證 | 這個 modal 會讓 DTE 呼叫無限阻塞,只能 `Stop-Process` 該 IDE,重開 solution 再 Build(通常第二次就過)。Build 前 `Get-TcIdeModalDialog` 會偵測到並回 `IDE_MODAL_DIALOG` |
| Microsoft Visual Studio 帳戶設定 | VS2022 未登入時 | 登入一次,或手動關閉視窗 |
| `Target system reports a fatal error` | Activate 的設定在 target 上無法啟動。2026-10-18 B 組那次的根因是 solution platform 錯(`TwinCAT RT (x64)` 對 UmRT),不是 license / isolated core / tsproj `TcVersion` / `TargetFeatures.xml` | 先 `Get-TcIdeInfo` 看 `solutionPlatform`,不對就 `Set-TcTarget -Platform`(見 `ACTIVATE_FAILED`);再看 XAE Output / Error List,其次才是 license 或 I/O 設定 |
| `Active solution platform 'TwinCAT RT (x64)' differs from current target platform 'TwinCAT OS (x64)'! Adjust solution platform and retry.`(WPF 框) | 4026 Activate 時 solution platform 與 target platform 不符。`SilentMode` 關著:框一直在、`ActivateConfiguration()` 阻塞到被關(實測 102 s);開著(預設):自動關框、約 2 s 返回,只剩 Output 的「Check config failed!」與 `LastBuildInfo > 0` | 模組回 `ACTIVATE_FAILED`;`Set-TcTarget -AmsNetId <id> -Platform 'TwinCAT OS (x64)'` 後重跑 Build + `Enable-TcConfig -Force` |
| Trial license security code | 7 天 trial 到期或首次啟用 | 需人工輸入驗證碼,模組無法代勞 |
| `File has been changed outside the environment. Reload the new file?`(VS2022 寫法 `... changed outside the source editor. Do you want to reload it?`) | 開在編輯器裡的檔案(.TcPOU 等)被磁碟上的工具(AI 編輯器、git checkout、產生器)改了,約 1 s 後出現;VS 選項 `AutoloadExternalChanges` 壓不掉。沒開在編輯器的檔案 XAE 約 5 s 內自動重載、不跳框(2026-10-20 `reload-experiment.ps1`) | `Get-TcIdeModalDialog` 回 `Kind = reload-prompt`(結果 `data.dialogKind`),hint 指向 `Reset-TcSolution`,它會對這個提示送 WM_CLOSE、`Documents.CloseAll`、`Solution.Close`、同一個 IDE `Solution.Open`、`Connect-TcIde` 重連(約 20~25 s);之後改磁碟後立刻 `Reset-TcSolution` 即可。見「磁碟改檔的正確做法」 |
| `The project file '...\plc.plcproj' has been modified outside of TwinCAT XAE. Do you want to reload the project?` | `.plcproj` 在磁碟上被改寫(產生器每次都重寫,內容相同也會跳) | `Get-TcIdeModalDialog` 回 `Kind = reload-prompt`、`ReloadTarget = project`;直接 `Reset-TcSolution`:按 Yes 讓 XAE 自己 reload 專案,只重連、不 close/reopen(`data.answeredYes`) |
| `Application 'Port_851' does not exist on device ... create it and proceed with download?` | 空 runtime 上 Login 時全域 `SilentMode` 沒開(例如沒經 `Connect-TcIde` 連線) | `Connect-TcIde` 連上就開 `ITcAutomationSettings.SilentMode`,XAE 自動答 Yes,不應再出現;手動點 Yes 即可。**不要**改用旗標 SILENT(257)壓框:它會跳過建 app,851 仍 Invalid |
| `Login aborted: Conflicting flag settings` | Login 旗標 3(REGULAR\|FORCEONLINECHANGE 互斥) | 不要用 3;用 `-LoginMode Regular\|Download\|OnlineChange`(1/4/2,不 OR SILENT) |

### 驗證紀錄 2026-10-18

環境:32-bit XAE 4024 + 本機 UmRT_Default(199.5.42.250.1.1)。

2026-10-19:空 UmRT(沒有 application)情況下,`Enable-TcConfig -Force` 以 `Login(REGULAR)`(=1)+ 全域 `SilentMode` 建立 app 並下載(26 s),lifecycle-smoke 37/37;`-NoLogin` 後直接 `Set-TcPlcState Run` 正確回 `PLC_NOT_LOADED`。同日 23:27 對照:`Login(257)`(REGULAR|SILENT)0.5 s 返回但不建 app、851 仍 Invalid;`Login(260)`(FORCEDOWNLOAD|SILENT)下載 28 s 成功,但下一輪 `ActivateConfiguration()` 耗 250 s 後失敗,實為 32-bit XAE OutOfMemory crash(Visu 引擎,事件 1026),與旗標無關;`Login(3)` 旗標互斥 abort。

| 組 | 專案 | IDE | 結果 |
|---|---|---|---|
| A | 4024.71 專案 | 32-bit XAE Shell(`TcXaeShell.DTE.15.0`) | 完整 lifecycle 通過(Connect → Build → Enable-TcConfig -Force → Connect-TcAds → 讀寫 → Logout) |
| B | 4026.24 Robust 專案 | VS2022(`VisualStudio.DTE.17.0`) | Activate 後 target 回 `Target system reports a fatal error`,未通過;**根因 = solution platform 錯**(見 `ACTIVATE_FAILED`),2026-10-20/21 以 `Set-TcTarget -Platform 'TwinCAT OS (x64)'` 解決 |

2026-10-20/21 B 組(4026.22 XAE,Robust 專案複本 `C:\Temp\RobustDemo-b`,PLC 專案 `Untitled1`,target 本機 UmRT 199.5.42.250.1.1;完整表見 `docs/troubleshooting.md`「B 組 2026-10-20/21」):

| Run | IDE / ProgId | 結果 |
|---|---|---|
| `lifecycle-smoke.ps1 -SolutionPlatform 'TwinCAT OS (x64)'`(log `tests/Integration/logs/B-vs2022.log`) | VS2022 zh-TW,`VisualStudio.DTE.17.0` | 35/35 PASS,77 s(Build 9.2 s、Enable -Force 8.4 s、無 dialog) |
| 同參數(`B-xae64.log`) | 64-bit XAE Shell `TcXaeShell.DTE.17.0` | 35/35 PASS(第 3 次跑;前兩次撞 UmRT crash #8 與 ADS 0x502 hang,皆 UmRT 側) |
| MCP `node mcp-server/scripts/lifecycle-client.mjs --expect-fail ACTIVATE_FAILED --fail-platform "TwinCAT RT (x64)" --platform "TwinCAT OS (x64)"` | VS2022 | 7/7 PASS(RT → `ACTIVATE_FAILED` 47 s;OS 14.4 s;CycleCount 319 → 420) |
| `multi-ide.ps1 -ProgId VisualStudio.DTE.17.0` | `VisualStudio.DTE.17.0` | 25/25 PASS(新啟動 target、不受別的 IDE 的 modal 影響、只關 target) |
| platform 切換(直接 PowerShell) | VS2022 | RT → `ACTIVATE_FAILED` 4.7 s;OS → Run 10.9 s;未知 platform → `PLATFORM_NOT_FOUND` |

## 重要注意

1. **AmsNetId 是動態的**:不要寫死,從 `Connect-TcIde` 的 `data.amsNetId` 或 `Connect-TcAds` 自動偵測取得。
2. **Lifecycle 順序**:Build → `Enable-TcConfig -Force`(含 Login + PLC Run)→ `Connect-TcAds` → Read/Write/Test。port 851 只在 download 後存在。
3. **Activate 後不要重連 IDE**:原 COM 參考在 TwinCAT XAR 重啟後仍有效;ADS 則會自動重連(看 `reconnected`)。
4. **測 FB 時寫 MAIN 層級變數**:PLC 每個 scan 都會覆寫 FB 的 `VAR_INPUT`,ADS 寫進去馬上被蓋掉;在 MAIN 宣告獨立變數餵給 FB。
5. **`Get/Write-TcPouCode` 的 `-PouPath` 可省略**:省略會自動找(`POUs` → project 根 → 遞迴搜尋),`data.pouPath`/`resolvedBy` 回報命中位置。4024 與 4026 格式相同:`TIPC^<PlcName>^<PlcName> Project^POUs^<PouName>`(DUT 在 `DUTs`、GVL 在 `GVLs`)。找不到看 `POU_NOT_FOUND` 的 hint 或 `Get-TcProjectTree -PlcOnly`。
6. **UmRT 假 Run / 0x502**:本機 UmRT 跑約 30 分鐘後 task 可能停止循環但 ADS 仍顯示 Run;驗證時讀 `TwinCAT_SystemInfoVarList._TaskInfo[1].CycleCount` 兩次,沒動就是停了,重啟 `TcSystemServiceUm` 後重做 `Enable-TcConfig -Force`。另有一種:UmRT process 活著、CPU idle,對該 target 的每個 ADS 呼叫都回 **0x502「Mailbox is full」**(本機 TcSysSrv 正常),`Enable-TcConfig` 等 180 s 回 `SYSTEM_STATE_TIMEOUT`(2026-10-21);處置同樣是 kill 並重啟 `TcSystemServiceUm` 後 `Enable-TcConfig -Force`。UmRT 也會 crash(`TcOsSys.dll` c0000005,issue #21),同樣重啟 service。
7. **UmRT 不要 Reset**:對 UmRT 送 `Set-TcPlcState -State Reset` 會直接結束 `TcSystemServiceUm`,要手動重啟 service;要清狀態改用 Stop → `Enter-TcPlcOnline` 重新 download。
8. **Build 失敗看 `data.errorItems`**:`Build-TcProject` 會用 UI Automation 讀 XAE Error List(`Get-TcBuildErrors`),每筆有 description/file/line;`code`(Cxxxx)是由描述推得,Error List 本身沒有 Code 欄,可能為 null。Build 成功時 `errorItems` 仍可能列出非 PLC code 的項目(例如 Library Manager 的「Could not open library '#System_VisuElem…'」placeholder 錯誤),看 `file` 分辨。Warning 也有內容:`data.warningItems[]`(同格式)與 `data.codeWarnings[]`(排除 Library Manager 項),`warnings` 計數不再只是數字。注意 XAE 在 Build 前會自動存檔(Save all before build),`Write-TcPouCode` 後 Build 會寫到磁碟。不要盲目重跑 Build。
9. **重新 download 後 index offset 會變**:不要快取 symbol 的 indexGroup/indexOffset;懷疑錯位時比對 `TwinCAT_SystemInfoVarList._AppInfo.AppTimestamp`。
10. **`error.hint` 有就照做**:它是模組對該 code 的建議下一步。經 MCP server 回傳時,hint 裡的 cmdlet 名已換成 tool 名(`Enter-TcPlcOnline` → `PlcLogin`、`Connect-TcIde -SolutionPath <sln>` → `ConnectIde SolutionPath=<sln>`)。
11. **直接改磁碟上的 .TcPOU / .plcproj 時**(不經 `Write-TcPouCode`):該檔**沒開**在 XAE 編輯器 → XAE 約 5 s 內自動重載、不跳框,改完等 5 s 再呼叫 DTE;該檔**開著** → 約 1 s 後跳 modal「File has been changed outside the environment. Reload the new file?」,所有 DTE 呼叫阻塞、VS 選項壓不掉,所以改完**立刻** `Reset-TcSolution`:它會先關掉這個提示(WM_CLOSE,`data.dismissedReloadPrompt`)、`Documents.CloseAll`(不存檔,`data.closedDocuments`;XAE 重開 solution 時會還原上次的編輯視窗,不關的話下次改磁碟又跳)、`Solution.Close`、在**同一個** IDE `Solution.Open` 再 `Connect-TcIde -SolutionPath`(solution-match 接回同 pid,`data.sameIde`),實測約 20~25 s。改寫 `.plcproj` 則跳「The project file ... has been modified outside of TwinCAT XAE. Do you want to reload the project?」(`reloadTarget = project`),同樣立刻 `Reset-TcSolution`:它對這個提示按 Yes(Win32 框依 control id、VS2022 WPF 框依 UIA Invoke,中文 UI 也行),XAE 自己 reload 專案,只重連不 close/reopen,比較快。其他種類的 modal 它只回 `IDE_MODAL_DIALOG`。`Write-TcPouCode` 走 COM 寫進 IDE 的編輯 buffer(磁碟檔案的 mtime/hash **不變**,要到存檔或 Build 的 Save all 才落地),不會跳框,能用就優先用它;要讓磁碟同步就接著 `Build-TcProject`。
12. **MCP 同回合平行送的 tool call 到達順序不保證**:server 嚴格依到達順序一次執行一個,每個結果的 `data.seq`(遞增)、`startedAt`、`finishedAt` 告訴你實際順序;「寫參數 → 下命令 → 觀察」要分回合,等值用 `WatchVariable` 的 `Until`,不要用長 `DurationMs` 或連發 `ReadVariable`。
13. **4026 XAE 先對齊 solution platform**:target 支援 TARGETINFO 時 `Set-TcTarget` / `Enable-TcConfig` 自動對齊;這台的 UmRT 不支援(0x702),要 `Set-TcTarget -AmsNetId <id> -Platform 'TwinCAT OS (x64)'` 或 `Enable-TcConfig -Force -Platform 'TwinCAT OS (x64)'`(MCP:`RunLifecycle` / `SetTarget` / `EnableConfig` 的 `Platform`),再 Build + `Enable-TcConfig -Force`;只想換 NetId 用 `Set-TcTarget -NoPlatformSwitch`(不帶時讀不到 platform 會回 `PLATFORM_UNKNOWN`);否則 `ACTIVATE_FAILED`(Check config failed,target 上什麼都沒寫)。XAE 載入 solution 時依 .tsproj 的 target 選 platform,`SetTargetNetId` 不改它;`Connect-TcIde` / `Get-TcIdeInfo` 的 `data.solutionPlatform` 看現在是哪個。4024 專案(project platform `TwinCAT OS (ARMT2)`)在 UmRT(4026 XAE)跑不起來,要先新增真正的 `TwinCAT OS (x64)` project platform。
