# Test fixture for test/modal-probe.test.js (real bridge/modal-probe.ps1): a WPF window titled like
# an XAE main window ("Probe Host - TcXaeShell"). The XAE main window is WPF too: behind a modal
# dialog its UIA IsEnabled stays TRUE and only WindowPattern.WindowInteractionState reports
# BlockedByModalWindow (verified on a real XAE with Help > About). With -ShowModal a WPF dialog
# titled 'TwinCAT PLC Control' owned by the main window is opened with ShowDialog() once the main
# window is rendered, which reproduces exactly that state.
# With -VsMessageBox the modal instead mimics the VS2022 WPF message box (measured on XAE 4026.22 in VS2022):
# AutomationId 'Microsoft.VisualStudio.MessageBox', title 'Microsoft Visual Studio', a TextBox with AutomationId
# 'Text' (Name = Text = -MessageText) and a Button AutomationId 'OKButton' (no Win32 control id); the main window
# gets AutomationId 'VisualStudioMainWindow'. Clicking OK prints "result Ok" and closes the box.
# Writes "ready" (main window rendered) and "dialog" (just before the modal opens) to stdout.
# Closes itself after -LifetimeSec so a test that dies never leaves the window behind.
# Windows PowerShell 5.1, run with -STA, ASCII only, no BOM.
param(
    [switch]$ShowModal,
    [switch]$VsMessageBox,
    [string]$MessageText = 'Active solution platform ''TwinCAT RT (x64)'' differs from current target platform ''TwinCAT OS (x64)''! Adjust solution platform and retry.',
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
if ($VsMessageBox) { [System.Windows.Automation.AutomationProperties]::SetAutomationId($main, 'VisualStudioMainWindow') }

$life = New-Object System.Windows.Threading.DispatcherTimer
$life.Interval = [TimeSpan]::FromSeconds([Math]::Max(1, $LifetimeSec))
$life.Add_Tick({ [System.Environment]::Exit(0) })
$life.Start()

$main.Add_ContentRendered({
    [Console]::Out.WriteLine('ready')
    [Console]::Out.Flush()
    if ($VsMessageBox) {
        $t = New-Object System.Windows.Threading.DispatcherTimer
        $t.Interval = [TimeSpan]::FromMilliseconds(100)
        $t.Add_Tick({
            $this.Stop()
            [Console]::Out.WriteLine('dialog')
            [Console]::Out.Flush()
            $dlg = New-Object System.Windows.Window
            $dlg.Title = 'Microsoft Visual Studio'
            $dlg.Width = 420
            $dlg.Height = 180
            $dlg.Owner = $main
            $dlg.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterOwner
            [System.Windows.Automation.AutomationProperties]::SetAutomationId($dlg, 'Microsoft.VisualStudio.MessageBox')
            $panel = New-Object System.Windows.Controls.StackPanel
            $tb = New-Object System.Windows.Controls.TextBox
            $tb.IsReadOnly = $true
            $tb.TextWrapping = [System.Windows.TextWrapping]::Wrap
            $tb.Text = $MessageText
            [System.Windows.Automation.AutomationProperties]::SetAutomationId($tb, 'Text')
            [System.Windows.Automation.AutomationProperties]::SetName($tb, $MessageText)
            $btn = New-Object System.Windows.Controls.Button
            $btn.Content = 'OK'
            $btn.Width = 80
            [System.Windows.Automation.AutomationProperties]::SetAutomationId($btn, 'OKButton')
            $btn.Add_Click({
                [Console]::Out.WriteLine('result Ok')
                [Console]::Out.Flush()
                [System.Windows.Window]::GetWindow($this).Close()
            })
            $null = $panel.Children.Add($tb)
            $null = $panel.Children.Add($btn)
            $dlg.Content = $panel
            $null = $dlg.ShowDialog()
        })
        $t.Start()
    }
    elseif ($ShowModal) {
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
