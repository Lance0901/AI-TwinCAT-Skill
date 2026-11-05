function Get-TcErrorListSummary {
    <#
    .SYNOPSIS
        Reads the IDE Error List once (Get-TcBuildErrors -IncludeWarnings) and classifies its rows
        the way Build-TcProject reports them; shared by Build-TcProject and Test-TcPlcProject.
    .DESCRIPTION
        Every error row gets a 'category' (Get-TcErrorItemCategory: code / library / other, #23), so
        errorItems has the same shape in both cmdlets:
          @{ severity; code; description; project; file; line; column; category }
        Returned PSCustomObject:
          errorItems         every error row of the Error List (@() when it could not be read)
          codeErrors         errorItems with category 'code'
          libraryErrorItems  errorItems with category 'library'
          nonLibraryErrors   errorItems with category code or other
          warningItems       the warning rows (@() when not readable)
          codeWarnings       warningItems without Library Manager rows and without rows that have no file
          errorCount         number of code errors when the Error List was read, else -FallbackErrorCount
          libraryErrorCount  number of library errors, $null when the Error List was not readable
          warningCount       counts.warnings of the Error List (else the number of warning rows when
                             there are any, else -FallbackWarningCount)
          errorListError     $null, or the error code of the failed Error List read
          errorListMessage   its message
          severityUnknown    rows whose severity could not be isolated (Get-TcBuildErrors)
          unclassifiedCount  number of those rows
          unclassified       those rows
          truncated          Get-TcBuildErrors data.truncated: not every row could be read ($false when
                             the Error List was not readable)
          scanCleanupWarning Get-TcBuildErrors data.scanCleanupWarning (#75), else $null
          incomplete         $true when Get-TcBuildErrors returned ERRORLIST_INCOMPLETE (#117): the rows that
                             were read are still in errorItems / warningItems (#138)
          missingRows        Get-TcBuildErrors data.missingRows (@() when complete)
          scope              Get-TcBuildErrors data.scope ($null when not read)
          warningsIncomplete $true when only warnings (or messages) were read short: errorListError stays
                             $null (the error rows are complete), Build-TcProject adds WARNINGS_INCOMPLETE
          errorListNote      text for that non-blocking case, else $null
          runtimeMessages    PLC runtime ADS log rows (TcUnit, ADSLOGSTR; Get-TcRuntimeLogKind 'runtime', #66), error and
                             warning rows, category 'runtime'; they are NOT in errorItems / warningItems and
                             never count as build errors
          ambiguousRows      rows with the runtime log prefix that also have a file, line or code: kept in
                             errorItems / warningItems (fail closed), each with a 'note'
        errorListError = ERRORLIST_INCOMPLETE only when the ERROR rows are not proven complete
        (Get-TcErrorListReadState: errors / total shortfall, Errors total unreadable, or a filtered
        scope with a shortfall); callers then treat the code as not verified (codeVerified = $null).
        The code of Build-TcProject before this function existed (complete-automation-interface task
        3.7); Build-TcProject keeps its own success decision.
    .PARAMETER TimeoutSec
        Get-TcBuildErrors -TimeoutSec; 0 (default) = its own default.
    .PARAMETER FallbackErrorCount
        errorCount when the Error List cannot be read (Build-TcProject: LastBuildInfo).
    .PARAMETER FallbackWarningCount
        warningCount when the Error List reports neither a count nor warning rows.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][int]$TimeoutSec = 0,
        [Parameter()][int]$FallbackErrorCount = 0,
        [Parameter()][int]$FallbackWarningCount = 0
    )
    $errorCount = $FallbackErrorCount
    $warningCount = $FallbackWarningCount
    $errorItems = @()
    $warningItems = @()
    $errorListError = $null
    $errorListMessage = $null
    $severityUnknown = $false
    $unclassified = @()
    $truncated = $false
    $el = if ($TimeoutSec -gt 0) { Get-TcBuildErrors -IncludeWarnings -TimeoutSec $TimeoutSec } else { Get-TcBuildErrors -IncludeWarnings }
    $rs = Get-TcErrorListReadState -Result $el
    $errorListNote = $null
    if ($rs.usable) {
        # Success, or ERRORLIST_INCOMPLETE: the rows that were read are kept either way (#138), so a
        # failed build still lists the code errors that were read.
        $errorItems = @($el.data.errors)
        if ($null -ne $el.data.counts.errors) { $errorCount = [int]$el.data.counts.errors } else { $errorCount = $errorItems.Count }
        if ($null -ne $el.data.PSObject.Properties['warnings']) { $warningItems = @($el.data.warnings) }
        if ($null -ne $el.data.counts.warnings) { $warningCount = [int]$el.data.counts.warnings }
        elseif ($warningItems.Count -gt 0) { $warningCount = $warningItems.Count }
        if ($null -ne $el.data.PSObject.Properties['severityUnknown']) { $severityUnknown = [bool]$el.data.severityUnknown }
        if ($null -ne $el.data.PSObject.Properties['unclassified']) { $unclassified = @($el.data.unclassified) }
        if ($null -ne $el.data.PSObject.Properties['truncated']) { $truncated = [bool]$el.data.truncated }
        if (-not $rs.errorsComplete) {
            $errorListError = [string]$el.error.code
            $errorListMessage = [string]$el.error.message
        }
        elseif ($rs.incomplete) { $errorListNote = $rs.note }
    }
    else {
        $errorListError = [string]$el.error.code
        $errorListMessage = [string]$el.error.message
    }

    # PLC runtime ADS log rows (#66, Get-TcRuntimeLogKind): TcUnit / ADSLOGSTR output is not a build
    # message, so it leaves errorItems / warningItems for runtimeMessages (category 'runtime') and
    # never counts as a build error. A row with the log prefix that also has a file, line or code
    # cannot be told apart: it stays where it was (fail closed) and gets a 'note'.
    $runtimeMessages = @()
    $ambiguousRows = @()
    $ambiguousNote = "looks like a PLC runtime ADS log row ('<task>' (<port>): ...) but has a file, line or compiler code, so it is kept as a build row (#66)"
    $splitRuntime = {
        param([object[]]$Rows)
        $kept = @()
        foreach ($r in @($Rows)) {
            if ($null -eq $r) { continue }
            $kind = Get-TcRuntimeLogKind $r
            if ($kind -eq 'runtime') {
                $r | Add-Member -NotePropertyName 'category' -NotePropertyValue 'runtime' -Force
                Set-Variable -Name runtimeMessages -Value (@($runtimeMessages) + $r) -Scope 1
            }
            else {
                if ($kind -eq 'ambiguous') {
                    $r | Add-Member -NotePropertyName 'note' -NotePropertyValue $ambiguousNote -Force
                    Set-Variable -Name ambiguousRows -Value (@($ambiguousRows) + $r) -Scope 1
                }
                $kept += $r
            }
        }
        $kept
    }
    $errorItems = @(& $splitRuntime $errorItems)
    $warningItems = @(& $splitRuntime $warningItems)

    # Category per item (#23): "Library Manager" rows are missing / unresolved libraries, not PLC
    # code errors; they stay listed after a successful build and never fail it on their own.
    foreach ($item in $errorItems) {
        $item | Add-Member -NotePropertyName 'category' -NotePropertyValue (Get-TcErrorItemCategory $item) -Force
    }
    $codeErrors = @($errorItems | Where-Object { $_.category -eq 'code' })
    $libraryErrorItems = @($errorItems | Where-Object { $_.category -eq 'library' })
    $nonLibraryErrors = @($errorItems | Where-Object { $_.category -ne 'library' })
    $libraryErrorCount = $null
    if ($null -eq $errorListError) {
        $errorCount = $codeErrors.Count
        $libraryErrorCount = $libraryErrorItems.Count
    }
    elseif ($rs.usable) {
        # errors read in part: at least what was read, never fewer than the fallback count
        $errorCount = [Math]::Max($codeErrors.Count, $FallbackErrorCount)
    }
    # Warnings: also drop rows without a file (the XAE build-summary row "... build for platform ...
    # failed" is listed as a Warning without project/file/line and survives the next successful build).
    $codeWarnings = @($warningItems | Where-Object { -not (Test-TcLibraryManagerItem $_) -and -not [string]::IsNullOrWhiteSpace([string]$_.file) })

    $scanWarning = $null
    if ($null -ne $el.data -and $null -ne $el.data.PSObject.Properties['scanCleanupWarning']) { $scanWarning = [string]$el.data.scanCleanupWarning }

    [PSCustomObject]@{
        errorItems         = $errorItems
        codeErrors         = $codeErrors
        libraryErrorItems  = $libraryErrorItems
        nonLibraryErrors   = $nonLibraryErrors
        warningItems       = $warningItems
        codeWarnings       = $codeWarnings
        errorCount         = $errorCount
        libraryErrorCount  = $libraryErrorCount
        warningCount       = $warningCount
        errorListError     = $errorListError
        errorListMessage   = $errorListMessage
        severityUnknown    = $severityUnknown
        unclassifiedCount  = $unclassified.Count
        unclassified       = $unclassified
        truncated          = $truncated
        scanCleanupWarning = $scanWarning
        incomplete         = [bool]$rs.incomplete
        missingRows        = @($rs.missingRows)
        scope              = $rs.scope
        warningsIncomplete = [bool]($rs.incomplete -and $rs.errorsComplete -and $rs.warningsIncomplete)
        errorListNote      = $errorListNote
        runtimeMessages    = @($runtimeMessages)
        ambiguousRows      = @($ambiguousRows)
    }
}
