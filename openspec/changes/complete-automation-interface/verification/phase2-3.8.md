# Task 3.8:第 2 期 17 個新 tool 的 registered tcauto 實測

- 方式：**registered tcauto**(`mcp__tcauto__*`,Claude Code 已註冊的 TcAuto MCP server)。沒有用 `Import-Module` 或自建 client。開始前用 ToolSearch 確認 17 個 tool 都在。
- 日期:2026-10-31(UTC 14:11–14:40)。主機：本機(Windows 11 26200)。全程離線：沒有 Activate、沒有 Login;`TcSystemServiceUm` 本來就不在，沒有碰，所以沒有跑 `Watch-Runtime.ps1`。
- 環境標記(下文簡寫):
  - **4026** = `VisualStudio.DTE.17.0`(VS2022 17.14.36811.4),TwinCAT 3.1.4026.22(登錄檔 `TcVersion`),副本 `C:\Temp\Verify-4026-axis\AxisInterface_Type01_Library.sln`,solution / project platform 都是 `TwinCAT OS (x64)`。ConnectIde launched pid 65840(connectSec 43.4)。
  - **4024** = `TcXaeShell.DTE.15.0`(32-bit XAE Shell),專案 `TcVersion 3.1.4024.71`,副本 `C:\Temp\Verify-4024-bfh\BFH-1650.sln`,`SetTarget AmsNetId=199.5.42.250.1.1 NoPlatformSwitch=true`(platform `TwinCAT RT (x64)`,adsError 0x7 因 UmRT 不在)。ConnectIde launched pid 45560(connectSec 100.6)。
- 每個 tool 的耗時：取自回傳的 `order.startedAt / finishedAt`(wall time,含 bridge),括號內是 tool 自己回報的 `*Sec`。
- 錯誤碼與 hint 照回傳原文抄。hint 有沒有出現 cmdlet 名稱、PowerShell 參數寫法，逐條標在「hint 檢查」欄，彙整在「發現的問題」。
- 原始紀錄(逐呼叫的重點):`C:\Users\aka09\AppData\Local\Temp\claude\C--Users-aka09-OneDrive----10-Works-Beckhoff-InternalProject-TwinCAT-AI-coding-2026-AI-TwinCAT-Skill\f3528917-15e7-45a3-8fab-e0c3ce11929f\scratchpad\p38\notes.md`;匯出檔在同目錄的 `out4026\`、`out4024\`。

## 結果總表

| tool | 4026 | 4024 | 結論 |
|---|---|---|---|
| `AddInterface` | 通過 | 通過 | 通過 |
| `AddPouMember` | 通過 | 通過 | 通過(hint 有問題 P1) |
| `GetLibraries` | 通過 | 通過 | 通過;frozen 語意見 3 |
| `AddPlaceholder` | 通過 | 通過 | 通過 |
| `RemoveReference` | 通過 | 通過 | 通過 |
| `InstallLibrary` | 通過 | 通過 | 通過(dry-run 不驗 repository,P8) |
| `UninstallLibrary` | 通過 | 通過 | 通過;還原方式見 6 |
| `FreezePlaceholder` | **單一通過、All 失敗** | 單一通過、All 回 success 但改了版本 | **有問題(P2、P3)** |
| `CheckAllObjects` | 通過 | 支援(專案本身有錯，只測到 CHECK_FAILED) | 通過 |
| `AddPlcTask` | 建立 / 讀回通過 | 通過 | **有問題(P4:沒存檔)** |
| `LinkProgramToTask` | 通過 | 通過 | 通過(hint 有問題 P1) |
| `UnlinkProgramFromTask` | 通過 | 通過 | 通過;`.zip` 匯不出，只能用 `.TcTTO` 還原 |
| `ExportPlcOpen` | 物件 / 資料夾通過，整專案讀回錯 | 通過 | **有問題(P5)** |
| `ImportPlcOpen` | 四種 Option 實寫通過、Replace 預告多報 | 通過 | **有問題(P6)** |
| `GenerateBootProject` | 通過 | 通過 | 通過 |
| `SaveAsLibrary` | 通過 | 通過 | 通過，但會存 `.plcproj`(P7) |
| `SaveArchive` | 通過(Solution 回 ARCHIVE_INCOMPLETE 是正確判斷) | 通過 | 通過 |

---

## 1. AddInterface

registered tcauto 實測 2026-10-31 本機 4026 / 4024。沒有 DryRun 參數(tool 不提供)。

| 呼叫 | 環境 | 結果 | 耗時 |
|---|---|---|---|
| `Name=I_P38Base` | 4026 | success,`declaration "INTERFACE I_P38Base\n"`、itemType 618、`projectSaved.verifiedFiles [I_P38Base.TcIO]`、`plcprojChanged true` | 2.85 s |
| `Name=I_P38Ext Extends=I_P38Base` | 4026 | success,`declaration "INTERFACE I_P38Ext EXTENDS I_P38Base\n"` | 2.0 s |
| `Name=I_P38` | 4024 | success,建在 `POUs^I_P38`(有 POUs 資料夾時自動放進去) | 1.9 s |
| `Extends='1bad; x'` | 4026 | `INVALID_PARAMS`,沒建。hint "Pass the name of the interface to extend, e.g. -Extends I_Base, or leave -Extends out." | 0.01 s |
| 同名 `I_P38Base` | 4026 | `POU_CREATE_FAILED`,message 標 `exists` 與既有 path | 0.4 s |

- 讀回：回傳的 declaration 來自新節點;`.plcproj` 讀回有 `<Compile Include="I_P38Base.TcIO">`。
- hint 檢查：`INVALID_PARAMS` 用 PowerShell 參數寫法 `-Extends`;`POU_CREATE_FAILED` 的 **message** 寫 `Write-TcPouCode -PouPath`(cmdlet 名稱),hint 寫 `AddPou PlcProjectPath=true`(值錯，應是路徑)。見 P1。

## 2. AddPouMember

registered tcauto 實測 2026-10-31 本機 4026 / 4024。沒有 DryRun 參數。父 FB 用 `AddPou FB_P38`(4026 建在專案根，4024 建在 `POUs`)。

**非 PUBLIC 的讀回格式(原「未實測」)**:4026 / 4024 完全相同。

| 呼叫 | 讀回 declaration | vInfo | 耗時(4026) |
|---|---|---|---|
| Method `M_Priv` PRIVATE BOOL | `METHOD PRIVATE M_Priv : BOOL` | `["1","BOOL","PRIVATE"]` | 1.29 s |
| Property `P_Prot` PROTECTED INT | `PROPERTY PROTECTED P_Prot : INT` | `["1","INT","PROTECTED"]` | 1.22 s |
| Method `M_Int` INTERNAL DINT LD | `METHOD INTERNAL M_Int : DINT`,language LD | `["6","DINT","INTERNAL"]` | 1.21 s |
| Get(`ParentPath=FB_P38.P_Prot`) | `PUBLIC\nVAR\nEND_VAR`,resolvedBy dot-path | `["1","PUBLIC"]` | 1.26 s |
| Set(完整 tree path) | `PUBLIC\nVAR\nEND_VAR` | `["1","PUBLIC"]` | 0.82 s |
| Action `A_Reset` | declaration null(action 沒有宣告) | `"1"` | 1.06 s |
| ITF Method `M_Do` BOOL | `METHOD M_Do : BOOL\nVAR_INPUT\nEND_VAR` | `"BOOL"` | 1.11 s |
| ITF Property `P_Cnt` DINT | `PROPERTY P_Cnt : DINT` | `"DINT"` | 0.85 s |

- `GetPouCode PouName=FB_P38.M_Priv`(dot-path)、`FB_P38.P_Prot.Set`、`M_Do`(tree-search)讀回和建立時一致。
- 小瑕疵:Action 的 `data.access` 回 `"PUBLIC"`(action 沒有 access)。

錯誤路徑(4026,都沒有建立任何東西):

| 呼叫 | code / reason | hint |
|---|---|---|
| Get 在 ITF property `I_P38Base.P_Cnt` 底下 | `POU_MEMBER_UNSUPPORTED` / `itf-property-accessor` | "Leave the interface property without accessors and implement Get / Set in the function block ... (AddPouMember ParentPath='<FB path>^<property>' Kind=Get)." ✓ |
| Access `FRIEND` | `POU_MEMBER_INVALID` / `access` | "Pass -Access PUBLIC, PRIVATE, PROTECTED or INTERNAL." |
| 名稱 `m_priv`(大小寫不同) | `POU_MEMBER_EXISTS`,`existingPath ...^M_Priv` | "...換一個 -Name;要改既有的就用 WritePouCode PouPath=<data.existingPath>..." |
| Method 無 ReturnType + PRIVATE | `POU_MEMBER_UNSUPPORTED` / `method-no-return-type` | "Pass -ReturnType (e.g. BOOL), or omit -Access / -Language; ... WritePouCode." |
| 父節點是 GVL | `POU_MEMBER_INVALID` / `parent-kind` | **"Look the parent up with GetProjectTree PlcOnly=and pass its path as -ParentPath."**(壞掉，P1) |

- 每次呼叫約 0.2–0.5 s(錯誤)/ 0.8–1.3 s(建立)。

## 3. GetLibraries

registered tcauto 實測 2026-10-31 本機 4026 / 4024。

- 4026:References 25 筆(0.88 s);`Repository=true Filter=P38*` 0 / 473 筆(2.2 s)。4024:`Filter=Tc2_*` 4 / 15 筆(0.73 s);Repository 380 筆。
- `frozen` 和 `.plcproj` `<PlaceholderResolution>` 逐筆比對一致(4026 原本就有 Tc2_Drive / Tc2_Math / Tc2_MC2* / Tc2_System / Tc3_IPCDiag / Tc3_JsonXml / Tc3_MC2_AdvancedHoming 被凍結)。
- **用固定版本新增的 placeholder(原「未實測」)**:`AddPlaceholder P38_PH2 Tc2_Math 3.5.1.0` 後 XAE 直接寫 `<PlaceholderResolution><Resolution>Tc2_Math, 3.5.1.0 (...)`,GetLibraries 讀成 **`frozen = true`**,沒有 freeze 過也一樣。反過來，既有 `#Tc2_Standard` 的 DefaultResolution 是固定 3.4.5.0、但 `.plcproj` 沒有 `<PlaceholderResolution>`,讀成 `frozen = false`。也就是 `frozen` 的實際意思是「`.plcproj` 有固定版本的 Resolution」,不是「呼叫過 FreezePlaceholder」,也不是「解析版本不會變」。
- visu placeholder:4026 的 `#System_Visu*` 7 筆 `effectiveResolution` 是 null(`resolvedFrom default`);4024 同類 placeholder 都有 EffectiveResolution。
- 錯誤路徑:`PlcProjectPath=NoSuchPlc` → `PLC_PROJECT_NOT_FOUND`,`data.plcProjects` 列出候選(0.24 s)。hint 有 `-PlcProjectPath`(PS 參數寫法)。

## 4. AddPlaceholder

registered tcauto 實測 2026-10-31 本機 4026 / 4024。沒有 DryRun 參數。

| 呼叫 | 結果 | 耗時 |
|---|---|---|
| 4026 `P38_PH1 Tc2_Math`(`*`) | success,`projectEntry.resolution "Tc2_Math, * (...)"`、`frozen false`、`namespace Tc2_Math` | 2.3 s |
| 4026 `#P38_PH2 Tc2_Math 3.5.1.0` | success,`projectEntry.resolutionVersion 3.5.1.0`、**`frozen true`**(見 3) | 2.1 s |
| 4026 同名再加 | success `alreadyPresent true`(還是呼叫了 Project.Save,`plcprojChanged false`) | 1.6 s |
| 4026 預設 library 不存在 | `PLACEHOLDER_ADD_FAILED` / `default-library-not-installed`(0x98510001),沒加;`data.buildRequired` 仍登記 "[AddPlaceholder called, refused]" | 0.75 s |
| 4026 不給 LibraryName | `PLACEHOLDER_ADD_FAILED` / `no-device-placeholder`(0x80070057) | 0.72 s |
| 4024 `P38_PH1 Tc2_Math` | success,`projectEntry.namespace null`(4024 不寫 `<Namespace>`) | 1.8 s |

- hint 檢查:MCP 名稱(GetLibraries / InstallLibrary / GetIdeModalDialog),但寫 `-LibraryName`(PS 參數寫法)。

## 5. RemoveReference

registered tcauto 實測 2026-10-31 本機 4026 / 4024。

| 呼叫 | 結果 | 耗時 |
|---|---|---|
| 4026 dry `P38_PH2` | success,`kind Placeholder`、`removeArgument "#P38_PH2"` | 0.72 s |
| 4026 實寫 `P38_PH2` | `verified true`,`.plcproj` 備份 `.tcauto-backup\20261031-221608\` | 2.5 s |
| 4026 實寫 `#P38_PH1`(帶 `#`) | `verified true` | 2.0 s |
| 4024 實寫 `P38_PH1` | `verified true` | 2.2 s |
| 4026 `P38_NoSuch` | `LIBRARY_NOT_FOUND`,`data.references` 列出全部 | 0.49 s |
| 4026 `#Tc2_Math` + `Kind=Library` | `LIBRARY_INVALID_ARGUMENT` / `kind-conflict`(dry-run 就擋) | 0.01 s |

- 讀回:`verified` 之後 GetLibraries 不再列出;結束時 placeholder 清單回到開始前。
- hint 檢查:`LIBRARY_NOT_FOUND` 寫「重跑同一個 cmdlet」;`LIBRARY_INVALID_ARGUMENT` 用 `-Name` / `-Kind` / `-Placeholder` 等 PS 參數寫法。見 P1。

## 6. InstallLibrary / UninstallLibrary / SaveAsLibrary

registered tcauto 實測 2026-10-31 本機 4026 / 4024。只用自己 SaveAsLibrary 產生的 library:先 `ConsumeXml` 把 project info 改成 `P38ProbeLib / P38 Test / 0.0.0.1`(4024:`P38Lib4024 / P38 Test4024 / 0.0.0.2`,原本是空的),讀回 `verified true`,安裝前確認 Repository 沒有 `P38*`。

### SaveAsLibrary

| 呼叫 | 結果 | 耗時 |
|---|---|---|
| 4026 `.library` | success `saved true`、`installed false`、868,948 B | 8.6 s(saveSec 7.87) |
| 4026 同檔再存 | `LIBRARY_SAVE_FILE_EXISTS` / `file-exists` | 0.02 s |
| 4026 `.txt` | `LIBRARY_SAVE_FAILED` / `extension` | 0.01 s |
| 4026 `Overwrite=true` | success,`previousFile <檔>.library.bak`(.bak 留著) | 6.0 s(5.42) |
| 4024 `.library` | success 758,272 B | 4.9 s(4.35) |

- 沒有 DryRun 參數。**會存 `.plcproj`**(兩邊都是):下一個存檔動作讀到的 `lastWriteBefore` 正好是 SaveAsLibrary 的呼叫時刻(4026 14:17:01.8、4024 14:36:52.9),連 ConsumeXml 的暫時 project info 都寫進磁碟了。見 P7。

### InstallLibrary

| 呼叫 | 結果 | 耗時 |
|---|---|---|
| 4026 dry | success,`identityFromFileName null` + warning(檔名不是 `<name>_<version>.library`,要等 XAE 安裝才知道是否已存在) | 2.2 s |
| 4026 dry `Repository=NoSuchRepo` | **success**(dry-run 不驗 repository,P8) | 2.2 s |
| 4026 實寫 `Repository=NoSuchRepo` | `LIBRARY_INSTALL_FAILED` / `repository-not-found`(0x98510001) | 2.6 s |
| 4026 實寫 | success,`installed [P38ProbeLib, 0.0.0.1 (P38 Test)]`(ScanLibraries 讀回) | 7.8 s |
| 4026 再裝一次 | `LIBRARY_ALREADY_INSTALLED`,`preCheck xae`(0x80131620) | 2.4 s |
| 4024 實寫 | success,`installed [P38Lib4024, 0.0.0.2 (P38 Test4024)]` | 14.3 s |

- 4024 與 4026 用同一個 repository 目錄 `C:\ProgramData\Beckhoff\TwinCAT\PlcEngineering\Managed Libraries`(4024 安裝後就出現在那裡);4024 的 ScanLibraries 只列 380 筆、4026 列 473 筆。

### UninstallLibrary

| 呼叫 | 結果 | 耗時 |
|---|---|---|
| 4026 dry | success,`repositoryFolder ...\P38 Test\P38ProbeLib\0.0.0.1`(`measured-default`) | 2.4 s |
| 4026 Version 9.9.9.9 | `LIBRARY_NOT_INSTALLED`,`data.candidates` 有 0.0.0.1 | 2.4 s |
| 4026 Version `*` | `LIBRARY_INVALID_ARGUMENT` / `wildcard`;message 寫 `Uninstall-TcLibrary`(cmdlet 名稱) | 0.01 s |
| 4026 實寫 | `verified true`,`matchesBefore 1 / matchesAfter 0`,備份 4 檔到 `.tcauto-backup\20261031-221829\library-repo\P38ProbeLib\0.0.0.1`;`P38 Test` 公司目錄一起被刪 | 5.7 s |
| 4024 實寫 | `verified true`,備份 4 檔 | 3.8 s |

**備份目錄對不對、複製回去 XAE 認不認(原「未實測」)**:

- 備份內容正確:`browsercache`、`dependencies`、`P38ProbeLib.library`、`projectinfo`,和 repository 版本目錄相同。路徑少了 distributor 這一層(`library-repo\<name>\<version>`),手動複製回去要自己補 `<Distributor>\`。
- 把備份目錄**手動複製回** `Managed Libraries\P38 Test\P38ProbeLib\0.0.0.1`:GetLibraries Repository **沒列出**(ScanLibraries 0 筆);此時 InstallLibrary 備份裡的 `.library` 反而回 `LIBRARY_ALREADY_INSTALLED`。也就是「目錄在、XAE 不認」的半套狀態(同一個 XAE 行程內;沒有測重啟 XAE 之後)。
- 正確的還原方式:**刪掉手動複製的目錄，用 InstallLibrary 安裝備份裡的 `.library`**(4026,success,5.2 s,ScanLibraries 讀回)。
- 結束時 repository 和開始前逐項比對完全相同(2585 項，兩次)。

## 7. FreezePlaceholder

registered tcauto 實測 2026-10-31 本機 4026 / 4024。

| 呼叫 | 結果 | 耗時 |
|---|---|---|
| 4026 dry `P38_PH1` | success,`targets[0] projectResolution "Tc2_Math, * (...)" frozen false` | 1.0 s |
| 4026 實寫 `P38_PH1` | success,`projectResolution "Tc2_Math, 3.5.1.0 (...)" frozen true`,`.plcproj` 備份 | 1.8 s |
| 4024 實寫 `P38_PH1` | success,同上 | 1.3 s |
| 4026 `P38_NoSuch` | `LIBRARY_NOT_FOUND`,`data.placeholders` 列出全部 | 0.81 s |
| 4026 `Placeholder` + `All` | `LIBRARY_INVALID_ARGUMENT` / `target` | 0.02 s |
| 4026 dry `All` | success,warning:7 個 visu placeholder 沒有 EffectiveResolution,"XAE may refuse the whole call" | 0.6 s |
| 4026 實寫 `All` | **`LIBRARY_VERIFY_FAILED` / `not-frozen`,`notFrozen [Tc3_GlobalTypes]`** | 2.8 s |
| 4024 dry `All` | success,warnings [](4024 visu placeholder 都有 EffectiveResolution) | 0.7 s |
| 4024 實寫 `All` | **success**,但版本被改(見下) | 2.4 s |

**`All` 的實際行為(原「未實測」)**,比對 `.plcproj` 前後:

- visu placeholder:4026 那 7 個沒有 EffectiveResolution 的，XAE **也凍結了**(`VisuElems, 4.8.0.0 (System)` 等，取 DefaultResolution 的版本),不是 warning 說的「凍不了 / 整個呼叫被拒」。
- **XAE 凍結的版本不一定是目前的 effective 版本**:
  - 4026 `#Tc2_System`:原本 `<PlaceholderResolution>` 是 3.10.1.0 → All 之後變成 **3.9.1.0**(= DefaultResolution 的版本),之後 GetLibraries 的 effective 也變 3.9.1.0。
  - 4026 `#CBML`:effective `Common Behaviour Model, 4.0.0.0 (CODESYS)` → 凍成 **`3.5.13.0 (3S - Smart Software Solutions GmbH)`**(distributor 也換了)。
  - 4024 `VisuDialogs`:effective 3.5.12.0 → 凍成 **4.8.0.0**;之後的 `.tszip` 裡 `_Libraries/system/visudialogs/4.8.0.0`。模組回 **success**,沒有任何 warning。
- `#Tc3_GlobalTypes`(4026):在 References 裡，但 `.plcproj` 沒有它的 `<PlaceholderReference>`(XAE 隱含加入的),XAE 不寫 Resolution → 模組讀回判定沒凍結 → `LIBRARY_VERIFY_FAILED`。其他 placeholder 已經寫進 `.plcproj` 並存檔。
- 結論：單一 placeholder 的 freeze 正確;`All` 會**靜默改變 library 版本**,模組的讀回只檢查「不是 `*`」,抓不到。見 P2、P3。

## 8. CheckAllObjects

registered tcauto 實測 2026-10-31 本機 4026 / 4024。沒有 DryRun 參數(唯讀)。

| 呼叫 | 結果 | 耗時 |
|---|---|---|
| 4026 正常 | success `passed true`,errors 0、warnings 27 | 9.4 s(checkSec 3.12) |
| 4026 `FB_P38.M_Priv` 實作 `M_Priv := ;`(FB 沒被引用) | `CHECK_FAILED`,errorItems `C0007 Expression expected instead of ';'`,file `FB_P38.TcPOU@M_Priv (Impl)`,line 1 | 7.0 s(0.94) |
| 4026 `PlcProjectPath=NoSuchPlc` | `PLC_PROJECT_NOT_FOUND` | 0.14 s |
| **4024**(原「未實測」) | **支援**。回 `CHECK_FAILED`,10 個 error 都在沒被引用的 `FB_R2RLineControl.TcPOU`(line 130 / 140 / 151 / 160,"'axisRewind' is no component of 'GVL_AXES'" 與 C0032;部分列 code null)。這是副本本身的錯，Build 會過(Build 不編沒被引用的 FB),所以 4024 這份專案走不到 `passed true` | 6.3 s(2.26) |

- hint:"依 data.errorItems 的 file / line 修正程式碼(GetPouCode PouPath=<路徑> 讀、WritePouCode PouPath=<路徑> 改),再重跑 CheckAllObjects..." ✓(MCP 名稱)。
- `WritePouCode Implementation ""` 清空：`cleared true`(4026,3.6 新行為的 registered 實測)。

## 9. AddPlcTask

registered tcauto 實測 2026-10-31 本機 4026 / 4024。4026 TIRS `BaseTime 10000`(100 ns 單位 = 1 ms)。

| 呼叫 | 結果 | 耗時 |
|---|---|---|
| 4026 dry `P38Task 2000 µs Priority 25` | success,`plannedSteps` 4 步、`xml <CycleTime>20000</CycleTime><Priority>25</Priority>` | 0.76 s |
| 4026 dry `PlcTask`(已存在) | `TASK_ALREADY_EXISTS`,`existingIn [TIRT, plc]` | 0.5 s |
| 4026 實寫 `P38Task` | success `verified true`,`readCycleTime 20000`、`readPriority 25`、`linkedTask TIRT^P38Task` | 4.4 s |
| 4026 實寫 `P38Odd 1500 µs`(不是 base time 倍數) | success,XAE 原樣存 `CycleTime 15000`,沒報錯、沒改值;沒給 Priority 時 XAE 給 1 | 4.7 s |
| 4026 實寫 Priority 300 / 63 / 62 | `TASK_CREATE_FAILED` step `cycle-time`:ConsumeXml S_OK 但讀回 Priority 是 **2**;`rolledBack true`(TIRT task 已刪，LookupTreeItem TIRT 確認) | 2.2–2.9 s |
| 4026 實寫 Priority 32 / 47 | success,讀回一致 | 4.0 s |
| 4024 實寫 `P38Task 2000 / 25` | success `verified true` | 4.9 s |

**原「未實測」的回答**:

- **父節點讀回**:`<Prj>` 的 ProduceXml 在 621 前後只差 `ChildCount 15 → 16`(82,141 字元裡只差 1 個字元),其他完全不變。650 見 10(`parentUnchanged true`)。
- **CycleTime 不是 base time 倍數**:XAE 離線時照收(15000 = 1.5 ms,base time 1 ms)。InfoSys 寫 cycle time 是 cycle ticks × base time,要是 base time 的整數倍([Task tab](https://infosys.beckhoff.com/content/1033/tc3_system/5210416139.html)、[Real Time Settings](https://infosys.beckhoff.com/content/1033/tcsystemmanager/1086417035.html))。模組 dry-run / 實寫都沒有警告;線上(Activate 後)XAE / runtime 怎麼處理沒測。
- **Priority 範圍**:InfoSys「Priorities」頁:可選 1 到 61,一個 priority 只能有一個 task([Priorities tab](https://infosys.beckhoff.com/content/1033/tc3_system/5206503819.html))。實測 32、47 可以;62、63、300 被 XAE 靜默換成下一個空的 priority(2),模組讀回不符、回滾、回錯誤 —— 結果正確(fail-closed),但 dry-run 沒先擋。和既有 task 撞 priority 的情況沒測。
- **重大問題：沒存檔**(P4):`AddPlcTask` 回 `verified true` 後，`.tsproj` / `.plcproj` 都沒寫。接著 `ResetSolution`(預設，以及 `SaveProjectChanges=true`,兩次)之後，4 個新 task 在 TIRT 和 `<Prj>` 底下**全部消失**;`ResetSolution` 的 projectCheck `missingOnDisk []`,沒偵測到(文件寫 tasks not detected)。後來用 `AddGvl`(會 Project.Save)才把 `P38Task` 寫進 `.tsproj` 與 `.plcproj`(`<Compile Include="P38Task.TcTTO">`)。
- hint 檢查:`verifyHint` 寫 `Enable-TcConfig -Force`、`Read-TcVariable -Path`(cmdlet 名稱);`TASK_CREATE_FAILED` hint "DeleteChild Path=<path> ConfirmName=<Name> **DryRun=true $false -AllowNoExport**"(壞掉)。見 P1。

## 10. LinkProgramToTask

registered tcauto 實測 2026-10-31 本機 4026 / 4024。

| 呼叫 | 結果 | 耗時 |
|---|---|---|
| 4026 dry `TestCam → P38Task` | success,`plannedPath ...^P38Task^TestCam` | 0.61 s |
| 4026 實寫 | success `verified true`,`itemType 650`,**`parentUnchanged true`**,`.TcTTO` 備份 | 1.2 s |
| 4024 實寫 `RollToRoll_Type01 → P38Task` | success `verified true`、`parentUnchanged true` | 1.6 s |
| 4026 `FB_P38`(FB) | `TASK_PROGRAM_INVALID` / `not-a-program`(pouType FunctionBlock) | 0.5 s |
| 4026 `testcam` | `TASK_PROGRAM_INVALID` / `case-mismatch`,`actualName TestCam` | 0.49 s |
| 4026 `PlcTask=NoSuchTask` | `TASK_NOT_FOUND`,`data.plcTasks` | 0.37 s |
| 4026 重複連結 | `TASK_PROGRAM_ALREADY_LINKED`,`existingLink TestCam` | 0.47 s |

- hint 檢查:`TASK_NOT_FOUND` "AddPlcTask Name=<Name> CycleTimeUs=<us> **DryRun=true $false**"、`TASK_PROGRAM_ALREADY_LINKED` "UnlinkProgramFromTask ... **DryRun=true $false**"(壞掉);`case-mismatch` 寫 `-ProgramName`。見 P1。

## 11. UnlinkProgramFromTask

registered tcauto 實測 2026-10-31 本機 4026 / 4024。

| 呼叫 | 結果 | 耗時 |
|---|---|---|
| 4026 dry | success,`callCount 1`、`callPath` | 0.37 s |
| 4026 `Main`(沒連) | `TASK_PROGRAM_NOT_LINKED`,`linkedPrograms [TestCam]` | 0.28 s |
| 4026 實寫(兩次) | success `verified true`、`remainingCalls 0` | 1.2–1.3 s |
| 4024 實寫 | success `verified true` | 1.6 s |

**原「未實測」的回答**:

- **650 的 `.zip` 匯出**:匯不出。4026 / 4024 都是 warning "ExportChild backup failed (No content in ZIP file.)",只有 `.TcTTO` 備份。warning 裡寫 `Reset-TcSolution`(cmdlet 名稱)。
- **用 `.TcTTO` 還原**:在 task 已經存進專案檔的前提下可行。把備份 `.TcTTO` 複製回 `P38Task.TcTTO`(還原前磁碟檔沒有 TestCam、還原後有)→ `ResetSolution`(14.7 s)→ `LookupTreeItem <Prj>^P38Task` 有 `TestCam [650]`。task 本身沒存檔時(P4),ResetSolution 會連 task 一起丟掉。

## 12. ExportPlcOpen

registered tcauto 實測 2026-10-31 本機 4026 / 4024。沒有 DryRun 參數(不改專案)。

| 呼叫 | 結果 | 耗時 |
|---|---|---|
| 4026 `[FB_P38, I_P38Base]` | success 8,864 B,objects 2:FB_P38 members A_Reset / M_Int / M_Priv / P_Prot;**I_P38Base members []** | 1.2 s(exportSec 0.21) |
| 4026 `[Basic Function]`(資料夾) | success 34,527 B,3 個物件 **`folder "Basic Function"`** | 1.05 s |
| 4026 `[AxisInterface.LIB.AxisControl.FB_AxisControl]` | success 949,306 B,members 40;**`folder null`** | 1.3 s |
| 4026 不給 Selection(整專案) | success 2,076,451 B,但 **objects 只列 6 個 GVL**(`GVL_Motion` 出現 3 次) | 1.1 s |
| 4024 `[POUs.FB_P38, POUs.I_P38]` | success 5,775 B;`folder null` | 1.2 s |
| 4026 第二個元素 `' POUs.FB_A '` | `PLCOPEN_FAILED` / `selection-not-found`(0x98510008,XAE 訊息是 trim 後的 `POUs.FB_A`) | 2.5 s |
| 4026 檔案已存在 | `PLCOPEN_FILE_EXISTS` | 0.01 s |
| 4026 `FB_P38.M_Priv`(member) | `PLCOPEN_FAILED` / `member-selection`,`suggestedSelection FB_P38` | 0.56 s |

**原「未實測」的回答**:

- **資料夾 selection 的讀回**:選頂層資料夾時，物件的 `folder` 讀回正確(`Basic Function`)。但用資料夾路徑選單一物件(`AxisInterface.LIB.AxisControl.FB_AxisControl`、4024 `POUs.FB_P38`)時 `folder` 是 null(檔案的 ProjectStructure 沒有 Folder 包著它，XAE 只匯出物件本身)。
- ITF method:檔案裡有 `<Interface name="I_P38Base"><Methods><Method name="M_Do">`,模組讀回 `members []`;ITF property `P_Cnt` 只出現在 ProjectStructure(和 probe 一致，沒匯出)。
- 整專案匯出：檔案裡有 21 個 `pou`、48 個 `dataType`(在 `addData` 底下),模組只解析到頂層的 `globalVars`,而且把 `MixedAttrsVarList` 裡的 `GVL_Motion` 多算兩次。見 P5。
- hint 檢查:寫「重跑同一個 cmdlet」與 `-Selection 'POUs.FB_A','DUTs.ST_B'`(PS 寫法)。

## 13. ImportPlcOpen

registered tcauto 實測 2026-10-31 本機 4026 / 4024。測試檔 `e_obj.xml` = 4026 匯出的 `FB_P38` + `I_P38Base`。匯入前把 `FB_P38.M_Priv` 實作改成 `M_Priv := TRUE; // P38 MODIFIED` 當標記。

**四種 Option 的 dry-run 預告 vs 實寫(原「未實測」)**:

| Option | dry-run 預告 | 實寫結果 | 一致? |
|---|---|---|---|
| None | `PLCOPEN_CONFLICT` / `conflict`,conflicts 2,`willImport []`,PlcOpenImport 沒呼叫 | 同(None 衝突時實寫也不呼叫 XAE) | 一致 |
| Skip | `willSkip [FB_P38, I_P38Base]` | `skipped` 兩個 `unchanged true`,M_Priv 標記還在 | 一致 |
| Rename | `willRename` → `FB_P38_1`、`I_P38Base_1`(`nameTaken false`) | `added FB_P38_1 / I_P38Base_1`,`.plcproj` verifiedFiles | 一致 |
| Rename(`_1` 已存在) | `nameTaken true` + warning「名稱未知」 | XAE 用 **`_2`**,`renamed` 讀回正確 | 預告不知道名稱，讀回正確 |
| Replace | FB_P38 `deletedChildren []`;**I_P38Base `deletedChildren [M_Do, P_Cnt]`** | FB_P38 子物件不變、M_Priv 回到匯出時的空實作;**I_P38Base 只刪了 `P_Cnt`,`M_Do` 還在** | **不一致**(預告多報 M_Do,P6) |

- 耗時:dry-run 0.4–0.9 s;Skip 2.9 s、Rename 3.0 s、Replace 6.9 s(備份占大部分)。
- Replace 的備份:`plcopen-replace.xml`(8,901 B)、每個物件的 ProduceXml + 磁碟檔副本 + ExportChild `.zip`(FB_P38 1,167 B、I_P38Base 480 B,都成功)。`data.backup.restore` 是 cmdlet 語法 `Import-TcPlcOpen -FilePath ... -Option Replace -DryRun $false`(restoreNote 有附 MCP 形式);`how` 寫 `Reset-TcSolution`、`Import-TcTreeItem`。見 P1。
- **Replace 的 PLCopen 備份能不能還原**:能。`ImportPlcOpen FilePath=<backup.xmlPath> Option=Replace DryRun=false` → `GetPouCode FB_P38.M_Priv` 讀回 `M_Priv := TRUE; // P38 MODIFIED`(4.3 s)。
- **ITF property(diskOnly)的還原**:能。把 `diskFileCopy`(`I_P38Base.TcIO`,有 P_Cnt)複製回磁碟 → `ResetSolution`(17.2 s,projectCheck complete)→ `LookupTreeItem I_P38Base` 有 `M_Do`、`P_Cnt`。`.zip` + ImportChild 這條沒測。
- **不同資料夾的同名物件算不算衝突**:算。把檔案 ProjectStructure 改成 FB_P38 在 `Basic Function` 底下(專案裡的 FB_P38 在根目錄):Skip 實寫 → XAE 沒建任何東西(`Basic Function` 仍是 3 個子物件);Rename 實寫 → XAE 建 `Basic Function^FB_P38_3`(`_1`、`_2` 已占用)。模組「整個專案比對名稱」和 XAE 一致。
- 4024:Rename 實寫 → `FB_P38_1`、`I_P38_1`,建在 `<Prj>` 根目錄(檔案沒有 Folder),`.plcproj` verifiedFiles,2.1 s。
- 錯誤路徑:檔案不存在 → `PLCOPEN_FAILED` / `file-missing`;不是 XML(`notes.md`)→ `PLCOPEN_FAILED` / `invalid-file`(訊息帶 PowerShell 在地化例外文字)。

## 14. GenerateBootProject

registered tcauto 實測 2026-10-31 本機 4026 / 4024。沒有 DryRun 參數。前後比對三個目錄(副本 `_Boot`、`%ProgramData%\Beckhoff\TwinCAT\3.1\Boot`、UmRT `...\Runtimes\UmRT_Default\3.1\Boot`)的長度與 mtime。

| 呼叫 | 結果 | 耗時 |
|---|---|---|
| 4026 | success,`bootDir _Boot\TwinCAT OS (x64)\Plc`;bootFiles 9 個，`updated true` 7 個(.app / .autostart / .cid / .crc / .occ / .ocm / _boot.tizip) | 9.3 s(generateSec 6.68) |
| 4024 | success,`bootDir _Boot\TwinCAT RT (x64)\Plc`;`updated true` 8 個(多 .tmc / .tpy,.ocm 沒更新) | 5.3 s(4.4) |
| 4026 沒被引用的 GVL 宣告有語法錯 | **success**(XAE 不編沒被引用的 GVL;boot 檔照常更新) | 5.8 s |
| 4026 被 task 呼叫的 `PRG_P38` 實作 `nUndefinedP38 := ;` | `BOOTPROJECT_FAILED` / `generate-failed`(0x80004005,xaeMessage 只有在地化 E_FAIL 文字),errorItems `C0007 ... PRG_P38.TcPOU (Impl):1` | 14.7 s(1.51) |
| `PlcProjectPath=NoSuchPlc` | `PLC_PROJECT_NOT_FOUND` | 0.18 s |

- **boot 檔讀回(原「未實測」)**:模組回報 `updated true` 的檔案和實際 mtime 變動的檔案逐一相同(4026 7 個、4024 8 個)。兩個 TwinCAT Boot 目錄都沒有變動。
- **solution / project platform 的資料夾**:兩份副本的 solution platform 都等於 project platform(4026 `TwinCAT OS (x64)`、4024 `TwinCAT RT (x64)`),實際寫的是 `_Boot\<該 platform>\Plc`,`bootDirs` 只有一個。兩者不同的情況這次沒有專案可測。
- hint ✓(GetPouCode / WritePouCode / GenerateBootProject / GetBuildErrors / BuildProject / EnableConfig)。

## 15. SaveArchive

registered tcauto 實測 2026-10-31 本機 4026 / 4024。沒有 DryRun 參數。

| 呼叫 | 結果 | 耗時 |
|---|---|---|
| 4026 Solution `.tnzip` | `ARCHIVE_INCOMPLETE`:檔案留著(26,366,698 B、130 entries),Error List 新增 1 列 `'TwinCAT Measurement' (22:30:40.881): Error creating Archive -> 已經加入含有相同索引鍵的項目。` | 7.3 s(saveSec 1.36) |
| 4026 Configuration `.tszip` | success,129 entries,`errorItems []` | 6.7 s(0.93) |
| 4024 Configuration | success,184 entries | 6.9 s(1.5) |
| 4024 Solution | success,185 entries(這份 sln 沒有 Scope 專案) | 6.4 s(0.94) |
| 4026 Configuration 檔案已存在 | `ARCHIVE_FILE_EXISTS` | 0.03 s |
| 4026 `.tnzip` + `Kind=Configuration` | `ARCHIVE_FAILED` / `extension` | 0.01 s |

- **錯誤列是同步還是非同步(原「未實測」)**:同步。錯誤列的時間戳 22:30:40.881(本地),檔案 lastWrite 22:30:40.844,都在呼叫期間(UTC 14:30:36.7–44.0)內，模組這次就讀到。呼叫結束 9 s 後再 `GetBuildErrors`,沒有新增的列(只有更早 GenerateBootProject 留下的 C0007 stale 列)。只量了這一次。
- hint ✓(SaveArchive Kind=Configuration / Overwrite=true;另有 `-FilePath`、`-Overwrite` 的 PS 寫法)。

---

## 發現的問題

沒有修 code。全部可在 registered tcauto 重現。

### P1. hint / message / data 裡的 cmdlet 名稱與壞掉的參數轉換

hint 必須是 MCP tool 名稱。下列實際回傳不符合:

| 位置 | 實際文字 | 問題 |
|---|---|---|
| `AddPouMember` `POU_MEMBER_INVALID` parent-kind hint | "Look the parent up with GetProjectTree PlcOnly=and pass its path as -ParentPath." | `PlcOnly=` 後面的 `true` 不見(轉換壞掉),`-ParentPath` 是 PS 寫法 |
| `AddPlcTask` `TASK_CREATE_FAILED` hint | "DeleteChild Path=<path> ConfirmName=<Name> DryRun=true $false -AllowNoExport" | `-DryRun:$false` 轉成 `DryRun=true $false`;`-AllowNoExport` 沒轉 |
| `LinkProgramToTask` `TASK_NOT_FOUND` hint | "AddPlcTask Name=<Name> CycleTimeUs=<us> DryRun=true $false" | 同上 |
| `LinkProgramToTask` `TASK_PROGRAM_ALREADY_LINKED` hint | "UnlinkProgramFromTask ProgramName=<data.existingLink> PlcTask=<舊 task> DryRun=true $false" | 同上 |
| `AddInterface` `POU_CREATE_FAILED` hint | "...用 GetProjectTree PlcOnly=true 找 <Plc> Project^POUs 的 path 後給 AddPou PlcProjectPath=true" | `PlcProjectPath=true` 應是路徑 |
| `AddInterface` `POU_CREATE_FAILED` **message** | "...or change it with Write-TcPouCode -PouPath '...'" | message 裡的 cmdlet 名稱 |
| `UninstallLibrary` `LIBRARY_INVALID_ARGUMENT` **message** | "...Uninstall-TcLibrary removes exactly one installed version." | message 裡的 cmdlet 名稱 |
| `AddPlcTask` `data.verifyHint` | "After Enable-TcConfig -Force, find n with Read-TcVariable -Path ..." | cmdlet 名稱(應為 EnableConfig Force=true / ReadVariable Path=) |
| `UnlinkProgramFromTask` warning | "...copy it back over '...P38Task.TcTTO', then Reset-TcSolution." | cmdlet 名稱 |
| `ImportPlcOpen` `data.backup.restore` / `diskOnly[].how` | "Import-TcPlcOpen -FilePath ... -Option Replace -DryRun $false";"...run Reset-TcSolution (not measured); or Import-TcTreeItem of ..." | cmdlet 名稱 |
| `LIBRARY_NOT_FOUND`、`LIBRARY_VERIFY_FAILED`、`PLCOPEN_FAILED` hint | 「...重跑同一個 cmdlet」 | 用「cmdlet」這個詞 |
| 多數 hint | `-Name`、`-Kind`、`-LibraryName`、`-Access`、`-ReturnType`、`-ProgramName`、`-PlcProjectPath`、`-Selection 'POUs.FB_A','DUTs.ST_B'`、`-FilePath`、`-Overwrite`、`-Extends`、`-DryRun $true` | PowerShell 參數寫法(MCP 是 `Name=` 形式) |
| 每個寫入 tool 的 `data.buildRequired` | "PLC code changed by Add-TcInterface I_P38Base" 等 | data 欄位裡的 cmdlet 名稱(不是 hint,列出供判斷) |

重現:例如 `AddPouMember ParentPath=GVL_Smoke4026 Kind=Method Name=M_Y`(4026)。

### P2. FreezePlaceholder All 靜默改變 library 版本

- 重現(4026):副本原本 `#Tc2_System` 的 `<PlaceholderResolution>` 是 `Tc2_System, 3.10.1.0`。`FreezePlaceholder All=true DryRun=false` → `.plcproj` 變成 `Tc2_System, 3.9.1.0`(= DefaultResolution),GetLibraries effective 也變 3.9.1.0;`#CBML` 從 effective `4.0.0.0 (CODESYS)` 變成 `3.5.13.0 (3S - Smart Software Solutions GmbH)`。
- 重現(4024):`VisuDialogs` effective 3.5.12.0 → `4.8.0.0 (System)`,回傳 **success**,沒有 warning;`.tszip` 的 `_Libraries` 也變成 4.8.0.0。
- dry-run 的 `targets[].effectiveResolution` 顯示的是舊版本，看不出會變。
- 模組讀回只檢查 Resolution 不是 `*`,沒有比對「凍結後版本 == 凍結前 effective 版本」。
- 4026 visu placeholder 的 dry-run warning 說「FreezePlaceholder cannot freeze such a placeholder」,實際上 XAE 凍結了(用 DefaultResolution 的版本)。

### P3. FreezePlaceholder All 遇到隱含 placeholder 回 LIBRARY_VERIFY_FAILED

- 重現(4026):`FreezePlaceholder All=true DryRun=false` → `LIBRARY_VERIFY_FAILED` / `not-frozen`,`notFrozen [Tc3_GlobalTypes]`。`#Tc3_GlobalTypes` 在 References 裡，但 `.plcproj` 沒有它的 `<PlaceholderReference>`(XAE 隱含加入),XAE 不會寫它的 Resolution。
- 此時其他 placeholder 已經凍結並存檔(備份在 `data.backupFiles`)。回傳 `success: false`,但專案已經改了。

### P4. AddPlcTask 建的 task 沒有存進專案檔

- 重現(4026):`AddPlcTask Name=P38Task CycleTimeUs=2000 Priority=25 DryRun=false` → `verified true`;`.tsproj` 沒有 `P38Task`、`.plcproj` 沒有 `P38Task.TcTTO`(`P38Task.TcTTO` 檔本身有寫到磁碟)。接著 `ResetSolution`(預設)→ TIRT 與 `<Prj>` 底下的 P38Task / P38Odd / P38Pri / P38Pri2 全部消失;`ResetSolution SaveProjectChanges=true` 同樣消失(`savedProjects []`,因為 missingOnDisk 是空的)。
- 對照：同樣的 AddPlcTask 後再 `AddGvl`(會 Project.Save),`.tsproj` 有 `<Name>P38Task</Name>`、`.plcproj` 有 `<Compile Include="P38Task.TcTTO">`。
- 影響:XAE 關閉 / ResetSolution / 沒存檔就結束時，task 不見;`UnlinkProgramFromTask` 建議的 `.TcTTO` 還原也一起失效。
- 類似 #76(AddPou 系列已修成存檔再讀回)。

### P5. ExportPlcOpen 讀回(objects)不完整

- 重現(4026):`ExportPlcOpen FilePath=...\e_all.xml`(不給 Selection)→ `objectCount 6`,只有 GVL(`GVL_Motion` 三次);檔案實際有 21 個 `pou`、48 個 `dataType`,在 `addData` 底下。
- `ExportPlcOpen Selection=[FB_P38, I_P38Base]` → `I_P38Base.members []`,檔案有 `<Interface><Methods><Method name="M_Do">`。
- `Selection=[AxisInterface.LIB.AxisControl.FB_AxisControl]` → `folder null`(資料夾路徑選單一物件時，檔案裡沒有 Folder)。
- 影響：整專案匯出時讀回不能拿來確認內容;ITF 的 members 也影響 P6。

### P6. ImportPlcOpen Replace 的 dry-run 多報被刪的子物件

- 重現(4026):`ImportPlcOpen FilePath=e_obj.xml Option=Replace`(dry-run)→ `willReplace I_P38Base deletedChildren [M_Do, P_Cnt]`;實寫 → `replaced I_P38Base deletedChildren [P_Cnt]`、`childrenAfter "M_Do"`(另外 `childrenAfter` 這裡是字串，不是陣列)。原因同 P5:解析檔案時沒把 `<Interface><Methods>` 當成 member。
- 方向是保守的(多報不會漏報),但預告不準。

### P7. SaveAsLibrary 會存 .plcproj

- 重現：在 4026 用 `ConsumeXml` 暫時改 project info(只在 XAE 記憶體)→ `SaveAsLibrary` → 之後第一個存檔動作讀到的 `.plcproj` `lastWriteBefore` 是 SaveAsLibrary 的呼叫時刻(14:17:01.8),而且磁碟 `.plcproj` 的 `<Title>` 已經是暫時值 `P38ProbeLib`。4024 同樣(14:36:52.9)。
- tool 說明寫「Does not change the project」;probe 3.4 記的是「只更新 `.~u`」。實際會把 XAE 記憶體的未存改動寫進 `.plcproj`。

### P8. InstallLibrary dry-run 不檢查 repository

- 重現(4026):`InstallLibrary LibraryPath=... Repository=NoSuchRepo`(dry-run)→ success;實寫才回 `LIBRARY_INSTALL_FAILED` / `repository-not-found`。

### 其他觀察(不算問題)

- `AddPlaceholder` 對已存在的 placeholder 回 `alreadyPresent true`,但仍呼叫 Project.Save。
- `AddPlaceholder` 被拒(`PLACEHOLDER_ADD_FAILED`)時仍登記 BUILD_REQUIRED(`[AddPlaceholder called, refused]`)。
- `AddPouMember` Action 的 `data.access` 回 `"PUBLIC"`。
- `SaveAsLibrary Overwrite=true` 成功後 `<檔>.library.bak` 留著。
- GenerateBootProject 失敗後 Error List 的 C0007 會留著，下一個 SaveArchive / GetBuildErrors 還看得到(SaveArchive 用前後比對，沒有誤判)。

## 還原與確認

- 開始前:`robocopy /MIR` 兩個副本到 `C:\Temp\Verify-4026-axis-baseline-38\`(266 檔)、`C:\Temp\Verify-4024-bfh-baseline-38\`(302 檔);4024 的 EtherCAT Device 1 / 5 仍是 `Disabled="true"`。Library repository 快照 2585 項(465 個版本目錄)。
- 結束時:兩個 IDE 都用 `DisconnectIde Quit=true` 關掉(4026 pid 65840、4024 pid 45560,`ownedBySession true`),之後沒有任何 `devenv` / `TcXaeShell` 行程。`robocopy <baseline> <副本> /MIR` 還原後，副本與 baseline 目錄逐檔 SHA-256 比對:4026 266 / 266、4024 302 / 302,**差異 0**。
- Library repository 和開始前逐項相同(差異 0);`P38 Test`、`P38 Test4024` 目錄都不存在。使用者原有的 `AxisInterface` 等 library 沒有碰。
- 沒有 attach 或操作使用者開著的 IDE(開始時本機沒有任何 IDE 行程)。
- 留下的檔：兩個 baseline 目錄、scratchpad 的 `p38\`(notes、匯出檔、archive、library 檔)。
