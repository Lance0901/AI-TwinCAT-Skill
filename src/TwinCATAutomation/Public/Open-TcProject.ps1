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
