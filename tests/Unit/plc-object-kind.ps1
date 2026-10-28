# Unit: PLC object kind, Get/Write-TcPouCode semantics, New-TcPlcObject and Add-TcPou / Add-TcDut
# (issues #17 / #22), no IDE needed. A mock ITcSysManager (PSCustomObject + ScriptMethod
# LookupTreeItem) replaces $script:TcSysManager; tree items are PSCustomObjects with ItemType /
# DeclarationText / Language. $global:MockMode makes CreateChild misbehave for the failure paths.
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Unit/plc-object-kind.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
# Write / Add record BUILD_REQUIRED code-changed (#65): never into the real %TEMP% state file
$env:TCAUTO_STATE_DIR = Join-Path $env:TEMP ("tcauto-unit-state-{0}" -f [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 400) { $Detail = $Detail.Substring(0, 400) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}

$P = 'TIPC^plc^plc Project'
$global:MockTree = @{}
$global:MockCreateCalls = @()
$global:MockMode = 'normal'   # normal | noregister | wrongtype | tamper | badreturn
# ChildCount / Child(i) computed from $global:MockTree (direct children by path), for the name-conflict walk
function Add-MockNav($o) {
    $o | Add-Member -Force -MemberType ScriptProperty -Name ChildCount -Value {
        $pre = "$($this.PathName)^"
        @($global:MockTree.Keys | Where-Object { $_.StartsWith($pre) -and -not $_.Substring($pre.Length).Contains('^') }).Count
    }
    $o | Add-Member -Force -MemberType ScriptMethod -Name Child -Value {
        param($i)
        $pre = "$($this.PathName)^"
        $keys = @($global:MockTree.Keys | Where-Object { $_.StartsWith($pre) -and -not $_.Substring($pre.Length).Contains('^') } | Sort-Object)
        $global:MockTree[$keys[$i - 1]]
    }
}
function New-MockItem([string]$Path, [int]$ItemType, $Decl, [switch]$Impl, [switch]$Folder, $Language = $null) {
    $o = [PSCustomObject]@{ PathName = $Path; Name = ($Path -split '\^')[-1]; ItemType = $ItemType; ItemSubType = 0; ItemSubTypeName = "TYPE_$ItemType"; DeclarationText = $Decl; Language = $Language }
    if ($Impl) { $o | Add-Member -NotePropertyName ImplementationText -NotePropertyValue '' }
    if ($Folder) {
        $o | Add-Member -MemberType ScriptMethod -Name CreateChild -Value {
            param($name, $subType, $before, $vInfo)
            $global:MockCreateCalls += , @($name, $subType, $vInfo)
            if ($subType -eq 610) { throw "Creating the child type 'TREEITEMTYPE_PLCITFMETH' is not possible on parent node type 'TREEITEMTYPE_PLCFOLDER'" }
            $lang = $null
            if ($subType -in 602, 603, 604) { $lang = if ($vInfo -is [array]) { [int]$vInfo[0] } else { [int]$vInfo } }
            $ret = $null; if ($subType -eq 603) { $ret = if ($global:MockMode -eq 'badreturn') { 'BOOL' } else { $vInfo[1] } }
            $header = switch ($subType) { 603 { "FUNCTION $name :$ret`nVAR_INPUT`nEND_VAR" } 604 { "FUNCTION_BLOCK $name" } 602 { "PROGRAM $name" } default { 'default' } }
            $type = if ($global:MockMode -eq 'wrongtype') { 610 } else { $subType }
            $child = [PSCustomObject]@{ PathName = "$($this.PathName)^$name"; Name = $name; ItemType = $type; ItemSubType = 0; ItemSubTypeName = ''; Language = $lang; Stored = $header }
            # tamper: the declaration written is not what reads back
            $child | Add-Member -MemberType ScriptProperty -Name DeclarationText -Value { $this.Stored } -SecondValue {
                param($v) if ($global:MockMode -eq 'tamper') { $this.Stored = "$v`n(* changed *)" } else { $this.Stored = $v }
            }
            Add-MockNav $child
            if ($global:MockMode -ne 'noregister') { $global:MockTree["$($this.PathName)^$name"] = $child }
            $child
        }
    }
    Add-MockNav $o
    $global:MockTree[$Path] = $o
    $o
}
# TIPC^plc and the project node, so Resolve-TcPlcProjectPath works on the mock
$tipc = [PSCustomObject]@{ PathName = 'TIPC'; Name = 'TIPC'; ItemType = 0; ChildCount = 1 }
$tipc | Add-Member -MemberType ScriptMethod -Name Child -Value { param($i) [PSCustomObject]@{ Name = 'plc'; PathName = 'TIPC^plc'; ChildCount = 0 } }
$global:MockTree['TIPC'] = $tipc
$null = New-MockItem $P 601 ''
$null = New-MockItem "$P^POUs" 601 '' -Folder
$null = New-MockItem "$P^DUTs" 601 '' -Folder
$null = New-MockItem "$P^POUs^MAIN" 602 'PROGRAM MAIN' -Impl -Language 1
$null = New-MockItem "$P^DUTs^ST_X" 606 "TYPE ST_X :`nSTRUCT`nEND_STRUCT`nEND_TYPE"
$null = New-MockItem "$P^GVLs^GVL_X" 615 "VAR_GLOBAL`nEND_VAR"
$null = New-MockItem "$P^POUs^I_X" 618 'INTERFACE I_X'
$null = New-MockItem "$P^GVLs" 601 '' -Folder
$null = New-MockItem "$P^POUs^FB_P" 604 'FUNCTION_BLOCK FB_P' -Impl -Language 1
$null = New-MockItem "$P^POUs^FB_P^P_Val" 611 'PROPERTY P_Val : INT'
$null = New-MockItem "$P^POUs^FB_P^M_Same" 609 'METHOD M_Same' -Impl -Language 1   # method name, not a conflict
$null = New-MockItem "$P^POUs^Sub" 601 ''                                          # nested folder
$null = New-MockItem "$P^POUs^Sub^ST_DEEP" 606 'TYPE ST_DEEP : STRUCT END_STRUCT END_TYPE'
$null = New-MockItem "$P^POUs^P_NODECL" 602 $null -Impl -Language 1                 # declaration reads null
$null = New-MockItem "$P^POUs^ITFP" 612 'PROPERTY ITFP : INT'                        # 612: not measured
# second PLC: names are checked per PLC project
$P2 = 'TIPC^plc2^plc2 Project'
$null = New-MockItem $P2 601 ''
$null = New-MockItem "$P2^POUs" 601 '' -Folder
$null = New-MockItem "$P2^GVLs" 601 '' -Folder
$null = New-MockItem "$P2^GVLs^GVL_P2" 615 "VAR_GLOBAL`nEND_VAR"
$null = New-MockItem "$P^POUs^ST_ONLY1" 606 'TYPE ST_ONLY1 : STRUCT END_STRUCT END_TYPE'
$null = New-MockItem "$P^POUs^ST_DUP" 606 'TYPE ST_DUP : STRUCT END_STRUCT END_TYPE'
$null = New-MockItem "$P^POUs^X_UNK" 9999 'X'                      # unknown kind, no implementation
$null = New-MockItem "$P^POUs^Y_UNK" 9998 'Y' -Impl                # unknown kind with implementation
$null = New-MockItem "$P^POUs^FB_LD" 604 'FUNCTION_BLOCK FB_LD' -Language 6
$ldItem = $global:MockTree["$P^POUs^FB_LD"]
$ldItem | Add-Member -MemberType ScriptProperty -Name ImplementationText -Value { $null }   # not readable as text
# a .NET item whose ImplementationText getter throws (PowerShell swallows exceptions of ScriptProperty getters)
Add-Type -TypeDefinition @'
public class TcUnitThrowingPou {
    public string PathName { get { return "x"; } }
    public string Name { get { return "FB_BAD"; } }
    public int ItemType { get { return 604; } }
    public string ItemSubTypeName { get { return "TREEITEMTYPE_PLCPOUFB"; } }
    public object Language { get { return 1; } }
    public string DeclarationText { get { return "FUNCTION_BLOCK FB_BAD"; } set { } }
    public string ImplementationText { get { throw new System.Runtime.InteropServices.COMException("read failed (mock)", unchecked((int)0x80004005)); } set { } }
}
'@
$global:MockTree["$P^POUs^FB_BAD"] = New-Object TcUnitThrowingPou

$sm = [PSCustomObject]@{}
$sm | Add-Member -MemberType ScriptMethod -Name LookupTreeItem -Value {
    param($path)
    if (-not $global:MockTree.ContainsKey($path)) { throw "Item not found: $path" }
    $global:MockTree[$path]
}
& $mod { param($s) $script:TcIdeProcessId = $null; $script:TcIdeConnected = $true; $script:TcDte = [PSCustomObject]@{}; $script:TcSysManager = $s; $script:TcSolutionPath = 'C:\Demo\Unit.sln' } $sm
# #76: the project file save after Add-* is covered by tests/Unit/project-save.ps1; stubbed here (no .tsproj on disk)
& $mod { function script:Invoke-TcPlcObjectSave { [CmdletBinding()] param([string]$ObjectPath, [string]$ExpectFile, [string]$ExpectLibrary, [string]$What) @{ Saved = [PSCustomObject]@{ plcproj = 'mock.plcproj'; verifiedFiles = @($ExpectFile) }; Error = $null } } }
# #65: the BUILD_REQUIRED entry of the mock solution (code-changed reason) and a reset of it
function Get-CodeChanged { & $mod { $e = Get-TcBuildRequired; if ($null -eq $e) { return $null }; (Get-TcBuildRequiredReasons $e)['code-changed'] } }
function Reset-BuildRequired { & $mod { $null = Clear-TcBuildRequired } }

# --- Get-TcPlcObjectKind
$k = & $mod { Get-TcPlcObjectKind -ItemType 604 }
Check 'kind 604' ($k.ObjectKind -eq 'POU' -and $k.PouType -eq 'FunctionBlock' -and $k.HasImplementation -eq $true) ($k | ConvertTo-Json -Compress)
foreach ($t in @(@(605, 'DUT', 'Enum'), @(606, 'DUT', 'Struct'), @(607, 'DUT', 'Union'), @(623, 'DUT', 'Alias'), @(615, 'GVL', $null), @(618, 'ITF', $null), @(611, 'PROPERTY', $null))) {
    $k = & $mod { param($n) Get-TcPlcObjectKind -ItemType $n } $t[0]
    Check "kind $($t[0])" ($k.ObjectKind -eq $t[1] -and $k.PouType -eq $t[2] -and $k.HasImplementation -eq $false) ($k | ConvertTo-Json -Compress)
}
foreach ($n in 612, 613, 614, 616) {
    $k = & $mod { param($x) Get-TcPlcObjectKind -ItemType $x } $n
    Check "kind $n (not measured) -> HasImplementation null" ($null -eq $k.HasImplementation -and $k.ObjectKind -ne 'UNKNOWN') ($k | ConvertTo-Json -Compress)
}
$k = & $mod { Get-TcPlcObjectKind -ItemType 9999 }
Check 'kind unknown' ($k.ObjectKind -eq 'UNKNOWN' -and $null -eq $k.HasImplementation) ($k | ConvertTo-Json -Compress)
$names = & $mod { @(ConvertTo-TcIecLanguageName -Value 1; ConvertTo-TcIecLanguageName -Value 6; ConvertTo-TcIecLanguageName -Value 4; ConvertTo-TcIecLanguageName -Value $null) }
Check 'language names 1/6/4/null' ($names[0] -eq 'ST' -and $names[1] -eq 'LD' -and $names[2] -eq 'FBD' -and $null -eq $names[3]) ($names -join ',')

# --- Get-TcPouCode
$r = Get-TcPouCode -PouName MAIN -PouPath "$P^POUs^MAIN"
Check 'Get POU' ($r.success -and $r.data.objectKind -eq 'POU' -and $r.data.hasImplementation -eq $true -and $r.data.implementation -eq '' -and $r.data.implementationReadable -eq $true -and $r.data.language -eq 'ST') ($r | ConvertTo-Json -Compress)
$r = Get-TcPouCode -PouName ST_X -PouPath "$P^DUTs^ST_X"
Check 'Get DUT' ($r.success -and $r.data.objectKind -eq 'DUT' -and $r.data.pouType -eq 'Struct' -and $r.data.hasImplementation -eq $false -and $null -eq $r.data.implementation -and $null -eq $r.data.implementationReadable -and $r.data.declaration -like 'TYPE ST_X*') ($r | ConvertTo-Json -Compress)
$r = Get-TcPouCode -PouName GVL_X -PouPath "$P^GVLs^GVL_X"
Check 'Get GVL' ($r.success -and $r.data.objectKind -eq 'GVL' -and $r.data.hasImplementation -eq $false) ($r | ConvertTo-Json -Compress)
$r = Get-TcPouCode -PouName FB_LD -PouPath "$P^POUs^FB_LD"
Check 'Get POU, implementation not text -> implementationReadable false' ($r.success -and $r.data.hasImplementation -eq $true -and $r.data.implementationReadable -eq $false -and $r.data.language -eq 'LD') ($r | ConvertTo-Json -Compress)
$r = Get-TcPouCode -PouName FB_BAD -PouPath "$P^POUs^FB_BAD"
# PowerShell 5.1 returned $null for the throwing .NET getter (measured 2026-10-25, PS 5.1.26100), so the
# failure shows as implementationReadable=false with implementation null, never ''.
$okNull = $r.success -and $r.data.implementationReadable -eq $false -and $null -eq $r.data.implementation
Check 'Get POU, ImplementationText getter throws -> implementationReadable false' $okNull ($r | ConvertTo-Json -Compress)
$r = Get-TcPouCode -PouName P_NODECL -PouPath "$P^POUs^P_NODECL"
Check 'Get POU, declaration reads null -> POU_READ_FAILED' ((-not $r.success) -and $r.error.code -eq 'POU_READ_FAILED' -and $r.error.hint) ($r | ConvertTo-Json -Compress)
$r = Get-TcPouCode -PouName ITFP -PouPath "$P^POUs^ITFP"
Check 'Get 612 (not measured): probed, no implementation -> hasImplementation false, implementationReadable null' ($r.success -and $r.data.hasImplementation -eq $false -and $null -eq $r.data.implementationReadable) ($r | ConvertTo-Json -Compress)
$r = Get-TcPouCode -PouName X_UNK -PouPath "$P^POUs^X_UNK"
Check 'Get UNKNOWN without implementation' ($r.success -and $r.data.objectKind -eq 'UNKNOWN' -and $r.data.hasImplementation -eq $false) ($r | ConvertTo-Json -Compress)

# --- Write-TcPouCode
$before = $global:MockTree["$P^DUTs^ST_X"].DeclarationText
$r = Write-TcPouCode -PouName ST_X -PouPath "$P^DUTs^ST_X" -Declaration "TYPE ST_X :`nSTRUCT`n a : INT;`nEND_STRUCT`nEND_TYPE" -Implementation 'x := 1;'
Check 'Write DUT impl -> INVALID_PARAMS' ((-not $r.success) -and $r.error.code -eq 'INVALID_PARAMS' -and $r.error.hint -and $r.data.objectKind -eq 'DUT') ($r | ConvertTo-Json -Compress)
Check 'Write DUT impl writes nothing' ($global:MockTree["$P^DUTs^ST_X"].DeclarationText -eq $before) ''
$r = Write-TcPouCode -PouName GVL_X -PouPath "$P^GVLs^GVL_X" -Implementation 'x := 1;'
Check 'Write GVL impl -> INVALID_PARAMS' ((-not $r.success) -and $r.error.code -eq 'INVALID_PARAMS') ($r | ConvertTo-Json -Compress)
$r = Write-TcPouCode -PouName P_Val -PouPath "$P^POUs^FB_P^P_Val" -Implementation 'P_Val := 1;'
Check 'Write PROPERTY impl -> INVALID_PARAMS, hint names ^Get' ((-not $r.success) -and $r.error.code -eq 'INVALID_PARAMS' -and $r.error.hint -like '*P_Val^Get*') ($r | ConvertTo-Json -Compress)
$beforeX = $global:MockTree["$P^POUs^X_UNK"].DeclarationText
$r = Write-TcPouCode -PouName X_UNK -PouPath "$P^POUs^X_UNK" -Declaration 'NEW' -Implementation 'x := 1;'
Check 'Write UNKNOWN without implementation -> INVALID_PARAMS, nothing written' ((-not $r.success) -and $r.error.code -eq 'INVALID_PARAMS' -and $global:MockTree["$P^POUs^X_UNK"].DeclarationText -eq $beforeX) ($r | ConvertTo-Json -Compress)
$r = Write-TcPouCode -PouName Y_UNK -PouPath "$P^POUs^Y_UNK" -Implementation 'y := 1;'
Check 'Write UNKNOWN with implementation' ($r.success -and $global:MockTree["$P^POUs^Y_UNK"].ImplementationText -eq 'y := 1;') ($r | ConvertTo-Json -Compress)
$r = Write-TcPouCode -PouName ST_X -PouPath "$P^DUTs^ST_X" -Declaration "TYPE ST_X :`nSTRUCT`n a : INT;`nEND_STRUCT`nEND_TYPE"
Check 'Write DUT decl' ($r.success -and $r.data.objectKind -eq 'DUT' -and @($r.data.updated) -contains 'declaration') ($r | ConvertTo-Json -Compress)
$r = Write-TcPouCode -PouName MAIN -PouPath "$P^POUs^MAIN" -Implementation 'n := n + 1;'
Check 'Write POU impl' ($r.success -and @($r.data.updated) -contains 'implementation' -and $global:MockTree["$P^POUs^MAIN"].ImplementationText -eq 'n := n + 1;') ($r | ConvertTo-Json -Compress)

# --- #65: Write-TcPouCode records BUILD_REQUIRED code-changed (only when something was written)
Reset-BuildRequired
$r = Write-TcPouCode -PouName GVL_X -PouPath "$P^GVLs^GVL_X" -Implementation 'x := 1;'
Check '#65 INVALID_PARAMS (nothing written) -> nothing recorded' ((-not $r.success) -and $null -eq (Get-CodeChanged) -and $null -eq $r.data.PSObject.Properties['buildRequired']) ($r | ConvertTo-Json -Compress)
$r = Write-TcPouCode -PouName MAIN -PouPath "$P^POUs^MAIN"
Check '#65 neither text given -> success, nothing recorded' ($r.success -and $null -eq (Get-CodeChanged) -and $null -eq $r.data.PSObject.Properties['buildRequired']) ($r | ConvertTo-Json -Compress)
$r = Write-TcPouCode -PouName MAIN -PouPath "$P^POUs^MAIN" -Implementation 'n := n + 2;'
Check '#65 Write success -> data.buildRequired names cmdlet + POU, no stateWarning' ($r.success -and $r.data.buildRequired -eq 'PLC code changed by Write-TcPouCode MAIN [implementation]' -and $null -eq $r.data.PSObject.Properties['stateWarning']) ($r | ConvertTo-Json -Compress)
$r = Write-TcPouCode -PouName ST_X -PouPath "$P^DUTs^ST_X" -Declaration "TYPE ST_X :`nSTRUCT`n b : INT;`nEND_STRUCT`nEND_TYPE"
$cc = Get-CodeChanged
Check '#65 second write: both changes listed in the entry' ($cc -eq 'PLC code changed by Write-TcPouCode MAIN [implementation] | Write-TcPouCode ST_X [declaration]') "$cc"
$null = New-MockItem "$P^POUs^FB_RO" 604 'FUNCTION_BLOCK FB_RO' -Language 1
$global:MockTree["$P^POUs^FB_RO"] | Add-Member -MemberType ScriptProperty -Name ImplementationText -Value { '' } -SecondValue { param($v) throw 'write rejected (mock)' }
Reset-BuildRequired
$r = Write-TcPouCode -PouName FB_RO -PouPath "$P^POUs^FB_RO" -Implementation 'x := 1;'
Check '#65 setter throws -> failure, still recorded (conservative)' ((-not $r.success) -and $r.data.buildRequired -eq 'PLC code changed by Write-TcPouCode FB_RO [write failed]' -and (Get-CodeChanged) -like '*FB_RO*') ($r | ConvertTo-Json -Compress)
$r = Write-TcPouCode -PouName FB_RO -PouPath "$P^POUs^FB_RO" -Declaration 'FUNCTION_BLOCK FB_RO' -Implementation 'x := 2;'
Check '#65 declaration written, implementation setter throws -> [declaration+write failed]' ((-not $r.success) -and $r.data.buildRequired -eq 'PLC code changed by Write-TcPouCode FB_RO [declaration+write failed]') ($r | ConvertTo-Json -Compress)
Reset-BuildRequired

# --- New-TcPlcObject
function New-Obj([string]$Folder, [string]$Name, [int]$Sub, $VInfo = $null, [string]$Decl, [string]$Lang) {
    & $mod { param($s, $p, $n, $t, $v, $d, $l) New-TcPlcObject -SysManager $s -ParentPath $p -Name $n -SubType $t -VInfo $v -Declaration $d -ExpectedLanguage $l } $sm "$P^$Folder" $Name $Sub $VInfo $Decl $Lang
}
function Get-Err([scriptblock]$Sb) { try { & $Sb | Out-Null; $null } catch { $_.Exception.Message } }
$c = New-Obj POUs FB_N 604 1 -Lang ST
$call = $global:MockCreateCalls[-1]
Check 'create FB: subtype 604, vInfo 1, language ST read back' ($c.Path -eq "$P^POUs^FB_N" -and $c.ItemType -eq 604 -and $c.Language -eq 'ST' -and $call[1] -eq 604 -and $call[2] -eq 1) ($call | ConvertTo-Json -Compress)
$c = New-Obj DUTs ST_N 606 -Decl "TYPE ST_N :`r`nSTRUCT`r`nEND_STRUCT`r`nEND_TYPE"
Check 'create DUT: declaration written + read back, no vInfo' ($c.ItemType -eq 606 -and $c.Declaration -like 'TYPE ST_N*' -and $null -eq $global:MockCreateCalls[-1][2]) ''
$e = Get-Err { New-Obj DUTs ST_X 606 }
Check 'create existing (same folder) -> exists' ($e -like 'exists:*ST_X*') $e
$e = Get-Err { New-Obj DUTs ST_DUP 606 }
Check 'create existing (other folder) -> exists with its path' ($e -like "exists:*$P^POUs^ST_DUP*") $e
$e = Get-Err { New-Obj DUTs ST_DEEP 606 }
Check 'create existing in a nested folder -> exists' ($e -like "exists:*POUs^Sub^ST_DEEP*") $e
$c = New-Obj DUTs M_Same 606
Check 'same name as a method -> no conflict' ($c.Path -eq "$P^DUTs^M_Same" -and $c.DuplicateCheckScope -eq 'project') ($c.DuplicateCheckScope)
$c = & $mod { param($s, $p) New-TcPlcObject -SysManager $s -ParentPath "$p^POUs" -Name ST_ONLY1 -SubType 606 } $sm $P2
Check 'second PLC: a name only in PLC 1 is allowed' ($c.Path -eq "$P2^POUs^ST_ONLY1") ($c.Path)
$e = Get-Err { & $mod { param($s, $p) New-TcPlcObject -SysManager $s -ParentPath "$p^POUs" -Name GVL_P2 -SubType 606 } $sm $P2 }
Check 'second PLC: same name in another folder of PLC 2 -> exists' ($e -like "exists:*plc2 Project^GVLs^GVL_P2*") $e
$c = & $mod { param($s, $p) New-TcPlcObject -SysManager $s -ParentPath "$p^DUTs" -Name ST_LIM -SubType 606 -MaxNodes 2 } $sm $P
Check 'node limit -> DuplicateCheckScope folder' ($c.DuplicateCheckScope -eq 'folder' -and $c.Path -eq "$P^DUTs^ST_LIM") ($c.DuplicateCheckScope)
$e = Get-Err { New-Obj DUTs ST_Y 610 }
Check 'CreateChild error passed on' ($e -like '*TREEITEMTYPE_PLCITFMETH*') $e
$global:MockMode = 'noregister'
$e = Get-Err { New-Obj DUTs ST_L 606 }
Check 'not found after CreateChild -> lookup:' ($e -like 'lookup:*Get-TcProjectTree*') $e
$global:MockMode = 'wrongtype'
$e = Get-Err { New-Obj DUTs ST_K 606 }
Check 'wrong ItemType -> kind: + object stays' ($e -like 'kind:*ItemType 610*stays in the tree*') $e
$global:MockMode = 'tamper'
$e = Get-Err { New-Obj DUTs ST_D 606 -Decl "TYPE ST_D :`nSTRUCT`nEND_STRUCT`nEND_TYPE" }
Check 'declaration reads back different -> declare: + object stays' ($e -like 'declare:*reads back different*stays in the tree*') $e
$global:MockMode = 'normal'
$e = Get-Err { New-Obj POUs FB_W 604 6 -Lang ST }
Check 'language read back differs -> language:' ($e -like "language:*'LD'*expected 'ST'*") $e

# --- Add-TcPou / Add-TcDut: the vInfo they pass
$r = Add-TcPou -Name F_A -Type Function -ReturnType INT -PlcProjectPath "$P^POUs"
$call = $global:MockCreateCalls[-1]
Check 'Add-TcPou Function: subtype 603, vInfo @(1, INT)' ($r.success -and $call[1] -eq 603 -and $call[2].Count -eq 2 -and [string]$call[2][0] -eq '1' -and [string]$call[2][1] -eq 'INT' -and $r.data.language -eq 'ST') (($call | ConvertTo-Json -Compress) + ' ' + ($r | ConvertTo-Json -Compress))
$r = Add-TcPou -Name F_B -Type Function -ReturnType INT -PlcProjectPath "$P^POUs"
Check 'Add-TcPou F_B created' $r.success ($r | ConvertTo-Json -Compress)
$r = Add-TcPou -Name FB_A -Type FunctionBlock -PlcProjectPath "$P^POUs"
Check 'Add-TcPou FB: subtype 604, vInfo 1' ($r.success -and $global:MockCreateCalls[-1][1] -eq 604 -and $global:MockCreateCalls[-1][2] -eq 1 -and $r.data.itemType -eq 604) ($r | ConvertTo-Json -Compress)
$r = Add-TcDut -Name A_A -DutType Alias -AliasType DINT
$call = $global:MockCreateCalls[-1]
Check 'Add-TcDut Alias: subtype 623, vInfo DINT' ($r.success -and $call[1] -eq 623 -and $call[2] -eq 'DINT' -and $r.data.declaration -like '*DINT*') (($call | ConvertTo-Json -Compress) + ' ' + ($r | ConvertTo-Json -Compress))
$r = Add-TcDut -Name ST_A -DutType Struct -Fields @{ nA = 'INT' }
Check 'Add-TcDut Struct: subtype 606, no vInfo' ($r.success -and $global:MockCreateCalls[-1][1] -eq 606 -and $null -eq $global:MockCreateCalls[-1][2]) ($r | ConvertTo-Json -Compress)
$global:MockMode = 'tamper'
$r = Add-TcDut -Name ST_T -DutType Struct
Check 'Add-TcDut declare failure -> DUT_CREATE_FAILED + hint' ((-not $r.success) -and $r.error.code -eq 'DUT_CREATE_FAILED' -and $r.error.message -like '*declare:*' -and $r.error.hint) ($r | ConvertTo-Json -Compress)
Check '#65 Add-TcDut failure after CreateChild (declare) -> recorded' ($r.data.buildRequired -eq 'PLC code changed by Add-TcDut ST_T [failed after CreateChild]') ($r | ConvertTo-Json -Compress)
$global:MockMode = 'normal'
$cc = Get-CodeChanged
Check '#65 Add-TcPou / Add-TcDut successes recorded' ($cc -like '*Add-TcPou F_A*' -and $cc -like '*Add-TcPou FB_A*' -and $cc -like '*Add-TcDut A_A*' -and $cc -like '*Add-TcDut ST_A*') "$cc"
$r = Add-TcGvl -Name GVL_N
Check '#65 Add-TcGvl success -> data.buildRequired' ($r.success -and $r.data.buildRequired -eq 'PLC code changed by Add-TcGvl GVL_N') ($r | ConvertTo-Json -Compress)
Reset-BuildRequired
$r = Add-TcPou -Name FB_A -Type FunctionBlock -PlcProjectPath "$P^POUs"
Check 'Add-TcPou existing -> POU_CREATE_FAILED exists' ((-not $r.success) -and $r.error.code -eq 'POU_CREATE_FAILED' -and $r.error.message -like '*exists:*') ($r | ConvertTo-Json -Compress)
Check '#65 Add-TcPou exists (before CreateChild) -> nothing recorded' ($null -eq (Get-CodeChanged)) "$(Get-CodeChanged)"

# --- name check: PLC called "Machine Project", path without a Project node, node limit, RPC busy
$PM = 'TIPC^Machine Project^Machine Project Project'
$null = New-MockItem $PM 601 ''
$null = New-MockItem "$PM^POUs" 601 '' -Folder
$null = New-MockItem "$PM^GVLs" 601 '' -Folder
$null = New-MockItem "$PM^GVLs^GVL_M" 615 "VAR_GLOBAL`nEND_VAR"
$e = Get-Err { & $mod { param($s, $p) New-TcPlcObject -SysManager $s -ParentPath "$p^POUs" -Name GVL_M -SubType 606 } $sm $PM }
Check 'PLC named "Machine Project": project node found, same name in GVLs -> exists' ($e -like "exists:*Machine Project Project^GVLs^GVL_M*") $e
$r = & $mod { param($s, $p) Find-TcPlcNameConflict -SysManager $s -ParentPath "$p^POUs" -Name 'NOPE' } $sm $PM
Check 'PLC named "Machine Project": walks <Plc> Project, scope project' ($r.Scope -eq 'project' -and $r.ProjectPath -eq $PM -and $r.Visited -ge 3) ($r | ConvertTo-Json -Compress)
$null = New-MockItem 'TIPC^Other^POUs' 601 '' -Folder
$c = & $mod { param($s) New-TcPlcObject -SysManager $s -ParentPath 'TIPC^Other^POUs' -Name ST_O -SubType 606 } $sm
Check 'path without a <Plc> Project node -> DuplicateCheckScope folder + note' ($c.DuplicateCheckScope -eq 'folder' -and $c.DuplicateCheckNote -and $c.Path -eq 'TIPC^Other^POUs^ST_O') ($c.DuplicateCheckNote)
$P3 = 'TIPC^p3^p3 Project'
$null = New-MockItem $P3 601 ''
$null = New-MockItem "$P3^POUs" 601 '' -Folder
foreach ($n in 'A1', 'B_HIT', 'C1', 'C2', 'C3') { $null = New-MockItem "$P3^POUs^$n" 606 'TYPE x END_TYPE' }
$r = & $mod { param($s, $p) Find-TcPlcNameConflict -SysManager $s -ParentPath "$p^POUs" -Name 'B_HIT' -MaxNodes 3 -WarningAction SilentlyContinue } $sm $P3
Check 'node limit: hits found before the limit are kept, scope folder + note' ($r.Scope -eq 'folder' -and @($r.Hits) -contains "$P3^POUs^B_HIT" -and $r.Note) ($r | ConvertTo-Json -Compress)
$e = Get-Err { & $mod { param($s, $p) New-TcPlcObject -SysManager $s -ParentPath "$p^POUs" -Name B_HIT -SubType 606 -MaxNodes 3 -WarningAction SilentlyContinue } $sm $P3 }
Check 'node limit: a hit still blocks (exists)' ($e -like 'exists:*B_HIT*') $e
$P4 = 'TIPC^p4^p4 Project'
$null = New-MockItem $P4 601 ''
$null = New-MockItem "$P4^POUs" 601 '' -Folder
$null = New-MockItem "$P4^POUs^Z1" 606 'TYPE x END_TYPE'
$p4f = $global:MockTree["$P4^POUs"]
$p4f | Add-Member -Force -MemberType ScriptMethod -Name Child -Value { param($i) throw 'item read failed (mock)' }
$r = & $mod { param($s, $p) Find-TcPlcNameConflict -SysManager $s -ParentPath "$p^POUs" -Name 'Z1' } $sm $P4
Check 'unreadable node -> counted in Skipped (fail-open)' ($r.Scope -eq 'project' -and $r.Skipped -ge 1 -and @($r.Hits).Count -eq 0) ($r | ConvertTo-Json -Compress)
$p4f | Add-Member -Force -MemberType ScriptMethod -Name Child -Value { param($i) throw 'Call was rejected by callee. (Exception from HRESULT: 0x80010001 (RPC_E_CALL_REJECTED))' }
$e = Get-Err { & $mod { param($s, $p) Find-TcPlcNameConflict -SysManager $s -ParentPath "$p^POUs" -Name 'Z1' } $sm $P4 }
Check 'RPC busy inside the walk is not skipped (rethrown / retried)' ($null -ne $e) $e

$global:MockMode = 'badreturn'
$r = Add-TcPou -Name F_BR -Type Function -ReturnType INT -PlcProjectPath "$P^POUs"
Check 'Add-TcPou Function, header has another return type -> POU_CREATE_FAILED declare' ((-not $r.success) -and $r.error.code -eq 'POU_CREATE_FAILED' -and $r.error.message -like '*declare:*does not match*') ($r | ConvertTo-Json -Compress)
$global:MockMode = 'normal'
$r = Add-TcPou -Name FB_OK -Type FunctionBlock -PlcProjectPath "$P^POUs"
Check 'Add-TcPou data has duplicateCheckScope project' ($r.success -and $r.data.duplicateCheckScope -eq 'project' -and $r.data.duplicateCheckSkippedNodes -eq 0) ($r | ConvertTo-Json -Compress)

# modal dialog: CreateChild must not be called
$origDialog = & $mod { ${function:Get-TcIdeModalDialog} }
& $mod { Set-Item -Path function:script:Get-TcIdeModalDialog -Value { @{ Title = 'TcXaeShell'; Text = 'mock dialog'; Kind = 'unknown'; ReloadTarget = $null; Hwnd = 0; Buttons = @() } } }
$calls = $global:MockCreateCalls.Count
$r = Add-TcDut -Name ST_MOD -DutType Struct
Check 'modal dialog -> IDE_MODAL_DIALOG, CreateChild not called' ((-not $r.success) -and $r.error.code -eq 'IDE_MODAL_DIALOG' -and $global:MockCreateCalls.Count -eq $calls -and -not $global:MockTree.ContainsKey("$P^DUTs^ST_MOD")) ($r | ConvertTo-Json -Compress)
& $mod { param($f) Set-Item -Path function:script:Get-TcIdeModalDialog -Value $f } $origDialog
Reset-BuildRequired
$null = & $mod { param($r) Register-TcCodeChange -Result $r -Change 'x' } $null
Check '#65 Register-TcCodeChange with $null result: recorded, returns null' ((Get-CodeChanged) -eq 'PLC code changed by x') "$(Get-CodeChanged)"
Reset-BuildRequired

Remove-Item -LiteralPath $env:TCAUTO_STATE_DIR -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item Env:\TCAUTO_STATE_DIR -ErrorAction SilentlyContinue
"failed: $fail"
exit [Math]::Min($fail, 255)
