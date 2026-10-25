function Clear-TcProject {
    <#
    .SYNOPSIS
        Cleans the open solution (Build > Clean Solution) and waits until the clean is done.
    .DESCRIPTION
        Removes the build output of every project of the active solution configuration, e.g.
        before a Build-TcProject that must start from scratch. Steps:
          1. Assert-TcConnection, then Get-TcIdeModalDialog: a dialog blocks the call, so
             IDE_MODAL_DIALOG is returned without trying.
          2. DTE.Solution and Solution.SolutionBuild are read until both are non-null (500 ms
             polls, at most 15 s; data.nullReads counts the $null answers). The old
             lifecycle-smoke step 03a ($script:TcDte.Solution.SolutionBuild.Clean) failed with
             "You cannot call a method on a null-valued expression" 0.2 s after a successful
             Connect-TcIde (measured 2026-10-19 and 2026-10-20, 4024 32-bit XAE Shell, issue
             #18); which link was $null is not known and it did not recur in 12 runs on
             2026-10-25 (nullReads 0), so the poll is a guard plus a record if it happens again.
             Still $null after 15 s: CLEAN_FAILED. Solution.IsOpen false: NO_SOLUTION.
          3. SolutionBuild.Clean($false) starts the clean and returns at once (Invoke-TcComRetry
             for RPC_E_CALL_REJECTED). The synchronous Clean($true) is not used: like Build($true)
             it does not return through out-of-process COM in VS2022 (see Build-TcProject).
             SolutionBuild.Clean / BuildState (vsBuildState 1 NotStarted, 2 InProgress, 3 Done):
             https://learn.microsoft.com/en-us/dotnet/api/envdte.solutionbuild.clean and
             https://learn.microsoft.com/en-us/dotnet/api/envdte.vsbuildstate
          4. BuildState is polled every 500 ms until Done (accepted once a not-Done state was
             seen or after a 1 s grace period); the IDE is checked for a modal dialog every ~5 s
             (IDE_MODAL_DIALOG). Not Done within -TimeoutSec: CLEAN_TIMEOUT.
          5. Readback: success only with BuildState = 3 and SolutionBuild.LastBuildInfo (number
             of projects that failed, https://learn.microsoft.com/en-us/dotnet/api/envdte.solutionbuild.lastbuildinfo)
             = 0 (or unreadable: data.failedProjects $null). > 0: the Error List is read (Get-TcBuildErrors,
             data.errorItems); only unresolved-library rows ('<plc>.Library Manager', no line) -> success
             with data.warning; anything else (or an unreadable Error List) -> CLEAN_FAILED.
    .PARAMETER TimeoutSec
        Maximum time in seconds for the clean (BuildState = Done). Default 300.
    .EXAMPLE
        Clear-TcProject
        Build-TcProject
    .OUTPUTS
        data.buildState      final SolutionBuild.BuildState (3 = Done)
        data.failedProjects  SolutionBuild.LastBuildInfo after the clean ($null when unreadable)
        data.cleanSec        seconds from Clean($false) until Done
        data.nullReads       $null answers for DTE.Solution / SolutionBuild before the clean started
        data.errorItems      Error List errors, only when failedProjects > 0
        data.warning         only unresolved-library errors were reported (see step 5)
        Errors: NOT_CONNECTED, NO_SOLUTION, IDE_MODAL_DIALOG, IDE_BUSY / IDE_CRASHED (COM),
        CLEAN_TIMEOUT, CLEAN_FAILED.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateRange(5, 3600)]
        [int]$TimeoutSec = 300
    )

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }

    $dialog = Get-TcIdeModalDialog
    if ($null -ne $dialog) {
        return New-TcModalDialogResult -Dialog $dialog -Operation 'SolutionBuild.Clean'
    }

    # --- 2. Solution / SolutionBuild, polled while the DTE still answers $null ---
    $nullReads = 0
    $sb = $null
    $readDeadline = [DateTime]::Now.AddSeconds(15)
    try {
        while ($true) {
            $sol = Invoke-TcComRetry -MaxRetries 3 -OperationName 'DTE.Solution' -ScriptBlock { Write-Output -NoEnumerate $script:TcDte.Solution }
            if ($null -ne $sol) {
                $isOpen = [bool](Invoke-TcComRetry -MaxRetries 3 -OperationName 'Solution.IsOpen' -ScriptBlock { $sol.IsOpen })
                if (-not $isOpen) {
                    return New-TcResult -Success $false -ErrorMessage 'No solution is open; nothing to clean.' `
                        -ErrorCode 'NO_SOLUTION' -Hint (Get-TcErrorHint -Code 'NO_SOLUTION')
                }
                $sb = Invoke-TcComRetry -MaxRetries 3 -OperationName 'Solution.SolutionBuild' -ScriptBlock { Write-Output -NoEnumerate $sol.SolutionBuild }
            }
            if ($null -ne $sb) { break }
            $nullReads++
            if ([DateTime]::Now -ge $readDeadline) {
                $what = if ($null -eq $sol) { 'DTE.Solution' } else { 'Solution.SolutionBuild' }
                return New-TcResult -Success $false `
                    -ErrorMessage "Clean not started: $what stayed `$null for 15 s ($nullReads read(s))." `
                    -ErrorCode 'CLEAN_FAILED' -Hint (Get-TcErrorHint -Code 'CLEAN_FAILED') `
                    -Data ([PSCustomObject]@{ nullReads = $nullReads; buildState = $null; failedProjects = $null; cleanSec = 0 })
            }
            Write-Verbose "Clear-TcProject: DTE answered `$null for Solution / SolutionBuild ($nullReads), retrying..."
            Start-Sleep -Milliseconds 500
        }
    }
    catch {
        return New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'CLEAN_FAILED' -MessagePrefix 'Clean not started (Solution / SolutionBuild unreadable)'
    }

    # --- 3. start the clean ---
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Invoke-TcComRetry -MaxRetries 5 -TimeoutSec 60 -OperationName 'SolutionBuild.Clean' -ScriptBlock { $sb.Clean($false) } | Out-Null
    }
    catch {
        return New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'CLEAN_FAILED' -MessagePrefix 'SolutionBuild.Clean failed'
    }

    # --- 4. wait for Done ---
    $state = $null
    $seenNotDone = $false
    $nextModalCheckSec = 5.0
    try {
        while ($true) {
            $state = [int](Invoke-TcComRetry -MaxRetries 3 -OperationName 'SolutionBuild.BuildState' -ScriptBlock { $sb.BuildState })
            if ($state -ne 3) { $seenNotDone = $true }
            elseif ($seenNotDone -or $watch.Elapsed.TotalSeconds -ge 1) { break }

            if ($watch.Elapsed.TotalSeconds -ge $nextModalCheckSec -or $watch.Elapsed.TotalSeconds -ge $TimeoutSec) {
                $nextModalCheckSec = $watch.Elapsed.TotalSeconds + 5
                $dialog = Get-TcIdeModalDialog
                if ($null -ne $dialog) {
                    return New-TcModalDialogResult -Dialog $dialog -Operation 'SolutionBuild.Clean (clean in progress, BuildState never reached Done)' `
                        -Data ([PSCustomObject]@{ buildState = $state; cleanSec = [math]::Round($watch.Elapsed.TotalSeconds, 1); nullReads = $nullReads })
                }
            }
            if ($watch.Elapsed.TotalSeconds -ge $TimeoutSec) {
                return New-TcResult -Success $false `
                    -ErrorMessage "Clean did not finish within $TimeoutSec s (SolutionBuild.BuildState = $state; 1 NotStarted, 2 InProgress, 3 Done)." `
                    -ErrorCode 'CLEAN_TIMEOUT' -Hint (Get-TcErrorHint -Code 'CLEAN_TIMEOUT') `
                    -Data ([PSCustomObject]@{ buildState = $state; cleanSec = [math]::Round($watch.Elapsed.TotalSeconds, 1); nullReads = $nullReads })
            }
            Start-Sleep -Milliseconds 500
        }
    }
    catch {
        # A dialog that came up between two modal checks makes BuildState fail as IDE_BUSY first.
        $err = $_
        $dialog = Get-TcIdeModalDialog
        if ($null -ne $dialog) {
            return New-TcModalDialogResult -Dialog $dialog -Operation 'SolutionBuild.Clean (clean in progress)' `
                -Data ([PSCustomObject]@{ buildState = $state; cleanSec = [math]::Round($watch.Elapsed.TotalSeconds, 1); nullReads = $nullReads })
        }
        return New-TcAdsErrorResult -ErrorRecord $err -DefaultCode 'CLEAN_FAILED' -MessagePrefix 'SolutionBuild.BuildState unreadable during the clean'
    }
    $cleanSec = [math]::Round($watch.Elapsed.TotalSeconds, 1)

    # --- 5. readback ---
    $failed = $null
    try { $failed = [int](Invoke-TcComRetry -MaxRetries 2 -OperationName 'SolutionBuild.LastBuildInfo' -ScriptBlock { $sb.LastBuildInfo }) }
    catch { $failed = $null; Write-Verbose "Clear-TcProject: LastBuildInfo unreadable ($($_.Exception.Message))" }

    $data = [PSCustomObject]@{
        buildState     = $state
        failedProjects = $failed
        cleanSec       = $cleanSec
        nullReads      = $nullReads
    }
    if ($null -ne $failed -and $failed -gt 0) {
        # Which errors? A PLC project whose libraries cannot be resolved fails the clean with
        # Error List rows "Could not open library ..." in '<plc>.Library Manager' (no line), e.g.
        # the Festo copy without its Visu libraries: LastBuildInfo = 1 on the first clean after
        # the solution was opened, 0 after a build (measured 2026-10-25, 4024 32-bit XAE Shell;
        # 4026 VS2022 RobustDemo: 0). Those are library-resolution errors of the project, not of
        # the clean (Build-TcProject treats them the same way); anything else is CLEAN_FAILED.
        $errList = Get-TcBuildErrors -TimeoutSec 30
        $items = @()
        if ($errList.success) { $items = @($errList.data.errors) }
        $data | Add-Member -NotePropertyName 'errorItems' -NotePropertyValue $items
        $libraryOnly = $errList.success -and $items.Count -gt 0 -and @($items | Where-Object { -not ($_.file -like '*Library Manager' -and ($null -eq $_.line -or [int]$_.line -le 0)) }).Count -eq 0
        if (-not $libraryOnly) {
            if (-not $errList.success) { $data | Add-Member -NotePropertyName 'errorListError' -NotePropertyValue $errList.error.code }
            return New-TcResult -Success $false -ErrorMessage "Clean finished but $failed project(s) failed (SolutionBuild.LastBuildInfo)." `
                -ErrorCode 'CLEAN_FAILED' -Hint (Get-TcErrorHint -Code 'CLEAN_FAILED') -Data $data
        }
        $warn = "Clean reported $failed failed project(s), but every Error List error is an unresolved library ('<plc>.Library Manager', no line): $($items.Count) item(s) in data.errorItems. Install / fix the libraries if Build-TcProject needs them."
        $data | Add-Member -NotePropertyName 'warning' -NotePropertyValue $warn
        Write-Warning $warn
    }
    New-TcResult -Success $true -Data $data
}
