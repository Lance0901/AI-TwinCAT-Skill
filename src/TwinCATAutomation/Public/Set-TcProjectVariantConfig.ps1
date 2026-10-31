function Set-TcProjectVariantConfig {
    <#
    .SYNOPSIS
        Adds or removes project variants: reads ProjectVariantConfig, changes it, writes the WHOLE document back and reads it back. Dry-run by default; backs up the .tsproj first.
    .DESCRIPTION
        ProjectVariantConfig is replaced as a whole on every write (measured 2026-11-01 4026 VS2022
        XAE 3.1.4026.22, self-built client,
        openspec/changes/complete-automation-interface/verification/phase3-probe.md question 17: no
        merge, no automatic [All] group, invalid XML -> E_FAIL with the old value kept). So the
        module reads the current document, adds / removes <Variant> / <Member> elements on that DOM
        (elements and attributes it does not know stay untouched; a new variant goes after the last
        <Variant>, a new group before the first, as in the sample of TE1000 v1.7.0 6.12.1 p.296) and
        writes the whole document back; the read-back document must equal it after normalizing
        (whitespace, XML declaration, comments).
        Checks (nothing written): names match ^[A-Za-z_][A-Za-z0-9_]*$ (INVALID_PARAMS); an added
        name already present (any case, names are case-sensitive in XAE) -> VARIANT_ALREADY_EXISTS;
        a removed name not present (exact case) -> VARIANT_NOT_FOUND; removing the current variant,
        or the group that is current -> VARIANT_IS_CURRENT (XAE would keep CurrentProjectVariant
        pointing at a name that no longer exists, question 17: switch with Set-TcCurrentVariant
        first). A removed variant is also removed from every group; a group left without members is
        removed (data.warnings). -Group: the added variants become members of that group (matched in
        any case like the variant names; created when missing).
        DryRun (default true): data.before / data.after (variants, groups), data.xml.
        DryRun=false: backup of the old document and the .tsproj (the variants are stored in its
        <Variants> element after a save, question 18), IDE_MODAL_DIALOG check, write, read back:
        the variant and group lists must equal the planned ones (VARIANT_VERIFY_FAILED). XAE
        refusing the document -> VARIANT_CONFIG_INVALID. BUILD_REQUIRED (code-changed) is recorded
        once the property was written.
        Item-level variant settings (PvDisable ...) are not changed here.
        Only unit tests so far; registered tcauto verification is task 4.6.
    .PARAMETER AddVariant
        Variant names to add.
    .PARAMETER RemoveVariant
        Variant names to remove (exact case).
    .PARAMETER Group
        Optional group the added variants join (created when missing).
    .PARAMETER DryRun
        Default true: only report the new document. false: back up, write, read back.
    .EXAMPLE
        Set-TcProjectVariantConfig -AddVariant Variant1, Variant2 -Group Group1
    .EXAMPLE
        Set-TcProjectVariantConfig -RemoveVariant Variant2 -DryRun $false
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string[]]$AddVariant,

        [Parameter()]
        [string[]]$RemoveVariant,

        [Parameter()]
        [string]$Group,

        [Parameter()]
        [bool]$DryRun = $true
    )

    $add = @($AddVariant | Where-Object { $null -ne $_ })
    $remove = @($RemoveVariant | Where-Object { $null -ne $_ })
    $data = [PSCustomObject]@{ addVariant = $add; removeVariant = $remove; group = $Group; dryRun = $DryRun }
    if ($add.Count -eq 0 -and $remove.Count -eq 0) {
        return New-TcResult -Success $false -ErrorCode 'INVALID_PARAMS' -Data $data -ErrorMessage 'Give -AddVariant and / or -RemoveVariant; nothing was written.'
    }
    $badNames = @(@($add) + @($remove) + @($(if ($PSBoundParameters.ContainsKey('Group')) { $Group })) | Where-Object { [string]$_ -notmatch $script:TcVariantNamePattern })
    if ($badNames.Count -gt 0) {
        return New-TcResult -Success $false -ErrorCode 'INVALID_PARAMS' -Data $data `
            -ErrorMessage "Variant / group names must match $($script:TcVariantNamePattern) (got $(($badNames | ForEach-Object { "'$_'" }) -join ', ')); nothing was written."
    }
    if ($PSBoundParameters.ContainsKey('Group') -and $add.Count -eq 0) {
        return New-TcResult -Success $false -ErrorCode 'INVALID_PARAMS' -Data $data -ErrorMessage '-Group only applies to -AddVariant; nothing was written.'
    }

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }
    $sm = Get-TcSysManager
    if ($null -eq $sm) { return New-TcNoSysManagerResult }

    $called = $false
    try {
        $st = Get-TcVariantState -SysManager $sm
        if (-not $st.Supported) {
            return New-TcResult -Success $false -ErrorCode 'VARIANT_NOT_SUPPORTED' -Data $data -ErrorMessage "Project variants cannot be read in this XAE: $($st.Error); nothing was written." -Hint (Get-TcErrorHint -Code 'VARIANT_NOT_SUPPORTED')
        }
        if (-not $st.Config.Ok) {
            return New-TcResult -Success $false -ErrorCode 'VARIANT_CONFIG_INVALID' -Data $data -ErrorMessage "$($st.Config.Error); nothing was written." -Hint (Get-TcErrorHint -Code 'VARIANT_CONFIG_INVALID')
        }
        $variants = [System.Collections.Generic.List[string]]::new()
        foreach ($v in @($st.Config.Variants)) { $variants.Add([string]$v) }
        $groups = [System.Collections.Generic.List[object]]::new()
        foreach ($g in @($st.Config.Groups)) { $groups.Add([PSCustomObject]@{ name = [string]$g.name; members = @($g.members) }) }
        $data | Add-Member -NotePropertyName current -NotePropertyValue $st.Current
        $data | Add-Member -NotePropertyName before -NotePropertyValue ([PSCustomObject]@{ variants = $variants.ToArray(); groups = @($groups | ForEach-Object { [PSCustomObject]@{ name = $_.name; members = @($_.members) } }) })

        foreach ($a in $add) {
            $hit = @($variants | Where-Object { $_ -ieq $a })
            if ($hit.Count -gt 0) {
                return New-TcResult -Success $false -ErrorCode 'VARIANT_ALREADY_EXISTS' -Data $data -ErrorMessage "A variant '$($hit[0])' already exists; nothing was written." -Hint (Get-TcErrorHint -Code 'VARIANT_ALREADY_EXISTS')
            }
        }
        foreach ($r in $remove) {
            if ($variants -cnotcontains $r) {
                $near = @($variants | Where-Object { $_ -ieq $r })
                $data | Add-Member -NotePropertyName variants -NotePropertyValue $variants.ToArray() -Force
                return New-TcResult -Success $false -ErrorCode 'VARIANT_NOT_FOUND' -Data $data `
                    -ErrorMessage "No variant '$r'$(if ($near.Count) { " (names are case-sensitive; there is '$($near[0])')" }); nothing was written." -Hint (Get-TcErrorHint -Code 'VARIANT_NOT_FOUND')
            }
            if ($st.Current -ceq $r) {
                return New-TcResult -Success $false -ErrorCode 'VARIANT_IS_CURRENT' -Data $data -ErrorMessage "'$r' is the current variant; XAE would keep pointing at it after it is removed. Nothing was written." -Hint (Get-TcErrorHint -Code 'VARIANT_IS_CURRENT')
            }
        }
        # review S6: change the document XAE gave us (unknown elements / attributes stay as they are)
        $doc = ConvertTo-TcVariantConfigDocument -Xml $st.ConfigXml
        if ($null -eq $doc) {
            return New-TcResult -Success $false -ErrorCode 'VARIANT_CONFIG_INVALID' -Data $data -ErrorMessage 'ProjectVariantConfig does not parse as a <ProjectVariants> document; nothing was written.' -Hint (Get-TcErrorHint -Code 'VARIANT_CONFIG_INVALID')
        }
        $root = $doc.DocumentElement
        $nameOf = { param($el) $n = $el.SelectSingleNode('Name'); if ($null -ne $n) { [string]$n.InnerText } else { '' } }
        foreach ($r in $remove) {
            foreach ($v in @($root.SelectNodes('Variant'))) { if ((& $nameOf $v) -ceq $r) { $null = $root.RemoveChild($v) } }
            foreach ($m in @($root.SelectNodes('Group/Member'))) { if ([string]$m.InnerText -ceq $r) { $null = $m.ParentNode.RemoveChild($m) } }
        }
        if ($remove.Count -gt 0) {
            foreach ($g in @($root.SelectNodes('Group'))) {
                if ($null -ne $g.SelectSingleNode('Member')) { continue }
                $gn = & $nameOf $g
                if ($st.Current -ceq "[$gn]") {
                    return New-TcResult -Success $false -ErrorCode 'VARIANT_IS_CURRENT' -Data $data -ErrorMessage "Removing $(($remove | ForEach-Object { "'$_'" }) -join ', ') leaves the current group '[$gn]' without members. Nothing was written." -Hint (Get-TcErrorHint -Code 'VARIANT_IS_CURRENT')
                }
                $null = $root.RemoveChild($g)
                Add-TcDataWarning -Data $data -Warning "group '$gn' has no member left and is removed"
            }
        }
        $lastVariant = @($root.SelectNodes('Variant'))
        $anchor = if ($lastVariant.Count -gt 0) { $lastVariant[-1] } else { $null }
        foreach ($av in $add) {
            $ve = $doc.CreateElement('Variant')
            $ne = $doc.CreateElement('Name'); $ne.InnerText = $av; $null = $ve.AppendChild($ne)
            if ($null -ne $anchor) { $null = $root.InsertAfter($ve, $anchor) } else { $null = $root.AppendChild($ve) }
            $anchor = $ve
        }
        if (-not [string]::IsNullOrWhiteSpace($Group)) {
            # N4: a group is matched like a variant name: any case (the existing spelling is kept)
            $ge = @($root.SelectNodes('Group') | Where-Object { (& $nameOf $_) -ieq $Group })[0]
            if ($null -eq $ge) {
                $ge = $doc.CreateElement('Group')
                $ne = $doc.CreateElement('Name'); $ne.InnerText = $Group; $null = $ge.AppendChild($ne)
                $firstVariant = $root.SelectSingleNode('Variant')
                if ($null -ne $firstVariant) { $null = $root.InsertBefore($ge, $firstVariant) } else { $null = $root.AppendChild($ge) }
            }
            elseif ((& $nameOf $ge) -cne $Group) { Add-TcDataWarning -Data $data -Warning "group '$Group' exists as '$(& $nameOf $ge)'; the variants are added to it" }
            $members = @($ge.SelectNodes('Member') | ForEach-Object { [string]$_.InnerText })
            foreach ($av in $add) {
                if ($members -ccontains $av) { continue }
                $me = $doc.CreateElement('Member'); $me.InnerText = $av; $null = $ge.AppendChild($me)
            }
        }
        $newXml = $doc.OuterXml
        $parsedNew = ConvertFrom-TcVariantConfig -Xml $newXml
        $data | Add-Member -NotePropertyName after -NotePropertyValue ([PSCustomObject]@{ variants = @($parsedNew.Variants); groups = @($parsedNew.Groups) })
        $data | Add-Member -NotePropertyName xml -NotePropertyValue $newXml
        if ($DryRun) { return New-TcResult -Success $true -Data $data }

        $bk = New-TcConfigBackup -Label 'ProjectVariantConfig' -Text $st.ConfigXml -DiskFiles @(Get-TcVariantDiskFiles) -Data $data
        if ($null -ne $bk.Result) { return $bk.Result }
        Add-TcBackupToData -Data $data -Backup $bk.Backup
        $dlg = Get-TcTreeItemDialogResult -Operation 'ProjectVariantConfig =' -Data $data
        if ($null -ne $dlg) { return $dlg }
        $called = $true
        $data | Add-Member -NotePropertyName writeCalled -NotePropertyValue $true -Force
        # No deadline (CODING_STANDARDS.md 1): dialog ruled out just above; 93 ms in the probe (question 15).
        try { Invoke-TcComRetry -OperationName 'ProjectVariantConfig' -ScriptBlock { $sm.ProjectVariantConfig = $newXml } | Out-Null }
        catch {
            if ($null -ne (Get-TcTreeItemPassThroughError -ErrorRecord $_)) { throw }
            $res = New-TcResult -Success $false -ErrorCode 'VARIANT_CONFIG_INVALID' -Data $data -ErrorMessage "XAE refused the new ProjectVariantConfig: $($_.Exception.Message)" -Hint (Get-TcErrorHint -Code 'VARIANT_CONFIG_INVALID')
            return Register-TcCodeChange -Result $res -Change 'Set-TcProjectVariantConfig [failed]'
        }
        $backXml = [string](Invoke-TcComRetry -OperationName 'ProjectVariantConfig' -ScriptBlock { $sm.ProjectVariantConfig })
        $back = ConvertFrom-TcVariantConfig -Xml $backXml
        # review S6: the whole document must come back (normalized: whitespace, declaration, comments)
        $expN = ConvertTo-TcNormalizedXml -Xml $newXml
        $gotN = ConvertTo-TcNormalizedXml -Xml $backXml
        $ok = $null -ne $gotN -and [string]::Equals($expN, $gotN, [System.StringComparison]::Ordinal)
        $data | Add-Member -NotePropertyName readback -NotePropertyValue ([PSCustomObject]@{ variants = @($back.Variants); groups = @($back.Groups) })
        if (-not $ok) {
            $data | Add-Member -NotePropertyName verified -NotePropertyValue $false
            $res = New-TcResult -Success $false -ErrorCode 'VARIANT_VERIFY_FAILED' -Data $data -ErrorMessage 'ProjectVariantConfig was written, but the document read back differs from the one written (compared after normalizing; data.readback vs data.after).' -Hint (Get-TcErrorHint -Code 'VARIANT_VERIFY_FAILED')
            return Register-TcCodeChange -Result $res -Change 'Set-TcProjectVariantConfig [failed at verify]'
        }
        $data | Add-Member -NotePropertyName verified -NotePropertyValue $true
        return Register-TcCodeChange -Result (New-TcResult -Success $true -Data $data) -Change "Set-TcProjectVariantConfig +$($add -join ',') -$($remove -join ',')"
    }
    catch {
        $res = New-TcTreeItemErrorResult -ErrorRecord $_ -DefaultCode 'VARIANT_CONFIG_INVALID' -Data $data -Operation 'Set-TcProjectVariantConfig'
        if ($called) { $res = Register-TcCodeChange -Result $res -Change 'Set-TcProjectVariantConfig [failed]' }
        return $res
    }
}
