# 第 2 期(PLC 補齊)API 研究:TE1000 Automation Interface

- 範圍:`tasks.md` 3.1–3.7。只做查證和讀 code,沒有啟動 IDE、沒有連 tcauto、沒有實測。下面每一條「需實測」都還沒驗證。
- 主要出處:TE1000 手冊 **Version 1.7.0(2026-09-03)**,https://download.beckhoff.com/download/document/automation/twincat3/TC3_Automation_Interface_EN.pdf 。下文寫「§x.y p.N」,p.N 是手冊印的頁碼(和 PDF 頁序相同)。
- InfoSys:https://infosys.beckhoff.com/content/1033/tc3_automationinterface/ 。實際查過的頁:
  - ITcPlcIECProject 介面版本表:https://infosys.beckhoff.com/content/1033/tc3_automationinterface/21841001483.html (內容和手冊 §5.28 相同，沒有寫 build 號)
  - PLC 指令「Check all objects」:https://infosys.beckhoff.com/content/1033/tc3_plc_intro/2531345035.html
  - `PlcTaskSystemInfo`(`_TaskInfo[]`):https://infosys.beckhoff.com/content/1033/tc3_plc_intro/714821259.html
- 另外讀了本機 interop `C:\Program Files (x86)\Beckhoff\TwinCAT\3.1\Components\TcBlockDiagram\Common\TCatSysManagerLib.dll`(3.4.0.0)的型別清單(reflection,2026-10-31)。interop 只說明介面有宣告，不代表 XAE 有實作。下文標「interop」的都是這個來源。
- **4024 / 4026 差異**:手冊 v1.7.0 的介面版本表「Newly introduced」欄都是空的，沒有寫 build 號。只有少數範例章節寫了最低 build,下文逐條列出。沒寫的一律是「查不到，需實測」。

---

## 3.1 Library Manager(`ITcPlcLibraryManager`)

### 取得介面
- 用 `LookupTreeItem("TIPC^<Plc>^<Plc> Project^References")` 拿 References 節點，在 C# cast 成 `ITcPlcLibraryManager`(要用 signature XML 的話 cast 成 `ITcPlcLibraryManager2`)。PowerShell 用 late binding,直接在 tree item 上呼叫方法。出處:§6.5.14 p.241–244,§6.5.11 p.237。
- 手冊在 §6.5.11 有兩個寫法互相矛盾:C# 範例 lookup `...^References`,PowerShell 範例 lookup `...^<Plc> Project`(沒有 `^References`)也呼叫 `ProduceAllLibrarySignatures()`。**需實測**:在 Project 節點上能不能 late-bind 這個方法。repo 目前一律用 References 節點。
- 所有方法在 adapter 斷線時都丟 `DanglingAdapterException`(§5.25.1)。

### API 表(§5.25.1 p.113–119,§5.25.2 p.119–120)

| 成員 | 簽名 | 參數 / 回傳 | 例外(手冊) |
|---|---|---|---|
| `References`(get) | `ITcPlcReferences**` | 目前的 library 和 placeholder reference;未連線時回 null | – |
| `Repositories`(get) | `ITcPlcLibRepositories**` | 已註冊的 repository(`Name`、`Folder`,§5.22/5.23 p.111–112) | – |
| `ScanLibraries` | `ScanLibraries([out,retval] ITcPlcReferences**)` | 所有 repository 中已安裝的全部 library | DanglingAdapter |
| `AddLibrary` | `AddLibrary(BSTR libName, BSTR version="", BSTR company="")` | version 空字串表示 latest/managed;也接受 display name `"Tc2_Math, * (Beckhoff Automation GmbH)"`(§6.5.14 p.243)。以 transaction 執行，之後強制 project reload | TSM_E_ITEMNOTFOUND:找不到 library;ArgumentException:已經加過 |
| `AddPlaceholder` | `AddPlaceholder(BSTR placeholderName, BSTR defaultLibName="", BSTR defaultVersion="", BSTR defaultDistributor="")` | defaultLibName 空字串時，依 device placeholder 決定預設 library | ArgumentException:名稱空白;E_INVALIDARG:沒給 libName,也找不到 device placeholder |
| `RemoveReference` | `RemoveReference(BSTR libName, BSTR version="", BSTR company="")` | library 和 placeholder 都用名稱移除(範例:`RemoveReference("Placeholder_NC")`,p.243) | ArgumentException:名稱空白;TSM_E_ITEMNOTFOUND:找不到 reference |
| `InstallLibrary` | `InstallLibrary(BSTR repositoryName, BSTR libPath, VARIANT_BOOL bOverwrite)` | 預設 repository 的名稱是 `"System"`(§6.5.12 p.239);bOverwrite=false 時，已安裝就取消 | TSM_E_ITEMNOTFOUND:找不到 repository |
| `UninstallLibrary` | `UninstallLibrary(BSTR repositoryName, BSTR libraryName, BSTR version="", BSTR distributor="")` | | ArgumentException:不是有效的 library;TSM_E_ITEMNOTFOUND |
| `FreezePlaceholder` | `FreezePlaceholder(BSTR placeholderName="")` | 名稱空字串或 null 時凍結全部 placeholder;版本鎖在目前的 EffectiveResolution,EffectiveResolution 是 `*` 時鎖在系統裡最新的版本(p.244) | E_FAIL:沒有 EffectiveResolution(`Error_PlaceholderNotResoluted_CannotFreeze`),或找不到 placeholder |
| `SetEffectiveResolution` | `SetEffectiveResolution(BSTR placeholderName, BSTR libName, BSTR version="", BSTR distributor="")` | 設定 placeholder 的 RedirectedResolution | ArgumentException;E_FAIL:找不到 placeholder |
| `InsertRepository` / `RemoveRepository` / `MoveRepository` | `(name, rootFolder, int index)` / `(name)` / `(name, int newIndex)` | index 決定優先順序 | ArgumentException:名稱重複或 index 超出範圍 |
| `ProduceAllLibrarySignatures`(v2) | `([out,retval] BSTR* pXml)` | 所有已解析 library 的公開型別 XML(輸出範例在 p.238) | E_FAIL:"Couldn't resolve libraries!" |
| `ProduceLibrarySignatures`(v2) | `(ITcPlcLibRef* pLibRef, [out,retval] BSTR*)` | 單一 library | E_INVALIDARG:找不到 library |

Reference 物件(§5.24 p.112、§5.26 p.120–121、§5.19 p.104–105):
- `ITcPlcLibRef.Name`:placeholder 的名稱前面會加 `#`。
- `ITcPlcLibrary`:`LibraryName`、`Version`(版本動態時是 `*`)、`Distributor`、`DisplayName`(格式 `"{LibraryName}, {Version} ({Distributor})"`)。
- `ITcPlcPlaceholderRef`:`PlaceholderName`、`EffectiveResolution`(型別 ITcPlcLibrary)、`CurrentLibrary`(已過時)。`ITcPlcPlaceholderRef2.DefaultResolution`。
- C# 範例(p.242)用 `is ITcPlcLibrary` / `is ITcPlcPlaceholderRef` 區分兩種 reference。PowerShell 只能 late binding,沒有 `is`,手冊的 PS 範例讀的是 `$libRef.LanguageIndependentName`,這個屬性不在 API 表裡。

### 手冊範例重點
- §6.5.14:四種寫法都在同一個 References 節點上呼叫，包括 AddLibrary 的三參數形式和 display-name 形式、AddPlaceholder 的單參數形式(加入既有的 placeholder)和四參數形式、用名稱 RemoveReference、ScanLibraries 之後逐一讀 `Name`。
- §6.5.12:InstallLibrary 的檔案可以是 `.library` 或 `.compiled-library`,repository 名稱 `"System"`。

### 4024 / 4026
- §2.2 Version overview(p.16–17):adding/removing libraries、placeholders、repositories,以及把 library 加進 repository,標示為 TwinCAT 3.1 支援。表格沒有細分 build。
- 各方法的最低 build:**查不到，需實測**。repo 只在 4026 實測過 AddLibrary(`Add-TcLibrary.ps1` .DESCRIPTION,2026-10-28)。

### 可重用的現有 code
- `Public/Add-TcLibrary.ps1`:
  - 解析 PLC project:`Get-TcPlcProjectList`、`Resolve-TcPlcProjectPath -RequireSingle`、`Find-TcPlcProject`,錯誤碼 `PLC_PROJECT_NOT_FOUND` / `PLC_PROJECT_AMBIGUOUS`。
  - `$sm.LookupTreeItem("$PlcProjectPath^References")`。註解寫到:tree item 不能經過 `Invoke-TcComRetry` 回傳，會被 pipeline 展開。
  - 列舉 `$refs.References` 讀 `Name`,用 `#<name>` 比對 placeholder。這段可以直接抽成 `Get-TcLibraryReferences`。
  - `Get-TcLibraryErrorText` 解析例外文字，對應 already contained / ITEMNOTFOUND。
  - `Invoke-TcPlcObjectSave -ObjectPath $refsPath -ExpectLibrary $Name`(`Private/Save-TcPlcProject.ps1`):存 `.plcproj` 後從磁碟讀回，驗證 reference 存在。RemoveReference 需要反向條件(`-ExpectNoLibrary` 之類的參數)。
  - `Register-TcCodeChange`(`Private/Set-TcBuildRequired.ps1`):記錄 BUILD_REQUIRED code-changed。
- D2 防護:`Private/TreeItem/TreeItemBackup.ps1` 的 `Invoke-TcTreeItemBackup` / `Find-TcTreeItemDiskFile`,可以在 RemoveReference / FreezePlaceholder 之前備份 `.plcproj`。

### 需實測
1. 在 4024 和 4026 上，`References` 列舉時每個 item 的實際型別：PowerShell 能不能讀到 `LibraryName` / `Version` / `Distributor` / `PlaceholderName` / `EffectiveResolution`。placeholder 物件上讀 `EffectiveResolution.Version` 是否可行。
2. `ScanLibraries()` 在 4024 / 4026 回傳的筆數和耗時(repository 很大時可能很慢)。
3. `RemoveReference` 移除 placeholder 時，名稱要給 `Tc2_Standard` 還是 `#Tc2_Standard`。
4. `FreezePlaceholder` 寫進 `.plcproj` 的結果長什麼樣(`<PlaceholderResolution>`?),要用什麼讀回驗證。
5. `InstallLibrary` / `UninstallLibrary` 改的是本機 repository,不是專案檔，D2 的備份範圍要怎麼定。需要 admin 嗎?
6. `AddPlaceholder` 單參數形式在沒有 device placeholder 時的錯誤文字(E_INVALIDARG)。

### 建議的 tool
| tool(MCP 名稱 / cmdlet) | 參數 | 備註 |
|---|---|---|
| `GetLibraries` / `Get-TcLibrary` | `PlcProjectPath?`、`Installed`(switch,改呼叫 ScanLibraries) | 唯讀;每筆回 `name`、`displayName`、`version`、`vendor`、`isPlaceholder`、`effectiveResolution` |
| `AddPlaceholder` / `Add-TcPlaceholder` | `Name`、`DefaultLibrary?`、`Version='*'`、`Vendor?`、`PlcProjectPath?` | 同 Add-TcLibrary 的存檔、讀回、BUILD_REQUIRED 流程 |
| `RemoveLibraryReference` / `Remove-TcLibraryReference` | `Name`、`Version?`、`Vendor?`、`ConfirmName`、`DryRun=true`、`PlcProjectPath?` | D2:dry-run、備份 `.plcproj`、讀回確認已移除 |
| `InstallLibrary` / `Install-TcLibrary` | `FilePath`、`Repository='System'`、`Overwrite=false` | 改的是本機 repository,不是專案 |
| `UninstallLibrary` / `Uninstall-TcLibrary` | `Name`、`Version?`、`Vendor?`、`Repository='System'`、`DryRun=true` | |
| `FreezePlaceholder` / `Set-TcPlaceholderFrozen` | `Name?`(空 = 全部)、`DryRun=true` | 可選擇併入 SetEffectiveResolution(`Library`、`Version`) |

新錯誤碼候選：`LIBRARY_REMOVE_FAILED`、`LIBRARY_INSTALL_FAILED`、`PLACEHOLDER_NOT_RESOLVED`(對應 FreezePlaceholder 的 E_FAIL)。

---

## 3.2 Boot project(`ITcPlcProject`)

### 取得介面
- `LookupTreeItem("TIPC^<Plc>")` 拿到 PLC **root 節點**(不是 `<Plc> Project` 那個 nested project 節點),cast 成 `ITcPlcProject`。PowerShell 直接 late binding。出處:§6.5.13「Setting boot project options」p.241,範例 `$plcProject = LookupTreeItem("TIPC^PlcGenerated")`、`$plcProject.BootProjectAutostart = $true`、`$plcProject.GenerateBootProject($true)`。

### API 表(§5.17 p.102–103)
| 成員 | 簽名 | 說明 |
|---|---|---|
| `GenerateBootProject` | `GenerateBootProject([in, defaultvalue(-1)] VARIANT_BOOL bActivate)` | 「Builds the local boot project (BuildLocalBootPrj)」。`bActivate`=VARIANT_TRUE 時同時 activate。回傳 BuildLocalBootPrj 的 HRESULT;E_POINTER:project item 無效。**注意預設值是 -1(TRUE)** |
| `BootProjectAutostart` | VARIANT_BOOL get/set | boot project 自動啟動;item 無效時 E_FAIL |
| `BootProjectEncryption` | `TcEncryptionType` get/set | `None 0` / `Target 1` / `Volume 2`(§5.46.16 p.165) |
| `TmcFileCopy` | VARIANT_BOOL get/set | 把 TMC 複製到 target |
| `ITcPlcProject2.TargetArchiveSettings` / `FileArchiveSettings` | `ITcPlcArchiveSettings**` | 見 3.4 |
- interop 的 `ITcPlcProject` 另外有 `CompileProject` 方法，手冊沒寫。不建議使用。
- 相關：系統層級的 boot 設定(`TISY` 用 ConsumeXml 改 `<BootSettings><AutoRun>` 等)在 §6.3.18 p.221–222,屬於 Windows 開機行為，不是 PLC boot project,不要混在一起。

### 檔案放在哪裡
- 手冊只寫「local boot project」,**沒有寫路徑**。
- repo 既有的引用(`Private/Get-TcBootPackageDiff.ps1` `Resolve-TcTargetBootDir`,本次未重查):InfoSys https://infosys.beckhoff.com/content/1033/tc3_grundlagen/4291093003.html 寫 boot project 在 `%ProgramData%\Beckhoff\TwinCAT\3.1\Boot\Plc`(4026 起，以前是 `C:\TwinCAT\3.1\Boot`)。UmRT 的位置是 `...\Runtimes\<name>\3.1\Boot`(repo 實測 2026-10-21)。
- 「local」指的是專案的 `_Boot\<platform>\Plc\Port_<port>.app`,還是 target 的 Boot 目錄?`bActivate=false` 會不會寫到 target?**查不到，需實測。**

### 和 `BOOT_PACKAGE_MISMATCH` 的關係
- 現有邏輯(`Get-TcBootPackageDiff`,只在 `Enable-TcConfig` Activate 之後呼叫，見 `Enable-TcConfig.ps1` L278、L314):比對 `_Boot\<platform>` 和 target Boot 目錄裡的 `CurrentConfig.xml`、`CurrentConfig.tszip`、`CurrentConfig\*.tpzip`、`Plc\Port_*.app`(限定 `-AdsPorts`)。兩邊都存在但 SHA-256 不同，才算 mismatch;只有一邊有的檔案只列在 `oneSided`。
- 可能衝突的情況(推論，需實測):
  - `GenerateBootProject($false)` 如果只更新本地 `_Boot\...\Plc\Port_851.app`,下一次 Enable-TcConfig 在 Activate 前**不會**比對，所以不會誤報;Activate 之後兩邊都會被覆寫。這種情況沒有衝突。
  - `GenerateBootProject($true)` 如果只把 `.app` 寫到 target,沒有更新 `CurrentConfig.*`,那和上一次 Activate 的 CurrentConfig 組合起來，runtime 重開後可能出現 ADS 1809(symbol description does not match)。這正是 #32 擔心的狀況。新 tool 產生之後應該呼叫 `Get-TcBootPackageDiff` 自己檢查，結果放進 data。
  - 一個要注意的點：如果新 tool 產生後的檢查遇到 `Port_*.app` 一致、但 `CurrentConfig.xml` 不一致，不能直接回 `BOOT_PACKAGE_MISMATCH`。GenerateBootProject 不負責 CurrentConfig。建議另外訂一個語意，例如 `data.bootPackage.status` 照實回報，只有 `.app` 不一致才算失敗。
- spec 要求「確認 boot 檔已經寫到 target」。target 是遠端 CX 時,`Resolve-TcTargetBootDir` 回 `$null`(讀不到遠端 Boot 目錄),只能回報 `unavailable`,不能宣稱成功。

### 可重用的現有 code
- `Get-TcBuildRequired` / `Get-TcBuildRequiredHint`(`Private/Set-TcBuildRequired.ps1`):沒有完整 build 時回 `BUILD_REQUIRED`,和 `Enable-TcConfig` L571 的寫法相同。
- `Get-TcBootPackageDiff` / `Resolve-TcTargetBootDir`:產生前後各比對一次，回報哪些檔案變了(SHA-256、時間)。
- `Get-TcPlcProjectList`(有 `adsPort`)、`Resolve-TcPlcProjectPath`:把 `<Plc> Project` 路徑轉成 root 路徑時要去掉最後一段。
- `Get-TcIdeModalDialog`:GenerateBootProject 是同步呼叫，呼叫前先檢查有沒有 modal dialog(和 `New-TcPlcObject` 同樣的考量)。

### 需實測
1. `GenerateBootProject($false)` 和 `GenerateBootProject($true)` 在 4024 和 4026 上分別改了哪些檔案(專案 `_Boot`、UmRT Boot、`%ProgramData%\...\Boot\Plc`),用 hash 和 mtime 比對。
2. 呼叫時 TwinCAT 要不要在 Run / Config 模式;PLC 是否必須 logged out。
3. 沒有 build 時它會不會自己 compile(BuildLocalBootPrj 是否包含 compile),會不會跳 dialog。
4. `BootProjectAutostart` 的設定存在哪個檔案(`.plcproj` / `.tsproj`),需不需要存檔。
5. 傳 `bActivate=true` 之後，`Get-TcBootPackageDiff` 的結果。

### 建議的 tool
| tool | 參數 | 備註 |
|---|---|---|
| `GenerateBootProject` / `New-TcBootProject` | `PlcProjectPath?`、`Activate=$true`、`Autostart?`(bool,有給才設) | 前置：沒有 completeBuild 回 `BUILD_REQUIRED`;執行後 data 帶 `files[]`(SHA-256 / mtime 前後對照)和 `bootPackage`(Get-TcBootPackageDiff 的結果);失敗回 `BOOTPROJECT_FAILED`(D7 已預定) |

---

## 3.3 PLCopen XML(`ITcPlcOpenImportExport` / `ITcPlcOpenImportExport2`)

### 取得介面
- `LookupTreeItem("TIPC^<Plc>^<Plc> Project")`,也就是 nested project 節點，再 cast:
  - `ITcPlcIECProject` 繼承自 `ITcPlcOpenImportExport`,所以 PlcOpenExport / PlcOpenImport 可以直接在 IEC project 上呼叫(§5.28 p.122)。
  - `ITcPlcOpenImportExport2` 是**獨立介面**(直接繼承 IUnknown,不是從 ITcPlcOpenImportExport 衍生，§5.20 p.105),同一個節點要另外 cast。手冊寫它**從 TwinCAT Build 4019 起**提供(§6.5.4 p.228)。
- PowerShell 範例在 project 節點上直接呼叫 `$plcProject.PlcOpenExport2(...)`(p.228–229)。

### API 表(§5.20 p.105–108)
| 方法 | 簽名 | 參數 | 例外 |
|---|---|---|---|
| `PlcOpenExport` | `(BSTR bstrFile, BSTR bstrSelection)` | selection 用 `;` 分隔、相對於 project 的路徑(例如 `"POUs.fb1;POUs.fb2"`,§6.5.4);空字串或 null 匯出整個 project,子樹遞迴 | ArgumentNullException;ArgumentException:bstrFile 空白、**檔案已存在**、目標資料夾不存在;XmlAutomationCollectionException:selection 路徑找不到 |
| `PlcOpenExport2` | `(BSTR bstrFile, BSTR bstrSelection, VARIANT_BOOL bSubTree)` | bSubTree=true 時匯出整個子樹(含 method、action、transition、property);false 只匯出列出的元素 | 同 PlcOpenExport |
| `PlcOpenImport` | `(BSTR bstrFile, int options=0, BSTR bstrSelection="", VARIANT_BOOL bSubTree=-1)` | options 見下表;bSubTree=TRUE 保留檔案裡的 folder 結構 | ArgumentException:檔案不存在;PlcOpenXmlException:selection 無法套用、衝突(errorOnConflict)、內容為空 |

`PLCIMPORTOPTIONS`(§5.46.7 p.161):

| 名稱 | 值 | 意義(手冊沒寫，依名稱推論) |
|---|---|---|
| `PLCIMPORTOPTIONS_NONE` | 0 | 衝突時報錯(§5.20.1.2 有明寫:「With NONE, a conflict results in an error」) |
| `PLCIMPORTOPTIONS_REPLACE` | 1 | 取代既有物件 |
| `PLCIMPORTOPTIONS_RENAME` | 2 | 新物件改名 |
| `PLCIMPORTOPTIONS_SKIP` | 3 | 跳過衝突的物件 |

### 手冊範例重點(§6.5.4 p.228–229)
- 匯出單一 POU 用 `PlcOpenExport2(file, "POUs.MyProg", false)`,多個用 `"POUs.MyProg;DUTs.MyDUT"`,整個 POUs 資料夾用 `("...", "POUs", true)`。
- selection 用 `.` 分隔層級，**不是** tree path 的 `^`。

### 4024 / 4026
- §2.2:PLCopen XML import/export 標為 TwinCAT 3.1 支援。`PlcOpenExport2` 從 4019 起。4024 和 4026 都超過 4019,但**沒有實測**。

### 可重用的現有 code
- `Private/TreeItem/TreeItemPath.ps1` 的 `Test-TcTreeItemFilePath`:檢查絕對路徑、非法字元、資料夾存在、檔案不存在(Export-TcTreeItem 用的就是這組 reason:not-absolute / invalid-path / folder-missing / file-exists),符合 PlcOpenExport「檔案已存在就丟例外」的規則。
- `Import-TcTreeItem.ps1` 的 dry-run → `Invoke-TcTreeItemBackup` → 呼叫 → `Test-TcTreeItemChildrenAdded` 讀回流程，可以套到 PlcOpenImport。dry-run 時可以先解析 PLCopen XML,列出 `<pou name=...>` / `<dataType name=...>`,再和目前的 project 物件比對，預告衝突(`Find-TcPlcNameConflict`,在 `New-TcPlcObject.ps1` 裡)。
- `Register-TcCodeChange`:匯入後記錄 code-changed。
- 匯入後存檔、讀回 `.plcproj`:`Invoke-TcPlcObjectSave`(和 Add-TcPou 相同)。

### 需實測
1. 4024 和 4026 的 selection 語法：巢狀資料夾怎麼寫(`POUs.Sub.FB_X`?)、method 能不能單獨選(`POUs.FB_X.M_Run`?)。
2. `PlcOpenImport` 的 bstrSelection 用的是檔案內的名稱，還是目標 project 的路徑?匯入到指定資料夾要怎麼做。
3. options 1 / 2 / 3 的實際行為，尤其 RENAME 的命名規則，以及 SKIP 有沒有回報哪些物件被跳過。
4. 匯入之後 XAE 會不會自動存 `.plcproj`、會不會跳 dialog。
5. LD / FBD POU 經過匯出再匯入，實作是否完全相同(spec 的 scenario)。

### 建議的 tool
| tool | 參數 | 備註 |
|---|---|---|
| `ExportPlcOpen` / `Export-TcPlcOpenXml` | `FilePath`、`Selection?`(`;` 分隔)、`SubTree=$true`、`PlcProjectPath?` | 唯讀;用 PlcOpenExport2,沒有這個介面時退回 PlcOpenExport |
| `ImportPlcOpen` / `Import-TcPlcOpenXml` | `FilePath`、`Conflict='None'`(None / Replace / Rename / Skip,對應 0–3)、`Selection?`、`KeepFolders=$true`、`DryRun=$true`、`PlcProjectPath?` | dry-run 列出檔案內的物件和衝突;實寫前備份;失敗回 `PLCOPEN_FAILED`(D7 已預定) |

---

## 3.4 SaveAsLibrary 和 archive

### SaveAsLibrary(`ITcPlcIECProject` / `ITcPlcIECProject6`)
- 取得方式：在 `TIPC^<Plc>^<Plc> Project` 上 cast 成 `ITcPlcIECProject`(§6.5.1 p.226,§6.5.13 p.240)。

| 方法 | 簽名 | 說明 |
|---|---|---|
| `SaveAsLibrary` | `(BSTR bstrLibraryPath, VARIANT_BOOL binstall=0)` | 等於不加密的 SaveAsLibrary2;binstall=TRUE 時，存完裝到 active profile(§5.28.1.1 p.123) |
| `SaveAsLibrary2`(v6) | `(BSTR path, VARIANT_BOOL bEncrypt=0, VARIANT_BOOL binstall=0)` | 只有開了 software protection 才能加密。例外:ArgumentException:檔案已存在、副檔名不是 `.library` / `.compiled-library`、要求加密但不支援(§5.28.6.1 p.126–127) |

- 注意：本機 interop 3.4.0.0 只有 `ITcPlcIECProject` 到 `ITcPlcIECProject5`,**沒有 6 / 7**(SaveAsLibrary2、ExportToSarif)。PowerShell 是 late binding,不靠 interop,但 4024 / 4026 的 XAE 有沒有實作 v6:**查不到，需實測**。

### Archive:手冊裡有四套 API,副檔名寫法不一致
| 層級 | API | 副檔名 | 出處 |
|---|---|---|---|
| Solution | `ITcArchivePersist.SaveAsArchive(BSTR path)` / `LoadFromArchive(BSTR path, BSTR solutionFolder)`;取得方式 `dte.GetObject("TcArchivePersist")` | `.tnzip` | §5.44 p.156–157,§6.3.7–6.3.8 p.209–210 |
| System Manager project(含 nested project) | `ITcSysManager9.SaveAsArchive(BSTR path)`;重新載入用 `dte.Solution.AddFromTemplate(tszip, folder, name)` | `.tszip` | §5.1.8 p.49–50,§6.5.13 p.241 |
| 單一 PLC project | `LookupTreeItem("TIPC").ExportChild("<Plc>", file)`;載入用 `TIPC.CreateChild(name, 0, null, tpzip)` 或 `ImportChild(tpzip, "", false, "")` | `.tpzip` | §6.3.7 p.209,§6.5.13 p.240–241 |
| PLC 資料夾 | `LookupTreeItem("...^POUs").ExportChild("", file)` / ImportChild | `.zip` | §6.3.7–6.3.8 p.209–210 |
| Tree item 層級 | `ITcArchiveImportExport.ExportArchive(file, vInfo)` / `ExportArchive2(file, ITcTreeItemCollection, vInfo)` / `ImportArchive(file, TCARCHIVE_IMPORTMODE, before, vInfo)`;只在 nested project 類節點上可用，一般 item 回 E_NOTIMPL;S_FALSE 表示 ZIP 沒建出來 | `*.tszip` / `*.tnzip` | §5.45 p.157–159 |
| 單一 project 的檔案 | `ITcProjectArchive.AddFilesToArchive(path, rootFolder, ulFlags)`;flags:`INCLUDE_NESTED=1`、`REMOVE_SCC=2` | ZIP | §5.14 p.99,§5.46.1 p.160 |

- `TCARCHIVE_IMPORTMODE`(§5.46.14 p.164):ADD 1、RENAME 2、ADDRENAME 3、OVERWRITE 4、ADDOVERWRITE 5。
- PLC archive 內容設定 `ITcPlcArchiveSettings`(在 PLC root 節點上用 `ITcPlcProject2.TargetArchiveSettings` / `FileArchiveSettings` 取得，§5.30 p.128–129):`SaveLoginInformation`、`SaveProjectSources`、`SaveCompiledLibraries`、`SaveSourceLibraries`(都是 VARIANT_BOOL)。
- 手冊說 solution 層級在 §6.3.7 是 `.tnzip`,在 §6.5.13 是 `.tszip`,實際上是兩個不同的介面(ITcArchivePersist 和 ITcSysManager9)。**兩者的檔案內容差在哪裡：查不到，需實測。**

### 可重用的現有 code
- `Export-TcTreeItem.ps1`(MCP `ExportChild`)和 `Import-TcTreeItem.ps1`(MCP `ImportChild`)已經包了 `ExportChild` / `ImportChild`,實測過 PLC 資料夾的 `.zip`(2026-10-30,4026)。要支援 `.tpzip`,只要在 `Get-TcTreeItemExportExtension`(`TreeItemPath.ps1` L497)加入規則：父節點是 TIPC、匯出 PLC root 時用 `.tpzip`。需要先實測。
- `Test-TcTreeItemFilePath`:SaveAsLibrary / SaveAsArchive 的路徑檢查(檔案已存在就拒絕)。
- `Register-TcCodeChange`:SaveAsLibrary 會不會改專案狀態要實測;如果會，要記錄。

### 需實測
1. 4024 和 4026 上 `SaveAsLibrary`(路徑可不可以用 `.compiled-library`)、`SaveAsLibrary2` 能不能 late-bind。
2. SaveAsLibrary 之前要不要先成功 build;沒有 build 時會不會跳 dialog。
3. `ExportChild("<Plc>", "*.tpzip")` 在 4024 / 4026 的結果，以及 `.tpzip` 和 `.zip` 的副檔名規則。
4. `dte.GetObject("TcArchivePersist")` 在 PS 5.1 bridge 裡拿不拿得到;SaveAsArchive 會不會先存 solution、會不會跳 dialog。
5. `LoadFromArchive` / `AddFromTemplate` 會開一個新 solution,和 `$script:TcDte` 目前連著的 solution 是什麼關係(要不要先 Close,要不要重新 Connect)。

### 建議的 tool
| tool | 參數 | 備註 |
|---|---|---|
| `SaveAsLibrary` / `Save-TcPlcLibrary` | `FilePath`(.library / .compiled-library)、`Install=$false`、`Encrypt=$false`、`PlcProjectPath?` | Encrypt 只在 v6 有;檔案已存在就拒絕;讀回確認檔案存在、大小 > 0 |
| `ExportPlcProjectArchive` / `Export-TcPlcArchive` | `FilePath`(.tpzip)、`PlcProjectPath?` | 內部呼叫 Export-TcTreeItem 的邏輯 |
| `SaveSolutionArchive` / `Save-TcSolutionArchive` | `FilePath`(.tnzip / .tszip)、`Kind='Solution'\|'SysManager'` | 載入(LoadFromArchive)會換掉目前 solution,建議放到第 3 期或另外開 issue |

---

## 3.5 Task 建立和 program 連結

### 建 Task
- `LookupTreeItem("TIRT").CreateChild(name, subType, null, null)`:SubType 0 = 有 process image,1 = 沒有 image(§6.3.1 p.196)。repo 的 `New-TcTreeItem` 已經支援，而且 2.8 實測過(`verification/phase1-2.8.md`)。
- 週期和 priority:
  - 用 ConsumeXml 改 `<TreeItem><TaskDef><CycleTime>`:repo 2.1 / 2.8 實測過，單位是 100 ns(20000 = 2 ms,`verification/phase1-2.1-consumexml.md` L5)。
  - 或用 `ITcTaskModule.CycleTime`(單位 100 ns,setter 可能回 S_FALSE 表示依 base time 調整過)/ `Priority`(setter 一律回 S_OK,即使內部拒絕了也一樣)(§5.11 p.95–96)。
  - 後者不會告訴你值有沒有被拒絕，所以建議用 ConsumeXml 加讀回(既有的 `Set-TcTreeItemXml` 流程)。

### Program 連結到 PLC task
- §6.5.3 p.227–228:在 `TIPC^<Plc>^<Plc> Project^PlcTask`(nested project 裡的 PLC task 物件，型別 621 `TREEITEMTYPE_PLCTASK`)上呼叫 `CreateChild("<ProgramName>", 650)`。子物件名稱必須和 program 名稱**完全一樣**。650 = `TREEITEMTYPE_PLCPROGREF`(§5.46.22 p.184)。
- 要把 PLC task 物件連到 TIRT 底下的某個 task(例如新建的 `TIRT^Task 2`):用 `ITcPlcTaskReference.LinkedTask`(BSTR get/set,值是 task module 的 tree path)。set 時找不到路徑回 TSM_E_ITEMNOTFOUND,目標不是 task 回 TSM_E_INVALIDITEMTYPE(§5.15 p.100)。
  - **這個介面要從哪個 tree item cast:手冊沒寫，需實測。** 候選有 `TIPC^<Plc>^<Plc> Instance^PlcTask`(instance 底下的 task reference,§6.5.1 p.226 說 instance 在 `childitems[1]`),或 nested project 裡的 PlcTask(621)。
- 在 PLC project 裡新增第二個 PLC task 物件(621):§6.5.5 表格寫 621「PLC task object」,但 vInfo 是 `–`,手冊沒有範例。**需實測**:能不能 `CreateChild("Task2", 621)`,以及建完之後 instance 會不會自動多一個 task reference。

### 用 CycleCount 驗證
- InfoSys `PlcTaskSystemInfo`(https://infosys.beckhoff.com/content/1033/tc3_plc_intro/714821259.html):`TwinCAT_SystemInfoVarList._TaskInfo[<index>]` 用 PLC 內的 task index 取值(在 PLC 內可以用 `GETCURTASKINDEXEX` 取得);`CycleCount` 計的是底層 system task,TwinCAT 用 RUN 模式重啟時歸零，PLC reset 不會歸零。其他欄位有 `CycleTime`、`TaskName`、`FirstCycle`、`CycleTimeExceeded` 等。
- index 是 PLC 自己的 task 順序(1-based),不是 TIRT 的順序。新 task 是第幾個，要讀 `_TaskInfo[n].TaskName` 去比對名稱。**需實測**:陣列長度和順序是否等於 PLC project 裡 task 物件的順序。
- repo 已經用過 `_TaskInfo[1].CycleCount` 判斷 UmRT 是否假 Run(`docs/troubleshooting.md` L809、`known-limitations.md` L20)。讀兩次取差值的做法可以用 `Watch-TcVariable` / `Read-TcVariable` 重用。

### 可重用的現有 code
- `New-TcTreeItem`(CreateChild,含 D2 dry-run、備份、讀回)、`Set-TcTreeItemXml`(ConsumeXml 片段、`XML_MERGE_FAILED`、讀回)、`Get-TcTreeItemXml`。
- 專用的 `Add-TcTask`:內部呼叫 New-TcTreeItem(`Path='TIRT'`、`SubType` 由 `-WithImage` 決定)加 Set-TcTreeItemXml(CycleTime / Priority),只是包裝，不用另寫 COM 呼叫(符合 D1)。
- program 連結(650)也可以走 New-TcTreeItem,但要先檢查 program 存在而且是 602(`Resolve-TcPouPath` + `Get-TcPlcObjectKind`),名稱完全相同。
- `Read-TcVariable` / `Watch-TcVariable`:讀 CycleCount。

### 需實測
1. CycleTime 是否必須是 base time 的倍數，不是倍數時 XAE 怎麼處理(2.1 已知 XAE 不驗證值,0 和負數都會收，所以模組要自己驗證)。
2. `CreateChild(prog, 650)` 在 4024 / 4026 的結果，名稱不一致時的錯誤;同一個 program 連兩次會怎樣。
3. `ITcPlcTaskReference` 要從哪個節點 cast,`LinkedTask` 的值是不是 `TIRT^PlcTask` 這種格式。
4. 新增第二個 PLC task(621)的方法，以及 `_TaskInfo` 的 index 對應。
5. Activate 之後新 task 的 CycleCount 有沒有在增加(spec scenario,需要 UmRT)。

### 建議的 tool
| tool | 參數 | 備註 |
|---|---|---|
| `AddTask` / `Add-TcTask` | `Name`、`CycleTimeUs`(或 ms)、`Priority`、`WithImage=$false`、`DryRun=$true` | 由 New-TcTreeItem + Set-TcTreeItemXml 組成;值由模組自己驗證(>0) |
| `LinkProgramToTask` / `Add-TcTaskProgram` | `ProgramName`、`PlcTask='PlcTask'`、`PlcProjectPath?`、`DryRun=$true` | CreateChild 650;先檢查 program(602) |
| `SetPlcTaskLink` / `Set-TcPlcTaskLink` | `PlcTask`、`TaskPath`(例如 `TIRT^Task 2`)、`PlcProjectPath?` | 看 3. 的實測結果再決定要不要做 |
| 驗證 | 不另做 tool,用 `WatchVariable` 讀 `TwinCAT_SystemInfoVarList._TaskInfo[n].CycleCount` | 可在 `Add-TcTask` 的 help 寫明驗證步驟 |

---

## 3.6 Interface、Method、Property、Action

### CreateChild 的 subType(§6.5.5 p.229–231,以及 enum §5.46.22 p.182–184)
| SubType | 物件 | 父節點 | vInfo(§6.5.5 表) |
|---|---|---|---|
| 601 | Folder | PLC 資料夾 / FB(FB 底下的 folder 從 4024.14 起，p.231) | 無,null |
| 602 / 603 / 604 | Program / Function / FB | 資料夾 | 602/604:[0] IEC language、[1] "Extends"、[2] 父型別、[3] "Implements"、[4] interface;603:[0] language、[1] 回傳型別 |
| 608 | Action | POU | [0] language、[1] PLCopen XML |
| 609 | Method | POU | [0] language、[1] 回傳型別、[2] access modifier、[3] PLCopen XML |
| 610 | Interface method | ITF | [0] 回傳型別 |
| 611 | Property | POU | [0] language、[1] 回傳型別、[2] access modifier |
| 612 | Interface property | ITF | [0] 回傳型別 |
| 613 / 614 | Property Get / Set | Property | [0] language、[1] access modifier、[2] PLCopen XML |
| 616 | Transition | POU(SFC) | [0] language、[1] PLCopen XML |
| 618 | Interface | 資料夾 | [0] extension type(要 Extends 的 interface) |
| 654 / 655 | Interface property Get / Set | ITF property | 無,null |

- access modifier:`PUBLIC` / `PRIVATE` / `PROTECTED` / `INTERNAL`(p.231;enum `PLCACCESS` 0–3,§5.46.6 p.161)。IEC language 的值:`IECLANGUAGETYPES` ST 1、IL 2、SFC 3、FBD 4、CFC 5、LD 6(§5.46.5 p.160–161)。
- **手冊內部矛盾(一定要實測)**:
  1. §6.5.5 的 Method 範例傳 `vInfo = { "MyMethod", "BOOL" }`,註解說「vInfo[0] = method name, vInfo[1] = return type (REQUIRED)」,和同一頁表格的「[0] IEC language」互相矛盾。
  2. 表格寫 622 = `PLCPROGREF`、624 = `EXTDATATYPECONT`、625 = `TMCDESCRIPTION`;enum §5.46.22 則寫 622 = `PLCPROJECTINFO`、624 = `PLCTARGETVISU`、625 = `PLCGLOBALTEXTLIST`、650 = `PLCPROGREF`、652 = `EXTDATATYPECONT`、653 = `TMCDESCRIPTION`。§6.5.3 用的是 650,所以以 enum 為準。3.6 用到的 608–618 兩邊一致。
  3. §6.5.6 的 PS 範例 `CreateChild("FB_TEST", 604, "", 6)` 直接把整數 6(LD)當 vInfo 傳，不是陣列。
- repo 已經實測過(`Get-TcPlcObjectKind.ps1` .DESCRIPTION,2026-10-25):`CreateChild 611` **不會**自動建立 Get / Set accessor。這和手冊有 613 / 614 一致：要另外建。

### 宣告和實作(§5.27 p.121–122、§5.29 p.127–128、§6.5.6 p.232–233)
- tree item cast 成 `ITcPlcDeclaration`(`DeclarationText` get/set,set 時存檔)和 `ITcPlcImplementation`(`ImplementationText` get/set,只有 ST 能 set;`ImplementationXml` get/set 是 PLCopen XML 片段;`Language` 唯讀)。
- 範例直接 lookup 子物件路徑 `TIPC^PLC1^PLC1 Project^POUs^MyFB^MyMethod`,再 cast(p.232)。
- §6.5.6 表格(p.233):Action / Transition 只有實作;Method、Property(Get/Set)兩者都有;Interface 只有宣告;Interface 的 Property(Get/Set)兩者都有(手冊這樣寫，和直覺不同，需實測)。
- 例外:`InsufficientAccessRightsException`(物件保護)、`UnsupportedAutomationException`(不支援的物件)、`NotSupportedException`(ImplementationText set 在非 ST 物件)。
- `ITcPlcPou.DocumentXml`(§5.18 p.104):整個物件檔(.TcPOU)的 XML,set 時會刪掉並覆寫 POU 檔再 reload。危險，第 2 期不建議使用。

### 4024 / 4026
- §2.2:新增 / 移除 POU / DUT / GVL、讀寫程式碼標為 TwinCAT 3.1 支援。FB 底下的 folder 從 4024.14 起。其他：查不到。
- repo 實測(2026-10-25):608 Action、611 Property、618 ITF 兩版都有;609 Method、610 ITF method 只實測了 4026。613 / 614 / 612 / 616 都還沒實測。

### repo 現況，以及要改哪裡
- `Get-TcPouCode` / `Write-TcPouCode` **已經能讀寫子物件**,只要給 `-PouPath`(完整 tree path,例如 `...^POUs^FB_X^M_Run`)。`Resolve-TcPouPath` 第 1 步就是用 LookupTreeItem 查明確路徑;`Get-TcPlcObjectKind` 已經對應 608–616、618。Write 對 PROPERTY 會提示改寫 `^Get` / `^Set`。
- 缺少的部分:
  1. **只給名稱時找不到子物件**:`Resolve-TcPouPath` 的 tree search(第 4 步)取第一個名稱相符的 item,`Get`、`Set`、同名 method 一定會撞名。建議加一個 `Parent.Child` 形式(例如 `-PouName 'FB_X.M_Run'`):拆開後先解析 `FB_X`,再 LookupTreeItem `<FB path>^M_Run`。另外要寫明：只給名稱、撞名時回 `POU_AMBIGUOUS`,不要靜默取第一個。
  2. **建立子物件**:`Private/New-TcPlcObject.ps1` 目前規定父節點必須是 PLC 資料夾或 `<Plc> Project`,而且 `Find-TcPlcNameConflict` 不檢查 method / action / property。子物件要放寬條件：父節點是 POU(602/604)或 ITF(618)。名稱只檢查同一個父節點底下。kind 步驟(ItemType == SubType)可以直接沿用。
  3. `Add-TcPou.ps1` 的 `$typeMap`(602–604)和 vInfo 組法(`{ language, return type }`)可以延伸成 Method / Property 的 vInfo,但要先實測上面的矛盾 1。
  4. 讀回驗證：`New-TcPlcObject` 的 declare 步驟(寫 DeclarationText 再讀回比對)可以直接用。

### 需實測
1. Method 609 的 vInfo 到底是 `{language, returnType, access}` 還是 `{name, returnType}`(4024 / 4026 各測一次);不傳 vInfo 時的預設值。
2. 613 / 614 在 property 底下建立 Get / Set;654 / 655 在 ITF property 底下建立。
3. 618 Interface 加 `Extends` 的 vInfo 形式(字串還是陣列)。
4. 609 Method 和 610 ITF method 在 4024 上的行為(repo 只實測過 4026)。
5. 子物件建立之後，`.plcproj` 會不會改(子物件寫在父 .TcPOU 裡，推論不會改，需要確認，關係到要不要呼叫 `Invoke-TcPlcObjectSave`)。

### 建議的 tool
| tool | 參數 | 備註 |
|---|---|---|
| `AddInterface` / `Add-TcInterface` | `Name`、`Extends?`、`Folder='POUs'`、`Declaration?`、`PlcProjectPath?` | 618 |
| `AddMethod` / `Add-TcMethod` | `ParentPath`(或 `Parent` 名稱)、`Name`、`ReturnType?`、`Access='PUBLIC'`、`Language='ST'`、`Declaration?`、`Implementation?` | 父節點是 POU 用 609,是 ITF 用 610 |
| `AddProperty` / `Add-TcProperty` | `ParentPath`、`Name`、`Type`、`Access`、`Accessors='Get,Set'` | 611(ITF 用 612),再依 Accessors 建 613 / 614(ITF 用 654 / 655) |
| `AddAction` / `Add-TcAction` | `ParentPath`、`Name`、`Language='ST'`、`Implementation?` | 608 |
| `GetPouCode` / `WritePouCode` 擴充 | `PouName` 接受 `FB_X.M_Run`、`FB_X.P_Value.Get` | 只改 `Resolve-TcPouPath`;撞名回 `POU_AMBIGUOUS` |

---

## 3.7 CheckAllObjects(`ITcPlcIECProject2`)

### API(§5.28.2 p.123–124)
- 取得方式:`TIPC^<Plc>^<Plc> Project` cast 成 `ITcPlcIECProject2`;PowerShell 用 late binding(§6.5.7 p.233–234 明寫 CheckAllObjects 可以 late-bind)。
- 簽名:`HRESULT CheckAllObjects([out, retval] VARIANT_BOOL* pResult)`。回 VARIANT_TRUE 表示檢查成功。
- 例外:`DanglingAdapterException`;`AutomationException(Error_CheckAllObjectsFailed, E_FAIL)`:檢查失敗。手冊沒說清楚「有編譯錯誤」是回 FALSE 還是丟 E_FAIL,**需實測**。
- 語意有矛盾:手冊 §5.28.2.1 寫「Rebuilds the project and checks all PLC objects」;InfoSys PLC 指令頁(https://infosys.beckhoff.com/content/1033/tc3_plc_intro/2531345035.html)寫這個指令檢查**所有**物件的語法(一般 build 只檢查有用到的物件)、主要給 library project 用、**不產生 code**。
  - 對 repo 的影響:CheckAllObjects 成功**不能**清掉 BUILD_REQUIRED(它不保證有可下載的編譯產物)。它也不應該被記錄成 code-changed。
- 相關的 `ITcPlcIECProject3.RunStaticAnalysis(VARIANT_BOOL bCheckAll=-1)` 從 4023.103 起(§6.5.7 p.233);結果也在 Error List。屬於第 4 期(靜態分析),這裡只列出來。

### 結果怎麼取
- 手冊只回 bool,沒有錯誤清單 API。§6.5.7 寫靜態分析的錯誤會出現在 VS 的 Error List 和 Output window,§6.5.2 也說 build 錯誤要看 DTE 的 Error List。CheckAllObjects 的錯誤寫到哪裡沒有明說，推論也在 Error List,**需實測**。
- 能重用 `errorItems`:
  - `Get-TcBuildErrors`(UIA 讀 Error List)回 `data.errors[]`,每筆是 `{ severity; code; description; project; file; line; column }`。`Build-TcProject` 再對每筆加上 `category`(`Get-TcErrorItemCategory`,分 code / library / other),分出 `codeErrors` / `libraryErrorItems`(`Build-TcProject.ps1` L386–417)。
  - CheckAllObjects 的 tool 照同一段邏輯處理，就能得到格式一致的 `errorItems`(spec 的要求)。建議把 L386–417 抽成 private 函式(例如 `Get-TcErrorListSummary`),Build-TcProject 和 CheckAllObjects 共用。
  - 要注意 Error List 裡可能留著上一次 build 的結果。repo 已經知道 Library Manager 的錯誤和 build summary 那一行會留下來(`Test-TcLibraryManagerItem`)。CheckAllObjects 之前要不要清空 Error List、怎麼清空：需實測。

### 4024 / 4026
- 介面版本表沒寫 build 號(InfoSys 21841001483 同樣沒寫)。本機 interop 3.4.0.0 有 `ITcPlcIECProject2.CheckAllObjects`。4024 / 4026 的 XAE 是否支援：**需實測**。

### 需實測
1. 4024 / 4026 上有錯和沒錯的專案，分別回什麼(bool / E_FAIL)、要花多久、會不會跳 dialog。
2. 錯誤是否出現在 Error List;有沒有沒被引用、但語法錯的 POU 能測出差異(spec 的 scenario)。
3. 呼叫之後 `LastBuildInfo` / `_Boot` 產物會不會變;會不會讓之後的 Enable-TcConfig 誤以為已經 build 過。
4. 和 `BUILD_REQUIRED` 狀態檔的互動(推論：不應該改這個狀態檔)。

### 建議的 tool
| tool | 參數 | 備註 |
|---|---|---|
| `CheckAllObjects` / `Test-TcPlcProject` | `PlcProjectPath?`、`TimeoutSec=600`、`IncludeWarnings=$true` | data:`passed`(回傳的 bool)、`errorItems` / `codeErrors` / `libraryErrorItems` / `warningItems`(格式同 BuildProject);不清除、也不設定 BUILD_REQUIRED;timeout 和 modal dialog 的處理照 Build-TcProject |

---

## 查不到的項目(要實測才能下結論)

- 所有 PLC 專用介面在 4024 和 4026 的最低 build(手冊版本表是空的)。手冊有寫 build 的只有這幾條:ITcProjectRoot 4018、PlcOpenExport2 4019、RunStaticAnalysis 4023.103、FB 底下的 folder 4024.14、DocFormat 4026.7。
- GenerateBootProject 產生的檔案位置，以及 `bActivate` 會不會寫到 target。
- PLCIMPORTOPTIONS 1–3 的實際行為;PlcOpen selection 的巢狀語法。
- ITcPlcTaskReference 要從哪個節點取得;要怎麼新增第二個 PLC task(621)。
- Method 609 的 vInfo 順序(手冊自相矛盾)。
- CheckAllObjects 有錯時是回 FALSE 還是丟 E_FAIL,錯誤寫到哪裡，會不會產生 code。
- SaveAsLibrary2 / ITcPlcIECProject6–7 在本機 XAE 上有沒有實作(interop 3.4.0.0 沒有宣告)。
- ITcArchivePersist(.tnzip)和 ITcSysManager9.SaveAsArchive(.tszip)差在哪裡。

## 實作順序建議和風險

### 建議順序
1. **3.6 子物件**(先做):`Get-TcPouCode` / `Write-TcPouCode` 已經能用 `-PouPath`,只要改 `Resolve-TcPouPath` 的 `A.B` 語法和 `POU_AMBIGUOUS`,再放寬 `New-TcPlcObject` 的父節點限制。風險低、重用最多，而且先釐清 609 vInfo 的矛盾，後面 3.3 驗證 PLCopen 匯出入時也會用到 Method。
2. **3.1 Library Manager**:流程 `Add-TcLibrary` 都有了(解析 PLC、References 節點、存檔、讀回、BUILD_REQUIRED),GetLibraries 是唯讀的，可以先上。Remove / Freeze 套 D2。
3. **3.7 CheckAllObjects**:API 簡單;主要工作是把 Build-TcProject L386–417 抽成共用函式。要先實測「不產生 code」,BUILD_REQUIRED 的語意才不會寫錯。
4. **3.5 Task + 連結**:建 Task 只是包裝既有的 New-TcTreeItem + Set-TcTreeItemXml。program 連結 650 有手冊範例。`ITcPlcTaskReference` 要先實測。CycleCount 驗證需要 Activate 和 UmRT,放在這一項的最後。
5. **3.3 PLCopen**:export 唯讀，風險低;import 是寫入，要套 dry-run、衝突預告和備份，工作量最大。
6. **3.2 Boot project**:檔案位置不明，又和 `BOOT_PACKAGE_MISMATCH` 有交集。先做一輪純實測(用 hash 比對三個目錄),確定語意再寫 code。
7. **3.4 SaveAsLibrary / archive**:SaveAsLibrary 和 `.tpzip` 匯出可以在 3.3 之後做。solution archive 的載入會換掉目前的 solution,建議拆出去另外開 issue,不進本期。

### 風險
- **手冊自相矛盾**(609 vInfo、622/650、CheckAllObjects 會不會 rebuild、§6.5.11 lookup 哪個節點):一律以實測為準，並且在 code 註解裡寫明「手冊 X 和 Y 矛盾，實測日期 / 環境」。
- **4024 和 4026 的支援差異沒有文件**:每個新 tool 兩個版本都要用 registered tcauto 實測(4024:`C:\Temp\Verify-4024-bfh`;4026:`C:\Temp\Verify-4026-axis`)。只在一個版本測過的，在 known-limitations 標清楚。
- **COM 同步呼叫會卡住**(GenerateBootProject、SaveAsLibrary、PlcOpenImport、CheckAllObjects 都可能跳 dialog):呼叫前一律先跑 `Get-TcIdeModalDialog` 檢查;長時間的呼叫要有 deadline(參考 `Invoke-TcProjectSaveWithDeadline`)。
- **誤報成功(#28 / #32)**:CheckAllObjects 回 TRUE 不代表可以下載;GenerateBootProject 回 S_OK 不代表 target 拿到新檔。兩者都要讀回(Error List / boot 檔 hash),而且不能拿來清除 BUILD_REQUIRED。
- **PLCopen import / RemoveReference 會悄悄改壞專案**:dry-run 預設開啟、先備份、寫入後讀回 `.plcproj` 或物件清單，都照 D2 處理。
- **tool 數量膨脹**:3.1 加上 3.6 就多了大約 10 個 tool。建議 SKILL.md 依「Library / POU 子物件 / Task / Export」分組，通用 CreateChild 的 description 寫明優先使用這些專用 tool(design.md 風險表已經列了)。
