# Shared helpers of the phase 3 system configuration cmdlets (complete-automation-interface tasks
# 4.1-4.5: NC axes, TcCOM modules, project variants, independent project files, ADS routes).
# Behaviour notes come from openspec/changes/complete-automation-interface/verification/phase3-probe.md
# (measured 2026-11-01 4026 VS2022 XAE 3.1.4026.22 / 4024 XAE Shell 3.1.4024.71, self-built client).

# Element / attribute names whose value is a password: masked as *** in every ProduceXml text the
# module returns or writes into a backup (research/phase3-api.md "Password": TE1000 v1.7.0 6.3.17
# p.220 AddRoute <Password>, 6.3.18 p.222 TISY <BootSettings><LogonPassword> "stored in the
# project"). Whole names only, so e.g. 'Bypass' is not touched.
$script:TcPasswordNamePattern = '(?:[A-Za-z0-9_.-]*Password[A-Za-z0-9_.-]*|[A-Za-z0-9_.-]*Pwd)'
$script:TcPasswordMask = '***'

function ConvertTo-TcMaskedXml {
    <#
    .SYNOPSIS
        Replaces the value of every Password / LogonPassword / *Pwd element and attribute in an XML text with ***.
    .DESCRIPTION
        Text based (the XML is not re-serialized, so formatting and the other values stay byte for
        byte): <XxxPassword ...>value</XxxPassword> -> <XxxPassword ...>***</XxxPassword> (only
        elements without child elements; an empty element stays empty), and XxxPassword="value"
        inside a start tag -> XxxPassword="***". Name match is case-insensitive on the whole
        element / attribute name ($script:TcPasswordNamePattern). Never throws; $null / empty text
        is returned as it is.
    .PARAMETER Xml
        XML text (ProduceXml output, a backup, an error message).
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Xml)
    if ([string]::IsNullOrEmpty($Xml)) { return $Xml }
    if ($Xml -notmatch '(?i)(password|pwd)') { return $Xml }
    $n = $script:TcPasswordNamePattern
    $out = $Xml
    try {
        $out = [regex]::Replace($out, "(?is)(<(?<n>(?:[A-Za-z0-9_.-]+:)?$n)(?:\s[^>]*)?>)([^<]+)(</\k<n>\s*>)", {
                param($m) $m.Groups[1].Value + $script:TcPasswordMask + $m.Groups[3].Value
            })
        $out = [regex]::Replace($out, "(?is)(<[A-Za-z_][^<>]*?\s(?:[A-Za-z0-9_.-]+:)?$n\s*=\s*)(""[^""]*""|'[^']*')", {
                param($m) $m.Groups[1].Value + '"' + $script:TcPasswordMask + '"'
            })
    }
    catch { return $Xml }
    return $out
}

function Get-TcExceptionHResult {
    <#
    .SYNOPSIS
        HRESULT of the COM exception inside an ErrorRecord / exception chain (0 when there is none).
    .DESCRIPTION
        PowerShell late binding wraps a COMException in MethodInvocationException; the wrapper
        HResults 0x80131501 / 0x80131500 are skipped. The first COMException wins, else the first
        other non-zero HResult.
    .PARAMETER InputObject
        ErrorRecord or Exception.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$InputObject)
    if ($null -eq $InputObject) { return 0 }
    $ex = if ($InputObject -is [System.Management.Automation.ErrorRecord]) { $InputObject.Exception } else { $InputObject }
    $first = 0
    while ($null -ne $ex -and $ex -is [System.Exception]) {
        $h = [int]$ex.HResult
        if ($ex -is [System.Runtime.InteropServices.COMException]) { return $h }
        if ($first -eq 0 -and $h -ne 0 -and $h -ne -2146233087 -and $h -ne -2146233088) { $first = $h }
        $ex = $ex.InnerException
    }
    return $first
}

function Get-TcExceptionText {
    <#
    .SYNOPSIS
        Message of an ErrorRecord / exception plus its inner messages, one line.
    .PARAMETER InputObject
        ErrorRecord or Exception.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$InputObject)
    if ($null -eq $InputObject) { return '' }
    $ex = if ($InputObject -is [System.Management.Automation.ErrorRecord]) { $InputObject.Exception } else { $InputObject }
    if ($ex -isnot [System.Exception]) { return [string]$InputObject }
    $parts = [System.Collections.Generic.List[string]]::new()
    while ($null -ne $ex) {
        $m = [string]$ex.Message
        if (-not [string]::IsNullOrWhiteSpace($m) -and -not $parts.Contains($m)) { $parts.Add($m) }
        $ex = $ex.InnerException
    }
    return (($parts.ToArray()) -join ' | ') -replace '\s+', ' '
}

function Add-TcDataWarning {
    <#
    .SYNOPSIS
        Appends one or more warnings to data.warnings (created when missing).
    .PARAMETER Data
        PSCustomObject.
    .PARAMETER Warning
        Text(s) to append.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Data, [Parameter()][AllowEmptyCollection()][string[]]$Warning = @())
    $add = @($Warning | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($add.Count -eq 0) { return }
    $wp = $Data.PSObject.Properties['warnings']
    $old = if ($null -ne $wp -and $null -ne $wp.Value) { @($wp.Value) } else { @() }
    $Data | Add-Member -NotePropertyName warnings -NotePropertyValue @($old + $add) -Force
}

function Find-TcSolutionTsProjFile {
    <#
    .SYNOPSIS
        .tsproj files below the solution folder (depth 3, .tcauto-backup skipped): @{ Files = @(); Single = <path> | $null }.
    .DESCRIPTION
        Single is set when exactly one .tsproj is found. Never throws.
    .PARAMETER SolutionDir
        Folder of the .sln (default Get-TcTreeItemSolutionDir).
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][string]$SolutionDir)
    if ([string]::IsNullOrWhiteSpace($SolutionDir)) { $SolutionDir = Get-TcTreeItemSolutionDir }
    $files = @()
    if (-not [string]::IsNullOrWhiteSpace($SolutionDir) -and (Test-Path -LiteralPath $SolutionDir -PathType Container)) {
        try {
            $files = @(Get-ChildItem -LiteralPath $SolutionDir -Recurse -Depth 3 -File -Filter '*.tsproj' -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch '\\\.tcauto-backup\\' } | ForEach-Object { $_.FullName })
        }
        catch { $files = @() }
    }
    return @{ Files = $files; Single = $(if ($files.Count -eq 1) { $files[0] } else { $null }) }
}

function New-TcConfigBackup {
    <#
    .SYNOPSIS
        Backup before a phase 3 write: <sln dir>\.tcauto-backup\<time>\<Label>.xml (masked text) plus copies of -DiskFiles: @{ Result; Backup }.
    .DESCRIPTION
        Same layout and rules as Invoke-TcTreeItemBackup (TREEITEM_BACKUP_FAILED when the solution
        folder is unknown or the backup cannot be written; the caller then changes nothing). The
        text is masked with ConvertTo-TcMaskedXml before it is written. Missing disk files are
        skipped silently (Test-Path), files that cannot be copied are warnings.
    .PARAMETER Label
        Name of the backup file (a tree path or e.g. 'ProjectVariantConfig').
    .PARAMETER Text
        Text to store (ProduceXml, a property value ...).
    .PARAMETER DiskFiles
        Files to copy (.tsproj, .xti ...).
    .PARAMETER Data
        Data attached to a failed result.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Text = '',
        [Parameter()][AllowEmptyCollection()][string[]]$DiskFiles = @(),
        [Parameter()][object]$Data
    )
    $dir = Get-TcTreeItemSolutionDir
    if ($null -eq $dir) {
        return @{ Backup = $null; Result = (New-TcResult -Success $false -ErrorCode 'TREEITEM_BACKUP_FAILED' -Data $Data `
                    -ErrorMessage 'No solution path is known (Connect-TcIde -SolutionPath / Open-TcProject); the backup cannot be written, nothing was changed.' `
                    -Hint (Get-TcErrorHint -Code 'TREEITEM_BACKUP_FAILED')) }
    }
    try {
        $files = @($DiskFiles | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_ -PathType Leaf) })
        $b = New-TcTreeItemBackup -SolutionDir $dir -Path $Label -Xml ([string](ConvertTo-TcMaskedXml -Xml ([string]$Text))) -DiskFiles $files
        return @{ Backup = $b; Result = $null }
    }
    catch {
        return @{ Backup = $null; Result = (New-TcResult -Success $false -ErrorCode 'TREEITEM_BACKUP_FAILED' -Data $Data `
                    -ErrorMessage "Backup '$Label' failed, nothing was changed: $($_.Exception.Message)" -Hint (Get-TcErrorHint -Code 'TREEITEM_BACKUP_FAILED')) }
    }
}

function Get-TcTreeItemPropertyNoThrow {
    <#
    .SYNOPSIS
        A property of a COM object, or -Default when it cannot be read.
    .PARAMETER Item
        COM object.
    .PARAMETER Name
        Property name.
    .PARAMETER Default
        Value on failure.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$Item, [Parameter(Mandatory)][string]$Name, [Parameter()][AllowNull()][object]$Default = $null)
    if ($null -eq $Item) { return $Default }
    try {
        $v = $Item.$Name
        if ($null -eq $v) { return $Default }
        return $v
    }
    catch { return $Default }
}

function ConvertFrom-TcHexId {
    <#
    .SYNOPSIS
        '#x05093009' / '0x05093009' / '05093009' / a number -> [uint32], or $null.
    .PARAMETER Value
        Text or number.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [uint32]) {
        $l = [long]$Value
        if ($l -lt 0 -or $l -gt [uint32]::MaxValue) { return $null }
        return [uint32]$l
    }
    $s = ([string]$Value).Trim()
    if ($s -match '^(?:#x|0x)([0-9A-Fa-f]{1,8})$') { return [uint32]::Parse($Matches[1], [System.Globalization.NumberStyles]::HexNumber) }
    if ($s -match '^[0-9]{1,10}$') {
        $l = [long]$s
        if ($l -le [uint32]::MaxValue) { return [uint32]$l }
    }
    return $null
}

function Format-TcHexId {
    <#
    .SYNOPSIS
        [uint32] -> '0x05093009'.
    .PARAMETER Value
        Number.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][uint32]$Value)
    return ('0x{0:X8}' -f $Value)
}
