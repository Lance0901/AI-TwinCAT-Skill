# Semantic linter (#252 tasks 1b.1 / 1b.6): the versioned FB type catalog (TypeCatalog.json) and the base for
# newSuppressions[] / newOverrides[] (design.md D5, PR #283 review B1 / SF6). The base is the merge-base with the
# origin default branch (or the upstream branch when no default branch is known), so a suppression or profile change the agent commits itself is still
# new; only without any remote ref HEAD is used. Read-only git commands only, one overall deadline. When git or the
# base cannot be read, everything is reported as new (fail closed: the user sees all of it).

$script:TcLintTypeCatalogSchema = 'tcauto-lint-type-catalog/1'
$script:TcLintGitExe = $null        # test seam: another executable simulates "git not available / hanging"
$script:TcLintGitResolved = $null   # full path of git.exe, resolved once (not CreateProcess' search order)
$script:TcLintGitBudgetMs = 20000   # all git calls of one lint run together (one deadline, not per call)

function Get-TcLintTypeCatalog {
    <#
    .SYNOPSIS
        Reads Private/Lint/TypeCatalog.json. Returns @{ ok; message; entries (name, library, kind, class, source); info (data.typeCatalog) }.
    #>
    [CmdletBinding()]
    param()
    $path = Join-Path $PSScriptRoot 'TypeCatalog.json'
    $j = Read-TcLintJson -Path $path
    if (-not $j.ok) { return @{ ok = $false; message = "Type catalog $path is not readable: $($j.error)" } }
    $v = $j.value
    if ($v.schema -ne $script:TcLintTypeCatalogSchema -or $v.version -isnot [int]) { return @{ ok = $false; message = "Type catalog $path has no valid schema / version" } }
    $entries = [System.Collections.Generic.List[object]]::new()
    $stateful = 0; $typeOnly = 0
    foreach ($lib in @($v.libraries)) {
        foreach ($k in @(@('stateful', 'stateful'), @('typeOnly', 'type-only'))) {
            foreach ($e in @($lib.($k[0]))) {
                if ($null -eq $e) { continue }
                if ($e.name -isnot [string] -or $e.source -isnot [string] -or $e.source -notlike 'https://infosys.beckhoff.com/*') {
                    return @{ ok = $false; message = "Type catalog $path entry of $($lib.name) has no name or no InfoSys source" }
                }
                if ($k[1] -eq 'stateful' -and @('timer', 'edge', 'counter', 'bistable') -cnotcontains $e.class) {
                    return @{ ok = $false; message = "Type catalog $path entry $($e.name) has no class (timer / edge / counter / bistable)" }
                }
                $entries.Add(@{ name = $e.name; library = [string]$lib.name; kind = $k[1]; class = [string]$e.class; source = $e.source })
                if ($k[1] -eq 'stateful') { $stateful++ } else { $typeOnly++ }
            }
        }
    }
    return @{ ok = $true; entries = $entries.ToArray()
        info = [ordered]@{ schema = $v.schema; version = $v.version; sha256 = (Get-TcLintFileSha256 -Path $path); stateful = $stateful; typeOnly = $typeOnly } }
}

function Get-TcLintGitExe {
    # the full path of git.exe found once through PATH (applications only); the test seam wins
    if ($script:TcLintGitExe) { return $script:TcLintGitExe }
    if (-not $script:TcLintGitResolved) {
        $c = Get-Command -Name git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($c) { $script:TcLintGitResolved = $c.Source }
    }
    return $script:TcLintGitResolved
}

function Invoke-TcLintGit {
    <#
    .SYNOPSIS
        Runs a read-only git command within the remaining budget. Returns @{ ok; exit; out; timedOut } (stdout as UTF-8). Never throws.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkDir, [Parameter(Mandatory)][string[]]$GitArgs, [Parameter(Mandatory)][System.Diagnostics.Stopwatch]$Clock)
    $left = $script:TcLintGitBudgetMs - $Clock.ElapsedMilliseconds
    if ($left -le 0) { return @{ ok = $false; exit = -1; out = ''; timedOut = $true } }
    $exe = Get-TcLintGitExe
    if (-not $exe) { return @{ ok = $false; exit = -1; out = ''; timedOut = $false } }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = (($GitArgs | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' ')
        $psi.WorkingDirectory = $WorkDir
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $psi.EnvironmentVariables['GIT_OPTIONAL_LOCKS'] = '0'   # read-only: no index refresh
        $p = [System.Diagnostics.Process]::Start($psi)
        # both streams async, then the deadline (ReadToEnd would block until git exits)
        $errTask = $p.StandardError.ReadToEndAsync()
        $outTask = $p.StandardOutput.ReadToEndAsync()
        if (-not $p.WaitForExit([int][Math]::Max(1, $left))) { try { $p.Kill() } catch { $null = $_ }; return @{ ok = $false; exit = -1; out = ''; timedOut = $true } }
        $p.WaitForExit()
        $null = $errTask.Result
        return @{ ok = ($p.ExitCode -eq 0); exit = $p.ExitCode; out = $outTask.Result; timedOut = $false }
    }
    catch { return @{ ok = $false; exit = -1; out = ''; timedOut = $false } }
}

function Get-TcLintDiskSpelling {
    <#
    .SYNOPSIS
        The path with the upper / lower case the file system has (git <rev>:<path> is case-sensitive).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    $cur = $root.ToUpperInvariant()
    foreach ($part in ($full.Substring($root.Length) -split '\\' | Where-Object { $_ -ne '' })) {
        $hit = $null
        try { $hit = @([System.IO.Directory]::GetFileSystemEntries($cur, $part)) | Select-Object -First 1 } catch { $hit = $null }
        if ($hit) { $cur = $hit } else { $cur = Join-Path $cur $part }
    }
    return $cur
}

function Resolve-TcLintGitBase {
    <#
    .SYNOPSIS
        Finds the base commit: merge-base with the origin default branch (origin/HEAD, origin/master, origin/main), else with
        @{upstream}, else HEAD. Returns @{ ok; reason; top; commit; kind; ref; basis }.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][System.Diagnostics.Stopwatch]$Clock)
    $no = { param($why) return @{ ok = $false; reason = $why } }
    $top = Invoke-TcLintGit -WorkDir $Dir -GitArgs @('rev-parse', '--show-toplevel') -Clock $Clock
    if ($top.timedOut) { return (& $no 'git did not answer within the deadline') }
    if (-not $top.ok) { return (& $no 'not a git repository, or git is not available') }
    $topDir = Get-TcLintDiskSpelling -Path ($top.out.Trim() -replace '/', '\')
    # origin default branch first (review N1: after `git push -u` the agent's own branch is @{upstream} and would hide its
    # own commits), then @{upstream} (no default branch known), then HEAD
    $ref = $null; $kind = $null
    $oh = Invoke-TcLintGit -WorkDir $topDir -GitArgs @('rev-parse', '--abbrev-ref', 'origin/HEAD') -Clock $Clock
    if ($oh.timedOut) { return (& $no 'git did not answer within the deadline') }
    if ($oh.ok -and $oh.out.Trim() -and $oh.out.Trim() -ne 'origin/HEAD') { $ref = $oh.out.Trim(); $kind = 'origin-default' }
    if (-not $ref) {
        foreach ($cand in 'origin/master', 'origin/main') {
            $c = Invoke-TcLintGit -WorkDir $topDir -GitArgs @('rev-parse', '--verify', '--quiet', "refs/remotes/$cand") -Clock $Clock
            if ($c.timedOut) { return (& $no 'git did not answer within the deadline') }
            if ($c.ok) { $ref = $cand; $kind = 'origin-default'; break }
        }
    }
    if (-not $ref) {
        $up = Invoke-TcLintGit -WorkDir $topDir -GitArgs @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}') -Clock $Clock
        if ($up.timedOut) { return (& $no 'git did not answer within the deadline') }
        if ($up.ok -and $up.out.Trim()) { $ref = $up.out.Trim(); $kind = 'upstream' }
    }
    if ($ref) {
        $mb = Invoke-TcLintGit -WorkDir $topDir -GitArgs @('merge-base', 'HEAD', $ref) -Clock $Clock
        if ($mb.timedOut) { return (& $no 'git did not answer within the deadline') }
        if (-not $mb.ok) { return (& $no "no merge-base of HEAD and $ref") }
        return @{ ok = $true; top = $topDir; commit = $mb.out.Trim(); kind = $kind; ref = $ref; basis = "git:merge-base:$ref" }
    }
    $head = Invoke-TcLintGit -WorkDir $topDir -GitArgs @('rev-parse', '--verify', '--quiet', 'HEAD') -Clock $Clock
    if ($head.timedOut) { return (& $no 'git did not answer within the deadline') }
    if (-not $head.ok) { return (& $no 'the repository has no commit') }
    return @{ ok = $true; top = $topDir; commit = $head.out.Trim(); kind = 'head'; ref = 'HEAD'; basis = 'git:head' }
}

function Get-TcLintOverrideKey($o) { return "$($o.kind)|$($o.ruleId)|$($o.objectPath)" }

function Get-TcLintNewItems {
    <#
    .SYNOPSIS
        newSuppressions[] and newOverrides[] against the git base. Returns @{ basis; reason; base; suppressions; overrides }.
    .PARAMETER Suppressions
        data.suppressions of the engine (inline and profile entries, each with a key).
    .PARAMETER Overrides
        data.profile.overrides (every setting weaker than the default profile).
    .PARAMETER PlcProjectFull
        The .plcproj (its directory is where the repository is searched).
    .PARAMETER ProfilePath
        The profile file in use, or $null for the built-in profile.
    .PARAMETER EngineType
        The engine's Suppressions type (KeysInObjectText uses the same directive parser as the engine).
    .PARAMETER RuleRegistry
        The engine RuleRegistry type (to read the base profile with the same validation).
    #>
    [CmdletBinding()]
    param([object[]]$Suppressions, [object[]]$Overrides, [Parameter(Mandatory)][string]$PlcProjectFull, [string]$ProfilePath,
        [Parameter(Mandatory)]$EngineType, [Parameter(Mandatory)]$RuleRegistry)
    $sup = @($Suppressions)
    # profile suppressions are already in newSuppressions[]; every other weakening goes to newOverrides[]
    $ovs = @($Overrides | Where-Object { $_.kind -ne 'suppression' })
    # item: kind, ruleId / objectPath, detail (what is weakened), reason, change = added / modified against the base
    $asNew = { param($o, $change) $x = [ordered]@{}; foreach ($k in $o.Keys) { if ($k -eq 'change') { $x['detail'] = $o[$k] } else { $x[$k] = $o[$k] } }; $x['change'] = $change; return $x }
    $allNew = {
        param($basis, $why)
        return @{ basis = $basis; reason = $why; base = $null; suppressions = $sup; overrides = @($ovs | ForEach-Object { & $asNew $_ 'added' }) }
    }
    if ($sup.Count -eq 0 -and $ovs.Count -eq 0) { return @{ basis = 'nothing-to-compare'; reason = $null; base = $null; suppressions = @(); overrides = @() } }
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $plcDir = [System.IO.Path]::GetDirectoryName($PlcProjectFull)
    $b = Resolve-TcLintGitBase -Dir $plcDir -Clock $clock
    if (-not $b.ok) { return (& $allNew 'unavailable' "$($b.reason): every suppression and profile override is listed as new") }
    $base = [ordered]@{ kind = $b.kind; ref = $b.ref; commit = $b.commit }
    $relOf = {
        param($full)
        $f = Get-TcLintDiskSpelling -Path $full
        $t = $b.top.TrimEnd('\') + '\'
        if (-not $f.StartsWith($t, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
        return ($f.Substring($t.Length) -replace '\\', '/')
    }
    # file text at the base: @{ found; text } ; a timeout anywhere makes the whole result unavailable
    $timedOut = $false
    $show = {
        param($rel)
        $g = Invoke-TcLintGit -WorkDir $b.top -GitArgs @('show', "$($b.commit):$rel") -Clock $clock
        if ($g.timedOut) { $script:__tcLintTimedOut = $true }
        return @{ found = $g.ok; text = $g.out }
    }
    $script:__tcLintTimedOut = $false

    # ---- suppressions
    $counts = @{}
    $newSup = [System.Collections.Generic.List[object]]::new()
    $profileBase = $null; $profileBaseRead = $false
    foreach ($s in $sup) {
        $c = $null
        if ($s.source -eq 'inline') {
            $rel = & $relOf (Join-Path $plcDir ($s.file -replace '/', '\'))
            if ($rel) {
                if (-not $counts.ContainsKey($rel)) {
                    $r = & $show $rel
                    $keys = if ($r.found) { $EngineType::KeysInObjectText($r.text) } else { $null }
                    $m = $null
                    if ($null -ne $keys) { $m = @{}; foreach ($k in $keys) { if ($m.ContainsKey($k)) { $m[$k]++ } else { $m[$k] = 1 } } }
                    $counts[$rel] = $m
                }
                $c = $counts[$rel]
            }
        }
        elseif ($ProfilePath) {
            if (-not $profileBaseRead) {
                $profileBaseRead = $true
                $rel = & $relOf $ProfilePath
                if ($rel) { $r = & $show $rel; if ($r.found) { $profileBase = $r.text } }
            }
            if ($null -ne $profileBase) {
                if (-not $counts.ContainsKey('profile:')) {
                    $m = @{}
                    try {
                        foreach ($e in @(($profileBase | ConvertFrom-Json -ErrorAction Stop).suppressions)) {
                            if ($null -eq $e) { continue }
                            $k = "profile|$($e.objectPath)|$($e.ruleId)|$($e.reason)"
                            if ($m.ContainsKey($k)) { $m[$k]++ } else { $m[$k] = 1 }
                        }
                    }
                    catch { $m = $null }
                    $counts['profile:'] = $m
                }
                $c = $counts['profile:']
            }
        }
        if ($null -ne $c -and $c.ContainsKey($s.key) -and $c[$s.key] -gt 0) { $c[$s.key]--; continue }
        $newSup.Add($s)
    }

    # ---- profile overrides (B1): the base profile is read with the same validation as the current one
    $newOv = [System.Collections.Generic.List[object]]::new()
    if ($ovs.Count -gt 0) {
        $baseOv = $null
        if ($ProfilePath -and -not $profileBaseRead) {
            $profileBaseRead = $true
            $rel = & $relOf $ProfilePath
            if ($rel) { $r = & $show $rel; if ($r.found) { $profileBase = $r.text } }
        }
        if ($null -ne $profileBase) {
            $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ('tcauto-lint-base-' + [guid]::NewGuid().ToString('N'))
            try {
                New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
                $tmp = Join-Path $tmpDir 'lint-profile.json'
                [System.IO.File]::WriteAllText($tmp, $profileBase, (New-Object System.Text.UTF8Encoding($false)))
                $bp = Resolve-TcLintProfile -PlcProjectFull $PlcProjectFull -RuleProfile $tmp -RuleRegistry $RuleRegistry
                if ($bp.ok) { $baseOv = @($bp.profile.overrides) }   # an invalid base profile: everything counts as new
            }
            finally { Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
        }
        $byKey = @{}
        foreach ($o in @($baseOv)) { if ($null -ne $o) { $byKey[(Get-TcLintOverrideKey $o)] = $o } }
        foreach ($o in $ovs) {
            $k = Get-TcLintOverrideKey $o
            if ($null -eq $baseOv -or -not $byKey.ContainsKey($k)) { $newOv.Add((& $asNew $o 'added')); continue }
            $old = $byKey[$k]
            if ([string]$old.change -ne [string]$o.change -or [string]$old.reason -ne [string]$o.reason -or [string]$old.path -ne [string]$o.path) { $newOv.Add((& $asNew $o 'modified')) }
        }
    }
    if ($script:__tcLintTimedOut) { return (& $allNew 'unavailable' 'git did not answer within the deadline: every suppression and profile override is listed as new') }
    return @{ basis = $b.basis; reason = $null; base = $base; suppressions = $newSup.ToArray(); overrides = $newOv.ToArray() }
}
