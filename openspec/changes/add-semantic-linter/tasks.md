每一期 = 一個 PR,可單獨 review / merge。每期都要 `scripts/check.ps1 -Strict` 綠燈;新 tool 依 repo 慣例同步 `$operationMap`、`Export-ToolSchema.ps1`、`tools.json`、`Update-GeneratedDocs.ps1`、`catalog.test.js`、`docs/troubleshooting.md`(每個新 error code 一節)。分期依 owner 決定 1:`compilerCatches = no` 且 `machineImpact ∈ behavior / crash` 優先,AI 改磁碟檔的問題留在 1a,CONTRACT 最後。規則定義見 `rule-catalog.md`。

「IDE 實測」= 只需 XAE、不需 runtime,在本機測試副本的**副本**上做(不 attach 使用者開著的原始專案),一次一個真機 worker,結果寫進 `verification/` 並附日期、XAE 版本、host。

## 0. Phase 0:設計(本 PR,Refs #252)

- [x] 0.1 proposal / design / spec / tasks / rule-catalog
- [x] 0.2 throwaway prototype 與語料實測(`research/corpus-feasibility.md`)
- [x] 0.3 TE1200 規則對照(`research/te1200-rules.md`)
- [x] 0.4 第一輪 reviewer 對抗性審查(design.md Review 紀錄)
- [x] 0.5 owner 決定 6 點(#252 留言)與第二輪獨立審查(PR #262 留言)落實
- [x] 0.6 `research/st-syntax-inventory.md`(ST 語法清單 + TwinCAT 行為出處)、`research/tc-xml-schema-observed.md`(XAE 實際 XML 結構)、`research/error-taxonomy-draft.md`(錯誤分類初版)
- [ ] 0.7 owner 確認錯誤分類初版並凍結(可與 Phase 1a 並行)

## 1a. Phase 1a:引擎 + 契約 + AI 改檔問題整類 + IDE 實測

- [ ] 1a.1 `Private/Lint/*.cs`(C# 5):tokenizer(含 `?=`、`S=`、`R=`、`REF=`、各 typed literal 前綴的文法)、宣告 parser(含 `VAR_GENERIC` 認得或安全略過)、陳述式結構掃描(含 `__TRY` / `__CATCH` / `__FINALLY` / `__ENDTRY`、條件 pragma → `notAnalyzed`)、XML 讀取、diagnostic 模型與排序
- [ ] 1a.2 延遲編譯 + hash namespace + LanguageMode 檢查(`LINT_ENGINE_UNAVAILABLE`)
- [ ] 1a.3 `Invoke-TcLintProject`(磁碟;`-PlcProjectPath`、`-SolutionPath`、`-Scope`、`-ObjectPaths`、`-RuleProfile default`、`-FailOn`、`-IncludeTiming`)
- [ ] 1a.4 契約:verdict / coverage(按規則計算)/ `unresolved[]` / `requiresDisposition` / metadata 的 `machineImpact`、`compilerCatches`、`te1200`;error code 全套(D4)
- [ ] 1a.5 規則:PROJECT-XML-001~004、PROJECT-KIND-001、PROJECT-NAME-001 / 002、PROJECT-GUID-001~004、PROJECT-SUB-001 / 002、PROJECT-LINEIDS-001、PROJECT-COMPILE-001~006、PROJECT-LIB-001、PROJECT-TSPROJ-001~003、PROJECT-ENC-001、LINT-*;結構依據 `research/tc-xml-schema-observed.md`
- [ ] 1a.6 profile / baseline 自動探索與 fail closed(Phase 1a 只有 default profile)、`overrides[]`
- [ ] 1a.7 (4026 VS2022 完成、4024 部分;結果 `verification/xae-corrupt-file-behavior.md`,blockable 已定案) **IDE 實測:XAE 遇到損毀檔案的行為**(每條 PROJECT-* 規則一個案例:植入 → `Reset-TcSolution` → `Get-TcProjectTree` / `BuildProject`,記錄是否跳框、物件是否消失、Build 結果)。依結果把 `blockable: pending` 定案;含空白 / `'` / `%` 檔名在 `.plcproj` 的實際寫法;`<LineIds>` 不一致時 XAE 是否重建;行尾 / 編碼混用的顯示
- [ ] 1a.8 (Transition / SFC POU 本體 tcauto 建不了,其餘完成;`verification/xae-generated-xml.md`) **IDE 實測:用 XAE 產生 `.TcIO`、Property(Get / Set)、Transition、SFC 物件**,補進 `tc-xml-schema-observed.md` 與 XML fixture(取代 prototype 自己寫的 Interface XML)
- [ ] 1a.9 (問題 1~3 實測完成、問題 4 只有 InfoSys;`verification/te1200-light.md`) **IDE 量測:TE1200 Light**(design.md D11 的四個問題)
- [ ] 1a.10 (完成,VAR_GENERIC / subrange 未判定;`verification/st-syntax-measured.md`) **查 InfoSys / IDE 實測**:`st-syntax-inventory.md` 標「未驗證」的語法項目(`?=`、`**`、`/* */`、`E_Enum#Member`、TIME literal 的底線 / 負號 / 小數、`END_IF` 後分號可省、多個 `<ST>` 元素是否存在);每項以最小 POU 跑 `BuildProject` 確認合法性
- **驗收**:
  - `tests/Unit/lint-parser.ps1`:語法清單每項一個 fixture;第二輪 review 6-1~6-4 的最小反例:條件 pragma → `notAnalyzed`(不是 `LINT_PARSE_FAILED`)、`__TRY` 內的呼叫被認出、`?=` 不丟例外、`T#1S-tonB.ET` 拆成正確 token
  - `tests/Unit/lint-project-xml.ps1`:XAE 原樣檔案(4024 與 4026 各一份,未在 XAE 外修改)零 finding;每條 PROJECT-* 規則至少 1 個破壞版正例;1a.7 加「在 XAE 寫入含 `]]>` 的程式碼」看 XAE 怎麼存
  - `tests/Unit/lint-contract.ps1`:D4 每一列一個 case(含 `LINT_ENGINE_UNAVAILABLE`);`unresolved[]` / `requiresDisposition`;en-US / zh-TW byte 相同
  - 兩個語料專案:解析 100%;axis 的 6 個假 GUID(PROJECT-GUID-005)與 11 個外部寫入檔(PROJECT-ENC-001)是預期正例;其餘 PROJECT-* 零 finding
  - 效能:≤ 200 物件 ≤ 2 s(不含首次編譯)
  - 1a.7~1a.10 的實測紀錄在 `verification/`

## 1b. Phase 1b:最確定的機台行為規則 + 磁碟改檔工作流

- [x] 1b.1 FB 型別目錄(專案內 FB + 版本化 library 清單,每個名稱附 InfoSys 來源 + profile `typeCatalog`),含「有狀態 FB」子集
- [x] 1b.2 SCAN-TEMPFB-001(blocking;METHOD `VAR`、FUNCTION `VAR`、`VAR_TEMP` 的重新初始化都有 InfoSys 出處)
- [x] 1b.3 PROJECT-TASK-001(必須處置)/ PROJECT-TASK-002(blocking):從 `.TcTTO` `PouCall` 建呼叫圖,依可達性判斷;以 `BuildProject` 實測「沒掛 task 的 PROGRAM 有語法錯時 Build 是否仍成功」(TASK-001 說明的依據)
- [x] 1b.6 suppression 提前上線(review 驗證 8:1a / 1b 已輸出 `unresolved[]`,沒有 suppression 就無法處置):inline(非 blockable 規則)與 profile `suppressions[]`、LINT-SUPPRESS-001~004、`newSuppressions[]`(LintProject 以 git HEAD 為基準)
- [x] 1b.4 語法清單中「安全略過」的項目,能做的改為「支援」(依 1a.10 結果)— 1a.10 結果是 4026.22 編譯器**拒絕** `?=`、`**`、`/* */`、`E_Enum#Member`、`T#-5S`、非 ASCII 識別字,沒有可改成「支援」的;4024 未測、owner 未決定,維持 notAnalyzed(可 pass),coverage reason 與 LINT-PARSE-002 / 003 的 limits 註明「4026.22 compiler rejects it (measured 2026-11-13)」;`T#-5S` 從「照常解析」改為 notAnalyzed
- [x] 1b.5 SKILL.md、CLAUDE.md 磁碟改檔段落、`docs/troubleshooting.md`「磁碟改檔的正確做法」加上:改檔 → `LintProject` → 通過才 `ResetSolution` → `BuildProject`(design.md D9)
- **驗收**:
  - 規則 fixture:SCAN-TEMPFB-001(METHOD VAR / FUNCTION VAR / VAR_TEMP 正例;METHOD VAR_INST、FB VAR 反例;第二輪 review 6-5 的 `M_Wait` 反例必須報)
  - PROJECT-TASK:axis 語料 `TestCam` 報 TASK-001(預期,必須處置);把 `TestCam` 加進 task 的變種報 TASK-002(`AxisInterface_Type01` 被兩處呼叫);bfh 語料零 finding
  - seeded:TON 搬進 METHOD VAR 的 mutation 必須命中

## 2. Phase 2:LintCandidate + 迴圈 / 陣列 / 除法 + Timer 細分 + stale 偵測

- [x] 2.1 `Invoke-TcLintCandidate`(overlay、`LINT_CONTEXT_REQUIRED`、overlay 邊界的 `LINT_INPUT_INVALID`)— PR #284;PLC 名稱 / IDE 已連線時省略路徑仍回 `LINT_INPUT_INVALID`(需要 IDE,與 LintProject 1a 一致);Transition 回 `LINT_INPUT_INVALID`(XML 結構未觀察)
- [x] 2.2 `LintCandidate` 的 `newSuppressions[]`(相對磁碟版本)— PR #284;profile 放寬照 git 基準列 `newOverrides[]`
- [x] 2.3 呼叫點模型:FB body 呼叫與 Method 呼叫分開,含 expression 內的呼叫;`inherited-use` — PR #284:1b 已有 expression / index 內呼叫與 `inExpression`;新增 `form`(body / member)、`returnValueUsed`、`viaSuper`。不經 `SUPER^` 的繼承成員呼叫要 EXTENDS 鏈,留給 2.5
- [x] 2.4 SCAN-LOOP-001、SCAN-FOR-001、SCAN-ARR-001(blocking);SAFETY-ARR-001、SAFETY-DIV-001 — PR #284(SAFETY-DIV-001 變數除數改為 info、不進 `unresolved[]`,理由見 rule-catalog)
- [x] 2.5 SCAN-FBCALL-001 / 002、SCAN-TIMER-001 / 002 / 004 / 005 — PR #289(`LintRules2b.cs`,測試 `tests/Unit/lint-rules-2b.ps1`;定義見 rule-catalog 的「Phase 2b」節)
- [ ] 2.6 stale 偵測(D2):`.plcproj` 屬於連線中的 solution、樹 / 磁碟 `<Compile>` 比對、`Document.Saved`、4024 保守規則
- [ ] 2.7 **真機**(registered tcauto,一次一個 worker):4024 XAE 上 `WritePouCode` 後 .TcPOU 的落地時機;XAE 新增 / 刪除物件後 2.6 是否抓得到;4026 VS2022 重跑 #69
- [x] 2.8 SKILL.md:LintCandidate → WritePouCode → BuildProject → LintProject;Failure contract 加入 `requiresDisposition` 規定(不得 EnableConfig、不得回報完成、`newSuppressions[]` 逐條列給使用者)— PR #284(Stop conditions 第 5 條)
- [ ] 2.9 PROJECT-SA-001(只在 1a.9 量測支持時做)
- [ ] 2.10(部分完成,不打勾)**IDE / UmRT 實測**(`st-syntax-inventory.md` 第 2 部分仍標未驗證的):TON 在 PT = 0 的行為、TON 中途幾個 cycle 沒被呼叫再進入的語意(SCAN-TIMER-004 / 005 的依據)、除以零與越界(未加 CheckBounds)在 runtime 的結果、未初始化 REFERENCE 解參照的後果、`FOR … BY 0`;除以常數 0 編譯器擋不擋(`BuildProject`,填 `compilerCatches: measured`) — 實測紀錄 [verification/runtime-semantics-measured.md](verification/runtime-semantics-measured.md)(2026-11-13:PT = 0、未呼叫 cycle、BY 0、整數 / REAL 除以零、MOD 0 已測;LREAL 除以零、REFERENCE / POINTER 讀取、變數索引越界的 runtime 部分因 lifecycle block 未跑,所以未勾;其餘已測項目的實測依據已套用到 rule-catalog 與 `st-syntax-inventory.md`:2b / 2c / 6a / 6b(常數索引)/ 7b(編譯器部分)。**已完成**:PT = 0、未呼叫 cycle、`BY 0`、DINT / REAL 除以零與 `MOD 0`、STRUCT 內 FB、只呼叫 Action、同一 PROGRAM 兩個 task、常數索引讀取、REFERENCE / POINTER 編譯器不擋;**未完成**:LREAL 除以零、REFERENCE / POINTER 的 runtime 讀取、變數索引越界的 runtime 結果、cycle 不結束時是否停 PLC、`%I*` 輸入在程式執行中是否不變)
- **驗收**:每條規則 ≥2 正例、≥2 反例(含 research 4.2 / 4.4 已知誤報案例)、1 個 suppression;seeded S06~S09、S16、S17 命中;stale 偵測真機紀錄

## 3. Phase 3:狀態機 / Motion / 記憶體 / 數值 + 驗證 + advisory gate

- [ ] 3.1 SCAN-SM-001、SCAN-MC-001 / 002(先補 Tc2_MC2「General rules for MC function blocks」InfoSys 出處)、SCAN-REF-001、SCAN-FBVAL-001、SCAN-OUT-001、SCAN-FLOAT-001、SCAN-INTDIV-001
- [ ] 3.2 錯誤分類清單凍結(0.7 + owner 提供的清單),記日期與 commit
- [ ] 3.3 LLM 產生語料(2–3 模型 × 約 30 任務)+ `BuildProject` 篩選 + owner 盲標;算每條規則 precision / recall,與 TE1200 Light 同批比較
- [ ] 3.4 Mutation testing:依錯誤分類寫 mutation operator,批次產生變種並跑 `BuildProject`,把 `compilerCatches` 改成 `measured:<日期>`
- [ ] 3.5 Holdout:owner 提供的第三個以上專案不用來調規則;規則凍結後跑一次。**接受門檻(事先寫明,跑之前由 owner 確認)**:blocking 規則誤報 0;warning 規則誤報率 ≤ 20%;未達門檻的規則不得升級
- [ ] 3.6 依 3.3~3.5 結果決定哪些 warning 升級為 blocking
- [ ] 3.7 EnableConfig / RunLifecycle advisory:Activate 前跑 `LintProject`,摘要放 `data.lint`,不擋(真機驗證)
- **驗收**:驗證報告寫進 `verification/`(每條規則的 precision / recall、compilerCatches 實測值);advisory 真機紀錄

## 4. Phase 4:契約 + TE1200 SARIF + POLICY + blocking gate

- [ ] 4.0 **IDE 實測**:Interface 實作差異(回傳型別、參數型別、參數名稱、VAR_OUTPUT 順序、Property Get vs Get+Set、ABSTRACT FB)編譯器擋不擋;enum 隱含值規則
- [ ] 4.1 CONTRACT-ITF-001 / 002(compilerCatches = yes 的差異不進 `blockingRulesSkipped`)
- [ ] 4.2 baseline 讀取、`LINT_BASELINE_INVALID`、`New-TcLintBaseline`;CONTRACT-ENUM / DUT(含 PERSISTENT 情境說明)
- [ ] 4.3 `Get-TcLintRule`(MCP `GetLintRule`)
- [ ] 4.4 TE1200 SARIF 合併(依 1a.9 結果;Full 授權客戶)
- [ ] 4.5 POLICY 引擎、`robust-solution` profile、POLICY-INTERLOCK-001(輸出明寫「不取代 TwinSAFE / 安全評估」)、ST-LLM-001
- [ ] 4.6 `-LintGate` blocking 模式(`LINT_GATE_BLOCKED`;前提:2.7 stale 偵測真機驗證通過)

## 5. 後續(不綁 phase)

- [ ] 5.1 抽出共用 `Import-TcCSharpSource` helper,`TcAdsHelper` / `ComRotHelper` / lint 一起改用 hash 型別名稱(review 第二輪 4-3)
- [ ] 5.2 git 歷史反向植入(視 owner 專案有無 git 歷史)
