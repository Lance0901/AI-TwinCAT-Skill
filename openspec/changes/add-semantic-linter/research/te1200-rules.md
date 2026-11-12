# TE1200 TwinCAT 3 PLC Static Analysis 規則清單

整理日期:2026-11-13。分類欄(未使用/型別轉換/指標/控制流/宣告/命名/其他)為整理者依規則「Function」描述自行歸類,非 Beckhoff 官方分類(官方章節分組見第 2 節末)。中文說明為整理者依英文 Function 欄位意譯。

## 1. 來源

實際打開成功:
- https://infosys.beckhoff.com/content/1033/te1200_tc3_plcstaticanalysis/3471292555.html (TE1200 Overview:Light 版、章節連結)
- https://infosys.beckhoff.com/content/1033/te1200_tc3_plcstaticanalysis/20912884235.html (SA0001 - SA0020 清單,名稱與子頁連結)
- 未能打開:`.../3475825675.html`(Rules overview,WebFetch 回 502)、`.../index.html`(逾時)。

**來源偏離說明**:InfoSys 的 Rules overview 頁抓不到,也無法逐頁抓 100+ 規則子頁,故規則完整清單、Light/Full 表、Automation Interface 章節改取自 Beckhoff 官方發佈的同一份手冊 PDF:
- https://download.beckhoff.com/download/Document/automation/twincat3/TE1200_TC3_PLC_Static_Analysis_EN.pdf (EN,Version 2.11.1,日期 2026-09-14;需帶 User-Agent 下載)

這不是 infosys.beckhoff.com 網域,但為 Beckhoff 官方手冊。若要求嚴格只用 infosys,僅 SA0001-SA0020 的名稱與 Light 版概述有 InfoSys 頁面直接驗證。

## 2. 規則表(手冊 2.11.1 列出共 117 條)

| SA 編號 | 規則英文名稱 | 中文說明 | 類別 |
|---|---|---|---|
| SA0001 | Unreachable code | 找出不會被執行的程式碼(如 RETURN/CONTINUE 之後) | 控制流 |
| SA0002 | Empty objects | 找出沒有程式碼的 POU/GVL/資料型別宣告 | 其他 |
| SA0003 | Empty statements | 只有分號、沒有敘述的行 | 其他 |
| SA0004 | Multiple write access on output | 同一個 output 在多處被寫入 | 其他 |
| SA0005 | Invalid addresses and data types | 無效的位址與資料型別指定 | 宣告 |
| SA0006 | Write access from several tasks | 同一變數被多個 task 寫入 | 其他 |
| SA0007 | Address operators on constants | 對常數使用 ADR 運算子 | 指標 |
| SA0008 | Check subrange types | subrange 型別超出範圍 | 型別轉換 |
| SA0009 | Unused return values | 呼叫 function/method/property 但未使用回傳值 | 未使用 |
| SA0010 | Arrays with only one component | 只有單一元素的 ARRAY | 宣告 |
| SA0011 | Useless declarations with only one component | 只有單一成員的 STRUCT/UNION/ENUM | 宣告 |
| SA0012 | Variables which could be declared as constants | 可宣告為 CONSTANT 的變數 | 宣告 |
| SA0013 | Declarations with the same variable name | 與其他變數/POU 同名的宣告 | 命名 |
| SA0014 | Assignments of instances | 對 FB instance 的賦值 | 其他 |
| SA0015 | Access to global data via FB_init | FB 透過 FB_init 存取全域資料 | 宣告 |
| SA0016 | Gaps in structures | 結構因對齊產生的間隙(gap) | 宣告 |
| SA0017 | Non-regular assignments to pointer variables | 對指標賦予非位址的值 | 指標 |
| SA0018 | Unusual bit access | 對有號變數做位元存取 | 型別轉換 |
| SA0019 | Implicit pointer conversions | 隱式的指標型別轉換 | 指標 |
| SA0020 | Possibly assignment of truncated value to REAL variable | 整數運算可能截斷後賦給 REAL | 型別轉換 |
| SA0021 | Transporting the address of a temporary variable | 傳遞暫存(stack)變數的位址 | 指標 |
| SA0022 | (Possibly) unassigned return value | (可能)未賦值的回傳值 | 其他 |
| SA0023 | Complex return values | 無法以暫存器複製回傳的複雜回傳值 | 宣告 |
| SA0024 | Untyped literals | 運算中使用未指定型別的 literal | 型別轉換 |
| SA0025 | Unqualified enumeration constants | 未加限定名稱的 enum 常數 | 命名 |
| SA0026 | Possible truncated strings | 字串賦值/初始化可能被截斷 | 型別轉換 |
| SA0027 | Multiple usage of name | 名稱/識別字/POU 名稱重複使用 | 命名 |
| SA0028 | Overlapping memory areas | 兩個以上變數佔用同一記憶體區域 | 宣告 |
| SA0029 | Notation in code different to declaration | 程式碼中的寫法與宣告不一致(大小寫等) | 命名 |
| SA0031 | Unused signatures | 未被呼叫的 POU/型別/介面/method 等 | 未使用 |
| SA0032 | Unused enumeration constants | 未使用的 enum 常數 | 未使用 |
| SA0033 | Unused variables | 已宣告但未使用的變數 | 未使用 |
| SA0034 | Enumeration variables with incorrect assignment | 對 enum 變數賦予不正確的值 | 型別轉換 |
| SA0035 | Unused input variables | 未賦值的 VAR_INPUT | 未使用 |
| SA0036 | Unused output variables | 未賦值的 VAR_OUTPUT | 未使用 |
| SA0037 | Write access to input variable | 對 VAR_INPUT 寫入 | 宣告 |
| SA0038 | Read access to output variable | 讀取 VAR_OUTPUT | 宣告 |
| SA0039 | Possible null pointer dereferences | 可能的 null pointer dereference | 指標 |
| SA0040 | Possible division by zero | 可能發生除以零 | 其他 |
| SA0041 | Possibly loop-invariant code | 迴圈內可能為 loop-invariant 的程式碼 | 控制流 |
| SA0042 | Usage of different access paths | 同一變數使用不同的存取路徑 | 其他 |
| SA0043 | Use of a global variable in only one POU | 全域變數只在單一 POU 使用 | 宣告 |
| SA0044 | Declarations with reference to interface | REFERENCE TO <interface> 等宣告 | 指標 |
| SA0046 | Possible use of not initialized interfaces | 可能使用未初始化的 interface | 指標 |
| SA0047 | Access to direct addresses | 在實作中直接存取位址(%I/%Q/%M) | 宣告 |
| SA0048 | AT declarations on direct addresses | 在直接位址上使用 AT 宣告 | 宣告 |
| SA0051 | Comparison operations on BOOL variables | 對 BOOL 做比較運算 | 其他 |
| SA0052 | Unusual shift operation | 對有號變數位移 | 型別轉換 |
| SA0053 | Too big bitwise shift | 位元位移超過資料型別寬度 | 型別轉換 |
| SA0054 | Comparisons of REAL/LREAL for equality/inequality | REAL/LREAL 以 = / <> 比較 | 型別轉換 |
| SA0055 | Unnecessary comparison operations of unsigned operands | 對無號運算元做不必要的比較 | 型別轉換 |
| SA0056 | Constant out of valid range | 常數超出有效範圍 | 型別轉換 |
| SA0057 | Possible loss of decimal points | 可能損失小數位 | 型別轉換 |
| SA0058 | Operations of enumeration variables | 對 enum 變數做運算(賦值除外) | 其他 |
| SA0059 | Comparison operations always returning TRUE or FALSE | 比較結果恆為 TRUE/FALSE | 控制流 |
| SA0060 | Zero used as invalid operand | 以 0 作為無效運算元 | 其他 |
| SA0061 | Unusual operation on pointer | 對 POINTER 做非常見運算 | 指標 |
| SA0062 | Expression is constant | 運算式為常數 | 控制流 |
| SA0063 | Possibly not 16-bit-compatible operations | 可能不相容 16-bit 的運算 | 型別轉換 |
| SA0064 | Addition of pointer | 指標加法 | 指標 |
| SA0065 | Incorrect pointer addition to base size | 指標加法的值與基底大小不符 | 指標 |
| SA0066 | Use of temporary results | 使用小於暫存器寬度的暫存結果 | 型別轉換 |
| SA0072 | Invalid uses of counter variable | FOR 計數變數被寫入 | 控制流 |
| SA0073 | Use of non-temporary counter variable | FOR 使用非暫時(non-temporary)計數變數 | 控制流 |
| SA0075 | Missing ELSE | CASE 缺少 ELSE | 控制流 |
| SA0076 | Missing enumeration constant | CASE 未涵蓋所有 enum 常數 | 控制流 |
| SA0077 | Enumeration type mismatch with CASE expression | CASE 混用 enum 與非 enum 值 | 控制流 |
| SA0078 | Missing CASE branches | CASE 沒有任何 case(只有 ELSE) | 控制流 |
| SA0081 | Upper border is not a constant | FOR 上限不是常數 | 控制流 |
| SA0090 | POUs should have a only one exit point | POU 應只有一個 exit point(RETURN 不在末尾) | 控制流 |
| SA0095 | Assignments in conditions | IF/CASE/WHILE/REPEAT 條件內含賦值 | 控制流 |
| SA0100 | Variables greater than <n> bytes | 變數大小超過 n bytes(可參數化) | 宣告 |
| SA0101 | Names with invalid length | 名稱長度不合規(可參數化) | 命名 |
| SA0102 | Access to program/fb variables from the outside | 從外部讀取 program/FB 的區域變數 | 宣告 |
| SA0103 | Concurrent access on not atomic data | 非原子資料被多個 task 存取 | 其他 |
| SA0105 | Multiple instance calls | FB instance 被多次呼叫(需 {attribute 'analysis:report-multiple-instance-call'}) | 其他 |
| SA0106 | Virtual method calls in FB_init | 在 FB_init 內呼叫 virtual method | 其他 |
| SA0107 | Missing formal parameters | 缺少 formal parameter(呼叫未帶參數名) | 其他 |
| SA0111 | Pointer variables | 使用 POINTER TO 變數(strict IEC) | 指標 |
| SA0112 | Reference variables | 使用 REFERENCE TO 變數(strict IEC) | 指標 |
| SA0113 | Variables with data type WSTRING | 使用 WSTRING(strict IEC) | 宣告 |
| SA0114 | Variables with data type LTIME | 使用 LTIME(strict IEC) | 宣告 |
| SA0115 | Declarations with data type UNION | 使用 UNION(strict IEC) | 宣告 |
| SA0117 | Variables with data type BIT | 使用 BIT 型別變數(strict IEC) | 宣告 |
| SA0118 | Initializations not using constants | 初始化使用非常數(strict IEC) | 宣告 |
| SA0119 | Object-oriented features | 使用物件導向功能(EXTENDS/IMPLEMENTS 等,strict IEC) | 其他 |
| SA0120 | Program calls | 呼叫 PROGRAM(strict IEC) | 其他 |
| SA0121 | Missing VAR_EXTERNAL declarations | 缺少 VAR_EXTERNAL 宣告(strict IEC) | 宣告 |
| SA0122 | Array index defined as expression | 陣列邊界以運算式宣告(strict IEC) | 宣告 |
| SA0123 | Usages of INI, ADR or BITADR | 使用 INI/ADR/BITADR(strict IEC) | 指標 |
| SA0124 | Dereference access in initializations | 初始化中使用 dereference | 指標 |
| SA0125 | References in initializations | 初始化中使用 reference | 指標 |
| SA0130 | Implicit expanding conversions | 隱式擴大型別轉換 | 型別轉換 |
| SA0133 | Explicit narrowing conversions | 顯式縮小型別轉換 | 型別轉換 |
| SA0134 | Explicit signed/unsigned conversions | 顯式有號/無號轉換 | 型別轉換 |
| SA0140 | Statements commented out | 被註解掉的程式碼 | 其他 |
| SA0145 | Possible use of not initialized references | 可能使用未初始化的 reference | 指標 |
| SA0147 | Unusual shift operation - strict | 對非 bit-field 型別位移(strict) | 型別轉換 |
| SA0148 | Unusual bit access - strict | 對非 bit-field 型別位元存取(strict) | 型別轉換 |
| SA0150 | Violations of lower or upper limits of the metrics | 違反 metrics 上/下限的 FB | 其他 |
| SA0160 | Recursive calls | 遞迴呼叫(含經 virtual/interface 的可能遞迴) | 控制流 |
| SA0161 | Unpacked structure in packed structure | packed 結構內含 unpacked 結構 | 宣告 |
| SA0162 | Missing comments | 缺少註解 | 命名 |
| SA0163 | Nested comments | 巢狀註解 | 其他 |
| SA0164 | Multi-line comments | 使用多行註解 (* *) | 其他 |
| SA0166 | Maximum number of input/output/VAR_IN_OUT variables | VAR_INPUT/OUTPUT/IN_OUT 數量上限(可參數化) | 宣告 |
| SA0167 | Report temporary FunctionBlock instances | FB instance 宣告為暫時變數(stack) | 宣告 |
| SA0168 | Unnecessary assignments | 無效果的賦值 | 其他 |
| SA0169 | Ignored outputs | 呼叫時未接收 method/function 的 output | 未使用 |
| SA0170 | Address of an output variable should not be used | 使用 output 變數的位址 | 指標 |
| SA0171 | Enumerations should have the 'strict' attribute | enum 應有 {attribute 'strict'} | 宣告 |
| SA0172 | Possible attempt to access outside the array limits | 可能存取超出陣列範圍 | 其他 |
| SA0175 | Suspicious operation on string | 字串可疑操作(UTF-8 相關) | 型別轉換 |
| SA0178 | Cognitive complexity | Cognitive complexity(可參數化) | 其他 |
| SA0179 | Coupling between objects | Coupling between objects(可參數化) | 其他 |
| SA0180 | Index range does not cover the entire array | 索引範圍未涵蓋整個陣列 | 其他 |
| SA0181 | Forbidden symbols | Forbidden symbols(可參數化) | 命名 |
**未取得/手冊未列出的編號**(手冊目錄沒有這些編號,不代表存在或已刪除,不猜測):SA0030、SA0045、SA0049-0050、SA0067-0071、SA0074、SA0079-0080、SA0082-0089、SA0091-0094、SA0096-0099、SA0104、SA0108-0110、SA0116、SA0126-0129、SA0131-0132、SA0135-0139、SA0141-0144、SA0146、SA0149、SA0151-0159、SA0165、SA0173-0174、SA0176-0177。

手冊官方分組(Rules 頁):List unused objects(SA0031/32/33/35/36)、Conversions(SA0019/130/133/134)、Usage of direct addresses(SA0005/47/48)、Rules for operators(SA0051-0066)、Rules for statements(SA0090;FOR:SA0072/73/81;CASE:SA0075-78)、Check strict IEC rules(SA0111-0123、0147、0148)、Rules for initializations(SA0118/124/125)、Possible use of uninitialized variables(SA0039/46/145)、Metrics(SA0178/179)、Checking concurrent access(SA0006/SA0103)、More rules(其餘)。可參數化規則:SA0100、0101、0166、0178、0179、0181。

## 3. 與關注主題的對照

| 主題 | 相關規則 | 備註 |
|---|---|---|
| 未使用變數 / FB instance | SA0033 Unused variables、SA0031 Unused signatures、SA0035/0036 Unused input/output variables、SA0032 | FB instance 是否由 SA0033 涵蓋:手冊 Function 欄未特別提,未驗證 |
| 多次寫入輸出 | SA0004 Multiple write access on output | 只能用 Run static analysis,不支援 Check all objects。相關:SA0037 寫入 VAR_INPUT、SA0038 讀取 VAR_OUTPUT |
| 條件內呼叫 FB/timer | 手冊清單中未取得對應規則 | SA0105(同一 instance 多處呼叫,需 attribute)、SA0167(暫時 FB instance)僅部分相關 |
| 除以零 | SA0040 Possible division by zero;SA0060 Zero used as invalid operand | |
| 陣列越界 | SA0172 Possible attempt to access outside the array limits(重要性 High);SA0180、SA0008 | |
| 指標/REFERENCE 檢查 | SA0039、SA0046、SA0145(未初始化)、SA0017、SA0019、SA0021、SA0061、SA0064/65、SA0111/112、SA0124/125 | |
| CASE 無 ELSE | SA0075 Missing ELSE | |
| 未處理的 enum | SA0076 Missing enumeration constant;SA0077;SA0034;SA0171 | |
| 遞迴 | SA0160 Recursive calls | 含經 virtual/interface 的可能遞迴 |
| 隱式型別轉換 | SA0130 Implicit expanding conversions、SA0019 Implicit pointer conversions、SA0020、SA0024、SA0057、SA0066 | 顯式:SA0133、SA0134 |
| Interface 實作 | 無專用規則;SA0044、SA0046、SA0119(strict IEC 下禁用 OO 功能)、SA0002(例外說明提及 interface 用的空 method) | 「FB 未實作 interface 成員」類檢查手冊未取得 |
| 未使用的回傳值 | SA0009 Unused return values;SA0022 未賦值回傳值;SA0169 Ignored outputs | |
| 同一變數多 task 存取 | SA0006 Write access from several tasks;SA0103 Concurrent access on not atomic data | 皆只偵測直接存取,經 pointer/reference 的不算 |
| 直接位址 %I %Q | SA0047 Access to direct addresses;SA0048 AT declarations on direct addresses;SA0005 | |
| 魔術數字 | 手冊全文搜尋 magic/hard-coded 無命中,未取得對應規則 | SA0024 Untyped literals 不是魔術數字規則 |

## 4. 授權、Light 版、自動化

**授權**(手冊 3 Installation / 3.3):
- TE1200 隨 TwinCAT 3 XAE 安裝,沒有獨立 setup;只需授權 engineering component。Build 4026 workload:`TwinCAT.Standard.XAE`。
- 無 7 天試用授權;無授權時可用免授權的 Static Analysis Light。

**Light 版**(免費,無 TE1200 授權):
- 規則範圍僅 7 條:SA0033 Unused variables、SA0028 Overlapping memory areas、SA0006 Write access from several tasks、SA0004 Multiple write access on output、SA0027 Multiple usage of name、SA0167 Report temporary FunctionBlock instances、SA0175 Suspicious operation on string。
- 規則只能 active-as-error 或 inactive(Full 另可 warning);不輸出 warning。
- 最多報 500 個 error(不可設定);規則設定綁 PLC 專案屬性,不可 save/load;執行綁定編譯流程且不可設定;不可檢查未使用物件(Check all objects);無 precompile wavy underline QuickFix;無 Naming conventions、Metrics、Forbidden symbols。
- Full:100 條以上規則。
- Light 版能否使用 Automation Interface:比較表未列,未驗證。

**Automation Interface**(手冊第 9 章,「can partly be operated」):
- `RunStaticAnalysis()` / `RunStaticAnalysis(bCheckAll)`:ITcPlcIECProject3(Build 4024+)/ ITcPlcIECProject4(4026+)。PowerShell 範例:`$sysMan.LookupTreeItem("TIPC^MyPlcProject^MyPlcProject Project").RunStaticAnalysis()`。
- `SaveStaticAnalysisSettings(file)` / `LoadStaticAnalysisSettings(file)`:*.csa,ITcPlcIECProject4,Build 4026+。
- `ExportStandardMetrics(file)`:ITcPlcIECProject5,Build 4026.4+,輸出 csv。
- `ExportToSarif(path)`:ITcPlcIECProject7,Build 4026.20+,輸出 SARIF;可先 Load 設定再執行。
- 隱式執行:啟用 "Perform static analysis automatically" 後,經 AI 建置專案時會一併執行。
- 結果如何讀回(Error List 等):AI 章節未說明,未驗證。本專案 tcauto 既有工具(如 CheckAllObjects)與這些 API 的關係未驗證。
- 其他:只分析目前 PLC 專案的應用程式碼,不分析引用的 library;可用 pragma/attribute 局部停用規則。

## 5. 取得失敗的部分

- InfoSys Rules overview 頁 502、index.html 逾時;SA0021 以後各規則子頁 InfoSys 未逐頁驗證(內容取自 PDF)。
- 各規則 Function 以外的細節(範例、參數預設值、PLCopen 對應)僅部分檢視,未整理。
