<#
.SYNOPSIS
    Forbidden-pattern lint (#68), used by scripts/check.ps1 (check "forbidden") and
    tests/Unit/forbidden-lint.ps1. Dot-source it; it only defines functions.

.DESCRIPTION
    A hit is code text (comments and comment-based help are ignored; string literals are code)
    that matches one rule:
      amsnetid        an AmsNetId literal (\b\d{1,3}(\.\d{1,3}){5}\b): AmsNetIds are dynamic,
                      take them from the IDE target / ADS session or a parameter.
      startrestart    StartRestartTwinCAT: a restart through the IDE, outside the module's gated
                      lifecycle (Enable-TcConfig -Force / Set-TcSystemState read the state back).
      executecommand  any ExecuteCommand (DTE command; "TwinCAT.*" commands are a GUI fallback).
      writecontrol    any WriteControl / WriteControlAsync (also in a string, e.g. reflection):
                      runtime state changes go through Set-TcSystemState / Set-TcPlcState /
                      Enable-TcConfig, which read back.
    A legitimate use is allowed only by an explicit marker that names the rule and a reason, in
    a COMMENT (PowerShell comment token, JavaScript // or /* */; a marker inside a string does not
    count) on the same line, or on a comment-only line directly above it:
        # tcauto-allow(writecontrol): Set-TcSystemState itself, readback below
        // tcauto-allow(amsnetid): default of the local test PC, override with --netid
    Several rules: tcauto-allow(writecontrol,amsnetid): <reason>. The reason must have at least
    8 characters. There is no file-level or wildcard allowlist.
    Windows PowerShell 5.1; ASCII.
#>

function Get-TcForbiddenRules {
    @(
        [PSCustomObject]@{ Id = 'amsnetid'; Regex = [regex]'\b\d{1,3}(?:\.\d{1,3}){5}\b'; Why = 'hardcoded AmsNetId (dynamic per target: IDE target, ADS session or a parameter)' }
        [PSCustomObject]@{ Id = 'startrestart'; Regex = [regex]'StartRestartTwinCAT'; Why = 'StartRestartTwinCAT (restart outside the gated lifecycle; use Enable-TcConfig -Force)' }
        [PSCustomObject]@{ Id = 'executecommand'; Regex = [regex]'\bExecuteCommand\b'; Why = 'DTE ExecuteCommand (GUI command)' }
        [PSCustomObject]@{ Id = 'writecontrol'; Regex = [regex]'\bWriteControl(?:Async)?\b'; Why = 'WriteControl (use Set-TcSystemState / Set-TcPlcState / Enable-TcConfig)' }
    )
}

# Splits a text into @{ Code; Comments }: two strings of the same length and line breaks, Code
# with every comment character blanked, Comments with every non-comment character blanked.
# $Ranges: comment ranges as @(start, end) (end exclusive).
function Split-TcCommentText {
    param([string]$Text, [object[]]$Ranges)
    $code = $Text.ToCharArray()
    $com = ([regex]::Replace($Text, '[^\r\n]', ' ')).ToCharArray()
    foreach ($r in $Ranges) {
        for ($i = [int]$r[0]; $i -lt [int]$r[1] -and $i -lt $code.Length; $i++) {
            $ch = $code[$i]
            if ($ch -eq "`r" -or $ch -eq "`n") { continue }
            $com[$i] = $ch
            $code[$i] = ' '
        }
    }
    @{ Code = (-join $code); Comments = (-join $com) }
}

# PowerShell file: comment = a Comment token of the 5.1 parser (comment-based help included).
function Get-TcPsCodeText {
    param([string]$Path)
    $tokens = $null; $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $text = [IO.File]::ReadAllText($Path)
    $ranges = @($tokens | Where-Object { $_.Kind -eq [System.Management.Automation.Language.TokenKind]::Comment } | ForEach-Object { , @($_.Extent.StartOffset, $_.Extent.EndOffset) })
    Split-TcCommentText -Text $text -Ranges $ranges
}

# JavaScript file: // and /* */ outside strings and template literals (regex literals are not
# recognised, which only matters for a '//' or '/*' inside one).
function Get-TcJsCodeText {
    param([string]$Path)
    $text = [IO.File]::ReadAllText($Path)
    $chars = $text.ToCharArray()
    $n = $chars.Length
    $ranges = [System.Collections.Generic.List[object]]::new()
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
            $s0 = $i
            while ($i -lt $n -and $chars[$i] -ne "`n") { $i++ }
            $ranges.Add(@($s0, $i))
            continue
        }
        if ($c -eq '/' -and $next -eq '*') {
            $s0 = $i
            $i += 2
            while ($i -lt $n -and -not ($chars[$i] -eq '*' -and $i + 1 -lt $n -and $chars[$i + 1] -eq '/')) { $i++ }
            $i = [Math]::Min($n, $i + 2)
            $ranges.Add(@($s0, $i))
            continue
        }
        $i++
    }
    Split-TcCommentText -Text $text -Ranges $ranges.ToArray()
}

# Rule ids allowed for line $Index (0-based): a marker in the comment part of that line, or in
# the comment part of the line above when that line has no code.
function Get-TcAllowedRules {
    param([string[]]$CodeLines, [string[]]$CommentLines, [int]$Index)
    $marker = [regex]'tcauto-allow\((?<rules>[a-z]+(?:\s*,\s*[a-z]+)*)\):\s*(?<reason>\S.{7,})'
    $found = @()
    $candidates = @($CommentLines[$Index])
    if ($Index -gt 0 -and [string]::IsNullOrWhiteSpace($CodeLines[$Index - 1])) { $candidates += $CommentLines[$Index - 1] }
    foreach ($l in $candidates) {
        foreach ($m in $marker.Matches([string]$l)) { $found += @($m.Groups['rules'].Value -split '\s*,\s*') }
    }
    $found
}

function Find-TcForbiddenPattern {
    <#
    .SYNOPSIS
        Returns one object per hit: File (relative to -Root), Line, Rule, Why, Text, Allowed.
    #>
    param([string[]]$Files, [string]$Root)
    $rules = Get-TcForbiddenRules
    $hits = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $Files) {
        $ext = [IO.Path]::GetExtension($f).ToLowerInvariant()
        $parts = if ($ext -eq '.js' -or $ext -eq '.mjs') { Get-TcJsCodeText -Path $f } else { Get-TcPsCodeText -Path $f }
        $codeLines = $parts.Code -split "`n"
        $comLines = $parts.Comments -split "`n"
        $raw = [IO.File]::ReadAllText($f) -split "`n"
        $rel = $f
        if (-not [string]::IsNullOrEmpty($Root) -and $f.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)) { $rel = $f.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/') }
        for ($i = 0; $i -lt $codeLines.Length; $i++) {
            $line = $codeLines[$i]
            $allowed = $null
            foreach ($r in $rules) {
                if (-not $r.Regex.IsMatch($line)) { continue }
                if ($null -eq $allowed) { $allowed = @(Get-TcAllowedRules -CodeLines $codeLines -CommentLines $comLines -Index $i) }
                $hits.Add([PSCustomObject]@{ File = $rel; Line = $i + 1; Rule = $r.Id; Why = $r.Why; Text = $raw[$i].Trim(); Allowed = ($allowed -contains $r.Id) })
            }
        }
    }
    $hits.ToArray()
}

# Files the check scans: src/ and mcp-server/ (.ps1 .psm1 .js .mjs, not mcp-server/test/) and
# tests/Integration/*.ps1.
function Test-TcForbiddenScope {
    param([string]$RelativePath)
    $p = $RelativePath.Replace('\', '/')
    if ($p -notmatch '\.(ps1|psm1|js|mjs)$') { return $false }
    if ($p -match '^src/') { return $true }
    if ($p -match '^mcp-server/' -and $p -notmatch '^mcp-server/(test|node_modules)/') { return $true }
    if ($p -match '^tests/Integration/[^/]+\.ps1$') { return $true }
    $false
}
