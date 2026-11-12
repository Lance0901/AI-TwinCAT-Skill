## Context

- #252(owner 開的):在 TcAuto 加一個 TwinCAT Semantic Linter,目標是**在 Activate / Download 之前**抓到 Build 抓不到、或 Build 之前就該擋下的問題。評分標準是「對真實 PLC 程式抓到多少真 bug、誤報多低、結果是否 deterministic」。
- 現有工具:`Build-TcProject`(XAE Error List)、`Test-TcPlcProject`(CheckAllObjects)、repo 自己的 forbidden-pattern lint(只掃 TcAuto 原始碼,不掃 PLC 程式)。repo 內沒有任何 ST tokenizer(`src/` 與 `mcp-server/` 搜過)。
- 限制:PowerShell 模組是核心;MCP tool = CLI action = cmdlet(`Invoke-TwinCATAutomation.ps1` 的 `$operationMap`、`mcp-server/scripts/Export-ToolSchema.ps1` 產生 `tools.json`、`scripts/Update-GeneratedDocs.ps1` 產生 adapters)。客戶安裝包只有 bundled node 24 + Windows PowerShell 5.1,沒有 .NET SDK。`src/` 已有 `Add-Type` 編譯的 C#(`Private/TcAdsHelper.cs`、`Private/ComRotHelper.cs`),`scripts/check.ps1` 不禁止 `Add-Type`。
- 可行性實測:`research/corpus-feasibility.md`(2 個真實專案、throwaway prototype、seeded-bug 18 個)。TE1200 規則清單:`research/te1200-rules.md`。候選規則排序:`research/rule-candidates.md`。

## Goals / Non-Goals

**Goals:**
- `LintCandidate`(寫入前,純文字)與 `LintProject`(寫入後,磁碟上的專案)兩個唯讀 tool,回傳 deterministic、可排序的結構化 diagnostics。
- 不需要 IDE、不需要 runtime 就能跑(見 D2 的範圍表)。
- fail closed:解析不了、context 不足、profile 壞掉、有東西沒分析到,都不能回 `passed: true`。
- 能當 blocking 的只有「確定性事實」類規則(PROJECT 結構、有 baseline 的 CONTRACT、profile 明列的 POLICY);heuristic 規則預設只出 warning。

**Non-Goals:**
- 不取代 compiler、`CheckAllObjects`、TE1200。TE1200 已有的規則(未使用變數、除以零、陣列越界、CASE 無 ELSE…)不重做,除非有「寫入前就擋」或「客戶只有 Light 版」的明確價值(見 D6)。
- 不用 LLM 當 gate;不 auto-fix;不碰 Activate / Login / Download / ADS / I/O。
- MVP 不做控制流 / 資料流分析(RETURN 後的可達性、常數折疊、除以零、陣列 index 流)。

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
- **ReloadModule 的陳舊型別**:.NET Framework 無法卸載 `Add-Type` 載入的 assembly。`.cs` 改了之後 `ReloadModule`(`Import-Module -Force`)會拿到舊引擎。做法:編譯前把 namespace 換成 `TcLint_<.cs 內容 SHA256 前 12 碼>`,cmdlet 依 hash 找型別;內容變了就是新型別。`data.engine.sourceHash` 回報實際用的版本(可在測試中斷言)。
- **相依**:只引用 `System.Xml`、`System.Core`;XML 讀取一律 `DtdProcessing = Prohibit`、`XmlResolver = null`(不讀外部實體)。
- 否決:預先編譯好的 DLL 隨安裝包發(要多一條 build/簽章流程,下載 zip 解出的 DLL 可能被 Zone.Identifier 擋 — 未驗證);Roslyn(PS 5.1 沒有);純 regex 規則(無法處理註解、字串、巢狀區塊,語料裡 `END_IF` 不接分號就會讓 regex 規則出錯)。

### D2. 輸入來源與「不需要 IDE」的範圍

**LintCandidate**:輸入是純文字,永遠不需要 IDE。

| 參數 | 說明 |
|---|---|
| `ObjectKind` | `Program` `FunctionBlock` `Function` `DUT` `GVL` `Interface` `Method` `Property` `Action` `Transition` |
| `ObjectName` | 物件名;Method / Property / Action / Transition 用 `Parent.Member`(與 `Write-TcPouCode -PouName` 同格式) |
| `Declaration` / `Implementation` | 文字;`Implementation` 只接受 ST(其他語言回 `LINT_INPUT_INVALID`) |
| `PlcProjectPath` | 選填。`.plcproj` 的檔案路徑,或已連 IDE 時的 PLC 名稱。給了就把候選物件**覆蓋**到該專案的磁碟版本上(同名物件被取代、新物件被加入),跑跨物件規則 |
| `RuleProfile` / `FailOn` / `Baseline` | 見 D5 |

沒給 `PlcProjectPath` 時,需要專案 context 的規則(例:Interface 簽章需要 Interface 定義、FB 型別目錄需要專案內的 FB)標成 `rulesNotRun`,reason `no-project-context`;**不算 coverage 缺口**(呼叫者自己選擇不給 context),但 `data.contextLevel = "text-only"` 讓呼叫者知道。

**LintProject**:讀磁碟上的 `.plcproj` 與它 `<Compile>` 列出的所有檔案(`.TcPOU` `.TcDUT` `.TcGVL` `.TcIO` `.TcTTO`,以及存在性檢查用的其他項目)。

- `PlcProjectPath`:`.plcproj` 檔案路徑 → 不需要 IDE。PLC 名稱或省略 → 需要已連線的 IDE,透過 `Get-TcPlcProjectList` 的 `projectFile` 找檔案;非停用的 PLC 多於一個且沒指定 → `PLC_PROJECT_AMBIGUOUS`(沿用 `Resolve-TcPlcProjectPath -RequireSingle` 的語意與 `data.plcProjects`);找不到 → `PLC_PROJECT_NOT_FOUND`。
- 也接受 `SolutionPath`(`.sln` / `.tsproj`)+ PLC 名稱,從 `.tsproj` 找 `.plcproj`(不需要 IDE;`.tsproj` 內 PLC 專案參照的格式要在 Phase 1 用語料確認,目前**未驗證**)。

**IDE 編輯器有未存內容時**:

- `Write-TcPouCode` 是寫 COM 的 `DeclarationText` / `ImplementationText`(編輯器 buffer),模組沒有公開的存檔 cmdlet,所以寫入後磁碟版可能是舊的。
- 建議做法:
  1. 寫入後的檢查用 **`LintCandidate -PlcProjectPath`**(把剛寫的文字覆蓋到磁碟專案上),不靠磁碟。這是 agent 主要工作流(D9)。
  2. `LintProject` 只描述磁碟。若 IDE 已連線:先呼叫 `Get-TcUnsavedChanges`;該 PLC 專案或其文件有未存變更 → `LINT_SOURCE_STALE`(`data.unsaved` 列出),不跑規則;`Get-TcUnsavedChanges` 讀不到(`Unchecked` / 例外)→ `LINT_SOURCE_UNVERIFIED`。若 IDE 沒連線:照跑,`data.source = { kind: "disk", ideChecked: false }`。之後若要把 lint 當 lifecycle gate(D9),gate 只接受 `ideChecked: true` 的結果。
- **未驗證、Phase 2 要真機量**:`DeclarationText` setter 之後 `Project.Saved` / `Document.Saved` 是否一定變 false(若不會,`LINT_SOURCE_STALE` 偵測不到,這條路就是 fail open,要改成「有 code-changed 紀錄(`Register-TcCodeChange`)就視為 stale」)。
- 否決:`LintProject` 透過 COM 逐一讀所有物件文字(需要 IDE、100+ 個物件逐一 COM 呼叫成本未知、與「不需 IDE」目標衝突);只靠磁碟不檢查(會在 agent 剛寫完時 PASS 舊程式碼 = fail open)。

**不需要 IDE / runtime 的範圍**:

| 功能 | IDE | runtime |
|---|---|---|
| `LintCandidate`(有無 `PlcProjectPath` 檔案路徑) | 不需要 | 不需要 |
| `LintProject -PlcProjectPath <.plcproj 檔>` | 不需要(已連線時會額外做 stale 檢查) | 不需要 |
| `LintProject` 用 PLC 名稱 / 省略路徑 | 需要(只用來找檔案與 stale 檢查) | 不需要 |
| 任何 lint 功能 | — | **永遠不需要**;不呼叫 ADS |

### D3. 解析深度

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
- 呼叫點:陳述式起點的 designator 後接 `(`,記錄 instance、member(`fb.M_Do()`)、所在區塊堆疊;`END_*` 後不接分號仍算陳述式起點(語料實際寫法)。
- 識別字引用集合、成員存取集合(`fb.Q`)。
- Phase 3 才加:賦值左值、RETURN/EXIT/CONTINUE 位置與可達性。

**TcPOU XML**:`<POU>` `<DUT>` `<GVL>` `<Itf>` 與子物件 `<Method>` `<Property>`(`<Get>` `<Set>`)`<Action>` `<Transition>`;`<LineIds>` 忽略。`<Implementation>` 下有多個 `<ST>` 元素(語料 bfh `FB_MachineCtrl` 有)時的語意**未驗證**:Phase 1 先當成「格式異常」回報 `LINT-XML-002` warning 並全部串接分析,真機確認後再定。

**非 ST 實作(SFC / CFC / LD / FBD / IL / NWL)與 PLCopen XML**:不分析。
- 該 section 記進 `data.coverage.notAnalyzed[]`,reason `language:CFC` 等。
- 依賴該物件呼叫點的規則(例如 SCAN-FBCALL 在一個有 CFC Action 的 FB 上)對**整個物件**不評估,記進 `data.coverage.rulesSkipped[]`,reason `object-partially-analyzed`(prototype:axis `FB_AxisControl` 有一個 CFC Action,整個 FB 的 SCAN 規則不跑,否則會把 CFC 裡的呼叫當「沒有呼叫點」)。
- PLCopen XML(`.xml` 匯入檔)不是 `LintProject` 的輸入;要檢查就先 `ImportPlcOpen` 再 lint 專案。

**coverage 與 verdict**(見 D4):`data.coverage = { objectsInScope, objectsAnalyzed, notAnalyzed[], excluded[], rulesSkipped[], rulesNotRun[] }`。`notAnalyzed` 非空 → verdict 不可能是 `pass`。

### D4. Fail-closed 語意

`data.verdict` 三值:`pass` | `fail` | `incomplete`。`data.passed = (verdict == "pass")`。`success` 只在 `verdict == pass` 時為 true,但 **warning-only 是 pass**(issue 驗收條件:warning-only 不得誤報成 tool failure)。

| 情境 | success | passed | error.code | data |
|---|---|---|---|---|
| 沒有 finding,或只有非 blocking finding | true | true | — | diagnostics 照列 |
| 有 blocking finding | false | false | `LINT_FAILED` | 完整 diagnostics |
| 有物件解析失敗(tokenize / 宣告 / 區塊結構) | false | false | `LINT_PARSE_FAILED` | `LINT-PARSE-*` diagnostic(blocking)+ 其他物件照跑的結果 |
| 範圍內有未分析的物件(非 ST、XML 讀不到但檔案存在) | false | false | `LINT_INCOMPLETE` | `coverage.notAnalyzed[]` |
| profile 檔不存在 / JSON 錯 / schema 不符 / 未知 rule id | false | 不輸出 | `LINT_PROFILE_INVALID` | 不跑任何規則 |
| baseline 檔壞掉,或 profile 要求 baseline 但找不到 | false | 不輸出 | `LINT_BASELINE_INVALID` | 不跑任何規則 |
| 多 PLC 未指定 | false | 不輸出 | `PLC_PROJECT_AMBIGUOUS` | `data.plcProjects`(與既有慣例相同) |
| 指定的 PLC / 檔案找不到 | false | 不輸出 | `PLC_PROJECT_NOT_FOUND` / `LINT_INPUT_INVALID` | |
| `.plcproj` 本身 XML 壞掉 | false | 不輸出 | `LINT_PARSE_FAILED` | |
| IDE 已連線且有未存變更 / 讀不到未存狀態 | false | 不輸出 | `LINT_SOURCE_STALE` / `LINT_SOURCE_UNVERIFIED` | `data.unsaved` |
| 參數錯(未知 ObjectKind、Implementation 非 ST…) | false | 不輸出 | `LINT_INPUT_INVALID` | |
| 引擎內部例外 | false | 不輸出 | `LINT_ENGINE_ERROR` | 例外訊息;**不得**退回「部分結果 + passed」 |

- 同時有多種失敗時 code 的優先序:`LINT_PROFILE_INVALID` > `LINT_BASELINE_INVALID` > `LINT_INPUT_INVALID` / `PLC_PROJECT_*` / `LINT_SOURCE_*` > `LINT_ENGINE_ERROR` > `LINT_PARSE_FAILED` > `LINT_INCOMPLETE` > `LINT_FAILED`。diagnostics 一律完整保留。
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
te1200        對應的 SA 規則(有的話)
compilerCatches  yes / no / unknown(有的話 → 價值只在寫入前)
```

**blocking 的計算**(每筆 finding):`blocking = !suppressed && severity >= FailOn && (confidence == high || profile 對此 rule 明確設 "blocking": true)`,且 `blockable == false` 的規則只有 profile 明確設 `"blocking": true` 才會 blocking;此時 diagnostic 帶 `blockingSource: "profile"`。`FailOn` 預設 `error`;可設 `warning`;不提供 `never`(要不擋就不要呼叫 gate)。

**Suppression**:用 ST 註解,不用 pragma(避免任何編譯器副作用;未知 attribute 對編譯器的影響**未驗證**)。

```iecst
// tcauto-lint-disable-next-line SCAN-TIMER-001: 測試模式切換器,切回時重新 arm 是預期行為
R_14Eng(CLK := b14Engage);

tonRelease : TON; // tcauto-lint-disable-line SCAN-FBCALL-001: 由 FB_Base.M_Cycle 呼叫
```

- 形式:`tcauto-lint-disable-next-line <RULE-ID>[, <RULE-ID>]: <理由>`、`tcauto-lint-disable-line …`、物件層級 `tcauto-lint-disable-object …`(只能寫在宣告區第一個 VAR 之前)。沿用 repo `tcauto-allow(<rule>): <reason>` 的「理由至少 8 字」。
- 沒有理由、理由太短 → suppression 不生效,另出 `LINT-SUPPRESS-001`(warning,`blockable`;default profile 是 warning,不 blocking)。未知 rule id → `LINT-SUPPRESS-002`。沒壓到任何 finding → `LINT-SUPPRESS-003` info。
- 被壓掉的 finding 仍列在 diagnostics,`suppressed: true` + `suppressionReason`,不計入 summary 的 errors / warnings(另計 `suppressed`)。
- 不能改原始碼的物件(library、產生的程式)用 profile 的 `suppressions[]`(`objectPath` + `ruleId` + `reason`,不接受 wildcard objectPath)。

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

- 載入:`-RuleProfile` 給內建名稱(`default`、之後的 `robust-solution`)或檔案路徑。未給時:找 `<solution 目錄>\.tcauto\lint-profile.json`,找到就用,沒有就 `default`。`data.profile = { name, source, sha256 }` 一律回報,讓結果可追溯。(是否自動探索 → owner 決定,見 Open Questions 1。)
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
- 產生 baseline 是寫檔動作 → 獨立 cmdlet `New-TcLintBaseline`(Phase 3),顯示內容、不覆寫既有檔(除非 `-Force`)。MVP 只讀 baseline。
- 放哪:建議 `<solution 目錄>\.tcauto\lint-baseline.json`,進版本控制(見 Open Questions 2)。
- 隱含 enum 值:無明確值的成員依前一個 +1 計算;前一個是非整數 expression 時記為未知,該成員只比對名稱,並出 `rulesSkipped`(prototype 的 S12 就是隱含值跟著變:`Manual 0→1` 讓 `Auto 1→2`,兩筆都報)。

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

**排序**(穩定、與 culture 無關):`file`(ordinal,先轉小寫 invariant)→ `objectPath` → section 順序(declaration < implementation)→ `line` → `column` → `ruleId`(ordinal)→ `message`(ordinal)。所有比較用 `StringComparer.Ordinal` / `ToLowerInvariant`;不依賴 `Dictionary` 列舉順序;檔案清單先排序再處理。CI 在 en-US 與 zh-TW culture 各跑一次比對 byte(本機 PowerShell tool 是 en-US、Bash 的 powershell.exe 是 zh-TW)。

### D6. 規則目錄

完整候選清單與排序在 `research/rule-candidates.md`;這裡定義 MVP 的 8 項。欄位:偵測演算法 / 預設 severity·confidence / blocking / 誤報來源 / 編譯器或 TE1200 會不會抓 / 實測依據。

1. **PROJECT-COMPILE-001/002/003**(`.plcproj` `<Compile>`)
   - 001:`<Compile Include>` 指向不存在的檔(所有項目,不只 PLC 物件副檔名)。error/high,blocking。
   - 002:同一路徑(大小寫不敏感、正規化 `\`)出現兩次。error/high,blocking。
   - 003:`.plcproj` 目錄底下有 `.TcPOU/.TcDUT/.TcGVL/.TcIO/.TcTTO` 但沒列在 `<Compile>`(不會被編譯)。warning/high,**不** blocking(可能刻意保留)。
   - 誤報來源:語料複製漏檔(prototype 實際發生一次,見 research 4.1);`_bak` 類目錄在專案目錄內。
   - 編譯器:001 載入 / Build 時 XAE 的行為**未驗證**;003 編譯器看不到(檔案根本沒被編譯),是本 linter 的獨有價值。
   - 實測:seeded S01/S02/S03 命中;語料 0 誤報(扣掉複製失誤)。
2. **PROJECT-GUID-001 / PROJECT-KIND-001 / PROJECT-NAME-001**
   - GUID-001:同一 `.plcproj` 內兩個物件(含 Method / Action / Property 子物件)`Id` 相同。error/high,blocking。XAE 遇到重複 Id 的行為**未驗證**。
   - KIND-001:副檔名與根元素不符(`.TcDUT` 內是 `<POU>`)。error/high,blocking。
   - NAME-001:檔名與物件名不同。warning/high,不 blocking(XAE 是否允許**未驗證**)。
   - 實測:seeded S04/S05 命中;語料 0 筆。
3. **CONTRACT-ITF-001/002**(Interface Method / Property 簽章)
   - 對每個 `IMPLEMENTS I_X`:收集 `I_X`(含 `EXTENDS` 的 Interface 鏈)的 Method / Property;FB(含專案內 `EXTENDS` 的基底 FB 鏈)必須有同名成員;回傳型別、`VAR_INPUT/OUTPUT/IN_OUT` 的順序、名稱、型別文字(正規化空白與大小寫)一致。Property 比對型別與 Get/Set 是否存在。
   - 001 缺成員、002 簽章不同:error/high,blocking。
   - Interface 或基底 FB 在 library 裡(專案內找不到)→ 不評估,`rulesSkipped` reason `type-outside-project`。
   - 誤報來源:型別別名(`ALIAS`)與 qualified 名稱(`Lib.T` vs `T`)— 比對前展開專案內 alias,不同寫法但無法證明相等時降為 warning/medium。
   - 編譯器:會抓(實作不完整會編譯錯誤 — 依 IEC 語意推論,**未實測**),價值是 `LintCandidate` 在寫入前擋。
   - 實測:seeded S10/S11 命中;語料沒有 Interface(語料缺口)。
4. **SCAN-FBCALL-001/002**(FB instance 沒有呼叫點)
   - 型別判斷只用**型別目錄**:專案內 `FUNCTION_BLOCK` + 內建 library 目錄(版本化資料檔,先放 Tc2_Standard、Tc2_MC2 常用 FB,每個名稱附 InfoSys 來源)+ profile `typeCatalog.functionBlocks`。目錄外的型別 → 不評估(`rulesSkipped` reason `unknown-type`),**不得用名稱前綴猜**(prototype v1 用 `MC_` 前綴猜,56 筆全誤報)。
   - 只看 `VAR` / `VAR_STAT` / `VAR_INST`(不看 INPUT/OUTPUT/IN_OUT、POINTER、REFERENCE);instance 在同一物件的本體、Method、Action 都沒有 `inst(...)` 也沒有 `inst.Method(...)`。
   - 001:有被引用(例如讀 `.Q`)但從不呼叫 → warning/medium,不 blocking(讀到的是永遠不更新的輸出)。002:完全沒被引用 → info/high(TE1200 SA0033 同類)。
   - 物件有任何未分析的 section(CFC Action 等)→ 整個物件不評估。
   - 誤報來源:instance 透過 `REFERENCE` / 指標 / Interface 交給別的物件呼叫;基底 FB 宣告、衍生 FB 呼叫(MVP 不追繼承,`EXTENDS` 專案外的物件 → 不評估);`{attribute 'call_after_init'}` 之類由系統呼叫的情況(**未驗證**)。
   - 實測:v2 語料 0 筆誤報(001)、2 筆真的未使用(002);seeded S08/S09 命中。
5. **SCAN-TIMER-001 / 002**(Timer / Trigger 條件呼叫)
   - 目標型別:`TON TOF TP LTON LTOF LTP R_TRIG F_TRIG CTU CTD CTUD`(Tc2_Standard)+ profile `typeCatalog.cyclicContract`。
   - 001:instance 所有本體呼叫點都在 IF / CASE 內,**且**沒有任何一個頂層 IF…ELSE 的所有分支都呼叫它 → warning/medium,不 blocking。
   - 002:只在 Action / Method 內呼叫,而那個 Action 沒有被本體無條件呼叫(Method 一律無法證明)→ info/low。
   - 誤報來源:CASE 的每個分支都呼叫(MVP 只處理 IF…ELSE,CASE…ELSE 留到 Phase 2);刻意的「只在某模式更新」(語料 `TestCam.R_14Eng`);狀態機在每個狀態都呼叫同一 timer。
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

**MVP 預設 blocking 的只有**:PROJECT-COMPILE-001/002、PROJECT-GUID-001、PROJECT-KIND-001、CONTRACT-ITF-001/002、CONTRACT-ENUM-*/DUT-001(有 baseline 時)、LINT-PARSE-*。SCAN-* 全部 warning / info(見 Open Questions 3)。

### D7. 測試策略

| 層 | 內容 | 跑在 |
|---|---|---|
| tokenizer / parser fixture | 每種 token、每種宣告形式各一組正例與反例;真實語料撞過的坑(`END_IF` 不接分號、多個 `<ST>`、巢狀 `(* *)`、`$'` 跳脫、中文註解、BOM) | `tests/Unit/lint-parser.ps1` |
| 規則 fixture | 每條規則:至少 2 個正例(該報)、2 個反例(不該報,包含已知誤報來源)、1 個 suppression(有理由生效 / 沒理由出 LINT-SUPPRESS-001) | `tests/Unit/lint-rules-<category>.ps1`(依 testing-policy 合併到少數檔,每檔有 2–3 s 固定成本) |
| 契約 | JSON 形狀、`verdict/passed/success` 對照表(D4 每一列一個 case)、error code 優先序、hint 存在、`passed` 欄位在錯誤時不存在 | `tests/Unit/lint-contract.ps1` |
| deterministic | 同輸入跑兩次 byte 相同;en-US 與 zh-TW culture 結果相同;檔案列舉順序打亂後結果相同 | 同上 |
| 語料回歸 | `tests/Fixtures/lint-corpus/`:從語料挑 10–20 個代表檔(需 owner 同意放進 repo,見 Open Questions 4);斷言不 crash、解析 100%、finding 快照(`ruleId+objectPath+line` 清單) | unit |
| seeded-bug 套件 | `research/prototype/Seed-Bugs.ps1` 的 18 個 seed 改成 fixture:每個 seed 期望的 ruleId;範圍外的 seed 期望「不報」(防止誤以為有涵蓋) | unit |
| 效能預算 | 單專案(≤ 200 物件)分析 ≤ 2 s(不含首次編譯);首次編譯 ≤ 3 s;超過就 FAIL(放 `check.ps1` 序列組) | unit(牆鐘斷言) |
| 整合 | `tests/Integration/lint-*.ps1`:對真實 `.TcPOU/.plcproj`(測試副本)跑 `LintProject`;**不需要 runtime**。stale 偵測(D2)需要 IDE → 真機 worker 用 registered tcauto 驗 | 真機,不進 CI |

mock 依據照 `docs/testing-policy.md` 第 3 節標註;D2 的 `Saved` 旗標行為在實測前一律標 `[推論]`。

### D8. 效能與資源

- 首次 `Add-Type` 0.7–1.0 s(實測);之後每專案 50–160 ms(實測,2 個專案)。
- 記憶體:prototype 用 `XmlDocument`,axis 專案 GC heap 增量約 42 MB。產品版改用 `XmlReader` 串流讀 `.TcPOU`,不保留 DOM。
- 不做跨呼叫的快取(MVP);`Scope=Object` 只解析範圍內物件 + 規則需要的 context(型別目錄需要掃全部宣告區,但不需要實作區)。

### D9. Agent 工作流整合

SKILL.md 與 tool description 引導的順序:

```text
產生候選程式碼
  -> LintCandidate -PlcProjectPath <plcproj>   (寫入前;LINT_FAILED 就改,不寫)
  -> WritePouCode
  -> BuildProject                               (編譯器是最終權威)
  -> LintProject(存檔後 / 交付前 / CI)          (跨物件與專案層級;LINT_SOURCE_STALE 代表要先存檔)
  -> Test / EnableConfig
```

- tool description 要寫清楚:`LINT_PARSE_FAILED` 先 Build 判斷是誰的錯;`passed: true` 不代表程式正確,只代表「列出的規則在分析到的範圍內沒有 blocking finding」;`coverage` 要一起看。
- **Lifecycle gate(只提方案,MVP 不做)**:`RunLifecycle` / `EnableConfig` 加 `-LintGate <profile>`:在 Activate 前跑 `LintProject`,要求 `ideChecked: true` 且 `verdict == pass`,否則回 `LINT_GATE_BLOCKED`(不記 lifecycle block,因為 runtime 沒動)。前提:D2 的 stale 偵測已真機驗證。預設關閉,owner 決定是否開(Open Questions 6)。

### D10. 分期(每期一個可獨立 review / merge 的 PR,見 tasks.md)

| Phase | 內容 | 可 blocking 的規則 |
|---|---|---|
| 0 | 本設計(這個 PR) | — |
| 1 | 引擎骨架:C# tokenizer / 宣告 parser / 結構掃描 / XML 讀取、`LintProject`(磁碟)、diagnostics 契約、排序、PROJECT-* 規則、coverage、error code 全套、profile 載入(只有 default) | PROJECT-COMPILE-001/002、GUID-001、KIND-001、LINT-PARSE-* |
| 2 | `LintCandidate`(含 overlay)、suppression、SCAN-FBCALL / SCAN-TIMER、型別目錄、stale 偵測(真機驗) | 同上 |
| 3 | CONTRACT-ITF / ENUM / DUT、baseline 讀取、`New-TcLintBaseline`、`GetLintRule` | + CONTRACT-* |
| 4 | POLICY 引擎與 `robust-solution` profile、Phase 2 以後的候選規則(依 rule-candidates 排序) | profile 決定 |

## Risks / Trade-offs

- **語料太少、規則在同一語料上調出來** → SCAN 規則的「v2 零誤報」可能 overfit。緩解:SCAN 全部非 blocking;Phase 2 驗收要加第三個以上真實專案(owner 提供)。
- **parser 不支援合法語法 → 誤擋**(`LINT_PARSE_FAILED`)。緩解:錯誤碼與 `LINT_FAILED` 分開、hint 先 Build、profile `exclude` 帶理由;語料回歸保證已知語法不退步。TwinCAT 新語法(例如 4026 的新關鍵字)可能未知:**未驗證**有哪些。
- **型別目錄不完整 → SCAN 規則少評估**(fail 到「不評估」那一側,會列在 `rulesSkipped`,不是靜默)。代價是召回率低。
- **stale 偵測依賴 XAE 的 `Saved` 旗標**:若 COM 寫入不會讓旗標變 false,`LintProject` 在 IDE 連線時仍可能檢查舊檔 → 未驗證前把「有 code-changed 紀錄」也當 stale。
- **ReloadModule 拿到舊引擎**:用 hash namespace 處理;若失效,`ReloadRuntime`(重啟 PS)是保底。
- **`Add-Type` 在受限環境失敗**(AppLocker / Constrained Language Mode):`TcAdsHelper.cs` 已有同樣依賴;失敗時回 `LINT_ENGINE_ERROR`,不退回 PowerShell 版本。
- **agent 把 `passed: true` 當成「程式正確」**:tool description 與 SKILL.md 要寫清楚範圍;diagnostics 帶 coverage。

## Open Questions(需要 owner 決定,附建議)

1. **profile 自動探索**:未給 `-RuleProfile` 時,要不要自動讀 `<solution 目錄>\.tcauto\lint-profile.json`?建議:要,並在輸出回報 `profile.source` 與 sha256。理由:repo 規則應該對每個 agent 自動生效。
2. **baseline 放哪、何時產生**:建議 `<solution 目錄>\.tcauto\lint-baseline.json` 進版控,在發佈版本時用 `New-TcLintBaseline` 明確產生。
3. **default profile 的 blocking 範圍**:建議只有 D6 末段列的確定性規則;SCAN-TIMER-001 在第三個專案驗證誤報率 < 10% 前維持 warning。
4. **語料進 repo**:建議從兩個測試專案挑 10–20 個檔(去掉客戶資訊)放 `tests/Fixtures/lint-corpus/`。需要 owner 確認這兩個專案可以公開在 repo 裡。
5. **更多語料**:建議再提供 2–3 個專案,至少一個有 Interface / Property / SFC / 多 PLC,補語料缺口。
6. **Lifecycle gate**:要不要做 `-LintGate`?建議 Phase 4 之後、stale 偵測真機驗過再做,預設關閉。
7. **`/* */` 註解與多個 `<ST>` 元素**:要查 InfoSys 或真機確認,決定 tokenizer / XML 讀取的行為。
8. **library 型別目錄的來源**:手寫版本化清單(建議,MVP)或解析 `_Libraries` 的 compiled-library(格式未知,未驗證)。
9. **TE1200 整合**:Automation Interface 有 `RunStaticAnalysis`、`ExportToSarif`(4026.20 起,見 `research/te1200-rules.md`);要不要另開 issue 包成 tool,讓 lint 結果與 TE1200 結果合併?建議另開 issue,不放進本 change。

## Review 紀錄

(reviewer subagent 挑戰後補上:採納 / 不採納與理由。)
