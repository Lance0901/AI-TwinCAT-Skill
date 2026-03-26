function Add-TcDut {
    <#
    .SYNOPSIS
        Adds a Data Unit Type (STRUCT, ENUM, ALIAS, UNION) to the PLC project.
    .PARAMETER Name
        DUT name (e.g., ST_MotorData, E_State).
    .PARAMETER DutType
        DUT type: Struct, Enum, Alias, Union.
    .PARAMETER Fields
        Optional hashtable of field declarations (name = type) for Struct/Union.
    .PARAMETER AliasType
        Base type for Alias DUT.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateSet('Struct', 'Enum', 'Alias', 'Union')]
        [string]$DutType,

        [Parameter()]
        [hashtable]$Fields,

        [Parameter()]
        [string]$AliasType
    )

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }

    $sm = Get-TcSysManager
    if ($null -eq $sm) {
        return New-TcResult -Success $false -ErrorMessage 'No TwinCAT project loaded.' -ErrorCode 'NO_PROJECT'
    }

    $dutSubTypes = @{
        'Struct' = 610
        'Enum'   = 611
        'Alias'  = 612
        'Union'  = 613
    }

    try {
        $plcConfig = $sm.LookupTreeItem('TIPC')
        $plcProject = $plcConfig.Child(1)

        # Build declaration
        switch ($DutType) {
            'Struct' {
                $decl = "TYPE $Name :`nSTRUCT`n"
                if ($Fields) {
                    foreach ($f in $Fields.GetEnumerator()) {
                        $decl += "    $($f.Key) : $($f.Value);`n"
                    }
                }
                $decl += "END_STRUCT`nEND_TYPE"
            }
            'Enum' {
                $decl = "TYPE $Name :`n(`n"
                if ($Fields) {
                    $entries = $Fields.GetEnumerator() | ForEach-Object { "    $($_.Key) := $($_.Value)" }
                    $decl += ($entries -join ",`n") + "`n"
                }
                $decl += ");`nEND_TYPE"
            }
            'Alias' {
                $baseType = if ($AliasType) { $AliasType } else { 'INT' }
                $decl = "TYPE $Name : $baseType;`nEND_TYPE"
            }
            'Union' {
                $decl = "TYPE $Name :`nUNION`n"
                if ($Fields) {
                    foreach ($f in $Fields.GetEnumerator()) {
                        $decl += "    $($f.Key) : $($f.Value);`n"
                    }
                }
                $decl += "END_UNION`nEND_TYPE"
            }
        }

        $declXml = "<Declaration><![CDATA[$decl]]></Declaration>"
        $subType = $dutSubTypes[$DutType]
        $newItem = $plcProject.CreateChild($Name, $subType, '', $declXml)

        New-TcResult -Success $true -Data ([PSCustomObject]@{
            name    = $Name
            dutType = $DutType
            path    = try { $newItem.PathName } catch { '' }
        })
    }
    catch {
        New-TcResult -Success $false -ErrorMessage "Failed to add DUT: $_" -ErrorCode 'DUT_CREATE_FAILED'
    }
}
