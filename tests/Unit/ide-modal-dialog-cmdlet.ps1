# Unit: #86 Get-TcIdeModalDialog is a public JSON cmdlet (the private scan is Find-TcIdeModalDialog),
# and every cmdlet name that an error hint tells the user to run is exported. No IDE: the private
# scan is replaced inside the module scope.
#   powershell.exe -NoProfile -File tests/Unit/ide-modal-dialog-cmdlet.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
$env:TCAUTO_STATE_DIR = Join-Path $env:TEMP ("tcauto-unit-state-{0}" -f [guid]::NewGuid().ToString('N'))
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 400) { $Detail = $Detail.Substring(0, 400) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}

# 1. exported, and the private scan is not
$cmd = Get-Command -Module TwinCATAutomation -Name Get-TcIdeModalDialog -ErrorAction SilentlyContinue
Check 'exported' ($null -ne $cmd) ''
Check 'private-not-exported' ($null -eq (Get-Command -Module TwinCATAutomation -Name Find-TcIdeModalDialog -ErrorAction SilentlyContinue)) ''
Check 'private-exists' ($null -ne (& $mod { Get-Command Find-TcIdeModalDialog -ErrorAction SilentlyContinue })) ''

# 2. no pid known -> NOT_CONNECTED with a next-step hint
& $mod { $script:TcIdeProcessId = $null }
$r = Get-TcIdeModalDialog
Check 'nopid-fails' ($r.success -eq $false -and $r.error.code -eq 'NOT_CONNECTED') "$($r.error.code)"
Check 'nopid-hint' (-not [string]::IsNullOrWhiteSpace($r.error.hint) -and $r.error.hint -match 'Connect-TcIde') "$($r.error.hint)"

# 3. no dialog -> success, data.dialog null, data.ideProcessId
& $mod { function script:Find-TcIdeModalDialog { [CmdletBinding()] param([int]$ProcessId = 0, [int]$TimeoutSec = 5) $null } }
$r = Get-TcIdeModalDialog -ProcessId 4242
Check 'none-success' ($r.success -eq $true) ''
Check 'none-dialog-null' ($null -eq $r.data.dialog) ''
Check 'none-pid' ($r.data.ideProcessId -eq 4242) "$($r.data.ideProcessId)"

# 4. a dialog -> data.dialog has the MCP GetIdeModalDialog shape; pid defaults to the connected one
$global:SeenPid = $null; $global:SeenTimeout = $null
& $mod {
    $script:TcIdeProcessId = 777
    function script:Find-TcIdeModalDialog {
        [CmdletBinding()] param([int]$ProcessId = 0, [int]$TimeoutSec = 5)
        $global:SeenPid = $ProcessId; $global:SeenTimeout = $TimeoutSec
        @{ Title = 'Microsoft Visual Studio'; Text = 'File has been changed outside the environment. Reload the new file?'
           Kind = 'reload-prompt'; ReloadTarget = 'file'; Hwnd = [long]66052
           Buttons = @(@{ Id = 6; Name = 'Yes' }, @{ Id = 7; Name = 'No' }) }
    }
}
$r = Get-TcIdeModalDialog -TimeoutSec 9
Check 'dlg-success' ($r.success -eq $true) ''
Check 'dlg-default-pid' ($global:SeenPid -eq 777 -and $r.data.ideProcessId -eq 777) "$($global:SeenPid)"
Check 'dlg-timeout-passed' ($global:SeenTimeout -eq 9) "$($global:SeenTimeout)"
$d = $r.data.dialog
Check 'dlg-fields' ($d.title -eq 'Microsoft Visual Studio' -and $d.kind -eq 'reload-prompt' -and $d.reloadTarget -eq 'file' -and $d.hwnd -eq 66052) ($d | ConvertTo-Json -Compress)
Check 'dlg-text' ($d.text -match 'Reload the new file') ''
Check 'dlg-buttons' (@($d.buttons).Count -eq 2 -and $d.buttons[0].id -eq 6 -and $d.buttons[0].name -eq 'Yes' -and $d.buttons[1].id -eq 7) ($d.buttons | ConvertTo-Json -Compress)
$names = @($d.PSObject.Properties.Name) -join ','
Check 'dlg-shape' ($names -eq 'title,text,kind,reloadTarget,hwnd,buttons') $names

# an unclassified dialog: kind unknown, reloadTarget null, no buttons
& $mod { function script:Find-TcIdeModalDialog { [CmdletBinding()] param([int]$ProcessId = 0, [int]$TimeoutSec = 5) @{ Title = 'Assertion Failed'; Text = 'boom' } } }
$r = Get-TcIdeModalDialog -ProcessId 1
Check 'unknown-kind' ($r.data.dialog.kind -eq 'unknown' -and $null -eq $r.data.dialog.reloadTarget -and $null -eq $r.data.dialog.hwnd -and @($r.data.dialog.buttons).Count -eq 0) ($r.data.dialog | ConvertTo-Json -Compress)

# a throwing scan never throws out of the cmdlet, and is NOT "no dialog" (#42)
& $mod { function script:Find-TcIdeModalDialog { [CmdletBinding()] param([int]$ProcessId = 0, [int]$TimeoutSec = 5) throw 'scan boom' } }
$r = Get-TcIdeModalDialog -ProcessId 1
Check 'throwing-scan' ($r.success -eq $false -and $r.error.code -eq 'MODAL_SCAN_INCOMPLETE' -and $r.data.scanComplete -eq $false -and $r.data.modalScan.reason -eq 'error' -and $null -eq $r.data.dialog) ($r | ConvertTo-Json -Compress -Depth 4)

# #42: a scan that ran out of time -> MODAL_SCAN_INCOMPLETE with a next-step hint, never success + dialog null
& $mod { function script:Find-TcIdeModalDialog { [CmdletBinding()] param([int]$ProcessId = 0, [int]$TimeoutSec = 5) New-TcModalScanIncomplete -ProcessId $ProcessId -Reason 'timeout' -TimeoutSec $TimeoutSec -ElapsedMs 5001 -Message 'mock timeout' } }
$r = Get-TcIdeModalDialog -ProcessId 31 -TimeoutSec 5
Check 'incomplete-fails' ($r.success -eq $false -and $r.error.code -eq 'MODAL_SCAN_INCOMPLETE') ($r | ConvertTo-Json -Compress -Depth 4)
Check 'incomplete-data' ($r.data.scanComplete -eq $false -and $null -eq $r.data.dialog -and $r.data.ideProcessId -eq 31 -and $r.data.modalScan.reason -eq 'timeout' -and $r.data.modalScan.timeoutSec -eq 5) ($r.data | ConvertTo-Json -Compress -Depth 4)
Check 'incomplete-hint' ($r.error.hint -match 'Get-TcIdeModalDialog -TimeoutSec' -and $r.error.hint -match 'scanComplete') "$($r.error.hint)"

# scanComplete true on the success paths
& $mod { function script:Find-TcIdeModalDialog { [CmdletBinding()] param([int]$ProcessId = 0, [int]$TimeoutSec = 5) $null } }
$r = Get-TcIdeModalDialog -ProcessId 31
Check 'complete-none-flag' ($r.success -eq $true -and $r.data.scanComplete -eq $true -and $null -eq $r.data.dialog) ($r.data | ConvertTo-Json -Compress)

# 5. #86 guard: every cmdlet an error hint tells the user to run must be exported
$hints = & $mod { $script:TcErrorHints }
$exported = @((Get-Module TwinCATAutomation).ExportedFunctions.Keys)
$verbs = 'Add|Build|Clear|Connect|Disconnect|Enable|Enter|Exit|Export|Find|Get|Import|Install|Invoke|Lock|New|Open|Read|Remove|Reset|Save|Set|Test|Uninstall|Wait|Watch|Write'
$missing = New-Object System.Collections.Generic.List[string]
$seen = 0
foreach ($k in $hints.Keys) {
    foreach ($m in [regex]::Matches([string]$hints[$k], "\b(?:$verbs)-Tc[A-Za-z]+")) {
        $seen++
        if ($exported -notcontains $m.Value) { $missing.Add("$k -> $($m.Value)") }
    }
}
Check 'hints-scanned' ($seen -gt 50) "$seen cmdlet mentions in $($hints.Count) hints"
Check 'hints-cmdlets-exported' ($missing.Count -eq 0) ($missing -join '; ')

"failed: $fail"
exit $fail
