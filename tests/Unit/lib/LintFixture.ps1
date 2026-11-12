# Synthetic TwinCAT project for the semantic linter unit tests (#252). Dot-source it.
# Mock basis: the files copy the structure XAE wrote in the two corpus projects (4024 BFH-1650 and
# 4026 AxisInterface, research/tc-xml-schema-observed.md, observed 2026-11-13): Tc* object files are
# UTF-8 with BOM, encoding="utf-8" declaration, CRLF, 2-space XML indentation, no final line break,
# every Declaration / ST in exactly one CDATA section, lower-case {8-4-4-4-12} Ids; the .plcproj has
# no XML declaration and no BOM (as the 4024 project); .tsproj tab-indented with upper-case GUIDs;
# .sln with BOM and the PLC GUID only in ProjectConfigurationPlatforms. FB_A is written the 4024 way
# (with LineIds), MAIN the 4026 way (without). Property (Get / Set, accessor declaration 'PUBLIC VAR END_VAR',
# LineIds '<POU>.<Property>.Get') and the .TcIO interface follow the files XAE generated in the IDE measurement
# (openspec/changes/add-semantic-linter/verification/xae-generated-xml.md, 2026-11-13, PR #276). No customer file is copied.

$script:LintFx = @{
    PlcGuid   = '{3abfd75b-ae61-4bea-9f5b-12954f0b7f68}'
    TcGuid    = '{39E8A5AC-2B90-4A0D-8AE6-91AEDF7E9878}'
    MainId    = '{570194db-04ab-4683-94d1-7e94b2eca650}'
    FbAId     = '{360318b9-90c4-486d-94a4-c5a37bd5c3fe}'
    FbAAction = '{f6602788-7d81-42e7-84b1-7512231454c8}'
    FbAMethod = '{bca2ddc8-99fd-474f-8c18-1873e77b9b3b}'
    DutId     = '{05f871a7-4745-4b28-a4e6-ee5839391f61}'
    GvlId     = '{decf9160-6dac-4c1e-bb53-439b8e497a1a}'
    TaskId    = '{b6046488-bcbd-4405-8aeb-520da86402f5}'
    FbAProp   = '{722106dd-7639-49f1-8215-188851906d22}'
    FbAGet    = '{a497c097-793a-4804-aa80-6a57816cc79c}'
    FbASet    = '{334ad498-c5df-4f59-9c38-e012e9fadc49}'
    ItfId     = '{00f8759d-d414-4d8e-b74e-54afc04cd3e4}'
    ItfMethod = '{818a507c-faf2-4912-977d-398090ca1663}'
    ItfProp   = '{069e7f1a-531c-4a3e-aeee-de9e18034550}'
}

function ConvertTo-LintFxBytes([string]$Text, [bool]$Bom = $true, [string]$Eol = "`r`n") {
    $t = ($Text -replace "`r`n", "`n") -replace "`n", $Eol
    $enc = New-Object System.Text.UTF8Encoding($Bom)
    $pre = if ($Bom) { [byte[]](0xEF, 0xBB, 0xBF) } else { [byte[]]@() }
    return [byte[]]($pre + $enc.GetBytes($t))
}

function Write-LintFxFile([string]$Path, [string]$Text, [bool]$Bom = $true, [string]$Eol = "`r`n") {
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllBytes($Path, (ConvertTo-LintFxBytes $Text $Bom $Eol))
}

# Edit a fixture file as text, keeping its BOM state; the scriptblock gets and returns the text.
function Edit-LintFxFile([string]$Path, [scriptblock]$Change) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text = [System.Text.Encoding]::UTF8.GetString($bytes, $(if ($bom) { 3 } else { 0 }), $bytes.Length - $(if ($bom) { 3 } else { 0 }))
    $new = & $Change $text
    if ([string]::Equals($new, $text, [System.StringComparison]::Ordinal)) { throw "Edit-LintFxFile: the change did nothing in $Path" }
    $enc = New-Object System.Text.UTF8Encoding($false)
    $pre = if ($bom) { [byte[]](0xEF, 0xBB, 0xBF) } else { [byte[]]@() }
    [System.IO.File]::WriteAllBytes($Path, [byte[]]($pre + $enc.GetBytes($new)))
}

function Get-LintFxPou([string]$Name, [string]$Id, [string]$Decl, [string]$Impl, [string]$Extra = '', [string]$Pv = '3.1.4026.18') {
    return @"
<?xml version="1.0" encoding="utf-8"?>
<TcPlcObject Version="1.1.0.1" ProductVersion="$Pv">
  <POU Name="$Name" Id="$Id" SpecialFunc="None">
    <Declaration><![CDATA[$Decl]]></Declaration>
    <Implementation>
      <ST><![CDATA[$Impl]]></ST>
    </Implementation>$Extra
  </POU>
</TcPlcObject>
"@
}

function Get-LintFxMainText {
    $decl = "PROGRAM MAIN`nVAR`n    fbA : FB_A;`n    eMode : E_Mode;`n    sText : STRING(80) := 'it`$'s (* not a comment *)';`nEND_VAR`n"
    $impl = "fbA(bStart := GVL_Main.bRun);`nIF fbA.M_Do(nValue := 1) THEN`n    eMode := E_Mode.Auto; // set mode`nEND_IF"
    return (Get-LintFxPou -Name 'MAIN' -Id $script:LintFx.MainId -Decl $decl -Impl $impl)
}

function Get-LintFxFbAText {
    $decl = "FUNCTION_BLOCK FB_A`nVAR_INPUT`n    bStart : BOOL;`nEND_VAR`nVAR`n    tonDelay : TON;`n    nState : INT;`nEND_VAR`n"
    $impl = "(* main body *)`ntonDelay(IN := bStart, PT := T#2S);`nIF tonDelay.Q THEN`n    nState := 1;`nEND_IF"
    $extra = @"

    <Action Name="A_Reset" Id="$($script:LintFx.FbAAction)">
      <Implementation>
        <ST><![CDATA[nState := 0;]]></ST>
      </Implementation>
    </Action>
    <Method Name="M_Do" Id="$($script:LintFx.FbAMethod)">
      <Declaration><![CDATA[METHOD M_Do : BOOL
VAR_INPUT
    nValue : INT;
END_VAR
]]></Declaration>
      <Implementation>
        <ST><![CDATA[M_Do := nValue > 0;]]></ST>
      </Implementation>
    </Method>
    <Property Name="P_State" Id="$($script:LintFx.FbAProp)">
      <Declaration><![CDATA[PROPERTY PUBLIC P_State : INT]]></Declaration>
      <Get Name="Get" Id="$($script:LintFx.FbAGet)">
        <Declaration><![CDATA[PUBLIC
VAR
END_VAR]]></Declaration>
        <Implementation>
          <ST><![CDATA[P_State := nState;]]></ST>
        </Implementation>
      </Get>
      <Set Name="Set" Id="$($script:LintFx.FbASet)">
        <Declaration><![CDATA[PUBLIC
VAR
END_VAR]]></Declaration>
        <Implementation>
          <ST><![CDATA[nState := P_State;]]></ST>
        </Implementation>
      </Set>
    </Property>
    <LineIds Name="FB_A">
      <LineId Id="3" Count="3" />
      <LineId Id="2" Count="0" />
    </LineIds>
    <LineIds Name="FB_A.A_Reset">
      <LineId Id="1" Count="0" />
    </LineIds>
    <LineIds Name="FB_A.M_Do">
      <LineId Id="1" Count="0" />
    </LineIds>
    <LineIds Name="FB_A.P_State.Get">
      <LineId Id="2" Count="0" />
    </LineIds>
    <LineIds Name="FB_A.P_State.Set">
      <LineId Id="2" Count="0" />
    </LineIds>
"@
    return (Get-LintFxPou -Name 'FB_A' -Id $script:LintFx.FbAId -Decl $decl -Impl $impl -Extra $extra.TrimEnd() -Pv '3.1.4024.16')
}

# .TcIO as XAE 4026.22 wrote it (verification/fixtures-xae-generated/4026/I_LintItf.TcIO, measured 2026-11-13, PR #276):
# <Itf> without SpecialFunc, Method with Declaration only, Property with Declaration only
function Get-LintFxItfText {
    return @"
<?xml version="1.0" encoding="utf-8"?>
<TcPlcObject Version="1.1.0.1" ProductVersion="3.1.4026.18">
  <Itf Name="I_Run" Id="$($script:LintFx.ItfId)">
    <Declaration><![CDATA[INTERFACE I_Run
]]></Declaration>
    <Method Name="M_Run" Id="$($script:LintFx.ItfMethod)">
      <Declaration><![CDATA[METHOD M_Run : BOOL
VAR_INPUT
END_VAR]]></Declaration>
    </Method>
    <Property Name="P_Ok" Id="$($script:LintFx.ItfProp)">
      <Declaration><![CDATA[PROPERTY P_Ok : BOOL]]></Declaration>
    </Property>
  </Itf>
</TcPlcObject>
"@
}

function Get-LintFxDutText {
    return @"
<?xml version="1.0" encoding="utf-8"?>
<TcPlcObject Version="1.1.0.1" ProductVersion="3.1.4024.16">
  <DUT Name="E_Mode" Id="$($script:LintFx.DutId)">
    <Declaration><![CDATA[{attribute 'qualified_only'}
{attribute 'strict'}
TYPE E_Mode :
(
    Manual := 0,
    Auto
) INT;
END_TYPE
]]></Declaration>
  </DUT>
</TcPlcObject>
"@
}

function Get-LintFxGvlText {
    return @"
<?xml version="1.0" encoding="utf-8"?>
<TcPlcObject Version="1.1.0.1" ProductVersion="3.1.4026.18">
  <GVL Name="GVL_Main" Id="$($script:LintFx.GvlId)">
    <Declaration><![CDATA[{attribute 'qualified_only'}
VAR_GLOBAL
    bRun : BOOL; // started by HMI
END_VAR]]></Declaration>
  </GVL>
</TcPlcObject>
"@
}

function Get-LintFxTaskText([string]$PouCall = 'MAIN', [string]$Priority = '20') {
    return @"
<?xml version="1.0" encoding="utf-8"?>
<TcPlcObject Version="1.1.0.1" ProductVersion="3.1.4026.18">
  <Task Name="PlcTask" Id="$($script:LintFx.TaskId)">
    <!--CycleTime in micro seconds.-->
    <CycleTime>10000</CycleTime>
    <Priority>$Priority</Priority>
    <PouCall>
      <Name>$PouCall</Name>
    </PouCall>
    <TaskFBGuid>{39e8a5ac-2b90-4a0d-8ae6-91aedf7e9878}</TaskFBGuid>
    <Fb_init>{86e3ee12-7718-4353-a294-07418636959d}</Fb_init>
    <Fb_exit>{88955385-48ba-4cf1-845d-9d37ae93d094}</Fb_exit>
    <CycleUpdate>{c123d701-d654-4a61-9196-5102edd6a54b}</CycleUpdate>
    <PostCycleUpdate>{80ad6352-f4f0-4104-a0e1-1cd8d2cd6038}</PostCycleUpdate>
  </Task>
</TcPlcObject>
"@
}

function Get-LintFxPlcprojText([string[]]$CompileItems, [string]$Guid = $script:LintFx.PlcGuid) {
    $items = ($CompileItems | ForEach-Object {
            $extra = if ($_ -like '*.TcGVL') { "`n      <LinkAlways>true</LinkAlways>" } else { '' }
            "    <Compile Include=`"$_`">`n      <SubType>Code</SubType>$extra`n    </Compile>"
        }) -join "`n"
    return @"
<Project DefaultTargets="Build" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <PropertyGroup>
    <FileVersion>1.0.0.0</FileVersion>
    <SchemaVersion>2.0</SchemaVersion>
    <ProjectGuid>$Guid</ProjectGuid>
    <SubObjectsSortedByName>True</SubObjectsSortedByName>
    <Name>PLC1</Name>
    <ProgramVersion>3.1.4026.22</ProgramVersion>
  </PropertyGroup>
  <ItemGroup>
$items
  </ItemGroup>
  <ItemGroup>
    <Folder Include="DUTs" />
    <Folder Include="GVLs" />
    <Folder Include="POUs" />
  </ItemGroup>
  <ItemGroup>
    <PlaceholderReference Include="Tc2_Standard">
      <DefaultResolution>Tc2_Standard, * (Beckhoff Automation GmbH)</DefaultResolution>
      <Namespace>Tc2_Standard</Namespace>
    </PlaceholderReference>
  </ItemGroup>
  <ItemGroup>
    <None Include="PLC1.tmc">
      <SubType>Content</SubType>
    </None>
  </ItemGroup>
  <ProjectExtensions>
    <PlcProjectOptions>
      <XmlArchive>
        <Data>
          <o xml:space="preserve" t="OptionKey">
            <v n="Name">"&lt;ProjectRoot&gt;"</v>
          </o>
        </Data>
        <TypeList>
          <Type n="String">System.String</Type>
        </TypeList>
      </XmlArchive>
    </PlcProjectOptions>
  </ProjectExtensions>
</Project>
"@
}

function Get-LintFxTsprojText([string]$PrjFilePath = 'PLC1\PLC1.plcproj', [string]$Guid = $script:LintFx.PlcGuid.ToUpperInvariant(), [string]$ContextName = 'PlcTask') {
    return @"
<?xml version="1.0"?>
<TcSmProject xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://www.beckhoff.com/schemas/2012/07/TcSmProject" TcSmVersion="1.0" TcVersion="3.1.4024.71">
	<Project ProjectGUID="$($script:LintFx.TcGuid)" ShowHideConfigurations="#x6">
		<System>
			<Tasks>
				<Task Id="3" Priority="20" CycleTime="100000" AmsPort="350" AdtTasks="true">
					<Name>PlcTask</Name>
				</Task>
			</Tasks>
		</System>
		<Plc>
			<Project GUID="$Guid" Name="PLC1" PrjFilePath="$PrjFilePath" TmcFilePath="PLC1\PLC1.tmc" ReloadTmc="true" AmsPort="851" FileArchiveSettings="#x000e" CopyTmcToTarget="true">
				<Instance Id="#x08502000" TcSmClass="TComPlcObjDef" KeepUnrestoredLinks="2" TmcPath="PLC1\PLC1.tmc">
					<Name>PLC1 Instance</Name>
					<CLSID ClassFactory="TcPlc30">{08500001-0000-0000-F000-000000000064}</CLSID>
					<Contexts>
						<Context>
							<Id>0</Id>
							<Name>$ContextName</Name>
							<ManualConfig>
								<OTCID>#x02010030</OTCID>
							</ManualConfig>
							<Priority>20</Priority>
							<CycleTime>10000000</CycleTime>
						</Context>
					</Contexts>
					<TaskPouOids>
						<TaskPouOid Prio="20" OTCID="#x08502001"/>
					</TaskPouOids>
				</Instance>
			</Project>
		</Plc>
	</Project>
</TcSmProject>
"@
}

function Get-LintFxSlnText([string]$PlcGuid = $script:LintFx.PlcGuid.ToUpperInvariant()) {
    $tc = $script:LintFx.TcGuid
    return "`nMicrosoft Visual Studio Solution File, Format Version 12.00`n# Visual Studio Version 17`nVisualStudioVersion = 17.14.36930.0`nMinimumVisualStudioVersion = 10.0.40219.1`n" +
    "Project(`"{B1E792BE-AA5F-4E3C-8C82-674BF9C0715B}`") = `"Sol`", `"Sol\Sol.tsproj`", `"$tc`"`nEndProject`nGlobal`n" +
    "`tGlobalSection(SolutionConfigurationPlatforms) = preSolution`n`t`tRelease|TwinCAT RT (x64) = Release|TwinCAT RT (x64)`n`tEndGlobalSection`n" +
    "`tGlobalSection(ProjectConfigurationPlatforms) = postSolution`n`t`t$tc.Release|TwinCAT RT (x64).ActiveCfg = Release|TwinCAT RT (x64)`n" +
    "`t`t$PlcGuid.Release|TwinCAT RT (x64).ActiveCfg = Release|TwinCAT RT (x64)`n`t`t$PlcGuid.Release|TwinCAT RT (x64).Build.0 = Release|TwinCAT RT (x64)`n" +
    "`tEndGlobalSection`nEndGlobal`n"
}

$script:LintFxCompile = @('DUTs\E_Mode.TcDUT', 'GVLs\GVL_Main.TcGVL', 'PlcTask.TcTTO', 'POUs\FB_A.TcPOU', 'POUs\I_Run.TcIO', 'POUs\MAIN.TcPOU')

# Writes a complete pristine solution below $Root. Returns the paths.
function New-LintFixture([string]$Root, [switch]$ReverseWriteOrder) {
    $sol = Join-Path $Root 'Sol'
    $tsDir = Join-Path $sol 'Sol'
    $plcDir = Join-Path $tsDir 'PLC1'
    $fx = [ordered]@{
        Root = $Root; Sln = (Join-Path $sol 'Sol.sln'); Tsproj = (Join-Path $tsDir 'Sol.tsproj'); Plcproj = (Join-Path $plcDir 'PLC1.plcproj'); PlcDir = $plcDir
        Main = (Join-Path $plcDir 'POUs\MAIN.TcPOU'); FbA = (Join-Path $plcDir 'POUs\FB_A.TcPOU'); Dut = (Join-Path $plcDir 'DUTs\E_Mode.TcDUT')
        Gvl = (Join-Path $plcDir 'GVLs\GVL_Main.TcGVL'); Task = (Join-Path $plcDir 'PlcTask.TcTTO'); Itf = (Join-Path $plcDir 'POUs\I_Run.TcIO')
    }
    $writes = @(
        { Write-LintFxFile $fx.Sln (Get-LintFxSlnText) $true },
        { Write-LintFxFile $fx.Tsproj (Get-LintFxTsprojText) $false },
        { Write-LintFxFile $fx.Plcproj (Get-LintFxPlcprojText $script:LintFxCompile) $false },
        { Write-LintFxFile $fx.Main (Get-LintFxMainText) },
        { Write-LintFxFile $fx.FbA (Get-LintFxFbAText) },
        { Write-LintFxFile $fx.Dut (Get-LintFxDutText) },
        { Write-LintFxFile $fx.Gvl (Get-LintFxGvlText) },
        { Write-LintFxFile $fx.Task (Get-LintFxTaskText) },
        { Write-LintFxFile $fx.Itf (Get-LintFxItfText) })
    if ($ReverseWriteOrder) { [array]::Reverse($writes) }
    foreach ($w in $writes) { & $w }
    return $fx
}

function Set-LintFxCompile($Fx, [string[]]$Items) {
    Write-LintFxFile $Fx.Plcproj (Get-LintFxPlcprojText $Items) $false
}
