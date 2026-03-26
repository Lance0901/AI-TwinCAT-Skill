function Connect-TcIde {
    <#
    .SYNOPSIS
        Connects to a running TwinCAT 3 IDE instance via the Running Object Table.
    .DESCRIPTION
        Obtains the EnvDTE and ITcSysManager interfaces. Tries XAE Shell first,
        then falls back to VS2022. Launches a new instance if none found.
    .PARAMETER ProgId
        COM ProgID to connect to. Default: TcXaeShell.DTE.17.0
    .PARAMETER NoLaunch
        If set, do not launch a new IDE instance if none is running.
    .EXAMPLE
        Connect-TcIde
        Connect-TcIde -ProgId "VisualStudio.DTE.17.0"
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ProgId,

        [Parameter()]
        [switch]$NoLaunch
    )

    $progIds = @('TcXaeShell.DTE.17.0', 'VisualStudio.DTE.17.0')

    if (-not [string]::IsNullOrWhiteSpace($ProgId)) {
        $progIds = @($ProgId)
    }

    $dte = $null
    $usedProgId = $null

    # Try to connect to running instance
    foreach ($pid in $progIds) {
        $dte = Get-ComObject -ProgId $pid
        if ($null -ne $dte) {
            $usedProgId = $pid
            break
        }
    }

    # Launch new instance if not found
    if ($null -eq $dte) {
        if ($NoLaunch) {
            return New-TcResult -Success $false -ErrorMessage 'No running TwinCAT IDE instance found.' -ErrorCode 'IDE_NOT_FOUND'
        }

        $launchProgId = $progIds[0]
        try {
            $type = [Type]::GetTypeFromProgID($launchProgId)
            if ($null -eq $type) {
                return New-TcResult -Success $false `
                    -ErrorMessage "TwinCAT 3 XAE is not installed. ProgID '$launchProgId' not registered. Install TwinCAT 3 XAE from https://www.beckhoff.com/twincat3/" `
                    -ErrorCode 'TWINCAT_NOT_FOUND'
            }

            $dte = [Activator]::CreateInstance($type)
            $dte.SuppressUI = $false
            $dte.MainWindow.Visible = $true
            $usedProgId = $launchProgId

            # Wait for IDE to be ready (max 60 seconds)
            $timeout = [DateTime]::Now.AddSeconds(60)
            while ([DateTime]::Now -lt $timeout) {
                try {
                    $null = $dte.Version
                    break
                }
                catch {
                    Start-Sleep -Milliseconds 500
                }
            }
        }
        catch {
            return New-TcResult -Success $false -ErrorMessage "Failed to launch TwinCAT IDE: $_" -ErrorCode 'IDE_LAUNCH_FAILED'
        }
    }

    # Store in module scope
    $script:TcDte = $dte
    $script:TcProgId = $usedProgId
    $script:TcIdeConnected = $true

    # Try to obtain ITcSysManager
    $script:TcSysManager = $null
    $sysManagerAvailable = $false
    try {
        $solution = $dte.Solution
        if ($null -ne $solution -and $solution.Projects.Count -gt 0) {
            for ($i = 1; $i -le $solution.Projects.Count; $i++) {
                try {
                    $sm = $solution.Projects.Item($i).Object
                    if ($null -ne $sm) {
                        $script:TcSysManager = $sm
                        $sysManagerAvailable = $true
                        break
                    }
                }
                catch { continue }
            }
        }
    }
    catch { }

    $ideVersion = try { $dte.Version } catch { 'unknown' }
    $ideSolution = try { $dte.Solution.FullName } catch { '' }

    $data = [PSCustomObject]@{
        progId              = $usedProgId
        version             = $ideVersion
        solution            = $ideSolution
        sysManagerAvailable = $sysManagerAvailable
    }

    if (-not $sysManagerAvailable) {
        $data | Add-Member -NotePropertyName 'warning' -NotePropertyValue 'No TwinCAT project loaded. Project-level operations unavailable until a project is opened.'
    }

    New-TcResult -Success $true -Data $data
}
