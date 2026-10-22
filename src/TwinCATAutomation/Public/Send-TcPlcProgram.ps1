function Send-TcPlcProgram {
    <#
    .SYNOPSIS
        Downloads the compiled PLC program to the target runtime — no dialog popups.
    .DESCRIPTION
        This is a convenience wrapper around Enter-TcPlcOnline.
        Enter-TcPlcOnline -LoginMode Download (PLC_LOGIN_FLAGS FORCEDOWNLOAD = 4, prompts answered by SilentMode) does login + full download in one call.
    .PARAMETER PlcProjectPath
        Tree path to PLC project. Default auto-detects from TIPC.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$PlcProjectPath
    )

    # FORCEDOWNLOAD (4) handles download; the global SilentMode answers prompts
    Enter-TcPlcOnline -PlcProjectPath $PlcProjectPath -LoginMode Download   # FORCEDOWNLOAD (4); SilentMode answers prompts
}
