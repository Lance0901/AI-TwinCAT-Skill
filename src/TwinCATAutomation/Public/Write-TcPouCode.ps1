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
        Full tree path to the POU. Auto-detected from PouName if omitted.
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
        return New-TcResult -Success $false -ErrorMessage 'No TwinCAT project loaded.' -ErrorCode 'NO_PROJECT'
    }

    try {
        # Find the POU (all COM calls wrapped in Invoke-TcComRetry)
        $pouItem = Invoke-TcComRetry -OperationName "Lookup POU $PouName" -ScriptBlock {
            $item = $null
            if (-not [string]::IsNullOrWhiteSpace($PouPath)) {
                $item = $sm.LookupTreeItem($PouPath)
            }
            else {
                # Search under TIPC
                $plcConfig = $sm.LookupTreeItem('TIPC')
                $plcProject = $plcConfig.Child(1)
                $pouFolder = $plcProject.LookupChild('POUs')
                if ($null -ne $pouFolder) {
                    $item = $pouFolder.LookupChild($PouName)
                }
                if ($null -eq $item) {
                    $item = $plcProject.LookupChild($PouName)
                }
            }
            Write-Output -NoEnumerate $item
        }

        if ($null -eq $pouItem) {
            return New-TcResult -Success $false -ErrorMessage "POU '$PouName' not found." -ErrorCode 'POU_NOT_FOUND'
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
            pou     = $PouName
            updated = $updated
        })
    }
    catch {
        New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'POU_WRITE_FAILED' -MessagePrefix 'Failed to write POU code'
    }
}
