function Reset-TcSolution {
    <#
    .SYNOPSIS
        Closes the open solution without saving and reopens it (Solution.Close($false) +
        Connect-TcIde -SolutionPath), so the IDE reloads every project file from disk.
    .DESCRIPTION
        Use after project files (.TcPOU, .TcGVL, .TcDUT, .plcproj ...) were changed ON DISK
        by another tool (an AI editor, git checkout, a generator) while the solution is open:
          - a file that is NOT open in a document window is picked up by XAE on its own
            within ~5 s; nothing to do.
          - a file that IS open in a document window makes XAE show the modal "File has
            been changed outside the environment. Reload the new file?" ~1 s after the
            write. It blocks every DTE call (IDE_MODAL_DIALOG, data.dialogKind
            'reload-prompt'), the Automation Interface has no reload command and the VS
            option AutoloadExternalChanges does not suppress it. Closing and reopening the
            solution is the dialog-free way (2026-10-20 reload-experiment scenario S3:
            ~9 s on a 4024 32-bit XAE, against ~45 s for kill + relaunch). Do it BEFORE the
            next DTE call, or close the document first.
        Write-TcPouCode / Add-TcPou write through COM (the IDE itself saves the file), so
        they never need this.

        Steps:
          1. modal-dialog pre-check (Get-TcIdeModalDialog): a dialog that is already up
             would block Solution.Close forever, so it is reported as IDE_MODAL_DIALOG
             instead (dismiss it in the IDE, then call again).
          2. Solution.Close($false) in Invoke-TcComRetry (unsaved editor changes are
             discarded); the old ITcSysManager is released.
          3. Connect-TcIde -SolutionPath <sln> -ProgId <current> -NoLaunch: the same ROT
             selection as a normal connect; the instance that just closed its solution is
             chosen as 'no-solution-open', the solution is opened and ITcSysManager
             re-acquired (SilentMode is re-enabled as well). data.sameIde tells whether
             the previous IDE pid was reused; another instance is reported in data.warning.
        The ADS connection is not touched. No dialog, no Start-Sleep.
    .PARAMETER SolutionPath
        .sln to reopen. Default: the solution Connect-TcIde / Open-TcProject opened
        ($script:TcSolutionPath), else the solution currently open in the IDE.
    .PARAMETER TimeoutSec
        Expected upper bound for Solution.Close (Invoke-TcComRetry -TimeoutSec). Default 60.
    .EXAMPLE
        # AI changed MAIN.TcPOU on disk while it was open in an XAE editor:
        Reset-TcSolution
        Build-TcProject
    .OUTPUTS
        data.solution              path that was reopened
        data.closed                Solution.Close returned (always true on success)
        data.closeSec              seconds Solution.Close took
        data.totalSec              seconds for close + reopen
        data.ideProcessId          IDE pid after the reopen
        data.previousIdeProcessId  IDE pid before
        data.sameIde               both pids equal
        data.selectedBy / sysManagerAvailable / silentMode / amsNetId / warning
                                   as reported by Connect-TcIde
        Errors: NOT_CONNECTED, NO_SOLUTION, FILE_NOT_FOUND, IDE_MODAL_DIALOG,
        SOLUTION_CLOSE_FAILED (or IDE_BUSY / IDE_TIMEOUT / IDE_CRASHED from the close),
        and any Connect-TcIde error code when the reopen fails (data.closed = true then).
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$SolutionPath,

        [Parameter()]
        [ValidateRange(5, 600)]
        [int]$TimeoutSec = 60
    )

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }

    $dte = $script:TcDte
    $progId = $script:TcProgId
    $previousPid = 0
    if ($null -ne $script:TcIdeProcessId) { try { $previousPid = [int]$script:TcIdeProcessId } catch { $previousPid = 0 } }

    # --- resolve the solution to reopen ---
    $path = $SolutionPath
    if ([string]::IsNullOrWhiteSpace($path) -and -not [string]::IsNullOrWhiteSpace($script:TcSolutionPath)) {
        $path = [string]$script:TcSolutionPath
    }
    if ([string]::IsNullOrWhiteSpace($path)) {
        try {
            $path = [string](Invoke-TcComRetry -OperationName 'Solution.FullName' -ScriptBlock { [string]$dte.Solution.FullName })
        }
        catch {
            return New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'NO_SOLUTION' -MessagePrefix 'Could not read the path of the open solution'
        }
    }
    if ([string]::IsNullOrWhiteSpace($path)) {
        return New-TcResult -Success $false -ErrorMessage 'No solution is open and no -SolutionPath was given; nothing to reopen.' `
            -ErrorCode 'NO_SOLUTION' -Hint (Get-TcErrorHint -Code 'NO_SOLUTION')
    }
    if (-not (Test-Path -LiteralPath $path)) {
        return New-TcResult -Success $false -ErrorMessage "Solution file not found: $path" -ErrorCode 'FILE_NOT_FOUND'
    }
    $path = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $path).Path)

    # A modal dialog (typically the reload prompt itself) blocks Solution.Close forever.
    $dialog = Get-TcIdeModalDialog
    if ($null -ne $dialog) {
        return New-TcModalDialogResult -Dialog $dialog -Operation 'Reset-TcSolution (Solution.Close)' `
            -Data ([PSCustomObject]@{ solution = $path; ideProcessId = $previousPid })
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Invoke-TcComRetry -OperationName 'Solution.Close' -TimeoutSec $TimeoutSec -ScriptBlock { $dte.Solution.Close($false) } | Out-Null
    }
    catch {
        return New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'SOLUTION_CLOSE_FAILED' -MessagePrefix 'Solution.Close failed' `
            -Data ([PSCustomObject]@{ solution = $path; closed = $false; ideProcessId = $previousPid })
    }
    $closeSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)

    # The ITcSysManager of the closed solution is dead; Connect-TcIde acquires the new one.
    if ($null -ne $script:TcSysManager) {
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($script:TcSysManager) | Out-Null } catch { }
        $script:TcSysManager = $null
    }

    $connectParams = @{ SolutionPath = $path; NoLaunch = $true }
    if (-not [string]::IsNullOrWhiteSpace($progId)) { $connectParams['ProgId'] = $progId }
    $connect = Connect-TcIde @connectParams

    if (-not $connect.success) {
        # Keep the code / hint of Connect-TcIde, say where it happened, and carry its data.
        $err = $connect.error
        $data = [PSCustomObject]@{ solution = $path; closed = $true; closeSec = $closeSec; previousIdeProcessId = $previousPid }
        $dp = $connect.PSObject.Properties['data']
        if ($null -ne $dp -and $null -ne $dp.Value) {
            foreach ($p in $dp.Value.PSObject.Properties) { $data | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force }
        }
        $params = @{
            Success      = $false
            ErrorMessage = "Solution closed but the reopen failed: $($err.message)"
            ErrorCode    = [string]$err.code
            Data         = $data
        }
        $hp = $err.PSObject.Properties['hint']
        if ($null -ne $hp -and -not [string]::IsNullOrWhiteSpace([string]$hp.Value)) { $params['Hint'] = [string]$hp.Value }
        return New-TcResult @params
    }

    $cd = $connect.data
    $newPid = 0
    try { $newPid = [int]$cd.ideProcessId } catch { $newPid = 0 }
    $sameIde = ($previousPid -gt 0 -and $newPid -eq $previousPid)

    $data = [PSCustomObject]@{
        solution             = $path
        closed               = $true
        closeSec             = $closeSec
        totalSec             = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        ideProcessId         = $newPid
        previousIdeProcessId = $previousPid
        sameIde              = $sameIde
        selectedBy           = $cd.selectedBy
        sysManagerAvailable  = [bool]$cd.sysManagerAvailable
        silentMode           = $cd.silentMode
    }
    foreach ($name in @('amsNetId', 'warning')) {
        $prop = $cd.PSObject.Properties[$name]
        if ($null -ne $prop) { $data | Add-Member -NotePropertyName $name -NotePropertyValue $prop.Value -Force }
    }
    if (-not $sameIde) {
        $note = "Connect-TcIde picked IDE pid $newPid instead of the previous pid $previousPid; the solution was reopened in another instance."
        $wp = $data.PSObject.Properties['warning']
        if ($null -ne $wp -and -not [string]::IsNullOrWhiteSpace([string]$wp.Value)) { $note = "$($wp.Value) $note" }
        $data | Add-Member -NotePropertyName 'warning' -NotePropertyValue $note -Force
    }

    New-TcResult -Success $true -Data $data
}
