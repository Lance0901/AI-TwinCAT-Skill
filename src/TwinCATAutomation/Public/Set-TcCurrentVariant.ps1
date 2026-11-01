function Set-TcCurrentVariant {
    <#
    .SYNOPSIS
        Switches the current project variant (CurrentProjectVariant; case-sensitive, '[Group]' allowed but not activatable, '' clears it) and reads it back. Dry-run by default.
    .DESCRIPTION
        TE1000 Automation Interface manual v1.7.0 6.12.1 p.296: setting CurrentProjectVariant switches
        the project to that variant in memory; '[Group1]' selects a group. Measured 2026-11-01 4026
        VS2022 XAE 3.1.4026.22 / 4024 XAE Shell 3.1.4024.71, self-built client
        (openspec/changes/complete-automation-interface/verification/phase3-probe.md questions 15, 18):
        an unknown name, a name in another case and '[All]' -> E_FAIL; '[Group1]' and '' are
        accepted; 85-230 ms per switch.
        The module checks first (nothing written): -Name must be a variant of ProjectVariantConfig
        (exact case), '[<group>]' with an existing group, or '' -> else VARIANT_NOT_FOUND
        (data.variants / data.groups; the message names a variant that differs only in case).
        A group is accepted, but Enable-TcConfig then refuses with VARIANT_GROUP_ACTIVE (a group
        cannot be activated, VM manual v1.4 p.7; XAE itself does not refuse it): data.warnings.
        Already current: success, data.written = false.
        DryRun (default true): data.previous, data.name. DryRun=false: backup of the .tsproj (it
        stores the current variant as TcProjectVariant="..." after a save, question 18),
        IDE_MODAL_DIALOG check, set, read back with exact case (VARIANT_SWITCH_FAILED). E_FAIL from
        XAE -> VARIANT_NOT_FOUND. BUILD_REQUIRED (code-changed) is recorded once the property was
        written: the variant changes disabled items, mappings and parameters, Build-TcProject before
        Enable-TcConfig. With a variant the boot package is in _Boot\<Variant>\<Platform> (#89).
        Verified with registered tcauto on 4026 and 4024 (openspec/changes/complete-automation-interface/verification/phase3-4.6.md).
    .PARAMETER Name
        Variant name (exact case), '[<group>]', or '' to clear.
    .PARAMETER DryRun
        Default true: only check and report. false: back up, switch, read back.
    .EXAMPLE
        Set-TcCurrentVariant -Name Variant1
    .EXAMPLE
        Set-TcCurrentVariant -Name Variant1 -DryRun $false
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Name,

        [Parameter()]
        [bool]$DryRun = $true
    )

    $data = [PSCustomObject]@{ name = $Name; dryRun = $DryRun }
    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }
    $sm = Get-TcSysManager
    if ($null -eq $sm) { return New-TcNoSysManagerResult }

    $called = $false
    try {
        $st = Get-TcVariantState -SysManager $sm
        if (-not $st.Supported) {
            return New-TcResult -Success $false -ErrorCode 'VARIANT_NOT_SUPPORTED' -Data $data -ErrorMessage "Project variants cannot be read in this XAE: $($st.Error); nothing was changed." -Hint (Get-TcErrorHint -Code 'VARIANT_NOT_SUPPORTED')
        }
        if (-not $st.Config.Ok) {
            return New-TcResult -Success $false -ErrorCode 'VARIANT_CONFIG_INVALID' -Data $data -ErrorMessage "$($st.Config.Error); nothing was changed." -Hint (Get-TcErrorHint -Code 'VARIANT_CONFIG_INVALID')
        }
        $variants = @($st.Config.Variants)
        $groups = @($st.Config.Groups | ForEach-Object { $_.name })
        $data | Add-Member -NotePropertyName previous -NotePropertyValue $st.Current
        $isGroup = $Name -match '^\[(.*)\]$'
        $ok = [string]::IsNullOrEmpty($Name) -or ($isGroup -and $groups -ccontains $Matches[1]) -or (-not $isGroup -and $variants -ccontains $Name)
        if (-not $ok) {
            $data | Add-Member -NotePropertyName variants -NotePropertyValue $variants
            $data | Add-Member -NotePropertyName groups -NotePropertyValue $groups
            $near = @($variants | Where-Object { $_ -ieq $Name }) + @($groups | Where-Object { "[$_]" -ieq $Name } | ForEach-Object { "[$_]" })
            return New-TcResult -Success $false -ErrorCode 'VARIANT_NOT_FOUND' -Data $data `
                -ErrorMessage "'$Name' is not a variant or '[group]' of ProjectVariantConfig$(if ($near.Count) { " (names are case-sensitive; there is '$($near[0])')" }); nothing was changed (XAE answers E_FAIL)." -Hint (Get-TcErrorHint -Code 'VARIANT_NOT_FOUND')
        }
        if ($isGroup) { Add-TcDataWarning -Data $data -Warning "'$Name' is a group: it can be built, but Enable-TcConfig refuses to activate it (VARIANT_GROUP_ACTIVE); switch to a variant before activating" }
        if ($st.Current -ceq $Name) {
            $data | Add-Member -NotePropertyName written -NotePropertyValue $false
            return New-TcResult -Success $true -Data $data
        }
        if ($DryRun) { return New-TcResult -Success $true -Data $data }

        $bk = New-TcConfigBackup -Label 'CurrentProjectVariant' -Text "<CurrentProjectVariant>$([System.Security.SecurityElement]::Escape($st.Current))</CurrentProjectVariant>" -DiskFiles @(Get-TcVariantDiskFiles) -Data $data
        if ($null -ne $bk.Result) { return $bk.Result }
        Add-TcBackupToData -Data $data -Backup $bk.Backup
        $dlg = Get-TcTreeItemDialogResult -Operation "CurrentProjectVariant = '$Name'" -Data $data
        if ($null -ne $dlg) { return $dlg }
        $called = $true
        $data | Add-Member -NotePropertyName writeCalled -NotePropertyValue $true -Force
        # No deadline (CODING_STANDARDS.md 1): dialog ruled out just above; 85-230 ms in the probe (question 18).
        try { Invoke-TcComRetry -OperationName 'CurrentProjectVariant' -ScriptBlock { $sm.CurrentProjectVariant = $Name } | Out-Null }
        catch {
            if ($null -ne (Get-TcTreeItemPassThroughError -ErrorRecord $_)) { throw }
            $res = New-TcResult -Success $false -ErrorCode 'VARIANT_NOT_FOUND' -Data $data -ErrorMessage "XAE refused CurrentProjectVariant = '$Name': $($_.Exception.Message)" -Hint (Get-TcErrorHint -Code 'VARIANT_NOT_FOUND')
            return Register-TcCodeChange -Result $res -Change "Set-TcCurrentVariant $Name [failed]"
        }
        $after = [string](Invoke-TcComRetry -OperationName 'CurrentProjectVariant' -ScriptBlock { $sm.CurrentProjectVariant })
        $data | Add-Member -NotePropertyName current -NotePropertyValue $after
        if ($after -cne $Name) {
            $data | Add-Member -NotePropertyName verified -NotePropertyValue $false
            $res = New-TcResult -Success $false -ErrorCode 'VARIANT_SWITCH_FAILED' -Data $data -ErrorMessage "CurrentProjectVariant was set to '$Name', but reads '$after'." -Hint (Get-TcErrorHint -Code 'VARIANT_SWITCH_FAILED')
            return Register-TcCodeChange -Result $res -Change "Set-TcCurrentVariant $Name [failed at verify]"
        }
        $data | Add-Member -NotePropertyName verified -NotePropertyValue $true
        return Register-TcCodeChange -Result (New-TcResult -Success $true -Data $data) -Change "Set-TcCurrentVariant $Name"
    }
    catch {
        $res = New-TcTreeItemErrorResult -ErrorRecord $_ -DefaultCode 'VARIANT_SWITCH_FAILED' -Data $data -Operation 'Set-TcCurrentVariant'
        if ($called) { $res = Register-TcCodeChange -Result $res -Change "Set-TcCurrentVariant $Name [failed]" }
        return $res
    }
}
