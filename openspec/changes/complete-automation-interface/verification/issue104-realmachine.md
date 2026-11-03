# #104 真機驗證(0abe88e)


> 測的是 `0abe88e`(名稱一對一比對)。之後的 `f9d637c` 改成先用 `PlcProjectDef/ProjectPath` 路徑對應，那段只有 unit test,尚未真機驗證(要確認 `data.disabledMatchBy = path`)。
## 結論

| 項目 | 判定 |
|---|---|
| 1 探測 | 完成:`Disabled` 讀回與 .tsproj 一致;精確對應欄位 = ProduceXml `PlcProjectDef/ProjectPath`(絕對路徑)/ `ProjectGUID` |
| 2 BuildProject(無 ExpectedProject) | **PASS** |
| 3 ExpectedProject enabled / disabled | **PASS** / **PASS** |
| 4 EnableConfig -Force + ReadVariable | **PASS**(第 3 次；前兩次是環境問題：#21 UmRT crash、license,使用者手動處理 license) |
| 5 #28 對照(enabled + 不 build) | **無法建構**:4026 VS2022 的 XAE 把 PLC `Disabled` 和 configuration 的 Build 勾選綁在一起(兩個方向都會自動同步，見 §5),做不出這個形狀；未測到 #28 路徑，不能判 PASS/FAIL |
| 收尾 | 副本還原，259 檔 SHA-256 全同;DisconnectIde Quit=true(pid 23044 結束);主 checkout detach 到 origin/master `e2ceb22` |

新發現(建議開 issue):(a) ResetSolution 不認 VS 的 .sln 方案層級 reload prompt(§5b、§ResetSolution 一節);(b) XAE Disabled ↔ Build.0 綁定，影響 #28 情境在 4026 上是否還會發生(§5c)。

環境：實測 2026-11-03,VS2022(`VisualStudio.DTE.17.0`,pid 23044,本 session 啟動)+ 本機 UmRT_Default(`199.5.42.250.1.1`),registered tcauto MCP。副本 `C:\Temp\Verify-4026-axis`,備份 `C:\Temp\Verify-4026-axis.bak-104`,SHA-256 清單 `C:\Temp\Verify-4026-axis.sha256-104.txt`(259 檔)。watcher pid 88580,log `tests\Integration\logs\runtime-watch-104.jsonl`。

## 建立 issue 形狀(做法)

| # | tool call | 結果 |
|---|---|---|
| 1 | `ConnectIde ProgId=VisualStudio.DTE.17.0 SolutionPath=C:\Temp\Verify-4026-axis\AxisInterface_Type01_Library.sln` | success,selectedBy launched,ownedBySession true,pid 23044,49 s,platform `TwinCAT OS (x64)` |
| 2 | `CreateChild Path=TIPC Name=DisabledDemo SubType=0 VInfo="Standard PLC Template.plcproj" DryRun=false` | success,verified,`TIPC^DisabledDemo`,AdsPort 852 |
| 3 | `BuildProject`(基準，兩個都 enabled) | success,兩個 PLC 都 `built`、shouldBuild true,completeBuild true |
| 4 | `ConsumeXml Path=TIPC^DisabledDemo Xml=<TreeItem><Disabled>true</Disabled></TreeItem> DryRun=false` | success,verified(ProduceXml 的 `TreeItem/Disabled` false→true) |

**XAE 在 Disable PLC 時自動把該 PLC 的 Build 勾選拿掉**(實測 2026-11-03,4026 VS2022):步驟 4 之後 DTE `ShouldBuild` = false,.sln 中 `{9EF125E4...}.Release|TwinCAT OS (x64)` 只剩 `ActiveCfg`、沒有 `Build.0`。所以不需要另外改 configuration。

## 1. 探測

| 項目 | 值 |
|---|---|
| ProduceXml `TreeItem/Disabled`(disabled PLC) | `true`(enabled PLC 為 `false`) |
| .tsproj | `<Project Disabled="true" GUID="{9EF125E4-...}" Name="DisabledDemo" PrjFilePath="DisabledDemo\DisabledDemo.plcproj" ... AmsPort="852">`,與 ProduceXml 一致 |
| SolutionContext.ShouldBuild(disabled PLC) | false(XAE 自動設) |
| 精確對應 .plcproj 的欄位 | ProduceXml `PlcProjectDef/ProjectPath` = **絕對路徑** `C:\temp\Verify-4026-axis\AxisInterface_Type01_Library\DisabledDemo\DisabledDemo.plcproj`;另有 `PlcProjectDef/ProjectGUID`(= .tsproj `GUID`,也是 .sln 裡 nested project 的 GUID)、`RelativePrjPath` = `DisabledDemo`(資料夾，不含檔名)。.tsproj `PrjFilePath` 是相對 .tsproj 的路徑 |

建議(只記錄，未改 code):用 `PlcProjectDef/ProjectPath` 或 `ProjectGUID` 對 DTE project 的 FullName / GUID,可取代名稱比對，解掉名稱對調的歧義。注意 ProjectPath 的磁碟根是 `C:\temp`(小寫),比對要不分大小寫。

## 2. BuildProject(不帶 ExpectedProject)— PASS

success,completeBuild true,coverageComplete true,codeVerified true,`disabledProjects=["DisabledDemo"]`,`skippedProjects=[]`,DisabledDemo `status=disabled`、`shouldBuild=false`、`disabled=true`;AxisInterface `built`;沒有 warningCode、沒有 disabledCheckError。

## 3. ExpectedProject — PASS

- `ExpectedProject=["AxisInterface"]`:success,completeBuild true,同上。
- `ExpectedProject=["DisabledDemo"]`:`EXPECTED_PROJECT_DISABLED`,message「Build not started」,0.7 s 返回;AxisInterface status `pending`(沒開始 Build)。

## 4. EnableConfig -Force — 未完成(環境問題)

1. 第 1 次:`RUNTIME_CRASHED`,set-config(送 Reconfig)時 UmRT 消失，與 #104 無關。簽名 = 已知 #21:Event 1000 `TcOsSys.dll` 3.1.0.1 c0000005 offset 0x589534,14:20:37;dump `%LOCALAPPDATA%\CrashDumps\TcSystemServiceUm.exe.102904.dmp`;watcher 14:20:36.8 `bootdata-empty`(484→0)與 pid 變化。
2. 依 brief 重啟 TcSystemServiceUm(pid 82512,14:21:12)。
3. 第 2 次:`IDE_MODAL_DIALOG`「Target system reports a fatal error ... 'TwinCAT System' (10000): Error: >> license not found << checking TwinCAT Licenses!」,bridge 重啟。**依規則 5 停下**,沒點視窗、沒啟 trial。

步驟 5(#28 對照)、還原尚未執行。

### #104 gate 是否放行

- 第 1 次:`steps[]` 只有 `set-config`(ok false,55.5 s),沒有回 BUILD_REQUIRED。`Enable-TcConfig.ps1` 的 BUILD_REQUIRED 檢查(line 632)在 set-config(line 746)之前，所以 **#104 的 BUILD_REQUIRED gate 已放行**;但流程停在 set-config,**沒走到 Activate**。
- 第 2 次:bridge 被 modal dialog 砍掉、重啟，回傳沒有 `steps[]`,看不出停在哪一步。dialog 時間 14:21:27.358(呼叫開始 14:21:15.8,約 11.5 s 後),內容是 'TwinCAT System' (10000) 的 license 檢查。從回傳無法證明有沒有走到 Activate(推論：license 檢查發生在 runtime 啟動 / 切 Run,未證實)。第 2 次也沒回 BUILD_REQUIRED。

### 第 3 次(使用者手動處理 license 後)— PASS

| tool call | 結果 |
|---|---|
| `GetIdeModalDialog ProcessId=23044` | dialog null |
| `ConnectIde`(同 sln,NoLaunch) | pid 23044,selectedBy solution-match,ownedBySession **false**(已知 #73,bridge 重啟後；pid 確認是本 session 啟動的那個) |
| `GetSystemState` | Config(15) |
| `EnableConfig Force=true TimeoutSec=180` | success,9 steps 全 ok:set-config → activate → boot-package → set-run → login → wait-plc-port → set-plc-run → wait-plc-run → verify;**沒有 BUILD_REQUIRED**;plcs=[AxisInterface 851 Run],`skippedPlcs=["DisabledDemo"]`;finalCheck ok;18.5 s |
| `ConnectAds` | 851 Run |
| `ReadVariable` | `Main.tA07_TestMode`=0(INT)、`Main.bEstop`=true(BOOL)、`_TaskInfo[1].CycleCount` 5852 → 8806(6 s 後，非假 Run) |

觀察:`bootPackage.status = match`,但 `files[]` 裡 `CurrentConfig\DisabledDemo.tpzip` 是 `match:false`(local 有、target 沒有，列在 `oneSided`)。這個 local 檔是基準 build(兩個都 enabled 時)留下的舊檔;disabled PLC 不會被下載，所以 target 沒有是正確的。模組目前把 oneSided 當成不影響 match,行為合理，但若要更嚴謹可考慮排除 disabled PLC 的 tpzip。

## 5. #28 對照 — 無法建構(見 5c)

| tool call | 結果 |
|---|---|
| `ConsumeXml TIPC^DisabledDemo <Disabled>false</Disabled> DryRun=false` | success,verified |
| `BuildProject` | success,**兩個都 shouldBuild=true / built**,completeBuild true |

**XAE 在 Enable PLC 時會自動把 Build 勾回來**(實測 2026-11-03,4026 VS2022),跟 Disable 時自動取消是對稱的。tcauto 沒有改 ShouldBuild 的 tool,做不出「enabled + 不 build」。Error List 另有 7 筆 14:21:27 的 license 錯誤(category other,沒有 file),沒影響 codeVerified。

### 5b. 改用 .sln 刪 Build.0(啟動 session 指示選 a)

| 動作 | 結果 |
|---|---|
| 確認 .tsproj 沒有 `Disabled="true" GUID="{9EF125E4...`(已 enabled) | 0 筆 |
| `sed` 刪副本 .sln 第 151 行 `{9EF125E4-...}.Release\|TwinCAT OS (x64).Build.0 = ...`(14:26:39,BOM 保留) | 只剩 ActiveCfg |
| `ResetSolution TimeoutSec=120` | **IDE_MODAL_DIALOG**:VS2022 對話框「偵測到檔案修改 / 方案 'AxisInterface_Type01_Library' 已在環境外部修改」,按鈕 `重新載入(&R)` id 259、`忽略(&I)` id 1412;模組判成 `dialogKind: unknown`,沒有處理(closed/reopened false) |

**新發現(建議開 issue)**:ResetSolution 只認 .plcproj 的 XAE project prompt 與 VS 的 file reload prompt,不認 VS 的 **solution** reload prompt(.sln 在外部被改)。實測 2026-11-03,4026 VS2022 zh-TW。按鈕 id 259 = 重新載入(不是 Win32 MessageBox 的 6)。

### 5c. 使用者按「重新載入」之後

| tool call | 結果 |
|---|---|
| `GetIdeModalDialog ProcessId=23044` | dialog null |
| 磁碟檢查 | .sln DisabledDemo 仍只有 ActiveCfg(沒有 Build.0);.tsproj 沒有 `Disabled="true"`;.sln mtime 14:33:04(VS 重載時重寫) |
| `ResetSolution TimeoutSec=120` | `IDE_MODAL_DIALOG`「Microsoft Visual Studio \| System Manager already disposed!」(operation `LookupTreeItem TIPC`,NullReference),114 s,什麼都沒關。原因：VS 重載方案後 bridge 手上的 ITcSysManager 是舊物件。之後 `GetIdeModalDialog` 回 dialog null(框自己沒了) |
| `ConnectIde`(NoLaunch) | pid 23044,solution-match,2.4 s |
| `BuildProject` | success,completeBuild true,**DisabledDemo `shouldBuild=false`、`status=disabled`、`disabled=true`**,disabledProjects=[DisabledDemo],skippedProjects=[] |
| `ProduceXml TIPC^DisabledDemo` | `<Disabled>true</Disabled>` |
| 磁碟 .tsproj(14:41:03,Build 時寫入) | `<Project Disabled="true" GUID="{9EF125E4...}" Name="DisabledDemo" ...>` |

**XAE 在載入方案時，把 .sln 沒有 Build.0 的 PLC project 載成 Disabled**,並在下次存檔寫回 .tsproj(實測 2026-11-03,4026 VS2022 zh-TW)。加上 §5 的 Disable→去 Build.0、Enable→加回 Build.0,XAE 這版把兩者當同一個設定。所以 #28 的「enabled 但 configuration 不 build」在這個環境建不出來；`BuildProject -ExpectedProject DisabledDemo` 在此狀態只會是 EXPECTED_PROJECT_DISABLED,沒意義，沒有跑。
待查:troubleshooting 第 172 行舊 #28 實測(移除 FrameworkUnitTest 的 Build.0 → skipped)用的是哪個 XAE 版本、有沒有重載方案；若 4026 一律會轉成 Disabled,`PROJECT_SKIPPED_BY_CONFIGURATION` 在 4026 可能只剩「重載前」的短暫視窗。InfoSys 沒找到這個綁定的說明(未查到出處，標實測)。

## ResetSolution 不認 .sln 方案層級 reload prompt(待開 issue)

- 發生步驟：步驟 5b,在副本 .sln 用 sed 刪掉一行 `Build.0`(14:26:39)後呼叫 `ResetSolution TimeoutSec=120`(14:26:42)。IDE:VS2022 `VisualStudio.DTE.17.0` pid 23044,zh-TW UI,4026 XAE。
- 對話框標題:`偵測到檔案修改`
- 內文:`方案 'AxisInterface_Type01_Library' 已在環境外部修改。\r\n\r\n按下 [重載] 從磁碟載入更新的方案。\r\n按下 [忽略] 以忽略外部變更。變更會在您下次開啟方案時使用。`
- 按鈕:`重新載入(&R)` id **259**、`忽略(&I)` id **1412**(不是 Win32 MessageBox 的 6/7)
- 模組判讀:ResetSolution 回 `IDE_MODAL_DIALOG`,`dialogKind: "unknown"`、`dialogReloadTarget: null`,`dismissedReloadPrompt/answeredYes/closed/reopened` 全 false。GetIdeModalDialog 在這個情境回的 kind 也是 unknown(ResetSolution 的 data.dialog 與 GetIdeModalDialog 同一判讀)。
- 使用者手動按「重新載入」後還有後續問題:bridge 的 SystemManager 已失效，下一次 ResetSolution 在 projectCheck 的 `LookupTreeItem TIPC` 拿到「System Manager already disposed!」,被包成 IDE_MODAL_DIALOG。需要 ConnectIde 重抓引用才恢復。
  - 觸發者與時間：是本 session 的 `ResetSolution`(14:38:45.5 開始、14:40:39.1 返回，114 s)。它在 projectCheck 呼叫 `LookupTreeItem TIPC`,XAE 跳出 Microsoft Visual Studio 錯誤框「System Manager already disposed!」(只有「確定」;使用者截圖約 14:39)。ResetSolution 回 `IDE_MODAL_DIALOG`,message 帶這段文字與原始 NullReference(`並未將物件參考設定為物件的執行個體。`),`projectCheck: null`,什麼都沒關。這個 error 是從例外文字組出來的，回傳裡沒有 `dialogKind`。
  - 14:40:4x 的 `GetIdeModalDialog ProcessId=23044` 回 `dialog: null`,所以這個框**沒有被 GetIdeModalDialog 分類過**(推測使用者在 ResetSolution 返回前後按了確定;114 s 裡大部分時間是在等這個框)。之後 `ConnectIde`(同 pid 23044,NoLaunch,solution-match)重新取得 ITcSysManager,BuildProject 正常。
- 建議：把這個 solution reload prompt 歸類成 `reload-prompt`(reloadTarget `solution`),用按鈕 id 259 回答;回答後重新取得 DTE/SysManager。按鈕 id 是否跨語系固定未驗證。

### 附給 #21 的 crash 簽名(第 1 次)

| 欄位 | 值 |
|---|---|
| 時間 | 2026-11-03 14:20:37(Event 1000);watcher 14:20:36.832 `bootdata-empty` 484→0、pid [102904]→[36708,102904];14:20:43.148 pid → [] |
| Faulting app | TcSystemServiceUm.exe 3.1.0.2649,timestamp 0x69824f03,pid 0x191F8(102904) |
| Faulting module | TcOsSys.dll 3.1.0.1,timestamp 0x69824839 |
| Exception / offset | 0xc0000005 / 0x0000000000589534 |
| Report Id | c620ea1b-cf04-41f0-9a25-41ad84947b00 |
| Dump | `%LOCALAPPDATA%\CrashDumps\TcSystemServiceUm.exe.102904.dmp`(2,574,780 bytes,14:20:42) |
| 情境 | EnableConfig Force set-config(送 AdsState Reconfig=16,原狀態 Run);UmRT 在本 session 前就已在跑。PLC 剛從 1 個變 2 個(第 2 個 disabled) |
| 復原 | 14:21:12 依 brief 重啟 TcSystemServiceUm(pid 82512)→ 下一次 EnableConfig 跳 license not found |

## 收尾

| 動作 | 結果 |
|---|---|
| `DisconnectIde Quit=true` | success,quit true,solutionClosed true,pid 23044 結束(ownedBySession false 是 #73,pid 是本 session 啟動的那個) |
| 還原副本 | 刪 `C:\Temp\Verify-4026-axis`,從 `.bak-104` 複製回來;`.vs` 隱藏屬性在複製時掉了，補回 Hidden |
| SHA-256 | 清單 259 檔全部相同(diff 0);含隱藏檔與備份全量比對 diff 0 |
| watcher | pid 88580 已停;events 只有 14:20:36–43 crash 與 14:21:13 重啟(pid → 82512) |
| 主 checkout | `git fetch` + `git checkout --detach origin/master` → `e2ceb22`;只剩原本就有的 `?? openspec/changes/add-scope-integration/` |
| 保留 | 備份 `C:\Temp\Verify-4026-axis.bak-104` 與清單 `C:\Temp\Verify-4026-axis.sha256-104.txt` 沒刪(要刪再說);UmRT 目前 Run,跑的是測試時下載的 AxisInterface |
