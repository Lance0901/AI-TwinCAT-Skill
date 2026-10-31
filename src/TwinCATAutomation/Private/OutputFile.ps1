# Output files written by XAE (complete-automation-interface phase 2, tasks 3.3 / 3.4): path checks,
# the -Overwrite move-aside (.bak) with restore, file facts for readback, and the HRESULT / exception
# type of a failed late-bound COM call. Used by Export-TcPlcOpen, Save-TcPlcLibrary, Save-TcArchive.
# XAE refuses an existing file in PlcOpenExport ("File '...' already exists!"), SaveAsLibrary ("File '...'
# already exist. Cannot SaveAsLibrary!") and SaveAsArchive ("Archive file already exists!") with an
# ArgumentException (measured 2026-10-31 4026 VS2022 XAE 3.1.4026.18, self-built client,
# openspec/changes/complete-automation-interface/verification/phase2-probe.md 3.3 / 3.4), so the module
# checks first and, with -Overwrite, renames the old file to .bak before the call.

function Test-TcOutputFilePath {
    <#
    .SYNOPSIS
        Checks the -FilePath of a file XAE is about to write: $null when usable, else @{ Reason; Message }.
    .DESCRIPTION
        Reasons: not-absolute / invalid-path (Test-TcTreeItemFilePath), extension (not one of
        -Extensions, compared case-insensitively), folder-missing (the folder does not exist),
        file-exists (the file exists and -AllowExisting is not set). Never throws.
    .PARAMETER FilePath
        Path to check.
    .PARAMETER Extensions
        Allowed extensions with the dot, e.g. '.xml'; empty = any.
    .PARAMETER AllowExisting
        An existing file is not a problem (the caller moves it aside, -Overwrite).
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$FilePath,
        [Parameter()][AllowEmptyCollection()][string[]]$Extensions = @(),
        [Parameter()][switch]$AllowExisting
    )
    try {
        $bad = Test-TcTreeItemFilePath -FilePath $FilePath
        if ($null -ne $bad) { return $bad }
        $ext = [System.IO.Path]::GetExtension($FilePath)
        if (@($Extensions).Count -gt 0 -and @($Extensions | Where-Object { $_ -ieq $ext }).Count -eq 0) {
            return @{ Reason = 'extension'; Message = "-FilePath '$FilePath' must end in $((@($Extensions) | ForEach-Object { "'$_'" }) -join ' or ') (got '$ext')" }
        }
        $dir = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($FilePath))
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return @{ Reason = 'folder-missing'; Message = "the folder '$dir' of -FilePath does not exist" } }
        if (Test-Path -LiteralPath $FilePath -PathType Container) { return @{ Reason = 'invalid-path'; Message = "-FilePath '$FilePath' is a folder" } }
        if (-not $AllowExisting -and (Test-Path -LiteralPath $FilePath -PathType Leaf)) { return @{ Reason = 'file-exists'; Message = "'$FilePath' already exists" } }
    }
    catch { return @{ Reason = 'invalid-path'; Message = "-FilePath '$FilePath' cannot be checked: $($_.Exception.Message)" } }
    return $null
}

function Move-TcFileAside {
    <#
    .SYNOPSIS
        -Overwrite: renames an existing -FilePath to '<FilePath>.bak' ('<FilePath>.bak-2', -3 ... when
        that exists) and returns the new path; $null when -FilePath does not exist. Throws when the
        rename fails (the caller writes nothing then).
    .PARAMETER FilePath
        File to move aside.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$FilePath)
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { return $null }
    $bak = "$FilePath.bak"
    $n = 1
    while (Test-Path -LiteralPath $bak) { $n++; $bak = "$FilePath.bak-$n" }
    Move-Item -LiteralPath $FilePath -Destination $bak -ErrorAction Stop
    return $bak
}

function Restore-TcFileAside {
    <#
    .SYNOPSIS
        Puts a file moved aside by Move-TcFileAside back: @{ restored; failedFile; message }. Never throws.
    .DESCRIPTION
        A file that the failed call left at -FilePath is renamed to '<FilePath>.failed' (-2, -3 ...)
        first (data.failedFile), so nothing is deleted. Without -BakPath nothing is restored
        (restored = $null).
    .PARAMETER FilePath
        Original path.
    .PARAMETER BakPath
        Path returned by Move-TcFileAside ($null: nothing was moved).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$FilePath, [Parameter()][AllowNull()][AllowEmptyString()][string]$BakPath)
    $out = [PSCustomObject]@{ restored = $null; failedFile = $null; message = $null }
    if ([string]::IsNullOrEmpty($BakPath)) { return $out }
    try {
        if (Test-Path -LiteralPath $FilePath -PathType Leaf) {
            $failed = "$FilePath.failed"
            $n = 1
            while (Test-Path -LiteralPath $failed) { $n++; $failed = "$FilePath.failed-$n" }
            Move-Item -LiteralPath $FilePath -Destination $failed -ErrorAction Stop
            $out.failedFile = $failed
        }
        Move-Item -LiteralPath $BakPath -Destination $FilePath -ErrorAction Stop
        $out.restored = $true
    }
    catch {
        $out.restored = $false
        $out.message = "the previous file could not be put back from '$BakPath' to '$FilePath': $($_.Exception.Message)"
    }
    return $out
}

function Get-TcOutputFileFacts {
    <#
    .SYNOPSIS
        { path; exists; size; lastWriteTimeUtc (DateTime or $null); lastWriteTime (text) } of a file. Never throws.
    .PARAMETER Path
        File path.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $f = $null
    try { $f = Get-Item -LiteralPath $Path -ErrorAction Stop } catch { $f = $null }
    if ($null -eq $f -or $f.PSIsContainer) { return [PSCustomObject]@{ path = $Path; exists = $false; size = $null; lastWriteTimeUtc = $null; lastWriteTime = $null } }
    [PSCustomObject]@{ path = $Path; exists = $true; size = [long]$f.Length; lastWriteTimeUtc = $f.LastWriteTimeUtc; lastWriteTime = $f.LastWriteTime.ToString('yyyy-MM-ddTHH:mm:ss.fff') }
}

function Get-TcComErrorInfo {
    <#
    .SYNOPSIS
        { hresult (int, 0 when none); exceptionType (innermost non-wrapper type name); argument
        ($true when an ArgumentException is in the chain); message (innermost message) } of a failed call.
    .DESCRIPTION
        Walks the exception chain of an ErrorRecord / Exception. The PowerShell wrappers
        (MethodInvocationException, RuntimeException, TargetInvocationException) are skipped: hresult
        and exceptionType come from the innermost other exception (the COMException /
        ArgumentException XAE threw); only when there is none the wrapper's HResult is used, except
        0x80131501 (the HResult every MethodInvocationException carries).
        Decided by type and HRESULT, never by the (localized) PowerShell text.
    .PARAMETER ErrorRecord
        ErrorRecord or Exception.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][object]$ErrorRecord)
    $ex = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ErrorRecord.Exception } else { $ErrorRecord }
    $chain = [System.Collections.Generic.List[object]]::new()
    while ($null -ne $ex -and $ex -is [System.Exception]) { $chain.Add($ex); $ex = $ex.InnerException }
    $wrapper = { param($e) $e -is [System.Management.Automation.MethodInvocationException] -or $e -is [System.Management.Automation.RuntimeException] -or $e -is [System.Reflection.TargetInvocationException] }
    $inner = @($chain | Where-Object { -not (& $wrapper $_) })
    $deepest = if ($inner.Count -gt 0) { $inner[$inner.Count - 1] } elseif ($chain.Count -gt 0) { $chain[$chain.Count - 1] } else { $null }
    $hr = 0
    foreach ($e in @($inner)) { if ($e.HResult -ne 0) { $hr = [int]$e.HResult } }
    if ($hr -eq 0) { foreach ($e in @($chain)) { if ($e.HResult -ne 0 -and $e.HResult -ne -2146233087) { $hr = [int]$e.HResult } } }
    [PSCustomObject]@{
        hresult       = $hr
        hresultHex    = $(if ($hr -ne 0) { '0x{0:X8}' -f $hr } else { $null })
        exceptionType = $(if ($null -ne $deepest) { $deepest.GetType().FullName } else { $null })
        argument      = (@($chain | Where-Object { $_ -is [System.ArgumentException] }).Count -gt 0)
        message       = $(if ($null -ne $deepest) { [string]$deepest.Message } else { [string]$ErrorRecord })
    }
}
