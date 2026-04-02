function Connect-TcIde {
    <#
    .SYNOPSIS
        Connects to a running TwinCAT 3 IDE instance via the Running Object Table.
    .DESCRIPTION
        Obtains the EnvDTE and ITcSysManager interfaces. Tries XAE Shell first,
        then falls back to VS2022. Launches a new instance if none found.
        When -SolutionPath is specified, automatically opens the project and
        obtains ITcSysManager in one step.
    .PARAMETER ProgId
        COM ProgID to connect to. Default: TcXaeShell.DTE.17.0
    .PARAMETER SolutionPath
        Path to a .sln file. If specified, the IDE will open this solution
        automatically after connecting (or connect to an instance already
        running this solution).
    .PARAMETER NoLaunch
        If set, do not launch a new IDE instance if none is running.
    .EXAMPLE
        Connect-TcIde
        Connect-TcIde -ProgId "VisualStudio.DTE.17.0"
        Connect-TcIde -SolutionPath "C:\Projects\MyProject.sln"
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ProgId,

        [Parameter()]
        [string]$SolutionPath,

        [Parameter()]
        [switch]$NoLaunch
    )

    # Validate SolutionPath if provided
    if (-not [string]::IsNullOrWhiteSpace($SolutionPath)) {
        if (-not (Test-Path $SolutionPath)) {
            return New-TcResult -Success $false -ErrorMessage "Solution file not found: $SolutionPath" -ErrorCode 'FILE_NOT_FOUND'
        }
        $SolutionPath = (Resolve-Path $SolutionPath).Path
    }

    $progIds = @('TcXaeShell.DTE.17.0', 'VisualStudio.DTE.17.0')
    if (-not [string]::IsNullOrWhiteSpace($ProgId)) {
        $progIds = @($ProgId)
    }

    $dte = $null
    $usedProgId = $null

    # --- Enumerate ALL running IDE instances via ROT ---
    # (Marshal.GetActiveObject only returns ONE per ProgID; ROT enumeration finds ALL)
    $allDtes = Get-AllComObjects
    Write-Verbose "ROT enumeration found $($allDtes.Count) DTE instance(s)"

    # --- Strategy 1: If SolutionPath specified, find IDE already running it ---
    if (-not [string]::IsNullOrWhiteSpace($SolutionPath)) {
        foreach ($candidate in $allDtes) {
            try {
                $openSln = $candidate.Solution.FullName
                if ($openSln -eq $SolutionPath) {
                    $dte = $candidate
                    $usedProgId = try { $candidate.RegistryRoot } catch { 'DTE' }
                    Write-Verbose "Found IDE already running target solution"
                    break
                }
            }
            catch { }
        }
    }

    # --- Strategy 2: Find any running IDE (prefer one with TwinCAT project) ---
    if ($null -eq $dte) {
        $dteWithProject = $null
        $dteWithoutProject = $null

        foreach ($candidate in $allDtes) {
            # Check if this instance has a TwinCAT project loaded
            $hasTcProject = $false
            try {
                $sol = $candidate.Solution
                if ($null -ne $sol -and $sol.Projects.Count -gt 0) {
                    for ($i = 1; $i -le $sol.Projects.Count; $i++) {
                        try {
                            $sm = $sol.Projects.Item($i).Object
                            if ($null -ne $sm) {
                                $hasTcProject = $true
                                break
                            }
                        }
                        catch { continue }
                    }
                }
            }
            catch { }

            if ($hasTcProject -and $null -eq $dteWithProject) {
                $dteWithProject = $candidate
            }
            elseif (-not $hasTcProject -and $null -eq $dteWithoutProject) {
                $dteWithoutProject = $candidate
            }
        }

        # Prefer IDE with TwinCAT project
        if ($null -ne $dteWithProject) {
            $dte = $dteWithProject
            $usedProgId = try { $dte.RegistryRoot } catch { 'DTE' }
            Write-Verbose "Connected to IDE with TwinCAT project"
        }
        elseif ($null -ne $dteWithoutProject) {
            $dte = $dteWithoutProject
            $usedProgId = try { $dte.RegistryRoot } catch { 'DTE' }
            Write-Verbose "Connected to IDE (no TwinCAT project)"
        }
    }

    # --- Fallback: try GetActiveObject for specific ProgIDs (if ROT enumeration returned nothing) ---
    if ($null -eq $dte -and $allDtes.Count -eq 0) {
        foreach ($pid in $progIds) {
            $candidate = Get-ComObject -ProgId $pid
            if ($null -ne $candidate) {
                $dte = $candidate
                $usedProgId = $pid
                Write-Verbose "Fallback: found IDE via GetActiveObject ($pid)"
                break
            }
        }
    }

    # --- Strategy 3: Launch new instance if not found ---
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

    # --- Auto-open solution if -SolutionPath specified and not already open ---
    if (-not [string]::IsNullOrWhiteSpace($SolutionPath)) {
        $currentSln = try { $dte.Solution.FullName } catch { '' }
        if ($currentSln -ne $SolutionPath) {
            try {
                Write-Verbose "Opening solution: $SolutionPath"
                $dte.Solution.Open($SolutionPath)
                Start-Sleep -Seconds 2  # Allow solution to fully load
            }
            catch {
                return New-TcResult -Success $false -ErrorMessage "Failed to open solution: $_" -ErrorCode 'PROJECT_OPEN_FAILED'
            }
        }
    }

    # Try to obtain ITcSysManager (force refresh after potential solution open)
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

    # Add target info if ITcSysManager is available
    if ($sysManagerAvailable) {
        try {
            $amsNetId = $script:TcSysManager.GetTargetNetId()
            $data | Add-Member -NotePropertyName 'amsNetId' -NotePropertyValue $amsNetId
        }
        catch { }
    }
    else {
        $nextAction = if (-not [string]::IsNullOrWhiteSpace($SolutionPath)) {
            "Solution opened but no TwinCAT project found in '$SolutionPath'. Verify the .sln contains a TwinCAT project."
        }
        else {
            'No TwinCAT project loaded. Use Connect-TcIde -SolutionPath "path\to\project.sln" to open a project, or call Open-TcProject.'
        }
        $data | Add-Member -NotePropertyName 'warning' -NotePropertyValue $nextAction
    }

    New-TcResult -Success $true -Data $data
}
