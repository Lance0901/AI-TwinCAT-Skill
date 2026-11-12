# Semantic linter (#252 tasks 1b.1 / 1b.6): the versioned FB type catalog (TypeCatalog.json) and the
# newSuppressions[] basis (design.md D5: LintProject compares with the git HEAD of the repository that holds
# the project; read-only git commands only). When git or HEAD cannot be read, every suppression is reported
# as new (fail closed: the user sees all of them).

$script:TcLintTypeCatalogSchema = 'tcauto-lint-type-catalog/1'
$script:TcLintGitExe = $null   # test seam: another executable name simulates "git not available"

function Get-TcLintTypeCatalog {
    <#
    .SYNOPSIS
        Reads Private/Lint/TypeCatalog.json. Returns @{ ok; message; entries (name, library, kind, source); info (data.typeCatalog) }.
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
                $entries.Add(@{ name = $e.name; library = [string]$lib.name; kind = $k[1]; source = $e.source })
                if ($k[1] -eq 'stateful') { $stateful++ } else { $typeOnly++ }
            }
        }
    }
    return @{ ok = $true; entries = $entries.ToArray()
        info = [ordered]@{ schema = $v.schema; version = $v.version; sha256 = (Get-TcLintFileSha256 -Path $path); stateful = $stateful; typeOnly = $typeOnly } }
}

function Invoke-TcLintGit {
    <#
    .SYNOPSIS
        Runs a read-only git command. Returns @{ ok; exit; out } (stdout decoded as UTF-8). Never throws.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkDir, [Parameter(Mandatory)][string[]]$GitArgs, [int]$TimeoutMs = 15000)
    $exe = if ($script:TcLintGitExe) { $script:TcLintGitExe } else { 'git' }
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
        # both streams async, then a real deadline (ReadToEnd would block until git exits: review should-fix 7)
        $errTask = $p.StandardError.ReadToEndAsync()
        $outTask = $p.StandardOutput.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutMs)) { try { $p.Kill() } catch { $null = $_ }; return @{ ok = $false; exit = -1; out = ''; timedOut = $true } }
        $p.WaitForExit()
        $null = $errTask.Result
        return @{ ok = ($p.ExitCode -eq 0); exit = $p.ExitCode; out = $outTask.Result }
    }
    catch { return @{ ok = $false; exit = -1; out = '' } }
}

function Get-TcLintDiskSpelling {
    <#
    .SYNOPSIS
        The path with the upper / lower case the file system has (git HEAD:<path> is case-sensitive; review should-fix 8).
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

function Get-TcLintNewSuppressions {
    <#
    .SYNOPSIS
        Compares the suppressions of this run with git HEAD. Returns @{ basis; reason; items }.
    .PARAMETER Suppressions
        data.suppressions of the engine (inline and profile entries, each with a key).
    .PARAMETER PlcProjectFull
        The .plcproj (its directory is where the repository is searched).
    .PARAMETER ProfilePath
        The profile file in use, or $null for the built-in profile.
    .PARAMETER EngineType
        The engine's Suppressions type (KeysInRawText uses the same directive parser as the engine).
    #>
    [CmdletBinding()]
    param([object[]]$Suppressions, [Parameter(Mandatory)][string]$PlcProjectFull, [string]$ProfilePath, [Parameter(Mandatory)]$EngineType)
    $all = @($Suppressions)
    $unavailable = { param($why) return @{ basis = 'unavailable'; reason = $why; items = $all } }
    if ($all.Count -eq 0) { return @{ basis = 'no-suppressions'; reason = $null; items = @() } }
    $plcDir = [System.IO.Path]::GetDirectoryName($PlcProjectFull)
    $top = Invoke-TcLintGit -WorkDir $plcDir -GitArgs @('rev-parse', '--show-toplevel')
    if (-not $top.ok) { return (& $unavailable 'not a git repository, or git is not available: every suppression is listed as new') }
    $topDir = Get-TcLintDiskSpelling -Path ($top.out.Trim() -replace '/', '\')
    $head = Invoke-TcLintGit -WorkDir $topDir -GitArgs @('rev-parse', '--verify', '--quiet', 'HEAD')
    if (-not $head.ok) { return (& $unavailable 'the repository has no HEAD commit: every suppression is listed as new') }
    $relOf = {
        param($full)
        $f = Get-TcLintDiskSpelling -Path $full
        $t = $topDir.TrimEnd('\') + '\'
        if (-not $f.StartsWith($t, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
        return ($f.Substring($t.Length) -replace '\\', '/')
    }
    $headCounts = @{}   # repo-relative path -> @{ key -> count } ; $null = not in HEAD
    $countsFor = {
        param($rel)
        if ($headCounts.ContainsKey($rel)) { return $headCounts[$rel] }
        $c = $null
        $g = Invoke-TcLintGit -WorkDir $topDir -GitArgs @('show', "HEAD:$rel")
        if ($g.ok) {
            $c = @{}
            foreach ($k in $EngineType::KeysInRawText($g.out)) { if ($c.ContainsKey($k)) { $c[$k]++ } else { $c[$k] = 1 } }
        }
        $headCounts[$rel] = $c
        return $c
    }
    $new = [System.Collections.Generic.List[object]]::new()
    foreach ($s in $all) {
        if ($s.source -eq 'inline') {
            $rel = & $relOf (Join-Path $plcDir ($s.file -replace '/', '\'))
            $c = if ($rel) { & $countsFor $rel } else { $null }
        }
        else {
            $c = $null
            if ($ProfilePath) {
                $rel = & $relOf $ProfilePath
                if ($rel -and -not $headCounts.ContainsKey("profile:$rel")) {
                    $pc = $null
                    $g = Invoke-TcLintGit -WorkDir $topDir -GitArgs @('show', "HEAD:$rel")
                    if ($g.ok) {
                        $pc = @{}
                        try {
                            foreach ($e in @(($g.out | ConvertFrom-Json -ErrorAction Stop).suppressions)) {
                                if ($null -eq $e) { continue }
                                $k = "profile|$($e.objectPath)|$($e.ruleId)|$($e.reason)"
                                if ($pc.ContainsKey($k)) { $pc[$k]++ } else { $pc[$k] = 1 }
                            }
                        }
                        catch { $pc = $null }
                    }
                    $headCounts["profile:$rel"] = $pc
                }
                if ($rel) { $c = $headCounts["profile:$rel"] }
            }
        }
        if ($null -ne $c -and $c.ContainsKey($s.key) -and $c[$s.key] -gt 0) { $c[$s.key]--; continue }
        $new.Add($s)
    }
    return @{ basis = 'git-head'; reason = $null; items = $new.ToArray() }
}
