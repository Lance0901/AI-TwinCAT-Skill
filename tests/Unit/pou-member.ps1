# Unit: task 3.6 (complete-automation-interface phase 2): Add-TcPouMember, Add-TcInterface, member paths
# in Resolve-TcPouPath (Parent.Member, POU_AMBIGUOUS), Get/Write-TcPouCode on ITF property accessors
# (654 / 655), Write-TcPouCode -Implementation '' and BUILD_REQUIRED only for real writes.
# No IDE / runtime: a mock ITcSysManager with an in-memory tree (as tests/Unit/tree-item-tools.ps1);
# CreateChild of the mock builds the declaration the way XAE did in the probe (verification/phase2-probe.md 3.6).
#   powershell.exe -NoProfile -File tests/Unit/pou-member.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
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
$global:T = @{}
# vInfo as text for the checks: type + elements ("String[]:1|BOOL|PRIVATE", "String:I_Base", "null")
function Format-VInfo($v) {
    if ($null -eq $v) { return 'null' }
    if ($v -is [array]) { return "$($v.GetType().Name):$(@($v) -join '|')" }
    return "$($v.GetType().Name):$v"
}
function New-MockNode([string]$Path, [int]$ItemType, [string]$Decl = $null, $Language = $null) {
    $name = ($Path -split '\^')[-1]
    $n = [PSCustomObject]@{ Name = $name; PathName = $Path; ItemType = $ItemType; ItemSubTypeName = "TYPE_$ItemType"; Kids = [System.Collections.ArrayList]::new(); Decl = $Decl; Impl = ''; Lang = $Language }
    $n | Add-Member ScriptProperty ChildCount { $this.Kids.Count }
    $n | Add-Member ScriptMethod Child { param($i) $global:T.Nodes[$this.Kids[$i - 1]] }
    # every code access is logged: 654 / 655 must never be read (phase2-probe.md: DeclarationText crashed VS2022)
    $n | Add-Member ScriptProperty Language { $global:T.Reads.Add("Language $($this.PathName)") | Out-Null; $this.Lang }
    if ($ItemType -ne 608) {
        $n | Add-Member ScriptProperty DeclarationText { $global:T.Reads.Add("Decl $($this.PathName)") | Out-Null; $this.Decl } {
            param($v)
            $global:T.Writes.Add("Decl $($this.PathName)") | Out-Null
            if ($global:T.SetMode -eq 'throw') { throw 'write rejected (mock)' }
            $this.Decl = $v
        }
    }
    if ($ItemType -in 602, 603, 604, 608, 609, 613, 614) {
        $n | Add-Member ScriptProperty ImplementationText { $global:T.Reads.Add("Impl $($this.PathName)") | Out-Null; $this.Impl } {
            param($v)
            $global:T.Writes.Add("Impl $($this.PathName)=[$v]") | Out-Null
            switch ($global:T.SetMode) {
                'throw' { throw 'write rejected (mock)' }
                'idetimeout' { throw "IDE_TIMEOUT: 'Set ImplementationText' did not return within 120 s (mock)" }
                'ignoreempty' { if ($v -ne '') { $this.Impl = $v } }
                default { $this.Impl = $v }
            }
        }
    }
    $n | Add-Member ScriptMethod CreateChild {
        param($name, $sub, $before, $vInfo)
        $global:T.Creates.Add("$($this.PathName)|$name|$sub|$(Format-VInfo $vInfo)") | Out-Null
        if ($global:T.CreateMode -eq 'loggedin') { throw [System.Runtime.InteropServices.COMException]::new('Cannot add an object because it affects a device you are currently logged into.', -2147467259) }
        $v = @($vInfo)
        $acc = { param($a) if (@('PUBLIC', 'PRIVATE', 'PROTECTED', 'INTERNAL') -contains $a -and $global:T.CreateMode -ne 'publicize') { $a } else { 'PUBLIC' } }
        $lang = $null; $decl = $null
        switch ($sub) {
            609 { if ($null -eq $vInfo) { $lang = 1; $decl = "METHOD $name" } else { $lang = [int]$v[0]; $decl = "METHOD $(& $acc $v[2]) $name : $($v[1])" } }
            611 { $decl = "PROPERTY $(& $acc $v[2]) $name : $($v[1])" }
            { $_ -in 613, 614 } { $lang = [int]$v[0]; $decl = "$(& $acc $v[1])`r`nVAR`r`nEND_VAR" }
            608 { $lang = [int]$v[0] }
            610 { $decl = if ($null -eq $vInfo) { "METHOD $name" } else { "METHOD $name : $($v[0])`r`nVAR_INPUT`r`nEND_VAR" } }
            612 { $decl = "PROPERTY $name : $($v[0])" }
            618 { $decl = if ($null -eq $vInfo) { "INTERFACE $name" } else { "INTERFACE $name EXTENDS $vInfo" } }
            default { $decl = 'X' }
        }
        $c = Add-MockNode "$($this.PathName)^$name" $sub $decl $lang
        Write-Output -NoEnumerate $c
    }
    $n
}
function Add-MockNode([string]$Path, [int]$ItemType, [string]$Decl = $null, $Language = $null) {
    $n = New-MockNode -Path $Path -ItemType $ItemType -Decl $Decl -Language $Language
    $global:T.Nodes[$Path] = $n
    $i = $Path.LastIndexOf('^')
    if ($i -gt 0 -and $global:T.Nodes.ContainsKey($Path.Substring(0, $i))) { $null = $global:T.Nodes[$Path.Substring(0, $i)].Kids.Add($Path) }
    Write-Output -NoEnumerate $n
}
function Reset-Mock {
    $global:T.Nodes = @{}
    $global:T.Creates = [System.Collections.ArrayList]::new()
    $global:T.Reads = [System.Collections.ArrayList]::new()
    $global:T.Writes = [System.Collections.ArrayList]::new()
    $global:T.CreateMode = 'ok'; $global:T.SetMode = 'ok'; $global:T.Dialog = $null
    $null = Add-MockNode 'TIPC' 14
    $null = Add-MockNode $P 600
    $null = Add-MockNode "$P^POUs" 601
    $null = Add-MockNode "$P^POUs^MAIN" 602 'PROGRAM MAIN' 1
    $null = Add-MockNode "$P^POUs^FC_F" 603 'FUNCTION FC_F : BOOL' 1
    foreach ($fb in 'FB_A', 'FB_B') {
        $null = Add-MockNode "$P^POUs^$fb" 604 "FUNCTION_BLOCK $fb" 1
        $null = Add-MockNode "$P^POUs^$fb^M_Run" 609 "METHOD M_Run : BOOL" 1
        $null = Add-MockNode "$P^POUs^$fb^P_Value" 611 "PROPERTY P_Value : INT"
        $null = Add-MockNode "$P^POUs^$fb^P_Value^Get" 613 "PUBLIC`r`nVAR`r`nEND_VAR" 1
    }
    $null = Add-MockNode "$P^POUs^FB_A^A_Old" 608 $null 1
    $null = Add-MockNode "$P^POUs^ITF_X" 618 'INTERFACE ITF_X'
    $null = Add-MockNode "$P^POUs^ITF_X^P_Cnt" 612 'PROPERTY P_Cnt : DINT'
    $null = Add-MockNode "$P^POUs^ITF_X^P_Cnt^Get" 654 'never read'
    $null = Add-MockNode "$P^POUs^ITF_X^P_Cnt^Set" 655 'never read'
    $null = Add-MockNode "$P^POUs^Sub" 601
    $null = Add-MockNode "$P^POUs^Sub^FB_Deep" 604 'FUNCTION_BLOCK FB_Deep' 1
    $null = Add-MockNode "$P^PlcTask" 621
    $null = Add-MockNode "$P^PlcTask^FB_Deep" 650              # task reference with the same name
    $null = Add-MockNode "$P^POUs^v1.2" 601                     # folder name with a dot
    $null = Add-MockNode "$P^POUs^v1.2^FB_V" 604 'FUNCTION_BLOCK FB_V' 1
    $sm = New-Object PSObject
    $sm | Add-Member ScriptMethod LookupTreeItem {
        param($p)
        if (-not $global:T.Nodes.ContainsKey($p)) { throw [System.Runtime.InteropServices.COMException]::new("Item '$p' not found", [int]0x98510001) }
        Write-Output -NoEnumerate $global:T.Nodes[$p]
    }
    $global:T.Sm = $sm
}
Reset-Mock
& $mod {
    $script:TcIdeProcessId = $null; $script:TcIdeConnected = $true; $script:TcSolutionPath = 'C:\Demo\PouMember.sln'
    function script:Assert-TcConnection { }
    function script:Get-TcSysManager { [CmdletBinding()] param([switch]$Refresh) , $global:T.Sm }
    function script:Get-TcIdeModalDialog { [CmdletBinding()] param([int]$ProcessId = 0, [int]$TimeoutSec = 5) $global:T.Dialog }
    function script:Resolve-TcPlcProjectPath { [CmdletBinding()] param($SysManager, [string]$PlcProjectPath) 'TIPC^plc^plc Project' }
    function script:Invoke-TcPlcObjectSave { [CmdletBinding()] param([string]$ObjectPath, [string]$ExpectFile, [string]$ExpectLibrary, [string]$What) @{ Saved = [PSCustomObject]@{ verifiedFiles = @($ExpectFile) }; Error = $null } }
}
function Get-CodeChanged { & $mod { $e = Get-TcBuildRequired; if ($null -eq $e) { return $null }; (Get-TcBuildRequiredReasons $e)['code-changed'] } }
function Reset-BuildRequired { & $mod { $null = Clear-TcBuildRequired } }
function Spec([hashtable]$A) { & $mod { param($a) Get-TcPouMemberSpec @a } $A }
function J($o) { $o | ConvertTo-Json -Depth 5 -Compress }

try {
    # --- vInfo / sub type per Kind (pure)
    $s = Spec @{ Kind = 'Method'; ParentItemType = 604; Name = 'M_X'; ReturnType = 'BOOL'; Access = 'private' }
    Check 'spec method FB: 609, string[] {1, BOOL, PRIVATE}' ($null -eq $s.Error -and $s.SubType -eq 609 -and (Format-VInfo $s.VInfo) -eq 'String[]:1|BOOL|PRIVATE' -and $s.ExpectedLanguage -eq 'ST') (J $s)
    $s = Spec @{ Kind = 'Method'; ParentItemType = 602; Name = 'M_X'; ReturnType = 'INT'; Language = 'LD' }
    Check 'spec method PROGRAM LD: {6, INT, PUBLIC}' ($s.SubType -eq 609 -and (Format-VInfo $s.VInfo) -eq 'String[]:6|INT|PUBLIC' -and $s.ExpectedLanguage -eq 'LD') (J $s)
    $s = Spec @{ Kind = 'Method'; ParentItemType = 604; Name = 'M_X' }
    Check 'spec method without return type: vInfo null' ($null -eq $s.Error -and $null -eq $s.VInfo -and $s.SubType -eq 609) (J $s)
    $s = Spec @{ Kind = 'Method'; ParentItemType = 604; Name = 'M_X'; Access = 'PRIVATE'; AccessGiven = $true }
    Check 'spec method without return type + PRIVATE -> POU_MEMBER_UNSUPPORTED' ($s.Error.Code -eq 'POU_MEMBER_UNSUPPORTED' -and $s.Error.Reason -eq 'method-no-return-type') (J $s.Error)
    $s = Spec @{ Kind = 'Property'; ParentItemType = 604; Name = 'P_X'; ReturnType = 'LREAL'; Access = 'PROTECTED' }
    Check 'spec property: 611 {1, LREAL, PROTECTED}' ($s.SubType -eq 611 -and (Format-VInfo $s.VInfo) -eq 'String[]:1|LREAL|PROTECTED') (J $s)
    $s = Spec @{ Kind = 'Property'; ParentItemType = 604; Name = 'P_X' }
    Check 'spec property without type -> POU_MEMBER_INVALID return-type' ($s.Error.Code -eq 'POU_MEMBER_INVALID' -and $s.Error.Reason -eq 'return-type') (J $s.Error)
    $s = Spec @{ Kind = 'Get'; ParentItemType = 611 }
    Check 'spec Get: 613 {1, PUBLIC}, named Get' ($s.SubType -eq 613 -and (Format-VInfo $s.VInfo) -eq 'String[]:1|PUBLIC' -and $s.ItemName -eq 'Get') (J $s)
    $s = Spec @{ Kind = 'Set'; ParentItemType = 611; Access = 'INTERNAL' }
    Check 'spec Set: 614 {1, INTERNAL}' ($s.SubType -eq 614 -and (Format-VInfo $s.VInfo) -eq 'String[]:1|INTERNAL' -and $s.ItemName -eq 'Set') (J $s)
    $s = Spec @{ Kind = 'Get'; ParentItemType = 611; Name = 'Getter' }
    Check 'spec Get named otherwise -> POU_MEMBER_INVALID name' ($s.Error.Code -eq 'POU_MEMBER_INVALID' -and $s.Error.Reason -eq 'name') (J $s.Error)
    $s = Spec @{ Kind = 'Action'; ParentItemType = 604; Name = 'A_X' }
    Check 'spec action: 608 {1}, no declaration' ($s.SubType -eq 608 -and (Format-VInfo $s.VInfo) -eq 'String[]:1' -and $s.NoDeclaration) (J $s)
    $s = Spec @{ Kind = 'Action'; ParentItemType = 604; Name = 'A_X'; ReturnType = 'BOOL' }
    Check 'spec action with return type -> POU_MEMBER_INVALID' ($s.Error.Code -eq 'POU_MEMBER_INVALID' -and $s.Error.Reason -eq 'return-type') (J $s.Error)
    $s = Spec @{ Kind = 'Method'; ParentItemType = 618; Name = 'M_I'; ReturnType = 'DINT' }
    Check 'spec ITF method: 610 {DINT} (no language, no access)' ($s.SubType -eq 610 -and (Format-VInfo $s.VInfo) -eq 'String[]:DINT' -and $null -eq $s.Access) (J $s)
    $s = Spec @{ Kind = 'Method'; ParentItemType = 618; Name = 'M_I' }
    Check 'spec ITF method without return type: vInfo null' ($s.SubType -eq 610 -and $null -eq $s.VInfo) (J $s)
    $s = Spec @{ Kind = 'Property'; ParentItemType = 618; Name = 'P_I'; ReturnType = 'INT' }
    Check 'spec ITF property: 612 {INT}' ($s.SubType -eq 612 -and (Format-VInfo $s.VInfo) -eq 'String[]:INT') (J $s)
    $s = Spec @{ Kind = 'Method'; ParentItemType = 618; Name = 'M_I'; ReturnType = 'BOOL'; Access = 'PRIVATE'; AccessGiven = $true }
    Check 'spec ITF method with PRIVATE -> POU_MEMBER_INVALID access' ($s.Error.Code -eq 'POU_MEMBER_INVALID' -and $s.Error.Reason -eq 'access') (J $s.Error)
    $s = Spec @{ Kind = 'Action'; ParentItemType = 618; Name = 'A_I' }
    Check 'spec action on interface -> POU_MEMBER_INVALID parent-kind' ($s.Error.Code -eq 'POU_MEMBER_INVALID' -and $s.Error.Reason -eq 'parent-kind') (J $s.Error)
    foreach ($k in 'Get', 'Set') {
        $s = Spec @{ Kind = $k; ParentItemType = 612 }
        Check "spec $k below ITF property (65x) -> POU_MEMBER_UNSUPPORTED, hint names the probe doc" ($s.Error.Code -eq 'POU_MEMBER_UNSUPPORTED' -and $s.Error.Reason -eq 'itf-property-accessor' -and $s.Error.Hint -like '*phase2-probe.md*' -and $s.Error.Hint -like '*crash*') (J $s.Error)
    }
    $s = Spec @{ Kind = 'Method'; ParentItemType = 603; Name = 'M_X'; ReturnType = 'BOOL' }
    Check 'spec method on FUNCTION -> POU_MEMBER_INVALID parent-kind' ($s.Error.Code -eq 'POU_MEMBER_INVALID' -and $s.Error.Reason -eq 'parent-kind') (J $s.Error)
    $s = Spec @{ Kind = 'Method'; ParentItemType = 604; Name = 'M X'; ReturnType = 'BOOL' }
    Check 'spec name not an identifier -> POU_MEMBER_INVALID name' ($s.Error.Code -eq 'POU_MEMBER_INVALID' -and $s.Error.Reason -eq 'name') (J $s.Error)

    # --- Add-TcPouMember: access check (XAE would make NOSUCH PUBLIC silently)
    Reset-Mock; Reset-BuildRequired
    $r = Add-TcPouMember -ParentPath "$P^POUs^FB_A" -Kind Method -Name M_Bad -ReturnType BOOL -Access NOSUCH
    Check 'access NOSUCH -> POU_MEMBER_INVALID, nothing created, hint' ((-not $r.success) -and $r.error.code -eq 'POU_MEMBER_INVALID' -and $r.data.reason -eq 'access' -and $r.error.hint -match 'PRIVATE' -and $global:T.Creates.Count -eq 0) (J $r)

    # --- method: vInfo, readback, data.path, BUILD_REQUIRED
    $r = Add-TcPouMember -ParentPath "$P^POUs^FB_A" -Kind Method -Name M_Start -ReturnType BOOL -Access private
    Check 'method created: 609, vInfo string[] {1,BOOL,PRIVATE}' ($r.success -and @($global:T.Creates)[0] -eq "$P^POUs^FB_A|M_Start|609|String[]:1|BOOL|PRIVATE") (@($global:T.Creates) -join ' ; ')
    Check 'method data.path usable as -PouPath, objectKind METHOD, access PRIVATE' ($r.data.path -eq "$P^POUs^FB_A^M_Start" -and $r.data.objectKind -eq 'METHOD' -and $r.data.access -eq 'PRIVATE' -and $r.data.language -eq 'ST' -and $r.data.declaration -eq 'METHOD PRIVATE M_Start : BOOL') (J $r.data)
    Check 'method success -> buildRequired code-changed' ($r.data.buildRequired -like '*Add-TcPouMember*M_Start*' -and (Get-CodeChanged) -like '*M_Start*') "$($r.data.buildRequired)"
    $g = Get-TcPouCode -PouName M_Start -PouPath $r.data.path
    Check 'Get-TcPouCode on data.path works' ($g.success -and $g.data.objectKind -eq 'METHOD') (J $g)

    # --- same name below the parent (case-insensitive), nothing created
    Reset-Mock; Reset-BuildRequired
    $r = Add-TcPouMember -ParentPath "$P^POUs^FB_A" -Kind Method -Name m_run -ReturnType BOOL
    Check 'same name (case-insensitive) -> POU_MEMBER_EXISTS, existingPath, nothing created' ((-not $r.success) -and $r.error.code -eq 'POU_MEMBER_EXISTS' -and $r.data.existingPath -eq "$P^POUs^FB_A^M_Run" -and $global:T.Creates.Count -eq 0 -and $null -eq (Get-CodeChanged)) (J $r)
    $r = Add-TcPouMember -ParentPath "$P^POUs^FB_A^P_Value" -Kind Get
    Check 'second Get -> POU_MEMBER_EXISTS (XAE would say SubType mismatch)' ((-not $r.success) -and $r.error.code -eq 'POU_MEMBER_EXISTS' -and $global:T.Creates.Count -eq 0) (J $r)

    # --- property, then its accessors through a dotted parent name
    $r = Add-TcPouMember -ParentPath "$P^POUs^FB_A" -Kind Property -Name P_New -ReturnType INT
    Check 'property: 611 {1,INT,PUBLIC}' ($r.success -and @($global:T.Creates)[-1] -eq "$P^POUs^FB_A|P_New|611|String[]:1|INT|PUBLIC") (@($global:T.Creates) -join ' ; ')
    $r = Add-TcPouMember -ParentPath 'FB_A.P_New' -Kind Get
    Check 'Get via ParentPath FB_A.P_New: 613 {1,PUBLIC}, path ...^P_New^Get' ($r.success -and @($global:T.Creates)[-1] -eq "$P^POUs^FB_A^P_New|Get|613|String[]:1|PUBLIC" -and $r.data.path -eq "$P^POUs^FB_A^P_New^Get" -and $r.data.resolvedBy -eq 'dot-path') (J $r)
    $r = Add-TcPouMember -ParentPath "$P^POUs^FB_A^P_New" -Kind Set -Access PROTECTED
    Check 'Set: 614 {1,PROTECTED}' ($r.success -and @($global:T.Creates)[-1] -eq "$P^POUs^FB_A^P_New|Set|614|String[]:1|PROTECTED") (J $r)

    # --- action: no declaration read
    $global:T.Reads.Clear()
    $r = Add-TcPouMember -ParentPath "$P^POUs^FB_A" -Kind Action -Name A_Reset -Language LD
    Check 'action: 608 {6}, language LD, declaration null' ($r.success -and @($global:T.Creates)[-1] -eq "$P^POUs^FB_A|A_Reset|608|String[]:6" -and $r.data.language -eq 'LD' -and $null -eq $r.data.declaration) (J $r)
    Check 'action: DeclarationText not read' (@($global:T.Reads | Where-Object { $_ -like 'Decl *A_Reset' }).Count -eq 0) (@($global:T.Reads) -join ' ; ')

    # --- interface parent: 610 / 612
    $r = Add-TcPouMember -ParentPath "$P^POUs^ITF_X" -Kind Method -Name M_Do -ReturnType DINT
    Check 'ITF method: 610 {DINT}' ($r.success -and @($global:T.Creates)[-1] -eq "$P^POUs^ITF_X|M_Do|610|String[]:DINT" -and $r.data.objectKind -eq 'ITF_METHOD') (J $r)
    $r = Add-TcPouMember -ParentPath "$P^POUs^ITF_X" -Kind Property -Name P_Two -ReturnType LREAL
    Check 'ITF property: 612 {LREAL}' ($r.success -and @($global:T.Creates)[-1] -eq "$P^POUs^ITF_X|P_Two|612|String[]:LREAL" -and $r.data.objectKind -eq 'ITF_PROPERTY') (J $r)
    $n = $global:T.Creates.Count
    $r = Add-TcPouMember -ParentPath "$P^POUs^ITF_X^P_Two" -Kind Get
    Check 'Get below ITF property -> POU_MEMBER_UNSUPPORTED, nothing created' ((-not $r.success) -and $r.error.code -eq 'POU_MEMBER_UNSUPPORTED' -and $r.data.reason -eq 'itf-property-accessor' -and $global:T.Creates.Count -eq $n -and $r.error.hint -like '*phase2-probe.md*') (J $r)

    # --- parent kind / ambiguous parent
    $r = Add-TcPouMember -ParentPath "$P^POUs^FC_F" -Kind Method -Name M_X -ReturnType BOOL
    Check 'method on a FUNCTION -> POU_MEMBER_INVALID parent-kind' ((-not $r.success) -and $r.error.code -eq 'POU_MEMBER_INVALID' -and $r.data.reason -eq 'parent-kind') (J $r)
    $n = $global:T.Creates.Count
    $r = Add-TcPouMember -ParentPath 'P_Value' -Kind Set
    Check 'ambiguous parent name -> POU_AMBIGUOUS with both candidates, nothing created' ((-not $r.success) -and $r.error.code -eq 'POU_AMBIGUOUS' -and @($r.data.candidates).Count -eq 2 -and @($r.data.candidates) -contains "$P^POUs^FB_B^P_Value" -and $global:T.Creates.Count -eq $n) (J $r)

    # --- XAE ignores the access (mock: always PUBLIC) -> declaration readback fails, member stays
    Reset-BuildRequired
    $global:T.CreateMode = 'publicize'
    $r = Add-TcPouMember -ParentPath "$P^POUs^FB_B" -Kind Method -Name M_Priv -ReturnType BOOL -Access PRIVATE
    Check 'access not applied -> POU_MEMBER_CREATE_FAILED declare, recorded (created)' ((-not $r.success) -and $r.error.code -eq 'POU_MEMBER_CREATE_FAILED' -and $r.error.message -match 'declare:' -and $r.data.buildRequired -like '*failed after CreateChild*') (J $r)
    $global:T.CreateMode = 'ok'

    # --- PLC logged in: PLC_LOGGED_IN, nothing recorded
    Reset-BuildRequired
    $global:T.CreateMode = 'loggedin'
    $r = Add-TcPouMember -ParentPath "$P^POUs^FB_B" -Kind Action -Name A_X
    Check 'logged in -> PLC_LOGGED_IN, no buildRequired' ((-not $r.success) -and $r.error.code -eq 'PLC_LOGGED_IN' -and $null -eq (Get-CodeChanged)) (J $r)
    $global:T.CreateMode = 'ok'

    # --- modal dialog: nothing created
    $global:T.Dialog = @{ Title = 'TwinCAT XAE'; Text = 'Something'; Kind = 'other' }
    $n = $global:T.Creates.Count
    $r = Add-TcPouMember -ParentPath "$P^POUs^FB_B" -Kind Action -Name A_Dlg
    Check 'modal dialog -> IDE_MODAL_DIALOG, nothing created' ((-not $r.success) -and $r.error.code -eq 'IDE_MODAL_DIALOG' -and $global:T.Creates.Count -eq $n) (J $r)
    $global:T.Dialog = $null

    # --- Add-TcInterface: vInfo null / string (an array is refused by XAE)
    Reset-Mock; Reset-BuildRequired
    $r = Add-TcInterface -Name I_Base
    Check 'interface: 618, vInfo null, .TcIO saved' ($r.success -and @($global:T.Creates)[0] -eq "$P^POUs|I_Base|618|null" -and $r.data.objectKind -eq 'ITF' -and @($r.data.projectSaved.verifiedFiles) -contains 'I_Base.TcIO') (J $r)
    $r = Add-TcInterface -Name I_Ext -Extends I_Base
    Check 'interface Extends: vInfo is a string, declaration EXTENDS' ($r.success -and @($global:T.Creates)[-1] -eq "$P^POUs|I_Ext|618|String:I_Base" -and $r.data.extends -eq 'I_Base' -and $r.data.declaration -eq 'INTERFACE I_Ext EXTENDS I_Base') (J $r)
    Check 'interface -> buildRequired' ((Get-CodeChanged) -like '*Add-TcInterface I_Ext*') "$(Get-CodeChanged)"
    $n = $global:T.Creates.Count
    $r = Add-TcInterface -Name I_Bad -Extends 'I_Base; DROP'
    Check 'interface bad Extends -> INVALID_PARAMS, nothing created' ((-not $r.success) -and $r.error.code -eq 'INVALID_PARAMS' -and $global:T.Creates.Count -eq $n) (J $r)
    $r = Add-TcInterface -Name ITF_X
    Check 'interface with an existing name -> POU_CREATE_FAILED exists' ((-not $r.success) -and $r.error.code -eq 'POU_CREATE_FAILED' -and $r.error.message -match 'exists:') (J $r)

    # --- Resolve-TcPouPath: dot path, POU_AMBIGUOUS, filtered duplicates, folder with a dot
    Reset-Mock
    $g = Get-TcPouCode -PouName 'FB_A.M_Run'
    Check 'FB_A.M_Run -> dot-path ...^FB_A^M_Run' ($g.success -and $g.data.pouPath -eq "$P^POUs^FB_A^M_Run" -and $g.data.resolvedBy -eq 'dot-path') (J $g)
    $g = Get-TcPouCode -PouName 'FB_A.P_Value.Get'
    Check 'FB_A.P_Value.Get -> ...^FB_A^P_Value^Get' ($g.success -and $g.data.pouPath -eq "$P^POUs^FB_A^P_Value^Get" -and $g.data.objectKind -eq 'PROPERTY_GET') (J $g)
    $g = Get-TcPouCode -PouName 'M_Run'
    Check 'M_Run in two FBs -> POU_AMBIGUOUS, candidates both, not the first' ((-not $g.success) -and $g.error.code -eq 'POU_AMBIGUOUS' -and @($g.data.candidates).Count -eq 2 -and @($g.data.candidates) -contains "$P^POUs^FB_A^M_Run" -and @($g.data.candidates) -contains "$P^POUs^FB_B^M_Run" -and $g.error.hint) (J $g)
    $g = Get-TcPouCode -PouName 'P_Value.Get'
    Check 'P_Value.Get (head ambiguous, both have Get) -> POU_AMBIGUOUS' ((-not $g.success) -and $g.error.code -eq 'POU_AMBIGUOUS' -and @($g.data.candidates) -contains "$P^POUs^FB_B^P_Value^Get") (J $g)
    $g = Get-TcPouCode -PouName 'FB_Deep'
    Check 'FB_Deep + task reference (650) of the same name -> the POU, not ambiguous' ($g.success -and $g.data.pouPath -eq "$P^POUs^Sub^FB_Deep" -and $g.data.resolvedBy -eq 'tree-search') (J $g)
    $g = Get-TcPouCode -PouName x -PouPath "$P^POUs^FB_A.M_Run"
    Check 'PouPath with dotted last segment -> explicit-dot' ($g.success -and $g.data.pouPath -eq "$P^POUs^FB_A^M_Run" -and $g.data.resolvedBy -eq 'explicit-dot') (J $g)
    $g = Get-TcPouCode -PouName x -PouPath "$P^POUs^v1.2^FB_V"
    Check 'folder name with a dot: original path tried first' ($g.success -and $g.data.resolvedBy -eq 'explicit' -and $g.data.pouPath -eq "$P^POUs^v1.2^FB_V") (J $g)
    $g = Get-TcPouCode -PouName 'FB_A.NoSuch'
    Check 'FB_A.NoSuch -> POU_NOT_FOUND, tried lists the dotted path' ((-not $g.success) -and $g.error.code -eq 'POU_NOT_FOUND' -and @($g.data.tried) -contains "$P^POUs^FB_A^NoSuch") (J $g)
    $w = Write-TcPouCode -PouName 'M_Run' -Implementation 'M_Run := TRUE;'
    Check 'Write by ambiguous name -> POU_AMBIGUOUS, nothing written' ((-not $w.success) -and $w.error.code -eq 'POU_AMBIGUOUS' -and $global:T.Writes.Count -eq 0) (J $w)

    # --- 654 / 655: only ItemType is read
    foreach ($acc in 'Get', 'Set') {
        $global:T.Reads.Clear(); $global:T.Writes.Clear()
        $path = "$P^POUs^ITF_X^P_Cnt^$acc"
        $g = Get-TcPouCode -PouName $acc -PouPath $path
        Check "Get-TcPouCode ITF property $acc -> POU_MEMBER_UNSUPPORTED" ((-not $g.success) -and $g.error.code -eq 'POU_MEMBER_UNSUPPORTED' -and $g.data.reason -eq 'itf-property-accessor' -and $g.error.message -like '*phase2-probe.md*') (J $g)
        Check "Get-TcPouCode ITF property ${acc}: no DeclarationText / ImplementationText / Language read" ($global:T.Reads.Count -eq 0) (@($global:T.Reads) -join ' ; ')
        $w = Write-TcPouCode -PouName $acc -PouPath $path -Implementation 'x := 1;'
        Check "Write-TcPouCode ITF property $acc -> POU_MEMBER_UNSUPPORTED, nothing read or written" ((-not $w.success) -and $w.error.code -eq 'POU_MEMBER_UNSUPPORTED' -and $global:T.Reads.Count -eq 0 -and $global:T.Writes.Count -eq 0) (J $w)
    }

    # --- Write-TcPouCode -Implementation '' clears (and is read back); -Declaration '' is refused
    Reset-Mock; Reset-BuildRequired
    $global:T.Nodes["$P^POUs^FB_A^M_Run"].Impl = 'M_Run := TRUE;'
    $w = Write-TcPouCode -PouName M_Run -PouPath "$P^POUs^FB_A^M_Run" -Implementation ''
    Check "Implementation '' -> written as '', read back empty, cleared=true" ($w.success -and $w.data.cleared -eq $true -and @($w.data.updated) -contains 'implementation' -and $global:T.Nodes["$P^POUs^FB_A^M_Run"].Impl -eq '' -and @($global:T.Writes) -contains "Impl $P^POUs^FB_A^M_Run=[]") (J $w)
    Check "Implementation '' -> buildRequired" ($w.data.buildRequired -like '*Write-TcPouCode M_Run `[implementation`]*') "$($w.data.buildRequired)"
    $global:T.Nodes["$P^POUs^FB_A^M_Run"].Impl = 'M_Run := TRUE;'
    $global:T.SetMode = 'ignoreempty'
    $w = Write-TcPouCode -PouName M_Run -PouPath "$P^POUs^FB_A^M_Run" -Implementation ''
    Check "Implementation '' not applied -> POU_WRITE_FAILED empty-not-applied" ((-not $w.success) -and $w.error.code -eq 'POU_WRITE_FAILED' -and $w.data.reason -eq 'empty-not-applied') (J $w)
    $global:T.SetMode = 'ok'
    Reset-BuildRequired; $global:T.Writes.Clear()
    $w = Write-TcPouCode -PouName M_Run -PouPath "$P^POUs^FB_A^M_Run" -Declaration ''
    Check "Declaration '' -> POU_WRITE_FAILED empty-not-supported, nothing written, nothing recorded" ((-not $w.success) -and $w.error.code -eq 'POU_WRITE_FAILED' -and $w.data.reason -eq 'empty-not-supported' -and $global:T.Writes.Count -eq 0 -and $null -eq (Get-CodeChanged)) (J $w)
    $w = Write-TcPouCode -PouName M_Run -PouPath "$P^POUs^FB_A^M_Run"
    Check 'neither text given -> success, nothing written' ($w.success -and @($w.data.updated).Count -eq 0 -and $global:T.Writes.Count -eq 0) (J $w)

    # --- BUILD_REQUIRED only for real writes
    Reset-BuildRequired
    $w = Write-TcPouCode -PouName A_Old -PouPath "$P^POUs^FB_A^A_Old" -Declaration 'VAR END_VAR'
    Check 'declaration on an action -> INVALID_PARAMS, nothing written / recorded' ((-not $w.success) -and $w.error.code -eq 'INVALID_PARAMS' -and $w.data.objectKind -eq 'ACTION' -and $global:T.Writes.Count -eq 0 -and $null -eq (Get-CodeChanged)) (J $w)
    $global:T.SetMode = 'throw'
    $w = Write-TcPouCode -PouName MAIN -PouPath "$P^POUs^MAIN" -Implementation 'x := 1;'
    Check 'setter refused by XAE -> POU_WRITE_FAILED, no buildRequired' ((-not $w.success) -and $w.error.code -eq 'POU_WRITE_FAILED' -and $null -eq (Get-CodeChanged) -and ($null -eq $w.data -or $null -eq $w.data.PSObject.Properties['buildRequired'])) (J $w)
    $global:T.SetMode = 'idetimeout'
    $w = Write-TcPouCode -PouName MAIN -PouPath "$P^POUs^MAIN" -Implementation 'x := 2;'
    Check 'setter IDE_TIMEOUT (may have run) -> recorded [write failed]' ((-not $w.success) -and $w.error.code -eq 'IDE_TIMEOUT' -and $w.data.buildRequired -like '*MAIN `[write failed`]*') (J $w)
    $global:T.SetMode = 'ok'
    Reset-BuildRequired

    # --- hints, cmdlet names only (the MCP server rewrites them into tool names)
    foreach ($code in 'POU_MEMBER_INVALID', 'POU_MEMBER_UNSUPPORTED', 'POU_MEMBER_EXISTS', 'POU_MEMBER_CREATE_FAILED', 'POU_AMBIGUOUS', 'POU_WRITE_FAILED') {
        $h = & $mod { param($c) Get-TcErrorHint -Code $c } $code
        Check "hint $code registered, no MCP tool names" (-not [string]::IsNullOrWhiteSpace($h) -and $h -notmatch '\b(AddPouMember|GetPouCode|WritePouCode|GetProjectTree)\b') "$h"
    }

    # --- tools.json
    $tj = Join-Path $PSScriptRoot '..\..\mcp-server\tools.json'
    $tools = @((Get-Content -LiteralPath $tj -Raw -Encoding UTF8 | ConvertFrom-Json).tools)
    $am = @($tools | Where-Object { $_.name -eq 'AddPouMember' })[0]
    Check 'tools.json AddPouMember: cmdlet, required ParentPath + Kind, Kind enum, plain annotations' ($null -ne $am -and $am.cmdlet -eq 'Add-TcPouMember' -and @($am.inputSchema.required) -contains 'ParentPath' -and @($am.inputSchema.required) -contains 'Kind' -and @($am.inputSchema.properties.Kind.enum).Count -eq 5 -and $am.annotations.readOnlyHint -eq $false -and $am.annotations.destructiveHint -eq $false -and $am.inputSchema.properties.Access.default -eq 'PUBLIC') (J $am.inputSchema)
    $ai = @($tools | Where-Object { $_.name -eq 'AddInterface' })[0]
    Check 'tools.json AddInterface: cmdlet, Name required, plain annotations' ($null -ne $ai -and $ai.cmdlet -eq 'Add-TcInterface' -and @($ai.inputSchema.required) -contains 'Name' -and $ai.annotations.destructiveHint -eq $false) (J $ai.inputSchema)
}
catch {
    Check 'unexpected-exception' $false "$($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber)"
}
finally {
    & $mod { $script:TcIdeConnected = $false; $script:TcSolutionPath = $null }
    Remove-Item -LiteralPath $env:TCAUTO_STATE_DIR -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\TCAUTO_STATE_DIR -ErrorAction SilentlyContinue
}

"failed: $fail"
exit [Math]::Min($fail, 255)
