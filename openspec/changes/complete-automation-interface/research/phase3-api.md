# 第 3 期(系統組態)API 研究:TE1000 Automation Interface

- 範圍:`tasks.md` 4.1–4.5,另外參考 proposal.md「第 3 期」和 design.md 的 D1 / D2、風險表、Open Questions。這份只做查證和讀 code,沒有啟動 IDE、沒有連 tcauto、也沒有實測。下面標「需實測」的項目都還沒驗證過。
- 主要出處:TE1000 手冊 **Version 1.7.0(2026-09-03)**,https://download.beckhoff.com/download/document/automation/twincat3/TC3_Automation_Interface_EN.pdf 。下文寫「§x.y p.N」時,p.N 是手冊上印的頁碼，和 PDF 的頁序相同(2026-11-01 用文字版逐頁核對過)。
- 次要出處:TE1000 **Variant Management** 手冊 Version 1.4(2021-07-21),https://download.beckhoff.com/download/Document/automation/twincat3/Variant_Management_EN.pdf ,下文寫「VM p.N」。Beckhoff Security Advisory 2017-002 v1.3(2023-12-18),https://download.beckhoff.com/download/document/product-security/Advisories/advisory-2017-002.pdf 。
- 實際查過的 InfoSys 頁面:
  - ITcSysManager14 屬性表:https://infosys.beckhoff.com/content/1033/tc3_automationinterface/21841711371.html
  - Access to TwinCAT variant management:https://infosys.beckhoff.com/content/1033/tc3_automationinterface/8204600715.html (內容和手冊 §6.12.1 相同)
  - Variant management Concept:https://infosys.beckhoff.com/content/1033/variant_management/6325752587.html
  - Variant management C++ 設定表:https://infosys.beckhoff.com/content/1033/variant_management/8843640971.html
  - Creating NC axes:https://infosys.beckhoff.com/content/1033/tc3_automationinterface/21842426635.html (和手冊 §6.10.1 相同)
  - Linking NC axes to I/O or a PLC:https://infosys.beckhoff.com/content/1033/tc3_automationinterface/21842434315.html (只寫 link 到 I/O,**沒有寫 link 到 PLC**)
  - Data type AXIS_REF(TC2 MC2 library 頁):https://infosys.beckhoff.com/content/1033/tcplclibmc2/458448779.html 。TC3 Tc2_MC2 對應頁 `tcplclib_tc2_mc2/70132363.html` 在 2026-11-01 回 404。
  - NC axis state index offset(0x4100 + ID):https://infosys.beckhoff.com/content/1033/tc3_ads_intro/713094155.html ;NC 的 index group 規格:https://infosys.beckhoff.com/content/1033/tc3_ads_intro/713061899.html
  - Enabling and disabling an Independent Project File:https://infosys.beckhoff.com/content/1033/tc3_automationinterface/21842602763.html (和手冊 §6.3.9 相同)
  - Command Independent project file:https://infosys.beckhoff.com/content/1033/tc3_userinterface/7738192779.html
  - Source control「Project settings」:https://infosys.beckhoff.com/content/1033/tc3_sourcecontrol/767894795.html
  - How to manage routes:https://infosys.beckhoff.com/content/1033/tc3_automationinterface/21842662155.html (和手冊 §6.3.17 相同)
  - Routes(XAE 節點):https://infosys.beckhoff.com/content/1033/tc3_system/818866059.html (沒有寫密碼)
  - TS1120 ECAD Import「Childs」:https://infosys.beckhoff.com/content/1033/tcecadimport/11276596107.html (TwinCAT 2 的產品，只拿來佐證 NC encoder 的 subtype,不能當作 TC3 AI 的依據)
- 另外讀了本機 interop `C:\Program Files (x86)\Beckhoff\TwinCAT\3.1\Components\TcBlockDiagram\Common\TCatSysManagerLib.dll` 的型別清單(assembly 3.4.0.0、file version 3.4.1.24,reflection only,2026-11-01)。interop 只能證明介面有宣告，不代表 XAE 有實作。下文標「interop」的都出自這裡。
- **4024 / 4026 差異**:TE1000 v1.7.0 的介面版本表沒有寫 build 號。這期有寫 build 的地方只有：variant management 從 4024 起(VM p.7),各項 variant 設定的最低 sub-build(VM p.24–30),direct broadcast search 從 4020.10 起(§6.3.11 p.212、§6.4.2 p.224),ReloadTmc 從 4024.10 起(§6.7.3 p.280),standalone System Manager 從 4026 起(§6.14 p.297)。其他項目一律寫「查不到，需實測」。

---

## 4.1 NC 模擬軸

### 建立 NC task 和 axis(§6.10.1 p.293)
- 節點:`TINC` 是 NC configuration。先在 `TINC` 下建 NC task,再到 task 的 `Axes` 底下建 axis。前提是「The NC/drive module is licensed and available in the solution (the TINC node is visible)」(p.293)。UmRT 上 TINC 能不能看到、需不需要 TF5000 試用授權:**需實測**。
- CreateChild 的 subType(都出自 p.293 的範例；手冊沒有完整清單):

| 父節點 | 呼叫 | 意義 |
|---|---|---|
| `TINC` | `CreateChild("NC-Task", 1, null, null)` | NC task。手冊註解寫「" SAF" suffix is always appended to the name」 |
| `TINC` | `CreateChild("CNC", 400)` | CNC task(屬於第 4 期，這期不做) |
| `<task>^Axes` | `CreateChild("Folder1", -1)` | 軸的子資料夾 |
| `<task>^Axes` | `CreateChild("Axis 2", 1, "Folder1/")` | axis;第三個參數 `bstrBefore` 結尾是 `/` 時，表示放在該資料夾的最後面 |

- 手冊前後不一致:
  - C# 註解寫名稱一定會加上「 SAF」。可是 PowerShell 範例在 `CreateChild("NC-Task", 1)` 之後 lookup 的是 `TINC^NC-Task^Axes`,沒有 SAF。
  - §6.10.2 p.294 建議用 `get_Child(1).LookupChild("Axes")`(註解寫「more reliable than a path string with a potential SAF suffix」)。
  - repo 的單元測試假資料用的是 `TINC^NC-Task 1 SAF^Axes^Axis 1`(`tests/Unit/io-scan-link.ps1` L29)。
  - 實際的 task 名稱和路徑要以 CreateChild 回傳 item 的 `PathName` 為準，**需實測**。`New-TcTreeItem` 已經會讀回 `createdPath` / `createdName`,名稱不同時也會加 warning(L136–159),所以可以直接處理這個差異。
- ItemType(§5.46.22 TREEITEMTYPES p.179):`NCDEF 19`、`NCAXISES 20`、`NCCHANNEL 21`、`NCAXIS 22`、`NCENCODER 23`、`NCDRIVE 24`、`NCCONTROLLER 25`。讀回驗證時，可以用 `ItemType == 22` 確認建出來的是 axis。
- 也可以用 axis 範本:`TINC^NC-Task^Axes` 上呼叫 `ImportChild("C:\AxisTemplates.xti", "", true, "Axis 1")`(§6.3.2 p.199)。repo 已經有 `Import-TcTreeItem`。

### 設成 simulation axis:手冊沒有寫
- §6.10.1 p.294 只寫了「先建 axis,再用 ProduceXml 取得目前設定當範本，修改後用 ConsumeXml 寫回」,沒有列出任何 XML 欄位。**encoder / drive 的型別欄位、速度、加減速的元素名稱，手冊和 InfoSys 都沒有寫。**
- 間接線索:
  - TS1120(TwinCAT 2 ECAD Import)寫「The SubType should be "1" for Simulations-Encoder」,Type 是 `NCENCODER` / `NCDRIVE` / `NCCONTROLLER`。這是 TC2 的另一個產品，只能當作推測方向。
  - interop 的 `ITcSmTreeItem2.ChangeChildSubType(bstrChild, nNewSubType, bAggressive, vInfo)` 可以在 axis 底下把 Enc / Drive 子節點換成別的 subtype,手冊 §5.2.2 p.62 只寫了「SubType switching」。
- 需實測(4.1 最主要的問題):
  1. `CreateChild(name, 1)` 建出來的 axis,預設的 encoder / drive 是不是 simulation(用 ProduceXml 看 Enc、Drive 子節點的 `ItemSubType` / `ItemSubTypeName`)。
  2. 如果預設不是 simulation,要用 ConsumeXml 的哪個元素、或用 ChangeChildSubType 的哪個 subtype 來切換。
  3. 速度、加速度、減速度、jerk 在 axis ProduceXml 裡的元素路徑(預期在 `AxisDef` 之類的節點底下，元素名稱未知)。
- 結論：專用 tool 的「simulation」參數要等 probe 確認 XML 結構才能寫。在那之前，只能用通用的 `Get-TcTreeItemXml` 加 `Set-TcTreeItemXml` 處理。

### 連結到 I/O(§6.10.2 p.294–295,這期用不到)
- 方法 1:axis 上 ConsumeXml `<TreeItem><NcAxisDef><AxisType>1</AxisType><AxisIoType>CANopen-DS402</AxisIoType><IoItem><PathName>TIID^...^Drive 2 (...)</PathName><Channel>0</Channel></IoItem></NcAxisDef></TreeItem>`。這段 `NcAxisDef` 是**命令型片段**,不在 ProduceXml 裡(推論，需實測)。
- 方法 2:`ITcSysManager3.ConsumeMappingInfo(VarLinks XML)`,`OwnerA Name="TICC^CNC^Axes^Axis_1"`。注意:`ConsumeMappingInfo`「overwrites all existing mappings」(§6.3.14 p.218),不能拿來只加一條 link。

### 連結到 PLC 的 AXIS_REF
- 手冊沒有 NC 對 PLC 的範例(InfoSys 21842434315 也沒有)。可以引用的規則:
  - `LinkVariables(bstrV1, bstrV2, offs1=0, offs2=0, size=0)` 兩端都要是完整的 tree path、都要是 Variable,而且型別和大小要相容(§5.1.1.2 p.38)。錯誤碼有 `TSM_E_ITEMNOTFOUND`、`TSM_E_INVALIDITEMTYPE`、`TSM_E_MISMATCHINGITEMS`、`E_ACCESSDENIED`。
  - §6.3.14 p.217 寫 mapping 可以接 PLC 和「NC axes」;順序是 source、destination;範例 PLC 端是 `TIPC^PlcProj^PlcProj Instance^PlcTask Inputs^bIn`。
  - AXIS_REF 的宣告是 `PlcToNc AT %Q* : PLCTONC_AXIS_REF` 和 `NcToPlc AT %I* : NCTOPLC_AXIS_REF`。PlcToNc 在 PLC 的 output image,要 link 到 NC axis 的 **input** image;NcToPlc 在 PLC 的 input image,要 link 到 NC axis 的 **output** image(InfoSys tcplclibmc2/458448779,TC2 MC2 頁;TC3 Tc2_MC2 頁 404)。
- 推論的 path(**需實測**,特別是 NC 端的變數名稱):

| 方向 | PLC 端 | NC 端 |
|---|---|---|
| NC → PLC | `TIPC^<Plc>^<Plc> Instance^PlcTask Inputs^MAIN.axis.NcToPlc` | `TINC^<task>^Axes^<axis>^Outputs^ToPlc` |
| PLC → NC | `TIPC^<Plc>^<Plc> Instance^PlcTask Outputs^MAIN.axis.PlcToNc` | `TINC^<task>^Axes^<axis>^Inputs^FromPlc` |

  NC 端的 `Outputs^ToPlc` 只出現在 repo 單元測試的假資料(`tests/Unit/io-scan-link.ps1` L29),沒有出處。`Inputs^FromPlc` 完全是推論。
- XAE 的「Link To PLC」在 PLC instance 有 AXIS_REF 的時候，會一次 link 整個 struct。AI 用 `LinkVariables` 對 struct 變數做 link 時，能不能一次 link 完、還是要逐個成員 link:**需實測**。
- AXIS_REF 要在 Build 之後，`PlcTask Inputs/Outputs` 底下才會出現(和 `Set-TcVariableLink` .DESCRIPTION 的前提相同)。

### Activate 之後讀軸狀態(ADS)
- 做法 A(建議):透過 PLC symbol 讀。現有的 `Read-TcVariable -Path "MAIN.axis.NcToPlc.ActPos"` 之類，不需要知道 NC 的 index group,而且同時驗證了 link 有效。要先確認 `NcToPlc` 底下的成員名稱(InfoSys NCTOPLC_AXIS_REF:https://infosys.beckhoff.com/content/1033/tcplclibmc2/458450315.html ,本次沒有打開這頁),以及 `Read-TcVariable` 能不能讀 struct 或巢狀成員:**需實測**。
- 做法 B:直接讀 NC 的 ADS。index group `0x4100 + axisId` 是 axis state,`0x4000 + ID` 是 parameter;`0x00000001` 是錯誤碼(symbolic `ErrState`),`0x00n10002` 是實際位置(`ActPos`),`0x00n00000` 是 axis online structure(InfoSys 713094155、713061899)。那一頁只寫了個別 offset 的 port(例如「Always to SAF Port 501!」「Only port 500!」),**沒有寫預設 port**;axisId 要從 axis 的 ProduceXml 取得：都要實測。做法 B 需要在 `Connect-TcAds` 加上 port 和 raw index 讀取，工作量比較大。
- UmRT 上 NC 能不能真的跑(SAF task 會不會動、模擬軸會不會移動):**需實測**。design.md 的風險表已經寫明:UmRT 跑不起來就列進 known-limitations,不靠推論修。

### 4024 / 4026
- 手冊 §2.2 p.18 的版本表：新增或移除 NC task、axis,axis 參數化，以及和 PLC 的 mapping,都標示 TwinCAT 3.1 支援，沒有細分 build。
- 各 API 的最低 build:**查不到，需實測**(4024 測試專案 `C:\Temp\Verify-4024-bfh`、4026 測試專案 `C:\Temp\Verify-4026-axis`)。

### 可重用的現有 code
- `New-TcTreeItem`(MCP `CreateChild`):可以直接建 NC task(`-Path TINC -SubType 1`)和 axis(`-Path '<task>^Axes' -SubType 1`)。已經有 dry-run、父節點備份、讀回 `createdPath`、`TREEITEM_ALREADY_EXISTS`。SAF 後綴會出現在 `data.createdName` 和 warnings 裡。
- `Get-TcTreeItemXml` / `Set-TcTreeItemXml`(MCP `ConsumeXml`):用來改 ProduceXml 裡**已經存在**的 axis 參數(例如速度)。限制：片段裡不能有 attribute(`attributes-not-supported`),元素路徑也一定要在目前的 XML 裡找得到(`paths-not-in-current-xml`,`Set-TcTreeItemXml.ps1` L13–21)。所以 `NcAxisDef` 這種命令型片段會被擋下來，要另外寫專用 cmdlet。
- `Set-TcVariableLink` / `Remove-TcVariableLink`:link 本身可以直接用，但參數名稱 `-IoChannel` 和說明都寫成 I/O(L4、L17–18)。NC 端是 `TINC^...` path 時是否能通過，看 `Test-TcTreeItemExists` 和 `Test-TcMappingHasLink`。`Get-TcMappingLinks` 解析 ProduceMappingInfo 的 OwnerA / OwnerB 時，能不能認出 NC owner:**需實測**。
- `Read-TcVariable`(做法 A)、`Enable-TcConfig -Force`(Activate 加上 PLC Run)。

---

## 4.2 TcCOM module 實例和參數

### 取得節點、建立實例(§6.7.1 p.273–275)
- 節點路徑:`LookupTreeItem("TIRC^TcCOM Objects")`(p.273)。
- 前提:TcCOM module 要能被 TwinCAT 找到，也就是放在 `TWINCAT3.XDIR\CustomConfig\Modules\`,或在 `TWINCAT3.XDIR\Config\Io\TcModuleFolders.xml` 加上路徑(p.274)。
- 用 GUID 建立:`CreateChild("Test", 0, "", "{8f5fdcff-ee4b-4ee5-80b1-25eb23bd1b45}")`,vInfo 放 GUID 字串(PowerShell 範例，p.274)。C# 範例傳的是 `Guid` 物件。GUID 可以從 TMC 的 `<TcModuleClass><Modules><Module GUID="...">` 找到。
- 用名稱建立:vInfo 放 module 名稱。**手冊在這裡自相矛盾**:C# 範例用 `CreateChild("Test", 1, "", "NewModule")`(subType 1),PowerShell 範例用 `CreateChild("Test", 0, "", "NewModule")`(subType 0),p.275。哪一個是對的:**需實測**。
- 手冊沒有列出系統內建的 TcCOM 類別 GUID。UmRT 上要測試，需要找一個本機已經安裝、不需要額外授權的 module(例如 TwinCAT 內建的 TcCOM 範例模組;本機 `TWINCAT3.XDIR\CustomConfig\Modules\` 或 `Config\Io` 底下有哪些 TMC):**需實測**。這是 4.2 能不能在 UmRT 驗證的關鍵。

### 列舉實例(§6.7.1 p.275、§5.31 p.129–134、§5.32 p.135)
- `ITcSysManager4.GetModuleManager()` 取得 `ITcModuleManager`,用 `foreach` 列舉 `ITcModuleInstance2`:`ModuleTypeName`、`ModuleInstanceName`、`ClassID`、`oid`、`ParentOID`。module 實例本身也是 `ITcSmTreeItem`(p.275)。

| 成員 | 簽名 | 說明 / 例外 |
|---|---|---|
| `ModuleCount` | `LONG*` get | |
| `_NewEnum` | `IUnknown**` | E_POINTER、E_OUTOFMEMORY(§5.31.1.4 p.132) |
| `LookupModule`(v1) | `(ULONG oid, REFIID riid, IUnknown**)` | E_UNEXPECTED:找不到這個 oid(§5.31.1.3 p.131) |
| `LookupModule`(v2) | `(BSTR bstrModuleType, ITcEnumModuleInstances**)` | 用 ModuleTypeName 比對，不分大小寫;找不到回 E_INVALIDARG(§5.31.2.1 p.133) |
| `TryLookupModule`(v2) | `(BSTR, ITcEnumModuleInstances**, VARIANT_BOOL* pbFound)` | 找不到時不丟例外(§5.31.2.2 p.134) |
| `Modules`(v3) | `ITcModuleInstanceCollection**` | `Count`、`Item`、`_NewEnum`(§5.32.1 p.135) |
| `GetOnlineModulePara` | `(ULONG oid, ULONG pid, ULONG maxData, VARIANT* pvData)` | 見下方 online 參數 |
| `SetOnlineModulePara` | `(ULONG oid, ULONG pid, VARIANT vData)` | |
| `Get/SetOnlineModuleParaDWORD` | `(oid, pid, ULONG*)` / `(oid, pid, ULONG)` | |

- interop:`ITcModuleManager` / `ITcModuleManager2` / `ITcModuleManager3` 的成員和手冊一致。interop 另外宣告了 `ITcModuleOnlineMode`(`OnlineMode` get/set、`TcGetObjPara(oid, pid, out nData, out data)`、`TcSetObjPara`),**手冊沒有寫**,不要使用。

### Init 參數(離線，寫進專案)
- XML:`ProduceXml()` 的 `TreeItem/TcModuleInstance/Module/Parameters/Parameter[Name='CallBy']`,範例把 `CreateSymbol` 這個 **attribute** 設成 true 再 ConsumeXml(§6.7.1 p.276)。data area 是 `Module/DataAreas/DataArea[ContextId='0' and Name='Input']/AreaNo` 的 `CreateSymbols` attribute(p.276–277)。
  - 手冊的 C# 範例本身有 bug:用了沒宣告的 `destParameters`、`dataAreaNoNode`,PowerShell 範例裡也混著 `//` 註解。只能參考寫法，不能照抄。
  - 參數的**值**在 XML 裡的元素名稱，手冊沒有寫(例如 `Parameter/Value`?)。**需實測**。
- COM:`ITcModuleInstance.GetModulePara(pid)` 回傳 `VT_ARRAY|VT_UI1` 的 little-endian raw bytes,不帶型別;`GetModuleParaDWORD(pid)` 適用 4 bytes 以內的值;`GetTypeOfModulePara(pid)` 回傳 `ITcTypeInstance`,`.Name` 是 "LREAL" 之類的型別名稱(§6.7.2 p.278–280,§5.33.1 p.136–139)。
  - `SetModulePara(pid, VARIANT)`:成功時「the Tree Item is marked as modified」。例外有 E_INVALIDARG、`ADS_E_INVALIDSIZE`(大小不符)、E_NOTIMPL(fieldbus box 等不支援)、TSM_E_ITEMDELETED(§5.33.1.6 p.139)。
  - pid 是 TMC 裡的 parameter ID(範例是 `0x050300B1`)。手冊沒有提供「參數名稱 → pid」的 API,要從 ProduceXml 的 Parameters 或 TMC 讀出來，**需實測**它在 XML 裡的欄位名稱。
- `ExportXml(bRecursive)` 和 `ImportXml(bstrXML)`(§5.33.1.1 / 5.33.1.5 p.136–139):module 實例的 XML 根元素是 `<TcModuleInstance>`。ImportXml 的錯誤碼有 `TSM_E_XMLERROR` 和 `TSM_E_INVALIDITEMTYPE`。
- repo 現況:`Set-TcTreeItemXml` 把 `TcModuleInstance` 底下的 `Context` / `ParameterValues` 當作**衍生欄位**,不比對，也不准只改這兩個(design.md D3,`derived-only`)。所以透過通用 ConsumeXml 改 Init 參數值會被擋下來，或無法讀回驗證。Init 參數要用 `SetModulePara` 加 `GetModulePara` 讀回，另外包成 cmdlet。

### Context(task 指派)(§6.7.1 p.277–278、§5.33.2 p.140–141)
- `ITcModuleInstance2.SetModuleContext(UINT index, ULONG taskOid)`;`GetModuleContext(index, out oid)`。taskOid 從 task 的 ProduceXml `TreeItem/ObjectId` 取得，值是 16 進位字串(p.278)。
- 例外:E_INVALIDARG 表示 context ID 不存在;E_FAIL 表示 oid 不是這個 context 的合法 task(p.141)。
- interop 的 `GetModuleContext(UInt32 index, out UInt32 pOid)` 是 out 參數，不是 retval。PowerShell late binding 怎麼呼叫(`[ref]`):**需實測**。

### Online 參數(要 Activate 並且 Run)
- `ITcModuleManager.GetOnlineModulePara(oid, pid, maxData)`:手冊寫「Reads data from the target system via AdsSyncReadReq(). The ADS address uses the document's target NetID and AMSPORT_R0_TCOMSERVER. oid is used as the IndexGroup, and pid is used as the IndexOffset.」(§5.31.1.1 p.130)。失敗時回 ADS error code。
- 所以 online 讀寫有兩條路:
  - (a) 透過 IDE 的 ModuleManager。
  - (b) 直接用 ADS:port `AMSPORT_R0_TCOMSERVER`、IndexGroup = oid、IndexOffset = pid。`AMSPORT_R0_TCOMSERVER` 的數值手冊沒有寫(**需實測或查 TcAdsDef.h**)。
  - (b) 不需要 IDE,和 repo 的 ADS client 一致。但 `Connect-TcAds` 目前只連 PLC port(851),要加上 port 和 raw IG/IO 讀寫。
- `SetOnlineModulePara`:`VT_VARIANT|VT_BYREF` 會先解開;SAFEARRAY 依維度寫成連續 buffer;scalar 依型別寫 1、2 或 4 bytes。不支援的型別回 `ADS_E_INVALIDDATA`(§5.31.1.5 p.132)。也就是說，**8 bytes 的 LREAL 不能用 scalar 寫**,要轉成 byte array。
- 用 XML 讀 online value:手冊沒有寫(**需實測**ProduceXml 在 Run 時有沒有 online 值)。

### 重新載入 TMC(§6.7.3 p.280,4024.10 起)
- `ConsumeXml("<TreeItem><ReloadTmc>true</ReloadTmc></TreeItem>")`;可以加 `Path="..." Mode="warm|cold|origin"` attribute;`<ExportTmc Path="..."/>` 可以先備份 TMC。module 的 GUID 改了就會 reload 失敗，要重建。
- 這兩個都是帶 attribute 的命令型片段，會被 `Set-TcTreeItemXml` 擋下來，要另外寫 cmdlet。

### 連結
- 「Variables from a TcCOM module instance can be linked ... using ... ITcSysManager::LinkVariables()」(p.278)。`Set-TcVariableLink` 可以直接用(限制同 4.1)。

### 4024 / 4026
- §2.2 p.18:新增或移除 TcCOM module、參數化，標示 TwinCAT 3.1 支援。ReloadTmc 從 4024.10 起。ModuleManager v2 / v3、ITcModuleInstance2 的 build:**查不到，需實測**。

### 可重用的現有 code
- `New-TcTreeItem -Path 'TIRC^TcCOM Objects' -Name X -SubType 0 -VInfo '{GUID}'`:可以直接建實例(vInfo 是字串)。
- `Get-TcTreeItemXml`:讀 Parameters / DataAreas。
- `Set-TcTreeItemXml`:不適用，因為有 attribute 和衍生欄位的限制。
- 需要新寫的 COM 呼叫:`GetModuleManager`、`Get/SetModulePara`、`SetModuleContext`。

---

## 4.3 Variant management

### 版本支援(**4024 有支援**)
- **TwinCAT 的 variant management 從 build 4024 開始**:「The TwinCAT variant management supports you from build 4024」(VM p.7;InfoSys Concept 頁 6325752587 同一句)。Project Variants toolbar 也是「delivered with build 4024」(VM p.7、p.19)。
- 各項設定的最低 sub-build(VM p.24–30,節錄這期會用到的):
  - System:Target Address 4024.0。Task 的 Disable、Priority / Cycle Ticks 4024.0。
  - TcCOM object:Disable 4024.10,Parameter (Init) 4024.10,另有一項參數設定 4024.17(VM p.25)。
  - NC axis:Disable 4024.0;Mapping(Link to I/O / Link To PLC)4024.4(4024.0 的「Link with I/O」從 4024.4 起由「Mapping」取代);Divider / Modulo 4024.7;axis type 和 unit 4024.17;Parameters 4024.0(VM p.26)。
  - PLC:compiler defines、PLC project / instance 的 Disable、Symbol Initialization 4024.0(VM p.27)。
  - C++:4024.10(InfoSys 8843640971)。I/O:EtherCAT Master 4024.0,Mapping 4024.4,部分設定 4024.17(VM p.29–30)。
- Automation Interface 的部分:「Access is possible from iTcSysManager14 (TCatSysManagerLib V 3.3.0.0)」(§6.12.1 p.296;InfoSys 8204600715)。**手冊沒有寫 TCatSysManagerLib 3.3.0.0 對應哪個 4024 sub-build**,所以本機 4024 XAE(BFH 測試環境)的 `$sm` 上能不能 late-bind 到 `CurrentProjectVariant`:**需實測**。本機 interop 是 3.4.0.0,有宣告這些成員。

### API(§5.1.13 p.52;InfoSys 21841711371)
| 成員 | 型別 | 說明 |
|---|---|---|
| `CurrentProjectVariant` | BSTR get/set | 「Name of the active project variant.」設值後「the project switches to the appropriate variant configuration and the corresponding item set in memory」。可以給 variant 名稱，或用 `[Group1]` 指定 group(§6.12.1 p.296) |
| `ProjectVariantConfig` | BSTR get/set | 「An XML document that describes the available project variants and their build settings.」 |
| `ProjectVariantItems` | BSTR get/set | 「An XML document that specifies, for each variant, which Tree Items are included or excluded.」手冊沒有範例 |
| `PinnedTcVersion` | BSTR get | 固定的 TwinCAT 版本;沒有固定時是空字串 |

- 例外：手冊和 InfoSys **都沒有寫**。設成不存在的 variant 名稱、或專案還沒定義 variant 時會發生什麼:**需實測**。
- 個別 item 的 variant 旗標:`ITcSmTreeItem9` 的 `PvDefine`、`PvDisable`、`PvLink`、`PvParameter`(VARIANT_BOOL),`PvSParameter`(`TCPV_PARA_VALUES`:`PV_NONE 0`、`PV_ALL 1`、`PV_SELECTED 2`),出處 §5.2.7 p.64、§5.46.17 p.165;interop 一致。`ITcSmTreeItem10.PvSimulation`(p.65)。
  - 手冊前後不一致:§5.2 的版本表(p.56)把「Flags for project variants」放在 ITcSmTreeItem6 那一列，但 §5.2.4 p.62–63 的 ITcSmTreeItem6 只有 SaveInOwnFile / SignFile / EncryptFile / ObjectProtectionLevel。interop 的 `ITcSmTreeItem6` 也沒有 Pv*,只有 `ITcSmTreeItem9` 有。以 §5.2.7 和 interop 為準。
  - 用法(p.296):先設 `PvDisable = true`(啟用這一項的 variant 管理),切到目標 variant,再設 `Disabled = SMDS_DISABLED`。只在目前的 variant 生效。

### XML(§6.12.1 p.296)
```xml
<?xml version="1.0"?>
<ProjectVariants>
  <Group><Name>Group1</Name><Member>Variant1</Member><Member>Variant2</Member></Group>
  <Group><Name>Group2</Name><Member>Variant2</Member><Member>Variant3</Member></Group>
  <Variant><Name>Variant1</Name></Variant>
  <Variant><Name>Variant2</Name></Variant>
  <Variant><Name>Variant3</Name></Variant>
</ProjectVariants>
```
- 寫入的方式是**整份取代**(`sysManager.ProjectVariantConfig = variantConfig`)。手冊沒有說它是合併還是覆蓋。推論是覆蓋，所以「新增一個 variant」要先讀出、加一筆、再整份寫回，並且要套用 D2(先備份、寫完讀回)。
- 讀出來的 XML 會不會多出「build settings」相關的元素(InfoSys 的描述提到 build settings):**需實測**。
- 自動加入的 `[All]` group:「A special group that is automatically added when creating the first variant is the group [All]」(VM p.7)。
- 選了 group 的時候不能 activate:「If a group is selected it is not possible to activate the configurations, as different variant-specific values for a setting can lead to an undefined state」(VM p.7)。所以 `Enable-TcConfig` 前如果 `CurrentProjectVariant` 是 `[...]` 開頭，應該擋下來，給出新錯誤碼。

### 和現有流程的互動(推論，需實測)
- 切換 variant 會改變 item 的 Disabled 狀態、mapping 和參數，因此 Build / Activate 的結果會跟著改變。切換之後應該記錄 BUILD_REQUIRED(用 `Register-TcCodeChange` 或類似機制)。
- variant 設定存在 `.tsproj` 的哪裡(元素名稱):**需實測**。這會影響 D2 備份要備份哪個檔案。

### 可重用的現有 code
- 沒有可以直接用的通用 tree tool(這是 SysManager 屬性，不是 tree item)。要新寫 cmdlet,但很薄。
- `Invoke-TcTreeItemBackup` 的備份目錄慣例(`.tcauto-backup\<timestamp>\`)可以拿來存 `ProjectVariantConfig` 的備份。

---

## 4.4 Independent project file

### API(§6.3.9 p.210、§5.2.4 p.62–63)
- `ITcSmTreeItem6.SaveInOwnFile`(VARIANT_BOOL get/set)對應 XAE 的「Independent Project File」勾選框。設定之後要 `SaveProject()`(C# 範例用 `sysManager.SaveProject()`),`.xti` 才會產生(p.210)。PowerShell 範例只設了屬性，沒有存檔。
- 這組屬性「apply only to items that can be saved in their own file. For other items, the getters return neutral values, and the setters do nothing and return S_OK」(§5.2.4 p.62)。**對不支援的 item 設 true 也會回 S_OK**,所以一定要讀回 getter,並檢查磁碟上有沒有出現 `.xti`,才能判斷是否成功(這正是 #28 那一類的誤報風險)。
- interop:`ITcSmTreeItem6.get_SaveInOwnFile` / `set_SaveInOwnFile` 有宣告。
- `ITcSysManager` 上**沒有** `SaveAsIndependentFile` 之類的方法(手冊和 interop 都沒有)。
- 哪些物件支援:
  - InfoSys source control 頁:「It is possible in TwinCAT to save individual sub-projects, NC axes or I/O devices explicitly in separate files.」而且這個功能要先在全域選項(TwinCAT → XAE Environment → File settings → Enable Multiple Files)開啟一次;那些全域選項「only become effective after restarting the development environment」。重啟這句講的是全域選項，不是單一物件的勾選。
  - PLC project:「The PLC project is explicitly saved in a separate (*.XTI) file」,而且 PLC project 的 links 會改存在 PLC 的 XTI,不再存在 `.tsproj`(InfoSys 7738192779)。
- 對 repo 的影響:
  - D2 的「節點對應的磁碟檔」備份(`Find-TcTreeItemDiskFile`)要能找到新的 `.xti`。
  - 開了 PLC independent file 之後，mapping 改存到 PLC 的 `.xti`。`Set-TcVariableLink` 的讀回用的是 ProduceMappingInfo(不讀檔),不受影響;但 D2 備份 mapping 時要備份對的檔案(推論)。
  - `.tsproj` 會被改寫。`Reset-TcSolution` 的規則講的是外部改寫磁碟檔，這裡是 XAE 自己存檔，不適用(推論)。
- 4024 / 4026:手冊沒有寫 build。**需實測**4024 上的 PowerShell late binding 能不能讀寫 SaveInOwnFile。

### 可重用的現有 code
- `Get-TcTreeItem` 讀 item 的基本資訊;`Invoke-TcTreeItemBackup` 備份 `.tsproj`;存檔的部分參考 `Invoke-TcProjectSaveWithDeadline`(第 2 期的 deadline 存檔)。
- 通用 tree tool 沒有「設 COM 屬性」的功能(ConsumeXml 改的是 XML),所以需要一個小的專用 cmdlet。SaveInOwnFile 有沒有出現在 ProduceXml 裡(如果有，就能用 Set-TcTreeItemXml):**需實測**。

---

## 4.5 ADS route

### 節點
- `LookupTreeItem("TIRR")`,ItemName 是「Route Settings」(§6.3.11 p.211–212、§6.3.17 p.220、§6.4 p.222–225)。注意:`TreeItemPath.ps1` L13 的 `$script:TcTreeRootCandidates` 沒有 `TIRR`。這個清單只用在路徑錯誤時列出可用的根節點，不影響 lookup;但建議補上 `TIRR`,讓錯誤提示能列出它。

### Broadcast search(§6.3.11 p.211–213、§6.4.2 p.224–225)
- 全網搜尋:`ConsumeXml("<TreeItem><RoutePrj><TargetList><BroadcastSearch>true</BroadcastSearch></TargetList></RoutePrj></TreeItem>")`,接著 `ProduceXml()`,結果在 `TreeItem/RoutePrj/TargetList/Target`。
- 指定 IP 或 hostname 搜尋(**4020.10 起**):`<TargetList><Search>172.17.60.153</Search></TargetList>` 或 `<Search>CX-12345</Search>`。
- 結果的 XML(p.212–213):
```xml
<TreeItem><RoutePrj><TargetList>
  <Target>
    <Name>CX-12345</Name><NetId>172.17.60.153.1.1</NetId><IpAddr>172.17.60.153</IpAddr>
    <Version>3.1.4026</Version><OS>Windows (10.0)</OS>
  </Target>
</TargetList></RoutePrj></TreeItem>
```
- 手冊 PowerShell 範例的 `$xmlDocument.TreeItem.RoutePrj.Target` 少了 `TargetList` 這一層(p.212、p.224),和上面的結構不一致。以結構為準。
- ConsumeXml 是不是同步等搜尋結束、要花多久、搜尋 timeout 是多少:**需實測**。沒有第二台 target 時，本機應該至少能找到自己或 UmRT(**需實測**)。

### 新增 route(§6.3.17 p.220–221、§6.4.1 p.222–223)
```xml
<TreeItem>
  <ItemName>Route Settings</ItemName>
  <PathName>TIRR</PathName>
  <RoutePrj>
    <TargetList><BroadcastSearch>true</BroadcastSearch></TargetList>
    <AddRoute>
      <RemoteName>RouteName</RemoteName>
      <RemoteNetId>1.2.3.4.5.6</RemoteNetId>
      <RemoteIpAddr>1.2.3.4</RemoteIpAddr>        <!-- 或 <RemoteHostName>CX-12345</RemoteHostName> -->
      <UserName>userName</UserName>
      <Password>password</Password>
      <NoEncryption></NoEncryption>
      <LocalName>LocalName</LocalName>
    </AddRoute>
  </RoutePrj>
</TreeItem>
```
- Project route(只寫進專案，不到 target 新增):`<AddProjectRoute><Name/><NetId/><IpAddr/>`(或 `<HostName/>`)`</AddProjectRoute>`。這段可以和 AddRoute 放在同一份 XML(p.221、p.223)。
- 「Only unencrypted routes are created using this method; ADS Secure / encrypted routes are not supported.」(p.220)
- 欄位裡**沒有** static / temporary 的選項。手冊的欄位只有 RemoteName、RemoteNetId、RemoteIpAddr / RemoteHostName、UserName、Password、NoEncryption、LocalName。XAE Add Route Dialog 裡的「Static / Temporary」、「Advanced Settings」在 AI 怎麼指定：**查不到，需實測**(用 ProduceXml 看 TIRR 有沒有對應欄位)。`NoEncryption` 的語意(空元素代表什麼)手冊也沒有說明。
- 範例都在 AddRoute 前面先放 `<BroadcastSearch>true</BroadcastSearch>`。這是必要的還是只是範例習慣:**需實測**。
- 成功與否只能從例外判斷;手冊沒有寫錯誤碼。讀回驗證的方式也沒有寫(推論：再做一次 ProduceXml,或用 ADS 連 target 的 port 10000 讀 state)。**需實測**。

### 刪除 route
- 「It is not possible to delete items directly via the Automation Interface. An alternative is to edit StaticRoutes.xml directly.」(p.220)
- 手冊的做法(p.221):載入 `C:\TwinCAT\3.1\Target\StaticRoutes.xml`,用字串取代刪掉 `<Route><Name/><Address/><NetId/><Type>TCP_IP</Type></Route>`,然後存檔。「Changes to the StaticRoutes.xml take effect only after the TwinCAT service is restarted.」
- 路徑問題:手冊的 Requirements 寫成 `C:\TwinCAT\3.1\TargetStaticRoutes.xml`(少了 `\`),code 裡寫的是 `...\Target\StaticRoutes.xml`。4026 把 Boot 目錄搬到 `%ProgramData%\Beckhoff\TwinCAT\3.1\Boot`(InfoSys 4291093003,repo 已引用),Target 目錄是否也一起搬了:**查不到，需實測**。UmRT 的 Target 目錄在 `...\Runtimes\<name>\3.1\Target`(InfoSys TF6310 頁的 UmRT 範例路徑 `C:\ProgramData\Beckhoff\TwinCAT\3.1\Runtimes\UmRT_Default\3.1\Target`,https://infosys.beckhoff.com/content/1033/tc170x_tc3_usermode_runtime/15569027467.html ,搜尋摘要，本次沒有打開)。
- 重啟 TwinCAT service 有副作用：repo 已知 Reset 會殺掉 `TcSystemServiceUm`(CLAUDE.md、troubleshooting「known limits」)。刪 route 的 tool **不能自動重啟 service**,只能回報 `restartRequired: true`,讓使用者決定。
- 刪除要寫系統目錄，可能需要 admin。手冊用字串取代，順序或空白不同就刪不到。建議改成解析 XML,用 Name + NetId 比對，再刪掉那個節點。刪之前先備份 StaticRoutes.xml,刪完讀回確認(套用 D2)。

### 密碼(重點)
- **XML 裡的密碼是明文**。手冊所有 AddRoute 範例都把 `<Password>password</Password>` / `<Password>1</Password>` 直接寫在 ConsumeXml 字串裡(p.220、p.222–223),沒有加密或 hash 欄位。
- 送到 target 的過程:Beckhoff Advisory 2017-002(CVE-2017-16718)寫到，透過 ADS 遠端新增 route 時，帳號密碼的「encryption bases on a fixed key」,攻擊者可以抽出這個 key 解密(只要在新增 route 的當下有網路存取);建議「By adding the static routes only locally, no credentials will be transferred via network」,或改用 Secure ADS。所以就算 XAE 有加密，**在網路上也只算可以還原**。
- 存起來的 route:手冊的 StaticRoutes.xml `<Route>` 範例只有 `Name`、`Address`、`NetId`、`Type`(p.221),**沒有密碼欄位**。推論 route 本身不存密碼，密碼只在建立 route 時用來向遠端認證一次。
- **ProduceXml 會不會把密碼讀回來**:手冊和 InfoSys 都沒有寫,**需實測**(probe 時用一個**假密碼**送 AddRoute 到不存在的 IP,再 ProduceXml TIRR,grep 那個假密碼)。
- 附帶一提，同類的風險:`TISY` 的 `<BootSettings><LogonPassword>`,手冊寫「The password for AutoLogon is stored in the project」(§6.3.18 p.222)。所以通用的 `Get-TcTreeItemXml TISY` 可能會回傳明文密碼(推論，需實測)。
- **對 repo 的影響(不論實測結果都要做)**:
  1. route 專用 tool 的參數 `Password` 不能寫進 log、`data`、錯誤訊息或 hint。ConsumeXml 失敗時，`New-TcTreeItemErrorResult` 會不會把 XML 字串帶進錯誤訊息，要先確認;專用 tool 要自己組錯誤訊息，不能帶 XML 原文。
  2. D2 的 ProduceXml 備份(`.tcauto-backup\...`)和 `Set-TcTreeItemXml` 的 `data.currentXml` / `data.changes` 都可能含有密碼。建議在 `Get-TcTreeItemXmlText` 這一層加一個統一的遮罩:元素名稱符合 `Password|LogonPassword|Pwd` 的內容換成 `***`,備份檔也用遮罩後的內容。這也應該補到第 1 期的通用 tool。
  3. MCP 層：tool 的 input 本身就含有密碼，會出現在 client 的對話紀錄裡。這點無法避免，要在 description 寫明，建議只對測試機使用;或者提供一個從環境變數讀密碼的選項(例如 `PasswordEnv`)。
  4. 用通用的 `Set-TcTreeItemXml` 送 `<AddRoute>` 會因為 `paths-not-in-current-xml` 被擋下來(AddRoute 不在 ProduceXml 裡;推論，需實測)。這正好避免了密碼經過通用 tool 的 data 回傳，所以**不要放寬通用 tool**,改寫專用 cmdlet。

### Target NetId(相關，已有)
- `ITcSysManager2.SetTargetNetId("...")`、`SetTargetNetId("")` 回到本機、`GetTargetNetId()`(p.221)。repo 的 `Set-TcTarget` 已經有。

### 4024 / 4026
- §2.2 p.16–17:route 管理、新增或移除 ADS route、broadcast search,標示 TwinCAT 3.1 支援。direct search 從 4020.10 起。其他:**需實測**。沒有第二台 target,新增或刪除到遠端的部分只能做單元測試(proposal / design 已經寫明),known-limitations 要標「未實測」。

### 可重用的現有 code
- `Get-TcTreeItemXml -Path TIRR`:可以直接看 route 和搜尋結果，但要先處理上面的密碼遮罩。
- `Set-TcTreeItemXml`:不適用(命令型片段)。
- `Set-TcTarget`:target NetId。
- 新的 cmdlet 共用：組 XML(用 `XmlDocument` 建，不用字串拼接，避免 injection)、解析 `TargetList`。

---

## 第 1 期通用 tool 能直接組合 vs 需要新 cmdlet

| 需求 | 通用 tool 能否處理 | 理由 |
|---|---|---|
| 建 NC task / axis | 可以:`CreateChild` | subType 1(p.293);讀回 createdPath 處理 SAF |
| 改 axis 既有參數 | 可以:`ConsumeXml` | 前提是元素已經在 ProduceXml 裡、沒有 attribute(需實測 XML 結構) |
| 設 simulation encoder / drive | 未知 | 可能要 ChangeChildSubType(通用 tool 沒有)或命令型 XML;需實測 |
| NcAxisDef link 到 I/O | 不行 | 命令型片段，會被 `paths-not-in-current-xml` 擋下 |
| link 到 AXIS_REF | 可以:`SetVariableLink` | 但描述寫的是 I/O;struct link 和 NC owner 的解析需實測 |
| 讀軸狀態 | 可以:`ReadVariable` | 透過 PLC 的 `NcToPlc`;NC 原生的 ADS 要新寫 |
| 建 TcCOM 實例 | 可以:`CreateChild` | vInfo 放 GUID 字串(p.274) |
| TcCOM CreateSymbol | 不行 | XML attribute(`attributes-not-supported`) |
| TcCOM Init 參數值 | 不行 | 衍生欄位規則 + 沒有 value 元素出處 → 用 SetModulePara |
| TcCOM context | 不行 | COM 方法 SetModuleContext |
| TcCOM online 參數 | 不行 | ModuleManager 或 ADS raw IG/IO |
| ReloadTmc / ExportTmc | 不行 | 帶 attribute 的命令型片段 |
| Variant | 不行 | SysManager 屬性 |
| Independent file | 不行(除非 ProduceXml 裡有這個欄位) | COM 屬性加上存檔 |
| Route 搜尋 / 新增 | 不行，**也不應該放寬** | 命令型片段 + 密碼 |
| Route 刪除 | 不行 | AI 不支援，要改 StaticRoutes.xml |

---

## 建議的 cmdlet / MCP tool 設計

所有修改類 tool 都套用 D2:`DryRun` 預設為 true、先備份、`IDE_MODAL_DIALOG` 檢查、讀回驗證、`destructiveHint`。MCP 名稱照 CLI action 名稱。

### 4.1 NC
| tool(MCP / cmdlet) | 參數 | 備註 |
|---|---|---|
| `AddNcTask` / `Add-TcNcTask` | `Name='NC-Task 1'`、`DryRun=true` | 內部用 New-TcTreeItem(TINC, subType 1);data 回 `createdPath`(含 SAF)、`axesPath` |
| `AddNcAxis` / `Add-TcNcAxis` | `Name`、`Task?`(省略時用唯一的 task;有多個時回 `NC_TASK_AMBIGUOUS`)、`Folder?`、`Simulation=$true`、`MaxVelocity?`、`Acceleration?`、`Deceleration?`、`DryRun=true` | `Simulation` 和速度參數要等 probe 確認 XML 元素後再開放;在那之前只建軸，回 `data.encoderType` / `data.driveType`(讀回值) |
| `LinkNcAxisToPlc` / `Set-TcNcAxisLink` | `Axis`(tree path 或名稱)、`PlcVariable`(例如 `MAIN.axis`)、`PlcProjectPath?` | 自動組出 PLC / NC 兩端的 path(NcToPlc ↔ Outputs、PlcToNc ↔ Inputs),內部呼叫 Set-TcVariableLink 兩次，再用 ProduceMappingInfo 讀回;要求 Build 過(否則回 `BUILD_REQUIRED`) |
| `GetNcAxisState` / `Get-TcNcAxisState` | `PlcVariable`(做法 A),之後可以加 `AxisId`(做法 B) | 唯讀;回 `actPos`、`actVelo`、`errorCode`、`state`(依 NcToPlc 成員，需實測) |

- design.md Open Question「要不要 composite」:建議**先不做**。等上面四個 tool 和 `RunLifecycle` 實測穩定之後，再考慮 `RunNcAxisCycle`。

### 4.2 TcCOM
| tool | 參數 | 備註 |
|---|---|---|
| `AddTcComModule` / `Add-TcComModule` | `Name`、`ClassId`(GUID)或 `ModuleName`、`Task?`(設 context 0)、`DryRun=true` | CreateChild 加上可選的 SetModuleContext;用名稱建立時的 subType(0 或 1)要等 probe |
| `GetTcComModules` / `Get-TcComModule` | `Type?` | 唯讀,ModuleManager 列舉:`instanceName`、`typeName`、`classId`、`oid`、`parentOid`、`path` |
| `GetTcComParameter` / `Get-TcComParameter` | `Path`、`Pid` 或 `Name`、`Online=$false` | 離線用 GetModulePara 加 GetTypeOfModulePara 解碼;online 用 GetOnlineModulePara(要 Run);回 `typeName`、`value`、`rawHex` |
| `SetTcComParameter` / `Set-TcComParameter` | `Path`、`Pid` 或 `Name`、`Value`、`Online=$false`、`DryRun=true` | 依 GetTypeOfModulePara 把值轉成 byte array;離線寫入後讀回並記錄 BUILD_REQUIRED(推論);online 寫入不改專案 |
| `ReloadTcComTmc` / `Update-TcComTmc` | `Path`、`TmcPath?`、`Mode='warm'`、`DryRun=true` | 4024.10 起;先用 ExportTmc 備份 |

新錯誤碼候選:`TCCOM_CLASS_NOT_FOUND`、`TCCOM_PARAM_NOT_FOUND`(E_FAIL / E_INVALIDARG)、`TCCOM_PARAM_SIZE_MISMATCH`(ADS_E_INVALIDSIZE)、`TCCOM_CONTEXT_INVALID`。

### 4.3 Variant
| tool | 參數 | 備註 |
|---|---|---|
| `GetProjectVariants` / `Get-TcProjectVariant` | – | 唯讀:`current`、`variants[]`、`groups[]`(解析 ProjectVariantConfig)、`supported`(late-bind 失敗時為 false,錯誤碼 `VARIANT_NOT_SUPPORTED`) |
| `AddProjectVariant` / `Add-TcProjectVariant` | `Name`、`Groups?`、`DryRun=true` | 讀出、加一筆、整份寫回、讀回;先備份原本的 XML |
| `SetProjectVariant` / `Set-TcProjectVariant` | `Name`(可以是 `[Group]`) | 設定後讀回 `CurrentProjectVariant`,不一致回 `VARIANT_SWITCH_FAILED`;記錄 BUILD_REQUIRED |
| `Enable-TcConfig` 的前置檢查 | – | current 是 group 時回 `VARIANT_GROUP_ACTIVE`,不 activate(VM p.7) |

### 4.4 Independent file
| tool | 參數 | 備註 |
|---|---|---|
| `SetIndependentFile` / `Set-TcIndependentFile` | `Path`、`Enabled`、`DryRun=true` | 設定後讀回 getter,存檔，再確認磁碟上 `.xti` 出現或消失;getter 沒變(不支援的 item)回 `INDEPENDENT_FILE_UNSUPPORTED`,不能報成功 |
| `GetTreeItem` 擴充 | – | data 加上 `saveInOwnFile` |

### 4.5 Route
| tool | 參數 | 備註 |
|---|---|---|
| `FindAdsTargets` / `Find-TcAdsTarget` | `Search?`(IP 或 hostname;省略時全網搜尋)、`TimeoutSec?` | 唯讀(會送 broadcast);回 `targets[] {name, netId, ipAddr, version, os}` |
| `GetAdsRoutes` / `Get-TcAdsRoute` | – | 讀 TIRR ProduceXml 或 StaticRoutes.xml;**一律遮罩密碼** |
| `AddAdsRoute` / `Add-TcAdsRoute` | `Name`、`NetId`、`Address`(IP 或 hostname)、`UserName`、`Password`(SecureString 或 `PasswordEnv`)、`LocalName?`、`ProjectRoute=$false`、`DryRun=true` | 用 XmlDocument 組 XML;dry-run 的回傳只有 `password: '***'`;失敗時回 `ROUTE_ADD_FAILED`(design.md 已預定),訊息不帶 XML |
| `RemoveAdsRoute` / `Remove-TcAdsRoute` | `Name`、`NetId`、`ConfirmName`、`DryRun=true` | 改 StaticRoutes.xml:備份、刪除節點、讀回;回 `restartRequired: true`;**不自動重啟 service**;沒有權限時回 `ROUTE_REMOVE_ACCESS_DENIED` |

---

## 查不到的項目(要實測才能下結論)
- NC:simulation encoder / drive 的設定方式，以及速度、加減速的 XML 元素;NC task 實際名稱(SAF);NC 端 `Outputs^ToPlc` / `Inputs^FromPlc` 的變數名稱;struct link;NC 的 ADS 預設 port;UmRT 上的 NC 授權和實際運作。
- TcCOM:用名稱建立時的 subType(0 或 1,手冊矛盾);Parameters 裡值的元素名稱;本機有哪個不需授權的 module 可以拿來測;`AMSPORT_R0_TCOMSERVER` 的數值;online 時 XML 有沒有 online 值;`GetModuleContext` 的 out 參數在 PowerShell 怎麼呼叫。
- Variant:TCatSysManagerLib 3.3.0.0 對應的 4024 sub-build;不存在的名稱或沒有定義 variant 時的行為;ProjectVariantConfig 是覆蓋還是合併;存在 `.tsproj` 的哪個元素。
- Independent file:哪些 item 實際支援;ProduceXml 有沒有對應欄位;4024 上的 late binding。
- Route:static / temporary 的欄位;NoEncryption 的語意;AddRoute 是否一定要搭配 BroadcastSearch;**ProduceXml 會不會讀回密碼**;4026 的 StaticRoutes.xml 路徑;搜尋耗時。

## Probe 要實測的問題清單
環境:4026(`C:\Temp\Verify-4026-axis`,VS2022)和 4024(`C:\Temp\Verify-4024-bfh`)的副本，透過已註冊的 tcauto MCP 執行(`mcp__tcauto__*`;沒有 tool 的部分才用自己寫的 client,結果要分開標示)。在 zh-TW culture 下跑。每一題都記錄日期和環境。

**NC(4.1)**
1. 4024 / 4026 的 UmRT 專案上,`LookupTreeItem("TINC")` 能不能成功;`CreateChild("NC-Task 1", 1)` 回傳的 `PathName`(有沒有 SAF、完整名稱是什麼);要不要授權。
2. `<task>^Axes` 上 `CreateChild("Axis 1", 1)`,記錄 axis 和子節點(Enc、Drive、Ctrl)的 `ItemType`、`ItemSubType`、`ItemSubTypeName`;預設是不是 simulation。
3. axis ProduceXml 全文(存起來):找出 axis type、encoder / drive 型別、最大速度、加速度、減速度、jerk 的元素路徑;ConsumeXml 改其中一個速度，讀回後檢查有沒有其他欄位被連帶改動。
4. 如果預設不是 simulation:`ChangeChildSubType` 改 Enc / Drive 的 subtype(值從 probe 2 推得);記錄可以用的值。
5. PLC 加上 `axis : AXIS_REF` 並 Build 之後，列出 `PlcTask Inputs/Outputs` 底下 axis 的子節點，以及 NC axis 的 `Inputs` / `Outputs` 子節點名稱;用 `LinkVariables` link 整個 `NcToPlc` ↔ `Outputs^ToPlc`(或 probe 找到的名稱),看是否成功;ProduceMappingInfo 怎麼表示;`Get-TcMappingLinks` 能不能解析。
6. Activate 並 Run 之後,`Read-TcVariable MAIN.axis.NcToPlc.ActPos`(和其他成員)讀不讀得到、模擬軸會不會動(PLC 下 MC_Power / MC_MoveAbsolute,或只確認 `NcToPlc` 有在更新)。
7. 從 axis ProduceXml 取得 axisId;用 ADS 讀 `0x4100+ID` / `0x00000001`,分別試 port 500 和 501。

**TcCOM(4.2)**
8. 本機 `CustomConfig\Modules`、`Config\Io` 底下有哪些 TMC(列出 GUID 和名稱),挑一個不需要授權的。
9. `TIRC^TcCOM Objects` 上用 GUID 字串建立(subType 0);用名稱建立(subType 0 和 1 各試一次);各自的回傳值和錯誤。
10. module 的 ProduceXml 全文:Parameters / Parameter 的值元素名稱、pid 欄位、DataAreas、Context。
11. `GetModuleManager()` 列舉;`GetModulePara`、`GetTypeOfModulePara` 讀一個 UDINT 參數和一個 LREAL 參數;`SetModulePara` 寫入再讀回;寫入後 ProduceXml 有沒有反映;`.tsproj` 有沒有變。
12. `SetModuleContext(0, taskOid)` 和 `GetModuleContext` 在 PowerShell late binding 下的呼叫方式。
13. Activate 並 Run 之後,`GetOnlineModulePara(oid, pid, 8)` 和 `SetOnlineModulePara`;用 ADS raw(IG = oid、IO = pid)讀同一個值做比對，確認 TcCOM server 的 port 數值。
14. ReloadTmc(4024.10 以上)對 UmRT 專案的效果;ExportTmc 產生的檔案。

**Variant(4.3)**
15. 4024 XAE 上 `$sm.CurrentProjectVariant` 讀不讀得到(late bind),記錄 XAE 版本和 TCatSysManagerLib 版本。這是「4024 是否支援」唯一能確認的方式。
16. 沒有 variant 的專案：讀 `ProjectVariantConfig` / `ProjectVariantItems` 的原始值。
17. 寫入範例 XML 之後讀回(有沒有自動加 `[All]`、有沒有多出 build settings);再寫一份只有一個 variant 的 XML,確認是覆蓋還是合併。
18. 設成不存在的名稱、設成 `[Group1]`、group 狀態下 Activate,各自的錯誤;`.tsproj` 裡的存放元素。
19. 一個 I/O item 設 `PvDisable = true` 並切換 variant,`Disabled` 怎麼變化。

**Independent file(4.4)**
20. 對 PLC project root、I/O device、NC axis、Task、TcCOM 實例分別設 `SaveInOwnFile = true`,讀回 getter,存檔後檢查 `.xti`;關掉再看(`.xti` 會不會被刪除)。
21. ProduceXml 有沒有對應欄位;PLC 開了之後 mapping 在磁碟上存在哪裡。

**Route(4.5)**
22. `TIRR` ProduceXml 全文(先看一次，**確認沒有密碼**之後才能存進 verification 文件)。
23. 全網 BroadcastSearch 和 `<Search>127.0.0.1</Search>` / 本機 hostname:耗時，以及結果裡有沒有本機或 UmRT。
24. 用**假密碼**(例如隨機 16 字元)對一個不存在的 IP 送 AddRoute(預期失敗):錯誤訊息裡有沒有密碼;之後 ProduceXml TIRR、`StaticRoutes.xml`、`.tsproj`、XAE log 都 grep 這個假密碼。
25. 只送 `AddProjectRoute`(不需要遠端):`.tsproj` 的變化，以及刪除方式(project route 也許能用 ConsumeXml 或 DeleteChild 刪?)。
26. 4026 和 4024 的 StaticRoutes.xml 實際路徑(XAR 和 UmRT);一般使用者有沒有寫入權限。
27. 有第二台 target 時(第 4 期):AddRoute 成功 → 讀回 → RemoveAdsRoute 改檔 → 重啟 service 後確認 route 消失。在那之前,known-limitations 標「未實測」。
