# #78: de-identification for New-TcIssueReport. Pure string / object functions: no IDE, no ADS, no network.
# The report is posted to a PUBLIC repository, so everything that can identify a person, a machine, a
# customer project or a credential is masked before the text goes into the pre-filled issue URL.
# Masks are heuristics: they cannot know a customer name inside a free-text sentence (use -ExtraMask
# of New-TcIssueReport for that), a token that is split across two lines is not recognised, and the
# caller must still read the body before submitting it. When a path cannot be told apart from the
# prose behind it, the whole rest of the line is masked (privacy over readability). Order of work:
# mask the (wide-cut) text first, cut the MASKED text afterwards at a word boundary, never the other
# way round (a cut before masking leaves a prefix of a token that no rule recognises any more).
# Known limits: a path that Out-String / the console wrapped over two lines is two fragments (the
# second one is not seen as a path), and a token split across lines is not recognised.

function Add-TcMaskCount {
    param([hashtable]$Counts, [string]$Name, [int]$By = 1)
    if ($Counts.ContainsKey($Name)) { $Counts[$Name] = [int]$Counts[$Name] + $By } else { $Counts[$Name] = $By }
}

# Project / solution files whose path is reduced to the file name.
$script:TcDeidProjectExtensions = 'sln|tsproj|plcproj|tsp|xti|xtd|tmc|tpy|library|compiled-library|project|tcpou|tcdut|tcgvl|tctto|tcio|tcvis|xml|tnzip|tszip|zip'
# Other file extensions whose leaf is kept (diagnostics: x.log, cfg.ini); a leaf without one of them is masked.
$script:TcDeidKeepExtensions = 'log|txt|json|ini|cfg|csv|dll|exe|bak|7z|md|pdf|bat|ps1|lib'
# Hosts whose URLs are kept as they are.
$script:TcDeidUrlWhitelist = '(?i)^(?:github\.com|infosys\.beckhoff\.com|learn\.microsoft\.com)$'
# Known TwinCAT / Beckhoff product folders whose full path is kept (no customer data in them). Anything
# else (TwinCAT\Projects, Temp, Program Files\<vendor>, Windows\Temp ...) follows the normal rules.
$script:TcDeidSystemPath = '(?i)^(?:file:/{2,3})?[A-Za-z]:[\\/]+(?:TwinCAT[\\/]+3\.\d+[\\/]+(?:Boot|Config|Components|Target|Repository|System)|Program Files(?: \(x86\))?[\\/]+Beckhoff|ProgramData[\\/]+Beckhoff|Users[\\/]+<user>[\\/]+AppData[\\/]+Local[\\/]+Beckhoff)(?:[\\/]|\s|$)'
# Folder names that carry no customer information (never added to the mask list).
$script:TcDeidGenericFolders = '(?i)^(?:users?|documents?|desktop|onedrive|projects?|src|source|sources|plc|pous|duts|gvls|temp|tmp|appdata|local|roaming|downloads?|program files|programdata|windows|system32|work|data|backup|backups|archive|bin|obj|lib|libs|build|builds|test|tests|docs?|logs?|config|configs?|twincat|beckhoff|common|shared|public|system|boot|repository|target|components|library|libraries|scripts?|tools?|modules?|windowspowershell|repos?|git|new|old|demo|files?|share|shares|net|org|com|the|and|gmbh|ltd|inc|co|visual studio|vs|x64|x86|debug|release|publish|output|in|out|root|home|mnt|drive)$'

# Cuts RAW text to at most Cap characters (wide cap, before masking) and drops the partial token at the
# cut, so no prefix of a token is left behind. A trailing run longer than 200 characters stays (it is long
# enough for the length based rules).
function Limit-TcRawText {
    param([string]$Text, [int]$Cap)
    if ($null -eq $Text -or $Text.Length -le $Cap) { return $Text }
    $n = $Cap
    if ([char]::IsHighSurrogate($Text[$n - 1])) { $n-- }
    $cut = $Text.Substring(0, $n)
    $m = [regex]::Match($cut, '\S{1,200}$')
    if ($m.Success -and $m.Length -lt $cut.Length) { $cut = $cut.Substring(0, $cut.Length - $m.Length) }
    return $cut
}

# Cuts MASKED text to at most Cap characters at a word boundary (backs off up to 200 characters, else
# drops the last token) and never inside a <placeholder>. The caller appends its marker.
function Limit-TcMaskedText {
    param([string]$Text, [int]$Cap)
    if ($null -eq $Text -or $Text.Length -le $Cap) { return $Text }
    $n = [Math]::Max(0, $Cap)
    if ($n -gt 0 -and [char]::IsHighSurrogate($Text[$n - 1])) { $n-- }
    $lt = if ($n -gt 0) { $Text.LastIndexOf('<', $n - 1) } else { -1 }
    if ($lt -ge 0 -and $lt -ge $n - 16) {
        $gt = $Text.IndexOf('>', $lt)
        if ($gt -ge $n) { $n = $lt }
    }
    $min = [Math]::Max(0, $n - 200)
    $found = -1
    for ($i = $n; $i -gt $min; $i--) {
        $ch = $Text[$i - 1]
        if ([char]::IsWhiteSpace($ch) -or ',;:"''()[]{}=<>'.IndexOf($ch) -ge 0) { $found = $i; break }
    }
    if ($found -ge 0) { $n = $found }
    else {
        $ws = $Text.LastIndexOfAny([char[]]@(' ', "`t", "`r", "`n"), [Math]::Max(0, $n - 1))
        if ($ws -gt 0) { $n = $ws }
    }
    return $Text.Substring(0, $n).TrimEnd()
}

# Folder names of a masked path -> $Counts['__folders'] (case-insensitive set). They are masked as words
# in the rest of the text and in the other inputs ("because ACME license expired"). Generic names stay.
function Add-TcFolderNames {
    param([hashtable]$Counts, [string]$DirText)
    if ([string]::IsNullOrEmpty($DirText)) { return }
    if (-not $Counts.ContainsKey('__folders')) { $Counts['__folders'] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase) }
    $set = $Counts['__folders']
    $first = $true
    foreach ($seg in ($DirText -split '[\\/]+')) {
        if ($first) { $first = $false; if ($seg -match '^(?:[A-Za-z]:|file:|X:)?$') { continue } }
        $seg = $seg.Trim()
        if ($seg.Length -lt 3 -or $seg.Length -gt 80 -or $seg.Contains('<') -or $seg.Contains('>')) { continue }
        if ($seg -notmatch $script:TcDeidGenericFolders -and $seg -notmatch '^\d+$') { [void]$set.Add($seg) }
        foreach ($w in ($seg -split '[\s_.\-]+')) {
            if ($w.Length -ge 3 -and $w -notmatch $script:TcDeidGenericFolders -and $w -notmatch '^\d+$') { [void]$set.Add($w) }
        }
    }
}

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

# Replaces lone UTF-16 surrogates (they cannot be URL-encoded) with U+FFFD.
function Repair-TcSurrogates {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    return [regex]::Replace($Text, '[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]', [string][char]0xFFFD)
}

# One drive / UNC-less path (already cut to its extent) -> masked text. System folders stay.
function Convert-TcDeidPath {
    param([string]$Path, [hashtable]$Counts)
    if ($Path -match $script:TcDeidSystemPath) { return $Path }
    $sepMatch = [regex]::Match($Path, '[\\/]')
    $sep = if ($sepMatch.Success) { $sepMatch.Value } else { '\' }
    $leaf = ''
    $rest = ''
    $kind = 'path'
    $tail = ''
    # a project / solution file: the first leaf (no separator inside, at most 4 words) that carries a project extension
    $pm = [regex]::Match($Path, '(?i)[\\/](?<leaf>(?:[^\\/\s]+\s+){0,3}?[^\\/\s]*?\.(?:' + $script:TcDeidProjectExtensions + '))(?![A-Za-z0-9\\/-])')
    if ($pm.Success) {
        $leaf = $pm.Groups['leaf'].Value
        $rest = $Path.Substring($pm.Index + 1 + $leaf.Length)
        $kind = 'project-path'
        Add-TcFolderNames -Counts $Counts -DirText $Path.Substring(0, $pm.Index)
    }
    else {
        $idx = $Path.LastIndexOfAny([char[]]@([char]92, [char]47))
        $tail = if ($idx -ge 0) { $Path.Substring($idx + 1) } else { '' }
        $dirEnd = if ($idx -ge 0) { $idx } else { 0 }
        if ($tail -ne '') {
            $tok = [regex]::Match($tail, '^\S+').Value
            # "build.log:42: error" -> the leaf is build.log; the line number and the message stay
            $clean = ($tok.TrimEnd(')', ']', '}', '.', ',', ';', ':') -replace '(?::\d+)+$', '')
            if ($clean -match ('(?i)\.(?:' + $script:TcDeidKeepExtensions + ')$')) { $leaf = $clean; $rest = $tail.Substring($clean.Length) }
        }
        # the folders (and a short extension-less last segment, which is a folder too) become mask words
        $dirText = $Path.Substring(0, $dirEnd)
        if ($leaf -eq '' -and $tail -ne '' -and $tail.Length -le 60 -and $tail -notmatch '[:<>]') { $dirText = $dirText + '/' + $tail }
        Add-TcFolderNames -Counts $Counts -DirText $dirText
    }
    Add-TcMaskCount -Counts $Counts -Name $kind
    if ($leaf -ne '') { return '<path>' + $sep + $leaf + $rest }
    if ($tail -eq '') { return '<path>' + $sep }
    return '<path>'
}

function ConvertTo-TcDeidentifiedText {
    <#
    .SYNOPSIS
        Masks user names, machine names, hosts / URLs, AMS NetIds, IPs / MACs, e-mail addresses, project
        paths and secrets in one string (#78). Increments $Counts[<mask name>] for every replacement.
    .PARAMETER Text
        The text to mask (a $null / empty string is returned unchanged).
    .PARAMETER Counts
        Hashtable that receives the number of replacements per mask name.
    .PARAMETER ExtraMask
        Literal strings (customer name, site name, solution name ...) replaced with <redacted>
        (case-insensitive; text inside <...> placeholders is never touched).
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
    $s = Repair-TcSurrogates $Text
    if ($s.Length -gt 100000) { $s = Limit-TcRawText -Text $s -Cap 100000 }
    $c = $Counts

    # 1. URLs: host (and port, user info) and path are identifying, except a few public documentation hosts
    $ev = {
        param($m)
        $auth = $m.Groups['auth'].Value
        $hostName = $auth
        $at = $hostName.LastIndexOf('@')
        if ($at -ge 0) { $hostName = $hostName.Substring($at + 1) }
        $hostName = ($hostName -replace ':\d*$', '')
        if ($at -lt 0 -and $hostName -match $script:TcDeidUrlWhitelist) { return $m.Value }
        Add-TcMaskCount -Counts $c -Name 'url'
        $out = $m.Groups['scheme'].Value + '://<url-host>'
        if ($m.Groups['rest'].Value.Length -gt 1) { $out += '/<path>' }
        return $out
    }
    $s = Invoke-TcRegexMap -Text $s -Pattern '(?i)\b(?<scheme>https?|ftps?|wss?|tc|ads)://(?<auth>[^/\s"''<>)\]]*)(?<rest>[^\s"''<>)\]]*)' -Map $ev

    # 2. credentials: "password = x", "password: ""two words""", "password is x", "Authorization: Bearer x"
    $ev = {
        param($m)
        $v = $m.Groups[3].Value
        if ($v.StartsWith('<') -or $v -match '^["'']<') { return $m.Value }
        Add-TcMaskCount -Counts $c -Name 'secret'
        $q = ''
        if ($v.Length -gt 0 -and ($v[0] -eq '"' -or $v[0] -eq "'")) { $q = [string]$v[0] }
        return $m.Groups[1].Value + $m.Groups[2].Value + $q + '<secret>' + $q
    }
    $s = Invoke-TcRegexMap -Text $s -Pattern '(?i)\b(password|passwd|pwd|passphrase|secret|token|api[_-]?key|authorization|credentials?)(\s*["'']?\s*[:=]\s*|\s+(?:is|was)\s+)("[^"\r\n]*"|''[^''\r\n]*''|(?:(?:Bearer|Basic)\s+)?[^\s"'',;&]+)' -Map $ev
    # host-like keys in text ("Address=cx-5a1b2c")
    $ev = {
        param($m)
        if ($m.Groups[3].Value.StartsWith('<')) { return $m.Value }
        Add-TcMaskCount -Counts $c -Name 'host-key'
        return $m.Groups[1].Value + $m.Groups[2].Value + '<host>'
    }
    $s = Invoke-TcRegexMap -Text $s -Pattern '(?i)\b(address|hostname|routename|computername|machinename)(\s*["'']?\s*[:=]\s*["'']?)([^\s"'',;&]+)' -Map $ev
    # PowerShell parameters that name a machine / route / address: "-Name ACME-CX01 -Address 10.2.3.4"
    $ev = {
        param($m)
        if ($m.Groups[2].Value.StartsWith('<')) { return $m.Value }
        Add-TcMaskCount -Counts $c -Name 'host-key'
        return $m.Groups[1].Value + '<host>'
    }
    $s = Invoke-TcRegexMap -Text $s -Pattern '(?i)((?<![\w-])-(?:Name|RouteName|Address|HostName|ComputerName)(?::|\s+))("[^"
]*"|''[^''
]*''|[^\s"'',;&]+)' -Map $ev
    # dotless route / target names: CX-5A1B2C (CX default names), <name>:<ADS or TwinCAT port>
    $ev = { param($m) Add-TcMaskCount -Counts $c -Name 'host-name'; return '<host>' }
    $s = Invoke-TcRegexMap -Text $s -Pattern '(?i)(?<![A-Za-z0-9-])CX-[0-9A-F]{6}(?:-[A-Za-z0-9_-]+)?(?![A-Za-z0-9-]|\.[A-Za-z0-9])' -Map $ev
    $ev = { param($m) Add-TcMaskCount -Counts $c -Name 'host-name'; return '<host>' + $m.Groups[1].Value }
    $s = Invoke-TcRegexMap -Text $s -Pattern '(?<![\w.:/\\<>-])[A-Za-z][A-Za-z0-9_-]{2,62}(:(?:48898|851|852|853|801|10000))(?![0-9])' -Map $ev
    # well-known token shapes (GitHub, OpenAI-style, AWS, Bearer, JWT)
    $ev = { param($m) Add-TcMaskCount -Counts $c -Name 'token'; return '<token>' }
    $s = Invoke-TcRegexMap -Text $s -Pattern '\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{16,}|AKIA[0-9A-Z]{16}|eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,})' -Map $ev
    $s = Invoke-TcRegexMap -Text $s -Pattern '(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{16,}' -Map $ev

    # 3. e-mail addresses (left boundary and bounded quantifiers keep the scan linear)
    $ev = { param($m) Add-TcMaskCount -Counts $c -Name 'email'; return '<email>' }
    $s = Invoke-TcRegexMap -Text $s -Pattern '(?<![\p{L}\p{N}._%+-])[\p{L}\p{N}._%+-]{1,64}@[\p{L}\p{N}-]{1,63}(?:\.[\p{L}\p{N}-]{1,63}){1,8}' -Map $ev

    # 4. TwinCAT tree paths below TIPC^: every segment after the first is a project / PLC / object name
    $ev = {
        param($m)
        $segs = $m.Value.Split('^')
        Add-TcMaskCount -Counts $c -Name 'tree-path'
        return 'TIPC' + ((1..($segs.Count - 1) | ForEach-Object { '^<segment>' }) -join '')
    }
    $s = Invoke-TcRegexMap -Text $s -Pattern '\bTIPC\^[^\r\n"''`;,|]*' -Map $ev

    # 5. user names inside paths: C:\Users\<name>\ -> C:\Users\<user>\ (also the JSON-doubled form)
    $ev = {
        param($m)
        if ($m.Groups[2].Value -eq '<user>') { return $m.Value }
        Add-TcMaskCount -Counts $c -Name 'user-path'
        return $m.Groups[1].Value + '<user>'
    }
    $s = Invoke-TcRegexMap -Text $s -Pattern '(?i)([A-Za-z]:\\{1,2}Users\\{1,2}|[A-Za-z]:/Users/|/Users/|/home/)([^\\/:*?"<>|\s]+)' -Map $ev

    # 6. paths. %5C is an encoded backslash
    if ($s -match '[A-Za-z]:%5[Cc]') { $s = [regex]::Replace($s, '%5[Cc]', '\') }
    # 6a. UNC: the server is a machine name, the share and folders carry customer names
    $ev = {
        param($m)
        $rest = $m.Groups['rest'].Value
        Add-TcMaskCount -Counts $c -Name 'unc-host'
        if ($rest.Length -le 1) { return '\\<host>' }
        return '\\<host>\' + (Convert-TcDeidPath -Path ('X:' + $rest) -Counts $c)
    }
    $s = Invoke-TcRegexMap -Text $s -Pattern '(?<![\\A-Za-z0-9:])\\\\(?<host>[^\\/\s"''<>|]+)(?<rest>(?:(?!\s[A-Za-z]:[\\/])[^\r\n"''`|*?])*)' -Map $ev
    # 6b. drive paths (back or forward slashes, file:///), up to a quote / line end / the next path start
    $ev = { param($m) return (Convert-TcDeidPath -Path $m.Value -Counts $c) }
    $stop = '(?!\s[A-Za-z]:[\\/]|\s\\\\|\s\.{1,2}[\\/])'
    $s = Invoke-TcRegexMap -Text $s -Pattern ('(?<![A-Za-z0-9])(?:file:/{2,3})?[A-Za-z]:[\\/](?:' + $stop + '[^\r\n"''`|*?])*') -Map $ev
    # 6c. relative paths (.\x, ..\x, ./x)
    $s = Invoke-TcRegexMap -Text $s -Pattern ('(?<![\w.:/\\])\.{1,2}[\\/](?:' + $stop + '[^\r\n"''`|*?])*') -Map $ev

    # 6d. root-relative paths (\Projects\ACME\Line3\Main.sln): a backslash, a segment of 2+ characters, a backslash
    $s = Invoke-TcRegexMap -Text $s -Pattern ('(?<![\w.:/\\>)\]~])\\(?=[^\\/\s"''<>|:*?]{2,}\\)(?:' + $stop + '[^
"''`|*?])*') -Map ({ param($m) return (Convert-TcDeidPath -Path ('X:' + $m.Value) -Counts $c) })

    # 7. host names with a private / public suffix (documentation hosts stay)
    $ev = {
        param($m)
        if ($m.Value -match '(?i)(^|\.)(github\.com|beckhoff\.com|microsoft\.com)$') { return $m.Value }
        Add-TcMaskCount -Counts $c -Name 'host-name'
        return '<host>'
    }
    $s = Invoke-TcRegexMap -Text $s -Pattern '(?i)(?<![A-Za-z0-9._<-])(?:[A-Za-z0-9-]{1,63}\.){1,6}(?:local|lan|corp|intranet|internal|home|localdomain|lab|site|com|net|org|de|tw|cn|jp|io|co|uk|eu|edu|gov|at|ch|nl|fr|it|us|box|arpa)(?![A-Za-z0-9-])' -Map $ev

    # 8. this machine's own names (computer, user, domain), whole words only; 2 characters are enough for non-ASCII names
    foreach ($pair in @(@('machine-name', $env:COMPUTERNAME, '<host>'), @('user-name', $env:USERNAME, '<user>'), @('machine-name', $env:USERDOMAIN, '<host>'))) {
        $name = [string]$pair[1]
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if ($name.Length -lt 3 -and -not ($name -match '[^\x00-\x7F]' -and $name.Length -ge 2)) { continue }
        $rep = [string]$pair[2]
        $kind = [string]$pair[0]
        $ev = { param($m) Add-TcMaskCount -Counts $c -Name $kind; return $rep }
        $s = Invoke-TcRegexMap -Text $s -Pattern ('(?i)(?<![A-Za-z0-9])' + [regex]::Escape($name) + '(?![A-Za-z0-9])') -Map $ev
    }

    # 9. AMS NetIds (six octets); loopback style 127.x.x.x.y.z is not identifying and stays
    $ev = {
        param($m)
        $oct = @($m.Value.Split('.') | ForEach-Object { [int]$_ })
        if (@($oct | Where-Object { $_ -gt 255 }).Count -gt 0) { return $m.Value }
        if ($oct[0] -eq 127) { return $m.Value }
        Add-TcMaskCount -Counts $c -Name 'ams-netid'
        return '<netid>'
    }
    $s = Invoke-TcRegexMap -Text $s -Pattern '(?<![\d.])(?:\d{1,3}\.){5}\d{1,3}(?![\d.])' -Map $ev

    # 10. IPv4 (loopback and 0.0.0.0 stay; a dotted number right after the WORD version / ver / v is a version)
    $ev = {
        param($m)
        $oct = @($m.Value.Split('.') | ForEach-Object { [int]$_ })
        if (@($oct | Where-Object { $_ -gt 255 }).Count -gt 0) { return $m.Value }
        if ($oct[0] -eq 127 -or $m.Value -eq '0.0.0.0') { return $m.Value }
        Add-TcMaskCount -Counts $c -Name 'ip-address'
        return '<ip>'
    }
    $s = Invoke-TcRegexMap -Text $s -Pattern '(?<![\d.])(?<!\b(?i:version|ver|v)[\s:="'']{0,3})(?:\d{1,3}\.){3}\d{1,3}(?![\d.])' -Map $ev
    # IPv6: full and compressed (::), optional %zone; ::1 stays
    $ev = {
        param($m)
        if ($m.Value -eq '::1') { return $m.Value }
        Add-TcMaskCount -Counts $c -Name 'ip-address'
        return '<ip>'
    }
    $h = '[0-9A-Fa-f]{1,4}'
    $s = Invoke-TcRegexMap -Text $s -Pattern ('(?<![0-9A-Za-z:])(?:(?:' + $h + ':){7}' + $h + '|(?:' + $h + ':){1,7}:(?:' + $h + '(?::' + $h + '){0,5})?|::(?:' + $h + ':){0,6}' + $h + ')(?:%[0-9A-Za-z]{1,16})?(?![0-9A-Za-z:])') -Map $ev
    $ev = { param($m) Add-TcMaskCount -Counts $c -Name 'mac-address'; return '<mac>' }
    $s = Invoke-TcRegexMap -Text $s -Pattern '(?i)(?<![0-9a-f:-])(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}(?![0-9a-f:-])' -Map $ev
    $ev = {
        param($m)
        if ($m.Value -notmatch '[A-Fa-f]' -or $m.Value -notmatch '[0-9]') { return $m.Value }
        Add-TcMaskCount -Counts $c -Name 'mac-address'
        return '<mac>'
    }
    $s = Invoke-TcRegexMap -Text $s -Pattern '(?<![0-9A-Za-z-])[0-9A-Fa-f]{12}(?![0-9A-Za-z-])' -Map $ev

    # 11. long letter+digit runs (base64 / hex keys, license keys); GUIDs and identifiers with _ - . are left alone
    $ev = {
        param($m)
        $v = $m.Value
        if ($v -notmatch '[A-Za-z]' -or $v -notmatch '[0-9]') { return $v }
        Add-TcMaskCount -Counts $c -Name 'long-secret'
        return '<secret>'
    }
    $s = Invoke-TcRegexMap -Text $s -Pattern '(?<![A-Za-z0-9+/_=.-])[A-Za-z0-9+/]{32,}={0,2}(?![A-Za-z0-9+/_=.-])' -Map $ev

    # 12. caller supplied literals and the folder names of the masked paths ("because ACME license expired");
    #     text inside <...> placeholders is skipped so <path> / <user> survive. Longest literal first.
    foreach ($group in @(@('extra', @($ExtraMask)), @('folder-name', @($(if ($c.ContainsKey('__folders')) { $c['__folders'] } else { @() }))))) {
        $kind = [string]$group[0]
        $lits = @($group[1] | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and ([string]$_).Length -ge 2 } | Sort-Object { ([string]$_).Length } -Descending | Select-Object -First 300 -Unique)
        if ($lits.Count -eq 0) { continue }
        $alt = (@($lits | ForEach-Object { [regex]::Escape([string]$_) }) -join '|')
        $ev = {
            param($m)
            if ($m.Groups[1].Success) { return $m.Groups[1].Value }
            Add-TcMaskCount -Counts $c -Name $kind
            return '<redacted>'
        }
        $s = Invoke-TcRegexMap -Text $s -Pattern ('(<[A-Za-z-]{1,20}>)|' + $alt) -Map $ev -IgnoreCase
    }
    return $s
}

# Keys whose VALUE is a credential whatever it looks like (AddAdsRoute Password, ...).
$script:TcDeidSecretKeyPattern = '(?i)^(pass(word|wd|wordenv|phrase)?|pwd|secret|token|api_?key|credentials?|authorization)$'
# Keys whose value is a host / route / machine name.
$script:TcDeidHostKeyPattern = '(?i)^(address|routename|hostname|host|computername|machinename)$'

function ConvertTo-TcDeidentifiedValue {
    <#
    .SYNOPSIS
        #78: masks every string AND every key of an object tree (hashtable / PSCustomObject / array /
        scalar) and returns the masked copy. Values under credential-like keys become <secret>, values
        under host-like keys <host>; -OmitKey drops keys. -State bounds the work: Nodes (default limit
        3000) and leaf strings longer than 3000 characters are cut before masking.
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
        [hashtable]$State,

        [Parameter()]
        [int]$Depth = 0
    )

    if ($null -eq $State) { $State = @{ Nodes = 0; Cut = 0; Chars = 0 } }
    if ($null -eq $Value) { return $null }
    if ($Depth -gt 12) { return '[max depth]' }
    $State.Nodes = [int]$State.Nodes + 1
    if ($State.Nodes -gt 3000) { $State.Cut = [int]$State.Cut + 1; return '[truncated]' }
    if ($Value -is [string]) {
        # wide raw cap (20000) and a total character budget bound the work; the leaf is masked FIRST and the
        # masked text is cut at a word boundary to 3000 characters afterwards
        $State.Chars = [int]$State.Chars + [Math]::Min($Value.Length, 20000)
        if ($State.Chars -gt 150000) { $State.Cut = [int]$State.Cut + 1; return '[truncated]' }
        $str = Limit-TcRawText -Text $Value -Cap 20000
        $masked = ConvertTo-TcDeidentifiedText -Text $str -Counts $Counts -ExtraMask $ExtraMask
        if ($masked.Length -gt 3000) { $masked = (Limit-TcMaskedText -Text $masked -Cap 3000) + ' [cut]' }
        return $masked
    }
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
            # the decision uses the ORIGINAL key; the key itself is masked like any other text
            $maskedKey = ConvertTo-TcDeidentifiedText -Text $k -Counts $Counts -ExtraMask $ExtraMask
            if ($out.Contains($maskedKey)) {
                $n = 2
                while ($out.Contains(('{0}#{1}' -f $maskedKey, $n))) { $n++ }
                $maskedKey = '{0}#{1}' -f $maskedKey, $n
            }
            if ($k -match $script:TcDeidSecretKeyPattern -and $null -ne $p[1] -and -not ($p[1] -is [bool])) {
                Add-TcMaskCount -Counts $Counts -Name 'secret'
                $out[$maskedKey] = '<secret>'
            }
            elseif ($k -match $script:TcDeidHostKeyPattern -and $p[1] -is [string] -and $p[1] -ne '') {
                Add-TcMaskCount -Counts $Counts -Name 'host-key'
                $out[$maskedKey] = '<host>'
            }
            else {
                $out[$maskedKey] = ConvertTo-TcDeidentifiedValue -Value $p[1] -Counts $Counts -ExtraMask $ExtraMask -OmitKey $OmitKey -State $State -Depth ($Depth + 1)
            }
        }
        return $out
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Value) {
            $list.Add((ConvertTo-TcDeidentifiedValue -Value $item -Counts $Counts -ExtraMask $ExtraMask -OmitKey $OmitKey -State $State -Depth ($Depth + 1)))
        }
        return , $list.ToArray()
    }
    return (ConvertTo-TcDeidentifiedText -Text ([string]$Value) -Counts $Counts -ExtraMask $ExtraMask)
}
