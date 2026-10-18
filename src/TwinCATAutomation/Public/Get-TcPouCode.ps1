function Get-TcPouCode {
    <#
    .SYNOPSIS
        Reads declaration and implementation code from an existing POU.
    .PARAMETER PouName
        Name of the POU to read.
    .PARAMETER PouPath
        Full tree path to the POU. Auto-detected from PouName if omitted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PouName,

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

        $declText = try { Invoke-TcComRetry -OperationName 'Get DeclarationText' -ScriptBlock { $pouItem.DeclarationText } } catch { '' }
        $implText = try { Invoke-TcComRetry -OperationName 'Get ImplementationText' -ScriptBlock { $pouItem.ImplementationText } } catch { '' }
        New-TcResult -Success $true -Data ([PSCustomObject]@{
            pou            = $PouName
            declaration    = $declText
            implementation = $implText
        })
    }
    catch {
        New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'POU_READ_FAILED' -MessagePrefix 'Failed to read POU code'
    }
}
