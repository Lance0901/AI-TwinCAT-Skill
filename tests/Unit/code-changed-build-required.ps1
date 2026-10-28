# Unit: BUILD_REQUIRED kind 'code-changed' (#65), no IDE needed. The state file goes to a temp
# TCAUTO_STATE_DIR. Covers: the reason / kind merge (a code-changed never hides a platform-switch
# or unverified-build, the list of changes is capped), the '<unknown>' key, a state file that
# cannot be written (data.stateWarning, the entry still blocks in this process), the
# Enter-TcPlcOnline refusal (message + hint name code-changed and the cmdlet), Clear on a complete
# build, and the recording cmdlets Add-TcLibrary / New-TcProject on mock COM objects
# (Write-TcPouCode / Add-TcPou / Add-TcDut / Add-TcGvl: tests/Unit/plc-object-kind.ps1).
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Unit/code-changed-build-required.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
$stateRoot = Join-Path $env:TEMP ("tcauto-unit-cc-{0}" -f [guid]::NewGuid().ToString('N'))
$env:TCAUTO_STATE_DIR = Join-Path $stateRoot 'state'
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 400) { $Detail = $Detail.Substring(0, 400) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}
$stateFile = Join-Path $env:TCAUTO_STATE_DIR 'build-required.json'
$sln = Join-Path $stateRoot 'Demo\Demo.sln'
$null = New-Item -ItemType Directory -Path (Split-Path -Parent $sln) -Force
Set-Content -LiteralPath $sln -Value '' -Encoding ASCII

function Set-Sln([string]$Path) { & $mod { param($p) $script:TcSolutionPath = $p } $Path }
function Get-Entry { & $mod { Get-TcBuildRequired } }
function Get-Reasons($e) { & $mod { param($x) Get-TcBuildRequiredReasons $x } $e }
function Reset-State {
    & $mod { $script:TcBuildRequiredLocal = @{} }
    Remove-Item -Path (Join-Path $env:TCAUTO_STATE_DIR 'build-required.json*') -Force -ErrorAction SilentlyContinue
}
function Register([string]$Change, $Result = $null) { & $mod { param($r, $c) Register-TcCodeChange -Result $r -Change $c } $Result $Change }
function Mark([string]$Kind, [string]$Reason) { & $mod { param($k, $r) Set-TcBuildRequired -Kind $k -Reason $r -WarningAction SilentlyContinue } $Kind $Reason }

Set-Sln $sln
Reset-State

# --- recorded in the file, kind code-changed, data.buildRequired on the result
$res = [PSCustomObject]@{ success = $true; data = [PSCustomObject]@{ pou = 'MAIN' } }
$out = Register 'Write-TcPouCode MAIN [implementation]' $res
Check 'result gets data.buildRequired, no stateWarning' ($out.data.buildRequired -eq 'PLC code changed by Write-TcPouCode MAIN [implementation]' -and $out.data.pou -eq 'MAIN' -and $null -eq $out.data.PSObject.Properties['stateWarning']) ($out | ConvertTo-Json -Compress)
$json = Get-Content -Raw -LiteralPath $stateFile | ConvertFrom-Json
$key = @($json.PSObject.Properties.Name)[0]
$fe = $json.$key
Check 'file entry: kind code-changed, reasons.code-changed, solution path' ($fe.kind -eq 'code-changed' -and $fe.reasons.'code-changed' -like '*Write-TcPouCode MAIN*' -and $fe.solution -eq $sln -and $key -eq $sln.ToLowerInvariant()) ($fe | ConvertTo-Json -Compress)
$res2 = [PSCustomObject]@{ success = $false; error = [PSCustomObject]@{ message = 'x'; code = 'POU_WRITE_FAILED' } }
$out = Register 'Write-TcPouCode FB_X [write failed]' $res2
Check 'failure result without data gets data.buildRequired' ($out.data.buildRequired -like '*FB_X*' -and $out.error.code -eq 'POU_WRITE_FAILED') ($out | ConvertTo-Json -Compress)
$e = Get-Entry
Check 'entry lists both changes in order' ((Get-Reasons $e)['code-changed'] -eq 'PLC code changed by Write-TcPouCode MAIN [implementation] | Write-TcPouCode FB_X [write failed]') ($e | ConvertTo-Json -Compress)

# --- a code-changed does not hide a more serious kind (#65 point 4)
Reset-State
$null = Mark 'unverified-build' 'the last Build-TcProject (LIBRARY_UNRESOLVED) did not prove that the PLC code was compiled'
$null = Register 'Add-TcPou FB_New'
$e = Get-Entry
$r = Get-Reasons $e
Check 'unverified-build + code-changed: kind unverified-build, both reasons kept' ($e.kind -eq 'unverified-build' -and $r.Contains('unverified-build') -and $r['code-changed'] -like '*Add-TcPou FB_New') ($e | ConvertTo-Json -Compress)
Check 'reason text lists unverified-build first' ($e.reason -like 'the last Build-TcProject*; and PLC code changed by Add-TcPou FB_New') $e.reason
$json = Get-Content -Raw -LiteralPath $stateFile | ConvertFrom-Json
Check 'file entry kind unverified-build too' ($json.PSObject.Properties.Value[0].kind -eq 'unverified-build') ''
$null = Mark 'platform-switch' "solution platform switched from 'Release|TwinCAT RT (x64)' to 'Release|TwinCAT OS (x64)'"
$null = Register 'Write-TcPouCode MAIN [declaration]'
$e = Get-Entry
Check 'platform-switch wins as kind after a later code-changed' ($e.kind -eq 'platform-switch' -and @((Get-Reasons $e).Keys).Count -eq 3) ($e | ConvertTo-Json -Compress)
$cons = & $mod { param($x) Get-TcBuildRequiredConsequence -Entry $x } $e
Check 'consequence names all three kinds' ($cons -like '*previous platform*' -and $cons -like '*did not prove*' -and $cons -like '*changed after the last complete build*#65*') $cons

# --- list cap: the last 8 changes, older ones counted; merging the same entry again is stable
Reset-State
foreach ($i in 1..10) { $null = Register "Write-TcPouCode P$i [implementation]" }
$cc = (Get-Reasons (Get-Entry))['code-changed']
Check 'cap: (+2 earlier) and P3..P10' ($cc -like 'PLC code changed by (+2 earlier) | Write-TcPouCode P3 *' -and $cc -like '*P10 `[implementation`]' -and $cc -notlike '*P1 *' -and $cc -notlike '*P2 *') $cc
$again = & $mod { param($t) Join-TcCodeChangedReason -Older $t -Newer $t } $cc
Check 'join of the same text is stable' ($again -eq $cc) $again
$null = Register 'Write-TcPouCode P5 [implementation]'
$cc2 = (Get-Reasons (Get-Entry))['code-changed']
Check 'a repeated change moves to the end, not listed twice' ($cc2 -like '*P10 `[implementation`] | Write-TcPouCode P5 `[implementation`]' -and ([regex]::Matches($cc2, 'P5 ')).Count -eq 1) $cc2

# --- Enter-TcPlcOnline refuses with code-changed in message and hint
Reset-State
$sm = [PSCustomObject]@{ Mock = $true }
& $mod { param($s) $script:TcIdeProcessId = $null; $script:TcIdeConnected = $true; $script:TcDte = [PSCustomObject]@{}; $script:TcSysManager = $s } $sm
$null = Register 'Write-TcPouCode MAIN [implementation]'
foreach ($mode in 'Regular', 'Download', 'OnlineChange') {
    $l = Enter-TcPlcOnline -LoginMode $mode
    Check "PlcLogin $mode -> BUILD_REQUIRED naming code-changed + cmdlet" ((-not $l.success) -and $l.error.code -eq 'BUILD_REQUIRED' -and $l.error.message -like '*PLC code changed by Write-TcPouCode MAIN*' -and $l.error.message -like '*#65*' -and $l.error.hint -like 'Recorded: code-changed (PLC code changed by Write-TcPouCode MAIN*' -and $l.error.hint -like '*completeBuild*') ($l | ConvertTo-Json -Compress -Depth 5)
}
$snd = Send-TcPlcProgram
Check 'SendPlcProgram -> BUILD_REQUIRED' ($snd.error.code -eq 'BUILD_REQUIRED') ($snd | ConvertTo-Json -Compress -Depth 5)
# a fresh module instance (new process / MCP bridge) still sees the file entry
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
Set-Sln $sln
Check 'entry survives Import-Module -Force (file)' ((Get-Reasons (Get-Entry))['code-changed'] -like '*Write-TcPouCode MAIN*') ''
# complete build: Clear-TcBuildRequired (what Build-TcProject calls on completeBuild = true)
$cw = & $mod { Clear-TcBuildRequired }
Check 'Clear (complete build) removes it' ($null -eq $cw -and $null -eq (Get-Entry) -and -not (Test-Path -LiteralPath $stateFile)) "$cw"
& $mod { param($s) $script:TcIdeProcessId = $null; $script:TcIdeConnected = $true; $script:TcDte = [PSCustomObject]@{}; $script:TcSysManager = $s } $sm
$l = Enter-TcPlcOnline -LoginMode Download
Check 'after the clear PlcLogin gets past BUILD_REQUIRED' ($l.error.code -ne 'BUILD_REQUIRED') ($l | ConvertTo-Json -Compress -Depth 3)

# --- unknown solution path: '<unknown>' key, blocks every solution, cleared by any complete build
Reset-State
Set-Sln $null
$null = Register 'Write-TcPouCode MAIN [implementation]'
$json = Get-Content -Raw -LiteralPath $stateFile | ConvertFrom-Json
Check "no solution path -> '<unknown>' entry" (@($json.PSObject.Properties.Name) -contains '<unknown>') ($json | ConvertTo-Json -Compress -Depth 4)
Set-Sln 'C:\Other\Other.sln'
Check "'<unknown>' blocks another solution" ((Get-Reasons (Get-Entry))['code-changed'] -like '*MAIN*') ''
$null = & $mod { Clear-TcBuildRequired }
Check "'<unknown>' cleared by a complete build of any solution" ($null -eq (Get-Entry)) ''

# --- state file not writable: data.stateWarning, the entry still blocks in this process
Reset-State
Set-Sln $sln
$blocker = Join-Path $stateRoot 'a-file'
Set-Content -LiteralPath $blocker -Value 'not a directory' -Encoding ASCII
$savedDir = $env:TCAUTO_STATE_DIR
$env:TCAUTO_STATE_DIR = Join-Path $blocker 'state'
try {
    $out = Register 'Add-TcGvl GVL_A' ([PSCustomObject]@{ success = $true; data = [PSCustomObject]@{ name = 'GVL_A' } })
    Check 'unwritable: data.stateWarning says process only' ($out.data.stateWarning -like 'BUILD_REQUIRED was recorded in this process only*' -and $out.data.buildRequired -like '*Add-TcGvl GVL_A') ($out | ConvertTo-Json -Compress)
    $e = Get-Entry
    Check 'unwritable: the entry still blocks (state-unreadable or the memory entry)' ($null -ne $e) ($e | ConvertTo-Json -Compress)
}
finally { $env:TCAUTO_STATE_DIR = $savedDir }
Check 'unwritable: memory entry blocks after the directory is fine again' ((Get-Reasons (Get-Entry))['code-changed'] -like '*Add-TcGvl GVL_A') ''
Reset-State

# --- Add-TcLibrary on a mock References node
$global:LibMode = 'ok'
$refs = [PSCustomObject]@{ Mock = $true }
$refs | Add-Member -MemberType ScriptMethod -Name CreateChild -Value { param($n, $t) if ($global:LibMode -eq 'throw') { throw 'library not found (mock)' }; [PSCustomObject]@{ Name = $n } }
$proj = [PSCustomObject]@{ Mock = $true }
$proj | Add-Member -MemberType ScriptMethod -Name LookupChild -Value { param($n) if ($global:LibMode -eq 'norefs') { return $null }; $refs }.GetNewClosure()
$tipc = [PSCustomObject]@{ Mock = $true }
$tipc | Add-Member -MemberType ScriptMethod -Name Child -Value { param($i) $proj }.GetNewClosure()
$smLib = [PSCustomObject]@{ Mock = $true }
$smLib | Add-Member -MemberType ScriptMethod -Name LookupTreeItem -Value { param($p) $tipc }.GetNewClosure()
& $mod { param($s) $script:TcIdeConnected = $true; $script:TcDte = [PSCustomObject]@{}; $script:TcSysManager = $s } $smLib
$r = Add-TcLibrary -Name Tc2_Standard
Check 'Add-TcLibrary success -> recorded' ($r.success -and $r.data.buildRequired -eq 'PLC code changed by Add-TcLibrary Tc2_Standard (version *)') ($r | ConvertTo-Json -Compress)
Reset-State
$global:LibMode = 'norefs'
$r = Add-TcLibrary -Name Tc2_Standard
Check 'Add-TcLibrary REFS_NOT_FOUND (before CreateChild) -> nothing recorded' ((-not $r.success) -and $r.error.code -eq 'REFS_NOT_FOUND' -and $null -eq (Get-Entry)) ($r | ConvertTo-Json -Compress)
$global:LibMode = 'throw'
$r = Add-TcLibrary -Name Tc3_Missing -Version '3.3.0.0'
Check 'Add-TcLibrary CreateChild throws -> failure, recorded (conservative)' ((-not $r.success) -and $r.data.buildRequired -eq 'PLC code changed by Add-TcLibrary Tc3_Missing (version 3.3.0.0) [failed after CreateChild]' -and $null -ne (Get-Entry)) ($r | ConvertTo-Json -Compress)
Reset-State

# --- New-TcProject on a mock DTE: the NEW solution is recorded
$newPlc = [PSCustomObject]@{ Mock = $true }
$newPlc | Add-Member -MemberType ScriptMethod -Name CreateChild -Value { param($a, $b, $c, $d) [PSCustomObject]@{ Name = $a } }
$newSm = [PSCustomObject]@{ Mock = $true }
$newSm | Add-Member -MemberType ScriptMethod -Name LookupTreeItem -Value { param($p) $newPlc }.GetNewClosure()
$solution = [PSCustomObject]@{ Mock = $true }
$solution | Add-Member -MemberType ScriptMethod -Name Create -Value { param($a, $b) }
$solution | Add-Member -MemberType ScriptMethod -Name AddFromTemplate -Value { param($a, $b, $c, $d) [PSCustomObject]@{ Object = $newSm } }.GetNewClosure()
$solution | Add-Member -MemberType ScriptMethod -Name SaveAs -Value { param($a) Set-Content -LiteralPath $a -Value '' -Encoding ASCII }
& $mod { param($s) $script:TcIdeProcessId = $null; $script:TcIdeConnected = $true; $script:TcDte = [PSCustomObject]@{ Solution = $s }; $script:TcSolutionPath = 'C:\Old\Old.sln' } $solution
$r = New-TcProject -Name NewDemo -Path $stateRoot
$newSln = Join-Path $stateRoot 'NewDemo\NewDemo.sln'
$json = Get-Content -Raw -LiteralPath $stateFile | ConvertFrom-Json
Check 'New-TcProject success -> recorded for the NEW solution' ($r.success -and $r.data.buildRequired -eq 'PLC code changed by New-TcProject NewDemo' -and @($json.PSObject.Properties.Name) -contains $newSln.ToLowerInvariant() -and @($json.PSObject.Properties.Name) -notcontains 'c:\old\old.sln') (($r | ConvertTo-Json -Compress) + ' ' + ($json | ConvertTo-Json -Compress -Depth 4))
Set-Sln 'C:\Old\Old.sln'
Check 'the previous solution is not blocked by it' ($null -eq (Get-Entry)) ''
Reset-State
$solution | Add-Member -Force -MemberType ScriptMethod -Name Create -Value { param($a, $b) throw 'create failed (mock)' }
$r = New-TcProject -Name NewDemo2 -Path $stateRoot
Check 'New-TcProject failure -> nothing recorded' ((-not $r.success) -and $null -eq (Get-Entry) -and -not (Test-Path -LiteralPath $stateFile)) ($r | ConvertTo-Json -Compress)

Reset-State
# failure AFTER Solution.Create (PR #71 review): the IDE holds the new solution, so the module's
# path becomes unknown and the change is recorded under '<unknown>' (blocks every solution)
$solution | Add-Member -Force -MemberType ScriptMethod -Name Create -Value { param($a, $b) }
$solution | Add-Member -Force -MemberType ScriptMethod -Name AddFromTemplate -Value { param($a, $b, $c, $d) throw 'template failed (mock)' }
# #29 session record of this "IDE" (our own pid, alive) in a temp LOCALAPPDATA: it must be removed
$savedLocal = $env:LOCALAPPDATA
$helper = $null
try {
    $env:LOCALAPPDATA = Join-Path $stateRoot 'localappdata'
    # a second live process whose record must survive (pid + start time of a running process)
    $helper = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 120' -WindowStyle Hidden -PassThru
    & $mod { param($p, $h) $script:TcSolutionPath = 'C:\Old\Old.sln'; $script:TcIdeProcessId = $p; Save-TcIdeSolutionRecord -ProcessId $h -Solution 'C:\Keep\Keep.sln'; Save-TcIdeSolutionRecord -ProcessId $p -Solution 'C:\Old\Old.sln' } $PID $helper.Id
    $recBefore = & $mod { param($p) Get-TcIdeSolutionRecord -ProcessId $p } $PID
    $r = New-TcProject -Name NewDemo3 -Path $stateRoot
    $recAfter = & $mod { param($p) Get-TcIdeSolutionRecord -ProcessId $p } $PID
    $recOther = & $mod { param($p) Get-TcIdeSolutionRecord -ProcessId $p } $helper.Id
    Check 'New-TcProject failure after Solution.Create -> #29 session record of the IDE removed, other live record kept' ($recBefore -eq 'C:\Old\Old.sln' -and $null -eq $recAfter -and $recOther -eq 'C:\Keep\Keep.sln') "before=$recBefore after=$recAfter other=$recOther"
    # an unreadable record file is left exactly as it is
    $recFile = & $mod { Get-TcIdeSolutionRecordPath }
    Set-Content -LiteralPath $recFile -Value '{ not json' -Encoding ASCII
    $rawBefore = Get-Content -Raw -LiteralPath $recFile
    & $mod { param($p) Remove-TcIdeSolutionRecord -ProcessId $p } $PID
    Check 'Remove-TcIdeSolutionRecord on a corrupt record file leaves it unchanged' ((Get-Content -Raw -LiteralPath $recFile) -eq $rawBefore) ''
}
finally {
    $env:LOCALAPPDATA = $savedLocal
    if ($null -ne $helper) { Stop-Process -Id $helper.Id -Force -ErrorAction SilentlyContinue }
    & $mod { $script:TcIdeProcessId = $null }
}
$json = Get-Content -Raw -LiteralPath $stateFile | ConvertFrom-Json
$solNow = & $mod { $script:TcSolutionPath }
Check 'New-TcProject failure after Solution.Create -> path unknown, <unknown> recorded' ((-not $r.success) -and $null -eq $solNow -and $r.data.buildRequired -eq 'PLC code changed by New-TcProject NewDemo3 [failed after Solution.Create]' -and @($json.PSObject.Properties.Name) -contains '<unknown>') (($r | ConvertTo-Json -Compress) + ' ' + ($json | ConvertTo-Json -Compress -Depth 4))
Set-Sln 'C:\Old\Old.sln'
Check 'and it blocks the previous solution too' ((Get-Reasons (Get-Entry))['code-changed'] -like '*NewDemo3*') ''
Reset-State

# --- separator (PR #71 review): a name with ', ' is not split, '|' in a change is replaced
Set-Sln $sln
$null = Register 'Reset-TcSolution A, B.sln (project reloaded from disk)'
$null = Register 'Write-TcPouCode X|Y [implementation]'
$null = Register 'Reset-TcSolution A, B.sln (project reloaded from disk)'
$cc = (Get-Reasons (Get-Entry))['code-changed']
Check "', ' inside a name kept, '|' replaced, repeated change listed once" ($cc -eq 'PLC code changed by Write-TcPouCode X/Y [implementation] | Reset-TcSolution A, B.sln (project reloaded from disk)') $cc
Reset-State

# --- Register-TcCodeChange when Set-TcBuildRequired throws: '<unknown>' in memory, warning
$origSet = & $mod { ${function:Set-TcBuildRequired} }
& $mod { Set-Item -Path function:script:Set-TcBuildRequired -Value { throw 'state broken (mock)' } }
$out = Register 'Add-TcPou FB_Z' ([PSCustomObject]@{ success = $true; data = [PSCustomObject]@{} })
& $mod { param($f) Set-Item -Path function:script:Set-TcBuildRequired -Value $f } $origSet
$mem = & $mod { $script:TcBuildRequiredLocal['<unknown>'] }
Check 'Set-TcBuildRequired throws -> <unknown> memory entry + stateWarning' ($out.data.stateWarning -like "*kept in this process only as '<unknown>'*" -and $mem.reasons.'code-changed' -like '*Add-TcPou FB_Z' -and (Get-Reasons (Get-Entry))['code-changed'] -like '*FB_Z') ($out | ConvertTo-Json -Compress)
Reset-State

# --- Reset-TcSolution (PR #71 review): failures after XAE reloaded the project from disk record
$global:DlgQueue = New-Object System.Collections.Queue
$global:ResetMode = @{}
$reloadDlg = @{ Title = 'TcXaeShell'; Text = 'The project file has been modified outside'; Kind = 'reload-prompt'; ReloadTarget = 'project'; Hwnd = 0; Buttons = @() }
$otherDlg = @{ Title = 'TcXaeShell'; Text = 'Assertion Failed (mock)'; Kind = 'unknown'; ReloadTarget = $null; Hwnd = 0; Buttons = @() }
$sol = [PSCustomObject]@{ Mock = $true }
$sol | Add-Member -MemberType ScriptProperty -Name FullName -Value { if ($global:ResetMode.FullName) { $global:ResetMode.FullName } else { $global:ResetSln } }
$sol | Add-Member -MemberType ScriptMethod -Name Close -Value { param($s) if ($global:ResetMode.CloseThrows) { throw 'close failed (mock)' } }
$sol | Add-Member -MemberType ScriptMethod -Name Open -Value { param($p) if ($global:ResetMode.OpenThrows) { throw 'open failed (mock)' } }
$docs = [PSCustomObject]@{ Count = 1 }
$docs | Add-Member -MemberType ScriptMethod -Name CloseAll -Value { param($m) if ($global:ResetMode.CloseAllThrows) { throw 'closeall failed (mock)' } }
$resetDte = [PSCustomObject]@{ Solution = $sol; Documents = $docs }
$global:ResetSln = $sln
$origFns = & $mod { @{ Dlg = ${function:Get-TcIdeModalDialog}; Rp = ${function:Close-TcReloadPrompt}; Conn = ${function:Connect-TcIde} } }
& $mod {
    Set-Item -Path function:script:Get-TcIdeModalDialog -Value { param($ProcessId) if ($global:DlgQueue.Count -gt 0) { $global:DlgQueue.Dequeue() } else { $null } }
    Set-Item -Path function:script:Close-TcReloadPrompt -Value { param($Dialog, $Answer, $TimeoutSec) @{ Sent = $true; Dismissed = $true; NextDialog = $null; Reason = 'mock' } }
    Set-Item -Path function:script:Connect-TcIde -Value { param($SolutionPath, $ProgId, [switch]$NoLaunch) [PSCustomObject]@{ success = $false; error = [PSCustomObject]@{ message = 'no IDE (mock)'; code = 'IDE_NOT_FOUND' } } }
}
function Start-Reset {
    param([object[]]$Dialogs, [hashtable]$Mode)
    Reset-State
    $global:DlgQueue.Clear(); foreach ($d in $Dialogs) { $global:DlgQueue.Enqueue($d) }
    $global:ResetMode = $Mode
    & $mod { param($d, $s) $script:TcIdeConnected = $true; $script:TcDte = $d; $script:TcSolutionPath = $s; $script:TcIdeProcessId = $null; $script:TcProgId = $null; $script:TcSysManager = $null } $resetDte $sln
    Reset-TcSolution -TimeoutSec 5
}
$r = Start-Reset -Dialogs @($reloadDlg, $otherDlg) -Mode @{}
Check 'Reset: Yes answered, then another modal -> IDE_MODAL_DIALOG, recorded' ((-not $r.success) -and $r.error.code -eq 'IDE_MODAL_DIALOG' -and $r.data.buildRequired -like '*Reset-TcSolution Demo.sln (project reloaded from disk, then modal dialog check failed)' -and (Get-Reasons (Get-Entry))['code-changed'] -like '*Demo.sln*') ($r | ConvertTo-Json -Compress -Depth 3)
$r = Start-Reset -Dialogs @($otherDlg) -Mode @{}
Check 'Reset: modal without a reload -> nothing recorded' ((-not $r.success) -and $r.error.code -eq 'IDE_MODAL_DIALOG' -and $null -eq $r.data.PSObject.Properties['buildRequired'] -and $null -eq (Get-Entry)) ($r | ConvertTo-Json -Compress -Depth 3)
$r = Start-Reset -Dialogs @() -Mode @{ FullName = 'C:\Other\Other.sln' }
Check 'Reset: RESET_SOLUTION_MISMATCH without a reload -> nothing recorded' ((-not $r.success) -and $r.error.code -eq 'RESET_SOLUTION_MISMATCH' -and $null -eq (Get-Entry)) ($r | ConvertTo-Json -Compress -Depth 3)
$r = Start-Reset -Dialogs @($reloadDlg) -Mode @{ CloseAllThrows = $true }
Check 'Reset: Yes answered, reconnect failed, Documents.CloseAll fails -> recorded' ((-not $r.success) -and $r.error.code -eq 'SOLUTION_CLOSE_FAILED' -and $r.data.answeredYes -eq $true -and $r.data.buildRequired -like '*then Documents.CloseAll failed)' -and $null -ne (Get-Entry)) ($r | ConvertTo-Json -Compress -Depth 3)
$r = Start-Reset -Dialogs @() -Mode @{ CloseAllThrows = $true }
Check 'Reset: Documents.CloseAll fails without a reload -> nothing recorded' ((-not $r.success) -and $r.error.code -eq 'SOLUTION_CLOSE_FAILED' -and $null -eq (Get-Entry)) ($r | ConvertTo-Json -Compress -Depth 3)
$r = Start-Reset -Dialogs @() -Mode @{ OpenThrows = $true }
Check 'Reset: Solution.Open fails -> PROJECT_OPEN_FAILED, recorded (half open)' ((-not $r.success) -and $r.error.code -eq 'PROJECT_OPEN_FAILED' -and $r.data.buildRequired -like '*Solution.Open failed, solution may be half open)' -and $null -ne (Get-Entry)) ($r | ConvertTo-Json -Compress -Depth 3)
$r = Start-Reset -Dialogs @() -Mode @{}
Check 'Reset: reopened, reconnect fails -> recorded' ((-not $r.success) -and $r.error.code -eq 'IDE_NOT_FOUND' -and $r.data.buildRequired -like '*Demo.sln (solution reopened from disk)' -and $null -ne (Get-Entry)) ($r | ConvertTo-Json -Compress -Depth 3)
# PR #71 re-review: -SolutionPath names another .sln than the one the IDE had open; the Yes reload
# happened in the open one, so both keys are recorded (Enable-TcConfig checks the module's key)
$otherSln = Join-Path $stateRoot 'Other\Other.sln'
$null = New-Item -ItemType Directory -Path (Split-Path -Parent $otherSln) -Force
Set-Content -LiteralPath $otherSln -Value '' -Encoding ASCII
function Get-StateKeys { if (Test-Path -LiteralPath $stateFile) { @((Get-Content -Raw -LiteralPath $stateFile | ConvertFrom-Json).PSObject.Properties.Name) } else { @() } }
$keySln = & $mod { param($p) ConvertTo-TcSolutionKey $p } $sln
$keyOther = & $mod { param($p) ConvertTo-TcSolutionKey $p } $otherSln
Reset-State
$global:DlgQueue.Clear(); $global:DlgQueue.Enqueue($reloadDlg); $global:DlgQueue.Enqueue($otherDlg)
$global:ResetMode = @{}
& $mod { param($d, $s) $script:TcIdeConnected = $true; $script:TcDte = $d; $script:TcSolutionPath = $s; $script:TcIdeProcessId = $null; $script:TcProgId = $null; $script:TcSysManager = $null } $resetDte $sln
$r = Reset-TcSolution -SolutionPath $otherSln -TimeoutSec 5
$keys = Get-StateKeys
Check 'Reset -SolutionPath other, Yes then modal -> both the open and the requested .sln recorded' ((-not $r.success) -and $keys -contains $keySln -and $keys -contains $keyOther) (($keys -join ', ') + ' ' + ($r | ConvertTo-Json -Compress -Depth 2))
# MISMATCH after a Yes reload: the solution the IDE reports is recorded as well
$r = Start-Reset -Dialogs @($reloadDlg) -Mode @{ FullName = $otherSln }
$keys = Get-StateKeys
Check 'Reset Yes, then RESET_SOLUTION_MISMATCH -> requested and open (.sln read back) recorded' ((-not $r.success) -and $r.error.code -eq 'RESET_SOLUTION_MISMATCH' -and $keys -contains $keySln -and $keys -contains $keyOther) (($keys -join ', ') + ' ' + ($r | ConvertTo-Json -Compress -Depth 2))
# PR #71 third review: three different solutions - module path A ($sln), -SolutionPath P
# ($otherSln), IDE reports B: after a Yes reload all three are recorded
$thirdSln = Join-Path $stateRoot 'Third\Third.sln'
$null = New-Item -ItemType Directory -Path (Split-Path -Parent $thirdSln) -Force
Set-Content -LiteralPath $thirdSln -Value '' -Encoding ASCII
$keyThird = & $mod { param($p) ConvertTo-TcSolutionKey $p } $thirdSln
Reset-State
$global:DlgQueue.Clear(); $global:DlgQueue.Enqueue($reloadDlg)
$global:ResetMode = @{ FullName = $thirdSln }
& $mod { param($d, $s) $script:TcIdeConnected = $true; $script:TcDte = $d; $script:TcSolutionPath = $s; $script:TcIdeProcessId = $null; $script:TcProgId = $null; $script:TcSysManager = $null } $resetDte $sln
$r = Reset-TcSolution -SolutionPath $otherSln -TimeoutSec 5
$keys = Get-StateKeys
Check 'Reset Yes, A / P / B all different, MISMATCH -> all three recorded' ((-not $r.success) -and $r.error.code -eq 'RESET_SOLUTION_MISMATCH' -and $keys -contains $keySln -and $keys -contains $keyOther -and $keys -contains $keyThird -and $keys.Count -eq 3) (($keys -join ', ') + ' ' + ($r | ConvertTo-Json -Compress -Depth 2))
# Yes-only success with -SolutionPath P while the module had A: both recorded
$okSm = [PSCustomObject]@{ Mock = $true }
$okSm | Add-Member -MemberType ScriptMethod -Name LookupTreeItem -Value { param($p) [PSCustomObject]@{ Name = 'TIPC' } }
$global:OkSm = $okSm
$connOrig = & $mod { ${function:Connect-TcIde} }
try {
    & $mod { Set-Item -Path function:script:Connect-TcIde -Value { param($SolutionPath, $ProgId, [switch]$NoLaunch) $script:TcSolutionPath = $SolutionPath; $script:TcSysManager = $global:OkSm; [PSCustomObject]@{ success = $true; data = [PSCustomObject]@{ ideProcessId = 0; selectedBy = 'solution-match'; sysManagerAvailable = $true; silentMode = $true } } } }
    Reset-State
    $global:DlgQueue.Clear(); $global:DlgQueue.Enqueue($reloadDlg)
    $global:ResetMode = @{ FullName = $otherSln }
    & $mod { param($d, $s) $script:TcIdeConnected = $true; $script:TcDte = $d; $script:TcSolutionPath = $s; $script:TcIdeProcessId = $null; $script:TcProgId = $null; $script:TcSysManager = $null } $resetDte $sln
    $r = Reset-TcSolution -SolutionPath $otherSln -TimeoutSec 5
    $keys = Get-StateKeys
    Check 'Reset Yes-only success with -SolutionPath P (module had A) -> both recorded' ($r.success -and $r.data.answeredYes -eq $true -and $keys -contains $keySln -and $keys -contains $keyOther -and $keys.Count -eq 2) (($keys -join ', ') + ' ' + ($r | ConvertTo-Json -Compress -Depth 2))
    # every state warning of the records is kept (Register-TcResetChange joins them with '; ')
    $origSet2 = & $mod { ${function:Set-TcBuildRequired} }
    try {
        & $mod { Set-Item -Path function:script:Set-TcBuildRequired -Value { param($Reason, $Kind, $SolutionPath) "warn for $([IO.Path]::GetFileName($SolutionPath))" } }
        Reset-State
        $global:DlgQueue.Clear(); $global:DlgQueue.Enqueue($reloadDlg)
        & $mod { param($d, $s) $script:TcIdeConnected = $true; $script:TcDte = $d; $script:TcSolutionPath = $s; $script:TcIdeProcessId = $null; $script:TcProgId = $null; $script:TcSysManager = $null } $resetDte $sln
        $r = Reset-TcSolution -SolutionPath $otherSln -TimeoutSec 5
        Check 'Reset with two records -> both state warnings joined' ($r.data.stateWarning -eq 'warn for Other.sln; warn for Demo.sln') "$($r.data.stateWarning)"
    }
    finally { & $mod { param($f) Set-Item -Path function:script:Set-TcBuildRequired -Value $f } $origSet2 }
}
finally {
    & $mod { param($f) Set-Item -Path function:script:Connect-TcIde -Value $f } $connOrig
}
& $mod { param($f) Set-Item -Path function:script:Get-TcIdeModalDialog -Value $f.Dlg; Set-Item -Path function:script:Close-TcReloadPrompt -Value $f.Rp; Set-Item -Path function:script:Connect-TcIde -Value $f.Conn } $origFns
Reset-State

Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item Env:\TCAUTO_STATE_DIR -ErrorAction SilentlyContinue
"failed: $fail"
exit [Math]::Min($fail, 255)
