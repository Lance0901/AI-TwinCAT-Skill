# Unit: New-TcProject templates (#70), no IDE needed. A mock DTE records the AddFromTemplate /
# CreateChild arguments; Resolve-TcProjectTemplate is replaced inside the module scope (or run for
# real against a temp TWINCAT3DIR). The state file goes to the isolated TCAUTO_STATE_DIR.
#   powershell.exe -NoProfile -File tests/Unit/new-project-template.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 400) { $Detail = $Detail.Substring(0, 400) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}

$root = Join-Path $env:TEMP ("tcauto-unit-70-{0}" -f [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root -Force
$global:Tc70 = @{ Calls = @(); Create = 0 }

# mock DTE: records every call
$plcNode = [PSCustomObject]@{ Mock = $true }
$plcNode | Add-Member -MemberType ScriptMethod -Name CreateChild -Value { param($a, $b, $c, $d) $global:Tc70.Calls += ,@('CreateChild', $a, $b, $c, $d); [PSCustomObject]@{ Name = $a } }
$sm = [PSCustomObject]@{ Mock = $true }
$sm | Add-Member -MemberType ScriptMethod -Name LookupTreeItem -Value { param($p) $plcNode }.GetNewClosure()
$solution = [PSCustomObject]@{ Mock = $true; IsOpen = $false; FullName = '' }
$solution | Add-Member -MemberType ScriptMethod -Name Create -Value { param($a, $b) $global:Tc70.Create++ }
$solution | Add-Member -MemberType ScriptMethod -Name AddFromTemplate -Value { $global:Tc70.Calls += ,(@('AddFromTemplate') + $args); [PSCustomObject]@{ Object = $sm } }.GetNewClosure()
$solution | Add-Member -MemberType ScriptMethod -Name SaveAs -Value { param($a) Set-Content -LiteralPath $a -Value '' -Encoding ASCII }
& $mod { param($s) $script:TcIdeProcessId = $null; $script:TcIdeConnected = $true; $script:TcDte = [PSCustomObject]@{ Solution = $s }; $script:TcSolutionPath = $null } $solution

# --- template found: AddFromTemplate gets the resolved full path, CreateChild the template name
$tpl = Join-Path $root 'Base\PrjTemplate\TwinCAT Project.tsproj'
$global:Tc70Tpl = $tpl
& $mod { function script:Resolve-TcProjectTemplate { [PSCustomObject]@{ Path = $global:Tc70Tpl; Searched = @($global:Tc70Tpl) } } }
$r = New-TcProject -Name Demo70 -Path $root
$add = @($global:Tc70.Calls | Where-Object { $_[0] -eq 'AddFromTemplate' })
$cc = @($global:Tc70.Calls | Where-Object { $_[0] -eq 'CreateChild' })
Check 'success with a resolved template' ($r.success -eq $true) ($r | ConvertTo-Json -Compress -Depth 4)
Check 'AddFromTemplate: one call, template = resolved full path (never empty)' ($add.Count -eq 1 -and $add[0][1] -eq $tpl -and -not [string]::IsNullOrWhiteSpace($add[0][1])) ($add | ConvertTo-Json -Compress)
Check 'AddFromTemplate: destination = <Path>\<Name>, project name = Name' ($add.Count -eq 1 -and $add[0][2] -eq (Join-Path $root 'Demo70') -and $add[0][3] -eq 'Demo70') ($add | ConvertTo-Json -Compress)
Check 'CreateChild: PLC name, subType 0, empty 3rd arg, vInfo = "Standard PLC Template"' ($cc.Count -eq 1 -and $cc[0][1] -eq 'Demo70_Plc' -and $cc[0][2] -eq 0 -and $cc[0][3] -eq '' -and $cc[0][4] -eq 'Standard PLC Template') ($cc | ConvertTo-Json -Compress)

# --- template not found: TEMPLATE_NOT_FOUND before Solution.Create, nothing recorded
$global:Tc70.Calls = @(); $global:Tc70.Create = 0
& $mod { $script:TcBuildRequiredLocal = @{}; $script:TcSolutionPath = 'C:\Old70\Old70.sln' }
Remove-Item -Path (Join-Path $env:TCAUTO_STATE_DIR 'build-required.json*') -Force -ErrorAction SilentlyContinue
$searchedList = @('X:\none\a\TwinCAT Project.tsproj', 'X:\none\b\TwinCAT Project.tsproj')
$global:Tc70Searched = $searchedList
& $mod { function script:Resolve-TcProjectTemplate { [PSCustomObject]@{ Path = $null; Searched = $global:Tc70Searched } } }
$r = New-TcProject -Name Missing70 -Path $root
Check 'not found -> TEMPLATE_NOT_FOUND with data.searched and a hint' ((-not $r.success) -and $r.error.code -eq 'TEMPLATE_NOT_FOUND' -and @($r.data.searched).Count -eq 2 -and $r.data.created -eq $false -and -not [string]::IsNullOrWhiteSpace($r.error.hint)) ($r | ConvertTo-Json -Compress -Depth 4)
Check 'not found -> Solution.Create / AddFromTemplate never called, no directory created' ($global:Tc70.Create -eq 0 -and $global:Tc70.Calls.Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $root 'Missing70'))) ''
Check 'not found -> nothing recorded as BUILD_REQUIRED, module solution path untouched' ($null -eq $r.data.buildRequired -and $null -eq (& $mod { Get-TcBuildRequired }) -eq $true -and (& $mod { $script:TcSolutionPath }) -eq 'C:\Old70\Old70.sln') ''

# --- the real resolver: TWINCAT3DIR comes first and the file must exist
$modRoot = Split-Path -Parent $mod.Path
. (Join-Path $modRoot 'Private\Resolve-TcProjectTemplate.ps1')
$fakeDir = Join-Path $root 'TcDir\3.1'
$fakeTpl = Join-Path $fakeDir 'Components\Base\PrjTemplate\TwinCAT Project.tsproj'
$savedDir = $env:TWINCAT3DIR
try {
    $env:TWINCAT3DIR = $fakeDir
    $x = Resolve-TcProjectTemplate
    Check 'resolver: TWINCAT3DIR without the file -> its path is searched first, not returned' ($x.Searched[0] -eq $fakeTpl -and $x.Path -ne $fakeTpl) ($x | ConvertTo-Json -Compress)
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $fakeTpl) -Force
    Set-Content -LiteralPath $fakeTpl -Value '' -Encoding ASCII
    $x = Resolve-TcProjectTemplate
    Check 'resolver: TWINCAT3DIR with the file -> that file wins' ($x.Path -eq $fakeTpl) ($x | ConvertTo-Json -Compress)
}
finally {
    $env:TWINCAT3DIR = $savedDir
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
"failed: $fail"
exit $fail
