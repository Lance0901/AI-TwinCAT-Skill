<#
.SYNOPSIS
    Rewrites the generated parts of the docs (counts and the SKILL.md cmdlet signature table) (#25).

.DESCRIPTION
    Numbers and tables that follow from the code are not written by hand any more: parallel PRs
    that add a cmdlet or a tool used to conflict on every "81 cmdlets" sentence. Sources:
      cmdlet-count      exported functions of src/TwinCATAutomation/TwinCATAutomation.psm1
      mcp-tool-count    "tools" entries of mcp-server/tools.json (cmdlets offered over MCP)
      composite-count   entries of `export const composites = [...]` in mcp-server/lib/composites.js
      cmdlet-signatures SKILL.md table: cmdlet, MCP tool name, parameters (from Get-Command)

    Where the output goes (markers in the target file; everything outside them stays hand-written):
      * inline  <!-- generated:cmdlet-count -->81<!-- /generated -->
      * block   <!-- generated:cmdlet-signatures -->  ...table...  <!-- /generated -->
      * $patternRules below: counts inside a code fence, where an HTML comment would show up
        literally (the number is captured by the regex group `n`).
    Line endings and BOM of every file are kept.

    Default: rewrite the files. -Check: write nothing, list every stale spot, exit 1 when any
    (scripts/check.ps1 runs it that way).

    Whole generated files (#144; nothing in them is hand-written, edit the generator or the sources):
      adapters/codex/tools.json, adapters/antigravity/plugin.yaml
        One action per key of $operationMap in Invoke-TwinCATAutomation.ps1 (the single source of the
        CLI actions), in file order. Parameters, types, enums, defaults and descriptions come from the
        action's entry in mcp-server/tools.json. Descriptions are taken COMPLETE (whitespace collapsed):
        they carry the safety rules (confirm with the user, fail closed, who may call what); a DryRun
        default of true is stated if the text does not say it. The four actions that have no tools.json entry (NewProject: not offered on
        MCP, #70; GetIdeModalDialog: composite; StartLifecycle: composite RunLifecycle on MCP, #27; ListOperations: CLI only) are described in
        $extraActions below. scripts/check.ps1 additionally compares the action names with
        $operationMap ('adapters' rule).
    .agents/skills/twincat/SKILL.md: hand-written lifecycle example and Failure contract; the cmdlet
    signature table in it is the generated cmdlet-signatures block (same as adapters/claude-code/SKILL.md).
.PARAMETER Check
    Report only; exit code 1 when a file differs from the generated output.
.PARAMETER DocsRoot
    Folder that holds the target files (default: the repository). For tests only: the sources
    (module, tools.json, composites.js) always come from this repository.
#>
[CmdletBinding()]
param([switch]$Check, [string]$DocsRoot)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $scriptDir '..')).ProviderPath
$utf8 = New-Object System.Text.UTF8Encoding($false)
if ([string]::IsNullOrWhiteSpace($DocsRoot)) { $DocsRoot = $repoRoot }

# Files that carry markers (relative paths). A marker in any other file is ignored.
$targets = @(
    'README.md', 'README.zh-TW.md', 'CLAUDE.md', 'AGENTS.md',
    'adapters/claude-code/SKILL.md', 'docs/setup-mcp.md', 'mcp-server/README.md', 'docs/known-limitations.md', '.agents/skills/twincat/SKILL.md'
)
# Files that are generated as a whole (relative paths): the content is built below.
$wholeFiles = @('adapters/codex/tools.json', 'adapters/antigravity/plugin.yaml')
# Counts that sit in a code fence: file, regex with named group n, value key.
$patternRules = @(
    @{ File = 'README.md'; Regex = 'Public/\s+# (?<n>\d+) exported cmdlets'; Key = 'cmdlet-count' },
    @{ File = 'README.zh-TW.md'; Regex = 'Public/\s+# (?<n>\d+) 個匯出的 cmdlet'; Key = 'cmdlet-count' }
)

# ---- sources -----------------------------------------------------------------------------------
$module = Import-Module (Join-Path $repoRoot 'src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -PassThru -DisableNameChecking -ErrorAction Stop
$commands = @(Get-Command -Module $module.Name -CommandType Function | Sort-Object Name)
$toolsDoc = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'mcp-server\tools.json'), $utf8) | ConvertFrom-Json
$toolByCmdlet = @{}
foreach ($t in $toolsDoc.tools) { $toolByCmdlet[[string]$t.cmdlet] = [string]$t.name }
$compositesJs = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'mcp-server\lib\composites.js'), $utf8)
$cm = [regex]::Match($compositesJs, 'export const composites = \[([^\]]*)\]')
if (-not $cm.Success) { throw 'composites.js: "export const composites = [...]" not found' }
$compositeConst = @($cm.Groups[1].Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$compositeCount = $compositeConst.Count
# composite tool -> public cmdlet that returns the same data: <Verb>-Tc<Rest> when the module has it
# (GetIdeModalDialog -> Get-TcIdeModalDialog); a composite without such a cmdlet is not listed.
$compositeByCmdlet = @{}
foreach ($cn in $compositeConst) {
    if ($cn -match '^(Get|Set|Add|Remove|Find|Test|Invoke|New|Clear|Enter|Exit|Connect|Disconnect)([A-Z].*)$' -and ($commands.Name -contains ('{0}-Tc{1}' -f $Matches[1], $Matches[2]))) { $compositeByCmdlet['{0}-Tc{1}' -f $Matches[1], $Matches[2]] = $cn }
}
# #27: the composite RunLifecycle is the MCP side of Start-TcLifecycle (names do not follow the rule above)
if ($compositeConst -contains 'RunLifecycle' -and ($commands.Name -contains 'Start-TcLifecycle')) { $compositeByCmdlet['Start-TcLifecycle'] = 'RunLifecycle' }

$common = @([System.Management.Automation.PSCmdlet]::CommonParameters) + @([System.Management.Automation.PSCmdlet]::OptionalCommonParameters)
# one spelling per type: lower case, Object -> obj (everything else: the .NET name in lower case)
$typeNames = @{ String = 'string'; Int32 = 'int'; Int64 = 'long'; Double = 'double'; Boolean = 'bool'; Object = 'obj'; 'String[]' = 'string[]'; 'Object[]' = 'obj[]'; 'Int32[]' = 'int[]' }
$rows = New-Object System.Collections.Generic.List[string]
foreach ($c in $commands) {
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($p in $c.Parameters.Values | Where-Object { $common -notcontains $_.Name }) {
        $mandatory = @($p.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory }).Count -gt 0
        $tn = $p.ParameterType.Name
        $item = if ($p.SwitchParameter) { "-$($p.Name)" } else { "-$($p.Name) <$(if ($typeNames.ContainsKey($tn)) { $typeNames[$tn] } else { $tn.ToLowerInvariant() })>" }
        $parts.Add($(if ($mandatory) { $item } else { "[$item]" }))
    }
    $tool = if ($toolByCmdlet.ContainsKey($c.Name)) { '`' + $toolByCmdlet[$c.Name] + '`' } elseif ($compositeByCmdlet.ContainsKey($c.Name)) { '`' + $compositeByCmdlet[$c.Name] + '` (composite)' } else { '-' }
    $sig = if ($parts.Count -gt 0) { '`' + ($parts -join ' ') + '`' } else { '-' }
    $rows.Add("| ``$($c.Name)`` | $tool | $sig |")
}
$signatureBlock = @(
    '',
    '<!-- 由 scripts/Update-GeneratedDocs.ps1 從 Get-Command 與 mcp-server/tools.json 產生,不要手改。 -->',
    '',
    '| Cmdlet | MCP tool | 參數(`[ ]` = 選填;切換參數不帶值) |',
    '|---|---|---|'
) + $rows + @('')

# ---- adapter files (#144) ----------------------------------------------------------------------
$cliText = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'Invoke-TwinCATAutomation.ps1'), $utf8)
$mapMatch = [regex]::Match($cliText, '\$operationMap\s*=\s*@\{(?<body>.*?)\n\}', 'Singleline')
if (-not $mapMatch.Success) { throw 'Invoke-TwinCATAutomation.ps1: $operationMap not found' }
$actionNames = @([regex]::Matches($mapMatch.Groups['body'].Value, "(?m)^\s*'([A-Za-z0-9]+)'\s*=") | ForEach-Object { $_.Groups[1].Value })
if ($actionNames.Count -eq 0) { throw '$operationMap has no entries' }

# Actions without a tools.json entry: name -> description + parameters (name, type, required, description, enum).
$extraActions = @{
    NewProject       = @{
        Description = 'Create new TwinCAT project with PLC and MAIN program. #70: only on an IDE with no solution open (otherwise SOLUTION_ALREADY_OPEN, nothing created); not offered on the MCP server.'
        Params      = @(
            @{ Name = 'Name'; Type = 'string'; Required = $true; Description = 'Project name' },
            @{ Name = 'Path'; Type = 'string'; Required = $false; Description = 'Target directory' })
    }
    GetIdeModalDialog = @{
        Description = 'Report the modal dialog blocking the IDE (data.scanComplete true + data.dialog null when none; an unfinished scan is MODAL_SCAN_INCOMPLETE, unknown, not none). Works while DTE calls fail with IDE_BUSY. On MCP this is a composite tool.'
        Params      = @(
            @{ Name = 'ProcessId'; Type = 'integer'; Required = $false; Description = 'IDE process id (default: the connected IDE)' },
            @{ Name = 'TimeoutSec'; Type = 'integer'; Required = $false; Minimum = 1; Maximum = 60; Default = 5; Description = 'How long to probe for a dialog (1..60, default 5).' })
    }
    StartLifecycle   = @{
        Description = 'Full PLC lifecycle in one call (#27): ConnectIde -> SetTarget (only with TargetAmsNetId or Platform) -> BuildProject (unless SkipBuild) -> EnableConfig (Force) -> ConnectAds -> GetPlcState readback (must be Run unless NoLogin, else RUNTIME_STATE_MISMATCH). Changes the running machine (TwinCAT restarts, PLC program downloaded and started): confirm with the user first. Fail closed (#68): stops at the first failing step, error = that step''s error as it is (LIFECYCLE_BLOCKED: stop and report, data.lifecycleBlock), never retry through another channel. ADS port: AdsPort, else the adsPort of EnableConfig data.plcs when they have exactly one distinct port, else 851; with PlcProjectPath an AdsPort that is not one of the selected PLC ports -> PLC_PORT_MISMATCH (not connected, allowed ports in the message). data: steps[] {name, success, code, durationMs, result}, failedStep, plcProjects, adsPort, loggedIn, plcState, lifecycleBlock. On MCP this is the composite RunLifecycle (same parameters).'
        Params      = @(
            @{ Name = 'SolutionPath'; Type = 'string'; Required = $false; Description = 'Solution (.sln) to open on ConnectIde. Given or omitted, only an IDE TcAuto launched or one already bound with ConnectIde ProcessId (user consent) is attached - with it, an IDE that already has the .sln open (#281 C); else IDE_ATTACH_CONSENT_REQUIRED (ask the user, then ConnectIde ProcessId=<pid>, plus SolutionPath when given).' },
            @{ Name = 'ProgId'; Type = 'string'; Required = $false; Description = 'Visual Studio / XAE shell ProgId passed to ConnectIde.' },
            @{ Name = 'NoLaunch'; Type = 'boolean'; Required = $false; Description = 'Do not launch XAE if it is not running.' },
            @{ Name = 'TargetAmsNetId'; Type = 'string'; Required = $false; Description = 'AmsNetId to select with SetTarget before the build. Omit to keep the target the IDE has.' },
            @{ Name = 'Platform'; Type = 'string'; Required = $false; Description = 'Solution platform for SetTarget and EnableConfig, e.g. "TwinCAT OS (x64)" (UmRT / TwinCAT/BSD) or "TwinCAT RT (x64)" (Windows RT). Needed only when the target does not report TARGETINFO (ADS 0x702).' },
            @{ Name = 'SkipBuild'; Type = 'boolean'; Required = $false; Description = 'Skip BuildProject.' },
            @{ Name = 'TimeoutSec'; Type = 'integer'; Required = $false; Minimum = 10; Maximum = 3600; Default = 120; Description = 'EnableConfig timeout in seconds (10..3600, default 120).' },
            @{ Name = 'NoLogin'; Type = 'boolean'; Required = $false; Description = 'EnableConfig: activate only, no PLC login / download / Run; the readback only reports the PLC state.' },
            @{ Name = 'PlcProjectPath'; Type = 'array'; Items = 'string'; Required = $false; Description = 'EnableConfig PlcProjectPath: PLC project(s) to log into and start (name, e.g. "FrameworkUnitTest", or tree path). Default: every enabled PLC.' },
            @{ Name = 'ExpectedProject'; Type = 'array'; Items = 'string'; Required = $false; Description = 'BuildProject ExpectedProject: PLC project(s) that must be part of the build. Not derived from PlcProjectPath.' },
            @{ Name = 'AdsPort'; Type = 'integer'; Required = $false; Minimum = 1; Maximum = 65535; Description = 'ADS port for ConnectAds (default: the one distinct adsPort of EnableConfig data.plcs, else 851). With PlcProjectPath it must be the port of a selected PLC (PLC_PORT_MISMATCH otherwise).' },
            @{ Name = 'BuildTimeoutSec'; Type = 'integer'; Required = $false; Minimum = 5; Maximum = 7200; Description = 'BuildProject TimeoutSec (5..7200; default: the BuildProject default).' })
    }
    ListOperations   = @{ Description = 'List all available operations.'; Params = @() }
}

# $extraActions must describe real operationMap actions, with the parameters of the cmdlet behind them.
$opCmdlet = @{}
foreach ($mm in [regex]::Matches($mapMatch.Groups['body'].Value, "(?m)^\s*'([A-Za-z0-9]+)'\s*=\s*(?:[$]null|'([^']+)')")) { $opCmdlet[$mm.Groups[1].Value] = $mm.Groups[2].Value }
$commonParams = @([System.Management.Automation.PSCmdlet]::CommonParameters) + @([System.Management.Automation.PSCmdlet]::OptionalCommonParameters)
foreach ($ek in $extraActions.Keys) {
    if ($actionNames -cnotcontains $ek) { throw "`$extraActions key '$ek' is not an action of `$operationMap in Invoke-TwinCATAutomation.ps1" }
    $cn = $opCmdlet[$ek]
    if ([string]::IsNullOrEmpty($cn)) { if (@($extraActions[$ek].Params).Count -ne 0) { throw "`$extraActions '$ek' has parameters but no cmdlet" }; continue }
    $cmd = $commands | Where-Object { $_.Name -eq $cn }
    if (-not $cmd) { throw "`$extraActions '$ek': cmdlet '$cn' is not exported by the module" }
    $real = @($cmd.Parameters.Values | Where-Object { $commonParams -notcontains $_.Name } | ForEach-Object { $_.Name } | Sort-Object)
    $mine = @($extraActions[$ek].Params | ForEach-Object { $_.Name } | Sort-Object)
    if (($real -join ',') -cne ($mine -join ',')) { throw "`$extraActions '$ek' parameters ($($mine -join ', ')) differ from $cn ($($real -join ', '))" }
    foreach ($ep in $extraActions[$ek].Params) {
        $isMandatory = @($cmd.Parameters[$ep.Name].Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory }).Count -gt 0
        if ([bool]$ep.Required -ne $isMandatory) { throw "`$extraActions '$ek' parameter $($ep.Name): Required = $($ep.Required), cmdlet says $isMandatory" }
    }
}

function ConvertTo-AdapterJsonString([string]$s) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $s.ToCharArray()) {
        switch ($ch) {
            '"' { [void]$sb.Append('\"') }
            '\' { [void]$sb.Append('\\') }
            "`n" { [void]$sb.Append('\n') }
            "`r" { [void]$sb.Append('\r') }
            "`t" { [void]$sb.Append('\t') }
            default { if ([int]$ch -lt 32) { [void]$sb.AppendFormat('\u{0:x4}', [int]$ch) } else { [void]$sb.Append($ch) } }
        }
    }
    [void]$sb.Append('"')
    $sb.ToString()
}
function ConvertTo-AdapterScalar($v) {
    if ($v -is [bool]) { return $(if ($v) { 'true' } else { 'false' }) }
    if ($v -is [string]) { return (ConvertTo-AdapterJsonString $v) }
    if ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) { return [string]::Format([cultureinfo]::InvariantCulture, '{0}', $v) }
    throw "adapter generator: value of type $(if ($null -eq $v) { 'null' } else { $v.GetType().FullName }) is not a scalar"
}
# Whole text, whitespace collapsed (the descriptions carry safety rules: nothing is cut).
function Get-FlatText([string]$Text) { ($Text -replace '\s+', ' ').Trim() }

$toolByName = @{}
foreach ($t in $toolsDoc.tools) { $toolByName[[string]$t.name] = $t }
$adapterActions = New-Object System.Collections.Generic.List[object]
foreach ($an in $actionNames) {
    $ps = New-Object System.Collections.Generic.List[object]
    if ($toolByName.ContainsKey($an)) {
        $tool = $toolByName[$an]
        $desc = Get-FlatText ([string]$tool.description)
        $req = @($tool.inputSchema.required)
        foreach ($prop in $tool.inputSchema.properties.PSObject.Properties) {
            $pv = $prop.Value
            $ps.Add(@{
                    Name = $prop.Name
                    Type = $(if ($pv.PSObject.Properties['type']) { [string]$pv.type } else { 'any' })
                    Enum = $(if ($pv.PSObject.Properties['enum']) { @($pv.enum) } else { $null })
                    Minimum = $(if ($pv.PSObject.Properties['minimum']) { $pv.minimum } else { $null })
                    Maximum = $(if ($pv.PSObject.Properties['maximum']) { $pv.maximum } else { $null })
                    Items = $(if ($pv.PSObject.Properties['items'] -and $pv.items.PSObject.Properties['type']) { [string]$pv.items.type } else { $null })
                    Required = ($req -contains $prop.Name)
                    HasDefault = [bool]$pv.PSObject.Properties['default']
                    Default = $(if ($pv.PSObject.Properties['default']) { $pv.default } else { $null })
                    Description = $(if ($pv.PSObject.Properties['description']) { Get-FlatText ([string]$pv.description) } else { '' })
                })
            if ($prop.Name -eq 'DryRun' -and $pv.PSObject.Properties['default'] -and $pv.default -eq $true -and $desc -notmatch '(?i)dry-run') { $desc += ' Dry-run by default.' }
        }
    }
    elseif ($extraActions.ContainsKey($an)) {
        $desc = $extraActions[$an].Description
        foreach ($ep in $extraActions[$an].Params) {
            $ps.Add(@{ Name = $ep.Name; Type = $ep.Type; Enum = $null; Items = $ep.Items; Minimum = $ep.Minimum; Maximum = $ep.Maximum; Required = $ep.Required; HasDefault = ($null -ne $ep.Default); Default = $ep.Default; Description = $ep.Description })
        }
    }
    else { throw "operationMap action '$an' has neither a tools.json entry nor an `$extraActions entry in scripts/Update-GeneratedDocs.ps1" }
    $adapterActions.Add(@{ Name = $an; Description = $desc; Params = $ps })
}

$jsonLines = New-Object System.Collections.Generic.List[string]
$jsonLines.AddRange([string[]]@('{', '  "name": "twincat-automation",', '  "description": "TwinCAT 3 IDE automation and PLC runtime control",', '  "entryPoint": "pwsh Invoke-TwinCATAutomation.ps1",', '  "tools": ['))
for ($ai = 0; $ai -lt $adapterActions.Count; $ai++) {
    $a = $adapterActions[$ai]
    $jsonLines.Add('    {')
    $jsonLines.Add("      `"name`": $(ConvertTo-AdapterJsonString $a.Name),")
    $jsonLines.Add("      `"description`": $(ConvertTo-AdapterJsonString $a.Description),")
    if ($a.Params.Count -eq 0) { $jsonLines.Add('      "parameters": {}') }
    else {
        $jsonLines.Add('      "parameters": {')
        for ($pi = 0; $pi -lt $a.Params.Count; $pi++) {
            $q = $a.Params[$pi]
            $f = New-Object System.Collections.Generic.List[string]
            $f.Add("`"type`": $(ConvertTo-AdapterJsonString $q.Type)")
            if ($null -ne $q.Enum) { $f.Add("`"enum`": [$((@($q.Enum) | ForEach-Object { ConvertTo-AdapterScalar $_ }) -join ', ')]") }
            if ($q.Items) { $f.Add("`"items`": { `"type`": $(ConvertTo-AdapterJsonString $q.Items) }") }
            if ($null -ne $q.Minimum) { $f.Add("`"minimum`": $(ConvertTo-AdapterScalar $q.Minimum)") }
            if ($null -ne $q.Maximum) { $f.Add("`"maximum`": $(ConvertTo-AdapterScalar $q.Maximum)") }
            if ($q.Description) { $f.Add("`"description`": $(ConvertTo-AdapterJsonString $q.Description)") }
            $f.Add("`"required`": $(ConvertTo-AdapterScalar $q.Required)")
            if ($q.HasDefault) { $f.Add("`"default`": $(ConvertTo-AdapterScalar $q.Default)") }
            $jsonLines.Add("        $(ConvertTo-AdapterJsonString $q.Name): { $($f -join ', ') }$(if ($pi -lt $a.Params.Count - 1) { ',' })")
        }
        $jsonLines.Add('      }')
    }
    $jsonLines.Add("    }$(if ($ai -lt $adapterActions.Count - 1) { ',' })")
}
$jsonLines.Add('  ]')
$jsonLines.Add('}')

$yamlLines = New-Object System.Collections.Generic.List[string]
$yamlLines.AddRange([string[]]@(
        '# Generated by scripts/Update-GeneratedDocs.ps1 from $operationMap (Invoke-TwinCATAutomation.ps1) and mcp-server/tools.json (#144).',
        '# Do not edit by hand: run the script and commit the result.',
        'name: twincat-automation', 'description: TwinCAT 3 IDE automation and PLC runtime control via PowerShell', 'version: 0.1.0', 'author: Lance0901', '',
        'runtime:', '  command: pwsh', '  args:', '    - Invoke-TwinCATAutomation.ps1', '    - --operation', '    - "{{operation}}"', '    - --params', '    - "{{params_json}}"', '',
        'actions:'))
foreach ($a in $adapterActions) {
    $yamlLines.Add("  - name: $($a.Name)")
    $yamlLines.Add("    description: $(ConvertTo-AdapterJsonString $a.Description)")
    if ($a.Params.Count -gt 0) {
        $yamlLines.Add('    parameters:')
        foreach ($q in $a.Params) {
            $yamlLines.Add("      $($q.Name):")
            if ($q.Type -ne 'any') { $yamlLines.Add("        type: $($q.Type)") }
            if ($null -ne $q.Enum) { $yamlLines.Add("        enum: [$((@($q.Enum) | ForEach-Object { ConvertTo-AdapterScalar $_ }) -join ', ')]") }
            if ($q.Items) { $yamlLines.Add('        items:'); $yamlLines.Add("          type: $($q.Items)") }
            if ($null -ne $q.Minimum) { $yamlLines.Add("        minimum: $(ConvertTo-AdapterScalar $q.Minimum)") }
            if ($null -ne $q.Maximum) { $yamlLines.Add("        maximum: $(ConvertTo-AdapterScalar $q.Maximum)") }
            if ($q.Description) { $yamlLines.Add("        description: $(ConvertTo-AdapterJsonString $q.Description)") }
            $yamlLines.Add("        required: $(ConvertTo-AdapterScalar $q.Required)")
            if ($q.HasDefault) { $yamlLines.Add("        default: $(ConvertTo-AdapterScalar $q.Default)") }
        }
    }
    $yamlLines.Add('')
}
# no blank line after the last action
$yamlLines.RemoveAt($yamlLines.Count - 1)
$wholeContent = @{
    'adapters/codex/tools.json'          = (($jsonLines -join "`n") + "`n")
    'adapters/antigravity/plugin.yaml'   = (($yamlLines -join "`n") + "`n")
}
$values = @{
    'cmdlet-count'      = [string]$commands.Count
    'mcp-tool-count'    = [string]@($toolsDoc.tools).Count
    'composite-count'   = [string]$compositeCount
    'cmdlet-signatures' = ($signatureBlock -join "`n")
}

# ---- rewrite -----------------------------------------------------------------------------------
$markerRegex = [regex]'(?s)<!-- generated:(?<key>[a-z-]+) -->(?<body>.*?)<!-- /generated -->'
$stale = New-Object System.Collections.Generic.List[string]
$problems = New-Object System.Collections.Generic.List[string]

foreach ($rel in $targets) {
    $path = Join-Path $DocsRoot $rel
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text = $utf8.GetString($bytes, $(if ($hasBom) { 3 } else { 0 }), $bytes.Length - $(if ($hasBom) { 3 } else { 0 }))
    $crlf = $text.Contains("`r`n")
    $orig = $text
    $lf = $text.Replace("`r`n", "`n")

    # Broken markers must never swallow hand-written text: an opening without its closing marker
    # would make the lazy regex run into the next block. Report and leave the file alone.
    $fileProblems = New-Object System.Collections.Generic.List[string]
    $opens = [regex]::Matches($lf, '<!-- generated:').Count
    $closes = [regex]::Matches($lf, '<!-- /generated -->').Count
    if ($opens -ne $closes) { $fileProblems.Add("${rel}: $opens opening and $closes closing generated markers") }
    foreach ($mm in $markerRegex.Matches($lf)) {
        $mk = $mm.Groups['key'].Value
        if ($mm.Groups['body'].Value.Contains('<!-- generated:')) { $fileProblems.Add("${rel}: marker '$mk' has no closing marker before the next opening one") }
        elseif ($mk -match '-count$' -and $mm.Groups['body'].Value -notmatch '^\d*$') { $fileProblems.Add("${rel}: marker '$mk' body is not a number") }
    }
    if ($fileProblems.Count -gt 0) { foreach ($fp in $fileProblems) { $problems.Add($fp) }; continue }

    $lf = $markerRegex.Replace($lf, {
            param($m)
            $key = $m.Groups['key'].Value
            if (-not $values.ContainsKey($key)) { $problems.Add("${rel}: unknown marker '$key'"); return $m.Value }
            "<!-- generated:$key -->$($values[$key])<!-- /generated -->"
        })
    foreach ($r in $patternRules | Where-Object { $_.File -eq $rel }) {
        $re = [regex]$r.Regex
        if (-not $re.IsMatch($lf)) { $problems.Add("${rel}: pattern '$($r.Regex)' not found"); continue }
        $lf = $re.Replace($lf, {
                param($m)
                $g = $m.Groups['n']
                $m.Value.Substring(0, $g.Index - $m.Index) + $values[$r.Key] + $m.Value.Substring($g.Index - $m.Index + $g.Length)
            })
    }
    $result = if ($crlf) { $lf.Replace("`n", "`r`n") } else { $lf }
    if ($result -cne $orig) {
        $stale.Add($rel)
        if (-not $Check) {
            $out = $utf8.GetBytes($result)
            if ($hasBom) { $out = [byte[]](0xEF, 0xBB, 0xBF) + $out }
            [System.IO.File]::WriteAllBytes($path, $out)
        }
    }
}

foreach ($rel in $wholeFiles) {
    $path = Join-Path $DocsRoot $rel
    $crlf = $true
    $hasBom = $false
    $orig = $null
    if (Test-Path -LiteralPath $path) {
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        $orig = $utf8.GetString($bytes, $(if ($hasBom) { 3 } else { 0 }), $bytes.Length - $(if ($hasBom) { 3 } else { 0 }))
        $crlf = $orig.Contains("`r`n")
    }
    $result = if ($crlf) { $wholeContent[$rel].Replace("`n", "`r`n") } else { $wholeContent[$rel] }
    if ($null -eq $orig -or $result -cne $orig) {
        $stale.Add($rel)
        if (-not $Check) {
            $out = $utf8.GetBytes($result)
            if ($hasBom) { $out = [byte[]](0xEF, 0xBB, 0xBF) + $out }
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force
            [System.IO.File]::WriteAllBytes($path, $out)
        }
    }
}
# every key used in the values table must appear somewhere (a typo'd marker would silently go stale)
$used = @{}
foreach ($rel in $targets) {
    foreach ($m in $markerRegex.Matches([System.IO.File]::ReadAllText((Join-Path $DocsRoot $rel), $utf8))) { $used[$m.Groups['key'].Value] = $true }
}
foreach ($k in $values.Keys) { if (-not $used.ContainsKey($k)) { $problems.Add("marker '$k' is not used in any target file") } }

foreach ($p in $problems) { Write-Host "PROBLEM $p" }
if ($Check) {
    foreach ($s in $stale) { Write-Host "STALE   $s" }
    if ($stale.Count -gt 0 -or $problems.Count -gt 0) { exit 1 }
    Write-Host "generated docs up to date ($($values['cmdlet-count']) cmdlets, $($values['mcp-tool-count']) MCP tools, $($values['composite-count']) composites, $($actionNames.Count) CLI actions)"
    exit 0
}
foreach ($s in $stale) { Write-Host "updated $s" }
if ($problems.Count -gt 0) { exit 1 }
Write-Host "done ($($values['cmdlet-count']) cmdlets, $($values['mcp-tool-count']) MCP tools, $($values['composite-count']) composites, $($actionNames.Count) CLI actions)"
