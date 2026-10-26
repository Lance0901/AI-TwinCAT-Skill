function Open-TcProject {
    <#
    .SYNOPSIS
        Opens an existing TwinCAT solution file in the connected IDE.
    .PARAMETER Path
        Path to the .sln or .tsproj file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }

    if (-not (Test-Path $Path)) {
        return New-TcResult -Success $false -ErrorMessage "File not found: $Path" -ErrorCode 'FILE_NOT_FOUND'
    }

    try {
        $script:TcDte.Solution.Open($Path)

        # Remembered for Reset-TcSolution (Solution.Close + reopen).
        $openedSln = try { [string]$script:TcDte.Solution.FullName } catch { '' }
        if ([string]::IsNullOrWhiteSpace($openedSln)) { $openedSln = (Resolve-Path -LiteralPath $Path).Path }
        $script:TcSolutionPath = try { [IO.Path]::GetFullPath($openedSln) } catch { $openedSln }
        # The IDE now has ANOTHER solution: update the #29 session record, or a later
        # Connect-TcIde would take this IDE for the previous solution while it is blocked.
        if ($null -ne $script:TcIdeProcessId) { Save-TcIdeSolutionRecord -ProcessId ([int]$script:TcIdeProcessId) -Solution $script:TcSolutionPath }

        # Refresh ITcSysManager
        $script:TcSysManager = $null
        $sm = Get-TcSysManager

        New-TcResult -Success $true -Data ([PSCustomObject]@{
            solution            = $script:TcDte.Solution.FullName
            sysManagerAvailable = ($null -ne $sm)
        })
    }
    catch {
        New-TcResult -Success $false -ErrorMessage "Failed to open project: $_" -ErrorCode 'PROJECT_OPEN_FAILED'
    }
}
