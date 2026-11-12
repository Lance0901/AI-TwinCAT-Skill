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
#   R  PR #266 review:
#      U1 getter fails, setter works -> unknown, record 'assumed-false', Disconnect writes false, record gone
#      U2 a legacy 'unknown' record -> treated as assumed-false (restored to false)
#      U3 setter fails -> nothing changed: no record kept, Disconnect writes nothing
#      W1 state file not writable -> data.silentModeStateWarning, Disconnect restores from memory
#      M1 two module instances on one IDE: A disconnects first (restores), B is still connected and
#         restores again on its own Disconnect (documented current behavior, follow-up issue)
#      F1 restore fails -> data.silentModeRestoreError, record kept for a later restore
#      Q1 -Quit whose DTE.Quit fails without -Kill -> restored (the IDE keeps running)
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
        # a throwing ScriptProperty getter of a mock reads as $null: failures are injected here by OperationName
        $script:Unit233ComRetry = ${function:Invoke-TcComRetry}
        function script:Invoke-TcComRetry {
            [CmdletBinding()] param([Parameter(Position = 0)][scriptblock]$ScriptBlock, [int]$MaxRetries = 5, [string]$OperationName = 'COM call', [int]$TimeoutSec = 120)
            if ($OperationName -eq 'SilentMode read (original)' -and $global:GetterThrows233) { throw 'RPC_E_SERVERFAULT (mock: SilentMode getter fails)' }
            if ($OperationName -eq 'SilentMode' -and $global:SetThrows233) { throw 'RPC_E_SERVERFAULT (mock: SilentMode setter fails)' }
            if ($OperationName -eq 'SilentMode restore' -and $global:RestoreThrows233) { throw 'RPC_E_SERVERFAULT (mock: SilentMode restore fails)' }
            if ($OperationName -eq 'DTE.Quit' -and $global:QuitThrows233) { throw 'E_FAIL (mock: DTE.Quit fails)' }
            & $script:Unit233ComRetry @PSBoundParameters
        }
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
    & $mod { param($p) Set-TcIdeSilentOriginal -ProcessId $p -Value 'assumed-false' } $ide2.Id
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

    # ================= PR #266 review =================
    function Get-Rec233([int]$P) { $m = New-Instance $ide.Id; & $m { param($x) Get-TcIdeSilentOriginal -ProcessId $x } $P }
    $global:GetterThrows233 = $false; $global:SetThrows233 = $false; $global:RestoreThrows233 = $false; $global:QuitThrows233 = $false

    # --- U1: getter fails, setter works -> assumed-false, Disconnect writes false, record removed ---
    $global:Settings233 = New-Settings $true
    $mod = New-Instance $ide.Id
    $global:GetterThrows233 = $true
    $r = Connect-TcIde -ProgId 'Fake.DTE.1' -NoLaunch
    $global:GetterThrows233 = $false
    $rec = & $mod { param($p) Get-TcIdeSilentOriginal -ProcessId $p } $ide.Id
    Check 'U1a-unreadable-unknown' ($r.success -and $r.data.silentModeOriginalUnknown -eq $true -and $r.data.silentModeOriginalSource -eq 'unreadable' -and $rec -eq 'assumed-false' -and $global:Settings233.Store -eq $true) "unknown=$($r.data.silentModeOriginalUnknown) source=$($r.data.silentModeOriginalSource) rec=$rec store=$($global:Settings233.Store)"
    $global:SilentWrites233.Clear()
    $d = Disconnect-TcIde
    Check 'U1b-restored-false' ($d.success -and ($global:SilentWrites233 -join ',') -eq 'False' -and $d.data.silentModeRestored -eq $false -and $null -ne $d.data.silentModeRestored -and $d.data.silentModeOriginalUnknown -eq $true) "writes=$($global:SilentWrites233 -join ',') restored=$($d.data.silentModeRestored) unknown=$($d.data.silentModeOriginalUnknown)"
    $after = Get-Rec233 $ide.Id
    Check 'U1c-record-removed' ($null -eq $after) "rec=$after"

    # --- U2: legacy 'unknown' record (before this fix: never restored) -> restored to false ---
    $global:Settings233 = New-Settings $true
    $mod = New-Instance $ide.Id
    & $mod { param($p) Set-TcIdeSilentOriginal -ProcessId $p -Value 'unknown' } $ide.Id
    $mod = New-Instance $ide.Id
    $r = Connect-TcIde -ProgId 'Fake.DTE.1' -NoLaunch
    $global:SilentWrites233.Clear()
    $d = Disconnect-TcIde
    $after = Get-Rec233 $ide.Id
    Check 'U2-legacy-unknown-restored' ($r.data.silentModeOriginalUnknown -eq $true -and ($global:SilentWrites233 -join ',') -eq 'False' -and $null -eq $after) "unknown=$($r.data.silentModeOriginalUnknown) writes=$($global:SilentWrites233 -join ',') rec=$after"

    # --- U3: setter fails -> nothing changed: no record, Disconnect writes nothing ---
    $global:Settings233 = New-Settings $false
    $mod = New-Instance $ide.Id
    $global:SetThrows233 = $true
    $r = Connect-TcIde -ProgId 'Fake.DTE.1' -NoLaunch
    $global:SetThrows233 = $false
    $rec = & $mod { param($p) Get-TcIdeSilentOriginal -ProcessId $p } $ide.Id
    $global:SilentWrites233.Clear()
    $d = Disconnect-TcIde
    Check 'U3-setter-fails-nothing-kept' ($r.data.silentMode -eq $false -and $null -eq $rec -and $global:SilentWrites233.Count -eq 0 -and $null -eq $d.data.silentModeRestored) "silentMode=$($r.data.silentMode) rec=$rec writes=$($global:SilentWrites233 -join ',')"

    # --- W1: state file not writable -> warning, Disconnect restores from memory ---
    $global:Settings233 = New-Settings $false
    $mod = New-Instance $ide.Id
    & $mod { function script:Write-TcIdeSolutionRecords { [CmdletBinding()] param([object[]]$Records, [string]$Path) if ($Path -like '*silent-originals.json') { throw 'access denied (mock)' } } }
    $r = Connect-TcIde -ProgId 'Fake.DTE.1' -NoLaunch
    $global:SilentWrites233.Clear()
    $d = Disconnect-TcIde
    Check 'W1-write-fails-warning-memory-restore' ($r.success -and -not [string]::IsNullOrWhiteSpace([string]$r.data.silentModeStateWarning) -and ($global:SilentWrites233 -join ',') -eq 'False' -and $d.data.silentModeRestored -eq $false) "warning=$($r.data.silentModeStateWarning) writes=$($global:SilentWrites233 -join ',')"
    if (Test-Path -LiteralPath $stateFile) { Remove-Item -LiteralPath $stateFile -Force }

    # --- M1: two module instances on the same IDE (A disconnects first) ---
    $global:Settings233 = New-Settings $false
    $modA = New-Instance $ide.Id
    $rA = & $modA { Connect-TcIde -ProgId 'Fake.DTE.1' -NoLaunch }
    $modB = New-Instance $ide.Id
    $rB = & $modB { Connect-TcIde -ProgId 'Fake.DTE.1' -NoLaunch }
    $global:SilentWrites233.Clear()
    $dA = & $modA { Disconnect-TcIde }
    $afterA = $global:Settings233.Store
    $bConnected = & $modB { [bool]$script:TcIdeConnected }
    $dB = & $modB { Disconnect-TcIde }
    $after = Get-Rec233 $ide.Id
    Check 'M1-a-first-restores-b-again' ($rA.data.silentModeOriginalSource -eq 'read' -and $rB.data.silentModeOriginalSource -eq 'state-file' -and $afterA -eq $false -and $bConnected -and $dB.data.silentModeRestored -eq $false -and ($global:SilentWrites233 -join ',') -eq 'False,False' -and $null -eq $after) "A=$($rA.data.silentModeOriginalSource) B=$($rB.data.silentModeOriginalSource) afterA=$afterA bConnected=$bConnected writes=$($global:SilentWrites233 -join ',') rec=$after"

    # --- F1: restore fails -> error reported, record kept ---
    $global:Settings233 = New-Settings $false
    $mod = New-Instance $ide.Id
    $r = Connect-TcIde -ProgId 'Fake.DTE.1' -NoLaunch
    $global:RestoreThrows233 = $true
    $d = Disconnect-TcIde -WarningAction SilentlyContinue
    $global:RestoreThrows233 = $false
    $kept = Get-Rec233 $ide.Id
    Check 'F1-restore-fails-record-kept' ($d.success -and $null -eq $d.data.silentModeRestored -and -not [string]::IsNullOrWhiteSpace([string]$d.data.silentModeRestoreError) -and $kept -eq $false -and $null -ne $kept -and $global:Settings233.Store -eq $true) "restored=$($d.data.silentModeRestored) error=$($d.data.silentModeRestoreError) kept=$kept"
    if (Test-Path -LiteralPath $stateFile) { Remove-Item -LiteralPath $stateFile -Force }

    # --- Q1: -Quit, DTE.Quit fails, no -Kill -> SilentMode restored (the IDE keeps running) ---
    $global:Settings233 = New-Settings $false
    $mod = New-Instance $ide.Id
    $r = Connect-TcIde -ProgId 'Fake.DTE.1' -NoLaunch
    & $mod { $script:TcIdeSelectedBy = 'launched' }   # owned, so -Quit is attempted
    $global:QuitThrows233 = $true
    $global:SilentWrites233.Clear()
    $q = Disconnect-TcIde -Quit
    $global:QuitThrows233 = $false
    Check 'Q1-quit-failed-restores' (-not $q.success -and $q.error.code -eq 'IDE_QUIT_FAILED' -and $q.data.quit -eq $false -and ($global:SilentWrites233 -join ',') -eq 'False' -and $q.data.silentModeRestored -eq $false) "code=$($q.error.code) quit=$($q.data.quit) writes=$($global:SilentWrites233 -join ',') restored=$($q.data.silentModeRestored)"
    & $mod { $script:TcIdeConnected = $false; $script:TcDte = $null; $script:TcIdeProcessId = $null; $script:TcIdeSelectedBy = $null }
}
finally {
    foreach ($p in @($ide, $ide2)) { if ($null -ne $p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } }
    Remove-Variable -Name Settings233, SilentWrites233, GetterThrows233, SetThrows233, RestoreThrows233, QuitThrows233 -Scope Global -ErrorAction SilentlyContinue
}

"failed: $fail"
exit [Math]::Min($fail, 255)
