# TwinCAT 專案檔 XML 結構(語料觀察)

> 目的：從真實專案檔歸納 XAE 實際寫出的 XML 結構，作為 semantic linter 規則的 ground truth。
> 方法：2026-11-13 用 PowerShell 5.1 `System.Xml` + regex 腳本唯讀掃描語料(腳本在 session scratchpad,未入 repo)。
> 本文件只寫**語料裡看到的事實**;沒看到的標「語料沒有」。「推得」= 由語料數值推論、未查 InfoSys。

## 0. 語料範圍

| 代號 | 路徑 | 版本(tsproj `TcVersion`) | 內容 |
|---|---|---|---|
| bfh | `C:\Temp\lint-corpus\bfh` | 3.1.4024.71 | 1 sln、1 tsproj、1 plcproj(PLC1)、45 TcPOU、39 TcDUT、6 TcGVL、1 TcTTO、9 TcVIS、1 TcVMO、1 TcGTLO、1 TcIPO、1 tmc |
| axis | `C:\Temp\lint-corpus\axis` | 3.1.4026.22 | 1 sln、3 tsproj(主檔 + `-Lance-G16`、`-LanceP-NB1` 兩份機器別副本)、1 plcproj(AxisInterface)、20 TcPOU、49 TcDUT、3 TcGVL、1 TcTTO、1 TcVIS、1 TcVMO、2 tmc |

**備份(不納入主要統計，另外標註)**:
- `axis\_bak_files_182205`、`axis\_bak_files_213736`(plcproj、Main.TcPOU、sln)、`axis\_bak_sln_181346`(sln)、`bfh\_bak_files_182911`(sln、MAIN.TcPOU、plcproj)。
  與主檔逐字比較(去掉 CR 後):TcPOU / sln 完全相同；plcproj **唯一差別是主檔多了結尾 CRLF**(備份檔最後一行 `</Project>` 後沒有換行)。
- `axis\.tcauto-backup\2026103x-*`:4 個 `TIRT_PlcTask.PlcTask.TcTTO`(內容同主檔 PlcTask.TcTTO)與 7 個 `.xti`(task 匯出，tab 縮排、無 BOM、`<?xml version="1.0"?>`)。

**語料缺口(整類沒有)**:`.TcIO`、`<Property>`/`<Get>`/`<Set>`、`<Transition>`、`<Itf>`(INTERFACE)、SFC/FBD/LD/IL 實作、`.TcTLO`、`.TcRMO`、`.TcNCI` 等。只出現 1 個 CFC 實作(axis FB_AxisControl.A90_Cyclic)。sln 參照的 `A10_Scope\A10_Scope.tcmproj` 不在語料內。

**重要背景**:axis 有一批檔案明顯**不是 XAE 寫的**(手寫/AI 寫的 GUID 如 `{a1b2c3d4-e5f6-7890-abcd-ef0123456789}`、無 BOM、LF 行尾，見 §1、§4)。下文凡涉及「XAE 怎麼寫」,以 bfh 全部 + axis 中 CRLF/BOM 正常的檔案為準，例外逐一列出。

---

## 1. 檔案層級(編碼、BOM、行尾、縮排、結尾換行)

### 1.1 主檔統計

| 版本 | 副檔名 | 檔數 | XML 宣告 | UTF-8 BOM | 行尾 | 結尾換行 | 縮排 |
|---|---|---|---|---|---|---|---|
| bfh | .TcPOU | 45 | `version="1.0" encoding="utf-8"` | 45/45 | CRLF 45/45 | 無 45/45 | 2 空白/層 |
| bfh | .TcDUT | 39 | 同上 | 39/39 | CRLF | 無 | 2 空白 |
| bfh | .TcGVL | 6 | 同上 | 6/6 | CRLF | 無 | 2 空白 |
| bfh | .TcTTO / .TcVIS(9) / .TcVMO / .TcGTLO / .TcIPO / .tmc | 各全數 | 同上 | 全有 | CRLF | 無 | 2 空白(tmc 無縮排行) |
| bfh | .plcproj | 1 | **無宣告** | **無** | CRLF | CRLF(備份檔:無) | 2 空白 |
| bfh | .tsproj | 1 | `<?xml version="1.0"?>`(無 encoding) | 無 | CRLF | CRLF | **tab** |
| bfh | .sln | 1 | — | 有 | CRLF | CRLF | tab |
| axis | .TcPOU | 20 | `version="1.0" encoding="utf-8"` 20/20 | 19/20 | CRLF 15、**LF 1、混用 4** | 無 16、LF 4 | 2 空白 |
| axis | .TcDUT | 49 | 同上 49/49 | 46/49 | CRLF 44、**LF 3、混用 2** | 無 45、LF 4 | 2 空白 |
| axis | .TcGVL | 3 | 同上 | 3/3 | CRLF 2、**LF 1** | 無 | 2 空白 |
| axis | .TcTTO / .TcVIS / .TcVMO / .tmc(2) | 各全數 | 同上 | 全有 | CRLF | 無 | 2 空白 |
| axis | .plcproj | 1 | `version="1.0" encoding="utf-8"` | **有** | CRLF | CRLF(備份檔:無) | 2 空白 |
| axis | .tsproj | 3 | `<?xml version="1.0"?>` | 無 | CRLF | CRLF | tab |
| axis | .sln | 1 | — | 有 | CRLF | CRLF | tab |

- 縮排：Tc* 物件檔與 plcproj 的 XML 結構行全是 2 空白/層，沒有任何 tab 縮排；tsproj 與 .xti 全是 tab。觀察到的唯一奇數縮排(FB_AxisControl 第 3827 行 11 空白)在 CDATA 的 ST 程式碼內。
- sln 都以 BOM + 空行開頭(`\uFEFF\r\nMicrosoft Visual Studio Solution File, Format Version 12.00`)。

### 1.2 例外清單(全在 axis)

| 檔案 | BOM | 行尾 | 結尾 |
|---|---|---|---|
| `DUT\Axis_Status\E_AxisFaultCategory.TcDUT` | 無 | LF | LF |
| `DUT\Axis_Status\E_AxisFaultSrc.TcDUT` | 無 | LF | LF |
| `DUT\Axis_Control\E_SyncProfileEngageMode.TcDUT` | 無 | LF | 無 |
| `CorrugatedPrint\FB_ExtendCrossCutter.TcPOU` | 無 | LF | 無 |
| `GVL\GVL_Motion.TcGVL` | 有 | LF | 無 |
| `DUT\Axis_Control\ST_AXIS_ADMINISTRATION.TcDUT` | 有 | 混用(CRLF 17 / LF 2) | LF |
| `DUT\Axis_Status\ST_AXIS_DIAGNOSIS.TcDUT` | 有 | 混用(25 / 5) | LF |
| `TestCam.TcPOU` | 有 | 混用(1009 / 11) | LF |
| `LIB\AxisControl\FB_AxisControl.TcPOU` | 有 | 混用(31387 / 68) | LF |
| `Feeder\FB_CorrugatedLiftingFixedAccDistance.TcPOU` | 有 | 混用(234 / 35) | LF |
| `Feeder\FB_CorrugatedWheelThreadSlopeCalculate.TcPOU` | 有 | 混用(272 / 133) | LF |

- 混用檔的 LF 行幾乎都在 CDATA 內；CDATA 外的 LF 只有 1~2 行，即**檔尾**(`</TcPlcObject>\n`)與附近。也就是說：XAE 存的結構行是 CRLF、檔尾無換行；之後有工具在 CDATA 內插入 LF 行、並在檔尾補 LF。
- 「無 BOM + 全 LF」的 3 個 DUT 同時有假 GUID(§4),是整檔由非 XAE 工具產生。

### 1.3 結尾換行

- XAE 寫的 Tc* 物件檔(TcPOU/DUT/GVL/TTO/VIS/VMO/GTLO/IPO)與 tmc:**一律沒有結尾換行**(bfh 103/103;axis 正常檔全數)。
- plcproj:備份(XAE 原樣)沒有結尾換行；主檔有 CRLF → 主檔被非 XAE 工具重寫過(內容其他部分不變)。
- tsproj、sln:有結尾 CRLF。

---

## 2. 根元素 `TcPlcObject`

- 所有 Tc* 物件檔(178 個主檔)根元素都是 `TcPlcObject`,`Version="1.1.0.1"` 178/178。
- 屬性順序固定 `Version` 在前、`ProductVersion` 在後。
- `ProductVersion` 分布：

| 版本 | 值 | 檔數 |
|---|---|---|
| bfh | `3.1.4024.16` | POU 45、DUT 39、GVL 5、VIS 9、VMO/GTLO/IPO 各 1 |
| bfh | `3.1.4026.0` | 1(`30_RollToRoll\GVL_Axes.TcGVL`) |
| bfh | **缺 ProductVersion** | 1(`PlcTask.TcTTO`:`<TcPlcObject Version="1.1.0.1">`) |
| axis | `3.1.4026.18` | POU 8(+備份 2)、DUT 5、GVL 2、TTO 1、VIS 1、VMO 1 |
| axis | `3.1.4026.17` | POU 11、DUT 1 |
| axis | `3.1.4024.13` | POU 1(FB_CorrugatedLiftingCalculate)、DUT 43、GVL 1 |

- 同一專案內 ProductVersion 不一致是常態(只有被修改過的物件會在存檔時更新版本戳記)。plcproj 兩者都有 `<WriteProductVersion>true</WriteProductVersion>`。

---

## 3. 物件元素樹

### 3.1 共通

- `TcPlcObject` 底下**恰好一個**物件元素(178/178)。
- 物件元素 `Name` 屬性 == 檔名(不含副檔名),區分大小寫比對 178/178 相符。
- 物件元素屬性順序：`Name` → `Id` →(POU)`SpecialFunc` /(GVL)`ParameterList`。
- POU/DUT 的 Declaration 第一個關鍵字後的名稱 == `Name`:153/153(TYPE 88、FUNCTION_BLOCK 52、FUNCTION 8、PROGRAM 5)。Method 宣告 `METHOD <名稱>` == `Name`:80/80。

### 3.2 `.TcPOU` → `<POU>`

屬性:`Name`、`Id`、`SpecialFunc`(65/65 都有，值一律 `"None"`)。

子元素出現順序(語料中所有 67 個 POU 都符合):

```
POU
├─ Declaration          必要(65/65)
├─ Implementation       必要(65/65)
│   └─ ST               (65/65 都是 ST)
├─ Folder*              選擇性(axis 11 檔;bfh 無)
├─ Action*              選擇性(axis 3 檔、bfh 1 檔)
├─ Method*              選擇性(axis 13 檔、bfh 1 檔)
└─ LineIds*             選擇性(bfh 45/45;axis 1/20)
```

- 順序固定為 `Declaration → Implementation → Folder* → Action* → Method* → LineIds*`;沒看到 Action 夾在 Method 之間或 LineIds 出現在成員之前。
- 同類成員之間按 `Name` **字母序(不分大小寫)** 排列：觀察 20 組(Method 15 組、Action 3 組、Folder 2 組，最多 25 個 Action、20 個 Method)全部符合。
- `<Property>`/`<Get>`/`<Set>`/`<Transition>`:**語料沒有**。

**Method**(80 個):屬性 `Name`、`Id`、選擇性 `FolderPath`(axis 11 檔);子元素固定 `Declaration → Implementation/ST`(80/80),Method 內部**沒有** LineIds。

**Action**(32 個):屬性 `Name`、`Id`、選擇性 `FolderPath`;子元素只有 `Implementation`(**沒有 Declaration**,32/32)。`Implementation` 下 ST 31 個、CFC 1 個。

**Folder**(16 個，僅 axis):`<Folder Name=".." Id="{..}" />`,可巢狀(FB_AdvancedHoming:`Private` 底下 4 個子 Folder)。成員用 `FolderPath="Private\01_Step Function\"` 掛到 Folder,**以 `\` 結尾**、多層用 `\` 串接。FolderPath 值:`Private\`(15)、`States\`(16)、`ActionProvider\`(5)、`Private\00_Status\`(5)、`Private\01_Step Function\`(7)、`Action Provider\`(3)、`Private\02_Finalizing Function\`(4)、`Public\`(2)、`Private\03_Setting Function\`(1)。

**CFC 實作**(1 個):`<Implementation><CFC PageOriented="true"><XmlArchive><Data>…</Data><TypeList>…</TypeList></XmlArchive></CFC></Implementation>`,不是 CDATA,是 XmlArchive 序列化(該 Action 共約 30,000 行)。

**一個 Action 下多個 `<ST>`**:**語料沒有**。bfh FB_MachineCtrl 有 4 個 Action(A00_BaseUnit、A10_ManualAction、A20_AutoAction、A30_HMI_Action),每個都是 `Action/Implementation/ST` 恰好一個 ST;其中 A10、A20 是空實作。全語料 32 個 Action、80 個 Method、65 個 POU 的 `Implementation` 都恰好一個子元素。FB_MachineCtrl 實際樣子:

```xml
    <Action Name="A10_ManualAction" Id="{fa397dde-0191-4186-89f0-dd757494c3d2}">
      <Implementation>
        <ST><![CDATA[]]></ST>
      </Implementation>
    </Action>
    ...
    <LineIds Name="FB_MachineCtrl.A00_BaseUnit">
      <LineId Id="2" Count="11" />
      <LineId Id="1" Count="0" />
    </LineIds>
```

### 3.3 `<LineIds>`

結構：`<LineIds Name="POU名稱">` 或 `<LineIds Name="POU名稱.成員名稱">`,底下一個以上 `<LineId Id="整數" Count="整數" />`(自閉合，`Id` 在前、`Count` 在後，`/>` 前有空白)。

- **位置**:全部集中在 `<POU>` 的最後，不放在 Method/Action 內。
- **對應**:每個有 ST 實作的 POU 本體 / Method / Action 都恰好有一個 LineIds(58/58 覆蓋),順序 = `[POU 本體, 成員依文件順序]`(46/46 檔相符)。
- **行數關係**:Σ(Count+1) == 該 ST CDATA 的行數(以換行切分)。58 個 LineIds 區塊中 57 個相符。例外:`bfh FB_Winder.TcPOU [FB_Winder]` 程式 148 行、Σ=147(差 1;該檔有中文註解行，疑似在 XAE 外被改過，未確認)。
- 同一區塊內 `Id..Id+Count` 範圍不重疊(0 例重疊);Id 不連續、不排序(如 `61,60,66,23,22,…`)。
- 最後一個 LineId 多為 `Id="2" Count="0"`(46 個區塊),其次 `1/0`、`5/0` 各 3。空實作是單一 `<LineId Id="1" Count="0" />` 或 `Id="5"`。
- 抽樣比對(程式行數 / LineId 項數 / Σ(Count+1)):

| POU [區塊] | 行數 | 項數 | Σ | LineId 內容 |
|---|---|---|---|---|
| bfh FB_MachineCtrl [本體] | 10 | 10 | 10 | 61+0 60+0 66+0 23+0 22+0 24+0 38+0 27+0 39+0 25+0 |
| bfh FB_MachineCtrl [.A00_BaseUnit] | 13 | 2 | 13 | 2+11 1+0 |
| bfh FB_MachineCtrl [.A30_HMI_Action] | 11 | 7 | 11 | 1+2 5+0 4+0 6+0 11+2 16+0 7+0 |
| bfh FB_PID [本體] | 47 | 2 | 47 | 3+45 2+0 |
| bfh MAIN [本體] | 29 | 2 | 29 | 107+27 2+0 |
| axis FB_CorrugatedLiftingCalculate [本體] | 14 | 2 | 14 | 3+12 2+0 |
| bfh FB_Winder [本體](例外) | 148 | 2 | 147 | 3+145 2+0 |

- **4024 vs 4026**:有 LineIds 的 POU 全部是 `ProductVersion 3.1.4024.x`(bfh 45 + axis 1);axis 19 個 `3.1.4026.17/18` 的 POU **都沒有 LineIds**,但 axis plcproj 的 ProjectExtensions 內有 `WriteLineIDs = True`(bfh plcproj 沒有這個選項)。原因未查證，只記錄觀察。

### 3.4 `.TcDUT` → `<DUT>`

- 88/88:`<DUT Name=".." Id="{..}">` → 唯一子元素 `<Declaration><![CDATA[TYPE … END_TYPE]]></Declaration>`。
- 沒有其他屬性、沒有 Implementation、沒有 LineIds。
- 宣告種類從 CDATA 看:STRUCT、ENUM(`) UDINT;` 等)、UNION(`U_*`),結構上無差異。

### 3.5 `.TcGVL` → `<GVL>`

- 9/9:`<GVL Name=".." Id="{..}">` → 唯一子元素 `<Declaration>`。
- 選擇性屬性 `ParameterList="True"`:1 檔(axis `AxisInterface_Parameters.TcGVL`,放在 Id 之後)。

### 3.6 `.TcTTO` → `<Task>`

```xml
<TcPlcObject Version="1.1.0.1" ProductVersion="3.1.4026.18">
  <Task Name="PlcTask" Id="{0825aa11-d4e5-4208-a3b5-27624c08224e}">
    <!--CycleTime in micro seconds.-->
    <CycleTime>2000</CycleTime>
    <Priority>20</Priority>
    <PouCall>
      <Name>Main</Name>
    </PouCall>
    <TaskFBGuid>{ed55fe2b-…}</TaskFBGuid>
    <Fb_init>{7c8e411b-…}</Fb_init>
    <Fb_exit>{4b5b2267-…}</Fb_exit>
    <CycleUpdate>{bb98e51b-…}</CycleUpdate>
    <PostCycleUpdate>{34863c1e-…}</PostCycleUpdate>
  </Task>
</TcPlcObject>
```

- 子元素順序 2/2 相同:`CycleTime → Priority → PouCall → TaskFBGuid → Fb_init → Fb_exit → CycleUpdate → PostCycleUpdate`;bfh 多一個結尾的 `<ObjectProperties />`。
- 固定有 XML 註解 `<!--CycleTime in micro seconds.-->`(2/2)。
- `PouCall` 每檔 1 個，內含 `<Name>`(值 = 被呼叫的 PROGRAM 名稱:axis `Main`、bfh `MAIN`,與 POU 名稱大小寫一致)。多個 PouCall:語料沒有。
- 5 個 GUID 欄位值都是小寫 `{8-4-4-4-12}`。
- bfh 的 TTO 沒有 `ProductVersion`(見 §2)。

### 3.7 `.TcVIS` / `.TcVMO` / `.TcGTLO` / `.TcIPO`(只列根結構)

| 檔類 | 物件元素 | 子元素 | 檔數 |
|---|---|---|---|
| .TcVIS | `<Visu Name Id>` | `XmlArchive` → `ObjectProperties` | 9;1 個(bfh)只有 `XmlArchive` |
| .TcVMO | `<VisuManager Name Id>` | `XmlArchive` | 2 |
| .TcGTLO | `<GlobalTextList Name Id>` | `XmlArchive` | 1 |
| .TcIPO | `<ImagePool Name Id>` | `XmlArchive` | 1 |

`XmlArchive` = `Data`(內含 `<o xml:space="preserve" t="…">`)+ `TypeList`(`<Type n="…">`)。

### 3.8 `.TcIO`

語料沒有。

---

## 4. Id 屬性(GUID)

統計範圍：主檔中 POU/DUT/GVL/Method/Action/Folder/Task/Visu/VisuManager/GlobalTextList/ImagePool 的 `Id`,共 306 個(不含 LineId 的整數 Id、不含 XmlArchive 內部)。

- **格式**:306/306 符合 `^\{[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\}$`,**大括號 + 全小寫**(0 個大寫或混合)。
- **每個物件 / 子物件都有 Id**:POU、DUT、GVL、Method、Action、Folder、Task、Visu 等，缺 Id 0 例。
- **唯一性**:306 個 Id 在主檔範圍內(跨兩個專案)**沒有重複**。
- **GUID version nibble**(第 3 組第 1 碼):

| 值 | 數量 | 分布 |
|---|---|---|
| `4` | 222 | bfh 全部(Tc* 物件 Id 都是 v4);axis 部分 |
| `0` | 80 | **全在 axis**(例 `{d490b3f4-d737-036c-3d86-4891f5a623c5}`、`{7ced14a7-c89f-01c6-17ed-175601c309ae}`),variant 碼也不在 8/9/a/b |
| `2` | 2 | axis `M_ClearDiag`、`M_ReportError` |
| `7`、`9` | 各 1 | axis `E_SyncProfileEngageMode`、`A91_ErrorHandler` |

- **明顯手造 GUID**(axis,格式合法但不是隨機):
  - `E_SyncProfileEngageMode` `{a1b2c3d4-e5f6-7890-abcd-ef0123456789}`
  - `E_AxisFaultCategory` `{c3b2a1d4-1234-4567-8901-aaabbbcccddd}`
  - `E_AxisFaultSrc` `{a3f1e2b4-5678-4abc-9def-123456789abc}`
  - `FB_AxisControl.M_ClearDiag` `{c1a2b3d4-1111-2222-3333-ddddeeeeffff}`
  - `FB_AxisControl.M_ReportError` `{c1a2b3d4-1111-2222-3333-aaaabbbbcccc}`
  - `FB_AxisControl.A91_ErrorHandler` `{91111111-91a9-91e9-9191-91efabc91111}`
  其中前 3 個同時是 §1.2 的「無 BOM + LF」檔。
- version 0 的 80 個 Id 從哪來(XAE 某種操作、匯入、或其他工具)語料無法判斷。
- 專案層級 GUID(plcproj / tsproj / sln)見 §6、§7:plcproj 小寫，tsproj / sln 大寫。plcproj ProjectExtensions 內還有大寫 GUID 與 `{eeeeeeee-3909-4298-8022-501ac3238667}` 這種 XAE 自己的固定鍵。

---

## 5. CDATA

範圍：主檔 TcPOU / TcDUT / TcGVL。

| 項目 | 結果 |
|---|---|
| `<Declaration>` 包 CDATA | 242/242 |
| `<ST>` 包 CDATA | 176/176 |
| 自閉合 `<Declaration/>` / `<ST/>` | 0 |
| 一個元素內多段 CDATA(`]]><![CDATA[`) | 0 |
| CDATA 內 `]]>` 跳脫(`]]]]><![CDATA[>`) | 0 |
| 空實作 | 14 個，一律寫成 `<ST><![CDATA[]]></ST>` |
| 空 Declaration | 0 |

- CDATA 結尾:Declaration 有 120 個在 `]]>` 前換行、122 個不換行;ST 有 54 個換行、108 個不換行(14 個空)。兩種都存在，不能當規則。
- CDATA 一律緊接開始標籤：`<Declaration><![CDATA[`、`<ST><![CDATA[`(中間沒有空白或換行)。

---

## 6. `.plcproj`(MSBuild)

### 6.1 根與頂層

- 根 `<Project DefaultTargets="Build" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">`(2/2)。沒有 `ToolsVersion`。
- 頂層子元素順序 2/2 相同:`PropertyGroup → ItemGroup×6 → ProjectExtensions`。
- ItemGroup 依內容分組，各組只放一種項目：

| 順序 | axis | bfh |
|---|---|---|
| 1 | Compile(75) | Compile(103) |
| 2 | Folder(14) | Folder(19) |
| 3 | PlaceholderReference(24) | PlaceholderReference(14) |
| 4 | None(1) | None(1) |
| 5 | SubObject(1) | LibraryReference(1) |
| 6 | PlaceholderResolution(15) | Content(1) |

- `ProjectExtensions/PlcProjectOptions/XmlArchive`(`Data` + `TypeList`)存專案選項(如 axis 的 `WriteLineIDs`、`DisabledWarningIds 410,5410`)。

### 6.2 PropertyGroup 關鍵欄位

兩者共有，且順序相同:`FileVersion(1.0.0.0) → SchemaVersion(2.0) → ProjectGuid → SubObjectsSortedByName(True) → DownloadApplicationInfo(true) → WriteProductVersion(true) → GenerateTpy(false) → Name → ProgramVersion → Application → TypeSystem → Implicit_Task_Info → Implicit_KindOfTask → Implicit_Jitter_Distribution → LibraryReferences`。

| 欄位 | axis | bfh |
|---|---|---|
| ProjectGuid | `{289acf00-57ff-4892-a409-b7cb00b64554}` | `{2cc04917-125b-4c19-bac8-bf2c10a34957}` |
| Name | AxisInterface | PLC1 |
| ProgramVersion | 3.1.4026.24 | 3.1.4026.22 |

- GUID 值一律小寫 + 大括號。
- axis 另有程式庫相關欄位(Company、Released、Title、ProjectVersion `0.0.4.88`、PreserveCompiledLibComments、DeploymentEvents、DefaultNamespace、Author、Description、DocFormat、CombineIds、POUsForPropertyAccessIncluded、GlobalVersionStructureIncluded、CompilerDefines `VISU_USEPROPERTYINFO`)。這是專案類型(library)差異，不一定是版本差異。
- `SubObjectsSortedByName=True` 與 §3.2「成員按字母序」一致。

### 6.3 `<Compile Include>` 與 `<SubType>`

- `SubType` 值一律 `Code`:axis 75/75、bfh 103/103(所有副檔名：TcPOU/TcDUT/TcGVL/TcTTO/TcVIS/TcVMO/TcGTLO/TcIPO)。
- 子元素：`SubType` 一定是第一個；額外子元素 `LinkAlways`(true,只出現在 GVL:axis 2、bfh 3)、`DependentUpon`(值 `Visualization Manager.TcVMO`,只出現在 TcVIS:axis 1、bfh 9)、`ExcludeFromBuild`(true,axis 1:`ST_AXIS_Coordinated.TcDUT`)。
- Compile 項目大致按路徑排序，但**不是嚴格排序**(XAE 似乎把新增項插在附近):axis `E_SyncProfileEngageMode` 排在 `ST_AXIS_SyncProfile` 後、`Feeder\FB_CorrugatedLifting*` 順序亂;bfh `GVL_R2RIO` 在 `GVL_HMI` 前、`VISUs\Visualization.TcVIS` 在 `POUs\RollToRoll_Type01.TcPOU` 前。
- Compile ↔ 磁碟(兩向):
  - Compile 指到不存在的檔:0(兩專案)。
  - 大小寫與磁碟不同:0。
  - 磁碟上 Tc* 檔沒被 Compile 列入:0。
- 路徑：一律 `\` 分隔、相對於 plcproj 目錄、沒有 `/`、沒有 `%xx` MSBuild 跳脫；含空白的路徑直接寫空白(axis 4 個 `Basic Function\…`、`Visualization Manager.TcVMO`;bfh 1 個)。

### 6.4 `<Folder Include>` vs 實際目錄

- axis:14 個 Folder ↔ 磁碟目錄完全一致(無多、無少)。
- bfh:19 個 Folder,其中 **4 個在磁碟上不存在**:`10_Units`、`20_Objects`、`VISUs\VISUs\VISUs`、`VISUs\VISUs\VISUs\Images`(XAE 中的空資料夾不會在磁碟建目錄)。磁碟上沒有未列入的目錄。
- Compile 用到的目錄全部有對應 Folder 宣告(兩專案 0 缺)。
- Folder 也非嚴格排序(bfh `VISUs` 在 `POUs` 前)。

### 6.5 `<None>` / `<Content>` / `<SubObject>`

```xml
<None Include="PLC1.tmc">            <!-- 兩專案都有，指向 <Name>.tmc -->
  <SubType>Content</SubType>
</None>
<Content Include="VISUs\VISUs\VISUs\Images\chrome_PgeV3rh02f.png">   <!-- bfh;檔案不在磁碟 -->
  <SubType>Content</SubType>
</Content>
<SubObject Include="FB_AdvancedHoming.M_HomeDirect_WithBias">          <!-- axis;成員層級排除 -->
  <ExcludeFromBuild>true</ExcludeFromBuild>
</SubObject>
```

### 6.6 LibraryReference / PlaceholderReference / PlaceholderResolution

```xml
<PlaceholderReference Include="Tc2_MC2">
  <DefaultResolution>Tc2_MC2, * (Beckhoff Automation GmbH)</DefaultResolution>
  <Namespace>Tc2_MC2</Namespace>
</PlaceholderReference>
<PlaceholderReference Include="System_VisuElems">
  <DefaultResolution>VisuElems, 4.8.0.0 (System)</DefaultResolution>
  <Namespace>VisuElems</Namespace>
  <SystemLibrary>true</SystemLibrary>
  <ResolverGuid>2717eb6a-dd07-4c66-8d8d-cacebd7b18ae</ResolverGuid>   <!-- 無大括號 -->
</PlaceholderReference>
<PlaceholderResolution Include="Tc2_MC2">                                   <!-- axis only -->
  <Resolution>Tc2_MC2, 3.3.72.0 (Beckhoff Automation GmbH)</Resolution>
</PlaceholderResolution>
<LibraryReference Include="VisuSymbols,3.5.10.0,System">                    <!-- bfh only;逗號無空白 -->
  <Namespace>VisuSymbols</Namespace>
</LibraryReference>
```

- PlaceholderReference 子元素組合:`[DefaultResolution, Namespace]` axis 17 / bfh 6;`[DefaultResolution, Namespace, SystemLibrary, ResolverGuid]` axis 7 / bfh 7(全是 `System_Visu*`);`[DefaultResolution]` 只有 1 個(bfh `Tc2_Utilities`,沒有 Namespace)。
- `DefaultResolution` 格式 `<庫名>, <版本 | *> (<廠商>)`;`LibraryReference Include` 格式 `<庫名>,<版本>,<廠商>`。
- PlaceholderReference `Include` 大小寫不統一:bfh 有 `system_visuinputs`(DefaultResolution 也是 `visuinputs, 3.5.13.0 (system)`),axis 是 `System_VisuInputs`。

---

## 7. `.tsproj` 與三處 GUID 一致性

### 7.1 結構

- 根 `<TcSmProject xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://www.beckhoff.com/schemas/2012/07/TcSmProject" TcSmVersion="1.0" TcVersion="3.1.40xx.xx">`。
- `TcSmProject/Project[@ProjectGUID]` → `System/Tasks/Task` … `Plc/Project` …。
- PLC 專案參照(實際元素):

```xml
<Plc>
  <Project GUID="{289ACF00-57FF-4892-A409-B7CB00B64554}" Name="AxisInterface"
           PrjFilePath="AxisInterface\AxisInterface.plcproj" TmcFilePath="AxisInterface\AxisInterface.tmc"
           ReloadTmc="true" AmsPort="851" TargetArchiveSettings="#x000f" FileArchiveSettings="#x000e" SymbolicMapping="true">
    <Instance Id="#x08502000" TcSmClass="TComPlcObjDef" KeepUnrestoredLinks="2" TmcHash="{…}" TmcPath="AxisInterface\AxisInterface.tmc">
      …
      <Contexts><Context><Id>0</Id><Name>PlcTask</Name>
        <ManualConfig><OTCID>#x02010030</OTCID></ManualConfig>
        <Priority>20</Priority><CycleTime>2000000</CycleTime></Context></Contexts>
      <TaskPouOids><TaskPouOid Prio="20" OTCID="#x08502001"/></TaskPouOids>
    </Instance>
  </Project>
</Plc>
```

  bfh 屬性略不同(`CopyTmcToTarget="true"`,無 `TargetArchiveSettings`/`SymbolicMapping`)。`PrjFilePath` 相對於 tsproj 目錄、`\` 分隔。tsproj 的 GUID 是**大寫**。

### 7.2 Task 定義與 .TcTTO 對應

| 欄位 | .TcTTO | tsproj `System/Tasks/Task` | tsproj `Plc/…/Context` | `TaskPouOid` |
|---|---|---|---|---|
| 名稱 | `Task@Name` = PlcTask | `<Name>PlcTask</Name>` | `<Name>PlcTask</Name>` | — |
| Priority | 20 | `@Priority="20"` | `<Priority>20</Priority>` | `@Prio="20"` |
| CycleTime(axis) | 2000 | `@CycleTime="20000"` | `<CycleTime>2000000</CycleTime>` | — |
| CycleTime(bfh) | 10000 | `@CycleTime="100000"` | `<CycleTime>10000000</CycleTime>` | — |

- 名稱、Priority 四處一致(兩專案)。
- CycleTime 比例兩專案都是 TTO ×10 = Task、TTO ×1000 = Context。TTO 有註解寫明 micro seconds,所以推得 Task 是 100 ns 單位、Context 是 ns 單位(推得，未查 InfoSys)。
- bfh 另有 `MotionTask`(Id 4、Priority 1、CycleTime 20000、AmsPort 351),不對應任何 TcTTO(NC task)。
- tsproj `Task@Id`(3/4)是整數，不是 GUID;TTO 的 `Task@Id` 是 GUID,兩者無對應關係。

### 7.3 三處 GUID 比對

| 專案 | 項目 | .plcproj `ProjectGuid` | .tsproj `Plc/Project@GUID` | .sln |
|---|---|---|---|---|
| bfh | PLC 專案 | `{2cc04917-125b-4c19-bac8-bf2c10a34957}` | `{2CC04917-125B-4C19-BAC8-BF2C10A34957}` | `{2CC04917-125B-4C19-BAC8-BF2C10A34957}`(只在 `ProjectConfigurationPlatforms`) |
| bfh | TwinCAT 專案 | — | `Project@ProjectGUID="{E7B0BA52-2F63-4659-ACCF-535A387ABD62}"` | `Project(…) = "BFH_1650", "LangMang260618\BFH_1650.tsproj", "{E7B0BA52-…}"` |
| axis | PLC 專案 | `{289acf00-57ff-4892-a409-b7cb00b64554}` | `{289ACF00-57FF-4892-A409-B7CB00B64554}`(3 份 tsproj 都一樣) | `{289ACF00-57FF-4892-A409-B7CB00B64554}`(只在 `ProjectConfigurationPlatforms`) |
| axis | TwinCAT 專案 | — | `{10112974-92E6-3C4B-560E-B30614E05491}`(3 份 tsproj 都一樣) | `Project(…) = "AxisInterface_Type01_Library", "AxisInterface_Type01_Library\AxisInterface_Type01_Library.tsproj", "{10112974-…}"` |

- **結論：不分大小寫比對，三處全部一致(兩專案)**。大小寫固定:plcproj 小寫、tsproj 與 sln 大寫。
- sln 裡 PLC 專案**不是** `Project(...)` 條目，只以 GUID 出現在 `ProjectConfigurationPlatforms`。tsproj 的 Project type GUID 是 `{B1E792BE-AA5F-4E3C-8C82-674BF9C0715B}`;axis 另有 `.tcmproj`(Scope)`{FD9F1D59-E000-42F3-8744-88DE1BE93C06}`。
- tsproj 的 `ProjectGUID` 不一定是 v4(axis `10112974-92E6-3C4B-…` version 碼 3)。

### 7.4 sln 版本差異

| | bfh | axis |
|---|---|---|
| 第 3 行 | `# TcXaeShell Solution File, Format Version 11.00` | `# Visual Studio Version 17` |
| VisualStudioVersion | 15.0.35826.109 | 17.14.36930.0 |
| SolutionConfigurationPlatforms | CE7 (ARMV7)、OS (ARMT2)、RT (x64)、RT (x86)(×Debug/Release) | 再加 OS (ARMV7-A/ARMV7-M/ARMV8-A/x64/x64-E),共 9 種 |

---

## 8. `.TcTTO` 與 plcproj 的列法

- 結構見 §3.6。
- plcproj 列法與其他物件一樣(2/2):

```xml
<Compile Include="PlcTask.TcTTO">
  <SubType>Code</SubType>
</Compile>
```

- 兩專案的 TTO 都在 plcproj 同層(根目錄)。tsproj 透過 `Context/Name` = TTO 的 `Task@Name` 對應(§7.2);TTO 的 `PouCall/Name` 指到 PROGRAM 名稱。

---

## 9. 4024 vs 4026 結構差異

| 項目 | bfh(4024) | axis(4026) | 確定是版本差異? |
|---|---|---|---|
| tsproj `TcVersion` | 3.1.4024.71 | 3.1.4026.22 | 是(定義) |
| Tc* `ProductVersion` | 3.1.4024.16(1 個 4026.0、TTO 缺) | 4026.17 / 4026.18,混 4024.13 | 是 |
| POU 的 `LineIds` | 45/45 有 | 4026 戳記的 19 個 POU 全無；4024.13 戳記的 1 個有 | 語料相關性強，原因未查 |
| plcproj `WriteLineIDs` 選項 | 無 | `True` | 不確定 |
| TcTTO | 無 ProductVersion、結尾有 `<ObjectProperties />` | 有 ProductVersion、無 ObjectProperties | 可能(各 1 檔) |
| plcproj XML 宣告 / BOM | 無 / 無 | `utf-8` / 有 | 可能(各 1 檔) |
| plcproj `ProgramVersion` | 3.1.4026.22 | 3.1.4026.24 | 否(是開啟它的 XAE 版本，不是專案版本) |
| POU `Folder` + `FolderPath` | 無 | 11 檔 | 否(使用方式差異) |
| GUID version 0 的 Id | 0 | 80 | 不確定 |
| PlaceholderResolution / SubObject | 無 | 有 | 否(使用方式差異) |
| LibraryReference / Content | 有 | 無 | 否 |
| Visu 系統庫版本 | 3.5.13.x | 4.7 / 4.8 | 是(隨 XAE) |
| sln 標頭 | TcXaeShell / VS 15 | Visual Studio 17 | 否(IDE 殼差異) |
| 根 `Version`、物件元素結構、CDATA、屬性順序、2 空白縮排、CRLF、Tc* 無結尾換行、tsproj tab 縮排 | 相同 | 相同 | — |

---

## 10. 對 linter 規則的啟示

### 10.1 可以當確定性檢查(語料零例外，或例外全是非 XAE 寫入)

1. **XML well-formed**,根元素 `TcPlcObject`、`Version="1.1.0.1"`,底下恰好一個物件元素(178/178)。
2. **物件 `Name` == 檔名**(區分大小寫，178/178);POU/DUT 宣告名稱 == `Name`(153/153);Method 宣告名稱 == `Name`(80/80)。
3. **每個 POU/DUT/GVL/Method/Action/Folder/Task/Visu 都有 `Id`**,格式 `{8-4-4-4-12}` 小寫十六進位(306/306)。
4. **Id 在專案內唯一**(306 個 0 重複)。
5. **元素順序**:POU = `Declaration, Implementation, Folder*, Action*, Method*, LineIds*`;Method = `Declaration, Implementation`;Action = `Implementation`;DUT/GVL = `Declaration` 單一子元素;TTO 順序固定。
6. **Declaration / ST 一律 CDATA**、一個元素一段 CDATA;空實作是 `<ST><![CDATA[]]></ST>`。
7. **LineIds(若存在)**:Name 指到實際存在的本體/成員、每個實作恰好一個、位於 POU 最後；Σ(Count+1) == 實作行數(57/58,唯一例外疑似外部修改，正好是這條規則要抓的情形)。
8. **plcproj ↔ 磁碟**:每個 `Compile Include` 檔案存在、大小寫一致；每個磁碟上的 Tc* 檔都有 Compile;`SubType` = `Code`;Compile 用到的目錄都有 `Folder` 宣告。
9. **三處 GUID 一致**:plcproj `ProjectGuid` == tsproj `Plc/Project@GUID` == sln `ProjectConfigurationPlatforms` 中的 GUID(不分大小寫);tsproj `PrjFilePath` 指到實際 plcproj。
10. **Task 對應**:TTO `Task@Name` ↔ tsproj `Context/Name`;Priority 四處一致;`PouCall/Name` 指到存在的 PROGRAM。
11. **編碼**:Tc* 物件檔 UTF-8 BOM + `encoding="utf-8"` 宣告 + CRLF(XAE 寫的檔零例外；違反的 11 檔都是外部寫入)。

### 10.2 可以當 warning / 啟發式(有訊號但不是硬性)

- **假 GUID 偵測**:序列(`1234`、`abcd…`)、重複字元(`aaaa`、`1111`)、`a1b2c3d4` 類 → 語料 6 個，全是 AI/手寫。建議 warning,不擋。
- **GUID version 碼非 4**:XAE 寫的 bfh 全是 v4,但 axis 有 80 個 v0,來源不明 → **不能當錯誤**。
- **CDATA 內混 LF / 檔尾多換行 / 少 BOM**:代表在 XAE 外改過；可提示「建議 Reset-TcSolution / 讓 XAE 重存」,不當錯誤。
- **成員按字母序**(20/20 符合，且 `SubObjectsSortedByName=True`):AI 插入 Method 位置錯可提示，但順序錯不一定導致編譯失敗(未實測)。

### 10.3 語料不足以下結論

- `<Property>`/`<Get>`/`<Set>`、`<Transition>`、`<Itf>`、SFC/FBD/LD/IL、`.TcIO` 的結構：語料沒有。
- 一個 Action 下多個 `<ST>`:語料沒有，不能假設存在或不存在。
- 4026 為何不寫 LineIds、`WriteLineIDs` 的作用：只有一個 4026 專案，需另外實測或查 InfoSys。所以「缺 LineIds」**不可**當錯誤。
- Compile / Folder 的排序規則：XAE 本身就不嚴格排序，不能當規則。
- plcproj 有沒有 XML 宣告 / BOM:兩專案不同，不能當規則。
- Folder 宣告但磁碟沒目錄：XAE 允許(bfh 4 個),不是錯誤；反向(磁碟有目錄沒宣告)語料沒有。
- CycleTime 單位:TTO = µs 有註解為證；tsproj 的 100 ns / ns 只是由比例推得，寫成規則前要查 InfoSys。
- 多 PLC 專案、多 task、多 PouCall、程式庫參照(`.library`)錯誤情境：語料沒有。

## 11. 1a.8 XAE 實測補充(2026-11-13)

用 XAE 4026.22(VS2022)與 tcauto 建立真實物件後的修正,細節與原樣檔案見 `../verification/xae-generated-xml.md` 與 `../verification/fixtures-xae-generated/`:

- **§5 / §10.1-6 修正**:程式碼含 `]]>` 時 XAE 自己切成兩段 CDATA(`]]]]><![CDATA[>`)。「一個元素一段 CDATA」只是語料沒遇到,不是規則;引擎必須串接多段 CDATA。
- **§3.2 補充**:POU 子元素順序觀察到 `Declaration, Implementation, Action*, Method*, Property*`;`<Property>` → `<Declaration>`、`<Get Name="Get">`、`<Set Name="Set">`(各有 Declaration + Implementation)。
- **§3.8 補充**:`.TcIO` 根下是 `<Itf Name Id>`(無 SpecialFunc),ITF Method / Property 只有 `<Declaration>`。
- SFC 實作與 CFC 相同,是 `XmlArchive`,另有同層 `<ObjectProperties>`。
- XAE 4026.22 新建物件的 `ProductVersion` 是 `3.1.4026.18`;新建 / 改寫過的 4026 POU 不寫 `<LineIds>`,而且會把手寫的 LineIds 刪掉(`../verification/xae-corrupt-file-behavior.md` 2.4)。
