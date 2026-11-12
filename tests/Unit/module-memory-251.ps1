# Unit: #251 tests/Unit/lib/ModuleMemory.ps1 restores NESTED module state. Save-UnitModuleMemory /
# Restore-UnitModuleMemory used to copy one level only: a test that changed an inner hashtable,
# list item or object property leaked into the next case. Now known containers are copied
# recursively (depth limit 8) and a generic collection that holds mutable items throws at Save.
# No IDE / ADS / runtime; only $script:Unit* variables of the imported module are touched.
#   powershell.exe -NoProfile -File tests/Unit/module-memory-251.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
. (Join-Path $PSScriptRoot 'lib\ModuleMemory.ps1')
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 400) { $Detail = $Detail.Substring(0, 400) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}
function Get-Nested { & $mod { , $script:UnitNested251 } }   # comma: a HashSet would be enumerated

& $mod {
    $o = [ordered]@{}; $o['k'] = @{ v = 1 }
    $script:UnitNested251 = @{
        Inner   = @{ Value = 1; Deeper = @{ Value = 'a' } }
        List    = [System.Collections.ArrayList]@(@{ Value = 1 })
        Array   = @(@{ Value = 1 }, 2)
        Obj     = [PSCustomObject]@{ Value = 1; Inner = @{ Value = 1 } }
        Ordered = $o
    }
}
$snap = Save-UnitModuleMemory $mod
& $mod {
    $n = $script:UnitNested251
    $n.Inner.Value = 2; $n.Inner.Deeper.Value = 'b'; $n.Inner.Added = 1
    $n.List[0].Value = 2; $null = $n.List.Add('x')
    $n.Array[0].Value = 2
    $n.Obj.Value = 2; $n.Obj.Inner.Value = 2
    $n.Ordered['k'].v = 2
}
Restore-UnitModuleMemory $mod $snap
$n = Get-Nested
Check 'nested hashtable restored (2 levels, added key gone)' ($n.Inner.Value -eq 1 -and $n.Inner.Deeper.Value -eq 'a' -and -not $n.Inner.ContainsKey('Added')) "$($n.Inner.Value) $($n.Inner.Deeper.Value) $($n.Inner.Keys -join ',')"
Check 'ArrayList item and count restored' ($n.List.Count -eq 1 -and $n.List[0].Value -eq 1) "count $($n.List.Count) value $($n.List[0].Value)"
Check 'array item restored' ($n.Array[0].Value -eq 1 -and $n.Array[1] -eq 2) "$($n.Array[0].Value)"
Check 'PSCustomObject property and inner hashtable restored' ($n.Obj.Value -eq 1 -and $n.Obj.Inner.Value -eq 1) "$($n.Obj.Value) $($n.Obj.Inner.Value)"
Check 'ordered dictionary inner value restored' ($n.Ordered['k'].v -eq 1) "$($n.Ordered['k'].v)"

# a second Restore from the same snapshot is clean too (the snapshot itself was not mutated)
& $mod { $script:UnitNested251.Inner.Deeper.Value = 'c' }
Restore-UnitModuleMemory $mod $snap
Check 'second Restore from the same snapshot' ((Get-Nested).Inner.Deeper.Value -eq 'a') "$((Get-Nested).Inner.Deeper.Value)"

# deeper than the limit -> Save throws (no silent shallow copy)
& $mod { $d = @{ Value = 0 }; for ($i = 0; $i -lt 12; $i++) { $d = @{ Next = $d } }; $script:UnitNested251 = $d }
$deepErr = $null
try { $null = Save-UnitModuleMemory $mod } catch { $deepErr = $_.Exception.Message }
Check 'nesting deeper than 8 -> Save throws' ($null -ne $deepErr -and $deepErr -match 'deeper than 8') "$deepErr"

# a generic collection with mutable items -> Save throws (it can only be copied shallow)
& $mod { $l = [System.Collections.Generic.List[object]]::new(); $l.Add(@{ Value = 1 }); $script:UnitNested251 = $l }
$genErr = $null
try { $null = Save-UnitModuleMemory $mod } catch { $genErr = $_.Exception.Message }
Check 'generic collection with a hashtable item -> Save throws' ($null -ne $genErr -and $genErr -match 'mutable') "$genErr"

# a generic collection of plain values is still copied (as before)
& $mod { $h = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase); $null = $h.Add('A'); $script:UnitNested251 = $h }
$snap2 = Save-UnitModuleMemory $mod
& $mod { $null = $script:UnitNested251.Add('B') }
Restore-UnitModuleMemory $mod $snap2
$h = Get-Nested
Check 'generic HashSet of strings: items and comparer restored' ($h.Count -eq 1 -and $h.Contains('a')) "count $($h.Count)"

& $mod { Remove-Variable -Name UnitNested251 -Scope Script -ErrorAction SilentlyContinue }
"failed: $fail"
exit $fail
