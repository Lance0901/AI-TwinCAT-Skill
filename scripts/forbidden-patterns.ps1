<#
.SYNOPSIS
    Forbidden-pattern lint (#68), used by scripts/check.ps1 (check "forbidden") and
    tests/Unit/forbidden-lint.ps1. Dot-source it; it only defines functions.

.DESCRIPTION
    A hit is code text (comments and comment-based help are ignored) that matches one rule:
      amsnetid        an AmsNetId literal (\b\d{1,3}(\.\d{1,3}){5}\b): AmsNetIds are dynamic,
                      take them from the IDE target / ADS session or a parameter.
      startrestart    ITcSysManager.StartRestartTwinCAT: shows dialogs; Enable-TcConfig -Force
                      uses ADS WriteControl.
      executecommand  DTE.ExecuteCommand("TwinCAT.*"): GUI command fallback.
      writecontrol    a direct .WriteControl( call: runtime state changes go through
                      Set-TcSystemState / Set-TcPlcState / Enable-TcConfig, which read back.
    A legitimate use is allowed only by an explicit marker that names the rule and a reason,
    on the same line or on a comment-only line directly above it:
        # tcauto-allow(writecontrol): Set-TcSystemState itself, readback below
        // tcauto-allow(amsnetid): default of the local test PC, override with --netid
    Several rules: tcauto-allow(writecontrol,amsnetid): <reason>. The reason must have at least
    8 characters. There is no file-level or wildcard allowlist.
    Windows PowerShell 5.1; ASCII.
#>

function Get-TcForbiddenRules {
    @(
        [PSCustomObject]@{ Id = 'amsnetid'; Regex = [regex]'\b\d{1,3}(?:\.\d{1,3}){5}\b'; Why = 'hardcoded AmsNetId (dynamic per target: IDE target, ADS session or a parameter)' }
        [PSCustomObject]@{ Id = 'startrestart'; Regex = [regex]'StartRestartTwinCAT'; Why = 'StartRestartTwinCAT (dialogs; use Enable-TcConfig -Force)' }
        [PSCustomObject]@{ Id = 'executecommand'; Regex = [regex]'ExecuteCommand\(\s*[''"]TwinCAT\.'; Why = 'DTE.ExecuteCommand("TwinCAT.*") GUI command' }
        [PSCustomObject]@{ Id = 'writecontrol'; Regex = [regex]'\.WriteControl\('; Why = 'direct WriteControl (use Set-TcSystemState / Set-TcPlcState / Enable-TcConfig)' }
    )
}

# Text of a PowerShell file with every comment token replaced by spaces (line breaks kept).
function Get-TcPsCodeText {
    param([string]$Path)
    $tokens = $null; $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $text = [IO.File]::ReadAllText($Path)
    $chars = $text.ToCharArray()
    foreach ($t in $tokens) {
        if ($t.Kind -ne [System.Management.Automation.Language.TokenKind]::Comment) { continue }
        for ($i = $t.Extent.StartOffset; $i -lt $t.Extent.EndOffset -and $i -lt $chars.Length; $i++) {
            if ($chars[$i] -ne "`r" -and $chars[$i] -ne "`n") { $chars[$i] = ' ' }
        }
    }
    -join $chars
}

# Text of a JavaScript file with // and /* */ comments replaced by spaces (strings and template
# literals are skipped; regex literals are not recognised, which only matters for a '//' in one).
function Get-TcJsCodeText {
    param([string]$Path)
    $chars = [IO.File]::ReadAllText($Path).ToCharArray()
    $n = $chars.Length
    $i = 0
    $quote = [char]0
    while ($i -lt $n) {
        $c = $chars[$i]
        $next = if ($i + 1 -lt $n) { $chars[$i + 1] } else { [char]0 }
        if ($quote -ne [char]0) {
            if ($c -eq '\') { $i += 2; continue }
            if ($c -eq $quote) { $quote = [char]0 }
            $i++; continue
        }
        if ($c -eq "'" -or $c -eq '"' -or $c -eq '`') { $quote = $c; $i++; continue }
        if ($c -eq '/' -and $next -eq '/') {
            while ($i -lt $n -and $chars[$i] -ne "`n") { if ($chars[$i] -ne "`r") { $chars[$i] = ' ' }; $i++ }
            continue
        }
        if ($c -eq '/' -and $next -eq '*') {
            while ($i -lt $n -and -not ($chars[$i] -eq '*' -and $i + 1 -lt $n -and $chars[$i + 1] -eq '/')) {
                if ($chars[$i] -ne "`r" -and $chars[$i] -ne "`n") { $chars[$i] = ' ' }
                $i++
            }
            if ($i -lt $n) { $chars[$i] = ' '; if ($i + 1 -lt $n) { $chars[$i + 1] = ' ' }; $i += 2 }
            continue
        }
        $i++
    }
    -join $chars
}

# Rule ids allowed for raw line $Index (0-based) of $Raw: a marker on that line, or on the line
# above when that line is only a comment.
function Get-TcAllowedRules {
    param([string[]]$Raw, [int]$Index)
    $marker = [regex]'tcauto-allow\((?<rules>[a-z]+(?:\s*,\s*[a-z]+)*)\):\s*(?<reason>\S.{7,})'
    $found = @()
    $candidates = @($Raw[$Index])
    if ($Index -gt 0 -and $Raw[$Index - 1] -match '^\s*(#|//)') { $candidates += $Raw[$Index - 1] }
    foreach ($l in $candidates) {
        foreach ($m in $marker.Matches([string]$l)) { $found += @($m.Groups['rules'].Value -split '\s*,\s*') }
    }
    $found
}

function Find-TcForbiddenPattern {
    <#
    .SYNOPSIS
        Returns one object per hit: File (relative to -Root), Line, Rule, Text, Allowed.
    #>
    param([string[]]$Files, [string]$Root)
    $rules = Get-TcForbiddenRules
    $hits = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $Files) {
        $ext = [IO.Path]::GetExtension($f).ToLowerInvariant()
        $code = if ($ext -eq '.js' -or $ext -eq '.mjs') { Get-TcJsCodeText -Path $f } else { Get-TcPsCodeText -Path $f }
        $codeLines = $code -split "`n"
        $raw = [IO.File]::ReadAllText($f) -split "`n"
        $rel = $f
        if (-not [string]::IsNullOrEmpty($Root) -and $f.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)) { $rel = $f.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/') }
        for ($i = 0; $i -lt $codeLines.Length; $i++) {
            $line = $codeLines[$i]
            $allowed = $null
            foreach ($r in $rules) {
                if (-not $r.Regex.IsMatch($line)) { continue }
                if ($null -eq $allowed) { $allowed = @(Get-TcAllowedRules -Raw $raw -Index $i) }
                $hits.Add([PSCustomObject]@{ File = $rel; Line = $i + 1; Rule = $r.Id; Why = $r.Why; Text = $raw[$i].Trim(); Allowed = ($allowed -contains $r.Id) })
            }
        }
    }
    $hits.ToArray()
}

# Files the check scans: src/ and mcp-server/ (.ps1 .psm1 .js .mjs, not mcp-server/test/) and
# tests/Integration/*.ps1, given as full paths with a relative path function.
function Test-TcForbiddenScope {
    param([string]$RelativePath)
    $p = $RelativePath.Replace('\', '/')
    if ($p -notmatch '\.(ps1|psm1|js|mjs)$') { return $false }
    if ($p -match '^src/') { return $true }
    if ($p -match '^mcp-server/' -and $p -notmatch '^mcp-server/(test|node_modules)/') { return $true }
    if ($p -match '^tests/Integration/[^/]+\.ps1$') { return $true }
    $false
}
