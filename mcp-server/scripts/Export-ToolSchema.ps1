<#
.SYNOPSIS
    Generates mcp-server/tools.json (MCP tool definitions) from the TwinCATAutomation module.

.DESCRIPTION
    For every exported cmdlet of the module this script
      * takes the MCP tool name from the $operationMap of Invoke-TwinCATAutomation.ps1
        (CLI action name -> cmdlet), falling back to "<Verb><Noun without Tc>",
      * builds a JSON schema from the cmdlet's parameters (types, ValidateSet,
        ValidateRange, literal default values, Mandatory -> required),
      * takes descriptions from comment-based help, overridden by $descriptionOverrides
        for the tools where the help alone is not enough,
      * assigns a per-tool timeout (ms) used by the Node side.

    Run it again whenever a cmdlet signature changes:
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/Export-ToolSchema.ps1

.PARAMETER ModulePath
    TwinCATAutomation.psm1. Default: ../../src/TwinCATAutomation/TwinCATAutomation.psm1.
.PARAMETER CliPath
    Invoke-TwinCATAutomation.ps1 (source of $operationMap). Default: ../../Invoke-TwinCATAutomation.ps1.
.PARAMETER OutPath
    Output file. Default: ../tools.json.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$ModulePath,

    [Parameter()]
    [string]$CliPath,

    [Parameter()]
    [string]$OutPath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# $PSScriptRoot is not populated while parameter defaults are evaluated in PS 5.1.
$scriptDir = Split-Path -Parent $PSCommandPath
if ([string]::IsNullOrWhiteSpace($ModulePath)) { $ModulePath = Join-Path $scriptDir '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1' }
if ([string]::IsNullOrWhiteSpace($CliPath)) { $CliPath = Join-Path $scriptDir '..\..\Invoke-TwinCATAutomation.ps1' }
if ([string]::IsNullOrWhiteSpace($OutPath)) { $OutPath = Join-Path $scriptDir '..\tools.json' }

$ModulePath = (Resolve-Path -LiteralPath $ModulePath).ProviderPath
$CliPath = (Resolve-Path -LiteralPath $CliPath).ProviderPath
if (-not [System.IO.Path]::IsPathRooted($OutPath)) {
    $OutPath = Join-Path (Get-Location).ProviderPath $OutPath
}
$OutPath = [System.IO.Path]::GetFullPath($OutPath)

# ---------------------------------------------------------------------------
# Hand-written tool descriptions (what an MCP client needs to know that the
# comment-based help does not say). Keys = tool names.
# ---------------------------------------------------------------------------
$descriptionOverrides = @{
    'ConnectIde'      = 'Connect to a running TwinCAT XAE / Visual Studio instance (found through the Running Object Table); only if none is found does it launch a new XAE. SolutionPath is optional and opens that .sln after connecting. Call this before any project, build or runtime tool. Returns ideProcessId and, when a solution is open, the detected target AmsNetId.'
    'DisconnectIde'   = 'Release the DTE/COM references held by the bridge. The IDE keeps running unless Quit=true, which closes the solution without saving and quits the IDE (only use on an IDE that ConnectIde launched).'
    'GetIdeInfo'      = 'Return version, edition, open solution and ITcSysManager availability of the connected IDE. Cheap connectivity check; fails with NOT_CONNECTED before ConnectIde.'
    'BuildProject'    = 'Build the PLC project of the open solution and wait for the result. On BUILD_FAILED read data.errorItems (description/file/line taken from the XAE Error List) instead of guessing; a full build can take several minutes (timeout 600 s). Requires ConnectIde with an open solution.'
    'GetBuildErrors'  = 'Read the compiler messages currently shown in the XAE Error List (errors by default; IncludeWarnings/IncludeMessages add the rest). Needs an English XAE UI (window "Error List", button "N Errors"); other UI languages return ERRORLIST_UNAVAILABLE.'
    'EnableConfig'    = 'Activate the configuration on the target without any dialog. Restarts TwinCAT and downloads/starts the PLC program: the machine stops and restarts. Confirm with the user first. With Force=true it runs the whole lifecycle: Config -> Activate -> wait for Run -> PLC Login+Download -> wait for port 851 -> PLC Run, and reports every step in data.steps. NoLogin=true stops after TwinCAT is in Run (no download, no PLC Run). TwinCAT restarts, so call ConnectAds again afterwards (ReadVariable/WriteVariable also auto-reconnect; data.reconnected tells you). Never add sleeps around this call; it polls until the target state is reached.'
    'ConnectAds'      = 'Open the ADS connection to the PLC runtime. Leave AmsNetId empty: it is auto-detected from the IDE target and changes per target (local UmRT, remote CX ...), so never hardcode it. Port defaults to 851 (PLC runtime 1). Requires ConnectIde for auto-detection.'
    'DisconnectAds'   = 'Close the ADS connection and forget the cached endpoint (disables auto-reconnect).'
    'ReadVariable'    = 'Read one or more PLC variables by symbol path (e.g. ["MAIN.nCounter","GVL.bRun"]) via ADS. Path is always an array, even for a single variable. Values are typed by the PLC type (BOOL/INT/REAL/STRING ...; structs come back as byte arrays). Requires ConnectAds (auto-reconnects after EnableConfig).'
    'WriteVariable'   = 'Write a single PLC variable by symbol path via ADS. Writes directly into the running PLC; may drive outputs or axes. Confirm with the user first. Value is converted to the PLC type of the symbol (send JSON bool for BOOL, number for numeric types, string for STRING). Requires ConnectAds.'
    'WatchVariable'   = 'Poll one PLC variable every IntervalMs for DurationMs and return the samples. The condition-based mode (Until) is a PowerShell scriptblock and is NOT available through MCP; use repeated ReadVariable calls instead. Requires ConnectAds.'
    'GetSymbols'      = 'List the PLC symbols of the connected runtime, optionally filtered by a substring (Filter). Use it to find exact variable paths before ReadVariable/WriteVariable.'
    'GetPlcState'     = 'Read the PLC runtime state (Run/Stop/...) on the connected ADS port.'
    'SetPlcState'     = 'Switch the PLC runtime to Run, Stop or Reset and wait for the state. WARNING: on a UmRT (user-mode runtime) target, Reset kills TcSystemServiceUm and you must EnableConfig again. Prefer Run/Stop.'
    'PlcLogin'        = 'Login to the PLC project and download the program in one call (Login flag 3, no dialogs). Use after a successful BuildProject when TwinCAT is already in Run; EnableConfig Force=true already includes this step.'
    'PlcLogout'       = 'Log out of the PLC project (the runtime keeps running).'
    'GetSystemState'  = 'Read the TwinCAT system state (Run/Config) of a target over ADS port 10000. AmsNetId defaults to 127.0.0.1.1.1 (the local system), which is NOT necessarily your target; pass the AmsNetId reported by ConnectIde/ConnectAds for a remote or UmRT target.'
    'SetSystemState'  = 'Switch TwinCAT to Run or Config via ADS WriteControl (no StartRestartTwinCAT dialog) and poll until the state is reached. Switching to Config stops the runtime: all outputs go to zero. Does not download the PLC program; EnableConfig Force=true is the usual choice.'
    'SendPlcProgram'  = 'Download the compiled PLC program to the target (alias of PlcLogin: Login+Download without dialogs).'
    'RunTestCycle'    = 'Builds, activates (TwinCAT restart) and runs the PLC: changes the running machine. Confirm with the user first. Full automated test cycle: build (unless SkipBuild), activate configuration, login, run every test case from NewTestCase, then stop the PLC (unless KeepRunning). Returns per-test results. Can take many minutes (timeout 900 s).'
    'RunTest'         = 'Execute one test case created with NewTestCase (setup writes -> wait -> assertions -> teardown writes) against the connected PLC. Requires ConnectAds.'
    'NewTestCase'     = 'Build a test case object for RunTest/RunTestCycle. Setup/Teardown are arrays of {Path, Value} writes; Assertions are {Path, Operator, Expected} with Operator one of Equal (default), NotEqual, GreaterThan, LessThan, GreaterThanOrEqual, LessThanOrEqual, Contains, IsTrue, IsFalse. Pure data, no IDE/PLC access.'
    'OpenProject'     = 'Open a solution (.sln) in the connected IDE and wait until the TwinCAT project is loaded.'
    'IoScan'          = 'Scan the I/O devices (EtherCAT ...) of the target and add them to the I/O tree. Requires the target in Config mode.'
}

# Per-tool timeouts in ms (Node side kills and restarts the bridge when exceeded).
$defaultTimeoutMs = 120000
$timeoutOverrides = @{
    'BuildProject'   = 600000
    'EnableConfig'   = 600000
    'RunTestCycle'   = 900000
    'ConnectIde'     = 180000
    'OpenProject'    = 180000
    'PlcLogin'       = 300000
    'SendPlcProgram' = 300000
    'SetSystemState' = 180000
    'SetPlcState'    = 180000
    'IoScan'         = 180000
}

# MCP tool annotations (https://modelcontextprotocol.io: ToolAnnotations).
# readOnlyHint: no side effects on IDE/project/runtime.
# destructiveHint: changes the running machine / runtime / connection state in a way
# that cannot simply be undone. Everything else (project edits, connecting) is
# readOnlyHint=false, destructiveHint=false.
$readOnlyTools = @(
    'GetIdeInfo', 'GetProjectTree', 'GetPouCode', 'GetIoTree', 'GetBuildErrors', 'GetSymbols',
    'GetPlcState', 'GetSystemState', 'ReadVariable', 'WatchVariable', 'NewTestCase'
)
$destructiveTools = @(
    'EnableConfig', 'SetSystemState', 'SetPlcState', 'WriteVariable', 'RunTest', 'RunTestCycle',
    'PlcLogin', 'SendPlcProgram', 'IoScan', 'SetTarget', 'DisconnectIde', 'PlcLogout'
)

function Get-ToolAnnotations {
    param([string]$ToolName)
    if ($readOnlyTools -contains $ToolName) { return [ordered]@{ readOnlyHint = $true } }
    if ($destructiveTools -contains $ToolName) { return [ordered]@{ readOnlyHint = $false; destructiveHint = $true } }
    return [ordered]@{ readOnlyHint = $false; destructiveHint = $false }
}

# Parameter description overrides: "<ToolName>.<ParamName>" = text.
$paramDescriptionOverrides = @{
    'ReadVariable.Path'       = 'Array of PLC symbol paths, e.g. ["MAIN.nCounter"]. Always an array, also for a single variable.'
    'WriteVariable.Value'     = 'New value; JSON bool, number or string matching the PLC type of the symbol.'
    'ConnectAds.AmsNetId'     = 'Target AmsNetId. Leave empty to auto-detect from the IDE target (recommended; it differs per target).'
    'GetSystemState.AmsNetId' = 'Target AmsNetId. Default 127.0.0.1.1.1 is the local TwinCAT system, which may not be your target.'
    'SetPlcState.State'       = 'Run, Stop or Reset. Reset kills TcSystemServiceUm on a UmRT target.'
    'EnableConfig.Force'      = 'true = full lifecycle without dialogs (Config -> Activate -> Run -> Login/Download -> PLC Run).'
    'EnableConfig.NoLogin'    = 'true = stop after TwinCAT reaches Run; skip PLC login/download/Run.'
    'NewTestCase.Setup'       = 'Writes before the test: array of {"Path":"MAIN.x","Value":1} (keys Path = PLC symbol path, Value = value to write, converted to the PLC type).'
    'NewTestCase.Teardown'    = 'Writes after the test (also run when the test fails): array of {"Path":"MAIN.x","Value":0} (keys Path, Value).'
    'NewTestCase.Assertions'  = 'Checks after WaitMs: array of {"Path":"MAIN.y","Operator":"Equal","Expected":1}. Keys: Path (PLC symbol path), Operator (optional, default Equal; one of Equal, NotEqual, GreaterThan, LessThan, GreaterThanOrEqual, LessThanOrEqual, Contains, IsTrue, IsFalse), Expected (omit for IsTrue/IsFalse). Short forms like "eq"/"gt" are NOT accepted.'
    'AddDut.Fields'           = 'Optional object of field declarations (name = type) for Struct/Union (name = value for Enum). Declaration order is not guaranteed (PowerShell hashtable).'
    'AddGvl.Variables'        = 'Optional object of variable declarations (name = type). Declaration order is not guaranteed (PowerShell hashtable).'
    'RunTest.TestCase'        = 'A test case object as returned by NewTestCase.'
    'RunTestCycle.TestCases'  = 'Array of test case objects as returned by NewTestCase.'
    'DisconnectIde.Quit'      = 'true = also close the solution (without saving) and quit the IDE.'
}

$commonParameters = @(
    'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction',
    'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable',
    'OutBuffer', 'PipelineVariable', 'WhatIf', 'Confirm', 'ProgressAction'
)

# ---------------------------------------------------------------------------
# Load module and CLI operation map
# ---------------------------------------------------------------------------
$module = Import-Module -Name $ModulePath -Force -PassThru -DisableNameChecking 3>$null 4>$null
$moduleVersion = [string]$module.Version
$psd1 = [System.IO.Path]::ChangeExtension($ModulePath, '.psd1')
if (Test-Path -LiteralPath $psd1) {
    try {
        $manifest = Import-PowerShellDataFile -LiteralPath $psd1
        if ($manifest.ModuleVersion) { $moduleVersion = [string]$manifest.ModuleVersion }
    }
    catch { Write-Warning "Could not read ModuleVersion from $psd1 : $($_.Exception.Message)" }
}

$cliText = [System.IO.File]::ReadAllText($CliPath)
$mapMatch = [regex]::Match($cliText, '\$operationMap\s*=\s*@\{(?<body>.*?)\n\}', 'Singleline')
if (-not $mapMatch.Success) { throw "Could not find `$operationMap in $CliPath" }
$opToCmdlet = [ordered]@{}
$cmdletToOp = @{}
foreach ($m in [regex]::Matches($mapMatch.Groups['body'].Value, "(?m)^\s*'(?<op>[A-Za-z0-9]+)'\s*=\s*(?<val>'[^']*'|\`$null)")) {
    $op = $m.Groups['op'].Value
    $val = $m.Groups['val'].Value
    if ($val -eq '$null') { continue }
    $cmdletName = $val.Trim("'")
    $opToCmdlet[$op] = $cmdletName
    $cmdletToOp[$cmdletName] = $op
}

$commands = @(Get-Command -Module $module.Name -CommandType Function | Sort-Object Name)
$commandNames = @($commands | ForEach-Object { $_.Name })
foreach ($op in @($opToCmdlet.Keys)) {
    if ($commandNames -notcontains $opToCmdlet[$op]) {
        Write-Warning "operationMap entry '$op' -> '$($opToCmdlet[$op])' has no matching cmdlet in the module; skipped."
    }
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Get-ToolName {
    param([string]$CmdletName)
    if ($cmdletToOp.ContainsKey($CmdletName)) { return $cmdletToOp[$CmdletName] }
    $fallback = $CmdletName -replace '^([A-Za-z]+)-Tc', '$1' -replace '-', ''
    Write-Warning "Cmdlet '$CmdletName' is not in the CLI operationMap; using tool name '$fallback'."
    return $fallback
}

function Get-LiteralDefault {
    # Returns @{ Found = bool; Value = ... } for a parameter's AST default value.
    param([System.Management.Automation.Language.ExpressionAst]$Ast)
    $none = @{ Found = $false; Value = $null }
    if ($null -eq $Ast) { return $none }
    if ($Ast -is [System.Management.Automation.Language.ConstantExpressionAst]) {
        return @{ Found = $true; Value = $Ast.Value }
    }
    if ($Ast -is [System.Management.Automation.Language.VariableExpressionAst]) {
        switch ($Ast.VariablePath.UserPath.ToLowerInvariant()) {
            'true' { return @{ Found = $true; Value = $true } }
            'false' { return @{ Found = $true; Value = $false } }
            default { return $none }   # $null or a runtime variable
        }
    }
    if ($Ast -is [System.Management.Automation.Language.UnaryExpressionAst] -and
        $Ast.TokenKind -eq [System.Management.Automation.Language.TokenKind]::Minus -and
        $Ast.Child -is [System.Management.Automation.Language.ConstantExpressionAst]) {
        return @{ Found = $true; Value = (0 - $Ast.Child.Value) }
    }
    return $none
}

function Get-TypeSchema {
    # Maps a .NET parameter type to a JSON schema fragment. Returns $null for unsupported types.
    param([System.Type]$Type)
    $tn = $Type.FullName
    switch ($tn) {
        'System.String' { return [ordered]@{ type = 'string' } }
        'System.Int32' { return [ordered]@{ type = 'integer' } }
        'System.Int64' { return [ordered]@{ type = 'integer' } }
        'System.Int16' { return [ordered]@{ type = 'integer' } }
        'System.UInt32' { return [ordered]@{ type = 'integer' } }
        'System.UInt16' { return [ordered]@{ type = 'integer' } }
        'System.Byte' { return [ordered]@{ type = 'integer' } }
        'System.Double' { return [ordered]@{ type = 'number' } }
        'System.Single' { return [ordered]@{ type = 'number' } }
        'System.Decimal' { return [ordered]@{ type = 'number' } }
        'System.Boolean' { return [ordered]@{ type = 'boolean' } }
        'System.Management.Automation.SwitchParameter' { return [ordered]@{ type = 'boolean' } }
        'System.String[]' { return [ordered]@{ type = 'array'; items = [ordered]@{ type = 'string' }; minItems = 1 } }
        'System.Collections.Hashtable' { return [ordered]@{ type = 'object'; additionalProperties = $true } }
        'System.Collections.Hashtable[]' { return [ordered]@{ type = 'array'; items = [ordered]@{ type = 'object'; additionalProperties = $true } } }
        'System.Management.Automation.PSObject' { return [ordered]@{ type = 'object'; additionalProperties = $true } }
        'System.Management.Automation.PSCustomObject' { return [ordered]@{ type = 'object'; additionalProperties = $true } }
        'System.Management.Automation.PSObject[]' { return [ordered]@{ type = 'array'; items = [ordered]@{ type = 'object'; additionalProperties = $true } } }
        'System.Object' { return [ordered]@{} }
        'System.Management.Automation.ScriptBlock' { return $null }
        default {
            if ($Type.IsArray) { return [ordered]@{ type = 'array'; items = [ordered]@{} } }
            Write-Warning "Unmapped parameter type $tn; exposing as free-form."
            return [ordered]@{}
        }
    }
}

function Get-HelpText {
    param($Description)
    if ($null -eq $Description) { return '' }
    $parts = @($Description | ForEach-Object { if ($null -ne $_.Text) { [string]$_.Text } else { [string]$_ } })
    $text = ($parts -join ' ') -replace '\s+', ' '
    return $text.Trim()
}

# ---------------------------------------------------------------------------
# Build tool list
# ---------------------------------------------------------------------------
$tools = New-Object System.Collections.ArrayList
$warningsCollected = New-Object System.Collections.ArrayList

foreach ($cmd in $commands) {
    $cmdletName = $cmd.Name
    $toolName = Get-ToolName -CmdletName $cmdletName

    $help = $null
    try { $help = Get-Help -Name $cmdletName -Full -ErrorAction Stop } catch { $help = $null }

    # --- tool description ---
    $synopsis = ''
    if ($null -ne $help -and $null -ne $help.Synopsis) { $synopsis = ([string]$help.Synopsis -replace '\s+', ' ').Trim() }
    $hasRealHelp = -not [string]::IsNullOrWhiteSpace($synopsis) -and
        $synopsis -ne $cmdletName -and
        -not ($synopsis -match ('^' + [regex]::Escape($cmdletName) + '(\s|\[|$)'))
    $description = if ($descriptionOverrides.ContainsKey($toolName)) { $descriptionOverrides[$toolName] }
                   elseif ($hasRealHelp) { $synopsis }
                   else { "$cmdletName (TwinCATAutomation)" }

    # --- parameter help lookup ---
    $paramHelp = @{}
    if ($null -ne $help -and $null -ne $help.parameters -and $null -ne $help.parameters.parameter) {
        foreach ($hp in @($help.parameters.parameter)) {
            if ($null -ne $hp.name) { $paramHelp[[string]$hp.name] = Get-HelpText $hp.description }
        }
    }

    # --- AST defaults ---
    $astDefaults = @{}
    try {
        $paramBlock = $cmd.ScriptBlock.Ast.Body.ParamBlock
        if ($null -ne $paramBlock) {
            foreach ($p in $paramBlock.Parameters) {
                $astDefaults[$p.Name.VariablePath.UserPath] = Get-LiteralDefault -Ast $p.DefaultValue
                if ($null -ne $p.DefaultValue -and -not $astDefaults[$p.Name.VariablePath.UserPath].Found) {
                    $null = $warningsCollected.Add("$cmdletName -$($p.Name.VariablePath.UserPath): default '$($p.DefaultValue.Extent.Text)' is not a literal; omitted from schema.")
                }
            }
        }
    }
    catch { }

    $properties = [ordered]@{}
    $required = New-Object System.Collections.ArrayList

    foreach ($pName in $cmd.Parameters.Keys) {
        if ($commonParameters -contains $pName) { continue }
        $meta = $cmd.Parameters[$pName]
        $schema = Get-TypeSchema -Type $meta.ParameterType
        if ($null -eq $schema) {
            $null = $warningsCollected.Add("$cmdletName -$pName ($($meta.ParameterType.Name)) is not exposed via MCP.")
            continue
        }

        $isMandatory = $false
        foreach ($attr in $meta.Attributes) {
            if ($attr -is [System.Management.Automation.ParameterAttribute] -and $attr.Mandatory) { $isMandatory = $true }
            elseif ($attr -is [System.Management.Automation.ValidateSetAttribute]) { $schema['enum'] = @($attr.ValidValues) }
            elseif ($attr -is [System.Management.Automation.ValidateRangeAttribute]) {
                $schema['minimum'] = $attr.MinRange
                $schema['maximum'] = $attr.MaxRange
            }
        }

        $descKey = "$toolName.$pName"
        $pDesc = ''
        if ($paramDescriptionOverrides.ContainsKey($descKey)) { $pDesc = $paramDescriptionOverrides[$descKey] }
        elseif ($paramHelp.ContainsKey($pName)) { $pDesc = $paramHelp[$pName] }
        if (-not [string]::IsNullOrWhiteSpace($pDesc)) { $schema['description'] = $pDesc }

        if ($astDefaults.ContainsKey($pName) -and $astDefaults[$pName].Found -and
            $meta.ParameterType.FullName -ne 'System.Management.Automation.SwitchParameter') {
            $schema['default'] = $astDefaults[$pName].Value
        }

        if ($isMandatory) {
            if ($schema.Contains('default')) {
                $null = $warningsCollected.Add("$cmdletName -$pName is Mandatory but has a default value; kept in required, default dropped.")
                $schema.Remove('default')
            }
            $null = $required.Add($pName)
        }

        $properties[$pName] = $schema
    }

    $timeoutMs = if ($timeoutOverrides.ContainsKey($toolName)) { $timeoutOverrides[$toolName] } else { $defaultTimeoutMs }

    $tool = [ordered]@{
        name        = $toolName
        cmdlet      = $cmdletName
        description = $description
        timeoutMs   = $timeoutMs
        annotations = (Get-ToolAnnotations -ToolName $toolName)
        inputSchema = [ordered]@{
            type                 = 'object'
            properties           = $properties
            required             = @($required.ToArray())
            additionalProperties = $false
        }
    }
    $null = $tools.Add($tool)
}

$sortedTools = @($tools | Sort-Object { $_['name'] })
$dupes = @($sortedTools | Group-Object { $_['name'] } | Where-Object { $_.Count -gt 1 })
foreach ($d in $dupes) { Write-Warning "Duplicate tool name '$($d.Name)'." }
$allNames = @($sortedTools | ForEach-Object { $_['name'] })
foreach ($n in @($readOnlyTools + $destructiveTools)) {
    if ($allNames -notcontains $n) { Write-Warning "Annotation list names unknown tool '$n'." }
}

$document = [ordered]@{
    generatedAt   = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    moduleVersion = $moduleVersion
    tools         = $sortedTools
}

$json = ConvertTo-Json -InputObject $document -Depth 20
# PS 5.1 escapes a few ASCII characters as \u00XX; keep them readable for diffs.
$json = $json -replace '\\u0027', "'" -replace '\\u003c', '<' -replace '\\u003e', '>' -replace '\\u0026', '&'
$json = $json -replace "`r?`n", "`r`n"
if (-not $json.EndsWith("`n")) { $json += "`r`n" }

$outDir = [System.IO.Path]::GetDirectoryName($OutPath)
if (-not (Test-Path -LiteralPath $outDir)) { $null = New-Item -ItemType Directory -Path $outDir -Force }
[System.IO.File]::WriteAllText($OutPath, $json, (New-Object System.Text.UTF8Encoding($false)))

foreach ($w in $warningsCollected) { Write-Warning $w }
Write-Host "Wrote $($sortedTools.Count) tools to $OutPath (module $moduleVersion)."
