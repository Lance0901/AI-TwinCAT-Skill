# Test fixture for test/modal-probe.test.js (#64 review): a custom dialog for Close-TcMessageBox -
# a WinForms form with a native Win32 BUTTON child whose control id is 6 (IDYES), so GetDlgItem /
# BM_CLICK / WM_COMMAND hit it exactly like a #32770 dialog button. The form's own WndProc handles
# WM_COMMAND id 6 (what the button's BN_CLICKED and a posted WM_COMMAND both deliver) and writes
# "result Yes <n>" (n = how many answers arrived) to stdout.
#   -Mode Nested          the Yes handler opens a nested MessageBox owned by the form (the form is
#                         then disabled and the synchronous BN_CLICKED of BM_CLICK does not return)
#   -Mode DisabledButton  the button is WS_DISABLED: BM_CLICK is processed but clicks nothing, so
#                         only the WM_COMMAND fallback answers; the handler then closes the form
# Writes "ready <hwnd>" once the form is shown. Closes itself after -LifetimeSec.
# Windows PowerShell 5.1, run with -STA, ASCII only, no BOM.
param(
    [ValidateSet('Nested', 'DisabledButton')]
    [string]$Mode = 'Nested',
    [int]$LifetimeSec = 60
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public class TcFixtureDialog : Form {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateWindowEx(int exStyle, string cls, string name, int style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    public string Mode = "Nested";
    public int Answers;
    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        int style = 0x40000000 | 0x10000000; // WS_CHILD | WS_VISIBLE, BS_PUSHBUTTON
        if (Mode == "DisabledButton") style |= 0x08000000; // WS_DISABLED
        CreateWindowEx(0, "BUTTON", "Yes", style, 10, 10, 80, 30, Handle, (IntPtr)6, IntPtr.Zero, IntPtr.Zero);
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0111 && (m.WParam.ToInt64() & 0xFFFF) == 6) {
            Answers++;
            Console.Out.WriteLine("result Yes " + Answers);
            Console.Out.Flush();
            if (Mode == "Nested") MessageBox.Show(this, "nested after answer " + Answers, "Nested");
            else Close();
            return;
        }
        base.WndProc(ref m);
    }
}
'@

$form = New-Object TcFixtureDialog
$form.Mode = $Mode
$form.Text = 'Probe Dialog'
$form.Width = 300
$form.Height = 150
$form.ShowInTaskbar = $false
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.Location = New-Object System.Drawing.Point(60, 60)

$life = New-Object System.Windows.Forms.Timer
$life.Interval = [Math]::Max(1, $LifetimeSec) * 1000
$life.Add_Tick({ [System.Environment]::Exit(0) })
$life.Start()

$form.Add_Shown({
    [Console]::Out.WriteLine("ready $([long]$form.Handle)")
    [Console]::Out.Flush()
})

[System.Windows.Forms.Application]::Run($form)
