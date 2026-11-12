# TwinCAT 3 ST 語法清單與行為出處(semantic linter parser 用)

- 整理日期:2026-11-13
- 來源:只用 infosys.beckhoff.com。每個 URL 都是本次以 WebFetch **實際打開成功**的頁面(除非標「未驗證」)。
- 「InfoSys 原文」欄的英文是頁面原句短引;沒有原句、只有語法列的就直接放語法。
- 「未驗證」= InfoSys 找不到、頁面沒寫、或頁面打不開。這些項目**不得**當成事實寫進規則,只能當 parser 的防禦性設計。
- 縮寫:`PI` = `https://infosys.beckhoff.com/content/1033/tc3_plc_intro/`(PLC 手冊 TC3 PLC intro 英文版)。表格裡寫 `PI/2528329355.html` 即 `https://infosys.beckhoff.com/content/1033/tc3_plc_intro/2528329355.html`。

parser 處理建議三選一:
- **支援**:語法完整解析,物件可分析。
- **安全略過**:不支援但合法 → 該物件記 `notAnalyzed`,絕不判 parse fail。
- **parse fail**:確定非法(InfoSys 明寫錯誤)才可用。

原則:合法程式不得判 parse fail;不認得但合法的構造一律「安全略過」。

---

## 0. 1a.10 實測更新(2026-11-13,XAE 4026.22 / VS2022)

原本標「未驗證」的語法已用最小 POU + `BuildProject` 實測,錯誤原文見 `../verification/st-syntax-measured.md`。

| 項目 | 結果 |
|---|---|
| `?=`、`**`、`/* */`、`E_Enum#Member`、`T#-5S`、非 ASCII 識別字、變數名 `r` / `s` | **編譯器拒絕** |
| `T#1_000MS`、`T#1.5S`、`t#1h2m3s4ms`、`LTIME#1US`、`END_IF` 後省略分號、`__TRY` 區塊(64-bit 4026)、`S=` / `R=` / `REF=`、WSTRING `$0041`、REAL `1_000.5`、`;;`、`[3(7), 2(0)]`、巢狀 `(* (* *) *)` | 接受 |
| 條件 pragma 不成立的分支 | **仍被解析**,放非法 ST 會報錯 |
| `VAR_GENERIC CONSTANT`、subrange `INT(0..100)` | 未判定(植入失敗 / 變數名衝突) |
| 除以常數 0 / 常數 index 越界 | Build 失敗(`C0374` / `C0049`);`MOD 0` 不報錯 |
| 沒被呼叫的 PROGRAM 有語法錯 | Build 成功,只有 `CheckAllObjects` 報 |

## 第 1 部分:語法清單

### 1.1 註解、字串、pragma

| 語法項目 | 範例 | InfoSys 連結 | 版本限制 | parser 建議 | 備註 |
|---|---|---|---|---|---|
| 單行註解 `//` | `x := 1; // note` | PI/2528329355.html | — | 支援 | "Starts with // and ends at the end of the line." |
| 區塊註解 `(* *)`,**可巢狀** | `(* a (* b *) c *)` | PI/2528329355.html | — | 支援(lexer 用深度計數) | "Additional (*.... *) comments can be contained within this comment." 頁面沒寫深度上限 → 不設上限 |
| `/* */` 註解 | `/* x */` | PLC 手冊未收錄。只有 NC I 的 ST 頁有:https://infosys.beckhoff.com/content/1033/tf5100_tc3_nc_i/4184579339.html | — | **未驗證(PLC)**;建議 lexer 認得 `/*...*/` 但遇到時整個物件記 notAnalyzed | NC I 頁寫 "may be nested up to a depth of 3",但那是 TF5100 NC I G-code interpreter 的 ST,**不能**推到 PLC ST。PLC ST 註解頁只列 `//` 與 `(* *)`。`/` 後接 `*` 在合法 PLC ST 幾乎不會出現(除法後接 `*` 不成立),故當註解吃掉風險低;**實測 2026-11-13:編譯器拒絕**(`../verification/st-syntax-measured.md`) |
| STRING literal `'...'` | `'Hello World!'` | PI/2529327243.html | — | 支援 | "A STRING constant is a string enclosed by single quotation marks."(Windows-1252) |
| `$` 跳脫 | `'$R$N'`, `'$27'`, `'$$'`, `'$''` | PI/2529327243.html | — | 支援 | "If a STRING constant contains a dollar sign ($), the following two characters are interpreted as hexadecimal code." 列表:`$L $N $P $R $T`(大小寫皆可)、`$$`、`$'`、`$<2 hex>`。lexer 規則:遇 `$` 一律多吃 1 個字元(`$'` 不可結束字串);吃 2 hex 的語意檢查不在 lexer 做 |
| WSTRING literal `"..."` | `"This is a WString."` | PI/2529437323.html | — | 支援 | "The character string is identified as WSTRING with double quotation marks."(UCS-2)。WSTRING 內 `$` 跳脫的形式(是否 4 hex)頁面**未寫 → 未驗證**;lexer 照 STRING 規則處理 `$"`、`$$` 即可;**實測 2026-11-13:`$0042` 4 位十六進位跳脫接受**(`../verification/st-syntax-measured.md`) |
| pragma 通則 `{ ... }` | `{attribute 'strict'}` | PI/2526889867.html | — | 支援(當 token,不進 AST 或掛在宣告上) | "Pragmas unknown to the compiler are read over like a comment."、"The instruction string of a pragma can also be multi-line."、"A pragma cannot be used within an expression."、"Case-sensitivity must be respected." → lexer:`{` 到對應 `}` 整段當 pragma token(要跳過其中的 `'...'`) |
| attribute pragma | `{attribute 'qualified_only'}`、`{attribute 'TcLinkTo' := '...'}` | PI/2529572491.html、PI/3107974923.html | — | 支援 | 無值形式 "{attribute 'attribute'}";有值形式見 TcLinkTo 頁 "{attribute 'TcLinkTo' := '<I/O point name>'}"。位置:POU/型別宣告前一行、VAR 區內變數前一行;Action/Transition 放實作區開頭(PI/2529567115.html) |
| 條件編譯 `{IF}` `{ELSIF}` `{ELSE}` `{END_IF}` | `{IF defined (Group1)} ... {ELSIF defined(Group2)} ... {ELSE} ... {END_IF}` | PI/2529795979.html | 宣告區內:**TC3.1 build 4024 起**才評估;"Conditional pragmas are supported in the PLC project, but not in libraries." | **安全略過**(物件內出現 `{IF` → notAnalyzed) | 運算子:`defined(...)`、`defined(variable:/type:/pou: ...)`、`hasvalue`、`hasattribute`、`hastype`,可配 NOT/AND/OR。linter 不知道 compile define,未啟用分支可能是不合法程式碼,若硬解析會誤判 parse fail |
| `{define}` / `{undefine}` | `{define MYDEF '1'}` | PI/2529795979.html | — | 支援(當 pragma token 忽略) | `{define <identifier>}` / `{define <identifier> '<value>'}` / `{undefine <identifier>}` |
| message pragma | `{info 'TODO'}`、`{warning 'x'}`、`{error 'x'}`、`{text 'x'}` | PI/2529561739.html | — | 支援(當 pragma token 忽略) | `{warning}` "only permitted for objects such as POUs, for instructions and for variables";宣告區範例後面帶 `;` |
| region pragma | `{region "Init"} ... {endregion}` | PI/3525631371.html | — | 支援(忽略) | 語法 `{region "description"} … {endregion}`;"Region pragmas can be nested.";可用於 ST 編輯器與宣告編輯器 |

### 1.2 敘述與例外處理

| 語法項目 | 範例 | InfoSys 連結 | 版本限制 | parser 建議 | 備註 |
|---|---|---|---|---|---|
| ST 指令總表 | IF / FOR / CASE / WHILE / REPEAT / RETURN / JMP / EXIT / CONTINUE / 註解 / FB 呼叫 | PI/2528270219.html | — | 支援 | 頁面清單即 parser 必須涵蓋的 statement 集合 |
| IF | `IF c THEN ... ELSIF c2 THEN ... ELSE ... END_IF;` | PI/2528275595.html | — | 支援 | 語法列寫 `END_IF;`,ELSIF `( )*`、ELSE `( )?` |
| `END_IF` 等後面的分號 | `END_IF` vs `END_IF;` | PI/2528275595.html(只寫有分號的形式) | — | 分號當可選 | 頁面語法都帶 `;`,**沒寫可省 → 未驗證**。保守:parser 接受有/無分號,也接受空敘述 `;;`,避免把合法程式判 fail;**實測 2026-11-13:省略分號接受**(`../verification/st-syntax-measured.md`) |
| FOR | `FOR i := 1 TO 10 BY 2 DO ... END_FOR;` | PI/2528280971.html | — | 支援 | "FOR <counter> := <start value> TO <end value> {BY <increment> } DO";BY 省略時步長 1 |
| CONTINUE(ExST) | `CONTINUE;` | PI/2528318603.html | — | 支援 | 用於 FOR / WHILE / REPEAT |
| JMP 與 label | `lblA: nX := nX + 1; ... JMP lblA;` | PI/2528307851.html | — | 支援(或安全略過) | `<label>: <instructions>` 與 `JMP <label>;`;label "a freely selectable, unique identifier, which you place at the beginning of a line"。parser 要能分辨 `ident :` 開頭的 label(ST 實作區內 `ident :` 不會是其他合法構造)。控制流分析若不想處理 JMP,可對含 JMP 的物件只做局部規則 |
| `__TRY` / `__CATCH(exc)` / `__FINALLY` / `__ENDTRY` | 見右 | PI/2529187211.html | **32-bit runtime:TC3.1 build 4024 起;64-bit runtime:build 4026 起** | 支援 | 語法 `__TRY ... __CATCH(exc) ... __FINALLY ... __ENDTRY`;exc 型別 `__SYSTEM.ExceptionCode`(PI/6753940235.html)。"If an exception occurs in a __CATCH or __FINALLY block, that exception is not caught." |

### 1.3 運算子與指派

| 語法項目 | 範例 | InfoSys 連結 | 版本限制 | parser 建議 | 備註 |
|---|---|---|---|---|---|
| 運算子優先序 | — | PI/2528237963.html | — | 支援 | 由強到弱:`( )` > 函式呼叫 > `EXPT` > 一元 `-`、`NOT` > `* / MOD` > `+ -` > `< > <= >=` > `= <>` > `AND`、`AND_THEN` > `XOR` > `OR`、`OR_ELSE`;"Operators with the same binding strength are processed from left to right." |
| `?=`(assignment attempt) | `itfB ?= itfA;` | **InfoSys 找不到**。指派頁 PI/2528243339.html 只列 `:=`、`=>`、`S=`、`R=`、assignment as expression、`REF=`;運算子總表 PI/2528853899.html 也沒有 | — | **未驗證** → lexer 認得 `?=` token,遇到的敘述/物件 **安全略過** | 不可判 parse fail(可能是新版或 CODESYS 衍生語法,手冊未收錄不代表編譯器不收);**實測 2026-11-13:4026.22 編譯器拒絕**(`../verification/st-syntax-measured.md`) |
| `S=` / `R=`(ExST) | `bOut S= bIn;` | PI/2528254091.html、PI/2528259467.html | — | 支援 | `<variable name> S= <operand name> ;`;同一行多個時 "all assignments refer to the operand at the end of the code line" |
| `REF=` | `refA REF= stA;` | PI/4978163979.html、PI/2529458827.html | — | 支援 | `<variable name> REF= <variable name>`;`value REF= refA` "leads to a compile error";`refInt REF= 0;` 合法 |
| `=>`(output 指派) | `fb(IN := x, Q => bQ, ET => );` | PI/3513625739.html | — | 支援 | `<output> => <variable>`;範例 `bFBCompOutput2 => ;` → **右側可空** |
| assignment as expression(ExST) | `a := b := c + 9;`、`IF b := (i = 1) THEN` | PI/2528264843.html | — | 支援 | "TwinCAT allows the use of assignments as expressions"。parser 的 expression 文法要允許 `:=` 出現在運算式內 |
| `**`(指數) | `x ** 2` | **InfoSys 未收錄**。指數只有 `EXPT(<base>,<exponent>)`(PI/2529122699.html,return "always LREAL") | — | **未驗證** → lexer 把 `**` 切成 `*` `*` 即會在 parse 失敗;建議改為認得 `**` token,遇到時物件 **安全略過** | 總表 PI/2528853899.html 明確沒有 `**`;**實測 2026-11-13:編譯器拒絕**(`../verification/st-syntax-measured.md`) |
| `AND_THEN` | `IF p <> 0 AND_THEN p^ = 99 THEN` | PI/2528923787.html | — | 支援 | "only allowed for programming in Structured Text";短路 |
| `OR_ELSE` | `b OR_ELSE fb.M()` | PI/2528929163.html | — | 支援 | "The OR_ELSE operator is only permitted for programming in Structured Text.";短路 |
| `XOR`、`MOD` | `a XOR b`、`a MOD 3` | PI/2528853899.html、PI/2528237963.html | — | 支援 | 總表列在 Bitstring / Arithmetic |
| 內建雙底線運算子 | `__NEW`、`__DELETE`、`__ISVALIDREF`、`__QUERYINTERFACE`、`__QUERYPOINTER`、`__VARINFO`、`__POUNAME`、`__POSITION` | PI/2528853899.html | — | 支援(當一般函式呼叫解析) | 識別字頁說雙底線保留給內部用 → 不要把 `__xxx(` 當成使用者識別字錯誤 |

### 1.4 宣告

| 語法項目 | 範例 | InfoSys 連結 | 版本限制 | parser 建議 | 備註 |
|---|---|---|---|---|---|
| 宣告通用語法 | `( <pragma> )* <scope> ( <type qualifier> )? <identifier> (AT <address>)? : <data type> ( := <initial value> )? ; END_VAR` | PI/2526557579.html | — | 支援 | scope 清單:"VAR, VAR_CONFIG, VAR_EXTERNAL, VAR_GLOBAL, VAR_INPUT, VAR_INST, VAR_IN_OUT, VAR_OUTPUT, VAR_STAT, VAR_TEMP";qualifier:"CONSTANT, RETAIN, PERSISTENT" |
| `VAR_GENERIC CONSTANT` | `VAR_GENERIC CONSTANT nLen : UDINT := 10; END_VAR`;實例 `fb : FB_Sample<100>;`、`fb : FB_Sample<(N*2)>;` | PI/13723588619.html | **TC3.1 build 4026 起** | 支援 | 實例宣告 `<fb instance name> : <function block name> < <literal> >;`,運算式需加括號。**`<` `>` 出現在型別位置**,parser 型別規則要容許 |
| `VAR_STAT` | `VAR_STAT n : INT; END_VAR` | PI/2528787339.html | — | 支援 | "TwinCAT initializes the static variables during download.";多實例共用一份 |
| `VAR_INST` | 見 2.1 | PI/2528798091.html | — | 支援 | 只能在 FB 的 method;"Instance variables cannot be extended with an attribute keyword." |
| `VAR_TEMP` | `VAR_TEMP t : INT; END_VAR` | PI/2528781963.html | — | 支援 | "TwinCAT reinitializes temporary variables each time the function block is called.";"only possible in programs and function blocks" |
| `VAR_CONFIG` | `VAR_CONFIG MAIN.fb.in AT %IX1.0 : BOOL; END_VAR` | TC3 PLC 手冊無獨立頁;只在宣告頁 scope 清單(PI/2526557579.html)。語法範例只有 TwinCAT 2 PLC Control 頁:https://infosys.beckhoff.com/content/1033/tcplccontrol/925318155.html | — | 支援(識別字位置允許點分 instance path)或 安全略過 | TC3 實際語法**未驗證**(只有 TC2 頁);名稱是完整 instance path,parser 需允許 `a.b.c AT %... : T;` |
| `VAR_EXTERNAL` | `VAR_EXTERNAL gX : INT; END_VAR` | PI/2528792715.html | — | 支援 | "Initialization is not allowed.";"In TwinCAT 3 PLC it is not necessary for variables to be declared as external" |
| `CONSTANT` | `VAR CONSTANT c : INT := 5; END_VAR` | PI/11982693643.html | — | 支援 | scope 可為 "VAR \| VAR_INPUT \| VAR_STAT \| VAR_GLOBAL";"Always assign an initialization value" |
| `RETAIN` / `PERSISTENT` | `VAR RETAIN ...`、`VAR_GLOBAL PERSISTENT ...` | 頁面存在於搜尋結果 PI/2528803467.html(標題 "Remanent Variables - PERSISTENT, RETAIN"),本次**未 WebFetch** | — | 支援 | 語意細節**未驗證**(只看到搜尋摘要);語法上就是 type qualifier,見 PI/2526557579.html。Function 內宣告 RETAIN:"this has no effect. In this case TwinCAT issues a compiler error."(PI/2530284939.html) |
| `AT %I*` / `%Q*` / `%M` | `bIn AT %I* : BOOL;`、`w AT %QW0 : WORD;`、`b AT %IX1.0 : BOOL;` | PI/11948825611.html | — | 支援 | `%` + `I\|Q\|M` + 可選 `X\|B\|W\|D` + `* \| <number>( .<number> )*` |
| `STRUCT` / `STRUCT EXTENDS` | `TYPE ST_B EXTENDS ST_A : STRUCT ... END_STRUCT END_TYPE` | PI/2529481355.html | — | 支援 | "TYPE <structure name> EXTENDS <basis structure> :" |
| `UNION` | `TYPE U : UNION a : LREAL; b : LINT; END_UNION END_TYPE` | PI/2529421195.html | — | 支援 | "all components have the same offset" |
| ENUM、base type、預設值 | `TYPE E : (A, B := 5, C) DWORD := B; END_TYPE` | PI/2529504395.html | `{attribute 'strict'}` **自 TC3.1 build 4026 起自動加在第一行** | 支援 | base type:"UINT \| SINT \| USINT \| DINT \| UDINT \| LINT \| ULINT \| BYTE \| WORD \| DWORD \| LWORD",未寫則 INT;`)` 後接 base type 再接 `:= <default>` |
| Alias / Subrange | `TYPE T : INT; END_TYPE`、`INT(0..100)` | 資料型別總表 PI/2529388939.html 有連結(PI/3928317323.html、PI/2529533323.html),本次**未開啟** | — | 支援 | 語法細節未驗證;subrange `(lo..hi)` 要能 parse,否則安全略過 |
| `ARRAY` 一般 | `ARRAY[1..10, 0..2] OF INT` | PI/2529464203.html(只有概述) | — | 支援 | "TwinCAT supports one-dimensional and multi-dimensional arrays of fixed or variable length." 初始化語法(如 `[3(0)]` 重複)本次**未驗證** → 初始化器解析失敗時安全略過 |
| `ARRAY[*]`(可變長度) | `VAR_IN_OUT a : ARRAY[*] OF INT; END_VAR`、`ARRAY[*, *] OF ...` | PI/8825257611.html | — | 支援 | "arrays with variable length can be declared in the declaration section VAR_IN_OUT";`LOWER_BOUND( <var> , <dim> )` / `UPPER_BOUND(...)` |
| `POINTER TO` / `^` / `ADR` | `p : POINTER TO INT; p := ADR(n); p^ := 1;` | PI/2529453451.html | — | 支援 | 後綴 `^` 要能接在任何 primary 後(`p^.x`、`a[i]^`) |
| `REFERENCE TO` 與 `REF=` | `r : REFERENCE TO INT; r REF= n;` | PI/2529458827.html | — | 支援 | "A reference type may not be used as the base type of an array, pointer or a reference."(語意錯誤,非 parse 層) |
| `__NEW` / `__DELETE` | `p := __NEW(FB_X); __DELETE(p);`、`__NEW(INT, 10)` | PI/2529171083.html | — | 支援 | `__NEW( <type> ( , <size> )? )`;FB/DUT 需 `{attribute 'enable_dynamic_creation'}`(注意第一參數是**型別名**,不是運算式) |
| `__ISVALIDREF` | `b := __ISVALIDREF(r);` | PI/2529165707.html、PI/2529458827.html | — | 支援 | 只能用在 `REFERENCE TO`;介面變數改用 `<> 0` |
| `__QUERYINTERFACE` | `b := __QUERYINTERFACE(itfA, itfB);` | PI/2529176459.html | — | 支援 | 兩者需衍生自 `__System.IQueryInterface` |
| `__QUERYPOINTER` | `b := __QUERYPOINTER(itf, p);` | PI/2529181835.html | — | 支援 | `__QUERYPOINTER (<ITF_Source>, <Pointer_Dest>)` |
| `THIS^` | `THIS^.M();` | PI/2528843147.html | — | 支援 | 用於 method 與 FB |
| `SUPER^` | `SUPER^();`、`SUPER^.M();` | PI/2528837771.html | — | 支援 | "You can only use SUPER in method implementations and associated function block implementations." `SUPER^()` 是呼叫父 FB body |
| `FB_init` / `FB_reinit` / `FB_exit` | `METHOD FB_init : BOOL VAR_INPUT bInitRetains : BOOL; bInCopyCode : BOOL; ... END_VAR`;實例 `fb : FB_X(nComNum := 1);`、`fb : FB_X(123);` | PI/5094414603.html | — | 支援 | **實例宣告可帶括號參數**(型別位置出現 `(...)`),parser 必須容許 |
| FB 宣告 EXTENDS / IMPLEMENTS | `FUNCTION_BLOCK FB_B EXTENDS FB_A IMPLEMENTS I_1, I_2` | PI/2530279563.html | — | 支援 | "FUNCTION_BLOCK <access specifier> <function block> \| EXTENDS ... \| IMPLEMENTS <comma-separated list of interfaces>" |
| `ABSTRACT` | `FUNCTION_BLOCK ABSTRACT FB_Base`、`METHOD ABSTRACT Execute` | PI/6413748235.html | **TC3.1 build 4024 起** | 支援 | 抽象 method/property 無實作 |
| `FINAL` / `INTERNAL` / `PUBLIC` / `PRIVATE` / `PROTECTED` | `METHOD PRIVATE M : BOOL`、`PROPERTY FINAL P : INT` | PI/2530307467.html(Method)、PI/2530335371.html(Property) | — | 支援 | method/property 修飾字清單出自這兩頁;FB 本身的 FINAL/INTERNAL 只在搜尋摘要看到,FB 頁 PI/2530279563.html 本身**未列出 → 未驗證**;parser 在 `FUNCTION_BLOCK` 後接受任意修飾關鍵字即可 |
| `PROPERTY` Get/Set | `PROPERTY PUBLIC nValue : INT` + Get/Set accessor | PI/2530335371.html | REFERENCE TO 回傳型 property 的 `:=`:"< 3.1.4022.0 the set accessor is called",之後改呼叫 Get;設 reference 用 `REF=` | 支援 | Get/Set 在 .TcPOU 內是分開的實作區塊,不是 ST 文字語法 |
| `ACTION` | 呼叫 `fbCounterA.Reset(In := FALSE);` | PI/2530340747.html | — | 支援 | "An action does not have its own declarations." → 名稱解析要用所屬 POU 的變數表 |
| `FUNCTION` 宣告 | `FUNCTION F : INT` | PI/2530284939.html | — | 支援 | "FUNCTION <function> : <data type>" |

### 1.5 typed literal(tokenizer 重點)

共通 lexer 規則(建議):先讀識別字,若**緊接** `#`,依前綴分派到對應的子 lexer;子 lexer 用**結構化樣式**,不能用「吃到空白為止」。

| 語法項目 | 範例 | InfoSys 連結 | 版本限制 | parser 建議 | 允許字元 / tokenizer 規則 |
|---|---|---|---|---|---|
| `T#` / `TIME#`(大小寫:`TIME\|time\|T\|t`) | `T#14ms`、`T#100s12ms`、`T#49D17H2M47S295MS` | PI/2529294987.html | — | 支援 | 單位 `d h m s ms`(大小寫皆可),順序不可變、可省略任意單位、最高單位可溢位。**單位比對要先試 `ms` 再試 `m`/`s`**。樣式:`(數字+ 單位)+`,遇到非數字非單位字元立即結束 → `T#1S-tonB.ET` 切成 `T#1S` `-` `tonB` `.` `ET`。底線、負號、小數(`T#1.5s`)手冊**都沒寫 → 未驗證**;建議數字部分寬鬆接受 `[0-9_.]`,但**不**把 `-` 吃進 literal(`#` 後緊接 `-` 例外地可接受為防禦) |
| `LTIME#`(`LTIME\|ltime`) | `LTIME#1000d15h23m12s34ms2us44ns` | PI/2529294987.html | — | 支援 | 多 `us`、`ns`;比對順序 `ms`/`us`/`ns` 先於 `m`/`s` |
| `D#` / `DATE#`(`DATE\|date\|D\|d`) | `D#2018-8-31`、`DATE#1996-05-06` | PI/2529300363.html | — | 支援 | 固定樣式 `\d+-\d+-\d+`(年 1970-2106),**只吃三段**,第四個 `-` 起不屬於 literal |
| `LD#` / `LDATE#`(`LDATE\|ldate\|LD\|ld`) | `LD#1996-05-06` | PI/2529300363.html | — | 支援 | 同 DATE,年 1970-2554 |
| `DT#` / `DATE_AND_TIME#` | `DT#2018-08-08-13:33:20` | PI/2529300363.html | — | 支援 | `\d+-\d+-\d+-\d+:\d+:\d+(\.\d+)?`(秒的小數只在 LDT 範例出現) |
| `LDT#` / `LDATE_AND_TIME#` | `LDT#2018-08-08-13:33:20.5` | PI/2529300363.html | — | 支援 | 同上,可帶小數秒 |
| `TOD#` / `TIME_OF_DAY#` | `TOD#12:34:56.789` | PI/2529300363.html | — | 支援 | `\d+:\d+:\d+(\.\d+)?` |
| `LTOD#` / `LTIME_OF_DAY#` | `LTOD#12:34:56.7890123456` | PI/2529300363.html | — | 支援 | 同 TOD,小數到 ns |
| 進位前綴 `2#` `8#` `16#` | `2#1001_0011`、`8#67`、`16#A` | PI/2529316491.html | — | 支援 | "You can use underscores within a numerical value." 16 進位 `[0-9A-Fa-f_]`,2 進位 `[01_]`,8 進位 `[0-7_]` |
| 型別前綴 `<Type>#` | `DINT#34`、`DINT#16#A1`、`INT#5` | PI/2529332619.html、PI/2529316491.html | — | 支援 | 頁面:"You have to capitalize the type.";型別清單 BOOL, SINT, USINT, BYTE, INT, UINT, WORD, DINT, UDINT, DWORD, REAL, LREAL。可疊加進位前綴(`DINT#16#A1`)。小寫前綴的合法性由編譯器判,parser 寬鬆接受 |
| `TRUE` / `FALSE` | `TRUE` | PI/2529289611.html | — | 支援 | "the truth values TRUE (1) and FALSE (0)" |
| REAL / 指數 | `1.64e+009`、`-1.7976931348623157E+308` | PI/2529321867.html | — | 支援 | `<significand> e \| E <exponent>`,指數可帶正負號;"7,4 with comma returns compiler error"。REAL 內底線**未寫 → 未驗證**,lexer 寬鬆接受;**實測 2026-11-13:`1_000.5` 接受**(`../verification/st-syntax-measured.md`) |
| 十進位底線 | `1_000_000` | PI/2529316491.html | — | 支援 | 同上 |
| `<Enum>#<Member>` 形式 | `E_Color#Red` | 本次**未找到** InfoSys 頁面 | — | **未驗證** → lexer 對 `<ident>#<ident>` 視為 qualified literal,不判 fail | ENUM 頁只寫 `{attribute 'qualified_only'}` 時用 `<enumeration name>.<component name>`;**實測 2026-11-13:編譯器拒絕**(`../verification/st-syntax-measured.md`) |

### 1.6 識別字

| 語法項目 | 範例 | InfoSys 連結 | 版本限制 | parser 建議 | 備註 |
|---|---|---|---|---|---|
| 字元集合 | `nVar_1` | PI/2529913227.html | — | 支援 | "An identifier must contain the following letters and numbers:" 0-9、A-Z、a-z;底線允許;空白、連字號、特殊字元(例:`ß`)不允許 |
| 開頭字元 | — | PI/2529913227.html | — | 支援 | "An identifier may not begin with a number." 開頭底線頁面未禁止 → 接受 |
| 雙底線 | `__x` | PI/2529913227.html | — | 支援 | "Double underscores ('__') should be avoided, because they are used for internal variables."(是建議,不是錯誤) |
| 長度 | — | PI/2529913227.html | — | 支援 | "There is no limit to the length of an identifier." |
| 大小寫 | `VAR1` = `var1` | PI/2529913227.html | — | 支援(符號表一律 case-insensitive) | "TwinCAT is not case-sensitive" |
| 關鍵字 | — | PI/2529913227.html | — | 支援 | "An identifier must not be identical to a keyword" |
| Unicode / 中文 | `變數1` | PI/2529913227.html 只列 ASCII,沒有明文談 Unicode | — | **未驗證** → lexer 遇到非 ASCII 字母**不判 fail**,物件安全略過 | 依頁面清單推論非 ASCII 不合法,但沒明寫;字串與註解內的中文當然合法;**實測 2026-11-13:非 ASCII 識別字編譯器拒絕**(`../verification/st-syntax-measured.md`) |
| pragma 大小寫 | `{attribute ...}` | PI/2526889867.html | — | 支援 | 與識別字相反:"Case-sensitivity must be respected."(pragma 內) |

---

## 第 2 部分:TwinCAT 行為出處

| # | 問題 | InfoSys 原文重點 | URL | 狀態 |
|---|---|---|---|---|
| 1a | METHOD 的 VAR 是否每次呼叫重新初始化? | "TwinCAT re-initializes all variables and function blocks, which you have declared in a method, with each call of the method." / "All data of a method are temporary and only valid while the method is executed (stack variables)." | PI/2530307467.html | 已驗證 |
| 1b | FUNCTION 的 VAR 是否每次呼叫重新初始化? | "TwinCAT re-initializes all variables that you have declared in a function each time the function is called." Function 內 RETAIN:"this has no effect. In this case TwinCAT issues a compiler error." | PI/2530284939.html | 已驗證 |
| 1c | VAR_INST 用途 | "TwinCAT does not store a VAR_INST variable of a method on the method stack like VAR variables"(放在 FB 實例上,"is not reinitialized each time the method is called");"Instance variables are only allowed in methods of a function block";不能用其他實例變數或 method 輸入初始化 | PI/2528798091.html | 已驗證 |
| 1d | VAR_TEMP(FB/PRG 內的暫時變數) | "TwinCAT reinitializes temporary variables each time the function block is called." | PI/2528781963.html | 已驗證 |
| 2a | TON 的 IN / PT / Q / ET 語意 | IN:"Rising edge: Start timer" / "Falling edge: Reset timer";"Q is TRUE, if IN = TRUE and ET = PT. Otherwise Q = FALSE." | https://infosys.beckhoff.com/content/1033/tcplclib_tc2_standard/74406539.html | 已驗證 |
| 2b | TON 在 PT = 0 時的行為 | 頁面沒寫 | 同上 | **未驗證** |
| 2c | TON 在 IN 一直 TRUE 時「離開再進入」(條件式呼叫、某幾個 cycle 沒呼叫)的語意 | 頁面只寫邊緣語意,沒寫「沒被呼叫的週期」怎麼算 | 同上 | **未驗證**(需 UmRT 實測) |
| 2d | R_TRIG 語意 | Q:"TRUE for a rising edge at the CLK input (for one cycle)."(頁面無實作碼,沒列內部 M) | https://infosys.beckhoff.com/content/1033/tcplclib_tc2_standard/74391563.html | 已驗證 |
| 3 | FOR:計數器到型別上限 → 無窮迴圈 | FOR 頁:"The <end value> must not have the same value as the upper bound of the data type of the counter."(沒寫「無窮迴圈」字樣)。編譯器警告 C0266:"Loop exit condition ... is constant FALSE. Possible endless loop.",範例正是 `FOR b := 0 TO 255 BY 1 DO`(b : BYTE),解法 "use a sufficiently large type for the control variable which can map the final value+1." | PI/2528280971.html、PI/21630340363.html | 已驗證(且編譯器已有 C0266 警告;linter 可不重做或只做 BY 非 1 的變形) |
| 4a | Tc2_MC2 General rules:Execute 上升沿 | "The function block can only be triggered by a rising edge at the "Execute" input if the "Busy" output is FALSE.";"The input parameters become active with a positive edge." | https://infosys.beckhoff.com/content/1033/tcplclib_tc2_mc2/70043531.html | 已驗證 |
| 4b | 必須持續呼叫直到 Done / Error / CommandAborted | "the function block must be called cyclically in order to be able to execute the command.";Busy 一直 TRUE 到命令成功或失敗結束;Done/Busy/Error/CommandAborted "are mutually exclusive" | 同上 | 已驗證 |
| 4c | 在 Busy 時停止呼叫 / 離開的後果 | 頁面沒寫 | 同上 | **未驗證** |
| 4d | 錯誤重置 | "Function block errors do not have to be reset explicitly. They are reset automatically when the "Execute" input is reset." | 同上 | 已驗證 |
| 5 | ENUM 未指定值的成員如何編號 | "The values of the components are initialized automatically: starting at 0, the values are incremented consecutively by 1." 未指定 base type 時 "the INT base data type is used automatically." 混合「部分顯式賦值」時下一個成員是否 = 前一個 +1 頁面沒逐字寫 | PI/2529504395.html | 已驗證(從 0 起、+1);混合賦值的接續規則**未驗證** |
| 6a | 除以零在 runtime 的結果 | CheckDiv 頁只寫可用 CheckDivDInt/LInt/Real/LReal "to avoid division by 0",沒寫不加時的結果。ExceptionCode 型別列有 `RTSEXCPT_DIVIDEBYZERO`、`RTSEXCPT_FPU_DIVIDEBYZERO`,但沒描述何時觸發 | PI/2530362251.html、PI/6753940235.html | **未驗證**(只確認有對應 exception code) |
| 6b | 陣列越界 / CheckBounds | "TwinCAT calls the function implicitly as soon as an ARRAY variable is assigned values.";"The check is only performed with a variable array index.";"A consistently faulty array index results in a compiler error."(常數索引)。沒加 CheckBounds 時的 runtime 結果頁面沒寫(ExceptionCode 有 `RTSEXCPT_ARRAYBOUNDS`) | PI/2530356875.html、PI/6753940235.html | CheckBounds 機制已驗證;無 CheckBounds 時的後果**未驗證** |
| 7a | `__ISVALIDREF` | "The operator is used to check whether a reference points to a value.";只能用於 `REFERENCE TO`,介面變數改 `<> 0` | PI/2529165707.html | 已驗證 |
| 7b | 未初始化 REFERENCE 解參照的後果 | "TwinCAT initializes references (with 0)." / "A reference can be invalid (0)." 解參照無效 reference 會發生什麼,頁面沒寫(ExceptionCode 有 `RTSEXCPT_ACCESS_VIOLATION`,但沒連到 reference) | PI/2529458827.html | 初值 0 已驗證;解參照後果**未驗證** |
| 8a | TE1200 Static Analysis Light 是否每次編譯自動執行 | "automatically executed following the successful compilation process."(編譯有錯則不跑);Light vs Full 表:Light "Yes, not configurable"、Full "Configurable" | PI/2527107467.html、PI/21574414603.html | 已驗證 |
| 8b | 結果是否出現在 Error List | PI/2527107467.html 寫規則違反以 error message 出現在 Error List | PI/2527107467.html | 已驗證 |
| 8c | 怎麼啟用 / 授權 / 規則 | 規則在 PLC 專案屬性的 Static Analysis 類別設定;Light "No, usable free of charge";最大錯誤數 500(不可設);Light 7 條:SA0033、SA0028、SA0006、SA0004、SA0027、SA0167、SA0175 | PI/2527107467.html、PI/21574414603.html | 已驗證 |
| 8d | Light 從哪個 build 起提供 | 只在搜尋摘要看到「4018」,實際頁面沒寫 | — | **未驗證** |

注意:PI/4196065547.html("Static Analysis Light" 英文頁)本次 WebFetch 回 404(1031 德文路徑也 404),改用 PI/2527107467.html 與 PI/21574414603.html。

---

## 附錄:本次打開成功的 InfoSys 頁面

TC3 PLC intro(前綴 `https://infosys.beckhoff.com/content/1033/tc3_plc_intro/`):
2528329355(ST comments)、2529294987(TIME/LTIME constants)、2529187211(__TRY)、2529795979(Conditional pragmas)、2529327243(STRING constants)、2526552203(Assigning identifiers,無規則)、2529561739(Message pragmas)、2526889867(Using pragmas)、2529913227(Identifier rules)、3525631371(Region pragma)、136301707(REFERENCE 用法)、2528237963(ST Expressions)、2528264843(Assignment as expression)、2528798091(VAR_INST)、2530307467(Object Method)、2528749707(Variables,僅概述)、13723588619(VAR_GENERIC CONSTANT)、2526762891(Programming ST)、2526557579(Declaring variables)、2529284235(Operands)、11948825611(AT declaration)、2529388939(Data types)、2529316491(Number constants)、2529321867(REAL constants)、2529300363(Date and time constants)、2529332619(Typed literals)、2529289611(BOOL constants)、2529504395(Enumerations)、2529481355(Structure)、2529421195(UNION)、2529464203(ARRAY,僅概述)、2529453451(POINTER)、8825257611(Array with variable length)、2530356875(CheckBounds)、2530362251(CheckDiv)、2529171083(__NEW)、2529176459(__QUERYINTERFACE)、2529181835(__QUERYPOINTER)、2529165707(__ISVALIDREF)、5094414603(FB_init)、4978163979(REF=)、2528280971(FOR)、2528307851(JMP)、2528318603(CONTINUE)、2528923787(AND_THEN)、2528929163(OR_ELSE)、2528254091(S=)、2528259467(R=)、3513625739(=>)、2528837771(SUPER)、2528843147(THIS)、2530279563(Function block)、2530335371(Property)、2528787339(VAR_STAT)、2528781963(VAR_TEMP)、2528792715(VAR_EXTERNAL)、2528755083(Local VAR)、6413748235(ABSTRACT)、2530284939(Function)、2530340747(Action)、2529437323(WSTRING)、2529567115(Attribute pragmas)、2529572491(User-defined attributes)、3107974923(TcLinkTo)、2528275595(IF)、11982693643(CONSTANT)、6753940235(ExceptionCode)、21630340363(C0266)、2529122699(EXPT)、2528853899(Operators 總表)、2526757515(ExST)、2528221835(ST/ExST reference)、2528243339(Assignments)、2528270219(Instructions)、12189021579(TIME data type)、21574414603(Light vs Full)、2527107467(Code analysis)。

其他:
- https://infosys.beckhoff.com/content/1031/tc3_plc_intro/2529294987.html(TIME 德文版)
- https://infosys.beckhoff.com/content/1033/tf5100_tc3_nc_i/4184579339.html(NC I ST 註解,含 `/* */`)
- https://infosys.beckhoff.com/content/1033/tcplccontrol/925318155.html(TwinCAT 2 Global Variables / VAR_CONFIG)
- https://infosys.beckhoff.com/content/1033/tcplclib_tc2_standard/74406539.html(TON)
- https://infosys.beckhoff.com/content/1033/tcplclib_tc2_standard/74391563.html(R_TRIG)
- https://infosys.beckhoff.com/content/1033/tcplclib_tc2_mc2/70043531.html(General rules for MC function blocks)

打不開:PI/4196065547.html(1033 與 1031 皆 404)。
