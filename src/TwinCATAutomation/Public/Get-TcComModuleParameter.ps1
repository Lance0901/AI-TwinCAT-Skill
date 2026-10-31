function Get-TcComModuleParameter {
    <#
    .SYNOPSIS
        Reads TcCOM module parameters: without -Name / -ParameterId the list from the ProduceXml; with one, its value via GetModulePara (offline) or GetOnlineModulePara (-Online). Read-only.
    .DESCRIPTION
        Measured 2026-11-01 4026 VS2022 XAE 3.1.4026.22, self-built client
        (openspec/changes/complete-automation-interface/verification/phase3-probe.md questions 10, 11,
        13; TE1000 v1.7.0 5.31.1.1 p.130, 5.33.1 p.136-139):
          - the parameter list (name, PTCID = parameter id, BitSize, BaseType) is in the module
            ProduceXml 'TcModuleInstance/Module/Parameters/Parameter'; the current project values in
            'ParameterValues/Value' (Value / EnumText / String).
          - offline: GetModulePara(pid) on the module tree item -> little-endian bytes (E_FAIL for an
            unknown pid); GetTypeOfModulePara(pid).Name gives the type (an enum's own name for enums).
          - -Online: ITcModuleManager.GetOnlineModulePara(oid, pid, maxData) reads the running object
            on the target (the manual: AdsSyncReadReq to AMSPORT_R0_TCOMSERVER = port 10, index group
            = oid, index offset = pid; the same value was read with raw ADS port 10 in the probe).
            0x98110703 -> TCCOM_PARAM_NOT_FOUND, 0x9811071D -> TCCOM_OBJECT_NOT_FOUND (not
            activated / not running), 0x98110705 -> TCCOM_PARAM_SIZE_MISMATCH.
        The module is found by tree path or instance name (ITcModuleManager Modules.Item(i), foreach
        and LookupModule do not work through late binding, and the children of TIRC^TcCOM Objects,
        named '<name> (<type>)').
        data (one parameter): modulePath, oid / oidHex, name, parameterId (hex), bitSize, baseType,
        typeName, value (decoded; $null for types that are only shown as hex), rawHex, projectValue
        (ParameterValues text), online. data (list): parameters[] (name, parameterId, bitSize,
        baseType, projectValue, group).
        Only unit tests so far; registered tcauto verification is task 4.6.
    .PARAMETER Module
        Instance name or tree path (TIRC^TcCOM Objects^<name> (<type>)).
    .PARAMETER Name
        Parameter name (case-insensitive), e.g. PollInterval.
    .PARAMETER ParameterId
        Parameter id (PTCID) as '#x03150105', '0x03150105' or decimal, instead of -Name.
    .PARAMETER Online
        Read the value of the running object on the target (needs Activate + Run) instead of the project value.
    .EXAMPLE
        Get-TcComModuleParameter -Module NtpTest
    .EXAMPLE
        Get-TcComModuleParameter -Module NtpTest -Name PollInterval -Online
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

        [Parameter()]
        [switch]$Online
    )

    $data = [PSCustomObject]@{ module = $Module; online = [bool]$Online }
    if (-not [string]::IsNullOrWhiteSpace($Name) -and -not [string]::IsNullOrWhiteSpace($ParameterId)) {
        return New-TcResult -Success $false -ErrorCode 'INVALID_PARAMS' -Data $data -ErrorMessage 'Give -Name or -ParameterId, not both.'
    }
    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }
    $sm = Get-TcSysManager
    if ($null -eq $sm) { return New-TcNoSysManagerResult }

    try {
        $m = Resolve-TcComModule -SysManager $sm -Module $Module -Data $data
        if ($null -ne $m.Result) { return $m.Result }
        $info = $m.Info
        $data | Add-Member -NotePropertyName oid -NotePropertyValue $info.oid
        $data | Add-Member -NotePropertyName oidHex -NotePropertyValue $info.oidHex
        $data | Add-Member -NotePropertyName typeName -NotePropertyValue $info.typeName -Force
        if ([string]::IsNullOrWhiteSpace($Name) -and [string]::IsNullOrWhiteSpace($ParameterId)) {
            if ($Online) { return New-TcResult -Success $false -ErrorCode 'INVALID_PARAMS' -Data $data -ErrorMessage '-Online reads one parameter: give -Name or -ParameterId.' }
            $data | Add-Member -NotePropertyName parameters -NotePropertyValue @($info.parameters | ForEach-Object {
                    [PSCustomObject]@{ name = $_.name; parameterId = $_.idHex; bitSize = $_.bitSize; baseType = $_.baseType; group = $_.group; projectValue = $info.values[$_.name] }
                }) -Force
            return New-TcResult -Success $true -Data $data
        }
        $f = Find-TcComParameter -Info $info -Name $Name -ParameterId $ParameterId -Data $data
        if ($null -ne $f.Result) { return $f.Result }
        $p = $f.Parameter
        $data | Add-Member -NotePropertyName name -NotePropertyValue $p.name -Force
        $data | Add-Member -NotePropertyName parameterId -NotePropertyValue $p.idHex
        $data | Add-Member -NotePropertyName bitSize -NotePropertyValue $p.bitSize
        $data | Add-Member -NotePropertyName baseType -NotePropertyValue $p.baseType
        $data | Add-Member -NotePropertyName projectValue -NotePropertyValue $info.values[$p.name]
        $item = $m.Item
        $tn = $null
        try { $tn = [string](Invoke-TcComRetry -OperationName "GetTypeOfModulePara $($p.idHex)" -ScriptBlock { $item.GetTypeOfModulePara($p.id) }).Name }
        catch { if ($null -ne (Get-TcTreeItemPassThroughError -ErrorRecord $_)) { throw }; $tn = $null }
        $type = Get-TcComParamType -Parameter $p -TypeName $tn -DataTypes $info.dataTypes
        $data | Add-Member -NotePropertyName paramType -NotePropertyValue $type.name
        $bytes = $null
        try {
            if ($Online) {
                if ($null -eq $info.oid) { return New-TcResult -Success $false -ErrorCode 'TCCOM_OBJECT_NOT_FOUND' -Data $data -ErrorMessage "Module '$($m.Path)' has no ObjectId in its ProduceXml; it cannot be read online." -Hint (Get-TcErrorHint -Code 'TCCOM_OBJECT_NOT_FOUND') }
                $mm = Invoke-TcComRetry -OperationName 'GetModuleManager' -ScriptBlock { Write-Output -NoEnumerate $sm.GetModuleManager() }
                $max = [uint32][Math]::Max(1024, [int]$type.bytes)
                $bytes = ConvertTo-TcByteArray -Value (Invoke-TcComRetry -OperationName "GetOnlineModulePara $($info.oidHex) $($p.idHex)" -ScriptBlock { $mm.GetOnlineModulePara([uint32]$info.oid, [uint32]$p.id, $max) })
            }
            else {
                $bytes = ConvertTo-TcByteArray -Value (Invoke-TcComRetry -OperationName "GetModulePara $($p.idHex)" -ScriptBlock { $item.GetModulePara($p.id) })
            }
        }
        catch {
            if ($null -ne (Get-TcTreeItemPassThroughError -ErrorRecord $_)) { throw }
            $code = ConvertTo-TcComErrorCode -ErrorRecord $_ -Operation $(if ($Online) { 'online' } else { 'param-get' }) -DefaultCode 'TCCOM_PARAM_READ_FAILED'
            return New-TcResult -Success $false -ErrorCode $code -Data $data `
                -ErrorMessage "$(if ($Online) { 'GetOnlineModulePara' } else { 'GetModulePara' })($($p.idHex)) on '$($m.Path)' failed: $($_.Exception.Message)" -Hint (Get-TcErrorHint -Code $code)
        }
        $data | Add-Member -NotePropertyName rawHex -NotePropertyValue (Format-TcHexBytes -Bytes $bytes)
        $data | Add-Member -NotePropertyName value -NotePropertyValue (ConvertFrom-TcComParamBytes -Type $type -Bytes $bytes)
        return New-TcResult -Success $true -Data $data
    }
    catch {
        New-TcTreeItemErrorResult -ErrorRecord $_ -DefaultCode 'TCCOM_PARAM_READ_FAILED' -Data $data -Operation 'Get-TcComModuleParameter'
    }
}
