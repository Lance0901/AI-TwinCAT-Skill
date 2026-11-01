function Get-TcProjectVariants {
    <#
    .SYNOPSIS
        Reads the project variants (CurrentProjectVariant, ProjectVariantConfig, ProjectVariantItems): current, variants[], groups[]. Read-only.
    .DESCRIPTION
        ITcSysManager14 properties (TE1000 Automation Interface manual v1.7.0 5.1.13 p.52, 6.12.1
        p.296; InfoSys https://infosys.beckhoff.com/content/1033/tc3_automationinterface/8204600715.html).
        Measured 2026-11-01, self-built client
        (openspec/changes/complete-automation-interface/verification/phase3-probe.md questions 15-16):
        4024.71 (32-bit XAE Shell) and 4026.22 (VS2022) both late-bind them; without variants 4026
        returns '' for everything and 4024 $null for ProjectVariantConfig / ProjectVariantItems; both
        give empty arrays here.
        data: supported (false when reading the properties throws: XAE without ITcSysManager14 ->
        VARIANT_NOT_SUPPORTED), current ('' = none), currentIsGroup ('[Group1]' cannot be activated:
        Enable-TcConfig returns VARIANT_GROUP_ACTIVE), variants[] (names, case-sensitive), groups[]
        (name, members[]), configXml, itemsXml (item-level settings, e.g. PvUseDisable per variant).
        Change the list with Set-TcProjectVariantConfig, switch with Set-TcCurrentVariant.
        Verified with registered tcauto on 4026 and 4024 (openspec/changes/complete-automation-interface/verification/phase3-4.6.md).
    .EXAMPLE
        Get-TcProjectVariants
    #>
    [CmdletBinding()]
    param()

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }
    $sm = Get-TcSysManager
    if ($null -eq $sm) { return New-TcNoSysManagerResult }

    $data = [PSCustomObject]@{ supported = $false }
    try {
        $st = Get-TcVariantState -SysManager $sm
        if (-not $st.Supported) {
            return New-TcResult -Success $false -ErrorCode 'VARIANT_NOT_SUPPORTED' -Data $data `
                -ErrorMessage "The project variant properties of ITcSysManager14 cannot be read in this XAE: $($st.Error)" -Hint (Get-TcErrorHint -Code 'VARIANT_NOT_SUPPORTED')
        }
        if (-not $st.Config.Ok) {
            $data | Add-Member -NotePropertyName configXml -NotePropertyValue $st.ConfigXml
            return New-TcResult -Success $false -ErrorCode 'VARIANT_CONFIG_INVALID' -Data $data -ErrorMessage $st.Config.Error -Hint (Get-TcErrorHint -Code 'VARIANT_CONFIG_INVALID')
        }
        $data.supported = $true
        $data | Add-Member -NotePropertyName current -NotePropertyValue $st.Current
        $data | Add-Member -NotePropertyName currentIsGroup -NotePropertyValue ($st.Current -match '^\[.*\]$')
        $data | Add-Member -NotePropertyName variants -NotePropertyValue @($st.Config.Variants)
        $data | Add-Member -NotePropertyName groups -NotePropertyValue @($st.Config.Groups)
        $data | Add-Member -NotePropertyName configXml -NotePropertyValue $st.ConfigXml
        $data | Add-Member -NotePropertyName itemsXml -NotePropertyValue $st.ItemsXml
        if (-not [string]::IsNullOrEmpty($st.Current) -and $st.Current -notmatch '^\[.*\]$' -and @($st.Config.Variants) -cnotcontains $st.Current) {
            Add-TcDataWarning -Data $data -Warning "the current variant '$($st.Current)' is not in ProjectVariantConfig any more (XAE keeps it after the config is replaced, phase3-probe.md question 17); switch with Set-TcCurrentVariant"
        }
        return New-TcResult -Success $true -Data $data
    }
    catch {
        New-TcTreeItemErrorResult -ErrorRecord $_ -DefaultCode 'VARIANT_NOT_SUPPORTED' -Data $data -Operation 'Get-TcProjectVariants'
    }
}
