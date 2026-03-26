function Send-TcPlcProgram {
    <#
    .SYNOPSIS
        Downloads the compiled PLC program to the target runtime — no dialog popups.
    .DESCRIPTION
        This is a convenience wrapper around Enter-TcPlcOnline.
        Login(3) handles both login and download in one call.
    .PARAMETER PlcProjectPath
        Tree path to PLC project. Default auto-detects from TIPC.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$PlcProjectPath
    )

    # Login(3) already handles download, so delegate
    Enter-TcPlcOnline -PlcProjectPath $PlcProjectPath
}
