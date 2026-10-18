function Get-TcIdeExeName {
    <#
    .SYNOPSIS
        Maps a DTE ProgID to the IDE executable name (without .exe).
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ProgId
    )
    if ($ProgId -like 'VisualStudio.*') { return 'devenv' }
    return 'TcXaeShell'
}

function Get-TcIdeProcessId {
    <#
    .SYNOPSIS
        Determines the process id (and main window handle) of a DTE instance.
    .DESCRIPTION
        Tries, in order:
          1. DTE.MainWindow.HWnd -> GetWindowThreadProcessId (user32)
          2. -KnownPid (pid parsed from the ROT moniker "!<ProgId>:<pid>")
          3. the youngest <exe> process started after -StartedAfter (freshly launched IDE)
        Every COM read is guarded; the function never throws.
    .OUTPUTS
        Hashtable @{ ProcessId = [int]; MainHwnd = [long] } (0 when unknown).
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [object]$Dte,

        [Parameter()]
        [string]$ProgId,

        [Parameter()]
        [int]$KnownPid = 0,

        [Parameter()]
        [object]$StartedAfter
    )

    $hwnd = [long]0
    $procId = 0

    if ($null -ne $Dte) {
        try {
            $hwnd = [long](Invoke-TcComRetry -MaxRetries 2 -OperationName 'MainWindow.HWnd' -ScriptBlock { [long]$Dte.MainWindow.HWnd })
        }
        catch {
            Write-Verbose "Get-TcIdeProcessId: MainWindow.HWnd unreadable ($($_.Exception.Message))"
            $hwnd = 0
        }
    }

    if ($hwnd -gt 0) {
        try {
            if (-not ([System.Management.Automation.PSTypeName]'TcAutomation.Native').Type) {
                Add-Type -Namespace TcAutomation -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
'@ -ErrorAction Stop
            }
            $outPid = [uint32]0
            $null = [TcAutomation.Native]::GetWindowThreadProcessId([IntPtr]$hwnd, [ref]$outPid)
            if ($outPid -gt 0) { $procId = [int]$outPid }
        }
        catch {
            Write-Verbose "Get-TcIdeProcessId: GetWindowThreadProcessId failed ($($_.Exception.Message))"
        }
    }

    if ($procId -le 0 -and $KnownPid -gt 0) { $procId = $KnownPid }

    if ($procId -le 0 -and $null -ne $StartedAfter) {
        $since = $null
        try { $since = [DateTime]$StartedAfter } catch { $since = $null }
        if ($null -ne $since) {
            $exe = Get-TcIdeExeName -ProgId $ProgId
            $young = @(Get-Process -Name $exe -ErrorAction SilentlyContinue | Where-Object {
                $st = $null
                try { $st = $_.StartTime } catch { $st = $null }
                ($null -ne $st) -and ($st -ge $since.AddSeconds(-2))
            } | Sort-Object StartTime -Descending)
            if ($young.Count -gt 0) { $procId = [int]$young[0].Id }
        }
    }

    # DTE.MainWindow.HWnd is often 0 on a freshly launched IDE; the process itself knows its main window.
    if ($hwnd -eq 0 -and $procId -gt 0) {
        try {
            $p = Get-Process -Id $procId -ErrorAction Stop
            $hwnd = [long]$p.MainWindowHandle
        }
        catch { $hwnd = 0 }
    }

    return @{
        ProcessId = $procId
        MainHwnd  = $hwnd
    }
}

function Stop-TcLaunchedIde {
    <#
    .SYNOPSIS
        Cleans up an IDE that Connect-TcIde launched but that never became ready.
    .DESCRIPTION
        Calls DTE.Quit() (guarded), waits up to 5 s, then force-stops every <exe>
        process (TcXaeShell.exe / devenv.exe, per ProgID) whose StartTime is later
        than -StartedAfter, so no orphan IDE is left behind. Processes started
        earlier (the user's own IDEs) are never touched. Never throws.
    .OUTPUTS
        Array of process ids that were stopped.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [object]$Dte,

        [Parameter(Mandatory)]
        [string]$ProgId,

        [Parameter(Mandatory)]
        [DateTime]$StartedAfter
    )

    if ($null -ne $Dte) {
        try { $Dte.Quit() } catch { Write-Verbose "Stop-TcLaunchedIde: Quit() failed ($($_.Exception.Message))" }
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($Dte) | Out-Null } catch { }
    }

    $exe = Get-TcIdeExeName -ProgId $ProgId
    $since = $StartedAfter.AddSeconds(-2)
    $stopped = @()
    $deadline = [DateTime]::Now.AddSeconds(5)
    while ($true) {
        $young = @(Get-Process -Name $exe -ErrorAction SilentlyContinue | Where-Object {
            $st = $null
            try { $st = $_.StartTime } catch { $st = $null }
            ($null -ne $st) -and ($st -ge $since)
        })
        if ($young.Count -eq 0) { break }
        if ([DateTime]::Now -ge $deadline) {
            foreach ($p in $young) {
                try {
                    Stop-Process -Id $p.Id -Force -ErrorAction Stop
                    $stopped += [int]$p.Id
                    Write-Verbose "Stop-TcLaunchedIde: killed orphan $exe pid $($p.Id)"
                }
                catch { Write-Verbose "Stop-TcLaunchedIde: Stop-Process $($p.Id) failed ($($_.Exception.Message))" }
            }
            break
        }
        Start-Sleep -Milliseconds 500
    }
    return ,$stopped
}
