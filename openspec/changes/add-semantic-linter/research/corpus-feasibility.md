# 語料可行性實測(#252 設計階段)

結論:兩個真實專案(4024 / 4026 存檔)的宣告區 242/242、ST 實作 176/176 都能被 throwaway prototype 完整 tokenize 與做區塊結構分析;PROJECT-* 規則在 seeded 測試 6/6 命中且語料零誤報,可以當 blocking;SCAN-* 規則第一版在語料上誤報率很高(71 筆中 68 筆誤報),經三個精化(END_IF 後無分號、明確 FB 型別目錄、IF/ELSE 全分支覆蓋+Action 呼叫圖)後剩 4 筆:2 筆真的未使用(info)、1 筆真模式但屬可接受寫法(warning)、1 筆誤報(SCAN-TIMER-003,因此不放 MVP)。SCAN 規則只能當 warning。

- 實測日期:2026-11-13
- 環境:Windows 11 Home 10.0.26200,Windows PowerShell 5.1(`powershell.exe -NoProfile`),.NET Framework csc(C# 5),Node v22.22.0。**沒有連 IDE、沒有碰 runtime**,只讀檔。
- prototype:`research/prototype/`(`StLint.cs` tokenizer + 宣告 parser + 陳述式結構掃描、`Analyzer.cs` 規則、`Run-Proto.ps1`、`Bench.ps1`、`bench-node.js`、`Seed-Bugs.ps1`)。throwaway,不進產品。
- 原始輸出:`research/results/axis.txt`、`bfh.txt`、`bfh-seeded.txt`。

## 1. 語料

| | axis | bfh |
|---|---|---|
| 來源(唯讀複製) | `C:\Temp\Verify-4026-axis` | `C:\Temp\Verify-4024-bfh` |
| 複製到 | `C:\Temp\lint-corpus\axis` | `C:\Temp\lint-corpus\bfh` |
| 分析的 `.plcproj` | `AxisInterface_Type01_Library\AxisInterface\AxisInterface.plcproj` | `LangMang260618\PLC1\PLC1.plcproj` |
| `<Compile>` 項目 | 75 | 103 |
| 物件 ProductVersion | 3.1.4026.0 / .17 / .18 | 3.1.4024.13 / .16 |
| .TcPOU / .TcDUT / .TcGVL / .TcTTO | 20 / 49 / 3 / 1 | 45 / 39 / 6 / 1 |
| Method / Action 子物件 | 77 / 28 | 3 / 4 |
| Property / Transition / Interface(.TcIO) | 0 / 0 / 0 | 0 / 0 / 0 |
| 實作語言 | ST 124、**CFC 1**(`FB_AxisControl.A90_Cyclic`) | ST 52 |

複製時排除 `_Boot`、`_CompileInfo`、`.vs`、`_Libraries`、`_Deployment`。兩個來源都有 `_bak_files_*` 目錄(只含 `.plcproj` 與 `Main.TcPOU` 的備份),不在 `<Compile>` 清單內,沒有納入分析。

**語料缺口**(影響結論的可信度):沒有 Interface、Property、Transition、SFC、LD/FBD、PLCopen XML、多 PLC solution、`.TcIO`。Interface 規則只靠 seeded 樣本驗證。

## 2. 解析成功率

| 項目 | axis | bfh | 合計 |
|---|---|---|---|
| 宣告區(POU/Method/Action/DUT/GVL)解析成功 | 149/149 | 93/93 | **242/242** |
| ST 實作 tokenize 成功 | 124/124 | 52/52 | **176/176** |
| ST 實作區塊結構(IF/CASE/FOR/WHILE/REPEAT 配對)成功 | 124/124 | 52/52 | **176/176** |
| 非 ST 實作(未分析,回報 coverage) | 1(CFC) | 0 | 1 |

失敗樣本:語料本身 0 筆。seeded 的兩個語法破壞(缺 `END_IF`、未結束的 `(*`)都被抓到並回報為「該物件未分析」(見第 5 節)。

prototype 撞到、已在 prototype 修掉的 parser 坑(產品 parser 要有 fixture):

1. `END_IF` / `END_CASE` 後面**不接分號**直接寫下一句(語料常見)。第一版把 `END_IF` 之後當成非陳述式起點,導致後面的 FB 呼叫沒被認出來,造成 SCAN-FBCALL 大量誤報。
2. 一個 Action 的 `<Implementation>` 底下有多個 `<ST>` 元素(bfh `FB_MachineCtrl`,其中一個是空的)。prototype 只取最後一個;產品要定義清楚(全部串接或回報異常),未驗證 XAE 的語意。
3. 中文註解、UTF-8 BOM、Tab 混用都沒問題。

## 3. 效能(同一台機器,單次量測,未做多次統計)

| 項目 | 數值 |
|---|---|
| ST 文字總量(兩專案 Declaration+Implementation) | 754,182 字元、17,902 行、404 段 |
| C# tokenizer(Add-Type 編譯後) | 17 ms / 全語料 |
| 純 PowerShell 5.1 tokenizer(簡化版,規則更少) | 332 ms / 全語料(約 C# 的 20 倍) |
| Node v22 tokenizer(同簡化版) | 20 ms / 全語料 |
| `Add-Type` 編譯兩個 .cs(約 800 行) | 718–951 ms,每個 PowerShell session 一次 |
| 單專案完整分析(XML 載入+解析+規則)cold / warm | axis 129–160 / 69–78 ms;bfh 95–136 / 52–61 ms |
| seeded bfh 第一次分析 | 1557 ms(剛寫完檔,原因未查;warm 32 ms) |
| GC heap 增量(含 XmlDocument) | axis 約 42 MB、bfh 約 4 MB |
| 同輸入跑兩次輸出 byte 相同 | 3/3 專案 `deterministic=True` |

推論(未驗證):純 PowerShell 版本加上宣告 parser 與規則後會再慢數倍;以 20 倍估計,10 萬行等級的專案會到數秒~十數秒。C# 版在同規模預估 < 1 s。

## 4. 規則在真實語料上的結果(人工逐筆判讀)

### 4.1 PROJECT-COMPILE / GUID / KIND

| 規則 | 語料 finding | 判讀 |
|---|---|---|
| PROJECT-COMPILE-001 Compile 指向不存在的檔 | bfh 1 筆(`VISUs\VISUs\ImagePool.TcIPO`) | **誤報,但原因是語料複製**:我的複製 filter 漏了 `.TcIPO`。來源有這個檔,補複製後消失。啟示:規則必須檢查**所有** `<Compile>` 項目的存在性,不只 PLC object 副檔名;語料複製腳本要用「`.plcproj` 列了什麼就複製什麼」 |
| PROJECT-COMPILE-002 重複 | 0 | — |
| PROJECT-COMPILE-003 磁碟上有檔但沒列入 Compile | 0(`_bak_files_*` 在 `.plcproj` 目錄外,不算) | 若備份目錄放在 `.plcproj` 目錄底下就會報;這正是要報的情況(不會被編譯),屬 warning |
| PROJECT-GUID-001 / PROJECT-KIND-001 | 0 | — |

### 4.2 SCAN-FBCALL-001(FB instance 被讀取但沒有呼叫點)

| 版本 | finding | 真問題 | 誤報 | 誤報原因 |
|---|---|---|---|---|
| v1 | 56(axis 37、bfh 19) | 0 | 56 | (a) `END_IF` 後無分號的呼叫沒被認出(bfh 19 筆全部是這個);(b) 把 `MC_` 開頭的型別一律當 FB,實際上 `MC_Direction`、`MC_CAM_ID`、`MC_CAM_REF`、`MC_StartMode`、`MC_HomingParameter`、`MC_Ref_Signal_Ref` 等是 ENUM / STRUCT |
| v2(修 a;型別改用明確的 library FB 清單,清單外的型別當「未知」不評估) | **0** | 0 | 0 | — |

結論:這條規則的誤報幾乎全部來自**型別知識**。沒有 library 型別資訊時不能用名字猜 FB;產品版要有「已知 FB 型別目錄」(專案內 FUNCTION_BLOCK + 版本化的 library 目錄),不在目錄裡的型別回報 coverage「型別未知,未評估」,不能靜默跳過也不能猜。

### 4.3 SCAN-FBCALL-002(FB instance 完全沒被引用)

2 筆(axis `MC_MoveAbsolute_Continue.fbExecute_Rtrig : R_TRIG`、`Main.fbWheelThreadCal`):**都是真的未使用**(死宣告)。價值低:TE1200 SA0033 Unused variables 就是這類(FB instance 是否涵蓋,手冊沒寫,未驗證);只做 info。

### 4.4 SCAN-TIMER-001(Timer/Trigger 只在 IF/CASE 內呼叫)

| 版本 | finding | 真問題(模式成立) | 誤報 |
|---|---|---|---|
| v1 | 3 | 1 | 2 |
| v2(IF…ELSE 每個分支都有呼叫 = 等同每個 scan 呼叫) | **1** | 1 | 0 |

- 誤報代表案例(v1):bfh `FB_BrakeControl` — `tonRelease` / `tonApply` 在 `IF powerOn AND enableMotion THEN … ELSE … END_IF` 的兩個分支都有呼叫(分別帶 `IN := TRUE/FALSE`)。每個 scan 恰好呼叫一次,timer 狀態正確更新。v2 加入「頂層 IF 有 ELSE 且每個分支都呼叫」判斷後消失。
- 真模式代表案例:axis `TestCam` — `R_14Eng(CLK := b14Engage)` 只在 `IF testFB = 14 THEN` 內。切換到別的 testFB 再切回來時,R_TRIG 保留舊的 CLK 記憶,可能漏抓或誤抓一次邊緣。這是測試程式的模式選擇器,作者大概是有意的 → **符合 warning、不該 blocking** 的定位。

### 4.5 SCAN-TIMER-002(只在 Method/Action 內呼叫)

v1 7 筆 info:全部是 Action 在 POU 本體被**無條件**呼叫(`A_ActionTrigger();`、`A30_HMI_Action();`)。v2 追一層 Action 呼叫圖後 0 筆。Method 內的呼叫沒追(需要知道誰、在哪個 scan 呼叫 Method),維持 info/low。

### 4.6 SCAN-TIMER-003(同一 timer instance 多次呼叫)

v1 3 筆、v2 1 筆,**全部誤報**:`FB_ThicknessAverage` 的 `rt` 在 `IF reset THEN … rt(CLK := FALSE); RETURN; END_IF` 與後面各呼叫一次,是正確的重置寫法(有 `RETURN`,同一 scan 只會執行其中一個)。要正確判斷需要控制流(RETURN / EXIT)分析 → **不放 MVP**;TE1200 SA0105 有同類規則(需 attribute)。

### 4.7 誤報率摘要

| 規則 | 語料 finding(v2) | 誤報 | 可當 blocking? |
|---|---|---|---|
| PROJECT-COMPILE-001/002 | 0 | 0 | 可以(確定性的檔案事實) |
| PROJECT-COMPILE-003 | 0 | 0 | 不行:不被編譯可能是刻意的(只當 warning) |
| PROJECT-GUID-001 / KIND-001 | 0 | 0 | 可以 |
| SCAN-FBCALL-001 | 0(v1 56 筆全誤報) | 0 | 不行(型別知識不完整時誤報爆量) |
| SCAN-FBCALL-002 | 2 | 0 | 不行(info;TE1200 已涵蓋類似規則) |
| SCAN-TIMER-001 | 1 | 0(1 筆為真模式但屬可接受寫法) | 不行(warning) |
| SCAN-TIMER-003 | 1 | 1 | 不做 |

樣本只有兩個專案、規則 v2 是在同一份語料上調出來的(有 overfit 風險)。「v2 零誤報」不能外推,要用第三個以上專案驗證(見 design.md 開放問題)。

## 5. Seeded-bug 測試

`Seed-Bugs.ps1` 把 bfh 語料再複製到 `C:\Temp\lint-corpus-seeded\bfh`,植入 18 個已知問題(每個 seed 都檢查只替換一處),用原始 bfh 當 CONTRACT baseline。

| Seed | 植入內容 | 期望規則 | 結果 |
|---|---|---|---|
| S01 | `FB_LevelControl.TcPOU` 的 `<Compile>` 改成 `<None>`(檔還在) | PROJECT-COMPILE-003 | 命中 |
| S02 | `<Compile Include="POUs\FB_Ghost.TcPOU">`(檔不存在) | PROJECT-COMPILE-001 | 命中 |
| S03 | `ST_EL1889.TcDUT` 重複 `<Compile>` | PROJECT-COMPILE-002 | 命中 |
| S04 | `FB_Winder` 的 POU Id 改成和 `FB_BrakeControl` 相同 | PROJECT-GUID-001 | 命中 |
| S05 | `.TcDUT` 檔裡放 `<POU>` | PROJECT-KIND-001 | 命中 |
| S06 | `tonWebBreak(...)` 包進 `IF state = 3 THEN … END_IF` | SCAN-TIMER-001 | 命中 |
| S07 | `rZero(CLK := …)` 包進 `CASE … OF 1: … END_CASE` | SCAN-TIMER-001 | 命中 |
| S08 | 刪掉 `tonAutoStart(...)` 呼叫,`.Q` / `.ET` 讀取保留 | SCAN-FBCALL-001 | 命中 |
| S09 | 新增 `tonUnusedSeed : TON;` 不使用 | SCAN-FBCALL-002 | 命中 |
| S10 | `I_Brake.M_Release(bForce : BOOL)`,FB 實作成 `(nForce : INT)` | CONTRACT-ITF-002 | 命中 |
| S11 | `I_Brake.M_Apply` 沒實作 | CONTRACT-ITF-001 | 命中 |
| S12 | `E_MachineMode.Manual := 0` 改 `1`(`Auto` 隱含值跟著變) | CONTRACT-ENUM-002 | 命中(2 筆:Manual、Auto) |
| S13 | `ST_EL1889` 的 `DI1`、`DI2` 對調 | CONTRACT-DUT-001 | 命中 |
| S14 | 刪掉一個 `END_IF` | LINT-PARSE-002(該物件未分析) | 命中 |
| S15 | 宣告區留下未結束的 `(*` | LINT-PARSE-001 | 命中 |
| S16 | `k := k / 0;` | (不在範圍;TE1200 SA0040) | 漏抓(預期) |
| S17 | `buf[51]`,`buf : ARRAY[1..50]` | (不在範圍;TE1200 SA0172) | 漏抓(預期) |
| S18 | `tonWebBreak(IN := TRUE OR …)`(timer 永不重置) | (需常數折疊;候選規則 SCAN-TIMER-004) | 漏抓(預期) |

**15/15 範圍內命中,3/3 範圍外漏抓**,無多餘 finding(seeded 輸出除了上表沒有其他 finding)。

限制:seed 是我自己設計、自己寫規則去抓,命中率天然偏高;S10/S11 的 `.TcIO` 與 Method XML 是我自己寫的,不是 XAE 產生的(語料沒有 Interface),所以這兩筆命中是循環論證,只證明比對邏輯可行,不證明能讀真實的 Interface 檔(design.md review S15,tasks 1.8);這個數字只證明「規則有實作到」,不證明對未知 bug 的召回率。S08 被抓到也依賴 v2 的型別目錄(`TON` 在清單內)。

## 6. 對設計的影響

1. **解析可行**:兩個專案 100% 解析成功,ST tokenizer + 宣告 parser + 區塊結構掃描足以支撐 MVP 規則,不需要完整 expression AST。
2. **架構選 C#(Add-Type)**:C# tokenizer 比純 PowerShell 快約 20 倍,和 Node 同級;編譯成本每個 session 約 0.7–1 s。見 design.md D1。
3. **型別知識是 SCAN 規則的誤報主因**:必須有明確的 FB 型別目錄;未知型別 = coverage 缺口,要回報,不能猜。
4. **SCAN 規則只能 warning**;PROJECT 結構規則與有 baseline 的 CONTRACT 規則可以 blocking。
5. **fail-closed 的單位是物件**:一個物件解析失敗時,其他物件照跑,但整體 `passed` 必須是 false(見 design.md D4)。
6. **多 `<ST>` 元素、END_IF 不接分號** 這類真實語料的格式要寫進 parser fixture。
