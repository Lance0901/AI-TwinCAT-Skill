# Test fixture for test/modal-probe.test.js (real bridge/modal-probe.ps1): a WPF window titled like
# an XAE main window ("Probe Host - TcXaeShell"). The XAE main window is WPF too: behind a modal
# dialog its UIA IsEnabled stays TRUE and only WindowPattern.WindowInteractionState reports
# BlockedByModalWindow (verified on a real XAE with Help > About). With -ShowModal a WPF dialog
# titled 'TwinCAT PLC Control' owned by the main window is opened with ShowDialog() once the main
# window is rendered, which reproduces exactly that state.
# Writes "ready" (main window rendered) and "dialog" (just before the modal opens) to stdout.
# Closes itself after -LifetimeSec so a test that dies never leaves the window behind.
# Windows PowerShell 5.1, run with -STA, ASCII only, no BOM.
param(
    [switch]$ShowModal,
    [string]$Title = 'Probe Host - TcXaeShell',
    [int]$LifetimeSec = 60
)

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$main = New-Object System.Windows.Window
$main.Title = $Title
$main.Width = 400
$main.Height = 200
$main.ShowInTaskbar = $false
$main.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
$main.Left = 40
$main.Top = 40
$main.Content = New-Object System.Windows.Controls.TextBlock
$main.Content.Text = 'probe host (WPF)'

$life = New-Object System.Windows.Threading.DispatcherTimer
$life.Interval = [TimeSpan]::FromSeconds([Math]::Max(1, $LifetimeSec))
$life.Add_Tick({ [System.Environment]::Exit(0) })
$life.Start()

$main.Add_ContentRendered({
    [Console]::Out.WriteLine('ready')
    [Console]::Out.Flush()
    if ($ShowModal) {
        $t = New-Object System.Windows.Threading.DispatcherTimer
        $t.Interval = [TimeSpan]::FromMilliseconds(100)
        $t.Add_Tick({
            $this.Stop()
            [Console]::Out.WriteLine('dialog')
            [Console]::Out.Flush()
            $dlg = New-Object System.Windows.Window
            $dlg.Title = 'TwinCAT PLC Control'
            $dlg.Width = 300
            $dlg.Height = 120
            $dlg.Owner = $main
            $dlg.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterOwner
            $dlg.Content = New-Object System.Windows.Controls.TextBlock
            $dlg.Content.Text = 'Internal error in the PLC compiler (probe test, WPF).'
            $null = $dlg.ShowDialog()
        })
        $t.Start()
    }
})

$app = New-Object System.Windows.Application
$null = $app.Run($main)
