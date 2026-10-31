function Set-TcComModuleParameter {
    <#
    .SYNOPSIS
        Writes one TcCOM module parameter (SetModulePara into the project, or SetOnlineModulePara with -Online into the running object only) and reads it back. Dry-run by default.
    .DESCRIPTION
        Measured 2026-11-01 4026 VS2022 XAE 3.1.4026.22 + local UmRT, self-built client
        (openspec/changes/complete-automation-interface/verification/phase3-probe.md questions 11, 13;
        TE1000 v1.7.0 5.33.1.6 p.139, 5.31.1.5 p.132):
          - the value is converted to exactly the parameter size first (type from the ProduceXml
            BaseType / GetTypeOfModulePara, size from BitSize; an enum is an integer of its BitSize)
            and range checked (INVALID: TCCOM_PARAM_INVALID_VALUE; struct / array types and named
            types that the module's DataTypes do not confirm as an enum are read-only here:
            TCCOM_PARAM_UNSUPPORTED_TYPE). A current value of another size than the planned bytes ->
            TCCOM_PARAM_SIZE_MISMATCH before anything is sent. A wrong size is refused by XAE with 0x98110705
            (ADS_E_INVALIDSIZE) -> TCCOM_PARAM_SIZE_MISMATCH; online an 8-byte scalar is refused too,
            so bytes are always sent.
          - offline: SetModulePara(pid, byte[]) on the module tree item; it changes the project in
            XAE memory (ProduceXml ParameterValues at once, no file until the project is saved).
            Backup: module ProduceXml (data.backupPath). Readback: GetModulePara must return the
            same bytes, else TCCOM_PARAM_VERIFY_FAILED. BUILD_REQUIRED (code-changed) is recorded
            once SetModulePara was called.
          - -Online: ITcModuleManager.SetOnlineModulePara(oid, pid, byte[]) writes the running object
            on the target only: the project value is NOT changed (measured: offline value and
            ProduceXml stayed 4321) and is restored by the next Activate. The previous online value
            is in data.previousHex (and in the backup file). Readback with GetOnlineModulePara.
            Nothing is recorded as BUILD_REQUIRED. 0x9811071D -> TCCOM_OBJECT_NOT_FOUND (not running).
        Before an online write (dry-run too) the project boot package must equal the target's Boot
        folder (Get-TcBootPackageDiff status 'match', variant boot folder included), else
        TCCOM_ONLINE_CONFIG_MISMATCH: an older or other configuration may use the same oid / pid
        for another object; a remote target ('unavailable') is refused as well (data.bootPackage).
        A modal dialog is checked right before the write (IDE_MODAL_DIALOG, nothing written).
        Same value already: success, data.written = false.
        DryRun (default true): data.currentHex, data.plannedHex, data.value.
        Only unit tests so far; registered tcauto verification is task 4.6.
    .PARAMETER Module
        Instance name or tree path (TIRC^TcCOM Objects^<name> (<type>)).
    .PARAMETER Name
        Parameter name (case-insensitive).
    .PARAMETER ParameterId
        Parameter id (PTCID) as '#x03150105', '0x03150105' or decimal, instead of -Name.
    .PARAMETER Value
        New value: number (invariant culture, '.' as decimal separator), true / false for BOOL, text for STRING.
    .PARAMETER Online
        Write the running object on the target only (needs Activate + Run); the project is not changed.
    .PARAMETER DryRun
        Default true: only report the planned bytes. false: back up, write, read back.
    .EXAMPLE
        Set-TcComModuleParameter -Module NtpTest -Name ClientEnable -Value false
    .EXAMPLE
        Set-TcComModuleParameter -Module NtpTest -Name PollInterval -Value 5000 -Online -DryRun $false
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Module,

        [Parameter()]
        [string]$Name,

        [Parameter()]
        [string]$ParameterId,

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [object]$Value,

        [Parameter()]
        [switch]$Online,

        [Parameter()]
        [bool]$DryRun = $true
    )

    $data = [PSCustomObject]@{ module = $Module; online = [bool]$Online; dryRun = $DryRun }
    $hasName = -not [string]::IsNullOrWhiteSpace($Name)
    $hasId = -not [string]::IsNullOrWhiteSpace($ParameterId)
    if ($hasName -eq $hasId) {
        return New-TcResult -Success $false -ErrorCode 'INVALID_PARAMS' -Data $data -ErrorMessage 'Give exactly one of -Name and -ParameterId; nothing was written.'
    }
    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }
    $sm = Get-TcSysManager
    if ($null -eq $sm) { return New-TcNoSysManagerResult }

    $called = $false
    $what = if ($Online) { 'SetOnlineModulePara' } else { 'SetModulePara' }
    try {
        $m = Resolve-TcComModule -SysManager $sm -Module $Module -Data $data
        if ($null -ne $m.Result) { return $m.Result }
        $info = $m.Info
        $item = $m.Item
        $f = Find-TcComParameter -Info $info -Name $Name -ParameterId $ParameterId -Data $data
        if ($null -ne $f.Result) { return $f.Result }
        $p = $f.Parameter
        $data | Add-Member -NotePropertyName name -NotePropertyValue $p.name -Force
        $data | Add-Member -NotePropertyName parameterId -NotePropertyValue $p.idHex
        $data | Add-Member -NotePropertyName oidHex -NotePropertyValue $info.oidHex
        $tn = $null
        try { $tn = [string](Invoke-TcComRetry -OperationName "GetTypeOfModulePara $($p.idHex)" -ScriptBlock { $item.GetTypeOfModulePara($p.id) }).Name }
        catch { if ($null -ne (Get-TcTreeItemPassThroughError -ErrorRecord $_)) { throw }; $tn = $null }
        $type = Get-TcComParamType -Parameter $p -TypeName $tn -DataTypes $info.dataTypes
        $data | Add-Member -NotePropertyName paramType -NotePropertyValue $type.name
        $planned = $null
        try { $planned = ConvertTo-TcComParamBytes -Type $type -Value $Value }
        catch {
            $msg = $_.Exception.Message
            $code = if ($msg -match '^(TCCOM_PARAM_[A-Z_]+):\s*') { $Matches[1] } else { 'TCCOM_PARAM_INVALID_VALUE' }
            return New-TcResult -Success $false -ErrorCode $code -Data $data -ErrorMessage (($msg -replace '^TCCOM_PARAM_[A-Z_]+:\s*', '') + '; nothing was written.') -Hint (Get-TcErrorHint -Code $code)
        }
        $data | Add-Member -NotePropertyName plannedHex -NotePropertyValue (Format-TcHexBytes -Bytes $planned)
        $data | Add-Member -NotePropertyName value -NotePropertyValue (ConvertFrom-TcComParamBytes -Type $type -Bytes $planned)

        $mm = $null
        if ($Online) {
            if ($null -eq $info.oid) { return New-TcResult -Success $false -ErrorCode 'TCCOM_OBJECT_NOT_FOUND' -Data $data -ErrorMessage "Module '$($m.Path)' has no ObjectId in its ProduceXml; nothing was written." -Hint (Get-TcErrorHint -Code 'TCCOM_OBJECT_NOT_FOUND') }
            # review S11: the running configuration must be the one of this project, else the oid /
            # pid may belong to another object (Get-TcBootPackageDiff, as Enable-TcConfig does)
            $cfg = Test-TcOnlineConfigMatch -SysManager $sm
            $data | Add-Member -NotePropertyName bootPackage -NotePropertyValue $cfg.BootPackage
            if (-not $cfg.Match) {
                return New-TcResult -Success $false -ErrorCode 'TCCOM_ONLINE_CONFIG_MISMATCH' -Data $data `
                    -ErrorMessage "The configuration running on the target is not confirmed to be this project's ($($cfg.Reason)); nothing was written online." -Hint (Get-TcErrorHint -Code 'TCCOM_ONLINE_CONFIG_MISMATCH')
            }
            $mm = Invoke-TcComRetry -OperationName 'GetModuleManager' -ScriptBlock { Write-Output -NoEnumerate $sm.GetModuleManager() }
        }
        $readBytes = {
            if ($Online) {
                $max = [uint32][Math]::Max(1024, [int]$type.bytes)
                ConvertTo-TcByteArray -Value (Invoke-TcComRetry -OperationName "GetOnlineModulePara $($info.oidHex) $($p.idHex)" -ScriptBlock { $mm.GetOnlineModulePara([uint32]$info.oid, [uint32]$p.id, $max) })
            }
            else { ConvertTo-TcByteArray -Value (Invoke-TcComRetry -OperationName "GetModulePara $($p.idHex)" -ScriptBlock { $item.GetModulePara($p.id) }) }
        }
        $current = $null
        try { $current = [byte[]](& $readBytes) }
        catch {
            if ($null -ne (Get-TcTreeItemPassThroughError -ErrorRecord $_)) { throw }
            $code = ConvertTo-TcComErrorCode -ErrorRecord $_ -Operation $(if ($Online) { 'online' } else { 'param-get' }) -DefaultCode 'TCCOM_PARAM_READ_FAILED'
            return New-TcResult -Success $false -ErrorCode $code -Data $data -ErrorMessage "Reading the current value of $($p.name) failed: $($_.Exception.Message); nothing was written." -Hint (Get-TcErrorHint -Code $code)
        }
        $curHex = Format-TcHexBytes -Bytes $current
        $data | Add-Member -NotePropertyName currentHex -NotePropertyValue $curHex
        # review S10: the value read now must have the size that would be written
        if (@($current).Count -ne @($planned).Count) {
            return New-TcResult -Success $false -ErrorCode 'TCCOM_PARAM_SIZE_MISMATCH' -Data $data `
                -ErrorMessage "$($p.name) reads $(@($current).Count) bytes but the planned value has $(@($planned).Count) ($($type.name), BitSize $($p.bitSize)); nothing was written." -Hint (Get-TcErrorHint -Code 'TCCOM_PARAM_SIZE_MISMATCH')
        }
        $data | Add-Member -NotePropertyName previousHex -NotePropertyValue $curHex
        $data | Add-Member -NotePropertyName projectChanged -NotePropertyValue (-not $Online)
        if ($curHex -eq $data.plannedHex) {
            $data | Add-Member -NotePropertyName written -NotePropertyValue $false
            return New-TcResult -Success $true -Data $data
        }
        if ($DryRun) { return New-TcResult -Success $true -Data $data }

        if ($Online) { $bk = New-TcConfigBackup -Label "$($m.Path).online-$($p.idHex)" -Text "<OnlineParameter Module=`"$($info.oidHex)`" Id=`"$($p.idHex)`" Name=`"$([System.Security.SecurityElement]::Escape($p.name))`">$curHex</OnlineParameter>" -Data $data }
        else {
            $bk = Invoke-TcTreeItemBackup -Item $item -Path $m.Path -Data $data
        }
        if ($null -ne $bk.Result) { return $bk.Result }
        Add-TcBackupToData -Data $data -Backup $bk.Backup
        $dlg = Get-TcTreeItemDialogResult -Operation "$what $($p.name)" -Data $data
        if ($null -ne $dlg) { return $dlg }
        $called = $true
        $data | Add-Member -NotePropertyName writeCalled -NotePropertyValue $true -Force
        # No deadline (CODING_STANDARDS.md 1): a dialog was ruled out just above; Set(Online)ModulePara
        # returned in a few ms in the probe (questions 11, 13).
        try {
            if ($Online) { Invoke-TcComRetry -OperationName "SetOnlineModulePara $($p.idHex)" -ScriptBlock { $mm.SetOnlineModulePara([uint32]$info.oid, [uint32]$p.id, $planned) } | Out-Null }
            else { Invoke-TcComRetry -OperationName "SetModulePara $($p.idHex)" -ScriptBlock { $item.SetModulePara($p.id, $planned) } | Out-Null }
        }
        catch {
            if ($null -ne (Get-TcTreeItemPassThroughError -ErrorRecord $_)) { throw }
            $code = ConvertTo-TcComErrorCode -ErrorRecord $_ -Operation $(if ($Online) { 'online' } else { 'param-set' }) -DefaultCode 'TCCOM_PARAM_WRITE_FAILED'
            $res = New-TcResult -Success $false -ErrorCode $code -Data $data -ErrorMessage "$what($($p.idHex), $($data.plannedHex)) on '$($m.Path)' failed: $($_.Exception.Message)" -Hint (Get-TcErrorHint -Code $code)
            if (-not $Online) { $res = Register-TcCodeChange -Result $res -Change "Set-TcComModuleParameter $($m.Path) $($p.name) [failed]" }
            return $res
        }
        $data | Add-Member -NotePropertyName written -NotePropertyValue $true
        $after = $null
        try { $after = Format-TcHexBytes -Bytes ([byte[]](& $readBytes)) }
        catch { if ($null -ne (Get-TcTreeItemPassThroughError -ErrorRecord $_)) { throw }; $after = "(read failed: $($_.Exception.Message))" }
        $data | Add-Member -NotePropertyName readbackHex -NotePropertyValue $after
        $res = $null
        if ($after -ne $data.plannedHex) {
            $data | Add-Member -NotePropertyName verified -NotePropertyValue $false
            $res = New-TcResult -Success $false -ErrorCode 'TCCOM_PARAM_VERIFY_FAILED' -Data $data `
                -ErrorMessage "$what returned, but $(if ($Online) { 'GetOnlineModulePara' } else { 'GetModulePara' }) reads $after instead of $($data.plannedHex)." -Hint (Get-TcErrorHint -Code 'TCCOM_PARAM_VERIFY_FAILED')
        }
        else {
            $data | Add-Member -NotePropertyName verified -NotePropertyValue $true
            $res = New-TcResult -Success $true -Data $data
        }
        if (-not $Online) { $res = Register-TcCodeChange -Result $res -Change "Set-TcComModuleParameter $($m.Path) $($p.name)" }
        return $res
    }
    catch {
        $res = New-TcTreeItemErrorResult -ErrorRecord $_ -DefaultCode 'TCCOM_PARAM_WRITE_FAILED' -Data $data -Operation 'Set-TcComModuleParameter'
        if ($called -and -not $Online) { $res = Register-TcCodeChange -Result $res -Change "Set-TcComModuleParameter $Module [failed]" }
        return $res
    }
}
