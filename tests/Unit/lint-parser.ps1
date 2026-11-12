# Unit: semantic linter (#252 Phase 1a) tokenizer, declaration parser, statement-structure scanner.
# One fixture per item of openspec/changes/add-semantic-linter/research/st-syntax-inventory.md
# (InfoSys links there), the corpus pitfalls (END_IF without ';', nested (* *), $' escape, Chinese
# comments, BOM) and the minimal counter-examples of the second design review 6-1..6-4:
# conditional pragma -> notAnalyzed (never LINT_PARSE_FAILED), calls inside __TRY recognised,
# ?= does not throw, T#1S-tonB.ET split into the right tokens. Constructs the inventory marks
# "unverified" must give status not-analyzed, not parse-failed (design.md D3).
#   powershell.exe -NoProfile -File tests/Unit/lint-parser.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 500) { $Detail = $Detail.Substring(0, 500) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}
$A = & (Get-Module TwinCATAutomation) { Get-TcLintEngineType -Name 'StAnalyzer' }
function Tok([string]$t) { return @($A::DescribeTokens($t)) }
function Impl([string]$t) { return $A::DescribeImplementation($t) }
function Decl([string]$t) { return $A::DescribeDeclaration($t) }
function TokCheck([string]$Name, [string]$Text, [string[]]$Want) {
    $got = Tok $Text
    Check "tokens: $Name" ((($got -join ' | ') -ceq ($Want -join ' | '))) ("got: " + ($got -join ' | '))
}
function StatusCheck([string]$Name, $Result, [string]$Status, [string]$Reason = $null) {
    $ok = $Result['status'] -eq $Status -and ([string]::IsNullOrEmpty($Reason) -or $Result['reason'] -eq $Reason -or $Result['errorRule'] -eq $Reason)
    Check "status: $Name" $ok ("status=$($Result['status']) reason=$($Result['reason']) errorRule=$($Result['errorRule']) error=$($Result['error'])")
}

# ---------------------------------------------------------------- 1.1 comments, strings, pragmas
TokCheck '// comment' "x := 1; // note := 2" @('Ident:x', 'Op::=', 'Number:1', 'Op:;')
TokCheck 'nested (* *)' "(* a (* b *) c *) y" @('Ident:y')
TokCheck "STRING with `$' escape and comment text" "s := 'it`$'s (* no *)';" @('Ident:s', 'Op::=', "String:'it`$'s (* no *)'", 'Op:;')
TokCheck 'STRING $R$N $$ $27' "s := '`$R`$N`$`$`$27';" @('Ident:s', 'Op::=', "String:'`$R`$N`$`$`$27'", 'Op:;')
TokCheck 'WSTRING with $"' "w := `"a`$`"b`";" @('Ident:w', 'Op::=', "WString:`"a`$`"b`"", 'Op:;')
TokCheck "pragma with '}' in quotes" "{attribute 'TcLinkTo' := '}x'} b" @("Pragma:{attribute 'TcLinkTo' := '}x'}", 'Ident:b')
TokCheck 'multi-line pragma' "{region `"Init`"`n}`nx;" @("Pragma:{region `"Init`"`n}", 'Ident:x', 'Op:;')
TokCheck 'BOM at the start is white space' ([string][char]0xFEFF + "x;") @('Ident:x', 'Op:;')
TokCheck 'Chinese in comments and strings' "// 中文註解`ns := '馬達';" @('Ident:s', 'Op::=', "String:'馬達'", 'Op:;')
TokCheck 'conditional pragma is flagged' "{IF defined (A)}x;{END_IF}" @('Pragma:{IF defined (A)}', 'Ident:x', 'Op:;', 'Pragma:{END_IF}', 'CONDITIONAL')
TokCheck 'unterminated string' "s := 'abc" @('Ident:s', 'Op::=', 'ERROR:unterminated string literal')
TokCheck 'line break in a string' "s := 'ab`ncd';" @('Ident:s', 'Op::=', 'ERROR:line break inside a string literal')
TokCheck 'unterminated (* comment' "x; (* open" @('Ident:x', 'Op:;', 'ERROR:unterminated (* comment')
TokCheck 'unterminated pragma is unsupported (incomplete), not an error' "{attribute 'x'" @('UNKNOWN:unsupported-syntax:unterminated-pragma')
TokCheck "pragma with `$' in quotes" "{warning 'don`$'t'} x;" @("Pragma:{warning 'don`$'t'}", 'Ident:x', 'Op:;')
TokCheck 'B2 backtick is a certain error' "x := ``a``;" @('Ident:x', 'Op::=', 'ERROR:character U+0060 is not ST')
TokCheck 'B2 typographic quote is a certain error' ("s := " + [char]0x2018 + 'a' + [char]0x2019 + ';') @('Ident:s', 'Op::=', 'ERROR:character U+2018 is not ST')
TokCheck 'B2 XML entity in code is reported as such' "IF a &lt; b THEN" @('Ident:IF', 'Ident:a', 'Ident:b', 'Ident:THEN', 'ENTITY:&lt;')
TokCheck '/* */ is unverified (PLC manual does not list it)' "x /* c */ := 1;" @('Ident:x', 'Op::=', 'Number:1', 'Op:;', 'UNVERIFIED:unverified-syntax:slash-star-comment')

# ---------------------------------------------------------------- 1.3 operators
TokCheck 'S= after a designator' "bOut S= bIn;" @('Ident:bOut', 'Op:S=', 'Ident:bIn', 'Op:;')
TokCheck 'R= after an index' "a[1] R= b;" @('Ident:a', 'Op:[', 'Number:1', 'Op:]', 'Op:R=', 'Ident:b', 'Op:;')
TokCheck 'REF= ' "refA REF= stA;" @('Ident:refA', 'Op:REF=', 'Ident:stA', 'Op:;')
TokCheck 'S as a variable after IF is not S=' "IF S=5 THEN" @('Ident:IF', 'Ident:S', 'Op:=', 'Number:5', 'Ident:THEN')
TokCheck '?= does not throw, flagged unverified' "itfB ?= itfA;" @('Ident:itfB', 'Op:?=', 'Ident:itfA', 'Op:;', 'UNVERIFIED:unverified-syntax:assignment-attempt')
TokCheck '** flagged unverified' "x := y ** 2;" @('Ident:x', 'Op::=', 'Ident:y', 'Op:**', 'Number:2', 'Op:;', 'UNVERIFIED:unverified-syntax:power-operator')
TokCheck '=> with empty right side' "fb(Q => );" @('Ident:fb', 'Op:(', 'Ident:Q', 'Op:=>', 'Op:)', 'Op:;')
TokCheck 'range .. is not a REAL' "ARRAY[1..10]" @('Ident:ARRAY', 'Op:[', 'Number:1', 'Op:..', 'Number:10', 'Op:]')

# ---------------------------------------------------------------- 1.5 typed literals (review 6-4)
TokCheck 'T#1S-tonB.ET is split' "IF tonA.ET > T#1S-tonB.ET THEN" @('Ident:IF', 'Ident:tonA', 'Op:.', 'Ident:ET', 'Op:>', 'TypedLiteral:T#1S', 'Op:-', 'Ident:tonB', 'Op:.', 'Ident:ET', 'Ident:THEN')
TokCheck 'TIME units' "T#14ms T#100s12ms TIME#49D17H2M47S295MS t#1h30m" @('TypedLiteral:T#14ms', 'TypedLiteral:T#100s12ms', 'TypedLiteral:TIME#49D17H2M47S295MS', 'TypedLiteral:t#1h30m')
TokCheck 'LTIME with us / ns' "LTIME#1000d15h23m12s34ms2us44ns+x" @('TypedLiteral:LTIME#1000d15h23m12s34ms2us44ns', 'Op:+', 'Ident:x')
TokCheck 'DATE stops after three groups' "D#2018-8-31-x" @('TypedLiteral:D#2018-8-31', 'Op:-', 'Ident:x')
TokCheck 'DT / LDT / TOD / LTOD' "DT#2018-08-08-13:33:20 LDT#2018-08-08-13:33:20.5 TOD#12:34:56.789 LTOD#12:34:56.7890123456" @('TypedLiteral:DT#2018-08-08-13:33:20', 'TypedLiteral:LDT#2018-08-08-13:33:20.5', 'TypedLiteral:TOD#12:34:56.789', 'TypedLiteral:LTOD#12:34:56.7890123456')
TokCheck 'base prefixes' "16#FF 2#1010_0101 8#67 1_000_000" @('Number:16#FF', 'Number:2#1010_0101', 'Number:8#67', 'Number:1_000_000')
TokCheck 'type prefixes' "DINT#16#A1 INT#-5 BOOL#TRUE REAL#1.5" @('TypedLiteral:DINT#16#A1', 'TypedLiteral:INT#-5', 'TypedLiteral:BOOL#TRUE', 'TypedLiteral:REAL#1.5')
TokCheck 'REAL with exponent' "x := 1.5E-3 + 1.64e+009;" @('Ident:x', 'Op::=', 'Number:1.5E-3', 'Op:+', 'Number:1.64e+009', 'Op:;')
TokCheck 'E_Enum#Member is unverified' "e := E_Color#Red;" @('Ident:e', 'Op::=', 'TypedLiteral:E_Color#Red', 'Op:;', 'UNVERIFIED:unverified-syntax:enum-hash-literal')
TokCheck 'direct addresses' "%IX0.0 %QW2 %I* %MB10" @('Address:%IX0.0', 'Address:%QW2', 'Address:%I*', 'Address:%MB10')
TokCheck 'non-ASCII identifier is unverified' "變數1 := 1;" @('Ident:變數1', 'Op::=', 'Number:1', 'Op:;', 'UNVERIFIED:unverified-syntax:non-ascii-identifier')
TokCheck 'B2 other unknown character is unsupported (incomplete), not a downgrade' "x := a & b;" @('Ident:x', 'Op::=', 'Ident:a', 'Ident:b', 'Op:;', 'UNKNOWN:unsupported-syntax:char-U+0026')

# ---------------------------------------------------------------- implementation structure
$r = Impl "IF a THEN b := 1; END_IF c := 2;`nFOR i := 1 TO 10 BY 2 DO x := x + i; END_FOR`nWHILE n < 5 DO n := n + 1; END_WHILE`nREPEAT n := n - 1; UNTIL n = 0 END_REPEAT;`nCASE e OF`n  E.A: fb1();`n  E.B, E.C: fb2();`n  1..5: ;`nELSE fb3();`nEND_CASE;;"
StatusCheck 'all block kinds, END_IF without semicolon, empty ;;' $r 'ok'
$calls = @($r['calls'])
Check 'CASE labels: calls at statement start, blocks recorded' ($calls.Count -eq 3 -and $calls[0]['target'] -eq 'fb1' -and $calls[0]['statementStart'] -and $calls[0]['blocks'] -eq 'CASE:label' -and $calls[2]['blocks'] -eq 'CASE:case-else') (($calls | ForEach-Object { "$($_['target'])/$($_['blocks'])/$($_['statementStart'])" }) -join ' ')

$r = Impl "__TRY`n  fbAxis(Enable := TRUE);`n__CATCH(exc)`n  fbErr(Code := exc);`n__FINALLY`n  fbFin();`n__ENDTRY"
StatusCheck '__TRY / __CATCH / __FINALLY / __ENDTRY' $r 'ok'
$c = @($r['calls'])
Check '__TRY: the call is recognised and not conditional; __CATCH call is conditional' ($c.Count -eq 3 -and $c[0]['target'] -eq 'fbAxis' -and -not $c[0]['conditional'] -and $c[1]['target'] -eq 'fbErr' -and $c[1]['conditional'] -and $c[1]['blocks'] -eq 'TRY:catch' -and -not $c[2]['conditional']) (($c | ForEach-Object { "$($_['target'])/$($_['blocks'])/$($_['conditional'])" }) -join ' ')

$r = Impl "bOk := fb.M_Update();`nIF fb.M_Done() THEN x := 1; END_IF`nfbA(IN := x, Q => );`nTHIS^.M_Run();`nSUPER^();`np := __NEW(FB_X);`na := b := c + 9;`nlbl: x := 1; JMP lbl;`np^ := 1;"
StatusCheck 'expressions, THIS^/SUPER^, __NEW, assignment as expression, JMP label' $r 'ok'
$c = @($r['calls'])
$byTarget = @{}; foreach ($x in $c) { $byTarget[$x['target']] = $x }
Check 'method call inside an expression has inExpression' ($byTarget['fb.M_Update']['inExpression'] -and $byTarget['fb.M_Done']['inExpression'] -and $byTarget['fb.M_Done']['conditional'] -and -not $byTarget['fbA']['inExpression']) (($c | ForEach-Object { "$($_['target'])/$($_['inExpression'])" }) -join ' ')
Check 'THIS^ / SUPER^ / __NEW recorded' ($byTarget.ContainsKey('THIS^.M_Run') -and $byTarget.ContainsKey('SUPER^') -and $byTarget.ContainsKey('__NEW')) (($c | ForEach-Object { $_['target'] }) -join ' ')

$r = Impl "a[fb.M_Get()] := 1;`nx := arr[GetIdx(i)].val;`ny := tab[k[j]];"
$t = @(@($r['calls']) | ForEach-Object { $_['target'] })
Check 'should-fix 7: calls inside array indexes are recorded' (($t -contains 'fb.M_Get') -and ($t -contains 'GetIdx') -and (@($r['identifierRefs']) -contains 'j') -and (@($r['identifierRefs']) -contains 'i')) (($t -join ',') + ' / ' + (@($r['identifierRefs']) -join ','))
StatusCheck 'B2 unknown character in code -> unsupported (incomplete)' (Impl 'x := a @ b;') 'unsupported' 'unsupported-syntax:char-U+0040'
StatusCheck 'B2 backtick -> LINT-PARSE-001' (Impl 'x := `a`;') 'parse-failed' 'LINT-PARSE-001'
$r = Impl "IF tonA.ET > T#1S-tonB.ET THEN x := 1; END_IF"
Check 'review 6-4: tonB is an identifier reference' (@($r['identifierRefs']) -contains 'tonB' -and @($r['memberAccesses']) -contains 'tonB.ET') ((@($r['identifierRefs']) -join ',') + ' / ' + (@($r['memberAccesses']) -join ','))

$r = Impl "{IF defined (SIMULATION)}`nIF bSim THEN`n{ELSE}`nIF bReal THEN`n{END_IF}`nx := 1;`nEND_IF"
StatusCheck 'review 6-1: conditional pragma with unbalanced IF -> not analysed' $r 'not-analyzed' 'conditional-pragma'
$r = Impl "itfBrake ?= fbBase;"
StatusCheck 'review 6-3: ?= -> not analysed (unverified-syntax)' $r 'not-analyzed' 'unverified-syntax:assignment-attempt'
$r = Impl "x := y ** 2;`nIF a THEN"
StatusCheck '** plus an open IF: downgraded, not a parse failure' $r 'not-analyzed' 'unverified-syntax:power-operator'
$r = Impl "IF a THEN`n  x := 1;"
StatusCheck 'missing END_IF -> LINT-PARSE-002' $r 'parse-failed' 'LINT-PARSE-002'
Check 'missing END_IF: position of the IF' ($r['errorLine'] -eq 1) "line=$($r['errorLine'])"
StatusCheck 'END_IF without IF -> LINT-PARSE-002' (Impl "x := 1; END_IF") 'parse-failed' 'LINT-PARSE-002'
StatusCheck 'END_FOR closes an IF -> LINT-PARSE-002' (Impl "IF a THEN FOR i := 1 TO 2 DO x := i; END_IF END_FOR") 'parse-failed' 'LINT-PARSE-002'
StatusCheck 'ELSE outside IF / CASE -> LINT-PARSE-002' (Impl "x := 1; ELSE y := 2;") 'parse-failed' 'LINT-PARSE-002'
StatusCheck 'unterminated string -> LINT-PARSE-001' (Impl "s := 'abc;") 'parse-failed' 'LINT-PARSE-001'
StatusCheck 'string error after a conditional pragma -> not analysed' (Impl "{IF defined(X)}`ns := 'abc;`n{END_IF}") 'not-analyzed' 'conditional-pragma'
StatusCheck 'AND_THEN / OR_ELSE / XOR / MOD / region / message pragma' (Impl "{region `"x`"}`nIF p <> 0 AND_THEN p^ = 99 OR_ELSE b XOR c THEN n := n MOD 3; END_IF`n{endregion}`n{warning 'todo'}") 'ok'
StatusCheck 'empty implementation' (Impl '') 'ok'

# ---------------------------------------------------------------- declarations
$d = Decl "{attribute 'reflection'}`nFUNCTION_BLOCK PUBLIC FB_B EXTENDS FB_A IMPLEMENTS I_1, Lib.I_2`nVAR_INPUT`n    {attribute 'hide'}`n    bStart, bStop : BOOL;`nEND_VAR`nVAR_OUTPUT`n    nErr : UDINT := 0;`nEND_VAR`nVAR_IN_OUT`n    a : ARRAY[*] OF INT;`nEND_VAR`nVAR`n    fb : FB_Sample<100>;`n    fb2 : FB_X(nComNum := 1);`n    bIn AT %I* : BOOL;`n    arr : ARRAY[0..2] OF INT := [3(0)];`n    p : POINTER TO INT;`n    r : REFERENCE TO ST_X;`n    s : STRING(80) := 'x';`nEND_VAR`nVAR_TEMP t : INT; END_VAR`nVAR_STAT st : INT; END_VAR`nVAR RETAIN PERSISTENT pv : INT; END_VAR"
StatusCheck 'FUNCTION_BLOCK with modifiers, EXTENDS, IMPLEMENTS, all VAR kinds' $d 'ok'
Check 'FB header' ($d['headerKeyword'] -eq 'FUNCTION_BLOCK' -and $d['name'] -eq 'FB_B' -and (@($d['modifiers']) -join ',') -eq 'PUBLIC' -and (@($d['extends']) -join ',') -eq 'FB_A' -and (@($d['implements']) -join ',') -eq 'I_1,Lib.I_2' -and $d['headerKnown']) ($d | ConvertTo-Json -Depth 3 -Compress)
$blocks = @($d['varBlocks'])
$vars = @($blocks | ForEach-Object { @($_['vars']) })
$names = @($vars | ForEach-Object { @($_['names']) })
Check 'VAR blocks and variables' ($blocks.Count -eq 7 -and ($names -join ',') -eq 'bStart,bStop,nErr,a,fb,fb2,bIn,arr,p,r,s,t,st,pv' -and (@($blocks[6]['qualifiers']) -join ',') -eq 'RETAIN,PERSISTENT') ($names -join ',')
$v = @{}; foreach ($x in $vars) { $v[@($x['names'])[0]] = $x }
Check 'types: generic <100>, FB_init args, ARRAY[*], AT %I*, init text' ($v['fb']['type'] -eq 'FB_Sample<100>' -and $v['fb2']['type'] -like 'FB_X(nComNum*1)' -and $null -eq $v['fb2']['init'] -and $v['a']['type'] -eq 'ARRAY[*]OF INT' -and $v['bIn']['address'] -eq '%I*' -and $v['arr']['init'] -like '*3(0)*' -and $v['nErr']['init'] -eq '0' -and @($v['bStart']['attributes'])[0] -eq "{attribute 'hide'}") (($vars | ForEach-Object { "$(@($_['names'])[0])=$($_['type'])|$($_['init'])" }) -join ' ; ')

$d = Decl "METHOD PRIVATE M_Do : BOOL`nVAR_INPUT n : INT; END_VAR"
Check 'METHOD with modifier and return type' ($d['status'] -eq 'ok' -and $d['headerKeyword'] -eq 'METHOD' -and $d['name'] -eq 'M_Do' -and $d['returnType'] -eq 'BOOL') ($d | ConvertTo-Json -Depth 3 -Compress)
$d = Decl "FUNCTION F_Scale : ARRAY[0..1] OF REAL`nVAR_INPUT x : REAL; END_VAR`nVAR_GENERIC CONSTANT nLen : UDINT := 10; END_VAR"
Check 'FUNCTION with ARRAY return type, VAR_GENERIC CONSTANT' ($d['status'] -eq 'ok' -and $d['returnType'] -eq 'ARRAY[0..1]OF REAL' -and @($d['varBlocks'])[1]['kind'] -eq 'VAR_GENERIC') ($d | ConvertTo-Json -Depth 3 -Compress)
$d = Decl "PROPERTY PUBLIC nValue : INT"
Check 'PROPERTY header' ($d['status'] -eq 'ok' -and $d['headerKeyword'] -eq 'PROPERTY' -and $d['name'] -eq 'nValue') ($d | ConvertTo-Json -Depth 3 -Compress)
$d = Decl "INTERFACE I_B EXTENDS I_A, I_C"
Check 'review 6-6: INTERFACE EXTENDS keeps every base' ($d['status'] -eq 'ok' -and (@($d['extends']) -join ',') -eq 'I_A,I_C') ($d | ConvertTo-Json -Depth 3 -Compress)
$d = Decl "PROGRAM MAIN`nVAR`nEND_VAR"
Check 'PROGRAM with an empty VAR block' ($d['status'] -eq 'ok' -and $d['headerKeyword'] -eq 'PROGRAM') ($d | ConvertTo-Json -Depth 3 -Compress)

$d = Decl "{attribute 'qualified_only'}`n{attribute 'strict'}`nTYPE E_Mode :`n(`n    Manual := 0,`n    Auto,`n    Service := 16#0A`n) DWORD := Auto;`nEND_TYPE"
$t = $d['type']
Check 'ENUM with base type, default, hex value' ($d['status'] -eq 'ok' -and $t['kind'] -eq 'ENUM' -and $t['name'] -eq 'E_Mode' -and $t['baseType'] -eq 'DWORD' -and $t['default'] -eq 'Auto' -and (@($t['enumMembers'] | ForEach-Object { "$($_['name'])=$($_['value'])" }) -join ',') -eq 'Manual=0,Auto=,Service=16#0A') ($t | ConvertTo-Json -Depth 3 -Compress)
$d = Decl "TYPE ST_B EXTENDS ST_A :`nSTRUCT`n    a, b : INT;`n    c : ARRAY[1..3] OF BOOL;`nEND_STRUCT`nEND_TYPE"
Check 'STRUCT EXTENDS' ($d['status'] -eq 'ok' -and $d['type']['kind'] -eq 'STRUCT' -and $d['type']['extends'] -eq 'ST_A' -and @($d['type']['members']).Count -eq 2) ($d | ConvertTo-Json -Depth 4 -Compress)
$d = Decl "TYPE U_X :`nUNION`n    r : LREAL;`n    n : LINT;`nEND_UNION`nEND_TYPE"
Check 'UNION' ($d['status'] -eq 'ok' -and $d['type']['kind'] -eq 'UNION') ($d | ConvertTo-Json -Depth 4 -Compress)
$d = Decl "TYPE T_Percent : INT(0..100); END_TYPE"
Check 'alias with subrange' ($d['status'] -eq 'ok' -and $d['type']['kind'] -eq 'ALIAS' -and $d['type']['baseType'] -eq 'INT(0..100)') ($d | ConvertTo-Json -Depth 4 -Compress)
$d = Decl "{attribute 'qualified_only'}`nVAR_GLOBAL CONSTANT`n    c : INT := 5;`nEND_VAR`nVAR_GLOBAL PERSISTENT`n    p : INT;`nEND_VAR"
Check 'GVL: VAR_GLOBAL CONSTANT + PERSISTENT' ($d['status'] -eq 'ok' -and $d['headerKeyword'] -eq 'VAR_GLOBAL' -and @($d['varBlocks']).Count -eq 2) ($d | ConvertTo-Json -Depth 3 -Compress)
$d = Decl "VAR_CONFIG`n    MAIN.fb.bIn AT %IX1.0 : BOOL;`nEND_VAR"
Check 'VAR_CONFIG with an instance path' ($d['status'] -eq 'ok' -and @(@($d['varBlocks'])[0]['vars'])[0]['names'][0] -eq 'MAIN.fb.bIn') ($d | ConvertTo-Json -Depth 4 -Compress)
$d = Decl "FUNCTION_BLOCK FB_C // 馬達控制`nVAR`n    {warning 'check'}`n    x : INT; (* 註解 *)`nEND_VAR"
Check 'Chinese comments and a message pragma in a declaration' ($d['status'] -eq 'ok' -and $d['name'] -eq 'FB_C') ($d | ConvertTo-Json -Depth 3 -Compress)

StatusCheck 'VAR without END_VAR -> LINT-PARSE-003' (Decl "FUNCTION_BLOCK FB_X`nVAR`n    x : INT;`n") 'parse-failed' 'LINT-PARSE-003'
StatusCheck 'second VAR before END_VAR -> LINT-PARSE-003' (Decl "PROGRAM P`nVAR`n    x : INT;`nVAR_INPUT`n    y : INT;`nEND_VAR") 'parse-failed' 'LINT-PARSE-003'
StatusCheck 'TYPE without END_TYPE -> LINT-PARSE-003' (Decl "TYPE ST_X :`nSTRUCT`n    a : INT;`nEND_STRUCT") 'parse-failed' 'LINT-PARSE-003'
StatusCheck 'B2 missing semicolon -> unsupported (incomplete), not a silent downgrade' (Decl "PROGRAM P`nVAR`n    x : INT`nEND_VAR") 'unsupported' 'unsupported-syntax:missing-semicolon'
$d = Decl "METHOD M : BOOL;`nVAR_INPUT n : INT; END_VAR"
Check 'nit: METHOD M : BOOL; -> returnType BOOL' ($d['status'] -eq 'ok' -and $d['returnType'] -eq 'BOOL') ($d | ConvertTo-Json -Depth 2 -Compress)
$d = Decl "PUBLIC`nVAR`nEND_VAR"
Check 'B1 property accessor declaration (as XAE writes it) parses' ($d['status'] -eq 'ok' -and $d['headerKeyword'] -eq 'ACCESSOR' -and (@($d['modifiers']) -join ',') -eq 'PUBLIC' -and $d['headerKnown']) ($d | ConvertTo-Json -Depth 2 -Compress)
$d = Decl "PROGRAM MAIN`n{IF defined (SIM)}`nVAR x : INT; END_VAR`n{ELSE}`nVAR x : INT;`n{END_IF}"
Check 'conditional pragma in the declaration: not analysed, header still known' ($d['status'] -eq 'not-analyzed' -and $d['reason'] -eq 'conditional-pragma' -and $d['headerKnown'] -and $d['name'] -eq 'MAIN') ($d | ConvertTo-Json -Depth 2 -Compress)
$d = Decl "{IF defined (SIM)}`nPROGRAM MAIN`n{END_IF}`nVAR x : INT; END_VAR"
Check 'conditional pragma before the header: header unknown' ($d['status'] -eq 'not-analyzed' -and -not $d['headerKnown']) ($d | ConvertTo-Json -Depth 2 -Compress)
$d = Decl ''
Check 'empty declaration (Action): ok, header empty' ($d['status'] -eq 'ok' -and $d['headerKeyword'] -eq '' -and $d['headerKnown']) ($d | ConvertTo-Json -Depth 2 -Compress)

"failed: $fail"
exit $fail
