function Write-TcPouCode {
    <#
    .SYNOPSIS
        Writes declaration and/or implementation code into an existing POU.
    .PARAMETER PouName
        Name of the POU to write to. A member can be named Parent.Member: FB_X.M_Run,
        FB_X.P_Value.Get (tried only after the name as given found nothing).
    .PARAMETER Declaration
        Structured Text declaration section (VAR blocks). An empty / blank -Declaration is refused
        (POU_WRITE_FAILED, data.reason empty-not-supported): clearing a declaration is not measured.
    .PARAMETER Implementation
        Structured Text implementation section (code body). -Implementation '' clears the body:
        ImplementationText = '' is written and must read back empty (measured 2026-10-31, 4026
        VS2022, self-built client: COM ImplementationText = '' on a method reads back '').
    .PARAMETER PouPath
        Full tree path to the POU, e.g. TIPC^<Plc>^<Plc> Project^POUs^<name> (same format on
        4024 and 4026; DUT ...^DUTs^<name>, GVL ...^GVLs^<name>; members ...^<FB>^<member>,
        accessors ...^<FB>^<property>^Get). If omitted (or not found), the POU is looked up by
        PouName: POUs folder -> project root -> tree search (depth 4) -> Parent.Member.
        data.pouPath / data.resolvedBy report which path was used; a name several objects carry
        returns POU_AMBIGUOUS (data.candidates) and nothing is written.
        A DUT / GVL / ITF / property (data.objectKind) has only a declaration: -Implementation on
        one of them returns INVALID_PARAMS and nothing is written (for an UNKNOWN ItemType
        ImplementationText is read first; $null counts as "no implementation part"). An action
        has only an implementation: -Declaration on it returns INVALID_PARAMS (DeclarationText
        does not exist on an action, measured 2026-10-31 4026 VS2022, self-built client).
    .NOTES
        BUILD_REQUIRED (#65): once a text was written the solution is recorded as 'code-changed'
        (Register-TcCodeChange): Enable-TcConfig and Enter-TcPlcOnline refuse until a complete
        Build-TcProject. data.buildRequired is the recorded reason, data.stateWarning is set
        when the state file could not be written. Conservative: a write that fails after a
        setter was called is recorded too ([write failed], [declaration+write failed]), the
        edit buffer may have changed. Requests refused before any setter (INVALID_PARAMS, empty
        -Declaration, POU_AMBIGUOUS ...) record nothing.
        The Get / Set accessor of an INTERFACE property (ItemType 654 / 655) is refused with
        POU_MEMBER_UNSUPPORTED before anything else is read (see Get-TcPouCode); an ItemType that
        cannot be read returns POU_WRITE_FAILED (data.reason itemtype-unreadable, fail-closed).
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

    # A parameter given as '' is not the same as one left out (task 3.6: '' used to return
    # success with updated=[] and nothing written).
    $declGiven = $PSBoundParameters.ContainsKey('Declaration')
    $implGiven = $PSBoundParameters.ContainsKey('Implementation')
    if ($declGiven -and [string]::IsNullOrWhiteSpace($Declaration)) {
        return New-TcResult -Success $false -ErrorCode 'POU_WRITE_FAILED' `
            -ErrorMessage "-Declaration is empty: clearing a declaration is not supported (not measured on XAE). Nothing was written." `
            -Hint "Pass the complete declaration (e.g. the header line plus VAR ... END_VAR), or leave -Declaration out to write only -Implementation." `
            -Data ([PSCustomObject]@{ pou = $PouName; pouPath = $PouPath; reason = 'empty-not-supported'; updated = @() })
    }

    # #65: set right before a setter is called (the edit buffer may change even when it throws)
    $writeStarted = $false
    $updated = @()
    $changeName = "Write-TcPouCode $PouName"
    try {
        $r = Resolve-TcPouPath -SysManager $sm -Name $PouName -PouPath $PouPath
        if (-not $r.Found) {
            if ($r.Ambiguous) { return New-TcPouAmbiguousResult -Name $PouName -Resolution $r }
            return New-TcPouNotFoundResult -Name $PouName -Resolution $r
        }
        $pouItem = $r.Item
        # ItemType alone first: nothing else is read from an ITF property accessor (654 / 655)
        $itemTypeNo = Get-TcTreeItemTypeNumber -Item $pouItem
        # fail-closed: an unreadable ItemType may be a 654 / 655, so nothing else is touched
        if ($itemTypeNo -eq -1) {
            return New-TcResult -Success $false -ErrorCode 'POU_WRITE_FAILED' `
                -ErrorMessage "ItemType of '$($r.Path)' cannot be read, so nothing is written (it could be an interface property accessor, see POU_MEMBER_UNSUPPORTED)." `
                -Hint (Get-TcErrorHint -Code 'POU_WRITE_FAILED') `
                -Data ([PSCustomObject]@{ pou = $PouName; pouPath = $r.Path; reason = 'itemtype-unreadable'; updated = @() })
        }
        if ($script:TcItfAccessorItemTypes -contains $itemTypeNo) {
            return New-TcItfAccessorUnsupportedResult -Path $r.Path -ItemType $itemTypeNo -Operation 'written' -Pou $PouName
        }
        $kind = Get-TcPlcObjectKind -Item $pouItem

        # an action has no declaration part (measured 2026-10-31 4026 VS2022, self-built client)
        if ($declGiven -and $kind.ObjectKind -eq 'ACTION') {
            return New-TcResult -Success $false -ErrorCode 'INVALID_PARAMS' `
                -ErrorMessage "'$PouName' is an ACTION ($($r.Path)): it has no declaration part, so -Declaration cannot be written. Nothing was written." `
                -Hint "Call Write-TcPouCode -PouName '$PouName' -PouPath '$($r.Path)' -Implementation <st> without -Declaration; the variables of an action are declared in its POU." `
                -Data ([PSCustomObject]@{ pou = $PouName; pouPath = $r.Path; objectKind = $kind.ObjectKind; itemType = $kind.ItemType })
        }

        # DUT / GVL / ITF / property have only a declaration part (Get-TcPlcObjectKind): refuse
        # before anything is written, so a request is never written half. An UNKNOWN ItemType is
        # probed first: ImplementationText reads $null on an item without implementation part
        # (measured 2026-10-25 on 4024 and 4026).
        $hasImpl = $kind.HasImplementation
        if ($implGiven -and $null -eq $hasImpl) {
            $probe = Invoke-TcComRetry -OperationName 'Get ImplementationText' -ScriptBlock { $pouItem.ImplementationText }
            $hasImpl = ($null -ne $probe)
        }
        if ($implGiven -and $hasImpl -eq $false) {
            $what = if ($kind.ObjectKind -eq 'UNKNOWN') { "an object of ItemType $($kind.ItemType)" } else { "a $($kind.ObjectKind)" }
            $hint = switch ($kind.ObjectKind) {
                'PROPERTY' { "A property has no code of its own: write the accessor, Write-TcPouCode -PouName Get -PouPath '$($r.Path)^Get' -Implementation <st> (or ^Set). Create a missing accessor with Add-TcPouMember -ParentPath '$($r.Path)' -Kind Get (CreateChild 611 creates none, measured 2026-10-25)." }
                'ITF_PROPERTY' { "An interface property has no code: implement it in the function block that implements the interface (Write-TcPouCode -PouPath '<FB path>^<property>^Get')." }
                default {
                    $shape = switch ($kind.ObjectKind) { 'DUT' { 'TYPE ... END_TYPE' } 'GVL' { 'VAR_GLOBAL ... END_VAR' } 'ITF' { 'INTERFACE ...' } 'ITF_METHOD' { 'METHOD ... VAR_INPUT ... END_VAR' } default { 'complete source' } }
                    "Call Write-TcPouCode -PouName '$PouName' -PouPath '$($r.Path)' -Declaration <text> without -Implementation; the whole source ($shape) goes into Declaration."
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

        if ($declGiven) {
            $writeStarted = $true
            Invoke-TcComRetry -OperationName 'Set DeclarationText' -ScriptBlock { $pouItem.DeclarationText = $Declaration } | Out-Null
            $updated += 'declaration'
        }

        $cleared = $false
        if ($implGiven) {
            $writeStarted = $true
            $implText = $Implementation
            if ([string]::IsNullOrWhiteSpace($implText)) { $implText = ''; $cleared = $true }
            Invoke-TcComRetry -OperationName 'Set ImplementationText' -ScriptBlock { $pouItem.ImplementationText = $implText } | Out-Null
            $updated += 'implementation'
            if ($cleared) {
                # read back: '' must read back empty (measured 2026-10-31, 4026 VS2022)
                $back = Invoke-TcComRetry -OperationName 'Get ImplementationText' -ScriptBlock { $pouItem.ImplementationText }
                if ($null -eq $back -or -not [string]::IsNullOrWhiteSpace([string]$back)) {
                    $res = New-TcResult -Success $false -ErrorCode 'POU_WRITE_FAILED' `
                        -ErrorMessage "ImplementationText = '' was written to '$($r.Path)' but it does not read back empty$(if ($null -eq $back) { ' (null)' }). The body may be unchanged." `
                        -Hint "Read it with Get-TcPouCode -PouPath '$($r.Path)'; to empty it, write a body that is only a comment (e.g. -Implementation '// empty')." `
                        -Data ([PSCustomObject]@{ pou = $PouName; pouPath = $r.Path; objectKind = $kind.ObjectKind; reason = 'empty-not-applied'; updated = $updated })
                    return Register-TcCodeChange -Result $res -Change "$changeName [$(@($updated) -join '+') not verified]"
                }
            }
        }

        $ok = New-TcResult -Success $true -Data ([PSCustomObject]@{
            pou        = $PouName
            pouPath    = $r.Path
            resolvedBy = $r.ResolvedBy
            objectKind = $kind.ObjectKind
            updated    = $updated
            cleared    = $cleared
        })
        if ($updated.Count -eq 0) { return $ok }   # neither text given: nothing written
        Register-TcCodeChange -Result $ok -Change "$changeName [$($updated -join '+')]"
    }
    catch {
        if ($writeStarted) {
            # conservative (#65): a setter that threw may still have changed the edit buffer
            $res = New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'POU_WRITE_FAILED' -MessagePrefix 'Failed to write POU code'
            # the parts that were written, then 'write failed' ([declaration+write failed])
            return Register-TcCodeChange -Result $res -Change "$changeName [$(@($updated + 'write failed') -join '+')]"
        }
        if ($_.Exception.Message -like 'PLC_PROJECT_NOT_FOUND*') {
            return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'PLC_PROJECT_NOT_FOUND' -Hint (Get-TcErrorHint -Code 'PLC_PROJECT_NOT_FOUND')
        }
        New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'POU_WRITE_FAILED' -MessagePrefix 'Failed to write POU code'
    }
}
