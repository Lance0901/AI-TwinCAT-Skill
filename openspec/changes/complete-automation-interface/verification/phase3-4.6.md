# Task 4.6:第 3 期 15 個新 tool 的 registered tcauto 真機驗證

- 方式:**registered tcauto**(`mcp__tcauto__*`)。沒有 `Import-Module`、沒有自建 client。只有一處用了「不是受測 tool」的通用 tool 繞道(`SetVariableLink`,見 4.1 LinkNcAxis),結果分開標示。
- 日期:2026-11-01(本地 10:19–10:35)。主機：本機 Windows 11 26200。
- 受測程式碼:branch `openspec/complete-automation-interface-phase3` HEAD `5089f6d`(4.1–4.5 實作 `7705b58`…`cc26b5a`、reviewer 修正 `ac7373e`…`5089f6d`)。
  - 載入確認:這個 session 的 MCP server node 行程(pid 2312)啟動於 10:17:58,晚於 HEAD commit 05:18:55;bridge 在第一個呼叫時才 spawn,載入當下的 `TwinCATAutomation.psm1`(`src/` 沒有未提交改動)。15 個新 tool(`AddNcTask`、`AddNcAxis`、`SetNcAxisParameter`、`LinkNcAxis`、`AddTcComModule`、`GetTcComParameter`、`SetTcComParameter`、`SetTcComContext`、`GetVariants`、`SetVariantConfig`、`SwitchVariant`、`SetIndependentFile`、`GetAdsRoutes`、`FindAdsTargets`、`AddAdsRoute`)在 ToolSearch 都看得到。
- 環境:
  - **4026** = `VisualStudio.DTE.17.0`(VS2022),TwinCAT 3.1.4026.22,副本 `C:\Temp\Verify-4026-axis\AxisInterface_Type01_Library.sln`,platform `TwinCAT OS (x64)`。ConnectIde launched pid 106056(connectSec 40.3,`ownedBySession true`);第一次 `IDE_MODAL_DIALOG` 讓 bridge 重啟後 reattach 時 `ownedBySession false`(已知 #73),pid 仍是同一個。
  - **4024** = `TcXaeShell.DTE.15.0`(32-bit XAE Shell),專案 3.1.4024.71,副本 `C:\Temp\Verify-4024-bfh\BFH-1650.sln`,platform `TwinCAT RT (x64)`。ConnectIde launched pid 34512(connectSec 94.9)。
  - Runtime:本機 UmRT_Default(`TcSystemServiceUm` pid 102904,02:46 由 probe session 啟動),AmsNetId `199.5.42.250.1.1`。開始時 AdsState = Config(probe 留下),第一次 `EnableConfig Force=true` 就回 Run。**全程沒有 license / trial / security code 對話框。**
- 背景監看:`tests/Integration/Watch-Runtime.ps1`(pid 65376),log 在 scratchpad `...\e9cb80e4-7983-457d-96c8-d252def6ae8b\scratchpad\runtime-watch.jsonl`(908 筆，10:19:57–10:35:12)。**沒有任何 `event` 行**:UmRT pid 全程 102904、bootdata 沒有變 0 byte;Config 386 / Run 514 / Stop 4 / unreachable 4(Activate 重啟時)。
- TwinCAT 行為結論沒有新的 InfoSys 出處，下文「實測」都是 **實測 2026-11-01,上述環境**。

## 結果總表

| tool | 4026 VS2022 | 4024 XAE Shell | 一句話 |
|---|---|---|---|
| `AddNcTask` | ✓ | ✓ | 兩個副本都回 `NC_TASK_ALREADY_EXISTS`(`existingTasks ["TINC^NC-Task 1 SAF"]`);成功路徑無法實測(TINC 只能有一個 task) |
| `AddNcAxis` | ✓ | ✓ | dry-run / 實建 / 同名(大小寫不同)被擋;讀回 Simulation encoder、`axisId` 5(4026)/ 4(4024),Run 時 `NcToPlc.AxisId` = 5 |
| `SetNcAxisParameter` | ✓ | ✓ | Deceleration / Jerk / MaxVelocity 實寫讀回;DriveType 7 → 5;ControllerType 4 → `NC_INVALID_SUBTYPE`;矛盾值有 warnings |
| `LinkNcAxis` | **✗ bug B1** | **✗ bug B1** | PLC instance 列舉不到子節點，一律 `NC_PLC_VARIABLE_NOT_FOUND`;link、已 link 拒絕都測不到 |
| `AddTcComModule` | ✓ | ✓ | GUID / TypeName 各一次，名稱 `NtpGuid (TcNtpExternalTimeProvider)`;4024 第一次就是 `NtpProbe_Obj1 (...)` |
| `GetTcComParameter` | ✓(N2) | ✓ | 清單、offline、Online 都可讀;TIME 型別 `value` 是 null |
| `SetTcComParameter` | ✓(N2) | ✓ | BOOL / UINT / DINT 實寫讀回;online 寫入不改專案;`TCCOM_ONLINE_CONFIG_MISMATCH` 自然觸發;`TCCOM_PARAM_SIZE_MISMATCH` 觸發不了 |
| `SetTcComContext` | ✓ | ✓ | Context Id 1 ← `TIRT^PlcTask`(`0x02010030`)讀回;ContextId 0 → `TCCOM_CONTEXT_INVALID` |
| `GetVariants` | ✓ | ✓ | 無 variant(4026 空字串、4024 `$null`)都回空清單，不當成讀取失敗 |
| `SetVariantConfig` | ✓ | ✓ | 新增 / 移除讀回;寫入前備份 `.tsproj` |
| `SwitchVariant` | ✓ | ✓ | 大小寫錯 → `VARIANT_NOT_FOUND`;`[Group1]` 可切且有 warning,`EnableConfig` → `VARIANT_GROUP_ACTIVE` |
| `EnableConfig` / `GenerateBootProject` variant(#89) | ✓ | ✓ | Variant1 → Build → Activate → Run,bootPackage 比對 `_Boot\Variant1\<platform>` 4 檔相同 |
| `SetIndependentFile` | ✓(繞過 B2 後) | ✓ | NC 軸 / TcCOM / PLC / I/O device 的 `.xti` 出現、消失，`.tsproj` 參照跟著增減;PlcTask → `INDEPENDENT_FILE_UNSUPPORTED`;4026 副本原樣回 `INDEPENDENT_FILE_TSPROJ_AMBIGUOUS`(B2) |
| `GetAdsRoutes` | ✓ | ✓ | target = UmRT(LocalHost 一條)與本機(3 actual / 2 static) |
| `FindAdsTargets` | ✓ | ✓ | target = UmRT → `ROUTE_SEARCH_REQUIRES_LOCAL_TARGET`;本機 broadcast / Search 各約 4.1 s,空結果帶 note |
| `AddAdsRoute` | ✓ dry-run(N4) | ✓ dry-run | `ROUTE_PASSWORD_MISSING` 兩種、`PasswordEnv=PATH` → `INVALID_PARAMS`、ProjectRoute dry-run;**沒有實際新增 route** |
| 密碼遮罩(TISY) | 測不到 | 測不到 | `TISY` 在兩個 XAE 都 `TREEITEM_NOT_FOUND`(N5) |
| 共通 `IDE_MODAL_DIALOG` | ✓ | – | `EnableConfig` 時自然出現「Target system reports a fatal error」 |

---

## 4.1 NC

### AddNcTask

- 4026 `DryRun=false`、4024 dry-run 都回 `NC_TASK_ALREADY_EXISTS`,`data.existingTasks = ["TINC^NC-Task 1 SAF"]`,hint 指向 `AddNcAxis Name=<axis> Task=<...>`(MCP 寫法)。沒有呼叫 CreateChild(0.3 s)。
- 從零建 task 的成功路徑仍未實測(兩個副本都已有 task,和 probe 第 1 題相同)。

### AddNcAxis

- 4026:dry-run `plannedSteps` 正確 → `DryRun=false` 建出 `TINC^NC-Task 1 SAF^Axes^AxisT46`(1.8 s):Enc subType 1 `Simulation encoder`、Drive 5 KL4XXX、Ctrl 1 P,`simulation true`、`axisId 5`、`verified true`、`buildRequired` 有記。
- 同名：`Name=axist46`(大小寫不同)→ `NC_AXIS_ALREADY_EXISTS`,`existingAxes ["AxisT46"]`,什麼都沒建。
- 4024:同樣建出 `AxisT46`,`axisId 4`(4024 專案只有 3 支軸)。
- 小觀察:`backupFiles` 是空陣列(NC 軸存在 `.tsproj` 裡，只有 ProduceXml 備份 `backupPath`)。

### SetNcAxisParameter

| 呼叫(4026,`AxisT46`) | 結果 |
|---|---|
| Deceleration 1200 + Jerk 5000 dry-run | `changes` current 1500 / 2250 → planned,`xml` 只含兩個元素 |
| 同上 `DryRun=false` | `written / verified true` |
| DriveType 7 | drive `Two speed drive`(subType 7) |
| DriveType 5 | 回到 `Drive (KL4XXX/...)` |
| ControllerType 4 | `NC_INVALID_SUBTYPE`,`allowedTypes [1,2,3,5..14]`,**送出前就擋下**(0.01 s,`data.reverted` 的還原路徑因此沒跑到) |
| Deceleration 20000 + MaxVelocity 50 dry-run | 4 條 warnings(Deceleration > DecelerationMaximum 15000;Velo/Maximum 低於 Fast / FastManual / SlowManual);沒有實寫 |

- 4024:MaxVelocity 1500 + Jerk 4000 實寫讀回，warning「Velo/Maximum 1500 is below Velo/Fast 2000」;ControllerType 4 同樣被擋。

### LinkNcAxis — bug B1

- `LinkNcAxis Axis=AxisT46 PlcVariable=GVL_Motion.arAxisCtrl_gb[5].Admin.Axis`(4026)在 `BuildProject` 前後都回 `NC_PLC_VARIABLE_NOT_FOUND`,`data.instanceChildren = []`、warning「0 children of 'TIPC^AxisInterface' have process images」。
- 但 `LookupTreeItem 'TIPC^AxisInterface^AxisInterface Instance'` 回 `childCount 0`,而 `LookupTreeItem '...^AxisInterface Instance^PlcTask Inputs'` 存在(40 個子節點，包含 `GVL_Motion.arAxisCtrl_gb[5].Admin.Axis.NcToPlc`)。
- 4024 相同:`...^PLC1 Instance^PlcTask Inputs^GVL_Axes.axisDraw.NcToPlc` lookup 成功(42 成員),`LinkNcAxis Axis=AxisT46 PlcVariable=GVL_Axes.axisDraw` 仍是 `NC_PLC_VARIABLE_NOT_FOUND`。
- 已 link 的軸再 link(`Axis 1` → `arAxisCtrl_gb[6]`)也先撞到同一個錯誤，`NC_AXIS_ALREADY_LINKED` 測不到。
- 詳見「發現的問題 B1」。

### 繞道驗證：新軸在 runtime 有在跑(不是 LinkNcAxis 的結果)

- 用通用 `SetVariableLink` 手動 link:`...PlcTask Inputs^GVL_Motion.arAxisCtrl_gb[5].Admin.Axis.NcToPlc` ↔ `TINC^NC-Task 1 SAF^Axes^AxisT46^Outputs^ToPlc`、`...PlcTask Outputs^...[5].Admin.Axis.PlcToNc` ↔ `...^AxisT46^Inputs^FromPlc`,兩條都 `linked true`。
- `BuildProject`(completeBuild true)→ `EnableConfig Force=true`(第二次;第一次見 4.2)→ Run → `ReadVariable`:`NcToPlc.AxisId = 5`(= AddNcAxis 的 `axisId`),`DcTimeStamp` 2653592896 → 2707592896(兩次讀取遞增)。

## 4.2 TcCOM(`TcNtpExternalTimeProvider`)

### AddTcComModule

| 呼叫 | 結果 |
|---|---|
| 4026 `Name=NtpGuid ClassId={7e6d2fda-…}` dry-run | `plannedSteps` CreateChild SubType 0 vInfo GUID |
| 同上 `DryRun=false` | `createdPath TIRC^TcCOM Objects^NtpGuid (TcNtpExternalTimeProvider)`,oid `0x01010010`,`contextIds [1]`,12 個參數，warning 說明改名 |
| 4026 `Name=NtpType TypeName=TcNtpExternalTimeProvider` | `NtpType (TcNtpExternalTimeProvider)`,oid `0x01010020` |
| 4024 `Name=NtpProbe TypeName=...` | **`NtpProbe_Obj1 (TcNtpExternalTimeProvider)`**(第一次就加 `_Obj1`,和 probe 第 9 題一致),8 個參數 |

- 4024 的 NTP TMC 和 4026 不同:沒有 `ClientEnable` / `ServerName` / `ServerPort` / `PollInterval`,client 設定包在 struct `ClientPara`(384 bit)裡 → `SetTcComParameter Name=ClientEnable` 回 `TCCOM_PARAM_NOT_FOUND`(列出 8 個參數)。因為不能用 tool 關掉 NTP client,**4024 的 NTP instance 沒有 Activate**,測完用 `DeleteChild` 刪掉。
- 用原名 `NtpProbe`(沒有 `_Obj1`)當 `Module` → `TCCOM_MODULE_NOT_FOUND`,`data.modules` 列出實際名稱(4026 的 `NtpGuid` 不帶後綴可以找到)。

### 參數(GetTcComParameter / SetTcComParameter)

| 呼叫 | 結果 |
|---|---|
| 4026 兩個 instance `ClientEnable=false` | `01` → `00` 讀回 |
| `PollInterval` 讀 | **baseType 是 TIME**(probe 文件寫 UDINT),`rawHex E8030000`(1000),`value null`(N2) |
| `PollInterval = 4321` | `TCCOM_PARAM_UNSUPPORTED_TYPE`「TIME (4 bytes) can only be read as hex」;hint 卻說「不是基本型別(struct / array)」(N2) |
| `ServerPort`(UINT)= 1234 | `7B00` → `D204` 讀回 |
| `ServerPort = 70000` | `TCCOM_PARAM_INVALID_VALUE`(範圍 0..65535),什麼都沒寫 |
| `ServerName`(STRING(255))dry-run | 256 bytes planned / current,沒有 size mismatch |
| 4024 `TimeType`(DINT)= 2 | `03000000` → `02000000` 讀回 |

- `TCCOM_PARAM_SIZE_MISMATCH`:模組在送出前用「目前值的長度」= 計畫長度檢查，離線的 UINT / BOOL / STRING / DINT 都一致;online 也都一致。**這次沒辦法自然觸發**(要 TMC 的 BitSize 和實際不同才會出現)。

### SetTcComContext

- `ContextId=0` → `TCCOM_CONTEXT_INVALID`,`data.contextIds [1]`。
- 預設(唯一 context)→ Context 1 = `TIRT^PlcTask`,`taskOidHex 0x02010030`,`readbackOidHex 0x02010030`,4026 兩個 instance、4024 一個都成功。

### Activate、IDE_MODAL_DIALOG 與 Online

- 第一次 `EnableConfig Force=true`(NC 軸 + 兩個 NTP instance)→ **`IDE_MODAL_DIALOG`**,XAE「Target system reports a fatal error」:`Create TComObj SAFEOP: Create Object NtpType (TcNtpExternalTimeProvider) >> AdsError: 1800 (0x708, ADS ERROR: device is busy)`,`bridgeRestarted true`。這是**自然觸發**(不是自己造的對話框),hint 是 MCP 寫法(`ConnectIde again`、`GetStatus / GetPlcState`)。
  - `GetIdeModalDialog ProcessId=106056` 讀到同一個 dialog(`kind unknown`,按鈕 `[{id 2, 確定}]`)。我用 Win32 `PostMessage(hwnd, WM_COMMAND, 2)` 按「確定」(自己啟動的 IDE、只有一個按鈕的錯誤訊息框),再 `GetIdeModalDialog` → `dialog null`,`ConnectIde NoLaunch=true` reattach。
  - 下一次 `BuildProject` 的 Error List 有原因:`'TCOM Server' (10): NtpType (...)(0x01010020): Register ExternalTime failed, HR=98110708`。**同一個 runtime 只能有一個 external time provider**(實測;InfoSys 沒查到出處)。`DeleteChild` 刪掉 `NtpType` 之後 Activate 成功。
- 第二次 `EnableConfig Force=true`:9 steps 全 ok,`plcState Run`,bootPackage match(4 檔)。
- Online:`ServerPort` online 讀 1234 → `SetTcComParameter Online=true Value=2345` → online 讀 2345,**offline / projectValue 仍是 1234**(`projectChanged false`)。online 寫入前會比對 boot package(`data.bootPackage status match`)。
- **`TCCOM_ONLINE_CONFIG_MISMATCH`**:Variant1 Activate 之後切 `Variant2`(沒有 `_Boot\Variant2`,模組 fallback 到舊的 `_Boot\TwinCAT OS (x64)`,和 target 的 Variant1 組態不同)→ online dry-run 回 `TCCOM_ONLINE_CONFIG_MISMATCH`,`bootPackage.mismatches` 4 檔,什麼都沒寫。

## 4.3 Variant

### 4026

| 步驟 | 結果 |
|---|---|
| `GetVariants` | `supported true`,`current ""`,`variants []`,`configXml ""` |
| `SetVariantConfig AddVariant [Variant1,Variant2,Variant3] Group Group1` | 讀回 3 個 variant + Group1;備份 `ProjectVariantConfig.xml` + `.tsproj`(3 個都備份，見 B2) |
| `SetVariantConfig RemoveVariant [Variant3]` | 只剩 Variant1 / Variant2,group member 也移除 |
| `SwitchVariant variant1` | `VARIANT_NOT_FOUND`「names are case-sensitive; there is 'Variant1'」 |
| `SwitchVariant [Group1]` | 成功 + warning「EnableConfig refuses to activate it」 |
| `EnableConfig Force=true` | `VARIANT_GROUP_ACTIVE`,`activated false`(0.07 s,BUILD_REQUIRED 之前就擋) |
| `SwitchVariant Variant1` → `GetVariants` | `current Variant1`,`itemsXml <ProjectVariants/>` |
| `BuildProject` → `EnableConfig Force=true` | **#89 PASS**:Run,`bootPackage.localDir = _Boot\Variant1\TwinCAT OS (x64)`,`variant Variant1`,4 檔 SHA-256 相同 |
| `GenerateBootProject`(Variant1) | `bootDir _Boot\Variant1\TwinCAT OS (x64)\Plc`,`variant Variant1`,7 檔 `updated true` |

- 存檔後 `.tsproj` 根元素有 `TcProjectVariant="Variant1"`,`<Variants SpecificLocalBootFolder="true">` 存在。
- 「未知節點保留」:registered tool 只能 add / remove,無法把未知元素寫進 `ProjectVariantConfig`,**這次沒測**(只有單元測試)。
- reviewer S2 的 `get_<Name>()` 讀法:4026(空字串)與 4024(`$null`,probe 第 16 題)無 variant 時都回 `success` + 空清單，有 variant 後 config / items 都讀得到。真 COM 上「讀取失敗」沒辦法自然觸發，所以只確認了空值那一邊。

### 4024

- `GetVariants` 空 → `SetVariantConfig` Variant1 / Variant2 + Group1 → `SwitchVariant VARIANT1` → `VARIANT_NOT_FOUND` → `SwitchVariant Variant1` → `BuildProject`(9.6 s,completeBuild)→ `EnableConfig Force=true` → Run,bootPackage `localDir _Boot\Variant1\TwinCAT RT (x64)` 4 檔相同。**#89 在 4024 也 PASS。**
- `GenerateBootProject`:`bootDir _Boot\Variant1\TwinCAT RT (x64)\Plc`。
- `SetVariantConfig RemoveVariant [Variant2]`:剩 Variant1,`current Variant1` 不變。

## 4.4 SetIndependentFile

- 4026 副本原樣：第一個呼叫(NC 軸)回 **`INDEPENDENT_FILE_TSPROJ_AMBIGUOUS`**:solution 資料夾有 3 個 `.tsproj`(`AxisInterface_Type01_Library.tsproj` 和兩個舊副本 `-Lance-G16`、`-LanceP-NB1`),但 `.sln` 只參照 `AxisInterface_Type01_Library.tsproj`(見 B2)。照 hint 把兩個舊副本暫時移出副本資料夾(收尾 `/MIR` 還原)後重跑。

| item(4026) | Enabled=true | Enabled=false |
|---|---|---|
| `TINC^NC-Task 1 SAF^Axes^AxisT46` | `createdFiles _Config\NC\Axes\AxisT46.xti`,`.tsproj` `<Axis File="AxisT46.xti" Id="5"/>` | `removedFiles` 同一檔，備份含 `.xti` |
| `TIRC^TcCOM Objects^NtpGuid (TcNtpExternalTimeProvider)` | `_Config\TcCOM Objects\NtpGuid (...).xti`,`<Module File=.../>` | 刪除 |
| `TIPC^AxisInterface` | `_Config\PLC\AxisInterface.xti`,`<Project File="AxisInterface.xti"/>` | 刪除 |
| `TIRT^PlcTask` | `INDEPENDENT_FILE_UNSUPPORTED`(`readback false`) | – |

- 全部關掉後磁碟上 `_Config` 底下 0 個 `.xti`、`.tsproj` 0 個 `File="` 參照。
- 4024 `TIID^Device 1 (EtherCAT)`:開 → `_Config\IO\Device 1 (EtherCAT).xti`(內容 `Disabled="true"` 保留)、`.tsproj` `<Device File="Device 1 (EtherCAT).xti" Id="1"/>`;關 → `removedFiles` 該檔(XAE 留下 `.xti.bak`)。

## 4.5 Route(只做唯讀與 dry-run)

- `GetAdsRoutes`:target = UmRT → `actualRoutes [LocalHost 192.168.50.168.1.1]`、static / project 空(4026、4024 相同);target = 本機 → 3 條 actual、2 條 static(含 address、flags)。
- `FindAdsTargets`:target = UmRT → `ROUTE_SEARCH_REQUIRES_LOCAL_TARGET`(`data.localNetId 192.168.50.168.1.1`,hint 是 MCP 寫法);`SetTarget AmsNetId=192.168.50.168.1.1 NoPlatformSwitch=true` 後 broadcast 4105 ms、`Search=127.0.0.1` 4087 ms,都是 `targets []` + note。之後 `SetTarget AmsNetId=199.5.42.250.1.1 Platform='TwinCAT OS (x64)'` 切回(projectCheck ok)。
- `AddAdsRoute`(全部 dry-run,沒有送出任何 route):
  - 沒有 PasswordEnv → `ROUTE_PASSWORD_MISSING`(message 有 PowerShell 寫法，見 N4)。
  - `PasswordEnv=PATH` → `INVALID_PARAMS`「must be named TCAUTO_ROUTE_PW or TCAUTO_ROUTE_PW_<SUFFIX>」,沒讀環境變數。
  - `PasswordEnv=TCAUTO_ROUTE_PW_T46`(server 行程沒有這個變數)→ `ROUTE_PASSWORD_MISSING`「is empty or not set in this process」。
  - `ProjectRoute=true` dry-run → `command AddProjectRoute`,`measured false`,沒有密碼欄位(4026、4024)。
- 密碼遮罩:`ProduceXml TISY` 在 4026、4024 都 `TREEITEM_NOT_FOUND`(頂層只有 TIPC / TIID / TIRC / TIRS / TIRT / TINC / TIRR);TIRS 也沒有 BootSettings。**LogonPassword 遮罩這次無法實測**(N5)。
- 沒改 StaticRoutes.xml、沒重啟 service。

## 發現的問題

### B1(bug):`LinkNcAxis` 一律回 `NC_PLC_VARIABLE_NOT_FOUND`

- 原因:`Resolve-TcPlcAxisImage`(`src/TwinCATAutomation/Private/NcAxis.ps1` 約 342 行)和 `Resolve-TcPlcInstancePath` 用 `Get-TcTreeItemChildList` **列舉** PLC instance(ItemType 57)的子節點來找 `* Inputs` / `* Outputs`;真 COM 上 PLC instance 的 `ChildCount` 是 0、列舉回空，但 `LookupChild` / `LookupTreeItem('<instance>^PlcTask Inputs')` 可以用(和 `<Plc> Project` 節點不出現在列舉裡是同類現象)。單元測試的 mock 會列舉出子節點，所以沒抓到。probe 第 5 題是直接 lookup 完整 path,沒走列舉。
- 重現(4026 VS2022 與 4024 XAE Shell 都一樣):`ConnectIde` → `BuildProject` → `LinkNcAxis Axis=<任一軸> PlcVariable=GVL_Motion.arAxisCtrl_gb[5].Admin.Axis`(4024 用 `GVL_Axes.axisDraw`)→ `NC_PLC_VARIABLE_NOT_FOUND`,`data.instanceChildren []`;同時 `LookupTreeItem Path='TIPC^AxisInterface^AxisInterface Instance'` → `childCount 0`,`LookupTreeItem Path='TIPC^AxisInterface^AxisInterface Instance^PlcTask Inputs'` → 40 個子節點。
- 影響:`LinkNcAxis` 在真機完全不能用(link 成功路徑、`NC_AXIS_ALREADY_LINKED`、modal rollback 都測不到)。修法方向：找 task image 時改用 `TIRT` 的 task 名稱拼 `<instance>^<task> Inputs` 再 lookup,不要靠列舉 instance。

### B2(bug):`SetIndependentFile` 掃整個資料夾找 `.tsproj`

- 4026 副本的 solution 資料夾有 3 個 `.tsproj`,`.sln` 只參照其中一個，模組回 `INDEPENDENT_FILE_TSPROJ_AMBIGUOUS`,什麼都不能做。XAE 開的是哪一個 `.tsproj` 其實知道(sln / DTE Project.FullName)。
- 重現:4026 副本原樣 → `SetIndependentFile Path='TINC^NC-Task 1 SAF^Axes^Axis 1' Enabled=true DryRun=false` → `INDEPENDENT_FILE_TSPROJ_AMBIGUOUS`,`tsprojFiles` 3 個。
- 同一類:`SetVariantConfig` / `SwitchVariant` 的 `backupFiles` 也把 3 個 `.tsproj` 都備份(無害，只是多餘)。

### N1:同一 runtime 只能有一個 `TcNtpExternalTimeProvider`

- 不是模組 bug,是測試資料的限制：第二個 instance 在 Activate 時 `Register ExternalTime failed, HR=98110708`(0x708 device is busy),XAE 跳 fatal error dialog。`AddTcComModule` 不擋(XAE 也不擋)。實測 2026-11-01 4026 VS2022 + UmRT,InfoSys 沒查到出處。測 TcCOM 時一個 runtime 只放一個 NTP instance。

### N2:TIME 型別參數

- `TcNtpExternalTimeProvider.PollInterval` 的 baseType 是 `TIME`(probe 文件寫 UDINT)。`GetTcComParameter` 回 `rawHex` 正確但 `value null`;`SetTcComParameter` 回 `TCCOM_PARAM_UNSUPPORTED_TYPE`,hint 卻寫「不是基本型別(struct / array)」,和 message 的「TIME (4 bytes)」不一致。TIME 是 4 byte 的 ms 整數，可考慮支援(或至少改 hint)。

### N3:4024 NTP 的 TMC 版本不同

- 4024.71 的 `TcNtpExternalTimeProvider` 沒有 `ClientEnable` 等獨立參數，client 設定在 struct `ClientPara` 裡;tool 無法寫 struct,所以 4024 無法用 tool 關掉 NTP client。整合測試在 4024 不要 Activate NTP instance。

### N4:`ROUTE_PASSWORD_MISSING` 的 message 有 PowerShell 寫法

- message「AddRoute needs exactly one of PasswordEnv (environment variable name) and -Password (SecureString)」:MCP 沒有 `Password` 參數，`-Password` 是 cmdlet 寫法(hint 本身是 MCP 寫法)。

### N5:`TISY` 查不到

- TE1000 手冊的 `TISY`(BootSettings / LogonPassword)在 4026.22 VS2022 和 4024.71 XAE Shell 上 `LookupTreeItem` 都找不到。單元測試用 mock 的 `TISY` 驗遮罩;真機上 LogonPassword 在哪個節點、會不會出現在 ProduceXml 還不知道。

### 觀察(不是問題)

- `SetTarget AmsNetId=<本機> NoPlatformSwitch=true` 回 `data.platform "TwinCAT RT (x64)"`,但下一次 `SetTarget` 的 `previousPlatform` 是 `TwinCAT OS (x64)`、Build 也是 OS (x64);NoPlatformSwitch 時回報的 platform 值可能讀的是別的東西。沒有影響結果，沒深究。
- online 寫入前的 boot 比對：目前 variant 的 `_Boot\<Variant>\<Platform>` 還不存在時 fallback 到 `_Boot\<Platform>` 並加 warning;target 真的跑舊組態時 match 是對的，跑別的 variant 時就 mismatch(上面 `TCCOM_ONLINE_CONFIG_MISMATCH` 就是這樣觸發的)。
- 每次 Build 的 Error List 都有「Unknown TMC file version found - ignoring the file」(4026 `AxisInterface.tmc`),和第 3 期無關。

## 還原確認

- 開始前 robocopy `/MIR` 備份到 `C:\Temp\Verify-4026-axis-baseline-46`、`C:\Temp\Verify-4024-bfh-baseline-46`,逐檔 SHA-256 manifest(`Get-ChildItem -Recurse -File -Force`):4026 266 檔、4024 302 檔，副本與 baseline 一致;4024 Device 1 / Device 5 都是 `Disabled="true"`。
- 結束時兩個 IDE 都 `DisconnectIde Quit=true`(4026 pid 106056、4024 pid 34512;`devenv` / `TcXaeShell` 行程都沒了),再用 baseline `/MIR` 還原，逐檔比對:
  - `Verify-4026-axis`:266 / 266,**SHA-256 全部相同**,沒有多或少(暫移出的兩個 `.tsproj` 也由 `/MIR` 放回;暫存資料夾 `C:\Temp\Verify-4026-axis-hold46` 已刪)。
  - `Verify-4024-bfh`:302 / 302,**SHA-256 全部相同**;Device 1 / Device 5 仍是 `Disabled="true"`。
- 沒有 attach 或操作其他 IDE;library repository 沒動;StaticRoutes.xml 沒動。
- **UmRT 最後狀態**:`TcSystemServiceUm` pid 102904 仍在跑，**AdsState = Run**,跑的是 4024 副本 Variant1 的組態(最後一次 Activate,含沒 link 的 `AxisT46`,沒有 TcCOM instance)。副本已還原，下一個測試要用 `EnableConfig Force=true` 重新 Activate 自己的專案。UmRT 的 `Boot` 目錄被這次 Activate 改寫(預期內)。
