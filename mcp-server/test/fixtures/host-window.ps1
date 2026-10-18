# Test fixture for test/modal-probe.test.js (real bridge/modal-probe.ps1): a plain WinForms window
# titled like an XAE main window ("Probe Host - TcXaeShell"). With -ShowMessageBox a message box
# 'TwinCAT PLC Control' owned by the form is opened once the form is shown, so the form becomes
# disabled exactly like the XAE main window behind a real modal dialog.
# Writes "ready" (form shown) and "dialog" (just before the message box opens) to stdout.
# Closes itself after -LifetimeSec so a test that dies never leaves the window behind.
# Windows PowerShell 5.1, run with -STA, ASCII only, no BOM.
param(
    [switch]$ShowMessageBox,
    [string]$Title = 'Probe Host - TcXaeShell',
    [int]$LifetimeSec = 60
)

Add-Type -AssemblyName System.Windows.Forms

$form = New-Object System.Windows.Forms.Form
$form.Text = $Title
$form.Width = 400
$form.Height = 200
$form.ShowInTaskbar = $false
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.Location = New-Object System.Drawing.Point(40, 40)

$life = New-Object System.Windows.Forms.Timer
$life.Interval = [Math]::Max(1, $LifetimeSec) * 1000
$life.Add_Tick({ [System.Environment]::Exit(0) })
$life.Start()

$form.Add_Shown({
    [Console]::Out.WriteLine('ready')
    [Console]::Out.Flush()
    if ($ShowMessageBox) {
        $t = New-Object System.Windows.Forms.Timer
        $t.Interval = 100
        $t.Add_Tick({
            $this.Stop()
            [Console]::Out.WriteLine('dialog')
            [Console]::Out.Flush()
            $null = [System.Windows.Forms.MessageBox]::Show($form, 'Internal error in the PLC compiler (probe test).', 'TwinCAT PLC Control')
        })
        $t.Start()
    }
})

[System.Windows.Forms.Application]::Run($form)
