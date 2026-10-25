# "Build required after a platform switch" (BUILD_REQUIRED, #45 / PR #44 review).
# Set-TcSolutionPlatform records an entry whenever the active solution platform changed;
# Build-TcProject removes it after a complete success (no skipped PLC project); Enable-TcConfig
# refuses to activate while an entry applies. The state is a FILE, not module state, so it
# survives Import-Module -Force, one-process-per-call CLI use and a restarted MCP bridge:
#   <dir>\build-required.json   { "<normalized .sln path>": { solution; reason; at } , ... }
#   <dir> = $env:TCAUTO_STATE_DIR (tests) or %TEMP%\TwinCATAutomation
# One entry per solution. A switch while no solution path is known is stored under the key
# '<unknown>', which applies to every solution (conservative), and Enable-TcConfig without a
# known solution path is blocked by any entry. An unreadable state file blocks too.
#
# Windows PowerShell 5.1, ASCII only.

$script:TcUnknownSolutionKey = '<unknown>'

function Get-TcBuildRequiredFile {
    $dir = $env:TCAUTO_STATE_DIR
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = Join-Path ([IO.Path]::GetTempPath()) 'TwinCATAutomation' }
    Join-Path $dir 'build-required.json'
}

function ConvertTo-TcSolutionKey {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $script:TcUnknownSolutionKey }
    $p = $Path.Trim()
    try { $p = [IO.Path]::GetFullPath($p) } catch { }
    return $p.TrimEnd('\', '/').ToLowerInvariant()
}

# Returns @{ Ok = $true; Entries = hashtable } or @{ Ok = $false; Error = message }.
function Read-TcBuildRequiredState {
    $file = Get-TcBuildRequiredFile
    $entries = @{}
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return @{ Ok = $true; Entries = $entries } }
    try {
        $text = [IO.File]::ReadAllText($file)
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            $obj = ConvertFrom-Json -InputObject $text -ErrorAction Stop
            foreach ($p in $obj.PSObject.Properties) { $entries[$p.Name] = $p.Value }
        }
        return @{ Ok = $true; Entries = $entries }
    }
    catch {
        return @{ Ok = $false; Error = "state file $file is not readable: $($_.Exception.Message)" }
    }
}

function Write-TcBuildRequiredState {
    param([hashtable]$Entries)
    $file = Get-TcBuildRequiredFile
    $dir = Split-Path -Parent $file
    if ($Entries.Count -eq 0) {
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force -ErrorAction Stop }
        return
    }
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    $o = [ordered]@{}
    foreach ($k in ($Entries.Keys | Sort-Object)) { $o[$k] = $Entries[$k] }
    $tmp = "$file.$PID.tmp"
    [IO.File]::WriteAllText($tmp, ([PSCustomObject]$o | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $file -Force
}

function Set-TcBuildRequired {
    <#
    .SYNOPSIS
        Records that the solution platform of the current solution ($script:TcSolutionPath)
        changed and a successful Build-TcProject is needed before Enable-TcConfig activates.
        Never throws (a failure is written as a warning).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Reason)
    try {
        $st = Read-TcBuildRequiredState
        $entries = if ($st.Ok) { $st.Entries } else { @{} }
        $entries[(ConvertTo-TcSolutionKey $script:TcSolutionPath)] = [PSCustomObject]@{
            solution = [string]$script:TcSolutionPath
            reason   = $Reason
            at       = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        }
        Write-TcBuildRequiredState -Entries $entries
    }
    catch {
        Write-Warning "Set-TcBuildRequired: could not write $(Get-TcBuildRequiredFile): $($_.Exception.Message)"
    }
}

function Clear-TcBuildRequired {
    <#
    .SYNOPSIS
        Removes the entry of the current solution and the '<unknown>' entry (a complete
        Build-TcProject success covers whatever solution is open). Never throws.
    #>
    [CmdletBinding()]
    param()
    try {
        $st = Read-TcBuildRequiredState
        $entries = if ($st.Ok) { $st.Entries } else { @{} }
        $null = $entries.Remove((ConvertTo-TcSolutionKey $script:TcSolutionPath))
        $null = $entries.Remove($script:TcUnknownSolutionKey)
        Write-TcBuildRequiredState -Entries $entries
    }
    catch {
        Write-Warning "Clear-TcBuildRequired: could not update $(Get-TcBuildRequiredFile): $($_.Exception.Message)"
    }
}

function Get-TcBuildRequired {
    <#
    .SYNOPSIS
        The entry that blocks activation of the current solution, or $null:
        its own entry, the '<unknown>' entry, any entry when no solution path is known,
        or a synthetic entry when the state file cannot be read.
    #>
    [CmdletBinding()]
    param()
    $st = Read-TcBuildRequiredState
    if (-not $st.Ok) {
        return [PSCustomObject]@{ solution = [string]$script:TcSolutionPath; reason = $st.Error; at = $null }
    }
    $entries = $st.Entries
    if ($entries.Count -eq 0) { return $null }
    $key = ConvertTo-TcSolutionKey $script:TcSolutionPath
    if ($entries.ContainsKey($key)) { return $entries[$key] }
    if ($entries.ContainsKey($script:TcUnknownSolutionKey)) { return $entries[$script:TcUnknownSolutionKey] }
    if ($key -eq $script:TcUnknownSolutionKey) { return @($entries.Values)[0] }
    return $null
}
