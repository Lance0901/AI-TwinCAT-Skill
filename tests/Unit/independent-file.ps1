# Unit: task 4.4 (complete-automation-interface phase 3): Set-TcIndependentFile (MCP SetIndependentFile).
# No IDE / runtime: mock items whose SaveInOwnFile behaves as XAE did in verification/phase3-probe.md
# question 20 (supported items write the .xti at once when set True; unsupported ones answer S_OK and
# read back False; False + Project.Save deletes the .xti). Project.Save is mocked.
#   powershell.exe -NoProfile -File tests/Unit/independent-file.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
$env:TCAUTO_STATE_DIR = Join-Path $env:TEMP ("tcauto-unit-state-{0}" -f [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
. (Join-Path $PSScriptRoot 'lib\MockTree.ps1')
$mod = Get-Module TwinCATAutomation
$fail = 0

$Root = Join-Path $env:TEMP ("tcauto-unit-indep-{0}" -f [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path (Join-Path $Root 'Prj') -Force
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
    Reset-Mock
    $r = Set-TcIndependentFile -Path 'TINC^NoSuch' -Enabled $true
    Check 'SetIndependentFile missing path -> TREEITEM_NOT_FOUND' ($r.error.code -eq 'TREEITEM_NOT_FOUND') (J $r.error)

    foreach ($c in @('INDEPENDENT_FILE_UNSUPPORTED', 'INDEPENDENT_FILE_WRITE_FAILED', 'INDEPENDENT_FILE_SAVE_FAILED', 'INDEPENDENT_FILE_VERIFY_FAILED')) {
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
    & $mod { $script:TcIdeConnected = $false; $script:TcSolutionPath = $null }
    Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $env:TCAUTO_STATE_DIR -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\TCAUTO_STATE_DIR -ErrorAction SilentlyContinue
}

"failed: $fail"
exit [Math]::Min($fail, 255)
