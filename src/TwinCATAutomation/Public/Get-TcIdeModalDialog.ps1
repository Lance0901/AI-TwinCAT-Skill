function Get-TcIdeModalDialog {
    <#
    .SYNOPSIS
        Reports the modal dialog (Assertion Failed, license prompt, reload prompt ...) that
        blocks the connected TwinCAT IDE, as JSON.
    .DESCRIPTION
        Scans the top-level windows of the IDE process with UI Automation (in a separate runspace
        with a hard timeout, so a blocked IDE message loop cannot hang the call) and returns the
        first dialog-like window. This is the cmdlet the IDE_MODAL_DIALOG / IDE_BUSY hints refer
        to (#86); internally it wraps the private Find-TcIdeModalDialog, which the other cmdlets
        use for their pre-flight checks.

        It does not touch the IDE through COM, so it also works while a modal dialog makes DTE calls
        fail with IDE_BUSY. It only reads: the dialog is not answered or closed (Reset-TcSolution
        handles reload prompts). In the MCP server the same data is the GetIdeModalDialog tool.

        success = true and data.scanComplete = true: the scan finished. data.dialog is then $null
        when no dialog is open (or the process is gone), otherwise
        { title, text, kind, reloadTarget, hwnd, buttons[{ id, name }] }:
        kind 'reload-prompt' (reloadTarget 'file' | 'project') or 'unknown' (reloadTarget $null).
        A scan that did not finish within -TimeoutSec (or failed) is NOT reported as "no dialog"
        (#42): success = false, code MODAL_SCAN_INCOMPLETE, data.scanComplete = false,
        data.dialog = $null, data.modalScan = { reason (timeout | prepare-timeout | error),
        timeoutSec, elapsedMs, prepareMs, message }; retry with a larger -TimeoutSec.
        The first scan of a process loads UI Automation and compiles its helper types; that
        cold start runs before the -TimeoutSec budget starts.
        data.ideProcessId (same name as the MCP tool and the hints) is the pid that was scanned.
    .PARAMETER ProcessId
        IDE process id. Default 0 = the pid Connect-TcIde recorded. Pass it explicitly to inspect
        an IDE this session is not connected to (e.g. one that blocked Connect-TcIde).
    .PARAMETER TimeoutSec
        Maximum time for the UI Automation scan, 1..60. Default 5.
    .EXAMPLE
        Get-TcIdeModalDialog | ConvertFrom-Json
    .EXAMPLE
        Get-TcIdeModalDialog -ProcessId 12345 -TimeoutSec 15
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [int]$ProcessId = 0,

        [Parameter()]
        [ValidateRange(1, 60)]
        [int]$TimeoutSec = 5
    )

    if ($ProcessId -le 0 -and $null -ne $script:TcIdeProcessId) {
        try { $ProcessId = [int]$script:TcIdeProcessId } catch { $ProcessId = 0 }
    }
    if ($ProcessId -le 0) {
        return New-TcResult -Success $false -ErrorCode 'NOT_CONNECTED' `
            -ErrorMessage 'No IDE process id is known: the module is not connected to an IDE and -ProcessId was not given.' `
            -Hint (Get-TcErrorHint -Code 'NOT_CONNECTED_IDE')
    }

    $dialog = $null
    try { $dialog = Find-TcIdeModalDialog -ProcessId $ProcessId -TimeoutSec $TimeoutSec }
    catch {
        $dialog = New-TcModalScanIncomplete -ProcessId $ProcessId -Reason 'error' -TimeoutSec $TimeoutSec -Message "the scan threw: $($_.Exception.Message)"
    }

    if (Test-TcModalScanIncomplete $dialog) {
        $info = ConvertTo-TcModalScanInfo -Scan $dialog
        return New-TcResult -Success $false -ErrorCode 'MODAL_SCAN_INCOMPLETE' `
            -ErrorMessage "MODAL_SCAN_INCOMPLETE: the modal-dialog scan of IDE pid $ProcessId did not complete ($($info.reason): $($info.message)); it is unknown whether a dialog is open." `
            -Hint (Get-TcErrorHint -Code 'MODAL_SCAN_INCOMPLETE') `
            -Data ([PSCustomObject][ordered]@{
                ideProcessId = $ProcessId
                scanComplete = $false
                dialog       = $null
                modalScan    = $info
            })
    }

    $dialogOut = $null
    if ($null -ne $dialog) { $dialogOut = ConvertTo-TcDialogRecord -Dialog $dialog }
    New-TcResult -Success $true -Data ([PSCustomObject][ordered]@{
            ideProcessId = $ProcessId
            scanComplete = $true
            dialog       = $dialogOut
        })
}
