# Unit: PLC object kind, Get/Write-TcPouCode semantics and New-TcPlcObject (issues #17 / #22),
# no IDE needed. A mock ITcSysManager (PSCustomObject + ScriptMethod LookupTreeItem) replaces
# $script:TcSysManager; tree items are PSCustomObjects with ItemType / DeclarationText.
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Unit/plc-object-kind.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}

$P = 'TIPC^plc^plc Project'
$global:MockTree = @{}
function New-MockItem([string]$Path, [int]$ItemType, [string]$Decl, [switch]$Impl, [switch]$Folder) {
    $o = [PSCustomObject]@{ PathName = $Path; Name = ($Path -split '\^')[-1]; ItemType = $ItemType; ItemSubType = 0; ItemSubTypeName = "TYPE_$ItemType"; DeclarationText = $Decl }
    if ($Impl) { $o | Add-Member -NotePropertyName ImplementationText -NotePropertyValue '' }
    if ($Folder) {
        $o | Add-Member -MemberType ScriptMethod -Name CreateChild -Value {
            param($name, $subType, $before, $vInfo)
            $global:MockCreateCalls += , @($name, $subType, $vInfo)
            if ($subType -eq 610) { throw "Creating the child type 'TREEITEMTYPE_PLCITFMETH' is not possible on parent node type 'TREEITEMTYPE_PLCFOLDER'" }
            $child = [PSCustomObject]@{ PathName = "$($this.PathName)^$name"; Name = $name; ItemType = $subType; ItemSubType = 0; ItemSubTypeName = ''; DeclarationText = 'default' }
            $global:MockTree["$($this.PathName)^$name"] = $child
            $child
        }
    }
    $global:MockTree[$Path] = $o
    $o
}
$null = New-MockItem "$P^POUs" 601 '' -Folder
$null = New-MockItem "$P^DUTs" 601 '' -Folder
$null = New-MockItem "$P^POUs^MAIN" 602 'PROGRAM MAIN' -Impl
$null = New-MockItem "$P^DUTs^ST_X" 606 "TYPE ST_X :`nSTRUCT`nEND_STRUCT`nEND_TYPE"
$null = New-MockItem "$P^GVLs^GVL_X" 615 "VAR_GLOBAL`nEND_VAR"
$null = New-MockItem "$P^POUs^I_X" 618 'INTERFACE I_X'
$global:MockCreateCalls = @()

$sm = [PSCustomObject]@{}
$sm | Add-Member -MemberType ScriptMethod -Name LookupTreeItem -Value {
    param($path)
    if (-not $global:MockTree.ContainsKey($path)) { throw "Item not found: $path" }
    $global:MockTree[$path]
}
& $mod { param($s) $script:TcIdeProcessId = $null; $script:TcIdeConnected = $true; $script:TcDte = [PSCustomObject]@{}; $script:TcSysManager = $s } $sm

# --- Get-TcPlcObjectKind
$k = & $mod { Get-TcPlcObjectKind -ItemType 604 }
Check 'kind 604' ($k.ObjectKind -eq 'POU' -and $k.PouType -eq 'FunctionBlock' -and $k.HasImplementation -eq $true) ($k | ConvertTo-Json -Compress)
foreach ($t in @(@(605, 'DUT', 'Enum'), @(606, 'DUT', 'Struct'), @(607, 'DUT', 'Union'), @(623, 'DUT', 'Alias'), @(615, 'GVL', $null), @(618, 'ITF', $null))) {
    $k = & $mod { param($n) Get-TcPlcObjectKind -ItemType $n } $t[0]
    Check "kind $($t[0])" ($k.ObjectKind -eq $t[1] -and $k.PouType -eq $t[2] -and $k.HasImplementation -eq $false) ($k | ConvertTo-Json -Compress)
}
$k = & $mod { Get-TcPlcObjectKind -ItemType 9999 }
Check 'kind unknown' ($k.ObjectKind -eq 'UNKNOWN' -and $null -eq $k.HasImplementation) ($k | ConvertTo-Json -Compress)

# --- Get-TcPouCode
$r = Get-TcPouCode -PouName MAIN -PouPath "$P^POUs^MAIN"
Check 'Get POU' ($r.success -and $r.data.objectKind -eq 'POU' -and $r.data.hasImplementation -eq $true -and $r.data.implementation -eq '') ($r | ConvertTo-Json -Compress)
$r = Get-TcPouCode -PouName ST_X -PouPath "$P^DUTs^ST_X"
Check 'Get DUT' ($r.success -and $r.data.objectKind -eq 'DUT' -and $r.data.pouType -eq 'Struct' -and $r.data.hasImplementation -eq $false -and $null -eq $r.data.implementation -and $r.data.declaration -like 'TYPE ST_X*') ($r | ConvertTo-Json -Compress)
$r = Get-TcPouCode -PouName GVL_X -PouPath "$P^GVLs^GVL_X"
Check 'Get GVL' ($r.success -and $r.data.objectKind -eq 'GVL' -and $r.data.hasImplementation -eq $false) ($r | ConvertTo-Json -Compress)

# --- Write-TcPouCode
$before = $global:MockTree["$P^DUTs^ST_X"].DeclarationText
$r = Write-TcPouCode -PouName ST_X -PouPath "$P^DUTs^ST_X" -Declaration "TYPE ST_X :`nSTRUCT`n a : INT;`nEND_STRUCT`nEND_TYPE" -Implementation 'x := 1;'
Check 'Write DUT impl -> INVALID_PARAMS' ((-not $r.success) -and $r.error.code -eq 'INVALID_PARAMS' -and $r.error.hint -and $r.data.objectKind -eq 'DUT') ($r | ConvertTo-Json -Compress)
Check 'Write DUT impl writes nothing' ($global:MockTree["$P^DUTs^ST_X"].DeclarationText -eq $before) ''
$r = Write-TcPouCode -PouName GVL_X -PouPath "$P^GVLs^GVL_X" -Implementation 'x := 1;'
Check 'Write GVL impl -> INVALID_PARAMS' ((-not $r.success) -and $r.error.code -eq 'INVALID_PARAMS') ($r | ConvertTo-Json -Compress)
$r = Write-TcPouCode -PouName ST_X -PouPath "$P^DUTs^ST_X" -Declaration "TYPE ST_X :`nSTRUCT`n a : INT;`nEND_STRUCT`nEND_TYPE"
Check 'Write DUT decl' ($r.success -and $r.data.objectKind -eq 'DUT' -and @($r.data.updated) -contains 'declaration') ($r | ConvertTo-Json -Compress)
$r = Write-TcPouCode -PouName MAIN -PouPath "$P^POUs^MAIN" -Implementation 'n := n + 1;'
Check 'Write POU impl' ($r.success -and @($r.data.updated) -contains 'implementation' -and $global:MockTree["$P^POUs^MAIN"].ImplementationText -eq 'n := n + 1;') ($r | ConvertTo-Json -Compress)

# --- New-TcPlcObject
$c = & $mod { param($s, $p) New-TcPlcObject -SysManager $s -ParentPath "$p^POUs" -Name FB_N -SubType 604 -VInfo 1 } $sm $P
$call = $global:MockCreateCalls[-1]
Check 'create FB: subtype 604, vInfo 1 (ST)' ($c.Path -eq "$P^POUs^FB_N" -and $c.ItemType -eq 604 -and $call[1] -eq 604 -and $call[2] -eq 1) (($call | ConvertTo-Json -Compress))
$c = & $mod { param($s, $p) New-TcPlcObject -SysManager $s -ParentPath "$p^DUTs" -Name ST_N -SubType 606 -Declaration "TYPE ST_N :`r`nSTRUCT`r`nEND_STRUCT`r`nEND_TYPE" } $sm $P
Check 'create DUT: declaration written + read back' ($c.ItemType -eq 606 -and $c.Declaration -like 'TYPE ST_N*' -and $null -eq $global:MockCreateCalls[-1][2]) ''
$err = $null
try { & $mod { param($s, $p) New-TcPlcObject -SysManager $s -ParentPath "$p^DUTs" -Name ST_X -SubType 606 } $sm $P | Out-Null } catch { $err = $_.Exception.Message }
Check 'create existing -> exists' ($err -like 'exists:*') $err
$err = $null
try { & $mod { param($s, $p) New-TcPlcObject -SysManager $s -ParentPath "$p^DUTs" -Name ST_Y -SubType 610 } $sm $P | Out-Null } catch { $err = $_.Exception.Message }
Check 'create with wrong subtype throws' ($err -like '*TREEITEMTYPE_PLCITFMETH*') $err
$r = & $mod { param($m) New-TcAdsErrorResult -ErrorRecord ([Exception]::new($m)) -DefaultCode 'DUT_CREATE_FAILED' -MessagePrefix 'Failed to add DUT' } 'exists: x'
Check 'DUT_CREATE_FAILED has a hint' ($r.error.code -eq 'DUT_CREATE_FAILED' -and $r.error.hint -like '*Write-TcPouCode*') ($r | ConvertTo-Json -Compress)

"failed: $fail"
exit $fail
