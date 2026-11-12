## Why

TcAuto 能 Build、能跑 CheckAllObjects,但 coding agent 寫出來的 PLC 程式常常 Build 成功卻在機台上出事:Timer / R_TRIG 只在 IF 裡呼叫、FB instance 宣告了卻沒呼叫、Interface 簽章不一致、`.plcproj` 漏了 Compile entry、公開 DUT / Enum 被改了 layout。這些問題編譯器不報,TE1200 只涵蓋其中一小部分,而且要等寫進 XAE、Build 完才看得到。#252 要在 TcAuto 內加一個 deterministic 的 Semantic Linter,**在寫入 XAE 之前與 Activate / Download 之前**把高信心問題擋下。

這個 change 是設計階段:可行性已用 throwaway prototype 在兩個真實專案(4024 / 4026)上實測(`research/corpus-feasibility.md`):宣告區 242/242、ST 實作 176/176 解析成功;seeded bug 18 個中範圍內 15/15 命中;同時量到 SCAN 類規則第一版誤報 68/71,所以 SCAN 類只能當 warning。

## What Changes

分 5 期,每期一個可獨立 review / merge 的 PR(tasks.md)。

- **Phase 0(本 PR)**:設計、規格、research(prototype、語料量測、TE1200 對照、候選規則排序)。不改產品程式。
- **Phase 1:引擎與 LintProject**
  - C# 5 引擎(`src/TwinCATAutomation/Private/Lint/*.cs`,`Add-Type` 延遲編譯):tokenizer、宣告 parser、陳述式結構掃描、TcPOU / plcproj 讀取、diagnostics 排序。
  - `Invoke-TcLintProject`(MCP `LintProject`):磁碟上的 `.plcproj`,不需要 IDE / runtime。
  - 規則:PROJECT-COMPILE-001/002/003、PROJECT-GUID-001、PROJECT-KIND-001、PROJECT-NAME-001、LINT-PARSE-*、LINT-COVERAGE-*。
  - 新錯誤碼:`LINT_FAILED`、`LINT_PARSE_FAILED`、`LINT_INCOMPLETE`、`LINT_PROFILE_INVALID`、`LINT_INPUT_INVALID`、`LINT_ENGINE_ERROR`(沿用 `PLC_PROJECT_AMBIGUOUS` / `PLC_PROJECT_NOT_FOUND`)。
- **Phase 2:LintCandidate 與 SCAN 規則**
  - `Invoke-TcLintCandidate`(MCP `LintCandidate`):純文字,可選擇覆蓋到磁碟專案上。
  - suppression(註解,必含 rule ID 與理由)。
  - SCAN-FBCALL-001/002、SCAN-TIMER-001/002、FB 型別目錄。
  - IDE 已連線時的未存檔偵測(`LINT_SOURCE_STALE` / `LINT_SOURCE_UNVERIFIED`,真機驗證)。
- **Phase 3:CONTRACT 規則**:CONTRACT-ITF-001/002、CONTRACT-ENUM-001/002、CONTRACT-DUT-001、baseline 讀取、`New-TcLintBaseline`、`GetLintRule`。
- **Phase 4:POLICY 與後續規則**:profile 的 POLICY 引擎、內建 `robust-solution` profile、`research/rule-candidates.md` 排名前段的規則(PROJECT-TASK-001、ST-LLM-001、SCAN-SM-001…)。

不改既有 tool 的參數與回傳格式。lint 不呼叫 Build、WritePouCode 或任何 runtime tool,也不觸發 lifecycle block。

## Capabilities

### New Capabilities
- `semantic-lint`:LintCandidate / LintProject 的輸入、fail-closed 結果語意、coverage、規則 metadata、suppression、profile、baseline、diagnostics 格式與排序、MVP 規則。

### Modified Capabilities
(`openspec/specs/` 目前沒有已發布的 spec,沒有要修改的。)

## Impact

- **程式碼**:`src/TwinCATAutomation/Private/Lint/`(C#)、`Public/Invoke-TcLintProject.ps1`、`Public/Invoke-TcLintCandidate.ps1`、之後的 `New-TcLintBaseline`、`Get-TcLintRule`;`Private/ConvertTo-TcAdsErrorCode.ps1` 的 hint。
- **MCP / adapters**:`Invoke-TwinCATAutomation.ps1` `$operationMap`、`mcp-server/scripts/Export-ToolSchema.ps1`、`tools.json`、`Update-GeneratedDocs.ps1` 產生的計數與 adapters、`mcp-server/test/catalog.test.js`。
- **文件**:`docs/troubleshooting.md`(新錯誤碼各一節)、`adapters/claude-code/SKILL.md`(工作流:LintCandidate → WritePouCode → BuildProject → LintProject)、`docs/known-limitations.md`(parser 未支援的語法、非 ST 不分析)。
- **測試**:`tests/Unit/lint-*.ps1`(fixture、契約、deterministic、seeded、效能)、`tests/Integration/lint-*.ps1`(真實專案檔,不需要 runtime)。
- **相容性**:純新增;不改既有 cmdlet。
