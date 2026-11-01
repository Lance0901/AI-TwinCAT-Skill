# Unit: task 4.3 (complete-automation-interface phase 3): Get-TcProjectVariants (MCP GetVariants),
# Set-TcProjectVariantConfig (SetVariantConfig), Set-TcCurrentVariant (SwitchVariant), the
# VARIANT_GROUP_ACTIVE check of Enable-TcConfig and the variant boot folder of #89
# (Get-TcBootPackageDiff / Get-TcBootFileSet: _Boot\<Variant>\<Platform>).
# No IDE / runtime: a mock ITcSysManager whose variant properties behave as XAE did in
# verification/phase3-probe.md questions 15-18 (whole-document replace, case-sensitive names,
# E_FAIL for unknown names / '[All]' / bad XML, '[Group]' accepted, 4024 returns $null).
#   powershell.exe -NoProfile -File tests/Unit/project-variant.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
$env:TCAUTO_STATE_DIR = Join-Path $env:TEMP ("tcauto-unit-state-{0}" -f [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
. (Join-Path $PSScriptRoot 'lib\MockTree.ps1')
$mod = Get-Module TwinCATAutomation
$fail = 0

$Root = Join-Path $env:TEMP ("tcauto-unit-variant-{0}" -f [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path (Join-Path $Root 'Prj') -Force
# long path names: with an 8.3 TEMP (RUNNER~1 on CI) Get-ChildItem returns the long form
$Root = & $mod { param($p) Get-TcLongPath $p } $Root
$Sln = Join-Path $Root 'Var.sln'
[System.IO.File]::WriteAllText($Sln, '')
$TsProj = Join-Path $Root 'Prj\Prj.tsproj'
[System.IO.File]::WriteAllText($TsProj, '<TcSmProject TcProjectVariant="Variant1"><Project><Variants SpecificLocalBootFolder="true"><Variant><Name>Variant1</Name></Variant></Variants></Project></TcSmProject>')
$Sample = '<?xml version="1.0"?><ProjectVariants><Group><Name>Group1</Name><Member>Variant1</Member><Member>Variant2</Member></Group><Variant><Name>Variant1</Name></Variant><Variant><Name>Variant2</Name></Variant></ProjectVariants>'

function Test-MockConfig([string]$x) {
    $d = New-Object System.Xml.XmlDocument
    try { $d.LoadXml($x) } catch { return $false }
    return ($d.DocumentElement.Name -eq 'ProjectVariants')
}
$sm = New-MockSysManager
$sm | Add-Member ScriptProperty CurrentProjectVariant { $global:T.Current } {
    param($v)
    $global:T.Mods.Add("Set CurrentProjectVariant $v") | Out-Null
    $d = New-Object System.Xml.XmlDocument
    $names = @(); $groups = @()
    if (Test-MockConfig $global:T.Config) { $d.LoadXml($global:T.Config); $names = @($d.SelectNodes('//Variant/Name') | ForEach-Object { $_.InnerText }); $groups = @($d.SelectNodes('//Group/Name') | ForEach-Object { "[$($_.InnerText)]" }) }
    if ($v -ne '' -and $names -cnotcontains $v -and $groups -cnotcontains $v) { throw (New-ComError 'Unspecified error' ([int]0x80004005)) }
    if ($global:T.Mode -eq 'switch-ignore') { return }
    $global:T.Current = $v
}
$sm | Add-Member ScriptProperty ProjectVariantConfig { $global:T.Config } {
    param($v)
    $global:T.Mods.Add('Set ProjectVariantConfig') | Out-Null
    if (-not (Test-MockConfig $v)) { throw (New-ComError 'Unspecified error' ([int]0x80004005)) }
    if ($global:T.Mode -eq 'config-drop-future') { $v = $v -replace '<Future>keep</Future>', '' }
    if ($global:T.Mode -eq 'config-drop-last') { $v = $v -replace '<Variant><Name>[^<]*</Name></Variant></ProjectVariants>$', '</ProjectVariants>' }
    $global:T.Config = $v
}
$sm | Add-Member ScriptProperty ProjectVariantItems { $global:T.Items }
$global:T.Sm = $sm
Install-MockModule $mod $Sln
function Reset-Mock([string]$Config = $Sample, [string]$Current = 'Variant1') {
    Reset-MockTree $Root
    $global:T.Config = $Config; $global:T.Current = $Current; $global:T.Items = '<?xml version="1.0"?><ProjectVariants/>'
}
function Get-CodeChanged { & $mod { $e = Get-TcBuildRequired; if ($null -eq $e) { return $null }; (Get-TcBuildRequiredReasons $e)['code-changed'] } }
function Reset-BuildRequired { & $mod { $null = Clear-TcBuildRequired } }
function Get-Sets { @($global:T.Mods | Where-Object { $_ -like 'Set *' }) }

try {
    # ===== Get-TcProjectVariants
    Reset-Mock
    $r = Get-TcProjectVariants
    Check 'GetVariants: current, variants, groups parsed' ($r.success -and $r.data.supported -and $r.data.current -eq 'Variant1' -and (@($r.data.variants) -join ',') -eq 'Variant1,Variant2' -and @($r.data.groups)[0].name -eq 'Group1' -and (@(@($r.data.groups)[0].members) -join ',') -eq 'Variant1,Variant2' -and -not $r.data.currentIsGroup) (J $r.data)
    Reset-Mock -Config $null -Current ''
    $r = Get-TcProjectVariants
    Check 'GetVariants 4024 without variants ($null) -> empty arrays' ($r.success -and @($r.data.variants).Count -eq 0 -and @($r.data.groups).Count -eq 0 -and $r.data.current -eq '') (J $r.data)
    Reset-Mock -Config '' -Current ''
    $r = Get-TcProjectVariants
    Check 'GetVariants 4026 without variants ('''') -> empty arrays' ($r.success -and @($r.data.variants).Count -eq 0) (J $r.data)
    Reset-Mock; $global:T.Sm = New-MockSysManager
    $r = Get-TcProjectVariants
    $global:T.Sm = $sm
    Check 'GetVariants XAE without the properties (no member, $null) -> VARIANT_NOT_SUPPORTED' ($r.error.code -eq 'VARIANT_NOT_SUPPORTED') (J $r.error)
    Reset-Mock -Current 'Gone'
    $r = Get-TcProjectVariants
    Check 'GetVariants current not in config -> warning' ($r.success -and @($r.data.warnings | Where-Object { $_ -like "*'Gone'*" }).Count -eq 1) (J $r.data.warnings)

    # ===== Set-TcProjectVariantConfig
    Reset-Mock; Reset-BuildRequired
    $r = Set-TcProjectVariantConfig
    Check 'SetVariantConfig nothing given -> INVALID_PARAMS' ($r.error.code -eq 'INVALID_PARAMS') (J $r.error)
    $r = Set-TcProjectVariantConfig -AddVariant 'bad name'
    Check 'SetVariantConfig invalid name -> INVALID_PARAMS' ($r.error.code -eq 'INVALID_PARAMS' -and (Get-Sets).Count -eq 0) (J $r.error)
    $r = Set-TcProjectVariantConfig -AddVariant variant2
    Check 'SetVariantConfig add existing name (other case) -> VARIANT_ALREADY_EXISTS' ($r.error.code -eq 'VARIANT_ALREADY_EXISTS') (J $r.error)
    $r = Set-TcProjectVariantConfig -RemoveVariant variant2
    Check 'SetVariantConfig remove with wrong case -> VARIANT_NOT_FOUND naming Variant2' ($r.error.code -eq 'VARIANT_NOT_FOUND' -and $r.error.message -match "there is 'Variant2'") (J $r.error)
    $r = Set-TcProjectVariantConfig -RemoveVariant Variant1
    Check 'SetVariantConfig remove the current variant -> VARIANT_IS_CURRENT' ($r.error.code -eq 'VARIANT_IS_CURRENT' -and $r.error.hint -match 'Set-TcCurrentVariant') (J $r.error)
    $r = Set-TcProjectVariantConfig -AddVariant Variant3 -Group Group2
    Check 'SetVariantConfig dry-run: whole new document planned, nothing written' ($r.success -and $r.data.dryRun -and (Get-Sets).Count -eq 0 -and (@($r.data.after.variants) -join ',') -eq 'Variant1,Variant2,Variant3' -and $r.data.xml -match '<Group><Name>Group2</Name><Member>Variant3</Member></Group>' -and $r.data.xml -match '^<\?xml version="1.0"\?><ProjectVariants><Group><Name>Group1</Name>') (J $r.data)
    $r = Set-TcProjectVariantConfig -AddVariant Variant3 -DryRun $false
    Check 'SetVariantConfig live add: written once, read back, backup with the .tsproj, BUILD_REQUIRED' ($r.success -and $r.data.verified -and (Get-Sets).Count -eq 1 -and $global:T.Config -match 'Variant3' -and (Test-Path -LiteralPath ([string]$r.data.backupPath)) -and @($r.data.backupFiles | Where-Object { $_ -like '*Prj.tsproj' }).Count -eq 1 -and (Get-CodeChanged) -match 'Set-TcProjectVariantConfig') (J $r.data)
    Check 'SetVariantConfig backup holds the old document' (([System.IO.File]::ReadAllText([string]$r.data.backupPath)) -eq $Sample) ''
    # 4.6 B2: old .tsproj copies in the solution folder, the .sln references one -> only it is backed up
    $Old1 = Join-Path $Root 'Prj\Prj-Old1.tsproj'; $Old2 = Join-Path $Root 'Prj-Old2.tsproj'
    [System.IO.File]::WriteAllText($Old1, '<TcSmProject/>'); [System.IO.File]::WriteAllText($Old2, '<TcSmProject/>')
    [System.IO.File]::WriteAllText($Sln, "Project(`"{B1E792BE-AA5F-4E3C-8C82-674BF9C0715B}`") = `"Prj`", `"Prj\Prj.tsproj`", `"{11111111-2222-3333-4444-555555555555}`"`r`nEndProject`r`n")
    Reset-Mock; Reset-BuildRequired
    $r = Set-TcProjectVariantConfig -AddVariant Variant4 -DryRun $false
    $bt = @($r.data.backupFiles | Where-Object { $_ -like '*.tsproj' })
    Check 'B2 SetVariantConfig with 3 .tsproj, sln references one -> backupFiles has only Prj.tsproj' ($r.success -and $bt.Count -eq 1 -and $bt[0] -like '*Prj.tsproj') (J $r.data.backupFiles)
    Reset-Mock; Reset-BuildRequired
    $r = Set-TcCurrentVariant -Name Variant2 -DryRun $false
    $bt = @($r.data.backupFiles | Where-Object { $_ -like '*.tsproj' })
    Check 'B2 SwitchVariant with 3 .tsproj, sln references one -> backupFiles has only Prj.tsproj' ($r.success -and $bt.Count -eq 1 -and $bt[0] -like '*Prj.tsproj') (J $r.data.backupFiles)
    Remove-Item -LiteralPath $Old1, $Old2 -Force
    [System.IO.File]::WriteAllText($Sln, '')
    Reset-Mock; Reset-BuildRequired
    $r = Set-TcProjectVariantConfig -RemoveVariant Variant2 -DryRun $false
    Check 'SetVariantConfig live remove: removed from the group too' ($r.success -and $global:T.Config -notmatch 'Variant2' -and $global:T.Config -match '<Group><Name>Group1</Name><Member>Variant1</Member></Group>') "$($global:T.Config)"
    Reset-Mock -Config '<?xml version="1.0"?><ProjectVariants><Group><Name>G</Name><Member>B</Member></Group><Variant><Name>A</Name></Variant><Variant><Name>B</Name></Variant></ProjectVariants>' -Current 'A'
    $r = Set-TcProjectVariantConfig -RemoveVariant B -DryRun $false
    Check 'SetVariantConfig group left empty -> removed, warning' ($r.success -and $global:T.Config -notmatch '<Group>' -and @($r.data.warnings | Where-Object { $_ -like "*group 'G'*" }).Count -eq 1) "$($global:T.Config)"
    Reset-Mock -Config '<?xml version="1.0"?><ProjectVariants><Group><Name>G</Name><Member>B</Member></Group><Variant><Name>A</Name></Variant><Variant><Name>B</Name></Variant></ProjectVariants>' -Current '[G]'
    $r = Set-TcProjectVariantConfig -RemoveVariant B -DryRun $false
    Check 'SetVariantConfig current group left empty -> VARIANT_IS_CURRENT' ($r.error.code -eq 'VARIANT_IS_CURRENT' -and (Get-Sets).Count -eq 0) (J $r.error)
    Reset-Mock; Reset-BuildRequired; $global:T.Mode = 'config-drop-last'
    $r = Set-TcProjectVariantConfig -AddVariant Variant3 -DryRun $false
    Check 'SetVariantConfig readback differs -> VARIANT_VERIFY_FAILED, recorded' ($r.error.code -eq 'VARIANT_VERIFY_FAILED' -and (Get-CodeChanged) -match 'verify') (J $r.error)
    Reset-Mock; Reset-BuildRequired; $global:T.Dialog = New-MockDialog
    $r = Set-TcProjectVariantConfig -AddVariant Variant3 -DryRun $false
    Check 'SetVariantConfig modal dialog -> IDE_MODAL_DIALOG, nothing written / recorded' ($r.error.code -eq 'IDE_MODAL_DIALOG' -and (Get-Sets).Count -eq 0 -and $null -eq (Get-CodeChanged)) (J $r.error)

    # ===== Set-TcCurrentVariant
    Reset-Mock; Reset-BuildRequired
    $r = Set-TcCurrentVariant -Name variant2
    Check 'SwitchVariant wrong case -> VARIANT_NOT_FOUND (case-sensitive), nothing written' ($r.error.code -eq 'VARIANT_NOT_FOUND' -and $r.error.message -match "there is 'Variant2'" -and (Get-Sets).Count -eq 0) (J $r.error)
    $r = Set-TcCurrentVariant -Name '[All]'
    Check 'SwitchVariant [All] -> VARIANT_NOT_FOUND' ($r.error.code -eq 'VARIANT_NOT_FOUND') (J $r.error)
    $r = Set-TcCurrentVariant -Name Variant1
    Check 'SwitchVariant already current -> written false' ($r.success -and $r.data.written -eq $false) (J $r.data)
    $r = Set-TcCurrentVariant -Name Variant2
    Check 'SwitchVariant dry-run: nothing written' ($r.success -and $r.data.dryRun -and $r.data.previous -eq 'Variant1' -and (Get-Sets).Count -eq 0) (J $r.data)
    $r = Set-TcCurrentVariant -Name Variant2 -DryRun $false
    Check 'SwitchVariant live: switched, read back, backup, BUILD_REQUIRED' ($r.success -and $r.data.verified -and $global:T.Current -eq 'Variant2' -and (Test-Path -LiteralPath ([string]$r.data.backupPath)) -and (Get-CodeChanged) -match 'Set-TcCurrentVariant') (J $r.data)
    $r = Set-TcCurrentVariant -Name '[Group1]' -DryRun $false
    Check 'SwitchVariant [Group1]: accepted with a VARIANT_GROUP_ACTIVE warning' ($r.success -and $global:T.Current -eq '[Group1]' -and @($r.data.warnings | Where-Object { $_ -like '*VARIANT_GROUP_ACTIVE*' }).Count -eq 1) (J $r.data)
    $r = Set-TcCurrentVariant -Name '' -DryRun $false
    Check 'SwitchVariant empty clears it' ($r.success -and $global:T.Current -eq '') (J $r.data)
    Reset-Mock; Reset-BuildRequired; $global:T.Mode = 'switch-ignore'
    $r = Set-TcCurrentVariant -Name Variant2 -DryRun $false
    Check 'SwitchVariant readback differs -> VARIANT_SWITCH_FAILED, recorded' ($r.error.code -eq 'VARIANT_SWITCH_FAILED' -and (Get-CodeChanged) -match 'verify') (J $r.error)

    # ===== review S6: unknown nodes / attributes survive, whole document read back
    Reset-Mock -Config '<?xml version="1.0"?><ProjectVariants><Group><Name>Group1</Name><Member>Variant1</Member></Group><Variant Id="7"><Name>Variant1</Name><Build Setting="x"/></Variant><Future a="b">keep</Future></ProjectVariants>'; Reset-BuildRequired
    $r = Set-TcProjectVariantConfig -AddVariant Variant2 -Group group1 -DryRun $false
    Check 'S6 add on the DOM: unknown element / attributes kept, verified' ($r.success -and $r.data.verified -and $global:T.Config -match '<Variant Id="7"><Name>Variant1</Name><Build Setting="x" /></Variant>' -and $global:T.Config -match '<Future a="b">keep</Future>' -and $global:T.Config -match '<Variant><Name>Variant2</Name></Variant>') "$($global:T.Config)"
    Check 'N4 -Group in another case joins the existing group (warning)' ($global:T.Config -match '<Group><Name>Group1</Name><Member>Variant1</Member><Member>Variant2</Member></Group>' -and $global:T.Config -cnotmatch '<Name>group1</Name>' -and @($r.data.warnings | Where-Object { $_ -like '*exists as*Group1*' }).Count -eq 1) "$($global:T.Config) $(J $r.data.warnings)"
    Reset-Mock -Config '<?xml version="1.0"?><ProjectVariants><Variant><Name>Variant1</Name></Variant><Future>keep</Future></ProjectVariants>'; Reset-BuildRequired; $global:T.Mode = 'config-drop-future'
    $r = Set-TcProjectVariantConfig -AddVariant Variant2 -DryRun $false
    Check 'S6 readback compares the whole document (an unknown element lost -> VARIANT_VERIFY_FAILED)' ($r.error.code -eq 'VARIANT_VERIFY_FAILED') (J $r.error)

    # ===== review S2: CurrentProjectVariant read through Invoke-TcComRetry, a failing read is an error
    if (-not ('TcUnitThrowingVariantSm' -as [type])) {
        Add-Type -TypeDefinition 'public class TcUnitThrowingVariantSm { public string Msg; public string CurrentProjectVariant { get { throw new System.Runtime.InteropServices.COMException(Msg, unchecked((int)0x80004005)); } } }'
    }
    $bad = New-Object TcUnitThrowingVariantSm
    $bad.Msg = 'Unspecified error (mock)'
    $rv = & $mod { param($x) Read-TcCurrentVariant -SysManager $x } $bad
    Check 'S2 Read-TcCurrentVariant: a property that throws -> Error, not empty' ($null -ne $rv.Error -and $null -eq $rv.Value) (J $rv)
    $global:T.Sm = $bad
    $r = Enable-TcConfig -Force
    Check 'S2 Enable-TcConfig: CurrentProjectVariant unreadable -> VARIANT_READ_FAILED, nothing activated' ($r.error.code -eq 'VARIANT_READ_FAILED' -and $r.data.activated -eq $false) (J $r)
    $bad.Msg = 'IDE_BUSY: mock busy'
    $r = Enable-TcConfig -Force
    Check 'S2 Enable-TcConfig: an IDE_* error keeps its code' ($r.error.code -eq 'IDE_BUSY') (J $r.error)
    $global:T.Sm = $sm
    $rv = & $mod { Read-TcCurrentVariant -SysManager ([PSCustomObject]@{ Other = 1 }) }
    Check 'S2 Read-TcCurrentVariant: no such member -> empty, not supported' ($rv.Value -eq '' -and $null -eq $rv.Error -and -not $rv.Supported) (J $rv)

    # ===== Enable-TcConfig: VARIANT_GROUP_ACTIVE before anything
    Reset-Mock -Current '[Group1]'; Reset-BuildRequired
    $r = Enable-TcConfig -Force
    Check 'EnableConfig with a group selected -> VARIANT_GROUP_ACTIVE, nothing activated' ($r.error.code -eq 'VARIANT_GROUP_ACTIVE' -and $r.data.activated -eq $false -and $r.error.hint -match 'Set-TcCurrentVariant') (J $r)
    $g = & $mod { Test-TcVariantGroupActive -Current '[Group1]' }
    Check 'Test-TcVariantGroupActive returns the error for a group' ($g.error.code -eq 'VARIANT_GROUP_ACTIVE') (J $g)
    $global:T.Current = 'Variant1'
    $g = & $mod { Test-TcVariantGroupActive -Current 'Variant1' }
    Check 'Test-TcVariantGroupActive: a variant is fine' ($null -eq $g) (J $g)

    # ===== #89: boot folder of a variant project
    $plat = 'TwinCAT OS (x64)'
    $old = Join-Path $Root "Prj\_Boot\$plat"
    $var = Join-Path $Root "Prj\_Boot\Variant1\$plat"
    foreach ($d in @($old, $var)) { $null = New-Item -ItemType Directory -Path (Join-Path $d 'Plc') -Force }
    [System.IO.File]::WriteAllText((Join-Path $old 'CurrentConfig.xml'), 'old package')
    [System.IO.File]::WriteAllText((Join-Path $old 'Plc\Port_851.app'), 'old app')
    [System.IO.File]::WriteAllText((Join-Path $var 'CurrentConfig.xml'), 'variant package')
    [System.IO.File]::WriteAllText((Join-Path $var 'Plc\Port_851.app'), 'variant app')
    (Get-Item -LiteralPath (Join-Path $old 'CurrentConfig.xml')).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(-1)
    $tgt = Join-Path $Root 'TargetBoot'
    $null = New-Item -ItemType Directory -Path (Join-Path $tgt 'Plc') -Force
    [System.IO.File]::WriteAllText((Join-Path $tgt 'CurrentConfig.xml'), 'variant package')
    [System.IO.File]::WriteAllText((Join-Path $tgt 'Plc\Port_851.app'), 'variant app')
    & $mod { param($x) $script:MockTargetBoot = $x; function script:Resolve-TcTargetBootDir { param([string]$AmsNetId) @{ Dir = $script:MockTargetBoot; Kind = 'umrt:Mock' } } } $tgt
    $d1 = & $mod { param($s, $p) Get-TcBootPackageDiff -SolutionPath $s -Platform $p -AmsNetId '1.2.3.4.1.1' -AdsPorts @(851) } $Sln $plat
    Check '#89 without -Variant: the old _Boot\<Platform> is compared -> mismatch (the reported bug)' ($d1.status -eq 'mismatch' -and $d1.localDir -eq $old) (J $d1)
    $d2 = & $mod { param($s, $p) Get-TcBootPackageDiff -SolutionPath $s -Platform $p -AmsNetId '1.2.3.4.1.1' -AdsPorts @(851) -Variant 'Variant1' } $Sln $plat
    Check '#89 with -Variant Variant1: _Boot\Variant1\<Platform> is compared -> match' ($d2.status -eq 'match' -and $d2.localDir -eq $var -and $d2.variant -eq 'Variant1') (J $d2)
    # review S1: base package newer than a stale variant package, target = the base package: the
    # variant folder is still the only candidate, so the stale package is reported (mismatch)
    [System.IO.File]::WriteAllText((Join-Path $old 'CurrentConfig.xml'), 'variant package NEW BASE')
    [System.IO.File]::WriteAllText((Join-Path $tgt 'CurrentConfig.xml'), 'variant package NEW BASE')
    (Get-Item -LiteralPath (Join-Path $var 'CurrentConfig.xml')).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(-2)
    $d4 = & $mod { param($s, $p) Get-TcBootPackageDiff -SolutionPath $s -Platform $p -AmsNetId '1.2.3.4.1.1' -AdsPorts @(851) -Variant 'Variant1' } $Sln $plat
    Check 'S1 base newer than the variant package -> still the variant folder, mismatch reported' ($d4.status -eq 'mismatch' -and $d4.localDir -eq $var) (J $d4)
    $d5 = & $mod { param($s, $p) Get-TcBootPackageDiff -SolutionPath $s -Platform $p -AmsNetId '1.2.3.4.1.1' -AdsPorts @(851) -Variant 'Variant9' } $Sln $plat
    Check 'S1 variant folder missing -> base compared, warning' ($d5.localDir -eq $old -and @($d5.warnings | Where-Object { $_ -match 'Variant9' }).Count -eq 1) (J $d5)
    [System.IO.File]::WriteAllText((Join-Path $old 'CurrentConfig.xml'), 'old package')
    [System.IO.File]::WriteAllText((Join-Path $tgt 'CurrentConfig.xml'), 'variant package')
    [System.IO.File]::WriteAllText($TsProj, '<TcSmProject><Project><Variants SpecificLocalBootFolder="false"/></Project></TcSmProject>')
    $d3 = & $mod { param($s, $p) Get-TcBootPackageDiff -SolutionPath $s -Platform $p -AmsNetId '1.2.3.4.1.1' -AdsPorts @(851) -Variant 'Variant1' } $Sln $plat
    Check '#89 SpecificLocalBootFolder="false": only _Boot\<Platform>' ($d3.localDir -eq $old) (J $d3)
    [System.IO.File]::WriteAllText($TsProj, '<TcSmProject><Project><Variants SpecificLocalBootFolder="true"/></Project></TcSmProject>')
    & $mod { param($x) $script:MockTsProj = $x; function script:Get-TcPlcProjectFile { param([string]$PlcName) [PSCustomObject]@{ TsProjFile = $script:MockTsProj } } } $TsProj
    $fs = & $mod { param($s) Get-TcBootFileSet -PlcName 'plc' -Platform 'TwinCAT OS (x64)' -AdsPort 851 -SolutionDir $s -Variant 'Variant1' } (Split-Path $Sln)
    Check 'S1 Get-TcBootFileSet -Variant: only _Boot\Variant1\<platform>\Plc when it exists' (@($fs.Dirs).Count -eq 1 -and @($fs.Dirs)[0] -like '*\_Boot\Variant1\TwinCAT OS (x64)\Plc' -and @($fs.Files.Keys | Where-Object { $_ -like '*Variant1*Port_851.app' }).Count -eq 1 -and @($fs.Files.Keys).Count -eq 1 -and $null -eq $fs.Warning) (J $fs.Dirs)
    $fsm = & $mod { param($s) Get-TcBootFileSet -PlcName 'plc' -Platform 'TwinCAT OS (x64)' -AdsPort 851 -SolutionDir $s -Variant 'Variant9' } (Split-Path $Sln)
    Check 'S1 Get-TcBootFileSet variant folder missing -> _Boot\<platform>\Plc with a warning' (@($fsm.Dirs).Count -eq 1 -and @($fsm.Dirs)[0] -notlike '*Variant9*' -and $fsm.Warning -match 'Variant9') (J $fsm)
    $fsr = & $mod { param($s) Get-TcBootFileSet -PlcName 'plc' -Platform '' -AdsPort 851 -SolutionDir $s } (Split-Path $Sln)
    Check 'N2 Get-TcBootFileSet fallback search also finds _Boot\<Variant>\<platform>\Plc' (-not $fsr.Derived -and @($fsr.Files.Keys | Where-Object { $_ -like '*\_Boot\Variant1\*Port_851.app' }).Count -eq 1 -and @($fsr.Files.Keys | Where-Object { $_ -like '*\_Boot\TwinCAT OS (x64)\Plc\Port_851.app' }).Count -eq 1) (J @($fsr.Files.Keys))
    $fs0 = & $mod { param($s) Get-TcBootFileSet -PlcName 'plc' -Platform 'TwinCAT OS (x64)' -AdsPort 851 -SolutionDir $s } (Split-Path $Sln)
    Check '#89 Get-TcBootFileSet without variant: unchanged (one folder)' (@($fs0.Dirs).Count -eq 1) (J $fs0.Dirs)

    # ===== hints / tools.json
    foreach ($c in @('VARIANT_NOT_SUPPORTED', 'VARIANT_CONFIG_INVALID', 'VARIANT_ALREADY_EXISTS', 'VARIANT_NOT_FOUND', 'VARIANT_IS_CURRENT', 'VARIANT_VERIFY_FAILED', 'VARIANT_SWITCH_FAILED', 'VARIANT_GROUP_ACTIVE')) {
        $h = & $mod { param($k) Get-TcErrorHint -Code $k } $c
        Check "hint $c" (-not [string]::IsNullOrWhiteSpace($h)) "$h"
    }
    $tools = @((Get-Content -Raw -Encoding UTF8 (Join-Path $PSScriptRoot '..\..\mcp-server\tools.json') | ConvertFrom-Json).tools)
    $byName = @{}; foreach ($tt in $tools) { $byName[$tt.name] = $tt }
    foreach ($pair in @(@('SetVariantConfig', 'Set-TcProjectVariantConfig'), @('SwitchVariant', 'Set-TcCurrentVariant'))) {
        $tt = $byName[$pair[0]]
        Check "tools.json $($pair[0]): $($pair[1]), destructive, DryRun default true" ($null -ne $tt -and $tt.cmdlet -eq $pair[1] -and $tt.annotations.destructiveHint -eq $true -and $tt.inputSchema.properties.DryRun.default -eq $true) (J $tt.annotations)
    }
    Check 'tools.json GetVariants: read-only' ($byName['GetVariants'].annotations.readOnlyHint -eq $true) (J $byName['GetVariants'].annotations)
    Check 'tools.json SetVariantConfig AddVariant is a string array' ($byName['SetVariantConfig'].inputSchema.properties.AddVariant.type -eq 'array') (J $byName['SetVariantConfig'].inputSchema.properties.AddVariant)
}
catch {
    Check 'unexpected-exception' $false "$($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber)"
}
finally {
    & $mod { $script:TcIdeConnected = $false; $script:TcSolutionPath = $null }
    Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $env:TCAUTO_STATE_DIR -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\TCAUTO_STATE_DIR -ErrorAction SilentlyContinue
}

"failed: $fail"
exit [Math]::Min($fail, 255)
