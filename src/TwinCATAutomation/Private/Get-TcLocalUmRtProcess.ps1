function Get-TcLocalUmRtProcess {
    <#
    .SYNOPSIS
        TcSystemServiceUm.exe processes of the Usermode Runtime (UmRT) that IS the target, or $null.
    .DESCRIPTION
        Used by Wait-TcAdsState -DetectRuntimeCrash (RUNTIME_CRASHED, task 1.8).
        "Local" and "is a UmRT" are decided in two steps:
          1. Resolve-TcTargetBootDir (Get-TcBootPackageDiff.ps1): the target AmsNetId equals the
             AmsNetId in %ProgramData%\Beckhoff\TwinCAT\3.1\Runtimes\<name>\3.1\TcRegistry.xml of a
             runtime folder on THIS PC -> Kind 'umrt:<name>'. Anything else (remote CX / PC, the
             local Windows XAR 'local-xar', an unknown NetId) is not a local UmRT -> $null.
             The TcRegistry.xml layout is not documented in InfoSys (measured 2026-10-21, UmRT_Default).
          2. Win32_Process: TcSystemServiceUm.exe processes whose command line contains <name>
             (the runtime is started with -n "<name>", measured 2026-10-21, see
             docs/troubleshooting.md "SYSTEM_STATE_TIMEOUT"; same match as
             Invoke-TcActivateWithDeadline runtimeAlive). When no command line matches but some
             TcSystemServiceUm.exe command lines are unreadable (process of another user /
             elevated), those processes are used instead (PidSource 'unreadable-commandline').
        Never throws: an unreadable registry file or process list gives $null / no pids, so the
        caller keeps its old behaviour.
    .PARAMETER AmsNetId
        Target AMS Net ID.
    .OUTPUTS
        $null (not a local UmRT) or [PSCustomObject]@{ RuntimeName; Pids = [int[]]; PidSource }
        (Pids empty when the UmRT is not running).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AmsNetId)

    $boot = $null
    try { $boot = Resolve-TcTargetBootDir -AmsNetId $AmsNetId } catch { return $null }
    if ($null -eq $boot -or [string]$boot.Kind -notlike 'umrt:*') { return $null }
    $name = ([string]$boot.Kind).Substring(5)

    $pids = @()
    $source = 'commandline'
    try {
        $procs = @(Get-CimInstance Win32_Process -Filter "Name='TcSystemServiceUm.exe'" -ErrorAction Stop)
        $pids = @($procs | Where-Object { [string]$_.CommandLine -match [regex]::Escape($name) } | ForEach-Object { [int]$_.ProcessId })
        if ($pids.Count -eq 0) {
            $pids = @($procs | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.CommandLine) } | ForEach-Object { [int]$_.ProcessId })
            if ($pids.Count -gt 0) { $source = 'unreadable-commandline' }
        }
    }
    catch {
        Write-Verbose "Get-TcLocalUmRtProcess: process list not readable ($($_.Exception.Message))"
        $pids = @()
    }
    [PSCustomObject]@{ RuntimeName = $name; Pids = [int[]]$pids; PidSource = $source }
}

function Test-TcProcessAlive {
    <#
    .SYNOPSIS
        $true when a process with this id exists (Get-Process -Id does not fail).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Id)
    try { $null = Get-Process -Id $Id -ErrorAction Stop; return $true } catch { return $false }
}
