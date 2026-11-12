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

function Get-TcDiagnosticsLicenseEvidence {
    <#
    .SYNOPSIS
        #49: license evidence from a data.diagnostics record (Get-TcRuntimeFailureDiagnostics):
        dialog title + text, then the Error List rows. $null when none. Never throws.
    #>
    param([object]$Diagnostics)
    if ($null -eq $Diagnostics) { return $null }
    $texts = @()
    try {
        $dp = $Diagnostics.PSObject.Properties['dialog']
        if ($null -ne $dp -and $null -ne $dp.Value) { $texts += "$([string]$dp.Value.title) | $([string]$dp.Value.text)" }
        $ep = $Diagnostics.PSObject.Properties['errorList']
        if ($null -ne $ep) { $texts += @($ep.Value | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ }) }
    }
    catch { return $null }
    Get-TcLicenseFailureEvidence -Texts $texts
}

function Add-TcLicenseMissingData {
    <#
    .SYNOPSIS
        #49: adds data.licenseMissing { evidence; originalCode } to -Result. Never throws.
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
    }
    catch { Write-Verbose "Add-TcLicenseMissingData: $($_.Exception.Message)" }
}
