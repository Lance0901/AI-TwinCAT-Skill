# Unit: 8.3 short vs long solution paths (issue #63), no IDE / runtime needed.
# Get-TcLongPath, Find-TcBlockedSolutionIde and the IDE matching of Connect-TcIde must treat
# C:\Users\RUNNER~1\...\AXISIN~1.SLN and its long spelling as the same solution. Skips (exit 0)
# when the volume generates no 8.3 short names.
#   powershell.exe -NoProfile -File tests/Unit/solution-path-83.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}
if ($null -eq ([System.Management.Automation.PSTypeName]'TcUnit83Path').Type) {
    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
using System.Text;
public static class TcUnit83Path {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern uint GetShortPathName(string p, StringBuilder s, uint size);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern uint GetLongPathName(string p, StringBuilder s, uint size);
    public static string Short(string p) { var sb = new StringBuilder(1024); uint n = GetShortPathName(p, sb, 1024); return (n > 0 && n < 1024) ? sb.ToString() : p; }
    public static string Long(string p) { var sb = new StringBuilder(1024); uint n = GetLongPathName(p, sb, 1024); return (n > 0 && n < 1024) ? sb.ToString() : p; }
}
'@
}

$root = Join-Path $env:TEMP ("tcauto-unit83-{0}" -f [guid]::NewGuid().ToString('N'))
$origLocalAppData = $env:LOCALAPPDATA
New-Item -ItemType Directory -Path $root | Out-Null
$root = [TcUnit83Path]::Long($root)
$longDir = Join-Path $root 'Verify Long Folder Name 12345'
New-Item -ItemType Directory -Path $longDir | Out-Null
$sln = Join-Path $longDir 'AxisInterface_Type01_Library.sln'
Set-Content -Path $sln -Value 'Microsoft Visual Studio Solution File, Format Version 12.00'
$short = [TcUnit83Path]::Short($sln)
if ($short -eq $sln -or $short -notmatch '~') {
    "SKIP solution-path-83: this volume does not generate 8.3 short names ($sln -> $short)"
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    exit 0
}
$shortDir = [TcUnit83Path]::Short($longDir)
"short form under test: $short"
$env:LOCALAPPDATA = $root   # session records go to the temp folder
$origStateDir = $env:TCAUTO_STATE_DIR
$env:TCAUTO_STATE_DIR = Join-Path $root 'state'   # #118: own records (the -Short83 child below uses its own folder)

$global:FakeIde = @{}
& $mod {
    function script:Get-Process {
        [CmdletBinding()] param([int]$Id)
        if ($global:FakeIde.ContainsKey($Id)) { return [PSCustomObject]@{ Id = $Id; MainWindowTitle = $global:FakeIde[$Id].Title; MainWindowHandle = [IntPtr]::Zero; StartTime = [DateTime]'2026-01-01T00:00:00' } }
        Microsoft.PowerShell.Management\Get-Process @PSBoundParameters
    }
    function script:Find-TcIdeModalDialog {
        [CmdletBinding()] param([int]$ProcessId = 0, [int]$TimeoutSec = 5, [int]$PrepareTimeoutSec = 0)
        if ($global:FakeIde.ContainsKey($ProcessId)) { return $global:FakeIde[$ProcessId].Dialog }
        $null
    }
    function script:Get-AllComObjects { [CmdletBinding()] param([switch]$IncludeDisplayName) $global:FakeRot }
}
function New-Dte { $o = New-Object PSObject; $o | Add-Member -MemberType NoteProperty -Name Version -Value ''; $o | Add-Member -MemberType NoteProperty -Name Busy -Value $false; $o }
function Set-Rot([object[]]$Entries) {
    $global:FakeRot = @($Entries | ForEach-Object { @{ DisplayName = "!Fake.DTE.1:$($_.Pid)"; Object = (New-Dte); ProgId = 'Fake.DTE.1'; ProcessId = $_.Pid } })
}
function Reset-Conn { & $mod { $script:TcIdeConnected = $false; $script:TcDte = $null; $script:TcIdeProcessId = $null; $script:TcSolutionPath = $null } }

try {
    # --- Get-TcLongPath ---
    $lp = { param($p) & $mod { param($x) Get-TcLongPath $x } $p }
    Check 'long-path-file' ((& $lp $short) -ceq $sln) "got=$(& $lp $short)"
    Check 'long-path-long-unchanged' ((& $lp $sln) -ceq $sln) "got=$(& $lp $sln)"
    Check 'long-path-dir' ((& $lp $shortDir) -ceq $longDir) "got=$(& $lp $shortDir)"
    Check 'long-path-lowercase-input' ((& $lp $short.ToLowerInvariant()) -eq $sln) "got=$(& $lp $short.ToLowerInvariant())"
    $missingShort = Join-Path $shortDir 'sub\Missing.sln'
    Check 'long-path-missing-leaf' ((& $lp $missingShort) -ceq (Join-Path $longDir 'sub\Missing.sln')) "got=$(& $lp $missingShort)"
    $nowhere = 'Q:\No Such Folder~1\x.sln'
    Check 'long-path-nothing-exists' ((& $lp $nowhere) -ceq $nowhere) "got=$(& $lp $nowhere)"
    Check 'long-path-dotdot' ((& $lp (Join-Path $shortDir '..\Verify Long Folder Name 12345\AxisInterface_Type01_Library.sln')) -ceq $sln) 'relative segments'

    # --- Find-TcBlockedSolutionIde: short and long -SolutionPath find the same mock IDE ---
    $title = 'AxisInterface_Type01_Library - Microsoft Visual Studio'
    $dlgShort = @{ Title = 'x'; Text = "The project file '$shortDir\Axis\plc.plcproj' has been modified outside of TwinCAT XAE."; Hwnd = 0; Buttons = @() }
    $global:FakeIde = @{
        101 = @{ Title = $title; Dialog = $dlgShort }   # dialog names the SHORT folder: inside
        102 = @{ Title = $title; Dialog = $null }        # title only
    }
    $cands = @([PSCustomObject]@{ pid = 101; progId = 'Fake.DTE.1'; busy = $true }, [PSCustomObject]@{ pid = 102; progId = 'Fake.DTE.1'; busy = $true })
    $find = { param($s) @(& $mod { param($c, $s) Find-TcBlockedSolutionIde -Candidates $c -SolutionPath $s } $cands $s | ForEach-Object { "$($_.Candidate.pid):$($_.MatchedBy):$($_.Strong)" }) -join ',' }
    $rLong = & $find $sln
    $rShort = & $find $short
    Check 'find-long' ($rLong -eq '101:dialog-path:True,102:window-title:False') "got=$rLong"
    Check 'find-short-equals-long' ($rShort -eq $rLong) "short=$rShort long=$rLong"

    # session record saved in one spelling, asked for in the other
    $global:FakeIde = @{ 201 = @{ Title = $title; Dialog = $null } }
    $one = @([PSCustomObject]@{ pid = 201; progId = 'Fake.DTE.1'; busy = $true })
    foreach ($pair in @(@('rec-short-ask-long', $short, $sln), @('rec-long-ask-short', $sln, $short))) {
        & $mod { param($s) Save-TcIdeSolutionRecord -ProcessId 201 -Solution $s } $pair[1]
        $h = @(& $mod { param($c, $s) Find-TcBlockedSolutionIde -Candidates $c -SolutionPath $s } $one $pair[2])
        Check $pair[0] ($h.Count -eq 1 -and $h[0].MatchedBy -eq 'session-record' -and $h[0].Strong -and $h[0].CorroboratedBy -eq 'window-title') "n=$($h.Count) by=$($h[0].MatchedBy) strong=$($h[0].Strong) why=$($h[0].Contradiction)"
    }
    # module state in short spelling
    $h = @(& $mod { param($c, $s, $p) Find-TcBlockedSolutionIde -Candidates $c -SolutionPath $s -PreviousProcessId 201 -PreviousStartTime ([DateTime]'2026-01-01T00:00:00') -PreviousSolution $p } $one $sln $short)
    Check 'module-state-short-previous' ($h.Count -eq 1 -and $h[0].MatchedBy -eq 'module-state') "by=$($h[0].MatchedBy)"
    # the short spelling of OUR sln in KnownSolutions is not "a same-named solution elsewhere"
    $h = @(& $mod { param($c, $s, $k) Find-TcBlockedSolutionIde -Candidates $c -SolutionPath $s -KnownSolutions @($k) } $one $sln $short)
    Check 'known-short-is-not-elsewhere' ($h.Count -eq 1 -and $h[0].Strong) "strong=$($h[0].Strong) why=$($h[0].Contradiction)"
    # dialog paths are expanded
    $paths = @(& $mod { param($x) Get-TcDialogProjectPaths -Text $x } "File '$shortDir\AxisInterface_Type01_Library.sln' changed")
    Check 'dialog-paths-expanded' ($paths.Count -eq 1 -and $paths[0] -ceq $sln) "got=$($paths -join '|')"

    # --- Connect-TcIde -NoLaunch: blocked IDE, short and long give the same answer, data.solution is the long name ---
    $global:FakeIde = @{ 301 = @{ Title = $title; Dialog = $dlgShort } }
    # #281 C: a blocked IDE is attached only when TcAuto may work in it: the user agreed earlier (consent memory)
    & $mod { Add-TcIdeAttachConsent -ProcessId 301 }
    $res = @{}
    foreach ($kv in @(@('long', $sln), @('short', $short))) {
        Reset-Conn
        Set-Rot @(@{ Pid = 301 })
        $r = Connect-TcIde -SolutionPath $kv[1] -ProgId 'Fake.DTE.1' -NoLaunch
        $st = & $mod { [PSCustomObject]@{ pid = $script:TcIdeProcessId; sln = $script:TcSolutionPath } }
        $res[$kv[0]] = "$($r.error.code)|$($r.data.ideProcessId)|$($r.data.matchedBy)|$($r.data.attached)|$($r.data.solution)|$($st.pid)|$($st.sln)"
    }
    Check 'connect-long' ($res.long -ceq "IDE_MODAL_DIALOG|301|dialog-path|True|$sln|301|$sln") "got=$($res.long)"
    Check 'connect-short-equals-long' ($res.short -ceq $res.long) "short=$($res.short)"

    # --- a file that does not exist is still reported as such ---
    Reset-Conn
    $global:FakeIde = @{}
    Set-Rot @()
    $r = Connect-TcIde -SolutionPath (Join-Path $shortDir 'Nope.sln') -ProgId 'Fake.DTE.1' -NoLaunch
    Check 'connect-missing-file' ($r.error.code -eq 'FILE_NOT_FOUND') "code=$($r.error.code)"

    # --- Solution.Open gets the long name. Open is only reached after Connect-TcIde LAUNCHES an IDE
    # ([Activator]::CreateInstance of a registered ProgId, not mockable here), so this is a source
    # check: the call must pass the normalised (8.3-expanded) path, never the raw parameter. ---
    $src = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\Public\Connect-TcIde.ps1') -Raw
    Check 'open-gets-normalized-path' (($src -match 'Solution\.Open\(\$normalizedSolutionPath\)') -and ($src -notmatch 'Solution\.Open\(\$SolutionPath\)')) 'Solution.Open argument'

    # --- the whole blocked-solution-ide suite with every path handed over in 8.3 form ---
    $out = & powershell.exe -NoProfile -File (Join-Path $PSScriptRoot 'blocked-solution-ide.ps1') -Short83 2>&1 | Out-String
    $code = $LASTEXITCODE
    Check 'blocked-solution-ide-short83' ($code -eq 0) "exit=$code $(@($out -split "`n" | Where-Object { $_ -match '^FAIL' }) -join ' / ')"
}
finally {
    Reset-Conn
    $env:LOCALAPPDATA = $origLocalAppData
    $env:TCAUTO_STATE_DIR = $origStateDir
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name FakeIde, FakeRot -Scope Global -ErrorAction SilentlyContinue
}

"failed: $fail"
exit [Math]::Min($fail, 255)
