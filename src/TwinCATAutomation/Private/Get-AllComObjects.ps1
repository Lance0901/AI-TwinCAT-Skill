function Get-AllComObjects {
    <#
    .SYNOPSIS
        Enumerates ALL DTE instances from the Running Object Table (ROT).
    .DESCRIPTION
        Unlike Get-ComObject (which uses Marshal.GetActiveObject and returns only
        ONE instance per ProgID), this function enumerates the entire ROT to find
        ALL running VS2022 and XAE Shell instances (any DTE version: 15.0, 17.0 ...).
        This is critical when multiple IDE instances are open simultaneously.
    .PARAMETER IncludeDisplayName
        Return one hashtable per instance instead of the bare COM object:
            @{ DisplayName = '!TcXaeShell.DTE.15.0:1234'; Object = <DTE>; ProgId = 'TcXaeShell.DTE.15.0'; ProcessId = 1234 }
        ProgId / ProcessId are parsed from the moniker display name and are $null
        when the name does not follow the "!<ProgId>:<pid>" pattern.
    .OUTPUTS
        Array of COM DTE objects (or hashtables with -IncludeDisplayName). Empty array if none found.
    .EXAMPLE
        $allDtes = Get-AllComObjects
        foreach ($dte in $allDtes) { $dte.Solution.FullName }
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$IncludeDisplayName
    )

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
        $results = @()
        foreach ($entry in $entries) {
            if (-not $IncludeDisplayName) {
                $results += $entry['Object']
                continue
            }
            $displayName = [string]$entry['DisplayName']
            $progId = $null
            $processId = $null
            # Moniker display names look like "!TcXaeShell.DTE.15.0:1234" / "!VisualStudio.DTE.17.0:5678"
            if ($displayName -match '^!?(?<prog>[A-Za-z0-9_]+\.DTE(\.\d+(\.\d+)?)?):(?<pid>\d+)\s*$') {
                $progId = $Matches['prog']
                try { $processId = [int]$Matches['pid'] } catch { $processId = $null }
            }
            elseif ($displayName -match '^!?(?<prog>[A-Za-z0-9_]+\.DTE(\.\d+(\.\d+)?)?)') {
                $progId = $Matches['prog']
            }
            $results += @{
                DisplayName = $displayName
                Object      = $entry['Object']
                ProgId      = $progId
                ProcessId   = $processId
            }
        }
        return $results
    }
    catch {
        Write-Verbose "ROT enumeration failed: $_. Falling back to empty list."
        return @()
    }
}
