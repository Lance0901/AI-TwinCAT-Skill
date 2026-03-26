function Build-TcProject {
    <#
    .SYNOPSIS
        Builds the PLC project and returns build results.
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
        # Get ITcPlcProject from the PLC project tree item
        $plcConfig = $sm.LookupTreeItem('TIPC')
        $plcProjectItem = $plcConfig.Child(1)

        # Build using DTE Solution Build
        $solution = $script:TcDte.Solution
        $solutionBuild = $solution.SolutionBuild
        $solutionBuild.Build($true)  # $true = wait for completion

        # Read build output
        $errorCount = $solutionBuild.LastBuildInfo
        $outputWindow = $script:TcDte.ToolWindows.OutputWindow
        $buildPane = $null
        for ($i = 1; $i -le $outputWindow.OutputWindowPanes.Count; $i++) {
            $pane = $outputWindow.OutputWindowPanes.Item($i)
            if ($pane.Name -eq 'Build') {
                $buildPane = $pane
                break
            }
        }

        $buildOutput = ''
        if ($null -ne $buildPane) {
            $textDoc = $buildPane.TextDocument
            $editPoint = $textDoc.StartPoint.CreateEditPoint()
            $buildOutput = $editPoint.GetText($textDoc.EndPoint)
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
