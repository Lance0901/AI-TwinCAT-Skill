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
    if ($Quit -and $null -ne $script:TcDte) {
        $dte = $script:TcDte
        $quitResult = @{ solutionClosed = $false; quit = $false; error = $null }
        try {
            Invoke-TcComRetry -OperationName 'Solution.Close' -TimeoutSec 60 -ScriptBlock { $dte.Solution.Close($false) } | Out-Null
            $quitResult.solutionClosed = $true
        }
        catch { $quitResult.error = "Solution.Close: $($_.Exception.Message)" }
        try {
            Invoke-TcComRetry -OperationName 'DTE.Quit' -TimeoutSec 60 -ScriptBlock { $dte.Quit() } | Out-Null
            $quitResult.quit = $true
        }
        catch { $quitResult.error = (($quitResult.error, "DTE.Quit: $($_.Exception.Message)") -ne $null) -join '; ' }
    }

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
    $script:TcIdeProcessId = $null
    $script:TcIdeMainHwnd = 0
    $script:TcLastModalDialog = $null

    $data = [PSCustomObject]@{ message = 'Disconnected from TwinCAT IDE.' }
    if ($null -ne $quitResult) {
        $data = [PSCustomObject]@{
            message        = if ($quitResult.quit) { 'Disconnected and IDE quit.' } else { 'Disconnected; IDE quit failed (see quitError).' }
            solutionClosed = $quitResult.solutionClosed
            quit           = $quitResult.quit
            quitError      = $quitResult.error
        }
    }
    New-TcResult -Success $true -Data $data
}
