# Unit: #121 follow-ups of the ReportIssue / New-TcIssueReport de-identification (#78). No IDE / ADS / runtime / network needed.
#   (1) customer-name parts inside POU / DUT names (camel-case parts, beginnings of 5+ letters), Beckhoff names stay
#   (2) free-text renamed CX hosts (Zebra-CX01), vendor / model names stay
#   (3) raw cut: a run without a boundary is never cut by count (no partial token)
#   (5) V10.0.0.5 / ver.10.0.0.5, MAC without separators (keyword or Beckhoff prefix 00-01-05), versions / numbers stay
#   powershell.exe -NoProfile -File tests/Unit/issue-report-121.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
$env:TCAUTO_STATE_DIR = Join-Path $env:TEMP ("tcauto-unit-state-121-{0}" -f [guid]::NewGuid().ToString('N'))
$modulePath = Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
Import-Module $modulePath -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 500) { $Detail = $Detail.Substring(0, 500) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $(if ($Ok) { '' } else { $Detail })
    if (-not $Ok) { $script:fail++ }
}
function Mask([string]$Text, [string[]]$Extra) { $c = @{}; & $mod { param($x, $c, $e) ConvertTo-TcDeidentifiedText -Text $x -Counts $c -ExtraMask $e } $Text $c $Extra }

# ---- 1 customer-name parts in POU / DUT / variable names
$pre = 'D:\Customers\Zebrafab\Line7\Main.sln'
$o = Mask ($pre + ' opened. FB_Zebra.TcPOU ST_ZebraRecipe nZebraCount MAIN FB_Motor Tc2_Standard Tc2_MC2 ST_Recipe E_State TcUnit I_Zebras')
Check 'beginning of the folder name (FB_Zebra) and camel-case part (ST_ZebraRecipe, nZebraCount) masked' ($o -notmatch 'Zebra(?!s)' -and $o -match 'ST_<redacted>Recipe' -and $o -match 'FB_<redacted>\.TcPOU') $o
Check 'Beckhoff / IEC names stay: MAIN, FB_, Tc2_Standard, Tc2_MC2, ST_Recipe, E_State, TcUnit' ($o -cmatch 'MAIN' -and $o -cmatch 'FB_Motor' -and $o -cmatch 'Tc2_Standard' -and $o -cmatch 'Tc2_MC2' -and $o -cmatch 'ST_Recipe' -and $o -cmatch 'E_State' -and $o -cmatch 'TcUnit') $o
Check 'a longer word that only starts like the prefix (Zebras) is not a prefix of the folder name and stays' ($o -cmatch 'I_Zebras') $o
$o = Mask ('D:\Customers\Motorworks\Line7\Main.sln FB_MotorControl Motorworks')
Check 'common word (Motor) is never masked by the prefix tier; the folder name itself is' ($o -cmatch 'FB_MotorControl' -and $o -notmatch 'Motorworks') $o
$o = Mask ('D:\Customers\Zebra\Main.sln ZebraRecipe FB_Zebra Zebrax')
Check 'folder name as a whole camel-case part: ZebraRecipe -> <redacted>Recipe' ($o -cmatch '<redacted>Recipe' -and $o -notmatch 'FB_Zebra' -and $o -cmatch 'Zebrax') $o
$o = Mask ('D:\Customers\Zebrafab\Main.sln FB_Zeb ST_Zebr')
Check 'prefixes shorter than 5 letters are not masked' ($o -cmatch 'FB_Zeb ST_Zebr') $o
$o = Mask 'FB_Zebra ST_ZebraRecipe MAIN Tc2_Standard'
Check 'without any path / folder nothing is masked' ($o -ceq 'FB_Zebra ST_ZebraRecipe MAIN Tc2_Standard') $o

# ---- 2 renamed CX hosts in free text
foreach ($pair in @(@('route Zebra-CX01 is down', 'Zebra'), @('plc Zebra-Line3-CX5130 offline', 'Zebra|Line3'), @('target CX5130-Zebra not found', 'Zebra'), @('ping zebra-cx01.', 'zebra'))) {
    $o = Mask $pair[0]
    Check ("renamed CX host: " + $pair[0]) ($o -notmatch $pair[1] -and $o -match '<host>') $o
}
foreach ($t in 'Beckhoff CX5130 runs TwinCAT', 'a CX5130-based controller', 'Beckhoff-CX5130 data sheet', 'CX2040-0121 module', 'CX5130 and CX9020') {
    $o = Mask $t
    Check ("CX model names stay: $t") ($o -ceq $t) $o
}

# ---- 3 raw cut of a run without a boundary
$cut = & $mod { Limit-TcRawText -Text ('Q' * 600) -Cap 300 }
Check 'Limit-TcRawText: a 600-char run with no boundary is dropped, not cut by count' ($cut -ceq '') $cut
$cut = & $mod { Limit-TcRawText -Text ('a,' + ('Q' * 600)) -Cap 300 }
Check 'Limit-TcRawText: backs off further than 200 characters to the last boundary' ($cut -ceq 'a') $cut
$cut = & $mod { Limit-TcRawText -Text ('ok words ' + ('Q' * 400) + ' tail') -Cap 300 }
Check 'Limit-TcRawText: boundary 390 characters back is found' ($cut -ceq 'ok words') $cut
$cut = & $mod { Limit-TcRawText -Text 'short text' -Cap 300 }
Check 'Limit-TcRawText: text within the cap is returned unchanged' ($cut -ceq 'short text') $cut
$tr = & $mod { Remove-TcTrailingToken -Text ('x ' + ('Q' * 500)) }
$tr2 = & $mod { Remove-TcTrailingToken -Text ('Q' * 500) }
$tr3 = & $mod { Remove-TcTrailingToken -Text 'a b cdef' }
Check 'Remove-TcTrailingToken: no 200-char limit; a single run is dropped; a normal token is removed' ($tr -ceq 'x' -and $tr2 -ceq '' -and $tr3 -ceq 'a b') ("$tr|$tr2|$tr3")
$rn = New-TcIssueReport -Title 't' -Notes ('Q' * 40000) -NoEnvironment
Check 'end to end: 40000-char run in Notes leaves no piece of the run' ($rn.success -and $rn.data.body -notmatch 'QQQQQQQQ') $rn.data.body.Length
$rl = New-TcIssueReport -Title 't' -Result ([pscustomobject]@{ success = $false; data = [pscustomobject]@{ s = ('Q' * 25000) } }) -NoEnvironment
Check 'end to end: 25000-char run in a result leaf leaves no piece of the run' ($rl.success -and $rl.data.body -notmatch 'QQQQQQQQ') $rl.data.body.Length

# ---- 5 V10.0.0.5, ver.10.0.0.5, MAC without separators
foreach ($t in 'firmware V10.0.0.5 failed', 'ver.10.0.0.5 failed', 'v192.168.1.50 up', 'V172.16.4.9', 'ver 10.1.2.3') {
    $o = Mask $t
    Check "private-range address after v / ver is masked: $t" ($o -notmatch '\d+\.\d+\.\d+\.\d+' -and $o -match '<ip>') $o
}
foreach ($t in 'v1.2.3.4', 'V3.1.4024.12', 'ver.1.2.3.4', 'ver 3.4.3.0', 'Version 10.0.0.5', 'version=3.4.3.0', 'Tc2_Standard.3.4.3.0', 'v8.8.8.8') {
    $o = Mask $t
    Check "version stays: $t" ($o -ceq $t) $o
}
foreach ($t in 'connect to server 192.168.1.20 failed', 'driver=10.0.0.5', 'dev 10.0.0.5', 'Observer 10.0.0.5') {
    $o = Mask $t
    Check "plain IPv4 still masked: $t" ($o -notmatch '\d+\.\d+\.\d+\.\d+' -and $o -match '<ip>') $o
}
$o = Mask 'MAC: 001122334455 hwaddr=665544332211 mac address 123456123456'
Check 'digit-only MAC after the word mac / hwaddr masked' ($o -notmatch '\d{12}' -and ([regex]::Matches($o, '<mac>')).Count -eq 3) $o
$o = Mask 'beckhoff nic 000105123456 up'
Check 'digit-only MAC with the Beckhoff prefix 00-01-05 masked' ($o -ceq 'beckhoff nic <mac> up') $o
$o = Mask 'built 202611051030 and id 123456123456 and 000106123456'
Check '12-digit numbers without mac context / Beckhoff prefix stay' ($o -ceq 'built 202611051030 and id 123456123456 and 000106123456') $o

# ---- review round 1 (#128)
# M1 folder names with a number / several camel-case parts
$o = Mask 'D:\Customers\Zebra2024\Main.sln FB_Zebra ST_ZebraRecipe Zebra2024 FB_Motor MAIN'
Check 'M1 folder Zebra2024: FB_Zebra / ST_ZebraRecipe masked, FB_Motor and MAIN stay' ($o -notmatch 'Zebra' -and $o -cmatch 'FB_Motor' -and $o -cmatch 'MAIN') $o
$o = Mask 'D:\x\AcmeCorp\Main.sln FB_AcmeMotor ST_CorpData FB_Pump'
Check 'M1/N2 folder AcmeCorp: first camel part Acme masked (the customer name is at the start), Corp / Motor / Data / Pump stay' ($o -notmatch 'Acme' -and $o -cmatch 'ST_CorpData' -and $o -cmatch 'Motor' -and $o -cmatch 'FB_Pump') $o
$o = Mask 'D:\x\ZebraFab\Main.sln ZebraFabLine ST_ZebraFab'
Check 'M1 folder ZebraFab: Zebra part masked in ZebraFabLine' ($o -notmatch 'Zebra') $o
# M5 generic / common folder names do not hide Beckhoff or PLC names
$o = Mask 'D:\Motor\Motion\EtherCATDevices\Visualization\Customers\Productionline\Main.sln FB_MotorControl Tc2_EtherCAT Visual Studio CustomAxis FB_ProductionData FB_Motor Motion'
Check 'M5 folders Motor / Motion / EtherCATDevices / Visualization / Customers / Productionline hide no part of a longer name' ($o -cmatch 'FB_MotorControl' -and $o -cmatch 'Tc2_EtherCAT' -and $o -cmatch 'Visual Studio' -and $o -cmatch 'CustomAxis' -and $o -cmatch 'FB_ProductionData') $o
# N1 a customer whose name is a common word is still masked as a whole word; longer names keep the word
$o = Mask 'D:\Customers\Motion\Line\Main.sln the Motion AG called; FB_MotionControl Tc2_MC2'
Check 'N1 folder Motion: "Motion AG" masked, FB_MotionControl kept' ($o -notmatch 'Motion AG' -and $o -cmatch 'FB_MotionControl' -and $o -cmatch 'the <redacted> AG') $o
foreach ($w in 'Speed', 'Master', 'Global', 'Ether', 'Custom', 'Simulation') {
    $o = Mask ("D:\x\$w\Main.sln by $w GmbH; FB_${w}Data")
    Check "N1 customer called $w is masked as a whole word, FB_${w}Data kept" ($o -notmatch "by $w" -and $o -cmatch ("FB_${w}Data")) $o
}
$o = Mask 'D:\x\Simulation\Main.sln FB_SimulAxis Simulation'
Check 'N1 folder Simulation: the word is masked, a beginning of a common word (FB_SimulAxis) stays' ($o -cmatch 'FB_SimulAxis <redacted>$') $o
# N2 camel parts of a folder name: only the first one, never a Beckhoff / IEC product word
$o = Mask 'D:\x\TwinCATProjects\Main.sln TwinCAT XAE TcUnit Twin'
Check 'N2 folder TwinCATProjects: TwinCAT / TcUnit kept' ($o -cmatch 'TwinCAT XAE TcUnit' ) $o
$o = Mask 'D:\x\UnitTests\Main.sln TcUnit Unit FB_UnitTest'
Check 'N2 folder UnitTests: TcUnit, Unit kept' ($o -cmatch 'TcUnit Unit FB_UnitTest') $o
$o = Mask 'D:\x\XAEShell\Main.sln XAE Shell VisualStudioShell'
Check 'N2 folder XAEShell: XAE / Shell parts kept' ($o -cmatch 'XAE Shell VisualStudioShell') $o
# N3 <name>_CX: variables with a common prefix stay
foreach ($t in 'Diag_CX5130', 'Axis_CX5130', 'Info_CX5130', 'Data_CX5130', 'Motor_CX5130') {
    $o = Mask $t
    Check "N3 counter: identifier stays: $t" ($o -ceq $t) $o
}
$o = Mask 'route Zebra_CX5130 down'
Check 'N3 Zebra_CX5130 still masked' ($o -notmatch 'Zebra' -and $o -match '<host>') $o
# N4 MACAddr / addr variants, key rule
$o = Mask 'MACAddr=001122334455 mac_addr: 112233445566 HW-Addr 223344556677 PhysicalAddr=334455667788 hwaddress 445566778899'
Check 'N4 MAC text variants (MACAddr, mac_addr, HW-Addr, PhysicalAddr, hwaddress)' ($o -notmatch '\d{12}') $o
$o = Mask 'macron 001122334455 and hwaddr_x 112233445566 and addr 223344556677'
Check 'N4 counter: macron, hwaddr_x, plain addr are no MAC context' ($o -ceq 'macron 001122334455 and hwaddr_x 112233445566 and addr 223344556677') $o
$cm = @{}
$vm = & $mod { param($c) ConvertTo-TcDeidentifiedValue -Value ([pscustomobject]@{ MACAddr = '001122334455'; mac_address = '1'; 'HW-Addr' = '2'; hwaddress = '3'; physical_address = '4'; machine = 'x'; macro = 'y'; MacAddressType = 'z' }) -Counts $c } $cm
Check 'N4 object keys MACAddr / mac_address / HW-Addr / hwaddress / physical_address -> <mac>; machine / macro / MacAddressType untouched' ($vm['MACAddr'] -ceq '<mac>' -and $vm['mac_address'] -ceq '<mac>' -and $vm['HW-Addr'] -ceq '<mac>' -and $vm['hwaddress'] -ceq '<mac>' -and $vm['physical_address'] -ceq '<mac>' -and $vm['machine'] -ceq 'x' -and $vm['macro'] -ceq 'y' -and $vm['MacAddressType'] -ceq 'z') ($vm | ConvertTo-Json -Compress)
# M2 digit-only MAC notations and the object key rule
$o = Mask 'macAddress=001122334455 mac-address: 112233445566 MAC-Adresse 223344556677 physicaladdress=334455667788 physical address 445566778899 hw-addr 556677889900'
Check 'M2 MAC notations: macAddress, mac-address, MAC-Adresse, physicaladdress, physical address, hw-addr' ($o -notmatch '\d{12}' -and ([regex]::Matches($o, '<mac>')).Count -eq 5) $o   # "mac-address: x" is taken first by the existing "address:" host-key rule (<host>), the value is masked either way
$o = Mask 'macro 001122334455 and timestamp=202611051030'
Check 'M2 counter: "macro" and "timestamp" are no MAC context' ($o -ceq 'macro 001122334455 and timestamp=202611051030') $o
$cm = @{}
$vm = & $mod { param($c) ConvertTo-TcDeidentifiedValue -Value ([pscustomobject]@{ MacAddress = '001122334455'; mac = 112233445566; hwaddr = 'x'; PhysicalAddress = '33-44'; timestamp = 202611051030; note = 'macro 1' }) -Counts $c } $cm
Check 'M2 object keys mac / macaddress / hwaddr / physicaladdress -> <mac>, other keys untouched' ($vm['MacAddress'] -ceq '<mac>' -and $vm['mac'] -ceq '<mac>' -and $vm['hwaddr'] -ceq '<mac>' -and $vm['PhysicalAddress'] -ceq '<mac>' -and $vm['timestamp'] -eq 202611051030 -and $vm['note'] -ceq 'macro 1') ($vm | ConvertTo-Json -Compress)
# M3 performance: versions cost nothing extra
$sw = [Diagnostics.Stopwatch]::StartNew()
$o = Mask ('v1.1.1.1 ' * 15000)
Check ("M3 15000 x 'v1.1.1.1': {0:n2}s < 2s, versions kept" -f $sw.Elapsed.TotalSeconds) ($sw.Elapsed.TotalSeconds -lt 2 -and $o.StartsWith('v1.1.1.1 v1.1.1.1')) ''
$o = Mask 'v10.0.0.0 and V172.16.0.9 and ver 169.254.1.1 and V172.32.0.1'
Check 'M3 private ranges after v: 10. 172.16-31. 169.254. masked (also .NET v10.0.0.0, known trade-off), 172.32 stays' ($o -ceq 'v<ip> and V<ip> and ver <ip> and V172.32.0.1') $o
# M4 CP / BK_IPC / BTN host names
foreach ($t in 'CX-1224A3', 'CP-1224A3', 'BK_IPC-1224A3', 'BTN-000fgyeg', 'host BTN-000FGYEG ok') {
    $o = Mask $t
    Check "M4 default host name masked: $t" ($o -notmatch '1224A3|000fgyeg' -and $o -match '<host>') $o
}
foreach ($t in 'CP-12', 'BTN-abc', 'BTN-000fgyeg12', 'CP-1224A3B', 'ATN-000fgyeg') {
    $o = Mask $t
    Check "M4 counter: not a host name: $t" ($o -ceq $t) $o
}
# m1 order codes, m2 more spellings
foreach ($t in 'CX2500-M310 power supply', 'EL1008-CX5130 cable', 'EtherCAT-CX5130 coupler', 'EK1100-CX2040') {
    $o = Mask $t
    Check "m1 order code / vendor name stays: $t" ($o -ceq $t) $o
}
foreach ($pair in @(@('route Zebra_CX01 down', 'Zebra'), @('route zebra-cx-01 down', 'zebra'))) {
    $o = Mask $pair[0]
    Check ("m2 renamed CX spelling: " + $pair[0]) ($o -notmatch $pair[1] -and $o -match '<host>') $o
}
foreach ($t in 'FB_CX5130Handler', 'Tc_CX01 name', 'a CX-01 model') {
    $o = Mask $t
    Check "m2 counter: stays: $t" ($o -ceq $t) $o
}
# m3 the dropped-input marker
$rd = New-TcIssueReport -Title 't' -Notes ('Q' * 40000) -NoEnvironment
Check 'm3 dropped input says so (no "cut at 10000")' ($rd.data.body -match 'input dropped: 40000 characters without a word boundary' -and $rd.data.body -notmatch 'cut at 10000') $rd.data.body
$rl2 = New-TcIssueReport -Title 't' -Result ([pscustomobject]@{ success = $false; data = [pscustomobject]@{ s = ('Q' * 25000) } }) -NoEnvironment
Check 'm3 dropped result leaf says so' ($rl2.data.body -match 'input dropped: 25000 characters') $rl2.data.body

# the whole report: new masks take part in New-TcIssueReport
$r = New-TcIssueReport -Title 'Zebrafab Line7' -Parameters @{ SolutionPath = 'D:\Customers\Zebrafab\Line7\Main.sln' } -Notes 'FB_Zebra failed on Zebra-CX01 (V10.0.0.5, mac 001122334455); MAIN ok' -NoEnvironment
Check 'report: customer prefix, renamed CX, V-address and digit MAC masked; MAIN kept' ($r.data.body -notmatch 'Zebra' -and $r.data.body -notmatch '10\.0\.0\.5' -and $r.data.body -notmatch '001122334455' -and $r.data.body -cmatch 'MAIN ok') $r.data.body

"failed: $fail"
exit $fail
