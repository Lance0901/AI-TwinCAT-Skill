function Build-TcProject {
    <#
    .SYNOPSIS
        Builds the PLC project and returns build results.
    .DESCRIPTION
        Uses DTE SolutionBuild with retry for RPC_E_CALL_REJECTED (IDE busy).
        Includes license check guidance if IDE remains unresponsive.
        Before the build the IDE is checked for a modal dialog (e.g. the XAE
        "Assertion Failed" box that appears after repeatedly opening/closing a
        solution): SolutionBuild.Build would then block forever, so IDE_MODAL_DIALOG
        is returned instead (data.dialogTitle / dialogText).
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

        # Read build output
        $errorCount = Invoke-TcComRetry -OperationName 'LastBuildInfo' -ScriptBlock { $solutionBuild.LastBuildInfo }

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

        $messages = $buildOutput -split "`n" | Where-Object { $_.Trim() -ne '' }

        $data = [PSCustomObject]@{
            errors   = $errorCount
            warnings = ($messages | Where-Object { $_ -match 'warning' }).Count
            messages = $messages
        }

        if ($errorCount -gt 0) {
            New-TcResult -Success $false -ErrorMessage 'Build failed' -ErrorCode 'BUILD_FAILED' -Data $data
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
