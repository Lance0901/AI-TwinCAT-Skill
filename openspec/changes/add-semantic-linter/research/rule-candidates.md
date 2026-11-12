# 候選規則清單與排序(#252)

結論:MVP 之後最值得做的是 **PROJECT-TASK-001(PROGRAM 沒掛到任何 task)**、**SCAN-SM-001(狀態被賦值卻沒有 CASE 分支)**、**ST-LLM-001(C 語言式語法幻覺)** 與 **SCAN-MC-001(MC FB 條件呼叫 / Execute 不歸零)**;TE1200 已涵蓋的除以零、陣列越界、未使用變數、CASE 無 ELSE 不重做(除非 owner 確認客戶多半只有 Light 版)。

## 1. 評分方式

- **價值**(1–5):部署前抓到的 bug 對機台的影響 × LLM / 人常犯的頻率。編譯器本來就會擋的,價值上限 3(只省一次 Build 來回)。
- **誤報風險**(低 / 中 / 高):依 prototype 實測或演算法性質判斷;沒實測的標「推估」。
- **成本**(S / M / L):S = 只需 token / 宣告;M = 需要跨物件或區塊結構;L = 需要控制流 / 資料流。
- **排序分數** = 價值 ÷ 誤報係數(低 1、中 2、高 4)÷ 成本係數(S 1、M 2、L 4),只用來排序,不是精確量測。

欄位「編譯器?」:yes = TwinCAT 編譯器會報錯(價值只在寫入前先擋);no;unknown = 未驗證。「TE1200」:對應 SA 規則(見 `te1200-rules.md`;Light 版只有 SA0004/0006/0027/0028/0033/0167/0175)。

## 2. 候選規則(MVP 8 項以外)

| 排名 | ID | 規則 | 來源 | 價值 | 誤報 | 成本 | 分數 | 編譯器? | TE1200 |
|---|---|---|---|---|---|---|---|---|---|
| 1 | PROJECT-TASK-001 | PROGRAM 沒有被任何 task(`.TcTTO` 的 PouCall)呼叫,也沒有被其他 POU 呼叫 → 永遠不執行 | LLM 常見(`AddPou` 後忘了 `LinkProgramToTask`);docs troubleshooting「AddPlcTask / PLCopen」 | 5 | 低(推估) | M | 1.25 | no | 無 |
| 2 | ST-LLM-001 | C 語言式語法:`==` `!=` `&&` `||` `++` `+=` `ELSE IF`(會多吃一個 END_IF)、`x = 5;` 當賦值 | issue「LLM hallucination」 | 3 | 低 | S | 3.0(上限受編譯器限制) | 多數 yes(`x = 5;` unknown) | 無 |
| 3 | SCAN-SM-001 | 狀態變數(CASE selector)被賦值成某個值,但 CASE 沒有該值的分支 → 機台卡死在未處理狀態 | issue「State Machine 缺回復路徑」;Robust Solution PKML 狀態表 | 5 | 低(推估;enum 型最準,INT 型要常數) | M | 1.25 | no | SA0076 只查 enum 成員缺 CASE,不看賦值 |
| 4 | SCAN-MC-001 | Tc2_MC2 FB(MC_Power、MC_MoveAbsolute…)只在 IF/CASE 內呼叫,或 `Execute` 設 TRUE 之後全程式沒有設 FALSE | Tc2_MC2 FB 需要持續呼叫直到 Done/Error(InfoSys Tc2_MC2 一般規則頁,本輪未取得連結 → **未驗證**);vault「PackML Service FB…Aborting 不停軸」 | 5 | 中(狀態機在單一狀態呼叫 MC FB 是常見寫法) | M | 0.63 | no | 無 |
| 5 | SCAN-TIMER-004 | Timer `IN` 是常數 TRUE / FALSE、或 `IN` 與 `PT` 都缺 | seeded S18 漏抓 | 3 | 低 | S(需簡單常數判斷) | 3.0 | no | 無 |
| 6 | PROJECT-TASK-002 | `.TcTTO` 在 `.plcproj` 但 `.tsproj` 沒有該 task;task cycle time 不是 base time 整數倍;priority 超出範圍 | docs known-limitations「AddPlcTask」(XAE 離線照收、無警告) | 4 | 低 | M | 1.0 | no | 無 |
| 7 | POLICY-RETVAL-001 | 指定 Method 的回傳值未使用(例:`RequestCommand`) | vault「PackML Service FB 吃掉 Abort」、Robust Solution PKML-008 / RES-013 | 4 | 低(只看清單內名稱) | S | 4.0 | no | SA0009(全部回傳值,需 full 授權) |
| 8 | POLICY-CALL-001 | 指定 FB / Method 每 scan 必須無條件呼叫一次(`M_UpdateService`、`M_UpdateModule`) | Robust Solution PKML-014、ARCH-003;vault「Interlock 函式庫」(`Execute()` 每 cycle) | 4 | 中(同 SCAN-TIMER) | M(重用 SCAN-TIMER 引擎) | 1.0 | no | 無 |
| 9 | ST-OOP-001 | `VAR PROTECTED` / `VAR PRIVATE`、ABSTRACT method 有本體、Method 名稱撞運算子(`Add`) | vault「TwinCAT 3 OOP 語法陷阱」#1 #2 #4 | 2 | 低 | S | 2.0 | yes | 無 |
| 10 | CONTRACT-SYM-001 | 引用專案與 library 目錄都沒有的型別 / FB / Method(LLM 編造 API) | issue「LLM 產生不存在的型別、Method」 | 3 | 高(library 目錄不完整就誤報) | M | 0.19 | yes | 無 |
| 11 | PROJECT-LIB-001 | 用了某 library 的 FB / 函式但 `.plcproj` 沒有該 library reference | vault「OOP 語法陷阱」#9(`LREAL_TO_FMTSTR`) | 3 | 中 | M | 0.38 | yes | 無 |
| 12 | SAFETY-DIV-001 | 除數是變數且同一陳述式路徑上沒有 `<> 0` 檢查;除以常數 0 | seeded S16 | 4 | 中 | L | 0.5 | 常數 0:unknown | SA0040(full) |
| 13 | SAFETY-ARR-001 | 常數 index 超出宣告範圍 | seeded S17 | 3 | 低 | S | 3.0 | unknown | SA0172(full) |
| 14 | SCAN-SM-002 | 等待類狀態(只等外部訊號才離開)沒有 timeout 分支 | issue「State Machine 缺 Timeout」 | 4 | 高 | L | 0.13 | no | 無 |
| 15 | SCAN-EDGE-001 | 同一 R_TRIG instance 在不同 task / 不同 POU 呼叫 | 推估 | 3 | 中 | M | 0.38 | no | SA0105 部分 |
| 16 | PROJECT-LIB-002 | library reference 是 `*` / newest(未凍結) | docs known-limitations「frozen」 | 2 | 中(專案策略) | S | 1.0 | no | 無 |
| 17 | SCAN-TIMER-003 | 同一 timer 每 scan 呼叫多次 | prototype(語料唯一 1 筆是誤報) | 3 | 高(需 RETURN 控制流) | L | 0.19 | no | SA0105(需 attribute) |

不做(TE1200 已涵蓋,或價值低):SA0033 未使用變數(我們的 SCAN-FBCALL-002 只當 info)、SA0075 CASE 無 ELSE、SA0004 輸出多處寫入、SA0006 / SA0103 多 task 存取、SA0039 / SA0145 指標 / REFERENCE 未檢查、SA0160 遞迴、魔術數字(TE1200 沒有,但誤報高、價值低)。

**SAFETY-DIV-001 / SAFETY-ARR-001 的去留取決於客戶授權**:若客戶多半只有免費的 Light 版(只有 7 條規則,不含 SA0040 / SA0172),這兩條的價值上升。→ owner 決定(design.md Open Questions)。

## 3. Robust Solution 規格(`twincat-reviewer` / `review-rules\robust-solution.md`)對照

這套規則幾乎全部綁定框架基底類別(`FB_ServiceBase`、`FB_ModuleBase`、`FB_BaseUnit`、`FB_PackMLBase`),只能放在 `robust-solution` profile,且只在偵測到繼承鏈時啟用,否則誤報高。

| 類別 | 可機械檢查(宣告 / token 就夠) | 需要語意 / 控制流 | 無法機械檢查 |
|---|---|---|---|
| NAM(命名) | NAM-001 檔名 = 物件名、002 一檔一物件、003 前綴、004 後綴、005、006、010 `M_` / `_`、012 enum `qualified_only` | NAM-008 `H_` 只給 protected hook、009 衍生不得與 FINAL 同名、013 已發布 enum 不得重編號(= CONTRACT-ENUM + baseline) | NAM-014 |
| OOP | 001/002/005/008 EXTENDS 基底、003 Adapter 用 `__QUERYINTERFACE`、004 Service 不得持有 `AXIS_REF` / `MC_*` / `%I %Q`、006/009 介面欄位、012、013 | 007、010、011 | — |
| PKML | 001 不得直接寫 `PackMLOut.eStateCurrent`、005 不得自建 first-scan、007 hook 內無 WHILE / REPEAT、008 `RequestCommand` 回傳值、010、011、012 CompletionBehavior、015 | 003、004、006、009、013、014 每 scan 一次 `M_UpdateService`、016、017 | — |
| RES | RES-013 回傳值不得忽略(部分) | 001–012 幾乎全部 | — |
| ARCH | 003、013、014、015、017(部分) | 001、002、004–012、016、018、020 | — |
| CMT | 002(近似)、003、004 不得比對 Message 字串 | — | 001 |

建議 Phase 4 先做「宣告 / token 就夠」那一欄(約 30 條),每條都是精確名稱比對,confidence high;語意欄留給 `twincat-reviewer` agent 人工 / LLM 審核,不進 linter。

## 4. 來源

- issue #252 本文(LLM 常見錯誤清單)。
- `te1200-rules.md`(TE1200 手冊 2.11.1,InfoSys + Beckhoff 官方 PDF)。
- `C:\Users\aka09\.claude\agents\twincat-reviewer.md` → `C:\Users\aka09\.claude\review-rules\robust-solution.md`(使用者私有規格,未進 repo)。
- 知識庫(唯讀):`wiki\TwinCAT 3 OOP 語法陷阱.md`、`wiki\PackML Service FB 吃掉 Abort 與 Aborting 不停軸就釋放 Resource.md`、`wiki\Interlock 函式庫.md`。
- repo:`docs/troubleshooting.md`(CheckAllObjects 與 Build 差異、PLCopen / Compile entry)、`docs/known-limitations.md`(AddPlcTask、library frozen)。
- prototype 實測:`corpus-feasibility.md`。
