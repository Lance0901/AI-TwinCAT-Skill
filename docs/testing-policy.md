# 測試政策

結論:CI 守「契約」與「fail-closed / lifecycle 邏輯」;mock 測試只證明「我們有處理」,不證明「真的會這樣發生」,後者只能真機驗。

## 1. CI 的目的

CI 守兩類,兩類都留在 CI:

| 類別 | 守什麼 | 例子 |
|---|---|---|
| 契約 | JSON 結構、error code、hint、cmdlet 參數 | `{success, data}` / `{success:false, error:{message, code, hint}}` 形狀;每個 hint key 在 `docs/troubleshooting.md` 有一節;SKILL.md 簽章表與 cmdlet 參數一致 |
| fail-closed / lifecycle 邏輯 | 不誤報成功 | 讀回狀態不符時回 `SYSTEM_STATE_MISMATCH`;`LIFECYCLE_BLOCKED` 擋住後續呼叫 |

## 2. regression 測試門檻

- 只有 bug 改變對外行為(回傳內容、error code)或涉及 fail-closed 時才加 regression 測試。純內部重構、訊息措辭、文件修正不加。
- 加進既有相關測試檔,不新開檔:每支 `tests/Unit` 腳本是獨立 `powershell.exe`,固定成本 2~3 s。

## 3. mock 可信度

- 新 mock 在檔頭註明依據:實測日期 + 環境(TwinCAT 版本、IDE、UmRT / CX),或 infosys.beckhoff.com 連結(同 `CODING_STANDARDS.md` 第 4 節)。
- 沒有依據的標 `[推論]`。
- 既有推論類測試不刪,標記即可;之後真機剛好測到該路徑,就補上依據。
- 推論類 mock 測試通過,不能當作行為正確的證據。

## 4. 時間預算

- CI 單一 job ≤ 10 分鐘。
- 超過時先量各區段耗時(CI log 時間戳),再決定處理方式;不直接刪測試。

## 5. 只靠真機的項目

| 類別 | 例子 |
|---|---|
| IDE / runtime 的實際行為 | XAE 彈窗、UmRT 當機、Activate 後的狀態轉換 |
| 與時間相關的行為 | timeout 長度、COM busy 時機 |

- 這類 mock 測試只驗「我們有處理」,不驗「真的會這樣發生」。
- 改動碰到這些路徑,必須用 tcauto MCP 真機驗證;規則見 `docs/agent-brief-realmachine.md`。

## 現況(2026-11-12)

- `tests/Unit` 共 65 支:契約 27 / 邏輯 23 / regression 10 / 安裝 1 / 文件 1 / 其他 3;`npm test` 402 支。
- unit 已平行執行(#240 / PR #243)。有牆鐘時間斷言的腳本放在 `scripts/check.ps1` 的序列組;新增有牆鐘時間斷言的測試要加進序列組。
- CI 原為單一 job 約 12 分鐘;#253 把 `npm test` 拆成與 `check` 平行的獨立 job(`check.ps1 -SkipNpmTest`),牆鐘時間約等於較慢的那個 job。後續:#241(測試加速)、#242(pre-push 只跑相關 unit)。
- 本機 hook 與 CI 分工:pre-commit 跑 `scripts/check.ps1 -Fast`;CI 跑完整 `-Strict`。hook 可被繞過,CI 是唯一保證關卡。
