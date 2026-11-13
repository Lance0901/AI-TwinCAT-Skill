## 每個 Phase 做完時,部署前能擋下的真 bug

依 owner 決定(#252 留言「Owner 決定(Lance,2026-11-13)」)排序:Build 抓不到、會讓機台行為出錯的規則優先;AI 改磁碟檔造成的專案完整性問題留在 Phase 1a;相容性契約最後。規則細節見 `rule-catalog.md`。

| Phase 做完 | 新增能擋下(blocking)的 | 新增必須處置的(warning,進 `unresolved[]`) | 編譯器本來就會擋? |
|---|---|---|---|
| 1a | AI 手改 XML 造成的損毀:not well-formed、CDATA 被切開;GUID 缺 / 錯 / 重複、種類與名稱不一致、Compile / tsproj / task 參照錯(實測前 `pending`,照 error 擋) | 專案目錄下的新 POU 沒列入 Compile(不會被編譯) | 多數未驗證;Build 會不會失敗正是 Phase 1a 的 IDE 實測項目 |
| 1b | Timer / Trigger / Counter 宣告在 METHOD / FUNCTION 的 VAR(永遠不計時、每次都觸發);PROGRAM 每 cycle 執行兩次 | PROGRAM 沒掛 task 也沒被呼叫(永遠不跑) | 推論否;SA0167(Light)編譯後自動跑,Build 是否因此失敗待 1a.9 量測 |
| 2 | busy-wait(task 卡死)、FOR 計數器溢位(無窮迴圈)、迴圈變數 index 越界(0-based 習慣)、除以常數 0 | Timer 條件呼叫、狀態 timer 離開沒歸零、PT 未設、FB 讀取但沒呼叫、變數除數沒檢查 | 否;FOR 溢位編譯器只出 warning C0266(Build 照過);常數 index 越界編譯器會擋(InfoSys),所以只做寫入前;除以常數 0 待實測 |
| 3 | 依驗證結果升級(誤報率低於事先寫明的門檻者) | 狀態機卡在未處理狀態、MC FB 條件呼叫 / Execute 不歸零 / 離開狀態沒停軸、REFERENCE 未初始化、FB 傳值、輸出多處寫入、浮點 `=` 比較、整數除法後轉 REAL | 否 |
| 4 | 有 baseline 時 enum 值 / STRUCT layout 改變;profile 定義的 POLICY | Interface 簽章(寫入前加速) | Interface:是(待實測) |

表中「編譯器本來就會擋?」欄的「否」除了已附出處的項目,都是推論,待 tasks 3.4 的 mutation testing 以 `BuildProject` 實測。

衡量指標:「`compilerCatches = no` 且 `machineImpact ∈ behavior / crash`」的規則數,以及在凍結的錯誤清單上量到的召回率(D7)。

## Context

- #252(owner 開的):在 TcAuto 加一個 TwinCAT Semantic Linter,目標是**在 Activate / Download 之前**抓到 Build 抓不到、或 Build 之前就該擋下的問題。評分標準是「對真實 PLC 程式抓到多少真 bug、誤報多低、結果是否 deterministic」。
- 現有工具:`Build-TcProject`(XAE Error List)、`Test-TcPlcProject`(CheckAllObjects)、repo 自己的 forbidden-pattern lint(只掃 TcAuto 原始碼,不掃 PLC 程式)。repo 內沒有任何 ST tokenizer(`src/` 與 `mcp-server/` 搜過)。
- 限制:PowerShell 模組是核心;MCP tool = CLI action = cmdlet(`Invoke-TwinCATAutomation.ps1` 的 `$operationMap`、`mcp-server/scripts/Export-ToolSchema.ps1` 產生 `tools.json`、`scripts/Update-GeneratedDocs.ps1` 產生 adapters)。客戶安裝包只有 bundled node 24 + Windows PowerShell 5.1,沒有 .NET SDK。`src/` 已有 `Add-Type` 編譯的 C#(`Private/TcAdsHelper.cs`、`Private/ComRotHelper.cs`),`scripts/check.ps1` 不禁止 `Add-Type`。
- 可行性實測:`research/corpus-feasibility.md`(2 個真實專案、throwaway prototype、seeded-bug 18 個)。TE1200 規則清單:`research/te1200-rules.md`。規則目錄:`rule-catalog.md`(取代初稿的 `research/rule-candidates.md` 排序)。XAE 實際產生的 XML 結構:`research/tc-xml-schema-observed.md`。ST 語法與 TwinCAT 行為出處:`research/st-syntax-inventory.md`。
- Owner 已定案的 6 點(#252 留言,2026-11-13):(1) 先做 Build 抓不到、會讓機台行為出錯的規則,CONTRACT 最後;(2) 判斷確定的規則預設 blocking;(3) 影響機台行為的 warning 必須處置,先 advisory、stale 偵測真機驗證後才擋;(4) 客戶只有 TE1200 Light,Full 版才有的檢查自己做,並量測 Light 結果能否經 `BuildProject` 取得;(5) 更多語料與錯誤清單之後提供,不擋 Phase 1;(6) AI 直接改磁碟檔造成的 XML / GUID / 專案一致性問題必須包含,不延後。

## Goals / Non-Goals

**Goals:**
- 在部署前擋下「Build 抓不到、會讓機台行為出錯」的 bug;衡量指標是 `compilerCatches = no` 且 `machineImpact ∈ behavior / crash` 的規則數與在凍結錯誤清單上的召回率,不是功能清單。
- 擋下 AI 直接改磁碟檔造成的專案檔損毀(XML、GUID、Compile / tsproj 參照)。
- `LintCandidate`(寫入前,純文字)與 `LintProject`(寫入後,磁碟上的專案)兩個唯讀 tool,回傳 deterministic、可排序的結構化 diagnostics。
- 不需要 IDE、不需要 runtime 就能跑(見 D2 的範圍表)。
- fail closed:解析不了、context 不足、profile 壞掉、有東西沒分析到,都不能回 `passed: true`;但**合法程式不得被判 `LINT_PARSE_FAILED`**(不認得的構造降級成 notAnalyzed,D3)。
- 判斷確定的規則預設 blocking(owner 決定 2);heuristic 規則是 warning,但 `machineImpact ∈ behavior / crash` 的 warning 必須處置(D6)。

**Non-Goals:**
- 不取代 compiler、`CheckAllObjects`、TE1200。客戶只有 TE1200 Light(owner 決定 4):Full 版才有的檢查(除以零、陣列越界、REFERENCE / POINTER 未檢查、浮點比較…)由本 linter 做;Light 版 7 條的重疊規則仍可做,價值在寫入前擋與客戶沒啟用時(D11)。
- 不是安全功能:POLICY-INTERLOCK 等規則的輸出明寫「不取代 TwinSAFE / 安全評估」。
- 不用 LLM 當 gate;不 auto-fix;不碰 Activate / Login / Download / ADS / I/O。
- Phase 1 不做控制流 / 資料流分析;Phase 2 起只做規則需要的局部分析(同一 IF 路徑的除數檢查、常數範圍迴圈的 index),不做一般性的可達性與常數折疊。

## Decisions

### D1. 解析與規則引擎用 C#(C# 5),由 PowerShell 以 `Add-Type` 在第一次 lint 時編譯

**建議**:`src/TwinCATAutomation/Private/Lint/*.cs`(tokenizer、宣告 parser、陳述式結構掃描、TcPOU/plcproj 讀取、規則、排序)全部用 C# 5 寫;`Invoke-TcLintCandidate` / `Invoke-TcLintProject` 這兩個 Public cmdlet 只做參數驗證、profile / baseline 載入、呼叫引擎、把引擎結果轉成 `New-TcResult`。

**理由(實測,`research/corpus-feasibility.md` 第 3 節)**:

| 方案 | 全語料 tokenize(754 KB ST) | 其他 |
|---|---|---|
| C#(Add-Type) | 17 ms | 編譯一次 0.7–1.0 s / session;完整分析單專案 50–160 ms |
| 純 PowerShell 5.1 | 332 ms(簡化版,規則更少) | 約 20 倍慢;加上 parser 與規則後推估數秒~十數秒(未驗證) |
| Node(mcp-server) | 20 ms | 與 C# 同級 |

- C# 與 Node 速度同級,但 Node 會破壞「cmdlet 是核心」:`Import-Module` 單獨使用、`Invoke-TwinCATAutomation.ps1` CLI 都沒有 node;邏輯會分裂成兩份實作。
- 純 PowerShell 慢一個數量級,而且 parser 需要大量 typed 資料結構;PS 5.1 的 generic 集合坑已經出過事(#75),維護風險高。
- repo 已有 `Add-Type` + `.cs` 的先例(`TcAdsHelper.cs`),PS 5.1 的 `Add-Type` 用 .NET Framework 的 csc(C# 5):不能用字串插值 `$""`、`?.`、`nameof`、expression-bodied member;prototype 已照這個限制寫並編譯成功。

**細節**:
- **延遲編譯**:不在 `Import-Module` 時編譯(避免每次 import 多 ~1 s),第一次呼叫 lint cmdlet 時編譯;MCP bridge 是常駐 PS session,之後不再付這個成本。
- **ReloadModule 的陳舊型別**:.NET Framework 無法卸載 `Add-Type` 載入的 assembly。`.cs` 改了之後 `ReloadModule`(`Import-Module -Force`)會拿到舊引擎。做法:編譯前把 namespace 換成 `TcLint_<.cs 內容 SHA256 前 12 碼>`,cmdlet 依 hash 找型別;內容變了就是新型別。`data.engine.sourceHash` 回報實際用的版本(可在測試中斷言)。library 型別目錄等資料檔不放 C# 靜態欄位,每次呼叫由 PowerShell 讀入傳給引擎;`data.engine.catalogHash` 另外回報(review N3)。
- **相依**:只引用 `System.Xml`、`System.Core`;XML 讀取一律 `DtdProcessing = Prohibit`、`XmlResolver = null`(不讀外部實體)。
- **受限環境**(review 第二輪 4-1):編譯前檢查 `$ExecutionContext.SessionState.LanguageMode`;不是 `FullLanguage`、或 `Add-Type` 失敗(csc 被擋、防毒攔截)→ `LINT_ENGINE_UNAVAILABLE`,hint 指向環境問題(AppLocker / WDAC / Constrained Language Mode、防毒),與引擎 bug 的 `LINT_ENGINE_ERROR` 分開。repo 的 `TcAdsHelper` / `ComRotHelper` 本來就依賴 `Add-Type`,lint 沒有增加新的失敗面。
- **既有載入方式不一致**(review 第二輪 4-3):既有 C# 用固定型別名稱 + `PSTypeName` 檢查,reload 後一樣拿到舊版。抽出共用 `Import-TcCSharpSource` helper、三處一起改,列為後續 task(tasks 5.x),不在 Phase 1 強制。
- 否決:預先編譯好的 DLL 隨安裝包發 — owner 定案維持 `Add-Type`。初稿的否決理由「DLL 可能被 Zone.Identifier 擋」不成立(`scripts/Build-TcAutoRelease.ps1` 已要求客戶先 `Unblock-File`,review 第二輪 4-2),真正的理由是不想多一條 release 建置路徑與「開發 / 發佈兩種載入方式」。Roslyn(PS 5.1 沒有);純 regex 規則(無法處理註解、字串、巢狀區塊)。

### D2. 輸入來源與「不需要 IDE」的範圍

**LintCandidate**:輸入是純文字,永遠不需要 IDE。

| 參數 | 說明 |
|---|---|
| `ObjectKind` | `Program` `FunctionBlock` `Function` `DUT` `GVL` `Interface` `Method` `Property` `Action` `Transition` |
| `ObjectName` | 物件名;Method / Property / Action / Transition 用 `Parent.Member`(與 `Write-TcPouCode -PouName` 同格式) |
| `Declaration` / `Implementation` | 文字;`Implementation` 只接受 ST(其他語言回 `LINT_INPUT_INVALID`) |
| `PlcProjectPath` | 選填。`.plcproj` 的檔案路徑,或已連 IDE 時的 PLC 名稱。給了就把候選物件**覆蓋**到該專案的磁碟版本上(同名物件被取代、新物件被加入),跑跨物件規則 |
| `RuleProfile` / `FailOn` / `Baseline` | 見 D5 |

**`PlcProjectPath` 的解析**(與 `Resolve-TcPlcProjectSpec` 一致,review S7):給 `.plcproj` 檔案路徑 → 不需 IDE;給 PLC 名稱 → 需要 IDE;**省略且 IDE 已連線** → 單一 PLC 自動取用、多個回 `PLC_PROJECT_AMBIGUOUS`;省略且 IDE 未連線 → text-only。**Phase 2a 實作(PR #284)**:只做不需要 IDE 的兩條 —— `.plcproj` 路徑與 text-only;PLC 名稱回 `LINT_INPUT_INVALID`,省略時一律 text-only(不看 IDE 是否連線;text-only 不會靜默 pass,所以不是 fail open)。經 IDE 找檔與 stale 偵測一起做(tasks 2.6)。

**範圍與跨物件檢查(PR #284 審查 S1)**:結果的 `diagnostics` 只列候選物件(與 `LintProject -Scope Object` 相同,語料一致性測試的比對基準)。另外把整個專案「有候選」與「磁碟原樣」各跑一次,**其他物件**只在有候選時才出現的 finding 列在 `data.crossObject.newFindings[]`(info 與已 suppress 的不列):其中有 blocking → 候選回 `LINT_FAILED`;非空 → `requiresDisposition`(reason `cross-object-findings`)。例:候選 GVL 把常數改成 0,讓別的 FB 的 `MOD` 變成 `MOD 0`。代價是每次 LintCandidate 跑三次引擎。

**既有 finding 與 context(PR #284 第三輪審查 S2 / S3 / N3)**:
- 其他物件在磁碟上本來就有的 finding(例:沒被呼叫的 PROGRAM 的 TASK-001,project 層級規則不受 scope 限制)放 `data.preExisting[]`,不算進候選的 verdict / `unresolved` / `requiresDisposition`;`data.projectVerdict` 是沒有候選時磁碟專案的結果。候選物件自己的 finding 一律留在 `diagnostics`:候選就是那個物件的新內容,沿用的問題也是寫入後會存在的問題。
- 規則需要的名稱(FOR 上下限 / 步長、WHILE / UNTIL 條件、陣列名與 index、除數)在 overlay 後的專案裡解析不到(候選、所屬 POU 與 EXTENDS 鏈、物件名、非 qualified_only 的 GVL 變數、型別目錄、標準函式都找過),或名稱指向檔案讀不到的物件 → `LINT_CONTEXT_REQUIRED`(`contextRequired` 的 `unresolved-identifier:<名稱>` / `context-object-broken:<檔>`)。只看規則位置的名稱:一般位置的 library 函式 / 型別不讓正常候選變 incomplete(語料 162 個物件的一致性測試確認)。
- 跨物件 blocking 只把 **pass** 改成 `LINT_FAILED`;已經是 `LINT_PARSE_FAILED` / `LINT_CONTEXT_REQUIRED` / `LINT_INCOMPLETE` 的保留原 code(D4 優先序,N3)。

**text-only 不能靜默 PASS**(review B2,issue「context 不足不得回傳 PASS」):候選內容本身需要 context 時 — 有 `IMPLEMENTS` / `EXTENDS`、`ObjectKind` 是 Method / Property / Action / Transition、或引用了不在內建型別目錄裡的型別 — 回 `LINT_CONTEXT_REQUIRED`(verdict `incomplete`),hint 要求帶 `PlcProjectPath`。只有完全自足的候選(例如只用基本型別與 Tc2_Standard FB 的 FUNCTION、STRUCT、ENUM)才能在 text-only 下 pass;`data.contextLevel = "text-only"`。

**Overlay 的邊界**(review S2):宣告區的物件名 / 種類與 `ObjectName` / `ObjectKind` 不符 → `LINT_INPUT_INVALID`;同名物件在磁碟上是不同種類 → `LINT_INPUT_INVALID`;Method / Property / Action 的 Parent 在磁碟上不存在 → `LINT_INPUT_INVALID`。overlay 的新物件不參與 PROJECT-COMPILE 檢查(它還沒有 `<Compile>` 項目),在 `coverage.rulesSkipped` 註明 reason `candidate-not-in-project`。

**LintProject**:讀磁碟上的 `.plcproj` 與它 `<Compile>` 列出的所有檔案(`.TcPOU` `.TcDUT` `.TcGVL` `.TcIO` `.TcTTO`,以及存在性檢查用的其他項目)。

- `PlcProjectPath`:`.plcproj` 檔案路徑 → 不需要 IDE。PLC 名稱或省略 → 需要已連線的 IDE,透過 `Get-TcPlcProjectList` 的 `projectFile` 找檔案;非停用的 PLC 多於一個且沒指定 → `PLC_PROJECT_AMBIGUOUS`(沿用 `Resolve-TcPlcProjectPath -RequireSingle` 的語意與 `data.plcProjects`);找不到 → `PLC_PROJECT_NOT_FOUND`。
- 也接受 `SolutionPath`(`.sln` / `.tsproj`)+ PLC 名稱,從 `.tsproj` 找 `.plcproj`(不需要 IDE;`.tsproj` 以 `Plc/Project@GUID` 與 `PrjFilePath` 參照 `.plcproj`(兩個語料專案觀察到的格式,`research/tc-xml-schema-observed.md`;多 PLC 未觀察)。

**IDE 編輯器有未存內容時**:

已知事實(`docs/troubleshooting.md`「磁碟改檔的正確做法」):
- `Write-TcPouCode` 寫入當下 XAE 就把 .TcPOU 寫到磁碟(實測 2026-10-28,4026 VS2022,#69);**4024 未重測**(2026-10-20 在 4024 32-bit XAE 曾記錄「要到存檔或 Build 才落地」)。
- `CreateChild` 新建物件的 `.plcproj` `<Compile>` 只改在 XAE 記憶體(#76);`Add-TcPou` / `Add-TcDut` / `Add-TcGvl` / `Add-TcLibrary` 現在會自己存專案檔並讀回驗證,但 XAE GUI 手動新增 / 刪除的不會。
- DTE `Project.Saved` / `IsDirty` 在未存的 `CreateChild` 之後仍是 True / False,不能拿來判斷 dirty;`Get-TcUnsavedChanges` 不讀巢狀 `.plcproj`(review B1 指出,設計初稿的前提錯了)。

所以真正的 stale 來源是**`.plcproj` 的 Compile 清單**(與 4024 上的 .TcPOU),不是 4026 上的 POU 文字。建議做法:
1. 寫入後的檢查以 **`LintCandidate -PlcProjectPath`** 為主(把剛寫的文字覆蓋到磁碟專案上),不依賴磁碟是否已落地。這是 agent 主要工作流(D9)。
2. `LintProject` 只描述磁碟。IDE 已連線時,先確認 `.plcproj` 屬於目前連線的 solution(`Get-TcPlcProjectList` 的 `projectFile` 比對;不屬於 → `data.source.ideChecked = false`,照跑、不宣稱已比對 IDE),再做 stale 檢查:
   - **XAE 樹與磁碟 `<Compile>` 比對**:重用 `Reset-TcSolution` 步驟 (1b) 的比對(`projectCheck.complete`、`missingOnDisk`);XAE 有、磁碟沒有 → `LINT_SOURCE_STALE`。
   - 目標 PLC 專案的文件 `Document.Saved == false` → `LINT_SOURCE_STALE`。
   - 有 code-changed 紀錄(`Register-TcCodeChange`)而目前 XAE 是 4024 → `LINT_SOURCE_STALE`(4024 的 .TcPOU 落地時機未確認,保守處理)。
   - 和目標 `.plcproj` 相關的項目讀不到 → `LINT_SOURCE_UNVERIFIED`;與目標無關的項目(例如 Scope 專案 `.tcmproj` 固定回 `Unchecked`,review S6)照 `Reset-TcSolution` 的慣例列出、不拒絕。
   - IDE 沒連線:照跑,`data.source = { kind: "disk", ideChecked: false }`。之後若把 lint 當 lifecycle gate(D6),gate 只接受 `ideChecked: true`。
3. **Phase 2 真機量**:4024 上 `WritePouCode` 後 .TcPOU 的落地時機;GUI 新增 POU 後 `projectCheck` 是否抓得到。量完再決定 4024 的保守規則能否拿掉。
- 否決:`LintProject` 透過 COM 逐一讀所有物件文字(需要 IDE、100+ 個物件逐一 COM 呼叫成本未知、與「不需 IDE」目標衝突);只用 `Get-TcUnsavedChanges`(看不到 `.plcproj` 的記憶體變更 = fail open)。

**不需要 IDE / runtime 的範圍**:

| 功能 | IDE | runtime |
|---|---|---|
| `LintCandidate`(text-only,或 `PlcProjectPath` 是檔案路徑) | 不需要 | 不需要 |
| `LintCandidate` 用 PLC 名稱 / IDE 已連線時省略路徑 | 需要(只用來找檔案) | 不需要 |
| `LintProject -PlcProjectPath <.plcproj 檔>` | 不需要(已連線時會額外做 stale 檢查) | 不需要 |
| `LintProject` 用 PLC 名稱 / 省略路徑 | 需要(只用來找檔案與 stale 檢查) | 不需要 |
| 任何 lint 功能 | — | **永遠不需要**;不呼叫 ADS |

### D3. 解析深度

**原則:合法程式不得被判 `LINT_PARSE_FAILED`**(review 第二輪 4-5、6-1~6-4)。每個語法構造在 `research/st-syntax-inventory.md` 標成三類之一:

| 類別 | 行為 |
|---|---|
| 支援 | 正常解析 |
| 不支援但安全略過 | 該 section 記 `coverage.notAnalyzed`(reason 例如 `conditional-pragma`、`unsupported-syntax:<項目>`),依 D3 的「按規則計算」影響 verdict;**不是** parse fail |
| 不支援即 parse fail | 只限確定非法的輸入(例如字串未結束、全部構造都認得但區塊不配對) |

- 任何物件只要含有「不支援但安全略過」的構造,後續的結構錯誤(例如區塊不配對)都視為「可能是我們不懂」,一律降級成 `notAnalyzed`,不報 `LINT-PARSE-*`。
- **「安全略過」只限明列的構造**(PR #274 第二輪審查 B2,2026-11-13 定案):條件 pragma、`?=`、`**`、`/* */`、`E_Enum#Member`、非 ASCII 識別字。這些段落記 `notAnalyzed`,verdict 仍可 pass,但每段加一筆 `coverage.rulesSkipped { ruleId: LINT-PARSE-00x, reason }`,`summary.notAnalyzed` 計數;LINT-PARSE-* 的 `compilerCatches` 標 `yes`(IDE 實測 `verification/st-syntax-measured.md`:4026.22 編譯器拒絕 `?=` `**` `/* */` `E#M` 與非 ASCII 識別字,不成立的條件分支也會被解析)。
- 清單以外不認得的東西(其他字元、格式不對的 typed literal / 位址、未結束的 pragma、宣告區不認得的結構)→ 段落狀態 `unsupported`,進 `coverage.blockingRulesSkipped`,verdict `incomplete`,**不得 pass**。反引號與 U+2018 / 2019 / 201C / 201D(從文件複製貼上的引號)→ `LINT-PARSE-001`;CDATA 內的 `&lt;` `&gt;` `&amp;` `&quot;` `&apos;` `&#..;` → `PROJECT-XML-003` variant `escaped-entity-in-cdata`(blocking)。
- 已知必須處理的構造(第二輪 review 的最小反例):
  - **條件編譯 pragma** `{IF defined(...)}` / `{ELSIF}` / `{ELSE}` / `{END_IF}`:兩個分支都掃會造成區塊不配對(誤擋)或把被排除的呼叫算進來(漏抓);linter 不知道 compile define,沒啟用的分支本來就可能不是合法程式碼(`st-syntax-inventory.md`)。MVP:物件內一出現 `{IF` 就整個物件記 `notAnalyzed`(reason `conditional-pragma`);宣告區的條件 pragma 從 build 4024 起才會被評估(InfoSys)。
  - **型別位置的非典型語法**:`FB_X<100>`(`VAR_GENERIC CONSTANT`,4026 起)、`fb : FB_X(nComNum := 1);`(FB_init 參數)、`ARRAY[*]`(只在 VAR_IN_OUT)要認得;運算式內允許 `:=`、`=>` 右側可留空。
  - InfoSys 查不到的 `?=` 與 `**`:InfoSys 沒收錄不代表編譯器不收,lexer 要認得這兩個 token,物件記 `notAnalyzed`(reason `unverified-syntax`),不判 parse fail。
  - **`__TRY` / `__CATCH` / `__FINALLY` / `__ENDTRY`**:當區塊關鍵字;CATCH 分支算條件區塊。
  - **`S=`、`R=`、`REF=`**:tokenizer 要認得,不得丟 `unexpected char`;`S=` / `R=` 的左值算寫入。
  - **`VAR_GENERIC CONSTANT`**:宣告 parser 認得或安全略過。
  - **typed literal**:依前綴各自定義字元集合,`T#1S-tonB.ET` 不得被吞成一個 token(prototype 的錯誤)。
- 每項是否合法、版本限制:以 `research/st-syntax-inventory.md` 的 InfoSys 連結為準;查不到的標未驗證,並在 tasks 排實測。

**Tokenizer**(prototype 已實作並在語料 100% 通過):
- 註解 `//`、`(* *)`(可巢狀)、`/* */`(TwinCAT 3 是否支援 `/* */`:**未驗證**,prototype 有支援,產品版要查 InfoSys 或實測再決定)。
- 字串 `'..'`(STRING)、`".."`(WSTRING),`$` 跳脫(`$'`、`$N`、`$$`、`$hh`);字串內不得換行。
- pragma / attribute `{...}` 整個當一個 token(用於 suppression 判斷與屬性讀取,例如 `{attribute 'qualified_only'}`)。
- typed literal:`T#1s`、`TIME#..`、`LTIME#`、`DT#`、`D#`、`TOD#`、`INT#5`、`16#FF`、`2#1010_0101`、`1.5E-3`。
- 直接位址 `%IX0.0`、`%QW2`、`%I*`。
- 關鍵字不分大小寫;識別字比對一律 `OrdinalIgnoreCase`。
- 每個 token 帶 section 內行號與欄號。

**宣告區 parser**:
- 物件頭:`PROGRAM` `FUNCTION_BLOCK` `FUNCTION` `METHOD` `PROPERTY` `INTERFACE` `TYPE … END_TYPE` `ACTION`;修飾 `PUBLIC/PRIVATE/PROTECTED/INTERNAL/ABSTRACT/FINAL`;`EXTENDS`、`IMPLEMENTS a, b`;回傳型別。
- VAR 區段:`VAR` `VAR_INPUT` `VAR_OUTPUT` `VAR_IN_OUT` `VAR_GLOBAL` `VAR_TEMP` `VAR_STAT` `VAR_INST` `VAR_EXTERNAL` `VAR_CONFIG`,加 `CONSTANT` `RETAIN` `PERSISTENT`。
- 變數行:多名稱、`AT %..`、型別(`ARRAY[..] OF`、`POINTER TO`、`REFERENCE TO`、`STRING(80)`、qualified 名稱)、初值(不解析 expression,只保留文字)、行前的 attribute。
- TYPE:`STRUCT`(含 `EXTENDS`)、`UNION`、ENUM(成員、明確值、base type、預設值)、alias。
- 不做:完整 expression AST、初值求值、`VAR_CONFIG` 對應。

**陳述式層級(不建完整 AST)**:
- IF/ELSIF/ELSE/CASE/FOR/WHILE/REPEAT 配對與巢狀深度;每個 IF 的分支數與有無 ELSE(prototype 的 SCAN-TIMER 精化需要)。
- 呼叫點:任何位置的 designator 後接 `(` 都記錄(review S11),分兩類:**FB body 呼叫**(`inst(...)`,只會在陳述式起點)與 **Method / 函式呼叫**(`inst.M_Do()`,可能在 expression 內,例如 `bOk := fb.M_Update();`、`IF fb.M_Done() THEN`),後者帶 `inExpression` 與「回傳值是否被使用」;都記錄所在區塊堆疊。`END_*` 後不接分號仍算陳述式起點(語料實際寫法)。prototype 只認陳述式起點,是已知缺口。
- 識別字引用集合、成員存取集合(`fb.Q`)。
- Phase 3 才加:賦值左值、RETURN/EXIT/CONTINUE 位置與可達性。

**TcPOU XML**:語料實際出現 `<POU>` `<DUT>` `<GVL>` 與子物件 `<Method>` `<Action>`;`<LineIds>` 忽略。**`<Itf>`(.TcIO)、`<Property>`(`<Get>` `<Set>`)、`<Transition>` 的結構未驗證**:語料沒有這些物件,prototype 的 seeded Interface XML 是我自己寫的(review S15:seeded S10/S11 命中是循環論證)。Phase 1a(tasks 1a.8)要在本機副本用 `AddInterface` / `AddPouMember` 建出真實物件當 fixture,再寫讀取程式。`<Implementation>` 下有多個 `<ST>` 元素:**語料沒有**(初稿誤記 bfh `FB_MachineCtrl` 有,`research/tc-xml-schema-observed.md` 第 3 節更正);XAE 會不會產生這種結構未驗證。防禦性處理:遇到時該物件回報 `LINT-XML-002` warning、全部串接分析,但 diagnostics 標 `lineUnreliable: true`(串接會讓行號對不上 `Get-TcPouCode`,review N4)。

**非 ST 實作(SFC / CFC / LD / FBD / IL / NWL)與 PLCopen XML**:不分析。
- 該 section 記進 `data.coverage.notAnalyzed[]`,reason `language:CFC` 等。
- 依賴該物件呼叫點的規則(例如 SCAN-FBCALL 在一個有 CFC Action 的 FB 上)對**整個物件**不評估,記進 `data.coverage.rulesSkipped[]`,reason `object-partially-analyzed`(prototype:axis `FB_AxisControl` 有一個 CFC Action,整個 FB 的 SCAN 規則不跑,否則會把 CFC 裡的呼叫當「沒有呼叫點」)。
- PLCopen XML(`.xml` 匯入檔)不是 `LintProject` 的輸入;要檢查就先 `ImportPlcOpen` 再 lint 專案。

**coverage 與 verdict**(見 D4):`data.coverage = { objectsInScope, objectsAnalyzed, notAnalyzed[], excluded[], rulesSkipped[], blockingRulesSkipped[], rulesNotRun[] }`。

- coverage 缺口**按規則計算**(review S5):非 ST 的 section 只影響「需要該 section 的規則」(SCAN-*、POLICY-CALL/RETVAL);PROJECT-*、CONTRACT-DUT/ENUM、宣告區規則照跑、不受影響。否則一個 CFC Action 會讓整個專案永遠 `incomplete`,逼使用者大量 exclude。
- 某條**預設 blocking** 的規則對某物件沒評估(例:CONTRACT-ITF 遇到 library 裡的 Interface,review S1)→ 記進 `blockingRulesSkipped[]`,verdict 為 `incomplete`;要接受這種缺口,profile 必須在 `acceptSkips[]` 明列(ruleId + objectPath + 理由),接受的項目列在輸出。
- 非 blocking 規則的跳過只記 `rulesSkipped[]`,不影響 verdict。
- **例外:個別位置的跳過**(#286 N3;Phase 2a 起,實作 `LintRules2a.cs` `Skip2` / `SkipSection`):SCAN-LOOP-001 / SCAN-FOR-001 / SCAN-ARR-001 / SAFETY-ARR-001 / SAFETY-DIV-001 雖然預設 blocking,但在**某個位置**證明不了(名稱解析不到、可能 alias、迴圈內有呼叫、值不是常數、library 符號 `library-symbol-unresolved:<名稱>` 等)而不報時,只記 `rulesSkipped[]`(帶 ruleId 與 reason),**不進** `blockingRulesSkipped[]`,verdict 不因此變 `incomplete`。理由:這些規則只在判斷確定時 blocking,合法程式大量出現這類位置(呼叫 FB、library 常數),若算 incomplete 會讓結果長期 `success: false`,與上一條 compilerCatches 的理由相同。只有整個 implementation section 的狀態是 `unsupported`(不認得的語法)時,這些規則才經 `SkipBlocking` 進 `blockingRulesSkipped[]`(verdict `incomplete`);`not-analyzed` 的 section(條件 pragma 等)同樣只記 `rulesSkipped[]`。與 `rule-catalog.md` 各規則的「證明不了 → 不報、記 rulesSkipped」一致。
- **`compilerCatches = yes` 的規則不進 `blockingRulesSkipped[]`**,只記 `rulesSkipped[]`(review 第二輪 1-3):Build 才是這類錯誤的權威;否則專案大量使用 library Interface(Tc3_EventLogger 等)時,CONTRACT-ITF 會讓每次結果都 `incomplete`,agent 會學會忽略 `success: false`。
- `exclude` 的 section 仍讓父物件算 partially-analyzed(review S4):排除 CFC Action 不會讓 SCAN 規則開始評估那個 FB;`exclude` 只免除 ST 分析,PROJECT-* 照跑。

### D4. Fail-closed 語意

`data.verdict` 三值:`pass` | `fail` | `incomplete`。`data.passed = (verdict == "pass")`。`success` 只在 `verdict == pass` 時為 true,但 **warning-only 是 pass**(issue 驗收條件:warning-only 不得誤報成 tool failure)。

| 情境 | verdict | success | passed | error.code | data |
|---|---|---|---|---|---|
| 沒有 finding,或只有非 blocking finding | pass | true | true | — | diagnostics 照列;有 behavior / crash 類 warning 時 `requiresDisposition: true` + `unresolved[]`(D6) |
| 有 blocking finding | fail | false | false | `LINT_FAILED` | 完整 diagnostics |
| 有物件解析失敗(tokenize / 宣告 / 區塊結構) | fail | false | false | `LINT_PARSE_FAILED` | `LINT-PARSE-*` diagnostic(blocking)+ 其他物件照跑的結果 |
| 有規則需要的 section 沒分析到(非 ST、XML 讀不到但檔案存在),或預設 blocking 規則被跳過且未 `acceptSkips` | incomplete | false | false | `LINT_INCOMPLETE` | `coverage.notAnalyzed[]` / `blockingRulesSkipped[]` |
| text-only 的 LintCandidate 需要專案 context | incomplete | false | false | `LINT_CONTEXT_REQUIRED` | context-free 的規則照跑 |
| profile 檔不存在 / JSON 錯 / schema 不符 / 未知 rule id;`.tcauto/` 存在但 profile 讀不到 | 不輸出 | false | 不輸出 | `LINT_PROFILE_INVALID` | 不跑任何規則 |
| baseline 檔壞掉;profile 要求 baseline 但找不到;預設位置有 baseline 但被 profile 關掉卻沒列 override 理由 | 不輸出 | false | 不輸出 | `LINT_BASELINE_INVALID` | 不跑任何規則 |
| 多 PLC 未指定 | 不輸出 | false | 不輸出 | `PLC_PROJECT_AMBIGUOUS` | `data.plcProjects`(與既有慣例相同) |
| 指定的 PLC / 檔案找不到 | 不輸出 | false | 不輸出 | `PLC_PROJECT_NOT_FOUND` / `LINT_INPUT_INVALID` | |
| `.plcproj` 本身 XML 壞掉 | fail | false | false | `LINT_PARSE_FAILED` | |
| IDE 已連線且 stale / 讀不到目標專案的狀態 | 不輸出 | false | 不輸出 | `LINT_SOURCE_STALE` / `LINT_SOURCE_UNVERIFIED` | `data.unsaved` |
| 參數錯(未知 ObjectKind、Implementation 非 ST、overlay 名稱 / 種類不符…) | 不輸出 | false | 不輸出 | `LINT_INPUT_INVALID` | |
| 引擎內部例外 | 不輸出 | false | 不輸出 | `LINT_ENGINE_ERROR` | 例外放 `data.engineDetail`;**不得**退回「部分結果 + passed」 |
| Constrained Language Mode、`Add-Type` 被擋 / csc 失敗 | 不輸出 | false | 不輸出 | `LINT_ENGINE_UNAVAILABLE` | `data.languageMode`;hint 指向環境(D1) |

- 處理順序(也是 code 優先序,review S17):引擎可用性(`LINT_ENGINE_UNAVAILABLE`)→ 解析輸入與 PLC(`LINT_INPUT_INVALID` / `PLC_PROJECT_*`)→ stale 檢查(`LINT_SOURCE_*`)→ 載入 profile(要知道 solution 目錄才能探索)→ baseline → 分析。分析後多種結果並存時:`LINT_ENGINE_ERROR` > `LINT_PARSE_FAILED` > `LINT_CONTEXT_REQUIRED` > `LINT_INCOMPLETE` > `LINT_FAILED`。diagnostics 一律完整保留。
- `LINT_PARSE_FAILED` 只用在 D3 的「不支援即 parse fail」類;含任何「安全略過」構造的物件一律降級為 `notAnalyzed`。
- `LINT_INCOMPLETE` 與 `LINT_FAILED` 的優先序(第二輪審查 nit,實作與本段一致):`blockingRulesSkipped` 非空(含 `unsupported` 段落、`too-large` 檔)或檔案讀不到 → `LINT_INCOMPLETE`,優先於 `LINT_FAILED`。另外「範圍內物件沒全部分析到、沒有載入專案、或 0 個物件」也是 incomplete,**但只在沒有任何 blocking finding 時**:一個 XML 壞掉的檔本身已有 blocking 的 PROJECT-XML-001,回 `LINT_FAILED` 比 `LINT_INCOMPLETE` 更直接指出要修什麼;若 profile 把那條規則關掉,就沒有 blocking finding,改回 incomplete(不會變 pass)。
- 「不輸出」= `data.passed` 欄位不存在(不是 false),避免呼叫者只看 `passed` 欄位。
- **parser 誤擋的出口**:`LINT_PARSE_FAILED` 可能是我們的 parser 不支援某個合法語法。hint 寫明:先 `BuildProject`;若 Build 成功,這是 linter 的限制 → 開 issue,並在 profile `exclude` 中帶理由排除該物件(排除的物件列在 `coverage.excluded[]`,不算 `notAnalyzed`)。不提供「忽略 parse 錯誤」的參數。
- 每個新 error code 依 `CODING_STANDARDS.md` 第 5 節進 `$script:TcErrorHints` 並在 `docs/troubleshooting.md` 有一節(`scripts/check.ps1` 的 `errorcodes` 會檢查)。
- lint 失敗**不觸發** lifecycle block(lint 不改 runtime),也不得改走 COM / DTE / GUI fallback。

### D5. 規則引擎、suppression、profile、baseline、排序

**Rule metadata**(C# 內的靜態註冊表;`GetLintRule` 之後從同一份資料輸出):

```text
id            SCAN-TIMER-001(穩定;語意大改就換新 id,不改 version 偷換)
version       整數;偵測邏輯改變就 +1(diagnostic 帶 ruleVersion)
category      ST / SCAN / CONTRACT / PROJECT / SAFETY / POLICY
severity      預設 error / warning / info
confidence    high / medium / low
blockable     能不能當 blocking(heuristic 規則 false;profile 可以明確覆寫,見下)
requires      前置條件:project-context / baseline / ide / type-catalog
appliesTo     TwinCAT 版本或語言限制;不知道就寫 "unknown"
limits        已知誤報來源(文字,給 GetLintRule)
te1200        對應的 SA 規則與版別(Light / Full)
compilerCatches  yes / no / unknown / measured:<日期>(mutation testing 以 BuildProject 實測後填,D7)
machineImpact none / project-integrity / behavior / crash(owner 決定 1;分期與「必須處置」都依這欄)
phase         1a / 1b / 2 / 3 / 4(見 rule-catalog.md)
```

`blockable` 的預設:判斷確定(偵測不依賴猜測)的規則預設 `true`(owner 決定 2,例:SCAN-TEMPFB-001、SCAN-LOOP-001、SCAN-FOR-001);依賴未實測 XAE 行為的 `pending`;heuristic 的 `false`。

**blocking 的計算**(每筆 finding):`blocking = !suppressed && severity >= FailOn && (confidence == high || profile 對此 rule 明確設 "blocking": true)`,且 `blockable == false` 的規則**不受 `FailOn` 影響**,只有 profile 明確設 `"blocking": true` 才會 blocking(review S17:否則 `-FailOn warning` 會讓 COMPILE-003 擋掉 `_bak` 檔);此時 diagnostic 帶 `blockingSource: "profile"`。`FailOn` 預設 `error`;可設 `warning`;不提供 `never`。參數 `-FailOn` 優先於 profile 的 `failOn`,但只能更嚴、不能更鬆(profile 說 `warning`、參數說 `error` → 用 `warning`)。

`blockable` 有三值:`true`、`false`、`pending`。`pending` = 偵測是確定的,但「這是不是 bug」依賴未實測的 XAE 行為(review S14):severity 照 error,blocking 照算,但 diagnostic 帶 `blockableBasis: "pending-measurement"`,Phase 1a(tasks 1a.7)實測完改成 true 或 false。

**Suppression**:用 ST 註解,不用 pragma(InfoSys:"Pragmas unknown to the compiler are read over like a comment.",見 `st-syntax-inventory.md`;用註解仍比較單純,不會出現在 attribute 查詢或 TE1200 的 pragma 處理裡)。

```iecst
// tcauto-lint-disable-next-line SCAN-TIMER-001: 測試模式切換器,切回時重新 arm 是預期行為
R_14Eng(CLK := b14Engage);

tonRelease : TON; // tcauto-lint-disable-line SCAN-FBCALL-001: 由 FB_Base.M_Cycle 呼叫
```

- 形式:`tcauto-lint-disable-next-line <RULE-ID>[, <RULE-ID>]: <理由>`、`tcauto-lint-disable-line …`、物件層級 `tcauto-lint-disable-object …`(只能寫在宣告區第一個 VAR 之前)。沿用 repo `tcauto-allow(<rule>): <reason>` 的「理由至少 8 字」。
- 沒有理由、理由太短 → suppression 不生效,另出 `LINT-SUPPRESS-001`(warning,`blockable`;default profile 是 warning,不 blocking)。未知 rule id → `LINT-SUPPRESS-002`。沒壓到任何 finding → `LINT-SUPPRESS-003` info。
- 被壓掉的 finding 仍列在 diagnostics,`suppressed: true` + `suppressionReason`,不計入 summary 的 errors / warnings(另計 `suppressed`)。
- 不能改原始碼的物件(library、產生的程式)用 profile 的 `suppressions[]`(`objectPath` + `ruleId` + `reason`,不接受 wildcard objectPath)。
- **被檢查的 LLM 不能自己壓掉 blocking**(review B3):寫 suppression 的通常就是被檢查的 agent,8 字理由擋不住它。
  - `blockable == true / pending` 的規則(例如 PROJECT-XML / GUID / COMPILE、CONTRACT-*、LINT-PARSE-*;依每條規則與 variant 的 blockable 判斷,PROJECT-TASK-001 是 false,可以 inline;profile 設 `blocking: true` 的規則也不行)**不接受 inline suppression**,只能用 profile `suppressions[]`(進版控、有人 review);inline 寫了 → suppression 不生效,另出 `LINT-SUPPRESS-004`。
  - `tcauto-lint-disable-object` 只能壓非 blockable 規則。
  - `newSuppressions[]` 的比對基準(review 驗證 7):`LintCandidate` = 候選 vs 磁碟版本;`LintProject` = 磁碟版本 vs solution 目錄所在 git repo 的 HEAD(`git show HEAD:<path>`,只讀)。不是 git repo 或讀不到 HEAD → `data.newSuppressionsBasis: "unavailable"`,並在 `data.suppressions[]` 列出範圍內**所有** suppression,SKILL.md 規定此時全部列給使用者。**PR #283 審查後(B1 / SF6)**:基準改為 origin 預設分支(`origin/HEAD` / `origin/master` / `origin/main`)的 merge-base,任何 remote 的 `refs/remotes/<remote>/HEAD` 也算預設分支;都沒有才用 `@{upstream}`(upstream 已包含 HEAD 時視為 unavailable,最終驗證 review),再沒有才用 HEAD(agent 自己 commit / `push -u` 不會清空;驗證 review N1:先用 upstream 時 push 後就清空);`newSuppressions[]` 非空也讓 `requiresDisposition = true`(reason `new-suppressions`,review N4);profile 的其他放寬(rules 停用 / 降級、exclude、acceptSkips、baseline 關閉)相對同一基準列在 `data.newOverrides[]`(`added` / `modified`),非空時 `requiresDisposition = true`;git 呼叫共用 20 s deadline,逾時 = unavailable。規定:列給使用者確認之前不准 commit suppression / profile 改動。Phase 1b 實作(保守選擇):`unavailable`(含 git 不在 PATH、沒有 HEAD commit、`git` 逾時)時 `newSuppressions[]` 也等於全部 suppression;檔案不在 HEAD(新檔)→ 它的 suppression 全部算新;比對鍵 = 種類 + rule id + 理由(不含行號);profile 的 `suppressions[]` 也比對 HEAD 版本的 profile。只用 `git rev-parse` / `git show`(`GIT_OPTIONAL_LOCKS=0`)。
  - profile 若是本次工作期間被改動的(sha256 與 git HEAD 不同,或檔案 mtime 晚於 session 開始 — 判斷方式 Phase 2 決定),在 `data.profile.modifiedSinceCommit` 標示。

**Profile**(純 JSON 資料,不得含程式):

```json
{
  "schema": "tcauto-lint-profile/1",
  "extends": "default",
  "failOn": "error",
  "rules": {
    "SCAN-TIMER-001": { "enabled": true, "severity": "error", "blocking": true },
    "POLICY-SYMBOL-001": { "enabled": true, "params": { "forbidden": ["MEMSET", "MEMCPY"] } },
    "POLICY-NAME-001": { "enabled": true, "params": { "prefix": { "FunctionBlock": "FB_", "Interface": "I_", "Struct": "ST_", "Enum": "E_" } } }
  },
  "typeCatalog": { "functionBlocks": ["FB_PackMLBase"], "cyclicContract": ["FB_ServiceBase.M_UpdateService"] },
  "exclude": [ { "objectPath": "FB_AxisControl.A90_Cyclic", "reason": "CFC,由 Build 與人工 review 把關" } ],
  "suppressions": [ { "objectPath": "FB_Lib.FB_X", "ruleId": "SCAN-FBCALL-001", "reason": "library 物件,不可修改" } ],
  "baseline": "lint-baseline.json"
}
```

- 載入:`-RuleProfile` 給內建名稱(`default`、之後的 `robust-solution`)或檔案路徑。未給時自動探索(review S3):從 `.plcproj` 所在目錄往上找,遇到第一個含 `.sln` 的目錄、或 git root、或磁碟根就停;途中第一個 `.tcauto\lint-profile.json` 生效。`.tcauto\` 存在但 profile 讀不到 / 壞掉 → `LINT_PROFILE_INVALID`(不退回 default)。text-only 的 LintCandidate 不探索,用 `default` 並在 `data.profile.source` 寫明。
- `data.profile = { name, source, sha256, overrides[] }` 一律回報。`overrides[]` 列出所有相對 default 變弱的設定:被關掉或降級的預設 blocking 規則、`exclude`、`acceptSkips`、`suppressions`、拿掉的 baseline。agent 偷改 profile 會直接出現在輸出。(是否自動探索 → 見 Open Questions 2。)
- 驗證:未知欄位、未知 rule id、型別錯、`extends` 循環、`exclude` / `suppressions` 沒理由 → `LINT_PROFILE_INVALID`,不跑。
- 樣式比對只支援精確名稱與 glob(`*` `?`),**不支援 regex**(避免 catastrophic backtracking 把 lint 卡死;之後若要 regex,用 .NET `Regex` 的 matchTimeout 並在逾時時 fail closed)。
- 不可執行:沒有 script、沒有路徑注入(profile 內的路徑一律相對 profile 檔所在目錄,解析後不得跳出 solution 目錄)。

**Baseline**(CONTRACT-ENUM / CONTRACT-DUT / 之後的 CONTRACT-ITF 相容性用):

```json
{
  "schema": "tcauto-lint-baseline/1",
  "source": { "plcproj": "PLC1/PLC1.plcproj", "note": "v1.2.0 發佈時的公開型別" },
  "types": {
    "E_MachineMode": { "kind": "ENUM", "members": [ { "name": "Manual", "value": "0" }, { "name": "Auto", "value": "1" } ] },
    "ST_EL1889": { "kind": "STRUCT", "fields": [ { "name": "DI1", "type": "BIT" }, { "name": "DI2", "type": "BIT" } ] }
  }
}
```

- baseline 列出的就是公開契約;沒列的型別不檢查。**沒有 baseline 時 CONTRACT-ENUM / DUT 不跑**(記 `rulesNotRun`,reason `no-baseline`),不猜。
- 探索(review S10):預設位置 `.tcauto\lint-baseline.json` 有檔就一律載入,不需要 profile 指定;profile 要關掉它必須明寫並列進 `overrides[]`。
- 比對以 **baseline 為主迴圈**(review S8;prototype 是以目前型別為主,會漏):baseline 有、目前沒有 → CONTRACT-*-001(型別刪除或改名);kind 不同(ENUM → ALIAS)→ 報;比對前展開 STRUCT `EXTENDS` 的基底欄位與專案內 alias;`{attribute 'pack_mode'}`、ENUM base type、alias 底層型別都納入比對(都會改 ADS layout)。
- 數值比對前把 IEC 整數字面值正規化成數值(`16#0A`、`INT#10`、`10` 視為相同,一律 `CultureInfo.InvariantCulture`,review S9);無法求值的 expression 才降為 warning/medium 並比對文字。
- 產生 baseline 是寫檔動作 → 獨立 cmdlet `New-TcLintBaseline`(Phase 4),顯示內容、不覆寫既有檔(除非 `-Force`)。MVP 只讀 baseline。
- 放哪:建議 `<solution 目錄>\.tcauto\lint-baseline.json`,進版本控制(見 Open Questions 3)。
- 隱含 enum 值:InfoSys:"starting at 0, the values are incremented consecutively by 1."(https://infosys.beckhoff.com/content/1033/tc3_plc_intro/2529504395.html);**部分成員有明確值時後面成員怎麼接**未驗證(tasks 4.0 實測);前一個是非整數 expression 時記為未知,該成員只比對名稱,並出 `rulesSkipped`(prototype 的 S12 就是隱含值跟著變:`Manual 0→1` 讓 `Auto 1→2`,兩筆都報)。

**Diagnostic 格式**(issue 的 schema 加上欄位):

```json
{
  "ruleId": "SCAN-TIMER-001", "ruleVersion": 1, "severity": "warning", "confidence": "medium",
  "blocking": false, "suppressed": false,
  "file": "30_RollToRoll/Fb/RollToRoll/FB_R2RLineControl.TcPOU",
  "objectPath": "FB_R2RLineControl", "section": "implementation", "line": 14, "column": 1,
  "message": "...", "evidence": "IF state = 3 THEN tonWebBreak(...)", "fixHint": "...", "autoFix": "none"
}
```

- `objectPath`:物件名 + 子物件(`FB_X.M_Run`、`FB_X.P_Value.Get`),與 `Write-TcPouCode -PouName` 同格式,agent 可直接拿去寫。`file` 是相對 `.plcproj` 目錄、`/` 分隔。IDE 樹路徑(`TIPC^…`)不從磁碟推算(磁碟資料夾與樹路徑是否 1:1:**未驗證**)。
- `line` / `column`:section 內的 1-based 位置(與 `Get-TcPouCode` 回傳的文字一致,不是 .TcPOU 檔案行號)。
- 不輸出時間戳與耗時(`-IncludeTiming` 才加 `data.timing`),確保同輸入 byte 相同。
- `message` 只用固定英文模板 + 結構化欄位;.NET 例外訊息(例如在地化的 `XmlException`)放 `data.engineDetail`,不進 diagnostics(review S16;prototype 的 `LoadError = e.Message` 會讓 zh-TW / en-US 輸出不同)。所有數值解析用 `InvariantCulture`。

**排序**(穩定、與 culture 無關):`file`(ordinal,先轉小寫 invariant)→ `objectPath` → section 順序(declaration < implementation)→ `line` → `column` → `ruleId`(ordinal)→ `message`(ordinal)。所有比較用 `StringComparer.Ordinal` / `ToLowerInvariant`;不依賴 `Dictionary` 列舉順序;檔案清單先排序再處理。CI 在 en-US 與 zh-TW culture 各跑一次比對 byte(本機 PowerShell tool 是 en-US、Bash 的 powershell.exe 是 zh-TW)。

### D6. Warning 的處置機制(owner 決定 3)

`success: true` 的 warning 會被 LLM agent 直接略過(review 第二輪 1-2)。加一層「必須處置」:

- `data.unresolved[]`:未被 suppress、`machineImpact ∈ behavior / crash` 的 finding(含 warning;**不含 info**,PR #284:SAFETY-DIV-001 變數除數 47 筆語料 finding 只有 1 筆是真問題候選,info 是參考,profile 把 severity 調高才進來)。每筆帶 diagnostic 的 `ruleId` / `objectPath` / `line`。
- `data.requiresDisposition: true`:`unresolved[]` 非空時。`success` 仍是 true(issue:warning-only 不得誤報成 tool failure)。
- 處置只有兩種:**改程式**,或**寫 inline suppression 加理由**。非 blockable 規則才允許 inline(D5),理由留在原始碼 diff 裡給人 review;blockable 規則只能用 profile `suppressions[]`。
- `data.newSuppressions[]`:本次候選 / 本次變更新增、磁碟版本(或 git HEAD)沒有的 suppression,逐條列出(規則、物件、行、理由)。
- **SKILL.md Failure contract 要寫明**:`requiresDisposition: true` 時 agent 不得呼叫 `EnableConfig` / `RunLifecycle`,也不得回報完成;必須逐條改程式或 suppress,並把 `newSuppressions[]` 逐條列給使用者。
- **EnableConfig / RunLifecycle 整合分兩段**:
  1. **advisory**(Phase 3):Activate 前自動跑 `LintProject`,摘要放 `data.lint`(`verdict`、`unresolved` 數、`newSuppressions`、`ideChecked`),**不擋**。lint 失敗(例如 `LINT_ENGINE_UNAVAILABLE`)也只記在 `data.lint`,不影響 EnableConfig 的結果。
  2. **blocking**(Phase 4):D2 的 stale 偵測真機驗證後,`-LintGate` 打開時 `unresolved > 0` 或 verdict 不是 pass → `LINT_GATE_BLOCKED`(不記 lifecycle block,runtime 沒動)。只接受 `ideChecked: true` 的結果。
- `compilerCatches = yes` 的規則不進 `unresolved[]`(Build 會擋)。

### D7. 測試與驗證方法

**測試層**:

| 層 | 內容 | 跑在 |
|---|---|---|
| tokenizer / parser fixture | `research/st-syntax-inventory.md` 每一項各一組正例;「安全略過」類斷言結果是 `notAnalyzed` 而不是 `LINT_PARSE_FAILED`;真實語料撞過的坑(`END_IF` 不接分號、多個 `<ST>`、巢狀 `(* *)`、`$'` 跳脫、中文註解、BOM);第二輪 review 6-1~6-4 的最小反例(條件 pragma、`__TRY`、`?=`、`T#1S-tonB.ET`) | `tests/Unit/lint-parser.ps1` |
| XML fixture | `research/tc-xml-schema-observed.md` 的每種物件:XAE 產生的原樣(反例,不得報)+ 每條 PROJECT-XML / GUID / COMPILE / TSPROJ 規則的破壞版(正例) | `tests/Unit/lint-project-xml.ps1` |
| 規則 fixture | 每條規則:至少 2 個正例、2 個反例(含已知誤報來源)、1 個 suppression 案例 | `tests/Unit/lint-rules-<category>.ps1` |
| 契約 | D4 每一列一個 case;`passed` 欄位在未分析時不存在;code 優先序;`unresolved[]` / `requiresDisposition` / `newSuppressions[]` | `tests/Unit/lint-contract.ps1` |
| deterministic | 同輸入兩次 byte 相同;en-US 與 zh-TW culture 相同;檔案列舉順序打亂後相同 | 同上 |
| 語料回歸 | 解析 100%、不 crash、finding 快照(語料是否進 repo 見 Open Questions 1) | unit |
| 效能預算 | ≤ 200 物件的專案 ≤ 2 s(不含首次編譯);首次編譯只記錄 | unit(序列組) |
| 整合 | 真實 `.TcPOU` / `.plcproj`,不需 runtime;stale 偵測要 IDE → 真機 worker 用 registered tcauto | 真機,不進 CI |

**驗證方法**(review 第二輪 5-1;現有 seeded 15/15 只證明規則有實作,不證明召回率):

1. **凍結的錯誤分類清單**:先列「LLM / 現場真的犯過的 PLC 錯誤」,凍結後才用它算召回率,避免自己出題自己抓。初版由 issue #252 與知識庫整理(`research/error-taxonomy-draft.md`,標「待 owner 確認」);owner 之後提供的清單(owner 決定 5)併入後凍結。
2. **LLM 產生語料 + 盲標**:2–3 個模型 × 約 30 個典型任務(輸送帶超時、氣缸回授、MC_Home 流程、PackML 狀態機、警報 latch)。在本機 XAE 只做 `BuildProject`(不碰 runtime),留能編譯的版本;owner 在不看 lint 結果的情況下標出真 bug;算每條規則的 precision / recall,並與 TE1200 Light 跑同一批比較。瓶頸是 owner 標註時間(估數小時)。
3. **Mutation testing + 以 BuildProject 實測 `compilerCatches`**:依錯誤分類寫 mutation operator(把呼叫包進 IF、刪掉 PT、TON 搬進 METHOD VAR、`[1..N]` 改 0-based 迴圈、加 busy-wait、XML 改壞、GUID 重複…),對語料批次產生變種,每個變種跑 `BuildProject`(只需 IDE)。metadata 的 `compilerCatches` 改成 `measured:<日期>` 實測值,不再是推論。
4. **Holdout 專案**:owner 之後提供的第三個以上專案不得用來調規則;規則凍結後跑一次報誤報率。**接受門檻事先寫明**(見 tasks 3.x):blocking 規則在 holdout 上誤報 = 0;warning 規則誤報率 ≤ 20%;否則該規則不得升級。
5. **git 歷史反向植入**(視 owner 專案有無 git 歷史):把 commit message 含 fix 的修正反轉回去當 seed。

mock 依據照 `docs/testing-policy.md` 第 3 節標註;未實測的 XAE 行為一律標 `[推論]`。

### D8. 效能與資源

- 首次 `Add-Type` 0.7–1.0 s(實測);之後每專案 50–160 ms(實測,2 個專案)。
- 記憶體:prototype 用 `XmlDocument`,axis 專案 GC heap 增量約 42 MB。產品版改用 `XmlReader` 串流讀 `.TcPOU`,不保留 DOM。
- 不做跨呼叫的快取(MVP);`Scope=Object` 只解析範圍內物件 + 規則需要的 context。

### D9. Agent 工作流整合

**透過 COM 寫入(主要路徑)**:

```text
產生候選程式碼
  -> LintCandidate -PlcProjectPath <plcproj>   (寫入前;LINT_FAILED 就改,不寫;requiresDisposition 就處置)
  -> WritePouCode
  -> BuildProject                               (編譯器是最終權威)
  -> LintProject                                (跨物件與專案層級)
  -> 處置 unresolved[] / 列出 newSuppressions[]
  -> EnableConfig(Phase 3 起附 data.lint 摘要)
```

**直接改磁碟檔(CLAUDE.md「Editing project files on disk」、`docs/troubleshooting.md`「磁碟改檔的正確做法」)**:

```text
改 .TcPOU / .plcproj / .tsproj
  -> LintProject(磁碟)        (PROJECT-XML / GUID / COMPILE / TSPROJ 先擋;不需要 IDE)
  -> 通過才 ResetSolution       (XAE 讀到的是已檢查過的檔案)
  -> BuildProject
```

- 這一步要加進 SKILL.md 與 CLAUDE.md 的磁碟改檔段落(tasks 1b)。順序的理由:XAE 載入損毀檔案的行為未驗證(可能跳框、物件消失),先在磁碟擋下比較便宜。
- tool description 要寫清楚:`passed: true` 不代表程式正確,只代表「列出的規則在分析到的範圍內沒有 blocking finding」;`coverage` 與 `unresolved[]` 要一起看。

### D10. 分期(每期一個可獨立 review / merge 的 PR,見 tasks.md)

| Phase | 內容 | 預設 blocking |
|---|---|---|
| 0 | 本設計 | — |
| 1a | 引擎、`LintProject`(磁碟)、契約(verdict / coverage / `unresolved` / `requiresDisposition` / machineImpact metadata)、語法清單的「安全略過」、PROJECT-XML / KIND / NAME / GUID / SUB / LINEIDS / COMPILE / LIB / TSPROJ / ENC 整類、IDE 實測(XAE 對每種損毀的行為、TE1200 Light 量測) | PROJECT-XML-001 / 003、LINT-PARSE-*;其餘 PROJECT-* `pending` |
| 1b | SCAN-TEMPFB-001、PROJECT-TASK-001 / 002、語法清單落實為「支援」、SKILL.md / CLAUDE.md 磁碟改檔工作流 | + SCAN-TEMPFB-001、PROJECT-TASK-002 |
| 2 | `LintCandidate`、suppression、型別目錄、SCAN-LOOP / FOR / ARR、SAFETY-ARR / DIV、SCAN-FBCALL、SCAN-TIMER-001 / 002 / 004 / 005、stale 偵測(真機)、SKILL.md 處置規定、PROJECT-SA-001(視量測) | + SCAN-LOOP-001、SCAN-FOR-001、SCAN-ARR-001、除以常數 0 |
| 3 | SCAN-SM / MC / REF / FBVAL / OUT / FLOAT / INTDIV;LLM 語料、mutation、holdout 驗證;EnableConfig advisory `data.lint` | 依驗證結果升級 |
| 4 | CONTRACT-* + baseline、`GetLintRule`、TE1200 SARIF 合併、POLICY / robust-solution / POLICY-INTERLOCK、`-LintGate` blocking 模式、ST-LLM-001 | profile 決定 |

### D11. TE1200 Light 的整合(owner 決定 4)

- 客戶只有 Light(7 條:SA0004 / 0006 / 0027 / 0028 / 0033 / 0167 / 0175,`research/te1200-rules.md`)。Full 版才有的檢查由本 linter 做(`rule-catalog.md` 的 TE1200 欄)。
- **Phase 1a IDE 量測**(只需 IDE、不需 runtime),回答:
  1. 新專案是否預設啟用 Light;
  2. Light 的結果會不會出現在 `BuildProject` 的 `errorItems`(Error List);
  3. `.plcproj` 裡怎麼設定才能啟用(哪個元素 / 屬性);
  4. 4026.20 以上能否經 Automation Interface(`RunStaticAnalysis` / `ExportToSarif`)取得 SARIF,Light 能不能用。
- 依結果:Phase 2 加 PROJECT-SA-001(專案沒啟用 SA0004 / SA0006 / SA0167);若 Light 結果已進 `errorItems`,`BuildProject` 的結果就已涵蓋,不另做。SARIF 合併放 Phase 4(Full 授權客戶才有意義)。
- 與 Light 重疊的自有規則(SCAN-TEMPFB-001 ↔ SA0167、SCAN-OUT-001 ↔ SA0004 / 0006)仍做:價值在寫入前擋與客戶沒啟用 Light 時。

## Risks / Trade-offs

- **語料太少、規則在同一語料上調出來** → SCAN 規則的「v2 零誤報」可能 overfit。緩解:holdout 專案 + 事先寫明的接受門檻(D7)。
- **parser 不支援合法語法 → 誤擋**。緩解:D3 的三類處理,不認得的構造降級為 `notAnalyzed`;語法清單逐項有 fixture。剩餘風險:清單沒列到的新語法造成區塊不配對 → 仍可能 `LINT_PARSE_FAILED`,hint 要求先 Build、Build 成功就開 issue。
- **判斷確定的 blocking 規則仍可能誤擋**(例如 PROJECT-TASK-002 遇到刻意的雙呼叫):只能用 profile `suppressions[]`(進版控、有人 review)排除。
- **型別目錄不完整 → SCAN 規則少評估**(列在 `rulesSkipped`,不是靜默)。
- **stale 偵測的盲點**:PLC editor 裡未存的 POU 內容是否偵測得到未驗證;4024 的 .TcPOU 落地時機未重測 → 4024 以 code-changed 紀錄保守判 stale。blocking 模式的 lifecycle gate 等真機驗證後才開。
- **ReloadModule 拿到舊引擎**:hash namespace;保底是 `ReloadRuntime`。
- **`Add-Type` 在受限環境失敗**:`LINT_ENGINE_UNAVAILABLE`,與既有 `TcAdsHelper` 同一個依賴。
- **agent 把 `passed: true` 當成「程式正確」**:`requiresDisposition` 與 SKILL.md 規定。
- **把 linter 當安全功能**:POLICY-INTERLOCK 等輸出明寫「不取代 TwinSAFE / 安全評估」。

## 已定案(owner,#252 留言「Owner 決定(Lance,2026-11-13)」)

| 原 Open Question / review 問題 | 決定 | 落實位置 |
|---|---|---|
| 分期依據(review 第二輪「需要 owner 決定」1) | Build 抓不到、會讓機台行為出錯的優先;CONTRACT 最後(決定 1) | 本檔開頭表、D10、`rule-catalog.md` |
| 確定性 SCAN 規則預設 blocking(第二輪 4) | 判斷確定的預設 blocking(決定 2) | D5 `blockable` 預設、`rule-catalog.md` |
| warning 處置政策與 lifecycle gate(第二輪 2;初稿 Open Question 6) | 必須處置;先 advisory、stale 真機驗證後才擋;newSuppressions 逐條列給使用者(決定 3) | D6 |
| 客戶的 TE1200 授權(第二輪 3;初稿 Open Question 9) | 只有 Light;Full 才有的自己做;量測 Light 能否經 BuildProject 取得(決定 4) | D11、`rule-catalog.md` |
| 更多語料、錯誤清單(初稿 Open Question 5;第二輪 5) | 之後提供,不擋 Phase 1(決定 5) | D7、tasks 3.x |
| AI 改磁碟檔的問題(新增) | 必須包含、不延後(決定 6) | `rule-catalog.md` 第 1 節、Phase 1a、D9 |
| 引擎發佈方式(第二輪 7) | 維持 `Add-Type`;採納 LanguageMode 檢查與 `LINT_ENGINE_UNAVAILABLE`;共用 helper 列為後續 | D1 |
| 安全互鎖規則(第二輪 6) | 排後期,輸出明寫不取代 TwinSAFE / 安全評估 | `rule-catalog.md` Phase 4 |

## Open Questions(仍待決定,附建議)

1. **語料進 repo**(初稿 4):建議從兩個測試專案挑 10–20 個檔放 `tests/Fixtures/lint-corpus/`;repo 是 public,需要 owner 確認可以公開。
2. **profile 自動探索**(初稿 1):建議要(D5 的探索演算法 + `overrides[]`)。
3. **baseline 位置**(初稿 2):建議 `<solution 目錄>\.tcauto\lint-baseline.json` 進版控,發版時用 `New-TcLintBaseline` 產生(Phase 4)。
4. **library 型別目錄的來源**(初稿 8):建議手寫版本化清單,每個名稱附 InfoSys 來源。
5. **錯誤分類清單初版**:`research/error-taxonomy-draft.md` 是否涵蓋 owner 心中的主要錯誤類型?等 owner 補充後凍結(D7)。
6. **holdout 接受門檻**:建議 blocking 規則誤報 0、warning 規則誤報率 ≤ 20%(D7),跑 holdout 前由 owner 確認。

## Review 紀錄

2026-11-13,`reviewer` subagent(唯讀),從「漏抓 / 誤擋 / fail open」三個角度挑戰初稿:3 blocker、18 should-fix、5 nit。

| # | 意見(摘要) | 處理 |
|---|---|---|
| B1 | D2 的前提錯:#69 實測 4026 上 `WritePouCode` 當下就落地;真正的 stale 是 `.plcproj`(#76),`Get-TcUnsavedChanges` 看不到;`Project.Saved` 不可靠;`.plcproj` 可能不屬於連線中的 solution | **採納**。D2 改用 `Reset-TcSolution` (1b) 的樹 / 磁碟比對 + Document.Saved + 4024 保守規則;先確認 `.plcproj` 屬於連線中的 solution。已讀 `docs/troubleshooting.md` 原文確認 |
| B2 | text-only 的 LintCandidate 跳過需要 context 的規則仍 pass,違反 issue「context 不足不得 PASS」 | **採納**。新 code `LINT_CONTEXT_REQUIRED`(verdict incomplete) |
| B3 | inline suppression 讓被檢查的 LLM 自己壓掉 blocking | **採納**。blockable 規則不接受 inline suppression(`LINT-SUPPRESS-004`);`data.newSuppressions[]`;`profile.overrides[]` |
| S1 | `rulesSkipped` 不影響 verdict,blocking 規則被跳過仍 pass | **採納**。`blockingRulesSkipped[]` → incomplete,profile `acceptSkips[]` 帶理由才接受 |
| S2 | overlay 邊界未定義,可能靜默 pass | **採納**。名稱 / 種類不符、Parent 不存在 → `LINT_INPUT_INVALID` |
| S3 | profile 探索未定義,可被 agent 改寫 | **採納**。明定探索演算法、`.tcauto/` 壞掉 fail closed、`overrides[]`、`-FailOn` 只能更嚴 |
| S4 | exclude 子物件後父物件被當完整分析 | **採納** |
| S5 | 一個非 ST 物件讓整個專案永遠 incomplete | **採納**。coverage 缺口按規則計算 |
| S6 | Scope 專案固定 `Unchecked` 會讓 LintProject 永遠 UNVERIFIED | **採納**。只看與目標 `.plcproj` 相關的項目 |
| S7 | LintCandidate 的 PlcProjectPath 與 ambiguity 慣例不一致 | **採納**。沿用 `Resolve-TcPlcProjectSpec`;範圍表修正 |
| S8 | baseline 比對以目前型別為主,刪除 / 改名 / kind 改變 / EXTENDS / pack_mode / base type 漏抓 | **採納** |
| S9 | enum 值文字比對誤擋(`10` vs `16#0A`) | **採納**。數值正規化;隱含 +1 標未驗證 |
| S10 | 沒 profile 時 baseline 不載入 = fail open | **採納**。預設位置有檔就載入 |
| S11 | 只認陳述式起點的呼叫,expression 內的 Method 呼叫看不到 | **採納**。呼叫點兩類 + `inExpression` |
| S12 | CONTRACT-ITF 嚴格度是推論卻設 blocking | **採納**。逐項實測編譯器,實測前 warning |
| S13 | Compile 路徑沒做 MSBuild unescape / 正規化 | **採納** |
| S14 | COMPILE-001 / GUID / KIND 的 XAE 行為未實測卻 blocking | **部分採納**。維持 error 但 `blockable: pending`,Phase 1 實測定案(不直接降成 warning:偵測是確定的,降級會讓真問題溜過) |
| S15 | Itf / Property / Transition XML 結構無出處,seeded S10/S11 是循環論證 | **採納**。標未驗證;Phase 1 用 XAE 建真實物件當 fixture。research 文件也註明 |
| S16 | 例外訊息在地化破壞 deterministic | **採納** |
| S17 | D4 表缺 verdict、優先序與 profile 探索衝突、`-FailOn warning` 會讓非 blockable 規則 blocking | **採納** |
| S18 | 專案內繼承造成 FBCALL 誤報 | **採納**。`inherited-use` |
| N1 | `inst.Method()` 不該算標準 FB 的呼叫 | **採納** |
| N2 | SCAN-TIMER 的漏抓情境 | **採納**。寫進 `limits`;SA0167 類列入候選 |
| N3 | 型別目錄被靜態快取 | **採納** |
| N4 | 多 `<ST>` 串接後行號不準 | **採納**。`lineUnreliable` |
| N5 | 首次編譯的牆鐘門檻在 CI 會偶發失敗 | **採納**。只記錄 |

沒有不採納的意見。S14 是部分採納(理由見表)。

### 第二輪(2026-11-13,獨立 reviewer;全文見 PR #262 留言「第二輪獨立設計審查」)與 owner 決定

[必改] 全部採納;[建議] / [可議] / [nit] 逐條如下(owner 沒否決的建議預設採納)。

| # | 等級 | 意見(摘要) | 處理 |
|---|---|---|---|
| 1-1 | 必改 | Phase 1–3 的 blocking 規則幾乎都是專案完整性或編譯器本來就擋的,擋機台行為錯誤的能力接近零 | **採納**。Goals 改用 owner 指標;metadata 加 `machineImpact`;分期依 `compilerCatches = no` 且 behavior / crash 排序(本檔開頭表、D10、`rule-catalog.md`) |
| 1-2 | 必改 | warning 沒有處置機制 | **採納**。D6:`unresolved[]`、`requiresDisposition`、`newSuppressions[]`、SKILL.md Failure contract、EnableConfig 先 advisory 後 blocking(owner 決定 3) |
| 1-3 | 建議 | compilerCatches=yes 的規則讓結果長期 incomplete,agent 學會忽略 `success:false` | **採納**。不進 `blockingRulesSkipped` 也不進 `unresolved`(D3、D6) |
| 2-1 | 必改 | 最高價值規則排在 Phase 4 | **採納**。重排分期(tasks.md) |
| 2-2 | 必改 | 暫時性 FB instance 漏進候選表 | **採納**。SCAN-TEMPFB-001,Phase 1b,blocking(owner 決定 2) |
| 2-3 | 建議 | ST-LLM-001 排名過高 | **採納**。降到 Phase 4,只保留 `x = 5;` 一項有價值 |
| 2-4 | 建議 | PROJECT-TASK-001 擴充雙呼叫 | **採納**。拆成 TASK-001(不執行,必須處置)與 TASK-002(雙執行,blocking);依可達性判斷。語料實測:axis `TestCam` 沒被呼叫(PoC 保留程式),因此 TASK-001 不 blocking |
| 3-a~m | 建議 | 13 條漏掉的高價值規則 | **採納**(owner 指定的全部進目錄,`rule-catalog.md`):TEMPFB、TIMER-005(狀態 timer 沒歸零)、TIMER-004(PT 未設 / IN 常數)、LOOP、FOR、ARR、REF、FBVAL、OUT、MC-002、FLOAT、INTDIV、POLICY-INTERLOCK(Phase 4,不取代 TwinSAFE) |
| 3 低優先 | 建議 | RETAIN / PERSISTENT、`%Q` 重疊、CASE range 重疊、遞迴不做 | **採納**(`rule-catalog.md` 第 3 節) |
| 4-1 | 建議 | Add-Type 失敗分不出環境問題 | **採納**。LanguageMode 檢查、`LINT_ENGINE_UNAVAILABLE` |
| 4-2 | 可議 | 否決預編譯 DLL 的理由不成立 | **理由修正、決定不變**:owner 定案維持 Add-Type;刪掉 Zone.Identifier 的錯誤理由,改寫真正理由(不增加 release 建置路徑) |
| 4-3 | nit | 與既有載入方式不一致 | **採納為後續 task**(tasks 5.1),不在 Phase 1 強制 |
| 4-4 | 必改 | 把 TE1200 排除與目標衝突 | **採納**。D11:Phase 1a 量測 Light 四個問題;Phase 2 視結果加 PROJECT-SA-001;SARIF 放 Phase 4 |
| 4-5 | 建議 | 手寫 parser 遇到不支援語法就 parse fail | **採納**。D3 三類處理 + `research/st-syntax-inventory.md` |
| 5-1 | 必改 | 15/15 不能當召回率 | **採納**。D7 驗證方法:凍結錯誤清單(`research/error-taxonomy-draft.md` 初版待 owner 確認)、LLM 語料盲標、mutation + BuildProject 實測 compilerCatches、holdout + 事先寫明的門檻、git 歷史反向植入 |
| 6-1 | 必改 | 條件編譯 pragma 造成誤擋 / 漏抓 | **採納**。整個物件 `notAnalyzed`(reason `conditional-pragma`;D3) |
| 6-2 | 必改 | `__TRY` / `__CATCH` 讓呼叫點漏判 | **採納**。區塊關鍵字,CATCH 算條件區塊 |
| 6-3 | 必改 | `?=` 讓 lexer 失敗;`S=` / `R=` / `REF=` / `VAR_GENERIC` 待確認 | **採納**。tokenizer / 宣告 parser 認得或安全略過;合法性見語法清單 |
| 6-4 | 建議 | typed literal 吞掉後面的運算式 | **採納**。依前綴定義文法 |
| 6-5 | 建議 | Method VAR 的 TON 不會被報 | **採納**。由 SCAN-TEMPFB-001 涵蓋,列為 1b 驗收 fixture |
| 6-6 | nit | 第三次以上重複不報、INTERFACE EXTENDS 只取第一個 | **採納**。fixture 涵蓋 |

Owner 決定 6(AI 改磁碟檔的問題)是 review 之外的新要求:落實為 `rule-catalog.md` 第 1 節的 PROJECT-XML / GUID / COMPILE / TSPROJ 等整類、`research/tc-xml-schema-observed.md`、Phase 1a 的 IDE 實測與 D9 的磁碟改檔工作流。

### 驗證輪(2026-11-13,reviewer subagent,只查 owner 決定落實、[必改] 處理、未驗證行為)

28 條,全部修正(無不採納):PROJECT-XML-003 的「多段 CDATA」改 pending(語料沒有含 `]]>` 的程式碼,無法排除 XAE 自己切段);驗收改成「XAE 原樣產生的檔案零 finding」,axis 的假 GUID / 外部寫入檔列為預期正例;總表補 severity 規則與 `impactBasis: "inferred"`(偵測確定即 blocking,後果是推論另標);SCAN-LOOP-001 的 confidence 與總表一致;SCAN-TEMPFB-001 的 FUNCTION 情況已有 InfoSys 出處,改 true;`newSuppressions` 在 LintProject 以 git HEAD 為基準,不可得時列出全部;suppression 提前到 1b(否則 1a / 1b 的 `unresolved[]` 無法處置);Non-Goals 舊 MVP 範圍、proposal 的「SCAN 只能 warning」、附錄的 SCAN-TIMER-005 舊 ID 修正;錯誤分類初版註明 `[review2]` 項目不算獨立分母;6-1 的範圍統一為「整個物件」;`?=` scenario 補 notAnalyzed;tasks 1a.10 改成真正未驗證的語法;REF / DIV 的 crash、CTU 推論(原寫「永遠是 0」是錯的)、TASK-001 的 Build 依據、PT 預設值、INTDIV、Interface「編譯器不報」都改標推論或附出處;enum 隱含值與未知 pragma 改用已驗證的 InfoSys 原文。
