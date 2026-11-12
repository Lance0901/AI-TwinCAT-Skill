# XAE 實際產生的物件 XML(tasks 1a.8)

- 日期:2026-11-13(實測)
- 環境:Windows 11 Home 10.0.26200;TwinCAT XAE 3.1.4026.22(Remote Manager 3.1.4026.22);4024 組另見第 3 節
- 4026 host:VS2022 Community 17(`VisualStudio.DTE.17.0`),專案 = `C:\Temp\Verify-4026-axis` 的副本 `C:\Temp\lint-ide\axis`
- 工具:registered tcauto(master runtime)的 `AddInterface` / `AddPou` / `AddPouMember` / `AddDut` / `AddGvl` / `WritePouCode`;檔案是 XAE 自己存的,原樣放在 `fixtures-xae-generated/`(物件名稱本來就是測試名,沒有專案特有內容)
- 例外:`4026/FB_LintBase.TcPOU` 在植入腳本的一個 bug(PowerShell `rd` 別名)被誤刪後,依 XAE 存出的原文逐字重建(長度 420 byte 與原檔相同);其餘檔案未經手動修改。

## 1. 產出清單(4026)

| 檔案 | 物件 | 怎麼產生 |
|---|---|---|
| `I_LintItf.TcIO` | INTERFACE + Method `M_Do : BOOL` + Property `P_Val : INT` | `AddInterface`、`AddPouMember`(ITF Method 610 / ITF Property 612) |
| `FB_LintBase.TcPOU` | 空 FB(基底) | `AddPou` |
| `FB_LintTest.TcPOU` | `FUNCTION_BLOCK FB_LintTest EXTENDS FB_LintBase IMPLEMENTS I_LintItf`;Method `M_Do`;Property `P_Val`(Get + Set)、`P_Ro`(只有 Get);Action `A_Act`(ST,程式碼含 `]]>`)、`A_Sfc`(SFC) | `AddPou`、`AddPouMember`(609 / 611 / 613 / 614 / 608)、`WritePouCode` |
| `E_LintEnum.TcDUT` / `ST_LintStruct.TcDUT` / `U_LintUnion.TcDUT` / `T_LintAlias.TcDUT` | ENUM / STRUCT / UNION / ALIAS | `AddDut` |
| `GVL_Lint.TcGVL` | GVL | `AddGvl` |

**做不到的**(不手寫,照實記錄):
- **Transition**:tcauto `AddPouMember` 只有 Method / Property / Action / Get / Set,沒有 Transition。
- **SFC POU 本體**:`AddPou` 只建 ST。改用 `AddPouMember -Language SFC` 建了一個 SFC **Action**(`A_Sfc`),取得 SFC 實作的 XML 形狀。
- **INTERFACE Property 的 Get / Set**:tcauto 刻意不支援(`POU_MEMBER_UNSUPPORTED`,讀取曾讓 VS2022 crash);所以 `I_LintItf.P_Val` 沒有 accessor,`CheckAllObjects` 對它報 warning `C0373 The property defines neither a get nor a set accessor.`(實測 2026-11-13)。

## 2. 與 `research/tc-xml-schema-observed.md` 的差異(4026)

| 項目 | 語料觀察 | XAE 實測 | linter 影響 |
|---|---|---|---|
| CDATA 段數(§5、§10.1-6) | 一律單段;`]]]]><![CDATA[>` 0 例 | **程式碼含 `]]>` 時 XAE 自己切成兩段**:`'a]]>b'` 存成 `<![CDATA[sTxt := 'a]]]]><![CDATA[>b'; ...]]>` | PROJECT-XML-003(b)「多段 CDATA」**不能報**;引擎讀 CDATA 必須把同一元素的多段串接(XmlReader 讀 `.InnerText` / 連續 CDATA 節點相接) |
| `ProductVersion` | 4026 物件 4026.17 / .18 | XAE 4026.22 新建的檔一律 `3.1.4026.18` | 不能拿 ProductVersion 比對 XAE 版本 |
| LineIds(§3.3) | 4026 戳記的 POU 都沒有 | 新建 / WritePouCode 寫過的 4026 POU 也**沒有** `<LineIds>`(axis `.plcproj` 有 `WriteLineIDs=True`) | 確認「缺 LineIds」不可當錯誤 |
| POU 子元素順序(§3.2) | `Declaration, Implementation, Folder*, Action*, Method*, LineIds*` | `Declaration, Implementation, Action*(A_Act, A_Sfc), Method*, Property*(P_Ro, P_Val)`;同類按名稱排序 | 順序補上 `Property*`,位置在 Method 之後 |
| `<Property>` | 語料沒有 | `<Property Name Id>` → `<Declaration>`(`PROPERTY PUBLIC P_Val : INT`)→ `<Get Name="Get" Id>` → `<Set Name="Set" Id>`;Get / Set 各有 `<Declaration>`(`PUBLIC` + 空 `VAR END_VAR`)與 `<Implementation><ST>`;只有 Get 時就只有 `<Get>` | PROJECT-SUB-001 的結構依據;Get / Set 的 `Name` 固定是 `Get` / `Set` |
| `.TcIO` / `<Itf>`(§3.8) | 語料沒有 | 根 `TcPlcObject` → `<Itf Name Id>`(**沒有** SpecialFunc)→ `<Declaration>`(`INTERFACE I_LintItf` + 換行)→ `<Method Name Id>` 只有 `<Declaration>`(`METHOD M_Do : BOOL` + `VAR_INPUT END_VAR`),**沒有 Implementation** → `<Property Name Id>` 只有 `<Declaration>` | KIND-001:`.TcIO` ↔ `<Itf>` ↔ `INTERFACE`;ITF Method 不要求 Implementation |
| SFC 實作 | 語料沒有 | `<Implementation><SFC><XmlArchive><Data>…</Data><TypeList>…</TypeList></XmlArchive></SFC></Implementation>`,另有與 Implementation 同層的 `<ObjectProperties><XmlArchive>`(SFCProperty 旗標);不是 CDATA | 與 CFC 一樣是 XmlArchive:ST 規則對它 `notAnalyzed` |
| Method 宣告 | `METHOD <名稱>` | `AddPouMember` 帶 Access 時寫成 `METHOD PUBLIC M_Do : BOOL`(修飾字在名稱前) | 取 Method 名稱要略過存取修飾字 |
| POU 屬性 | `Name, Id, SpecialFunc="None"` | 相同 | — |
| DUT / GVL | `Declaration` 單一子元素 | 相同(4 種 DUT、GVL 皆是) | — |
| 檔案層級(§1) | UTF-8 BOM + `encoding="utf-8"` + CRLF + 無結尾換行 + 2 空白縮排 | 9 個新檔全部相同 | — |
| `.plcproj` Compile(§6.3) | `<Compile Include><SubType>Code</SubType></Compile>` | 新物件(含 `.TcIO`)相同;XAE 新增的 Compile 依字母序插入 | — |

## 3. 4024(32-bit XAE Shell)

- 環境:32-bit XAE Shell(`TcXaeShell.DTE.15.0`,XAE 4026.22),Remote Manager 4024.71,專案 `C:\Temp\Verify-4024-bfh` 的副本;同樣的 tcauto 呼叫建立同一組物件(INTERFACE、FB_LintBase、FB_LintTest 含 Method / Property Get+Set / 只有 Get / Action、4 種 DUT、GVL;沒有 SFC Action)。Build 0 error / 0 warning。
- 原樣檔:`fixtures-xae-generated/4024/`(8 檔)。

與 4026 的差異:

| 項目 | 4026(VS2022) | 4024(32-bit XAE Shell + RM 4024.71) |
|---|---|---|
| `ProductVersion` | `3.1.4026.18` | `3.1.4024.16` |
| `<LineIds>` | 不寫 | **有**,而且每個實作一塊,含 Property accessor:`FB_LintTest`、`FB_LintTest.A_Act`、`FB_LintTest.M_Do`、`FB_LintTest.P_Ro.Get`、`FB_LintTest.P_Val.Get`、`FB_LintTest.P_Val.Set`(accessor 的名稱格式是 `<POU>.<Property>.Get`) |
| `]]>` 的存法 | 切兩段 CDATA | 相同:`'a]]]]><![CDATA[>b'` |
| BOM / 行尾 | UTF-8 BOM、CRLF | 相同 |
| 預設位置 | AxisInterface 沒有 POUs 資料夾,放專案根 | POU / ITF 放 `POUs\`,DUT / GVL 放專案根 |
