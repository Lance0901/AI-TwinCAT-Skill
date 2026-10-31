# Phase 2 API 實測(實作前的設計確認):3.1–3.7

- 環境:**自建 client 實測 2026-10-31 4026 VS2022 XAE 3.1.4026.18**(`VisualStudio.DTE.17.0`,devenv 17.14.36811.4;XAE 版本取自本次 XAE 新寫出的 `.TcPOU` / `.TcIO` 檔頭 `ProductVersion="3.1.4026.18"`)。副本 `C:\Temp\Verify-4026-axis\AxisInterface_Type01_Library.sln`,solution platform `TwinCAT OS (x64)`,全程離線:沒有 Activate、沒有 Login,`TcSystemServiceUm` 本來就不在，沒有碰。
- 方式：**自建 client**,和 registered tcauto 驗證分開。PowerShell 5.1,每個步驟一個行程:`Import-Module` 本 repo 的模組 → `Connect-TcIde -ProgId VisualStudio.DTE.17.0 -SolutionPath <副本>`(第一次 launched,之後 `-NoLaunch` reattach,並用記下的 pid 確認是自己啟動的那個)→ `& (Get-Module TwinCATAutomation) { Get-TcSysManager }` 拿 `ITcSysManager`,直接 late-bind 呼叫 COM。`Get-TcPouCode` / `Write-TcPouCode` / `Get-TcBuildErrors` / `Build-TcProject` 用模組 cmdlet。沒有對應的 tcauto tool,所以沒走 MCP。
- 路徑:PLC root `TIPC^AxisInterface`,nested project `TIPC^AxisInterface^AxisInterface Project`(以下寫 `<Prj>`)。
- 腳本、log、匯出檔:`C:\Users\aka09\AppData\Local\Temp\claude\C--Users-aka09-OneDrive----10-Works-Beckhoff-InternalProject-TwinCAT-AI-coding-2026-AI-TwinCAT-Skill\2ef230f0-30e3-4b2a-8ecd-5c33ec4cc6bb\scratchpad\phase2-probe\`(`common.ps1`、`p36*.ps1`、`p37*.ps1`、`p34.ps1`、`p31*.ps1`、`p35*.ps1`、`p33.ps1`、`p32.ps1`、`predo.ps1`;完整呼叫紀錄 `probe.log`;`out\` 放匯出檔與 archive)。
- 下文的耗時是單次呼叫的 wall time(ms),取自 `probe.log`。HRESULT 是 COM 例外的 `HResult`。錯誤訊息裡的中文是 zh-TW 系統的 .NET 在地化訊息，照原樣抄。
- 對照的研究文件:`research/phase2-api.md`(TE1000 手冊 v1.7.0 頁碼沿用該文件)。

## 過程中的兩次 IDE crash(重要)

兩次都是我啟動的 VS2022(pid 46452、24804),都由同一個動作觸發，簽名相同:

- 觸發：在 **ITF property 底下用 654 建 Get**(`CreateChild('Get', 654, '', $null)`,71 ms 成功)之後，讀這個 Get 的 `DeclarationText`。呼叫卡住約 48 s 後 RPC 斷線(`0x800706BA`)。第二次逐步拆開確認:CreateChild、`ChildCount`、`LookupTreeItem`、`ItemType`(654)、`ProduceXml`(`TREEITEMTYPE_PLCITFPROPGET`)都正常，**讀 `DeclarationText` 才 crash**。
- 事件檢視器 Application 1000:`devenv.exe 17.14.36811.4`,faulting module `KERNELBASE.dll 10.0.26100.9711`,exception code `0xe06d7363`(C++ exception),offset `0x00000000000c408a`。兩次完全相同(15:48:19、16:05:58)。dump:`%LOCALAPPDATA%\CrashDumps\devenv.exe.46452.dmp`、`devenv.exe.24804.dmp`(各約 400 MB,沒有刪)。
- 第一次 crash 後，用 baseline 把副本整個還原，重新 `Connect-TcIde`(38 s)繼續;第二次 crash 是最後一個實驗，故意放在最後做。
- 模組的反應：下一個 `Get-TcPouCode` 回 `IDE_CRASHED`(正確)。
- 影響:654 / 655 的子物件**不能用 `Get-TcPouCode` 讀**(模組會讀 DeclarationText),實作前必須避開或先查清楚。下文 3.6 有細節。

---

## 3.6 Interface、Method、Property、Action

自建 client 實測 2026-10-31 4026 VS2022 XAE 3.1.4026.18。父 FB 用 `<Prj>.CreateChild('FB_P2Probe', 604, '', 1)` 建(261 ms,成功)。

### vInfo 實測結果(手冊矛盾 1)

| 物件 | vInfo | 結果 | 讀回的宣告 |
|---|---|---|---|
| 609 Method | `[string[]]{'M_NameRet','BOOL'}`(手冊範例的 {name, returnType}) | **E_FAIL 0x80004005** "Language type not supported!"(50 ms) | – |
| 609 Method | `[string[]]{'1','BOOL','PRIVATE'}` | OK(211 ms),Language=1 | `METHOD PRIVATE M_LangRet : BOOL` |
| 609 Method | `[object[]]{1,'INT','PROTECTED'}` | OK(82 ms) | `METHOD PROTECTED M_LangRetO : INT` |
| 609 Method | `[string[]]{'1','BOOL'}`(2 個元素) | OK(44 ms) | `METHOD M_Two : BOOL`(沒有 access modifier) |
| 609 Method | `[string[]]{'1','BOOL','NOSUCH'}` | OK(33 ms),**不合法的 access 被靜默當成 PUBLIC** | `METHOD PUBLIC M_Bad : BOOL` |
| 609 Method | `[string[]]{'6','BOOL'}`(LD) | OK(227 ms),Language=6 | `METHOD M_LD : BOOL`,implementation 是 NWL XML |
| 609 Method | `$null` | OK(59 ms) | `METHOD M_Null`(沒有回傳型別) |
| 609 Method | 整數 `1` | E_FAIL "The specified vInfo (Type: Int32) is not supported for creating TreeItem type 'TREEITEMTYPE_PLCMETHOD' on parent item type '604'" | – |
| 609 Method | `[string[]]{'1'}`(1 個元素) | E_FAIL "vInfo (Type: String[]) is not supported ..." | – |
| 611 Property | `{'P_NameType','INT'}` | E_FAIL "Language type not supported!" | – |
| 611 Property | `[string[]]{'1','INT','PUBLIC'}` | OK(79–95 ms) | `PROPERTY PUBLIC P_LangType : INT` |
| 611 Property | 整數 `1` | E_FAIL "vInfo (Type: Int32) is not supported ... 'TREEITEMTYPE_PLCPROP'" | – |
| 611 Property | `$null` | E_FAIL,訊息是 NullReferenceException 的在地化文字「並未將物件參考設定為物件的執行個體。」 | – |
| 613 Get | `[string[]]{'1','PUBLIC'}` | OK(74–88 ms) | `PUBLIC / VAR / END_VAR` |
| 614 Set | `[string[]]{'1','PUBLIC'}` | OK(59 ms) | `PUBLIC / VAR / END_VAR` |
| 614 Set | 整數 `1` | E_FAIL "vInfo (Type: Int32) is not supported ... 'TREEITEMTYPE_PLCPROPSET' on parent item type '611'" | – |
| 613 Get 第二次 | 同上 | E_FAIL "Creating the child type 'TREEITEMTYPE_PLCPROPGET' is not possible on parent node type 'TREEITEMTYPE_PLCPROP' (SubType mismatch)"(錯誤文字不是「已存在」) | – |
| 608 Action | `{'A_NameX','BOOL'}` | E_FAIL "Language type not supported!" | – |
| 608 Action | `[string[]]{'1'}`、整數 `1`、`$null` | 三種都 OK(25–121 ms),Language=1 | Action 沒有宣告(`DeclarationText` 不存在) |
| 608 Action | 整數 `6` | OK,Language=6(LD,implementation 是 NWL XML) | – |
| 618 Interface | `$null` | OK(93–98 ms) | `INTERFACE ITF_P2Probe` |
| 618 Interface | 字串 `'ITF_P2Probe'` | OK(41 ms) | `INTERFACE ITF_P2Ext EXTENDS ITF_P2Probe` |
| 618 Interface | `[string[]]{'ITF_P2Probe'}` | E_FAIL "vInfo (Type: String[]) is not supported for creating TreeItem type 'TREEITEMTYPE_PLCITF' on parent item type '600'" | – |
| 610 ITF method | `[string[]]{'BOOL'}` / 字串 `'DINT'` / `$null` | 三種都 OK(29–59 ms) | `METHOD M_ItfRet : BOOL / VAR_INPUT / END_VAR`;`$null` 時沒有回傳型別 |
| 610 ITF method | `[string[]]{'M_ItfNR','BOOL'}` | **OK 但內容錯**:陣列被當成回傳型別直接接起來 | `METHOD M_ItfNR : M_ItfNR` 換行 `BOOL`(語法錯) |
| 612 ITF property | `[string[]]{'INT'}` / 字串 `'LREAL'` | OK(38–54 ms) | `PROPERTY P_Cnt : DINT` |
| 612 ITF property | `$null` | E_FAIL(NullReferenceException 在地化文字) | – |
| 654 ITF prop Get | `$null` | CreateChild OK(67–71 ms),**之後讀 DeclarationText 讓 devenv crash**(見上) | – |
| 655 ITF prop Set | – | 沒測到(第二次在 654 之後就 crash) | – |

其他:
- 名稱不是合法識別字(含空白、括號)時:E_FAIL "Creating the child named '...' is not possible on node (Name mismatch)"。
- 同名:E_FAIL "An object with the name 'M_Run' already exists within the corresponding namespace. Object Path: 'M_Run'"。名稱和 FB 內其他子物件不同就能建(`Run` 可以和 `M_Run` 並存)。
- 611 **不會**自動建 Get / Set(和 2026-10-25 的實測一致);612 也不會自動建 654 / 655。

**結論**:手冊 §6.5.5 的**表格**正確，範例註解「vInfo[0] = method name」是錯的。609 / 611 / 608 的 vInfo 第 0 個元素是 IEC language(字串或整數都行),609 / 611 是 `{language, returnType[, access]}`,613 / 614 是 `{language, access}`,608 給 language(陣列或純量都行)。618 的 Extends 只接受**字串**,不接受陣列。610 / 612 給回傳型別(陣列或字串)。

### 622 / 624 / 625(手冊矛盾 2)

在 `<Prj>` 底下 CreateChild,vInfo `$null`:

| SubType | 結果 |
|---|---|
| 622 | E_FAIL "Couldn't create 'X_Sub622'!"(名稱改成 `Project Information` 也一樣) |
| 624 | E_FAIL "Creating the child type 'TREEITEMTYPE_PLCTARGETVISU' is not possible on parent node type 'TREEITEMTYPE_PLCAPP' (SubType mismatch)" |
| 625 | E_FAIL "... (Name mismatch)"(`X_Sub625`、`GlobalTextList` 都一樣) |
| 650 | 在 project 底下:E_FAIL "Unable to cast object of type 'Beckhoff.TwinCAT.VS.PlcProjectNode' to type '...PlcTaskNode'"(只能建在 PLC task 底下，見 3.5) |
| 652 / 653 | E_FAIL "Couldn't create ..." |

沒辦法用建出來的物件看 ItemSubType,改讀既有物件的 ProduceXml(`ItemType` / `ItemSubTypeName`):`PlcTask^Main` = 650 `TREEITEMTYPE_PLCPROGREF`、`AxisInterface.tmc` = 653 `TREEITEMTYPE_PLCTMCDESCRIPTION`、`References` = 617 `TREEITEMTYPE_PLCLIBMAN`、`PlcTask` = 621 `TREEITEMTYPE_PLCTASK`、Visualization 619 / Visualization Manager 620。624 的錯誤訊息直接寫出 `TREEITEMTYPE_PLCTARGETVISU`,`<Prj>` 是 `TREEITEMTYPE_PLCAPP`。

**結論**:以 enum §5.46.22 為準(650 PLCPROGREF、653 TMCDESCRIPTION、624 PLCTARGETVISU),§6.5.5 表格的 622 / 624 / 625 寫錯。622 / 625 實際代表什麼，這一輪沒辦法建出來確認(見「仍然未知」)。

### 子物件的 ItemType(ProduceXml)

609 `TREEITEMTYPE_PLCMETHOD`、611 `TREEITEMTYPE_PLCPROP`、613 `TREEITEMTYPE_PLCPROPGET`、608 `TREEITEMTYPE_PLCACTION`、618 `TREEITEMTYPE_PLCITF`、610 `TREEITEMTYPE_PLCITFMETH`、612 `TREEITEMTYPE_PLCITFPROP`、654 `TREEITEMTYPE_PLCITFPROPGET`。ItemSubType 一律 0。

### 用模組讀寫子物件(`Get-TcPouCode` / `Write-TcPouCode -PouPath`)

路徑一律是 tree path,`<Prj>^<FB>^<子物件>`,accessor 再加一層 `^Get` / `^Set`。

| 物件 | `-PouPath` | Get | Write |
|---|---|---|---|
| Method | `<Prj>^FB_P2Probe^M_Run` | OK,objectKind METHOD,宣告和實作都有(105–250 ms) | 宣告 + 實作 OK,讀回一致 |
| Property | `<Prj>^FB_P2Probe^P_Value` | OK,PROPERTY,`hasImplementation=false` | 宣告 OK(INT→DINT,讀回一致);寫實作 → `INVALID_PARAMS`,hint 指向 `^Get` / `^Set` |
| Property Get / Set | `<Prj>^FB_P2Probe^P_Value^Get` / `^Set` | OK,PROPERTY_GET / PROPERTY_SET | 實作 OK,讀回一致 |
| Action | `<Prj>^FB_P2Probe^A_Reset` | OK,ACTION,`declaration=null` | 實作 OK;寫宣告 → `POU_WRITE_FAILED`(DeclarationText 屬性不存在) |
| Interface | `<Prj>^ITF_P2Probe` | OK,ITF | 宣告 OK |
| ITF method | `<Prj>^ITF_P2Probe^M_Do` | OK,ITF_METHOD | 宣告 OK;寫實作 → `INVALID_PARAMS`(正確) |
| ITF property | `<Prj>^ITF_P2Probe^P_Cnt` | OK,ITF_PROPERTY | 沒測 |
| ITF property Get(654) | – | **讀 DeclarationText 讓 IDE crash**,模組回 `IDE_CRASHED` | – |

只給名稱的情況:
- `-PouName M_Run`、`-PouName Get`:`resolvedBy=tree-search`,取第一個符合的。**FB_P2Probe 和 FB_P2Probe_1 都有 `M_Run`、`P_Value^Get` 時，還是靜默回 FB_P2Probe 的**,沒有 ambiguous 錯誤(研究文件預期的風險，實測確認)。
- `-PouName FB_P2Probe.M_Run` → `POU_NOT_FOUND`(`.` 語法還不支援)。
- `-PouName FB_P2Probe^M_Run` → OK,`resolvedBy=project-root`(現有程式已經接受 `^` 相對路徑)。

順便發現的兩個模組問題(沒改 `src/`,實作時處理):
1. `Write-TcPouCode -Implementation ""`(或 `" "`)回 `success`,`updated=[]`,**什麼都沒寫**。要把實作清空只能直接設 COM `ImplementationText = ''`。3.7 還原時踩到。
2. Action 寫宣告失敗(`POU_WRITE_FAILED`,什麼都沒寫)時，結果還是帶了 `buildRequired`(登記了 code changed)。

### 檔案

- CreateChild 子物件當下就把父物件的 `.TcPOU` / `.TcIO` 寫到磁碟(FB_P2Probe.TcPOU 裡有 `<Method>`、`<Property><Get><Set>`、`<Action>`),`LineIDs.dbg` 也會改。**`.plcproj` 沒有改**(hash 和 baseline 相同)。新 FB / ITF 本身的 `.plcproj` 項目要存檔才會寫(#76 的既有行為)。

### 對實作的影響
- `Add-TcMethod` / `Add-TcProperty` / `Add-TcAction` 的 vInfo 一律組 `[string[]]`,第 0 個是 IEC language:Method `{lang, returnType, access}`、Property `{lang, type, access}`、Get / Set `{lang, access}`、Action `{lang}`。Method 沒有回傳型別時傳 `{lang, '', access}` 之前要先實測;`$null` 可以建出沒有回傳型別的 method。
- access modifier 由模組自己驗證(XAE 把不合法值靜默當 PUBLIC)。
- `Add-TcInterface -Extends` 傳字串，不傳陣列。ITF method 的 vInfo 只放回傳型別，名稱放進陣列會產生語法錯的宣告。
- Property 要另外建 Get / Set(613 / 614,父節點是 property)。重複建 Get 的錯誤文字是 "SubType mismatch",要自己先檢查 accessor 是否已存在。
- **654 / 655(ITF property 的 Get / Set)先不要做**:讀它的 DeclarationText 會讓 VS2022 crash。`Get-TcPouCode` / `Write-TcPouCode` 也要擋 654 / 655(或 ItemType 是 654 / 655 時不讀 DeclarationText)。要支援的話先另開 issue,在 64-bit XAE Shell 和 4024 上確認是不是一樣。
- `Resolve-TcPouPath` 要加 `A.B` 語法，並在只給名稱、命中多個時回 `POU_AMBIGUOUS`。
- 子物件不改 `.plcproj`,建立之後不需要 `Invoke-TcPlcObjectSave`;D2 備份的對象是父物件的 `.TcPOU` / `.TcIO`。

---

## 3.1 Library Manager

自建 client 實測 2026-10-31 4026 VS2022 XAE 3.1.4026.18。

### 介面在哪個節點
- `<Prj>^References`(ItemType 617)和 `<Prj>` 本身都能 late-bind:`References`(兩邊都是 25 筆)、`ScanLibraries()`(兩邊都 473 筆)、`ProduceAllLibrarySignatures()`(兩邊都 1,678,184 字元)結果相同。手冊 §6.5.11 的 C# / PS 兩種寫法都對。
- `Repositories` 在 References 節點上回 **Count=0**(實際上有 System repository,InstallLibrary 用 `"System"` 成功)。`Repositories` 的列舉方式這一輪沒查出來。

### References 列舉
- 25 筆全部是 placeholder:`Name` 帶 `#`(例如 `#Tc2_Math`),`PlaceholderName` 不帶 `#`,`LibraryName` / `Version` / `Distributor` / `DisplayName` 在 placeholder 上讀到空字串。`EffectiveResolution.LibraryName / Version / Distributor` 可讀(例如 `Tc2_Math,3.5.1.0,Beckhoff Automation GmbH`),visu 類的 placeholder EffectiveResolution 是 `$null`;`DefaultResolution` 也可讀(`Tc2_Math,*,...`)。
- 手冊 PS 範例用的 `LanguageIndependentName` 讀到空字串。
- 耗時：列舉 25 筆加讀屬性 1760 ms。

### ScanLibraries
- 473 筆,747 ms(References 節點)/ 372 ms(Project 節點，第二次)。每筆是 `ITcPlcLibrary`:`Name` = `LibraryName`(不帶 `#`)、`Version`、`Distributor`、`DisplayName` 格式 `"3S Storage, 3.5.11.10 (3S - Smart Software Solutions GmbH)"`。同一個 library 的每個版本各一筆。
- 本機 repository 實體目錄是 `C:\ProgramData\Beckhoff\TwinCAT\PlcEngineering\Managed Libraries\<Distributor>\<Library>\<Version>`(465 個版本目錄)。使用者已經裝了 `AxisInterface` 0.0.2.16 / 0.0.2.17 / 0.0.3.24 / 0.0.3.104(Beckhoff Automation)。

### AddPlaceholder
| 呼叫 | 結果 |
|---|---|
| `AddPlaceholder('P2Probe_PH1','Tc2_Math','*','Beckhoff Automation GmbH')` | OK 669 ms;Eff=`Tc2_Math,3.5.1.0`,Def=`Tc2_Math,*` |
| `AddPlaceholder('P2Probe_PH2','Tc2_Math','3.5.1.0',...)` | OK 140 ms |
| 同名再加一次 | ArgumentException 0x80070057 "Placeholder 'P2Probe_PH1' already contained!" |
| 單參數 `AddPlaceholder('P2Probe_NoDev')`(沒有 device placeholder) | ArgumentException 0x80070057 "Default Placeholder 'P2Probe_NoDev' could not be found! (ITcPlcLibraryManager:AddPlaceholder"(手冊寫 E_INVALIDARG,實際 HRESULT 也是 0x80070057 = E_INVALIDARG) |
| `AddPlaceholder('')` | ArgumentException 0x80070057 "Placeholder name '' not specified." |
| 預設 library 不存在 | COMException **0x98510001** "Default Library 'NoSuchLib_X, * (Nobody)' not found! (ITcPlcLibraryManager:AddLibrary",沒有建出 placeholder |

AddPlaceholder 之後(用 `SaveAsArchive` 取出記憶體裡的 `.plcproj`,沒有存檔):會同時寫 `<PlaceholderReference Include="P2Probe_PH1"><DefaultResolution>Tc2_Math, * (Beckhoff Automation GmbH)</DefaultResolution><Namespace>Tc2_Math</Namespace>` 和 `<PlaceholderResolution Include="P2Probe_PH1"><Resolution>Tc2_Math, * (...)</Resolution>`。

### FreezePlaceholder(只 freeze 一個)
- `FreezePlaceholder('P2Probe_PH1')`:OK 668 ms,回 void。`.plcproj` 只改一處:`<PlaceholderResolution Include="P2Probe_PH1"><Resolution>` 從 `Tc2_Math, * (...)` 變成 **`Tc2_Math, 3.5.1.0 (Beckhoff Automation GmbH)`**;`<PlaceholderReference>` 的 DefaultResolution 不變。其他 24 個 placeholder 完全不變。物件上的 EffectiveResolution 本來就是 3.5.1.0,所以**讀 References 看不出有沒有 freeze**,要讀 `.plcproj` 的 PlaceholderResolution。
- 找不到 placeholder:COMException 0x80004005 "Placeholder 'P2Probe_NoSuch' not found. Cannot freeze!"。
- 副本是 library 專案,FreezePlaceholder 一樣可以用。

### RemoveReference
- `RemoveReference('#P2Probe_PH2')`(帶 `#`)和 `RemoveReference('P2Probe_PH1')`(不帶 `#`)**都成功**(909 ms / 245 ms),都回 void,讀回已不在 References。
- 找不到:COMException 0x98510001 "Specified library 'P2Probe_NoSuch' not found! (ITcPlcLibraryManager:RemoveReference"。空名稱:ArgumentException 0x80070057 "Library name '' not specified."。
- 全部移除之後，placeholder 清單和 baseline `.plcproj` 完全一樣(24 個)。

### InstallLibrary / UninstallLibrary
為了不碰使用者的 `AxisInterface` library,先用 ConsumeXml 把 project info 暫時改成 `Title=P2ProbeLib`、`Company=P2Probe Test`、`Version=0.0.0.1`(`<TreeItem><IECProjectDef><ProjectInfo>...` 片段，讀回確認)→ `SaveAsLibrary` 產生 `P2ProbeLib_0.0.0.1.library` → 安裝 / 解除安裝 → 再用 ConsumeXml 改回原值(讀回 `AxisInterface / Beckhoff Automation / 0.0.4.88`)。安裝前確認 ScanLibraries 沒有 `P2ProbeLib`。

| 呼叫 | 結果 |
|---|---|
| `InstallLibrary('NoSuchRepo', lib, false)` | COMException 0x98510001 "Could not find repository 'NoSuchRepo' (ITcPlcLibraryManager:InstallLibrary" |
| `InstallLibrary('System', lib, false)` | OK 3579 ms,回 void。ScanLibraries 出現 `P2ProbeLib, 0.0.0.1 (P2Probe Test)`;repository 多了 `P2Probe Test\P2ProbeLib\0.0.0.1` |
| 同一個再裝一次(`false`) | **IOException 0x80131620 "Library already exists."**(手冊寫「取消」,實際是丟例外) |
| `InstallLibrary('System', lib, true)` | OK 693 ms(覆蓋的是我自己裝的那一個) |
| `UninstallLibrary('System','P2ProbeLib','9.9.9.9','P2Probe Test')`(版本錯) | **NullReferenceException 0x80004003**(在地化訊息「並未將物件參考設定為物件的執行個體。」),沒有移除任何東西 |
| `UninstallLibrary('System','P2ProbeLib','0.0.0.1','P2Probe Test')` | OK 171 ms;ScanLibraries 沒有了;repository 的版本目錄清單和安裝前**完全相同**(465),`P2Probe Test` 公司目錄也一起刪掉 |
| 再解除安裝一次(已不存在) | NullReferenceException 0x80004003 |

- 一般使用者權限就能 install / uninstall(沒有 UAC 提示)。

### 對實作的影響
- 介面節點維持用 References;Project 節點也能用，不必改既有 code。
- `GetLibraries`:placeholder 要讀 `PlaceholderName` + `EffectiveResolution` / `DefaultResolution`,不要讀 `LibraryName`(空字串)。`effectiveResolution` 可能是 null(visu placeholder)。是否 frozen 要從 `.plcproj` 的 `<PlaceholderResolution>` 判斷，物件 API 看不出來。
- `RemoveLibraryReference`:名稱帶不帶 `#` 都可以，模組可以統一去掉 `#` 再傳。錯誤 0x98510001 對應 not found。
- `FreezePlaceholder` 的讀回：比對 `.plcproj` `<PlaceholderResolution Include=name><Resolution>` 的版本不再是 `*`。D2 備份 `.plcproj` 即可。
- `InstallLibrary`:已安裝時是 IOException "Library already exists."(不是 HRESULT 錯誤碼),要用訊息比對。`UninstallLibrary` 找不到時丟的是 NullReferenceException,**不能**拿來判斷「不存在」以外的錯誤;dry-run / 實作前要先用 ScanLibraries 確認 name + version + distributor 存在，解除安裝後再用 ScanLibraries 讀回。
- 改的是本機 repository(`...\PlcEngineering\Managed Libraries`),不是專案檔:D2 的備份對象是 library 檔本身(Uninstall 前把 repository 裡那個版本目錄複製一份)。
- 新錯誤碼候選維持研究文件的 `LIBRARY_INSTALL_FAILED` / `LIBRARY_REMOVE_FAILED`;`PLACEHOLDER_NOT_RESOLVED` 這一輪沒遇到(Freeze 只在找不到 placeholder 時失敗)。

---

## 3.7 CheckAllObjects

自建 client 實測 2026-10-31 4026 VS2022 XAE 3.1.4026.18。在 `<Prj>` 上 late-bind `CheckAllObjects()`。

| 狀態 | 回傳 | 耗時 | Error List(`Get-TcBuildErrors -IncludeWarnings`) |
|---|---|---|---|
| 正常(含沒被引用的 FB_P2Probe) | `[Boolean] True` | 2151 ms | errors 0、warnings 29 |
| 沒被引用的 FB 的 method 寫語法錯 `M_Two := ;` | **`[Boolean] False`,沒有例外** | 733 ms | errors 1:`C0007 Expression expected instead of ';'`,file `FB_P2Probe.TcPOU@M_Two (Impl)`,line 1 |
| 同一個 method 改成 `M_Two := nUndefinedVar;` | `False` | 1100 ms | errors 2:`C0046 Identifier 'nUndefinedVar' not defined`、`C0032 Cannot convert type ...` |
| 還原(COM `ImplementationText = ''`) | `True` | 1046 ms | errors 0 |
| PlcTask 底下有不存在的 program 呼叫(3.5 的實驗) | `False` | 1046 ms | `C0046` / `C0035` / `C0080` / `C0036`,file `PlcTask.TcTTO`,line 0 |

- 在 PLC root `TIPC^AxisInterface` 上呼叫：沒有這個方法(PowerShell "does not contain a method named 'CheckAllObjects'"),只能在 `<Prj>` 上。
- **和 Build 的差別(spec scenario)**:語法錯還在的時候跑 `Build-TcProject`:`success=true`、errors 0、coverageComplete true。也就是 Build 只編有被引用的物件，CheckAllObjects 會檢查沒被引用的物件。
- 不產生 code:修好 Snap 後重測，`CheckAllObjects()` 前後整個副本目錄(`C:\Temp\Verify-4026-axis`)**沒有任何檔案變動**(`_Boot`、`_CompileInfo` 都沒動)。對照:`Build-TcProject` 會改 `.tsproj`、`.tsproj.bak`、`.~u`,`_Boot` 也會寫(見 3.2)。
- 沒有 modal dialog。
- Error List 會留著舊項目:`'TwinCAT Measurement' ... Error creating Archive`(3.4 的 tnzip 造成)在之後每一次讀 Error List 都還在，severity 是 Error,而且沒有 file / code。

### 對實作的影響
- `passed` 直接用回傳的 bool,錯誤時是 False 不是例外(手冊沒寫清楚的部分)。仍要 catch `E_FAIL`(手冊列的 `Error_CheckAllObjectsFailed`),這一輪沒遇到。
- 錯誤明細用 `Get-TcBuildErrors` 讀，格式和 Build 一樣(code / description / file `X.TcPOU@Method (Impl)` / line)。要過濾掉不是這次檢查產生的項目(例如沒有 file、沒有 code 的 TwinCAT Measurement 項目)。
- CheckAllObjects 不產生 code、不改檔：不清除也不設定 BUILD_REQUIRED,不登記 code-changed。
- 要在 `<Prj>` 上呼叫，不是 PLC root。

---

## 3.5 Task 和 program 連結

自建 client 實測 2026-10-31 4026 VS2022 XAE 3.1.4026.18。

### `ITcPlcTaskReference` / `LinkedTask`
| 節點 | LinkedTask |
|---|---|
| `<Prj>^PlcTask`(621) | **`TIRT^PlcTask`** |
| `TIPC^AxisInterface`(56)、`...^AxisInterface Instance`(57)、`<Prj>`(600)、`TIRT^PlcTask`(1) | 空字串(late-bind 不報錯，但不是 task reference) |
| `...^AxisInterface Instance^PlcTask` | COMException 0x98510001 "Hidden subitem 'PlcTask' under 'AxisInterface Instance' not found"(Instance 沒有子節點) |

- `<Prj>^PlcTask` 的 ProduceXml:`<PlcTaskDef><LinkedTask>TIRT^PlcTask</LinkedTask></PlcTaskDef>`。用 ConsumeXml `<TreeItem><PlcTaskDef><LinkedTask>TIRT^P2RtTask</LinkedTask></PlcTaskDef></TreeItem>` 也能改(讀回正確)。
- set `LinkedTask = 'TIRT^P2RtTask2'`:OK,讀回一致。`'TIRT^NoSuchTask'`:COMException **0x98510001**(訊息只有 HRESULT)。`'TIPC'`:COMException **0x98510002** "Item 'PLC' is not a task! (ITcPlcTaskReference:set_LinkedTask"。手冊的 TSM_E_ITEMNOTFOUND / TSM_E_INVALIDITEMTYPE 實際就是 0x98510001 / 0x98510002。
- 兩個 PLC task 都 link 到 `TIRT^PlcTask` 也被接受，沒有錯誤。

### 在 `^PlcTask` 底下 CreateChild 650
| 名稱 | 結果 |
|---|---|
| `TestCam`(既有 program) | OK 209 ms,PlcTask 子節點多一個 `TestCam [650]` |
| `TestCam` 第二次(同名) | **OK**,出現兩個 `TestCam` |
| `testcam`(大小寫不同) | OK |
| `NoSuchProg`(不存在) | **OK** |
| `FB_P2Probe`(FB,不是 program) | OK |
| `GVL_Smoke4026`(GVL) | OK |
| 名稱 `X`、vInfo `'TestCam'` | OK,建出 `X`(vInfo 被忽略) |

- XAE **完全不驗證**:每一個都直接寫成 `PlcTask.TcTTO` 的 `<PouCall><Name>...</Name></PouCall>`,檔案當下就寫到磁碟(沒有存檔),`LineIDs.dbg` 也改。
- 錯誤到編譯才出現:CheckAllObjects False;`Build-TcProject` 回 `BUILD_FAILED`,codeErrors 有 `C0046 Identifier 'NoSuchProg' not defined`、`C0035 Program name, function or function block instance expected instead of 'NoSuchProg'`、`C0080 Function block 'FB_P2Probe' must be instantiated to be accessed`、`C0036 Cannot call object of type 'VAR_GLOBAL'`,file 都是 `PlcTask.TcTTO`。同名重複呼叫沒有編譯錯誤(TestCam 會被呼叫兩次)。
- 移除:`PlcTask.DeleteChild('<name>')`,同名有兩個時一次刪一個。全部刪完後 `PlcTask.TcTTO` 的 hash 和 baseline 相同。

### 新增第二個 PLC task(621)
- `<Prj>.CreateChild('P2Task', 621, '', $null)`,TIRT 底下沒有同名 task 時:E_FAIL "**No task 'P2Task' found in Realtime-Settings!**"。
- 先 `TIRT.CreateChild('P2RtTask', 1, '', $null)`,再 `<Prj>.CreateChild('P2RtTask', 621, '', $null)`:OK 324 ms,建出 `<Prj>^P2RtTask`,**LinkedTask 自動是 `TIRT^P2RtTask`**,當下寫出新檔 `P2RtTask.TcTTO`。再建一次同名:E_FAIL "An object with the name 'P2RtTask' already exists ..."。
- 之後可以在 `<Prj>^P2RtTask` 底下 CreateChild 650 連 program(OK)。
- 建完後 Instance 的 ProduceXml `<Contexts>` 還是只有 PlcTask(推論要 build 後才更新，沒驗證)。
- 清除：`<Prj>.DeleteChild('P2RtTask')`、`TIRT.DeleteChild(...)`。

### 對實作的影響
- `Add-TcTask`(PLC 用)要兩步：先建 TIRT task(subType 1),再在 `<Prj>` 用**同名** CreateChild 621;LinkedTask 自動接好。要連到不同名的 TIRT task 再設 `LinkedTask`(或 ConsumeXml `PlcTaskDef/LinkedTask`)。
- `ITcPlcTaskReference` 就在 `<Prj>^<PlcTask>`(621)節點上;值的格式是 tree path `TIRT^<task>`。
- `LinkProgramToTask` 一定要自己先檢查：program 存在、ItemType 是 602(FB / GVL / 不存在的名稱 XAE 都照收)、名稱大小寫和 program 完全相同、同一個 task 底下還沒有同名的 650。寫入後讀回 `.TcTTO` 或 PlcTask 子節點。
- D2 的備份對象是 `.TcTTO`(650 / 621 當下就改寫或新增 `.TcTTO`)。

---

## 3.3 PLCopen XML

自建 client 實測 2026-10-31 4026 VS2022 XAE 3.1.4026.18。在 `<Prj>` 上 late-bind `PlcOpenExport` / `PlcOpenExport2` / `PlcOpenImport`。

### Export 的 selection
| selection | 結果 |
|---|---|
| `FB_P2Probe` | OK 231 ms,8928 bytes;含 method、property(含 Get / Set)、action(PlcOpenExport 預設就含子樹) |
| `FB_P2Probe;ITF_P2Probe` | OK,兩個物件 |
| 巢狀資料夾 `AxisInterface.LIB.AxisControl.FB_AxisControl` | OK 145 ms(`.` 分隔資料夾層級) |
| 同一路徑用 `^` | COMException **0x98510008** "Cannot export PlcOpen format. Selection 'AxisInterface^LIB^AxisControl^FB_AxisControl' not found!" |
| 資料夾 `AxisInterface.LIB`、含空白的 `Basic Function` | OK,資料夾內的物件全部匯出 |
| method 單獨 `FB_P2Probe.M_Run`、accessor `FB_P2Probe.P_Value.Get` | ArgumentException 0x80070057 "Couldn't create ExportObjects" |
| 不存在 `NoSuchPou` | COMException 0x98510008 "Selection 'NoSuchPou' not found!" |
| 空字串 | 整個 project,2,074,464 bytes,177 ms |
| `PlcOpenExport2(FB, false)` / `(FB, true)` | false:2552 bytes,**只有 FB 本身，沒有 method / property / action**;true:和 PlcOpenExport 相同(8928 bytes) |
| `PlcOpenExport2('Basic Function', false / true)` | false:兩個 FB 和 DUT 都有，但 FB 底下的 action 不見了;true:含 action |
| 檔案已存在 | ArgumentException 0x80070057 "File '...e01.xml' already exists!",原檔不變 |
| 資料夾不存在 | ArgumentException 0x80070057 "Directory '...nosub' does not exist!" |

- **ITF 的 property 沒有被匯出**:`ITF_P2Probe`(M_Do、P_Cnt、P_Str)匯出後只有 `<Method name="M_Do">`,P_Cnt / P_Str 只出現在 projectstructure 的 `<Object Name=...>`。(這兩個 ITF property 沒有 Get / Set,因為 654 會 crash;有 accessor 時會不會匯出沒測。)

### Import 的 options(用自己匯出的 `FB_P2Probe;ITF_P2Probe` 檔匯回同一個 project)
匯入前先把 `M_Run` 的實作改成 `M_Run := FALSE; // MODIFIED`,用來判斷有沒有取代。呼叫 `PlcOpenImport(file, opt, '', $true)`。

| options | 結果 |
|---|---|
| 0 NONE | Exception 0x80131500 "Creation of object 'FB_P2Probe' failed. Reason: Import conflict! Creation of object 'ITF_P2Probe' failed. Reason: Import conflict!";沒有任何改動(沒有部分匯入) |
| 3 SKIP | 回 void,6 ms,**沒有任何改動，也沒有回報哪些被跳過** |
| 1 REPLACE | 回 void,242 ms;`M_Run` 實作變回匯出時的 `M_Run := bGo;`。**副作用:ITF_P2Probe 原本的 P_Cnt / P_Str 被刪掉**(因為匯出檔裡沒有它們),只剩 M_Do |
| 2 RENAME | 回 void,136 ms;新增 `FB_P2Probe_1`、`ITF_P2Probe_1`(加 `_1` 後綴),原物件不變 |

- `PlcOpenImport(file, 1, 'FB_P2Probe', $true)`:OK,只取代 FB(實作被還原)。selection 用的是檔案內的物件名稱。
- 匯入不存在的檔:ArgumentException 0x80070057 "Import File '...' doesn't exist!"。
- 都沒有 modal dialog(每次都用 `Get-TcIdeModalDialog` 檢查)。
- 匯入當下就寫磁碟：改了 `FB_P2Probe.TcPOU`、`ITF_P2Probe.TcIO`,新增 `FB_P2Probe_1.TcPOU`、`ITF_P2Probe_1.TcIO`;`.plcproj` 要存檔才會寫(之後 GenerateBootProject 存檔時寫進去了，見 3.2)。

### 對實作的影響
- `ExportPlcOpen`:selection 用 `.` 分隔，模組要把 tree path(`^`)或 `<Prj>` 相對路徑轉成 `.`。method / property / action 不能單獨選，要選父 POU。預設用 `PlcOpenExport2(..., $true)`(和 PlcOpenExport 相同),`SubTree=$false` 會丟掉子物件，要在 help 寫清楚。檔案已存在的檢查沿用 `Test-TcTreeItemFilePath`。
- `ImportPlcOpen`:
  - NONE 衝突是 .NET Exception 0x80131500,訊息逐一列出衝突物件，可以直接解析成 `conflicts[]`。
  - SKIP 不回報跳過了什麼，dry-run 的衝突預告要模組自己做(解析檔案的 `<pou name>` / `<dataType name>` / ITF,和 project 比對)。
  - **REPLACE 是整個物件覆蓋**:目標物件有、檔案裡沒有的子物件會被刪掉(ITF property 實例)。D2 一定要備份目標的 `.TcPOU` / `.TcIO`,dry-run 要列出「會被刪掉的子物件」。
  - RENAME 規則是加 `_1`,匯入後讀回 project 子節點找新名稱回報。
- 錯誤碼:selection 找不到是 0x98510008,可以對應 `PLCOPEN_FAILED` 的一種 reason。

---

## 3.2 GenerateBootProject(false)

自建 client 實測 2026-10-31 4026 VS2022 XAE 3.1.4026.18。只測 `bActivate=false`。監看三個目錄(每次呼叫前後比對長度與 mtime):副本 `C:\Temp\Verify-4026-axis`、`C:\ProgramData\Beckhoff\TwinCAT\3.1\Boot`、UmRT 的 `C:\ProgramData\Beckhoff\TwinCAT\3.1\Runtimes\UmRT_Default\3.1\Boot`。`TcSystemServiceUm` 沒在跑。

| 情況 | 回傳 / 例外 | 耗時 | 改了哪些檔 |
|---|---|---|---|
| PLC root `TIPC^AxisInterface`,上一次 Build 失敗(錯誤之後已經移除)、還沒重新 build | 回 void(S_OK) | 4029 ms | `_Boot\TwinCAT OS (x64)\Plc\Port_851.app` / `.autostart` / `.cid` / `.crc` / `.occ` / `.ocm` / `Port_851_boot.tizip`;**`AxisInterface.plcproj`、`AxisInterface.tmc`、`.tsproj`、`.tsproj.bak` 也被改**;新增 `_CompileInfo\<guid>.compileinfo` |
| 有編譯錯誤(PlcTask 呼叫不存在的 program) | COMException **0x80004005**,訊息只有在地化的「值未落在預期的範圍內。」(ArgumentException 的預設訊息) | 2162 ms | `_Boot` 沒變;`.tsproj` / `.tsproj.bak` 被改 |
| `Build-TcProject` 成功之後 | 回 void | 1698 ms | 同一組 `_Boot\TwinCAT OS (x64)\Plc\Port_851.*`,和 `_CompileInfo` |
| 在 nested project `<Prj>` 上呼叫 | 沒有這個方法(PowerShell "does not contain a method named 'GenerateBootProject'") | – | – |

- **TwinCAT Boot 目錄(`%ProgramData%\...\3.1\Boot`)和 UmRT 的 Boot 目錄完全沒有變動**。`bActivate=false` 只寫專案的 `_Boot\<platform>\Plc\Port_<port>.*`。
- `_Boot\...\CurrentConfig.xml` / `CurrentConfig.tszip` / `CurrentConfig\*.tpzip` **不是** GenerateBootProject 寫的，是 Build 寫的(16:05:02–03 的 mtime 對應 Build-TcProject 的時間)。
- 沒有 build 也能呼叫：它自己編譯(有 compile 錯誤時失敗，沒有錯誤時成功)。
- **它會存檔**:第一次呼叫時把記憶體裡尚未存檔的修改(3.6 / 3.3 建的 FB_P2Probe、FB_P2Probe_1、ITF_P2Probe、ITF_P2Probe_1)寫進了 `AxisInterface.plcproj`。
- `BootProjectAutostart`(讀)= False,但 `Port_851.autostart`(0 bytes)每次都被重寫。`BootProjectEncryption`=0、`TmcFileCopy`=False(只讀，沒有改)。
- 沒有 modal dialog。

### 對實作的影響
- 在 PLC root(`TIPC^<Plc>`)上呼叫，不是 `<Plc> Project`。
- `bActivate=false` 的產物位置固定是 `<tsproj 目錄>\_Boot\<solution platform>\Plc\Port_<adsPort>.*`,可以用前後 SHA-256 讀回確認;target Boot 目錄不會變，所以不能宣稱「target 已拿到新檔」。(推論，沒實測)`Get-TcBootPackageDiff` 在這個情況下會看到 `_Boot` 的 `.app` 和 target 不同，這是預期結果，不應該回 `BOOT_PACKAGE_MISMATCH`。
- 這一輪沒遇到「回 S_OK 但其實沒產生」的情況;失敗時錯誤訊息完全沒資訊，要接著讀 Error List(`Get-TcBuildErrors`)取 compile 錯誤，錯誤碼用 `BOOTPROJECT_FAILED`。
- **會存 `.plcproj` / `.tsproj`**:tool 要在 description 寫清楚，並登記 / 檢查 BUILD_REQUIRED 的方式要考慮它自己會編譯。前置條件可以不強制 completeBuild,但要在呼叫後讀 Error List 確認沒有錯誤。
- 研究文件推論的 `Enable-TcConfig` 衝突：這一輪確認 bActivate=false 不會碰 target,所以不會在 Activate 前造成 mismatch。

---

## 3.4 SaveAsLibrary / archive

自建 client 實測 2026-10-31 4026 VS2022 XAE 3.1.4026.18。在 `<Prj>` 上 late-bind。輸出放在 scratchpad 的 `out\p34\`。

### SaveAsLibrary / SaveAsLibrary2
| 呼叫 | 結果 | 耗時 |
|---|---|---|
| `SaveAsLibrary('<..>.library', $false)` | OK,回 void,869,839 bytes | 6160 ms |
| 同一檔再存一次 | ArgumentException 0x80070057 "File '...' already exist. Cannot SaveAsLibrary!" | 505 ms |
| `.compiled-library` | OK,481,919 bytes | 6935 ms |
| `.txt` | ArgumentException 0x80070057 "contains invalid file extension '.txt'. Please use '.library' or '.compiled-library'." | 551 ms |
| 資料夾不存在 | DirectoryNotFoundException 0x80070003 "Directory '...nosuchdir' not found!" | 127 ms |
| `SaveAsLibrary2(path, $false, $false)` | **可以 late-bind**,OK,869,839 bytes(和 SaveAsLibrary 相同) | 5461 ms |
| `SaveAsLibrary2(path, $true, $false)`(加密) | ArgumentException 0x80070057 "No Software-Protection/User-Database is connected to this TwinCAT project. Cannot save library with encryption!" | 646 ms |

- `.library` 是 ZIP(452 個 entry,`<guid>.meta` / `<guid>.object` 和 `__shared_data_storage_*`)。
- 不改專案檔：只有 VS 的 `.~u` 被更新。沒有 modal dialog。沒有先 build 也能存(這一輪呼叫時專案有成功 build 過，沒有另外測「從沒 build 過」)。
- 用 ConsumeXml 暫時改 project info(Title / Company / Version)之後 SaveAsLibrary,產生的 library 用的是改過的名稱和版本(3.1 InstallLibrary 的實驗)。

### Archive
| API | 結果 | 耗時 | 內容 |
|---|---|---|---|
| `ITcSysManager9.SaveAsArchive('<..>.tszip')`(在 `$sm` 上 late-bind) | OK,26,475,460 bytes | 1180 ms | 121 entries:`AxisInterface_Type01_Library.tsproj`(只有主 tsproj)+ `AxisInterface/` 整個 PLC 專案(`.plcproj`、`.tmc`、所有 POU / DUT / GVL / TcTTO / visu、`_Libraries/` 27 個檔)。**沒有 `.sln`,沒有 `A10_Scope`** |
| 同檔再存 | ArgumentException 0x80070057 "Archive file already exists!" | 490 ms | – |
| `dte.GetObject('TcArchivePersist').SaveAsArchive('<..>.tnzip')` | 取得物件 OK(42 ms);SaveAsArchive 回 void,26,483,775 bytes | 1281 ms | 122 entries:`AxisInterface_Type01_Library.sln` + `AxisInterface_Type01_Library/AxisInterface_Type01_Library.tsproj` + 同樣的 PLC 專案。**也沒有 `A10_Scope`**:Error List 多一筆 Error `'TwinCAT Measurement' (15:55:10.615): Error creating Archive -> 已經加入含有相同索引鍵的項目。`(兩次 tnzip 都出現),但 SaveAsArchive 回 S_OK |

- 兩種 archive 都打包**記憶體裡的目前狀態**:磁碟上的 `.plcproj` 還沒有 FB_P2Probe,archive 裡的 `.plcproj` 已經有。都不會存檔(tszip 不改任何檔;tnzip 只改 `.~u`)。
- 兩者差異:`.tnzip` = solution 層級(多了 `.sln`,路徑多一層 `AxisInterface_Type01_Library/`,會嘗試包含 Scope 等非 TwinCAT XAE 專案);`.tszip` = 只有 TwinCAT XAE 專案(tsproj + nested PLC 專案)。兩者都不含 `-Lance-G16.tsproj` 等其他 tsproj 變體。
- 只測產生，沒有測載入。

### 對實作的影響
- `Save-TcPlcLibrary`:SaveAsLibrary 和 SaveAsLibrary2 都可以用;`-Encrypt` 只在有 software protection 時可用，錯誤文字明確，可以直接轉成錯誤。副檔名、檔案已存在、資料夾不存在 XAE 都會擋，但模組仍先用 `Test-TcTreeItemFilePath` 檢查，錯誤格式一致。耗時 5–7 s,要有 deadline。
- `Save-TcSolutionArchive`:`.tnzip` 回 S_OK 也可能少了專案(這次少了 A10_Scope)。tool 要在呼叫後讀 Error List 找 "Error creating Archive",並列出 archive 內容和 sln 內的專案清單比對，不能只看回傳值(#28 的誤報成功)。
- archive 打包的是記憶體狀態，不是磁碟狀態：description 要寫清楚;如果使用者期待「磁碟上的版本」,要先存檔。

---

## 還原與確認

- 開始前用 robocopy 把整個副本複製到 `C:\Temp\Verify-4026-axis-baseline-phase2\`,並記錄 259 個檔的 SHA-256(`baseline-manifest.csv`)。
- 第一次 crash 後、和最後結束時，都用 `robocopy <baseline> <副本> /MIR` 還原。結束時比對:
  - 副本和 baseline 目錄含隱藏檔(`.vs\`、`A10_Scope\VSSettings\.vsm`)共 266 個檔，**SHA-256 全部相同**。
  - 29 個 `.tsproj` / `.plcproj` / `.TcPOU` / `.TcTTO`:全部和 baseline manifest 相同。
- IDE:兩個我啟動的 VS2022(pid 46452、24804)都是 crash 結束的(見最上面),沒有機會 `Disconnect-TcIde -Quit`;結束時沒有任何 `devenv` / `TcXaeShell` 行程。沒有 attach 或操作其他 IDE。
- Library repository:版本目錄清單和實驗前相同(465),`P2Probe Test\P2ProbeLib` 和公司目錄 `P2Probe Test` 都不存在。使用者既有的 `AxisInterface` library 沒有動過(用的是改名後的 `P2ProbeLib`)。
- 沒有跑 `Watch-Runtime.ps1`:UmRT 本來就沒在跑，這次沒有任何 runtime / ADS 操作。
- 留下的檔:兩個 crash dump(`%LOCALAPPDATA%\CrashDumps\devenv.exe.46452.dmp`、`devenv.exe.24804.dmp`)、scratchpad 的實驗檔、baseline 目錄 `C:\Temp\Verify-4026-axis-baseline-phase2\`。

## 過程備註

- PowerShell 函式的參數名稱和 scriptblock 的動態作用域撞名，導致第一次 3.6 的 CreateChild 收到錯的名稱(全部 "Name mismatch" 失敗，沒有建出東西),修好 helper 後重跑。
- 檔案變動比對的 helper 一開始 regex 寫錯，前半段(3.7、3.4、3.5 第一輪)的「沒有檔案變動」紀錄無效;修正後重測了 CheckAllObjects、Build、SaveAsLibrary、兩種 archive、650,上文的檔案變動結論都來自重測。
- 腳本檔用 Write tool 寫成無 BOM 的 UTF-8,PS 5.1 會把 repo 路徑裡的中文讀錯，所以腳本裡用萬用字元解析 repo 路徑。

## 仍然未知

1. **654 / 655(ITF property 的 Get / Set)**:CreateChild 成功，但讀 DeclarationText 讓 VS2022 crash(兩次重現)。655 沒測到。64-bit XAE Shell、4024 是否一樣、ImplementationText 能不能讀，都還不知道。要先另開 issue。
2. 622 / 625 實際代表什麼:CreateChild 一律失敗("Couldn't create" / "Name mismatch"),沒辦法看 ItemSubType。
3. `Repositories` 屬性為什麼回 Count=0、要怎麼列舉。
4. ITF property 有 Get / Set 時,PLCopen export 會不會把它匯出(這次沒有 accessor,所以沒匯出，REPLACE 時被刪)。
5. Method 傳 `{lang, '', access}`(沒有回傳型別、有 access)的行為。
6. SaveAsLibrary 在「從沒 build 過」的專案上會不會跳 dialog。
7. GenerateBootProject 回 S_OK 但其實有問題的情況;`bActivate=true` 的行為(這一輪規定只測 false)。
8. 621 建完之後 Instance `<Contexts>` 什麼時候更新、`_TaskInfo[]` 的 index 對應(需要 build + Activate)。
9. `.tnzip` 的 Scope 專案失敗("已經加入含有相同索引鍵的項目")是 A10_Scope 專案本身的問題，還是 TcArchivePersist 對 Scope 專案的通病。
10. 全部只在 4026 + VS2022 測過;4024 和 64-bit XAE Shell 都沒測。之後實作要用 registered tcauto 在兩個版本重測。
