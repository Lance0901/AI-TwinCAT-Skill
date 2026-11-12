# ST 語法合法性實測(tasks 1a.10)

- 日期:2026-11-13(實測)
- 環境:Windows 11 Home 10.0.26200;TwinCAT XAE 3.1.4026.22(Remote Manager 3.1.4026.22);host VS2022 Community 17.14(`VisualStudio.DTE.17.0`);專案 `C:\Temp\lint-ide\axis`(`C:\Temp\Verify-4026-axis` 的副本);solution platform `Release|TwinCAT OS (x64)`;registered tcauto(master runtime)。4024 未測。
- 方法:每個語法項目一個最小 FB(`FB_Dxx`),由 `PRG_LintSyntax` 宣告並呼叫,`Main` 開頭呼叫 `PRG_LintSyntax`(確保被編譯);直接寫 .TcPOU + `.plcproj` 後 `ResetSolution` → `BuildProject` → `GetBuildErrors`。結果以 Error List 中該 FB 的 error 列為準(「接受」= 該 FB 0 error)。
- 植入腳本 `C:\Temp\lint-ide\tools\Lint-D.ps1`(不入 repo);下表「寫法」欄就是植入的原文。

## 1. 語法項目

| # | 項目 | 寫法(宣告 / 實作) | 結果 | Error List 原文(第一條) |
|---|---|---|---|---|
| D01 | `?=` assignment attempt | `itfA : I_LintItf; itfB : I_LintItf; fb : FB_LintTest;` / `itfA := fb; itfB ?= itfA;` | **拒絕** | `C0189 ';' expected instead of '?'`(Impl 第 2 行) |
| D02 | `**` 指數 | `fR : LREAL;` / `fR := 2.0 ** 3.0;` | **拒絕** | `C0189 ';' expected instead of '**'`、`C0009 Unexpected token '**' found` |
| D03 | `/* */` 註解 | `/* c-style comment */` + `x := 1;` | **拒絕** | `C0009 Unexpected token '/' found` |
| D04 | `E_Enum#Member` | `e : E_LintEnum := E_LintEnum#eRun;` / `e := E_LintEnum#eErr;` | **拒絕** | `C0032 Cannot convert type 'Unknown type: 'E_LintEnum#eRun'' to type 'E_LINTENUM'` |
| D05 | TIME literal 底線 | `t := T#1_000MS;` | 接受 | — |
| D06 | TIME literal 負號 | `t := T#-5S;` | **拒絕** | `C0189 ';' expected instead of 'T#'` |
| D07 | TIME literal 小數 | `t := T#1.5S;` | 接受 | — |
| D08 | `END_IF` 後省略分號 | `IF x = 0 THEN x := 1; END_IF` + 下一行 `x := 2;` | 接受 | — |
| D09 | `__TRY` / `__CATCH(exc)` / `__FINALLY` / `__ENDTRY` | `exc : __SYSTEM.ExceptionCode;` + 完整區塊 | 接受(64-bit,4026) | — |
| D10 | 條件 pragma(不成立的分支放非法 ST) | `{IF defined (LINT_UNDEFINED_SYMBOL)}` / `this is not valid ST at all` / `{ELSE}` / `x := 1;` / `{END_IF}` | **編譯器仍解析不成立的分支並報錯** | `C0189 ';' expected instead of 'is'`(第 2 行)等 10 條;另有 `C0139 The code 'THIS;' has no effect` 類 warning |
| D11 | `VAR_GENERIC CONSTANT` | — | **未測**:植入腳本沒寫出這個檔(`PRG_LintSyntax` 因此報 `C0077 Unknown type: 'FB_D11_VarGeneric'`),時間內未重跑 | — |
| D12 | `S=` / `R=` | `b S= c; b R= NOT c;` | 接受 | — |
| D13 | `REF=` | `fR : REFERENCE TO INT;` / `fR REF= n; fR := 5;` | 接受 | — |
| D14 | WSTRING `$` 4 位十六進位跳脫 | `w : WSTRING := "A$0042C";` / `w := "x$0041";` | 接受 | — |
| D15 | REAL literal 底線 | `fR := 1_000.5;` | 接受 | — |
| D16 | 非 ASCII 識別字 | `變數1 : INT;` | **拒絕** | `C0009 Unexpected token '變' found`(Decl 第 3 行) |
| D17 | 空敘述 | `x := 1;;` + `;` | 接受 | — |
| D18 | 陣列重複初始化 | `a : ARRAY[1..5] OF INT := [3(7), 2(0)];` | 接受 | — |
| D19 | subrange 型別 | `s : INT(0..100);` | **無法判定**:變數名 `s` 本身就被拒(見 D24) | `C0009 Unexpected token 's' found` |
| D20 | 巢狀區塊註解 | `(* outer (* inner *) still comment *)` | 接受 | — |
| D21 | 小寫 time literal | `t := t#1h2m3s4ms;` | 接受 | — |
| D22 | LTIME literal | `t : LTIME;` / `t := LTIME#1US;` | 接受 | — |
| D23 | 變數名 `r` | `r : INT;` / `r := 1;` | **拒絕** | `C0009 Unexpected token 'r' found`(Decl 第 3 行) |
| D24 | 變數名 `s` | `s : INT;` / `s := 1;` | **拒絕** | `C0009 Unexpected token 's' found`(Decl 第 3 行) |

D23 / D24 是測試中意外發現的:第一輪 D02 / D13 / D15 用了變數名 `r`,全部在宣告行報 `Unexpected token 'r'`;改名 `fR` 後三項都通過。InfoSys 沒找到「`R` / `S` 不能當識別字」的明文(推測與 `S=` / `R=` 運算子有關,未查證)。

「多個 `<ST>` 元素」:無法用 Build 測;XAE 自己存檔一律一個 `<ST>`(見 `xae-generated-xml.md`)。

## 2. Build 與可達性(PROJECT-TASK-001 的依據)

| 案例 | 寫法 | CheckAllObjects | BuildProject |
|---|---|---|---|
| 沒掛 task、沒被呼叫的 PROGRAM 有語法錯 | `PRG_Orphan`:`x := ;` | `C0007 Expression expected instead of ';'`(PRG_Orphan Impl 第 1 行) | **成功,0 errors**(`codeVerified` / `completeBuild` true),Error List 沒有 PRG_Orphan 的列 |
| 沒被引用的 FB 有型別錯 | `FB_OrphanErr`:`x : INT;` / `x := 'text';` | **沒有任何列** | 成功,沒有任何列 |

結論:**Build 只編譯被引用的物件**;語法錯只有 `CheckAllObjects` 抓得到,型別錯連 `CheckAllObjects` 也抓不到。另見 `xae-corrupt-file-behavior.md`:沒被引用的物件 XML 壞掉時 Build 也成功。

## 3. 編譯期常數錯誤(SAFETY-DIV-001 / SAFETY-ARR-001 的 compilerCatches)

物件都被 `PRG_LintConst` 呼叫。

| 案例 | 寫法 | 結果 |
|---|---|---|
| 整數除以常數 0 | `x := x / 0;` | **BUILD_FAILED**:`C0374 Division by zero` |
| 實數除以常數 0 | `fR := fR / 0.0;` | **BUILD_FAILED**:`C0374 Division by zero` |
| 常數 index 越界(上界) | `a : ARRAY[1..10] OF INT;` / `a[11] := 0;` | **BUILD_FAILED**:`C0049 The constant index '11' is not within the range from '1' to '10'` |
| 常數 index 越界(下界,0-based 習慣) | `a[0] := 0;` | **BUILD_FAILED**:`C0049 The constant index '0' is not within the range from '1' to '10'` |
| `MOD` 常數 0 | `x := x MOD 0;` | **沒有任何錯誤或警告** |

→ SAFETY-DIV-001 常數部分:`/ 0` 的 compilerCatches = `measured:2026-11-13 yes`(編譯器擋),**`MOD 0` = no**(編譯器不擋,linter 要抓);SAFETY-ARR-001 常數 index:compilerCatches = `measured:2026-11-13 yes`,與 InfoSys「A consistently faulty array index results in a compiler error」一致。
