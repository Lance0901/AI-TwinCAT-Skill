# Semantic linter (#252) rule profile and baseline: discovery, validation, overrides (design.md D5).
# A profile is JSON data only (schema tcauto-lint-profile/1): no script, no regex, exact object paths;
# anything unknown or malformed -> LINT_PROFILE_INVALID and no rule runs (fail closed). Every setting
# that is weaker than the default profile is listed in data.profile.overrides.

$script:TcLintProfileSchema = 'tcauto-lint-profile/1'
$script:TcLintBaselineSchema = 'tcauto-lint-baseline/1'
$script:TcLintMinReasonLength = 8

function Get-TcLintSearchDirs {
    <#
    .SYNOPSIS
        Directories from the .plcproj directory upwards, ending with the first one that holds a .sln or .git (the drive root itself is never searched). Last element = the solution root used for path containment.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StartDir)
    $dirs = [System.Collections.Generic.List[string]]::new()
    $d = $StartDir
    while (-not [string]::IsNullOrEmpty($d)) {
        # never search the drive root: any user may create C:\.tcauto there (review nit 13)
        if ($dirs.Count -gt 0 -and [string]::IsNullOrEmpty([System.IO.Path]::GetDirectoryName($d))) { break }
        $dirs.Add($d)
        $hasSln = @(Get-ChildItem -LiteralPath $d -Filter '*.sln' -File -ErrorAction SilentlyContinue).Count -gt 0
        $hasGit = Test-Path -LiteralPath (Join-Path $d '.git')
        if ($hasSln -or $hasGit) { break }
        $d = [System.IO.Path]::GetDirectoryName($d)
    }
    return , $dirs
}

function Get-TcLintFileSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        return (-join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }))
    }
    finally { $sha.Dispose() }
}

function Test-TcLintPathInside {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Root)
    $r = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $p = [System.IO.Path]::GetFullPath($Path)
    return $p.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)
}

function Read-TcLintJson {
    # @{ ok; value; error } ; the file is read as UTF-8 (BOM optional)
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    try {
        $info = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($info.PSIsContainer) { return @{ ok = $false; error = 'is a directory' } }
        if ($info.Length -gt 1MB) { return @{ ok = $false; error = 'larger than 1 MB' } }
        $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        $value = $text | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $value -or $value -isnot [System.Management.Automation.PSCustomObject]) { return @{ ok = $false; error = 'top level is not a JSON object' } }
        return @{ ok = $true; value = $value }
    }
    catch { return @{ ok = $false; error = "not readable JSON ($($_.Exception.GetType().Name))" } }
}

function Get-TcLintPropNames($Obj) {
    if ($null -eq $Obj -or $Obj -isnot [System.Management.Automation.PSCustomObject]) { return @() }
    return @($Obj.PSObject.Properties | ForEach-Object { $_.Name })
}

function Test-TcLintReason([object]$Reason) {
    return ($Reason -is [string]) -and ($Reason.Trim().Length -ge $script:TcLintMinReasonLength)
}

function Resolve-TcLintProfile {
    <#
    .SYNOPSIS
        Finds, validates and converts the lint profile. Returns @{ ok; code; message; profile (data.profile); failOn; entries; baselinePath; baselineDisabled; searchRoot }.
    .PARAMETER PlcProjectFull
        Full path of the .plcproj (start of the discovery).
    .PARAMETER RuleProfile
        'default', a profile file path, or empty = discover .tcauto\lint-profile.json.
    .PARAMETER RuleRegistry
        The engine RuleRegistry type (rule ids and metadata).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PlcProjectFull,
        [string]$RuleProfile,
        [Parameter(Mandatory)]$RuleRegistry
    )
    $dirs = Get-TcLintSearchDirs -StartDir ([System.IO.Path]::GetDirectoryName($PlcProjectFull))
    $searchRoot = $dirs[$dirs.Count - 1]
    $discovered = $null
    foreach ($d in $dirs) {
        $p = Join-Path (Join-Path $d '.tcauto') 'lint-profile.json'
        if (Test-Path -LiteralPath $p) { $discovered = $p; break }
    }
    $defaultBaseline = $null
    foreach ($d in $dirs) {
        $b = Join-Path (Join-Path $d '.tcauto') 'lint-baseline.json'
        if (Test-Path -LiteralPath $b) { $defaultBaseline = $b; break }
    }
    $profileData = [ordered]@{ name = 'default'; source = 'built-in'; sha256 = $null; overrides = @() }
    $result = @{ ok = $true; profile = $profileData; failOn = 'error'; searchRoot = $searchRoot; maxFileSizeMB = 8
        rules = @(); excludes = @(); suppressions = @(); acceptSkips = @(); baselinePath = $defaultBaseline; baselineSource = $(if ($defaultBaseline) { 'discovered' } else { $null }); baselineDisabled = $null }

    $file = $null
    if ([string]::IsNullOrWhiteSpace($RuleProfile)) {
        if ($null -ne $discovered) { $file = $discovered; $profileData.source = 'discovered' }
    }
    elseif ($RuleProfile -eq 'default') {
        $profileData.source = 'built-in (-RuleProfile default)'
        if ($null -ne $discovered) { $profileData.ignoredDiscoveredProfile = $discovered }
    }
    else {
        if (-not (Test-Path -LiteralPath $RuleProfile -PathType Leaf)) {
            return @{ ok = $false; code = 'LINT_PROFILE_INVALID'; message = "Rule profile not found: $RuleProfile (built-in profiles: default)" }
        }
        $file = (Resolve-Path -LiteralPath $RuleProfile).ProviderPath
        $profileData.source = 'parameter'
        if ($null -ne $discovered -and -not [string]::Equals($discovered, $file, [System.StringComparison]::OrdinalIgnoreCase)) { $profileData.ignoredDiscoveredProfile = $discovered }
    }
    if ($null -eq $file) { return $result }

    $fail = { param($m) return @{ ok = $false; code = 'LINT_PROFILE_INVALID'; message = "Rule profile $file is invalid: $m"; profilePath = $file } }
    $j = Read-TcLintJson -Path $file
    if (-not $j.ok) { return (& $fail $j.error) }
    $v = $j.value
    $profileData.name = [System.IO.Path]::GetFileName($file)
    $profileData.path = $file
    $profileData.sha256 = Get-TcLintFileSha256 -Path $file

    $allowedTop = @('schema', 'extends', 'failOn', 'rules', 'typeCatalog', 'exclude', 'suppressions', 'acceptSkips', 'baseline', 'description', 'maxFileSizeMB')
    foreach ($k in (Get-TcLintPropNames $v)) { if ($allowedTop -cnotcontains $k) { return (& $fail "unknown field '$k'") } }
    if ($v.schema -ne $script:TcLintProfileSchema) { return (& $fail "schema must be '$($script:TcLintProfileSchema)'") }
    if ($null -ne $v.extends -and $v.extends -ne 'default') { return (& $fail "extends must be 'default' (the only built-in profile)") }
    if ($null -ne $v.description -and $v.description -isnot [string]) { return (& $fail 'description must be a string') }
    if ($null -ne $v.failOn) {
        if (@('error', 'warning') -cnotcontains $v.failOn) { return (& $fail "failOn must be 'error' or 'warning'") }
        $result.failOn = $v.failOn
    }
    if ($null -ne $v.maxFileSizeMB) {
        if (($v.maxFileSizeMB -isnot [int] -and $v.maxFileSizeMB -isnot [long]) -or $v.maxFileSizeMB -lt 1 -or $v.maxFileSizeMB -gt 256) { return (& $fail 'maxFileSizeMB must be an integer from 1 to 256') }
        $result.maxFileSizeMB = [int]$v.maxFileSizeMB
    }
    $overrides = [System.Collections.Generic.List[object]]::new()

    # rules
    $rules = [System.Collections.Generic.List[object]]::new()
    if ($null -ne $v.rules) {
        if ($v.rules -isnot [System.Management.Automation.PSCustomObject]) { return (& $fail 'rules must be an object') }
        foreach ($id in (Get-TcLintPropNames $v.rules | Sort-Object)) {
            $meta = $RuleRegistry::Get($id)
            if ($null -eq $meta) { return (& $fail "unknown rule id '$id'") }
            $r = $v.rules.$id
            if ($r -isnot [System.Management.Automation.PSCustomObject]) { return (& $fail "rules.$id must be an object") }
            foreach ($k in (Get-TcLintPropNames $r)) { if (@('enabled', 'severity', 'blocking', 'params', 'reason') -cnotcontains $k) { return (& $fail "rules.$id has unknown field '$k'") } }
            if ($null -ne $r.enabled -and $r.enabled -isnot [bool]) { return (& $fail "rules.$id.enabled must be true or false") }
            if ($null -ne $r.blocking -and $r.blocking -isnot [bool]) { return (& $fail "rules.$id.blocking must be true or false") }
            if ($null -ne $r.severity -and @('error', 'warning', 'info') -cnotcontains $r.severity) { return (& $fail "rules.$id.severity must be error, warning or info") }
            if ($null -ne $r.params -and @(Get-TcLintPropNames $r.params).Count -gt 0) { return (& $fail "rules.$id.params: this rule has no parameters") }
            $rank = @{ error = 3; warning = 2; info = 1 }
            $weaker = @()
            if ($r.enabled -eq $false) { $weaker += 'disabled' }
            if ($null -ne $r.severity -and $rank[$r.severity] -lt $rank[$meta.Severity]) { $weaker += "severity $($meta.Severity) -> $($r.severity)" }
            if ($r.blocking -eq $false -and $meta.Blockable -ne 'false') { $weaker += 'blocking false' }
            if ($id -like 'LINT-PARSE-*' -and $weaker.Count -gt 0) {
                return (& $fail "rules.${id}: parse failures cannot be disabled or weakened; exclude the object with a reason instead")
            }
            if ($weaker.Count -gt 0) {
                if (-not (Test-TcLintReason $r.reason)) { return (& $fail "rules.$id weakens the default ($($weaker -join ', ')) and needs a reason of at least $($script:TcLintMinReasonLength) characters") }
                $overrides.Add([ordered]@{ kind = 'rule'; ruleId = $id; change = ($weaker -join ', '); reason = $r.reason })
            }
            $rules.Add(@{ id = $id; enabled = $r.enabled; severity = $r.severity; blocking = $r.blocking })
        }
    }
    $result.rules = $rules.ToArray()

    if ($null -ne $v.typeCatalog) {
        if ($v.typeCatalog -isnot [System.Management.Automation.PSCustomObject]) { return (& $fail 'typeCatalog must be an object') }
        foreach ($k in (Get-TcLintPropNames $v.typeCatalog)) {
            if (@('functionBlocks', 'stateful', 'cyclicContract') -cnotcontains $k) { return (& $fail "typeCatalog has unknown field '$k'") }
            foreach ($n in @($v.typeCatalog.$k)) { if ($n -isnot [string] -or $n -match '[*?]') { return (& $fail "typeCatalog.$k must be a list of exact names") } }
        }
    }

    # exclude / suppressions / acceptSkips: exact object paths, reason required
    $lists = @(
        @{ key = 'exclude'; fields = @('objectPath', 'reason'); needRule = $false; target = 'excludes' },
        @{ key = 'suppressions'; fields = @('objectPath', 'ruleId', 'reason'); needRule = $true; target = 'suppressions' },
        @{ key = 'acceptSkips'; fields = @('objectPath', 'ruleId', 'reason'); needRule = $true; target = 'acceptSkips' })
    foreach ($l in $lists) {
        $items = [System.Collections.Generic.List[object]]::new()
        $raw = $v.($l.key)
        if ($null -ne $raw) {
            if ($raw -isnot [System.Array] -and $raw -isnot [System.Management.Automation.PSCustomObject]) { return (& $fail "$($l.key) must be a list") }
            $i = 0
            foreach ($e in @($raw)) {
                $where = "$($l.key)[$i]"; $i++
                if ($e -isnot [System.Management.Automation.PSCustomObject]) { return (& $fail "$where must be an object") }
                foreach ($k in (Get-TcLintPropNames $e)) { if ($l.fields -cnotcontains $k) { return (& $fail "$where has unknown field '$k'") } }
                if ($e.objectPath -isnot [string] -or [string]::IsNullOrWhiteSpace($e.objectPath)) { return (& $fail "$where.objectPath is required") }
                if ($e.objectPath -match '[*?]') { return (& $fail "$where.objectPath must be an exact path (no wildcard)") }
                if (-not (Test-TcLintReason $e.reason)) { return (& $fail "$where.reason is required (at least $($script:TcLintMinReasonLength) characters)") }
                if ($l.needRule) {
                    if ($e.ruleId -isnot [string] -or $null -eq $RuleRegistry::Get($e.ruleId)) { return (& $fail "$where.ruleId '$($e.ruleId)' is not a known rule id") }
                    if ($l.key -eq 'suppressions' -and $e.ruleId -like 'LINT-PARSE-*') { return (& $fail "${where}: parse failures cannot be suppressed; exclude the object with a reason instead") }
                }
                $items.Add(@{ objectPath = $e.objectPath; ruleId = $e.ruleId; reason = $e.reason })
                $ov = [ordered]@{ kind = $(switch ($l.key) { 'exclude' { 'exclude' } 'suppressions' { 'suppression' } default { 'acceptSkip' } }); objectPath = $e.objectPath }
                if ($l.needRule) { $ov.ruleId = $e.ruleId }
                $ov.reason = $e.reason
                $overrides.Add($ov)
            }
        }
        $result[$l.target] = $items.ToArray()
    }

    # baseline: path relative to the profile, inside the solution root; or { disabled, reason }
    $profileDir = [System.IO.Path]::GetDirectoryName($file)
    if ($null -ne $v.baseline) {
        if ($v.baseline -is [string]) {
            if ([System.IO.Path]::IsPathRooted($v.baseline)) { return (& $fail 'baseline must be a path relative to the profile') }
            $bp = [System.IO.Path]::GetFullPath((Join-Path $profileDir $v.baseline))
            if (-not (Test-TcLintPathInside -Path $bp -Root $searchRoot)) { return (& $fail "baseline '$($v.baseline)' points outside the solution directory $searchRoot") }
            $result.baselinePath = $bp
            $result.baselineSource = 'profile'
            $result.baselineRequired = $true
        }
        elseif ($v.baseline -is [System.Management.Automation.PSCustomObject]) {
            foreach ($k in (Get-TcLintPropNames $v.baseline)) { if (@('disabled', 'reason') -cnotcontains $k) { return (& $fail "baseline has unknown field '$k'") } }
            if ($v.baseline.disabled -ne $true) { return (& $fail 'baseline object must be { "disabled": true, "reason": "..." }') }
            if (-not (Test-TcLintReason $v.baseline.reason)) { return (& $fail "baseline.disabled needs a reason (at least $($script:TcLintMinReasonLength) characters)") }
            $result.baselineDisabled = $v.baseline.reason
            $overrides.Add([ordered]@{ kind = 'baseline-disabled'; path = $defaultBaseline; reason = $v.baseline.reason })
            $result.baselinePath = $null
            $result.baselineSource = $null
        }
        else { return (& $fail 'baseline must be a relative path or { "disabled": true, "reason": "..." }') }
    }
    $profileData.overrides = $overrides.ToArray()
    return $result
}

function Resolve-TcLintBaseline {
    <#
    .SYNOPSIS
        Validates the baseline file found by Resolve-TcLintProfile. Returns @{ ok; code; message; baseline (data.baseline or $null) }.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ProfileResult)
    $path = $ProfileResult.baselinePath
    if ($null -eq $path) { return @{ ok = $true; baseline = $null } }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return @{ ok = $false; code = 'LINT_BASELINE_INVALID'; message = "The profile requires baseline $path, but it does not exist" }
    }
    $j = Read-TcLintJson -Path $path
    if (-not $j.ok) { return @{ ok = $false; code = 'LINT_BASELINE_INVALID'; message = "Baseline $path is invalid: $($j.error)" } }
    $v = $j.value
    foreach ($k in (Get-TcLintPropNames $v)) {
        if (@('schema', 'source', 'types') -cnotcontains $k) { return @{ ok = $false; code = 'LINT_BASELINE_INVALID'; message = "Baseline $path is invalid: unknown field '$k'" } }
    }
    if ($v.schema -ne $script:TcLintBaselineSchema) { return @{ ok = $false; code = 'LINT_BASELINE_INVALID'; message = "Baseline $path is invalid: schema must be '$($script:TcLintBaselineSchema)'" } }
    if ($v.types -isnot [System.Management.Automation.PSCustomObject]) { return @{ ok = $false; code = 'LINT_BASELINE_INVALID'; message = "Baseline $path is invalid: types must be an object" } }
    foreach ($t in (Get-TcLintPropNames $v.types)) {
        $e = $v.types.$t
        if ($e -isnot [System.Management.Automation.PSCustomObject] -or @('ENUM', 'STRUCT', 'UNION', 'ALIAS') -cnotcontains $e.kind) {
            return @{ ok = $false; code = 'LINT_BASELINE_INVALID'; message = "Baseline $path is invalid: types.$t.kind must be ENUM, STRUCT, UNION or ALIAS" }
        }
    }
    return @{ ok = $true; baseline = [ordered]@{ path = $path; source = $ProfileResult.baselineSource; sha256 = (Get-TcLintFileSha256 -Path $path)
            types = @(Get-TcLintPropNames $v.types).Count; rulesUsingIt = 'CONTRACT-ENUM / CONTRACT-DUT (Phase 4; not run in this version)' } }
}
