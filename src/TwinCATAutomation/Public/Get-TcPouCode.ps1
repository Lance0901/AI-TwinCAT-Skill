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
        $pouItem = $null
        if (-not [string]::IsNullOrWhiteSpace($PouPath)) {
            $pouItem = $sm.LookupTreeItem($PouPath)
        }
        else {
            $plcConfig = $sm.LookupTreeItem('TIPC')
            $plcProject = $plcConfig.Child(1)
            $pouFolder = $plcProject.LookupChild('POUs')
            if ($null -ne $pouFolder) {
                $pouItem = $pouFolder.LookupChild($PouName)
            }
            if ($null -eq $pouItem) {
                $pouItem = $plcProject.LookupChild($PouName)
            }
        }

        if ($null -eq $pouItem) {
            return New-TcResult -Success $false -ErrorMessage "POU '$PouName' not found." -ErrorCode 'POU_NOT_FOUND'
        }

        $declText = try { $pouItem.DeclarationText } catch { '' }
        $implText = try { $pouItem.ImplementationText } catch { '' }
        New-TcResult -Success $true -Data ([PSCustomObject]@{
            pou            = $PouName
            declaration    = $declText
            implementation = $implText
        })
    }
    catch {
        New-TcResult -Success $false -ErrorMessage "Failed to read POU code: $_" -ErrorCode 'POU_READ_FAILED'
    }
}
