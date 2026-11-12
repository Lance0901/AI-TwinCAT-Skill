# Unit: #233 the SilentMode original of an IDE survives the end of the PowerShell process (MCP
# bridge restart, a new agent tool call): it is kept in <TCAUTO_STATE_DIR>\silent-originals.json
# (key: IDE pid + process start time). A new module instance (Import-Module -Force = a new process
# for the module state) reads it back. No IDE needed: the "IDE" is a hidden ping.exe this test
# starts (real pid + start time) and stops; its DTE is a mock in the ROT (Get-AllComObjects).
#   P  persisted original read back by a new module instance; removed after the restore; pruned
#      when the IDE process is gone; corrupt / unreadable file -> no record (fail closed)
#   C  Connect-TcIde / Disconnect-TcIde across module instances:
#      C1 original false recorded by instance 1, instance 2 sees SilentMode true -> restores false
#      C2 SilentMode true and NO record -> data.silentModeOriginalUnknown, Disconnect writes false
#      C3 SilentMode false and no record -> original false, not unknown
#   powershell.exe -NoProfile -File tests/Unit/silent-original-persist-233.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
$modPath = Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1'
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}

$stateFile = Join-Path $env:TCAUTO_STATE_DIR 'silent-originals.json'
$global:Settings233 = $null
$global:SilentWrites233 = [System.Collections.Generic.List[string]]::new()

# A new module instance with the ROT / modal-scan mocks: plays a new PowerShell process.
function New-Instance([int]$IdePid) {
    Import-Module $modPath -Force -WarningAction SilentlyContinue
    $m = Get-Module TwinCATAutomation
    & $m {
        param($p)
        $script:Unit233Pid = $p
        function script:Find-TcIdeModalDialog { [CmdletBinding()] param([int]$ProcessId = 0, [int]$TimeoutSec = 5, [int]$PrepareTimeoutSec = 0) $null }
        function script:Find-TcIdeModalDialogColdRetry { [CmdletBinding()] param() $script:TcLastModalScanRetried = $false; $null }
        function script:Get-AllComObjects {
            [CmdletBinding()] param([switch]$IncludeDisplayName)
            $dte = New-Object PSObject
            $dte | Add-Member -MemberType NoteProperty -Name Version -Value '17.0'
            $dte | Add-Member -MemberType NoteProperty -Name Solution -Value ([PSCustomObject]@{ FullName = ''; IsOpen = $false; Projects = [PSCustomObject]@{ Count = 0 } })
            $dte | Add-Member -MemberType ScriptMethod -Name GetObject -Value { param($n) if ($n -eq 'TcAutomationSettings') { , $global:Settings233 } else { throw "unexpected GetObject('$n')" } }
            @(@{ DisplayName = "!Fake.DTE.1:$($script:Unit233Pid)"; Object = $dte; ProgId = 'Fake.DTE.1'; ProcessId = $script:Unit233Pid })
        }
    } $IdePid
    $m
}
function New-Settings([bool]$Value) {
    $s = New-Object PSObject
    $s | Add-Member -MemberType NoteProperty -Name Store -Value $Value
    $s | Add-Member -MemberType ScriptProperty -Name SilentMode -Value { $this.Store } -SecondValue { param($v) $this.Store = [bool]$v; $global:SilentWrites233.Add([string][bool]$v) }
    $s
}
function Start-FakeIde { Start-Process -FilePath "$env:SystemRoot\System32\PING.EXE" -ArgumentList '-n', '600', '127.0.0.1' -WindowStyle Hidden -PassThru }

$ide = Start-FakeIde
$ide2 = Start-FakeIde
try {
    # --- P1: persisted, read back by a new module instance ---
    $mod = New-Instance $ide.Id
    & $mod { param($p) Set-TcIdeSilentOriginal -ProcessId $p -Value $false } $ide.Id
    $mod = New-Instance $ide.Id
    $v = & $mod { param($p) Get-TcIdeSilentOriginal -ProcessId $p } $ide.Id
    Check 'P1-persisted-false' ($null -ne $v -and $v -is [bool] -and $v -eq $false) "value=$v type=$(if ($null -ne $v) { $v.GetType().Name })"
    $recs = @()
    try { $recs = @(Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json | ForEach-Object { $_ }) } catch { }
    $r1 = @($recs | Where-Object { [int]$_.pid -eq $ide.Id })
    Check 'P2-file-shape' ($r1.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace([string]$r1[0].startTime) -and [string]$r1[0].imageName -eq 'PING') "records=$($recs.Count) start=$($r1[0].startTime) image=$($r1[0].imageName)"

    # --- P3: 'unknown' (getter unreadable) survives too ---
    & $mod { param($p) Set-TcIdeSilentOriginal -ProcessId $p -Value 'unknown' } $ide2.Id
    $mod = New-Instance $ide.Id
    $u = & $mod { param($p) Get-TcIdeSilentOriginal -ProcessId $p } $ide2.Id
    Check 'P3-persisted-unknown' ($u -is [string] -and $u -eq 'unknown') "value=$u"

    # --- P4: removed (restored) -> a new instance has no record ---
    & $mod { param($p) Set-TcIdeSilentOriginal -ProcessId $p -Value $null } $ide2.Id
    $mod = New-Instance $ide.Id
    $n = & $mod { param($p) Get-TcIdeSilentOriginal -ProcessId $p } $ide2.Id
    Check 'P4-removed' ($null -eq $n) "value=$n"

    # --- P5: the record of a process that is gone is pruned on the next write ---
    & $mod { param($p) Set-TcIdeSilentOriginal -ProcessId $p -Value $true } $ide2.Id
    Stop-Process -Id $ide2.Id -Force; $ide2.WaitForExit(5000) | Out-Null
    & $mod { param($p) Set-TcIdeSilentOriginal -ProcessId $p -Value $false } $ide.Id
    $recs = @(Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json | ForEach-Object { $_ })
    Check 'P5-pruned' (@($recs | Where-Object { [int]$_.pid -eq $ide2.Id }).Count -eq 0 -and @($recs | Where-Object { [int]$_.pid -eq $ide.Id }).Count -eq 1) "pids=$(@($recs | ForEach-Object { $_.pid }) -join ',')"

    # --- P6: a record with another start time (recycled pid) is not used ---
    $fake = @([PSCustomObject]@{ pid = $ide.Id; startTime = '2001-01-01T00:00:00.0000000Z'; imageName = 'PING'; original = $true; recordedAt = '2001-01-01T00:00:00.0000000Z' })
    Set-Content -LiteralPath $stateFile -Value (ConvertTo-Json -InputObject $fake -Depth 3) -Encoding UTF8
    $mod = New-Instance $ide.Id
    $rv = & $mod { param($p) Get-TcIdeSilentOriginal -ProcessId $p } $ide.Id
    Check 'P6-recycled-pid' ($null -eq $rv) "value=$rv"

    # --- P7: corrupt file -> no record (fail closed: the caller then treats a true as unknown) + warning ---
    Set-Content -LiteralPath $stateFile -Value '{ not json' -Encoding UTF8
    $mod = New-Instance $ide.Id
    $cv = & $mod { param($p) Get-TcIdeSilentOriginal -ProcessId $p } $ide.Id
    $cw = & $mod { $script:TcSilentOriginalWarning }
    Check 'P7-corrupt-no-record' ($null -eq $cv -and -not [string]::IsNullOrWhiteSpace([string]$cw)) "value=$cv warning=$cw"
    & $mod { param($p) Set-TcIdeSilentOriginal -ProcessId $p -Value $false } $ide.Id
    $kept = @(Get-ChildItem -LiteralPath $env:TCAUTO_STATE_DIR -Filter 'silent-originals.json.corrupt-*')
    $mod = New-Instance $ide.Id
    $after = & $mod { param($p) Get-TcIdeSilentOriginal -ProcessId $p } $ide.Id
    Check 'P8-corrupt-moved-aside' ($kept.Count -ge 1 -and $after -eq $false -and $null -ne $after) "kept=$($kept.Count) after=$after"
    Remove-Item -LiteralPath $stateFile -Force

    # --- C1: instance 1 connects (SilentMode false) and ends without Disconnect; instance 2 restores false ---
    $global:Settings233 = New-Settings $false
    $mod = New-Instance $ide.Id
    $r = Connect-TcIde -ProgId 'Fake.DTE.1' -NoLaunch
    Check 'C1a-connect' ($r.success -and $global:Settings233.Store -eq $true -and $r.data.silentModeOriginal -eq $false -and $r.data.silentModeOriginalUnknown -eq $false) "success=$($r.success) err=$($r.error.message) store=$($global:Settings233.Store) orig=$($r.data.silentModeOriginal) unknown=$($r.data.silentModeOriginalUnknown)"
    $mod = New-Instance $ide.Id   # process ended without Disconnect-TcIde
    $r = Connect-TcIde -ProgId 'Fake.DTE.1' -NoLaunch
    Check 'C1b-original-from-file' ($r.success -and $r.data.silentModeOriginal -eq $false -and $r.data.silentModeOriginalUnknown -eq $false -and $r.data.silentModeOriginalSource -eq 'state-file') "orig=$($r.data.silentModeOriginal) unknown=$($r.data.silentModeOriginalUnknown) source=$($r.data.silentModeOriginalSource)"
    $global:SilentWrites233.Clear()
    $null = Disconnect-TcIde
    Check 'C1c-restored-false' ($global:Settings233.Store -eq $false -and ($global:SilentWrites233 -join ',') -eq 'False') "store=$($global:Settings233.Store) writes=$($global:SilentWrites233 -join ',')"
    $mod = New-Instance $ide.Id
    $gone = & $mod { param($p) Get-TcIdeSilentOriginal -ProcessId $p } $ide.Id
    Check 'C1d-record-removed' ($null -eq $gone) "value=$gone"

    # --- C2: SilentMode true and no record -> unknown, restored to false (the value of a new IDE) ---
    $global:Settings233 = New-Settings $true
    $mod = New-Instance $ide.Id
    $r = Connect-TcIde -ProgId 'Fake.DTE.1' -NoLaunch
    Check 'C2a-unknown' ($r.success -and $r.data.silentModeOriginalUnknown -eq $true -and $null -eq $r.data.silentModeOriginal -and $r.data.silentModeOriginalSource -eq 'unknown-was-true') "unknown=$($r.data.silentModeOriginalUnknown) orig=$($r.data.silentModeOriginal) source=$($r.data.silentModeOriginalSource)"
    $mod = New-Instance $ide.Id   # and again in a later process: still unknown, never "true"
    $r = Connect-TcIde -ProgId 'Fake.DTE.1' -NoLaunch
    Check 'C2b-unknown-kept' ($r.success -and $r.data.silentModeOriginalUnknown -eq $true) "unknown=$($r.data.silentModeOriginalUnknown) source=$($r.data.silentModeOriginalSource)"
    $global:SilentWrites233.Clear()
    $d = Disconnect-TcIde
    Check 'C2c-restored-false' ($d.success -and $global:Settings233.Store -eq $false -and ($global:SilentWrites233 -join ',') -eq 'False') "store=$($global:Settings233.Store) writes=$($global:SilentWrites233 -join ',')"

    # --- C3: SilentMode false, no record -> original false, not unknown ---
    $global:Settings233 = New-Settings $false
    $mod = New-Instance $ide.Id
    $r = Connect-TcIde -ProgId 'Fake.DTE.1' -NoLaunch
    Check 'C3-false-known' ($r.success -and $r.data.silentModeOriginal -eq $false -and $r.data.silentModeOriginalUnknown -eq $false -and $r.data.silentModeOriginalSource -eq 'read') "orig=$($r.data.silentModeOriginal) unknown=$($r.data.silentModeOriginalUnknown) source=$($r.data.silentModeOriginalSource)"
    $null = Disconnect-TcIde
}
finally {
    foreach ($p in @($ide, $ide2)) { if ($null -ne $p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } }
    Remove-Variable -Name Settings233, SilentWrites233 -Scope Global -ErrorAction SilentlyContinue
}

"failed: $fail"
exit [Math]::Min($fail, 255)
