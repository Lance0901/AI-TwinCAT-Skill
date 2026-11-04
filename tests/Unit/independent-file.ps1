# Unit: task 4.4 (complete-automation-interface phase 3): Set-TcIndependentFile (MCP SetIndependentFile).
# No IDE / runtime: mock items whose SaveInOwnFile behaves as XAE did in verification/phase3-probe.md
# question 20 (supported items write the .xti at once when set True; unsupported ones answer S_OK and
# read back False; False + Project.Save deletes the .xti). Project.Save is mocked.
#   powershell.exe -NoProfile -File tests/Unit/independent-file.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
$env:TCAUTO_STATE_DIR = Join-Path $env:TEMP ("tcauto-unit-state-{0}" -f [guid]::NewGuid().ToString('N'))
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1')   # #118: own TCAUTO_STATE_DIR, never the real state
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
. (Join-Path $PSScriptRoot 'lib\MockTree.ps1')
$mod = Get-Module TwinCATAutomation
$fail = 0

$Root = Join-Path $env:TEMP ("tcauto-unit-indep-{0}" -f [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path (Join-Path $Root 'Prj') -Force
# long path names: with an 8.3 TEMP (RUNNER~1 on CI) Get-ChildItem returns the long form
$Root = & $mod { param($p) Get-TcLongPath $p } $Root
$Sln = Join-Path $Root 'Ind.sln'
[System.IO.File]::WriteAllText($Sln, '')
$TsProj = Join-Path $Root 'Prj\Prj.tsproj'
$Axis = 'TINC^NC-Task 1 SAF^Axes^Axis 1'

function Add-MockOwnFileNode([string]$Path, [int]$ItemType, [string]$XtiRel, [bool]$Supported = $true) {
    $n = Add-MockNode $Path $ItemType
    $n.Props.Own = $false; $n.Props.Xti = $(if ($XtiRel) { Join-Path $Root "Prj\$XtiRel" } else { $null }); $n.Props.Supported = $Supported
    $n | Add-Member ScriptProperty SaveInOwnFile { $this.Props.Own } {
        param($v)
        $global:T.Mods.Add("Set SaveInOwnFile $($this.PathName) $v") | Out-Null
        if (-not $this.Props.Supported) { return }
        $this.Props.Own = [bool]$v
        # XAE writes the .xti at once when set True (measured)
        if ($v -and $global:T.Mode -eq 'other-file') {
            $o = Join-Path $Root 'Prj\_Config\NC\Other.xti'
            $null = New-Item -ItemType Directory -Path (Split-Path $o) -Force
            [System.IO.File]::WriteAllText($o, '<TcSmItem>other</TcSmItem>')
            return
        }
        if ($v -and $null -ne $this.Props.Xti -and $global:T.Mode -ne 'no-file') {
            $null = New-Item -ItemType Directory -Path (Split-Path $this.Props.Xti) -Force
            [System.IO.File]::WriteAllText($this.Props.Xti, "<TcSmItem>$($this.Name)</TcSmItem>")
        }
    }
    Write-Output -NoEnumerate $n
}
function Reset-Mock {
    Reset-MockTree $Root
    Remove-Item -LiteralPath (Join-Path $Root 'Prj\_Config') -Recurse -Force -ErrorAction SilentlyContinue
    [System.IO.File]::WriteAllText($TsProj, '<TcSmProject><Project/></TcSmProject>')
    $global:T.Saves = [System.Collections.ArrayList]::new()
    $null = Add-MockNode 'TINC' 19
    $null = Add-MockOwnFileNode 'TINC^NC-Task 1 SAF' 1 '_Config\NC\NC.xti'
    $null = Add-MockNode 'TINC^NC-Task 1 SAF^Axes' 20
    $null = Add-MockOwnFileNode $Axis 22 '_Config\NC\Axes\Axis 1.xti'
    $null = Add-MockNode 'TIRT' 0
    $null = Add-MockOwnFileNode 'TIRT^PlcTask' 19 $null $false
}
$global:T.Sm = New-MockSysManager
Install-MockModule $mod $Sln
& $mod {
    # Project.Save as XAE did it: an item set back to False loses its .xti (and .bak)
    function script:Invoke-TcProjectSaveWithDeadline {
        [CmdletBinding()] param([string]$TsProjFile, [string]$PlcProjFile, [int]$TimeoutSec, [string]$SaveScript)
        $null = $global:T.Saves.Add($TsProjFile)
        if ($global:T.Mode -eq 'save-fail') { throw 'PROJECT_SAVE_TIMEOUT: mock' }
        # review S2: like the real runspace script, the project is looked up by FullName through
        # ConvertTo-TcPathKey on both sides
        if ($null -ne $script:TcDte) {
            $want = ConvertTo-TcPathKey $TsProjFile
            $hit = @($script:TcDte.Solution.Projects.List | Where-Object { (ConvertTo-TcPathKey ([string]$_.FullName)) -eq $want })
            if ($hit.Count -eq 0) { throw "save: Project.Save of '$TsProjFile' failed (no project of the solution has FullName '$TsProjFile')" }
        }
        foreach ($n in @($global:T.Nodes.Values | Where-Object { $null -ne $_.Props.Xti -and -not $_.Props.Own })) {
            if ($global:T.Mode -ne 'keep-file') { Remove-Item -LiteralPath $n.Props.Xti -Force -ErrorAction SilentlyContinue }
        }
    }
}
function Get-CodeChanged { & $mod { $e = Get-TcBuildRequired; if ($null -eq $e) { return $null }; (Get-TcBuildRequiredReasons $e)['code-changed'] } }
function Reset-BuildRequired { & $mod { $null = Clear-TcBuildRequired } }
function Get-Sets { @($global:T.Mods | Where-Object { $_ -like 'Set *' }) }
$AxisXti = Join-Path $Root 'Prj\_Config\NC\Axes\Axis 1.xti'

try {
    Reset-Mock; Reset-BuildRequired
    $r = Set-TcIndependentFile -Path $Axis -Enabled $true
    Check 'SetIndependentFile dry-run: expected file, nothing set' ($r.success -and $r.data.dryRun -and $r.data.expectedFile -eq 'Axis 1.xti' -and (Get-Sets).Count -eq 0 -and -not (Test-Path -LiteralPath $AxisXti)) (J $r.data)
    $r = Set-TcIndependentFile -Path $Axis -Enabled $false
    Check 'SetIndependentFile already off -> written false' ($r.success -and $r.data.written -eq $false) (J $r.data)
    $r = Set-TcIndependentFile -Path $Axis -Enabled $true -DryRun $false
    Check 'SetIndependentFile on: success, .xti created, project saved, BUILD_REQUIRED' ($r.success -and $r.data.verified -and @($r.data.createdFiles) -contains $AxisXti -and @($global:T.Saves).Count -eq 1 -and $r.data.projectSaved -eq $TsProj -and (Get-CodeChanged) -match 'Set-TcIndependentFile') (J $r.data)
    Check 'SetIndependentFile on: backup written before the setter (no .xti in it yet), .tsproj copied' ((Test-Path -LiteralPath ([string]$r.data.backupPath)) -and @($r.data.backupFiles | Where-Object { $_ -like '*Prj.tsproj' }).Count -eq 1 -and @($r.data.backupFiles | Where-Object { $_ -like '*.xti' }).Count -eq 0) (J $r.data.backupFiles)
    $r = Set-TcIndependentFile -Path $Axis -Enabled $false -DryRun $false
    Check 'SetIndependentFile off: .xti removed after the save, backup holds the old .xti' ($r.success -and @($r.data.removedFiles) -contains $AxisXti -and -not (Test-Path -LiteralPath $AxisXti) -and @($r.data.backupFiles | Where-Object { $_ -like '*Axis 1.xti' }).Count -eq 1) (J $r.data)
    Reset-Mock; Reset-BuildRequired
    $r = Set-TcIndependentFile -Path 'TINC^NC-Task 1 SAF' -Enabled $true -DryRun $false
    Check 'SetIndependentFile NC task -> NC.xti' ($r.success -and $r.data.expectedFile -eq 'NC.xti' -and @($r.data.createdFiles | Where-Object { $_ -like '*\NC.xti' }).Count -eq 1) (J $r.data)
    Reset-Mock; Reset-BuildRequired
    $r = Set-TcIndependentFile -Path 'TIRT^PlcTask' -Enabled $true -DryRun $false
    Check 'SetIndependentFile PlcTask: S_OK but reads back False -> INDEPENDENT_FILE_UNSUPPORTED, recorded, no save' ($r.error.code -eq 'INDEPENDENT_FILE_UNSUPPORTED' -and @($global:T.Saves).Count -eq 0 -and (Get-CodeChanged) -match 'unsupported') (J $r)
    Reset-Mock; Reset-BuildRequired; $global:T.Mode = 'no-file'
    $r = Set-TcIndependentFile -Path $Axis -Enabled $true -DryRun $false
    Check 'SetIndependentFile on but no .xti appears -> INDEPENDENT_FILE_VERIFY_FAILED' ($r.error.code -eq 'INDEPENDENT_FILE_VERIFY_FAILED') (J $r.error)
    Reset-Mock; Reset-BuildRequired
    $null = Set-TcIndependentFile -Path $Axis -Enabled $true -DryRun $false
    $global:T.Mode = 'keep-file'
    $r = Set-TcIndependentFile -Path $Axis -Enabled $false -DryRun $false
    Check 'SetIndependentFile off but the .xti is still there -> INDEPENDENT_FILE_VERIFY_FAILED' ($r.error.code -eq 'INDEPENDENT_FILE_VERIFY_FAILED' -and $r.error.message -match 'still exists') (J $r.error)
    Reset-Mock; Reset-BuildRequired; $global:T.Mode = 'save-fail'
    $r = Set-TcIndependentFile -Path $Axis -Enabled $true -DryRun $false
    Check 'SetIndependentFile save fails -> INDEPENDENT_FILE_SAVE_FAILED, recorded' ($r.error.code -eq 'INDEPENDENT_FILE_SAVE_FAILED' -and (Get-CodeChanged) -match 'not saved') (J $r.error)
    Reset-Mock; Reset-BuildRequired; $global:T.Dialog = New-MockDialog
    $r = Set-TcIndependentFile -Path $Axis -Enabled $true -DryRun $false
    Check 'SetIndependentFile modal dialog -> IDE_MODAL_DIALOG, nothing set / recorded' ($r.error.code -eq 'IDE_MODAL_DIALOG' -and (Get-Sets).Count -eq 0 -and $null -eq (Get-CodeChanged) -and -not (Test-Path -LiteralPath $AxisXti)) (J $r.error)
    # review S12
    Reset-Mock; Reset-BuildRequired
    [System.IO.File]::WriteAllText((Join-Path $Root 'Prj\Second.tsproj'), '<TcSmProject/>')
    $r = Set-TcIndependentFile -Path $Axis -Enabled $true -DryRun $false
    Check 'S12 two .tsproj -> INDEPENDENT_FILE_TSPROJ_AMBIGUOUS before backup and setter' ($r.error.code -eq 'INDEPENDENT_FILE_TSPROJ_AMBIGUOUS' -and (Get-Sets).Count -eq 0 -and $null -eq $r.data.PSObject.Properties['backupPath'] -and @($r.data.tsprojFiles).Count -eq 2) (J $r)
    $r = Set-TcIndependentFile -Path $Axis -Enabled $true
    Check 'S12 the .tsproj check is also in the dry-run' ($r.error.code -eq 'INDEPENDENT_FILE_TSPROJ_AMBIGUOUS') (J $r.error)
    Remove-Item -LiteralPath (Join-Path $Root 'Prj\Second.tsproj') -Force
    Reset-Mock; Reset-BuildRequired
    $null = New-Item -ItemType Directory -Path (Split-Path $AxisXti) -Force
    [System.IO.File]::WriteAllText($AxisXti, '<TcSmItem>stale</TcSmItem>')
    (Get-Item -LiteralPath $AxisXti).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddDays(-1)
    $global:T.Mode = 'no-file'
    $r = Set-TcIndependentFile -Path $Axis -Enabled $true -DryRun $false
    Check 'S12 an old untouched Axis 1.xti does not count -> INDEPENDENT_FILE_VERIFY_FAILED' ($r.error.code -eq 'INDEPENDENT_FILE_VERIFY_FAILED' -and @($r.data.writtenFiles).Count -eq 0) (J $r.data)
    Reset-Mock; Reset-BuildRequired; $global:T.Mode = 'other-file'
    $r = Set-TcIndependentFile -Path $Axis -Enabled $true -DryRun $false
    Check 'S12 another new .xti does not count -> INDEPENDENT_FILE_VERIFY_FAILED' ($r.error.code -eq 'INDEPENDENT_FILE_VERIFY_FAILED' -and @($r.data.createdFiles | Where-Object { $_ -like '*Other.xti' }).Count -eq 1) (J $r.data)
    Reset-Mock; Reset-BuildRequired
    $r = Set-TcIndependentFile -Path $Axis -Enabled $true -DryRun $false
    Check 'S12 the expected file written below _Config -> writtenFiles, success' ($r.success -and @($r.data.writtenFiles) -contains $AxisXti) (J $r.data)
    # 4.6 B2: 3 .tsproj in the solution folder (old copies), the .sln references only one
    $Old1 = Join-Path $Root 'Prj\Prj-Lance-G16.tsproj'; $Old2 = Join-Path $Root 'Prj\Prj-LanceP-NB1.tsproj'
    [System.IO.File]::WriteAllText($Old1, '<TcSmProject/>'); [System.IO.File]::WriteAllText($Old2, '<TcSmProject/>')
    $SlnText = "Microsoft Visual Studio Solution File, Format Version 12.00`r`nProject(`"{B1E792BE-AA5F-4E3C-8C82-674BF9C0715B}`") = `"Prj`", `"Prj\Prj.tsproj`", `"{11111111-2222-3333-4444-555555555555}`"`r`nEndProject`r`n"
    [System.IO.File]::WriteAllText($Sln, $SlnText)
    Reset-Mock; Reset-BuildRequired
    $r = Set-TcIndependentFile -Path $Axis -Enabled $true
    Check 'B2 3 .tsproj, the .sln references one -> dry-run success, tsproj from the sln' ($r.success -and $r.data.tsproj -eq $TsProj -and $r.data.tsprojSource -eq 'sln') (J $r.data)
    $r = Set-TcIndependentFile -Path $Axis -Enabled $true -DryRun $false
    Check 'B2 3 .tsproj, sln names one -> live success, saved that one, backup holds only it' ($r.success -and $r.data.projectSaved -eq $TsProj -and @($global:T.Saves) -contains $TsProj -and @($r.data.backupFiles | Where-Object { $_ -like '*.tsproj' }).Count -eq 1 -and @($r.data.backupFiles | Where-Object { $_ -like '*Prj.tsproj' }).Count -eq 1) (J $r.data)
    # the .sln references two of them -> really ambiguous
    [System.IO.File]::WriteAllText($Sln, $SlnText + "Project(`"{B1E792BE-AA5F-4E3C-8C82-674BF9C0715B}`") = `"Old`", `"Prj\Prj-Lance-G16.tsproj`", `"{22222222-2222-3333-4444-555555555555}`"`r`nEndProject`r`n")
    Reset-Mock; Reset-BuildRequired
    $r = Set-TcIndependentFile -Path $Axis -Enabled $true -DryRun $false
    Check 'B2 the .sln references two .tsproj -> INDEPENDENT_FILE_TSPROJ_AMBIGUOUS (source sln), nothing set' ($r.error.code -eq 'INDEPENDENT_FILE_TSPROJ_AMBIGUOUS' -and $r.data.tsprojSource -eq 'sln' -and @($r.data.tsprojFiles).Count -eq 2 -and (Get-Sets).Count -eq 0 -and $r.error.message -match 'references') (J $r)
    # DTE Solution.Projects FullName wins over the .sln (and the folder)
    [System.IO.File]::WriteAllText($Sln, '')
    $dteProjects = [PSCustomObject]@{ List = @([PSCustomObject]@{ FullName = $TsProj }, [PSCustomObject]@{ FullName = (Join-Path $Root 'Prj\plc\plc.plcproj') }) }
    $dteProjects | Add-Member ScriptProperty Count { @($this.List).Count }
    $dteProjects | Add-Member ScriptMethod Item { param($i) $this.List[$i - 1] }
    $mockDte = [PSCustomObject]@{ Solution = [PSCustomObject]@{ FullName = $Sln; Projects = $dteProjects } }
    & $mod { param($d) $script:TcDte = $d } $mockDte
    Reset-Mock; Reset-BuildRequired
    $r = Set-TcIndependentFile -Path $Axis -Enabled $true -DryRun $false
    Check 'B2 DTE project FullName decides (3 .tsproj, empty .sln) -> success, tsprojSource dte' ($r.success -and $r.data.tsproj -eq $TsProj -and $r.data.tsprojSource -eq 'dte' -and @($global:T.Saves) -contains $TsProj) (J $r.data)
    $bf = & $mod { @(Get-TcTsProjBackupFiles) }
    Check 'B2 Get-TcTsProjBackupFiles (variant / route backups) -> only the DTE .tsproj' (@($bf).Count -eq 1 -and @($bf)[0] -eq $TsProj) (J $bf)
    # review S2: DTE reports the FullName with 8.3 short names; the save gets DTE's spelling and
    # the lookup compares long-path keys on both sides
    $short = (New-Object -ComObject Scripting.FileSystemObject).GetFile($TsProj).ShortPath
    $dteProjects.List[0].FullName = $short
    Reset-Mock; Reset-BuildRequired
    $r = Set-TcIndependentFile -Path $Axis -Enabled $true -DryRun $false
    Check "S2 DTE FullName in 8.3 form ($(if ($short -ne $TsProj) { 'short differs' } else { '8.3 names off: same text' })) -> save gets DTE's spelling, success, data in long form" ($r.success -and @($global:T.Saves) -contains $short -and $r.data.tsproj -eq $TsProj -and $r.data.projectSaved -eq $TsProj -and $r.data.tsprojSource -eq 'dte') "$short $(J $r.data)"
    $k1 = & $mod { param($a) ConvertTo-TcPathKey $a } $short
    $k2 = & $mod { param($a) ConvertTo-TcPathKey $a } $TsProj
    Check 'S2 ConvertTo-TcPathKey: 8.3 and long spelling give the same key' ($k1 -eq $k2 -and $k1 -eq $TsProj.ToUpperInvariant()) "$k1 | $k2"
    # the same function text in a separate runspace (like the STA runspace of the real save)
    $fn = & $mod { $script:TcPathKeyFunctionText }
    $ps = [PowerShell]::Create()
    try {
        $null = $ps.AddScript("param(`$a, `$b)`n" + $fn + "`n(ConvertTo-TcPathKey `$a) -eq (ConvertTo-TcPathKey `$b)").AddArgument($short).AddArgument($TsProj)
        $same = @($ps.Invoke())
        Check 'S2 the key function text works in a separate runspace (short = long)' ($same.Count -eq 1 -and $same[0] -eq $true -and -not $ps.HadErrors) "$($same -join ',')"
    }
    finally { $ps.Dispose() }
    $dteProjects.List[0].FullName = $TsProj
    & $mod { $script:TcDte = $null }
    # review S3: an absolute path in the .sln is used as it is; a bad line does not drop the others
    [System.IO.File]::WriteAllText($Sln, "Project(`"{B1E792BE-AA5F-4E3C-8C82-674BF9C0715B}`") = `"Bad`", `"Prj\a<b|c.tsproj`", `"{33333333-2222-3333-4444-555555555555}`"`r`nEndProject`r`nProject(`"{B1E792BE-AA5F-4E3C-8C82-674BF9C0715B}`") = `"Old`", `"$Old1`", `"{22222222-2222-3333-4444-555555555555}`"`r`nEndProject`r`n")
    Reset-Mock; Reset-BuildRequired
    $r = Set-TcIndependentFile -Path $Axis -Enabled $true
    Check 'S3 .sln: a bad line + an absolute path -> the absolute one decides (source sln)' ($r.success -and $r.data.tsproj -eq $Old1 -and $r.data.tsprojSource -eq 'sln') (J $r.data)
    [System.IO.File]::WriteAllText($Sln, "Project(`"{B1E792BE-AA5F-4E3C-8C82-674BF9C0715B}`") = `"Old`", `"$Old1`", `"{22222222-2222-3333-4444-555555555555}`"`r`nEndProject`r`nProject(`"{B1E792BE-AA5F-4E3C-8C82-674BF9C0715B}`") = `"Prj`", `"Prj\Prj.tsproj`", `"{11111111-2222-3333-4444-555555555555}`"`r`nEndProject`r`n")
    Reset-Mock; Reset-BuildRequired
    $r = Set-TcIndependentFile -Path $Axis -Enabled $true
    Check 'S3 .sln: one absolute + one relative line -> both resolved (ambiguous, 2 files)' ($r.error.code -eq 'INDEPENDENT_FILE_TSPROJ_AMBIGUOUS' -and $r.data.tsprojSource -eq 'sln' -and @($r.data.tsprojFiles) -contains $Old1 -and @($r.data.tsprojFiles) -contains $TsProj -and @($r.data.tsprojFiles).Count -eq 2) (J $r.data)
    [System.IO.File]::WriteAllText($Sln, '')
    # nothing names one: folder scan with 3 -> ambiguous, the message says neither DTE nor the .sln named one
    Reset-Mock; Reset-BuildRequired
    $r = Set-TcIndependentFile -Path $Axis -Enabled $true
    Check 'B2 no DTE, empty .sln, 3 .tsproj in the folder -> INDEPENDENT_FILE_TSPROJ_AMBIGUOUS (source folder)' ($r.error.code -eq 'INDEPENDENT_FILE_TSPROJ_AMBIGUOUS' -and $r.data.tsprojSource -eq 'folder' -and @($r.data.tsprojFiles).Count -eq 3 -and $r.error.hint -match 'tsprojSource') (J $r)
    Remove-Item -LiteralPath $Old1, $Old2 -Force
    Reset-Mock
    $r = Set-TcIndependentFile -Path 'TINC^NoSuch' -Enabled $true
    Check 'SetIndependentFile missing path -> TREEITEM_NOT_FOUND' ($r.error.code -eq 'TREEITEM_NOT_FOUND') (J $r.error)

    foreach ($c in @('INDEPENDENT_FILE_UNSUPPORTED', 'INDEPENDENT_FILE_TSPROJ_AMBIGUOUS', 'INDEPENDENT_FILE_WRITE_FAILED', 'INDEPENDENT_FILE_SAVE_FAILED', 'INDEPENDENT_FILE_VERIFY_FAILED')) {
        $h = & $mod { param($k) Get-TcErrorHint -Code $k } $c
        Check "hint $c" (-not [string]::IsNullOrWhiteSpace($h)) "$h"
    }
    $tools = @((Get-Content -Raw -Encoding UTF8 (Join-Path $PSScriptRoot '..\..\mcp-server\tools.json') | ConvertFrom-Json).tools)
    $tt = @($tools | Where-Object { $_.name -eq 'SetIndependentFile' })[0]
    Check 'tools.json SetIndependentFile: destructive, Enabled required, DryRun true' ($null -ne $tt -and $tt.cmdlet -eq 'Set-TcIndependentFile' -and $tt.annotations.destructiveHint -eq $true -and @($tt.inputSchema.required) -contains 'Enabled' -and $tt.inputSchema.properties.DryRun.default -eq $true) (J $tt)
}
catch {
    Check 'unexpected-exception' $false "$($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber)"
}
finally {
    & $mod { $script:TcIdeConnected = $false; $script:TcSolutionPath = $null; $script:TcDte = $null }
    Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $env:TCAUTO_STATE_DIR -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\TCAUTO_STATE_DIR -ErrorAction SilentlyContinue
}

"failed: $fail"
exit [Math]::Min($fail, 255)
