function Disconnect-TcIde {
    <#
    .SYNOPSIS
        Disconnects from the TwinCAT IDE and releases COM references.
    .PARAMETER Quit
        Also close the solution (without saving) and quit the IDE instance this
        session is connected to. Use this to clean up an IDE that Connect-TcIde
        launched; do not use it on an IDE the user opened themselves.
    #>
    [CmdletBinding()]
    param(
        [switch]$Quit
    )

    $quitResult = $null
    if ($Quit -and ($null -eq $script:TcDte -or -not $script:TcIdeConnected)) {
        # Nothing to quit: never connected, already disconnected, or the IDE state was reset
        # after IDE_CRASHED. Reported as success with quit = false instead of a COM error text.
        $quitResult = @{ solutionClosed = $false; quit = $false; error = $null; reason = 'not connected' }
    }
    elseif ($Quit) {
        $dte = $script:TcDte
        $quitResult = @{ solutionClosed = $false; quit = $false; error = $null; reason = $null }
        try {
            Invoke-TcComRetry -OperationName 'Solution.Close' -TimeoutSec 60 -ScriptBlock {
                $sol = $dte.Solution
                if ($null -eq $sol) { throw 'DTE.Solution is null (the DTE reference is no longer usable)' }
                $sol.Close($false)
            } | Out-Null
            $quitResult.solutionClosed = $true
        }
        catch { $quitResult.error = "Solution.Close: $($_.Exception.Message)" }
        try {
            Invoke-TcComRetry -OperationName 'DTE.Quit' -TimeoutSec 60 -ScriptBlock { $dte.Quit() } | Out-Null
            $quitResult.quit = $true
        }
        catch {
            # The IDE drops the RPC connection while it exits, so DTE.Quit() itself usually fails
            # with a dead-RPC error (or IDE_CRASHED from Invoke-TcComRetry once the process is
            # gone). That is the expected outcome of a successful quit, not a crash.
            if ($_.Exception.Message -match 'IDE_CRASHED|0x80010108|0x800706BE|0x800706BA') {
                $quitResult.quit = $true
            }
            else {
                $quitResult.error = (($quitResult.error, "DTE.Quit: $($_.Exception.Message)") -ne $null) -join '; '
            }
        }
    }

    # Restore the SilentMode value Connect-TcIde found, unless the IDE was quit.
    if (-not $Quit -and $null -ne $script:TcAutomationSettings -and $null -ne $script:TcSilentModeOriginal) {
        $settingsRestore = $script:TcAutomationSettings
        $silentRestore = [bool]$script:TcSilentModeOriginal
        try {
            Invoke-TcComRetry -OperationName 'SilentMode restore' -ScriptBlock { $settingsRestore.SilentMode = $silentRestore } | Out-Null
        }
        catch { Write-Verbose "SilentMode could not be restored to $silentRestore ($($_.Exception.Message))" }
    }

    if ($null -ne $script:TcAutomationSettings) {
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($script:TcAutomationSettings) | Out-Null } catch { }
    }
    $script:TcAutomationSettings = $null
    $script:TcSilentMode = $false
    $script:TcSilentModeOriginal = $null

    if ($null -ne $script:TcSysManager) {
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($script:TcSysManager) | Out-Null } catch { }
        $script:TcSysManager = $null
    }

    if ($null -ne $script:TcDte) {
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($script:TcDte) | Out-Null } catch { }
        $script:TcDte = $null
    }

    $script:TcIdeConnected = $false
    $script:TcProgId = $null
    $script:TcSolutionPath = $null
    $script:TcIdeProcessId = $null
    $script:TcIdeMainHwnd = 0
    $script:TcLastModalDialog = $null

    $data = [PSCustomObject]@{ message = 'Disconnected from TwinCAT IDE.' }
    if ($null -ne $quitResult) {
        $message = if ($quitResult.quit) { 'Disconnected and IDE quit.' }
                   elseif ($quitResult.reason -eq 'not connected') { 'Not connected to an IDE; nothing to quit.' }
                   else { 'Disconnected; IDE quit failed (see quitError).' }
        $data = [PSCustomObject]@{
            message        = $message
            solutionClosed = $quitResult.solutionClosed
            quit           = $quitResult.quit
            quitError      = $quitResult.error
        }
        if ($null -ne $quitResult.reason) { $data | Add-Member -NotePropertyName 'reason' -NotePropertyValue $quitResult.reason }
    }
    New-TcResult -Success $true -Data $data
}
