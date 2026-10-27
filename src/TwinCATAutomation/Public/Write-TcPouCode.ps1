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
        A DUT / GVL / ITF / property (data.objectKind) has only a declaration: -Implementation on
        one of them returns INVALID_PARAMS and nothing is written (for an UNKNOWN ItemType
        ImplementationText is read first; $null counts as "no implementation part").
    .NOTES
        BUILD_REQUIRED (#65): once a text was written (also when a write then failed half way)
        the solution is recorded as 'code-changed' (Register-TcCodeChange): Enable-TcConfig and
        Enter-TcPlcOnline refuse until a complete Build-TcProject. data.buildRequired is the
        recorded reason, data.stateWarning is set when the state file could not be written.
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

        # DUT / GVL / ITF / property have only a declaration part (Get-TcPlcObjectKind): refuse
        # before anything is written, so a request is never written half. An UNKNOWN ItemType is
        # probed first: ImplementationText reads $null on an item without implementation part
        # (measured 2026-10-25 on 4024 and 4026).
        $hasImpl = $kind.HasImplementation
        if (-not [string]::IsNullOrWhiteSpace($Implementation) -and $null -eq $hasImpl) {
            $probe = Invoke-TcComRetry -OperationName 'Get ImplementationText' -ScriptBlock { $pouItem.ImplementationText }
            $hasImpl = ($null -ne $probe)
        }
        if (-not [string]::IsNullOrWhiteSpace($Implementation) -and $hasImpl -eq $false) {
            $what = if ($kind.ObjectKind -eq 'UNKNOWN') { "an object of ItemType $($kind.ItemType)" } else { "a $($kind.ObjectKind)" }
            $hint = switch ($kind.ObjectKind) {
                'PROPERTY' { "A property has no code of its own: write the accessor, Write-TcPouCode -PouName Get -PouPath '$($r.Path)^Get' -Implementation <st> (or ^Set). The Get / Set items exist only after they were added in XAE (CreateChild 611 creates none, measured 2026-10-25); check with Get-TcProjectTree -PlcOnly." }
                'ITF_PROPERTY' { "An interface property has no code: implement it in the function block that implements the interface (Write-TcPouCode -PouPath '<FB path>^<property>^Get')." }
                default {
                    $shape = switch ($kind.ObjectKind) { 'DUT' { 'TYPE ... END_TYPE' } 'GVL' { 'VAR_GLOBAL ... END_VAR' } 'ITF' { 'INTERFACE ...' } 'ITF_METHOD' { 'METHOD ... VAR_INPUT ... END_VAR' } default { 'complete source' } }
                    "Call Write-TcPouCode -PouName '$PouName' -PouPath '$($r.Path)' -Declaration <text> without -Implementation (MCP WritePouCode without Implementation); the whole source ($shape) goes into Declaration."
                }
            }
            return New-TcResult -Success $false -ErrorCode 'INVALID_PARAMS' `
                -ErrorMessage "'$PouName' is $what ($($r.Path)): it has no implementation part, so -Implementation cannot be written. Nothing was written." `
                -Hint $hint `
                -Data ([PSCustomObject]@{
                    pou               = $PouName
                    pouPath           = $r.Path
                    objectKind        = $kind.ObjectKind
                    itemType          = $kind.ItemType
                    hasImplementation = $false
                })
        }

        $updated = @()
        # #65: from here on the edit buffer may change (also when a setter fails half way)
        $changeName = "Write-TcPouCode $PouName"
        $writeStarted = $false

        if (-not [string]::IsNullOrWhiteSpace($Declaration)) {
            $writeStarted = $true
            Invoke-TcComRetry -OperationName 'Set DeclarationText' -ScriptBlock { $pouItem.DeclarationText = $Declaration } | Out-Null
            $updated += 'declaration'
        }

        if (-not [string]::IsNullOrWhiteSpace($Implementation)) {
            $writeStarted = $true
            Invoke-TcComRetry -OperationName 'Set ImplementationText' -ScriptBlock { $pouItem.ImplementationText = $Implementation } | Out-Null
            $updated += 'implementation'
        }

        $ok = New-TcResult -Success $true -Data ([PSCustomObject]@{
            pou        = $PouName
            pouPath    = $r.Path
            resolvedBy = $r.ResolvedBy
            objectKind = $kind.ObjectKind
            updated    = $updated
        })
        if ($updated.Count -eq 0) { return $ok }   # neither text given: nothing written
        Register-TcCodeChange -Result $ok -Change "$changeName [$($updated -join '+')]"
    }
    catch {
        if ($writeStarted) {
            # conservative (#65): a setter that threw may still have changed the edit buffer
            $res = New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'POU_WRITE_FAILED' -MessagePrefix 'Failed to write POU code'
            return Register-TcCodeChange -Result $res -Change "$changeName [write failed]"
        }
        if ($_.Exception.Message -like 'PLC_PROJECT_NOT_FOUND*') {
            return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'PLC_PROJECT_NOT_FOUND' -Hint (Get-TcErrorHint -Code 'PLC_PROJECT_NOT_FOUND')
        }
        New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'POU_WRITE_FAILED' -MessagePrefix 'Failed to write POU code'
    }
}
