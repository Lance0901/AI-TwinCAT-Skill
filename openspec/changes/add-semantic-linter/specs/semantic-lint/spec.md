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
IDE 已連線時,`LintProject` SHALL 在分析前檢查該 PLC 專案的未存檔變更。有未存變更 MUST 回 `LINT_SOURCE_STALE`(`data.unsaved` 列出);無法判斷 MUST 回 `LINT_SOURCE_UNVERIFIED`。兩者都 MUST NOT 輸出 `data.passed`。

#### Scenario: WritePouCode 後未存檔
- **WHEN** 用 `WritePouCode` 改了 `FB_X` 但還沒存檔,接著呼叫 `LintProject`
- **THEN** 回 `LINT_SOURCE_STALE`,hint 建議改用 `LintCandidate -PlcProjectPath` 檢查剛寫的文字,或存檔後重跑

### Requirement: 結果語意 fail closed
每次呼叫 SHALL 回傳 `data.verdict`(`pass` / `fail` / `incomplete`)。`data.passed` MUST 等於 `verdict == "pass"`,`success` MUST 只在 verdict 為 `pass` 時為 true。只有非 blocking finding 時 verdict MUST 是 `pass`。分析未執行(profile 無效、輸入錯、多 PLC 未指定、未存檔、引擎例外)時 MUST NOT 輸出 `data.passed` 欄位。

| 情境 | error.code |
|---|---|
| 有 blocking finding | `LINT_FAILED` |
| 有物件無法解析 | `LINT_PARSE_FAILED` |
| 範圍內有未分析的物件 | `LINT_INCOMPLETE` |
| profile 無效 | `LINT_PROFILE_INVALID` |
| baseline 無效或 profile 要求卻找不到 | `LINT_BASELINE_INVALID` |
| 參數錯 / 檔案找不到 | `LINT_INPUT_INVALID` |
| 引擎例外 | `LINT_ENGINE_ERROR` |

多種同時發生時依 design.md D4 的優先序選 code,diagnostics 全部保留。

#### Scenario: 只有 warning
- **WHEN** 分析完成,只有一筆 SCAN-TIMER-001 warning
- **THEN** `success: true`、`data.passed: true`、`data.verdict: "pass"`,diagnostics 含那筆 warning

#### Scenario: blocking finding
- **WHEN** `.plcproj` 有一個 `<Compile>` 指向不存在的檔
- **THEN** `success: false`、`error.code: LINT_FAILED`、`data.passed: false`,完整 diagnostics 保留

#### Scenario: 解析失敗不得 PASS
- **WHEN** 某個 POU 少一個 `END_IF`,其他物件都沒問題
- **THEN** `error.code: LINT_PARSE_FAILED`、`data.passed: false`,其他物件的 diagnostics 照常輸出

#### Scenario: profile 壞掉
- **WHEN** `-RuleProfile` 指向的 JSON 有未知的 rule id
- **THEN** 回 `LINT_PROFILE_INVALID`,沒有任何規則被執行,`data.passed` 不存在

### Requirement: 未分析的內容要明確回報
非 ST 實作(SFC、CFC、LD、FBD、IL)、無法讀取的物件、規則因前置條件不足而未評估的範圍 SHALL 列在 `data.coverage`(`notAnalyzed[]`、`excluded[]`、`rulesSkipped[]`、`rulesNotRun[]`),每筆帶 `objectPath` 與 `reason`。範圍內有 `notAnalyzed` 時 verdict MUST NOT 是 `pass`。物件只有部分 section 被分析時,依賴該物件呼叫點的規則 MUST 對整個物件不評估並記入 `rulesSkipped`。

#### Scenario: CFC Action
- **WHEN** `FB_AxisControl` 有一個 CFC Action,`Scope=All`,profile 沒有排除它
- **THEN** `coverage.notAnalyzed` 有 `FB_AxisControl.A90_Cyclic`(reason `language:CFC`),verdict 為 `incomplete`,`FB_AxisControl` 的 SCAN 規則列在 `rulesSkipped`

#### Scenario: 帶理由排除
- **WHEN** profile `exclude` 列了 `FB_AxisControl.A90_Cyclic` 並附理由
- **THEN** 它出現在 `coverage.excluded`(含理由),不算 `notAnalyzed`;沒有附理由的 exclude MUST 讓 profile 載入失敗(`LINT_PROFILE_INVALID`)

### Requirement: 規則 metadata
每條規則 SHALL 宣告穩定的 `id`、`version`、`category`、預設 `severity`、`confidence`、`blockable`、`requires`(前置條件)、已知限制,以及對應的 TE1200 規則與編譯器是否會報(未知就寫 unknown)。每筆 diagnostic MUST 帶 `ruleId` 與 `ruleVersion`。

#### Scenario: 規則邏輯改變
- **WHEN** 某規則的偵測邏輯改變
- **THEN** 它的 `version` 加一;語意大改時換新的 rule id

### Requirement: blocking 的判定
一筆 finding SHALL 只在下列條件都成立時為 blocking:未被 suppress、severity ≥ `FailOn`、confidence 為 high 或 profile 對該規則明確設 `"blocking": true`。`blockable` 為 false 的規則只有 profile 明確設定時才會 blocking,此時 diagnostic MUST 帶 `blockingSource: "profile"`。`FailOn` 預設 `error`。

#### Scenario: heuristic 規則預設不擋
- **WHEN** default profile 下出現 SCAN-TIMER-001
- **THEN** 它是 warning,`blocking: false`

### Requirement: Suppression 必須有理由
Suppression SHALL 寫成 ST 註解 `tcauto-lint-disable-next-line|disable-line|disable-object <RULE-ID>[, ...]: <理由>`,或 profile `suppressions[]`(精確 `objectPath` + `ruleId` + `reason`)。沒有理由或理由少於 8 字的 suppression MUST NOT 生效,並產生 `LINT-SUPPRESS-001`;未知 rule id 產生 `LINT-SUPPRESS-002`。被壓掉的 finding MUST 仍出現在 diagnostics,帶 `suppressed: true` 與理由,且不計入 errors / warnings。

#### Scenario: 沒寫理由
- **WHEN** 程式碼有 `// tcauto-lint-disable-next-line SCAN-TIMER-001`
- **THEN** SCAN-TIMER-001 照常報出,另有一筆 LINT-SUPPRESS-001

### Requirement: Profile 只是資料
Rule profile SHALL 是 JSON 資料(schema `tcauto-lint-profile/1`),只能設定規則開關、severity、blocking、參數、型別目錄、exclude、suppression 與 baseline 路徑。Profile MUST NOT 能執行 PowerShell / JavaScript 或其他程式,樣式比對只支援精確名稱與 glob。載入或驗證失敗 MUST 回 `LINT_PROFILE_INVALID` 且不執行任何規則。每次結果 MUST 回報 `data.profile` 的名稱、來源路徑與 sha256。

#### Scenario: profile 有路徑跳出
- **WHEN** profile 的 `baseline` 是 `..\..\Windows\x.json`
- **THEN** 回 `LINT_PROFILE_INVALID`

### Requirement: CONTRACT 規則需要明確 baseline
需要相容性比對的規則(CONTRACT-ENUM-*、CONTRACT-DUT-*)SHALL 只對 baseline 檔列出的型別比對。沒有 baseline 時 MUST NOT 推測,規則列入 `rulesNotRun`(reason `no-baseline`)。baseline 檔存在但格式錯 MUST 回 `LINT_BASELINE_INVALID`。

#### Scenario: Enum 數值被改
- **WHEN** baseline 中 `E_MachineMode.Manual = 0`,目前程式改成 `Manual := 1`
- **THEN** 出現 CONTRACT-ENUM-002(blocking),而且隱含值跟著變的 `Auto` 也報出

### Requirement: Diagnostics 結構與排序
每筆 diagnostic SHALL 含 `ruleId`、`ruleVersion`、`severity`、`confidence`、`blocking`、`suppressed`、`file`(相對 `.plcproj` 目錄,`/` 分隔)、`objectPath`(與 `WritePouCode -PouName` 同格式)、`section`、`line`、`column`(section 內 1-based)、`message`,可選 `evidence`、`fixHint`、`autoFix`。排序 MUST 依 `file` → `objectPath` → section → `line` → `column` → `ruleId` → `message`,全部用 ordinal / invariant 比較。預設輸出 MUST NOT 含時間戳或耗時。

#### Scenario: deterministic
- **WHEN** 同一輸入在 en-US 與 zh-TW culture 的 PowerShell 各跑兩次
- **THEN** 四次的 JSON 輸出 byte 相同

### Requirement: MVP 規則
系統 SHALL 提供下列規則,行為依 design.md D6:PROJECT-COMPILE-001/002/003、PROJECT-GUID-001、PROJECT-KIND-001、PROJECT-NAME-001、CONTRACT-ITF-001/002、SCAN-FBCALL-001/002、SCAN-TIMER-001/002、CONTRACT-ENUM-001/002、CONTRACT-DUT-001、POLICY-SYMBOL-001、POLICY-NAME-001/002、POLICY-CALL-001、POLICY-RETVAL-001。default profile 中 SCAN-* 與 PROJECT-COMPILE-003、PROJECT-NAME-001 MUST NOT 是 blocking;POLICY-* MUST 預設關閉。

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
- **THEN** 報 CONTRACT-ITF-002(error、high、blocking)
