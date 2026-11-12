## ADDED Requirements

### Requirement: Lint tool 是唯讀的
`LintCandidate` 與 `LintProject` SHALL 不修改任何檔案、IDE 狀態或 runtime 狀態。它們 MUST NOT 呼叫 `WritePouCode`、`BuildProject`、任何 ADS / runtime tool、DTE command 或 GUI 操作,也 MUST NOT 記錄 lifecycle block 或 code-changed 狀態。

#### Scenario: lint 後狀態不變
- **WHEN** 對一個專案呼叫 `LintProject`
- **THEN** 專案目錄內所有檔案的內容與修改時間不變,`BUILD_REQUIRED` / lifecycle block 狀態不變

#### Scenario: lint 失敗不改走其他路徑
- **WHEN** lint 引擎丟出例外
- **THEN** 回 `LINT_ENGINE_ERROR`,MUST NOT 改用其他方式(COM、DTE、GUI、純 PowerShell 版本)重試或回傳部分結果當成通過

### Requirement: 不需要 IDE 與 runtime
`LintCandidate` 與 `LintProject -PlcProjectPath <.plcproj 檔案路徑>` SHALL 在沒有連線 IDE、沒有 runtime 的情況下完整執行。只有用 PLC 名稱指定或省略 `PlcProjectPath` 時才需要已連線的 IDE(只用來找 `.plcproj` 與檢查未存檔變更)。任何 lint 功能 MUST NOT 需要 runtime 或 ADS。

#### Scenario: 沒有 IDE
- **WHEN** 沒有呼叫過 `ConnectIde`,呼叫 `LintProject -PlcProjectPath C:\x\PLC1\PLC1.plcproj`
- **THEN** 正常分析,`data.source.ideChecked` 為 false

#### Scenario: 沒有 IDE 又沒給檔案路徑
- **WHEN** 沒有連線 IDE,呼叫 `LintProject` 不帶 `PlcProjectPath`
- **THEN** 回 `LINT_INPUT_INVALID`,hint 指出要給 `.plcproj` 路徑或先 `ConnectIde`

### Requirement: 多 PLC 專案的選擇
用 PLC 名稱或省略 `PlcProjectPath` 時,系統 SHALL 沿用 `Resolve-TcPlcProjectPath -RequireSingle` 的語意:非停用的 PLC 專案多於一個且沒有指定 → `PLC_PROJECT_AMBIGUOUS`,並在 `data.plcProjects` 列出候選;指定的找不到 → `PLC_PROJECT_NOT_FOUND`。

#### Scenario: 兩個 PLC 沒指定
- **WHEN** IDE 開著有兩個 PLC 專案的 solution,呼叫 `LintProject` 不帶 `PlcProjectPath`
- **THEN** 回 `PLC_PROJECT_AMBIGUOUS`,`data.plcProjects` 有兩筆,沒有分析任何檔案

### Requirement: 未存檔的 IDE 內容不得被當成已檢查
IDE 已連線且目標 `.plcproj` 屬於連線中的 solution 時,`LintProject` SHALL 在分析前比對 XAE 樹與磁碟 `.plcproj` 的 `<Compile>` 清單,並檢查目標專案文件的 `Saved` 狀態。不一致或有未存文件 MUST 回 `LINT_SOURCE_STALE`(`data.unsaved` 列出);與目標專案相關的項目無法判斷 MUST 回 `LINT_SOURCE_UNVERIFIED`。兩者都 MUST NOT 輸出 `data.passed`。與目標無關的項目(例如 Scope 專案)讀不到 MUST NOT 讓結果失敗。`.plcproj` 不屬於連線中的 solution 時 MUST 回報 `data.source.ideChecked: false`。

#### Scenario: GUI 新增了 POU 但 .plcproj 還沒存
- **WHEN** 使用者在 XAE 新增 `FB_New`,`.plcproj` 只改在 XAE 記憶體,接著呼叫 `LintProject`
- **THEN** 回 `LINT_SOURCE_STALE`,`data.unsaved` 列出 XAE 有、磁碟 `<Compile>` 沒有的 `FB_New`

#### Scenario: 指向別的 solution
- **WHEN** IDE 連著 solution A,`LintProject -PlcProjectPath` 指向 solution B 的 `.plcproj`
- **THEN** 照常分析,`data.source.ideChecked` 為 false

### Requirement: 結果語意 fail closed
每次呼叫 SHALL 回傳 `data.verdict`(`pass` / `fail` / `incomplete`)。`data.passed` MUST 等於 `verdict == "pass"`,`success` MUST 只在 verdict 為 `pass` 時為 true。只有非 blocking finding 時 verdict MUST 是 `pass`。分析未執行(profile 無效、輸入錯、多 PLC 未指定、未存檔、引擎例外)時 MUST NOT 輸出 `data.passed` 欄位。

| 情境 | error.code |
|---|---|
| 有 blocking finding | `LINT_FAILED` |
| 有物件無法解析 | `LINT_PARSE_FAILED` |
| 規則需要的 section 沒分析到,或預設 blocking 規則被跳過且 profile 沒有 `acceptSkips` | `LINT_INCOMPLETE` |
| text-only 的候選需要專案 context | `LINT_CONTEXT_REQUIRED` |
| profile 無效 | `LINT_PROFILE_INVALID` |
| baseline 無效或 profile 要求卻找不到 | `LINT_BASELINE_INVALID` |
| 參數錯 / 檔案找不到 | `LINT_INPUT_INVALID` |
| 引擎例外 | `LINT_ENGINE_ERROR` |
| Constrained Language Mode、`Add-Type` 被擋 | `LINT_ENGINE_UNAVAILABLE` |

多種同時發生時依 design.md D4 的優先序選 code,diagnostics 全部保留。

#### Scenario: 受限環境
- **WHEN** PowerShell 在 Constrained Language Mode
- **THEN** 回 `LINT_ENGINE_UNAVAILABLE`,`data.languageMode` 帶實際值,hint 指向環境設定;MUST NOT 回 `LINT_ENGINE_ERROR`

#### Scenario: 只有 warning
- **WHEN** 分析完成,只有一筆 SCAN-TIMER-001 warning
- **THEN** `success: true`、`data.passed: true`、`data.verdict: "pass"`,diagnostics 含那筆 warning

#### Scenario: blocking finding
- **WHEN** `.plcproj` 有一個 `<Compile>` 指向不存在的檔
- **THEN** `success: false`、`error.code: LINT_FAILED`、`data.passed: false`,完整 diagnostics 保留

#### Scenario: 解析失敗不得 PASS
- **WHEN** 某個 POU 少一個 `END_IF`,其他物件都沒問題
- **THEN** `error.code: LINT_PARSE_FAILED`、`data.passed: false`,其他物件的 diagnostics 照常輸出

#### Scenario: 沒有 context 不得 PASS
- **WHEN** 沒有連線 IDE,`LintCandidate` 不帶 `PlcProjectPath`,候選是 `FUNCTION_BLOCK FB_X IMPLEMENTS I_Brake`
- **THEN** 回 `LINT_CONTEXT_REQUIRED`、`data.passed: false`,hint 要求帶 `PlcProjectPath`

#### Scenario: profile 壞掉
- **WHEN** `-RuleProfile` 指向的 JSON 有未知的 rule id
- **THEN** 回 `LINT_PROFILE_INVALID`,沒有任何規則被執行,`data.passed` 不存在

### Requirement: 未分析的內容要明確回報
非 ST 實作(SFC、CFC、LD、FBD、IL)、無法讀取的物件、規則因前置條件不足而未評估的範圍 SHALL 列在 `data.coverage`(`notAnalyzed[]`、`excluded[]`、`rulesSkipped[]`、`rulesNotRun[]`),每筆帶 `objectPath` 與 `reason`。coverage 缺口 MUST 按規則計算:未分析的 section 只讓「需要該 section 的規則」不評估;不需要它的規則(PROJECT-*、宣告區規則)照跑。預設 blocking 的規則對某物件未評估時 MUST 記入 `blockingRulesSkipped`,且除非 profile `acceptSkips` 帶理由明列,verdict MUST NOT 是 `pass`。物件只有部分 section 被分析(含被 `exclude` 的 section)時,依賴該物件呼叫點的規則 MUST 對整個物件不評估並記入 `rulesSkipped`。

#### Scenario: CFC Action
- **WHEN** `FB_AxisControl` 有一個 CFC Action,`Scope=All`,profile 沒有排除它
- **THEN** `coverage.notAnalyzed` 有 `FB_AxisControl.A90_Cyclic`(reason `language:CFC`),`FB_AxisControl` 的 SCAN 規則列在 `rulesSkipped`;PROJECT-* 規則照常檢查它;SCAN 規則不是預設 blocking,所以這個缺口本身不讓 verdict 變成 `incomplete`

#### Scenario: 帶理由排除
- **WHEN** profile `exclude` 列了 `FB_AxisControl.A90_Cyclic` 並附理由
- **THEN** 它出現在 `coverage.excluded`(含理由)與 `data.profile.overrides`,不算 `notAnalyzed`;`FB_AxisControl` 的 SCAN 規則仍不評估;沒有附理由的 exclude MUST 讓 profile 載入失敗(`LINT_PROFILE_INVALID`)

### Requirement: 合法程式不得被判解析失敗
Parser SHALL 依 `research/st-syntax-inventory.md` 把每個語法構造分成「支援」、「不支援但安全略過」、「不支援即 parse fail」。含有「安全略過」構造的 section MUST 記入 `coverage.notAnalyzed`,MUST NOT 產生 `LINT_PARSE_FAILED`;同一 section 的後續結構錯誤也 MUST 降級為 `notAnalyzed`。`LINT_PARSE_FAILED` 只能用於確定非法的輸入。

#### Scenario: 條件編譯 pragma
- **WHEN** 實作含 `{IF defined (SIMULATION)} IF bSim THEN {ELSE} IF bReal THEN {END_IF} … END_IF`
- **THEN** 該 section 記 `notAnalyzed`(reason `conditional-pragma`),MUST NOT 回 `LINT_PARSE_FAILED`

#### Scenario: 例外處理區塊
- **WHEN** 實作是 `__TRY fbAxis(Enable := TRUE); __CATCH(exc) … __ENDTRY`
- **THEN** `fbAxis` 的呼叫被認出;CATCH 分支內的呼叫算條件呼叫

#### Scenario: assignment attempt
- **WHEN** 實作含 `itfBrake ?= fbBase;`
- **THEN** tokenizer 不丟例外

#### Scenario: typed literal 不吞後面的運算式
- **WHEN** `IF tonA.ET > T#1S-tonB.ET THEN`
- **THEN** `tonB` 出現在識別字引用中

### Requirement: 規則 metadata
每條規則 SHALL 宣告穩定的 `id`、`version`、`category`、預設 `severity`、`confidence`、`blockable`(`true` / `false` / `pending`)、`requires`(前置條件)、已知限制、對應的 TE1200 規則與版別(Light / Full)、`compilerCatches`(`yes` / `no` / `unknown` / `measured:<日期>`)與 `machineImpact`(`none` / `project-integrity` / `behavior` / `crash`)。每筆 diagnostic MUST 帶 `ruleId`、`ruleVersion` 與 `machineImpact`。判斷確定的規則預設 `blockable: true`;依賴未實測 XAE 行為的規則 MUST 是 `pending`。

#### Scenario: 規則邏輯改變
- **WHEN** 某規則的偵測邏輯改變
- **THEN** 它的 `version` 加一;語意大改時換新的 rule id

### Requirement: blocking 的判定
一筆 finding SHALL 只在下列條件都成立時為 blocking:未被 suppress、severity ≥ `FailOn`、confidence 為 high 或 profile 對該規則明確設 `"blocking": true`。`blockable` 為 false 的規則 MUST NOT 因 `FailOn` 變成 blocking,只有 profile 明確設定時才會 blocking,此時 diagnostic MUST 帶 `blockingSource: "profile"`。`FailOn` 預設 `error`;參數只能比 profile 更嚴。`blockable` 為 `pending`(依賴未實測的 XAE 行為)的規則照算 blocking,diagnostic MUST 帶 `blockableBasis: "pending-measurement"`。

#### Scenario: FailOn warning 不影響非 blockable 規則
- **WHEN** `-FailOn warning`,`.plcproj` 目錄下有一個未列入 Compile 的 `.TcPOU`(PROJECT-COMPILE-003)
- **THEN** 該 finding `blocking: false`

#### Scenario: heuristic 規則預設不擋
- **WHEN** default profile 下出現 SCAN-TIMER-001
- **THEN** 它是 warning,`blocking: false`,並列在 `data.unresolved`

### Requirement: 影響機台行為的 warning 必須處置
未被 suppress、`machineImpact` 為 `behavior` 或 `crash` 的 finding SHALL 列入 `data.unresolved`;非空時 `data.requiresDisposition` MUST 為 true,`success` 維持依 verdict 決定。`compilerCatches` 為 `yes` 的規則 MUST NOT 進 `unresolved`,也 MUST NOT 進 `coverage.blockingRulesSkipped`。`data.newSuppressions` MUST 列出本次新增、磁碟版本沒有的 suppression。SKILL.md 的 Failure contract MUST 規定 `requiresDisposition` 為 true 時 agent 不得呼叫 `EnableConfig` / `RunLifecycle` 或回報完成,並把 `newSuppressions` 逐條列給使用者。

#### Scenario: warning 未處置
- **WHEN** 只有一筆 SCAN-TIMER-005 warning(behavior),沒有 suppression
- **THEN** `success: true`、`data.passed: true`、`data.requiresDisposition: true`,`data.unresolved` 有這一筆

#### Scenario: 帶理由 suppress 後
- **WHEN** agent 在該行上方加 `// tcauto-lint-disable-next-line SCAN-TIMER-005: 離開狀態時由外層 FB 重置`
- **THEN** `data.unresolved` 為空、`requiresDisposition: false`,`data.newSuppressions` 列出這一行與理由

### Requirement: EnableConfig 的 lint 摘要先不擋
在 stale 偵測真機驗證之前,`EnableConfig` / `RunLifecycle` 的 lint 整合 SHALL 只在結果附 `data.lint` 摘要(verdict、unresolved 數、newSuppressions、ideChecked),MUST NOT 因 lint 結果改變 EnableConfig 的成功與否。blocking 模式(`LINT_GATE_BLOCKED`)只能在 stale 偵測真機驗證通過後、以明確參數開啟。

#### Scenario: advisory
- **WHEN** advisory 模式下 `EnableConfig`,lint 有 2 筆 unresolved
- **THEN** EnableConfig 照常執行,`data.lint.unresolved` 為 2

### Requirement: Suppression 必須有理由
Suppression SHALL 寫成 ST 註解 `tcauto-lint-disable-next-line|disable-line|disable-object <RULE-ID>[, ...]: <理由>`,或 profile `suppressions[]`(精確 `objectPath` + `ruleId` + `reason`)。沒有理由或理由少於 8 字的 suppression MUST NOT 生效,並產生 `LINT-SUPPRESS-001`;未知 rule id 產生 `LINT-SUPPRESS-002`。`blockable` 為 true 或 pending 的規則 MUST NOT 接受 inline suppression,只能用 profile `suppressions[]`;inline 寫了 MUST NOT 生效並產生 `LINT-SUPPRESS-004`。`LintCandidate` MUST 在 `data.newSuppressions` 列出候選新增、磁碟版本沒有的 inline suppression。被壓掉的 finding MUST 仍出現在 diagnostics,帶 `suppressed: true` 與理由,且不計入 errors / warnings。

#### Scenario: agent 自己壓掉 blocking 規則
- **WHEN** 候選在簽章錯誤的 Method 上方加了 `// tcauto-lint-disable-next-line CONTRACT-ITF-002: 簽章差異為預期設計`
- **THEN** CONTRACT-ITF-002 仍照常報出,另有一筆 LINT-SUPPRESS-004,`data.newSuppressions` 列出這一行

#### Scenario: 沒寫理由
- **WHEN** 程式碼有 `// tcauto-lint-disable-next-line SCAN-TIMER-001`
- **THEN** SCAN-TIMER-001 照常報出,另有一筆 LINT-SUPPRESS-001

### Requirement: Profile 只是資料
Rule profile SHALL 是 JSON 資料(schema `tcauto-lint-profile/1`),只能設定規則開關、severity、blocking、參數、型別目錄、exclude、suppression 與 baseline 路徑。Profile MUST NOT 能執行 PowerShell / JavaScript 或其他程式,樣式比對只支援精確名稱與 glob。載入或驗證失敗 MUST 回 `LINT_PROFILE_INVALID` 且不執行任何規則。每次結果 MUST 回報 `data.profile` 的名稱、來源路徑、sha256,以及 `overrides`(所有相對 default 變弱的設定:被關掉或降級的預設 blocking 規則、exclude、acceptSkips、suppressions、拿掉的 baseline)。`.tcauto\` 目錄存在但 profile 讀不到 MUST 回 `LINT_PROFILE_INVALID`,MUST NOT 退回 default。

#### Scenario: profile 有路徑跳出
- **WHEN** profile 的 `baseline` 是 `..\..\Windows\x.json`
- **THEN** 回 `LINT_PROFILE_INVALID`

### Requirement: CONTRACT 規則需要明確 baseline
需要相容性比對的規則(CONTRACT-ENUM-*、CONTRACT-DUT-*)SHALL 只對 baseline 檔列出的型別比對,並以 baseline 為主迴圈:baseline 有而目前沒有的型別、kind 改變 MUST 報出。數值比對前 MUST 把 IEC 整數字面值正規化(`16#0A` 與 `10` 相同)。預設位置有 baseline 檔就 MUST 載入,不需要 profile 指定。沒有 baseline 時 MUST NOT 推測,規則列入 `rulesNotRun`(reason `no-baseline`)。baseline 檔存在但格式錯 MUST 回 `LINT_BASELINE_INVALID`。

#### Scenario: 同值不同寫法
- **WHEN** baseline `Manual = 10`,目前寫成 `Manual := 16#0A`
- **THEN** 不報 CONTRACT-ENUM-002

#### Scenario: 型別被刪
- **WHEN** baseline 有 `E_MachineMode`,目前專案沒有
- **THEN** 報 CONTRACT-ENUM-001

#### Scenario: Enum 數值被改
- **WHEN** baseline 中 `E_MachineMode.Manual = 0`,目前程式改成 `Manual := 1`
- **THEN** 出現 CONTRACT-ENUM-002(blocking),而且隱含值跟著變的 `Auto` 也報出

### Requirement: Diagnostics 結構與排序
每筆 diagnostic SHALL 含 `ruleId`、`ruleVersion`、`severity`、`confidence`、`blocking`、`suppressed`、`file`(相對 `.plcproj` 目錄,`/` 分隔)、`objectPath`(與 `WritePouCode -PouName` 同格式)、`section`、`line`、`column`(section 內 1-based)、`message`,可選 `evidence`、`fixHint`、`autoFix`。排序 MUST 依 `file` → `objectPath` → section → `line` → `column` → `ruleId` → `message`,全部用 ordinal / invariant 比較。預設輸出 MUST NOT 含時間戳或耗時;`message` MUST 是固定英文模板,.NET 例外訊息只能放在 `data.engineDetail`。

#### Scenario: deterministic
- **WHEN** 同一輸入在 en-US 與 zh-TW culture 的 PowerShell 各跑兩次
- **THEN** 四次的 JSON 輸出 byte 相同

### Requirement: AI 改磁碟檔造成的專案損毀
系統 SHALL 在 Phase 1a 提供 `rule-catalog.md` 第 1 節的 PROJECT-XML / KIND / NAME / GUID / SUB / LINEIDS / COMPILE / LIB / TSPROJ / ENC 規則。結構檢查 MUST 以 `research/tc-xml-schema-observed.md`(XAE 實際產生的檔案)為依據;語料沒觀察到的物件種類 MUST 記 `rulesNotRun`(reason `schema-not-observed`),不得猜測結構。XAE 實際行為未實測的規則 MUST 是 `blockable: pending`。XAE 原樣產生的檔案 MUST NOT 產生任何 PROJECT-* finding。

#### Scenario: CDATA 被切開
- **WHEN** agent 手寫的 `.TcPOU` 程式碼含 `]]>`,`<ST>` 變成兩段 CDATA
- **THEN** 報 PROJECT-XML-003(blocking)

#### Scenario: 複製檔案沒換 Id
- **WHEN** `FB_B.TcPOU` 是複製 `FB_A.TcPOU` 改名而來,POU `Id` 相同
- **THEN** 報 PROJECT-GUID-003,`blockableBasis: "pending-measurement"`(實測前)

#### Scenario: XAE 原樣檔案
- **WHEN** 對未修改的 4024 與 4026 測試專案跑 `LintProject`
- **THEN** 沒有任何 PROJECT-XML / GUID / KIND / COMPILE / TSPROJ finding

### Requirement: 判斷確定的機台行為規則預設 blocking
SCAN-TEMPFB-001、PROJECT-TASK-002、SCAN-LOOP-001、SCAN-FOR-001、SCAN-ARR-001 SHALL 在 default profile 為 blocking(依 `rule-catalog.md`;規則依據的 TwinCAT 行為在取得 InfoSys 出處或實測前 MUST 是 `pending`)。heuristic 規則 MUST NOT 預設 blocking。

#### Scenario: Timer 宣告在 METHOD VAR
- **WHEN** `METHOD M_Wait : BOOL VAR ton : TON; END_VAR ton(IN := TRUE, PT := T#2S); M_Wait := ton.Q;`
- **THEN** 報 SCAN-TEMPFB-001(blocking);改成 `VAR_INST` 後不報

#### Scenario: busy-wait
- **WHEN** `WHILE NOT bSensor DO END_WHILE`,`bSensor` 是 `AT %I*` 變數
- **THEN** 報 SCAN-LOOP-001(blocking)

#### Scenario: FOR 溢位
- **WHEN** `i : BYTE; FOR i := 0 TO 255 DO … END_FOR`
- **THEN** 報 SCAN-FOR-001(blocking)

#### Scenario: PROGRAM 沒掛 task
- **WHEN** PROGRAM `TestCam` 沒在任何 `.TcTTO` 的 `PouCall`,也沒被可達的 POU 呼叫
- **THEN** 報 PROJECT-TASK-001(warning),列入 `data.unresolved`

### Requirement: 其他規則
系統 SHALL 依 `rule-catalog.md` 的 phase 提供其餘規則(SCAN-FBCALL、SCAN-TIMER、SAFETY、SCAN-SM / MC / REF / FBVAL / OUT / FLOAT / INTDIV、CONTRACT-*、POLICY-*)。default profile 中 POLICY-* MUST 預設關閉。CONTRACT-ITF-002 的每一種差異只有在實測確認 TwinCAT 編譯器會擋時才能是 blocking,其餘 MUST 是 warning。POLICY-INTERLOCK-001 的訊息與文件 MUST 寫明「不取代 TwinSAFE / 安全評估」。

#### Scenario: Timer 只在 IF 內呼叫
- **WHEN** `IF state = 3 THEN tonWebBreak(IN := x, PT := T#500MS); END_IF`,且 `tonWebBreak` 沒有其他呼叫
- **THEN** 報 SCAN-TIMER-001(warning、medium、非 blocking)

#### Scenario: IF / ELSE 兩邊都呼叫
- **WHEN** `tonRelease` 在 `IF a THEN tonRelease(IN := TRUE); ELSE tonRelease(IN := FALSE); END_IF` 的兩個分支都呼叫
- **THEN** 不報 SCAN-TIMER-001

#### Scenario: 型別不在目錄
- **WHEN** `x : MC_Direction;`(ENUM)被讀取但沒有呼叫
- **THEN** 不報 SCAN-FBCALL-001;若 `MC_Direction` 不在型別目錄,它記在 `rulesSkipped`(reason `unknown-type`)

#### Scenario: Interface 簽章不一致
- **WHEN** `I_Brake.M_Release(bForce : BOOL)`,FB 實作成 `M_Release(nForce : INT)`
- **THEN** 報 CONTRACT-ITF-002;參數型別差異經實測確認編譯器會擋後為 error、high、blocking,實測前為 warning、medium
