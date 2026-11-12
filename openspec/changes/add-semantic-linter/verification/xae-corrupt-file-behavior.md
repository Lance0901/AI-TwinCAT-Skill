# XAE 遇到損毀 / 被 AI 改壞的專案檔時的實際行為(tasks 1a.7)

- 日期:2026-11-13(實測)
- 環境:Windows 11 Home 10.0.26200;TwinCAT XAE 3.1.4026.22(Remote Manager 3.1.4026.22)
- 4026 host:VS2022 Community 17.14(`VisualStudio.DTE.17.0`,devenv 17.14.36811.4),專案 `C:\Temp\lint-ide\axis`(`C:\Temp\Verify-4026-axis` 的副本)
- 4024 host:32-bit XAE Shell(`TcXaeShell.DTE.15.0`,由 `ConnectIde` 依 Remote Manager 4024.71 選出,remoteManagerVerified true),專案 `C:\Temp\lint-idefh`(`C:\Temp\Verify-4024-bfh` 的副本),solution platform `Release|TwinCAT RT (x64)`
- 工具:registered tcauto(master runtime)。只做 IDE 操作,沒有 Activate / Login / runtime。
- 方法:`C:\Temp\lint-ide\tools\Lint-Plant.ps1`(腳本不入 repo,植入內容逐案寫在下表)。每批:還原乾淨基準 → 植入 → `ResetSolution`(必要時 `DiscardProjectChanges`)→ `GetProjectTree` → `CheckAllObjects` → `BuildProject` → 比對植入前後所有檔案的 SHA256(看 XAE 有沒有自己改寫磁碟)。
- 植入對象 `FB_C01`~`FB_C20` 是 `FB_LintBase`(XAE 建的空 FB)的複本,**沒有被任何程式呼叫**;`FB_LintTest` / `I_LintItf` 也沒被呼叫。所以「Build 成功」代表「XAE 的 Build 不會擋」,不代表被引用時也不擋(被引用的情況本次沒測)。

## 0. 先看結論

1. **Build 擋不住壞檔**。沒被引用的物件,無論 XML 壞成什麼樣子,`BuildProject` 都回 `buildSucceeded=true`(LastBuildInfo,pane `Build complete -- 0 errors`)。XAE 的「載入錯誤」(schema 不符、缺 Declaration、GUID 重複)只出現在 Error List;`CheckAllObjects` 會列出其中一部分。
2. **最危險的是「靜默」**:XML 不 well-formed(少結束標籤、未跳脫 `<` `&`、CDATA 被提早結束)時,物件仍在樹上但 itemType 變成 0(XAE 不認得它是什麼),**Check 與 Build 都沒有任何錯誤或警告**。這類只有 linter 抓得到。
3. **XAE 會自己改磁碟檔**:全零 GUID、跨檔重複 GUID 在載入時被 XAE 換成新 GUID 並寫回磁碟(沒有任何提示)。
4. **同一 POU 內子物件重複 GUID** 讓整個 POU 變成 itemType 0(無法編輯、無法寫入程式碼),Error List 有 error。
5. **子物件結構錯可能讓 VS2022 當機**:第 4 批(4 個 SUB 案例同批)在 `ResetSolution` 重開方案時 devenv 0xc00000fd(stack overflow)當掉;逐案拆開的結果見 2.4。

## 1. 結果表(4026,VS2022)

欄位:對話框 = ResetSolution 期間 XAE 跳的框(reload 提示由 tcauto 處理,不另列);樹 = `GetProjectTree` 的名稱 / type;Check / Build = 與該案例有關的 Error List 原文(`CheckAllObjects` / `BuildProject`);改寫 = XAE 是否在載入後改了磁碟檔。

### 1.1 XML / CDATA / 必要元素(第 1 批)

| 案例 | 規則 | 植入 | 對話框 | 樹 | Check | Build | 改寫 | 建議 blockable |
|---|---|---|---|---|---|---|---|---|
| C01 | XML-001 | 刪掉 `</Declaration>`(不 well-formed) | 無 | 在,**itemType 0** | 無 | 成功,無 | 否 | **true**:XAE 靜默壞掉,沒有任何訊息 |
| C02 | XML-003(a) | `<Declaration>` 沒包 CDATA(內容只有合法字元) | 無 | FunctionBlock | 無 | 成功 | 否 | **false**(warning):XAE 照常讀成程式碼 |
| C03 | XML-003(a) | CDATA 內含未切開的 `]]>`(`s := 'a]]>b';`)→ 提早結束,殘留文字含 `]]>`(不 well-formed) | 無 | 在,**itemType 0** | 無 | 成功,無 | 否 | **true**:同 C01,靜默 |
| C04 | XML-001 | `<ST>` 沒 CDATA 且含未跳脫 `<` `&` | 無 | 在,**itemType 0** | 無 | 成功,無 | 否 | **true**:靜默 |
| C05 | XML-003(a) | `<ST>` 沒 CDATA、`&lt;` 正確跳脫 | 無 | FunctionBlock | 無 | 成功 | 否 | **false**(warning) |
| C06 | XML-004 | 根元素改名 `TcPlcObjectX` | 無 | 在,**itemType 0** | `Parts of the XML data do not conform to the schema:` | 成功;errorItems 同左 | 否 | **true** |
| C07 | XML-004 / NAME | 物件元素缺 `Name` 屬性 | 無 | **FB_C07 消失,出現 `Untitled`**(FunctionBlock) | `C0243 The name used in the signature is not identical to the object name` | 成功(C0243 不在 Build 的 errorItems) | 否 | **true** |
| C08 | XML-004 | 缺 `SpecialFunc="None"` | 無 | FunctionBlock | 無 | 成功 | 否 | **false**:`SpecialFunc` 不是必要屬性 |
| C09 | XML-004 | 刪掉 `<Declaration>` 元素 | 無 | 在,**itemType 0** | `Tag 'Declaration' is missing in '...\FB_C09.TcPOU' at line 7.`、`Tag 'Implementation' is missing in '...\FB_C09.TcPOU' at line 8.` | 成功;errorItems 同左 | 否 | **true** |
| C10 | XML-004 | FB 刪掉 `<Implementation>` 元素 | 無 | 在,**itemType 0** | `Tag 'Implementation' is missing in '...\FB_C10.TcPOU' at line 12.` | 成功;errorItems 同左 | 否 | **true** |

另:XAE **自己存**含 `]]>` 的程式碼時會切成兩段 CDATA(`'a]]]]><![CDATA[>b'`,見 `xae-generated-xml.md`),所以 XML-003(b)「多段 CDATA」→ **false**(合法格式,引擎要把多段串接)。

### 1.2 名稱 / 種類(第 2 批)

| 案例 | 規則 | 植入 | 對話框 | 樹 | Check | Build | 改寫 | 建議 blockable |
|---|---|---|---|---|---|---|---|---|
| C11 | NAME-001 | `Name="FB_C11X"`,宣告與檔名仍是 `FB_C11` | 無 | **顯示 `FB_C11X`**(XAE 以 `Name` 屬性命名) | `C0243 The name used in the signature is not identical to the object name` | 成功 | 否 | **true** |
| C16 | NAME-001 | 宣告改 `FUNCTION_BLOCK FB_C16X`,`Name` 與檔名仍是 `FB_C16` | 無 | 顯示 `FB_C16` | `C0243 …`(同上) | 成功 | 否 | **true** |
| C12 | NAME-002 | 檔名改 `FB_C12_renamed.TcPOU`(Compile 同步改),`Name` / 宣告仍是 `FB_C12` | 無 | 顯示 `FB_C12` | 無 | 成功 | 否 | **false**(維持 warning):XAE 以 XML `Name` 為準,檔名不影響 |
| C13 | KIND-001 | `.TcPOU` 改名成 `FB_C13.TcDUT`(內容仍是 `<POU>`) | 無 | `FB_C13` FunctionBlock | 無 | 成功 | 否 | **false**(warning):物件種類由 XML 元素決定,副檔名不影響 |
| C14 | KIND-001 | `FB_C14.TcPOU` 的內容換成 `<DUT>`(ENUM) | 無 | `FB_C14`,itemType 605(ENUM DUT) | `C0006 'END_TYPE' expected instead of ''` | 成功 | 否 | **true**:物件變成另一種東西且有編譯錯 |
| C15 | KIND-001 | `<POU>` 內宣告 `FUNCTION_BLOCK` 改成 `PROGRAM` | 無 | **Program(602)** | 無 | 成功 | 否 | **false**:POU 的種類由宣告關鍵字決定,這是合法的改型(但語意改變,另由 diff 審查) |

KIND-001 的定案:「XML 元素(POU / DUT / GVL / Itf)≠ 宣告關鍵字所屬家族」→ blockable true;「副檔名 ≠ XML 元素」→ false(warning);同一家族內的關鍵字(PROGRAM / FUNCTION_BLOCK / FUNCTION)不檢查。

### 1.3 GUID(第 3 批)

| 案例 | 規則 | 植入 | 對話框 | 樹 | Check | Build | 改寫 | 建議 blockable |
|---|---|---|---|---|---|---|---|---|
| C16 | GUID-001 | POU 缺 `Id` | 無 | FunctionBlock | warning:`The "Id" attribute is missing in <POU> element.` | 成功,同 warning | 否 | **false**(warning):XAE 載入並警告 |
| FB_LintTest.A_Act | GUID-001 | Action 缺 `Id` | 無 | (FB_LintTest 因下一列變 itemType 0) | warning:`The "Id" attribute is missing in <Action> element.` | 同左 | 否 | **false**(warning) |
| C17 | GUID-002 | `Id="{xyz-123}"` | 無 | 在,**itemType 0**;`WritePouCode` 回 `INVALID_PARAMS`(ItemType 0,沒有 implementation) | `Parts of the XML data do not conform to the schema: The "Id" attribute in <POU> element has got a wrong format.` | 成功;errorItems 同左 | 否 | **true** |
| C18 | GUID-004 | 全零 GUID | 無 | FunctionBlock | 無 | 成功 | **是**:載入時 XAE 把 Id 換成新 GUID 並寫回磁碟 | **false**(info:「XAE 會自動重產並改寫檔案」) |
| C19 / C20 | GUID-003(跨檔) | C19 的 Id 改成與 C20 相同 | 無 | 兩個都 FunctionBlock | 無 | 成功 | **是**:XAE 把 **C20(原本的那個)** 的 Id 換成新 GUID 寫回磁碟,C19 保留重複前的值;之後 `WritePouCode` C19 存檔,Id 不再變 | **false**(warning:XAE 自動修,但改的是哪一個不可預期,會造成 git diff) |
| FB_LintTest M_Do = P_Ro | GUID-003(同 POU 子物件) | Method 的 Id 改成與同 FB 的 Property 相同 | 無 | FB_LintTest **itemType 0**,子節點全部消失 | `Object 'FB_LintTest.M_Do' has same GUID '…' as object 'FB_LintTest.P_Ro'. The GUID per object has to be unique !` | 成功;errorItems 同左 | 否 | **true** |

同批另有 `LineIDs.dbg` 被 XAE 改寫(每次載入 / 存檔都會改,不是植入造成)。

### 1.4 子物件結構(第 4 批:4 案同批 → VS2022 當機)

- 植入:FB_LintTest 的 `P_Ro` 刪掉 `<Get>`(Property 沒有 Get 也沒有 Set);`I_LintItf` 的 Method `M_Do` 刪掉 `<Declaration>`;FB_C01 加兩個同名 Method `M_X`;FB_C02 加一個沒有 `<Declaration>` 的 Method `M_Y`。
- `ResetSolution`:XAE 跳 solution reload 提示(tcauto 按 Ignore)→ 關閉、重開方案 → **devenv 當機**,`IDE_NOT_FOUND`(`Solution reopened but ConnectIde failed`)。
- Windows Application log 03:22:33:`Faulting application name: devenv.exe, version: 17.14.36811.4 … Faulting module name: KERNELBASE.dll, version: 10.0.26100.9974 … Exception code: 0xc00000fd … Fault offset: 0x000000000000fea6`;WER 1001 APPCRASH。0xc00000fd = stack overflow。
- 當機前 XAE 已改寫磁碟:`I_LintItf.TcIO` 的 `M_Do` 多了一個空的 `<Declaration><![CDATA[]]></Declaration>`;`FB_LintTest.TcPOU` 的 SFC Action 內 `<l2 n="Attributes" />` 被展開成 3 個 SFCAttribute。
- 逐案拆開的結果:見 2.1(第 41~44 批)。**當機元凶是「同一 FB 兩個同名 Method」**(第 43 批單獨重現,同一簽名)。

## 2. 後續批次(4026)

當機時的處理:記錄 Application log → 還原基準 → `ConnectIde` 重開(本 session 啟動的 IDE)。共當機 2 次(第 43、8 批,外加第 4 批 = 第 43 批同因)。

### 2.1 子物件結構(第 41~44 批,逐案)

| 案例 | 規則 | 植入 | 對話框 | 樹 | Check | Build | 改寫 | 建議 blockable |
|---|---|---|---|---|---|---|---|---|
| 41 | SUB-001 | FB 的 Property `P_Ro` 刪掉 `<Get>`(沒有 Get 也沒有 Set) | 無 | `P_Ro` 在,沒有子項 | warning `C0373 The property defines neither a get nor a set accessor.` | 成功(Build 的 Error List 沒有這條 warning) | 否 | **false**(warning):編譯器只警告 |
| 42 | SUB-001 | INTERFACE 的 Method `M_Do` 刪掉 `<Declaration>` | 無 | `M_Do` 在(610) | `C0087 There is no implementation for method '' defined in interface 'I_LINTITF'`(在實作它的 FB_LintTest)、`Tag 'Declaration' is missing in '…\I_LintItf.TcIO' at line 7.`、`C0383 The POU declaration is incomplete without a name` | 成功;errorItems 只有 Tag missing 那條 | **是**:XAE 寫回一個空的 `<Declaration><![CDATA[]]></Declaration>` | **true** |
| 43 | SUB-002 | 同一 FB 兩個同名 Method `M_X`(`BOOL` / `INT`,不同 Id) | 無 | — | — | — | 否 | **true**:`ResetSolution` 重開方案時 **devenv 當機**,Application Error:`devenv.exe 17.14.36811.4 … KERNELBASE.dll 10.0.26100.9974 … 0xc00000fd … offset 0xfea6`(第 4 批與第 43 批兩次相同) |
| 44 | SUB-001 | FB 的 Method `M_Y` 沒有 `<Declaration>` | 無 | **`M_Y` 不在樹上**(FB_C02 沒有子項) | `Check` 回 passed,但 Error List 有 `Tag 'Declaration' is missing in '…\FB_C02.TcPOU' at line 18.`、`Tag 'Implementation' is missing … at line 20.`(後者在磁碟上其實存在) | 成功;errorItems 同左兩條 | 否 | **true**:成員靜默消失 |

### 2.2 `.plcproj` Compile / Folder(第 5 批,同批多案,依樹分辨)

| 案例 | 規則 | 植入 | 樹 | Check / Build | 改寫 | 建議 blockable |
|---|---|---|---|---|---|---|
| 5a | COMPILE-001 | `<Compile Include="FB_Ghost.TcPOU">`,磁碟沒有這個檔 | **`FB_Ghost` 出現在樹上,itemType 0** | 0 error / 成功 | 否 | **true**:樹上出現無法使用的幽靈物件,沒有任何錯誤 |
| 5b | COMPILE-002 | `FB_C01.TcPOU` 列兩次 | `FB_C01` 只出現一次 | 0 error / 成功 | 否(XAE 下次存 `.plcproj` 是否去重未觀察) | **false**(warning):XAE 容忍 |
| 5c | COMPILE-003 | `FB_Orphan.TcPOU` 在目錄但沒列入 | **不在樹上** | 0 error / 成功 | 否 | false(照原定義;物件根本不存在於專案) |
| 5d | COMPILE-004 | `FB_C02` 的 `<SubType>Designer</SubType>` | FunctionBlock | 0 error / 成功 | 否 | **false**(warning) |
| 5e | COMPILE-004 | `FB_C03` 寫成自閉合 `<Compile Include="FB_C03.TcPOU" />`(沒有 SubType) | FunctionBlock | 0 error / 成功 | 否 | **false**(warning) |
| 5f | COMPILE-006 | Include 改小寫 `fb_c04.tcpou`(磁碟 `FB_C04.TcPOU`) | `FB_C04`(名稱來自 XML) | 0 error / 成功 | 否 | **false**(warning;Windows 不分大小寫) |
| 5g | COMPILE-005 | `<Folder Include="NoSuchDir" />`,磁碟沒有目錄 | 資料夾 `NoSuchDir` 在(空) | 0 error / 成功 | **是**:XAE 在磁碟建立空目錄 `NoSuchDir` | false(info) |
| 5h | COMPILE-005 | `FB_C05` 搬到 `Sub Dir\`,Include 改 `Sub Dir\FB_C05.TcPOU`,沒有 Folder 宣告 | 資料夾 `Sub Dir` 在,FB_C05 在其下 | 0 error / 成功 | **是**:XAE 在 `.plcproj` 補上 `<Folder Include="Sub Dir" />` | false(info) |
| 5i | COMPILE-006 | `FB_C06` 搬到 `Pct Dir\`,Include 寫 MSBuild 跳脫 `Pct%20Dir\FB_C06.TcPOU` | 資料夾 `Pct Dir` 在,FB_C06 在其下 | 0 error / 成功 | 否 | false:XAE 會 unescape `%20` |

檔名含空白 / `'` / `%` 的 `.plcproj` 寫法:物件名必須是 IEC 識別字,XAE 建的物件檔名不會有這些字元;**資料夾名**可以有空白,語料 axis 的 `Basic Function\…` 是直接寫空白、不跳脫。tcauto 沒有建資料夾的 tool,所以「XAE 自己建含 `'` / `%` 的資料夾時怎麼寫」本次沒測到;只確認 XAE 讀得懂 `%20`。

### 2.3 編碼 / 行尾(第 6 批,各案在不同檔,依樹分辨)

| 案例 | 規則 | 植入 | 樹 | Check / Build | 改寫 | 建議 blockable |
|---|---|---|---|---|---|---|
| C07 | XML-002 | UTF-8 無 BOM | FunctionBlock | 0 error | 否 | false(ENC-001 info) |
| C08 | XML-002 | UTF-16 LE + BOM,宣告 `encoding="utf-16"`(一致) | FunctionBlock | 0 error | 否 | false(info) |
| C09 | XML-002 | UTF-16 LE + BOM,宣告仍是 `encoding="utf-8"`(不一致) | **itemType 0** | 0 error | 否 | **true**:靜默壞掉 |
| C10 | ENC-001 | 全檔 LF | FunctionBlock | 0 error | 否 | false(info) |
| C11 | ENC-001 | CRLF / LF 混用 | FunctionBlock | 0 error | 否 | false(info) |
| C12 | XML-002 | 宣告 UTF-8,註解內有非法 UTF-8 位元組 `0xA4 0xA4` | **itemType 0** | 0 error | 否 | **true**:靜默壞掉 |
| C13 | XML-002 | 沒有 XML 宣告、沒有 BOM(純 ASCII) | FunctionBlock | 0 error | 否 | false |
| C14 | XML-002 | 沒有 BOM、合法 UTF-8 中文註解 | FunctionBlock | 0 error | 否 | false(info) |

### 2.4 LineIds(第 7 批)

- 植入:`FB_C15` 加兩個不一致的 `<LineIds>`(行數不符,且有一塊指向不存在的 `FB_C15.M_None`)。
- 結果:載入、Check、Build 全部 0 error,磁碟沒改。之後 `WritePouCode` 改 FB_C15 的實作 → XAE 存檔時**把兩塊 LineIds 整段刪掉**(4026 本來就不寫 LineIds)。
- PROJECT-LINEIDS-001 → **false**(info);4026 下次存檔會自己清掉。4024 的行為見第 3 節。

### 2.5 `.tsproj` / `.plcproj` / `.TcTTO` 參照(第 8~10 批)

| 案例 | 規則 | 植入 | 結果 | 建議 blockable |
|---|---|---|---|---|
| 8 | TSPROJ-001 | `.tsproj` 的 `PrjFilePath` 指向不存在的 `AxisInterfaceX.plcproj` | `ResetSolution` 成功(tcauto `projectCheck` 回「找不到檔案」);接著 `GetProjectTree` 時 **devenv 當機**:`TwinCAT System Manager.x64.dll 3.1.0.4841(Build_4026.22)… 0xc0000005 … offset 0x15190ed` | **true** |
| 9 | TSPROJ-002 | `.plcproj` 的 `ProjectGuid` 換成新 GUID(`.tsproj` / `.sln` 仍是舊值) | 載入、Check、Build 0 error;XAE **把 `.plcproj` 的 ProjectGuid 寫回原值**(以 `.tsproj` 為準) | **false**(warning:XAE 自動修並改寫檔案) |
| 10 | TSPROJ-003 | `.TcTTO` 的 `PouCall` 指向不存在的 `MainX` | 樹:PlcTask 底下 `MainX`(TaskPou);Check 與 Build:`C0046 Identifier 'MainX' not defined`、`C0035 Program name, function or function block instance expected instead of 'MainX'`,**BUILD_FAILED** | **false**:編譯器會擋(compilerCatches yes);寫入前擋仍有價值,但不必 blocking |

### 2.6 Library / Placeholder 參照(第 11~12 批)

| 案例 | 規則 | 植入 | 結果 | 建議 blockable |
|---|---|---|---|---|
| 11 | LIB-001 | `PlaceholderReference "BATW_Base"` 刪掉 `<Namespace>` | `ResetSolution` 時 solution reload 提示關不掉,接著 XAE 跳出**需選擇的對話框**:標題 `判斷提示已失敗: 中止=結束,重試=偵錯,忽略=繼續`(按鈕 中止 / 重試 / 略過),內文是堆疊 `_3S.CoDeSys.ObjectManager.UndoManager.EndCompoundAction()` ← `SVNode.Remove` ← `MutualProjectStructure.RemoveNode` ← `MutualProjectFileHandling.ReloadFile` ← `PlcFileNode.ReloadI`。依規則不代按,`DisconnectIde Quit Kill` 關掉本次啟動的 IDE | **true** |
| 12 | LIB-001 | `PlaceholderReference "CBML"` 只剩 `<Namespace>`(刪掉 `DefaultResolution`) | 載入、Check、Build 都 0 error,無對話框 | **false**(warning) |

## 3. 4024(32-bit XAE Shell)

只完成第 101 批(XML),時間內沒有跑 GUID / Compile / LineIds 三批。

- 基準:`FB_LintBase`(XAE 建)複製成 FB_C01~C08 加入 `.plcproj`,`ResetSolution` + `BuildProject` 0 error。
- 第 101 批植入:FB_C01 刪掉 `</Declaration>`(不 well-formed);FB_C02 `<Declaration>` 沒包 CDATA;FB_C03 CDATA 內含未切開的 `]]>`(不 well-formed)。
- `ResetSolution` 成功;接著 `GetProjectTree` 讀樹時 **XAE 當機**(`IDE_CRASHED`,RPC 0x800706BE)。Application log:`TcXaeShell 15.0.0.0`,faulting module `TwinCAT System Manager.dll 3.1.0.4381`,exception 0xc0000005,offset 0x00bc59d8。
- 還原 → 重開 → 重新植入後,`ResetSolution` 兩次都回 `SOLUTION_CLOSE_FAILED: DTE.Solution answered $null before Solution.Close`(之前先有一次 `MODAL_SCAN_INCOMPLETE`,`GetIdeModalDialog` 讀到無對話框),依規則停止,IDE 以 `DisconnectIde Quit Kill` 關閉(本次啟動的)。
- 對照 4026(VS2022):同樣三個案例只是物件變成 itemType 0、沒有任何訊息;**在 4024 的 32-bit XAE Shell 上則讓 IDE 當機**。XML-001 / XML-003 的 blockable true 在 4024 更有依據。
- 第 101 批三個案例同批,無法分辨是哪一個造成當機。

## 4. 實測過程中發現的工具問題

- `BuildProject` 在 Error List 有 XAE 載入錯誤(schema 不符、Tag missing、GUID 重複)時仍回 `success=true`、`codeVerified=true`、`completeBuild=true`,但 `data.errors > 0`、`errorItems` 非空;build pane 是 `0 errors`。這些物件沒被引用,Build 本身確實成功,但回傳值自相矛盾。→ #275。
