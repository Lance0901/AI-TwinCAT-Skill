# Throwaway: copy the bfh corpus and plant known bugs. Each seed must apply exactly once. NOT product code.
param([string]$Src = 'C:\Temp\lint-corpus\bfh', [string]$Dst = 'C:\Temp\lint-corpus-seeded\bfh')
$ErrorActionPreference = 'Stop'
if (Test-Path $Dst) { Remove-Item $Dst -Recurse -Force }
Copy-Item $Src $Dst -Recurse
$P = Join-Path $Dst 'LangMang260618\PLC1'
$utf8 = New-Object System.Text.UTF8Encoding($true)
function Edit-Seed([string]$Id, [string]$Rel, [string]$Old, [string]$New) {
    $f = Join-Path $P $Rel
    $s = [IO.File]::ReadAllText($f)
    $n = ([regex]::Matches($s, [regex]::Escape($Old))).Count
    if ($n -ne 1) { throw "$Id : expected 1 match in $Rel, got $n" }
    [IO.File]::WriteAllText($f, $s.Replace($Old, $New), $utf8)
    "$Id applied: $Rel"
}
$proj = 'PLC1.plcproj'
# S01 orphan: Compile entry removed, file stays on disk
Edit-Seed S01 $proj '<Compile Include="30_RollToRoll\Fb\RollToRoll\FB_LevelControl.TcPOU">' '<None Include="30_RollToRoll\Fb\RollToRoll\FB_LevelControl.TcPOU">'
$s = [IO.File]::ReadAllText((Join-Path $P $proj)); $i = $s.IndexOf('<None Include="30_RollToRoll\Fb\RollToRoll\FB_LevelControl.TcPOU">'); $j = $s.IndexOf('</Compile>', $i)
$s = $s.Substring(0, $j) + '</None>' + $s.Substring($j + 10); [IO.File]::WriteAllText((Join-Path $P $proj), $s, $utf8)
# S02 Compile entry pointing to a missing file; S03 duplicate Compile entry
Edit-Seed S02+S03 $proj '<Compile Include="00_Machine\01_DUTs\E_OpMode.TcDUT">' ('<Compile Include="POUs\FB_Ghost.TcPOU"><SubType>Code</SubType></Compile>' + "`r`n    " + '<Compile Include="00_Machine\01_DUTs\IO\ST_EL1889.TcDUT"><SubType>Code</SubType></Compile>' + "`r`n    " + '<Compile Include="00_Machine\01_DUTs\E_OpMode.TcDUT">')
# S04 duplicate object GUID
Edit-Seed S04 '30_RollToRoll\Fb\RollToRoll\FB_Winder.TcPOU' 'Id="{37907d40-70f4-48b0-a1ab-75e5a875e712}"' 'Id="{5182006f-83a3-4698-894e-82baca23252e}"'
# S05 object kind / extension mismatch: a POU stored in a .TcDUT file
Copy-Item (Join-Path $P '30_RollToRoll\Fb\RollToRoll\FB_BrakeControl.TcPOU') (Join-Path $P '00_Machine\01_DUTs\FB_Wrong.TcDUT')
Edit-Seed S05a '00_Machine\01_DUTs\FB_Wrong.TcDUT' 'Id="{5182006f-83a3-4698-894e-82baca23252e}"' 'Id="{aaaaaaaa-0000-0000-0000-000000000005}"'
Edit-Seed S05b '00_Machine\01_DUTs\FB_Wrong.TcDUT' 'FUNCTION_BLOCK FB_BrakeControl' 'FUNCTION_BLOCK FB_Wrong'
Edit-Seed S05c '00_Machine\01_DUTs\FB_Wrong.TcDUT' 'POU Name="FB_BrakeControl"' 'POU Name="FB_Wrong"'
Edit-Seed S05d $proj '<Compile Include="00_Machine\01_DUTs\E_OpMode.TcDUT">' ('<Compile Include="00_Machine\01_DUTs\FB_Wrong.TcDUT"><SubType>Code</SubType></Compile>' + "`r`n    " + '<Compile Include="00_Machine\01_DUTs\E_OpMode.TcDUT">')
# S06 TON only called inside IF (no ELSE)
Edit-Seed S06 '30_RollToRoll\Fb\RollToRoll\FB_R2RLineControl.TcPOU' 'tonWebBreak(IN := (state = 3)' 'IF state = 3 THEN tonWebBreak(IN := (state = 3)'
Edit-Seed S06b '30_RollToRoll\Fb\RollToRoll\FB_R2RLineControl.TcPOU' 'PT := T#500MS);' 'PT := T#500MS); END_IF'
# S07 R_TRIG only called inside a CASE branch
Edit-Seed S07 '30_RollToRoll\Fb\RollToRoll\FB_LoadcellCalibration.TcPOU' 'rZero(CLK := captureZero);' 'CASE BOOL_TO_INT(atStandstill) OF 1: rZero(CLK := captureZero); END_CASE'
# S08 FB instance read (.Q/.ET) but its call removed
Edit-Seed S08 'POUs\RollToRoll_Type01.TcPOU' 'tonAutoStart(IN := bAutoStart AND (NOT bAutoStartInhibit) AND (NOT bStopPriority), PT := T#3S);' '// call removed by seed S08'
# S09 FB instance declared, never referenced
Edit-Seed S09 '30_RollToRoll\Fb\RollToRoll\FB_BrakeControl.TcPOU' 'FUNCTION_BLOCK FB_BrakeControl' "FUNCTION_BLOCK FB_BrakeControl IMPLEMENTS I_Brake`r`nVAR`r`n    tonUnusedSeed : TON;`r`nEND_VAR"
# S10 interface method signature mismatch; S11 interface method not implemented
$itf = @'
<?xml version="1.0" encoding="utf-8"?>
<TcPlcObject Version="1.1.0.1" ProductVersion="3.1.4024.62">
  <Itf Name="I_Brake" Id="{aaaaaaaa-0000-0000-0000-000000000010}">
    <Declaration><![CDATA[INTERFACE I_Brake
]]></Declaration>
    <Method Name="M_Release" Id="{aaaaaaaa-0000-0000-0000-000000000011}">
      <Declaration><![CDATA[METHOD M_Release : BOOL
VAR_INPUT
    bForce : BOOL;
END_VAR
]]></Declaration>
    </Method>
    <Method Name="M_Apply" Id="{aaaaaaaa-0000-0000-0000-000000000012}">
      <Declaration><![CDATA[METHOD M_Apply : BOOL
]]></Declaration>
    </Method>
  </Itf>
</TcPlcObject>
'@
[IO.File]::WriteAllText((Join-Path $P 'POUs\I_Brake.TcIO'), $itf, $utf8)
Edit-Seed S10a $proj '<Compile Include="00_Machine\01_DUTs\E_OpMode.TcDUT">' ('<Compile Include="POUs\I_Brake.TcIO"><SubType>Code</SubType></Compile>' + "`r`n    " + '<Compile Include="00_Machine\01_DUTs\E_OpMode.TcDUT">')
Edit-Seed S10b '30_RollToRoll\Fb\RollToRoll\FB_BrakeControl.TcPOU' "    </Implementation>`r`n" ("    </Implementation>`r`n" + '    <Method Name="M_Release" Id="{aaaaaaaa-0000-0000-0000-000000000013}"><Declaration><![CDATA[METHOD M_Release : BOOL' + "`r`n" + 'VAR_INPUT' + "`r`n" + '    nForce : INT;' + "`r`n" + 'END_VAR' + "`r`n" + ']]></Declaration><Implementation><ST><![CDATA[M_Release := TRUE;]]></ST></Implementation></Method>' + "`r`n")
# S12 enum numeric value changed vs baseline
Edit-Seed S12 '00_Machine\01_DUTs\E_MachineMode.TcDUT' 'Manual := 0,' 'Manual := 1,'
# S13 public struct field order changed vs baseline
Edit-Seed S13 '00_Machine\01_DUTs\IO\ST_EL1889.TcDUT' "DI1  AT %I* :BIT;`r`n        DI2  AT %I* :BIT;" "DI2  AT %I* :BIT;`r`n        DI1  AT %I* :BIT;"
# S14 missing END_IF (parser must fail closed for this object)
Edit-Seed S14 '30_RollToRoll\Fb\RollToRoll\FB_ThicknessAverage.TcPOU' "IF idx > k THEN idx := 1; END_IF" "IF idx > k THEN idx := 1;"
# S15 unterminated block comment in a declaration
Edit-Seed S15 '30_RollToRoll\Fb\RollToRoll\FB_Winder.TcPOU' 'fbDiam      : FB_DiameterCalculation;' 'fbDiam      : FB_DiameterCalculation; (* unterminated seed S15'
# Expected misses (out of prototype scope; TE1200 / compiler / future flow analysis):
# S16 division by literal zero
Edit-Seed S16 '30_RollToRoll\Fb\RollToRoll\FB_ThicknessAverage.TcPOU' 'k := LIMIT(1, k, 50);' 'k := LIMIT(1, k, 50); k := k / 0;'
# S17 constant out-of-range array index (buf is ARRAY[1..50])
Edit-Seed S17 '30_RollToRoll\Fb\RollToRoll\FB_ThicknessAverage.TcPOU' 'buf[idx] := thickness;' 'buf[idx] := thickness; buf[51] := 0.0;'
# S18 TON whose IN is constant TRUE (never re-arms)
Edit-Seed S18 'POUs\RollToRoll_Type01.TcPOU' 'tonWebBreak(IN := running AND' 'tonWebBreak(IN := TRUE OR running AND'
'seeding done'
