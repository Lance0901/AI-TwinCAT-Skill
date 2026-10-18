function Build-TcProject {
    <#
    .SYNOPSIS
        Builds the PLC project and returns build results including the compiler
        messages of the IDE Error List.
    .DESCRIPTION
        Uses DTE SolutionBuild with retry for RPC_E_CALL_REJECTED (IDE busy).
        Includes license check guidance if IDE remains unresponsive.
        Before the build the IDE is checked for a modal dialog (e.g. the XAE
        "Assertion Failed" box that appears after repeatedly opening/closing a
        solution): SolutionBuild.Build would then block forever, so IDE_MODAL_DIALOG
        is returned instead (data.dialogTitle / dialogText).
        After the build the Error List window is read with Get-TcBuildErrors (UI
        Automation): data.errors is the number of errors shown there and
        data.errorItems lists them (code / description / project / file / line).
        Success is decided in this order:
          (a) SolutionBuild.LastBuildInfo (= number of projects that failed to build,
              data.failedProjects) when it could be read: > 0 = BUILD_FAILED;
          (b) otherwise the Error List: any error that is not a "Library Manager" item
              (file not like '*Library Manager', line > 0) = BUILD_FAILED;
          (c) when neither is readable: BUILD_STATUS_UNKNOWN (success = false) - look at
              the XAE Error List yourself before deciding.
    .OUTPUTS
        data.buildSucceeded  $true / $false (the decision above); $null = BUILD_STATUS_UNKNOWN
        data.errors          error count (Error List; fallback: failedProjects)
        data.warnings        warning count (Error List; 0 when unavailable)
        data.messages        lines of the DTE build output pane (usually empty)
        data.failedProjects  SolutionBuild.LastBuildInfo ($null when it could not be read)
        data.errorItems      [ @{ severity; code; description; project; file; line; column } ]
        data.codeErrors      errorItems without the "Library Manager" items (file like
                             '*Library Manager' and line 0/empty) - the PLC code errors
        data.errorListError  only when the Error List could not be read (its error code)
    #>
    [CmdletBinding()]
    param()

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }

    $sm = Get-TcSysManager
    if ($null -eq $sm) {
        return New-TcResult -Success $false -ErrorMessage 'No TwinCAT project loaded.' -ErrorCode 'NO_PROJECT'
    }

    $dialog = Get-TcIdeModalDialog
    if ($null -ne $dialog) {
        return New-TcModalDialogResult -Dialog $dialog -Operation 'SolutionBuild.Build'
    }

    try {
        # Entire build operation wrapped in retry for RPC_E_CALL_REJECTED (IDE busy)
        $solutionBuild = $null
        try {
            $solutionBuild = Invoke-TcComRetry -MaxRetries 5 -OperationName 'SolutionBuild.Build' -TimeoutSec 600 -ScriptBlock {
                $solution = $script:TcDte.Solution
                $sb = $solution.SolutionBuild
                $sb.Build($true)  # $true = wait for completion
                Write-Output -NoEnumerate $sb
            }
        }
        catch {
            $mapped = ConvertTo-TcAdsErrorCode -InputObject $_
            if ($null -ne $mapped -and $mapped.Code -eq 'IDE_BUSY') {
                return New-TcResult -Success $false `
                    -ErrorMessage 'Build failed: IDE is busy or a dialog is blocking. Check for license dialogs — if no valid license, register a 7-day trial at https://www.beckhoff.com/twincat3/' `
                    -ErrorCode 'IDE_BUSY' `
                    -Hint $mapped.Hint
            }
            throw
        }

        # LastBuildInfo = number of projects that failed to build (NOT the error count).
        # $null when it cannot be read: a failed read must never count as "0 failed".
        $failedProjects = $null
        try { $failedProjects = [int](Invoke-TcComRetry -OperationName 'LastBuildInfo' -ScriptBlock { $solutionBuild.LastBuildInfo }) }
        catch {
            Write-Verbose "Build-TcProject: LastBuildInfo not readable ($($_.Exception.Message)); success will be decided from the Error List."
            $failedProjects = $null
        }

        $buildOutput = ''
        try {
            $buildOutput = Invoke-TcComRetry -MaxRetries 3 -OperationName 'Read build output' -ScriptBlock {
                $text = ''
                $outputWindow = $script:TcDte.ToolWindows.OutputWindow
                $buildPane = $null
                for ($i = 1; $i -le $outputWindow.OutputWindowPanes.Count; $i++) {
                    $pane = $outputWindow.OutputWindowPanes.Item($i)
                    if ($pane.Name -eq 'Build') {
                        $buildPane = $pane
                        break
                    }
                }

                if ($null -ne $buildPane) {
                    $textDoc = $buildPane.TextDocument
                    $editPoint = $textDoc.StartPoint.CreateEditPoint()
                    $text = $editPoint.GetText($textDoc.EndPoint)
                }
                $text
            }
        }
        catch {
            Write-Verbose "Could not read build output: $_"
        }

        $messages = @($buildOutput -split "`n" | Where-Object { $_.Trim() -ne '' })

        # Error List (UI Automation): the PLC compiler does not report through DTE.
        # A build that is known to have succeeded only needs a short look (leftover
        # Library Manager items); a failed / undecided build gets the default timeout.
        $errorCount = if ($null -ne $failedProjects) { $failedProjects } else { 0 }
        $warningCount = @($messages | Where-Object { $_ -match 'warning' }).Count
        $errorItems = @()
        $errorListError = $null
        $severityUnknown = $false
        $unclassifiedCount = 0
        $el = if ($null -ne $failedProjects -and $failedProjects -eq 0) { Get-TcBuildErrors -TimeoutSec 8 } else { Get-TcBuildErrors }
        if ($el.success) {
            $errorItems = @($el.data.errors)
            if ($null -ne $el.data.counts.errors) { $errorCount = [int]$el.data.counts.errors } else { $errorCount = $errorItems.Count }
            if ($null -ne $el.data.counts.warnings) { $warningCount = [int]$el.data.counts.warnings }
            if ($null -ne $el.data.PSObject.Properties['severityUnknown']) { $severityUnknown = [bool]$el.data.severityUnknown }
            if ($null -ne $el.data.PSObject.Properties['unclassified']) { $unclassifiedCount = @($el.data.unclassified).Count }
        }
        else {
            $errorListError = [string]$el.error.code
            Write-Verbose "Build-TcProject: Error List not readable ($($el.error.message)); errors falls back to LastBuildInfo."
        }

        # "Library Manager" items (file like '*Library Manager', no line) are missing /
        # unresolved libraries, not PLC code errors; they stay listed after a successful
        # build and never fail it on their own.
        $codeErrors = @($errorItems | Where-Object { -not (Test-TcLibraryManagerItem $_) })
        $libraryManagerCount = $errorItems.Count - $codeErrors.Count

        # --- success decision: (a) LastBuildInfo, (b) Error List, (c) unknown ---
        $buildSucceeded = $null
        $decidedBy = $null
        if ($null -ne $failedProjects) {
            $buildSucceeded = ($failedProjects -eq 0)
            $decidedBy = 'LastBuildInfo'
        }
        elseif ($null -eq $errorListError) {
            $realErrors = @($codeErrors | Where-Object { $_.file -notlike '*Library Manager' -and $null -ne $_.line -and $_.line -gt 0 })
            if ($realErrors.Count -gt 0) {
                $buildSucceeded = $false
                $decidedBy = 'ErrorList'
            }
            elseif ($severityUnknown -and $unclassifiedCount -gt 0) {
                # rows exist but their severity could not be isolated: not decidable
                $buildSucceeded = $null
            }
            else {
                $buildSucceeded = $true
                $decidedBy = 'ErrorList'
            }
        }

        $data = [PSCustomObject]@{
            buildSucceeded = $buildSucceeded
            errors         = $errorCount
            warnings       = $warningCount
            messages       = $messages
            failedProjects = $failedProjects
            errorItems     = $errorItems
            codeErrors     = $codeErrors
        }
        if ($null -ne $decidedBy) {
            $data | Add-Member -NotePropertyName 'decidedBy' -NotePropertyValue $decidedBy
        }
        if ($null -ne $errorListError) {
            $data | Add-Member -NotePropertyName 'errorListError' -NotePropertyValue $errorListError
        }
        if ($severityUnknown) {
            $data | Add-Member -NotePropertyName 'severityUnknown' -NotePropertyValue $true
            $data | Add-Member -NotePropertyName 'unclassified' -NotePropertyValue @($el.data.unclassified)
        }

        if ($null -eq $buildSucceeded) {
            $why = if ($null -ne $errorListError) { "LastBuildInfo not readable and Error List not readable ($errorListError)" }
                   else { "LastBuildInfo not readable and the Error List rows ($unclassifiedCount) have no usable severity" }
            New-TcResult -Success $false -ErrorMessage "Build result could not be determined: $why." `
                -ErrorCode 'BUILD_STATUS_UNKNOWN' -Hint (Get-TcErrorHint -Code 'BUILD_STATUS_UNKNOWN') -Data $data
        }
        elseif (-not $buildSucceeded) {
            $summary = "Build failed: $($codeErrors.Count) code error(s)"
            if ($libraryManagerCount -gt 0) { $summary += " (+$libraryManagerCount Library Manager)" }
            if ($codeErrors.Count -gt 0) {
                $parts = @()
                foreach ($item in @($codeErrors | Select-Object -First 3)) {
                    $loc = ''
                    if (-not [string]::IsNullOrWhiteSpace($item.file)) {
                        $loc = [IO.Path]::GetFileNameWithoutExtension([string]$item.file)
                        if ($null -ne $item.line -and $item.line -gt 0) { $loc += ":$($item.line)" }
                        $loc = " ($loc)"
                    }
                    $codeText = if ([string]::IsNullOrWhiteSpace($item.code)) { '' } else { "$($item.code) " }
                    $parts += "$codeText$($item.description)$loc"
                }
                $summary += '. ' + ($parts -join '; ')
                if ($codeErrors.Count -gt 3) { $summary += " ... (+$($codeErrors.Count - 3) more)" }
            }
            elseif ($null -ne $errorListError) {
                $summary += " ($failedProjects project(s) failed; Error List not readable: $errorListError)"
            }
            elseif ($null -ne $failedProjects) {
                $summary += " ($failedProjects project(s) failed; no code error listed in the Error List)"
            }
            New-TcResult -Success $false -ErrorMessage $summary -ErrorCode 'BUILD_FAILED' -Hint (Get-TcErrorHint -Code 'BUILD_FAILED_COMPILE') -Data $data
        }
        else {
            New-TcResult -Success $true -Data $data
        }
    }
    catch {
        $errData = $null
        if ($null -ne $script:TcLastModalDialog) {
            $errData = [PSCustomObject]@{ dialogTitle = [string]$script:TcLastModalDialog.Title; dialogText = [string]$script:TcLastModalDialog.Text }
        }
        New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'BUILD_FAILED' -MessagePrefix 'Build failed' -Data $errData
    }
}
