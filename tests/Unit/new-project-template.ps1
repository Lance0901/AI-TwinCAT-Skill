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
$global:Tc70 = @{ Calls = @(); Create = 0; Files = 'all'; NoPlcNode = $false }

# mock DTE: records every call
$plcNode = [PSCustomObject]@{ Mock = $true }
$plcNode | Add-Member -MemberType ScriptMethod -Name CreateChild -Value { param($a, $b, $c, $d) $global:Tc70.Calls += ,@('CreateChild', $a, $b, $c, $d); [PSCustomObject]@{ Name = $a } }
$sm = [PSCustomObject]@{ Mock = $true }
$sm | Add-Member -MemberType ScriptMethod -Name LookupTreeItem -Value { param($p) if ($global:Tc70.NoPlcNode -and $p -like 'TIPC^*') { return $null }; $plcNode }.GetNewClosure()
$solution = [PSCustomObject]@{ Mock = $true; IsOpen = $false; FullName = '' }
$solution | Add-Member -MemberType ScriptMethod -Name Create -Value { param($a, $b) $global:Tc70.Create++ }
$solution | Add-Member -MemberType ScriptMethod -Name AddFromTemplate -Value { $global:Tc70.Calls += ,(@('AddFromTemplate') + $args); $global:Tc70.Dir = $args[1]; $global:Tc70.Name = $args[2]; $tcp = [PSCustomObject]@{ Object = $sm }; $tcp | Add-Member -MemberType ScriptMethod -Name Save -Value {
    $global:Tc70.Calls += ,@('Project.Save')
    $d = $global:Tc70.Dir; $n = $global:Tc70.Name
    if ($global:Tc70.Files -eq 'all') {
        Set-Content -LiteralPath (Join-Path $d "$n.tsproj") -Encoding ASCII -Value "<TcSmProject><Project><Plc><Project Name=`"${n}_Plc`" PrjFilePath=`"${n}_Plc\${n}_Plc.plcproj`"/></Plc></Project></TcSmProject>"
    }
    elseif ($global:Tc70.Files -eq 'skeleton') {
        Set-Content -LiteralPath (Join-Path $d "$n.tsproj") -Encoding ASCII -Value '<Project ProjectGUID="{1}" ShowHideConfigurations="#x6"/>'
    }
    if ($global:Tc70.Files -in 'all', 'skeleton') { Set-Content -LiteralPath (Join-Path $d "${n}_Plc.plcproj") -Value '' -Encoding ASCII }
}; $tcp }.GetNewClosure()
$solution | Add-Member -MemberType ScriptMethod -Name SaveAs -Value { param($a)
    Set-Content -LiteralPath $a -Value '' -Encoding ASCII
    $global:Tc70.Calls += ,@('SaveAs')
}
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
Check 'Project.Save() is called before SaveAs' (($global:Tc70.Calls | ForEach-Object { $_[0] }) -join ',' -match 'CreateChild,Project.Save,SaveAs') (($global:Tc70.Calls | ForEach-Object { $_[0] }) -join ',')
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

# --- the folder <Path>\<Name> already exists: PROJECT_DIR_EXISTS before Solution.Create
$global:Tc70.Calls = @(); $global:Tc70.Create = 0
& $mod { function script:Resolve-TcProjectTemplate { [PSCustomObject]@{ Path = $global:Tc70Tpl; Searched = @($global:Tc70Tpl) } } }
$null = New-Item -ItemType Directory -Path (Join-Path $root 'Exists70') -Force
$r = New-TcProject -Name Exists70 -Path $root
Check 'existing folder -> PROJECT_DIR_EXISTS, Solution.Create not called' ((-not $r.success) -and $r.error.code -eq 'PROJECT_DIR_EXISTS' -and $global:Tc70.Create -eq 0 -and $global:Tc70.Calls.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($r.error.hint)) ($r | ConvertTo-Json -Compress -Depth 4)

# --- read-back (F3): files missing / PLC node missing -> PROJECT_CREATE_UNVERIFIED, not success
$global:Tc70.Files = 'sln'
$r = New-TcProject -Name Unver70a -Path $root
Check 'only the .sln on disk -> PROJECT_CREATE_UNVERIFIED listing .tsproj and .plcproj, path unknown' ((-not $r.success) -and $r.error.code -eq 'PROJECT_CREATE_UNVERIFIED' -and (@($r.data.missing) -join '|') -like '*tsproj*' -and (@($r.data.missing) -join '|') -like '*plcproj*' -and $null -eq (& $mod { $script:TcSolutionPath })) ($r | ConvertTo-Json -Compress -Depth 4)
$global:Tc70.Files = 'skeleton'
& $mod { $script:TcBuildRequiredLocal = @{} }
$r = New-TcProject -Name Skel70 -Path $root
Check 'unsaved 329-byte-style .tsproj skeleton (no <Plc>) -> PROJECT_CREATE_UNVERIFIED naming the .tsproj' ((-not $r.success) -and $r.error.code -eq 'PROJECT_CREATE_UNVERIFIED' -and (@($r.data.missing) -join '|') -like '*no <Plc> node*') ($r | ConvertTo-Json -Compress -Depth 4)
$global:Tc70.Files = 'all'; $global:Tc70.NoPlcNode = $true
& $mod { $script:TcBuildRequiredLocal = @{} }
$r = New-TcProject -Name Unver70b -Path $root
Check 'files fine, TIPC^<Name>_Plc not found -> PROJECT_CREATE_UNVERIFIED' ((-not $r.success) -and $r.error.code -eq 'PROJECT_CREATE_UNVERIFIED' -and (@($r.data.missing) -join '|') -like '*TIPC^Unver70b_Plc*') ($r | ConvertTo-Json -Compress -Depth 4)
$global:Tc70.NoPlcNode = $false

# --- check order (F4): a solution is open AND the template is missing -> SOLUTION_ALREADY_OPEN
$global:Tc70.Calls = @(); $global:Tc70.Create = 0
& $mod { function script:Resolve-TcProjectTemplate { [PSCustomObject]@{ Path = $null; Searched = @('X:\none') } } }
$solution.IsOpen = $true; $solution.FullName = 'C:\Open70\Open70.sln'
$r = New-TcProject -Name Order70 -Path $root
Check 'solution open + template missing -> SOLUTION_ALREADY_OPEN (open check first)' ((-not $r.success) -and $r.error.code -eq 'SOLUTION_ALREADY_OPEN' -and $global:Tc70.Create -eq 0) ($r | ConvertTo-Json -Compress -Depth 4)
$solution.IsOpen = $false; $solution.FullName = ''

# --- the real resolver, independent of the local TwinCAT install: Program Files and the registry
# level are replaced (env vars / Get-TcRegistryInstallDir stub), only temp folders are used
$modRoot = Split-Path -Parent $mod.Path
. (Join-Path $modRoot 'Private\Resolve-TcProjectTemplate.ps1')
$rel = 'Components\Base\PrjTemplate\TwinCAT Project.tsproj'
$envDir = Join-Path $root 'EnvDir\3.1'
$regBase = Join-Path $root 'RegBase'
$regTpl = Join-Path $regBase "3.1\$rel"
$envTpl = Join-Path $envDir $rel
$saved = @{ T = $env:TWINCAT3DIR; P = $env:ProgramFiles; X = ${env:ProgramFiles(x86)} }
function Get-TcRegistryInstallDir { $global:Tc70Reg }
try {
    $env:ProgramFiles = Join-Path $root 'NoPF'; ${env:ProgramFiles(x86)} = Join-Path $root 'NoPF86'
    $global:Tc70Reg = $regBase
    $env:TWINCAT3DIR = $envDir
    $x = Resolve-TcProjectTemplate
    Check 'resolver: TWINCAT3DIR searched first, listed even without the file' ($x.Searched[0] -eq $envTpl -and $null -eq $x.Path) ($x | ConvertTo-Json -Compress)
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $regTpl) -Force
    Set-Content -LiteralPath $regTpl -Value '' -Encoding ASCII
    $x = Resolve-TcProjectTemplate
    Check 'resolver: TWINCAT3DIR without the file -> registry level is the fallback' ($x.Path -eq $regTpl -and $x.Searched[1] -eq $regTpl) ($x | ConvertTo-Json -Compress)
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $envTpl) -Force
    Set-Content -LiteralPath $envTpl -Value '' -Encoding ASCII
    $x = Resolve-TcProjectTemplate
    Check 'resolver: TWINCAT3DIR with the file beats the registry level' ($x.Path -eq $envTpl) ($x | ConvertTo-Json -Compress)
    # dedupe: the same dir twice (trailing backslash, other case) is listed once
    $env:TWINCAT3DIR = (Join-Path $regBase '3.1').ToUpperInvariant() + '\'
    $x = Resolve-TcProjectTemplate
    Check 'resolver: trailing backslash / case difference is de-duplicated' (@($x.Searched | Where-Object { $_ -ieq $regTpl }).Count -eq 1 -and $x.Path -ieq $regTpl) ($x | ConvertTo-Json -Compress)
    # F2: a drive that does not exist must not throw (ErrorActionPreference = Stop here)
    $env:TWINCAT3DIR = 'Q:\x'
    $global:Tc70Reg = 'Q:\reg'
    $threw = $null
    try { $x = Resolve-TcProjectTemplate } catch { $threw = $_.Exception.Message }
    Check 'resolver: TWINCAT3DIR / registry on a missing drive (Q:) -> no exception, candidates listed, not found' ($null -eq $threw -and $null -eq $x.Path -and @($x.Searched | Where-Object { $_ -like 'Q:\x*' }).Count -eq 1 -and @($x.Searched | Where-Object { $_ -like 'Q:\reg*' }).Count -eq 1) ("$threw " + ($x | ConvertTo-Json -Compress))
}
finally {
    $env:TWINCAT3DIR = $saved.T; $env:ProgramFiles = $saved.P; ${env:ProgramFiles(x86)} = $saved.X
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
"failed: $fail"
exit $fail
