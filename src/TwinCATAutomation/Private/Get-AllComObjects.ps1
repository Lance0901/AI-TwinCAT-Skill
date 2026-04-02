function Get-AllComObjects {
    <#
    .SYNOPSIS
        Enumerates ALL DTE instances from the Running Object Table (ROT).
    .DESCRIPTION
        Unlike Get-ComObject (which uses Marshal.GetActiveObject and returns only
        ONE instance per ProgID), this function enumerates the entire ROT to find
        ALL running VS2022 and XAE Shell instances. This is critical when multiple
        IDE instances are open simultaneously.
    .OUTPUTS
        Array of COM DTE objects. Empty array if none found.
    .EXAMPLE
        $allDtes = Get-AllComObjects
        foreach ($dte in $allDtes) { $dte.Solution.FullName }
    #>
    [CmdletBinding()]
    param()

    # Load ComRotHelper.cs if not already loaded
    if (-not ([System.Management.Automation.PSTypeName]'ComRotHelper').Type) {
        $helperPath = Join-Path $PSScriptRoot 'ComRotHelper.cs'
        if (-not (Test-Path $helperPath)) {
            Write-Warning "ComRotHelper.cs not found at $helperPath"
            return @()
        }
        $csCode = Get-Content $helperPath -Raw
        Add-Type -TypeDefinition $csCode -Language CSharp -ErrorAction Stop
    }

    try {
        $entries = [ComRotHelper]::GetAllDteInstances()
        $dteObjects = @()
        foreach ($entry in $entries) {
            $dteObjects += $entry['Object']
        }
        return $dteObjects
    }
    catch {
        Write-Verbose "ROT enumeration failed: $_. Falling back to empty list."
        return @()
    }
}
