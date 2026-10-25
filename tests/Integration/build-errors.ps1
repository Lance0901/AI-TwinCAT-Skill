# Integration: Build-TcProject / Get-TcBuildErrors read real compiler messages from the XAE Error List.
# Steps: Connect-TcIde -SolutionPath -> Get-TcPouCode -> inject "nUndefinedVar_Test := 1;" (C0046)
#        -> Build-TcProject (expect BUILD_FAILED, buildSucceeded=false, codeErrors with file/line)
#        -> Get-TcBuildErrors -IncludeWarnings -IncludeMessages (counts)
#        -> restore the POU -> Build-TcProject (expect success, codeErrors empty) -> Disconnect-TcIde -Quit.
# Every step appends one JSON line to -LogPath; console prints "PASS/FAIL <step> [cmdlet] <code> <ms>".
#
# THIS SCRIPT MODIFIES THE PROJECT ON DISK: XAE saves all documents before a build ("Save all
# before build" is on by default), so the injected line is written into <PouName>.TcPOU by step 4.
# Therefore:
#   - -IUnderstandThisModifiesTheProject is mandatory (exit 2 without it);
#   - a solution under a OneDrive folder is refused (exit 3) - run against a plain local COPY;
#   - the POU file is copied to <PouName>.TcPOU.bak-<timestamp> before the injection and
#     restored from that copy (plain file copy, not through the IDE) in the finally block;
#     the .bak is deleted only after the restore was verified.
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Integration/build-errors.ps1 `
#       -SolutionPath C:\Temp\TcBuildErrTest\TwinCAT_Festo.sln -ProgId TcXaeShell.DTE.15.0 `
#       -IUnderstandThisModifiesTheProject
# Known XAE quirk: a full compile of a project with visualizations can pop "Assertion Failed"
# (CODESYS code optimizer); the build call then never returns - run this script under an outer
# deadline (see README) and delete plc\_CompileInfo before retrying. When the outer deadline
# kills this script the finally block does not run: the .bak file is then left next to the POU
# for a manual restore.
# Does not Activate / Login / touch the PLC runtime.

param(
    [Parameter(Mandatory)][string]$SolutionPath,
    [string]$ProgId = 'TcXaeShell.DTE.15.0',
    [string]$PlcProject = 'plc',
    [string]$PouName = 'MAIN_GantryCylinder',
    # Tree path of the POU; default: TIPC^<PlcProject>^<PlcProject> Project^POUs^<PouName>
    [string]$PouPath,
    # Default: <this folder>\logs\build-errors.log (resolved in the body: $PSScriptRoot is empty in param defaults under -File)
    [string]$LogPath,
    # Delete <plc>\_CompileInfo next to the solution before opening it (avoids stale-state asserts).
    [switch]$CleanCompileInfo,
    # Required: acknowledges that the POU file of the solution is modified on disk (and restored).
    [switch]$IUnderstandThisModifiesTheProject,
    # Pass -AllowUnresolvedLibrary to Build-TcProject: accept LIBRARY_UNRESOLVED (project with missing libraries, #45).
    [switch]$AllowUnresolvedLibrary
)

if (-not $IUnderstandThisModifiesTheProject) {
    Write-Host "build-errors.ps1 MODIFIES THE PROJECT ON DISK: XAE saves all documents before a build, so the"
    Write-Host "injected compile error is written into $PouName.TcPOU (a .bak copy is made and restored afterwards)."
    Write-Host "Run it only against a local COPY of a solution and pass -IUnderstandThisModifiesTheProject."
    exit 2
}
if ($SolutionPath -match '(?i)OneDrive') {
    Write-Host "REFUSED: the solution path is inside a OneDrive folder ($SolutionPath). Copy the solution to a plain local folder (e.g. C:\Temp) first."
    exit 3
}

$ErrorActionPreference = 'Continue'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($LogPath)) { $LogPath = Join-Path $scriptDir 'logs\build-errors.log' }
Import-Module (Join-Path $scriptDir '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue

if ([string]::IsNullOrWhiteSpace($PouPath)) { $PouPath = "TIPC^$PlcProject^$PlcProject Project^POUs^$PouName" }
$injectLine = 'nUndefinedVar_Test := 1;'

$logDir = Split-Path -Parent $LogPath
if ($logDir -and -not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
Add-Content -Path $LogPath -Value ("# build-errors.ps1 run " + (Get-Date).ToString('s') + " solution=$SolutionPath") -Encoding UTF8

$script:failCount = 0
$script:ideConnected = $false   # Connect-TcIde succeeded and Disconnect-TcIde has not run yet
$script:ownIde = $false         # the IDE was launched by this run (safe to quit)
$script:pouFile = $null         # <...>\<PouName>.TcPOU on disk
$script:pouBackup = $null       # <pouFile>.bak-<timestamp>

function Write-StepLog {
    param([string]$Step, [string]$Cmdlet, [int]$ElapsedMs, [bool]$Pass, $Result, [string]$Note)
    $code = $null
    if ($null -ne $Result -and $Result.PSObject.Properties['error'] -and $null -ne $Result.error) { $code = $Result.error.code }
    $entry = [PSCustomObject]@{
        time = (Get-Date).ToString('s'); step = $Step; cmdlet = $Cmdlet; elapsedMs = $ElapsedMs
        pass = $Pass; code = $code; note = $Note; result = $Result
    }
    Add-Content -Path $LogPath -Value ($entry | ConvertTo-Json -Depth 8 -Compress) -Encoding UTF8
    if ($Pass) { $tag = 'PASS' } else { $tag = 'FAIL'; $script:failCount++ }
    $codeText = if ($code) { " $code" } else { '' }
    $noteText = if ($Note) { " - $Note" } else { '' }
    Write-Host ("{0} {1} [{2}]{3} {4}ms{5}" -f $tag, $Step, $Cmdlet, $codeText, $ElapsedMs, $noteText)
}
function Invoke-Step {
    param([string]$Step, [string]$Cmdlet, [scriptblock]$Block, [scriptblock]$Check, [string]$Note)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = $null
    try { $r = & $Block }
    catch { $r = [PSCustomObject]@{ success = $false; error = [PSCustomObject]@{ code = 'SCRIPT_EXCEPTION'; message = $_.Exception.Message } } }
    $sw.Stop()
    $pass = if ($Check) { [bool](& $Check $r) } else { [bool]$r.success }
    Write-StepLog -Step $Step -Cmdlet $Cmdlet -ElapsedMs ([int]$sw.ElapsedMilliseconds) -Pass $pass -Result $r -Note $Note
    return $r
}

# Locate <PouName>.TcPOU on disk (prefer the one under <PlcProject>) and copy it to a .bak file.
function Backup-PouFile {
    $slnDir = Split-Path -Parent (Resolve-Path $SolutionPath).Path
    $candidates = @(Get-ChildItem -Path $slnDir -Recurse -Filter "$PouName.TcPOU" -File -ErrorAction SilentlyContinue)
    $preferred = @($candidates | Where-Object { $_.FullName -like "*\$PlcProject\*" })
    $file = if ($preferred.Count -gt 0) { $preferred[0] } elseif ($candidates.Count -gt 0) { $candidates[0] } else { $null }
    if ($null -eq $file) { throw "POU file $PouName.TcPOU not found under $slnDir" }
    $script:pouFile = $file.FullName
    $script:pouBackup = $script:pouFile + '.bak-' + (Get-Date).ToString('yyyyMMdd-HHmmss')
    Copy-Item -LiteralPath $script:pouFile -Destination $script:pouBackup -Force
    if (-not (Test-Path -LiteralPath $script:pouBackup)) { throw "backup copy failed: $($script:pouBackup)" }
    Write-Host "backup: $($script:pouBackup)"
}

# Restore the POU file from the .bak by plain file copy (never through the IDE); delete the .bak
# only when the restored file matches the backup.
function Restore-PouFile {
    if ([string]::IsNullOrWhiteSpace($script:pouBackup) -or -not (Test-Path -LiteralPath $script:pouBackup)) { return }
    try {
        Copy-Item -LiteralPath $script:pouBackup -Destination $script:pouFile -Force
        $hBak = (Get-FileHash -LiteralPath $script:pouBackup -Algorithm SHA256).Hash
        $hNow = (Get-FileHash -LiteralPath $script:pouFile -Algorithm SHA256).Hash
        if ($hBak -eq $hNow) {
            Remove-Item -LiteralPath $script:pouBackup -Force
            Write-Host "restored $($script:pouFile) from backup (bak deleted)"
        }
        else {
            Write-Host "WARNING: restore of $($script:pouFile) did not verify; backup kept at $($script:pouBackup)"
        }
    }
    catch {
        Write-Host "WARNING: restore failed ($($_.Exception.Message)); backup kept at $($script:pouBackup)"
    }
}

function Invoke-Main {
    if ($CleanCompileInfo) {
        $ci = Join-Path (Split-Path -Parent $SolutionPath) "$([IO.Path]::GetFileNameWithoutExtension($SolutionPath))\$PlcProject\_CompileInfo"
        if (Test-Path $ci) { Remove-Item $ci -Recurse -Force; Write-Host "removed $ci" }
    }

    # 1. connect (launches the IDE when none has this solution open)
    $c = Invoke-Step -Step '1-connect' -Cmdlet 'Connect-TcIde' -Block { Connect-TcIde -SolutionPath $SolutionPath -ProgId $ProgId }
    if (-not $c.success) { Write-Host "ABORT: cannot connect"; return 1 }
    $script:ideConnected = $true
    $script:ownIde = ($c.data.selectedBy -eq 'launched')
    Write-Host "IDE pid $($c.data.ideProcessId) selectedBy=$($c.data.selectedBy)"

    # 2. read the POU
    $g = Invoke-Step -Step '2-read-pou' -Cmdlet 'Get-TcPouCode' -Block { Get-TcPouCode -PouName $PouName -PouPath $PouPath }
    if (-not $g.success) { Write-Host "ABORT: POU not readable"; return 1 }
    $origImpl = [string]$g.data.implementation
    if ($origImpl -match [regex]::Escape($injectLine)) {
        Write-Host "ABORT: POU already contains the injected line (leftover of an earlier run?) - restore the POU and rerun"
        return 1
    }

    # backup the POU file BEFORE the injection (XAE saves it to disk when building)
    try { Backup-PouFile } catch { Write-Host "ABORT: $($_.Exception.Message)"; return 1 }

    # 3. inject an undefined identifier (C0046) as the last implementation line
    $w = Invoke-Step -Step '3-inject' -Cmdlet 'Write-TcPouCode' -Block {
        Write-TcPouCode -PouName $PouName -PouPath $PouPath -Implementation ($origImpl.TrimEnd() + "`r`n$injectLine`r`n")
    }
    if (-not $w.success) { Write-Host "ABORT: inject failed"; return 1 }

    # 4. build -> BUILD_FAILED, buildSucceeded=false, codeErrors with file/line. With unresolved
    #    libraries (libraryErrors > 0) the code may not be compiled at all (#45): LIBRARY_UNRESOLVED
    #    also passes (no -AllowUnresolvedLibrary here: the real result is what is checked).
    $b1 = Invoke-Step -Step '4-build-fail' -Cmdlet 'Build-TcProject' -Block { Build-TcProject } -Check {
        param($r)
        ((-not $r.success) -and $r.error.code -eq 'BUILD_FAILED' -and $r.data.buildSucceeded -eq $false -and @($r.data.codeErrors).Count -gt 0) -or
        ((-not $r.success) -and $r.error.code -eq 'LIBRARY_UNRESOLVED' -and $r.data.libraryErrors -gt 0)
    }
    $notCompiled = ((-not $b1.success) -and $b1.error.code -eq 'LIBRARY_UNRESOLVED')
    Write-Host "  buildSucceeded=$($b1.data.buildSucceeded) decidedBy=$($b1.data.decidedBy) errors=$($b1.data.errors) libraryErrors=$($b1.data.libraryErrors) failedProjects=$($b1.data.failedProjects) warnings=$($b1.data.warnings) errorItems=$(@($b1.data.errorItems).Count) codeErrors=$(@($b1.data.codeErrors).Count)"
    Write-Host "  message: $($b1.error.message)"
    $hit = @($b1.data.codeErrors | Where-Object { $_.file -like "*$PouName*" -and $null -ne $_.line -and $_.line -gt 0 })
    $c0046 = @($hit | Where-Object { $_.code -eq 'C0046' })
    Write-StepLog -Step '4b-codeErrors-check' -Cmdlet 'Build-TcProject' -ElapsedMs 0 -Pass ($notCompiled -or ($hit.Count -gt 0 -and $c0046.Count -gt 0)) `
        -Result ([PSCustomObject]@{ success = ($hit.Count -gt 0); data = [PSCustomObject]@{ pouHits = $hit; c0046 = $c0046.Count; first3 = @($b1.data.codeErrors | Select-Object -First 3) } }) `
        -Note "codeErrors with file~$PouName and a line: $($hit.Count); with code C0046: $($c0046.Count)$(if ($notCompiled) { '; LIBRARY_UNRESOLVED: code not compiled (#45), not checked' })"
    @($b1.data.codeErrors) | Select-Object -First 3 | ForEach-Object {
        $itemJson = $_ | ConvertTo-Json -Compress
        Write-Host "  codeError: $itemJson"
    }

    # 5. Get-TcBuildErrors alone (counts + warnings + messages)
    $e = Invoke-Step -Step '5-get-errors' -Cmdlet 'Get-TcBuildErrors' -Block { Get-TcBuildErrors -IncludeWarnings -IncludeMessages } -Check {
        param($r) $r.success -and $r.data.counts.errors -gt 0
    }
    $countsJson = $e.data.counts | ConvertTo-Json -Compress
    $rowsText = "errors=$(@($e.data.errors).Count) warnings=$(@($e.data.warnings).Count) messages=$(@($e.data.messages).Count)"
    Write-Host "  counts: $countsJson truncated=$($e.data.truncated) rows: $rowsText"

    # 6. restore the POU through the IDE (the file on disk is restored again in the finally block)
    $null = Invoke-Step -Step '6-restore' -Cmdlet 'Write-TcPouCode' -Block { Write-TcPouCode -PouName $PouName -PouPath $PouPath -Implementation $origImpl }

    # 7. build again -> success, codeErrors empty; whatever is still listed is Library Manager items
    #    (LIBRARY_UNRESOLVED without -AllowUnresolvedLibrary)
    $b2 = Invoke-Step -Step '7-build-ok' -Cmdlet 'Build-TcProject' -Block { Build-TcProject -AllowUnresolvedLibrary:$AllowUnresolvedLibrary } -Check {
        param($r)
        ($r.success -and $r.data.buildSucceeded -eq $true -and @($r.data.codeErrors).Count -eq 0) -or
        ((-not $r.success) -and $r.error.code -eq 'LIBRARY_UNRESOLVED' -and @($r.data.codeErrors).Count -eq 0)
    }
    Write-Host "  buildSucceeded=$($b2.data.buildSucceeded) decidedBy=$($b2.data.decidedBy) errors=$($b2.data.errors) libraryErrors=$($b2.data.libraryErrors) failedProjects=$($b2.data.failedProjects) errorItems=$(@($b2.data.errorItems).Count) codeErrors=$(@($b2.data.codeErrors).Count)"
    @($b2.data.errorItems) | ForEach-Object {
        $leftover = "  leftover: [" + $_.file + "] " + $_.description
        Write-Host $leftover
    }

    # 8. close the IDE we launched (never an IDE the user had open)
    $quitNote = if ($script:ownIde) { 'quit' } else { 'left running (not launched by this run)' }
    $null = Invoke-Step -Step '8-disconnect' -Cmdlet 'Disconnect-TcIde' -Block { Disconnect-TcIde -Quit:$script:ownIde } -Note $quitNote
    $script:ideConnected = $false

    return $script:failCount
}

$exitCode = 1
try {
    $mainOut = @(Invoke-Main)
    $exitCode = [int]$mainOut[$mainOut.Count - 1]
}
finally {
    # Always: close the IDE first (so it cannot re-save the POU afterwards), then put the
    # original file back from the .bak by plain copy and delete the .bak once verified.
    if ($script:ideConnected) {
        try { $null = Disconnect-TcIde -Quit:$script:ownIde; Write-Host "finally: Disconnect-TcIde -Quit:$($script:ownIde)" } catch { Write-Host "finally: Disconnect-TcIde failed: $($_.Exception.Message)" }
        $script:ideConnected = $false
    }
    Restore-PouFile
    Write-Host "DONE failures=$($script:failCount) log=$LogPath"
}
exit $exitCode
