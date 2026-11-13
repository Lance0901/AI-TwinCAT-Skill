function Invoke-TcLintCandidate {
    <#
    .SYNOPSIS
        Read-only semantic lint of a PLC object BEFORE it is written (#252 Phase 2a): the candidate Declaration / Implementation laid over the .plcproj on disk in memory (same name replaced, new object added), or checked alone. Needs no IDE and no runtime; nothing is written.
    .DESCRIPTION
        Same engine, rules, profile and output as Invoke-TcLintProject, scoped to the candidate object (like
        LintProject -Scope Object: findings of other objects are not reported; project-level rules still run).
        Workflow: LintCandidate -> WritePouCode -> BuildProject -> LintProject (a pass here is not a pass of the
        project: other objects and cross-object effects are checked by LintProject after writing).

        -PlcProjectPath <.plcproj>: overlay on the disk project (contextLevel = project). A PLC name, or no path
        while the IDE is connected, needs the IDE and is not supported in this version (LINT_INPUT_INVALID).
        Without -PlcProjectPath: text-only (contextLevel = text-only, default profile): a candidate that needs
        the project (EXTENDS / IMPLEMENTS, Method / Property / Action, a type or identifier not declared in it
        and not elementary / standard / in the type catalog) -> LINT_CONTEXT_REQUIRED (verdict incomplete; the
        rules that need no context still ran, data.candidate.contextRequired says why). Never a silent pass.

        Overlay boundaries -> LINT_INPUT_INVALID: declaration keyword or name differs from -ObjectKind /
        -ObjectName; an object of that name is another kind on disk; the Parent of a Method / Property / Action
        does not exist; Transition (XML structure never observed); an implementation for a DUT / GVL / Interface
        / property declaration; a declaration for an Action; Implementation that is not ST.

        Rules of this version: as Invoke-TcLintProject plus SCAN-LOOP-001 (busy-wait), SCAN-FOR-001 (FOR end value
        at the counter type limit), SCAN-ARR-001 (constant FOR range outside the array bounds), SAFETY-ARR-001
        (constant index out of bounds; the compiler also rejects it, value only before writing), SAFETY-DIV-001
        (division / MOD by constant zero; unchecked variable divisor as info). A new object is not in <Compile>:
        PROJECT-COMPILE-001 is skipped (coverage.rulesSkipped candidate-not-in-project).

        Disposition: requiresDisposition = true -> fix each data.unresolved[] entry or suppress it inline with a
        reason (non-blocking rules only), and list every data.newSuppressions[] (new against the disk version of
        the object) and data.newOverrides[] entry to the user before writing. Do not call EnableConfig.

        data: as Invoke-TcLintProject, plus contextLevel (project / text-only), candidate { objectKind,
        objectPath, file, overlay (replaced / added / text-only), contextRequired[] }, newSuppressionsBasis
        (candidate-vs-disk / candidate-text-only), newOverridesBasis.

        Errors: LINT_FAILED, LINT_PARSE_FAILED, LINT_CONTEXT_REQUIRED, LINT_INCOMPLETE, LINT_INPUT_INVALID,
        LINT_PROFILE_INVALID, LINT_BASELINE_INVALID, LINT_ENGINE_ERROR, LINT_ENGINE_UNAVAILABLE; each with error.hint.
    .PARAMETER ObjectKind
        Program, FunctionBlock, Function, DUT, GVL, Interface, Method, Property or Action.
    .PARAMETER ObjectName
        Object name; Method / Property / Action as Parent.Member (Write-TcPouCode -PouName format); a property accessor as Parent.Property.Get / .Set.
    .PARAMETER Declaration
        Declaration text (empty for an Action; for an accessor the accessor declaration, may be empty).
    .PARAMETER Implementation
        Structured Text implementation (empty for DUT / GVL / Interface / property declaration).
    .PARAMETER PlcProjectPath
        Path of the .plcproj to lay the candidate over. Omitted: text-only.
    .PARAMETER RuleProfile
        default (built-in), or the path of a tcauto-lint-profile/1 JSON file. Omitted: discovered from the .plcproj directory (text-only: default).
    .PARAMETER FailOn
        error (default) or warning: the lowest severity that blocks. Can only make the profile stricter.
    .PARAMETER Baseline
        Path of a tcauto-lint-baseline/1 file (instead of the discovered one); validated, used by CONTRACT-* rules (Phase 4, not run in this version).
    .PARAMETER IncludeTiming
        Add data.timing (the output is then no longer byte-identical between runs).
    .EXAMPLE
        Invoke-TcLintCandidate -ObjectKind Method -ObjectName FB_Axis.M_Home -Declaration $decl -Implementation $code -PlcProjectPath C:\Temp\Verify-4026-axis\AxisInterface_Type01_Library\AxisInterface\AxisInterface.plcproj
    .EXAMPLE
        Invoke-TcLintCandidate -ObjectKind Function -ObjectName F_Scale -Declaration $decl -Implementation $code
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateSet('Program', 'FunctionBlock', 'Function', 'DUT', 'GVL', 'Interface', 'Method', 'Property', 'Action', 'Transition')]
        [string]$ObjectKind,

        [Parameter()]
        [string]$ObjectName,

        [Parameter()]
        [AllowEmptyString()]
        [string]$Declaration = '',

        [Parameter()]
        [AllowEmptyString()]
        [string]$Implementation = '',

        [Parameter()]
        [string]$PlcProjectPath,

        [Parameter()]
        [string]$RuleProfile,

        [Parameter()]
        [ValidateSet('error', 'warning')]
        [string]$FailOn,

        [Parameter()]
        [string]$Baseline,

        [Parameter()]
        [switch]$IncludeTiming
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $fail = {
        param($Code, $Message, $Data)
        New-TcResult -Success $false -ErrorCode $Code -ErrorMessage $Message -Hint (Get-TcErrorHint -Code $Code) -Data $Data
    }

    # 1. engine (design.md D4 order)
    $engine = Get-TcLintEngine
    if (-not $engine.ok) {
        $d = [ordered]@{ languageMode = $engine.languageMode }
        if ($engine.detail) { $d.engineDetail = $engine.detail }
        return (& $fail $engine.code $engine.message $d)
    }
    $compileMs = $sw.ElapsedMilliseconds
    $ns = $engine.Namespace
    $registry = "$ns.RuleRegistry" -as [type]

    # 2. inputs (every check returns a contract code: no ValidateSet / binding exception, PR #274 review F5)
    if ([string]::IsNullOrWhiteSpace($ObjectKind) -or [string]::IsNullOrWhiteSpace($ObjectName)) {
        return (& $fail 'LINT_INPUT_INVALID' 'Give -ObjectKind and -ObjectName' $null)
    }
    $kinds = @('Program', 'FunctionBlock', 'Function', 'DUT', 'GVL', 'Interface', 'Method', 'Property', 'Action', 'Transition')
    $kindNorm = $kinds | Where-Object { [string]::Equals($_, $ObjectKind, [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
    if (-not $kindNorm) { return (& $fail 'LINT_INPUT_INVALID' "Unknown -ObjectKind '$ObjectKind' (Program, FunctionBlock, Function, DUT, GVL, Interface, Method, Property, Action)" $null) }
    if (-not [string]::IsNullOrEmpty($FailOn) -and @('error', 'warning') -notcontains $FailOn) {
        return (& $fail 'LINT_INPUT_INVALID' "-FailOn must be error or warning, got '$FailOn'" $null)
    }
    if ($null -eq $Declaration) { $Declaration = '' }
    if ($null -eq $Implementation) { $Implementation = '' }
    $textOnly = [string]::IsNullOrWhiteSpace($PlcProjectPath)
    $plcFull = $null
    if (-not $textOnly) {
        if ($PlcProjectPath -notmatch '\.plcproj$') {
            return (& $fail 'LINT_INPUT_INVALID' "-PlcProjectPath '$PlcProjectPath' is not a .plcproj file path. A PLC name needs the IDE to find the file, which this version does not do: give the .plcproj path (or omit it for a text-only check)" $null)
        }
        if (-not (Test-Path -LiteralPath $PlcProjectPath -PathType Leaf)) { return (& $fail 'LINT_INPUT_INVALID' ".plcproj not found: $PlcProjectPath" $null) }
        $plcFull = (Resolve-Path -LiteralPath $PlcProjectPath).ProviderPath
    }

    # 4. profile, 5. baseline (text-only: no discovery, default unless a profile file is given; design.md D5)
    $profileStart = if ($textOnly) { Join-Path ([System.IO.Path]::GetTempPath()) 'tcauto-lint-text-only\candidate.plcproj' } else { $plcFull }
    $profArg = $RuleProfile
    if ($textOnly -and [string]::IsNullOrWhiteSpace($profArg)) { $profArg = 'default' }
    $prof = Resolve-TcLintProfile -PlcProjectFull $profileStart -RuleProfile $profArg -RuleRegistry $registry
    if (-not $prof.ok) { return (& $fail $prof.code $prof.message ([ordered]@{ profilePath = $prof.profilePath })) }
    if ($textOnly) {
        $prof.profile.source = "$($prof.profile.source); text-only: no profile discovery"
        $prof.baselinePath = $null; $prof.baselineSource = $null
        if ($prof.profile.Contains('ignoredDiscoveredProfile')) { $prof.profile.Remove('ignoredDiscoveredProfile') }
    }
    if (-not [string]::IsNullOrWhiteSpace($Baseline)) {
        if (-not (Test-Path -LiteralPath $Baseline -PathType Leaf)) { return (& $fail 'LINT_BASELINE_INVALID' "Baseline not found: $Baseline" $null) }
        $prof.baselinePath = (Resolve-Path -LiteralPath $Baseline).ProviderPath
        $prof.baselineSource = 'parameter'
    }
    $base = Resolve-TcLintBaseline -ProfileResult $prof
    if (-not $base.ok) { return (& $fail $base.code $base.message ([ordered]@{ profile = $prof.profile })) }
    $effectiveFailOn = $prof.failOn
    if ($FailOn -eq 'warning') { $effectiveFailOn = 'warning' }

    # candidate text size: same limit as a project file (PR #274 review should-fix 5)
    $maxBytes = [long]$prof.maxFileSizeMB * 1MB
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    if (($utf8.GetByteCount($Declaration) + $utf8.GetByteCount($Implementation)) -gt $maxBytes) {
        return (& $fail 'LINT_INPUT_INVALID' "Candidate text is larger than the profile limit maxFileSizeMB = $($prof.maxFileSizeMB)" $null)
    }

    # 6. analysis
    $opt = New-Object "$ns.LintOptions"
    $opt.PlcProjectPath = $plcFull
    $opt.FailOn = $effectiveFailOn
    $opt.MaxFileBytes = $maxBytes
    $opt.CandidateMode = $true
    $opt.CandidateTextOnly = $textOnly
    $opt.CandidateKind = $kindNorm
    $opt.CandidateName = $ObjectName.Trim()
    $opt.CandidateDeclaration = $Declaration
    $opt.CandidateImplementation = $Implementation
    if ($script:TcLintTestFault) { $opt.TestFault = $true }
    foreach ($r in $prof.rules) { $opt.AddRuleOverride($r.id, $r.enabled, [string]$r.severity, $r.blocking) }
    foreach ($e in $prof.excludes) { $opt.AddExclude($e.objectPath, $e.reason) }
    foreach ($e in $prof.suppressions) { $opt.AddSuppression($e.objectPath, $e.ruleId, $e.reason) }
    foreach ($e in $prof.acceptSkips) { $opt.AddAcceptSkip($e.objectPath, $e.ruleId, $e.reason) }
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
        if ($inner -is [System.ArgumentException] -and $inner.Message -like 'LINT_INPUT_INVALID:*') {
            return (& $fail 'LINT_INPUT_INVALID' ($inner.Message.Substring(19)) $null)
        }
        return (& $fail 'LINT_ENGINE_ERROR' 'The lint engine failed; no result is reported' ([ordered]@{ engineDetail = "$($inner.GetType().FullName): $($inner.Message)" }))
    }

    # newSuppressions[] (tasks 2.2): inline directives against the disk version of the same file (design.md D5:
    # LintCandidate = candidate vs disk); profile suppressions and other weakenings against the git base as LintProject
    $all = @($res['suppressions'])
    $inline = @($all | Where-Object { $_['source'] -eq 'inline' })
    $profileSup = @($all | Where-Object { $_['source'] -ne 'inline' })
    $diskCounts = @{}
    $newInline = [System.Collections.Generic.List[object]]::new()
    $suppType = "$ns.Suppressions" -as [type]
    foreach ($s in $inline) {
        $c = $null
        if (-not $textOnly) {
            $rel = [string]$s['file']
            if (-not $diskCounts.ContainsKey($rel)) {
                $full = Join-Path ([System.IO.Path]::GetDirectoryName($plcFull)) ($rel -replace '/', '\')
                $m = $null
                if (Test-Path -LiteralPath $full -PathType Leaf) {
                    $keys = $suppType::KeysInObjectText([System.IO.File]::ReadAllText($full))
                    if ($null -ne $keys) { $m = @{}; foreach ($k in $keys) { if ($m.ContainsKey($k)) { $m[$k]++ } else { $m[$k] = 1 } } }
                }
                $diskCounts[$rel] = $m
            }
            $c = $diskCounts[$rel]
        }
        if ($null -ne $c -and $c.ContainsKey($s['key']) -and $c[$s['key']] -gt 0) { $c[$s['key']]--; continue }
        $newInline.Add($s)
    }
    $gitStart = if ($textOnly) { $profileStart } else { $plcFull }
    $newSup = Get-TcLintNewItems -Suppressions $profileSup -Overrides @($prof.profile.overrides) -PlcProjectFull $gitStart -ProfilePath $prof.profile.path -EngineType $suppType -RuleRegistry $registry
    $newSuppressions = @($newInline.ToArray()) + @($newSup.suppressions)
    $reasons = [System.Collections.Generic.List[string]]::new()
    if ([bool]$res['requiresDisposition']) { $reasons.Add('unresolved') }
    if (@($newSup.overrides).Count -gt 0) { $reasons.Add('new-overrides') }
    if ($newSuppressions.Count -gt 0) { $reasons.Add('new-suppressions') }

    $source = [ordered]@{ kind = $res['source']['kind']; plcProjectPath = $res['source']['plcProjectPath']; ideChecked = $false }
    $verdict = [string]$res['verdict']
    $data = [ordered]@{
        verdict              = $verdict
        passed               = ($verdict -eq 'pass')
        contextLevel         = $(if ($textOnly) { 'text-only' } else { 'project' })
        candidate            = $res['candidate']
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
        suppressions         = $all
        newSuppressions      = $newSuppressions
        newOverrides         = @($newSup.overrides)
        newSuppressionsBasis = $(if ($textOnly) { 'candidate-text-only' } else { 'candidate-vs-disk' })
        newOverridesBasis    = $newSup.basis
        newOverridesBase     = $newSup.base
        typeCatalog          = $catInfo
        coverage             = $res['coverage']
        rulesRun             = @($res['rulesRun'])
    }
    if ($newSup.reason) { $data.newOverridesBasisReason = $newSup.reason }
    $data.scope['note'] = 'LintCandidate checks the candidate object only (plus the project files): run LintProject -Scope All after writing it'
    if (@($res['engineDetail']).Count -gt 0) { $data.engineDetail = @($res['engineDetail']) }
    if ($IncludeTiming) { $data.timing = [ordered]@{ engineLoadMs = $compileMs; engineCompiled = [bool]$engine.compiled; analyzeMs = ($sw.ElapsedMilliseconds - $analyzeStart); totalMs = $sw.ElapsedMilliseconds } }

    $code = [string]$res['code']
    if ($verdict -eq 'pass') { return (New-TcResult -Success $true -Data $data) }
    $msg = switch ($code) {
        'LINT_PARSE_FAILED' { 'Lint could not parse the candidate (see LINT-PARSE-* in data.diagnostics)' }
        'LINT_CONTEXT_REQUIRED' { "The candidate needs the project to be checked ($(@($res['candidate']['contextRequired']) -join ', ')): give -PlcProjectPath" }
        'LINT_INCOMPLETE' { 'Lint is incomplete: a default-blocking rule could not run on part of the candidate (data.coverage.blockingRulesSkipped / notAnalyzed)' }
        default { "Lint found $($res['summary']['blocking']) blocking finding(s) in the candidate" }
    }
    return (& $fail $code $msg $data)
}
