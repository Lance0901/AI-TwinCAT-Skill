# Unit: task 3.3 (complete-automation-interface phase 2): Export-TcPlcOpen (MCP ExportPlcOpen) and
# Import-TcPlcOpen (ImportPlcOpen).
# No IDE / runtime: a mock ITcSysManager with an in-memory PLC tree whose '<Plc> Project' node has
# PlcOpenExport / PlcOpenImport behaving as XAE did in the probe (verification/phase2-probe.md 3.3):
# '^' in a selection -> 0x98510008, NONE throws on a conflict and imports nothing, SKIP skips silently,
# REPLACE replaces the object with the children of the file only, RENAME appends '_1'.
# A temp solution directory holds the object files for the backup and the SKIP fingerprint.
#   powershell.exe -NoProfile -File tests/Unit/plcopen.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
$env:TCAUTO_STATE_DIR = Join-Path $env:TEMP ("tcauto-unit-state-{0}" -f [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 400) { $Detail = $Detail.Substring(0, 400) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}
function J($o) { $o | ConvertTo-Json -Depth 6 -Compress }

$Root = Join-Path $env:TEMP ("tcauto-unit-plcopen-{0}" -f [guid]::NewGuid().ToString('N'))
$Out = Join-Path $Root 'out'
$In = Join-Path $Root 'in'
$null = New-Item -ItemType Directory -Path $In -Force
$null = New-Item -ItemType Directory -Path (Join-Path $Root 'plc\POUs') -Force
$null = New-Item -ItemType Directory -Path $Out -Force
$Sln = Join-Path $Root 'Open.sln'
[System.IO.File]::WriteAllText($Sln, '')
$P = 'TIPC^plc^plc Project'

# PLCopen XML as XAE writes it (TC6 namespace, 3S addData for methods / interfaces / project structure)
function New-PlcOpenXml([object[]]$Objects) {
    $pous = ''; $itfs = ''; $struct = ''
    foreach ($o in $Objects) {
        $m = ($o.Members | ForEach-Object { "<data name=""http://www.3s-software.com/plcopenxml/method"" handleUnknown=""implementation""><Method name=""$_"" /></data>" }) -join ''
        if ($o.Kind -eq 'ITF') { $itfs += "<data name=""http://www.3s-software.com/plcopenxml/interface"" handleUnknown=""implementation""><Interface name=""$($o.Name)""><addData>$m</addData></Interface></data>" }
        else { $pous += "<pou name=""$($o.Name)"" pouType=""functionBlock""><interface /><body><ST><xhtml xmlns=""http://www.w3.org/1999/xhtml"" /></ST></body><addData>$m</addData></pou>" }
        $struct += "<Object Name=""$($o.Name)"" ObjectId=""x"" />"
    }
    "<?xml version=""1.0"" encoding=""utf-8""?><project xmlns=""http://www.plcopen.org/xml/tc6_0200""><fileHeader companyName=""Beckhoff"" /><types><dataTypes /><pous>$pous</pous></types><instances><configurations /></instances><addData>$itfs<data name=""http://www.3s-software.com/plcopenxml/projectstructure"" handleUnknown=""discard""><ProjectStructure><Folder Name=""POUs"">$struct</Folder></ProjectStructure></data></addData></project>"
}

$global:T = @{}
function Add-MockNode([string]$Path, [int]$ItemType = 0) {
    $name = ($Path -split '\^')[-1]
    $n = [PSCustomObject]@{ Name = $name; PathName = $Path; ItemType = $ItemType; ItemSubType = 0; ItemSubTypeName = 'TREEITEMTYPE_MOCK'; Kids = [System.Collections.ArrayList]::new() }
    $n | Add-Member ScriptProperty ChildCount { $this.Kids.Count }
    $n | Add-Member ScriptMethod Child { param($i) $global:T.Nodes[$this.Kids[$i - 1]] }
    $n | Add-Member ScriptMethod ProduceXml { param($rec) "<TreeItem><ItemName>$($this.Name)</ItemName><PathName>$($this.PathName)</PathName></TreeItem>" }
    $n | Add-Member ScriptMethod ExportChild {
        param($cname, $file)
        $global:T.Order.Add("ExportChild $($this.PathName)^$cname") | Out-Null
        if ($global:T.ExportChildMode -eq 'throw') { throw [System.Runtime.InteropServices.COMException]::new('Cannot export child (mock)', -2147467259) }
        if ($global:T.ExportChildMode -eq 'nofile') { return }
        [System.IO.File]::WriteAllText($file, "zip of $cname")
    }
    $global:T.Nodes[$Path] = $n
    $i = $Path.LastIndexOf('^')
    if ($i -gt 0) { $null = $global:T.Nodes[$Path.Substring(0, $i)].Kids.Add($Path) }
    Write-Output -NoEnumerate $n
}
function Remove-MockNode([string]$Path) {
    foreach ($k in @($global:T.Nodes[$Path].Kids)) { Remove-MockNode $k }
    $i = $Path.LastIndexOf('^')
    $global:T.Nodes[$Path.Substring(0, $i)].Kids.Remove($Path) | Out-Null
    $global:T.Nodes.Remove($Path)
}
function Set-PrjMethods($n) {
    $n | Add-Member ScriptMethod PlcOpenExport {
        param($file, $sel)
        $global:T.Order.Add("PlcOpenExport $sel") | Out-Null
        $global:T.ExportCalls.Add($sel) | Out-Null
        switch ($global:T.ExportMode) {
            'notfound' { throw [System.Runtime.InteropServices.COMException]::new("Cannot export PlcOpen format. Selection '$sel' not found!", [int]0x98510008) }
            'arg' { throw [System.ArgumentException]::new("Couldn't create ExportObjects") }
            'nofile' { return }
            'garbage' { [System.IO.File]::WriteAllText($file, 'not xml at all'); return }
            'other' { [System.IO.File]::WriteAllText($file, (New-PlcOpenXml @(@{ Name = 'FB_Other'; Kind = 'POU'; Members = @() }))); return }
        }
        if (Test-Path -LiteralPath $file) { throw [System.ArgumentException]::new("File '$file' already exists!") }
        $objs = @(@($sel -split ';') | Where-Object { $_ } | ForEach-Object {
                $leaf = ($_ -split '\.')[-1]
                $node = @($global:T.Nodes.Values | Where-Object { $_.Name -eq $leaf })[0]
                @{ Name = $leaf; Kind = $(if ($null -ne $node -and $node.ItemType -eq 618) { 'ITF' } else { 'POU' }); Members = @(if ($null -ne $node) { $node.Kids | ForEach-Object { ($_ -split '\^')[-1] } }) }
            })
        [System.IO.File]::WriteAllText($file, (New-PlcOpenXml $objs))
    }
    $n | Add-Member ScriptMethod PlcOpenImport {
        param($file, $opt, $sel, $sub)
        $global:T.Order.Add("PlcOpenImport $opt") | Out-Null
        $global:T.ImportCalls.Add("$opt|$sel|$sub") | Out-Null
        if ($global:T.ImportMode -eq 'noop') { return }
        if ($global:T.ImportMode -eq 'throw-conflict') { throw [System.Exception]::new("Creation of object 'FB_A' failed. Reason: Import conflict! Creation of object 'ITF_A' failed. Reason: Import conflict!") }
        $existing = @($global:T.FileObjects | Where-Object { $global:T.Nodes.ContainsKey("$($global:P)^POUs^$($_.Name)") })
        if ([int]$opt -eq 0 -and $existing.Count -gt 0) { throw [System.Exception]::new((($existing | ForEach-Object { "Creation of object '$($_.Name)' failed. Reason: Import conflict!" }) -join ' ')) }
        foreach ($o in $global:T.FileObjects) {
            $path = "$($global:P)^POUs^$($o.Name)"
            $type = if ($o.Kind -eq 'ITF') { 618 } else { 604 }
            $memberType = if ($o.Kind -eq 'ITF') { 610 } else { 609 }
            if ($global:T.Nodes.ContainsKey($path)) {
                if ([int]$opt -eq 3) { continue }
                if ([int]$opt -eq 2) { $path = "$path`_1" }
                if ([int]$opt -eq 1) {
                    Remove-MockNode $path
                    $f = Join-Path $global:Root "plc\POUs\$($o.Name)$(if ($o.Kind -eq 'ITF') { '.TcIO' } else { '.TcPOU' })"
                    [System.IO.File]::WriteAllText($f, 'replaced by import')
                }
            }
            $null = Add-MockNode $path $type
            foreach ($m in $o.Members) { $null = Add-MockNode "$path^$m" $memberType }
        }
    }
}
function Reset-Mock {
    Remove-Item -LiteralPath (Join-Path $Root '.tcauto-backup') -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $Out -File -ErrorAction SilentlyContinue | Remove-Item -Force
    $global:T.Nodes = @{}
    $global:T.Order = [System.Collections.ArrayList]::new()
    $global:T.ExportCalls = [System.Collections.ArrayList]::new()
    $global:T.ImportCalls = [System.Collections.ArrayList]::new()
    $global:T.ExportMode = 'ok'; $global:T.ImportMode = 'ok'; $global:T.ExportChildMode = 'ok'; $global:T.Dialog = $null
    $global:T.Saves = [System.Collections.ArrayList]::new(); $global:T.SaveMode = 'ok'
    $null = Add-MockNode 'TIPC'
    $null = Add-MockNode 'TIPC^plc' 56
    Set-PrjMethods (Add-MockNode $P 600)
    $null = Add-MockNode "$P^POUs" 601
    $null = Add-MockNode "$P^POUs^MAIN" 602
    $null = Add-MockNode "$P^POUs^FB_A" 604
    $null = Add-MockNode "$P^POUs^FB_A^M_Run" 609
    $null = Add-MockNode "$P^POUs^FB_A^P_Value" 611
    $null = Add-MockNode "$P^POUs^FB_A^P_Value^Get" 613
    $null = Add-MockNode "$P^POUs^ITF_A" 618
    $null = Add-MockNode "$P^POUs^ITF_A^M_Do" 610
    $null = Add-MockNode "$P^POUs^ITF_A^P_Cnt" 612
    $null = Add-MockNode "$P^POUs^ITF_A^P_Str" 612
    $null = Add-MockNode "$P^DUTs" 601
    [System.IO.File]::WriteAllText((Join-Path $Root 'plc\POUs\FB_A.TcPOU'), '<TcPlcObject>FB_A original</TcPlcObject>')
    [System.IO.File]::WriteAllText((Join-Path $Root 'plc\POUs\ITF_A.TcIO'), '<TcPlcObject>ITF_A original</TcPlcObject>')
    [System.IO.File]::WriteAllText((Join-Path $Root 'plc\POUs\MAIN.TcPOU'), '<TcPlcObject>MAIN</TcPlcObject>')
}
$global:P = $P
$global:Root = $Root
$sm = New-Object PSObject
$sm | Add-Member ScriptMethod LookupTreeItem {
    param($p)
    if (-not $global:T.Nodes.ContainsKey($p)) { throw [System.Runtime.InteropServices.COMException]::new("Item '$p' not found", [int]0x98510001) }
    Write-Output -NoEnumerate $global:T.Nodes[$p]
}
$global:T.Sm = $sm

& $mod {
    param($s)
    $script:TcIdeProcessId = $null; $script:TcIdeConnected = $true; $script:TcSolutionPath = $s
    function script:Assert-TcConnection { }
    function script:Get-TcSysManager { [CmdletBinding()] param([switch]$Refresh) , $global:T.Sm }
    function script:Get-TcIdeModalDialog { [CmdletBinding()] param([int]$ProcessId = 0, [int]$TimeoutSec = 5) $global:T.Dialog }
    function script:Get-TcPlcProjectList { [CmdletBinding()] param($SysManager) @([PSCustomObject]@{ name = 'plc'; nodePath = 'TIPC^plc'; projectPath = 'TIPC^plc^plc Project'; adsPort = 851 }) }
    function script:Resolve-TcPlcProjectPath { [CmdletBinding()] param($SysManager, [switch]$RequireSingle) 'TIPC^plc^plc Project' }
    # Save-TcPlcProject without DTE: records what the .plcproj readback must contain
    function script:Save-TcPlcProject {
        [CmdletBinding()] param([string]$PlcName, [string[]]$ExpectFile = @(), [string[]]$ExpectLibrary = @(), [int]$TimeoutSec = 60)
        $null = $global:T.Saves.Add("$PlcName|$((@($ExpectFile) | Sort-Object) -join ',')")
        if ($global:T.SaveMode -eq 'dialog') { return @{ ModalDialog = @{ Title = 'Microsoft Visual Studio'; Text = 'Save?'; Kind = 'unknown' } } }
        if ($global:T.SaveMode -eq 'missing') { throw "save: Project.Save returned but 'plc.plcproj' read back from disk has no <Compile Include> for $(@($ExpectFile) -join ', ')." }
        [ordered]@{ plc = $PlcName; plcproj = 'plc.plcproj'; verifiedFiles = @($ExpectFile | ForEach-Object { [PSCustomObject]@{ file = $_; preExisting = $false } }); warning = $null }
    }
} $Sln
function Get-CodeChanged { & $mod { $e = Get-TcBuildRequired; if ($null -eq $e) { return $null }; (Get-TcBuildRequiredReasons $e)['code-changed'] } }
function Reset-BuildRequired { & $mod { $null = Clear-TcBuildRequired } }
$dialog = [PSCustomObject]@{ Title = 'Microsoft Visual Studio'; Text = 'Assertion Failed'; Kind = 'unknown'; Buttons = @('OK') }

try {
    # ===== helpers
    $sel = & $mod { Test-TcPlcOpenSelection -Selection @('POUs.FB_A', 'LIB.Basic Function.FB_X') }
    Check 'selection: dotted paths with a space are accepted' ($null -eq $sel) (J $sel)
    $sel = & $mod { Test-TcPlcOpenSelection -Selection @('POUs..FB_A') }
    Check 'selection: an empty level is refused' ($sel.Reason -eq 'invalid-selection') (J $sel)
    $info = & $mod {
        try { $o = New-Object PSObject; $o | Add-Member ScriptMethod Go { throw [System.Runtime.InteropServices.COMException]::new('mock', [int]0x98510008) }; $o.Go() }
        catch { Get-TcComErrorInfo -ErrorRecord $_ }
    }
    Check 'Get-TcComErrorInfo: HRESULT of the COMException below the PowerShell wrapper' ($info.hresult -eq [int]0x98510008 -and $info.hresultHex -eq '0x98510008' -and $info.exceptionType -eq 'System.Runtime.InteropServices.COMException') (J $info)
    $info = & $mod { try { throw [System.ArgumentException]::new('x') } catch { Get-TcComErrorInfo -ErrorRecord $_ } }
    Check 'Get-TcComErrorInfo: ArgumentException is recognised by type' ($info.argument) (J $info)

    # ===== Export: selection checks (nothing called)
    Reset-Mock; Reset-BuildRequired
    $f = Join-Path $Out 'e.xml'
    $r = Export-TcPlcOpen -Selection 'POUs^FB_A' -FilePath $f
    Check 'Export ^ -> PLCOPEN_FAILED invalid-selection, hint shows the dotted form, XAE not called' ($r.error.code -eq 'PLCOPEN_FAILED' -and $r.data.reason -eq 'invalid-selection' -and $r.error.hint -match 'POUs\.FB_A' -and $global:T.ExportCalls.Count -eq 0) (J $r.error)
    $r = Export-TcPlcOpen -Selection 'POUs.FB_A;POUs.MAIN' -FilePath $f
    Check 'Export ; inside one element -> invalid-selection' ($r.error.code -eq 'PLCOPEN_FAILED' -and $r.data.reason -eq 'invalid-selection' -and $global:T.ExportCalls.Count -eq 0) (J $r.error)
    $r = Export-TcPlcOpen -Selection 'POUs.FB_A.M_Run' -FilePath $f
    Check 'Export method (dotted path) -> member-selection, suggests the FB, XAE not called' ($r.error.code -eq 'PLCOPEN_FAILED' -and $r.data.reason -eq 'member-selection' -and $r.data.memberSelection.suggestedSelection -eq 'POUs.FB_A' -and $r.data.memberSelection.objectKind -eq 'METHOD' -and $global:T.ExportCalls.Count -eq 0) (J $r.data)
    $r = Export-TcPlcOpen -Selection 'FB_A.P_Value.Get' -FilePath $f
    Check 'Export accessor (bare name, Resolve-TcPouPath) -> member-selection, suggests POUs.FB_A' ($r.error.code -eq 'PLCOPEN_FAILED' -and $r.data.reason -eq 'member-selection' -and $r.data.memberSelection.suggestedSelection -eq 'POUs.FB_A' -and $r.data.memberSelection.itemType -eq 613) (J $r.data)
    $r = Export-TcPlcOpen -Selection 'POUs.FB_A' -FilePath 'relative.xml'
    Check 'Export relative path -> PLCOPEN_FAILED not-absolute' ($r.error.code -eq 'PLCOPEN_FAILED' -and $r.data.reason -eq 'not-absolute') (J $r.error)
    $r = Export-TcPlcOpen -Selection 'POUs.FB_A' -FilePath (Join-Path $Out 'nosub\e.xml')
    Check 'Export missing folder -> PLCOPEN_FAILED folder-missing' ($r.error.code -eq 'PLCOPEN_FAILED' -and $r.data.reason -eq 'folder-missing') (J $r.error)
    $global:T.Dialog = $dialog
    $r = Export-TcPlcOpen -Selection 'POUs.FB_A' -FilePath $f
    Check 'Export modal dialog -> IDE_MODAL_DIALOG, XAE not called' ($r.error.code -eq 'IDE_MODAL_DIALOG' -and $global:T.ExportCalls.Count -eq 0) (J $r.error)
    $global:T.Dialog = $null

    # ===== Export: success and readback
    $r = Export-TcPlcOpen -Selection 'POUs.FB_A', 'POUs.ITF_A' -FilePath $f
    $fb = @($r.data.objects | Where-Object { $_.name -eq 'FB_A' })[0]
    $itf = @($r.data.objects | Where-Object { $_.name -eq 'ITF_A' })[0]
    Check 'Export: selection joined with ;, success, file read back' ($r.success -and $r.data.exported -and $global:T.ExportCalls[0] -eq 'POUs.FB_A;POUs.ITF_A' -and $r.data.objectCount -eq 2 -and $r.data.fileSize -gt 0) (J $r.data)
    Check 'Export: data.objects lists kind, folder and members' ($fb.kind -eq 'POU' -and $fb.pouType -eq 'functionBlock' -and $fb.folder -eq 'POUs' -and @($fb.members | ForEach-Object { $_.name }) -contains 'M_Run' -and $itf.kind -eq 'ITF' -and @($itf.members).Count -eq 3) (J $r.data.objects)
    Check 'Export records no BUILD_REQUIRED' ($null -eq (Get-CodeChanged)) "$(Get-CodeChanged)"
    $r = Export-TcPlcOpen -FilePath (Join-Path $Out 'all.xml')
    Check 'Export without selection: whole project (empty selection string)' ($r.success -and $global:T.ExportCalls[-1] -eq '') (J $r.data)

    # ===== Export: file exists / Overwrite
    $r = Export-TcPlcOpen -Selection 'POUs.MAIN' -FilePath $f
    Check 'Export existing file without -Overwrite -> PLCOPEN_FILE_EXISTS, file unchanged, XAE not called' ($r.error.code -eq 'PLCOPEN_FILE_EXISTS' -and ([System.IO.File]::ReadAllText($f)) -match 'FB_A' -and $global:T.ExportCalls.Count -eq 2) (J $r.error)
    $old = [System.IO.File]::ReadAllText($f)
    $r = Export-TcPlcOpen -Selection 'POUs.MAIN' -FilePath $f -Overwrite
    Check 'Export -Overwrite: old file renamed to .bak, new file written' ($r.success -and $r.data.previousFile -eq "$f.bak" -and ([System.IO.File]::ReadAllText("$f.bak")) -eq $old -and ([System.IO.File]::ReadAllText($f)) -match 'MAIN' -and ([System.IO.File]::ReadAllText($f)) -notmatch 'FB_A') (J $r.data)
    Remove-Item -LiteralPath "$f.bak" -Force
    $cur = [System.IO.File]::ReadAllText($f)
    $global:T.ExportMode = 'notfound'
    $r = Export-TcPlcOpen -Selection 'POUs.NoSuch' -FilePath $f -Overwrite
    Check 'Export -Overwrite, XAE 0x98510008 -> selection-not-found, old file put back, no .bak left' ($r.error.code -eq 'PLCOPEN_FAILED' -and $r.data.reason -eq 'selection-not-found' -and $r.data.hresult -eq '0x98510008' -and $r.data.restore.restored -and ([System.IO.File]::ReadAllText($f)) -eq $cur -and -not (Test-Path -LiteralPath "$f.bak")) (J $r.data)
    $global:T.ExportMode = 'garbage'
    $r = Export-TcPlcOpen -Selection 'POUs.MAIN' -FilePath $f -Overwrite
    Check 'Export -Overwrite, unreadable output -> PLCOPEN_VERIFY_FAILED, old file back, new one kept as .failed' ($r.error.code -eq 'PLCOPEN_VERIFY_FAILED' -and $r.data.reason -eq 'invalid-file' -and ([System.IO.File]::ReadAllText($f)) -eq $cur -and $r.data.restore.failedFile -eq "$f.failed" -and (Test-Path -LiteralPath "$f.failed")) (J $r.data.restore)
    $global:T.ExportMode = 'arg'
    $r = Export-TcPlcOpen -Selection 'POUs.MAIN' -FilePath (Join-Path $Out 'arg.xml')
    Check 'Export ArgumentException from XAE -> PLCOPEN_FAILED invalid-argument' ($r.error.code -eq 'PLCOPEN_FAILED' -and $r.data.reason -eq 'invalid-argument') (J $r.data)
    $global:T.ExportMode = 'other'
    $r = Export-TcPlcOpen -Selection 'POUs.MAIN' -FilePath (Join-Path $Out 'other.xml')
    Check 'Export: selected object missing in the file -> PLCOPEN_VERIFY_FAILED selection-missing' ($r.error.code -eq 'PLCOPEN_VERIFY_FAILED' -and $r.data.reason -eq 'selection-missing' -and @($r.data.missingSelections) -contains 'POUs.MAIN') (J $r.data)
    $global:T.ExportMode = 'nofile'
    $r = Export-TcPlcOpen -Selection 'POUs.MAIN' -FilePath (Join-Path $Out 'none.xml')
    Check 'Export: no file written -> PLCOPEN_VERIFY_FAILED file-not-written' ($r.error.code -eq 'PLCOPEN_VERIFY_FAILED' -and $r.data.reason -eq 'file-not-written') (J $r.data)

    # ===== Import: file checks
    Reset-Mock; Reset-BuildRequired
    $r = Import-TcPlcOpen -FilePath (Join-Path $Out 'missing.xml')
    Check 'Import missing file -> PLCOPEN_FAILED file-missing' ($r.error.code -eq 'PLCOPEN_FAILED' -and $r.data.reason -eq 'file-missing') (J $r.error)
    $xxe = Join-Path $Out 'xxe.xml'
    [System.IO.File]::WriteAllText($xxe, '<?xml version="1.0"?><!DOCTYPE project [<!ENTITY x SYSTEM "file:///c:/windows/win.ini">]><project>&x;</project>')
    $r = Import-TcPlcOpen -FilePath $xxe
    Check 'Import file with a DTD -> PLCOPEN_FAILED invalid-file (no XXE)' ($r.error.code -eq 'PLCOPEN_FAILED' -and $r.data.reason -eq 'invalid-file' -and $global:T.ImportCalls.Count -eq 0) (J $r.error)
    $emp = Join-Path $Out 'empty.xml'
    [System.IO.File]::WriteAllText($emp, '<project xmlns="http://www.plcopen.org/xml/tc6_0200"><types><pous /></types></project>')
    $r = Import-TcPlcOpen -FilePath $emp
    Check 'Import file without objects -> PLCOPEN_FAILED no-objects' ($r.error.code -eq 'PLCOPEN_FAILED' -and $r.data.reason -eq 'no-objects') (J $r.error)

    # the probe's file: FB_A (only M_Run) + ITF_A (only M_Do) + a new FB_New
    $global:T.FileObjects = @(
        @{ Name = 'FB_A'; Kind = 'POU'; Members = @('M_Run') },
        @{ Name = 'ITF_A'; Kind = 'ITF'; Members = @('M_Do') },
        @{ Name = 'FB_New'; Kind = 'POU'; Members = @() })
    $imp = Join-Path $In 'import.xml'
    [System.IO.File]::WriteAllText($imp, (New-PlcOpenXml $global:T.FileObjects))
    $newOnly = Join-Path $In 'new-only.xml'
    [System.IO.File]::WriteAllText($newOnly, (New-PlcOpenXml @(@{ Name = 'FB_New'; Kind = 'POU'; Members = @() })))

    # ===== Import: dry-run preview per option
    $r = Import-TcPlcOpen -FilePath $imp
    Check 'Import dry-run None with conflicts -> PLCOPEN_CONFLICT listing both, XAE not called' ($r.error.code -eq 'PLCOPEN_CONFLICT' -and @($r.data.conflicts).Count -eq 2 -and @($r.data.conflicts | Where-Object { $_.name -eq 'FB_A' -and $_.existingPath -eq "$P^POUs^FB_A" }).Count -eq 1 -and $global:T.ImportCalls.Count -eq 0) (J $r.data.conflicts)
    $r = Import-TcPlcOpen -FilePath $newOnly
    Check 'Import dry-run None without conflicts -> success, willImport' ($r.success -and $r.data.dryRun -and @($r.data.willImport) -contains 'FB_New' -and @($r.data.conflicts).Count -eq 0) (J $r.data)
    $r = Import-TcPlcOpen -FilePath $imp -Option Skip
    Check 'Import dry-run Skip -> willSkip lists the conflicts, willImport the rest' ($r.success -and (@($r.data.willSkip) -join ',') -eq 'FB_A,ITF_A' -and (@($r.data.willImport) -join ',') -eq 'FB_New') (J $r.data)
    $r = Import-TcPlcOpen -FilePath $imp -Option Rename
    Check 'Import dry-run Rename -> expected names <name>_1' ($r.success -and (@($r.data.willRename | ForEach-Object { $_.expectedName }) -join ',') -eq 'FB_A_1,ITF_A_1' -and @($r.data.willRename | Where-Object { $_.nameTaken }).Count -eq 0) (J $r.data.willRename)
    $r = Import-TcPlcOpen -FilePath $imp -Option Replace
    $wi = @($r.data.willReplace | Where-Object { $_.name -eq 'ITF_A' })[0]
    $wf = @($r.data.willReplace | Where-Object { $_.name -eq 'FB_A' })[0]
    Check 'Import dry-run Replace -> children missing in the file are listed as deleted (ITF properties, FB property)' ($r.success -and (@($wi.deletedChildren) -join ',') -eq 'P_Cnt,P_Str' -and (@($wf.deletedChildren) -join ',') -eq 'P_Value' -and $r.data.replaceWarning -match 'children the file does not have are deleted' -and $r.data.replaceWarning -match 'P_Cnt') (J $r.data.willReplace)
    Check 'Import dry-runs: nothing called, nothing recorded, no backup' ($global:T.ImportCalls.Count -eq 0 -and $null -eq (Get-CodeChanged) -and -not (Test-Path -LiteralPath (Join-Path $Root '.tcauto-backup'))) "$(Get-CodeChanged)"
    $null = Add-MockNode "$P^POUs^FB_A_1" 604
    $r = Import-TcPlcOpen -FilePath $imp -Option Rename
    Check 'Import dry-run Rename when <name>_1 exists -> nameTaken + warning' (@($r.data.willRename | Where-Object { $_.name -eq 'FB_A' -and $_.nameTaken }).Count -eq 1 -and @($r.data.warnings | Where-Object { $_ -match "FB_A_1' already exists" }).Count -eq 1) (J $r.data)

    # ===== Import live: None with conflict is refused before XAE
    Reset-Mock; Reset-BuildRequired
    $r = Import-TcPlcOpen -FilePath $imp -DryRun $false
    Check 'Import live None with conflict -> PLCOPEN_CONFLICT, XAE not called, nothing recorded' ($r.error.code -eq 'PLCOPEN_CONFLICT' -and $global:T.ImportCalls.Count -eq 0 -and $null -eq (Get-CodeChanged)) "$(J $r.error) | $(Get-CodeChanged)"

    # ===== Import live: Replace backs up first (PLCopen XML required, .zip best effort), then saves
    Reset-Mock; Reset-BuildRequired
    $r = Import-TcPlcOpen -FilePath $imp -Option Replace -DryRun $false
    $order = @($global:T.Order) -join ';'
    Check 'Import live Replace: PlcOpenExport backup of both objects, then the .zip backups, then PlcOpenImport 1' ($r.success -and $order -eq "PlcOpenExport POUs.FB_A;POUs.ITF_A;ExportChild $P^POUs^FB_A;ExportChild $P^POUs^ITF_A;PlcOpenImport 1") $order
    $bx = [string]$r.data.backup.xmlPath
    Check 'Import live Replace: data.backup.xmlPath is a PLCopen file of both objects in .tcauto-backup' ($bx -like '*\.tcauto-backup\*\plcopen-replace.xml' -and (Test-Path -LiteralPath $bx) -and ([System.IO.File]::ReadAllText($bx)) -match 'FB_A' -and ([System.IO.File]::ReadAllText($bx)) -match 'ITF_A' -and (@($r.data.backup.objects) -join ',') -eq "$P^POUs^FB_A,$P^POUs^ITF_A") (J $r.data.backup)
    Check 'Import live Replace: data.backup.restore is the Import-TcPlcOpen -Option Replace command' ($r.data.backup.restore -eq "Import-TcPlcOpen -FilePath '$bx' -Option Replace -DryRun `$false" -and $r.data.backup.restoreNote -match 'ImportPlcOpen') "$($r.data.backup.restore)"
    Check 'Import live Replace: .zip backups hold the export and the original disk files' (@($r.data.backup.zipBackups).Count -eq 2 -and @($r.data.backup.zipBackups | Where-Object { $_.exportPath -like '*.zip' -and (Test-Path -LiteralPath $_.exportPath) }).Count -eq 2 -and @($r.data.backup.zipBackups | ForEach-Object { $_.backupFiles } | Where-Object { $_ -like '*FB_A.TcPOU' -and ([System.IO.File]::ReadAllText($_)) -match 'FB_A original' }).Count -eq 1 -and @($r.data.backup.zipBackups | ForEach-Object { $_.backupFiles } | Where-Object { $_ -like '*ITF_A.TcIO' }).Count -eq 1) (J $r.data.backup.zipBackups)
    $ri = @($r.data.replaced | Where-Object { $_.name -eq 'ITF_A' })[0]
    Check 'Import live Replace: readback reports the children really deleted' ((@($ri.deletedChildren) -join ',') -eq 'P_Cnt,P_Str' -and $r.data.verified -and @($r.data.added | Where-Object { $_.name -eq 'FB_New' }).Count -eq 1) (J $r.data.replaced)
    Check 'Import live Replace: project saved, the .plcproj readback expects the added object with its folder' (@($global:T.Saves).Count -eq 1 -and $global:T.Saves[0] -eq 'plc|POUs\FB_New.TcPOU' -and (@($r.data.expectedProjectFiles) -join ',') -eq 'POUs\FB_New.TcPOU' -and $null -ne $r.data.projectSaved) "$(J $global:T.Saves) $(J $r.data.projectSaved)"
    Check 'Import live Replace: BUILD_REQUIRED code-changed, no unsaved-.plcproj warning any more' ((Get-CodeChanged) -match 'Import-TcPlcOpen import\.xml \[Replace\]' -and @($r.data.warnings | Where-Object { $_ -match 'only after the project is saved' }).Count -eq 0) "$(Get-CodeChanged)"
    $r2 = Import-TcPlcOpen -FilePath $bx -Option Replace
    Check 'Import: the backup file itself previews a Replace of both objects (the restore path)' ($r2.success -and (@($r2.data.willReplace | ForEach-Object { $_.name }) -join ',') -eq 'FB_A,ITF_A') (J $r2.data.willReplace)

    Reset-Mock; Reset-BuildRequired; $global:T.ExportMode = 'notfound'
    $r = Import-TcPlcOpen -FilePath $imp -Option Replace -DryRun $false
    Check 'Import live Replace, PlcOpenExport backup fails -> PLCOPEN_BACKUP_FAILED, XAE import not called, nothing recorded' ($r.error.code -eq 'PLCOPEN_BACKUP_FAILED' -and $r.data.reason -eq 'plcopen-backup-failed' -and (@($r.data.backupObject) -join ',') -eq "$P^POUs^FB_A,$P^POUs^ITF_A" -and $global:T.ImportCalls.Count -eq 0 -and $null -eq (Get-CodeChanged) -and $global:T.Nodes.ContainsKey("$P^POUs^ITF_A^P_Cnt")) "$(J $r.error) | $(Get-CodeChanged)"
    Reset-Mock; $global:T.ExportMode = 'other'
    $r = Import-TcPlcOpen -FilePath $imp -Option Replace -DryRun $false
    Check 'Import live Replace, PLCopen backup lacks the objects -> PLCOPEN_BACKUP_FAILED, not imported' ($r.error.code -eq 'PLCOPEN_BACKUP_FAILED' -and $r.error.message -match 'lacks' -and $global:T.ImportCalls.Count -eq 0) (J $r.error)
    Reset-Mock; $global:T.ExportMode = 'nofile'
    $r = Import-TcPlcOpen -FilePath $imp -Option Replace -DryRun $false
    Check 'Import live Replace, PLCopen backup not written -> PLCOPEN_BACKUP_FAILED, not imported' ($r.error.code -eq 'PLCOPEN_BACKUP_FAILED' -and $global:T.ImportCalls.Count -eq 0) (J $r.error)
    Reset-Mock; $global:T.ExportChildMode = 'throw'
    $r = Import-TcPlcOpen -FilePath $imp -Option Replace -DryRun $false
    Check 'Import live Replace, .zip backup fails -> only a warning, imported (PLCopen backup is there)' ($r.success -and $global:T.ImportCalls.Count -eq 1 -and @($r.data.backup.zipBackups).Count -eq 0 -and @($r.data.warnings | Where-Object { $_ -match 'extra backup' -and $_ -match 'PLCopen backup' }).Count -eq 2) (J $r.data.warnings)
    Reset-Mock; $global:T.ExportChildMode = 'nofile'
    $r = Import-TcPlcOpen -FilePath $imp -Option Replace -DryRun $false
    Check 'Import live Replace, .zip not written -> only a warning, imported' ($r.success -and $global:T.ImportCalls.Count -eq 1 -and @($r.data.warnings | Where-Object { $_ -match 'extra backup' }).Count -eq 2) (J $r.data.warnings)

    # ===== Import live: project save fails
    Reset-Mock; Reset-BuildRequired; $global:T.SaveMode = 'missing'
    $r = Import-TcPlcOpen -FilePath $imp -Option Rename -DryRun $false
    Check 'Import live: .plcproj readback lacks the new objects -> PROJECT_SAVE_FAILED, BUILD_REQUIRED recorded' ($r.error.code -eq 'PROJECT_SAVE_FAILED' -and $r.data.verified -and $null -ne $r.data.projectSave -and (Get-CodeChanged) -match '\[Rename\] \[project not saved\]' -and (@($global:T.Saves) -join ';') -eq 'plc|POUs\FB_A_1.TcPOU,POUs\FB_New.TcPOU,POUs\ITF_A_1.TcIO') "$(J $r.error) | $(Get-CodeChanged) | $(J $global:T.Saves)"
    Reset-Mock; Reset-BuildRequired; $global:T.SaveMode = 'dialog'
    $r = Import-TcPlcOpen -FilePath $imp -Option Rename -DryRun $false
    Check 'Import live: dialog before the save -> IDE_MODAL_DIALOG, BUILD_REQUIRED recorded' ($r.error.code -eq 'IDE_MODAL_DIALOG' -and (Get-CodeChanged) -match 'project not saved') "$(J $r.error) | $(Get-CodeChanged)"
    Reset-Mock; $global:T.Dialog = $dialog
    $r = Import-TcPlcOpen -FilePath $newOnly -DryRun $false
    Check 'Import live modal dialog -> IDE_MODAL_DIALOG, XAE not called' ($r.error.code -eq 'IDE_MODAL_DIALOG' -and $global:T.ImportCalls.Count -eq 0) (J $r.error)

    # ===== Import live: Skip reports what was skipped
    Reset-Mock; Reset-BuildRequired
    $r = Import-TcPlcOpen -FilePath $imp -Option Skip -DryRun $false
    $sk = @($r.data.skipped | Where-Object { $_.name -eq 'FB_A' })[0]
    Check 'Import live Skip: data.skipped lists the conflicts, disk file unchanged' ($r.success -and @($r.data.skipped).Count -eq 2 -and $sk.unchanged -eq $true -and $sk.diskFile -like '*FB_A.TcPOU' -and $global:T.ImportCalls[0] -eq '3||True') (J $r.data.skipped)
    Check 'Import live Skip: the existing objects keep their children, FB_New added, recorded' ($global:T.Nodes.ContainsKey("$P^POUs^ITF_A^P_Cnt") -and $global:T.Nodes.ContainsKey("$P^POUs^FB_New") -and (Get-CodeChanged) -match '\[Skip\]') "$(Get-CodeChanged)"

    # ===== Import live: Rename finds the new names
    Reset-Mock; Reset-BuildRequired
    $r = Import-TcPlcOpen -FilePath $imp -Option Rename -DryRun $false
    Check 'Import live Rename: data.renamed has FB_A -> FB_A_1 and ITF_A -> ITF_A_1' ($r.success -and (@($r.data.renamed | ForEach-Object { "$($_.name)->$($_.newName)" }) -join ',') -eq 'FB_A->FB_A_1,ITF_A->ITF_A_1' -and $r.data.verified) (J $r.data.renamed)

    # ===== Import live: None without conflict, XAE conflict exception, verify failure
    Reset-Mock; Reset-BuildRequired
    $global:T.FileObjects = @(@{ Name = 'FB_New'; Kind = 'POU'; Members = @() })
    $r = Import-TcPlcOpen -FilePath $newOnly -DryRun $false
    Check 'Import live None: success, FB_New added, option 0 passed' ($r.success -and $global:T.ImportCalls[0] -eq '0||True' -and $global:T.Nodes.ContainsKey("$P^POUs^FB_New") -and (Get-CodeChanged) -match '\[None\]') (J $r.data)
    Reset-Mock; Reset-BuildRequired; $global:T.ImportMode = 'throw-conflict'
    $r = Import-TcPlcOpen -FilePath $newOnly -DryRun $false
    Check 'Import live: XAE "Import conflict!" -> PLCOPEN_CONFLICT with xaeConflicts, BUILD_REQUIRED recorded (API called)' ($r.error.code -eq 'PLCOPEN_CONFLICT' -and (@($r.data.xaeConflicts) -join ',') -eq 'FB_A,ITF_A' -and (Get-CodeChanged) -match 'Import-TcPlcOpen new-only\.xml \[None\] \[failed\]') "$(J $r.data) | $(Get-CodeChanged)"
    Reset-Mock; Reset-BuildRequired; $global:T.ImportMode = 'noop'
    $r = Import-TcPlcOpen -FilePath $newOnly -DryRun $false
    Check 'Import live: object missing afterwards -> PLCOPEN_VERIFY_FAILED, recorded' ($r.error.code -eq 'PLCOPEN_VERIFY_FAILED' -and @($r.data.missing) -contains 'FB_New' -and (Get-CodeChanged) -match 'verify failed') "$(J $r.error) | $(Get-CodeChanged)"

    # ===== hints / tools.json
    $codes = @('PLCOPEN_FAILED', 'PLCOPEN_FILE_EXISTS', 'PLCOPEN_CONFLICT', 'PLCOPEN_VERIFY_FAILED', 'PLCOPEN_BACKUP_FAILED')
    $missing = @($codes | Where-Object { [string]::IsNullOrWhiteSpace((& $mod { param($c) Get-TcErrorHint -Code $c } $_)) })
    Check 'hints exist for every new PLCOPEN_* code' ($missing.Count -eq 0) ($missing -join ',')
    $tj = Join-Path $PSScriptRoot '..\..\mcp-server\tools.json'
    $tools = @((Get-Content -LiteralPath $tj -Raw -Encoding UTF8 | ConvertFrom-Json).tools)
    $byName = @{}; foreach ($t in $tools) { $byName[$t.name] = $t }
    $t = $byName['ExportPlcOpen']
    Check 'tools.json ExportPlcOpen: Export-TcPlcOpen, not read-only (writes a file), not destructive, FilePath required' ($null -ne $t -and $t.cmdlet -eq 'Export-TcPlcOpen' -and $t.annotations.readOnlyHint -eq $false -and $t.annotations.destructiveHint -eq $false -and @($t.inputSchema.required) -contains 'FilePath' -and $t.inputSchema.properties.Selection.type -eq 'array') (J $t)
    $t = $byName['ImportPlcOpen']
    Check 'tools.json ImportPlcOpen: Import-TcPlcOpen, destructive, DryRun true, Option None|Replace|Rename|Skip default None' ($null -ne $t -and $t.cmdlet -eq 'Import-TcPlcOpen' -and $t.annotations.destructiveHint -eq $true -and $t.inputSchema.properties.DryRun.default -eq $true -and $t.inputSchema.properties.Option.default -eq 'None' -and (@($t.inputSchema.properties.Option.enum) -join ',') -eq 'None,Replace,Rename,Skip') (J $t.inputSchema)
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
