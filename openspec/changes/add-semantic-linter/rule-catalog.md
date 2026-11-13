# 規則目錄(#252)

結論:分期依 owner 決定 1 排序:先做 **compilerCatches = no 且 machineImpact ∈ behavior / crash** 的規則,AI 改磁碟檔造成的專案完整性問題(owner 決定 6)同樣留在 Phase 1a;相容性契約(CONTRACT-*)放最後。判斷確定的規則預設 blocking(owner 決定 2);會影響機台行為的 warning 進 `data.unresolved[]`,必須處置(owner 決定 3,design.md D6)。

## 欄位定義

| 欄位 | 值 |
|---|---|
| `machineImpact` | `none` / `project-integrity`(專案檔損毀、XAE 載入或 Build 異常)/ `behavior`(程式照跑但機台動作錯)/ `crash`(PLC exception、cycle overrun、task 卡死) |
| `compilerCatches` | `yes`(編譯錯誤,Build 失敗)/ `warning`(編譯器只出 warning,Build 仍成功,所以不算擋下)/ `no` / `unknown`(未實測)/ `measured:<日期>`(mutation testing 以 `BuildProject` 實測後填,design.md D7) |
| `confidence` | `high` / `medium` / `low` |
| `blockable` | `true` / `false` / `pending`(偵測確定,但「是不是錯」依賴未實測的 XAE 行為;實測前照 error 算 blocking,帶 `blockableBasis: "pending-measurement"`) |
| `te1200` | 對應的 SA 規則與版別(`Light` = 免費 7 條:SA0004 / SA0006 / SA0027 / SA0028 / SA0033 / SA0167 / SA0175;`Full` = 需授權)。來源 `research/te1200-rules.md`。**客戶只有 Light**(owner 決定 4):對應 Full 的規則由本 linter 做;對應 Light 的規則仍做,價值在「寫入前就擋」與「客戶沒啟用 Light」 |
| `phase` | 見 tasks.md |

TwinCAT 行為沒有 InfoSys 出處的一律標「未驗證」,並在 tasks.md 排「IDE 實測」或「查 InfoSys」任務;出處清單見 `research/st-syntax-inventory.md` 第 2 部分。XML 結構的依據是 `research/tc-xml-schema-observed.md`(從真實 4024 / 4026 專案歸納)。

## 總表(依 phase 排序)

| ID | 一句話 | machineImpact | compilerCatches(`no` 是推論,待 tasks 3.4 mutation 以 BuildProject 實測) | confidence | blockable | TE1200 | phase |
|---|---|---|---|---|---|---|---|
| PROJECT-XML-001 | XML 不是 well-formed | project-integrity | unknown | high | true | — | 1a |
| PROJECT-XML-002 | 編碼宣告與實際位元組不符 / 非法 UTF-8 / BOM 異常 | project-integrity | unknown | high | true(宣告與位元組不符、非法 UTF-8:XAE 靜默載入成 itemType 0);無 BOM / 一致的 UTF-16 / 無宣告:false · 實測定案 [實測](verification/xae-corrupt-file-behavior.md) | — | 1a |
| PROJECT-XML-003 | CDATA 被破壞:CDATA 內寫了 XML 跳脫 `&lt;` 等(true,本 PR 第二輪審查 B2);Declaration / ST 有 CDATA 外的一般文字;被拆成多段 CDATA(實測:XAE 自己寫的格式,不報) | project-integrity → behavior | unknown | high | true(CDATA 被提早結束 = 不 well-formed,靜默壞掉);沒包 CDATA 但合法:false(warning);多段 CDATA:**false**(XAE 自己會這樣寫) · 實測定案 [實測](verification/xae-corrupt-file-behavior.md) | — | 1a |
| PROJECT-XML-004 | 必要元素 / 屬性缺漏、元素順序與 XAE 產生的不同 | project-integrity | unknown | high | true(缺根元素 / Name / Declaration / Implementation);缺 SpecialFunc:false · 實測定案 [實測](verification/xae-corrupt-file-behavior.md) | — | 1a |
| PROJECT-KIND-001 | XML 物件種類 ≠ 宣告關鍵字 ≠ 副檔名 | project-integrity | unknown | high | true(XML 元素與宣告家族不符);副檔名 ≠ 元素:false(warning) · 實測定案 [實測](verification/xae-corrupt-file-behavior.md) | — | 1a |
| PROJECT-NAME-001 | `Name` 屬性 ≠ 宣告區物件名 | project-integrity | unknown | high | true(XAE 以 Name 屬性命名並報 C0243) · 實測定案 [實測](verification/xae-corrupt-file-behavior.md) | — | 1a |
| PROJECT-NAME-002 | 檔名 ≠ 物件名 | none | unknown | high | false(實測:XAE 以 XML Name 為準) | — | 1a |
| PROJECT-GUID-001 | 物件 / 子物件缺 `Id` | project-integrity | unknown | high | false(warning:XAE 載入並警告 Id missing) · 實測定案 [實測](verification/xae-corrupt-file-behavior.md) | — | 1a |
| PROJECT-GUID-002 | `Id` 格式不是 `{8-4-4-4-12}` 十六進位 | project-integrity | unknown | high | true(itemType 0 + schema error) · 實測定案 [實測](verification/xae-corrupt-file-behavior.md) | — | 1a |
| PROJECT-GUID-003 | 同專案 `Id` 重複(含子物件;複製檔案沒換 Id) | project-integrity | unknown | high | 同 POU 子物件:true(整個 POU 變 itemType 0);跨檔:false(warning,XAE 自動換掉其中一個並改寫檔) · 實測定案 [實測](verification/xae-corrupt-file-behavior.md) | — | 1a |
| PROJECT-GUID-004 | 全零 GUID | project-integrity | unknown | high | false(info:XAE 載入時自動重產並改寫檔) · 實測定案 [實測](verification/xae-corrupt-file-behavior.md) | — | 1a |
| PROJECT-GUID-005 | 明顯手寫的假 GUID(`a1b2c3d4-e5f6-…`、序列、重複字元) | project-integrity | no | medium | false | — | 1a |
| PROJECT-SUB-001 | 子物件結構錯(Method 無 Declaration、Property 沒有 Get 也沒有 Set、Transition 無實作) | project-integrity | unknown | high | Method / ITF Method 無 Declaration:true;Property 無 Get / Set:false(C0373 warning);Transition:未測(tcauto 不能建) · 實測定案 [實測](verification/xae-corrupt-file-behavior.md) | — | 1a |
| PROJECT-SUB-002 | 同一 POU 內子物件重名(Method / Action / Property) | project-integrity | unknown(推論 yes) | high | true(同名 Method 讓 VS2022 載入時 stack overflow 當機) · 實測定案 [實測](verification/xae-corrupt-file-behavior.md) | SA0027(Light,名稱重複) | 1a |
| PROJECT-LINEIDS-001 | `<LineIds>` 與實際行數 / 子物件不一致 | none(待查) | no | high | false(info;4026 XAE 下次存檔整段刪掉,不報錯) · 實測定案 [實測](verification/xae-corrupt-file-behavior.md) | — | 1a |
| PROJECT-COMPILE-001 | `<Compile>` 指向不存在的檔 | project-integrity | unknown | high | true(樹上出現 itemType 0 的幽靈物件,無任何錯誤) · 實測定案 [實測](verification/xae-corrupt-file-behavior.md) | — | 1a |
| PROJECT-COMPILE-002 | `<Compile>` 重複 | project-integrity | unknown | high | false(warning:XAE 容忍) · 實測定案 [實測](verification/xae-corrupt-file-behavior.md) | — | 1a |
| PROJECT-COMPILE-003 | 專案目錄下的物件檔沒列入 `<Compile>`(不會被編譯) | behavior | no | high | false | — | 1a |
| PROJECT-COMPILE-004 | `<SubType>` 與 XAE 產生的值不同 | project-integrity | unknown | high | false(warning:Designer / 缺 SubType 都照常載入) · 實測定案 [實測](verification/xae-corrupt-file-behavior.md) | — | 1a |
| PROJECT-COMPILE-005 | `<Folder Include>` 與實際目錄 / Compile 路徑不符 | none | no | high | false | — | 1a |
| PROJECT-COMPILE-006 | Include 路徑大小寫與磁碟不符、MSBuild 跳脫錯 | project-integrity | unknown | high | false(warning:大小寫不符、`%20` 都照常載入) · 實測定案 [實測](verification/xae-corrupt-file-behavior.md) | — | 1a |
| PROJECT-LIB-001 | LibraryReference / PlaceholderReference XML 結構缺必要子元素 | project-integrity | unknown | high | 缺 Namespace:true(XAE 跳 Assertion Failed 對話框);缺 DefaultResolution:見實測 · 實測定案 [實測](verification/xae-corrupt-file-behavior.md) | — | 1a |
| PROJECT-TSPROJ-001 | `.tsproj` 參照的 `.plcproj` 不存在 / 路徑不符 | project-integrity | unknown | high | true(PrjFilePath 指向不存在的 plcproj → 讀樹時 VS2022 當機) · 實測定案 [實測](verification/xae-corrupt-file-behavior.md) | — | 1a |
| PROJECT-TSPROJ-002 | PLC 專案 GUID 在 `.sln` / `.tsproj` / `.plcproj` 不一致 | project-integrity | unknown | high | false(warning:XAE 把 plcproj ProjectGuid 寫回 tsproj 的值) · 實測定案 [實測](verification/xae-corrupt-file-behavior.md) | — | 1a |
| PROJECT-TSPROJ-003 | `.TcTTO` ↔ `.tsproj` task 不一致;`PouCall` 指向不存在的 PROGRAM | behavior | unknown | high | false(PouCall 指向不存在的 PROGRAM:編譯器 C0046 / C0035 擋下;task 不一致部分未測) · 實測定案 [實測](verification/xae-corrupt-file-behavior.md) | — | 1a |
| PROJECT-ENC-001 | 行尾 / 編碼混用 | none(待查) | no | high | false(info;LF / 混用 / 無 BOM 都照常載入) · 實測定案 [實測](verification/xae-corrupt-file-behavior.md) | — | 1a |
| LINT-PARSE-* / LINT-XML-* / LINT-COVERAGE-* / LINT-SUPPRESS-* | 引擎自身 | — | — | high | PARSE: true | — | 1a |
| SCAN-TEMPFB-001 | 有狀態 FB 宣告在 FUNCTION / METHOD 的 VAR 或 VAR_TEMP | behavior | unknown(SA0167 Light 編譯後自動跑,Build 結果待 1a.9) | high | true(InfoSys 已證實暫時變數語意) | SA0167(Light,編譯成功後自動跑) | 1b |
| PROJECT-TASK-001 | PROGRAM 沒被任何 task 也沒被任何 POU 呼叫 | behavior | no(實測:沒被呼叫的 PROGRAM 有語法錯 Build 仍成功,只有 CheckAllObjects 報 [實測](verification/st-syntax-measured.md)) | high | false(必須處置) | — | 1b |
| PROJECT-TASK-002 | 同一 PROGRAM 每 cycle 執行兩次以上(兩個 task / task + POU) | behavior | no | high | true | — | 1b |
| SCAN-LOOP-001 | busy-wait:WHILE / REPEAT 迴圈內不會改變條件 | crash | no | high | true | 部分相關:SA0041(Full) | 2 |
| SCAN-FOR-001 | FOR 計數器型別上限 ≤ 常數終值(溢位 → 無窮迴圈);`BY 0`(variant,pending) | crash | warning(C0266,不擋 Build) | high | true(`BY 0`:pending) | — | 2 |
| SCAN-ARR-001 | 常數範圍 FOR 的 index 超出陣列宣告範圍(0-based 習慣) | crash / behavior | no | high | true | SA0172(Full) | 2 |
| SAFETY-ARR-001 | 常數 index 超出陣列範圍 | crash / behavior | yes(InfoSys;measured:2026-11-13 C0049 [實測](verification/st-syntax-measured.md)) | high | false(只有寫入前價值) | SA0172(Full) | 2 |
| SAFETY-DIV-001 | 除以常數 0;除數是變數且同一路徑沒有 `<> 0` 檢查 | crash(整數 / REAL `/` 實測 2026-11-13:整個 TwinCAT system 進 Exception、PLC 全停,要重新 Activate;`MOD` 變數 0 實測不 exception、結果 0,見 [runtime-semantics-measured.md](verification/runtime-semantics-measured.md) 第 7 節) | 常數 `/ 0`:measured:2026-11-13 yes(C0374);**`MOD 0`:no(編譯期與 runtime 都不擋,runtime 結果 0)**;變數:no [實測](verification/st-syntax-measured.md) | 常數 high / 變數 medium | 常數 true / 變數 false | SA0040(Full) | 2 |
| SCAN-FBCALL-001 | FB instance 被讀取但從不呼叫 | behavior | no | medium | false | — | 2 |
| SCAN-FBCALL-002 | FB instance 完全沒被引用 | none | no | high | false(info) | SA0033(Light) | 2 |
| SCAN-TIMER-001 | Timer(TON / TOF / TP 與 LTON / LTOF / LTP)/ 邊緣觸發(R_TRIG / F_TRIG)只在 IF / CASE 內呼叫 | behavior | no | medium | false | — | 2 |
| SCAN-TIMER-002 | Timer 只在 Method / Action 內呼叫,無法證明每 cycle 呼叫 | behavior | no | low | false(info) | — | 2 |
| SCAN-TIMER-004 | Timer `PT` 從未設定 / `IN` 恆為常數 FALSE | behavior | no | PT:high / IN:medium | false | — | 2 |
| SCAN-TIMER-005 | 狀態 timer(TON / LTON):只在單一 CASE 的分支內以 `IN := TRUE` 呼叫,離開時沒有 `IN := FALSE` | behavior | no | medium | false | — | 2 |
| PROJECT-SA-001 | 專案沒啟用 TE1200 Light 的關鍵規則 | behavior | no | high | false | SA0004 / 0006 / 0167 | 2(視 Phase 1a 量測) |
| SCAN-SM-001 | 狀態被賦值成 CASE 沒有的值,且 CASE 無 ELSE | behavior | no | high | false | 部分相關:SA0076(Full) | 3 |
| SCAN-MC-001 | MC FB 只在條件內呼叫 / `Execute` 設 TRUE 後從不設 FALSE | behavior | no | medium | false | — | 3 |
| SCAN-MC-002 | MC_Move* 只在單一狀態呼叫,物件內沒有 MC_Stop / MC_Halt | behavior | no | medium | false | — | 3 |
| SCAN-REF-001 | REFERENCE / POINTER 可能未初始化就解參照 | crash(推論,解參照後果未驗證) | no | medium | false | SA0039 / SA0145(Full) | 3 |
| SCAN-FBVAL-001 | FB 以值傳遞(`VAR_INPUT` 的型別是 FB) | behavior | no | high | false | 部分相關:SA0014(Full) | 3 |
| SCAN-OUT-001 | 同一輸出多處寫入 / 跨 task 寫入 | behavior | no | medium | false | SA0004 / SA0006(Light) | 3 |
| SCAN-FLOAT-001 | REAL / LREAL 用 `=` / `<>` 比較 | behavior | no | medium | false | SA0054(Full) | 3 |
| SCAN-INTDIV-001 | 整數除法結果才轉 REAL | behavior | no | medium | false | SA0020 / SA0057(Full) | 3 |
| CONTRACT-ITF-001/002 | Interface 成員缺漏 / 簽章不同 | none(推論編譯器擋) | yes(推論,待 4.0 實測) | high | 實測後定 | — | 4 |
| CONTRACT-ENUM-001/002 | 相對 baseline:enum 成員刪除 / 數值改變 | behavior(HMI / ADS / PERSISTENT 語意) | no | high | true | — | 4 |
| CONTRACT-DUT-001 | 相對 baseline:STRUCT layout 改變 | behavior | no | high | true | — | 4 |
| POLICY-* | profile 定義(SYMBOL / NAME / CALL / RETVAL / robust-solution) | 依規則 | no | high | profile 決定 | 部分:命名規則(Full) | 4 |
| POLICY-INTERLOCK-001 | profile 宣告的互鎖輸出被後面的指派覆蓋 | behavior | no | medium | profile 決定 | — | 4 |
| ST-LLM-001 | C 語言式語法(`x = 5;` 當陳述式等) | none(多數編譯器擋) | 多數 yes | high | false | — | 4 |

**severity 與 blocking**:總表 `blockable` 為 `true` 或 `pending` 的規則,預設 severity 一律 `error`、confidence `high`(D5 的 blocking 條件因此成立);`false` 的是 `warning` 或 `info`(info 只用在 SCAN-FBCALL-002、SCAN-TIMER-002、PROJECT-LINEIDS-001、PROJECT-ENC-001、PROJECT-COMPILE-005)。`blockable: true` 的意思是「偵測確定」(owner 決定 2);若規則描述的機台後果仍是推論,diagnostic 另帶 `impactBasis: "inferred"`,不影響 blocking。

## 1. AI 直接改磁碟檔造成的問題(Phase 1a)

背景:repo 的工作流允許 agent 直接改 `.TcPOU` / `.plcproj` 再 `Reset-TcSolution`(CLAUDE.md「Editing project files on disk」、`docs/troubleshooting.md`「磁碟改檔的正確做法」)。LLM 手寫 XML 很容易出錯,而 XAE 遇到這類錯誤的行為多數**未實測**。

共同規則:
- 依據:`research/tc-xml-schema-observed.md`(XAE 實際產生的結構)。結構規則只比對「語料中每個樣本都有」的元素與屬性;語料樣本不足的(例如 `.TcIO`、Property、Transition)在 Phase 1a 用 XAE 產生真實檔案後才啟用,啟用前記 `rulesNotRun`(reason `schema-not-observed`)。
- **1a.7 實測定案(2026-11-13,XAE 4026.22 / VS2022;4024 部分見該檔第 3 節)**:總表 `blockable` 欄已依 `verification/xae-corrupt-file-behavior.md` 改寫,下面各節原本寫「未驗證 / pending」的段落以該檔為準。重點:(1) XAE 的 Build **擋不住**沒被引用物件的壞檔(Build 成功,載入錯誤只在 Error List);(2) 不 well-formed、編碼宣告不符、非法 UTF-8 時物件**靜默**變成 itemType 0,Check / Build 都沒有訊息;(3) 同名 Method、`.tsproj` 指向不存在的 `.plcproj` 會讓 VS2022 當機,PlaceholderReference 缺 `Namespace` 會跳 Assertion Failed;(4) 全零 / 跨檔重複 GUID、`.plcproj` ProjectGuid 不一致、缺 Folder 宣告會被 XAE **自動改寫磁碟檔**。
- 「XAE 遇到時實際會怎樣」:每條在 tasks 1a 有一個 IDE 實測任務(只需 IDE、不需 runtime;在本機測試副本的副本上做:植入錯誤 → `Reset-TcSolution` → `Get-TcProjectTree` / `BuildProject`,記錄是否跳框、物件是否消失、Build 結果)。實測前 `blockable = pending`。
- 誤報來源:未來 TwinCAT 版本的 XML 結構變化(`ProductVersion` 不在已觀察範圍 → 結構規則降為 warning 並在 `rulesSkipped` 註明 `unobserved-product-version`)。

### PROJECT-XML-001 XML 不是 well-formed
- 機台行為:XAE 無法載入該物件(具體表現未驗證:跳框、物件消失或 Build 失敗)。
- 偵測:`XmlReader`(`DtdProcessing = Prohibit`)讀檔失敗。
- blockable true:依據是 XML 1.0 規範(不是 TwinCAT 行為),任何 XML parser 都不會接受。
- 之後所有規則對該檔不評估(記 `notAnalyzed`,reason `xml-not-well-formed`)。

### PROJECT-XML-002 編碼
- 偵測:檔頭 BOM 與 `<?xml encoding=?>` 不一致(例:UTF-8 BOM + `encoding="utf-16"`);宣告 UTF-8 但含非法 UTF-8 序列(嚴格 decoder);沒有宣告也沒有 BOM 且含非 ASCII。
- XAE 的容忍度未驗證 → pending。語料觀察到的 BOM / 宣告分布見 `tc-xml-schema-observed.md`。

### PROJECT-XML-003 CDATA 被破壞
- 機台行為:程式碼被截斷或混入 XML 片段;若 XAE 照樣載入,編譯的是被改過的程式(行為錯)。
- 偵測(依 IDE 實測定案,`verification/xae-corrupt-file-behavior.md` C02 / C03 / C05 與 `verification/xae-generated-xml.md`,XAE 3.1.4026.22,2026-11-13):(a) CDATA 內的程式碼含 `&lt;` `&gt;` `&amp;` `&quot;` `&apos;` `&#..;`(被 XML 工具多跳脫一次,編譯器看到的是跳脫文字)— variant `escaped-entity-in-cdata`,blockable true;(b) 程式碼在 CDATA 外但是合法 XML — variant `text-outside-cdata`,warning(XAE 照常讀成程式碼,C02 / C05);CDATA 被提早結束而不 well-formed 的情況是 PROJECT-XML-001(C03,XAE 靜默變成未知物件);(c) 多段 CDATA:XAE 自己存含 `]]>` 的程式碼就是 `'a]]]]><![CDATA[>b'`,**不報**,引擎串接後分析。
- XAE 載入被切壞的檔案後是否照樣編譯:未驗證(compilerCatches unknown)。

### PROJECT-XML-004 必要元素 / 屬性 / 順序
- 偵測:依 `tc-xml-schema-observed.md` 的每種物件樹(`TcPlcObject` → `POU|DUT|GVL|Itf|Task` → `Declaration` → `Implementation/ST` …),必要元素缺漏、必要屬性(`Name`、`Id`、POU 的 `SpecialFunc`)缺漏、子元素順序與觀察不同。
- 順序不同的影響未驗證 → 順序差異 warning,缺漏 pending。
- 語料觀察到的固定順序(`tc-xml-schema-observed.md` 第 10.1 節):POU = `Declaration, Implementation, Folder*, Action*, Method*, LineIds*`;Method = `Declaration, Implementation`;Action 只有 `Implementation`;DUT / GVL 只有 `Declaration`。同類成員按名稱字母排序(20/20,`SubObjectsSortedByName=True`)— 只當提示,不報錯。

### PROJECT-KIND-001 種類三方一致
- XML 物件元素(`POU` / `DUT` / `GVL` / `Itf`)、宣告關鍵字(`PROGRAM|FUNCTION_BLOCK|FUNCTION` / `TYPE` / `VAR_GLOBAL` / `INTERFACE`)、副檔名(`.TcPOU` / `.TcDUT` / `.TcGVL` / `.TcIO`)三者要一致。prototype seeded S05 命中。

### PROJECT-NAME-001 / 002
- 001:`Name` 屬性 ≠ 宣告區名稱(例:`<POU Name="FB_A">` 但宣告 `FUNCTION_BLOCK FB_B`)。XAE 以哪個為準未驗證 → pending。
- 002:檔名 ≠ 物件名。warning,不 blocking(Robust Solution NAM-001 可在 profile 升級)。

### PROJECT-GUID-001 ~ 004
- 001 缺 `Id`、002 格式錯(不是 `{8-4-4-4-12}` 十六進位;大小寫依語料觀察)、003 同專案重複(含 Method / Action / Property / Get / Set / Transition 子物件;最常見來源是複製檔案改名沒換 Id)、004 全零。
- XAE 遇到重複 / 缺 Id 的行為未驗證(可能自動重編、可能讓兩個物件互相覆蓋)→ pending。prototype seeded S04 命中。
- 語料(`tc-xml-schema-observed.md` 第 4 節):306 個 Id 全部是小寫 `{8-4-4-4-12}`、零重複。**axis 有 6 個明顯手寫的假 GUID**(例:`{a1b2c3d4-e5f6-7890-abcd-ef0123456789}`),所在檔案同時沒有 BOM、行尾是 LF,是整檔由非 XAE 工具產生 — 這正是 owner 決定 6 要抓的情況。→ PROJECT-GUID-005:序列 / 重複字元 / `a1b2c3d4` 類樣式報 warning(不擋;樣式重複的 GUID 本身不違法,但跨專案複製時撞號的機率高)。GUID version 碼不是 4 **不能**當錯誤(axis 有 80 個 v0,來源不明)。

### PROJECT-SUB-001 / 002
- 001:子物件結構不完整。Property 沒有 Get 也沒有 Set、Method 沒有 Declaration、Transition 沒有實作。語料沒有 Property / Transition → 依 Phase 1a 用 XAE 產生的樣本定義。
- 002:同一 POU 內 Method / Action / Property 重名。編譯器多半會擋(推論,未驗證);寫入前擋仍有價值。

### PROJECT-LINEIDS-001
- `<LineIds>` 記錄的子物件名稱或行數與實作不一致(手改程式碼時最常見)。
- XAE 是否重建 LineIds、不一致是否影響線上監看 / 斷點:未驗證。先定為 info,`machineImpact: none`;IDE 實測後再決定等級。
- 語料:4024 存檔的 POU 都有 `<LineIds>`,Σ(Count+1) 等於實作行數(57/58;唯一例外 bfh `FB_Winder` 差 1 行,疑似在 XAE 外改過);**4026 存檔的 19 個 POU 全部沒有 `<LineIds>`**(原因未查,axis 的 `.plcproj` 有 `WriteLineIDs=True`)→ 「缺 LineIds」不可當錯誤,只檢查「有的時候是否一致」。

### PROJECT-COMPILE-001 ~ 006
- 001 指向不存在的檔、002 重複(MSBuild unescape + `GetFullPath` 正規化後比較)、003 專案目錄下的物件檔沒列入(behavior:新寫的 POU 根本不會被編譯;不 blocking,可能刻意保留)、004 `<SubType>` 與 XAE 產生的值不同、005 `<Folder Include>` 與實際不符(info;只報「Compile 用到的目錄沒有 Folder 宣告」— 語料 bfh 有 4 個 Folder 宣告在磁碟上沒有目錄,XAE 允許,不報)、006 Include 大小寫與磁碟不符或跳脫錯誤。
- prototype seeded S01 / S02 / S03 命中;語料 0 誤報。

### PROJECT-LIB-001
- LibraryReference / PlaceholderReference / PlaceholderResolution 的必要子元素(依語料觀察)缺漏。pending。

### PROJECT-TSPROJ-001 ~ 003
- 001:`.tsproj` 參照的 `.plcproj` 不存在或路徑與實際不符。
- 002:PLC 專案 GUID 在 `.sln` / `.tsproj` / `.plcproj` 三處不一致(三處各自的欄位依 `tc-xml-schema-observed.md`)。
- 003:`.plcproj` 列了 `.TcTTO` 但 `.tsproj` 沒有對應 task(或反之);`PouCall` 指向不存在的 PROGRAM。cycle time / priority 的範圍檢查(XAE 離線照收、無警告,`docs/known-limitations.md`「AddPlcTask」)併入此規則,warning。
- 全部 pending。

### PROJECT-ENC-001 行尾 / 編碼混用
- 同一檔案 CRLF 與 LF 混用;同一專案不同檔的編碼不一致。XAE 顯示是否異常未驗證 → info,實測後決定是否保留。
- 語料:XAE 寫的 Tc* 物件檔一律 UTF-8 BOM + `encoding="utf-8"` + CRLF;axis 有 11 個檔缺 BOM / 用 LF / 混用,全部是 XAE 外寫入的。這是「檔案被外部改過」的強訊號:建議 info 並提示「`Reset-TcSolution` 讓 XAE 重新載入」。`.plcproj` 有沒有 XML 宣告 / BOM 兩個專案不同(bfh 沒有),**不能**當規則。

## 2. 機台行為類

### SCAN-TEMPFB-001 有狀態 FB 是暫時 instance(Phase 1b,blocking)
- 機台行為:METHOD 的 `VAR` 每次呼叫重新初始化 — InfoSys:"TwinCAT re-initializes all variables and function blocks, which you have declared in a method, with each call of the method."(https://infosys.beckhoff.com/content/1033/tc3_plc_intro/2530307467.html);`VAR_TEMP` 同樣("TwinCAT reinitializes temporary variables each time the function block is called.",https://infosys.beckhoff.com/content/1033/tc3_plc_intro/2528781963.html)。推得:TON 永遠到不了 Q,R_TRIG 只要 CLK 為 TRUE 每次都觸發,CTU 每次重新從 0 開始、累計不超過 1(以上是依 InfoSys 語意的推論)。`VAR_TEMP` 的頁面只寫 function block;PROGRAM 的 `VAR_TEMP` 由「Use of function blocks」涵蓋:"Temporary instances are those that are declared in a method or a function or as VAR_TEMP, and are therefore reinitialized in each processing cycle or with each block call."(https://infosys.beckhoff.com/content/1033/tc3_plc_intro/12050023819.html,2026-11-13 查證)。Property Get / Set 的 `VAR`:InfoSys 只寫 "a property can contain local variables"(2530335371.html),**沒有**重新初始化的出處 → 實作為 warning variant `accessor-var`(不 blocking,仍進 `unresolved[]`)。FUNCTION 的 `VAR` 同樣:"TwinCAT re-initializes all variables that you have declared in a function each time the function is called."(https://infosys.beckhoff.com/content/1033/tc3_plc_intro/2530284939.html)。
- 偵測:只看宣告區。型別在 FB 型別目錄的「有狀態」清單(`src/TwinCATAutomation/Private/Lint/TypeCatalog.json` v1:Tc2_Standard 的 TON / TOF / TP / LTON / LTOF / LTP / R_TRIG / F_TRIG / CTU / CTD / CTUD / RS / SR,每個附 InfoSys 頁;profile `typeCatalog.stateful`)且宣告在 FUNCTION `VAR`、METHOD `VAR`、任何 `VAR_TEMP`(含 PROGRAM / FB)。METHOD 的 `VAR_INST`、FB `VAR`、`VAR_STAT`、`VAR_INPUT` / `VAR_IN_OUT`、`POINTER TO` / `REFERENCE TO` 不報。`ARRAY[..] OF TON` 與 `Tc2_Standard.TON` 照報。專案 `TYPE T : TON` alias、STRUCT / UNION 成員(含巢狀、ARRAY)、專案 FB 的 `VAR` / `VAR_STAT` / 輸入輸出 / METHOD `VAR_INST` 與 `EXTENDS` 鏈遞移地含有狀態型別、`STRUCT EXTENDS` 的基底成員 → 有狀態(PR #283 審查 SF1 / SF2 與驗證 N2 / N5;循環參照有防護);不含的專案 FB → `rulesSkipped project-type:<名稱>`,STRUCT 成員判不出 → `struct-type:<名稱>`。**blocking 範圍(審查 SF3)**:TypeCatalog v2 每個有狀態型別帶 class;timer(TON / TOF / TP / LTON / LTOF / LTP)與 profile `typeCatalog.stateful` → blocking;edge / counter / bistable(R_TRIG / F_TRIG / CTU / CTD / CTUD / RS / SR)→ 必須處置的 warning,理由:12050023819 原文 "It is therefore only rarely useful to create an instance as a temporary variable."(不是一定錯,一次呼叫內用完的 trigger / counter 合法);STRUCT 成員裡的 FB → warning(「FB 可當 STRUCT 成員」InfoSys Structure 頁沒有明文;實測 2026-11-13(XAE 4026.22 / VS2022,本機 UmRT;[verification/runtime-semantics-measured.md](verification/runtime-semantics-measured.md) 第 1 節):Build 成功、runtime 正常計時,1 s 後 `Q = TRUE`。是否因此把 STRUCT 成員的 timer 升為 blocking 由 owner 決定,目前仍是 warning)。宣告區有條件 pragma 時,`{IF}` 區外的變數照常評估。**實作差異(Phase 1b,owner 2026-11-13 指示)**:Tc2_MC2 FB 只列型別(`typeOnly`,規則另議)→ `rulesSkipped` `type-only:<型別>`,不報;專案自己的 FB 預設不算有狀態(要 profile `typeCatalog.stateful` 列出)。目錄外的型別 → `rulesSkipped` `unknown-type:<型別>`,不用名稱前綴猜。宣告區 notAnalyzed(條件 pragma 等)→ 不評估、記 `rulesSkipped`。
- 誤報來源:刻意在 Method 內每次重建、只用一次的 FB(極少見);型別目錄把無狀態 FB 列成有狀態。
- TE1200:SA0167(Light)。InfoSys:Light "automatically executed following the successful compilation process",規則違反以 error 出現在 Error List(https://infosys.beckhoff.com/content/1033/tc3_plc_intro/2527107467.html)。所以 Build 成功後 Error List 可能已經有 SA0167 — `BuildProject` 的 `errorItems` 是否包含、Build 結果是否因此變成失敗,由 Phase 1a(tasks 1a.9)量測。本規則的價值:`LintCandidate` 寫入前就擋、磁碟改檔後不需 IDE、Light 結果沒進 `errorItems` 的情況。
- prototype 漏抓的反例(review 第二輪 6-5):`METHOD M_Wait VAR ton : TON; END_VAR ton(IN:=TRUE, PT:=T#2S);` 舊的 SCAN-TIMER 規則不報,本規則要報。

### PROJECT-TASK-001 PROGRAM 永遠不執行(Phase 1b,必須處置)
- 機台行為:PROGRAM 沒掛在任何 task 的 `PouCall`,也沒被任何可達的 POU 呼叫 → 整段邏輯不跑。Build 照樣成功(實測 2026-11-13:沒掛 task、沒被呼叫的 PROGRAM 有語法錯,`BuildProject` 成功 0 errors,只有 `CheckAllObjects` 報,[verification/st-syntax-measured.md](verification/st-syntax-measured.md) 第 2 節)。
- 偵測(PR #283 審查 SF4 後):只認**本體**可達 —— task `PouCall` 或從可達 POU 呼叫 `P()`;只呼叫 `P.ActionX()` / `P.MethodX()` → 報 variant `action-only`,只在這種 PROGRAM 本體裡被呼叫的 PROGRAM 也不可達(驗證 N3)(本體不執行:實測 2026-11-13(XAE 4026.22 / VS2022,本機 UmRT;[verification/runtime-semantics-measured.md](verification/runtime-semantics-measured.md) 第 2 節):PROGRAM 與 FB 只呼叫 Action 時本體計數器不動、Action 計數器每 cycle +1;Action 頁 [2530340747](https://infosys.beckhoff.com/content/1033/tc3_plc_intro/2530340747.html) 只有呼叫語法,沒寫本體)。只在 `{IF}` 區內被呼叫 → `rulesSkipped call-graph-incomplete`;PROGRAM 被當變數型別 → `rulesSkipped program-used-as-type`。原寫法:從每個 `.TcTTO` 的 `PouCall` 出發建呼叫圖(FB 內呼叫 PROGRAM 也算),不可達的 PROGRAM 報出。只讀取 `P.var` 不算呼叫。FB 型別:在可達 POU、GVL、DUT 裡宣告就算可達(over-approximation,只會讓 001 更安靜)。PROGRAM 名稱出現在 linter 讀不了的部分(CFC / SFC 的那段原始 XML、條件 pragma 段落、壞檔、視覺化)→ `rulesSkipped` `call-graph-incomplete:<物件>`;某個 `PouCall` 指向不存在 / 非 PROGRAM 的 POU(TSPROJ-003,編譯器會擋)→ `rulesSkipped` `pou-call-unresolved`;專案沒有任何 `.TcTTO`(library)→ `rulesNotRun` `no-task`。
- 語料實測(2026-11-13):axis 的 `TestCam` PROGRAM 沒被 task 也沒被任何 POU 呼叫 → 會報。它是保留的 PoC 測試程式,不是 bug。因此**不 blocking**,但 `machineImpact: behavior` → 進 `unresolved[]`,agent 必須改程式或寫理由 suppress。
- 誤報來源:刻意保留的測試程式(語料 1/1 是這種);只在條件編譯分支呼叫(記 notAnalyzed)。

### PROJECT-TASK-002 PROGRAM 每 cycle 執行兩次以上(Phase 1b,blocking)
- 機台行為:同一 PROGRAM 被兩個 task 的 `PouCall` 呼叫,或被 task 呼叫又被可達的 POU 呼叫 → 每 cycle 執行兩次,內部 timer / trigger / counter 被重複呼叫(「每 task 各執行一次本體、共用變數」已實測,第 3 節;timer 每 cycle 被評估兩次、R_TRIG 在第二次呼叫時 Q 變回 FALSE 是依 IEC 語意的推論)。跨 task 時還有並行存取。
- 偵測:同上呼叫圖。來源 = 每個 task `PouCall` + 每個從 task 可達、呼叫 `P()` 的 PROGRAM(同一 program 內的多個呼叫點算一個來源,所以兩個互斥分支各呼叫一次不報)。實作的 variant(第一輪 review 後):`two-tasks`、`task-and-program`、`two-programs`(「確定」來源 ≥ 2,blocking;確定 = task PouCall,或「確定每 cycle 執行」的 PROGRAM 在 body 無條件呼叫;確定每 cycle 執行 = 在 task 上,或被這樣的 PROGRAM 無條件呼叫)、`task-twice`(同一 task 兩個 PouCall,blocking)、`repeated-call`(同一 program body 兩次以上無條件、敘述層級的 `P()`;審查 SF5 後只有被呼叫的 PROGRAM 遞移地持有有狀態 FB 才 blocking,否則是合法的參數化寫法 → warning)、`possible-double-call`(來源 ≥ 2 但有條件 / 迴圈 / Action / 不確定執行的呼叫者,或同一呼叫者兩個不在同一 IF / CASE 不同分支的呼叫點,或迴圈內呼叫 → warning,仍進 `unresolved[]`)、`fb-or-function-caller`(任一呼叫者是 FB / FUNCTION → warning)。`{IF}` 區內的呼叫視為不確定,區外照算。呼叫點在 linter 讀不了的段落 → `rulesSkipped` `call-graph-incomplete`(與其他 notAnalyzed 一致,不讓結果 incomplete)。
- 語料:axis 的 `AxisInterface_Type01` 被 `Main`(task)與 `TestCam` 呼叫,但 `TestCam` 不可達 → 不報;若有人把 `TestCam` 掛上 task 就會報。這個例子說明規則必須依可達性判斷。
- blockable true(判斷確定;owner 決定 2):理由 = 確定性的結構事實 + 推論的後果。被兩個 task 或兩個可達 program 呼叫是從檔案確定的事實;InfoSys 只有 FB 的 "Access from several task contexts to one function block is not allowed."([12050040971](https://infosys.beckhoff.com/content/1033/tc3_plc_intro/12050040971.html)),同一 PROGRAM 掛兩個 task 時 InfoSys 查不到說明,但實測 2026-11-13(XAE 4026.22 / VS2022,本機 UmRT;[verification/runtime-semantics-measured.md](verification/runtime-semantics-measured.md) 第 3 節)已量到:Build / Activate 都成功、沒有任何 warning;兩個 task 各自每 cycle 執行一次本體,共用同一份 PROGRAM 變數(`nCount` = 兩個 task 次數之和)。「會造成什麼」(timer / trigger 被兩個節拍呼叫、跨 task 並行存取的後果)仍是依 IEC 呼叫語意的推論;實作的 diagnostic 目前帶 `impactBasis: inferred`,是否改 `measured`(事實部分已實測,後果部分是推論)由 owner / main 決定。呼叫者是 FB / FUNCTION 時執行次數不確定 → 只警告。刻意的雙呼叫只能用 profile `suppressions[]` 排除(design.md Risks)。
- 語料(2026-11-13):axis 原樣不報;把 `TestCam` 加進 `PlcTask` 的 `PouCall` 的變種 → `AxisInterface_Type01` 報 `possible-double-call`(warning:Main 無條件呼叫,TestCam 在 `IF testFB = 14` / `IF testFB = 15` 內各呼叫一次 —— 測試模式下確實每 cycle 跑兩次,是真問題;因為是條件呼叫,不算「確定」,不 blocking);bfh 不報。

### SCAN-LOOP-001 busy-wait(Phase 2,blocking)
- 機台行為:`WHILE NOT bSensor DO END_WHILE`。同一 cycle 內輸入不會更新,迴圈不會結束 → task 卡住、cycle overrun / watchdog。task 的順序有出處:InfoSys TwinCAT real-time(https://infosys.beckhoff.com/content/1033/tc3_grundlagen/6828869003.html)"This makes the current input values available to the PLC application (input update), followed by processing of the application program (cycle update). Finally the results are written to the outputs (output update)." —「程式執行中輸入不會再更新」是由這個順序推論,未實測。LLM 帶循序程式思維時最典型的錯。
- 偵測:WHILE / REPEAT 的條件中所有變數在迴圈本體內都沒被寫入、沒有 `EXIT` / `RETURN` / `JMP`、沒有指標 / REFERENCE 寫入,而且本體的呼叫改不到條件:只呼叫型別目錄(`TypeCatalog.json` + profile `typeCatalog`)裡的 FB instance 或 IEC 標準函式 / 型別轉換,且條件變數沒有交給任何呼叫(任何參數、`ADR`、`REF=` 來源)。符合以上條件就是 confidence high(與條件變數種類無關;`WHILE NOT x DO END_WHILE` 的 `x` 是一般變數也一樣)。例:`WHILE NOT bDone DO rt(CLK := TRUE); n := n + 1; END_WHILE` → blocking。條件含 `AT %I*` 或 FB 輸出只是最常見的形態,寫進 message 方便理解(依條件種類:輸入 / FB 輸出 / 其他變數不加說明)。
- 判斷不了的呼叫(第二輪審查 B1,PR #284):條件變數交給了呼叫(例外(#286 N5):交給 Tc2_Standard 有狀態 FB 的具名輸入參數 `名稱 := 運算式` 只是讀取,不算;輸出 `=>`、位置引數、`ADR` / `REF=`、其他 FB 照舊),或本體有專案函式 / FB、method、action、陣列元素 / 指標呼叫、未知型別 → 不報,記 `rulesSkipped` reason `call-in-body`;條件本身含呼叫 → `call-in-condition`。不得靜默通過(原定義「本體有呼叫就不報」是 fail open 的來源,已改)。
- 已知限制(PR #284 第四輪驗證 nit 2 / 3,保留):`fb-wait-loop` 不分 FB 種類,CTU / R_TRIG 這類在同一 cycle 內輸出就會變的 FB 也報(warning,必須處置);SAFETY-DIV-001 的守衛方向只認 `d <> 0` / `d > 0` / `d = 0` 寫在左邊,`NOT (d = 0)`、`0 <> d` 與 AND_THEN / OR_ELSE 混用的優先序不判斷,當成有守衛(info,不擋)。
- variant `fb-wait-loop`(第二輪審查 S1,warning、不擋、進 `unresolved`):條件讀某個型別目錄 FB instance 的輸出,本體又呼叫同一個 instance(`WHILE NOT mc.Done DO mc(Axis := ax, Execute := TRUE); END_WHILE`、`WHILE NOT fb.Q DO fb(IN := TRUE, PT := T#1S); END_WHILE`)= 在同一個 cycle 內等 FB 完成。同一 cycle 內反覆呼叫能不能讓輸出改變,InfoSys 沒寫:AXIS_REF 頁只說 NcToPlc "Data structure which is cyclically exchanged between PLC and NC"、Status "has to be updated through the PLC program"(https://infosys.beckhoff.com/content/1033/tcplclib_tc2_mc2/70132363.html);TON 頁只說 "the time in milliseconds is counted up in ET"(https://infosys.beckhoff.com/content/1033/tcplclib_tc2_standard/74406539.html)。未驗證(tasks 2.10 UmRT 實測);不論哪種,結果都是無窮迴圈或整個 task 卡在等待時間。專案 FB 這樣呼叫 → `call-in-body`(可能是合法的逐次計算)。
- 誤報來源:另一個 task 在其他 core 改條件變數(仍然是錯誤設計);本體透過指標改條件(上面已排除)。
- TE1200:沒有直接對應(SA0041「loop-invariant code」不同)。
- cycle overrun 後果(只查文件,未測;[runtime-semantics-measured.md](verification/runtime-semantics-measured.md) 第 10 節):"If the defined cycle time of a task is exceeded, processing of the \"old\" cycle continues in the next cycle. In addition, the task exceed counter is incremented." / "...several cycles may be lost."(https://infosys.beckhoff.com/content/1033/tc3_grundlagen/6828869003.html);Task tab "Watchdog Cycles"、"Warning by exceeding"(https://infosys.beckhoff.com/content/1033/tc3_system/5210416139.html)。依此,cycle 不結束時後續 cycle 全部遺失、只累加 exceed counter / 警告;「同一 cycle 永遠不結束時 runtime 會不會強制中止、會不會停 PLC」**查不到、未實測**(會卡死 UmRT)。
- 出處(查 2026-11-13):WHILE 頁 "If the Boolean expression never takes the value FALSE, the instructions are repeated continuously, causing a runtime error."(https://infosys.beckhoff.com/content/1033/tc3_plc_intro/9007201783032715.html);REPEAT 頁同義(https://infosys.beckhoff.com/content/1033/tc3_plc_intro/9007201783038091.html)。「同一 cycle 內輸入不更新」InfoSys 沒有專述,是 PLC scan 模型的推論。
- **loop-invariant 來源(#286 第 2 項,owner 決定;實作 `LintRules2a.cs` `InvariantFed` / `InvariantSources`,測試 `tests/Unit/lint-rules-2a.ps1` `I-S2*`)**:迴圈本體**有**寫入條件變數,但每一個寫入的值只來自「迴圈內每一 pass 都相同」的來源、且包住該寫入的 IF / ELSIF / CASE 條件也只由這類來源組成,本體又沒有 EXIT / RETURN / JMP 與可能改變來源的呼叫 → 每一 pass 算出同一個條件,無窮迴圈。來源清單:(1) 字面值 / 常數(`VAR CONSTANT`、qualified GVL 常數)/ enum 成員;(2) `AT %I*` 輸入(變數本身或 GVL 內);(3) 型別目錄 FB instance 的輸出,而該 instance 在迴圈本體沒被呼叫;(4) 迴圈本體沒寫入、也沒交給呼叫的變數;(5) 只用上述來源的 IEC 標準函式 / 型別轉換。variant:`invariant-write`(blocking,不含 `%I*` 來源)、`invariant-input-write`(含 `%I*` 來源:**warning、不 blocking、進 `unresolved[]`、`requiresDisposition`**;理由是「輸入在程式執行中保持不變」InfoSys 沒有說明,**未驗證**,見下)。只有字面值 / 常數的寫入不報(第一次寫入後的值已知,可能正好結束迴圈,例:`st.Q := TRUE`)。證明不了 → 不報、記 `rulesSkipped`,reason:`possible-alias`(REFERENCE / POINTER / VAR_IN_OUT / `^`、`%Q` / `%M` 位址可能與別的變數重疊)、`call-in-body`(來源交給呼叫)、`call-result-source`(來源是函式呼叫結果)、`written-element-may-be-the-condition`、`condition-write-not-analysed`(寫入在 FOR / TRY 內)、`direct-address-source`(直接位址 `%IX0.0` 當來源)、`name-unresolved` 等。反例不報:搜尋迴圈(`bFound := arr[i] = nKey; i := i + 1`)、來源在迴圈內被寫入、來源是迴圈有呼叫的 FB 的輸出。
- **`%I*` 來源為何只是 warning**:2026-11-13 以 WebFetch 讀 [6828869003](https://infosys.beckhoff.com/content/1033/tc3_grundlagen/6828869003.html) 與 WebSearch(限 infosys.beckhoff.com)查「process image 在 task cycle 開始時更新、程式執行中不變」:**未找到明文**。該頁只寫 "Copying of the inputs to the process images of the runtime modules called by the task" 與 "This makes the current input values available to the PLC application (input update), followed by processing of the application program (cycle update)",另寫 "The PLC runtime modules independently perform an input and output update."(為與 TwinCAT 2 相容,PLC runtime module 直接更新輸入輸出)。「程式執行中輸入不變」只是順序推論,且 PLC runtime module 有自己的 I/O 更新,**未驗證**,所以 `%I*` 來源降為 warning + 必須處置(message 與 `LintRules2a.cs` 一致)。
- 實作(PR #284):寫入 = `:=`、`S=`、`R=`、`REF=`、`=>`(呼叫的形式參數 `fb(IN := x)` 不算寫入 `IN`);條件 / 寫入對象可能別名(REFERENCE、VAR_IN_OUT、POINTER、`THIS^`)→ `rulesSkipped possible-alias`;`WHILE TRUE` / `UNTIL FALSE` 無 EXIT → 報。語料 8 個 WHILE 全部在本體寫入條件變數,0 筆,第二輪審查修正後也沒有新增 `rulesSkipped`。

### SCAN-FOR-001 FOR 溢位(Phase 2,blocking)
- 機台行為:`i : BYTE; FOR i := 0 TO 255 DO` 終值等於型別最大值,最後一次遞增溢位回 0 → 無窮迴圈。InfoSys FOR 頁:"The <end value> must not have the same value as the upper bound of the data type of the counter."(https://infosys.beckhoff.com/content/1033/tc3_plc_intro/2528280971.html);編譯器警告 C0266(https://infosys.beckhoff.com/content/1033/tc3_plc_intro/21630340363.html)。**編譯器只出 warning,Build 仍成功**,所以本規則仍擋(blocking)。`BY 0`:編譯器不擋、沒有 warning;runtime 計數器不前進、迴圈自己不會結束,無守衛時為同一 cycle 內的無窮迴圈(實測 2026-11-13(XAE 4026.22 / VS2022,本機 UmRT;[verification/runtime-semantics-measured.md](verification/runtime-semantics-measured.md) 第 6 節,`FOR i6 := 0 TO 10 BY 0` 靠自加的 1000 次上限 EXIT 才離開,`i6` 停在 0)。
- 偵測:計數器型別(BYTE / USINT / SINT / WORD / UINT / INT / …)的上限 ≤ 常數終值(含 CONSTANT 展開),負步長對應下限。`BY` 是常數 0 另列 `variant: by-zero`;行為已實測(上面,第 6 節),但目前實作仍標 pending,`by-zero` 要不要定為 blocking 由 owner 決定(實測結果支持 blocking:編譯器不擋且迴圈不會結束)。
- 誤報來源:幾乎沒有(本體內 EXIT 可能讓它結束 → 本體有 EXIT 時降為 warning)。
- InfoSys 補充(查 2026-11-13):TwinCAT 2 FOR 頁明寫 "if the variable counter is of type SINT, and if <END_VALUE> is 127, you get an endless loop."(https://infosys.beckhoff.com/content/1033/tcplccontrol/925251083.html);`BY 0`、迴圈內改計數器:InfoSys 查無(`BY 0` 見上,已實測)。
- 實作(PR #284):計數器 SINT~LWORD;終值 / 步長不是常數、計數器在本體被寫入或以 bare 參數傳給非 IEC 標準函式的呼叫 → `rulesSkipped`。步長不是 1 時的跨越溢位(variant `step-overflow`):最後一個 ≤ 終值的計數值 + 步長 > 型別上限(負步長對下限)→ blocking(第二輪審查 N5)。依據 FOR 頁 "Whenever the <instructions> have been executed, the <counter> is automatically incremented by the step size" 與 "The counter is checked before each loop pass" —— 計數器不可能在不離開型別範圍的情況下超過終值;溢位後回繞是由步長 1 的情況推論,未實測。`BYTE 0 TO 254 BY 2` 報,`0 TO 253 BY 2`、`0 TO 254 BY 3` 不報;本體有 EXIT 時仍降 warning。語料 17 個 FOR,評估 10、跳過 7,0 筆。

### SCAN-ARR-001 常數範圍迴圈越界(Phase 2,blocking)
- 機台行為:`a : ARRAY[1..10] OF INT; FOR i := 0 TO 9 DO a[i] := 0;`(0-based 習慣)→ 越界存取。CheckBounds 是隱式檢查函式,要專案加入才有(https://infosys.beckhoff.com/content/1033/tc3_plc_intro/2530356875.html);沒加時越界的後果 InfoSys 沒寫 → 「蓋到相鄰變數」是推論,未驗證:變數索引的越界讀 / 寫在實測 2026-11-13(XAE 4026.22 / VS2022,本機 UmRT;[verification/runtime-semantics-measured.md](verification/runtime-semantics-measured.md) 第 9 節)標 NOT RUN(Exception 後 lifecycle block);同節實測常數索引的讀、寫都被編譯器擋(C0049)。
- 偵測:FOR 上下限是常數(含 CONSTANT),本體內出現 `a[i]` / `a[i ± k]`,本體不改 `i`,與 `a` 的宣告範圍比對。多維陣列逐維比。
- 誤報來源:`ARRAY[*]`(可變長度,不評估);index 在 IF 守衛內(`IF i >= 1 THEN a[i]`)→ 有守衛就降為 warning。
- TE1200:SA0172(Full)— 客戶沒有。
- 實作(PR #284):index `i`、`i ± k`、`k - i`;陣列在 section / POU / 基底 FB / GVL(含 qualified_only)宣告;STRUCT 成員陣列、`ARRAY OF ARRAY` 第二層 → `rulesSkipped`(不猜)。守衛 = 包住存取、條件提到 `i` 的 IF / CASE / WHILE,或條件讀到「迴圈本體內在存取之前由含 `i` 的運算式算出的變數」(`b := i > 0; IF b THEN a[i]`,可遞移,第二輪審查 B2),或本體有 EXIT / CONTINUE / RETURN → variant `guarded`(warning,必須處置)。選 warning 不選 info:守衛沒有被求值,`b := i < 100` 這種守衛照樣放行越界值,看一眼條件就能處置;降成 info 會讓 agent 略過真的越界。條件與 `i` 無關(`IF x > 0 THEN a[i]`,`x` 不由 `i` 算出)仍 blocking。IEC 標準函式 / 型別轉換的參數視為傳值。語料常數範圍迴圈全在範圍內,0 筆。

### SAFETY-ARR-001 / SAFETY-DIV-001(Phase 2)
- ARR-001:常數 index 超出宣告範圍(seeded S17)。InfoSys CheckBounds 頁:"A consistently faulty array index results in a compiler error."(https://infosys.beckhoff.com/content/1033/tc3_plc_intro/2530356875.html)→ 編譯器擋,只有寫入前價值,不進 `unresolved`;實測 2026-11-13(XAE 4026.22,[verification/st-syntax-measured.md](verification/st-syntax-measured.md) 第 3 節的寫入、[runtime-semantics-measured.md](verification/runtime-semantics-measured.md) 第 9 節的讀取):常數索引 `a[11]`、`a[0]`(範圍 1..10)的讀與寫都被 C0049 擋下。SCAN-ARR-001(迴圈變數 index)不受影響:"The check is only performed with a variable array index."
- DIV-001 同一運算式內的檢查(第二輪審查 S5):只有在除法前面是 `AND_THEN` / `OR_ELSE`,或檢查位於 `SEL` 的 G 參數、除法在 IN0 / IN1 時才算守衛;`AND` / `OR` 不算(巢狀 IF 照算)。InfoSys AND_THEN "In contrast, TwinCAT always evaluates all operands if the IEC operator AND is used."(https://infosys.beckhoff.com/content/1033/tc3_plc_intro/2528923787.html);SEL "TwinCAT does not compute an expression that precedes IN0 if G = TRUE." / "... IN1 if G = FALSE."(https://infosys.beckhoff.com/content/1033/tc3_plc_intro/2528956043.html)→ `SEL(d = 0, x / d, 0)` 不報。
- DIV-001:除以常數 0(seeded S16):blocking(若實測編譯器已擋,價值只剩寫入前);除數是變數且同一 IF 路徑上沒有 `<> 0` / `> 0` 檢查:info medium,不擋、不進 `unresolved[]`(Phase 2a 語料實測 47 筆多為設定值除數,見 `LintCore.cs` SAFETY-DIV-001 Limits;原設計為 warning),`machineImpact: crash` 對整數 `/` 與 REAL `/` 已實測確認(實測 2026-11-13(XAE 4026.22 / VS2022,本機 UmRT;[verification/runtime-semantics-measured.md](verification/runtime-semantics-measured.md) 第 7 節,見下);`MOD 0` 實測不 exception(靜默得 0),`machineImpact: crash` 對 MOD 不成立。
- TE1200:SA0172 / SA0040(Full)— 客戶沒有。
- 除以零的 runtime 出處(查 2026-11-13):DIV 頁 "In TwinCAT, division by zero always leads to an exception and the corresponding task is stopped."(https://infosys.beckhoff.com/content/1033/tc3_plc_intro/2528875403.html;同頁 permitted data types 含 REAL / LREAL);MOD 頁 "The behavior when dividing by zero or MOD 0 can vary depending on the target system!"(https://infosys.beckhoff.com/content/1033/tc3_plc_intro/2528880779.html)。浮點:Task tab "Thus an exception is generated for division by zero and \"Invalid Operations\""(https://infosys.beckhoff.com/content/1033/tc3_system/5210416139.html,Floating Point Exception 選項)。
- 除以零的 runtime 實測(實測 2026-11-13(XAE 4026.22 / VS2022,本機 UmRT;[verification/runtime-semantics-measured.md](verification/runtime-semantics-measured.md) 第 7 節,本專案 task 為預設 Floating Point Exception 設定):(a) DINT `/` 變數 0:PLC exception,Error List `Exception Code: 0xc0000094, Integer divide by zero`,port 851 = Stop、port 10000 = **Exception**(adsState 19),兩個 task 都停;(b) REAL `/` 變數 0.0:`Exception Code: 0xc000008e, FPU zero divide`,狀態同 (a);(c) DINT `MOD` 變數 0:**不 exception**,PLC 照跑,結果 0;(d) LREAL `/`:NOT RUN。恢復:`SetPlcState Reset` / `Run` 都救不回來(TwinCAT 自己重啟到 Config),需要重新 Activate(`EnableConfig Force`),第 7.1 節。REAL 的結果取決於 task 的 Floating Point Exception 設定,關掉時是否得 INF / NaN 未測。所以 `constant-zero-div` / `unchecked-variable-divisor` 的後果是整個 TwinCAT system 進 Exception(PLC 全停),`constant-zero-mod` 的後果是靜默得到 0(邏輯錯、不停機)。
- 實作與決定(PR #284):variant `constant-zero-div`(字面值 `/ 0`:blocking,finding 標 compilerCatches yes,不進 `unresolved`;具名常數 = 0:blocking,編譯器擋不擋未實測)、`constant-zero-mod`(blocking,編譯器不擋 → 進 `unresolved`)、`unchecked-variable-divisor`(**info、永不 blocking、不進 `unresolved`**)。`machineImpact` 欄位目前整條規則都是 `crash`,依實測 `constant-zero-mod` 應為 `behavior`(靜默得 0);本 PR 不改欄位與等級,建議見 PR 回報。變數除數的語料逐筆判讀(axis 46 + bfh 1 = 47 筆;第二輪審查 S5 後 axis 47、共 48 筆,新增的是 `FB_CorrugatedLiftingFixedAccDistance.StartAction` 的 `SyncPrintDistance_deg / SyncPrintDistance_deg`,輸入 SyncPrintDistance 為 0 時除以 0,歸「輸入為 0」類):真問題候選 1、呼叫端輸入為 0 時才發生 10、設定值衍生(直徑 × PI 等)35、誤報 2 —— 「確定是 bug」precision 約 1/48,當必須處置的 warning 會逼 agent 大量 suppress,違反「合法程式不得誤擋」,所以降為 info;profile 把 severity 調成 warning 時重新進 `unresolved`。為此 design.md D6 的 `unresolved[]` 改為不收 info。

### Phase 2b:SCAN-FBCALL-001 / 002、SCAN-TIMER-001 / 002 / 004 / 005(PR #289)

實作 `src/TwinCATAutomation/Private/Lint/LintRules2b.cs`,metadata 在 `LintCore.cs` 的 Phase 2b 區塊,測試 `tests/Unit/lint-rules-2b.ps1`。六條都 `requires: type-catalog`(型別目錄 `TypeCatalog.json` + 專案 FB + profile `typeCatalog`;目錄外的型別不用名稱前綴猜,見 SCAN-TEMPFB-001)。共同範圍:只看宣告在 FUNCTION_BLOCK / PROGRAM 的 `VAR` / `VAR_STAT` 的 instance(不看 INPUT / OUTPUT / IN_OUT、POINTER / REFERENCE、GVL、METHOD 內的區域變數)。「呼叫」= 在 owner 的本體、Action、Method、Property accessor 任何一處出現 `inst(...)`(不檢查那段程式碼會不會被執行,除非規則另述)。

**共同的 `rulesSkipped` reason(格式 `<reason>:<instance>`,每條規則各記一筆;任何一種「instance 可能在 owner 的 ST 以外被使用」都不報,不得靜默通過)**:

| reason | 意思 |
|---|---|
| `passed-or-aliased` | instance 被當參數、`ADR(inst)`、`REF=` 來源、指派給 interface 或被整個指派(`f(inst)`、`itf := inst`、`inst := other`)→ 可能在別處被呼叫 |
| `qualified-access` | 專案任何地方 `.` 後面出現同名(`PRG.inst`、`fb.inst`)|
| `inherited-use` | 有 FB `EXTENDS` 該 owner,衍生 FB 可能呼叫基底的 instance |
| `unanalysed-part` | 名稱出現在 linter 讀不了的段落(CFC / SFC 原始 XML、壞檔、視覺化)|
| `referenced-in-declaration` | 名稱出現在別的宣告初值(`ADR(inst)`、`REFERENCE TO ... := inst`、FB_init 引數)|
| `shadowed-name` | 同一 POU 的 Method 區域變數同名 |
| `array-instance` | `ARRAY OF FB` |
| `type-alias:<型別>` / `unknown-type:<型別>` | 專案 `TYPE T : TON` alias 或 STRUCT / ALIAS 型別、目錄外的型別 |
| `declaration-not-analyzed`、`call-site-not-found`、`nested-member-access` | 宣告區 / 呼叫點 / `inst.a.b`、`inst.a[...]` 無法分析 |
| owner 有問題的段落 | 條件 pragma(`{IF}`)、不支援的語法等 → 該物件不評估 |

「每條規則各記一筆」= 依規則適用範圍:SCAN-FBCALL-001 / 002 適用所有 FB instance(`unknown-type` / `type-alias` 不知道是不是 timer,只記這兩條);SCAN-TIMER-001 / 002 適用 timer + edge;SCAN-TIMER-004 只適用 timer(TON / TOF / TP / LT*);SCAN-TIMER-005 只適用 TON / LTON。規則各自追加的 reason(`member-call`、`call-in-pragma`、`call-in-loop`、`also-called-in-member`、`input-write-unresolved`)同樣記給該型別適用、且在該處還沒判定完的每條 timer 規則(例:`call-in-loop` 時 004 已判定、002 不適用 → 記 001 / 005)。
規則各自追加的 reason 見各節。

#### SCAN-FBCALL-001 FB instance 被讀取但從不呼叫(warning,`blockable: false`,進 `unresolved[]`)
- 定義:instance 有被引用(例如讀 `.Q`、寫 `.PT`),但整個 owner 沒有 `inst(...)` 呼叫。機台行為:FB 的輸出只在被呼叫時才更新,讀到的永遠是初值(依 IEC FB 語意推論,`impactBasis: inferred`,未實測);confidence medium。
- 偵測:專案 FB 還把 EXTENDS 鏈上任何 Method / Action / Property 的呼叫(`inst.M()`、`inst.Prop`)算「有呼叫」(Property accessor 的程式碼會跑);鏈上有 library 基底(讀不到成員)→ 視為有呼叫。owner 自己基底的成員在基底評估。
- 追加 reason:`member-call-of-library-fb`(型別目錄內的 library FB 只被 `inst.Method()` 呼叫:不知道 Method 會不會執行本體,不報)。
- 已知漏抓:instance 在永遠不會被執行的程式碼裡被呼叫(不檢查可達性);呼叫發生在別的 POU(`qualified-access` / `passed-or-aliased` 一律跳過)。
- 與 TEMPFB 的差別:本規則不看 instance 宣告在哪個 section 的語意,只看呼叫點有沒有。

#### SCAN-FBCALL-002 FB instance 完全沒被引用(info,`machineImpact: none`,不進 `unresolved[]`)
- 定義:型別目錄的 FB(含只列型別的 Tc2_MC2 `type-only`)或專案 FB 的 instance,在 owner 的任何 ST 段落都沒有任何引用(沒呼叫、沒成員存取、沒傳出去)。confidence high。
- TE1200 Light SA0033(Unused variables)的關係(`research/te1200-rules.md`):SA0033 是 Light 七條之一,涵蓋「已宣告但未使用的變數」;手冊 Function 欄沒有特別提 FB instance,**FB instance 是否由 SA0033 涵蓋未驗證**。因此本規則只報 FB instance(info),其餘未使用變數留給 SA0033,不重做;價值在寫入前(`LintCandidate`)就看到、以及客戶沒啟用 / 沒跑 Light 時。SA0033 與本規則同時存在不矛盾,也不互相取代。
- 追加 reason:`fb-init`(FB 或其 EXTENDS 鏈有 `FB_init` / `FB_reinit` / `FB_exit`、宣告帶建構參數,或 EXTENDS 鏈的 base 在專案外 → 宣告本身可能有作用(例如在 `FB_init` 自行註冊),不報)。
- 已知漏抓:變數只在註解 / 字串內提到不算引用(正確);instance 只被自己的 Method 內同名區域變數遮蔽 → `shadowed-name` 不報。

#### SCAN-TIMER-001 Timer / 邊緣觸發只在 IF / CASE 內呼叫(warning,`blockable: false`,進 `unresolved[]`)
- 範圍:型別目錄 class `timer`(TON / TOF / TP / LTON / LTOF / LTP)與 `edge`(R_TRIG / F_TRIG)。counter(CTU / CTD / CTUD)與 RS / SR **不檢查**(只在條件下計數是正常設計)。
- 機台行為出處:TON 沒被呼叫的 cycle,內部時間照牆上時間算 — 實測 2026-11-13(XAE 4026.22 / VS2022,本機 UmRT,[runtime-semantics-measured.md](verification/runtime-semantics-measured.md) 第 5 節):2 ms task 先呼叫 0.5 s(`ET = T#498ms`),跳過 1500 cycle(`TIME()` 差 3002 ms),再呼叫的第一個 cycle `ET = T#3s500ms`,PT 2 s 的 timer `Q = TRUE`。TON 頁 [74406539](https://infosys.beckhoff.com/content/1033/tcplclib_tc2_standard/74406539.html) 沒寫沒被呼叫的週期怎麼算。邊緣觸發:兩次呼叫之間的邊緣會漏掉(依 R_TRIG 頁 [74391563](https://infosys.beckhoff.com/content/1033/tcplclib_tc2_standard/74391563.html) "for one cycle" 的語意推論,未實測)。
- 偵測:所有呼叫點都在 IF / CASE 內,且沒有任何一層 IF…ELSE / CASE…ELSE 的所有分支都呼叫它(巢狀遞迴判斷)。呼叫在 owner 本體,或在「本體以敘述層級、不在 IF / CASE / 迴圈內無條件呼叫」的 Action / Method。有條件呼叫 + 同一個 timer 另有符合 005 條件者只報 005,不報 001。
- 不報(每種 rulesSkipped reason,追加於共同 reason 之外):`explicit-reset`(任何呼叫有 `IN := FALSE` / `CLK := FALSE`,或有 `inst.IN :=` / `inst.CLK :=` 賦值**且同一路徑之後有呼叫該 instance(呼叫沒帶 IN / CLK 參數)** — 作者有處理離開狀態;只寫 `inst.IN :=` 不呼叫,FB 取樣不到那個值,下次呼叫又傳自己的 IN,不算 reset — 依 IEC FB 呼叫語意推論,未實測)、`input-write-unresolved`(`inst.IN :=` 之後同一段落沒有呼叫,但別的 Action / Method 有呼叫該 instance,或之後的呼叫用位置引數 → 判斷不了是否取樣到,不報)、`call-in-loop`(呼叫在迴圈內)、`call-in-pragma`(呼叫在 `{IF}` 區內)、`also-called-in-member`(另有呼叫在「不確定每次都跑」的 Method / Action 內)、`member-call`(`inst.Method()` 型式)。任何一個無條件呼叫 → 不報。
- 已知漏抓(limits):提早 `RETURN`(`IF NOT bEnable THEN RETURN; END_IF` 之後的呼叫,實際是條件呼叫)、`JMP` 之後的呼叫、owner instance 本身被條件呼叫(遞移)。
- TE1200:無對應(SA0105 Full 需要 attribute,只部分相關)。
- 誤報來源:刻意「只在某模式更新」的 timer(語料 `TestCam.R_14Eng` 類)— 需處置。

#### SCAN-TIMER-002 Timer / 邊緣觸發只在 Method / Action 內呼叫(info,不進 `unresolved[]`,confidence low)
- 定義:所有呼叫都在 Method / Action,而 owner 本體沒有「以敘述層級、不在 IF / CASE / 迴圈內」呼叫那個 Action / Method(Method 被別的 POU 呼叫的情況不追,所以無法證明每 cycle 呼叫)。
- 不報:共同 reason;只要有一個呼叫在本體或每次都跑的成員內即走 001 的判斷。「每次都跑」的成員:本體以敘述層級無條件呼叫、IF…ELSE / CASE…ELSE 的每個分支都以敘述呼叫(與 001 直接呼叫 timer 的「全分支」判斷相同)、回傳值被使用的呼叫(`b := M()`)、最外層 IF / CASE / WHILE / FOR 條件裡的呼叫(`IF M() THEN`),並沿成員呼叫鏈往下追(本體 → `M_Outer` → `M_Inner`);接在 `AND_THEN` / `OR_ELSE` 後面或 IF 分支內的呼叫不算。
- 已知漏抓 / 誤報:外部 POU 每 cycle 呼叫該 Method 的合法寫法會被報成 info(所以只是 info、low)。出處同 001(實測第 5 節的語意:不被呼叫的 cycle 時間照算)。

#### SCAN-TIMER-004 PT 未設 / IN 恆為 FALSE(warning,`blockable: false`,進 `unresolved[]`)
- 範圍:只看 timer(TON / TOF / TP / LTON / LTOF / LTP)。
- variant `pt-unset`(confidence high):instance 的所有呼叫都沒傳 `PT`、沒有 `inst.PT :=`、宣告沒有初值或初值 `(名稱 := 值, ...)` 裡沒有 `PT :=`(例:`t1 : TON := (IN := FALSE);` 照報);初值解析不了 → rulesSkipped `initialiser-not-parsed`。機台行為:PT 預設 `T#0S`(TIME 預設初值 InfoSys 出處未附,推論),而 TON 在 `PT = T#0S` 時 — 實測 2026-11-13(XAE 4026.22 / VS2022,本機 UmRT,[runtime-semantics-measured.md](verification/runtime-semantics-measured.md) 第 4 節):`IN` 上升緣**當個 cycle** `Q = TRUE`、`ET = T#0ms`,`IN` 落下當個 cycle `Q = FALSE`,延遲完全失效、`Q` 跟著 `IN` 走(TON 頁 74406539 沒寫 PT = 0)。實測對象是 TON;TOF / TP / LT* 在 PT = 0 的行為**未測**,依同一套「PT 為 0 沒有延遲」推論。
- variant `in-constant`(confidence medium):所有呼叫的 `IN` 都是常數 `FALSE`,且 `IN` 沒有被 `inst.IN :=` 賦值 → timer 永不啟動。**IN 常數 `TRUE` 不報**(開機延遲 `tonStartup(IN := TRUE, PT := T#5S)` 是合法寫法;狀態機形態由 005 處理)。
- 追加 reason:`positional-arguments`(呼叫用位置引數,讀不到 PT / IN 名稱)。
- 已知漏抓:`IN := TRUE OR x` 之類需要常數折疊(未做);seeded S18 目前不報。

#### SCAN-TIMER-005 狀態 timer 離開時沒歸零(warning,`blockable: false`,進 `unresolved[]`)
- 範圍:TON / LTON。
- 機台行為:`CASE eState OF WAIT: ton(IN := TRUE, PT := T#2S); ...`,離開 WAIT 後不再呼叫,`IN` 內部仍是 TRUE;之後再進入 WAIT 沒有上升沿,TON 依牆上時間算 `ET`,跳過的時間 ≥ 剩餘 PT 時重新呼叫的第一個 cycle `Q = TRUE`,超時判斷失效 — 實測 2026-11-13(XAE 4026.22 / VS2022,本機 UmRT,[runtime-semantics-measured.md](verification/runtime-semantics-measured.md) 第 5 節,數據同 TIMER-001)。「Q 可能立刻成立」已由推論改為實測確定(跳過時間超過剩餘 PT 時)。
- 偵測:所有呼叫都在**同一個 CASE** 的分支內、每個呼叫都是 `IN := TRUE`、沒有 `IN := FALSE`、沒有「之後同一路徑有呼叫(不帶 IN)」的 `inst.IN :=`(只寫 `inst.IN := FALSE` 不呼叫照報:TON 取樣不到 FALSE,下次呼叫又傳 `IN := TRUE` — 依 IEC FB 呼叫語意推論,未實測;判斷不了 → rulesSkipped `input-write-unresolved`),且不是「每個分支都呼叫(含 ELSE)」。`IN` 不是常數 → 改報 001。與 001 不重複報(同一 timer 只報 005)。
- 不報:用位置引數(`positional`,不報 005,落到 001 / `explicit-reset` 的判斷);其餘 reason 同共同 reason 與 001。
- 與 001 的差別:001 把正確寫法(離開前 `ton(IN := FALSE)`)和錯誤寫法報成同一個 warning;005 只抓錯的那種,confidence 較高(實作標 medium)。

**文件與實作的已知對應**:附錄 D6 舊稿的 4(FBCALL)與 5(TIMER)是 MVP 初稿,與上面實作不同之處以本節為準 — 舊稿 TIMER 範圍含 CTU / CTD / CTUD(實作不含)、舊稿 TIMER-004 含「IN 常數 TRUE」(實作不報)、舊稿 FBCALL 看 `VAR_INST`(實作只看 `VAR` / `VAR_STAT`)。

### PROJECT-SA-001(Phase 2,視 Phase 1a 量測)
- 若量測確認 TE1200 Light 結果會進 `BuildProject` 的 `errorItems`,且 `.plcproj` 有啟用設定:專案沒啟用 SA0004 / SA0006 / SA0167 時報 warning,fixHint 說明怎麼啟用。量測結果不支持就不做。

### Phase 3:SCAN-SM-001、SCAN-MC-001 / 002、SCAN-REF-001、SCAN-FBVAL-001、SCAN-OUT-001、SCAN-FLOAT-001、SCAN-INTDIV-001

| ID | 機台行為 | 偵測 | 誤報來源 | 出處狀態 |
|---|---|---|---|---|
| SCAN-SM-001 | 狀態變數被賦值成 CASE 沒有的值、CASE 無 ELSE → 那個狀態什麼都不做,機台停住 | CASE selector 是單一變數;收集 `sel := <常數 / enum 成員>`;與 CASE 標籤(含範圍)比對 | 刻意的「閒置」狀態(值存在但不需動作) | 不依賴 TwinCAT 特有行為 |
| SCAN-MC-001 | MC FB 只在條件內呼叫,或 `Execute` 設 TRUE 後全物件沒有設 FALSE → 下一次命令沒有上升沿 | 型別目錄的 Tc2_MC2 FB;同 SCAN-TIMER-001 的條件分析 + Execute 賦值掃描 | 狀態機在單一狀態呼叫 MC FB 是常見寫法 | 上升沿:"The function block can only be triggered by a rising edge at the "Execute" input if the "Busy" output is FALSE."(https://infosys.beckhoff.com/content/1033/tcplclib_tc2_mc2/70043531.html);Busy 中停止呼叫的後果未驗證 |
| SCAN-MC-002 | MC_Move* 在某狀態 Execute 後沒等 Done 就離開,也沒 MC_Stop / MC_Halt → 軸繼續動,程式以為停了(推論,未驗證) | MC_Move* 只在單一 CASE 分支呼叫,物件內沒有 MC_Stop / MC_Halt | 由外層 FB 統一停軸 | 同上;離開後軸是否繼續動未驗證(tasks 3.1 先查 InfoSys) |
| SCAN-REF-001 | 未初始化的 REFERENCE / POINTER 解參照 → page fault、PLC 停機(推論;編譯器不擋 — 實測 2026-11-13([runtime-semantics-measured.md](verification/runtime-semantics-measured.md) 第 8 節,Build 成功、這兩行無 error / warning);runtime 解參照後果 NOT RUN,**未驗證**) | `REFERENCE TO` 宣告在 VAR(非 IN_OUT),物件內沒有 `REF=` 也沒有 `__ISVALIDREF`;POINTER 做 `p^` 但沒有 `ADR(` 指派也沒有 `<> 0` 檢查 | 透過 FB_init / 外部指派 | `__ISVALIDREF` 出處見 st-syntax-inventory |
| SCAN-FBVAL-001 | `VAR_INPUT fb : FB_X` 傳的是複本,呼叫只更新複本,狀態遺失 | VAR_INPUT 的型別在 FB 目錄內 | 刻意傳值只讀輸出 | 推論(IEC 傳值語意) |
| SCAN-OUT-001 | 同一輸出多處無條件寫入,前面的條件被覆蓋;跨 task 寫入 | 同一 `AT %Q*` / VAR_OUTPUT 有兩處以上無條件指派;或分布在不同 task 可達的 POU | 預設值 + 條件覆寫的寫法 | SA0004 / SA0006(Light) |
| SCAN-FLOAT-001 | `IF rPos = 100.0` 幾乎不成立,機台卡在等待 | 運算元型別是 REAL / LREAL(MVP 只處理區域變數與 literal) | 與 0.0 比較的初始化判斷 | SA0054(Full) |
| SCAN-INTDIV-001 | `rRatio := nA / nB` 先截斷再轉換(推論,依 IEC 運算型別規則;InfoSys 出處待補) | 兩個整數運算元相除、結果指派給 REAL / LREAL | 刻意整數除法 | SA0020 / SA0057(Full) |

### Phase 4:CONTRACT-*、POLICY-*、ST-LLM-001
- CONTRACT-ITF-001 / 002:編譯器擋(待實測),價值只剩寫入前;**compilerCatches = yes 的規則不進 `blockingRulesSkipped`**(review 第二輪 1-3:library Interface 會讓每次結果都 incomplete)。
- CONTRACT-ENUM / DUT:baseline 比對,說明加上 PERSISTENT 情境(enum 重編號後,保存的數值在還原時對到不同成員;推論)。
- POLICY-INTERLOCK-001:profile 宣告 `{output, interlock}`,檢查輸出在檔案順序上最後一次指派是否為 `x := x AND interlock`,或位於 `IF NOT interlock THEN x := FALSE` 之後。輸出與文件**必須明寫「本規則不是安全功能,不取代 TwinSAFE 或安全評估」**。
- ST-LLM-001:多數子項編譯器會擋;只有 `x = 5;` 當陳述式值得做,編譯器擋不擋未驗證(review 第二輪 2-3 降級)。

## 3. 不做

- SA0033 未使用變數(只保留 SCAN-FBCALL-002 info)、SA0075 CASE 無 ELSE(由 SCAN-SM-001 涵蓋會出事的那一種)、SA0160 遞迴、`%Q` 直接位址重疊(SA0028 Light)、CASE range 重疊(編譯器多半擋,未驗證)、RETAIN / PERSISTENT 誤用(併入 CONTRACT-ENUM 說明)、魔術數字。

## 附錄:design.md 初稿 D6 的詳細定義

以下是第一輪 review 後 design.md D6 的原文(仍有效的偵測細節與 prototype 實測依據)。分期、blocking 與 machineImpact 以本檔上方的總表為準;下文提到的「MVP」「Phase」是舊分期。


完整候選清單與排序在 `research/rule-candidates.md`;這裡定義 MVP 的 8 項。欄位:偵測演算法 / 預設 severity·confidence / blocking / 誤報來源 / 編譯器或 TE1200 會不會抓 / 實測依據。

1. **PROJECT-COMPILE-001/002/003**(`.plcproj` `<Compile>`)
   - 001:`<Compile Include>` 指向不存在的檔(所有項目,不只 PLC 物件副檔名)。error/high,blockable `pending`(XAE 載入 / Build 遇到時的行為未實測)。
   - 002:同一檔案出現兩次。error/high,blockable `pending`。
   - 路徑比較前先做 MSBuild unescape(`%20` `%27` 等),再相對 `.plcproj` 目錄 `Path.GetFullPath` 正規化(`.\POUs\X` 與 `POUs\X` 視為同一個),大小寫不敏感(review S13)。TwinCAT 對含空白 / `'` / `%` 檔名實際寫入的格式,Phase 1 實測。
   - 003:`.plcproj` 目錄底下有 `.TcPOU/.TcDUT/.TcGVL/.TcIO/.TcTTO` 但沒列在 `<Compile>`(不會被編譯)。warning/high,**不** blocking(可能刻意保留)。
   - 誤報來源:語料複製漏檔(prototype 實際發生一次,見 research 4.1);`_bak` 類目錄在專案目錄內。
   - 編譯器:001 載入 / Build 時 XAE 的行為**未驗證**;003 編譯器看不到(檔案根本沒被編譯),是本 linter 的獨有價值。
   - 實測:seeded S01/S02/S03 命中;語料 0 誤報(扣掉複製失誤)。
2. **PROJECT-GUID-001 / PROJECT-KIND-001 / PROJECT-NAME-001**
   - GUID-001:同一 `.plcproj` 內兩個物件(含 Method / Action / Property 子物件)`Id` 相同。error/high,blockable `pending`:XAE 遇到重複 Id 的行為**未驗證**(若 XAE 自動重新產生並正常 Build,就改成 warning)。
   - KIND-001:副檔名與根元素不符(`.TcDUT` 內是 `<POU>`)。error/high,blockable `pending`。
   - Phase 1 在本機測試副本實測:三種情況下 XAE 開專案與 Build 的行為(只需 IDE、不需 runtime),附實測紀錄後定案。
   - NAME-001:檔名與物件名不同。warning/high,不 blocking(XAE 是否允許**未驗證**)。
   - 實測:seeded S04/S05 命中;語料 0 筆。
3. **CONTRACT-ITF-001/002**(Interface Method / Property 簽章)
   - 對每個 `IMPLEMENTS I_X`:收集 `I_X`(含 `EXTENDS` 的 Interface 鏈)的 Method / Property;FB(含專案內 `EXTENDS` 的基底 FB 鏈)必須有同名成員;回傳型別、`VAR_INPUT/OUTPUT/IN_OUT` 的順序、名稱、型別文字(正規化空白與大小寫)一致。Property 比對型別與 Get/Set 是否存在。
   - 001 缺成員、002 簽章不同。**嚴格度依實測決定**(review S12):Phase 3 在本機用 XAE 逐項實測編譯器擋不擋 — 回傳型別不同、參數型別不同、參數名稱不同、VAR_OUTPUT 順序、Property 只有 Get 的介面被實作成 Get+Set、ABSTRACT FB 未實作 — 只有編譯器會擋的差異設 error/high blocking,其餘 warning/medium;每項附實測日期與環境。實測前一律 warning/medium。
   - Interface 或基底 FB 在 library 裡(專案內找不到)→ 不評估,`rulesSkipped` reason `type-outside-project`。
   - 誤報來源:型別別名(`ALIAS`)與 qualified 名稱(`Lib.T` vs `T`)— 比對前展開專案內 alias,不同寫法但無法證明相等時降為 warning/medium。
   - 編譯器:會抓(實作不完整會編譯錯誤 — 依 IEC 語意推論,**未實測**),價值是 `LintCandidate` 在寫入前擋。
   - 實測:seeded S10/S11 命中;語料沒有 Interface(語料缺口)。
4. **SCAN-FBCALL-001/002**(FB instance 沒有呼叫點)
   - 型別判斷只用**型別目錄**:專案內 `FUNCTION_BLOCK` + 內建 library 目錄(版本化資料檔,先放 Tc2_Standard、Tc2_MC2 常用 FB,每個名稱附 InfoSys 來源)+ profile `typeCatalog.functionBlocks`。目錄外的型別 → 不評估(`rulesSkipped` reason `unknown-type`),**不得用名稱前綴猜**(prototype v1 用 `MC_` 前綴猜,56 筆全誤報)。
   - 只看 `VAR` / `VAR_STAT` / `VAR_INST`(不看 INPUT/OUTPUT/IN_OUT、POINTER、REFERENCE);instance 在同一物件的本體、Method、Action 都沒有 `inst(...)` 也沒有 `inst.Method(...)`。
   - 標準 FB(TON、R_TRIG… 沒有 Method 的)只算 body 呼叫:`tonX.M_Reset()` 之類只呼叫 Method 而從不呼叫 body,`.Q` 永遠不更新(review N1)。
   - 專案內有任何 FB `EXTENDS` 該 FB → 它宣告的 instance 不評估,`rulesSkipped` reason `inherited-use`(review S18)。
   - 001:有被引用(例如讀 `.Q`)但從不呼叫 → warning/medium,不 blocking(讀到的是永遠不更新的輸出)。002:完全沒被引用 → info/high(TE1200 SA0033 同類)。
   - 物件有任何未分析的 section(CFC Action 等)→ 整個物件不評估。
   - 誤報來源:instance 透過 `REFERENCE` / 指標 / Interface 交給別的物件呼叫;基底 FB 宣告、衍生 FB 呼叫(MVP 不追繼承,`EXTENDS` 專案外的物件 → 不評估);`{attribute 'call_after_init'}` 之類由系統呼叫的情況(**未驗證**)。
   - 實測:v2 語料 0 筆誤報(001)、2 筆真的未使用(002);seeded S08/S09 命中。
5. **SCAN-TIMER-001 / 002**(Timer / Trigger 條件呼叫)
   - 目標型別:`TON TOF TP LTON LTOF LTP R_TRIG F_TRIG CTU CTD CTUD`(Tc2_Standard)+ profile `typeCatalog.cyclicContract`。
   - 001:instance 所有本體呼叫點都在 IF / CASE 內,**且**沒有任何一個頂層 IF…ELSE 的所有分支都呼叫它 → warning/medium,不 blocking。
   - 002:只在 Action / Method 內呼叫,而那個 Action 沒有被本體無條件呼叫(Method 一律無法證明)→ info/low。
   - 誤報來源:CASE 的每個分支都呼叫(MVP 只處理 IF…ELSE,CASE…ELSE 留到 Phase 2);刻意的「只在某模式更新」(語料 `TestCam.R_14Eng`);狀態機在每個狀態都呼叫同一 timer。
   - 已知漏抓(寫進 `limits`,review N2):`IF NOT bEnable THEN RETURN; END_IF` 之後的呼叫(實際上是條件呼叫);外層 FB instance 本身被條件呼叫(遞移);WHILE 內的呼叫;Method `VAR` 裡宣告的 TON 是每次呼叫重新初始化的暫時 instance(TE1200 SA0167,Light 版也有)— 由 SCAN-TEMPFB-001 涵蓋(舊稿稱 SCAN-TIMER-005;現在 SCAN-TIMER-005 是「狀態 timer 沒歸零」)。
   - 編譯器 / TE1200:都沒有對應規則(TE1200 SA0105「多處呼叫」需要 attribute、只部分相關)→ 本 linter 獨有價值。
   - 實測:v1 3 筆(2 誤報,`FB_BrakeControl` IF/ELSE 兩邊都呼叫)→ v2 1 筆真模式;Action 精化把 7 筆 info 降到 0;seeded S06/S07 命中。**這是在同一份語料上調出來的**,第三個專案驗證前不能宣稱誤報率。
   - 同一 timer 多次呼叫(prototype 的 SCAN-TIMER-003)**不放 MVP**:語料唯一一筆是正確的 `IF reset THEN rt(CLK:=FALSE); RETURN; END_IF` 寫法,需要 RETURN 控制流才能判斷。
6. **CONTRACT-ENUM-001/002、CONTRACT-DUT-001**(相對 baseline)
   - ENUM-001 成員被刪、ENUM-002 數值改變(含隱含值連動);DUT-001 STRUCT 欄位順序 / 名稱 / 型別在第一個不同處報出(後面的欄位位移一併影響 ADS layout)。error/high,blocking。
   - 新增成員或欄位加在最後:info(ADS layout 尾端變化,呼叫者自行判斷)。
   - 沒 baseline 不跑。編譯器不會抓(這是相容性契約)→ 獨有價值。
   - 實測:seeded S12/S13 命中。
7. **POLICY-***(profile 定義,default profile 全部關閉)
   - `POLICY-SYMBOL-001` 禁用識別字(精確名或 glob;只比對 token,不比對註解與字串)。
   - `POLICY-NAME-001` 物件命名前綴 / 後綴(依 ObjectKind);`POLICY-NAME-002` 檔名 = 物件名(Robust Solution NAM-001)。
   - `POLICY-CALL-001` 「每個 scan 必呼叫」清單(例:`M_UpdateService`,對應 Robust Solution PKML-014 / ARCH-003),重用 SCAN-TIMER 引擎。
   - `POLICY-RETVAL-001` 回傳值必須使用的 Method 清單(例:`RequestCommand`,對應 PKML-008 與 vault「PackML Service FB 吃掉 Abort」)。
   - blocking 由 profile 決定;rule 本身 confidence high(比對的是明列的名稱)。
   - Robust Solution 規格的完整對照與哪些可機械檢查:`research/rule-candidates.md` 第 3 節,做成內建 `robust-solution` profile(Phase 4)。
8. **統一 diagnostics**:D5 的格式與排序;`LINT-PARSE-*`、`LINT-COVERAGE-*`、`LINT-SUPPRESS-*`、`LINT-XML-*` 也走同一格式。

**(舊分期,已被上方總表取代)MVP 預設 blocking**:PROJECT-COMPILE-001/002、PROJECT-GUID-001、PROJECT-KIND-001(以上 `pending`,待 Phase 1 實測)、CONTRACT-ITF-001/002 中實測確認編譯器會擋的差異、CONTRACT-ENUM-*/DUT-001(有 baseline 時)、LINT-PARSE-*。SCAN-* 全部 warning / info;PROJECT-COMPILE-003、PROJECT-NAME-001 是 `blockable: false`(見 Open Questions 3)。

