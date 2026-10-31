function Test-TcPlcProject {
    <#
    .SYNOPSIS
        Checks the syntax of EVERY object of the PLC project (ITcPlcIECProject2.CheckAllObjects), also the ones no build compiles; returns the Error List rows like BuildProject. Generates no code, never changes BUILD_REQUIRED.
    .DESCRIPTION
        Use it after editing code that nothing calls yet (a new function block, a library project):
        Build-TcProject only compiles the objects that are referenced, so a syntax error in an
        unreferenced function block leaves the build successful (errors 0), while CheckAllObjects
        returns False and lists the error (measured 2026-10-31 4026 VS2022, self-built client,
        openspec/changes/complete-automation-interface/verification/phase2-probe.md 3.7). InfoSys PLC
        command "Check all objects": checks the syntax of all objects, not only the used ones, and
        generates no code (https://infosys.beckhoff.com/content/1033/tc3_plc_intro/2531345035.html).
        API: CheckAllObjects() on the '<Plc> Project' node, late bound (TE1000 Automation Interface
        manual v1.7.0, 5.28.2 p.123-124 and 6.5.7 p.233-234). Only that node has the method: on the
        PLC root 'TIPC^<Plc>' PowerShell throws MethodNotFound (English PowerShell: "does not
        contain a method named 'CheckAllObjects'"; the text is localized, e.g. zh-TW) (measured
        2026-10-31 4026 VS2022 XAE 3.1.4026.18, self-built client). The module decides by the
        error id MethodNotFound, not by the text.
        Steps: the PLC project is resolved (-PlcProjectPath; several PLC projects without it ->
        PLC_PROJECT_AMBIGUOUS), a modal dialog in the IDE returns IDE_MODAL_DIALOG (nothing called),
        then CheckAllObjects(), then the Error List is read (Get-TcBuildErrors -IncludeWarnings, the
        same rows and categories as Build-TcProject: Get-TcErrorListSummary).
        Result:
          True  -> success, data.passed = $true, data.errorItems = @() (error rows still shown in
                   the Error List go to data.staleErrorItems with a warning), warnings in
                   data.warningItems / data.codeWarnings.
          False -> CHECK_FAILED, data.passed = $false, data.errorItems = the error rows of the Error
                   List except the stale ones (same shape as BuildProject errorItems, category
                   code / library / other), data.codeErrors / data.libraryErrorItems; stale rows
                   (category other AND no code: no file and no compiler code) in
                   data.staleErrorItems. A row with a code but no file stays in errorItems. A
                   syntax error gives False, not an exception (measured 2026-10-31 4026 VS2022 XAE
                   3.1.4026.18, self-built client: C0007 in FB_P2Probe.TcPOU@M_Two (Impl), line 1).
                   Rows without file and code stay in the Error List from earlier operations
                   (measured, same environment: "'TwinCAT Measurement' ... Error creating Archive"
                   after a failed archive), so they are not counted as results of this check.
          An exception from CheckAllObjects (TE1000 5.28.2 lists E_FAIL Error_CheckAllObjectsFailed;
          not seen in the probe) -> CHECK_FAILED with data.passed = $null and data.callError; the
          method missing -> CHECK_UNAVAILABLE. IDE_BUSY / IDE_CRASHED / IDE_MODAL_DIALOG keep their code.
        When the Error List cannot be read, data.errorListError says why (the result is still
        decided by the return value).
        BUILD_REQUIRED: CheckAllObjects generates no code (InfoSys link above; measured 2026-10-31
        4026 VS2022 XAE 3.1.4026.18, self-built client: no file of the solution directory changed, _Boot and _CompileInfo included),
        so this cmdlet neither sets nor clears BUILD_REQUIRED and records no code change. A
        successful check does NOT replace Build-TcProject before Enable-TcConfig / Enter-TcPlcOnline.
        Not verified through the registered MCP server yet (task 3.8).
    .PARAMETER PlcProjectPath
        PLC name or tree path ('TIPC^<Plc>^<Plc> Project') when the solution has more than one PLC
        project (otherwise PLC_PROJECT_AMBIGUOUS).
    .OUTPUTS
        data: plcProjectPath, passed, checkSec, errors (code error count), warnings (warning count),
        errorItems, codeErrors, libraryErrorItems, staleErrorItems, warningItems, codeWarnings;
        errorListError, callError and warningTexts only when they apply.
    .EXAMPLE
        Test-TcPlcProject
    .EXAMPLE
        Test-TcPlcProject -PlcProjectPath FrameworkUnitTest
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

    $data = [PSCustomObject]@{ plcProjectPath = $null; passed = $null }
    try {
        $spec = Resolve-TcPlcProjectSpec -SysManager $sm -PlcProjectPath $PlcProjectPath
        if ($null -ne $spec.Result) { return $spec.Result }
        $prjPath = $spec.PlcProjectPath
        $data.plcProjectPath = $prjPath
        $r = Resolve-TcTreeItem -SysManager $sm -Path $prjPath -Data $data -ParameterName 'PlcProjectPath'
        if ($null -ne $r.Result) { return $r.Result }
        $prj = $r.Item

        $dialog = Get-TcIdeModalDialog
        if ($null -ne $dialog) {
            return New-TcModalDialogResult -Dialog $dialog -Operation 'CheckAllObjects' -Data $data
        }

        $callError = $null
        $ret = $null
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            # No deadline (CODING_STANDARDS.md section 1): an open dialog was ruled out just above,
            # Connect-TcIde turns on ITcAutomationSettings.SilentMode, and CheckAllObjects returned in
            # 0.7-2.2 s without any dialog in every probe call (measured 2026-10-31 4026 VS2022,
            # self-built client, phase2-probe.md 3.7). The MCP tool timeout bounds it from outside.
            $ret = Invoke-TcComRetry -OperationName 'CheckAllObjects' -ScriptBlock { $prj.CheckAllObjects() }
        }
        catch {
            if ($null -ne (Get-TcTreeItemPassThroughError -ErrorRecord $_)) { throw }
            $msg = $_.Exception.Message
            # Decided by the error id: the message is localized (zh-TW PowerShell does not say
            # "does not contain a method named"); the English text is only a fallback.
            $noMethod = ([string]$_.FullyQualifiedErrorId -eq 'MethodNotFound') -or
                ($_.Exception -is [System.Management.Automation.MethodException] -and $msg -match "does not contain a method named 'CheckAllObjects'")
            if ($noMethod) {
                return New-TcResult -Success $false -ErrorCode 'CHECK_UNAVAILABLE' -Data $data `
                    -ErrorMessage "'$prjPath' has no CheckAllObjects method (ITcPlcIECProject2 not available in this XAE): $msg" `
                    -Hint (Get-TcErrorHint -Code 'CHECK_UNAVAILABLE')
            }
            $callError = $msg
        }
        $sw.Stop()
        $passed = $null
        if ($null -eq $callError) {
            $v = @($ret)
            if ($v.Count -eq 1 -and $v[0] -is [bool]) { $passed = [bool]$v[0] }
            elseif ($v.Count -eq 1 -and $null -ne $v[0]) {
                try { $passed = [System.Convert]::ToBoolean($v[0]) } catch { $callError = "CheckAllObjects returned '$($v[0])', not a boolean" }
            }
            else { $callError = 'CheckAllObjects returned no value' }
        }
        $data.passed = $passed
        $data | Add-Member -NotePropertyName checkSec -NotePropertyValue ([Math]::Round($sw.Elapsed.TotalSeconds, 2))
        if ($null -ne $callError) { $data | Add-Member -NotePropertyName callError -NotePropertyValue $callError }

        # Error List: a passed check only needs a short look (as a successful Build-TcProject).
        $elTimeout = if ($passed -eq $true) { 8 } else { 0 }
        $els = Get-TcErrorListSummary -TimeoutSec $elTimeout
        # stale = left over from earlier operations: no file (category other) AND no compiler code
        $isStale = { param($i) $i.category -eq 'other' -and [string]::IsNullOrWhiteSpace([string]$i.code) }
        $located = @($els.errorItems | Where-Object { -not (& $isStale $_) })
        $stale = @($els.errorItems | Where-Object { & $isStale $_ })
        $warningTexts = @()
        if ($passed -eq $true) {
            $data | Add-Member -NotePropertyName errorItems -NotePropertyValue @()
            $data | Add-Member -NotePropertyName codeErrors -NotePropertyValue @()
            $data | Add-Member -NotePropertyName libraryErrorItems -NotePropertyValue @()
            $stale = @($els.errorItems)
            if ($stale.Count -gt 0) { $warningTexts += "CheckAllObjects returned True, but the Error List still shows $($stale.Count) error row(s) (data.staleErrorItems); they are not results of this check" }
            $data | Add-Member -NotePropertyName errors -NotePropertyValue 0
        }
        else {
            $data | Add-Member -NotePropertyName errorItems -NotePropertyValue $located
            $data | Add-Member -NotePropertyName codeErrors -NotePropertyValue $els.codeErrors
            $data | Add-Member -NotePropertyName libraryErrorItems -NotePropertyValue $els.libraryErrorItems
            $data | Add-Member -NotePropertyName errors -NotePropertyValue $(if ($null -eq $els.errorListError) { @($els.codeErrors).Count } else { $null })
        }
        $data | Add-Member -NotePropertyName staleErrorItems -NotePropertyValue $stale
        $data | Add-Member -NotePropertyName warnings -NotePropertyValue $(if ($null -eq $els.errorListError) { $els.warningCount } else { $null })
        $data | Add-Member -NotePropertyName warningItems -NotePropertyValue $els.warningItems
        $data | Add-Member -NotePropertyName codeWarnings -NotePropertyValue $els.codeWarnings
        if ($null -ne $els.errorListError) {
            $data | Add-Member -NotePropertyName errorListError -NotePropertyValue $els.errorListError
            $warningTexts += "the Error List could not be read ($($els.errorListError): $($els.errorListMessage)); the result comes from the CheckAllObjects return value only"
        }
        if ($els.severityUnknown) {
            $data | Add-Member -NotePropertyName severityUnknown -NotePropertyValue $true
            $data | Add-Member -NotePropertyName unclassified -NotePropertyValue @($els.unclassified)
        }
        if ($null -ne $els.scanCleanupWarning) { $data | Add-Member -NotePropertyName scanCleanupWarning -NotePropertyValue $els.scanCleanupWarning }
        if ($warningTexts.Count -gt 0) { $data | Add-Member -NotePropertyName warningTexts -NotePropertyValue $warningTexts }

        if ($passed -eq $true) { return New-TcResult -Success $true -Data $data }

        if ($null -ne $callError) {
            $msg = "CheckAllObjects on '$prjPath' failed: $callError"
        }
        else {
            $msg = "CheckAllObjects on '$prjPath' returned False"
            if ($null -ne $els.errorListError) { $msg += "; the Error List could not be read ($($els.errorListError)), so the errors are not listed" }
            elseif ($located.Count -eq 0) { $msg += '; the Error List shows no error row except stale ones (no file and no code)' }
            else {
                $parts = @()
                foreach ($item in @($located | Select-Object -First 3)) {
                    $loc = [IO.Path]::GetFileName([string]$item.file)
                    if ($null -ne $item.line -and $item.line -gt 0) { $loc += ":$($item.line)" }
                    $codeText = if ([string]::IsNullOrWhiteSpace($item.code)) { '' } else { "$($item.code) " }
                    $parts += "$codeText$($item.description) ($loc)"
                }
                $msg += ": $($located.Count) error(s). " + ($parts -join '; ')
                if ($located.Count -gt 3) { $msg += " ... (+$($located.Count - 3) more)" }
            }
        }
        New-TcResult -Success $false -ErrorCode 'CHECK_FAILED' -ErrorMessage $msg -Hint (Get-TcErrorHint -Code 'CHECK_FAILED') -Data $data
    }
    catch {
        $errData = $data
        if ($null -ne $script:TcLastModalDialog) {
            $errData | Add-Member -NotePropertyName dialogTitle -NotePropertyValue ([string]$script:TcLastModalDialog.Title) -Force
            $errData | Add-Member -NotePropertyName dialogText -NotePropertyValue ([string]$script:TcLastModalDialog.Text) -Force
        }
        New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'CHECK_FAILED' -MessagePrefix 'CheckAllObjects failed' -Data $errData
    }
}
