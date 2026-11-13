# Runtime / IDE 語意實測(tasks 2.10,#252)

- 日期:2026-11-13(實測)
- 環境:Windows 11 Home 10.0.26200;TwinCAT XAE 3.1.4026.22(Remote Manager 3.1.4026.22);host VS2022 Community(`VisualStudio.DTE.17.0`,本次自己啟動的 pid 25580);本機 UmRT `UmRT_Default`(`TcSystemServiceUm.exe` 3.1.0.2649,AmsNetId 由工具回報 `199.5.42.250.1.1`);solution platform `Release|TwinCAT OS (x64)`;registered tcauto(master runtime,未換 runtime)。
- 專案:`C:\Temp\lint-rt\axis`(`C:\Temp\Verify-4026-axis` 的副本)。新增 8 個物件放在 `LintRT\` 資料夾(直接寫 .TcPOU / .TcDUT + `.plcproj`,IDE 開啟前完成),`Main` 實作開頭呼叫 `PRG_LintRT(); PRG_LintForBy0(); PRG_LintExc();`。
- Task:`PlcTask` 2 ms(`_TaskInfo[1].CycleTime` 讀回 20000 × 100 ns)、priority 20;第 3 項另以 `AddPlcTask` 加 `LintTask2` 10 ms、priority 25(`_TaskInfo[2].CycleTime` 讀回 100000)。
- 「標 InfoSys」= 本次以 WebFetch 打開並引用的頁面;「查不到」= 打開的頁面沒寫。下面所有 runtime 觀察都是「實測 2026-11-13,XAE 4026.22 / VS2022,本機 UmRT(TwinCAT OS x64)」。
- 例外類案例(7~9)全部放在 `PRG_LintExc` 的 `CASE nCase OF`,`nCase` 預設 0(不執行);每個案例前重新 `EnableConfig Force`(單獨 Activate),用 `WriteVariable PRG_LintExc.nCase` 觸發一次。

## 總表

| # | 項目 | InfoSys 出處 | 實測結論 | 影響規則 |
|---|---|---|---|---|
| 1 | STRUCT 成員是 FB instance(`TON`) | Structure 頁只寫 "combines several variables with any data type"([2529481355](https://infosys.beckhoff.com/content/1033/tc3_plc_intro/2529481355.html)),沒有明文提 FB | **合法**:Build 0 error 0 warning;runtime 正常計時(1 s 後 `Q = TRUE`、`ET = T#1s`) | SCAN-TEMPFB-001(STRUCT 成員的有狀態判斷)、TypeCatalog `struct-type` |
| 2 | 只呼叫 Action,不呼叫本體 | Action 頁只有呼叫語法,沒寫本體會不會跑([2530340747](https://infosys.beckhoff.com/content/1033/tc3_plc_intro/2530340747.html)) | **本體不執行**:PROGRAM 與 FB 都一樣(本體計數器 0,Action 計數器每 cycle +1) | PROJECT-TASK-001 variant `action-only` |
| 3 | 同一 PROGRAM 掛兩個 task | 查不到;只有 FB 的 "Access from several task contexts to one function block is not allowed."([12050040971](https://infosys.beckhoff.com/content/1033/tc3_plc_intro/12050040971.html)) | **Build / Activate 都成功、沒有任何 warning**;兩個 task 各自每 cycle 執行一次本體(共用同一份變數) | PROJECT-TASK-002 |
| 4 | `TON` 在 `PT = T#0S` | TON 頁沒寫 PT = 0([74406539](https://infosys.beckhoff.com/content/1033/tcplclib_tc2_standard/74406539.html)) | `IN` 上升緣**當個 cycle** `Q = TRUE`、`ET = T#0ms`;`IN` 落下當個 cycle `Q = FALSE` → 延遲完全失效、`Q` 跟著 `IN` 走 | SCAN-TIMER-004(PT 未設定) |
| 5 | `TON` 中途 N 個 cycle 沒被呼叫 | TON 頁沒寫([74406539](https://infosys.beckhoff.com/content/1033/tcplclib_tc2_standard/74406539.html)) | **照牆上時間算**:跳過 1500 cycle(`TIME()` 差 3002 ms)後第一次呼叫,`ET` 從 498 ms 直接跳到 3500 ms;PT 2 s 的 timer 第一次呼叫就 `Q = TRUE` | SCAN-TIMER-005(與 001) |
| 6 | `FOR i := 0 TO 10 BY 0` | FOR 頁只寫 "The step size <increment> can have any integer value."([2528280971](https://infosys.beckhoff.com/content/1033/tc3_plc_intro/2528280971.html)) | **編譯器不擋、沒有 warning**;runtime `i` 停在 0、迴圈不會自己結束(靠自加的 1000 次上限 EXIT 才出來) | SCAN-FOR-001 variant `by-zero` |
| 7a | DINT `/ 變數(= 0)` | "In TwinCAT, division by zero always leads to an exception and the corresponding task is stopped."([DIV 2528875403](https://infosys.beckhoff.com/content/1033/tc3_plc_intro/2528875403.html)) | **PLC exception**:Error List `Exception Code: 0xc0000094, Integer divide by zero`;port 851 = Stop、port 10000 = **Exception**(adsState 19);整個 PLC(兩個 task)都停 | SAFETY-DIV-001 |
| 7b | DINT `MOD 變數(= 0)` | 查不到(DIV 頁那句只講 division) | **不 exception**,PLC 照跑,結果 = **0** | SAFETY-DIV-001(MOD 要另列) |
| 7c | REAL `/ 變數(= 0.0)` | Task tab:Floating point exception "Thus an exception is generated for division by zero and "Invalid Operations""([5210416139](https://infosys.beckhoff.com/content/1033/tc3_system/5210416139.html)) | **PLC exception**:`Exception Code: 0xc000008e, FPU zero divide`;狀態同 7a(本專案 task 用預設設定) | SAFETY-DIV-001 |
| 7d | LREAL `/ 變數(= 0.0)` | 同 7c | **NOT RUN**(7c 的恢復過程留下 lifecycle block,見第 7 節) | — |
| 8 | 未初始化 `REFERENCE TO INT` 讀取、`POINTER TO INT := 0` 解參照讀取 | "TwinCAT initializes references (with 0)."([2529458827](https://infosys.beckhoff.com/content/1033/tc3_plc_intro/2529458827.html));`__ISVALIDREF`([2529165707](https://infosys.beckhoff.com/content/1033/tc3_plc_intro/2529165707.html)) | **編譯器不擋、沒有 warning**(已 Build 下載);runtime 讀取 **NOT RUN**(同上) | SCAN-REF-001 |
| 9 | 陣列越界(無 CheckBounds) | "The check is only performed with a variable array index. A consistently faulty array index results in a compiler error."([2530356875](https://infosys.beckhoff.com/content/1033/tc3_plc_intro/2530356875.html)) | 常數索引越界**讀取**也被擋:`C0049`(上界 11、下界 0 都是);變數索引的讀 / 寫 **NOT RUN**(同上) | SAFETY-ARR-001、SCAN-ARR-001 |
| 10 | 無窮迴圈 / cycle overrun(不測) | TwinCAT real-time([6828869003](https://infosys.beckhoff.com/content/1033/tc3_grundlagen/6828869003.html))、Task tab([5210416139](https://infosys.beckhoff.com/content/1033/tc3_system/5210416139.html)) | 只查文件,見第 10 節 | SCAN-LOOP-001 |

## 1. STRUCT 成員是 FB instance

```
TYPE ST_LintTmrHolder :
STRUCT
    tmr   : TON;
    nPad  : INT;
END_STRUCT
END_TYPE

// PRG_LintRT
VAR  bRun1 : BOOL;  stHold : ST_LintTmrHolder;  bQ1 : BOOL;  tEt1 : TIME;  END_VAR
stHold.tmr(IN := bRun1, PT := T#1S);
bQ1  := stHold.tmr.Q;
tEt1 := stHold.tmr.ET;
```

- 步驟:`BuildProject` → `EnableConfig Force` → `ReadVariable` → `WriteVariable PRG_LintRT.bRun1 TRUE` → `ReadVariable` 兩次。
- Build:成功,0 error;24 個 warning 全是專案原有的(C0139 / C0195 / C0196 / C0197 / C0297 / C0371),`LintRT\` 底下的物件沒有任何 warning。
- Runtime:寫入前 `bQ1 = FALSE`、`tEt1 = T#0ms`;寫入後約 0.37 s 讀到 `tEt1 = T#352ms`、`bQ1 = FALSE`;約 10 s 後 `bQ1 = TRUE`、`tEt1 = T#1s`。
- 結論:FB instance 可以當 STRUCT 成員,經由 STRUCT 路徑呼叫時行為和一般 instance 相同。

## 2. 只呼叫 Action

```
PROGRAM PRG_LintActOnly           // 本體:nBody := nBody + 1;
ACTION ActA                       //       nAct  := nAct  + 1;
FUNCTION_BLOCK FB_LintAct         // 本體:nBody := nBody + 1;
ACTION ActF                       //       nAct  := nAct  + 1;

// PRG_LintRT(每 cycle,由 Main 呼叫)
PRG_LintActOnly.ActA();
fbAct.ActF();                     // fbAct : FB_LintAct;
```

`PRG_LintActOnly()` 與 `fbAct()` 在整個專案都沒被呼叫,`PRG_LintActOnly` 也沒掛 task。

- Build:成功,沒有 warning(沒有「PROGRAM 未被呼叫」之類的提示)。
- Runtime(兩次讀取,間隔約 14 s):

| 變數 | 第 1 次 | 第 2 次 |
|---|---|---|
| `PRG_LintActOnly.nBody` | 0 | 0 |
| `PRG_LintActOnly.nAct` | 5485 | 12360 |
| `PRG_LintRT.fbAct.nBody` | 0 | 0 |
| `PRG_LintRT.fbAct.nAct` | 5498 | 12373 |

- 結論:呼叫 `<program>.<action>()` / `<instance>.<action>()` **只執行 Action**,PROGRAM 與 FB 的本體都不會被執行。

## 3. 同一個 PROGRAM 掛到兩個 task

```
PROGRAM PRG_LintTwoTask
VAR  nCount : DINT;  fbTaskIdx : GETCURTASKINDEX;  aCnt : ARRAY[0..10] OF DINT;  nLastIdx : BYTE;  END_VAR
nCount := nCount + 1;
fbTaskIdx();
nLastIdx := fbTaskIdx.index;
IF fbTaskIdx.index <= 10 THEN aCnt[fbTaskIdx.index] := aCnt[fbTaskIdx.index] + 1; END_IF
```

- 步驟:`PlcTask.TcTTO` 直接加第二個 `<PouCall>PRG_LintTwoTask`(IDE 開啟前);`AddPlcTask LintTask2 10000 µs priority 25` → `LinkProgramToTask PRG_LintTwoTask → LintTask2`(兩者 readback `verified: true`)→ Build → `EnableConfig Force`。
- Build:成功,沒有 warning;Activate 9 個 step 全部 ok,`dialogsSeen = []`,Error List 也沒有相關 message。
- Runtime(`_TaskInfo[1]` = `AxisInterface_PlcTask`、`_TaskInfo[2]` = `AxisInterface_LintTask2`;兩次讀取的差值):

| | 第 1 次 | 第 2 次 | 差值 |
|---|---|---|---|
| `aCnt[1]`(PlcTask 執行次數) | 5523 | 12388 | 6865 |
| `_TaskInfo[1].CycleCount` | 5768 | 12612 | 6844 |
| `aCnt[2]`(LintTask2 執行次數) | 1106 | 2478 | 1372 |
| `_TaskInfo[2].CycleCount` | 1151 | 2519 | 1368 |
| `nCount` | 6606 | 14856 | 8250 ≈ 6865 + 1372 |

(差值有幾個 cycle 的誤差,因為同一次 `ReadVariable` 的各個值不是同一 cycle 取樣。)

- 結論:同一個 PROGRAM 可以掛兩個 task,編譯器與 Activate 都**不警告**;每個 task 每 cycle 各執行一次本體,而且**共用同一份 PROGRAM 變數**(`nCount` 是兩者的和)→ 本體裡的 timer / trigger 會被兩個 task 以不同節拍呼叫,且有跨 task 的並行存取。

## 4. `TON` 在 `PT = T#0S`

```
IF bIn4 THEN
    ton4(IN := TRUE, PT := T#0S);
    IF nCyc4 = 0 THEN bQ4_c0 := ton4.Q; tEt4_c0 := ton4.ET;
    ELSIF nCyc4 = 1 THEN bQ4_c1 := ton4.Q; tEt4_c1 := ton4.ET; END_IF
    nCyc4 := nCyc4 + 1;
ELSE
    ton4(IN := FALSE, PT := T#0S);
    IF nCyc4 > 0 THEN bQ4_off := ton4.Q; END_IF
    nCyc4 := 0;
END_IF
```

(`tEt4_c0` / `tEt4_c1` 初值 `T#99MS`、`bQ4_off` 初值 TRUE,用來確認真的被寫過。)

- 步驟:`WriteVariable bIn4 TRUE` → 讀;`WriteVariable bIn4 FALSE` → 讀。
- Runtime:`bQ4_c0 = TRUE`、`tEt4_c0 = T#0ms`(上升緣當個 cycle);`bQ4_c1 = TRUE`、`tEt4_c1 = T#0ms`;IN 落下後 `bQ4_off = FALSE`。
- 結論:`PT = T#0S` 時 `Q` 在 `IN` 上升緣的**同一個 cycle** 就是 TRUE,`ET` 一直是 0;落下當個 cycle 變 FALSE。等於沒有延遲。

## 5. `TON` 的 `IN` 保持 TRUE,中間 N 個 cycle 沒被呼叫

```
IF bRun5 THEN
    nCyc5 := nCyc5 + 1;
    IF nCyc5 <= 250 OR nCyc5 > 1750 THEN          // 2 ms task:先呼叫 0.5 s,跳過 1500 cycle(3 s),再呼叫
        ton5a(IN := TRUE, PT := T#10S);
        ton5b(IN := TRUE, PT := T#2S);
        IF nCyc5 = 250 THEN  tEtA_before := ton5a.ET; tEtB_before := ton5b.ET; bQB_before := ton5b.Q; tNow_before := TIME();
        ELSIF nCyc5 = 1751 THEN tEtA_after := ton5a.ET; tEtB_after := ton5b.ET; bQB_after := ton5b.Q; tNow_after := TIME();
        ELSIF nCyc5 = 1760 THEN tEtA_after10 := ton5a.ET; bDone5 := TRUE; END_IF
    END_IF
ELSE
    nCyc5 := 0;  ton5a(IN := FALSE, PT := T#10S);  ton5b(IN := FALSE, PT := T#2S);
END_IF
```

- 步驟:`WriteVariable bRun5 TRUE` → 等 `bDone5` → 讀。
- Runtime:

| 變數 | 值 |
|---|---|
| `tEtA_before` / `tEtB_before`(第 250 cycle) | `T#498ms` / `T#498ms` |
| `bQB_before` | FALSE |
| `tNow_after − tNow_before`(`TIME()`) | 3002 ms |
| `tEtA_after`(第 1751 cycle,跳過後第一次呼叫) | **`T#3s500ms`** |
| `tEtB_after` / `bQB_after` | `T#2s` / **TRUE** |
| `tEtA_after10`(第 1760 cycle) | `T#3s518ms` |

- 結論:`TON` 以呼叫當下的系統時間減去上升緣時記下的起點計算 `ET`,**沒被呼叫的時間也算進去**;跳過的時間超過剩餘 PT 時,重新呼叫的**第一個 cycle `Q` 就是 TRUE**。所以「離開狀態不呼叫 timer、`IN` 仍是 TRUE、之後再進來」時,timer 不會重新計時,而會立刻(或很快)逾時。

## 6. `FOR i := 0 TO 10 BY 0`

```
IF bRun THEN
    bRun := FALSE;  nRuns := nRuns + 1;  nIter := 0;  bGuardHit := FALSE;
    FOR i6 := 0 TO 10 BY 0 DO
        nIter := nIter + 1;
        IF nIter >= 1000 THEN bGuardHit := TRUE; EXIT; END_IF
    END_FOR
END_IF
```

- Build:成功,**沒有 error 也沒有 warning**(該 POU 沒有任何 Error List 列)。
- Runtime(`WriteVariable PRG_LintForBy0.bRun TRUE` 後讀):`nRuns = 1`、`nIter = 1000`、`bGuardHit = TRUE`、`i6 = 0`。
- 結論:`BY 0` 編譯器不擋;計數器不會前進,迴圈本身永遠不會結束 —— 沒有守衛時就是同一 cycle 內的無窮迴圈(後果見第 10 節)。

## 7. 除以零(變數除數)

```
VAR  nNum : DINT := 100;  nDiv : DINT := 0;  nRes : DINT := -1;
     fNum : REAL := 1.0;  fNegNum : REAL := -1.0;  fZero : REAL := 0.0;  fRes, fResNeg, fRes00 : REAL := -1.0;
     lNum : LREAL := 1.0; lZero : LREAL := 0.0;  lRes : LREAL := -1.0;  END_VAR
IF nCase <> 0 THEN
    nLastCase := nCase;  bAfter := FALSE;
    CASE nCase OF
        71: nRes := nNum / nDiv;
        72: nRes := nNum MOD nDiv;
        73: fRes := fNum / fZero;  fResNeg := fNegNum / fZero;  fRes00 := fZero / fZero;
        74: lRes := lNum / lZero;
    END_CASE
    nCase := 0;  bAfter := TRUE;  nExecCount := nExecCount + 1;
END_IF
```

`bAfter` / `nExecCount` / `nCase := 0` 在 CASE 之後:沒被更新就表示那個 cycle 停在 CASE 裡。

| 案例 | Error List(runtime 列原文) | port 851 | port 10000 | 變數 |
|---|---|---|---|---|
| 71 DINT `/` | `'Port_851' (851): Exception (Exception Code: 0xc0000094, Integer divide by zero) in PLC Application AxisInterface Instance, Task PlcTask (...), Area 1, Offset 0xbda4` | Stop | **Exception**(adsState 19) | `nRes = -1`、`bAfter = FALSE`、`nExecCount = 0`、`nCase = 71`;`LintTask2` 的 CycleCount 也停止增加 |
| 72 DINT `MOD` | 無 | Run | Run | `nRes = 0`、`bAfter = TRUE`、`nExecCount = 1` |
| 73 REAL `/` | `'Port_851' (851): Exception (Exception Code: 0xc000008e, FPU zero divide) in PLC Application AxisInterface Instance, Task PlcTask (...), Area 1, Offset 0xbde0` | Stop | **Exception**(adsState 19) | `fRes = fResNeg = fRes00 = -1`(第一個除法就停)、`bAfter = FALSE` |
| 74 LREAL `/` | NOT RUN | | | |

- 沒有任何 IDE modal dialog(`GetIdeModalDialog` → `dialog: null`);訊息只出現在 Error List。
- 本專案的 task 沒改過 Floating point exception 設定;InfoSys Task tab:"Enables Floating Point Exception. Thus an exception is generated for division by zero and "Invalid Operations""([5210416139](https://infosys.beckhoff.com/content/1033/tc3_system/5210416139.html))。所以 REAL / LREAL 除以 0 的結果**取決於 task 的這個設定**;關掉時是否得到 INF / NaN 本次沒測。

### 7.1 Exception 之後怎麼恢復(實測)

watcher(`tests/Integration/Watch-Runtime.ps1`,每秒一筆)時間線,案例 71:

| 時間 | port 10000 |
|---|---|
| 13:47:48 | Run |
| 13:47:49 ~ 13:48:07 | Exception(停在這裡,不會自己恢復) |
| 13:48:07.5 | 送 `SetPlcState Run`(之前先 `WriteVariable nCase 0`,寫入成功) |
| 13:48:08 | unreachable(port 851 回 0x6) |
| 13:48:09 起 | **Config** |

- 案例 71:`SetPlcState Run` 回 `success: true`(851 讀回 Run,26 ms),但 Error List 同時出現 `Shutting down TwinCAT Server` → `TwinCAT System Start: AdsState: 15` → `TwinCAT system start completed. AdsState: >15<`:**TwinCAT 自己整個重啟到 Config**,port 851 消失。UmRT 行程 pid 沒變(不是 crash)。要再 `EnableConfig Force` 才回到 Run(實測成功)。
- 案例 73:先 `SetPlcState Reset` → `success`,PLC 變數重新初始化(`nCase` 讀回 0),但 port 10000 **仍是 Exception**;接著 `SetPlcState Run` → `PLC_RUN_TIMEOUT`(851 回 0x6,系統同樣自己掉回 Config)→ tcauto 記下 lifecycle block(`Set-TcPlcState` / `PLC_RUN_TIMEOUT`,2026-11-13 13:50:02)。
- 結論:PLC exception 會讓**整個 TwinCAT system 進入 Exception 狀態**(不只 PLC Stop);PLC 層的 Reset / Run 都救不回來,實際需要的是**重新 Activate(`EnableConfig Force`)**。這個 block 不是 UmRT crash,依規則停止,7d、8、9 的 runtime 部分因此 NOT RUN。
- 工具面的發現(另開 issue):系統在 Exception 時 `SetPlcState Run` 的 `success: true` 只是 851 的瞬間讀值,系統隨即重啟到 Config。

## 8. 未初始化 REFERENCE / 0 指標的讀取

```
VAR  refI : REFERENCE TO INT;  bRefValid : BOOL := TRUE;  nRefVal : INT := -1;
     pI : POINTER TO INT := 0;  nPtrVal : INT := -1;  END_VAR
bRefValid := __ISVALIDREF(refI);          // 每 cycle
81: nRefVal := refI;
82: nPtrVal := pI^;
```

- Build:成功,**這兩行沒有任何 error / warning**(與第 1~6 項同一次 Build、已下載執行)。
- Runtime:`bRefValid` 本次沒有讀取(第 7.1 節的 block 之前沒排到),81 / 82 **NOT RUN**。
- InfoSys:"TwinCAT initializes references (with 0)." / "A reference can be invalid (0)."([2529458827](https://infosys.beckhoff.com/content/1033/tc3_plc_intro/2529458827.html));`__ISVALIDREF` "The check is thus comparable with a check for 'unequal to 0' in the case of a pointer variable."([2529165707](https://infosys.beckhoff.com/content/1033/tc3_plc_intro/2529165707.html))。讀取無效 reference 的後果頁面沒寫。
- 結論:編譯器不擋(compilerCatches: measured no);runtime 後果仍未驗證。

## 9. 陣列越界(專案沒有 CheckBounds)

```
TYPE ST_LintArrSentinel :
STRUCT  arr : ARRAY[1..10] OF INT;  nSentinel : INT := 777;  END_STRUCT
END_TYPE
VAR  stArr : ST_LintArrSentinel := (arr := [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);  nIdx : DINT := 11;  nArrVal : INT := -1;  END_VAR
91: nArrVal := stArr.arr[nIdx];          // 變數索引讀
92: stArr.arr[nIdx] := 12345;            // 只超出 1,觀察 nSentinel
```

- 常數索引(Activate 之後、IDE 未重開,用 `WritePouCode` 暫加兩行再 `BuildProject`,之後還原並重新 Build 成功):

```
93: nArrVal := stArr.arr[11];
94: nArrVal := stArr.arr[0];
```

  → `BUILD_FAILED`:`C0049 The constant index '11' is not within the range from '1' to '10'`、`C0049 The constant index '0' is not within the range from '1' to '10'`。和 `st-syntax-measured.md` 第 3 節的寫入案例一樣,**讀取**也擋。
- 變數索引 91 / 92:Build 成功、沒有 warning;runtime **NOT RUN**。
- InfoSys:CheckBounds "The check is only performed with a variable array index. A consistently faulty array index results in a compiler error."([2530356875](https://infosys.beckhoff.com/content/1033/tc3_plc_intro/2530356875.html))。沒加 CheckBounds 時的後果頁面沒寫。

## 10. 無窮迴圈 / cycle overrun(只查文件,不測)

- "If the defined cycle time of a task is exceeded, processing of the "old" cycle continues in the next cycle. In addition, the task exceed counter is incremented." / "...the current processing task is completed, and processing of the next task does not commence until the next possible scheduled cycle start. This means that several cycles may be lost."([TwinCAT real-time 6828869003](https://infosys.beckhoff.com/content/1033/tc3_grundlagen/6828869003.html))
- Task tab:"Watchdog Cycles: Specifies how often the cycle time may be exceeded before a warning is triggered."、"Warning by exceeding: The TwinCAT system issues a message if the set task cycle time is exceeded."([5210416139](https://infosys.beckhoff.com/content/1033/tc3_system/5210416139.html))
- 文件沒寫「單一 cycle 永遠不結束」(第 6 項沒有守衛的情況)時 runtime 會不會強制中止;依上面兩句,cycle 不結束就一直是同一個 cycle,後續 cycle 全部遺失,只會累加 exceed counter / 發警告。是否會停 PLC **查不到、未實測**(會卡死 UmRT,依任務指示不測)。

## 附帶事件:Activate 時 UmRT crash(#21)

- 第一次 `EnableConfig Force`(13:45:28,系統原本 Run)在 set-config 步驟回 `RUNTIME_CRASHED`:`TcSystemServiceUm` pid 48236 消失。事件 1000:faulting module `TcOsSys.dll` 3.1.0.1、exception `0xc0000005`、offset `0x0000000000589534`;dump `%LOCALAPPDATA%\CrashDumps\TcSystemServiceUm.exe.48236.dmp`;watcher 同時記到 `bootdata-empty`(308 → 0 byte)。
- 依 `docs/agent-brief-realmachine.md`「UmRT 復原」重啟(新 pid 58916),讀回 Config,`ClearLifecycleBlock`(Reason 記錄上述簽名)後重新 `EnableConfig Force` 成功。和測試碼無關(crash 發生在新程式下載之前)。

## 收尾狀態

- IDE:`DisconnectIde Quit=true` 關掉自己啟動的 pid 25580;使用者的 VS2022(pid 12448)沒碰。
- UmRT:pid 58916 存活,port 10000 = Config;**留有一個 lifecycle block**(`Set-TcPlcState` `PLC_RUN_TIMEOUT` 13:50:02),需要 owner 同意後 `ClearLifecycleBlock` 再 `EnableConfig Force`。
- PLC 專案副本:例外碼仍在 `PRG_LintExc`,但全部由 `nCase`(預設 0)關閉;最後一次 Build 成功(0 error)。

## rule-catalog 與 st-syntax-inventory 要跟著改的地方

(本 PR 不改這兩個檔;PR #284 正在改 rule-catalog。)

| 檔案 / 位置 | 現在的字樣 | 建議改成 |
|---|---|---|
| rule-catalog SCAN-TEMPFB-001 偵測說明「STRUCT 成員裡的 FB → warning(「FB 可當 STRUCT 成員」InfoSys Structure 頁沒有明文,未驗證)」 | 未驗證 | 「FB 可當 STRUCT 成員:實測 2026-11-13(本檔第 1 節),Build 成功、runtime 正常計時」;是否因此把 STRUCT 成員的 timer 升為 blocking 由 owner 決定 |
| rule-catalog PROJECT-TASK-001 `action-only`「本體不執行 ... → 推論」 | 推論 | 「實測 2026-11-13(第 2 節):PROGRAM 與 FB 只呼叫 Action 時本體不執行」 |
| rule-catalog PROJECT-TASK-002「同一 PROGRAM 掛兩個 task 時 TwinCAT 的行為**查不到,未驗證**」、「timer / trigger 每 cycle 被評估兩次 ... 推論」 | 未驗證 / 推論 | 「實測(第 3 節):Build / Activate 不警告;每個 task 各執行一次本體,共用同一份變數」;`impactBasis` 可改 `measured`(並行存取的後果仍是推論) |
| rule-catalog SCAN-TIMER-004「PT = 0 的行為頁面沒寫,**未驗證**」 | 未驗證 | 「實測(第 4 節):上升緣當個 cycle `Q = TRUE`、`ET = 0`,延遲失效」 |
| rule-catalog SCAN-TIMER-005「ET 從舊值繼續,Q 可能立刻成立 ...(推論 ... **未驗證**)」 | 未驗證 | 「實測(第 5 節):ET 依牆上時間計算,未被呼叫的時間照算;跳過時間 ≥ 剩餘 PT 時重新呼叫的第一個 cycle `Q = TRUE`」→ 「Q 可能立刻成立」改為確定 |
| rule-catalog SCAN-FOR-001「`BY 0` 的行為未驗證」、variant `by-zero` pending | 未驗證 / pending | 「實測(第 6 節):編譯器不擋、無 warning;runtime 計數器不前進,無守衛時為同一 cycle 內的無窮迴圈」→ `by-zero` 可定為 blocking |
| rule-catalog SAFETY-DIV-001 machineImpact「crash(推論,runtime 結果未驗證)」 | 推論 | 整數 `/`、REAL `/`(task 預設 FPU exception):「實測(第 7 節):PLC exception,TwinCAT system 進 Exception,要重新 Activate 才能恢復」;InfoSys DIV 頁 "division by zero always leads to an exception and the corresponding task is stopped." |
| rule-catalog SAFETY-DIV-001 compilerCatches「**`MOD 0`:no**」 | 只寫編譯期 | 補 runtime:「`MOD` 變數 0 不 exception,結果 0(實測第 7 節)」→ MOD 0 的 machineImpact 應改為「靜默得到 0」(邏輯錯,不停機),與 `/` 分開成 variant |
| rule-catalog SCAN-REF-001「page fault、PLC 停機(推論 ... 未驗證)」 | 推論 | compilerCatches 改「measured no(第 8 節)」;runtime 後果仍「未驗證」(NOT RUN) |
| rule-catalog SCAN-ARR-001 / SAFETY-ARR-001「蓋到相鄰變數是推論,未驗證」 | 推論 | 常數索引讀寫都被 C0049 擋(實測);變數索引越界後果仍「未驗證」(NOT RUN) |
| rule-catalog SCAN-LOOP-001「cycle overrun / watchdog(推論 ... InfoSys 出處待補)」 | 出處待補 | 補第 10 節兩個連結;「同一 cycle 不結束時是否停 PLC」仍未驗證 |
| st-syntax-inventory 第 2 部分 2b | 未驗證 | 實測(本檔第 4 節) |
| st-syntax-inventory 第 2 部分 2c | 未驗證(需 UmRT 實測) | 實測(本檔第 5 節):牆上時間 |
| st-syntax-inventory 第 2 部分 6a | 未驗證(只確認有對應 exception code) | 整數 `/`:`0xc0000094 Integer divide by zero`;REAL `/`:`0xc000008e FPU zero divide`;`MOD`:結果 0、不 exception(實測第 7 節);出處補 DIV 頁 2528875403 與 Task tab 5210416139 |
| st-syntax-inventory 第 2 部分 6b | 無 CheckBounds 時的後果未驗證 | 常數索引讀取也 C0049(實測第 9 節);變數索引仍未驗證 |
| st-syntax-inventory 第 2 部分 7b | 解參照後果未驗證 | 編譯器不擋(實測第 8 節);runtime 後果仍未驗證 |

還沒做完、要另排一次真機的:7d(LREAL)、8(REFERENCE / POINTER 讀取、`__ISVALIDREF` 讀值)、9(變數索引讀、只超出 1 的寫入與哨兵)。程式碼已在副本裡,只要 `EnableConfig Force` 後依序 `WriteVariable PRG_LintExc.nCase` 74 / 81 / 82 / 91 / 92(91 前把 `nIdx` 設 11 或 0),每個 exception 案例之後用 `EnableConfig Force` 恢復,**不要**用 `SetPlcState Run`。
