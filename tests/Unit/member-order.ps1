# Unit: #47 ordered members for Add-TcDut (-Fields) / Add-TcGvl (-Variables) and #70 New-TcProject
# fail-closed, no IDE needed. New-TcPlcObject / Invoke-TcPlcObjectSave / Resolve-TcPlcProjectFolder
# are stubbed in module scope; the stub's readback can be made to reorder the members.
#   powershell.exe -NoProfile -File tests/Unit/member-order.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
# Add-* record BUILD_REQUIRED code-changed (#65): never into the real %TEMP% state file
$env:TCAUTO_STATE_DIR = Join-Path $env:TEMP ("tcauto-unit-state-{0}" -f [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 400) { $Detail = $Detail.Substring(0, 400) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}

# --- ConvertTo-TcMemberList
$names = { param($r) (@($r.Members | ForEach-Object { $_.Name }) -join ',') }
$r = & $mod { ConvertTo-TcMemberList -InputObject @(@{ name = 'zLast'; type = 'BOOL' }, @{ name = 'aFirst'; type = 'INT'; init = '5' }, [PSCustomObject]@{ Name = 'mMid'; Type = 'LREAL'; Comment = 'c' }) -Kind Var -ParameterName Fields }
Check 'array keeps input order' ($null -eq $r.Error -and (& $names $r) -eq 'zLast,aFirst,mMid' -and $r.Members[1].Init -eq '5' -and $r.Members[2].Comment -eq 'c') ($r | ConvertTo-Json -Compress -Depth 4)
$r = & $mod { ConvertTo-TcMemberList -InputObject ([ordered]@{ zLast = 'BOOL'; aFirst = 'INT'; mMid = 'LREAL'; bSecond = 'DINT' }) -Kind Var -ParameterName Fields }
Check '[ordered] keeps input order' ($null -eq $r.Error -and (& $names $r) -eq 'zLast,aFirst,mMid,bSecond') ($r | ConvertTo-Json -Compress -Depth 4)
$r = & $mod { ConvertTo-TcMemberList -InputObject ('{"zLast":"BOOL","aFirst":"INT","mMid":"LREAL"}' | ConvertFrom-Json) -Kind Var -ParameterName Fields }
Check 'PSCustomObject (CLI JSON) keeps property order' ($null -eq $r.Error -and (& $names $r) -eq 'zLast,aFirst,mMid') ($r | ConvertTo-Json -Compress -Depth 4)
$r = & $mod { ConvertTo-TcMemberList -InputObject @{ zLast = 'BOOL'; aFirst = 'INT' } -Kind Var -ParameterName Fields }
Check 'plain hashtable > 1 member -> error' ($null -ne $r.Error -and $r.Error -like '*hashtable*#47*') "$($r.Error)"
$r = & $mod { ConvertTo-TcMemberList -InputObject @{ nA = 'INT' } -Kind Var -ParameterName Fields }
Check 'plain hashtable with 1 member accepted' ($null -eq $r.Error -and (& $names $r) -eq 'nA') "$($r.Error)"
$r = & $mod { ConvertTo-TcMemberList -InputObject @(@{ name = 'eZulu'; value = 0 }, @{ name = 'eAlpha' }, @{ name = 'eMike'; value = '7' }) -Kind Enum -ParameterName Fields }
Check 'enum array, value optional' ($null -eq $r.Error -and (& $names $r) -eq 'eZulu,eAlpha,eMike' -and $r.Members[0].Value -eq '0' -and $null -eq $r.Members[1].Value) ($r | ConvertTo-Json -Compress -Depth 4)
foreach ($case in @(
        @('missing type', @(@{ name = 'a' })),
        @('bad name', @(@{ name = '1a'; type = 'INT' })),
        @('duplicate name', @(@{ name = 'a'; type = 'INT' }, @{ name = 'A'; type = 'BOOL' })),
        @('unknown key', @(@{ name = 'a'; type = 'INT'; typ = 'x' })),
        @('type with ;', @(@{ name = 'a'; type = 'INT; b : BOOL' })),
        @('string entry', @('a : INT')))) {
    $in = $case[1]
    $r = & $mod { param($x) ConvertTo-TcMemberList -InputObject $x -Kind Var -ParameterName Fields } $in
    Check "invalid: $($case[0])" ($null -ne $r.Error) "$($r.Error)"
}

# --- Format / parse round trip
$m = & $mod { (ConvertTo-TcMemberList -InputObject @(@{ name = 'zLast'; type = 'BOOL'; init = 'TRUE'; comment = 'last' }, @{ name = 'aFirst'; type = 'STRING(20)' }) -Kind Var -ParameterName F).Members }
$lines = & $mod { param($x) Format-TcMemberDeclaration -Members $x -Kind Var } @($m)
Check 'format var lines' (($lines -join '|') -eq '    zLast : BOOL := TRUE; // last|    aFirst : STRING(20);') ($lines -join '|')
$order = & $mod { Get-TcDeclarationMemberOrder -Declaration "TYPE ST_A :`nSTRUCT`n    (* x : INT; *)`n    zLast : BOOL := TRUE; // y : INT;`n    {attribute 'hide'}`n    a1, a2 : INT;`n    aFirst AT %I* : STRING(20);`nEND_STRUCT`nEND_TYPE" -Kind Var }
Check 'parse struct (comments, pragma, multi-name, AT)' (($order -join ',') -eq 'zLast,a1,a2,aFirst') ($order -join ',')
$order = & $mod { Get-TcDeclarationMemberOrder -Declaration "{attribute 'qualified_only'}`nVAR_GLOBAL`n    nB : INT;`n    nA : INT := 3;`nEND_VAR" -Kind Var }
Check 'parse VAR_GLOBAL' (($order -join ',') -eq 'nB,nA') ($order -join ',')
$order = & $mod { Get-TcDeclarationMemberOrder -Declaration "TYPE E_A :`n(`n    eZulu := 0,`n    eAlpha, // c`n    eMike := 2`n) INT;`nEND_TYPE" -Kind Enum }
Check 'parse enum with base type' (($order -join ',') -eq 'eZulu,eAlpha,eMike') ($order -join ',')

# --- Add-TcDut / Add-TcGvl with stubs
& $mod {
    $script:TcIdeProcessId = $null; $script:TcIdeConnected = $true; $script:TcDte = [PSCustomObject]@{}
    $script:TcSysManager = [PSCustomObject]@{}; $script:TcSolutionPath = 'C:\Demo\Unit.sln'
    function script:Resolve-TcPlcProjectFolder { param($SysManager, $FolderName) @{ Path = "TIPC^plc^plc Project^$FolderName" } }
    function script:Invoke-TcPlcObjectSave { [CmdletBinding()] param([string]$ObjectPath, [string]$ExpectFile, [string]$ExpectLibrary, [string]$What) @{ Saved = [PSCustomObject]@{ plcproj = 'mock.plcproj' }; Error = $null } }
    function script:New-TcPlcObject {
        param($SysManager, $ParentPath, $Name, $SubType, $VInfo, $Declaration, $Progress)
        $Progress['CreateCalled'] = $true
        $global:LastDecl = $Declaration
        $readback = $Declaration
        if ($global:MockReorder) {
            # swap the first two member lines, as a reordering XAE / hashtable would
            $l = [System.Collections.Generic.List[string]]($Declaration -split "`n")
            $i = 0; while ($l[$i] -notmatch '^    ') { $i++ }
            $t = $l[$i]; $l[$i] = $l[$i + 1]; $l[$i + 1] = $t
            $readback = $l -join "`n"
        }
        @{ Path = "$ParentPath^$Name"; ItemType = $SubType; Declaration = $readback; DuplicateCheckScope = 'project'; DuplicateCheckSkippedNodes = 0; DuplicateCheckNote = $null }
    }
}
$global:MockReorder = $false
$fields = @(@{ name = 'zLast'; type = 'BOOL' }, @{ name = 'aFirst'; type = 'INT' }, @{ name = 'mMid'; type = 'LREAL' }, @{ name = 'bSecond'; type = 'DINT' }, @{ name = 'yFourth'; type = 'STRING(20)' })
$r = Add-TcDut -Name ST_O -DutType Struct -Fields $fields
Check 'Add-TcDut Struct array -> success, memberOrder = input' ($r.success -and ($r.data.memberOrder -join ',') -eq 'zLast,aFirst,mMid,bSecond,yFourth') ($r | ConvertTo-Json -Compress -Depth 4)
Check 'Add-TcDut Struct declaration text in order' ($global:LastDecl -eq "TYPE ST_O :`nSTRUCT`n    zLast : BOOL;`n    aFirst : INT;`n    mMid : LREAL;`n    bSecond : DINT;`n    yFourth : STRING(20);`nEND_STRUCT`nEND_TYPE") $global:LastDecl
$r = Add-TcDut -Name E_O -DutType Enum -Fields @(@{ name = 'eZulu'; value = 0 }, @{ name = 'eAlpha'; value = 1 }, @{ name = 'eMike' })
Check 'Add-TcDut Enum array -> success' ($r.success -and ($r.data.memberOrder -join ',') -eq 'eZulu,eAlpha,eMike' -and $global:LastDecl -eq "TYPE E_O :`n(`n    eZulu := 0,`n    eAlpha := 1,`n    eMike`n);`nEND_TYPE") (($r | ConvertTo-Json -Compress -Depth 4) + ' ' + $global:LastDecl)
$r = Add-TcGvl -Name GVL_O -Variables ([ordered]@{ zLast = 'BOOL'; aFirst = 'INT'; mMid = 'LREAL' })
Check 'Add-TcGvl [ordered] -> success' ($r.success -and ($r.data.memberOrder -join ',') -eq 'zLast,aFirst,mMid') ($r | ConvertTo-Json -Compress -Depth 4)

$global:LastDecl = $null
$r = Add-TcDut -Name ST_H -DutType Struct -Fields @{ zLast = 'BOOL'; aFirst = 'INT' }
Check 'Add-TcDut hashtable > 1 -> INVALID_PARAMS, nothing created' ((-not $r.success) -and $r.error.code -eq 'INVALID_PARAMS' -and $r.error.hint -and $null -eq $global:LastDecl) ($r | ConvertTo-Json -Compress -Depth 4)
$r = Add-TcGvl -Name GVL_H -Variables @{ zLast = 'BOOL'; aFirst = 'INT' }
Check 'Add-TcGvl hashtable > 1 -> INVALID_PARAMS, nothing created' ((-not $r.success) -and $r.error.code -eq 'INVALID_PARAMS' -and $null -eq $global:LastDecl) ($r | ConvertTo-Json -Compress -Depth 4)

$global:MockReorder = $true
$r = Add-TcDut -Name ST_R -DutType Struct -Fields $fields
Check 'Add-TcDut readback reordered -> MEMBER_ORDER_MISMATCH' ((-not $r.success) -and $r.error.code -eq 'MEMBER_ORDER_MISMATCH' -and $r.error.hint -and ($r.data.actualOrder -join ',') -eq 'aFirst,zLast,mMid,bSecond,yFourth' -and ($r.data.expectedOrder -join ',') -eq 'zLast,aFirst,mMid,bSecond,yFourth') ($r | ConvertTo-Json -Compress -Depth 4)
Check 'MEMBER_ORDER_MISMATCH recorded code-changed' ($r.data.buildRequired -like '*Add-TcDut ST_R*') ($r | ConvertTo-Json -Compress -Depth 4)
$r = Add-TcGvl -Name GVL_R -Variables $fields
Check 'Add-TcGvl readback reordered -> MEMBER_ORDER_MISMATCH' ((-not $r.success) -and $r.error.code -eq 'MEMBER_ORDER_MISMATCH') ($r | ConvertTo-Json -Compress -Depth 4)
$global:MockReorder = $false

# --- #70 New-TcProject fail-closed
$global:CreateCalled = $false
$sol = [PSCustomObject]@{ IsOpen = $true; FullName = 'C:\Demo\Unit.sln' }
$sol | Add-Member -MemberType ScriptMethod -Name Create -Value { param($a, $b) $global:CreateCalled = $true }
& $mod { param($s) $script:TcDte = [PSCustomObject]@{ Solution = $s } } $sol
$r = New-TcProject -Name NewOne -Path $env:TEMP
Check 'New-TcProject with open solution -> SOLUTION_ALREADY_OPEN, no Solution.Create' ((-not $r.success) -and $r.error.code -eq 'SOLUTION_ALREADY_OPEN' -and $r.error.hint -and $r.data.openSolution -eq 'C:\Demo\Unit.sln' -and -not $global:CreateCalled) ($r | ConvertTo-Json -Compress -Depth 4)
$bad = [PSCustomObject]@{}
$bad | Add-Member -MemberType ScriptProperty -Name IsOpen -Value { throw 'RPC failed (mock)' }
$bad | Add-Member -MemberType ScriptProperty -Name FullName -Value { throw 'RPC failed (mock)' }
$bad | Add-Member -MemberType ScriptMethod -Name Create -Value { param($a, $b) $global:CreateCalled = $true }
& $mod { param($s) $script:TcDte = [PSCustomObject]@{ Solution = $s } } $bad
$r = New-TcProject -Name NewOne -Path $env:TEMP
Check 'New-TcProject IsOpen unreadable solution state -> fail-closed' ((-not $r.success) -and $r.error.code -eq 'SOLUTION_ALREADY_OPEN' -and -not $global:CreateCalled) ($r | ConvertTo-Json -Compress -Depth 4)
& $mod { $script:TcDte = [PSCustomObject]@{ Solution = $null } }
$r = New-TcProject -Name NewOne -Path $env:TEMP
Check 'New-TcProject without Solution object -> fail-closed' ((-not $r.success) -and $r.error.code -eq 'SOLUTION_ALREADY_OPEN') ($r | ConvertTo-Json -Compress -Depth 4)

if (Test-Path -LiteralPath $env:TCAUTO_STATE_DIR) { Remove-Item -LiteralPath $env:TCAUTO_STATE_DIR -Recurse -Force -ErrorAction SilentlyContinue }
"member-order: $fail failed"
exit $fail
