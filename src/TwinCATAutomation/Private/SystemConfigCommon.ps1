# Shared helpers of the phase 3 system configuration cmdlets (complete-automation-interface tasks
# 4.1-4.5: NC axes, TcCOM modules, project variants, independent project files, ADS routes).
# Behaviour notes come from openspec/changes/complete-automation-interface/verification/phase3-probe.md
# (measured 2026-11-01 4026 VS2022 XAE 3.1.4026.22 / 4024 XAE Shell 3.1.4024.71, self-built client).

# Element / attribute names whose value is a password: masked as *** in every ProduceXml text the
# module returns or writes into a backup (research/phase3-api.md "Password": TE1000 v1.7.0 6.3.17
# p.220 AddRoute <Password>, 6.3.18 p.222 TISY <BootSettings><LogonPassword> "stored in the
# project"). A name containing password / passwd / pwd (any case) counts; 'Bypass' does not.
$script:TcPasswordNamePattern = '(?i)(password|passwd|pwd)'
$script:TcPasswordMask = '***'
$script:TcMaskedText = '(masked)'

function Test-TcSecretName {
    <#
    .SYNOPSIS
        True for an element / attribute (local) name that holds a password (password / passwd / pwd, any case).
    .PARAMETER Name
        Name.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Name)
    return (-not [string]::IsNullOrEmpty($Name) -and $Name -match $script:TcPasswordNamePattern)
}

function ConvertTo-TcMaskedXml {
    <#
    .SYNOPSIS
        Replaces the content of every password element (Password, LogonPassword, Passwd, *Pwd ...) and the value of every such attribute with ***.
    .DESCRIPTION
        The text is parsed as XML (XmlReader with DtdProcessing Prohibit and no resolver: no DTD, no
        external entity; whitespace kept). Every element whose local name matches
        $script:TcPasswordNamePattern loses ALL its child nodes (text, CDATA, child elements,
        comments) and gets the text *** (an empty element stays empty); every matching attribute of
        any element gets ***. Nothing matched: the text is returned unchanged (byte for byte);
        otherwise the re-serialized document. A text that does not parse (an error message, a
        fragment) but contains passw / pwd is replaced as a whole by '(masked)'; other text is
        returned as it is. Never throws.
    .PARAMETER Xml
        XML text (ProduceXml output, a backup, an error message).
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Xml)
    if ([string]::IsNullOrEmpty($Xml)) { return $Xml }
    if ($Xml -notmatch '(?i)(passw|pwd)') { return $Xml }
    $doc = $null
    $sr = $null
    $reader = $null
    try {
        $settings = New-Object System.Xml.XmlReaderSettings
        $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $doc = New-Object System.Xml.XmlDocument
        $doc.XmlResolver = $null
        $doc.PreserveWhitespace = $true
        $sr = New-Object System.IO.StringReader($Xml)
        $reader = [System.Xml.XmlReader]::Create($sr, $settings)
        $doc.Load($reader)
    }
    catch { return $script:TcMaskedText }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $sr) { $sr.Dispose() }
    }
    $changed = $false
    try {
        foreach ($el in @($doc.SelectNodes('//*'))) {
            foreach ($a in @($el.get_Attributes())) {
                if (Test-TcSecretName -Name $a.get_LocalName()) { $a.set_Value($script:TcPasswordMask); $changed = $true }
            }
            if (Test-TcSecretName -Name $el.get_LocalName()) {
                if ($el.get_HasChildNodes()) {
                    while ($el.get_HasChildNodes()) { $null = $el.RemoveChild($el.get_FirstChild()) }
                    $null = $el.AppendChild($doc.CreateTextNode($script:TcPasswordMask))
                }
                $changed = $true
            }
        }
    }
    catch { return $script:TcMaskedText }
    if (-not $changed) { return $Xml }
    return $doc.OuterXml
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

function Get-TcDteTsProjFiles {
    <#
    .SYNOPSIS
        FullName of every DTE Solution.Projects entry that ends in .tsproj (distinct, existing on disk): @{ Files = @(); Error = $null | message }. Never throws.
    .DESCRIPTION
        The TwinCAT project XAE has loaded (the same DTE Solution.Projects walk as
        Get-TcPlcProjectFile and Get-TcSysManager). No DTE -> Files empty, Error set.
    #>
    [CmdletBinding()]
    param()
    $out = @{ Files = @(); Error = $null }
    $dte = $script:TcDte
    if ($null -eq $dte) { $out.Error = 'no DTE connection'; return $out }
    try {
        $names = Invoke-TcComRetry -OperationName 'Solution.Projects (.tsproj FullName)' -ScriptBlock {
            $__list = [System.Collections.Generic.List[string]]::new()
            $__all = $dte.Solution.Projects
            for ($__i = 1; $__i -le [int]$__all.Count; $__i++) {
                $__full = $null
                try { $__full = [string]$__all.Item($__i).FullName } catch {
                    if ($_.Exception.ToString() -match '0x80010001|0x8001010A|RPC_E_CALL_REJECTED|RPC_E_SERVERCALL_RETRYLATER') { throw }
                    $__full = $null
                }
                if (-not [string]::IsNullOrWhiteSpace($__full) -and $__full -match '(?i)\.tsproj$') { $__list.Add($__full) }
            }
            Write-Output -NoEnumerate $__list.ToArray()
        }
        $files = [System.Collections.Generic.List[string]]::new()
        foreach ($f in @($names)) {
            if ([string]::IsNullOrWhiteSpace($f) -or -not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
            $full = [System.IO.Path]::GetFullPath($f)
            if (@($files | Where-Object { $_ -ieq $full }).Count -eq 0) { $files.Add($full) }
        }
        $out.Files = $files.ToArray()
    }
    catch { $out.Error = $_.Exception.Message }
    return $out
}

function Get-TcSlnTsProjFiles {
    <#
    .SYNOPSIS
        .tsproj files the .sln references (Project("{...}") = "<name>", "<rel>.tsproj", ...), resolved against the .sln folder, existing on disk, distinct. Never throws.
    .PARAMETER SolutionFile
        Path of the .sln.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][string]$SolutionFile)
    $files = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($SolutionFile) -or -not (Test-Path -LiteralPath $SolutionFile -PathType Leaf)) { return $files.ToArray() }
    try {
        $dir = [System.IO.Path]::GetDirectoryName($SolutionFile)
        foreach ($line in [System.IO.File]::ReadAllLines($SolutionFile)) {
            $m = [regex]::Match($line, '^\s*Project\("\{[^}]*\}"\)\s*=\s*"[^"]*"\s*,\s*"([^"]+\.tsproj)"', 'IgnoreCase')
            if (-not $m.Success) { continue }
            $full = [System.IO.Path]::GetFullPath((Join-Path $dir $m.Groups[1].Value))
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
            if (@($files | Where-Object { $_ -ieq $full }).Count -eq 0) { $files.Add($full) }
        }
    }
    catch { Write-Verbose "Get-TcSlnTsProjFiles: '$SolutionFile' not readable ($($_.Exception.Message))" }
    return $files.ToArray()
}

function Find-TcSolutionTsProjFile {
    <#
    .SYNOPSIS
        The .tsproj of the open TwinCAT project: @{ Files = @(); Single = <path> | $null; Source = 'dte' | 'sln' | 'folder' | $null; FolderFiles = @() }.
    .DESCRIPTION
        phase3-4.6 B2: a solution folder can hold old copies of the .tsproj that the solution does
        not use (4026 copy: 3 .tsproj, the .sln references one), so the folder is scanned last.
        The first source that names at least one existing file decides (Source):
          1. 'dte'    - DTE Solution.Projects FullName ending in .tsproj (Get-TcDteTsProjFiles);
          2. 'sln'    - the .tsproj the .sln references (Get-TcSlnTsProjFiles; the .sln is
                        $script:TcSolutionPath, else DTE Solution.FullName);
          3. 'folder' - .tsproj files below the solution folder (depth 3, .tcauto-backup skipped).
        A deciding source with several files leaves Single $null (the solution really has several
        TwinCAT projects). Files = the candidates of the deciding source; FolderFiles = the folder
        scan (for the data of a failed result). Paths in the long form. Never throws.
    .PARAMETER SolutionDir
        Folder of the .sln (default Get-TcTreeItemSolutionDir).
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][string]$SolutionDir)
    $sln = [string]$script:TcSolutionPath
    if ([string]::IsNullOrWhiteSpace($sln) -and $null -ne $script:TcDte) {
        try { $sln = [string]$script:TcDte.Solution.FullName } catch { $sln = '' }
    }
    if ([string]::IsNullOrWhiteSpace($SolutionDir)) { $SolutionDir = Get-TcTreeItemSolutionDir }
    $folder = @()
    if (-not [string]::IsNullOrWhiteSpace($SolutionDir) -and (Test-Path -LiteralPath $SolutionDir -PathType Container)) {
        try {
            $folder = @(Get-ChildItem -LiteralPath $SolutionDir -Recurse -Depth 3 -File -Filter '*.tsproj' -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch '\\\.tcauto-backup\\' } | ForEach-Object { $_.FullName })
        }
        catch { $folder = @() }
    }
    $out = @{ Files = @(); Single = $null; Source = $null; FolderFiles = $folder }
    foreach ($src in @('dte', 'sln', 'folder')) {
        $files = switch ($src) {
            'dte' { @((Get-TcDteTsProjFiles).Files) }
            'sln' { @(Get-TcSlnTsProjFiles -SolutionFile $sln) }
            default { $folder }
        }
        $files = @($files)
        if ($files.Count -eq 0) { continue }
        # the same spelling as the folder scan (long path form; with an 8.3 TEMP the .sln path is short)
        $long = [System.Collections.Generic.List[string]]::new()
        foreach ($f in $files) {
            $hit = @($folder | Where-Object { $_ -ieq $f })
            $p = if ($hit.Count -gt 0) { [string]$hit[0] } else { [string](Get-TcLongPath $f) }
            if (@($long | Where-Object { $_ -ieq $p }).Count -eq 0) { $long.Add($p) }
        }
        $out.Files = $long.ToArray()
        $out.Source = $src
        if ($long.Count -eq 1) { $out.Single = $long[0] }
        return $out
    }
    return $out
}

function Get-TcTsProjBackupFiles {
    <#
    .SYNOPSIS
        The .tsproj file(s) to copy into a backup: the one Find-TcSolutionTsProjFile decided, else its candidates (phase3-4.6 B2: not every .tsproj of the solution folder).
    #>
    [CmdletBinding()]
    param()
    $ts = Find-TcSolutionTsProjFile
    if ($null -ne $ts.Single) { return @($ts.Single) }
    return @($ts.Files)
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

function Read-TcComPropertyValue {
    <#
    .SYNOPSIS
        Reads a property so that a failing getter THROWS (review S2).
    .DESCRIPTION
        '$obj.Name' and PSObject.Properties[Name].Value return $null when the getter throws (the
        exception is swallowed; checked 2026-11-01 Windows PowerShell 5.1 with a .NET getter that
        throws COMException), which would make "could not be read" look like "empty". The accessor
        method get_<Name>() does throw (MethodInvocationException). When there is no such method
        (FullyQualifiedErrorId MethodNotFound: a script property, an adapter without accessor
        methods) the property is read the plain way. An object without the member returns $null.
    .PARAMETER Object
        COM / .NET object.
    .PARAMETER Name
        Property name.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Object, [Parameter(Mandatory)][string]$Name)
    try { return $Object."get_$Name"() }
    catch {
        if ([string]$_.FullyQualifiedErrorId -notlike 'MethodNotFound*') { throw }
    }
    return $Object.$Name
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
