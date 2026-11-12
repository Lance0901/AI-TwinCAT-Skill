# #241: "fresh module memory" without a second Import-Module -Force (about 2 s each).
#   $snap = Save-UnitModuleMemory $mod      right after Import-Module -Force + the mocks
#   Restore-UnitModuleMemory $mod $snap     later: that module instance is back to the snapshot:
#     - every $script:Tc* / $script:Unit* variable has its snapshot value (collections deep-copied, #251),
#       such variables created since are removed;
#     - every function visible in the module scope is the snapshot one again (a mock a test
#       installed later with "function script:X" is undone), functions created since are removed.
# All module state is $script:Tc* (checked 2026-11-12: no other $script: name in src/), the test mocks
# keep theirs in $script:Unit*. The snapshot belongs to ONE module instance (its scriptblocks are
# bound to it): take a new one after every Import-Module -Force.
# Use it only where a case needs clean memory. Where the test is about a NEW module instance (bridge
# restart: a new $script:TcModuleInstanceId, state read back from disk) keep Import-Module -Force.

# #251: known containers (hashtable, ordered dictionary, ArrayList, array, PSCustomObject) are copied
# recursively, so a test that changes an inner value cannot leak into the next case. Nesting deeper
# than 8 levels throws, and so does a generic collection (List / HashSet / Dictionary, copied shallow)
# that holds a mutable item: a new module variable of that shape must get its own copy here first.
# Anything else (strings, numbers, scriptblocks, COM / .NET objects) is kept by reference, as before.
$script:UnitModuleCopyMaxDepth = 8

function Test-UnitMutableValue([object]$Value) {
    $null -ne $Value -and $Value -isnot [string] -and (
        $Value -is [System.Collections.IDictionary] -or $Value -is [System.Collections.IList] -or
        $Value -is [System.Management.Automation.PSCustomObject])
}

function Copy-UnitModuleValue([object]$Value, [int]$Depth = 0) {
    if ($null -eq $Value) { return $null }
    if ($Depth -gt $script:UnitModuleCopyMaxDepth) {
        throw "Copy-UnitModuleValue: module value nested deeper than $($script:UnitModuleCopyMaxDepth) levels ($($Value.GetType().FullName)); extend tests/Unit/lib/ModuleMemory.ps1 (#251)"
    }
    if ($Value -is [hashtable]) {
        $h = $Value.Clone()   # keeps the comparer
        foreach ($k in @($h.Keys)) { $h[$k] = Copy-UnitModuleValue $Value[$k] ($Depth + 1) }
        return $h
    }
    if ($Value -is [System.Collections.Specialized.OrderedDictionary]) {
        $o = [ordered]@{}
        foreach ($k in $Value.Keys) { $o[$k] = Copy-UnitModuleValue $Value[$k] ($Depth + 1) }
        return $o
    }
    if ($Value -is [System.Collections.ArrayList]) {
        $l = New-Object System.Collections.ArrayList
        foreach ($item in $Value) { $null = $l.Add((Copy-UnitModuleValue $item ($Depth + 1))) }
        return , $l
    }
    if ($Value -is [System.Array]) {
        $a = $Value.Clone()
        for ($i = 0; $i -lt $a.Length; $i++) { if (Test-UnitMutableValue $a[$i]) { $a[$i] = Copy-UnitModuleValue $a[$i] ($Depth + 1) } }
        return , $a
    }
    if ($Value.GetType().IsGenericType -and $Value -is [System.Collections.IEnumerable]) {
        # List / HashSet / Dictionary: same type, same items, same comparer (when it has one); only
        # plain items, a mutable one would be shared with the snapshot
        foreach ($item in $Value) {
            $iv = if ($null -ne $item -and $item.GetType().IsGenericType -and $item.GetType().Name -like 'KeyValuePair*') { $item.Value } else { $item }
            if (Test-UnitMutableValue $iv) {
                throw "Copy-UnitModuleValue: $($Value.GetType().FullName) holds a mutable item ($($iv.GetType().FullName)) that would only be copied shallow; extend tests/Unit/lib/ModuleMemory.ps1 (#251)"
            }
        }
        $cmp = $Value.PSObject.Properties['Comparer']
        $ctorArgs = if ($null -ne $cmp) { @($Value, $cmp.Value) } else { @(, $Value) }
        return , ([Activator]::CreateInstance($Value.GetType(), $ctorArgs))
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $c = $Value.PSObject.Copy()
        foreach ($p in @($c.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' })) {
            if (Test-UnitMutableValue $p.Value) { $p.Value = Copy-UnitModuleValue $p.Value ($Depth + 1) }
        }
        return $c
    }
    return $Value
}

# The functions of the module scope: the function: drive seen from there also lists the global ones
# (powershell.exe -File runs the test script in the global scope, so its own helpers are there);
# only those whose Module is this module belong to it (module code and "function script:X" mocks).
function Get-UnitModuleFunction([System.Management.Automation.PSModuleInfo]$Module) {
    @(& $Module { Get-ChildItem -Path function: } | Where-Object { $null -ne $_.Module -and $_.Module.Name -eq $Module.Name })
}

function Save-UnitModuleMemory([System.Management.Automation.PSModuleInfo]$Module) {
    $vars = @{}
    foreach ($v in @(& $Module { Get-Variable -Scope Script | Where-Object { $_.Name -match '^(Tc|Unit)' -and ($_.Options -band 3) -eq 0 } })) {
        $vars[$v.Name] = Copy-UnitModuleValue $v.Value
    }
    $funcs = @{}
    foreach ($f in @(Get-UnitModuleFunction $Module)) { $funcs[$f.Name] = $f.ScriptBlock }
    @{ Vars = $vars; Funcs = $funcs }
}

function Restore-UnitModuleMemory([System.Management.Automation.PSModuleInfo]$Module, [hashtable]$Snapshot) {
    $copies = @{}
    foreach ($k in $Snapshot.Vars.Keys) { $copies[$k] = Copy-UnitModuleValue $Snapshot.Vars[$k] }
    # Dot-sourced into the module scope: Remove-Item function:script:X from a child scope (& $Module)
    # reports success but leaves the function there (measured 2026-11-12, PS 5.1). The helper
    # variables are named __unit* (not Tc* / Unit*) and removed at the end.
    . $Module {
        param($__unitVars, $__unitFuncs, $__unitModuleName)
        foreach ($__unitV in @(Get-Variable -Scope Script | Where-Object { $_.Name -match '^(Tc|Unit)' -and ($_.Options -band 3) -eq 0 })) {
            if (-not $__unitVars.ContainsKey($__unitV.Name)) { Remove-Variable -Name $__unitV.Name -Scope Script -Force }
        }
        foreach ($__unitK in $__unitVars.Keys) { Set-Variable -Name $__unitK -Scope Script -Value $__unitVars[$__unitK] }
        foreach ($__unitF in @(Get-ChildItem -Path function: | Where-Object { $null -ne $_.Module -and $_.Module.Name -eq $__unitModuleName })) {
            if (-not $__unitFuncs.ContainsKey($__unitF.Name)) { Remove-Item -LiteralPath "function:$($__unitF.Name)" -Force }
            elseif (-not [object]::ReferenceEquals($__unitF.ScriptBlock, $__unitFuncs[$__unitF.Name])) { Set-Item -LiteralPath "function:$($__unitF.Name)" -Value $__unitFuncs[$__unitF.Name] }
        }
        Remove-Variable -Name __unitVars, __unitFuncs, __unitModuleName, __unitV, __unitK, __unitF -ErrorAction SilentlyContinue
    } $copies $Snapshot.Funcs $Module.Name
}
