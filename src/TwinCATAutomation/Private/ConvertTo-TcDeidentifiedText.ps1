# #78: de-identification for New-TcIssueReport. Pure string / object functions: no IDE, no ADS, no network.
# The report is posted to a PUBLIC repository, so everything that can identify a person, a machine, a
# customer project or a credential is masked before the text goes into the pre-filled issue URL.
# Masks are heuristics: they cannot know a customer name inside a free-text sentence (use -ExtraMask
# of New-TcIssueReport for that) and the caller must still read the body before submitting it.

function Add-TcMaskCount {
    param([hashtable]$Counts, [string]$Name, [int]$By = 1)
    if ($Counts.ContainsKey($Name)) { $Counts[$Name] = [int]$Counts[$Name] + $By } else { $Counts[$Name] = $By }
}

# Project / solution files whose path is reduced to the file name.
$script:TcDeidProjectExtensions = 'sln|tsproj|plcproj|tsp|xti|xtd|tmc|tpy|library|compiled-library|project|tcpou|tcdut|tcgvl|tctto|tcio|tcvis|xml|tnzip|tszip|zip'

# Regex replace with a PowerShell evaluator. No .NET delegate: a scriptblock turned into a MatchEvaluator
# (or closed with GetNewClosure) loses the module scope, so Add-TcMaskCount would not be found.
function Invoke-TcRegexMap {
    param([string]$Text, [string]$Pattern, [scriptblock]$Map, [switch]$IgnoreCase)
    $opt = [System.Text.RegularExpressions.RegexOptions]::None
    if ($IgnoreCase) { $opt = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase }
    $sb = [System.Text.StringBuilder]::new()
    $last = 0
    foreach ($m in [regex]::Matches($Text, $Pattern, $opt)) {
        [void]$sb.Append($Text.Substring($last, $m.Index - $last))
        [void]$sb.Append([string](& $Map $m))
        $last = $m.Index + $m.Length
    }
    [void]$sb.Append($Text.Substring($last))
    return $sb.ToString()
}

function ConvertTo-TcDeidentifiedText {
    <#
    .SYNOPSIS
        Masks user names, machine names, AMS NetIds, IPs / MACs, e-mail addresses, project paths and
        secrets in one string (#78). Increments $Counts[<mask name>] for every replacement.
    .PARAMETER Text
        The text to mask (a $null / empty string is returned unchanged).
    .PARAMETER Counts
        Hashtable that receives the number of replacements per mask name.
    .PARAMETER ExtraMask
        Literal strings (customer name, site name ...) replaced with <redacted> (case-insensitive).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()][AllowEmptyString()]
        [string]$Text,

        [Parameter(Mandatory)]
        [hashtable]$Counts,

        [Parameter()]
        [string[]]$ExtraMask
    )

    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $s = $Text
    $c = $Counts
    $ext = $script:TcDeidProjectExtensions

    # 1. credentials: "password = x", "token: x", "Authorization: x" -> keep the key, drop the value
    $ev = {
        param($m)
        if ($m.Groups[3].Value.StartsWith('<')) { return $m.Value }
        Add-TcMaskCount -Counts $c -Name 'secret'
        return $m.Groups[1].Value + $m.Groups[2].Value + '<secret>'
    }
    $s = Invoke-TcRegexMap -Text $s -Pattern '(?i)\b(password|passwd|pwd|secret|token|api[_-]?key|authorization|credentials?)(\s*["'']?\s*[:=]\s*["'']?)((?:(?:Bearer|Basic)\s+)?[^\s"'',;&]+)' -Map $ev
    # well-known token shapes (GitHub, OpenAI-style, AWS, Bearer, JWT)
    $ev = { param($m) Add-TcMaskCount -Counts $c -Name 'token'; return '<token>' }
    $s = Invoke-TcRegexMap -Text $s -Pattern '\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{16,}|AKIA[0-9A-Z]{16}|eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,})' -Map $ev
    $s = Invoke-TcRegexMap -Text $s -Pattern '(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{16,}' -Map $ev

    # 2. e-mail addresses
    $ev = { param($m) Add-TcMaskCount -Counts $c -Name 'email'; return '<email>' }
    $s = Invoke-TcRegexMap -Text $s -Pattern '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+' -Map $ev

    # 3. Windows / unix user names inside paths: C:\Users\<name>\ -> C:\Users\<user>\ (also the JSON-doubled form)
    $ev = {
        param($m)
        if ($m.Groups[2].Value -eq '<user>') { return $m.Value }
        Add-TcMaskCount -Counts $c -Name 'user-path'
        return $m.Groups[1].Value + '<user>'
    }
    $s = Invoke-TcRegexMap -Text $s -Pattern '(?i)([A-Za-z]:\\{1,2}Users\\{1,2}|/Users/|/home/)([^\\/:*?"<>|\s]+)' -Map $ev

    # 4. UNC paths: the server name is a machine name
    $ev = {
        param($m)
        $rest = $m.Groups['rest'].Value
        Add-TcMaskCount -Counts $c -Name 'unc-host'
        if ([string]::IsNullOrEmpty($rest)) { return '\\<host>' }
        $segs = @($rest.Split('\') | Where-Object { $_ -ne '' })
        if ($segs.Count -ge 2) { return '\\<host>\<path>\' + $segs[$segs.Count - 1] }
        return '\\<host>\' + $segs[0]
    }
    $s = Invoke-TcRegexMap -Text $s -Pattern '(?<![\\A-Za-z0-9])\\\\(?<host>[^\\/\s"''<>|]+)(?<rest>(?:\\[^\\/:*?"<>|\s]+)*)' -Map $ev

    # 5. drive paths: project / solution files -> file name only; any other directory outside the
    #    well-known system folders -> <path>\<leaf> (customer folders carry customer names)
    $word = '[^\\/:*?"|\s]+'   # < > allowed: earlier masks leave <user> / <redacted> inside a path
    $pathRe = '(?<![A-Za-z0-9])[A-Za-z]:\\{1,2}(?:' + $word + '(?: ' + $word + '){0,3}\\{1,2})*(?:' + $word + '(?: ' + $word + '){0,2}?\.(?:' + $ext + ')(?![A-Za-z0-9])|' + $word + ')?'
    $ev = {
        param($m)
        $p = $m.Value
        $sep = '\'
        $mm = [regex]::Match($p, '^[A-Za-z]:(\\{1,2})')
        if ($mm.Success) { $sep = $mm.Groups[1].Value }
        $leaf = ($p -split '\\+')[-1]
        if ([string]::IsNullOrEmpty($leaf)) { return $p }
        if ($leaf -match ('(?i)\.(?:' + $ext + ')$')) {
            Add-TcMaskCount -Counts $c -Name 'project-path'
            return '<path>' + $sep + $leaf
        }
        if ($p -match '(?i)^[A-Za-z]:\\{1,2}(?:TwinCAT|Windows|Program Files(?: \(x86\))?|ProgramData\\{1,2}Beckhoff|Users\\{1,2}<user>\\{1,2}AppData)(?:\\|$)') { return $p }
        if ($p -match '^[A-Za-z]:\\{1,2}[^\\]*$') { return $p }   # a file or folder right under the drive root
        Add-TcMaskCount -Counts $c -Name 'path'
        return '<path>' + $sep + $leaf
    }
    $s = Invoke-TcRegexMap -Text $s -Pattern $pathRe -Map $ev

    # 6. this machine's own names (computer, user, domain), whole words only
    foreach ($pair in @(@('machine-name', $env:COMPUTERNAME, '<host>'), @('user-name', $env:USERNAME, '<user>'), @('machine-name', $env:USERDOMAIN, '<host>'))) {
        $name = [string]$pair[1]
        if ([string]::IsNullOrWhiteSpace($name) -or $name.Length -lt 3) { continue }
        $rep = [string]$pair[2]
        $kind = [string]$pair[0]
        $ev = { param($m) Add-TcMaskCount -Counts $c -Name $kind; return $rep }
        $s = Invoke-TcRegexMap -Text $s -Pattern ('(?i)(?<![A-Za-z0-9])' + [regex]::Escape($name) + '(?![A-Za-z0-9])') -Map $ev
    }

    # 7. AMS NetIds (six octets); loopback style 127.x.x.x.y.z is not identifying and stays
    $ev = {
        param($m)
        $oct = @($m.Value.Split('.') | ForEach-Object { [int]$_ })
        if (@($oct | Where-Object { $_ -gt 255 }).Count -gt 0) { return $m.Value }
        if ($oct[0] -eq 127) { return $m.Value }
        Add-TcMaskCount -Counts $c -Name 'ams-netid'
        return '<netid>'
    }
    $s = Invoke-TcRegexMap -Text $s -Pattern '(?<![\d.])(?:\d{1,3}\.){5}\d{1,3}(?![\d.])' -Map $ev

    # 8. IPv4 (loopback and 0.0.0.0 stay; a dotted number right after "version" / "v" is a version, not an address)
    $ev = {
        param($m)
        $oct = @($m.Value.Split('.') | ForEach-Object { [int]$_ })
        if (@($oct | Where-Object { $_ -gt 255 }).Count -gt 0) { return $m.Value }
        if ($oct[0] -eq 127 -or $m.Value -eq '0.0.0.0') { return $m.Value }
        Add-TcMaskCount -Counts $c -Name 'ip-address'
        return '<ip>'
    }
    $s = Invoke-TcRegexMap -Text $s -Pattern '(?<![\d.])(?<!(?i:version|ver|v)[\s:="'']{0,3})(?:\d{1,3}\.){3}\d{1,3}(?![\d.])' -Map $ev
    $ev = { param($m) Add-TcMaskCount -Counts $c -Name 'ip-address'; return '<ip>' }
    $s = Invoke-TcRegexMap -Text $s -Pattern '(?i)(?<![0-9a-f:])(?:[0-9a-f]{1,4}:){7}[0-9a-f]{1,4}(?![0-9a-f:])' -Map $ev
    $ev = { param($m) Add-TcMaskCount -Counts $c -Name 'mac-address'; return '<mac>' }
    $s = Invoke-TcRegexMap -Text $s -Pattern '(?i)(?<![0-9a-f:-])(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}(?![0-9a-f:-])' -Map $ev

    # 9. long letter+digit runs (base64 / hex keys, license keys); GUIDs and identifiers with _ - . are left alone
    $ev = {
        param($m)
        $v = $m.Value
        if ($v -notmatch '[A-Za-z]' -or $v -notmatch '[0-9]') { return $v }
        Add-TcMaskCount -Counts $c -Name 'long-secret'
        return '<secret>'
    }
    $s = Invoke-TcRegexMap -Text $s -Pattern '(?<![A-Za-z0-9+/_=.-])[A-Za-z0-9+/]{32,}={0,2}(?![A-Za-z0-9+/_=.-])' -Map $ev

    # 10. caller supplied literals
    foreach ($lit in @($ExtraMask)) {
        if ([string]::IsNullOrWhiteSpace($lit) -or $lit.Length -lt 2) { continue }
        $ev = { param($m) Add-TcMaskCount -Counts $c -Name 'extra'; return '<redacted>' }
        $s = Invoke-TcRegexMap -Text $s -Pattern ([regex]::Escape($lit)) -Map $ev -IgnoreCase
    }
    return $s
}

# Keys whose VALUE is a credential whatever it looks like (AddAdsRoute Password, ...).
$script:TcDeidSecretKeyPattern = '(?i)^(pass(word|wd|wordenv)?|pwd|secret|token|api_?key|credentials?|authorization)$'

function ConvertTo-TcDeidentifiedValue {
    <#
    .SYNOPSIS
        #78: masks every string of an object tree (hashtable / PSCustomObject / array / scalar) and
        returns the masked copy. Values under credential-like keys become <secret>; -OmitKey drops keys.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory)]
        [hashtable]$Counts,

        [Parameter()]
        [string[]]$ExtraMask,

        [Parameter()]
        [string[]]$OmitKey,

        [Parameter()]
        [int]$Depth = 0
    )

    if ($null -eq $Value) { return $null }
    if ($Depth -gt 12) { return '[max depth]' }
    if ($Value -is [string]) { return (ConvertTo-TcDeidentifiedText -Text $Value -Counts $Counts -ExtraMask $ExtraMask) }
    if ($Value -is [bool] -or $Value -is [ValueType]) { return $Value }

    $pairs = $null
    if ($Value -is [System.Collections.IDictionary]) {
        $pairs = @($Value.Keys | ForEach-Object { , @([string]$_, $Value[$_]) })
    }
    elseif ($Value -is [System.Management.Automation.PSCustomObject] -or $Value -is [System.Management.Automation.PSObject]) {
        $pairs = @($Value.PSObject.Properties | ForEach-Object { , @([string]$_.Name, $_.Value) })
    }
    if ($null -ne $pairs) {
        $out = [ordered]@{}
        foreach ($p in $pairs) {
            $k = $p[0]
            if (@($OmitKey) -contains $k) { continue }
            if ($k -match $script:TcDeidSecretKeyPattern -and $null -ne $p[1] -and -not ($p[1] -is [bool])) {
                Add-TcMaskCount -Counts $Counts -Name 'secret'
                $out[$k] = '<secret>'
            }
            else {
                $out[$k] = ConvertTo-TcDeidentifiedValue -Value $p[1] -Counts $Counts -ExtraMask $ExtraMask -OmitKey $OmitKey -Depth ($Depth + 1)
            }
        }
        return $out
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Value) {
            $list.Add((ConvertTo-TcDeidentifiedValue -Value $item -Counts $Counts -ExtraMask $ExtraMask -OmitKey $OmitKey -Depth ($Depth + 1)))
        }
        return , $list.ToArray()
    }
    return (ConvertTo-TcDeidentifiedText -Text ([string]$Value) -Counts $Counts -ExtraMask $ExtraMask)
}
