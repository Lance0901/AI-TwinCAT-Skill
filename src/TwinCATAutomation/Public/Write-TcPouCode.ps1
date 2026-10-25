function Write-TcPouCode {
    <#
    .SYNOPSIS
        Writes declaration and/or implementation code into an existing POU.
    .PARAMETER PouName
        Name of the POU to write to.
    .PARAMETER Declaration
        Structured Text declaration section (VAR blocks).
    .PARAMETER Implementation
        Structured Text implementation section (code body).
    .PARAMETER PouPath
        Full tree path to the POU, e.g. TIPC^<Plc>^<Plc> Project^POUs^<name> (same format on
        4024 and 4026; DUT ...^DUTs^<name>, GVL ...^GVLs^<name>). If omitted (or not found),
        the POU is looked up by PouName: POUs folder -> project root -> tree search (depth 4).
        data.pouPath / data.resolvedBy report which path was used.
        A DUT / GVL / ITF (data.objectKind) has only a declaration: -Implementation on one of
        them returns INVALID_PARAMS and nothing is written.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PouName,

        [Parameter()]
        [string]$Declaration,

        [Parameter()]
        [string]$Implementation,

        [Parameter()]
        [string]$PouPath
    )

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }

    $sm = Get-TcSysManager
    if ($null -eq $sm) {
        return New-TcNoSysManagerResult
    }

    try {
        $r = Resolve-TcPouPath -SysManager $sm -Name $PouName -PouPath $PouPath
        if (-not $r.Found) {
            return New-TcPouNotFoundResult -Name $PouName -Resolution $r
        }
        $pouItem = $r.Item
        $kind = Get-TcPlcObjectKind -Item $pouItem

        # DUT / GVL / ITF have only a declaration part (Get-TcPlcObjectKind): refuse before
        # anything is written, so a declaration is never written half of a request
        if (-not [string]::IsNullOrWhiteSpace($Implementation) -and $kind.HasImplementation -eq $false) {
            $shape = switch ($kind.ObjectKind) { 'DUT' { 'TYPE ... END_TYPE' } 'GVL' { 'VAR_GLOBAL ... END_VAR' } 'ITF' { 'INTERFACE ...' } default { 'complete source' } }
            return New-TcResult -Success $false -ErrorCode 'INVALID_PARAMS' `
                -ErrorMessage "'$PouName' is a $($kind.ObjectKind) ($($r.Path)): it has no implementation part, so -Implementation cannot be written. Nothing was written." `
                -Hint "Call Write-TcPouCode -PouName '$PouName' -PouPath '$($r.Path)' -Declaration <text> without -Implementation (MCP WritePouCode without Implementation); the whole $($kind.ObjectKind) source ($shape) goes into Declaration." `
                -Data ([PSCustomObject]@{
                    pou               = $PouName
                    pouPath           = $r.Path
                    objectKind        = $kind.ObjectKind
                    hasImplementation = $false
                })
        }

        $updated = @()

        if (-not [string]::IsNullOrWhiteSpace($Declaration)) {
            Invoke-TcComRetry -OperationName 'Set DeclarationText' -ScriptBlock { $pouItem.DeclarationText = $Declaration } | Out-Null
            $updated += 'declaration'
        }

        if (-not [string]::IsNullOrWhiteSpace($Implementation)) {
            Invoke-TcComRetry -OperationName 'Set ImplementationText' -ScriptBlock { $pouItem.ImplementationText = $Implementation } | Out-Null
            $updated += 'implementation'
        }

        New-TcResult -Success $true -Data ([PSCustomObject]@{
            pou        = $PouName
            pouPath    = $r.Path
            resolvedBy = $r.ResolvedBy
            objectKind = $kind.ObjectKind
            updated    = $updated
        })
    }
    catch {
        if ($_.Exception.Message -like 'PLC_PROJECT_NOT_FOUND*') {
            return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'PLC_PROJECT_NOT_FOUND' -Hint (Get-TcErrorHint -Code 'PLC_PROJECT_NOT_FOUND')
        }
        New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'POU_WRITE_FAILED' -MessagePrefix 'Failed to write POU code'
    }
}
