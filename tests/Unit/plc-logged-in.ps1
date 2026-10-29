# Unit: task 1.8 PLC_LOGGED_IN (phase0-1.7 finding 4): Add-TcPou / Add-TcDut / Add-TcGvl while the PLC is
# logged in. XAE's CreateChild error "Cannot add an object because it affects a device you are currently
# logged into" (measured 2026-10-29, 4026 XAE in VS2022) -> PLC_LOGGED_IN with a PlcLogout hint, and an
# error returned by CreateChild itself records no BUILD_REQUIRED. No IDE: mock ITcSysManager whose
# folder CreateChild throws; Resolve-TcPlcProjectPath / Get-TcIdeModalDialog / Invoke-TcPlcObjectSave stubbed.
#   powershell.exe -NoProfile -File tests/Unit/plc-logged-in.ps1
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

$P = 'TIPC^plc^plc Project'
$global:MockMode = 'loggedin'   # loggedin | other | idetimeout
$global:MockTree = @{}
$global:LoggedInText = 'Cannot add an object because it affects a device you are currently logged into.'
function New-MockFolder([string]$Path) {
    $o = [PSCustomObject]@{ PathName = $Path; Name = ($Path -split '\^')[-1]; ItemType = 601; ChildCount = 0 }
    $o | Add-Member -MemberType ScriptMethod -Name Child -Value { param($i) $null }
    $o | Add-Member -MemberType ScriptMethod -Name CreateChild -Value {
        param($name, $subType, $before, $vInfo)
        switch ($global:MockMode) {
            'loggedin' { throw [System.Runtime.InteropServices.COMException]::new($global:LoggedInText, -2147467259) }
            'idetimeout' { throw "IDE_TIMEOUT: 'CreateChild $name' did not return within 120 s (mock)" }
            default { throw [System.Runtime.InteropServices.COMException]::new('Some other XAE refusal (mock)', -2147467259) }
        }
    }
    $global:MockTree[$Path] = $o
}
New-MockFolder $P
New-MockFolder "$P^POUs"
New-MockFolder "$P^DUTs"
New-MockFolder "$P^GVLs"
$sm = [PSCustomObject]@{}
$sm | Add-Member -MemberType ScriptMethod -Name LookupTreeItem -Value {
    param($path)
    if (-not $global:MockTree.ContainsKey($path)) { throw "Item not found: $path" }
    $global:MockTree[$path]
}
& $mod {
    param($s, $p)
    $script:TcIdeProcessId = $null; $script:TcIdeConnected = $true; $script:TcDte = [PSCustomObject]@{}; $script:TcSysManager = $s; $script:TcSolutionPath = 'C:\Demo\LoggedIn.sln'
    function script:Resolve-TcPlcProjectPath { param($SysManager) 'TIPC^plc^plc Project' }
    function script:Get-TcIdeModalDialog { $null }
    function script:Invoke-TcPlcObjectSave { [CmdletBinding()] param([string]$ObjectPath, [string]$ExpectFile, [string]$ExpectLibrary, [string]$What) throw 'save must not be reached (mock)' }
} $sm $P
function Get-CodeChanged { & $mod { $e = Get-TcBuildRequired; if ($null -eq $e) { return $null }; (Get-TcBuildRequiredReasons $e)['code-changed'] } }
function Reset-BuildRequired { & $mod { $null = Clear-TcBuildRequired } }
$hint = & $mod { Get-TcErrorHint -Code 'PLC_LOGGED_IN' }
Check 'PLC_LOGGED_IN hint registered and names PlcLogout / Exit-TcPlcOnline' ($hint -match 'PlcLogout' -and $hint -match 'Exit-TcPlcOnline') "$hint"

# --- logged in: all three Add-* -> PLC_LOGGED_IN, hint, nothing recorded
$global:MockMode = 'loggedin'
$calls = @(
    @('Add-TcPou', { Add-TcPou -Name FB_New -Type FunctionBlock }),
    @('Add-TcDut', { Add-TcDut -Name ST_New -DutType Struct }),
    @('Add-TcGvl', { Add-TcGvl -Name GVL_P0 -Variables @(@{ name = 'bFlag'; type = 'BOOL' }) })
)
foreach ($c in $calls) {
    Reset-BuildRequired
    $r = & $c[1]
    Check "$($c[0]) logged in -> PLC_LOGGED_IN + PlcLogout hint" ((-not $r.success) -and $r.error.code -eq 'PLC_LOGGED_IN' -and $r.error.hint -eq $hint -and $r.error.message -match 'logged into') ($r | ConvertTo-Json -Compress -Depth 3)
    $cc = Get-CodeChanged
    Check "$($c[0]) logged in -> no BUILD_REQUIRED (no data.buildRequired, nothing in the state)" ($null -eq $cc -and ($null -eq $r.PSObject.Properties['data'] -or $null -eq $r.data -or $null -eq $r.data.PSObject.Properties['buildRequired'])) "codeChanged=$cc"
}

# --- other CreateChild refusal: keeps *_CREATE_FAILED, still not recorded (CreateChild itself failed)
$global:MockMode = 'other'
Reset-BuildRequired
$r = Add-TcGvl -Name GVL_Other
Check 'other CreateChild error -> GVL_CREATE_FAILED (not PLC_LOGGED_IN)' ((-not $r.success) -and $r.error.code -eq 'GVL_CREATE_FAILED') "code=$($r.error.code)"
Check 'other CreateChild error -> nothing recorded' ($null -eq (Get-CodeChanged)) "$(Get-CodeChanged)"

# --- IDE_* during CreateChild (may have run inside XAE) -> conservative record kept (#65)
$global:MockMode = 'idetimeout'
Reset-BuildRequired
$r = Add-TcPou -Name FB_T -Type FunctionBlock
Check 'IDE_TIMEOUT during CreateChild -> IDE_TIMEOUT, recorded (conservative)' ((-not $r.success) -and $r.error.code -eq 'IDE_TIMEOUT' -and $r.data.buildRequired -eq 'PLC code changed by Add-TcPou FB_T [failed after CreateChild]') ($r | ConvertTo-Json -Compress -Depth 3)
Reset-BuildRequired

# --- ConvertTo-TcAdsErrorCode on the raw text and on a modal-dialog wrapper
$m = & $mod { param($t) ConvertTo-TcAdsErrorCode -InputObject $t } "Exception calling ""CreateChild"" with ""4"" argument(s): ""$global:LoggedInText"""
Check 'raw XAE text -> PLC_LOGGED_IN' ($m.Code -eq 'PLC_LOGGED_IN') "$($m.Code)"
$m = & $mod { param($t) ConvertTo-TcAdsErrorCode -InputObject $t } "IDE_MODAL_DIALOG: TwinCAT | x (operation 'CreateChild', original error: $global:LoggedInText)"
Check 'modal dialog wrapper stays IDE_MODAL_DIALOG' ($m.Code -eq 'IDE_MODAL_DIALOG') "$($m.Code)"

& $mod { $script:TcSysManager = $null; $script:TcDte = $null; $script:TcIdeConnected = $false; $script:TcSolutionPath = $null }
Remove-Item -LiteralPath $env:TCAUTO_STATE_DIR -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item Env:\TCAUTO_STATE_DIR -ErrorAction SilentlyContinue
"failed: $fail"
exit [Math]::Min($fail, 255)
