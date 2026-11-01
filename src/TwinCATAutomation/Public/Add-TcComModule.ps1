function Add-TcComModule {
    <#
    .SYNOPSIS
        Creates a TcCOM module instance below 'TIRC^TcCOM Objects' from its class GUID or type name and returns the name XAE actually gave it. Dry-run by default.
    .DESCRIPTION
        TE1000 Automation Interface manual v1.7.0 6.7.1 p.274-275: CreateChild(name, 0, '', <GUID or
        module name>). Measured 2026-11-01 4026 VS2022 XAE 3.1.4026.22 / 4024 XAE Shell 3.1.4024.71,
        self-built client (openspec/changes/complete-automation-interface/verification/phase3-probe.md
        question 9): GUID with or without braces and the type name with subType 0 or 1 all work; XAE
        names the instance '<Name> (<ModuleTypeName>)'; a taken name is renamed '<Name>_ObjN (...)'
        without an error (4024 adds _ObjN even the first time); an unknown GUID fails with
        0x98510009 "TCOM Module / TCOM Configuration with GUID '%s' not found!" -> TCCOM_CLASS_NOT_FOUND.
        So the module checks first: an existing child named <Name> or '<Name> (...)'
        (case-insensitive) -> TCCOM_MODULE_ALREADY_EXISTS, nothing created; and the result always
        comes from the readback: data.createdPath / createdName (the renamed tree name), classId
        (Module/@GUID of the ProduceXml), typeName, oid / oidHex, contextIds (TMC Context Id, use it
        with Set-TcComModuleContext), parameterCount. A different name is a warning, not a failure.
        A class GUID that differs from -ClassId, or a type that differs from -TypeName ->
        TCCOM_VERIFY_FAILED and the instance is deleted again (data.rollback).
        The module must be installed where TwinCAT finds it (CustomConfig\Modules or a folder listed
        in Config\Io\TcModuleFolders.xml, manual p.274). TMC without <Licenses> is no proof that no
        license is needed: only TcNtpExternalTimeProvider {7e6d2fda-2d37-4998-a31f-36958d3a2c8a} was
        activated on the local UmRT in the probe (question 8; set its ClientEnable FALSE first, it
        would contact ntp.beckhoff-cloud.com).
        Uses New-TcTreeItem (backup of the folder, modal dialog check, parent / child readback).
        BUILD_REQUIRED (code-changed) is recorded once CreateChild was called.
        DryRun (default true): nothing is created; data.plannedSteps, data.vInfo.
        Verified with registered tcauto on 4026 and 4024 (openspec/changes/complete-automation-interface/verification/phase3-4.6.md).
    .PARAMETER Name
        Instance name (no '^'); XAE appends ' (<type>)'.
    .PARAMETER ClassId
        Class GUID from the TMC (<Module GUID=...>), with or without braces. Exactly one of ClassId / TypeName.
    .PARAMETER TypeName
        Module type name, e.g. TcNtpExternalTimeProvider. Exactly one of ClassId / TypeName.
    .PARAMETER DryRun
        Default true: only check and report the plan. false: create and read back.
    .EXAMPLE
        Add-TcComModule -Name NtpTest -ClassId '{7e6d2fda-2d37-4998-a31f-36958d3a2c8a}'
    .EXAMPLE
        Add-TcComModule -Name NtpTest -TypeName TcNtpExternalTimeProvider -DryRun $false
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Name,

        [Parameter()]
        [string]$ClassId,

        [Parameter()]
        [string]$TypeName,

        [Parameter()]
        [bool]$DryRun = $true
    )

    $data = [PSCustomObject]@{ name = $Name; dryRun = $DryRun; folder = $script:TcComFolderPath }
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Contains('^')) {
        return New-TcResult -Success $false -ErrorCode 'INVALID_PARAMS' -Data $data -ErrorMessage "-Name must be a non-empty name without '^' (got '$Name'); nothing was created."
    }
    $hasId = -not [string]::IsNullOrWhiteSpace($ClassId)
    $hasType = -not [string]::IsNullOrWhiteSpace($TypeName)
    if ($hasId -eq $hasType) {
        return New-TcResult -Success $false -ErrorCode 'INVALID_PARAMS' -Data $data -ErrorMessage 'Give exactly one of -ClassId (GUID) and -TypeName; nothing was created.'
    }
    $guid = $null
    if ($hasId) {
        $guid = ConvertTo-TcGuidText -Value $ClassId
        if ($null -eq $guid) { return New-TcResult -Success $false -ErrorCode 'INVALID_PARAMS' -Data $data -ErrorMessage "-ClassId '$ClassId' is not a GUID; nothing was created." }
        $data | Add-Member -NotePropertyName classIdRequested -NotePropertyValue $guid
    }
    elseif ($TypeName -notmatch '^[A-Za-z_][A-Za-z0-9_. -]*$') {
        return New-TcResult -Success $false -ErrorCode 'INVALID_PARAMS' -Data $data -ErrorMessage "-TypeName '$TypeName' is not a module type name; nothing was created."
    }
    $vInfo = if ($hasId) { $guid } else { $TypeName.Trim() }
    $data | Add-Member -NotePropertyName vInfo -NotePropertyValue $vInfo

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }
    $sm = Get-TcSysManager
    if ($null -eq $sm) { return New-TcNoSysManagerResult }

    $called = $false
    try {
        $r = Resolve-TcTreeItem -SysManager $sm -Path $script:TcComFolderPath -Data $data
        if ($null -ne $r.Result) { return $r.Result }
        $esc = [System.Management.Automation.WildcardPattern]::Escape($Name)
        $taken = @(Get-TcTreeItemChildList -Item $r.Item | Where-Object { $_.name -ieq $Name -or $_.name -ilike "$esc (*)" } | ForEach-Object { $_.name })
        if ($taken.Count -gt 0) {
            $data | Add-Member -NotePropertyName existingModules -NotePropertyValue $taken
            return New-TcResult -Success $false -ErrorCode 'TCCOM_MODULE_ALREADY_EXISTS' -Data $data `
                -ErrorMessage "A TcCOM instance '$($taken[0])' already exists (XAE would rename the new one to '$($Name)_ObjN'); nothing was created." -Hint (Get-TcErrorHint -Code 'TCCOM_MODULE_ALREADY_EXISTS')
        }
        $data | Add-Member -NotePropertyName plannedSteps -NotePropertyValue @("CreateChild '$($script:TcComFolderPath)' '$Name' SubType 0 vInfo '$vInfo'", 'readback: renamed tree name, Module/@GUID, Module/Name, contexts')
        if ($DryRun) { return New-TcResult -Success $true -Data $data }

        $c = New-TcTreeItem -Path $script:TcComFolderPath -Name $Name -SubType 0 -VInfo $vInfo -DryRun $false
        $called = Test-TcWriteCalled -Result $c
        Copy-TcDataFields -From $c.data -To $data -Names @('backupPath', 'backupFiles', 'warnings', 'hresult', 'hresultHex')
        if (-not $c.success) {
            $code = [string]$c.error.code
            $hint = [string]$c.error.hint
            # N1: by HRESULT (0x98510009, phase3-probe.md question 9); the English text is the fallback
            $hr = if ($null -ne $c.data -and $null -ne $c.data.PSObject.Properties['hresult']) { [int]$c.data.hresult } else { 0 }
            if ($code -eq 'TREEITEM_CREATE_FAILED' -and ($hr -eq [int]0x98510009 -or ($hr -eq 0 -and [string]$c.error.message -match 'TCOM Module / TCOM Configuration with GUID'))) { $code = 'TCCOM_CLASS_NOT_FOUND'; $hint = Get-TcErrorHint -Code $code }
            $res = New-TcResult -Success $false -ErrorCode $code -Data $data -ErrorMessage "Add-TcComModule: $($c.error.message)" -Hint $hint
            if ($called) { $res = Register-TcCodeChange -Result $res -Change "Add-TcComModule $Name [failed]" }
            return $res
        }
        $path = [string]$c.data.createdPath
        $data | Add-Member -NotePropertyName createdPath -NotePropertyValue $path
        $data | Add-Member -NotePropertyName createdName -NotePropertyValue ([string]$c.data.createdName)
        $item = Find-TcTreeItemNoThrow -SysManager $sm -Path $path
        $info = if ($null -ne $item) { Get-TcComModuleInfo -Item $item -Path $path } else { $null }
        $mism = [System.Collections.Generic.List[object]]::new()
        if ($null -eq $info -or -not $info.isModule) { $mism.Add([PSCustomObject]@{ field = 'TcModuleInstance'; expected = 'Module in the ProduceXml'; actual = '(missing)' }) }
        else {
            $data | Add-Member -NotePropertyName classId -NotePropertyValue $info.classId
            $data | Add-Member -NotePropertyName typeName -NotePropertyValue $info.typeName
            $data | Add-Member -NotePropertyName oid -NotePropertyValue $info.oid
            $data | Add-Member -NotePropertyName oidHex -NotePropertyValue $info.oidHex
            $data | Add-Member -NotePropertyName contextIds -NotePropertyValue @($info.contextIds)
            $data | Add-Member -NotePropertyName parameterCount -NotePropertyValue @($info.parameters).Count
            if ($hasId -and $info.classId -ne $guid) { $mism.Add([PSCustomObject]@{ field = 'Module/@GUID'; expected = $guid; actual = [string]$info.classId }) }
            if ($hasType) {
                $leaf = [string]$c.data.createdName
                $okType = ([string]$info.typeName -ieq $TypeName.Trim()) -or $leaf -ilike "* ($([System.Management.Automation.WildcardPattern]::Escape($TypeName.Trim())))"
                if (-not $okType) { $mism.Add([PSCustomObject]@{ field = 'Module/Name'; expected = $TypeName; actual = [string]$info.typeName }) }
            }
        }
        if ($mism.Count -gt 0) {
            $rb = Invoke-TcNcAxisRollback -Path $path
            $data | Add-Member -NotePropertyName mismatches -NotePropertyValue $mism.ToArray()
            $data | Add-Member -NotePropertyName rollback -NotePropertyValue @($rb)
            $data | Add-Member -NotePropertyName rolledBack -NotePropertyValue $rb.removed
            $data | Add-Member -NotePropertyName verified -NotePropertyValue $false
            $res = New-TcResult -Success $false -ErrorCode 'TCCOM_VERIFY_FAILED' -Data $data `
                -ErrorMessage ("CreateChild returned, but the readback differs: " + (($mism | ForEach-Object { "$($_.field) expected '$($_.expected)' actual '$($_.actual)'" }) -join '; ') + "; $(if ($rb.removed) { 'the instance was deleted again' } else { "the instance could NOT be deleted ($($rb.message))" }).") -Hint (Get-TcErrorHint -Code 'TCCOM_VERIFY_FAILED')
            return Register-TcCodeChange -Result $res -Change "Add-TcComModule $Name [failed at verify]"
        }
        $data | Add-Member -NotePropertyName verified -NotePropertyValue $true
        return Register-TcCodeChange -Result (New-TcResult -Success $true -Data $data) -Change "Add-TcComModule $path"
    }
    catch {
        $res = New-TcTreeItemErrorResult -ErrorRecord $_ -DefaultCode 'TREEITEM_CREATE_FAILED' -Data $data -Operation 'Add-TcComModule'
        if ($called) { $res = Register-TcCodeChange -Result $res -Change "Add-TcComModule $Name [failed]" }
        return $res
    }
}
