# Task 3.8 重測:P1–P8 修正的 registered tcauto 真機驗證

- 方式：**registered tcauto**(`mcp__tcauto__*`)。沒有 `Import-Module`、沒有自建 client。
- 日期:2026-11-01(本地 00:27–00:41,UTC 2026-10-31 16:27–16:41)。主機：本機 Windows 11 26200。全程離線(沒有 Activate / Login;`TcSystemServiceUm` 本來就不在，沒跑 `Watch-Runtime.ps1`)。
- 受測程式碼:branch `openspec/complete-automation-interface-phase2` HEAD `812e369`(修正 commit `95c11a4` `0af2f78` `8f78c28` `7d3eac8` `1cc2a6f` `ab1d7de` `a6d652b` `f4185c0` `812e369`)。
  - 載入確認:MCP server node 行程(pid 83364)啟動於 00:25:27,晚於 HEAD commit 時間 00:13:18;bridge 在本次第一個呼叫時才啟動、載入當下的 `TwinCATAutomation.psm1`。實際回傳也是新行為(第一個 P1 呼叫 `GetProjectTree PlcOnly=true`、`ParentPath`,不再是 `PlcOnly=and` / `-ParentPath`)。
- 環境:
  - **4026** = `VisualStudio.DTE.17.0`(VS2022),TwinCAT 3.1.4026.22,副本 `C:\Temp\Verify-4026-axis\AxisInterface_Type01_Library.sln`,platform `TwinCAT OS (x64)`。ConnectIde launched pid 114924(connectSec 35.5,`ownedBySession true`)。
  - **4024** = `TcXaeShell.DTE.15.0`(32-bit XAE Shell),專案 3.1.4024.71,副本 `C:\Temp\Verify-4024-bfh\BFH-1650.sln`,platform `TwinCAT RT (x64)`。ConnectIde launched pid 15436(connectSec 34.6)。
- 原始紀錄與匯出檔:scratchpad `...\179bcdc2-0756-440a-aba5-9a1385f47bb2\scratchpad\rt\`。

## 結果總表

| P | 結果 | 一句話 |
|---|---|---|
| P1 hint / message / data 轉換 | **通過(有殘留，見新發現 N1–N3)** | 3.8 表列的壞轉換全部消失;`GetLibraries` `PLC_PROJECT_NOT_FOUND` hint 仍有 `-PlcProjectPath` |
| P2 FreezePlaceholder 改版本 | **通過** | 4026 / 4024 `All` 實寫後 `<Resolution>` = 凍結前 effective(`pinned [CBML, Tc2_System]`、`pinned [VisuDialogs]`);單一路徑不需要釘回;`LIBRARY_VERSION_CHANGED` 觸發不了 |
| P3 隱含 placeholder | **通過** | `Tc3_GlobalTypes` 進 `skipped[]`(implicit)、All 回 success;單一實寫在呼叫前擋下 `implicit-placeholder` |
| P4 AddPlcTask 存檔 | **通過** | 4026 / 4024 `.tsproj` 有 task、`.plcproj` 有 `.TcTTO`,`ResetSolution` 後 TIRT / PLC 兩個節點都在 |
| P5 ExportPlcOpen 讀回 | **通過(N4)** | 4026 objectCount 73、4024 89,都等於檔案去重後的物件數;ITF members、單選資料夾物件的 folder 正確 |
| P6 ImportPlcOpen Replace 預告 | **通過** | dry-run `deletedChildren [P_Cnt]` = 實寫;`childrenAfter ["M_Do"]` 是陣列 |
| P7 SaveAsLibrary 存 .plcproj | **通過** | 有未存改動 → `projectSaved/projectFileWritten true/true`(磁碟 Title 變成暫時值);沒有 → `false/false`(LastWriteTime 不變) |
| P8 InstallLibrary dry-run 驗 repository | **依設計，但這台機器走不到 repository-not-found** | 4026 / 4024 `Repositories` 都讀回 null → 三態中的 `not-verified`(success + warning);實寫才回 `repository-not-found` |

## P1. hint / message / data 轉換

3.8 P1 表每一列重跑(4026,除非另註)。全部沒有 `DryRun=true $false`、`PlcOnly=and`、`PlcProjectPath=true`、cmdlet 名稱。

| 3.8 的位置 | 這次實際文字(節錄) | 結果 |
|---|---|---|
| `AddPouMember` parent-kind(`ParentPath=GVL_Smoke4026`) | "Look the parent up with GetProjectTree PlcOnly=true and pass its path as ParentPath." | ✓ |
| `AddPouMember` access `FRIEND` | "Pass Access PUBLIC, PRIVATE, PROTECTED or INTERNAL." | ✓ |
| `AddPouMember` 名稱已存在 | "...換一個 Name;要改既有的就用 WritePouCode PouPath=<data.existingPath>" | ✓ |
| `AddPouMember` method 無 ReturnType + PRIVATE | "Pass ReturnType (e.g. BOOL), or omit Access / Language; ... WritePouCode." | ✓ |
| `AddPlcTask` `TASK_CREATE_FAILED`(Priority 63) | "...都用 DeleteChild Path=<path> ConfirmName=<Name> DryRun=false AllowNoExport=true,再重跑 AddPlcTask" | ✓ |
| `LinkProgramToTask` `TASK_NOT_FOUND` | "...要新的 task 先 AddPlcTask Name=<Name> CycleTimeUs=<us> DryRun=false" | ✓ |
| `LinkProgramToTask` `TASK_PROGRAM_ALREADY_LINKED` | "...UnlinkProgramFromTask ProgramName=<data.existingLink> PlcTask=<舊 task> DryRun=false,再 LinkProgramToTask ..." | ✓ |
| `LinkProgramToTask` case-mismatch | "...case-mismatch:改用 ProgramName=<data.actualName>" | ✓ |
| `AddInterface` `POU_CREATE_FAILED` hint | "...當 PlcProjectPath=<path> 重跑同一個 tool" | ✓ |
| `AddInterface` `POU_CREATE_FAILED` **message** | "...or change it with WritePouCode PouPath='TIPC^...^Main'." | ✓ |
| `AddInterface` `INVALID_PARAMS`(`Extends='1bad; x'`) | "Pass the name of the interface to extend, e.g. Extends I_Base, or leave Extends out." | ✓(`Extends I_Base` 沒有 `=`,見 N3) |
| `UninstallLibrary` `Version=*` message | — | **沒跑**:Claude Code auto mode 分類器把這個呼叫(預設 dry-run)當成刪除擋下，沒有繞過 |
| `AddPlcTask` `data.verifyHint` | "After EnableConfig Force=true, find n with ReadVariable Path=['TwinCAT_SystemInfoVarList._TaskInfo[n].TaskName'] ..." | ✓ tool 名稱;`Path=[...]` 寫成陣列，見 N3 |
| `UnlinkProgramFromTask` warning | "...copy it back over '...RtTask.TcTTO', then ResetSolution." | ✓(仍寫「not measured yet, task 3.8」,3.8 其實量過了) |
| `ImportPlcOpen` `backup.restore` / `diskOnly[].how` | "ImportPlcOpen FilePath='...plcopen-replace.xml' Option=Replace DryRun=false";"...and run ResetSolution (not measured); or ImportChild of ..." | ✓ |
| `LIBRARY_NOT_FOUND` / `PLCOPEN_FAILED` / `LIBRARY_INVALID_ARGUMENT` hint | 「...拼對名稱後重跑同一個 tool」「依 data.reason 修正後重跑同一個 tool」 | ✓ |
| `PLCOPEN_FAILED` selection 寫法 | "Selection=['POUs.FB_A','DUTs.ST_B']" | ✓ |
| `data.buildRequired` | "PLC code changed by FreezePlaceholder All=true"、"...by AddPlcTask RtTask" | ✓ |
| `GetLibraries` `PLC_PROJECT_NOT_FOUND`(`PlcProjectPath=NoSuchPlc`) | "...剛 Activate / 重啟後可重試一次。**-PlcProjectPath** 可給 PLC 名稱..." | **✗ 殘留**(N1) |

## P2. FreezePlaceholder 不再靜默改版本

### 4026

- 凍結前(`GetLibraries`):`#Tc2_System` effective 3.10.1.0、`.plcproj` Resolution 3.10.1.0、DefaultResolution 3.9.1.0;`#CBML` effective `Common Behaviour Model, 4.0.0.0 (CODESYS)`、沒有 Resolution、DefaultResolution `*, (3S - Smart Software Solutions GmbH)`。
- dry-run `All=true`(0.9 s):Tc2_System `willFreezeTo 3.9.1.0`、`versionWillChange true` + warning ✓;**CBML `willFreezeTo 4.0.0.0 (CODESYS)`、`versionWillChange false`**(實寫時 XAE 其實改了它，需要釘回，預告漏報，見 N5)。7 個 visu placeholder 與 `Tc3_GlobalTypes` 進 `skipped[]`。
- 實寫 `All=true`(5.6 s):**success**,`pinned ["CBML","Tc2_System"]`、`notFrozen []`、`changed[]` 14 筆(都是 `before null` 的新凍結，版本 = 凍結前 effective)。
- 磁碟讀回 `.plcproj`:`Tc2_System, 3.10.1.0`、`Common Behaviour Model, 4.0.0.0 (CODESYS)` ✓;GetLibraries effective 也是這兩個值。`SetEffectiveResolution` 確實把版本釘回(registered tcauto 實測 2026-11-01 4026 VS2022)。
- **單一 placeholder 路徑**:把 `.plcproj` 還原成凍結前 → `ResetSolution` → 
  - `Placeholder=CBML` dry-run `versionWillChange false`;實寫 success、`pinned []`,Resolution `4.0.0.0 (CODESYS)`(XAE 單一 freeze 直接用 effective)。
  - `Placeholder=Tc2_System`(已凍結 3.10.1.0)dry-run **`willFreezeTo 3.9.1.0`、`versionWillChange true`**;實寫 success、`pinned []`、`changed []`、`plcprojChanged false`,仍是 3.10.1.0。單一路徑的預告是誤報(N5)。
- `LIBRARY_VERSION_CHANGED`:釘回每次都成功，觸發不了;沒改 code 無法模擬。

### 4024

- dry-run `All=true`:14 個 target,`VisuDialogs willFreezeTo 3.5.12.0`、`versionWillChange false`(3.8 實測 XAE 會凍成 4.8.0.0,預告漏報，N5)。
- 實寫 `All=true`(3.8 s):success,**`pinned ["VisuDialogs"]`**;磁碟 `<Resolution>VisuDialogs, 3.5.12.0 (System)</Resolution>`(DefaultResolution `VisuDialogs, * (System)`)✓。

## P3. 隱含 placeholder

- 4026 dry-run / 實寫 `All=true`:`skipped [{placeholder Tc3_GlobalTypes, reason implicit}]`,All 回 success,`notFrozen []` ✓。
- `Placeholder=Tc3_GlobalTypes` dry-run:warning "...DryRun=false refuses it (LIBRARY_INVALID_ARGUMENT reason implicit-placeholder)"。
- 實寫:`LIBRARY_INVALID_ARGUMENT` / `implicit-placeholder`,"Nothing was frozen.",沒有 backup、沒有 BUILD_REQUIRED ✓。

## P4. AddPlcTask 存檔

| 環境 | 呼叫 | 結果 |
|---|---|---|
| 4026 | `AddPlcTask Name=RtTask CycleTimeUs=2000 Priority=25 DryRun=false` | success `verified true`(5.7 s),`steps` 多一步 `save`,`projectSaved.verifiedFiles [RtTask.TcTTO]`、`plcprojChanged true` |
| 4026 | `ResetSolution`(預設) | success(14.7 s),projectCheck complete、`missingOnDisk []` |
| 4026 | `LookupTreeItem TIRT^RtTask` / `...Project^RtTask` | 都在(itemType 1 / 621) ✓ |
| 4026 | Priority 63 | `TASK_CREATE_FAILED` step `cycle-time`(讀回 Priority 1),`rolledBack true`、`TIRT^RtPri63 removed` |
| 4024 | `AddPlcTask Name=RtTask 2000 / 25` | success(6.6 s),`verifiedFiles [RtTask.TcTTO]` |
| 4024 | `ResetSolution` → LookupTreeItem / GetProjectTree | TIRT^RtTask、`PLC1 Project^RtTask` 都在 ✓ |

**`.tsproj` 裡 task 的實際格式**(兩邊相同):inline 的 `<Task Id="6" Priority="25" CycleTime="20000" AmsPort="351" AdtTasks="true"><Name>RtTask</Name>...`(4024 是 `Id="7"`、`AmsPort="352"`),**不是** `<Task File=...>`;副本裡沒有任何 `.xti`。`.TcTTO` 在 PLC 專案目錄(`AxisInterface\RtTask.TcTTO`、`PLC1\RtTask.TcTTO`,645 B),`.plcproj` 有 `<Compile Include="RtTask.TcTTO">`。所以 `a6d652b` 的 `<Task File=...>` 讀回路徑這次沒走到(副本沒有獨立 task 檔)。

**rollback 路徑**:
- cycle-time 讀回不符的 rollback:觸發了(Priority 63),✓。
- save-verify 失敗的 rollback(`a6d652b`,存檔後 `.tsproj` 讀不到 task):**觸發不了**。要讓 Project.Save 成功但 `.tsproj` 沒有 task,不改 code 做不到;把 `.tsproj` 設唯讀會變成存檔失敗(另一條路徑),而且 VS 可能跳唯讀 dialog,沒有做。

## P5. ExportPlcOpen 讀回

| 環境 | Selection | 結果 |
|---|---|---|
| 4026 | `[FB_Rt, I_RtBase]` | objects 2;FB_Rt members `A_Reset`、`M_Priv`;**I_RtBase members `[M_Do]`** ✓(ITF property `P_Cnt` 只在 ProjectStructure,XAE 不匯出) |
| 4026 | `[Basic Function]`(資料夾) | 3 個物件 `folder "Basic Function"` ✓ |
| 4026 | `[AxisInterface.LIB.AxisControl.FB_AxisControl]` | **`folder "AxisInterface.LIB.AxisControl"`** ✓(3.8 是 null),members 40 |
| 4026 | 整專案 | **objectCount 73**;檔案 `pou` / `dataType` / `Interface` / `globalVars` 共 75 個節點，`GVL_Motion` 3 段，去重 73 ✓。資料夾路徑(`CorrugatedPrint.Feeder`、`AxisInterface.DUT.Axis_Control`...)都有 |
| 4024 | `[POUs.I_Rt4024]` | `folder "POUs"`、members `[M_Do]` ✓ |
| 4024 | 整專案 | **objectCount 89**;檔案 91 個節點，`GVL_HMI` 3 段，去重 89 ✓ |

- 錯誤路徑(4026):`' POUs.FB_A '` → `selection-not-found`(trim 後)、`Main.ExtendSlotTest` → `member-selection` `suggestedSelection Main`、檔案不存在 → `file-missing`。
- **新發現 N4**:有多段 `globalVars` 的 GVL(4026 `GVL_Motion`、4024 `GVL_HMI`)回 `members: [{"value":[],"Count":0}]`,其他 GVL 是 `members: []`。

## P6. ImportPlcOpen Replace 預告

4026,檔案 `e_obj.xml` = 匯出的 `FB_Rt`(A_Reset、M_Priv)+ `I_RtBase`(M_Do;專案裡另有 `P_Cnt`)。匯入前 `FB_Rt.M_Priv` 實作改成 `M_Priv := TRUE; // RT MODIFIED`。

| | FB_Rt | I_RtBase |
|---|---|---|
| dry-run `deletedChildren` | `[]` | **`[P_Cnt]`**(3.8 多報 `M_Do`) |
| 實寫 `deletedChildren` | `[]` | `[P_Cnt]` |
| 實寫 `childrenAfter` | `["A_Reset","M_Priv"]` | **`["M_Do"]`(陣列)** |

- 讀回:`GetPouCode FB_Rt.M_Priv` 實作回到空(標記被取代);`LookupTreeItem I_RtBase` 只剩 `M_Do`。dry-run 與實寫一致 ✓。實寫 4.5 s。
- `backup.restore` / `restoreNote` / `diskOnly[].how` 都是 MCP 寫法(見 P1)。

## P7. SaveAsLibrary 的 projectSaved / projectFileWritten

| 環境 | 情境 | `projectSaved` | `projectFileWritten` | 磁碟讀回 |
|---|---|---|---|---|
| 4026 | 沒有未存改動 | `false` | `false` | `.plcproj` LastWriteTime 16:34:21.40 前後相同 |
| 4026 | `ConsumeXml` 把 ProjectInfo Title 暫改 `RtProbeLib`(只在 XAE 記憶體) | `true` | `true` | LastWriteTime 變 16:36:50.50,磁碟 `<Title>RtProbeLib</Title>` |
| 4024 | ProjectInfo 全空 | — | — | `LIBRARY_SAVE_FAILED` / `save-failed`,xaeMessage "The specified library is not a managed library. (Reason: 'Title' not specified.)";`.plcproj` 沒被寫 |
| 4024 | `ConsumeXml` 設 Title / Company / Version 後 | `true` | `true` | — |
| 4024 | 緊接著再存一次 | `false` | `false` | — |

`projectSaved` 是讀回比對的結果，不再固定回 true(`f4185c0`)✓。暫時改的 Title 在 4026 用 ConsumeXml 改回(verified);兩份副本最後都整個還原。

## P8. InstallLibrary dry-run 的 repository 檢查

| 環境 | 呼叫 | 結果 |
|---|---|---|
| 4026 | dry-run `Repository=NoSuchRepo` | success,`repositoryCheck {state not-verified, readable false, listed [], error "Repositories is null"}` + warning "...DryRun=false lets XAE decide" |
| 4026 | dry-run `Repository=System` | success,`repositoryCheck.state known` |
| 4024 | dry-run `Repository=NoSuchRepo` | 同 4026,`not-verified`、`Repositories is null` |
| 4024 | **實寫** `Repository=NoSuchRepo`(自己的 RtLib4024) | `LIBRARY_INSTALL_FAILED` / `repository-not-found`(0x98510001 "Could not find repository 'NoSuchRepo'"),沒裝 |

- **Repositories 實際列出幾個**:4026、4024 都是 **0 個 —— 讀回 `null`(不可讀)**,不是「列出 0 個」。三態走的是「不可讀 → not-verified」。所以在這台機器上 dry-run 抓不到 `NoSuchRepo`,只有實寫才知道;程式行為符合 `f4185c0` 的設計，但 P8 原本想要的「dry-run 就擋」在這兩個環境做不到。
- 小瑕疵:warning 文字寫「it listed none on 4026」,實際是讀不到(null)。
- 4026 只做 dry-run:這份專案的 library identity 是使用者已安裝的 `AxisInterface`,不實寫。
- ScanLibraries 數:4026 473、4024 380(和 3.8 相同)。

## 新發現(都沒改 code)

| # | 問題 | 重現 | 影響 |
|---|---|---|---|
| N1 | `GetLibraries` `PLC_PROJECT_NOT_FOUND` 的 hint 仍有 PowerShell 寫法 `-PlcProjectPath` | 4026 `GetLibraries PlcProjectPath=NoSuchPlc` → hint "...剛 Activate / 重啟後可重試一次。-PlcProjectPath 可給 PLC 名稱(FrameworkUnitTest)或樹路徑..." | P1 殘留。推測是 `-PlcProjectPath` 後面接中文字，812e369 的「後面是值才改寫」規則沒命中 |
| N2 | `ResetSolution` 在 `.plcproj` 剛被外部改寫時卡 120 s 回 `RESET_SOLUTION_UNVERIFIED`,沒有處理 reload prompt | 4026:XAE 開著時把 `.plcproj` 複製蓋回 → 立刻 `ResetSolution` → 120.3 s 後 `RESET_SOLUTION_UNVERIFIED`(guardError "Solution / Solution.FullName answered $null");`GetIdeModalDialog` 看到 reload-prompt(reloadTarget project,WPF 按鈕 id 0);再跑一次 `ResetSolution` 才 `answeredYes true`(10.4 s) | 文件說會先處理 reload prompt;實際 guard 先讀 Solution.FullName,prompt 擋住時白等 120 s。只量一次，沒確認 prompt 是在 guard 開始前還是期間跳出 |
| N3 | 參數轉換的小瑕疵 | `AddInterface Extends='1bad; x'` hint "e.g. Extends I_Base"(少 `=`);`AddPlcTask` verifyHint `ReadVariable Path=['TwinCAT_SystemInfoVarList._TaskInfo[n].TaskName']`(單一字串被寫成陣列);`InstallLibrary` repository-not-found hint「InstallLibrary 的 InstallLibrary 失敗」(cmdlet 名稱改寫後重複) | 文字可讀，但不是可直接照抄的 MCP 呼叫 |
| N4 | 多段 `globalVars` 的 GVL,ExportPlcOpen `members` 序列化成 `[{"value":[],"Count":0}]` | 4026 整專案匯出 `GVL_Motion`;4024 整專案匯出 `GVL_HMI`(兩者在檔案裡都是 3 段 `globalVars`) | PowerShell 陣列被包成物件;只有這種 GVL |
| N5 | FreezePlaceholder dry-run 的 `willFreezeTo` / `versionWillChange` 不準 | All 路徑:4026 `CBML`(DefaultResolution `* (3S)`)、4024 `VisuDialogs`(`* (System)`)預告 false,實寫都要 `pinned`;單一路徑:4026 `Tc2_System` 預告 true(3.9.1.0),實寫沒變 | 結果安全(實寫有比對並釘回),但 dry-run 預告不能拿來判斷。推測：All 用 DefaultResolution、`*` 時 XAE 取最新版;單一 freeze 用 effective |
| N6 | `UninstallLibrary Version=*` 這列在本環境沒跑成 | Claude Code auto mode 分類器擋下(即使預設 dry-run) | 測試環境限制，不是模組問題;需要使用者放行該 tool 才能補測 |

## 其他觀察

- `AddPouMember` Action 的 `data.access` 現在是 `null`(3.8 的小瑕疵已修)。
- `AddPlaceholder` 對已存在 placeholder 不存檔(`1cc2a6f`)這次沒測。
- `UnlinkProgramFromTask` 650 的 `.zip` 仍匯不出(warning "No content in ZIP file."),只有 `.TcTTO` 備份，與 3.8 相同。

## 還原與確認

- 開始前:`robocopy /MIR` 兩份副本到 `C:\Temp\Verify-4026-axis-baseline-rt\`(266 檔)、`C:\Temp\Verify-4024-bfh-baseline-rt\`(302 檔),逐檔 SHA-256 存檔(開始時的雜湊清單用 `Get-ChildItem` 沒加 `-Force`,漏了隱藏檔與 `.vs\` 底下的 7 個 / 1 個檔，只列到 259 / 301;收尾時用 `-Force` 重比);4024 EtherCAT Device 1 / 5 仍 `Disabled="true"`(2 處)。Library repository 快照 2585 項。
- 結束:兩個 IDE 都用 `DisconnectIde Quit=true` 關閉(4026 pid 114924、4024 pid 15436,`ownedBySession true`),之後沒有任何 `devenv` / `TcXaeShell` 行程。`robocopy <baseline> <副本> /MIR` 還原後逐檔 SHA-256 比對(含隱藏檔，`-Force`):4026 266 / 266、4024 302 / 302,**差異 0**;4026 副本也和 3.8 的 `C:\Temp\Verify-4026-axis-baseline-38\`(266 檔)逐檔相同。那 7 個只有 `-Force` 才列得出的檔是 `.vs\AxisInterface_Type01_Library\` 底下的 `.suo`、`DocumentLayout(.backup).json`、Copilot / FileContentIndex 的 `.db` / `.vsidx`,加上 `A10_Scope\VSSettings\.vsm`。
- Library repository:2585 項，沒有新增或刪除任何目錄 / library;唯一差異是 XAE 自己的 `Managed Libraries\cache` 檔 LastWriteTime 變了(大小 239,180 B 不變，時間 00:37:54 = 4026 IDE 結束時)。`Rt Test4024` 目錄不存在。使用者原有的 `AxisInterface` 等 library 沒有碰。
- 開始時本機沒有任何 IDE 行程，沒有 attach 或操作使用者的 IDE。
