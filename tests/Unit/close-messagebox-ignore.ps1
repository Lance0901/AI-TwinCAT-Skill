# Unit: Close-TcMessageBox -Answer Ignore clicks control id 1412 (the Ignore button of the VS2022
# solution reload prompt, #106; measured 2026-11-03 VS2022 zh-TW), no IDE needed. A Win32 fixture:
# a hidden STATIC window of this process with a BUTTON child whose control id is 1412. The parent
# never closes, so the click path runs to its end: BM_CLICK processed but the window still open,
# then WM_COMMAND posted and the window still open (#135 F4 diagnostics BmClick / WmCommand).
#   powershell.exe -NoProfile -File tests/Unit/close-messagebox-ignore.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 600) { $Detail = $Detail.Substring(0, 600) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}

if (-not ([System.Management.Automation.PSTypeName]'TcUnitFixture.Win32Fixture').Type) {
    Add-Type -Namespace TcUnitFixture -Name Win32Fixture -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr CreateWindowEx(uint exStyle, string className, string windowName, uint style, int x, int y, int width, int height, System.IntPtr parent, System.IntPtr menu, System.IntPtr instance, System.IntPtr param);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern bool DestroyWindow(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern int GetDlgCtrlID(System.IntPtr hWnd);
'@
}
$fx = [TcUnitFixture.Win32Fixture]
$WS_POPUP = [uint32]2147483648   # 0x80000000 (a hex literal is a negative Int32 in PS 5.1)
$WS_CHILD = [uint32]0x40000000
$parent = $fx::CreateWindowEx(0, 'STATIC', 'tcauto unit fixture', $WS_POPUP, 0, 0, 10, 10, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)
$button = [IntPtr]::Zero
try {
    Check 'fixture window created' ($parent -ne [IntPtr]::Zero) "hwnd $parent"
    $button = $fx::CreateWindowEx(0, 'BUTTON', 'Ignore', $WS_CHILD, 0, 0, 10, 10, $parent, [IntPtr]1412, [IntPtr]::Zero, [IntPtr]::Zero)
    Check 'fixture button has control id 1412' ($button -ne [IntPtr]::Zero -and $fx::GetDlgCtrlID($button) -eq 1412) "button $button id $($fx::GetDlgCtrlID($button))"

    $r = & $mod { param($h) Close-TcMessageBox -Hwnd $h -Answer Ignore -ProcessId $PID } $parent
    Check 'Ignore -> control id 1412 clicked (BM_CLICK processed, still open; WM_COMMAND posted, still open)' ($r.Sent -eq $true -and $r.ControlId -eq 1412 -and $r.Method -eq 'WM_COMMAND' -and $r.Closed -eq $false -and $r.BmClick -eq 'processed-still-open' -and $r.WmCommand -eq 'posted-still-open') ($r | ConvertTo-Json -Compress)

    $r = & $mod { param($h) Close-TcMessageBox -Hwnd $h -Answer Close -ProcessId $PID } $parent
    Check 'Close (WM_CLOSE) -> no BM_CLICK / WM_COMMAND diagnostics' ($r.Method -eq 'WM_CLOSE' -and $null -eq $r.BmClick -and $null -eq $r.WmCommand) ($r | ConvertTo-Json -Compress)

    # 'Reload' (259) is no longer an answer: Reset-TcSolution answers the solution prompt Ignore
    $bound = $null
    try { $null = & $mod { param($h) Close-TcMessageBox -Hwnd $h -Answer Reload -ProcessId $PID } $parent; $bound = 'accepted' }
    catch { $bound = $_.Exception.GetType().Name }
    Check 'Close-TcMessageBox -Answer Reload is rejected by ValidateSet' ($bound -eq 'ParameterBindingValidationException') "$bound"
    $bound = $null
    try { $null = & $mod { Close-TcReloadPrompt -Dialog @{ Hwnd = 0 } -Answer Reload } ; $bound = 'accepted' }
    catch { $bound = $_.Exception.GetType().Name }
    Check 'Close-TcReloadPrompt -Answer Reload is rejected by ValidateSet' ($bound -eq 'ParameterBindingValidationException') "$bound"
    $p = & $mod { Close-TcReloadPrompt -Dialog @{ Hwnd = 0 } -Answer Ignore }
    Check 'Close-TcReloadPrompt accepts -Answer Ignore (unknown handle -> not sent)' ($p.Sent -eq $false -and $p.Answer -eq 'Ignore' -and $p.Dismissed -eq $false) ($p | ConvertTo-Json -Compress -Depth 2)
}
finally {
    if ($button -ne [IntPtr]::Zero) { $null = $fx::DestroyWindow($button) }
    if ($parent -ne [IntPtr]::Zero) { $null = $fx::DestroyWindow($parent) }
}
"failed: $fail"
exit [Math]::Min($fail, 255)
