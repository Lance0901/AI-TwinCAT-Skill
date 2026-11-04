# Unit-test state isolation (#118). Dot-source it at the top of every tests/Unit/*.ps1 that loads
# the module, BEFORE the first Import-Module (scripts/check.ps1 "unit" fails a script that does not):
#   . (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }
# - Own process: the environment below must never stay behind in the caller's session (a later
#   real Enable-TcConfig there would read the temp state and miss a real lifecycle block, #68, or
#   throw under the refusal flag). So when the test script is NOT the -File entry of this
#   powershell.exe (run with "& script.ps1" from an interactive / persistent session, or
#   dot-sourced), it is started again as "powershell.exe -NoProfile -File <script> <args>" and the
#   caller's script ends with the child's exit code ($TcUnitChildExit, the 'exit' on the same line); nothing is changed in the caller's session.
# - $env:TCAUTO_STATE_DIR: kept when the caller already set one (scripts/check.ps1 gives every
#   script its own empty folder and removes it afterwards); otherwise a new empty folder
#   %TEMP%\tcauto-unit-state-<guid>, removed when this PowerShell exits (a killed run leaves it;
#   under scripts/check.ps1 the helper never creates one). Every module state file follows it:
#   build-required.json, lifecycle-block.json (+ history) and ide-solutions.json, and the mutex
#   names get the hash of that folder.
# - $env:TCAUTO_TEST_FORBID_REAL_STATE = '1': the module refuses the real default folders
#   (%TEMP%\TwinCATAutomation, %LOCALAPPDATA%\TwinCATAutomation) if a test ever clears
#   TCAUTO_STATE_DIR while still calling it: it throws and prints TCAUTO_REAL_STATE_REFUSED on
#   stderr, which scripts/check.ps1 turns into a FAIL.
# Never point TCAUTO_STATE_DIR at a real state folder: this helper throws when it does.
param(
    [string]$Caller,
    [System.Collections.IDictionary]$CallerArgs
)
if ([string]::IsNullOrWhiteSpace($Caller)) { $Caller = $MyInvocation.PSCommandPath }
$TcUnitChildExit = $null

# Is $Script the -File argument of this process (powershell.exe ... -File <script>)?
function Test-TcUnitProcessEntry([string]$Script) {
    if ([string]::IsNullOrWhiteSpace($Script)) { return $false }
    $want = [IO.Path]::GetFullPath($Script)
    $a = [Environment]::GetCommandLineArgs()
    for ($i = 1; $i -lt $a.Count - 1; $i++) {
        if ($a[$i] -match '^[-/]f(i(le?)?)?$') {
            try { $got = [IO.Path]::GetFullPath($a[$i + 1].Trim('"')) } catch { return $false }
            return [string]::Equals($got, $want, [StringComparison]::OrdinalIgnoreCase)
        }
    }
    $false
}

if (-not (Test-TcUnitProcessEntry $Caller)) {
    if ($env:TCAUTO_UNIT_RELAUNCHED -eq $Caller) {
        throw "UnitIsolation: '$Caller' was started again with -File but still is not the process entry; refusing to change this session's environment (#118)"
    }
    $tcUnitArgs = @('-NoProfile', '-File', $Caller)
    if ($null -ne $CallerArgs) {
        foreach ($k in @($CallerArgs.Keys)) {
            $v = $CallerArgs[$k]
            if ($v -is [System.Management.Automation.SwitchParameter]) { if ($v.IsPresent) { $tcUnitArgs += "-$k" } }
            else { $tcUnitArgs += "-$k"; $tcUnitArgs += "$v" }
        }
    }
    $tcUnitSavedRelaunch = $env:TCAUTO_UNIT_RELAUNCHED
    $tcUnitSavedEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'   # 5.1: stderr of a native child must not become a terminating error
    $env:TCAUTO_UNIT_RELAUNCHED = $Caller
    try { & powershell.exe @tcUnitArgs; $tcUnitCode = $LASTEXITCODE }
    finally {
        if ($null -eq $tcUnitSavedRelaunch) { Remove-Item Env:\TCAUTO_UNIT_RELAUNCHED -ErrorAction SilentlyContinue } else { $env:TCAUTO_UNIT_RELAUNCHED = $tcUnitSavedRelaunch }
        $ErrorActionPreference = $tcUnitSavedEap
    }
    # 'exit' in a dot-sourced file ends only that file: the caller's line ends the test with this code.
    $TcUnitChildExit = $tcUnitCode
    return
}

# --- from here on: this process belongs to the test script alone ---

function Get-TcUnitLongPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full -notmatch '~') { return $full }
    if ($null -eq ([System.Management.Automation.PSTypeName]'TcUnitIsoLongPath').Type) {
        Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
using System.Text;
public static class TcUnitIsoLongPath {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern uint GetLongPathName(string shortPath, StringBuilder longPath, uint size);
    public static string Get(string p) {
        var sb = new StringBuilder(1024);
        uint n = GetLongPathName(p, sb, (uint)sb.Capacity);
        return (n > 0 && n < sb.Capacity) ? sb.ToString() : p;
    }
}
'@
    }
    # expand the longest existing parent (the folder itself may not exist yet)
    $head = $full; $tail = ''
    while ($head -and -not (Test-Path -LiteralPath $head)) {
        $tail = '\' + (Split-Path -Leaf $head) + $tail
        $head = Split-Path -Parent $head
    }
    if (-not $head) { return $full }
    ([TcUnitIsoLongPath]::Get($head).TrimEnd('\') + $tail)
}

function Get-TcUnitRealStateDirs {
    $dirs = @(Join-Path ([IO.Path]::GetTempPath()) 'TwinCATAutomation')
    if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) { $dirs += Join-Path $env:TEMP 'TwinCATAutomation' }
    if (-not [string]::IsNullOrWhiteSpace($env:TCAUTO_UNIT_REAL_LOCALAPPDATA)) { $dirs += Join-Path $env:TCAUTO_UNIT_REAL_LOCALAPPDATA 'TwinCATAutomation' }
    elseif (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { $dirs += Join-Path $env:LOCALAPPDATA 'TwinCATAutomation' }
    @($dirs | ForEach-Object { Get-TcUnitLongPath $_ })
}

function Test-TcUnitRealStateDir([string]$Dir) {
    if ([string]::IsNullOrWhiteSpace($Dir)) { return $true }
    $full = Get-TcUnitLongPath $Dir
    foreach ($real in Get-TcUnitRealStateDirs) {
        if ([string]::Equals($full, $real, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ($full.StartsWith($real + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    $false
}

# The real %LOCALAPPDATA% as seen when the helper first ran (tests may redirect LOCALAPPDATA later).
if ([string]::IsNullOrWhiteSpace($env:TCAUTO_UNIT_REAL_LOCALAPPDATA)) { $env:TCAUTO_UNIT_REAL_LOCALAPPDATA = $env:LOCALAPPDATA }

if ([string]::IsNullOrWhiteSpace($env:TCAUTO_STATE_DIR)) {
    $env:TCAUTO_STATE_DIR = Join-Path ([IO.Path]::GetTempPath()) ("tcauto-unit-state-{0}" -f [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $env:TCAUTO_STATE_DIR -Force
    $global:TcUnitOwnStateDir = $env:TCAUTO_STATE_DIR
    $null = Register-EngineEvent -SourceIdentifier ([System.Management.Automation.PsEngineEvent]::Exiting) -Action {
        if ($global:TcUnitOwnStateDir) { Remove-Item -LiteralPath $global:TcUnitOwnStateDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
if (Test-TcUnitRealStateDir $env:TCAUTO_STATE_DIR) {
    throw "UnitIsolation: TCAUTO_STATE_DIR '$($env:TCAUTO_STATE_DIR)' is a real TcAuto state folder; unit tests must use a temp folder (#118)"
}
$env:TCAUTO_TEST_FORBID_REAL_STATE = '1'
