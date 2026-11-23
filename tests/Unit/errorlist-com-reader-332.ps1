# Unit: the algorithm of the COM Error List read (ErrorListComCore.cs) and its PowerShell wrapper, driven with a FAKE source
# (no IDE, no EnvDTE assembly needed: only ErrorListComCore.cs is compiled), review #332 S1 / S3 / S7 / S9 / N5.
#   K  normal read: severities by flag, flags put back; a Count that lags one read behind the flag change does not swap rows (S3);
#      Error List window not created -> created hidden, read, hidden again (S7, Lance: hidden tab allowed); creation fails -> errorlist-create-failed;
#      hiding it again fails -> reported (hiddenRestored false), never faked; flags that never reach the list -> flags-not-effective
#   L  Read-TcErrorListCom: busy once, buttons restored -> retried with the FIRST attempt's flags; busy and buttons NOT restored -> no retry,
#      flagsRestored $false is returned (S1)
#   M  Initialize-TcErrorListComTypes: a failure is not cached for the whole process (N5)
#   N  PR #332 real-machine report items 2 / 5: flags are written only when they differ (fewer writes), rows read before a timeout are kept
#      (partial), the budget grows with the rows that are fetched, warnings / messages can be counted without fetching, ErrorLevel only on
#      request, the restore is proven by its own readback, the timing of every kind of call is reported
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
        public bool CreateFails;        // Create() cannot make the window
        public bool HideFails;          // RestoreHidden() cannot put it back
        public int CreateCalls;
        public int HideCalls;
        public int Lag;                 // Count() answers with the previous list this many times after a flag change
        public bool NeverZero;          // flags have no effect on the list
        public int BusyOnCount;         // the Count() call with this number (per Read call 1) throws RPC_E_CALL_REJECTED once
        public bool FailSetsAfterBusy;  // after that busy error every SetFlag throws RPC_E_CALL_REJECTED (the restore fails)
        public int Runs;
        public int SetCalls;
        public int RowDelayMs;          // every RowAt() takes this long (a slow IDE)
        public int RowCalls;
        public int LevelReads;
        public int IgnoreWritesAfter;   // after this many SetFlag calls the IDE silently ignores writes (a button that does not move)
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
        public bool Create(out string caption)
        {
            caption = "Error List"; st.CreateCalls++;
            if (st.CreateFails) return false;
            st.Exists = true; shown = Current(); return true;
        }
        public bool RestoreHidden() { st.HideCalls++; return !st.HideFails; }
        public bool GetFlag(int i) { return st.Flags[i]; }
        public void SetFlag(int i, bool v)
        {
            st.SetCalls++;
            if (st.FailSetsAfterBusy && st.BusyThrown) throw Busy();
            if (st.IgnoreWritesAfter > 0 && st.SetCalls > st.IgnoreWritesAfter) return;
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
        public ErrorListComRow RowAt(int i, bool withLevel)
        {
            st.RowCalls++;
            if (withLevel) st.LevelReads++;
            if (st.RowDelayMs > 0) System.Threading.Thread.Sleep(st.RowDelayMs);
            return shown[i - 1];
        }
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
        public static ErrorListComResult Read(object dte, ErrorListComOptions o, bool[] originalFlags)
        {
            State.Runs++;
            string x = "null";
            if (originalFlags != null) x = originalFlags[0] + "," + originalFlags[1] + "," + originalFlags[2];
            State.Orig.Add(x);
            using (var s = new FakeSource(State, State.Runs)) return ErrorListComCore.Run(s, o, originalFlags);
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
    Check 'K3 Error List window does not exist (S7): created, read normally (same rows, same isolation), flags back, created = true, hidden again' ($r.Ok -and $r.Created -and $r.HiddenRestored -and $st.CreateCalls -eq 1 -and $st.HideCalls -eq 1 -and (Descs $r.Errors) -eq 'e1,e2' -and (Descs $r.Warnings) -eq 'w1' -and (Descs $r.Messages) -eq 'm1' -and $r.AllCount -eq 4 -and $r.FlagsRestored -and $st.Flags[0] -and -not $st.Flags[1] -and $st.Flags[2]) (J @{ ok = $r.Ok; reason = $r.Reason; created = $r.Created; hidden = $r.HiddenRestored })
    Reset-Fake
    $r = [TcAutomation.ErrorListComReader]::Read($null, 1, 5000, $null)
    Check 'K3 window already there: not created, no hide attempt, hiddenRestored stays true' ($r.Ok -and -not $r.Created -and $r.HiddenRestored -and $st.CreateCalls -eq 0 -and $st.HideCalls -eq 0) (J @{ created = $r.Created; hide = $st.HideCalls })

    Reset-Fake
    $st.Exists = $false
    $st.CreateFails = $true
    $r = [TcAutomation.ErrorListComReader]::Read($null, 1, 5000, $null)
    Check 'K3b creation fails: errorlist-create-failed, no flag read or set, created = false (caller falls back to UIA)' (-not $r.Ok -and $r.Reason -eq 'errorlist-create-failed' -and -not $r.Created -and $st.SetCalls -eq 0 -and -not $r.FlagsChanged -and $r.FlagsRestored) (J @{ reason = $r.Reason; sets = $st.SetCalls; created = $r.Created })

    Reset-Fake
    $st.Exists = $false
    $st.HideFails = $true
    $r = [TcAutomation.ErrorListComReader]::Read($null, 1, 5000, $null)
    Check 'K3c created, read ok, hiding it again fails: data is still read, created = true, hiddenRestored = false (reported, not faked), 3 tries, flags still back' ($r.Ok -and $r.Created -and -not $r.HiddenRestored -and $st.HideCalls -eq 3 -and $r.FlagsRestored -and (Descs $r.Errors) -eq 'e1,e2') (J @{ ok = $r.Ok; created = $r.Created; hidden = $r.HiddenRestored; hideCalls = $st.HideCalls })

    Reset-Fake
    $st.Exists = $false
    $st.NeverZero = $true
    $r = [TcAutomation.ErrorListComReader]::Read($null, 1, 300, $null)
    Check 'K3d created window gets the same defences: flags never reach the list -> flags-not-effective, flags back, hidden again' (-not $r.Ok -and $r.Reason -eq 'flags-not-effective' -and $r.Created -and $r.HiddenRestored -and $r.FlagsRestored -and $st.HideCalls -eq 1) (J @{ reason = $r.Reason; created = $r.Created; hidden = $r.HiddenRestored })

    Reset-Fake
    $st.NeverZero = $true
    $r = [TcAutomation.ErrorListComReader]::Read($null, 1, 300, $null)
    Check 'K4 all-off never shows Count 0 (the flags do not reach the list): flags-not-effective, buttons back' (-not $r.Ok -and $r.Reason -eq 'flags-not-effective' -and $r.FlagsRestored -and $st.Flags[0] -and $st.Flags[2]) (J @{ reason = $r.Reason; flags = $st.Flags })

    Reset-Fake
    $r = [TcAutomation.ErrorListComReader]::Read($null, 1, 5000, [bool[]]@($false, $true, $false))
    Check 'K5 originalFlags passed in (a retry): FlagsBefore are those, and they are what is restored' ($r.Ok -and -not $r.FlagsBefore[0] -and $r.FlagsBefore[1] -and -not $st.Flags[0] -and $st.Flags[1] -and -not $st.Flags[2]) (J $st.Flags)

    # --- N: speed, partial, restore proof (PR #332 real-machine report items 2 / 5) ---
    Reset-Fake
    $r = [TcAutomation.ErrorListComReader]::Read($null, 1, 5000, $null)
    Check 'N1 flags are written only when they differ: a normal read of (T,F,T) needs 10 writes (the first version wrote about 27)' ($r.Ok -and $st.SetCalls -eq 10) "sets=$($st.SetCalls)"
    Check 'N1 the restore is read back: FlagsAfter equals FlagsBefore, FlagsMatchBefore, no note' ($r.FlagsRestored -and $r.FlagsMatchBefore -and $r.FlagsAfter[0] -and -not $r.FlagsAfter[1] -and $r.FlagsAfter[2] -and [string]::IsNullOrEmpty($r.RestoreNote)) (J @{ after = $r.FlagsAfter; note = $r.RestoreNote })
    Check 'N1 counts: errors 2 / warnings 1 / messages 1, all complete, not partial' ($r.ErrorCount -eq 2 -and $r.WarningCount -eq 1 -and $r.MessageCount -eq 1 -and $r.ErrorsComplete -and $r.WarningsComplete -and $r.MessagesComplete -and -not $r.Partial) (J @{ e = $r.ErrorCount; w = $r.WarningCount; m = $r.MessageCount })
    Check 'N2 the timing text names every kind of call (flagSets / counts / rows / sleeps)' ($r.Timing -match 'flagSets=10 ' -and $r.Timing -match 'counts=\d+' -and $r.Timing -match 'rows=4 ' -and $r.Timing -match 'sleeps=\d+') $r.Timing

    Reset-Fake
    $st.IgnoreWritesAfter = 9
    $r = [TcAutomation.ErrorListComReader]::Read($null, 1, 5000, $null)
    Check 'N3 the IDE ignores the restore writes (no error thrown): FlagsRestored = $false from the readback, FlagsAfter shows what the buttons say, a note names before / after' ($r.Ok -and -not $r.FlagsRestored -and -not $r.FlagsMatchBefore -and $r.FlagsAfter[1] -and $r.RestoreNote -match 'before the read = True/False/True' -and $r.RestoreNote -match 'after the restore = True/True/True') (J @{ restored = $r.FlagsRestored; after = $r.FlagsAfter; note = $r.RestoreNote })

    Reset-Fake
    $o = New-Object TcAutomation.ErrorListComOptions
    $o.SettleMs = 1; $o.MaxMs = 5000; $o.FetchWarnings = $false; $o.FetchMessages = $false; $o.ReadLevel = $false
    $r = [TcAutomation.ErrorListComReader]::Read($null, $o, $null)
    Check 'N4 warnings / messages only counted: no rows fetched for them, the counts are there and the sum still equals the all-flags count' ($r.Ok -and $r.Warnings.Count -eq 0 -and $r.Messages.Count -eq 0 -and $r.WarningCount -eq 1 -and $r.MessageCount -eq 1 -and $r.AllCount -eq 4 -and $st.RowCalls -eq 2) (J @{ rowCalls = $st.RowCalls; all = $r.AllCount })
    Check 'N4 ReadLevel = false: ErrorLevel is never read' ($st.LevelReads -eq 0) "levelReads=$($st.LevelReads)"
    Reset-Fake
    $r = [TcAutomation.ErrorListComReader]::Read($null, 1, 5000, $null)
    Check 'N4 ReadLevel (default true): one level read per fetched row' ($st.LevelReads -eq 4 -and $st.RowCalls -eq 4) "levelReads=$($st.LevelReads)"

    # slow rows: 60 errors at 4 ms each = 240 ms of row time against a fixed budget of 80 ms
    function Reset-Slow {
        Reset-Fake
        $st.Errs.Clear()
        for ($i = 1; $i -le 60; $i++) { $st.Errs.Add([TcAutomation.ErrorListComReader]::Row("slow$i")) }
        $st.RowDelayMs = 4
    }
    Reset-Slow
    $o = New-Object TcAutomation.ErrorListComOptions
    $o.SettleMs = 1; $o.MaxMs = 80
    $r = [TcAutomation.ErrorListComReader]::Read($null, $o, $null)
    Check 'N5 the budget runs out in the middle of the rows: not ok, reason timeout, the rows read so far are KEPT (partial), errors not complete, buttons back' (-not $r.Ok -and $r.Reason -eq 'timeout' -and $r.Partial -and $r.Errors.Count -gt 0 -and $r.Errors.Count -lt 60 -and -not $r.ErrorsComplete -and $r.FlagsRestored) (J @{ ok = $r.Ok; reason = $r.Reason; partial = $r.Partial; rows = $r.Errors.Count })
    Check 'N5 the count that was reached is reported (60 errors expected), the others were not reached (-1)' ($r.ErrorCount -eq -1 -or $r.ErrorCount -eq 60) "errorCount=$($r.ErrorCount)"
    Reset-Slow
    $o = New-Object TcAutomation.ErrorListComOptions
    $o.SettleMs = 1; $o.MaxMs = 80; $o.CapMs = 3000; $o.PerRowMs = 15
    $r = [TcAutomation.ErrorListComReader]::Read($null, $o, $null)
    Check 'N6 the same list with a cap: every fetched row adds its time (15 ms each) to the budget, all 60 rows are read' ($r.Ok -and $r.Errors.Count -eq 60 -and $r.ErrorsComplete -and -not $r.Partial -and $r.BudgetMs -gt 80) (J @{ ok = $r.Ok; reason = $r.Reason; rows = $r.Errors.Count; budget = $r.BudgetMs })
    Reset-Slow
    $o = New-Object TcAutomation.ErrorListComOptions
    $o.SettleMs = 1; $o.MaxMs = 80; $o.CapMs = 120; $o.PerRowMs = 15
    $r = [TcAutomation.ErrorListComReader]::Read($null, $o, $null)
    Check 'N6 the cap is hard: 120 ms is not enough for 240 ms of rows -> timeout, partial, budget never above the cap' (-not $r.Ok -and $r.Reason -eq 'timeout' -and $r.Partial -and $r.BudgetMs -le 120) (J @{ reason = $r.Reason; budget = $r.BudgetMs; rows = $r.Errors.Count })

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

    Reset-Slow
    $c = & $mod { Read-TcErrorListCom -MaxMs 80 }
    Check 'L6 Read-TcErrorListCom: a read that runs out of time returns the rows read (partial = $true, 1..59 rows), reason timeout, buttons restored' (-not $c.ok -and $c.partial -and $c.reason -eq 'timeout' -and $c.errors.Count -gt 0 -and $c.errors.Count -lt 60 -and $c.flagsRestored -and -not $c.errorsComplete) (J @{ ok = $c.ok; partial = $c.partial; rows = $c.errors.Count; reason = $c.reason })
    Reset-Slow
    $c = & $mod { Read-TcErrorListCom -MaxMs 80 -CapMs 3000 }
    Check 'L6 the same read with -CapMs: all 60 rows, ok, budgetMs above the fixed 80, timing reported' ($c.ok -and $c.errors.Count -eq 60 -and $c.budgetMs -gt 80 -and $c.timing -match 'flagSets=') (J @{ ok = $c.ok; rows = $c.errors.Count; budget = $c.budgetMs })
    Reset-Fake
    $c = & $mod { Read-TcErrorListCom -MaxMs 5000 -FetchWarnings $false -FetchMessages $false -ReadLevel $false }
    Check 'L7 -FetchWarnings / -FetchMessages $false: counted (1 / 1), not fetched (0 rows), errors fetched (2)' ($c.ok -and $c.warningCount -eq 1 -and $c.messageCount -eq 1 -and $c.warnings.Count -eq 0 -and $c.messages.Count -eq 0 -and $c.errors.Count -eq 2) (J @{ w = $c.warningCount; m = $c.messageCount })

    Reset-Fake
    $st.Exists = $false
    $st.CreateFails = $true
    $c = & $mod { Read-TcErrorListCom -MaxMs 5000 }
    Check 'L3 Error List not created and cannot be: ok = $false, reason errorlist-create-failed, a single run, no retry, created = false' (-not $c.ok -and $c.reason -eq 'errorlist-create-failed' -and $st.Runs -eq 1 -and -not $c.created) (J $c)

    Reset-Fake
    $st.Exists = $false
    $st.BusyOnCount = 3
    $c = & $mod { Read-TcErrorListCom -MaxMs 5000 }
    Check 'L4 created by attempt 1, busy, retried: attempt 2 finds the (hidden again) window, the result still says created = true, hiddenRestored = true' ($c.ok -and $st.Runs -eq 2 -and $c.created -and $c.hiddenRestored -and $st.CreateCalls -eq 1) (J @{ runs = $st.Runs; created = $c.created; hidden = $c.hiddenRestored; ok = $c.ok; reason = $c.reason })

    Reset-Fake
    $st.Exists = $false
    $st.HideFails = $true
    $c = & $mod { Read-TcErrorListCom -MaxMs 5000 }
    Check 'L5 created, hiding fails: Read-TcErrorListCom carries created = true, hiddenRestored = false' ($c.ok -and $c.created -and -not $c.hiddenRestored) (J @{ created = $c.created; hidden = $c.hiddenRestored })
    $v = & $mod { param($x) Get-TcErrorListComVerdict -Com $x -ErrorRows 2 -IsolatedTotal 4 } $c
    Check 'L5 verdict accepts the data (the read is sound) and names the visible window in notes' ($v.accept -and (@($v.notes) -join ' ') -match 'could not be set back to hidden') (J $v)

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
