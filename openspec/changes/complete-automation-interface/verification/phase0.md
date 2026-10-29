# Phase 0 真機驗證紀錄(tasks 1.3、1.4、1.6、1.7、1.8)

合併自三份紀錄:1.3 / 1.4 / 1.6(2026-10-28)、1.7(2026-10-29)、1.8 複測(2026-10-29)。原始 log 在 `tests/Integration/logs/`(gitignore,不進 repo);這份是保存版。

---

# Part 1:1.3 / 1.4 / 1.6(2026-10-28)


### 1.3 IoScan / SetVariableLink(a7ef1ee)
| tool | 情境 | 結果 |
|---|---|---|
| IoScan | Run 模式 | `IO_SCAN_REQUIRES_CONFIG`,附 hint ✅ |
| IoScan | Config 模式、沒有裝置 | success、devices=[]、帶 warning ✅ |
| SetVariableLink | PLC 路徑錯 | `TREEITEM_NOT_FOUND`,missingEnd=PlcVariable ✅ |
| SetVariableLink / RemoveVariableLink | 成功路徑 | 只有自建 client 測過(subagent,離線 EK1100+EL1004)。registered 還沒測，要等第 1 期 CreateChild 才能建離線 I/O |
| SetSystemState | Config | success,這次沒 crash ✅ |
| EnableConfig Force | 回 Run | 9/9 ✅ |

### 1.4 AddLibrary(a603c59)
| 情境 | 結果 |
|---|---|
| Tc2_DataExchange | success,plcprojChanged=true ✅ |
| 不存在的 library | `LIBRARY_ADD_FAILED`,notInstalled=true ✅ |
| 重複加入 | success,alreadyPresent=true,plcprojChanged=false ✅ |
| 之後 BuildProject | completeBuild=true ✅ |
| 4024 | 只有自建 client 測過(subagent) |

### 1.6 未實測 tool(這次全部 ✅)
| tool | 結果 |
|---|---|
| GetIdeInfo | edition Community、platform 正確 |
| GetIdeModalDialog | dialog=null |
| OpenProject | 重開同一個 sln,約 6.8 s |
| CleanProject | cleanVerified=true |
| GetIoTree | TIID 底下沒有子節點 |
| GetSystemState | Run |
| ConnectAds / GetPlcState | Run |
| SetPlcState | Stop → Run |
| WatchVariable | 取樣，以及 Until(CycleCount > N),untilMet=true |
| PlcLogout | logoutVia=treeItem.Logoff |
| DisconnectAds | 之後 ReadVariable 回 NOT_CONNECTED,不會自動重連(符合說明) |
| SetSystemState | Run→Run 重啟,leftOriginal=true |
| SendPlcProgram | 程式碼沒改時：success,downloaded=false,AppTimestamp 不變。改程式碼但沒 Build:BUILD_REQUIRED。Build 之後:downloaded=true,AppTimestamp 從 23:06:02 變成 23:42:39,PLC 停在 Stop |

### 發現(1.8)
- SendPlcProgram 的說明寫「FORCEDOWNLOAD,一律完整下載」。但程式碼沒改時,XAE 不會下載(downloaded=false,AppTimestamp 不變)。回傳本身是誠實的，不算假成功，所以只修文件：說明沒有變更時不會下載，下載後 PLC 停在 Stop。

---

# Part 2:1.7(2026-10-29)


- 日期:2026-10-29 11:55–12:09(+08:00)
- 方式:registered tcauto MCP(`mcp__tcauto__*`),沒有自寫 client
- 環境:本機 UmRT `199.5.42.250.1.1`(`TcSystemServiceUm.exe` 3.1.0.2649)
  - A:4026 VS2022 `VisualStudio.DTE.17.0`(pid 32380,本 session launched),副本 `C:\Temp\Verify-4026-axis\AxisInterface_Type01_Library.sln`,`TwinCAT OS (x64)`
  - B:4024 XAE Shell `TcXaeShell.DTE.15.0`(pid 40072,本 session launched),副本 `C:\Temp\Verify-4024-bfh\BFH-1650.sln`,`TwinCAT RT (x64)`(`SetTarget NoPlatformSwitch`)
- MCP schema:`NewTestCase` 有 `WaitUntil` / `WaitTimeoutMs`(新版)
- Watcher log:`tests/Integration/logs/runtime-watch-1.7.jsonl`

### A. 4026(VS2022)

| # | tool | 情境 | 結果 | 回傳重點 |
|---|------|------|------|----------|
| A2 | RunLifecycle | SolutionPath + Platform `TwinCAT OS (x64)` + TargetAmsNetId(第 1 次) | **FAIL** | ConnectIde(launched, 42.6 s)/ SetTarget(projectCheck ok)/ BuildProject(completeBuild true)成功;EnableConfig set-config 時 **UmRT crash**(見發現 1),等滿 300 s 才回 `SYSTEM_STATE_TIMEOUT`(ADS 0x7) |
| A2 | RunLifecycle | 重啟 UmRT 後重跑 | PASS | 5 步全 success(29 s);ConnectIde selectedBy solution-match、ownedBySession true;EnableConfig 9 steps ok,plcState Run,bootPackage match(4 檔),finalCheck ok;ConnectAds 851 Run |
| A3 | AddGvl | GVL_P0(bFlag BOOL, nVal INT, tDur TIME := T#6S),PLC 仍 login 中 | FAIL(預期外) | `GVL_CREATE_FAILED`:XAE「Cannot add an object because it affects a device you are currently logged into」(見發現 2) |
| A3 | PlcLogout | — | PASS | logoutVia treeItem.Logoff |
| A3 | AddGvl | 同上,logout 後 | PASS | path `TIPC^AxisInterface^AxisInterface Project^GVL_P0`(專案沒有 GVLs folder,落在 project root);memberOrder [bFlag,nVal,tDur];.plcproj 存檔並讀回 verifiedFiles GVL_P0.TcGVL;buildRequired 記錄 |
| A3 | WritePouCode | Main implementation 加 `IF GVL_P0.bFlag THEN GVL_P0.nVal := GVL_P0.nVal + 1; END_IF` | PASS | updated [implementation] |
| A3 | BuildProject | — | PASS | errors 0、warnings 26、codeVerified / coverageComplete / completeBuild true(4.1 s) |
| A3 | EnableConfig | Force + Platform | PASS | 10 steps ok(含 reconnect),platformCheck parameter,plcState Run,bootPackage match |
| A4a | NewTestCase + RunTest | WaitUntil nVal > 50(timeout 5000),bFlag 設 TRUE | PASS | result Pass,**waitMs 194**(< 5000),waitTimedOut false,actual 106 |
| A4b | NewTestCase + RunTest | WaitUntil nVal > 10(timeout 2000),bFlag FALSE | PASS(預期 Fail) | result Fail,waitTimedOut true,waitMs 2023,lastValues {nVal: 0},reason「WaitUntil not met within 2000 ms」,assertions [] |
| A4c | NewTestCase + RunTest | 只用 WaitMs 500;assertion nVal > 0、tDur = T#6s | 部分 | result Pass(nVal 247、tDur "T#6s");**回傳沒有 deprecated 提示**,只有 schema/help 寫 DEPRECATED(見發現 3) |
| A4d | NewTestCase + RunTest | nVal 設 7,assertion Equal 999 | PASS(預期 Fail) | result Fail,assertion actual 7 / expected 999 pass false,waitMs 16 |
| A5 | RunTestCycle | a + c,不加 KeepRunning | PASS | total 2 / passed 2;steps Build/Activate/Login/ConnectAds/Run/Stop 全 success(21.4 s);a waitMs 150;之後 GetStatus:system Run、**PLC Stop** |
| A6 | AddLibrary | Tc2_DataExchange(成功) | PASS | alreadyPresent false,verifiedLibraries [Tc2_DataExchange],plcprojChanged true;PLC login 中也能加(與 AddGvl 不同) |
| A6 | AddLibrary | Tc9_NoSuchLib_P0(不存在) | PASS(預期 Fail) | `LIBRARY_ADD_FAILED`,data.notInstalled true,0x98510001「Managed Library ... not found!」,projectSaved null,hint 說 .plcproj 未改 |
| A6 | AddLibrary | Tc2_DataExchange 重複 | PASS | success,alreadyPresent true,existingReference Tc2_DataExchange,plcprojChanged false,沒有 buildRequired |
| A7 | IoScan | system Run | PASS(預期 Fail) | `IO_SCAN_REQUIRES_CONFIG`,data.state Run |
| A7 | RemoveVariableLink | PlcVariable `TIPC^AxisInterface^AxisInterface Instance^PlcTask Inputs^MAIN.bNoSuchVar_P0` | PASS(預期 Fail) | `TREEITEM_NOT_FOUND`,data.missingEnd PlcVariable,removed false |
| A8 | DisconnectIde | Quit true | PASS | quit true,ownedBySession true,pid 32380 退出 |
| A8 | 還原 | 備份 → 副本,hash 比對 | PASS | 見下方 hash 表;另刪除測試產生的 `GVL_P0.TcGVL`,.plcproj 無 GVL_P0 / Tc2_DataExchange |

### B. 4024(XAE Shell 32-bit)

| # | tool | 情境 | 結果 | 回傳重點 |
|---|------|------|------|----------|
| B | ConnectIde | ProgId TcXaeShell.DTE.15.0 + 副本 | PASS | selectedBy launched,ownedBySession true,pid 40072,connectSec 86.2,solution 是副本 |
| B | SetTarget | NoPlatformSwitch | PASS | platformCheck disabled,platform 維持 TwinCAT RT (x64),adsError 0x702 |
| B | AddLibrary | Tc2_DataExchange(成功) | PASS | alreadyPresent false,verifiedLibraries [Tc2_DataExchange],plcprojChanged true |
| B | AddLibrary | Tc2_DataExchange 重複 | PASS | alreadyPresent true,plcprojChanged false |
| B | BuildProject | — | PASS | errors 0、warnings 0、completeBuild true(10.2 s) |
| B | EnableConfig | Force(RunTest 需要 4024 程式在跑) | PASS | 10 steps ok,PLC1 851 Run,bootPackage match,platformCheck skipped(0x702) |
| B | IoScan | system Run | PASS(預期 Fail) | `IO_SCAN_REQUIRES_CONFIG`,data.state Run |
| B | RunTest a | WaitUntil `TwinCAT_SystemInfoVarList._TaskInfo[1].CycleCount` > 0 | PASS | result Pass,waitMs 30,actual 1408 |
| B | RunTest b | WaitUntil `MAIN.LT_Read` = -12345.5(timeout 2000) | PASS(預期 Fail) | result Fail,waitTimedOut true,waitMs 2023,lastValues {MAIN.LT_Read: 0} |
| B | DisconnectIde | Quit true | PASS | quit true,ownedBySession true,pid 40072 退出 |
| B | 還原 | 備份 → 副本,hash 比對 | PASS | 見下方 hash 表;.plcproj 無 Tc2_DataExchange;tsproj 兩個 EtherCAT Device 仍 `Disabled="true"` |

### 還原 hash(SHA256,備份在 `%TEMP%\tcauto-bk-17\`,還原後副本與備份一致)

| 副本檔案 | SHA256 | 測試期間被改過 |
|----------|--------|----------------|
| 4026 `AxisInterface_Type01_Library\AxisInterface_Type01_Library.tsproj` | C141D3B9FAB2782D328603A664A267F39FB5D57F1A3BE9BE371FA6DC06E55682 | 是 |
| 4026 `AxisInterface_Type01_Library\AxisInterface_Type01_Library-Lance-G16.tsproj` | 6625F3C42FF3CB4CBFDC319A667DF9429696AE79E240A3EF5C2126995A5C7070 | 否 |
| 4026 `AxisInterface_Type01_Library\AxisInterface_Type01_Library-LanceP-NB1.tsproj` | 15AC3105A92C901EB1FA1765435BE113BC77C542A7AFD3B01BD36F2C7A482978 | 否 |
| 4026 `AxisInterface_Type01_Library\AxisInterface\AxisInterface.plcproj` | C7EB837B54367C76FF241F72466B57734604A635AB8B785DFF378865CD1B70C3 | 是 |
| 4026 `AxisInterface_Type01_Library\AxisInterface\Main.TcPOU` | 9A62EEC8BB82374A1670209AEF7C926FFA983E3A1090AD7219D39C0A29BAE7F0 | 是 |
| 4024 `LangMang260618\BFH_1650.tsproj` | 5C8257B718162FEA16104198FB79B4005212EC6CF787D324D19E1AE157729A34 | 否 |
| 4024 `LangMang260618\PLC1\PLC1.plcproj` | C1426F02B5F5173D6BF792DA615C07E145A93FEBD4CA55D4244092C830533D58 | 是 |
| 4024 `LangMang260618\PLC1\POUs\MAIN.TcPOU` | 7FD6E0198551AF0B0D455A466555A84C6496E9ABAFC1A6A4F41C980EAD9D3E7C | 否 |

收尾狀態:UmRT pid 13124,port 10000 Run(最後 activate 的是 4024 BFH-1650 config,PLC1 Run);兩個 IDE 都已退出;watcher(pid 36824)已停。

### 發現

1. **UmRT crash,新簽名(不是 #21)**:2026-10-29 11:57:26,第一次 RunLifecycle 的 EnableConfig set-config(port 10000 → Config)時 `TcSystemServiceUm.exe` 3.1.0.2649 崩潰。Faulting module `ntdll.dll` 10.0.26100.9711,exception **0xc00000fd(stack overflow)**,offset 0x1cfa8,WER bucket 1957946794227469818,dump `%LOCALAPPDATA%\CrashDumps\TcSystemServiceUm.exe.122620.dmp`。watcher:11:57:13 `TCNC.bootdata` 396 → 0 bytes,11:57:27 多一個 pid 116720,11:57:32 兩個 pid 都消失。和 troubleshooting「已知限制」的 #21 簽名(`TcOsSys.dll` c0000005 offset 0x589534)不同,但同樣是 bootdata 先變 0。當時跑的是之前 session 留下的 4026 程式;4026 Build 有 `C0297 Possible Stack Overflow ... 101032 of 49152`(FB_Json_Converter.JsonStrToObj),可能相關,未證實(實測)。重啟 UmRT 後重跑成功。建議:troubleshooting 已知限制補這個簽名;開 issue 追。
2. **模組在 target 消失後仍等滿 300 s**:UmRT 在 set-config 開始 ~40 s 就不見了(ADS 0x7 Target machine could not be found),`Set-TcSystemState` 仍輪詢到 TimeoutSec 才回 `SYSTEM_STATE_TIMEOUT`,message 寫「last state: Run」。hint 只講 license,沒提 runtime 消失。建議:連續 0x7 / TcSystemServiceUm 不在時提早回專用錯誤(例如 RUNTIME_CRASHED),並在 hint 指向「UmRT 復原」。
3. **WaitMs 沒有執行時的 deprecated 提示**:只用 `WaitMs` 的 NewTestCase / RunTest / RunTestCycle 回傳都沒有 warning 欄位;只有 MCP schema 描述和 `New-TcTestCase.ps1` help 寫 DEPRECATED。design.md 只要求「help 標為不建議使用」,所以不算違反 spec,但 1.7 任務期望「看到 deprecated 提示」沒達成。另外 NewTestCase 給了 WaitUntil 時回傳的 `waitMs` 仍是預設 1000(會被忽略),容易誤讀。建議:NewTestCase 只用 WaitMs 時在 data 加 `warning`/`deprecated`,RunTest 結果帶出。
4. **AddGvl 在 PLC login 中被拒,錯誤沒分類**:XAE 回「Cannot add an object because it affects a device you are currently logged into」,模組回 `GVL_CREATE_FAILED`,hint 列 exists / lookup / kind / declare,沒提 login;`data.buildRequired` 寫「failed after CreateChild」,但其實 CreateChild 本身就失敗、沒有建立任何物件(還是記了 BUILD_REQUIRED)。EnableConfig Force 和 RunTestCycle 結束時都保持 login,所以這個順序在 lifecycle 裡很常見。AddLibrary 在 login 中則可以成功。建議:辨識這個訊息回專用 code(例如 PLC_LOGGED_IN,hint = 先 PlcLogout),AddPou / AddDut 很可能同樣行為(未測)。
5. **RunLifecycle 不把 Platform 傳給 EnableConfig**:這是 tool 說明寫明的設計(「Platform is given to SetTarget only」),但 EnableConfig 的 data.warning 仍會出現「-Platform was not given」整段長訊息,對 caller 是雜訊。可考慮 RunLifecycle 有 Platform 時也傳給 EnableConfig,或在這情境不出 warning。

---

# Part 3:1.8 修正後複測(2026-10-29 12:38–12:40)

registered tcauto,4026 VS2022,本機 UmRT `199.5.42.250.1.1`。

| 對應發現 | 情境 | 結果 |
|---|---|---|
| 1.7 發現 5 | RunLifecycle 帶 Platform | 5 步全部 success;EnableConfig 的 `data.warning` 為 null |
| 1.7 發現 4 | PLC login 狀態下 AddPou、AddGvl、AddDut | 全部回 `PLC_LOGGED_IN`;data 沒有 buildRequired |
| 1.7 發現 3 | NewTestCase 只用 WaitMs | 回傳有 warning;RunTest 結果也帶 warning,result Pass |
| 1.7 發現 2 | `RUNTIME_CRASHED` 提早退出 | **只有單元測試**(`tests/Unit/runtime-crashed.ps1`)。真機要等 UmRT 自然 crash,不能故意 Stop-Process `TcSystemServiceUm` 模擬 |
| 1.7 發現 3 | NewTestCase 給 WaitUntil 時回傳不帶 `waitMs` | **只有單元測試** |
| 1.7 發現 1 | UmRT ntdll c00000fd 簽名 | 不修(runtime 本身問題),記進 known-limitations,追蹤 #21([補充說明](https://github.com/Lance0901/AI-TwinCAT-Skill/issues/21#issuecomment-6487701546)) |

# 未實測 / 只有單元測試的項目

- `RUNTIME_CRASHED` 提早退出:單元測試
- NewTestCase WaitUntil 回傳不帶 `waitMs`:單元測試
- SetVariableLink / RemoveVariableLink 成功路徑:只有自建 client(subagent,離線 EK1100 + EL1004),registered 等第 1 期 `CreateChild`
- 1.4 AddLibrary 在 4024 的 2026-10-28 結果:自建 client;2026-10-29 已用 registered tcauto 在 4024 複測 PASS
