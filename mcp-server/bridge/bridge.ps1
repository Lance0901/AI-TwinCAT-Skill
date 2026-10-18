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

$script:KnownCodePattern = '^(IDE_BUSY|IDE_TIMEOUT|IDE_MODAL_DIALOG|NOT_CONNECTED|ADS_[A-Z_]+)\b'
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

    $objects = Invoke-Captured -Id $Id -Script {
        param($p, $t)
        Invoke-InModule { param($p2, $t2) Get-TcIdeModalDialog -ProcessId $p2 -TimeoutSec $t2 } @($p, $t)
    } -ArgumentList @($ideProcessId, $timeoutSec)
    $dialog = $null
    foreach ($o in $objects) { if ($null -ne $o) { $dialog = $o } }

    $dialogOut = $null
    if ($null -ne $dialog) {
        $title = $null; $text = $null
        if ($dialog -is [System.Collections.IDictionary]) { $title = $dialog['Title']; $text = $dialog['Text'] }
        else { $title = $dialog.Title; $text = $dialog.Text }
        $dialogOut = [ordered]@{ title = [string]$title; text = [string]$text }
    }
    return New-SuccessResult -Data ([ordered]@{ ideProcessId = [int]$ideProcessId; dialog = $dialogOut })
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

    $ideProcessId = $null
    if ($null -ne $pidVal) { try { $ideProcessId = [int]$pidVal } catch { $ideProcessId = $null } }

    $portOut = $null
    if ($null -ne $adsPort) { try { if ([int]$adsPort -gt 0) { $portOut = [int]$adsPort } } catch { } }

    $amsOut = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$amsNetId)) { $amsOut = [string]$amsNetId }

    $dialogOut = $null
    if ($null -ne $lastDialog) {
        if ($lastDialog -is [System.Collections.IDictionary]) {
            $dialogOut = [ordered]@{ title = [string]$lastDialog['Title']; text = [string]$lastDialog['Text'] }
        }
        else {
            $dialogOut = [ordered]@{ title = [string]$lastDialog.Title; text = [string]$lastDialog.Text }
        }
    }

    return New-SuccessResult -Data ([ordered]@{
        ideConnected        = ($null -ne $dte)
        ideProcessId        = $ideProcessId
        sysManagerAvailable = ($null -ne $sysMan)
        adsConnected        = $adsConnected
        amsNetId            = $amsOut
        adsPort             = $portOut
        lastModalDialog     = $dialogOut
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
            'ping' {
                Write-Result -Id $id -Result (New-SuccessResult -Data ([ordered]@{ pong = $true }))
            }
            'shutdown' {
                Invoke-BridgeCleanup
                Write-Result -Id $id -Result ([PSCustomObject]@{ success = $true })
                $shutdown = $true
            }
            default {
                Write-Result -Id $id -Result (New-ErrorResult -Code 'INVALID_REQUEST' -Message "Unknown op '$op'." -Hint 'Valid ops: call, modal, state, ping, shutdown.')
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
