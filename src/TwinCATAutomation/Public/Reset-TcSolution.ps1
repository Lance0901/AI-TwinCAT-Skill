function Reset-TcSolution {
    <#
    .SYNOPSIS
        Closes every document and the solution without saving, reopens the solution on the
        same IDE and reconnects, so the IDE reloads every project file from disk.
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
            solution is the dialog-free way (2026-10-20, 4024 32-bit XAE: 20-25 s in total,
            Solution.Open 7-9 s + Connect-TcIde reconnect 12-13 s, against ~45 s for
            kill + relaunch).
        Write-TcPouCode / Add-TcPou write into the IDE's edit buffer through COM (the file
        on disk is only written when the IDE saves, e.g. before a Build), so they never
        trigger the prompt and never need this.

        Steps:
          1. Get-TcIdeModalDialog. The reload prompt itself (Kind 'reload-prompt') is
             dismissed with WM_CLOSE (Close-TcReloadPrompt; the solution is reopened right
             after, so the answer does not matter) and data.dismissedReloadPrompt = true.
             Any other dialog is reported as IDE_MODAL_DIALOG (it would block
             Solution.Close too).
          2. Documents.CloseAll(vsSaveChangesNo): XAE restores the document windows of
             the last session when a solution is (re)opened, so a changed .TcPOU that
             stays open would trigger the prompt again on the next disk edit.
             data.closedDocuments = number of documents that were open.
          3. Solution.Close($false) in Invoke-TcComRetry; the old ITcSysManager is released.
          4. Solution.Open(<sln>) on the SAME DTE (Invoke-TcComRetry, 7-9 s): an IDE with
             no solution open is never reused by Connect-TcIde -SolutionPath (it belongs
             to whoever opened it), so the reopen must happen on the instance we hold.
          5. Connect-TcIde -SolutionPath <sln> -ProgId <current> -NoLaunch: picks the same
             instance as 'solution-match', re-acquires ITcSysManager, re-enables SilentMode.
             data.sameIde tells whether the previous IDE pid was reused.
        The ADS connection is not touched. No dialog, no Start-Sleep beyond the polls.
    .PARAMETER SolutionPath
        .sln to reopen. Default: the solution Connect-TcIde / Open-TcProject opened
        ($script:TcSolutionPath), else the solution currently open in the IDE.
    .PARAMETER TimeoutSec
        Expected upper bound for each of Documents.CloseAll, Solution.Close and
        Solution.Open (Invoke-TcComRetry -TimeoutSec). Default 120.
    .EXAMPLE
        # AI changed MAIN.TcPOU on disk while it was open in an XAE editor:
        Reset-TcSolution
        Build-TcProject
    .OUTPUTS
        data.solution              path that was reopened
        data.dismissedReloadPrompt the reload prompt was up and was closed by this cmdlet
        data.closedDocuments       documents closed before Solution.Close
        data.closed                Solution.Close returned
        data.closeSec              seconds for CloseAll + Solution.Close
        data.openSec               seconds Solution.Open took
        data.connectSec            seconds the Connect-TcIde reconnect took
        data.totalSec              seconds in total (measured 20-25 s)
        data.ideProcessId          IDE pid after the reconnect
        data.previousIdeProcessId  IDE pid before
        data.sameIde               both pids equal
        data.selectedBy / sysManagerAvailable / silentMode / amsNetId / warning
                                   as reported by Connect-TcIde
        Errors: NOT_CONNECTED, NO_SOLUTION, FILE_NOT_FOUND, IDE_MODAL_DIALOG,
        SOLUTION_CLOSE_FAILED, PROJECT_OPEN_FAILED (or IDE_BUSY / IDE_TIMEOUT /
        IDE_CRASHED from the COM calls), and any Connect-TcIde error code when the
        reconnect fails (data.closed / data.reopened say how far it got).
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$SolutionPath,

        [Parameter()]
        [ValidateRange(5, 600)]
        [int]$TimeoutSec = 120
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

    $progress = [ordered]@{
        solution             = $path
        dismissedReloadPrompt = $false
        closedDocuments      = 0
        closed               = $false
        reopened             = $false
        previousIdeProcessId = $previousPid
    }
    function Get-ProgressData { param([hashtable]$Extra) $d = [PSCustomObject]$progress; if ($null -ne $Extra) { foreach ($k in $Extra.Keys) { $d | Add-Member -NotePropertyName $k -NotePropertyValue $Extra[$k] -Force } }; $d }

    # --- 1. modal dialog: the reload prompt is dismissed, anything else is reported ---
    $dialog = Get-TcIdeModalDialog
    if ($null -ne $dialog) {
        if ([string]$dialog.Kind -eq 'reload-prompt') {
            $closeResult = Close-TcReloadPrompt -Dialog $dialog
            if (-not $closeResult.Dismissed) {
                return New-TcModalDialogResult -Dialog $dialog -Operation "Reset-TcSolution (reload prompt could not be dismissed: $($closeResult.Reason))" `
                    -Data (Get-ProgressData)
            }
            $progress.dismissedReloadPrompt = $true
            Write-Verbose "Reset-TcSolution: reload prompt dismissed ($($closeResult.Reason))."
        }
        else {
            return New-TcModalDialogResult -Dialog $dialog -Operation 'Reset-TcSolution (Documents.CloseAll / Solution.Close)' -Data (Get-ProgressData)
        }
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    # --- 2. close every document (vsSaveChangesNo = 2) ---
    try {
        $progress.closedDocuments = [int](Invoke-TcComRetry -OperationName 'Documents.CloseAll' -TimeoutSec $TimeoutSec -ScriptBlock {
            $docs = $dte.Documents
            $n = 0
            if ($null -ne $docs) {
                try { $n = [int]$docs.Count } catch { $n = 0 }
                $docs.CloseAll(2)
            }
            $n
        })
    }
    catch {
        return New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'SOLUTION_CLOSE_FAILED' -MessagePrefix 'Documents.CloseAll failed' -Data (Get-ProgressData)
    }

    # --- 3. close the solution without saving ---
    try {
        Invoke-TcComRetry -OperationName 'Solution.Close' -TimeoutSec $TimeoutSec -ScriptBlock { $dte.Solution.Close($false) } | Out-Null
    }
    catch {
        return New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'SOLUTION_CLOSE_FAILED' -MessagePrefix 'Solution.Close failed' -Data (Get-ProgressData)
    }
    $progress.closed = $true
    $closeSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)

    # The ITcSysManager of the closed solution is dead; Connect-TcIde acquires the new one.
    if ($null -ne $script:TcSysManager) {
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($script:TcSysManager) | Out-Null } catch { }
        $script:TcSysManager = $null
    }

    # --- 4. reopen on the same DTE ---
    $openSw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Invoke-TcComRetry -OperationName 'Solution.Open' -TimeoutSec $TimeoutSec -ScriptBlock { $dte.Solution.Open($path) } | Out-Null
    }
    catch {
        return New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'PROJECT_OPEN_FAILED' -MessagePrefix 'Solution closed but Solution.Open failed' `
            -Data (Get-ProgressData -Extra @{ closeSec = $closeSec })
    }
    $progress.reopened = $true
    $openSec = [math]::Round($openSw.Elapsed.TotalSeconds, 1)

    # --- 5. reconnect: the instance now has the target solution open -> 'solution-match' ---
    $connectParams = @{ SolutionPath = $path; NoLaunch = $true }
    if (-not [string]::IsNullOrWhiteSpace($progId)) { $connectParams['ProgId'] = $progId }
    $connectSw = [System.Diagnostics.Stopwatch]::StartNew()
    $connect = Connect-TcIde @connectParams
    $connectSec = [math]::Round($connectSw.Elapsed.TotalSeconds, 1)

    if (-not $connect.success) {
        # Keep the code / hint of Connect-TcIde, say where it happened, and carry its data.
        $err = $connect.error
        $data = Get-ProgressData -Extra @{ closeSec = $closeSec; openSec = $openSec; connectSec = $connectSec }
        $dp = $connect.PSObject.Properties['data']
        if ($null -ne $dp -and $null -ne $dp.Value) {
            foreach ($p in $dp.Value.PSObject.Properties) { $data | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force }
        }
        $params = @{
            Success      = $false
            ErrorMessage = "Solution reopened but Connect-TcIde failed: $($err.message)"
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

    $data = Get-ProgressData -Extra ([ordered]@{
        closeSec            = $closeSec
        openSec             = $openSec
        connectSec          = $connectSec
        totalSec            = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        ideProcessId        = $newPid
        sameIde             = $sameIde
        selectedBy          = $cd.selectedBy
        sysManagerAvailable = [bool]$cd.sysManagerAvailable
        silentMode          = $cd.silentMode
    })
    foreach ($name in @('amsNetId', 'warning')) {
        $prop = $cd.PSObject.Properties[$name]
        if ($null -ne $prop) { $data | Add-Member -NotePropertyName $name -NotePropertyValue $prop.Value -Force }
    }
    if (-not $sameIde) {
        $note = "Connect-TcIde picked IDE pid $newPid instead of the previous pid $previousPid."
        $wp = $data.PSObject.Properties['warning']
        if ($null -ne $wp -and -not [string]::IsNullOrWhiteSpace([string]$wp.Value)) { $note = "$($wp.Value) $note" }
        $data | Add-Member -NotePropertyName 'warning' -NotePropertyValue $note -Force
    }

    New-TcResult -Success $true -Data $data
}
