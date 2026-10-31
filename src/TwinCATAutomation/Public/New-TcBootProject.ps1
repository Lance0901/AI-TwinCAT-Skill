function New-TcBootProject {
    <#
    .SYNOPSIS
        Generates the local boot project of a PLC (GenerateBootProject($false) on 'TIPC^<Plc>'): writes _Boot\<platform>\Plc\Port_<port>.* of the project, not the target. SAVES the project files. Reads the boot files back.
    .DESCRIPTION
        API: ITcPlcProject.GenerateBootProject(bActivate) on the PLC root node 'TIPC^<Plc>' ("Builds
        the local boot project", TE1000 Automation Interface manual v1.7.0, 5.17 p.102-103; sample
        6.5.13 p.241). Only bActivate = false is called: true is not measured, so this cmdlet offers
        no option for it. To bring the program to the target use Build-TcProject and
        Enable-TcConfig -Force.
        Measured 2026-10-31 4026 VS2022 XAE 3.1.4026.18, self-built client
        (openspec/changes/complete-automation-interface/verification/phase2-probe.md 3.2):
          - only the PLC root has the method; on '<Plc> Project' PowerShell finds no such method.
          - it writes <tsproj folder>\_Boot\<solution platform>\Plc\Port_<adsPort>.app, the files of
            the same name with the extensions autostart, cid, crc, occ and ocm, and
            Port_<adsPort>_boot.tizip (1.7-4 s); %ProgramData%\Beckhoff\TwinCAT\3.1\Boot and the
            UmRT Boot folder did not change.
          - IT SAVES THE PROJECT: unsaved changes in XAE memory (objects created through the
            Automation Interface) were written to the .plcproj, and the .tsproj / .tmc were
            rewritten; data.warnings says so on every call.
          - it compiles by itself, no Build-TcProject needed before. A compile error -> COMException
            E_FAIL (0x80004005) whose localized message says nothing useful; the module then reads
            the Error List (the same rows as Build-TcProject, Get-TcErrorListSummary) and returns
            BOOTPROJECT_FAILED with data.errorItems (rows without file and code, left over from
            earlier operations, go to data.staleErrorItems).
          - no modal dialog appeared.
        Steps: PLC project resolved (-PlcProjectPath; several without it -> PLC_PROJECT_AMBIGUOUS),
        the boot files listed before the call (Get-TcBootFileSet: solution platform from
        Get-TcSolutionPlatform, ADS port from the PLC node, .tsproj folder from the solution),
        IDE_MODAL_DIALOG when a dialog is open (nothing called), GenerateBootProject($false),
        readback.
        Readback: Port_<port>.app must exist and be newer than before the call, else
        BOOTPROJECT_VERIFY_FAILED reason not-updated. data.bootFiles: path, size, lastWriteTime,
        updated. When the boot folder cannot be derived (platform, port or .tsproj unknown) the
        _Boot\*\Plc\Port_* files below the solution folder are listed instead with a warning; at
        least one of them must be newer, else BOOTPROJECT_VERIFY_FAILED reason boot-dir-unknown.
        BUILD_REQUIRED is not changed: Activate still goes through Build-TcProject and
        Enable-TcConfig, which check and clear it; this call does not prove a complete build.
        BOOT_PACKAGE_MISMATCH: this only writes the local _Boot, not the target, so it does not
        affect the comparison Enable-TcConfig makes after Activate.
        No deadline (CODING_STANDARDS.md section 1): a dialog is ruled out right before the call,
        Connect-TcIde turns on ITcAutomationSettings.SilentMode, and the probe calls returned in
        1.7-4 s; the MCP tool timeout (600 s, as BuildProject) bounds it from outside.
        Not verified through the registered MCP server yet (task 3.8).
    .PARAMETER PlcProjectPath
        PLC name or tree path ('TIPC^<Plc>' or 'TIPC^<Plc>^<Plc> Project') when the solution has more
        than one PLC project (otherwise PLC_PROJECT_AMBIGUOUS).
    .OUTPUTS
        data: plcProjectPath, plcPath, adsPort, platform, bootDir, bootDirDerived, bootFiles, generateSec,
        warnings; on a compile failure errorItems, codeErrors, libraryErrorItems, staleErrorItems.
    .EXAMPLE
        New-TcBootProject
    .EXAMPLE
        New-TcBootProject -PlcProjectPath FrameworkUnitTest
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$PlcProjectPath
    )

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }
    $sm = Get-TcSysManager
    if ($null -eq $sm) { return New-TcNoSysManagerResult }

    $saveWarning = 'GenerateBootProject saves the project: unsaved changes in XAE memory are written to the .plcproj / .tsproj (measured 2026-10-31 4026 VS2022, phase2-probe.md 3.2)'
    $data = [PSCustomObject]@{ plcProjectPath = $null; plcPath = $null; adsPort = $null; platform = $null }
    $warnings = [System.Collections.Generic.List[string]]::new()
    try {
        $spec = Resolve-TcPlcProjectSpec -SysManager $sm -PlcProjectPath $PlcProjectPath
        if ($null -ne $spec.Result) { return $spec.Result }
        $prjPath = $spec.PlcProjectPath
        $plcPath = Get-TcTreePathParent -Path $prjPath
        $data.plcProjectPath = $prjPath
        $data.plcPath = $plcPath
        $entry = @($spec.PlcProjects | Where-Object { [string]$_.projectPath -ieq $prjPath })[0]
        $port = if ($null -ne $entry -and $null -ne $entry.adsPort) { [int]$entry.adsPort } else { 0 }
        $data.adsPort = $(if ($port -gt 0) { $port } else { $null })
        $r = Resolve-TcTreeItem -SysManager $sm -Path $plcPath -Data $data -ParameterName 'PlcProjectPath (PLC root)'
        if ($null -ne $r.Result) { return $r.Result }
        $root = $r.Item

        $platform = (Get-TcSolutionPlatform).platform
        $data.platform = $platform
        $plcName = Get-TcPlcNameFromPath -TreePath $plcPath
        $before = Get-TcBootFileSet -PlcName $plcName -Platform $platform -AdsPort $port -SolutionDir (Get-TcTreeItemSolutionDir)
        $data | Add-Member -NotePropertyName bootDir -NotePropertyValue $before.Dir
        $data | Add-Member -NotePropertyName bootDirDerived -NotePropertyValue $before.Derived

        $dlg = Get-TcTreeItemDialogResult -Operation "GenerateBootProject '$plcPath'" -Data $data
        if ($null -ne $dlg) { return $dlg }
        $warnings.Add($saveWarning)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            # No deadline: see .DESCRIPTION (dialog ruled out above, SilentMode, 1.7-4 s measured).
            Invoke-TcComRetry -OperationName 'GenerateBootProject' -ScriptBlock { $root.GenerateBootProject($false) } | Out-Null
        }
        catch {
            if ($null -ne (Get-TcTreeItemPassThroughError -ErrorRecord $_)) { throw }
            $sw.Stop()
            $data | Add-Member -NotePropertyName generateSec -NotePropertyValue ([Math]::Round($sw.Elapsed.TotalSeconds, 2))
            $data | Add-Member -NotePropertyName warnings -NotePropertyValue $warnings.ToArray()
            # decided by the error id: the "method not found" text is localized
            if ([string]$_.FullyQualifiedErrorId -eq 'MethodNotFound') {
                $data | Add-Member -NotePropertyName reason -NotePropertyValue 'no-method'
                return New-TcResult -Success $false -ErrorCode 'BOOTPROJECT_FAILED' -Data $data `
                    -ErrorMessage "'$plcPath' has no GenerateBootProject method (ITcPlcProject); nothing was generated." -Hint (Get-TcErrorHint -Code 'BOOTPROJECT_FAILED')
            }
            $info = Get-TcComErrorInfo -ErrorRecord $_
            $data | Add-Member -NotePropertyName reason -NotePropertyValue 'generate-failed'
            $data | Add-Member -NotePropertyName xaeMessage -NotePropertyValue $info.message
            $data | Add-Member -NotePropertyName hresult -NotePropertyValue $info.hresultHex
            # E_FAIL with a meaningless message on a compile error (measured): the Error List tells why
            $els = Get-TcErrorListSummary
            $isStale = { param($i) $i.category -eq 'other' -and [string]::IsNullOrWhiteSpace([string]$i.code) }
            $located = @($els.errorItems | Where-Object { -not (& $isStale $_) })
            $data | Add-Member -NotePropertyName errorItems -NotePropertyValue $located
            $data | Add-Member -NotePropertyName codeErrors -NotePropertyValue @($els.codeErrors)
            $data | Add-Member -NotePropertyName libraryErrorItems -NotePropertyValue @($els.libraryErrorItems)
            $data | Add-Member -NotePropertyName staleErrorItems -NotePropertyValue @($els.errorItems | Where-Object { & $isStale $_ })
            $msg = "GenerateBootProject on '$plcPath' failed ($($info.hresultHex)): $($info.message)"
            if ($null -ne $els.errorListError) {
                $data | Add-Member -NotePropertyName errorListError -NotePropertyValue $els.errorListError
                $msg += "; the Error List could not be read ($($els.errorListError)), so the errors are not listed"
            }
            elseif ($located.Count -eq 0) { $msg += '; the Error List shows no error row except stale ones (no file and no code)' }
            else {
                $parts = @($located | Select-Object -First 3 | ForEach-Object {
                        $loc = [IO.Path]::GetFileName([string]$_.file)
                        if ($null -ne $_.line -and $_.line -gt 0) { $loc += ":$($_.line)" }
                        "$(if ([string]::IsNullOrWhiteSpace($_.code)) { '' } else { "$($_.code) " })$($_.description) ($loc)"
                    })
                $msg += ". Error List: $($located.Count) error(s): " + ($parts -join '; ')
                if ($located.Count -gt 3) { $msg += " ... (+$($located.Count - 3) more)" }
            }
            return New-TcResult -Success $false -ErrorCode 'BOOTPROJECT_FAILED' -Data $data -ErrorMessage $msg -Hint (Get-TcErrorHint -Code 'BOOTPROJECT_FAILED')
        }
        $sw.Stop()
        $data | Add-Member -NotePropertyName generateSec -NotePropertyValue ([Math]::Round($sw.Elapsed.TotalSeconds, 2))

        # readback
        $after = Get-TcBootFileSet -PlcName $plcName -Platform $platform -AdsPort $port -SolutionDir (Get-TcTreeItemSolutionDir)
        $files = @(Compare-TcBootFileSet -Before $before.Files -After $after.Files)
        $data | Add-Member -NotePropertyName bootFiles -NotePropertyValue $files
        $updated = @($files | Where-Object { $_.updated })
        $fail = $null
        if ($before.Derived) {
            $app = Join-Path $before.Dir "Port_$port.app"
            $appEntry = @($files | Where-Object { $_.path -ieq $app })[0]
            if ($null -eq $appEntry -or -not $appEntry.updated -or $null -eq $appEntry.size) {
                $fail = @{ Reason = 'not-updated'; Message = "GenerateBootProject returned, but '$app' $(if ($null -eq $appEntry -or $null -eq $appEntry.size) { 'does not exist' } else { 'is not newer than before the call' })" }
            }
        }
        else {
            $warnings.Add("the boot folder could not be derived ($($before.Reason)); data.bootFiles lists the _Boot\*\Plc\Port_* files found below the solution folder instead")
            if ($updated.Count -eq 0) { $fail = @{ Reason = 'boot-dir-unknown'; Message = "GenerateBootProject returned, but no boot file below the solution folder is newer than before the call ($($before.Reason))" } }
        }
        $data | Add-Member -NotePropertyName warnings -NotePropertyValue $warnings.ToArray()
        if ($null -ne $fail) {
            $data | Add-Member -NotePropertyName reason -NotePropertyValue $fail.Reason
            return New-TcResult -Success $false -ErrorCode 'BOOTPROJECT_VERIFY_FAILED' -Data $data -ErrorMessage "$($fail.Message)." -Hint (Get-TcErrorHint -Code 'BOOTPROJECT_VERIFY_FAILED')
        }
        New-TcResult -Success $true -Data $data
    }
    catch {
        if ($warnings.Count -gt 0) { $data | Add-Member -NotePropertyName warnings -NotePropertyValue $warnings.ToArray() -Force }
        New-TcTreeItemErrorResult -ErrorRecord $_ -DefaultCode 'BOOTPROJECT_FAILED' -Data $data -Operation 'GenerateBootProject'
    }
}
