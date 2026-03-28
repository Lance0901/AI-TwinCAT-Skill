function Build-TcProject {
    <#
    .SYNOPSIS
        Builds the PLC project and returns build results.
    .DESCRIPTION
        Uses DTE SolutionBuild with retry for RPC_E_CALL_REJECTED (IDE busy).
        Includes license check guidance if IDE remains unresponsive.
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

    try {
        # Entire build operation wrapped in retry for RPC_E_CALL_REJECTED
        $maxRetries = 5
        $built = $false
        $solutionBuild = $null

        for ($retry = 1; $retry -le $maxRetries; $retry++) {
            try {
                $solution = $script:TcDte.Solution
                $solutionBuild = $solution.SolutionBuild
                $solutionBuild.Build($true)  # $true = wait for completion
                $built = $true
                break
            }
            catch {
                if ($_.Exception.Message -match 'RPC_E_CALL_REJECTED|0x80010001') {
                    Write-Verbose "Build attempt ${retry}/${maxRetries}: IDE busy, retrying in 5 seconds..."
                    Start-Sleep -Seconds 5
                }
                else {
                    throw
                }
            }
        }

        if (-not $built) {
            return New-TcResult -Success $false `
                -ErrorMessage 'Build failed: IDE is busy or a dialog is blocking. Check for license dialogs — if no valid license, register a 7-day trial at https://www.beckhoff.com/twincat3/' `
                -ErrorCode 'IDE_BUSY'
        }

        # Read build output
        $errorCount = $solutionBuild.LastBuildInfo

        $buildOutput = ''
        try {
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
                $buildOutput = $editPoint.GetText($textDoc.EndPoint)
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
        New-TcResult -Success $false -ErrorMessage "Build failed: $_" -ErrorCode 'BUILD_FAILED'
    }
}
