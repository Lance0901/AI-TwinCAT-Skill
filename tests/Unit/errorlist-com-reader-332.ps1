# Unit: the algorithm of the COM Error List read (ErrorListComCore.cs) and its PowerShell wrapper, driven with a FAKE source
# (no IDE, no EnvDTE assembly needed: only ErrorListComCore.cs is compiled), review #332 S1 / S3 / S7 / S9 / N5.
#   K  normal read: severities by flag, flags put back; a Count that lags one read behind the flag change does not swap rows (S3);
#      Error List window not created -> reject without touching a flag (S7); flags that never reach the list -> flags-not-effective
#   L  Read-TcErrorListCom: busy once, buttons restored -> retried with the FIRST attempt's flags; busy and buttons NOT restored -> no retry,
#      flagsRestored $false is returned (S1)
#   M  Initialize-TcErrorListComTypes: a failure is not cached for the whole process (N5)
#   powershell.exe -NoProfile -File tests/Unit/errorlist-com-reader-332.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
$stateRoot = Join-Path $env:TEMP ("tcauto-unit-reader-332-{0}" -f [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $stateRoot -Force
$env:TCAUTO_STATE_DIR = Join-Path $stateRoot 'state'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 600) { $Detail = $Detail.Substring(0, 600) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}
function J($o) { $o | ConvertTo-Json -Compress -Depth 6 }

$fake = @'

namespace TcAutomation
{
    // Scripted Error List: rows per severity, the flags the user has, and the misbehaviours the review is about.
    public sealed class FakeState
    {
        public bool[] Flags = new bool[] { true, false, true };
        public List<ErrorListComRow> Errs = new List<ErrorListComRow>();
        public List<ErrorListComRow> Warns = new List<ErrorListComRow>();
        public List<ErrorListComRow> Msgs = new List<ErrorListComRow>();
        public bool Exists = true;
        public int Lag;                 // Count() answers with the previous list this many times after a flag change
        public bool NeverZero;          // flags have no effect on the list
        public int BusyOnCount;         // the Count() call with this number (per Read call 1) throws RPC_E_CALL_REJECTED once
        public bool FailSetsAfterBusy;  // after that busy error every SetFlag throws RPC_E_CALL_REJECTED (the restore fails)
        public int Runs;
        public int SetCalls;
        public int CountCallsRun1;
        public bool BusyThrown;
        public List<string> Orig = new List<string>();
    }

    sealed class FakeSource : IErrorListSource
    {
        readonly FakeState st;
        readonly int run;
        List<ErrorListComRow> shown;
        int lagLeft;
        public FakeSource(FakeState s, int run) { st = s; this.run = run; }
        List<ErrorListComRow> Current()
        {
            var l = new List<ErrorListComRow>();
            if (st.Flags[0]) l.AddRange(st.Errs);
            if (st.Flags[1]) l.AddRange(st.Warns);
            if (st.Flags[2]) l.AddRange(st.Msgs);
            if (st.NeverZero && l.Count == 0) l.Add(new ErrorListComRow());
            return l;
        }
        static COMException Busy() { return new COMException("busy", unchecked((int)0x80010001)); }
        public bool Open(out string caption) { caption = "Error List"; if (!st.Exists) return false; shown = Current(); return true; }
        public bool GetFlag(int i) { return st.Flags[i]; }
        public void SetFlag(int i, bool v)
        {
            st.SetCalls++;
            if (st.FailSetsAfterBusy && st.BusyThrown) throw Busy();
            if (st.Flags[i] != v) { st.Flags[i] = v; lagLeft = st.Lag; }
        }
        public int Count()
        {
            if (run == 1)
            {
                st.CountCallsRun1++;
                if (st.BusyOnCount > 0 && st.CountCallsRun1 == st.BusyOnCount) { st.BusyThrown = true; throw Busy(); }
            }
            if (lagLeft > 0) { lagLeft--; return shown.Count; }
            shown = Current();
            return shown.Count;
        }
        public ErrorListComRow RowAt(int i) { return shown[i - 1]; }
        public void Dispose() { }
    }

    // same name and signature as the real adapter: Read-TcErrorListCom calls it
    public static class ErrorListComReader
    {
        public static FakeState State = new FakeState();
        public static ErrorListComResult Read(object dte, int settleMs, int maxMs, bool[] originalFlags)
        {
            State.Runs++;
            string o = "null";
            if (originalFlags != null) o = originalFlags[0] + "," + originalFlags[1] + "," + originalFlags[2];
            State.Orig.Add(o);
            using (var s = new FakeSource(State, State.Runs)) return ErrorListComCore.Run(s, settleMs, maxMs, originalFlags);
        }
        public static ErrorListComRow Row(string d) { var r = new ErrorListComRow(); r.Description = d; r.Level = 2; r.Line = 1; r.Column = 1; return r; }
    }
}
'@
$core = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\Private\ErrorListComCore.cs'))
Add-Type -TypeDefinition ($core + $fake) -ErrorAction Stop
$st = [TcAutomation.ErrorListComReader]::State
function Reset-Fake([bool[]]$Flags = @($true, $false, $true), [int]$Lag = 0) {
    $s = New-Object TcAutomation.FakeState
    $s.Flags = $Flags
    $s.Lag = $Lag
    $s.Errs.AddRange([TcAutomation.ErrorListComRow[]]@([TcAutomation.ErrorListComReader]::Row('e1'), [TcAutomation.ErrorListComReader]::Row('e2')))
    $s.Warns.Add([TcAutomation.ErrorListComReader]::Row('w1'))
    $s.Msgs.Add([TcAutomation.ErrorListComReader]::Row('m1'))
    [TcAutomation.ErrorListComReader]::State = $s
    $script:st = $s
}
function Descs($rows) { (@($rows) | ForEach-Object { $_.Description }) -join ',' }

try {
    # --- K: the algorithm ---
    Reset-Fake
    $r = [TcAutomation.ErrorListComReader]::Read($null, 1, 5000, $null)
    Check 'K1 isolated read: errors e1,e2 / warnings w1 / messages m1, all-flags count 4' ($r.Ok -and (Descs $r.Errors) -eq 'e1,e2' -and (Descs $r.Warnings) -eq 'w1' -and (Descs $r.Messages) -eq 'm1' -and $r.AllCount -eq 4) (J @{ ok = $r.Ok; reason = $r.Reason })
    Check 'K1 the user flags (errors + messages, no warnings) are put back and reported' ($st.Flags[0] -and -not $st.Flags[1] -and $st.Flags[2] -and $r.FlagsRestored -and $r.FlagsChanged -and $r.FlagsBefore[0] -and -not $r.FlagsBefore[1]) (J $st.Flags)

    Reset-Fake -Lag 1
    $r = [TcAutomation.ErrorListComReader]::Read($null, 1, 5000, $null)
    Check 'K2 Count lags one read behind each flag change (S3): rows are NOT swapped between severities, the sum still matches' ($r.Ok -and (Descs $r.Errors) -eq 'e1,e2' -and (Descs $r.Warnings) -eq 'w1' -and (Descs $r.Messages) -eq 'm1' -and $r.AllCount -eq 4) ("e=$(Descs $r.Errors) w=$(Descs $r.Warnings) m=$(Descs $r.Messages) all=$($r.AllCount) $($r.Reason)")

    Reset-Fake
    $st.Exists = $false
    $r = [TcAutomation.ErrorListComReader]::Read($null, 1, 5000, $null)
    Check 'K3 Error List window does not exist (S7): errorlist-not-created, no flag was read or set, nothing to restore' (-not $r.Ok -and $r.Reason -eq 'errorlist-not-created' -and $st.SetCalls -eq 0 -and -not $r.FlagsChanged -and $r.FlagsRestored) (J @{ reason = $r.Reason; sets = $st.SetCalls })

    Reset-Fake
    $st.NeverZero = $true
    $r = [TcAutomation.ErrorListComReader]::Read($null, 1, 300, $null)
    Check 'K4 all-off never shows Count 0 (the flags do not reach the list): flags-not-effective, buttons back' (-not $r.Ok -and $r.Reason -eq 'flags-not-effective' -and $r.FlagsRestored -and $st.Flags[0] -and $st.Flags[2]) (J @{ reason = $r.Reason; flags = $st.Flags })

    Reset-Fake
    $r = [TcAutomation.ErrorListComReader]::Read($null, 1, 5000, [bool[]]@($false, $true, $false))
    Check 'K5 originalFlags passed in (a retry): FlagsBefore are those, and they are what is restored' ($r.Ok -and -not $r.FlagsBefore[0] -and $r.FlagsBefore[1] -and -not $st.Flags[0] -and $st.Flags[1] -and -not $st.Flags[2]) (J $st.Flags)

    # --- L: Read-TcErrorListCom with the real Invoke-TcComRetry ---
    & $mod { $script:TcDte = [PSCustomObject]@{ Version = '17.0' }; $script:TcIdeProcessId = $null; $script:TcComRetryDelayMs = 0; $script:TcErrorListComSettleMs = 1; $script:TcComCallDeadline = $null }
    Reset-Fake
    $st.BusyOnCount = 3
    $c = & $mod { Read-TcErrorListCom -MaxMs 5000 }
    Check 'L1 busy once, buttons restored: retried, the second attempt got the FIRST attempt flags (T,F,T), read ok' ($c.ok -and $st.Runs -eq 2 -and $st.Orig[0] -eq 'null' -and $st.Orig[1] -eq 'True,False,True' -and $c.flagsRestored -and $c.errors.Count -eq 2) (J @{ runs = $st.Runs; orig = $st.Orig; ok = $c.ok; reason = $c.reason })
    Check 'L1 the user flags are back after the retry' ($st.Flags[0] -and -not $st.Flags[1] -and $st.Flags[2]) (J $st.Flags)

    Reset-Fake
    $st.BusyOnCount = 3
    $st.FailSetsAfterBusy = $true
    $c = & $mod { Read-TcErrorListCom -MaxMs 5000 }
    Check 'L2 busy and the buttons could NOT be restored: no retry (one run), ok = $false, flagsRestored = $false is returned, not lost' (-not $c.ok -and $st.Runs -eq 1 -and -not $c.flagsRestored -and $c.flagsChanged -and $c.reason -eq 'com-error') (J @{ runs = $st.Runs; ok = $c.ok; restored = $c.flagsRestored; reason = $c.reason })
    $v = & $mod { param($x) Get-TcErrorListComVerdict -Com $x } $c
    Check 'L2 the verdict names it and carries flagsRestored $false up to the caller' (-not $v.accept -and $v.flagsRestored -eq $false -and $v.reason -match 'could not be set back') (J $v)

    Reset-Fake
    $st.Exists = $false
    $c = & $mod { Read-TcErrorListCom -MaxMs 5000 }
    Check 'L3 Error List not created: ok = $false, reason errorlist-not-created, a single run, no retry' (-not $c.ok -and $c.reason -eq 'errorlist-not-created' -and $st.Runs -eq 1) (J $c)

    # --- M: init failure is not forever (N5) ---
    $old = [DateTime]::UtcNow.AddSeconds(-120)
    & $mod { param($d) $script:TcErrorListComTypeState = [PSCustomObject]@{ ok = $false; reason = 'com-helper-unavailable: x'; at = $d; idePid = 4242 } } $old
    $s1 = & $mod { Initialize-TcErrorListComTypes -IdeProcessId 4242 }
    Check 'M1 a failure older than the retry interval is tried again (the type is loaded here, so it now succeeds)' ($s1.ok) (J $s1)
    $now = [DateTime]::UtcNow
    & $mod { param($d) $script:TcErrorListComTypeState = [PSCustomObject]@{ ok = $false; reason = 'com-helper-unavailable: x'; at = $d; idePid = 4242 } } $now
    $s2 = & $mod { Initialize-TcErrorListComTypes -IdeProcessId 4242 }
    Check 'M2 a fresh failure of the same IDE process is answered from the cache' (-not $s2.ok -and $s2.reason -match 'com-helper-unavailable') (J $s2)
    $s3 = & $mod { Initialize-TcErrorListComTypes -IdeProcessId 777 }
    Check 'M3 a fresh failure but another IDE process (other EnvDTE folder): tried again' ($s3.ok) (J $s3)
}
finally {
    Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
}
"failed: $fail"
exit [Math]::Min($fail, 255)
