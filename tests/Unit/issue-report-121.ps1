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

# the whole report: new masks take part in New-TcIssueReport
$r = New-TcIssueReport -Title 'Zebrafab Line7' -Parameters @{ SolutionPath = 'D:\Customers\Zebrafab\Line7\Main.sln' } -Notes 'FB_Zebra failed on Zebra-CX01 (V10.0.0.5, mac 001122334455); MAIN ok' -NoEnvironment
Check 'report: customer prefix, renamed CX, V-address and digit MAC masked; MAIN kept' ($r.data.body -notmatch 'Zebra' -and $r.data.body -notmatch '10\.0\.0\.5' -and $r.data.body -notmatch '001122334455' -and $r.data.body -cmatch 'MAIN ok') $r.data.body

"failed: $fail"
exit $fail
