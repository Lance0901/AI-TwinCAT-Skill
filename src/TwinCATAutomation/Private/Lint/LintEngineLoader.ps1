# Semantic linter (#252) engine loader: compiles Private/Lint/*.cs on the first lint call (not at
# Import-Module) with Add-Type, which in Windows PowerShell 5.1 is the .NET Framework csc (C# 5).
# design.md D1:
# - the namespace TcLintEngine is renamed to TcLint_<first 12 hex of SHA256 over the sources>, so a
#   changed .cs gives a new type even when an older engine is still loaded in the AppDomain
#   (Add-Type assemblies cannot be unloaded; ReloadModule / Import-Module -Force keeps them);
# - not FullLanguage (Constrained Language Mode: AppLocker / WDAC) or Add-Type failing for an
#   environment reason (csc blocked, antivirus) -> LINT_ENGINE_UNAVAILABLE; a C# compile error
#   (error CSxxxx, our own bug) -> LINT_ENGINE_ERROR.

$script:TcLintEngine = $null                  # @{ Hash; Type; Namespace } of the loaded engine
$script:TcLintLanguageModeOverride = $null    # tests only: pretend another LanguageMode
$script:TcLintAddTypeOverride = $null         # tests only: scriptblock run instead of Add-Type (throw to simulate a failure)
$script:TcLintTestFault = $false               # tests only: make the engine throw (LINT_ENGINE_ERROR)

function Get-TcLintEngine {
    <#
    .SYNOPSIS
        Returns @{ ok = $true; Type; Hash; Namespace; compiled } or @{ ok = $false; code; message; languageMode; detail }.
    #>
    [CmdletBinding()]
    param()

    $mode = if ($null -ne $script:TcLintLanguageModeOverride) { [string]$script:TcLintLanguageModeOverride } else { [string]$ExecutionContext.SessionState.LanguageMode }
    if ($mode -ne 'FullLanguage') {
        return @{ ok = $false; code = 'LINT_ENGINE_UNAVAILABLE'; languageMode = $mode
            message = "The lint engine needs PowerShell FullLanguage mode to compile its C# source (LanguageMode is $mode)" }
    }
    $dir = $PSScriptRoot
    $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.cs' | Sort-Object { $_.Name.ToLowerInvariant() })
    if ($files.Count -eq 0) {
        return @{ ok = $false; code = 'LINT_ENGINE_ERROR'; languageMode = $mode; message = "No lint engine source (*.cs) in $dir" }
    }
    $src = ($files | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($src)) } finally { $sha.Dispose() }
    $hash = (-join ($hashBytes | ForEach-Object { $_.ToString('x2') })).Substring(0, 12)
    if ($null -ne $script:TcLintEngine -and $script:TcLintEngine.Hash -eq $hash) {
        return @{ ok = $true; Type = $script:TcLintEngine.Type; Hash = $hash; Namespace = $script:TcLintEngine.Namespace; compiled = $false; languageMode = $mode }
    }
    $ns = "TcLint_$hash"
    $type = "$ns.LintEngine" -as [type]
    $compiled = $false
    if ($null -eq $type) {
        $code = [regex]::Replace($src, '\bTcLintEngine\b', $ns)
        try {
            if ($null -ne $script:TcLintAddTypeOverride) { & $script:TcLintAddTypeOverride $code }
            else { Add-Type -TypeDefinition $code -ReferencedAssemblies 'System.Xml', 'System.Core' -ErrorAction Stop }
        }
        catch {
            $text = ($_ | Out-String)
            $isCompileError = $text -match 'error CS\d{4}'
            return @{ ok = $false; languageMode = $mode
                code = $(if ($isCompileError) { 'LINT_ENGINE_ERROR' } else { 'LINT_ENGINE_UNAVAILABLE' })
                message = $(if ($isCompileError) { 'The lint engine source does not compile (engine bug)' } else { 'Add-Type could not compile the lint engine (csc blocked or failing)' })
                detail = $_.Exception.Message }
        }
        $type = "$ns.LintEngine" -as [type]
        $compiled = $true
        if ($null -eq $type) {
            return @{ ok = $false; code = 'LINT_ENGINE_ERROR'; languageMode = $mode; message = "Compiled, but type $ns.LintEngine is not loadable" }
        }
    }
    $script:TcLintEngine = @{ Hash = $hash; Type = $type; Namespace = $ns }
    return @{ ok = $true; Type = $type; Hash = $hash; Namespace = $ns; compiled = $compiled; languageMode = $mode }
}

function Get-TcLintEngineType {
    <#
    .SYNOPSIS
        Tests / internal: the engine type with the given short name (StAnalyzer, RuleRegistry, LintOptions ...), compiling on first use.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $e = Get-TcLintEngine
    if (-not $e.ok) { throw "$($e.code): $($e.message)" }
    return ("$($e.Namespace).$Name" -as [type])
}
