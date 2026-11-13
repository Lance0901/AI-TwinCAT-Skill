function Invoke-TcLintProject {
    <#
    .SYNOPSIS
        Read-only semantic lint of a TwinCAT PLC project on disk (#252 Phase 1a / 1b): project file integrity (XML, GUID, Compile list, .tsproj references, encoding), ST parsing and machine-behaviour rules Build does not catch (stateful FB as temporary instance, PROGRAM never / twice called). Needs no IDE and no runtime.
    .DESCRIPTION
        Reads the .plcproj, every file its <Compile> items list, the .tsproj that references it and the
        .sln. Nothing is written, nothing is connected (no IDE, no ADS). The engine is C# compiled on the
        first call (Add-Type, about 1 s once per session).

        Rules of this version (openspec/changes/add-semantic-linter/rule-catalog.md section 1):
        PROJECT-XML-001..004, PROJECT-KIND-001, PROJECT-NAME-001/002, PROJECT-GUID-001..005,
        PROJECT-SUB-001/002, PROJECT-LINEIDS-001, PROJECT-COMPILE-001..006, PROJECT-LIB-001,
        PROJECT-TSPROJ-001..003, PROJECT-ENC-001, LINT-PARSE-001..003, LINT-XML-002; Phase 1b (section 2):
        SCAN-TEMPFB-001 (timer in METHOD VAR, FUNCTION VAR or VAR_TEMP: blocking, re-initialized on every call;
        trigger / counter / flip-flop: warning to dispose), PROJECT-TASK-001 (warning, must be disposed: PROGRAM
        body on no task and called by nobody), PROJECT-TASK-002 (blocking: PROGRAM certainly runs twice per
        cycle; possible double calls are warnings), LINT-SUPPRESS-001..004.
        Types are only judged from data.typeCatalog (versioned list + profile typeCatalog), never guessed.

        Disposition: requiresDisposition = true -> fix each data.unresolved[] entry or suppress it with
        "// tcauto-lint-disable-next-line <RULE-ID>: <reason>" (non-blocking rules only; a blocking rule needs
        the profile suppressions[]), and list every data.newSuppressions[] and data.newOverrides[] (profile
        weakenings) entry to the user, new against the git base (merge-base with upstream / origin default
        branch, else HEAD; newSuppressionsBasis = unavailable lists all); do not commit them before the user
        confirmed. No EnableConfig before that.

        data.passed = true does NOT mean the program is correct: only that the listed rules found no
        blocking finding in the analysed part (read data.coverage and data.unresolved with it).
        data: verdict (pass / fail / incomplete), passed (absent when nothing was analysed), source
        { kind = disk, plcProjectPath, solutionPath, tsprojPaths, ideChecked = false }, engine
        { version, sourceHash }, profile { name, source, sha256, overrides[] }, baseline, failOn, summary,
        diagnostics[] { ruleId, ruleVersion, severity, confidence, blocking, suppressed, machineImpact,
        blockableBasis (pending-measurement: XAE behaviour not measured yet, still blocking), file
        (relative to the .plcproj directory), objectPath, section, line, column, message, evidence,
        fixHint }, unresolved[] (machine-behaviour findings that must be fixed or suppressed),
        requiresDisposition, suppressions[] { source, kind, ruleIds, file, objectPath, line, reason, effective,
        matched }, newSuppressions[], newOverrides[] { kind, ruleId, objectPath, detail, reason, change },
        newSuppressionsBasis (git:merge-base:<ref> / git:head / unavailable / nothing-to-compare),
        newSuppressionsBase { kind, ref, commit }, dispositionReasons (unresolved, new-overrides),
        typeCatalog { version, sha256, stateful, typeOnly }, coverage { objectsInScope, objectsAnalyzed, notAnalyzed[], excluded[],
        rulesSkipped[], blockingRulesSkipped[], acceptedSkips[], rulesNotRun[] }, rulesRun[].

        Errors: LINT_FAILED (blocking finding), LINT_PARSE_FAILED (code or .plcproj cannot be parsed),
        LINT_INCOMPLETE (a default-blocking rule could not run, or a file could not be read),
        LINT_INPUT_INVALID, PLC_PROJECT_AMBIGUOUS / PLC_PROJECT_NOT_FOUND (-SolutionPath),
        LINT_PROFILE_INVALID, LINT_BASELINE_INVALID, LINT_ENGINE_ERROR, LINT_ENGINE_UNAVAILABLE;
        each with error.hint.
    .PARAMETER PlcProjectPath
        Path of the .plcproj file. With -SolutionPath: the PLC project name (or its .plcproj path). A PLC name without -SolutionPath needs the IDE and is not supported in this version (LINT_INPUT_INVALID).
    .PARAMETER SolutionPath
        A .sln or .tsproj; the .plcproj is found through Plc/Project@PrjFilePath of the .tsproj (no IDE needed).
    .PARAMETER Scope
        All (default) or Object: with Object only the objects in -ObjectPaths are checked (project-level rules still run). A pass with Scope=Object is not a pass of the whole project: run Scope=All before Reset-TcSolution / Build-TcProject (data.scope).
    .PARAMETER ObjectPaths
        Object names for -Scope Object (FB_X; FB_X.M_Run selects the object FB_X).
    .PARAMETER RuleProfile
        default (built-in), or the path of a tcauto-lint-profile/1 JSON file. Omitted: the first .tcauto\lint-profile.json from the .plcproj directory up to the solution directory, else default.
    .PARAMETER FailOn
        error (default) or warning: the lowest severity that blocks. Can only make the profile stricter.
    .PARAMETER IncludeTiming
        Add data.timing (milliseconds; the output is then no longer byte-identical between runs).
    .EXAMPLE
        Invoke-TcLintProject -PlcProjectPath C:\Temp\Verify-4026-axis\AxisInterface_Type01_Library\AxisInterface\AxisInterface.plcproj
    .EXAMPLE
        Invoke-TcLintProject -SolutionPath C:\Temp\Verify-4024-bfh\BFH-1650.sln -PlcProjectPath PLC1
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$PlcProjectPath,

        [Parameter()]
        [string]$SolutionPath,

        [Parameter()]
        [ValidateSet('All', 'Object')]
        [string]$Scope = 'All',

        [Parameter()]
        [string[]]$ObjectPaths,

        [Parameter()]
        [string]$RuleProfile,

        [Parameter()]
        [ValidateSet('error', 'warning')]
        [string]$FailOn,

        [Parameter()]
        [switch]$IncludeTiming
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $fail = {
        param($Code, $Message, $Data)
        New-TcResult -Success $false -ErrorCode $Code -ErrorMessage $Message -Hint (Get-TcErrorHint -Code $Code) -Data $Data
    }

    # 1. engine (design.md D4 order: engine availability first)
    $engine = Get-TcLintEngine
    if (-not $engine.ok) {
        $d = [ordered]@{ languageMode = $engine.languageMode }
        if ($engine.detail) { $d.engineDetail = $engine.detail }
        return (& $fail $engine.code $engine.message $d)
    }
    $compileMs = $sw.ElapsedMilliseconds
    $ns = $engine.Namespace
    $registry = "$ns.RuleRegistry" -as [type]

    # 2. inputs
    $plcFull = $null; $tsprojFull = $null; $slnFull = $null
    if ([string]::IsNullOrWhiteSpace($PlcProjectPath) -and [string]::IsNullOrWhiteSpace($SolutionPath)) {
        return (& $fail 'LINT_INPUT_INVALID' 'Give -PlcProjectPath <.plcproj file> or -SolutionPath <.sln / .tsproj>' $null)
    }
    if ($Scope -eq 'Object' -and @($ObjectPaths).Count -eq 0) { return (& $fail 'LINT_INPUT_INVALID' '-Scope Object needs -ObjectPaths' $null) }
    if ($Scope -ne 'Object' -and @($ObjectPaths).Count -gt 0) { return (& $fail 'LINT_INPUT_INVALID' '-ObjectPaths needs -Scope Object' $null) }
    if (-not [string]::IsNullOrWhiteSpace($SolutionPath)) {
        if (-not (Test-Path -LiteralPath $SolutionPath -PathType Leaf) -or $SolutionPath -notmatch '\.(sln|tsproj)$') {
            return (& $fail 'LINT_INPUT_INVALID' "-SolutionPath must be an existing .sln or .tsproj file: $SolutionPath" $null)
        }
        $solFull = (Resolve-Path -LiteralPath $SolutionPath).ProviderPath
        if ($solFull -match '\.sln$') { $slnFull = $solFull }
        $plcs = @(("$ns.LintEngine" -as [type])::ListPlcProjects($solFull))
        $list = @($plcs | ForEach-Object { [ordered]@{ name = $_['name']; plcProjectPath = $_['plcProjectPath']; tsprojPath = $_['tsprojPath']; exists = $_['exists']; error = $_['error'] } })
        $cands = $list
        if (-not [string]::IsNullOrWhiteSpace($PlcProjectPath)) {
            if ($PlcProjectPath -match '\.plcproj$') {
                $want = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($PlcProjectPath)
                $cands = @($list | Where-Object { $_.plcProjectPath -and [string]::Equals($_.plcProjectPath, $want, [System.StringComparison]::OrdinalIgnoreCase) })
            }
            else { $cands = @($list | Where-Object { [string]::Equals([string]$_.name, $PlcProjectPath, [System.StringComparison]::OrdinalIgnoreCase) }) }
        }
        if ($cands.Count -eq 0) {
            return (& $fail 'PLC_PROJECT_NOT_FOUND' "No PLC project '$PlcProjectPath' in $solFull" ([ordered]@{ plcProjects = $list }))
        }
        if ($cands.Count -gt 1) {
            return (& $fail 'PLC_PROJECT_AMBIGUOUS' "$solFull has $($cands.Count) PLC projects; select one with -PlcProjectPath <name>" ([ordered]@{ plcProjects = $cands }))
        }
        $sel = $cands[0]
        if (-not $sel.error -and [string]::IsNullOrEmpty($sel.plcProjectPath)) { $sel.error = 'no-prjfilepath' }
        if ($sel.error) { return (& $fail 'LINT_INPUT_INVALID' "PLC project '$($sel.name)' cannot be read from $($sel.tsprojPath): $($sel.error)" ([ordered]@{ plcProjects = $list })) }
        $plcFull = $sel.plcProjectPath
        $tsprojFull = $sel.tsprojPath
    }
    else {
        if ($PlcProjectPath -notmatch '\.plcproj$') {
            return (& $fail 'LINT_INPUT_INVALID' "-PlcProjectPath '$PlcProjectPath' is not a .plcproj file path. A PLC name needs the IDE to find the file, which this version does not do: give the .plcproj path, or -SolutionPath <sln> -PlcProjectPath <name>" $null)
        }
        if (-not (Test-Path -LiteralPath $PlcProjectPath -PathType Leaf)) {
            return (& $fail 'LINT_INPUT_INVALID' ".plcproj not found: $PlcProjectPath" $null)
        }
        $plcFull = (Resolve-Path -LiteralPath $PlcProjectPath).ProviderPath
    }

    # 3. stale check (XAE vs disk) is Phase 2: report it, never claim it was done
    # 4. profile, 5. baseline
    $prof = Resolve-TcLintProfile -PlcProjectFull $plcFull -RuleProfile $RuleProfile -RuleRegistry $registry
    if (-not $prof.ok) { return (& $fail $prof.code $prof.message ([ordered]@{ profilePath = $prof.profilePath })) }
    $base = Resolve-TcLintBaseline -ProfileResult $prof
    if (-not $base.ok) { return (& $fail $base.code $base.message ([ordered]@{ profile = $prof.profile })) }
    $effectiveFailOn = $prof.failOn
    if ($FailOn -eq 'warning') { $effectiveFailOn = 'warning' }   # the parameter can only be stricter

    # 6. analysis
    $opt = New-Object "$ns.LintOptions"
    $opt.PlcProjectPath = $plcFull
    $opt.SolutionPath = $slnFull
    $opt.TsprojPath = $tsprojFull
    $opt.FailOn = $effectiveFailOn
    $opt.MaxFileBytes = [long]$prof.maxFileSizeMB * 1MB
    if ($script:TcLintTestFault) { $opt.TestFault = $true }
    if ($Scope -eq 'Object') { foreach ($o in $ObjectPaths) { $opt.AddScopeObject($o) } }
    foreach ($r in $prof.rules) { $opt.AddRuleOverride($r.id, $r.enabled, [string]$r.severity, $r.blocking) }
    foreach ($e in $prof.excludes) { $opt.AddExclude($e.objectPath, $e.reason) }
    foreach ($e in $prof.suppressions) { $opt.AddSuppression($e.objectPath, $e.ruleId, $e.reason) }
    foreach ($e in $prof.acceptSkips) { $opt.AddAcceptSkip($e.objectPath, $e.ruleId, $e.reason) }
    # FB type catalog (tasks 1b.1): versioned library list + profile typeCatalog
    $cat = Get-TcLintTypeCatalog
    if (-not $cat.ok) { return (& $fail 'LINT_ENGINE_ERROR' 'The lint type catalog is missing or invalid; no result is reported' ([ordered]@{ engineDetail = $cat.message })) }
    foreach ($e in $cat.entries) { $opt.AddCatalogType($e.name, $e.library, $e.kind, $e.source, $e.class) }
    $profSrc = if ($prof.profile.path) { $prof.profile.path } else { 'profile' }
    foreach ($nme in @($prof.typeCatalog.stateful)) { $opt.AddCatalogType($nme, 'profile', 'stateful', $profSrc, 'profile') }
    foreach ($nme in @($prof.typeCatalog.functionBlocks)) { $opt.AddCatalogType($nme, 'profile', 'function-block', $profSrc, '') }
    $catInfo = $cat.info
    $catInfo['profileStateful'] = @($prof.typeCatalog.stateful).Count
    $catInfo['profileFunctionBlocks'] = @($prof.typeCatalog.functionBlocks).Count
    $analyzeStart = $sw.ElapsedMilliseconds
    try { $res = ("$ns.LintEngine" -as [type])::Run($opt) }
    catch {
        $inner = $_.Exception
        while ($null -ne $inner.InnerException) { $inner = $inner.InnerException }
        if ($inner -is [System.ArgumentException] -and $inner.Message -like 'SCOPE_OBJECT_NOT_FOUND:*') {
            return (& $fail 'LINT_INPUT_INVALID' "-ObjectPaths names an object that is not in the project: $($inner.Message.Substring(23))" $null)
        }
        return (& $fail 'LINT_ENGINE_ERROR' 'The lint engine failed; no result is reported' ([ordered]@{ engineDetail = "$($inner.GetType().FullName): $($inner.Message)" }))
    }

    # newSuppressions[] / newOverrides[]: against the git base (merge-base with upstream / origin default, else HEAD;
    # design.md D5, PR #283 review B1 / SF6); unavailable -> all listed (fail closed)
    $newSup = Get-TcLintNewItems -Suppressions @($res['suppressions']) -Overrides @($prof.profile.overrides) -PlcProjectFull $plcFull -ProfilePath $prof.profile.path -EngineType ("$ns.Suppressions" -as [type]) -RuleRegistry $registry
    $reasons = [System.Collections.Generic.List[string]]::new()
    if ([bool]$res['requiresDisposition']) { $reasons.Add('unresolved') }
    if (@($newSup.overrides).Count -gt 0) { $reasons.Add('new-overrides') }

    $source = [ordered]@{ kind = 'disk'; plcProjectPath = $res['source']['plcProjectPath']; solutionPath = $res['source']['solutionPath']
        tsprojPaths = @($res['source']['tsprojPaths']); ideChecked = $false }
    if ($script:TcIdeConnected) { $source.ideCheck = 'not-implemented: XAE editor / project state is not compared with the disk in this version (Phase 2); save in XAE before linting' }
    $verdict = [string]$res['verdict']
    $data = [ordered]@{
        verdict              = $verdict
        passed               = ($verdict -eq 'pass')
        contextLevel         = 'project'
        source               = $source
        engine               = [ordered]@{ version = ("$ns.LintEngine" -as [type])::EngineVersion; sourceHash = $engine.Hash }
        profile              = $prof.profile
        baseline             = $base.baseline
        failOn               = $effectiveFailOn
        summary              = $res['summary']
        diagnostics          = @($res['diagnostics'])
        unresolved           = @($res['unresolved'])
        requiresDisposition  = ($reasons.Count -gt 0)
        dispositionReasons   = @($reasons)
        scope                = $res['scope']
        suppressions         = @($res['suppressions'])
        newSuppressions      = @($newSup.suppressions)
        newOverrides         = @($newSup.overrides)
        newSuppressionsBasis = $newSup.basis
        newSuppressionsBase  = $newSup.base
        typeCatalog          = $catInfo
        coverage             = $res['coverage']
        rulesRun             = @($res['rulesRun'])
    }
    if ($newSup.reason) { $data.newSuppressionsBasisReason = $newSup.reason }
    if ($Scope -eq 'Object') { $data.scope['note'] = 'Scope=Object checks only these objects (plus the project files), not the whole project: run Scope=All before Reset-TcSolution / BuildProject' }
    if (@($res['engineDetail']).Count -gt 0) { $data.engineDetail = @($res['engineDetail']) }
    if ($IncludeTiming) { $data.timing = [ordered]@{ engineLoadMs = $compileMs; engineCompiled = [bool]$engine.compiled; analyzeMs = ($sw.ElapsedMilliseconds - $analyzeStart); totalMs = $sw.ElapsedMilliseconds } }

    $code = [string]$res['code']
    if ($verdict -eq 'pass') { return (New-TcResult -Success $true -Data $data) }
    $msg = switch ($code) {
        'LINT_PARSE_FAILED' { 'Lint could not parse part of the project (see LINT-PARSE-* / PROJECT-XML-001 in data.diagnostics)' }
        'LINT_INCOMPLETE' { 'Lint is incomplete: a default-blocking rule could not run on part of the project (data.coverage.blockingRulesSkipped / notAnalyzed)' }
        default { "Lint found $($res['summary']['blocking']) blocking finding(s)" }
    }
    return (& $fail $code $msg $data)
}
