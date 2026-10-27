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
Check 'entry lists both changes in order' ((Get-Reasons $e)['code-changed'] -eq 'PLC code changed by Write-TcPouCode MAIN [implementation], Write-TcPouCode FB_X [write failed]') ($e | ConvertTo-Json -Compress)

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
Check 'cap: (+2 earlier) and P3..P10' ($cc -like 'PLC code changed by (+2 earlier), Write-TcPouCode P3 *' -and $cc -like '*P10 `[implementation`]' -and $cc -notlike '*P1 *' -and $cc -notlike '*P2 *') $cc
$again = & $mod { param($t) Join-TcCodeChangedReason -Older $t -Newer $t } $cc
Check 'join of the same text is stable' ($again -eq $cc) $again
$null = Register 'Write-TcPouCode P5 [implementation]'
$cc2 = (Get-Reasons (Get-Entry))['code-changed']
Check 'a repeated change moves to the end, not listed twice' ($cc2 -like '*P10 `[implementation`], Write-TcPouCode P5 `[implementation`]' -and ([regex]::Matches($cc2, 'P5 ')).Count -eq 1) $cc2

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

Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item Env:\TCAUTO_STATE_DIR -ErrorAction SilentlyContinue
"failed: $fail"
exit [Math]::Min($fail, 255)
