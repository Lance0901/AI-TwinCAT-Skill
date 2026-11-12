## Why

TcAuto 能 Build、能跑 CheckAllObjects,但 coding agent 寫出來的 PLC 程式常常 Build 成功卻在機台上出事:Timer / R_TRIG 只在 IF 裡呼叫、FB instance 宣告了卻沒呼叫、Interface 簽章不一致、`.plcproj` 漏了 Compile entry、公開 DUT / Enum 被改了 layout。這些問題編譯器不報;客戶只有 TE1200 Light(7 條規則),Full 版的檢查也沒有;而且要等寫進 XAE、Build 完才看得到。另外,agent 直接改磁碟上的 `.TcPOU` / `.plcproj` 時,手寫 XML 很容易弄壞檔案(CDATA、GUID、Compile entry),XAE 遇到時的行為大多未實測。#252 要在 TcAuto 內加一個 deterministic 的 Semantic Linter,**在寫入 XAE 之前與 Activate / Download 之前**把高信心問題擋下。

這個 change 是設計階段:可行性已用 throwaway prototype 在兩個真實專案(4024 / 4026)上實測(`research/corpus-feasibility.md`):宣告區 242/242、ST 實作 176/176 解析成功;seeded bug 18 個中範圍內 15/15 命中;同時量到 SCAN 類規則第一版誤報 68/71,所以 SCAN 類只能當 warning。

## What Changes

依 owner 決定(#252 留言「Owner 決定(Lance,2026-11-13)」)分期:先做 Build 抓不到、會讓機台行為出錯的規則;AI 直接改磁碟檔造成的專案損毀留在 Phase 1a;相容性契約(CONTRACT-*)最後。每期一個可獨立 review / merge 的 PR(tasks.md),規則定義見 `rule-catalog.md`。

- **Phase 0(本 PR)**:設計、規格、規則目錄、research(prototype、語料量測、TE1200 對照、ST 語法清單、XAE 實際 XML 結構、錯誤分類初版)。不改產品程式。
- **Phase 1a:引擎 + 契約 + AI 改檔問題整類**
  - C# 5 引擎(`Add-Type` 延遲編譯,Constrained Language Mode → `LINT_ENGINE_UNAVAILABLE`);不認得的合法語法降級為 notAnalyzed,不判 parse fail。
  - `Invoke-TcLintProject`(MCP `LintProject`,磁碟,不需要 IDE / runtime)。
  - 契約:verdict / coverage / `unresolved[]` / `requiresDisposition`;rule metadata 含 `machineImpact`、`compilerCatches`、TE1200 版別。
  - PROJECT-XML / KIND / NAME / GUID / SUB / LINEIDS / COMPILE / LIB / TSPROJ / ENC 規則,以 XAE 實際產生的檔案為依據;XAE 行為未實測的先 `blockable: pending`。
  - IDE 實測(不需 runtime):XAE 遇到每種損毀的行為、TE1200 Light 能否經 `BuildProject` 取得。
- **Phase 1b:最確定的機台行為規則**:SCAN-TEMPFB-001(Timer 宣告在 METHOD / FUNCTION VAR)、PROJECT-TASK-001 / 002(PROGRAM 沒掛 task / 每 cycle 跑兩次);SKILL.md / CLAUDE.md 的磁碟改檔工作流加上 `LintProject`。
- **Phase 2:LintCandidate + 迴圈 / 陣列 / 除法 + Timer 細分**:`Invoke-TcLintCandidate`、suppression、SCAN-LOOP / FOR / ARR(blocking)、SAFETY-ARR / DIV、SCAN-FBCALL、SCAN-TIMER-001 / 002 / 004 / 005、stale 偵測(真機)、SKILL.md 處置規定。
- **Phase 3:狀態機 / Motion / 記憶體 / 數值 + 驗證**:SCAN-SM / MC / REF / FBVAL / OUT / FLOAT / INTDIV;錯誤清單凍結、LLM 語料盲標、mutation testing、holdout;EnableConfig 附 `data.lint` 摘要(不擋)。
- **Phase 4:契約 + POLICY + blocking gate**:CONTRACT-ITF / ENUM / DUT + baseline、`GetLintRule`、TE1200 SARIF、POLICY / `robust-solution` / POLICY-INTERLOCK(不取代 TwinSAFE)、`-LintGate` blocking 模式。

不改既有 tool 的參數與回傳格式(EnableConfig 只新增 `data.lint`)。lint 不呼叫 Build、WritePouCode 或任何 runtime tool,也不觸發 lifecycle block。

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
