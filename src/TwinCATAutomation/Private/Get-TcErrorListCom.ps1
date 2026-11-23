# Error List via COM (DTE2.ToolWindows.ErrorList.ErrorItems), the primary source of Get-TcBuildErrors
# (item 88, re #320 / #329 / #300). The UI Automation scan (Get-TcIdeErrorList.ps1) is the fallback.
#
# What was measured (2026-11-23, G16 report item88, VS2022 4026 zh-TW, XAE 64-bit 4026, XAE 32-bit TcXaeShell 15.0):
#  - early binding (C#, ErrorListComReader.cs) reads the full list in the IDE's own process space of the call,
#    same row counts as the UIA scan, no Error List window shown, no foreground change; 529 rows 0.96 s.
#    PowerShell late binding reads a fake 0 (that was the old "ErrorItems is always 0").
#  - ErrorItems follows the Errors / Warnings / Messages buttons (ShowErrors / ShowWarnings / ShowMessages) and the
#    scope filter. The scope is NOT a property of the COM object, but the Error List window caption carries it:
#    'Error List' / 'Error List - Current Project (<proj>)' / '... - Current Document' / '... - Open Documents'
#    (zh-TW: the localized title + the same suffix). Entire Solution = the bare caption. A filtered scope answers 0 or a few
#    rows WITHOUT an error, so a partial scope must never be read as "no errors" (fail closed: UIA fallback).
#  - ErrorLevel: 4026 (DTE 17.0) is 2 for errors, warnings and messages alike (1 only for 'Related position' rows),
#    so it cannot give the severity there; 4024 (TcXaeShell 15.0, DTE 15.0): error 4 / warning 2 / message 1.
#    Observation only, no InfoSys source (vsBuildErrorLevel documents High 1 / Medium 2 / Low 3, not these values):
#    marked 實測 2026-11-23.
#  - Description has no compiler code; FileName is the full path + ' (Impl)' / ' (Decl)' (4026) or the full path (4024);
#    Project is the .plcproj path relative to the solution; Column is always 1; Line like the UIA scan.
#  - The first access to ToolWindows.ErrorList creates the Error List when it never existed (XAE 64-bit: an auto-hidden
#    tab appears at the bottom, the panel stays collapsed, no foreground change).

# vsBuildErrorLevel values per IDE host (key = DTE.Version major). 15 = TcXaeShell 15.0 (VS2017 shell); 17.x maps nothing.
$script:TcErrorLevelSeverityByDteMajor = @{
    15 = @{ 4 = 'Error'; 2 = 'Warning'; 1 = 'Message' }
}

# Scope part of the Error List window caption (Window.Caption). Entire Solution = the bare window title.
# '錯誤清單' = the zh-TW title (kept as escapes: this file is ASCII).
$script:TcErrorListEntireCaptionPattern = '^(Error List|錯誤清單)$'
$script:TcErrorListScopeCaptionPattern = '^(Error List|錯誤清單)\s+-\s+(?<scope>.+)$'

# Per process: $null (not tried) or @{ ok; reason }
$script:TcErrorListComTypeState = $null
$script:TcErrorListComDefaultMaxMs = 10000
$script:TcErrorListComSettleMs = 150

function ConvertFrom-TcErrorListScopeCaption {
    <#
    .SYNOPSIS
        { kind = 'entire' | 'partial' | 'unknown'; scope } of an Error List window caption.
    .DESCRIPTION
        entire   the bare title ('Error List' / zh-TW title): scope Entire Solution
        partial  '<title> - <scope>' ('Current Project (X)', 'Current Document', 'Open Documents', ...): the list is filtered
        unknown  no caption, or a title this module does not know (other UI language): not provably the entire solution
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$Caption)
    if ([string]::IsNullOrWhiteSpace($Caption)) { return [PSCustomObject]@{ kind = 'unknown'; scope = $null } }
    $c = $Caption.Trim()
    if ($c -match $script:TcErrorListEntireCaptionPattern) { return [PSCustomObject]@{ kind = 'entire'; scope = $null } }
    if ($c -match $script:TcErrorListScopeCaptionPattern) { return [PSCustomObject]@{ kind = 'partial'; scope = [string]$Matches['scope'] } }
    return [PSCustomObject]@{ kind = 'unknown'; scope = $null }
}

function ConvertFrom-TcErrorLevel {
    <#
    .SYNOPSIS
        'Error' / 'Warning' / 'Message' for an ErrorItem.ErrorLevel of the given IDE host, or $null when the host's
        levels do not tell the severity (4026: every row is 2) or the value is not a known one.
    .PARAMETER DteMajor
        Major of DTE.Version (15 = TcXaeShell 15.0 / 4024, 17 = VS2022 and the 64-bit XAE of 4026); $null = unknown host.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Level, [AllowNull()][object]$DteMajor)
    if ($null -eq $DteMajor) { return $null }
    $map = $script:TcErrorLevelSeverityByDteMajor[[int]$DteMajor]
    if ($null -eq $map) { return $null }
    if (-not $map.ContainsKey($Level)) { return $null }
    return [string]$map[$Level]
}

function ConvertTo-TcErrorListComFile {
    <#
    .SYNOPSIS
        UIA-compatible 'file' of an ErrorItem.FileName: the base name, the ' (Impl)' / ' (Decl)' suffix and an
        '@<member>' part kept as the UIA grid shows them ('Main.TcPOU (Impl)', 'FB_X.TcPOU@Method (Impl)', 4024: 'MAIN.TcPOU').
        filePath = the full path without the suffix. Both $null for an empty name.
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$FileName)
    if ([string]::IsNullOrWhiteSpace($FileName)) { return [PSCustomObject]@{ file = $null; filePath = $null; part = $null } }
    $t = $FileName.Trim()
    $part = $null
    if ($t -match '^(?<name>.*?)\s+\((?<part>Impl|Decl)\)$') { $t = $Matches['name']; $part = $Matches['part'] }
    $slash = [Math]::Max($t.LastIndexOf('\'), $t.LastIndexOf('/'))
    $base = if ($slash -ge 0) { $t.Substring($slash + 1) } else { $t }
    $file = if ($null -ne $part) { "$base ($part)" } else { $base }
    return [PSCustomObject]@{ file = $file; filePath = $t; part = $part }
}

function ConvertTo-TcErrorListComProject {
    <#
    .SYNOPSIS
        UIA-compatible 'project' of an ErrorItem.Project: the project file name without extension
        ('AxisInterface_Type01_Library\AxisInterface\AxisInterface.plcproj' -> 'AxisInterface'), $null when empty.
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$Project)
    if ([string]::IsNullOrWhiteSpace($Project)) { return $null }
    $t = $Project.Trim()
    $slash = [Math]::Max($t.LastIndexOf('\'), $t.LastIndexOf('/'))
    $leaf = if ($slash -ge 0) { $t.Substring($slash + 1) } else { $t }
    if ($leaf -match '^(?<n>.+)\.(plcproj|tsproj|tmcproj|sln)$') { return [string]$Matches['n'] }
    return $leaf
}

function ConvertTo-TcErrorListComItem {
    <#
    .SYNOPSIS
        One COM row -> the public item shape of Get-TcBuildErrors (severity, code, description, project, file, line,
        column) plus filePath. code is $null (Resolve-TcErrorItemCode fills it from the build pane); column is $null
        like the UIA scan (the COM column is a constant 1).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Row, [Parameter(Mandatory)][string]$Severity)
    $f = ConvertTo-TcErrorListComFile -FileName ([string]$Row.FileName)
    [PSCustomObject]@{
        severity    = $Severity
        code        = $null
        description = [string]$Row.Description
        project     = ConvertTo-TcErrorListComProject -Project ([string]$Row.Project)
        file        = $f.file
        line        = [int]$Row.Line
        column      = $null
        filePath    = $f.filePath
    }
}

function ConvertFrom-TcBuildPaneDiagnostics {
    <#
    .SYNOPSIS
        The compiler lines of the build pane text as { severity ('Error'|'Warning'), file, line, code, text }.
    .DESCRIPTION
        Line forms (Get-TcBuildWarningLines): '<file>(<line>) : error: C0046: <text>' (TwinCAT PLC compiler) and
        '<file>(<line>,<col>): error C0046: <text>' (MSBuild); the code (Cxxxx / SAxxxx) is optional. The pane line
        number is NOT the Error List line on 4026 (whole object file vs. line inside the Impl section, measured
        2026-11-23: 209-211 vs 45-47), so callers match on file + text and use the line only to choose between equals.
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$Text)
    $out = [System.Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrWhiteSpace($Text)) { return , $out.ToArray() }
    $rx = [regex]'(?i)^\s*(?<file>.+?)\((?<line>\d+)(?:,\d+)?\)\s*:\s*(?<sev>error|warning)\b\s*:?\s*(?:(?<code>[A-Za-z]{1,3}\d{3,5})\b\s*:?\s*)?(?<text>.*?)\s*$'
    foreach ($ln in ($Text -split "`n")) {
        $l = $ln.TrimEnd("`r")
        if ($l.Trim() -eq '') { continue }
        $m = $rx.Match($l)
        if (-not $m.Success) { continue }
        $out.Add([PSCustomObject]@{
                severity = $(if ($m.Groups['sev'].Value -ieq 'error') { 'Error' } else { 'Warning' })
                file     = $m.Groups['file'].Value.Trim()
                line     = [int]$m.Groups['line'].Value
                code     = $(if ($m.Groups['code'].Success) { $m.Groups['code'].Value.ToUpperInvariant() } else { $null })
                text     = $m.Groups['text'].Value
            })
    }
    return , $out.ToArray()
}

function Get-TcErrorListFileKey {
    # base name of a file column / pane file without ' (Impl)' / ' (Decl)' and without '@<member>', lower case
    param([AllowNull()][string]$File)
    if ([string]::IsNullOrWhiteSpace($File)) { return '' }
    $t = $File.Trim() -replace '\s+\((Impl|Decl)\)$', ''
    $slash = [Math]::Max($t.LastIndexOf('\'), $t.LastIndexOf('/'))
    if ($slash -ge 0) { $t = $t.Substring($slash + 1) }
    $at = $t.IndexOf('@')
    if ($at -ge 0) { $t = $t.Substring(0, $at) }
    return $t.ToLowerInvariant()
}

function Resolve-TcErrorItemCode {
    <#
    .SYNOPSIS
        The compiler code (Cxxxx / SAxxxx) of one COM item from the build pane lines, or $null when it cannot be
        told (no matching line, or matching lines with different codes).
    .DESCRIPTION
        Candidates = pane lines of the same severity, same file (base name) and the same text. Several candidates:
        those with the same line number win; the result is the code only when the remaining candidates agree on one.
        Never inferred from the description text (the old UIA inference stays in the UIA path only).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Item, [AllowNull()][object[]]$PaneLines)
    $lines = @($PaneLines | Where-Object { $null -ne $_ })
    if ($lines.Count -eq 0) { return $null }
    $key = Get-TcErrorListFileKey -File ([string]$Item.file)
    if ($key -eq '') { return $null }
    $cand = @($lines | Where-Object {
            $_.severity -eq [string]$Item.severity -and (Get-TcErrorListFileKey -File ([string]$_.file)) -eq $key -and
            ([string]$_.text).Trim() -ceq ([string]$Item.description).Trim()
        })
    if ($cand.Count -eq 0) { return $null }
    $sameLine = @($cand | Where-Object { [int]$_.line -eq [int]$Item.line })
    if ($sameLine.Count -gt 0) { $cand = $sameLine }
    $codes = @($cand | ForEach-Object { $_.code } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
    if ($codes.Count -eq 1 -and @($cand | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.code) }).Count -eq 0) { return [string]$codes[0] }
    return $null
}

function Get-TcErrorListComVerdict {
    <#
    .SYNOPSIS
        Decides whether a COM read may stand for the whole Error List: { accept; reason; notes }.
        Fail closed: anything that cannot be proven falls back to the UIA scan (the result carries the reason).
    .DESCRIPTION
        A COM read is rejected when
          - it failed (reason com-read-failed:<why>) or its flags could not be set (inside com-read-failed)
          - the Error List scope is not provably Entire Solution (scope-not-entire / scope-unknown): the list is filtered
            and a filtered list answers 0 rows without an error
          - isolation (severity by one Show* flag at a time) does not add up: sum of the three reads != all-flags count
          - the host reads severity by ErrorLevel (DTE 15) and a row has a level this module does not know
          - the caller knows the build / check failed (-ExpectErrors) and no error row was read
          - the fresh build pane (-PaneLines of THIS build) lists more error lines than error rows were read
        Not a reason: a row count of 0 on its own (a clean build can have an empty list) - the scope check above is what
        tells an empty list from a hidden one.
    .PARAMETER Com
        Read-TcErrorListCom result: ok, reason, caption, isolated, allCount, flagsRestored.
    .PARAMETER ErrorRows
        Number of rows classified as Error.
    .PARAMETER UnmappedRows
        Rows whose ErrorLevel could not be mapped (level mode).
    .PARAMETER IsolatedTotal
        Sum of the three isolated reads (isolation mode).
    .PARAMETER ExpectErrors
        The caller knows at least one error exists (LastBuildInfo > 0, CheckAllObjects False).
    .PARAMETER PaneLines
        ConvertFrom-TcBuildPaneDiagnostics of a pane that belongs to THIS build, or $null (no cross-check).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Com,
        [int]$ErrorRows = 0,
        [int]$UnmappedRows = 0,
        [int]$IsolatedTotal = 0,
        [switch]$ExpectErrors,
        [AllowNull()][object[]]$PaneLines = $null
    )
    $notes = [System.Collections.Generic.List[string]]::new()
    $verdict = { param([bool]$Accept, [string]$Reason) [PSCustomObject]@{ accept = $Accept; reason = $Reason; notes = $notes.ToArray() } }
    if (-not [bool]$Com.ok) {
        $why = [string]$Com.reason
        if (-not [string]::IsNullOrWhiteSpace([string]$Com.error)) { $why += ": $([string]$Com.error)" }
        return (& $verdict $false "com-read-failed:$why")
    }
    $scope = ConvertFrom-TcErrorListScopeCaption -Caption ([string]$Com.caption)
    if ($scope.kind -eq 'partial') { return (& $verdict $false "scope-not-entire: the Error List caption is '$([string]$Com.caption)' (scope '$($scope.scope)'), the list is filtered") }
    if ($scope.kind -eq 'unknown') { return (& $verdict $false "scope-unknown: the Error List caption '$([string]$Com.caption)' is not a known Entire Solution caption") }
    if ([bool]$Com.isolated) {
        if ($IsolatedTotal -ne [int]$Com.allCount) {
            return (& $verdict $false "severity-isolation-mismatch: errors+warnings+messages read one flag at a time = $IsolatedTotal, all flags on = $([int]$Com.allCount)")
        }
    }
    elseif ($UnmappedRows -gt 0) {
        return (& $verdict $false "error-level-unmapped: $UnmappedRows row(s) have an ErrorLevel this host's mapping does not know")
    }
    if ($ExpectErrors -and $ErrorRows -eq 0) {
        return (& $verdict $false 'expected-errors-none-read: the build / check failed but the COM list has no error row')
    }
    if ($null -ne $PaneLines) {
        $paneErrors = @($PaneLines | Where-Object { $_.severity -eq 'Error' }).Count
        if ($paneErrors -gt $ErrorRows) {
            return (& $verdict $false "fewer-errors-than-build-pane: the build pane lists $paneErrors error line(s), the COM list has $ErrorRows error row(s)")
        }
    }
    if (-not [bool]$Com.flagsRestored) { $notes.Add('the Error List Errors / Warnings / Messages buttons could not be set back to their earlier state') }
    return (& $verdict $true $null)
}

function Get-TcErrorListComAssemblyPaths {
    <#
    .SYNOPSIS
        EnvDTE.dll / EnvDTE80.dll of the connected IDE (...\Common7\IDE\PublicAssemblies next to the IDE exe), else of an
        installed TcXaeShell / VS2022; $null when none is found.
    #>
    [CmdletBinding()]
    param([int]$IdeProcessId = 0)
    $dirs = [System.Collections.Generic.List[string]]::new()
    if ($IdeProcessId -gt 0) {
        try {
            $exe = [string](Get-Process -Id $IdeProcessId -ErrorAction Stop).MainModule.FileName
            if (-not [string]::IsNullOrWhiteSpace($exe)) { $dirs.Add((Join-Path (Split-Path -Parent $exe) 'PublicAssemblies')) }
        }
        catch { Write-Verbose "Get-TcErrorListComAssemblyPaths: IDE exe path not readable ($($_.Exception.Message))" }
    }
    $pf86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    if (-not [string]::IsNullOrWhiteSpace($pf86)) { $dirs.Add((Join-Path $pf86 'Beckhoff\TcXaeShell\Common7\IDE\PublicAssemblies')) }
    foreach ($pf in @($env:ProgramFiles, $pf86)) {
        if ([string]::IsNullOrWhiteSpace($pf)) { continue }
        foreach ($d in @(Get-ChildItem -LiteralPath (Join-Path $pf 'Microsoft Visual Studio') -Directory -ErrorAction SilentlyContinue)) {
            foreach ($ed in @(Get-ChildItem -LiteralPath $d.FullName -Directory -ErrorAction SilentlyContinue)) {
                $dirs.Add((Join-Path $ed.FullName 'Common7\IDE\PublicAssemblies'))
            }
        }
    }
    foreach ($dir in $dirs) {
        $a = Join-Path $dir 'EnvDTE.dll'
        $b = Join-Path $dir 'EnvDTE80.dll'
        if ((Test-Path -LiteralPath $a -PathType Leaf) -and (Test-Path -LiteralPath $b -PathType Leaf)) { return @($a, $b) }
    }
    return $null
}

function Initialize-TcErrorListComTypes {
    <#
    .SYNOPSIS
        Compiles ErrorListComReader.cs once per process (Add-Type). Returns { ok; reason }; a failure is cached
        (csc blocked / Constrained Language Mode / no EnvDTE assemblies do not heal within a process).
    #>
    [CmdletBinding()]
    param([int]$IdeProcessId = 0)
    if ($null -ne $script:TcErrorListComTypeState) { return $script:TcErrorListComTypeState }
    $state = [PSCustomObject]@{ ok = $false; reason = $null }
    if (([System.Management.Automation.PSTypeName]'TcAutomation.ErrorListComReader').Type) {
        $state.ok = $true
        $script:TcErrorListComTypeState = $state
        return $state
    }
    try {
        $csPath = Join-Path $PSScriptRoot 'ErrorListComReader.cs'
        if (-not (Test-Path -LiteralPath $csPath -PathType Leaf)) { throw "ErrorListComReader.cs not found next to the module ($csPath)" }
        $src = [IO.File]::ReadAllText($csPath)
        $paths = Get-TcErrorListComAssemblyPaths -IdeProcessId $IdeProcessId
        $refs = if ($null -ne $paths) { @($paths) } else { @('EnvDTE', 'EnvDTE80') }
        Add-Type -TypeDefinition $src -ReferencedAssemblies $refs -ErrorAction Stop
        $state.ok = $true
    }
    catch {
        $state.reason = "com-helper-unavailable: $($_.Exception.Message)"
    }
    $script:TcErrorListComTypeState = $state
    return $state
}

function Read-TcErrorListCom {
    <#
    .SYNOPSIS
        Calls the C# reader on the connected DTE (through Invoke-TcComRetry: busy / dead RPC retried, IDE_* classified).
        Returns { ok; reason; error; caption; isolated; allCount; flagsRestored; flagsBefore; ms; all|errors|warnings|messages }.
        Mocked in unit tests.
    #>
    [CmdletBinding()]
    param([bool]$Isolate, [int]$MaxMs)
    $dte = $script:TcDte
    $settle = [int]$script:TcErrorListComSettleMs
    $r = Invoke-TcComRetry -MaxRetries 2 -OperationName 'ErrorList.ErrorItems' -ScriptBlock {
        $res = [TcAutomation.ErrorListComReader]::Read($dte, $Isolate, $settle, $MaxMs)
        $kind = Get-TcComRpcFailureKind -Exception ([PSCustomObject]@{ Message = [string]$res.Error; HResult = [int]$res.HResult; InnerException = $null })
        if ($res.Reason -eq 'com-error' -and ($kind.Busy -or $kind.DeadRpc)) {
            # busy / dead RPC reaches Invoke-TcComRetry (retry, IDE_BUSY / IDE_CRASHED)
            throw [System.Runtime.InteropServices.COMException]::new([string]$res.Error, [int]$res.HResult)
        }
        $res
    }
    $rowsOf = { param($list) @(@($list) | Where-Object { $null -ne $_ }) }
    [PSCustomObject]@{
        ok            = [bool]$r.Ok
        reason        = [string]$r.Reason
        error         = [string]$r.Error
        caption       = [string]$r.Caption
        isolated      = [bool]$r.Isolated
        allCount      = [int]$r.AllCount
        flagsRestored = [bool]$r.FlagsRestored
        flagsBefore   = @($r.FlagsBefore)
        ms            = [Math]::Round([double]$r.Ms, 1)
        all           = & $rowsOf $r.All
        errors        = & $rowsOf $r.Errors
        warnings      = & $rowsOf $r.Warnings
        messages      = & $rowsOf $r.Messages
    }
}

function Get-TcErrorListViaCom {
    <#
    .SYNOPSIS
        The COM read of the Error List as the data of a Get-TcBuildErrors result.
        Returns { accepted; reason; data; elapsedMs }: accepted = $true -> data is complete and may be returned as is;
        $false -> reason says why the UIA scan must read instead (data is $null).
    .PARAMETER ExpectErrors
        The caller knows the build / check failed (see Get-TcErrorListComVerdict).
    .PARAMETER BuildPaneText
        Build pane text of THIS build (Build-TcProject): cross-checked against the error rows and used for the codes.
        Without it the pane is read here for the codes only (it may belong to an earlier build: matches on file + text).
    #>
    [CmdletBinding()]
    param(
        [bool]$IncludeWarnings = $true,
        [bool]$IncludeMessages = $false,
        [int]$MaxMs = 0,
        [switch]$ExpectErrors,
        [AllowNull()][string]$BuildPaneText = $null
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $reject = { param([string]$Why) [PSCustomObject]@{ accepted = $false; reason = $Why; data = $null; elapsedMs = [int]$sw.ElapsedMilliseconds } }
    if ($null -eq $script:TcDte) { return (& $reject 'com-unavailable: no DTE connection') }
    if ($MaxMs -le 0) { $MaxMs = [int]$script:TcErrorListComDefaultMaxMs }
    try {
        $idePid = 0
        if ($null -ne $script:TcIdeProcessId) { try { $idePid = [int]$script:TcIdeProcessId } catch { $idePid = 0 } }
        $ts = Initialize-TcErrorListComTypes -IdeProcessId $idePid
        if (-not $ts.ok) { return (& $reject ([string]$ts.reason)) }

        $dteMajor = $null
        try {
            $ver = [string](Invoke-TcComRetry -MaxRetries 2 -OperationName 'DTE.Version' -ScriptBlock { $script:TcDte.Version })
            if ($ver -match '^(\d+)\.') { $dteMajor = [int]$Matches[1] }
        }
        catch { if (Test-TcComMustRethrow -ErrorRecord $_) { throw } }
        # severity by ErrorLevel only where the host's levels tell it; everywhere else one Show* flag at a time
        $isolate = ($null -eq $dteMajor -or $null -eq $script:TcErrorLevelSeverityByDteMajor[$dteMajor])

        $com = Read-TcErrorListCom -Isolate $isolate -MaxMs $MaxMs
        if ($null -eq $com) { return (& $reject 'com-read-failed:no result') }

        $items = @{ Error = [System.Collections.Generic.List[object]]::new(); Warning = [System.Collections.Generic.List[object]]::new(); Message = [System.Collections.Generic.List[object]]::new() }
        $unmapped = 0
        $isolatedTotal = 0
        $severityBy = 'ShowFlags'
        if ($com.ok) {
            if ($com.isolated) {
                $isolatedTotal = @($com.errors).Count + @($com.warnings).Count + @($com.messages).Count
                foreach ($r in @($com.errors)) { $items.Error.Add((ConvertTo-TcErrorListComItem -Row $r -Severity 'Error')) }
                foreach ($r in @($com.warnings)) { $items.Warning.Add((ConvertTo-TcErrorListComItem -Row $r -Severity 'Warning')) }
                foreach ($r in @($com.messages)) { $items.Message.Add((ConvertTo-TcErrorListComItem -Row $r -Severity 'Message')) }
            }
            else {
                $severityBy = 'ErrorLevel'
                foreach ($r in @($com.all)) {
                    $sev = ConvertFrom-TcErrorLevel -Level ([int]$r.Level) -DteMajor $dteMajor
                    if ($null -eq $sev) { $unmapped++; continue }
                    $items[$sev].Add((ConvertTo-TcErrorListComItem -Row $r -Severity $sev))
                }
            }
        }

        $freshPane = $null
        $paneLines = $null
        $paneText = $BuildPaneText
        if ($com.ok -and [string]::IsNullOrWhiteSpace($paneText)) {
            # codes only: the pane may be older than the list, so no count cross-check from it
            try {
                $pr = Invoke-TcComRetry -MaxRetries 2 -OperationName 'Read build output' -ScriptBlock { Get-TcBuildOutputPane }
                if ($null -ne $pr -and [string]$pr.status -eq 'read') { $paneText = [string]$pr.text }
            }
            catch { if (Test-TcComMustRethrow -ErrorRecord $_) { throw } }
        }
        elseif ($com.ok) { $freshPane = $true }
        if (-not [string]::IsNullOrWhiteSpace($paneText)) { $paneLines = ConvertFrom-TcBuildPaneDiagnostics -Text $paneText }

        $verdict = Get-TcErrorListComVerdict -Com $com -ErrorRows $items.Error.Count -UnmappedRows $unmapped -IsolatedTotal $isolatedTotal `
            -ExpectErrors:$ExpectErrors -PaneLines $(if ($freshPane) { $paneLines } else { $null })
        if (-not $verdict.accept) { return (& $reject ([string]$verdict.reason)) }

        # Compiler codes from the build pane (Error and Warning rows); no match -> $null
        if ($null -ne $paneLines -and @($paneLines).Count -gt 0) {
            foreach ($sev in @('Error', 'Warning')) {
                foreach ($it in $items[$sev]) { $it.code = Resolve-TcErrorItemCode -Item $it -PaneLines $paneLines }
            }
        }
        $unresolvedCodes = @($items.Error | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.code) }).Count

        $counts = [PSCustomObject]@{ errors = $items.Error.Count; warnings = $items.Warning.Count; messages = $items.Message.Count }
        $data = [PSCustomObject]@{
            counts    = $counts
            errors    = $items.Error.ToArray()
            truncated = $false
            source    = 'ErrorList(COM)'
            scope     = [PSCustomObject]@{ before = [string]$com.caption; after = [string]$com.caption; entire = $true; switched = $false }
        }
        if ($IncludeWarnings) { $data | Add-Member -NotePropertyName 'warnings' -NotePropertyValue $items.Warning.ToArray() }
        if ($IncludeMessages) { $data | Add-Member -NotePropertyName 'messages' -NotePropertyValue $items.Message.ToArray() }
        $data | Add-Member -NotePropertyName 'comRead' -NotePropertyValue ([PSCustomObject]@{
                severityBy       = $severityBy
                dteMajor         = $dteMajor
                readMs           = $com.ms
                rows             = ($items.Error.Count + $items.Warning.Count + $items.Message.Count)
                flagsRestored    = [bool]$com.flagsRestored
                errorsWithoutCode = $unresolvedCodes
                paneCrossCheck   = [bool]$freshPane
                notes            = @($verdict.notes)
            })
        return [PSCustomObject]@{ accepted = $true; reason = $null; data = $data; elapsedMs = [int]$sw.ElapsedMilliseconds }
    }
    catch {
        # IDE_BUSY / IDE_CRASHED / IDE_MODAL_DIALOG from Invoke-TcComRetry: the COM source is not usable now; the UIA
        # scan decides what it can still read (it reports ERRORLIST_UNAVAILABLE when it cannot)
        return (& $reject "com-error: $($_.Exception.Message)")
    }
}
