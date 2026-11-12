# #49: LICENSE_MISSING - the target reported a missing license after a runtime-changing request.
#
# No pre-check before Activate: InfoSys documents no way to read, before Activate, whether the
# target's licenses cover the project (the license check is part of the runtime start, "no running
# runtime = no current license information",
# https://infosys.beckhoff.com/content/1033/tc3_security_management/3297369483.html; the IG / IO of
# the license server port 30 are not documented, see #49). So the failure is classified AFTER the
# request: the XAE fatal error dialog / Error List row / modal-probe report carries the runtime's
# own text, measured 2026-11-11 (VS2022 4026 + UmRT):
#   Target system reports a fatal error: 'TwinCAT System' (10000) >> license not found << checking TwinCAT Licenses!
# The decision does not depend on the XAE UI language: '(10000)' after 'TwinCAT System' in
# parentheses AND a license word. The number equals the ADS port of the TwinCAT system service; what
# XAE means by it is NOT confirmed by InfoSys (see Get-TcIdeErrorList). Only the English runtime text
# above is measured; the German / zh-TW / zh-CN / ja words are an inference. '(10000)' alone is not
# enough: the ADS 1809 fatal error carries the same "'TwinCAT System' (10000)" prefix (#194).
# The dialog is never pressed (license dialogs are the user's, worker rules / SKILL.md Failure
# contract); the lifecycle block of the failed request is kept (#68 / #236).
#
# Windows PowerShell 5.1; ASCII source (non-ASCII words as \u escapes).

# '(10000)' in ASCII or full-width parentheses: a bare 10000 (e.g. 'ADS port 10000' in a state
# message) does not count
$script:TcLicenseSourcePattern = '[(\uFF08]\s*10000\s*[)\uFF09]'
# license / licence / Lizenz / \u6388\u6B0A (zh-TW) / \u6388\u6743 (zh-CN) / \u30E9\u30A4\u30BB\u30F3\u30B9 (ja)
$script:TcLicenseWordPattern = '(?i)licen[cs]|lizenz|\u6388\u6B0A|\u6388\u6743|\u30E9\u30A4\u30BB\u30F3\u30B9'

function Test-TcLicenseFailureText {
    <#
    .SYNOPSIS
        #49: $true when -Text carries the runtime's license failure: the number 10000 (error source
        'TwinCAT System') and a license word, in any language. Never throws.
    #>
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    ($Text -match $script:TcLicenseSourcePattern) -and ($Text -match $script:TcLicenseWordPattern)
}

function Get-TcLicenseFailureEvidence {
    <#
    .SYNOPSIS
        #49: first text of -Texts that Test-TcLicenseFailureText accepts (whitespace collapsed, cut
        to 300 chars), else $null. Never throws.
    #>
    param([object[]]$Texts)
    foreach ($t in @($Texts)) {
        $s = [string]$t
        if (Test-TcLicenseFailureText $s) {
            $s = ($s -replace '\s+', ' ').Trim()
            if ($s.Length -gt 300) { $s = $s.Substring(0, 300) }
            return $s
        }
    }
    $null
}

# PR #259 S1: only a dialog that is up now or the error text of this step changes the code. An Error
# List row may be left from an earlier activation (whether XAE keeps runtime log rows across an
# Activate is not measured), so a row alone is only a reference: data.licenseErrorListEvidence and
# this note after the original hint. (While a dialog is up the Error List is not read at all, #198.)
$script:TcLicenseErrorListNote = 'Reference (#49): the XAE Error List has a license failure row (data.licenseErrorListEvidence). It may be left from an earlier activation, so the code was NOT changed to LICENSE_MISSING: handle the cause above first; if the license really is missing, see LICENSE_MISSING in docs/troubleshooting.md (the user renews / activates it in XAE).'

function Get-TcDialogLicenseEvidence {
    <#
    .SYNOPSIS
        #49: license evidence from the dialog of a data.diagnostics record
        (Get-TcRuntimeFailureDiagnostics): title + text. $null when none. Never throws.
    #>
    param([object]$Diagnostics)
    if ($null -eq $Diagnostics) { return $null }
    try {
        $dp = $Diagnostics.PSObject.Properties['dialog']
        if ($null -eq $dp -or $null -eq $dp.Value) { return $null }
        Get-TcLicenseFailureEvidence -Texts @("$([string]$dp.Value.title) | $([string]$dp.Value.text)")
    }
    catch { $null }
}

function Get-TcErrorListLicenseEvidence {
    <#
    .SYNOPSIS
        #49 / PR #259 S1: the first Error List row of a data.diagnostics record with the license
        failure (each row on its own), $null when none. A reference only, never a code change.
        Never throws.
    #>
    param([object]$Diagnostics)
    if ($null -eq $Diagnostics) { return $null }
    try {
        $ep = $Diagnostics.PSObject.Properties['errorList']
        if ($null -eq $ep) { return $null }
        Get-TcLicenseFailureEvidence -Texts @($ep.Value | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
    }
    catch { $null }
}

function Add-TcLicenseErrorListReference {
    <#
    .SYNOPSIS
        PR #259 S1: adds data.licenseErrorListEvidence to -Result (no code change). Never throws.
    #>
    param([object]$Result, [string]$Evidence)
    if ($null -eq $Result -or [string]::IsNullOrWhiteSpace($Evidence)) { return }
    try {
        $data = $null
        $dp = $Result.PSObject.Properties['data']
        if ($null -ne $dp) { $data = $dp.Value }
        if ($data -is [System.Collections.IDictionary]) { $data = [PSCustomObject]$data }
        if ($null -eq $data) { $data = [PSCustomObject]@{} }
        $data | Add-Member -NotePropertyName 'licenseErrorListEvidence' -NotePropertyValue $Evidence -Force
        $Result | Add-Member -NotePropertyName 'data' -NotePropertyValue $data -Force
    }
    catch { Write-Verbose "Add-TcLicenseErrorListReference: $($_.Exception.Message)" }
}

function Add-TcLicenseMissingData {
    <#
    .SYNOPSIS
        #49: adds data.licenseMissing { evidence; originalCode } to -Result and puts
        'LICENSE_MISSING: ' in front of error.message (PR #259 N1; error.code is the code). Never throws.
    #>
    param([object]$Result, [string]$Evidence, [string]$OriginalCode)
    if ($null -eq $Result) { return }
    try {
        $data = $null
        $dp = $Result.PSObject.Properties['data']
        if ($null -ne $dp) { $data = $dp.Value }
        if ($data -is [System.Collections.IDictionary]) { $data = [PSCustomObject]$data }
        if ($null -eq $data) { $data = [PSCustomObject]@{} }
        $data | Add-Member -NotePropertyName 'licenseMissing' -NotePropertyValue ([PSCustomObject]@{ evidence = $Evidence; originalCode = $OriginalCode }) -Force
        $Result | Add-Member -NotePropertyName 'data' -NotePropertyValue $data -Force
        if ($null -ne $Result.error) {
            $m = [string]$Result.error.message
            if (-not $m.StartsWith('LICENSE_MISSING: ')) { $Result.error | Add-Member -NotePropertyName 'message' -NotePropertyValue "LICENSE_MISSING: $m" -Force }
        }
    }
    catch { Write-Verbose "Add-TcLicenseMissingData: $($_.Exception.Message)" }
}
