每一期 = 一個 PR,可單獨 review / merge。每期都要 `scripts/check.ps1 -Strict` 綠燈;新 tool 依 repo 慣例同步 `$operationMap`、`Export-ToolSchema.ps1`、`tools.json`、`Update-GeneratedDocs.ps1`、`catalog.test.js`、`docs/troubleshooting.md`(每個新 error code 一節)。

## 0. Phase 0:設計(本 PR,Refs #252)

- [x] 0.1 proposal / design / spec / tasks
- [x] 0.2 throwaway prototype 與語料實測(`research/corpus-feasibility.md`)
- [x] 0.3 TE1200 規則對照(`research/te1200-rules.md`)、候選規則排序(`research/rule-candidates.md`)
- [x] 0.4 reviewer 對抗性審查,結果記在 design.md「Review 紀錄」
- [ ] 0.5 owner 回答 design.md Open Questions(至少 1、2、3、4)後再開 Phase 1

## 1. Phase 1:引擎骨架 + LintProject + PROJECT 規則

- [ ] 1.1 `Private/Lint/*.cs`(C# 5):tokenizer、宣告 parser、陳述式結構掃描、`.plcproj` / TcPOU 讀取(`XmlReader`,禁 DTD / 外部實體)、diagnostic 模型與排序
- [ ] 1.2 延遲編譯 + hash namespace(D1);`data.engine.sourceHash`
- [ ] 1.3 `Invoke-TcLintProject`(`-PlcProjectPath` 檔案路徑 / PLC 名稱、`-SolutionPath`、`-Scope All|Object`、`-ObjectPaths`、`-RuleProfile default`、`-FailOn`、`-IncludeTiming`)
- [ ] 1.4 規則:PROJECT-COMPILE-001/002/003、PROJECT-GUID-001、PROJECT-KIND-001、PROJECT-NAME-001、LINT-PARSE-001/002、LINT-XML-001/002、LINT-COVERAGE-001
- [ ] 1.5 verdict / coverage / error code(`LINT_FAILED`、`LINT_PARSE_FAILED`、`LINT_INCOMPLETE`、`LINT_PROFILE_INVALID`、`LINT_INPUT_INVALID`、`LINT_ENGINE_ERROR`;沿用 `PLC_PROJECT_AMBIGUOUS` / `PLC_PROJECT_NOT_FOUND`)
- [ ] 1.6 查證並記錄:`/* */` 註解是否合法、`<Implementation>` 多個 `<ST>` 的語意、`.tsproj` 內 `.plcproj` 參照格式(InfoSys 或實測,附出處)
- **驗收**:
  - `tests/Unit/lint-parser.ps1`:每種 token / 宣告形式正反例,含語料撞過的坑(`END_IF` 不接分號、巢狀 `(* *)`、`$'`、BOM、中文註解)
  - `tests/Unit/lint-contract.ps1`:D4 表每一列一個 case;`passed` 欄位在未分析時不存在;code 優先序;en-US / zh-TW byte 相同;檔案列舉順序打亂結果相同
  - `tests/Unit/lint-project-rules.ps1`:PROJECT 規則各 ≥2 正例、≥2 反例
  - 語料回歸(若 owner 同意 fixture 進 repo):解析 100%、不 crash、finding 快照
  - 效能:≤ 200 物件的專案 ≤ 2 s(不含首次編譯),首次編譯 ≤ 3 s
  - Integration(真實 `.plcproj`,不需 runtime):兩個測試副本跑 `LintProject` 結果與快照一致
  - 既有 `CheckAllObjects` / `BuildProject` / `WritePouCode` / lifecycle guard 的 unit 全綠

## 2. Phase 2:LintCandidate + suppression + SCAN 規則 + stale 偵測

- [ ] 2.1 `Invoke-TcLintCandidate`(`ObjectKind`、`ObjectName`、`Declaration`、`Implementation`、`PlcProjectPath`、`RuleProfile`、`FailOn`);overlay 語意(同名取代、新物件加入)
- [ ] 2.2 suppression 解析與 LINT-SUPPRESS-001/002/003
- [ ] 2.3 FB 型別目錄:專案內 FB + 版本化 library 清單(每個名稱附 InfoSys 來源)+ profile `typeCatalog`
- [ ] 2.4 SCAN-FBCALL-001/002、SCAN-TIMER-001/002(含 IF…ELSE 全分支、Action 呼叫圖;CASE…ELSE 全分支)
- [ ] 2.5 `LintProject` 在 IDE 已連線時的未存檔偵測:`LINT_SOURCE_STALE` / `LINT_SOURCE_UNVERIFIED`
- [ ] 2.6 **真機**(registered tcauto,一次一個 worker):`WritePouCode` 後 `Project.Saved` / `Document.Saved` 的實際值(4024 XAE、4026 VS2022);若不會變 false,改成「有 code-changed 紀錄就視為 stale」
- [ ] 2.7 SKILL.md 與 tool description:LintCandidate → WritePouCode → BuildProject → LintProject 的工作流;`passed` 的範圍說明
- **驗收**:
  - 規則 fixture:每條 ≥2 正例、≥2 反例(含 research 4.2 / 4.4 的已知誤報案例:`MC_Direction` 類型、IF/ELSE 兩邊呼叫、Action 無條件呼叫)、suppression 有理由 / 沒理由
  - seeded 套件:S01–S09、S14、S15 命中;S16–S18 不報
  - 第三個以上真實專案(owner 提供)跑 SCAN 規則,人工判讀誤報率,寫進 `verification/`
  - 真機紀錄 2.6 寫進 `verification/`,未實測項目列在 `docs/known-limitations.md`

## 3. Phase 3:CONTRACT 規則 + baseline

- [ ] 3.1 CONTRACT-ITF-001/002(Interface `EXTENDS` 鏈、專案內基底 FB `EXTENDS` 鏈、Property Get/Set;library 內的型別記 `rulesSkipped`)
- [ ] 3.2 baseline 讀取(schema `tcauto-lint-baseline/1`)、`LINT_BASELINE_INVALID`
- [ ] 3.3 CONTRACT-ENUM-001/002(含隱含值)、CONTRACT-DUT-001
- [ ] 3.4 `New-TcLintBaseline`(寫檔,不覆寫既有檔除非 `-Force`,回傳內容)
- [ ] 3.5 `Get-TcLintRule`(MCP `GetLintRule`):metadata、正反例、限制
- **驗收**:fixture 覆蓋 S10–S13;baseline 缺失時 `rulesNotRun`;baseline 壞掉時 fail closed;CONTRACT-ITF 在型別別名 / qualified 名稱的反例不誤報

## 4. Phase 4:POLICY 引擎 + 候選規則

- [ ] 4.1 POLICY-SYMBOL-001、POLICY-NAME-001/002、POLICY-CALL-001、POLICY-RETVAL-001(profile 參數驅動)
- [ ] 4.2 內建 `robust-solution` profile:`research/rule-candidates.md` 第 3 節「宣告 / token 就夠」欄,只在偵測到框架繼承鏈時啟用
- [ ] 4.3 依 `research/rule-candidates.md` 排序實作:PROJECT-TASK-001、ST-LLM-001、SCAN-SM-001、SCAN-TIMER-004、PROJECT-TASK-002(每條一個小 PR 也可以)
- [ ] 4.4 (owner 同意才做)`RunLifecycle` / `EnableConfig` 的 `-LintGate`(D9),預設關閉
- **驗收**:每條規則 fixture + 語料誤報判讀;`robust-solution` profile 對一個 Robust Solution 專案跑一次並人工判讀
