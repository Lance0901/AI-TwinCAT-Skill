<#
.SYNOPSIS
    stdin/stdout JSON bridge between the Node MCP server and the TwinCATAutomation module.

.DESCRIPTION
    NOT meant to be run by a person. mcp-server/index.js starts exactly one instance
    (powershell.exe -STA -NoProfile -NonInteractive -ExecutionPolicy Bypass
    -File bridge/bridge.ps1 -ModulePath <psm1>) and talks to it with newline-delimited
    JSON: one request object per stdin line, one "result" line (optionally preceded by
    "log" lines) per request on stdout. The module's $script: state (DTE, ITcSysManager,
    TcAdsClient, AmsNetId, IDE pid) lives in this process for the whole session.

    The wire contract is mcp-server/PROTOCOL.md. Nothing but protocol lines may be
    written to stdout; stderr is free-form diagnostics.

.PARAMETER ModulePath
    Path to TwinCATAutomation.psm1 (or .psd1).

.NOTES
    Keep this file ASCII only: Windows PowerShell 5.1 reads BOM-less files as ANSI.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ModulePath
)

# ---------------------------------------------------------------------------
# Process-wide setup
# ---------------------------------------------------------------------------
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$global:ProgressPreference = 'SilentlyContinue'

$script:BridgeVerbose = ($env:TWINCAT_MCP_VERBOSE -eq '1')
# Module functions resolve preference variables through the global scope, so the
# global copies are what actually enables Write-Verbose / Write-Debug inside them.
if ($script:BridgeVerbose) {
    $VerbosePreference = 'Continue'; $global:VerbosePreference = 'Continue'
    $DebugPreference = 'Continue';   $global:DebugPreference = 'Continue'
}
else {
    $VerbosePreference = 'SilentlyContinue'; $global:VerbosePreference = 'SilentlyContinue'
    $DebugPreference = 'SilentlyContinue';   $global:DebugPreference = 'SilentlyContinue'
}
$WarningPreference = 'Continue';     $global:WarningPreference = 'Continue'
$InformationPreference = 'Continue'; $global:InformationPreference = 'Continue'

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
try { [Console]::OutputEncoding = $utf8NoBom } catch { }
try { [Console]::InputEncoding = $utf8NoBom } catch { }
$OutputEncoding = $utf8NoBom
$global:OutputEncoding = $utf8NoBom

$script:KnownCodePattern = '^(IDE_BUSY|IDE_TIMEOUT|IDE_MODAL_DIALOG|IDE_CRASHED|NOT_CONNECTED|ADS_[A-Z_]+)\b'
$script:CommonParameters = @(
    'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction',
    'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable',
    'OutBuffer', 'PipelineVariable', 'WhatIf', 'Confirm', 'ProgressAction'
)

# ---------------------------------------------------------------------------
# Output helpers (the ONLY way anything reaches stdout)
# ---------------------------------------------------------------------------
function Write-Line {
    param([string]$Json)
    # ConvertTo-Json -Compress never emits raw line breaks (strings are escaped),
    # but the transport is line based, so make it impossible to break a frame.
    if ($Json.IndexOf("`n") -ge 0 -or $Json.IndexOf("`r") -ge 0) {
        $Json = $Json -replace '\r?\n', ' '
    }
    [Console]::Out.WriteLine($Json)
    [Console]::Out.Flush()
}

function Write-Stderr {
    param([string]$Text)
    try { [Console]::Error.WriteLine($Text); [Console]::Error.Flush() } catch { }
}

function ConvertTo-Line {
    param($Object)
    # Depth 50: the module returns nested PSCustomObjects (project trees, I/O trees,
    # test results); -Depth 10 silently turned deeper levels into type-name strings.
    ConvertTo-Json -InputObject $Object -Depth 50 -Compress
}

function New-ErrorResult {
    param(
        [string]$Code,
        [string]$Message,
        [string]$Hint,
        $Data
    )
    $err = [ordered]@{ message = $Message; code = $Code }
    if (-not [string]::IsNullOrWhiteSpace($Hint)) { $err['hint'] = $Hint }
    $r = [ordered]@{ success = $false; error = $err }
    if ($null -ne $Data) { $r['data'] = $Data }
    [PSCustomObject]$r
}

function New-SuccessResult {
    param($Data)
    if ($null -eq $Data) { $Data = @{} }
    [PSCustomObject]@{ success = $true; data = $Data }
}

function Write-Log {
    param($Id, [string]$Level, [string]$Message)
    $line = [ordered]@{ id = $Id; event = 'log'; level = $Level; message = $Message }
    Write-Line (ConvertTo-Line $line)
}

function Write-Result {
    param($Id, $Result)
    $line = [ordered]@{ id = $Id; event = 'result' }
    if ($Result -is [System.Collections.IDictionary]) {
        foreach ($k in $Result.Keys) { $line[[string]$k] = $Result[$k] }
    }
    else {
        foreach ($p in $Result.PSObject.Properties) { $line[$p.Name] = $p.Value }
    }
    if (-not $line.Contains('success')) { $line['success'] = $false }
    $json = $null
    try {
        $json = ConvertTo-Line $line
    }
    catch {
        # Serialisation failed (exotic object in data): degrade to an error result
        # rather than leaving the request without a reply.
        $fallback = [ordered]@{
            id = $Id; event = 'result'; success = $false
            error = [ordered]@{ code = 'INTERNAL_ERROR'; message = "Result could not be serialised: $($_.Exception.Message)" }
        }
        $json = ConvertTo-Line $fallback
    }
    Write-Line $json
}

# ---------------------------------------------------------------------------
# Module import + ready line
# ---------------------------------------------------------------------------
$script:Module = $null
try {
    $resolved = $ModulePath
    try { $resolved = (Resolve-Path -LiteralPath $ModulePath -ErrorAction Stop).ProviderPath } catch { }
    # Stream 3-6 noise during import (unapproved-verb warning, verbose import lines)
    # must never reach stdout.
    $script:Module = Import-Module -Name $resolved -Force -PassThru -DisableNameChecking 3>$null 4>$null 5>$null 6>$null
    if ($null -eq $script:Module) { throw "Import-Module returned no module object for '$resolved'." }
}
catch {
    $ready = [ordered]@{
        event = 'ready'
        ok    = $false
        error = [ordered]@{
            code    = 'MODULE_IMPORT_FAILED'
            message = $_.Exception.Message
            hint    = "Check that '$ModulePath' exists and that Windows PowerShell 5.1 can import it (Import-Module -Force in a console)."
        }
    }
    Write-Line (ConvertTo-Line $ready)
    exit 2
}

$script:ModuleName = $script:Module.Name
$script:ExportedCmdlets = @($script:Module.ExportedFunctions.Keys | Sort-Object)

$ready = [ordered]@{
    event      = 'ready'
    ok         = $true
    cmdlets    = $script:ExportedCmdlets
    psVersion  = $PSVersionTable.PSVersion.ToString()
    apartment  = [string][System.Threading.Thread]::CurrentThread.ApartmentState
    modulePath = [string]$script:Module.Path
}
Write-Line (ConvertTo-Line $ready)

# ---------------------------------------------------------------------------
# Module-scope accessors
# ---------------------------------------------------------------------------
function Invoke-InModule {
    # Runs a script block inside the module's session state (private functions,
    # $script: variables). Arguments are passed positionally.
    param([scriptblock]$Script, [object[]]$ArgumentList = @())
    & $script:Module $Script @ArgumentList
}

function Get-ModuleVar {
    param([string]$Name)
    Invoke-InModule { param($n) Get-Variable -Name $n -Scope Script -ValueOnly -ErrorAction SilentlyContinue } @($Name)
}

function Get-BridgeHint {
    param([string]$Code, [string]$Message)
    if ([string]::IsNullOrWhiteSpace($Code)) { return $null }
    # The module's NOT_CONNECTED hint is ADS oriented; the IDE variant is self-explanatory.
    if ($Code -eq 'NOT_CONNECTED' -and $Message -match '(?i)TwinCAT IDE|Connect-TcIde') {
        return 'Run Connect-TcIde first (ConnectIde).'
    }
    try {
        $h = Invoke-InModule { param($c) Get-TcErrorHint -Code $c } @($Code)
        if ($null -ne $h) { return [string]$h }
    }
    catch { }
    return $null
}

function Add-MissingHint {
    # Result objects built with New-TcResult without -Hint get the module's standard
    # hint for their code when one exists (data shape is otherwise untouched).
    param($Result)
    try {
        if ($null -eq $Result) { return }
        $success = $null
        if ($Result -is [System.Collections.IDictionary]) {
            if ($Result.Contains('success')) { $success = $Result['success'] }
            $err = if ($Result.Contains('error')) { $Result['error'] } else { $null }
        }
        else {
            $sp = $Result.PSObject.Properties['success']
            if ($null -ne $sp) { $success = $sp.Value }
            $ep = $Result.PSObject.Properties['error']
            $err = if ($null -ne $ep) { $ep.Value } else { $null }
        }
        if ($success -ne $false -or $null -eq $err) { return }
        $code = $null; $message = $null; $hasHint = $false
        if ($err -is [System.Collections.IDictionary]) {
            $code = $err['code']; $message = $err['message']
            $hasHint = $err.Contains('hint') -and -not [string]::IsNullOrWhiteSpace([string]$err['hint'])
        }
        else {
            $cp = $err.PSObject.Properties['code'];    if ($null -ne $cp) { $code = $cp.Value }
            $mp = $err.PSObject.Properties['message']; if ($null -ne $mp) { $message = $mp.Value }
            $hp = $err.PSObject.Properties['hint']
            $hasHint = ($null -ne $hp) -and -not [string]::IsNullOrWhiteSpace([string]$hp.Value)
        }
        if ($hasHint -or [string]::IsNullOrWhiteSpace([string]$code)) { return }
        $hint = Get-BridgeHint -Code ([string]$code) -Message ([string]$message)
        if ([string]::IsNullOrWhiteSpace($hint)) { return }
        if ($err -is [System.Collections.IDictionary]) { $err['hint'] = $hint }
        else { $err | Add-Member -NotePropertyName 'hint' -NotePropertyValue $hint -Force }
    }
    catch { }
}

# ---------------------------------------------------------------------------
# Stream capture: run a script block, turn streams 3-6 into log lines, return
# the remaining pipeline objects.
# ---------------------------------------------------------------------------
function Invoke-Captured {
    # Streams 2-6 are merged into the pipeline and handled one record at a time, so
    # every log line is written as soon as it is produced. If the script block then
    # throws, the warnings/errors emitted before the exception have already been
    # sent (the exception itself propagates to the caller unchanged).
    param($Id, [scriptblock]$Script, [object[]]$ArgumentList = @())
    $objects = New-Object System.Collections.ArrayList
    & $Script @ArgumentList 2>&1 3>&1 4>&1 5>&1 6>&1 | ForEach-Object {
        $o = $_
        if ($o -is [System.Management.Automation.ErrorRecord]) {
            # Non-terminating Write-Error inside a cmdlet. Terminating errors are
            # exceptions and never arrive here.
            $em = if ($null -ne $o.Exception) { [string]$o.Exception.Message } else { [string]$o }
            Write-Log -Id $Id -Level 'error' -Message $em
        }
        elseif ($o -is [System.Management.Automation.WarningRecord]) {
            Write-Log -Id $Id -Level 'warning' -Message ([string]$o.Message)
        }
        elseif ($o -is [System.Management.Automation.VerboseRecord]) {
            Write-Log -Id $Id -Level 'debug' -Message ([string]$o.Message)
        }
        elseif ($o -is [System.Management.Automation.DebugRecord]) {
            Write-Log -Id $Id -Level 'debug' -Message ([string]$o.Message)
        }
        elseif ($o -is [System.Management.Automation.InformationRecord]) {
            Write-Log -Id $Id -Level 'info' -Message ([string]$o.MessageData)
        }
        else {
            $null = $objects.Add($o)
        }
    }
    return , $objects.ToArray()
}

function Test-HasSuccess {
    param($Object)
    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains('success') }
    if ($Object -is [string] -or $Object.GetType().IsPrimitive) { return $false }
    return ($null -ne $Object.PSObject.Properties['success'])
}

# ---------------------------------------------------------------------------
# Parameter conversion (PROTOCOL.md "Parameter conversion")
# ---------------------------------------------------------------------------
class BridgeParamException : System.Exception {
    BridgeParamException([string]$m) : base($m) { }
}

function Test-IsJsonObject {
    param($Value)
    return ($Value -is [System.Management.Automation.PSCustomObject]) -or ($Value -is [System.Collections.IDictionary])
}

function Test-IsJsonArray {
    param($Value)
    return ($null -ne $Value) -and ($Value -is [System.Collections.IList]) -and -not ($Value -is [string])
}

function ConvertTo-PlainValue {
    # JSON value (ConvertFrom-Json output) -> hashtable / object[] / scalar, recursively.
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in $Value.Keys) { $h[[string]$k] = ConvertTo-PlainValue $Value[$k] }
        return $h
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $Value.PSObject.Properties) { $h[$p.Name] = ConvertTo-PlainValue $p.Value }
        return $h
    }
    if (Test-IsJsonArray $Value) {
        $list = New-Object System.Collections.ArrayList
        foreach ($e in $Value) { $null = $list.Add((ConvertTo-PlainValue $e)) }
        return , $list.ToArray()
    }
    return $Value
}

function ConvertTo-BridgeHashtable {
    param($Value, [string]$Name)
    if (-not (Test-IsJsonObject $Value)) {
        throw [BridgeParamException]::new("Parameter '$Name' expects a JSON object.")
    }
    return [hashtable](ConvertTo-PlainValue $Value)
}

function ConvertTo-BridgeValue {
    param([System.Type]$TargetType, $Value, [string]$Name)

    $t = $TargetType
    $tn = $t.FullName

    if ($tn -eq 'System.Management.Automation.ScriptBlock') {
        throw [BridgeParamException]::new("Parameter '$Name' is a scriptblock and cannot be passed through the bridge.")
    }

    if ($tn -eq 'System.Management.Automation.SwitchParameter' -or $tn -eq 'System.Boolean') {
        $b = $null
        if ($Value -is [bool]) { $b = $Value }
        elseif ($Value -is [string] -and $Value -match '^(?i)(true|false)$') { $b = ($Value -ieq 'true') }
        elseif ($Value -is [ValueType]) { $b = [bool]$Value }
        else { throw [BridgeParamException]::new("Parameter '$Name' expects a boolean.") }
        if ($tn -eq 'System.Boolean') { return [bool]$b }
        return [switch]$b
    }

    if ($tn -eq 'System.Collections.Hashtable') {
        return ConvertTo-BridgeHashtable -Value $Value -Name $Name
    }

    if ($tn -eq 'System.Collections.Hashtable[]') {
        $items = if (Test-IsJsonArray $Value) { @($Value) } else { @(, $Value) }
        $arr = New-Object System.Collections.ArrayList
        $i = 0
        foreach ($e in $items) {
            if (-not (Test-IsJsonObject $e)) {
                throw [BridgeParamException]::new("Parameter '$Name' expects an array of JSON objects (element $i is not an object).")
            }
            $null = $arr.Add((ConvertTo-BridgeHashtable -Value $e -Name "$Name[$i]"))
            $i++
        }
        return [hashtable[]]$arr.ToArray()
    }

    if ($tn -eq 'System.Management.Automation.PSObject[]') {
        $items = if (Test-IsJsonArray $Value) { @($Value) } else { @(, $Value) }
        return [PSObject[]]$items
    }

    if ($tn -eq 'System.Management.Automation.PSObject' -or $tn -eq 'System.Management.Automation.PSCustomObject') {
        return $Value
    }

    if ($tn -eq 'System.String[]') {
        if (Test-IsJsonObject $Value) { throw [BridgeParamException]::new("Parameter '$Name' expects a string or an array of strings.") }
        $items = if (Test-IsJsonArray $Value) { @($Value) } else { @(, $Value) }
        $strs = New-Object System.Collections.ArrayList
        foreach ($e in $items) {
            if ($null -eq $e -or (Test-IsJsonObject $e) -or (Test-IsJsonArray $e)) {
                throw [BridgeParamException]::new("Parameter '$Name' expects an array of strings.")
            }
            $null = $strs.Add([string]$e)
        }
        return [string[]]$strs.ToArray()
    }

    if ($tn -eq 'System.String') {
        if ((Test-IsJsonObject $Value) -or (Test-IsJsonArray $Value)) {
            throw [BridgeParamException]::new("Parameter '$Name' expects a string.")
        }
        if ($Value -is [bool]) { return $(if ($Value) { 'true' } else { 'false' }) }
        return [string]$Value
    }

    $numeric = @('System.Int32', 'System.Int64', 'System.Int16', 'System.UInt32', 'System.UInt64', 'System.UInt16',
        'System.Byte', 'System.SByte', 'System.Double', 'System.Single', 'System.Decimal')
    if ($numeric -contains $tn) {
        # JSON has a number type: strings ("5"), bools, objects and arrays are rejected
        # rather than coerced.
        if ($null -eq $Value -or $Value -is [bool] -or $Value -is [string] -or $Value -is [char] -or
            -not ($Value -is [ValueType])) {
            throw [BridgeParamException]::new("Parameter '$Name' expects a JSON number.")
        }
        $integerTargets = @('System.Int32', 'System.Int64', 'System.Int16', 'System.UInt32', 'System.UInt64',
            'System.UInt16', 'System.Byte', 'System.SByte')
        if ($integerTargets -contains $tn) {
            # No rounding (Convert.ChangeType would round 2.5 -> 2 banker's style).
            $fractional = $false
            if ($Value -is [double] -or $Value -is [single]) {
                $d = [double]$Value
                $fractional = [double]::IsNaN($d) -or [double]::IsInfinity($d) -or ($d -ne [Math]::Truncate($d))
            }
            elseif ($Value -is [decimal]) {
                $fractional = ($Value -ne [decimal]::Truncate($Value))
            }
            if ($fractional) {
                throw [BridgeParamException]::new("Parameter '$Name' expects an integer, got $Value.")
            }
        }
        try { return [System.Convert]::ChangeType($Value, $t, [System.Globalization.CultureInfo]::InvariantCulture) }
        catch { throw [BridgeParamException]::new("Parameter '$Name' expects a number of type $($t.Name): $($_.Exception.Message)") }
    }

    if ($tn -eq 'System.Object') {
        # A JSON array stays an array: a bare 'return $Value' lets PowerShell unroll it, so a
        # one-element array ([{"name":"bReady","type":"BOOL"}]) reached Add-TcDut -Fields as the
        # single PSCustomObject and was read as a name=type map.
        if (Test-IsJsonArray $Value) { return , $Value }
        return $Value
    }

    if ($t.IsArray) {
        $items = if (Test-IsJsonArray $Value) { @($Value) } else { @(, $Value) }
        return $items
    }

    # Unknown target type: let PowerShell's binder try.
    return $Value
}

function ConvertTo-Splat {
    param([System.Management.Automation.CommandInfo]$Command, $Params)
    $splat = @{}
    if ($null -eq $Params) { return $splat }

    $pairs = New-Object System.Collections.ArrayList
    if ($Params -is [System.Collections.IDictionary]) {
        foreach ($k in $Params.Keys) { $null = $pairs.Add(@([string]$k, $Params[$k])) }
    }
    elseif ($Params -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $Params.PSObject.Properties) { $null = $pairs.Add(@($p.Name, $p.Value)) }
    }
    else {
        throw [BridgeParamException]::new("'params' must be a JSON object.")
    }

    foreach ($pair in $pairs) {
        $name = $pair[0]; $value = $pair[1]
        if ($null -eq $value) { continue }

        $meta = $null
        foreach ($key in $Command.Parameters.Keys) {
            if ($key -ieq $name) { $meta = $Command.Parameters[$key]; break }
        }
        if ($null -eq $meta -or ($script:CommonParameters -contains $meta.Name)) {
            throw [BridgeParamException]::new("Unknown parameter '$name' for $($Command.Name)")
        }
        $splat[$meta.Name] = ConvertTo-BridgeValue -TargetType $meta.ParameterType -Value $value -Name $meta.Name
    }
    return $splat
}

# ---------------------------------------------------------------------------
# op handlers
# ---------------------------------------------------------------------------
function Invoke-OpCall {
    param($Id, $Request)

    $cmdletName = $null
    $cp = $Request.PSObject.Properties['cmdlet']
    if ($null -ne $cp) { $cmdletName = [string]$cp.Value }
    if ([string]::IsNullOrWhiteSpace($cmdletName)) {
        return New-ErrorResult -Code 'INVALID_CMDLET' -Message "Request has no 'cmdlet'." -Hint 'Use one of the cmdlets listed in the ready event.'
    }
    if (-not ($script:ExportedCmdlets -ccontains $cmdletName)) {
        return New-ErrorResult -Code 'INVALID_CMDLET' -Message "Cmdlet '$cmdletName' is not exported by $($script:ModuleName)." -Hint 'Use one of the cmdlets listed in the ready event (case sensitive).'
    }

    $command = Get-Command -Name $cmdletName -Module $script:ModuleName -CommandType Function -ErrorAction Stop

    $params = $null
    $pp = $Request.PSObject.Properties['params']
    if ($null -ne $pp) { $params = $pp.Value }
    $splat = $null
    try {
        $splat = ConvertTo-Splat -Command $command -Params $params
    }
    catch [BridgeParamException] {
        return New-ErrorResult -Code 'INVALID_PARAMS' -Message $_.Exception.Message
    }
    catch {
        if ($_.Exception -is [BridgeParamException]) {
            return New-ErrorResult -Code 'INVALID_PARAMS' -Message $_.Exception.Message
        }
        return New-ErrorResult -Code 'INVALID_PARAMS' -Message "Parameter conversion failed: $($_.Exception.Message)"
    }

    $objects = $null
    try {
        $objects = Invoke-Captured -Id $Id -Script { param($c, $s) & $c @s } -ArgumentList @($command, $splat)
    }
    catch {
        $ex = $_.Exception
        $msg = [string]$ex.Message
        # ParameterBindingException (e.g. ValidateSet / ValidateRange violation) is a
        # caller error, not an execution error.
        if ($ex -is [System.Management.Automation.ParameterBindingException]) {
            return New-ErrorResult -Code 'INVALID_PARAMS' -Message $msg
        }
        $code = 'EXECUTION_ERROR'
        $hint = $null
        if ($msg -match $script:KnownCodePattern) {
            $code = $Matches[1]
            $hint = Get-BridgeHint -Code $code -Message $msg
        }
        else {
            try {
                $mapped = Invoke-InModule { param($e) ConvertTo-TcAdsErrorCode -InputObject $e } @($ex)
                if ($null -ne $mapped -and -not [string]::IsNullOrWhiteSpace([string]$mapped.Code)) {
                    $code = [string]$mapped.Code
                    $hint = [string]$mapped.Hint
                }
            }
            catch { }
        }
        if ($script:BridgeVerbose) {
            Write-Stderr "[bridge] $cmdletName threw: $msg`n$($_.ScriptStackTrace)"
        }
        $data = [ordered]@{ cmdlet = $cmdletName; exceptionType = $ex.GetType().FullName }
        return New-ErrorResult -Code $code -Message $msg -Hint $hint -Data $data
    }

    $candidate = $null
    foreach ($o in $objects) {
        if (Test-HasSuccess $o) { $candidate = $o }
    }
    if ($null -ne $candidate) {
        Add-MissingHint -Result $candidate
        return $candidate
    }

    if ($objects.Count -gt 0) {
        # Cmdlets that return a plain object instead of New-TcResult (New-TcTestCase):
        # wrap it so the tool still gets its payload. See PROTOCOL.md NO_RESULT.
        $payload = if ($objects.Count -eq 1) { $objects[0] } else { $objects }
        return New-SuccessResult -Data $payload
    }

    return New-ErrorResult -Code 'NO_RESULT' -Message "$cmdletName returned no result object"
}

function Invoke-OpModal {
    param($Id, $Request)

    $paramsObj = $null
    $pp = $Request.PSObject.Properties['params']
    if ($null -ne $pp -and $null -ne $pp.Value -and ($pp.Value -is [System.Management.Automation.PSCustomObject])) {
        $paramsObj = $pp.Value
    }

    # params.ProcessId (explicit) wins over the pid stored by Connect-TcIde, so the
    # Node side can scan the IDE of a previous bridge process after a restart.
    $ideProcessId = 0
    $explicitPid = $null
    if ($null -ne $paramsObj) { $explicitPid = $paramsObj.PSObject.Properties['ProcessId'] }
    if ($null -ne $explicitPid -and $null -ne $explicitPid.Value) {
        $pv = $explicitPid.Value
        if ($pv -is [bool] -or $pv -is [string] -or -not ($pv -is [ValueType])) {
            return New-ErrorResult -Code 'INVALID_PARAMS' -Message "Parameter 'ProcessId' expects an integer."
        }
        try { $ideProcessId = [int]$pv } catch {
            return New-ErrorResult -Code 'INVALID_PARAMS' -Message "Parameter 'ProcessId' expects an integer."
        }
        if ($ideProcessId -le 0 -or [double]$pv -ne [double]$ideProcessId) {
            return New-ErrorResult -Code 'INVALID_PARAMS' -Message "Parameter 'ProcessId' must be a positive integer."
        }
    }
    else {
        $stored = Get-ModuleVar 'TcIdeProcessId'
        if ($null -ne $stored) { try { $ideProcessId = [int]$stored } catch { $ideProcessId = 0 } }
    }
    if ($ideProcessId -le 0) {
        return New-ErrorResult -Code 'NOT_CONNECTED' -Message 'No IDE process id is known; the module is not connected to an IDE.' -Hint 'Run Connect-TcIde first, or pass params.ProcessId.'
    }

    $timeoutSec = 5
    if ($null -ne $paramsObj) {
        $tp = $paramsObj.PSObject.Properties['TimeoutSec']
        if ($null -ne $tp -and $null -ne $tp.Value) {
            try { $timeoutSec = [int]$tp.Value } catch {
                return New-ErrorResult -Code 'INVALID_PARAMS' -Message "Parameter 'TimeoutSec' expects a number."
            }
        }
    }
    if ($timeoutSec -lt 1) { $timeoutSec = 1 }
    if ($timeoutSec -gt 60) { $timeoutSec = 60 }

    # #42 review: prepare (cold start) + scan must end before the Node-side tool timeout
    # (GetIdeModalDialog timeoutMs 90000 in lib/composites.js), else BRIDGE_TIMEOUT kills this
    # bridge. 90 - 15 s margin (runspace start-up, JSON, pipe) - scan budget = prepare cap
    # (TimeoutSec 60 -> 15 s prepare, TimeoutSec 5 -> 60 s).
    $toolTimeoutSec = 90
    $prepareSec = [Math]::Max(1, [Math]::Min(60, $toolTimeoutSec - 15 - $timeoutSec))
    $dialog = $null
    try {
        $objects = Invoke-Captured -Id $Id -Script {
            param($p, $t, $pp)
            Invoke-InModule { param($p2, $t2, $pp2) Find-TcIdeModalDialog -ProcessId $p2 -TimeoutSec $t2 -PrepareTimeoutSec $pp2 } @($p, $t, $pp)
        } -ArgumentList @($ideProcessId, $timeoutSec, $prepareSec)
        foreach ($o in $objects) { if ($null -ne $o) { $dialog = $o } }
    }
    catch {
        $em = $_.Exception.Message
        $dialog = Invoke-InModule { param($p2, $t2, $m2) New-TcModalScanIncomplete -ProcessId $p2 -Reason 'error' -TimeoutSec $t2 -Message $m2 } @($ideProcessId, $timeoutSec, "the scan threw: $em")
    }

    # #42: a scan that did not complete is NOT "no dialog": MODAL_SCAN_INCOMPLETE, scanComplete false.
    $incomplete = $false
    try { $incomplete = [bool](Invoke-InModule { param($d) Test-TcModalScanIncomplete $d } @(, $dialog)) } catch { $incomplete = $false }
    if ($incomplete) {
        $info = Invoke-InModule { param($d) ConvertTo-TcModalScanInfo -Scan $d } @(, $dialog)
        $hint = Invoke-InModule { Get-TcErrorHint -Code 'MODAL_SCAN_INCOMPLETE' } @()
        return New-ErrorResult -Code 'MODAL_SCAN_INCOMPLETE' -Hint $hint `
            -Message "MODAL_SCAN_INCOMPLETE: the modal-dialog scan of IDE pid $ideProcessId did not complete ($($info.reason): $($info.message)); it is unknown whether a dialog is open." `
            -Data ([ordered]@{ ideProcessId = [int]$ideProcessId; scanComplete = $false; dialog = $null; modalScan = $info })
    }

    $dialogOut = $null
    if ($null -ne $dialog) {
        # kind: 'reload-prompt' = VS "File has been changed outside the environment. Reload the new
        # file?" (reloadTarget 'file': a file open in an editor was changed on disk) or XAE "The
        # project file ... has been modified outside of TwinCAT XAE. Do you want to reload the
        # project?" (reloadTarget 'project': a .plcproj was rewritten) -> ResetSolution; else
        # 'unknown' (reloadTarget null). Classification is the module's (Add-TcDialogKind).
        $dialogOut = ConvertTo-BridgeDialog $dialog
    }
    return New-SuccessResult -Data ([ordered]@{ ideProcessId = [int]$ideProcessId; scanComplete = $true; dialog = $dialogOut })
}

function ConvertTo-BridgeDialog {
    # Module dialog record (@{ Title; Text; Kind; ReloadTarget; Hwnd; Buttons }, hashtable or
    # object) -> JSON shape {title, text, kind, reloadTarget, hwnd, buttons[{id, name}]}.
    # Kind / ReloadTarget are (re)derived by the module's Add-TcDialogKind when missing.
    param([object]$Dialog)
    $rec = $null
    try { $rec = Invoke-InModule { param($d) Add-TcDialogKind -Dialog $d } @(, $Dialog) } catch { $rec = $null }
    if ($null -eq $rec) {
        $title = $null; $text = $null; $kind = $null
        if ($Dialog -is [System.Collections.IDictionary]) { $title = $Dialog['Title']; $text = $Dialog['Text']; $kind = $Dialog['Kind'] }
        else { try { $title = $Dialog.Title; $text = $Dialog.Text; $kind = $Dialog.Kind } catch { } }
        if ([string]::IsNullOrWhiteSpace([string]$kind)) { $kind = 'unknown' }
        return [ordered]@{ title = [string]$title; text = [string]$text; kind = [string]$kind; reloadTarget = $null; hwnd = $null; buttons = @() }
    }
    $k = [string]$rec.Kind
    if ([string]::IsNullOrWhiteSpace($k)) { $k = 'unknown' }
    $target = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$rec.ReloadTarget)) { $target = [string]$rec.ReloadTarget }
    $hwndOut = $null
    try { $hv = [long]$rec.Hwnd; if ($hv -gt 0) { $hwndOut = $hv } } catch { $hwndOut = $null }
    $buttons = @()
    try { $buttons = @(Invoke-InModule { param($b) ConvertTo-TcDialogButtonList -Buttons $b } @(, @($rec.Buttons))) } catch { $buttons = @() }
    return [ordered]@{ title = [string]$rec.Title; text = [string]$rec.Text; kind = $k; reloadTarget = $target; hwnd = $hwndOut; buttons = $buttons }
}

function Get-RawRequestId {
    # Best-effort id recovery for lines ConvertFrom-Json rejects (e.g. PS 5.1 refuses
    # keys that differ only in case), so the caller can still match the error reply.
    # Returns a string for "id":"x", a number for "id":7, otherwise $null.
    param([string]$Line)
    $m = [regex]::Match($Line, '"id"\s*:\s*("([^"]*)"|(\d+))')
    if (-not $m.Success) { return $null }
    if ($m.Groups[2].Success) { return $m.Groups[2].Value }
    $n = [long]0
    if ([long]::TryParse($m.Groups[3].Value, [ref]$n)) { return $n }
    return $m.Groups[3].Value
}

function Invoke-OpState {
    $dte = Get-ModuleVar 'TcDte'
    $sysMan = Get-ModuleVar 'TcSysManager'
    $pidVal = Get-ModuleVar 'TcIdeProcessId'
    $adsConnected = [bool](Get-ModuleVar 'TcAdsConnected')
    $amsNetId = Get-ModuleVar 'TcAdsAmsNetId'
    $adsPort = Get-ModuleVar 'TcAdsPort'
    $lastDialog = Get-ModuleVar 'TcLastModalDialog'
    $mainHwndVal = Get-ModuleVar 'TcIdeMainHwnd'

    $ideMainHwnd = $null
    if ($null -ne $mainHwndVal) { try { $h = [long]$mainHwndVal; if ($h -gt 0) { $ideMainHwnd = $h } } catch { $ideMainHwnd = $null } }

    $ideProcessId = $null
    if ($null -ne $pidVal) { try { $ideProcessId = [int]$pidVal } catch { $ideProcessId = $null } }

    $portOut = $null
    if ($null -ne $adsPort) { try { if ([int]$adsPort -gt 0) { $portOut = [int]$adsPort } } catch { } }

    $amsOut = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$amsNetId)) { $amsOut = [string]$amsNetId }

    $dialogOut = $null
    if ($null -ne $lastDialog) { $dialogOut = ConvertTo-BridgeDialog $lastDialog }

    return New-SuccessResult -Data ([ordered]@{
        ideConnected        = ($null -ne $dte)
        ideProcessId        = $ideProcessId
        ideMainHwnd         = $ideMainHwnd
        sysManagerAvailable = ($null -ne $sysMan)
        adsConnected        = $adsConnected
        amsNetId            = $amsOut
        adsPort             = $portOut
        lastModalDialog     = $dialogOut
    })
}

function Invoke-OpTargetKind {
    # #307 (GetStatus data.targetKind): kind of a target AmsNetId through the module's
    # Get-TcTargetKind. params.AmsNetId wins; else the ADS NetId of the session, else the IDE
    # target recorded by Connect-TcIde / Set-TcTarget. Never fails: no NetId gives 'unknown'.
    param($Request)
    $id = $null
    $pp = $Request.PSObject.Properties['params']
    if ($null -ne $pp -and $null -ne $pp.Value -and ($pp.Value -is [System.Management.Automation.PSCustomObject])) {
        $a = $pp.Value.PSObject.Properties['AmsNetId']
        if ($null -ne $a -and -not [string]::IsNullOrWhiteSpace([string]$a.Value)) { $id = [string]$a.Value }
    }
    if ($null -eq $id) {
        $ads = Get-ModuleVar 'TcAdsAmsNetId'
        if (-not [string]::IsNullOrWhiteSpace([string]$ads)) { $id = [string]$ads }
    }
    if ($null -eq $id) {
        $ide = $null
        try { $ide = Invoke-InModule { Resolve-TcLifecycleIdeNetId } } catch { $ide = $null }
        if (-not [string]::IsNullOrWhiteSpace([string]$ide)) { $id = [string]$ide }
    }
    # A module without Get-TcTargetKind (older than #307, loaded by ReloadModule) -> 'unknown'.
    $kind = 'unknown'; $source = 'match-failed'
    try {
        $k = Invoke-InModule { param($n) Get-TcTargetKind -AmsNetId $n } @([string]$id)
        if ($null -ne $k -and -not [string]::IsNullOrWhiteSpace([string]$k.targetKind)) { $kind = [string]$k.targetKind; $source = [string]$k.targetKindSource }
    }
    catch { Write-Stderr "[bridge] targetkind: $($_.Exception.Message)" }
    return New-SuccessResult -Data ([ordered]@{
        amsNetId         = $id
        targetKind       = $kind
        targetKindSource = $source
    })
}

function Get-BridgeModuleVariable {
    # @{ Exists; Value } of a $script: variable of the module. Unlike Get-ModuleVar this tells
    # "not defined" apart from "defined as $null" (#41 review: a missing variable must fail closed).
    param([string]$Name)
    Invoke-InModule {
        param($n)
        $v = Get-Variable -Name $n -Scope Script -ErrorAction SilentlyContinue
        if ($null -eq $v) { return @{ Exists = $false; Value = $null } }
        return @{ Exists = $true; Value = $v.Value }
    } @($Name)
}

function Get-BridgeLocalLifecycleBlocks {
    # #41 / #68: the lifecycle block records the module holds in memory ($script:TcLifecycleBlockLocal,
    # Private/LifecycleBlock.ps1). A record there may exist in memory only (the state file could not be
    # written), so a new Import-Module / bridge process would not see it. Returns @{ Readable; List }
    # (List = [{ key; record }]). The check itself is the module's private
    # Get-TcLifecycleBlockLocalForReload; since #130 it runs the cross-bridge sync first, which only
    # removes records whose Clear receipt is bound to them (#113), so the rest still refuse.
    # A module older than #41 has no such function: then $script:TcLifecycleBlockLocal itself is read
    # (every module since #68 defines it), so a session can reload into an older sha AND out of it.
    # Neither the function nor the variable, a value that is not a hashtable, or an exception counts
    # as a block (fail closed).
    $list = New-Object System.Collections.ArrayList
    try {
        $has = Invoke-InModule { [bool](Get-Command -Name 'Get-TcLifecycleBlockLocalForReload' -CommandType Function -ErrorAction SilentlyContinue) }
        if (-not $has) {
            $var = Get-BridgeModuleVariable 'TcLifecycleBlockLocal'
            if (-not $var.Exists) {
                $null = $list.Add([ordered]@{ key = '<missing>'; record = 'the loaded module has neither Get-TcLifecycleBlockLocalForReload nor $script:TcLifecycleBlockLocal (older than #68), so its in-memory lifecycle blocks cannot be checked; ask the user before restarting the MCP server, which drops the in-memory state' })
                return @{ Readable = $false; List = [object[]]$list.ToArray() }
            }
            $local = $var.Value
            if (-not ($local -is [System.Collections.IDictionary])) {
                $t = if ($null -eq $local) { 'null' } else { $local.GetType().FullName }
                $null = $list.Add([ordered]@{ key = '<unreadable>'; record = "unexpected value of `$script:TcLifecycleBlockLocal ($t)" })
                return @{ Readable = $false; List = [object[]]$list.ToArray() }
            }
            foreach ($k in @($local.Keys | Sort-Object)) { $null = $list.Add([ordered]@{ key = [string]$k; record = $local[$k] }) }
            return @{ Readable = $true; List = [object[]]$list.ToArray() }
        }
        $r = Invoke-InModule { Get-TcLifecycleBlockLocalForReload }
        if ($null -eq $r -or -not ($r -is [System.Collections.IDictionary]) -or -not $r.Contains('List')) { throw 'Get-TcLifecycleBlockLocalForReload returned no list' }
        foreach ($e in @($r['List'])) { $null = $list.Add([ordered]@{ key = [string]$e['key']; record = $e['record'] }) }
        return @{ Readable = $true; List = [object[]]$list.ToArray() }
    }
    catch {
        $null = $list.Add([ordered]@{ key = '<unreadable>'; record = "the in-memory lifecycle block state could not be read: $($_.Exception.Message)" })
        return @{ Readable = $false; List = [object[]]$list.ToArray() }
    }
}

function Save-BridgeBuildRequiredFallback {
    # #41 review round 2: a module without one of the helpers Save-BridgeLocalBuildRequired uses
    # (Merge-TcBuildRequiredEntry & co.) still has $script:TcBuildRequiredLocal. The bridge then adds
    # every in-memory entry whose key is MISSING from build-required.json, unchanged, under the same
    # mutex (name from the module's Get-TcBuildRequiredMutexName). A key already in the file is left
    # alone: any entry blocks its solution, and without the module's merge rule the bridge must not
    # rewrite one. No mutex name, lock not acquired, file not readable / writable -> refused.
    param($Local, [string[]]$Keys, [string]$Missing)
    $fail = { param($why) @{ Ok = $false; Error = "the loaded module has no $Missing; $why"; Keys = $Keys; Persisted = [string[]]@() } }
    $dir = $env:TCAUTO_STATE_DIR
    if ([string]::IsNullOrWhiteSpace($dir)) {
        if ($env:TCAUTO_TEST_FORBID_REAL_STATE -eq '1') { return (& $fail 'the real state directory is refused (TCAUTO_TEST_FORBID_REAL_STATE=1, #118)') }
        $dir = Join-Path ([IO.Path]::GetTempPath()) 'TwinCATAutomation'
    }
    $mutexName = $null
    try { $mutexName = [string](Invoke-InModule { if (Get-Command -Name 'Get-TcBuildRequiredMutexName' -CommandType Function -ErrorAction SilentlyContinue) { Get-TcBuildRequiredMutexName } }) } catch { $mutexName = $null }
    if ([string]::IsNullOrWhiteSpace($mutexName)) { return (& $fail 'its Get-TcBuildRequiredMutexName is missing too, so build-required.json cannot be updated under its lock') }
    $file = Join-Path $dir 'build-required.json'
    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    $got = $false
    $tmp = $null
    try {
        try { $got = $mutex.WaitOne(3000) } catch [System.Threading.AbandonedMutexException] { $got = $true }
        if (-not $got) { return (& $fail 'lock not acquired within 3000 ms') }
        $doc = [ordered]@{}
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            $text = [IO.File]::ReadAllText($file)
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $obj = ConvertFrom-Json -InputObject $text -ErrorAction Stop
                if (-not ($obj -is [System.Management.Automation.PSCustomObject])) { throw "$file is not a JSON object" }
                foreach ($p in $obj.PSObject.Properties) { $doc[$p.Name] = $p.Value }
            }
        }
        elseif (Test-Path -LiteralPath $file) { throw "$file is not a file" }
        $written = New-Object System.Collections.ArrayList
        foreach ($k in $Keys) {
            if (-not $doc.Contains($k)) { $doc[$k] = $Local[$k]; $null = $written.Add($k) }
        }
        if ($written.Count -gt 0) {
            if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
            $tmp = "$file.$PID.tmp"
            [IO.File]::WriteAllText($tmp, ([PSCustomObject]$doc | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
            if (Test-Path -LiteralPath $file) { [IO.File]::Replace($tmp, $file, [NullString]::Value) } else { [IO.File]::Move($tmp, $file) }
        }
        return @{ Ok = $true; Error = $null; Keys = $Keys; Persisted = [string[]]$written.ToArray(); Fallback = $true }
    }
    catch {
        try { if ($tmp -and (Test-Path -LiteralPath $tmp)) { [IO.File]::Delete($tmp) } } catch { }
        return (& $fail "build-required.json could not be updated: $($_.Exception.Message)")
    }
    finally {
        if ($got) { try { $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
    }
}

function Save-BridgeLocalBuildRequired {
    # #41 review: $script:TcBuildRequiredLocal (Private/Set-TcBuildRequired.ps1) holds every
    # BUILD_REQUIRED entry this module instance recorded, also one that never reached
    # build-required.json (the file could not be written). A reload would drop it and open the build
    # gate. So, under the state file's mutex, every in-memory entry is merged into the file
    # (Merge-TcBuildRequiredEntry, the module's own rule) and the file is written when an entry is
    # missing there or differs in solution / reasons / build-selection guard. Returns
    # @{ Ok; Error; Keys; Persisted }; Ok = $false (variable missing, functions missing, lock not
    # acquired, file not readable / writable) refuses the reload.
    try {
        $var = Get-BridgeModuleVariable 'TcBuildRequiredLocal'
        if (-not $var.Exists) {
            return @{ Ok = $false; Error = 'the loaded module does not define $script:TcBuildRequiredLocal, so its in-memory BUILD_REQUIRED entries cannot be checked'; Keys = [string[]]@(); Persisted = [string[]]@() }
        }
        $local = $var.Value
        if (-not ($local -is [System.Collections.IDictionary])) {
            $t = if ($null -eq $local) { 'null' } else { $local.GetType().FullName }
            return @{ Ok = $false; Error = "unexpected value of `$script:TcBuildRequiredLocal ($t)"; Keys = [string[]]@(); Persisted = [string[]]@() }
        }
        $keys = [string[]]@($local.Keys | ForEach-Object { [string]$_ } | Sort-Object)
        if ($keys.Count -eq 0) { return @{ Ok = $true; Error = $null; Keys = $keys; Persisted = [string[]]@() } }
        $r = Invoke-InModule {
            param($localEntries, $localKeys)
            foreach ($fn in @('Invoke-TcBuildRequiredLocked', 'Read-TcBuildRequiredState', 'Write-TcBuildRequiredState', 'Merge-TcBuildRequiredEntry', 'Get-TcBuildRequiredReasons', 'Get-TcEntryGuard')) {
                if ($null -eq (Get-Command -Name $fn -CommandType Function -ErrorAction SilentlyContinue)) {
                    return @{ Fallback = $true; Missing = $fn }
                }
            }
            $signature = {
                param($e)
                if ($null -eq $e) { return '' }
                $m = Get-TcBuildRequiredReasons $e
                $parts = @(@($m.Keys) | Sort-Object | ForEach-Object { "$_=$($m[$_])" })
                $g = Get-TcEntryGuard $e
                $gs = if ($null -ne $g) { ConvertTo-Json -InputObject $g -Depth 6 -Compress } else { '' }
                "$([string]$e.solution)`n$($parts -join "`n")`n$gs"
            }
            Invoke-TcBuildRequiredLocked -Body {
                $st = Read-TcBuildRequiredState
                $written = New-Object System.Collections.ArrayList
                foreach ($k in $localKeys) {
                    $old = $st.Entries[$k]
                    $merged = Merge-TcBuildRequiredEntry -Older $old -Newer $localEntries[$k]
                    if ($null -eq $old -or (& $signature $old) -ne (& $signature $merged)) {
                        $st.Entries[$k] = $merged
                        $null = $written.Add($k)
                    }
                }
                if ($written.Count -gt 0) { Write-TcBuildRequiredState -Entries $st.Entries }
                , ([string[]]$written.ToArray())
            }
        } @($local, $keys)
        if ($null -ne $r -and $r.Contains('Fallback')) {
            return Save-BridgeBuildRequiredFallback -Local $local -Keys $keys -Missing ([string]$r.Missing)
        }
        if ($null -eq $r -or -not $r.Locked -or $null -ne $r.Error) {
            $why = if ($null -ne $r -and $null -ne $r.Error) { [string]$r.Error } else { 'lock not acquired' }
            return @{ Ok = $false; Error = $why; Keys = $keys; Persisted = [string[]]@() }
        }
        return @{ Ok = $true; Error = $null; Keys = $keys; Persisted = [string[]]@($r.Result) }
    }
    catch {
        return @{ Ok = $false; Error = $_.Exception.Message; Keys = [string[]]@(); Persisted = [string[]]@() }
    }
}

function Invoke-OpRetire {
    # #41 ReloadModule, step 1 of 2. Refused while the module holds a lifecycle block in memory (a
    # reload must never become a way around #68) or while its in-memory BUILD_REQUIRED entries cannot
    # be written to build-required.json (Save-BridgeLocalBuildRequired; a reload must not open the
    # build gate either). Otherwise ADS and the IDE COM references are released (Disconnect-TcAds /
    # Disconnect-TcIde without -Quit: the IDE keeps running) and the main loop exits after the reply.
    # The Node side then starts a new bridge process with the new -ModulePath.
    $blocks = Get-BridgeLocalLifecycleBlocks
    $modulePathNow = [string]$script:Module.Path
    if ($blocks.List.Count -gt 0) {
        return New-ErrorResult -Code 'RELOAD_LIFECYCLE_BLOCKED' `
            -Message "ReloadModule NOT RUN: the loaded module holds $($blocks.List.Count) lifecycle block record(s) in memory or its in-memory lifecycle state cannot be checked (#68); a reload would drop the in-memory copy. Nothing was disconnected or reloaded." `
            -Hint 'Stop and report data.lifecycleBlocks to the user. The block is cleared only with ClearLifecycleBlock after the user agreed; then run ReloadModule again. Do not restart the server or the bridge to get around it.' `
            -Data ([ordered]@{ modulePath = $modulePathNow; lifecycleBlocks = $blocks.List; readable = $blocks.Readable; notRun = $true })
    }
    $build = Save-BridgeLocalBuildRequired
    if (-not $build.Ok) {
        return New-ErrorResult -Code 'RELOAD_BUILD_REQUIRED' `
            -Message "ReloadModule NOT RUN: the in-memory BUILD_REQUIRED entries of the loaded module could not be written to build-required.json ($($build.Error)); a reload would drop them and skip the build check. Nothing was disconnected or reloaded." `
            -Hint 'Run BuildProject until it returns data.completeBuild=true (that removes the entries), or make the state directory writable again, then ReloadModule again. Do not restart the server or the bridge to get around it.' `
            -Data ([ordered]@{ modulePath = $modulePathNow; buildRequiredKeys = $build.Keys; error = $build.Error; notRun = $true })
    }
    $ideWas = $false; $adsWas = $false
    try { $ideWas = ($null -ne (Get-ModuleVar 'TcDte')) } catch { }
    try { $adsWas = [bool](Get-ModuleVar 'TcAdsConnected') } catch { }
    Invoke-BridgeCleanup
    return New-SuccessResult -Data ([ordered]@{
        retired                = $true
        modulePath             = $modulePathNow
        ideWasConnected        = $ideWas
        adsWasConnected        = $adsWas
        buildRequiredKeys      = $build.Keys
        buildRequiredPersisted = $build.Persisted
    })
}

function Invoke-BridgeCleanup {
    # Best effort: drop the ADS client and release COM references. Never throws,
    # never writes to stdout.
    try { $null = @(Disconnect-TcAds 3>$null 4>$null 5>$null 6>$null) } catch { }
    try { $null = @(Disconnect-TcIde 3>$null 4>$null 5>$null 6>$null) } catch { }
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
$exitCode = 0
while ($null -ne ($line = [Console]::In.ReadLine())) {
    # A UTF-8 BOM can precede the first line when stdin comes from a PowerShell pipe.
    $line = $line.Trim([char]0xFEFF)
    if ([string]::IsNullOrWhiteSpace($line)) { continue }

    $request = $null
    try {
        $request = ConvertFrom-Json -InputObject $line
    }
    catch {
        Write-Result -Id (Get-RawRequestId $line) -Result (New-ErrorResult -Code 'INVALID_REQUEST' -Message "Request line is not valid JSON: $($_.Exception.Message)")
        continue
    }
    if ($null -eq $request -or -not ($request -is [System.Management.Automation.PSCustomObject])) {
        Write-Result -Id (Get-RawRequestId $line) -Result (New-ErrorResult -Code 'INVALID_REQUEST' -Message 'Request must be a JSON object.')
        continue
    }

    $id = $null
    $idProp = $request.PSObject.Properties['id']
    if ($null -ne $idProp) { $id = $idProp.Value }

    $op = 'call'
    $opProp = $request.PSObject.Properties['op']
    if ($null -ne $opProp -and -not [string]::IsNullOrWhiteSpace([string]$opProp.Value)) { $op = [string]$opProp.Value }

    $shutdown = $false
    try {
        switch ($op.ToLowerInvariant()) {
            'call' {
                Write-Result -Id $id -Result (Invoke-OpCall -Id $id -Request $request)
            }
            'modal' {
                Write-Result -Id $id -Result (Invoke-OpModal -Id $id -Request $request)
            }
            'state' {
                Write-Result -Id $id -Result (Invoke-OpState)
            }
            'targetkind' {
                Write-Result -Id $id -Result (Invoke-OpTargetKind -Request $request)
            }
            'ping' {
                Write-Result -Id $id -Result (New-SuccessResult -Data ([ordered]@{ pong = $true }))
            }
            'retire' {
                $retire = Invoke-OpRetire
                Write-Result -Id $id -Result $retire
                if ($retire.success -eq $true) { $shutdown = $true }
            }
            'shutdown' {
                Invoke-BridgeCleanup
                Write-Result -Id $id -Result ([PSCustomObject]@{ success = $true })
                $shutdown = $true
            }
            default {
                Write-Result -Id $id -Result (New-ErrorResult -Code 'INVALID_REQUEST' -Message "Unknown op '$op'." -Hint 'Valid ops: call, modal, state, targetkind, ping, retire, shutdown.')
            }
        }
    }
    catch {
        $msg = $_.Exception.Message
        Write-Stderr "[bridge] INTERNAL_ERROR on op '$op' id '$id': $msg`n$($_.ScriptStackTrace)"
        try {
            Write-Result -Id $id -Result (New-ErrorResult -Code 'INTERNAL_ERROR' -Message "Bridge handler failed: $msg")
        }
        catch { }
    }

    if ($shutdown) { break }
}

# stdin closed without shutdown: release what we hold and exit cleanly.
if (-not $shutdown) { Invoke-BridgeCleanup }
exit $exitCode
