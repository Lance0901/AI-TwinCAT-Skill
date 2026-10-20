# Test fixture for test/modal-probe.test.js: imports the TwinCATAutomation module, scans
# -ProcessId with the module's Get-TcIdeModalDialog and, with -Answer, answers the dialog with
# the module's Close-TcMessageBox (by control id). With -Classify it only classifies the given
# title / text pairs (no window needed). Writes ONE JSON line to stdout.
# Windows PowerShell 5.1, ASCII only, no BOM.
param(
    [Parameter(Mandatory = $true)]
    [string]$ModulePath,

    [int]$ProcessId = 0,

    [string]$Answer = '',

    [switch]$Classify,

    # Pass handle 0 to Close-TcMessageBox (exercises its UI Automation lookup of the VS2022 message box).
    [switch]$ZeroHwnd
)

$ErrorActionPreference = 'Stop'
$mod = Import-Module $ModulePath -Force -PassThru -WarningAction SilentlyContinue

if ($Classify) {
    $samples = @(
        @{ name = 'file'; title = 'Microsoft Visual Studio'; text = "C:\p\POUs\MAIN.TcPOU`r`n`r`nThis file has been changed outside the environment. Reload the new file?" },
        @{ name = 'project'; title = 'TwinCAT XAE'; text = "The project file 'C:\p\plc\plc.plcproj' has been modified outside of TwinCAT XAE.  Do you want to reload the project?" },
        @{ name = 'other'; title = 'TwinCAT XAE'; text = 'Build failed' }
    )
    $out = [ordered]@{}
    foreach ($s in $samples) {
        $r = & $mod { param($t, $x) @{ kind = (Get-TcModalDialogKind -Title $t -Text $x); reloadTarget = (Get-TcReloadTarget -Title $t -Text $x) } } $s.title $s.text
        $out[$s.name] = [ordered]@{ kind = $r.kind; reloadTarget = $r.reloadTarget }
    }
    [Console]::Out.WriteLine(($out | ConvertTo-Json -Compress -Depth 5))
    exit 0
}

$dialog = & $mod { param($p) Get-TcIdeModalDialog -ProcessId $p -TimeoutSec 10 } $ProcessId
$send = $null
if ($null -ne $dialog -and -not [string]::IsNullOrWhiteSpace($Answer)) {
    $h = if ($ZeroHwnd) { 0 } else { $dialog.Hwnd }
    $send = & $mod { param($h, $a, $p) Close-TcMessageBox -Hwnd ([IntPtr][long]$h) -Answer $a -ProcessId $p } $h $Answer $ProcessId
}
$buttons = @()
if ($null -ne $dialog) { $buttons = @(& $mod { param($b) ConvertTo-TcDialogButtonList -Buttons $b } $dialog.Buttons) }
$result = [ordered]@{
    dialog = if ($null -eq $dialog) { $null } else {
        [ordered]@{ title = $dialog.Title; text = $dialog.Text; kind = $dialog.Kind; reloadTarget = $dialog.ReloadTarget; hwnd = $dialog.Hwnd; buttons = $buttons }
    }
    send   = if ($null -eq $send) { $null } else { [ordered]@{ sent = $send.Sent; method = $send.Method; controlId = $send.ControlId; reason = $send.Reason } }
}
[Console]::Out.WriteLine(($result | ConvertTo-Json -Compress -Depth 6))
