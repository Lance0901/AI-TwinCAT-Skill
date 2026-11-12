# Unit: #78 New-TcIssueReport / MCP ReportIssue. No IDE / ADS / runtime / network needed.
#   (1) de-identification: user names in paths, project paths -> file name, this machine's names,
#       AMS NetIds (loopback stays), IPs / MACs (versions stay), e-mail, credentials / tokens, ExtraMask
#   (2) the URL: base, title / body / labels parameters decode back to data.title / data.body,
#       the cap (MaxUrlLength) with the [truncated] marker while data.body stays complete
#   (3) no network / no IDE / no ADS: the cmdlet works with every such command made to throw,
#       its source has no web / process / gh calls, it is not refused by LIFECYCLE_BLOCKED
#   (4) environment comes from module state only (solution reduced to the file name)
#   powershell.exe -NoProfile -File tests/Unit/issue-report-78.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
$env:TCAUTO_STATE_DIR = Join-Path $env:TEMP ("tcauto-unit-state-78-{0}" -f [guid]::NewGuid().ToString('N'))
$modulePath = Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
Import-Module $modulePath -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 500) { $Detail = $Detail.Substring(0, 500) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $(if ($Ok) { '' } else { $Detail })
    if (-not $Ok) { $script:fail++ }
}
function Get-Query([string]$Url, [string]$Name) {
    $q = $Url.Substring($Url.IndexOf('?') + 1)
    foreach ($pair in $q.Split('&')) {
        $kv = $pair.Split('=', 2)
        if ($kv[0] -eq $Name) { return [System.Uri]::UnescapeDataString($kv[1]) }
    }
    return $null
}

# --- stubs: anything that would touch the IDE, ADS, the network or a process throws
& $mod {
    foreach ($n in 'Get-TcSysManager', 'Ensure-TcAdsConnection', 'Assert-TcConnection', 'Connect-TcIde', 'Connect-TcAds', 'Get-TcIdeInfo') {
        Set-Item -Path "function:script:$n" -Value ([scriptblock]::Create("throw 'IDE/ADS touched: $n'"))
    }
    foreach ($n in 'Invoke-WebRequest', 'Invoke-RestMethod', 'Start-Process', 'Invoke-Expression') {
        Set-Item -Path "function:script:$n" -Value ([scriptblock]::Create("throw 'forbidden call: $n'"))
    }
}

$computer = $env:COMPUTERNAME
$user = $env:USERNAME
$resultJson = '{"success":false,"error":{"code":"BUILD_FAILED","message":"Cannot open C:\\Users\\bob\\Desktop\\ACME Line3\\Main.sln on ' + $computer + ' target 10.1.2.3.1.1 (192.168.1.50 / 127.0.0.1 / fe80:0:0:0:1:2:3:4) mail bob@acme.example mac 00-11-22-33-44-55 password=hunter2 loopback 127.0.0.1.1.1","hint":"HINT-TEXT-SHOULD-BE-DROPPED"},"data":{"key":"AB12cd34EF56gh78IJ90kl12MN34op56qr78","ver":"Version 3.4.3.0","guid":"3f2504e0-4f89-11d3-9a0c-0305e82c3301","user":"' + $user + '"}}'
$r = New-TcIssueReport -Title 'Build fails on C:\Users\bob\p.sln' -Tool 'BuildProject' `
    -Parameters @{ Force = $true; Password = 'abc'; SolutionPath = 'D:\Customers\ACME\Line3\Main.sln'; Token = 'ghp_abcdefghijklmnopqrstuvwxyz0123456789' } `
    -Result $resultJson -Expected 'Build succeeds' -Notes 'Seen at ACME plant, Authorization: Bearer abcdefghijklmnop1234567890 and token=zzz' -ExtraMask 'ACME'
$body = [string]$r.data.body
Check 'success + url + body' ($r.success -and $r.data.url -and $body) ($r | ConvertTo-Json -Compress -Depth 3)

# (1) masks
Check 'user dir keeps the form C:\Users\<user>\AppData\Local\Beckhoff' ((& $mod { $c = @{}; ConvertTo-TcDeidentifiedText -Text 'C:\Users\bob\AppData\Local\Beckhoff\x.log' -Counts $c }) -ceq 'C:\Users\<user>\AppData\Local\Beckhoff\x.log') ''
Check 'bob gone' (-not ($body -cmatch 'bob')) $body
Check 'ACME gone (ExtraMask + path)' (-not ($body -cmatch 'ACME|acme')) $body
Check 'project path reduced to file name' ($body -match '<path>\\\\?Main\.sln' -and $body -notmatch 'Customers' -and $body -notmatch 'Desktop\\') $body
Check 'computer name masked' ($body -notmatch [regex]::Escape($computer) -or $computer.Length -lt 3) $body
Check 'user account name masked' ($body -notmatch ('(?i)\b' + [regex]::Escape($user) + '\b') -or $user.Length -lt 3) $body
Check 'AMS NetId masked, loopback NetId kept' ($body -match '<netid>' -and $body -notmatch '10\.1\.2\.3\.1\.1' -and $body -match '127\.0\.0\.1\.1\.1') $body
Check 'IPv4 / IPv6 masked, 127.0.0.1 kept' ($body -notmatch '192\.168\.1\.50' -and $body -notmatch 'fe80' -and $body -match '127\.0\.0\.1') $body
Check 'MAC masked' ($body -notmatch '00-11-22-33-44-55' -and $body -match '<mac>') $body
Check 'e-mail masked' ($body -notmatch 'acme\.example' -and $body -match '<email>') $body
Check 'password= / Password key / token masked' ($body -notmatch 'hunter2' -and $body -notmatch '"Password":"abc"' -and $body -notmatch 'ghp_' -and $body -notmatch 'abcdefghijklmnop1234567890' -and $body -notmatch 'token=zzz') $body
Check 'long key masked, GUID and "Version 3.4.3.0" kept' ($body -notmatch 'AB12cd34EF56' -and $body -match '3f2504e0-4f89-11d3-9a0c-0305e82c3301' -and $body -match 'Version 3\.4\.3\.0') $body
Check 'error.hint dropped, error.code shown' ($body -notmatch 'HINT-TEXT' -and $body -match 'error\.code: `BUILD_FAILED`') $body
Check 'masks table + report' ($r.data.masks.'ams-netid' -ge 1 -and $r.data.masks.email -ge 1 -and $r.data.masks.secret -ge 2 -and $r.data.masks.'project-path' -ge 1 -and $r.data.maskReport -match 'Masked:' -and $body -match 'masks applied') ($r.data.masks | ConvertTo-Json -Compress)
Check 'title masked' ($r.data.title -notmatch 'bob' -and $r.data.title -match '<path>\\p\.sln') $r.data.title
$none = New-TcIssueReport -Title 'Nothing to hide'
Check 'no secrets -> report says so' ($none.success -and $none.data.masks.Count -eq 0 -and $none.data.maskReport -match 'No mask was needed' -and $none.data.body -notmatch '## Result' -and $none.data.body -notmatch '## Call') ($none.data | ConvertTo-Json -Compress -Depth 3)
$bad = New-TcIssueReport -Title '   '
Check 'blank title -> INVALID_PARAMS' (-not $bad.success -and $bad.error.code -eq 'INVALID_PARAMS') ($bad | ConvertTo-Json -Compress)
$txt = New-TcIssueReport -Title 't' -Result 'not json {at all'
Check 'non-JSON result is kept as text' ($txt.success -and $txt.data.body -match 'not json \{at all') $txt.data.body
$js = New-TcIssueReport -Title 't' -Parameters '{"Path":"E:\\Cust\\Plant\\x.plcproj","apiKey":"k1"}'
Check 'JSON string parameters are parsed and masked' ($js.data.body -match '<path>' -and $js.data.body -match 'x\.plcproj' -and $js.data.body -notmatch 'Plant' -and $js.data.body -notmatch 'k1"' -and $js.data.body -match '<secret>') $js.data.body

# (2) URL
$base = 'https://github.com/Lance0901/AI-TwinCAT-Skill/issues/new?title='
Check 'url base and parameters' ($r.data.url.StartsWith($base) -and $r.data.url -match '&body=' -and $r.data.url -match '&labels=field-report$') $r.data.url.Substring(0, 120)
Check 'title / body decode back' ((Get-Query $r.data.url 'title') -ceq $r.data.title -and (Get-Query $r.data.url 'body') -ceq $r.data.body -and (Get-Query $r.data.url 'labels') -eq 'field-report' -and -not $r.data.truncated) ''
$nl = New-TcIssueReport -Title 'x' -Label ''
Check 'empty -Label -> no labels parameter' ($nl.data.url -notmatch 'labels=' -and $nl.data.labels.Count -eq 0) $nl.data.url
$big = '{"success":false,"error":{"code":"X","message":"' + ('long line with words 12345 ' * 4000) + '"}}'
$longNotes = ('Notes mit Umlaut and Chinese text ' + ([string][char]0x4E2D + [char]0x6587) * 600)
$rb = New-TcIssueReport -Title 'big' -Tool 'T' -Parameters @{ a = ('p' * 3000) } -Result $big -Notes $longNotes -Expected 'short expected'
Check 'URL capped at 7000, truncated flag + sections' ($rb.data.urlLength -le 7000 -and $rb.data.url.Length -eq $rb.data.urlLength -and $rb.data.truncated -and $rb.data.truncatedSections -contains 'Result') ("{0} {1}" -f $rb.data.urlLength, ($rb.data.truncatedSections -join ','))
$ub = Get-Query $rb.data.url 'body'
Check 'URL body has [truncated], data.body is complete' ($ub -match '\[truncated\]' -and $rb.data.body -notmatch '\[truncated\]' -and $rb.data.body.Length -gt $ub.Length -and $rb.data.body -match 'short expected' -and $ub -match 'short expected') ("{0} vs {1}" -f $rb.data.body.Length, $ub.Length)
$rs = New-TcIssueReport -Title 'big' -Result $big -Notes $longNotes -MaxUrlLength 2000
Check 'MaxUrlLength 2000 honoured' ($rs.data.urlLength -le 2000) $rs.data.urlLength
$rejected = $false
try { $null = New-TcIssueReport -Title 'x' -MaxUrlLength 1999 } catch { $rejected = $true }
Check 'MaxUrlLength below 2000 rejected' $rejected ''
$unicodeTitle = New-TcIssueReport -Title (([string][char]0x4E2D) * 300)
Check 'long title cut to 120 chars' ($unicodeTitle.data.title.Length -le 120) $unicodeTitle.data.title.Length

# (3) no network / IDE / ADS; LIFECYCLE_BLOCKED does not refuse
$null = & $mod { Set-TcLifecycleBlock -AmsNetId '10.7.7.7.1.1' -Command 'Set-TcSystemState' -ErrorCode 'SYSTEM_STATE_TIMEOUT' }
$lb = New-TcIssueReport -Title 'while blocked'
Check 'works while a LIFECYCLE_BLOCKED exists' ($lb.success -and $null -eq $lb.PSObject.Properties['lifecycleBlock'] -and $lb.data.url) ($lb | ConvertTo-Json -Compress -Depth 2)
$src = Get-ChildItem (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation') -Recurse -Include 'New-TcIssueReport.ps1', 'ConvertTo-TcDeidentifiedText.ps1', 'Get-TcIssueEnvironment.ps1'
$forbidden = 'Invoke-WebRequest|Invoke-RestMethod|Net\.WebClient|HttpClient|Start-Process|Invoke-Expression|\bgh\b\s+(issue|api)|Get-TcSysManager|Ensure-TcAdsConnection|\$script:TcDte|\$script:TcSysManager|\$script:TcAdsClient'
$hits = @()
foreach ($f in $src) {
    $tokens = $null; $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
    foreach ($t in $tokens) {
        if ($t.Kind -eq 'Comment') { continue }
        if ($t.Text -match $forbidden) { $hits += ('{0}: {1}' -f $f.Name, $t.Text) }
    }
    # no git (or any other native program) is started: no command named git / gh / curl / powershell ...
    $cmds = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($cmd in $cmds) {
        $name = $cmd.GetCommandName()
        if ($name -match '^(?i:git|gh|curl|wget|powershell|pwsh|cmd|node|npm)(\.exe)?$') { $hits += ('{0}: command {1}' -f $f.Name, $name) }
    }
}
Check 'source: no web / process / gh / IDE / ADS access (3 files)' ($src.Count -eq 3 -and $hits.Count -eq 0) ($hits -join '; ')

# (4) environment from module state only
& $mod { $script:TcIdeConnected = $true; $script:TcProgId = 'VisualStudio.DTE.17.0'; $script:TcSolutionPath = 'C:\Users\bob\Customer X\Plant.sln'; $script:TcAdsConnected = $true; $script:TcAdsAmsNetId = '10.1.2.3.1.1'; $script:TcAdsAssemblyVersion = '4.4.0.0' }
$e = New-TcIssueReport -Title 'env'
Check 'environment: module, powershell, ProgId, ads dll; solution file name OMITTED by default' ($e.data.environment.module -match '^TwinCATAutomation \d' -and $e.data.environment.powershell -match '5\.1|7\.' -and $e.data.environment.ideProgId -eq 'VisualStudio.DTE.17.0' -and -not $e.data.environment.Contains('solutionFile') -and $e.data.environment.adsDllVersion -eq '4.4.0.0') ($e.data.environment | ConvertTo-Json -Compress)
Check 'environment: no AmsNetId, no customer folder' ($e.data.body -notmatch '10\.1\.2\.3' -and $e.data.body -notmatch 'Customer X' -and $e.data.body -notmatch 'bob') ''
$ne = New-TcIssueReport -Title 'env' -NoEnvironment
Check '-NoEnvironment drops the section' ($ne.data.body -notmatch '## Environment' -and $null -eq $ne.data.environment) ''

# ---- review round 1 (every leak the reviewer probed is a test)
function Mask([string]$Text, [string[]]$Extra) { $c = @{}; & $mod { param($x, $c, $e) ConvertTo-TcDeidentifiedText -Text $x -Counts $c -ExtraMask $e } $Text $c $Extra }
$bs = [string][char]92
function P([string]$s) { $s -replace '/B/', $bs }    # write backslashes without escaping trouble
$cn = [string][char]0x5BA2 + [char]0x6236 + 'A'       # a non-ASCII customer name

# 1 any number of spaces / non-ASCII in a drive path
$o = Mask 'D:\OneDrive - ACME Automation GmbH\Projects\Line3\Main.sln'
Check 'path with many spaces -> <path>\Main.sln' ($o -ceq '<path>\Main.sln') $o
$o = Mask 'D:\Work Folder With Many Spaces Here\Cust\Main.sln'
Check 'path with 5 spaces in a folder' ($o -ceq '<path>\Main.sln') $o
$o = Mask ('D:\' + $cn + ' x\Line 3\Main.sln')
Check 'non-ASCII customer folder' ($o -ceq '<path>\Main.sln') $o
$o = Mask 'D:\Projects\ACME\Line3\PLC\POUs\MAIN.TcPOU(12): error C0077'
Check 'error line keeps the file and the message, not the folders' ($o -ceq '<path>\MAIN.TcPOU(12): error C0077') $o
$o = Mask 'Open D:\Cust\ACME\a.sln then D:\Cust\ACME\b.sln'
Check 'two paths in one sentence' ($o -ceq 'Open <path>\a.sln then <path>\b.sln') $o
$o = Mask 'Message: Cannot find path ''D:\Cust\ACME\x.txt'' because it does not exist.'
Check 'quoted path ends at the quote' ($o -ceq 'Message: Cannot find path ''<path>\x.txt'' because it does not exist.') $o
# 2 directories, trailing backslash
$o = Mask 'D:\Cust\ACME\Line3\'
Check 'trailing-backslash directory masked' ($o -ceq '<path>\') $o
$o = Mask 'D:\Cust\ACME\Line3'
Check 'directory without extension masked' ($o -ceq '<path>') $o
$o = Mask 'D:\Cust\ACME\Line3\notes.txt'
Check 'diagnostic file keeps its name' ($o -ceq '<path>\notes.txt') $o
$o = Mask 'C:\TwinCAT\3.1\Boot\CurrentConfig.xml and C:\Program Files\ACME Tools\cfg.ini'
Check 'TwinCAT product folders keep the full path (even .xml); Program Files\<vendor> does not' ($o -ceq 'C:\TwinCAT\3.1\Boot\CurrentConfig.xml and <path>\cfg.ini') $o
# 3 IPv4 next to words ending in v / ver
foreach ($t in 'connect to server 192.168.1.20 failed', 'Server: 192.168.1.20', 'driver=10.0.0.5', 'dev 10.0.0.5', 'Observer 10.0.0.5') {
    $o = Mask $t
    Check "IPv4 masked: $t" ($o -notmatch '\d+\.\d+\.\d+\.\d+' -and $o -match '<ip>') $o
}
foreach ($t in 'Version 3.4.3.0', 'version=3.4.3.0', 'ver 3.4.3.0') {
    $o = Mask $t
    Check "version kept: $t" ($o -ceq $t) $o
}
# 7 forward slashes, file:///, relative, %5C, UNC
$o = Mask 'D:/Projects/ACME/Line3/Main.sln'
Check 'forward-slash drive path' ($o -ceq '<path>/Main.sln') $o
$o = Mask 'file:///D:/Projects/ACME/Line3/Main.sln'
Check 'file:/// path' ($o -ceq '<path>/Main.sln') $o
$o = Mask '.\ACME\Line3\Main.sln and ..\Cust\x.plcproj'
Check 'relative paths' ($o -ceq '<path>\Main.sln and <path>\x.plcproj') $o
$o = Mask 'D:%5CCust%5CACME%5Cx.sln'
Check '%5C encoded backslashes' ($o -notmatch 'ACME|Cust') $o
$o = Mask ($bs + $bs + 'fileserver01' + $bs + 'eng$' + $bs + 'ACME' + $bs + 'Line3' + $bs + 'Main.sln')
Check 'UNC share path' ($o -ceq ($bs + $bs + '<host>' + $bs + '<path>' + $bs + 'Main.sln')) $o
$o = Mask ($bs + $bs + 'fileserver01.acme.local' + $bs + 'share')
Check 'UNC host with domain' ($o -notmatch 'fileserver|acme' -and $o -match '<host>') $o
$o = Mask 'C:\Users\Bob Smith\Desktop\x.sln'
Check 'user name with a space' ($o -notmatch 'Bob|Smith') $o
$o = Mask 'C:\Users\bob\AppData\Local\Temp\x.log'
Check 'AppData\Local\Temp is not a whitelisted folder' ($o -ceq '<path>\x.log') $o
# 8 hosts / URLs
$o = Mask 'https://acme.sharepoint.com/sites/Line3/Shared%20Documents/x.sln and https://acme-my.sharepoint.com/personal/bob_acme_com/Documents'
Check 'SharePoint URLs masked' ($o -notmatch 'acme|bob|Line3|sharepoint') $o
$o = Mask 'see https://github.com/Lance0901/AI-TwinCAT-Skill/issues/78 and https://infosys.beckhoff.com/x and https://learn.microsoft.com/y'
Check 'whitelisted documentation hosts stay' ($o -ceq 'see https://github.com/Lance0901/AI-TwinCAT-Skill/issues/78 and https://infosys.beckhoff.com/x and https://learn.microsoft.com/y') $o
$o = Mask 'http://192.168.1.20:8080/x tc://cx-5a1b2c.acme.local/route'
Check 'URL with IP / tc:// host' ($o -notmatch '192\.168|acme|cx-5a1b2c') $o
$o = Mask 'route Address=cx-5a1b2c.acme.local HostName: CX-5A1B2C RouteName=Line3Route'
Check 'Address / HostName / RouteName text' ($o -notmatch 'cx-5a1b2c|CX-5A1B2C|acme|Line3Route') $o
# 9 IPv6 / MAC
foreach ($t in 'fe80::1c2b:3d4e:5f60:7a8b%12', '2001:db8::1', '2001:0db8:0000:0000:0000:0000:0000:0001', 'at fd00::10 up') {
    $o = Mask $t
    Check "IPv6 masked: $t" ($o -notmatch '[0-9a-f]{2,4}:[0-9a-f]' -and $o -match '<ip>') $o
}
$o = Mask 'loopback ::1 stays'
Check '::1 stays' ($o -ceq 'loopback ::1 stays') $o
$o = Mask 'mac 00AA22BB44CC and 202611051030'
Check 'MAC without separators masked, a number stays' ($o -ceq 'mac <mac> and 202611051030') $o
# 13 quoted secrets
$o = Mask 'password: "my secret pass" and password is hunter2 and pwd=''two words'' end'
Check 'quoted / "is" secrets' ($o -notmatch 'my secret|pass"|hunter2|two words') $o
# 12 short non-ASCII user names
$oldUser = $env:USERNAME
$env:USERNAME = [string][char]0x738B + [char]0x660E
$o = Mask ('hello ' + $env:USERNAME + ' there')
$env:USERNAME = 'ab'
$o2 = Mask 'hello ab there'
$env:USERNAME = $oldUser
Check '2-char non-ASCII user name masked, 2-char ASCII is not' ($o -ceq 'hello <user> there' -and $o2 -ceq 'hello ab there') ("$o / $o2")
# nit: ExtraMask never corrupts placeholders
$o = Mask 'C:\Users\x\proj\Main.sln mail a@b.example' @('path', 'email')
Check 'ExtraMask path / email leaves <path> <email> intact' ($o -ceq '<path>\Main.sln mail <email>') $o
# 10 TIPC tree paths, solution base name
$o = Mask 'Path TIPC^ACME_Line3^ACME_Line3 Project^POUs^MAIN failed'
Check 'TIPC^ tree path: segments after TIPC masked' ($o -notmatch 'ACME|POUs|MAIN' -and $o -match '^Path TIPC\^<segment>\^<segment>') $o
& $mod { $script:TcSolutionPath = 'D:\x\ZetaCorpLine.sln' }
$k = New-TcIssueReport -Title 'ZetaCorpLine broke' -Notes 'in the ZetaCorpLine solution; plc TIPC^PlcAlpha7^PlcAlpha7 Project, again PlcAlpha7' -Tool 'x'
Check 'open solution base name and PLC names from TIPC^ masked everywhere' ($k.data.body -notmatch 'ZetaCorpLine|PlcAlpha7' -and $k.data.title -notmatch 'ZetaCorpLine') ($k.data.title + ' | ' + $k.data.body)
$ki = New-TcIssueReport -Title 'x' -IncludeSolutionName
Check '-IncludeSolutionName adds solutionFile' ($ki.data.environment.solutionFile -eq 'ZetaCorpLine.sln') ($ki.data.environment | ConvertTo-Json -Compress)
& $mod { $script:TcSolutionPath = $null }
# 6 keys
$kr = New-TcIssueReport -Title 't' -NoEnvironment -ExtraMask 'ACME' -Result @{ success = $false; data = @{ 'D:\Cust\Plant9\x.sln' = 'k'; '192.168.5.5' = 1; 'ACMEKey' = 2; Password = 'p'; Address = 'cx-1'; RouteName = 'r' } }
Check 'object keys masked (path, IP, ExtraMask); secret / host keys by original key' ($kr.data.body -notmatch 'Plant9|192\.168|ACME|"p"|cx-1|"r"' -and $kr.data.body -match '<secret>' -and $kr.data.body -match '<host>') $kr.data.body
# 14 error.code
$kc = New-TcIssueReport -Title 't' -NoEnvironment -ExtraMask 'ACME' -Result @{ success = $false; error = @{ code = 'D:\Cust\ACME\x ACME'; message = 'm' } }
$kg = New-TcIssueReport -Title 't' -NoEnvironment -Result @{ success = $false; error = @{ code = 'BUILD_FAILED'; message = 'm' } }
Check 'error.code: a code-shaped value is shown, anything else is masked' ($kc.data.body -notmatch 'ACME|Cust' -and $kg.data.body -match 'error\.code: `BUILD_FAILED`') $kc.data.body
# nit: label
$kl = New-TcIssueReport -Title 't' -NoEnvironment -Label 'C:\Users\bob\x lbl'
Check '-Label is masked / sanitised' ($kl.data.url -notmatch 'bob' -and ($kl.data.labels -join ',') -notmatch 'bob') $kl.data.url
# 4 huge inputs: no exception, URL within the limit
$sw = [Diagnostics.Stopwatch]::StartNew()
try {
    $h1 = New-TcIssueReport -Title 'big' -Result ('x ' * 35000) -Notes ('y ' * 35000) -Expected ('e ' * 35000) -Parameters ('p ' * 35000) -NoEnvironment   # words, not one run: a run without a boundary is dropped completely since #121
    Check '70000-char inputs: success, URL within the limit' ($h1.success -and $h1.data.urlLength -le 7000 -and $h1.data.url.Length -eq $h1.data.urlLength -and $h1.data.truncated) ("{0}" -f $h1.data.urlLength)
    $h2 = New-TcIssueReport -Title 'big' -Result ('{"a":"' + ('z' * 50000) + '"}') -Parameters ('{"b":"' + ('w' * 50000) + '"}') -NoEnvironment
    Check '50000-char JSON strings: success, URL within the limit' ($h2.success -and $h2.data.urlLength -le 7000) ("{0}" -f $h2.data.urlLength)
    $arr = @(1..6000 | ForEach-Object { @{ k = "item $_ 192.168.1.$($_ % 250)" } })
    $h3 = New-TcIssueReport -Title 'many' -Result @{ success = $false; data = $arr } -NoEnvironment
    Check '6000-element result: success, node budget, URL within the limit' ($h3.success -and $h3.data.urlLength -le 7000 -and $h3.data.body -notmatch '192\.168') ("{0}" -f $h3.data.urlLength)
    $cjk = ([string][char]0x4E2D + [char]0x6587 + [char]::ConvertFromUtf32(0x1F600)) * 8000
    $h4 = New-TcIssueReport -Title 'cjk' -Notes $cjk -Result ('{"m":"' + $cjk + '"}')
    Check 'CJK + emoji inputs: success, URL within the limit, decodes' ($h4.success -and $h4.data.urlLength -le 7000 -and $h4.data.url.Length -eq $h4.data.urlLength -and (Get-Query $h4.data.url 'body').Length -gt 100) ("{0}" -f $h4.data.urlLength)
}
catch { Check 'huge inputs do not throw' $false $_.Exception.Message }
Check 'huge inputs finish in reasonable time' ($sw.Elapsed.TotalSeconds -lt 120) ("{0:n1}s" -f $sw.Elapsed.TotalSeconds)
# 11 linear time on long runs
foreach ($s in @(('z' * 16000), ('z1' * 8000), ('a b ' * 4000), ('a.b' * 5000), ('x@' * 4000))) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $null = Mask $s
    Check ("regex time on {0}...: {1:n2}s < 3s" -f $s.Substring(0, 4), $sw.Elapsed.TotalSeconds) ($sw.Elapsed.TotalSeconds -lt 3) ''
}
# 5 surrogates
$emoji = [char]::ConvertFromUtf32(0x1F600)
$sg = New-TcIssueReport -Title (('a' * 116) + $emoji + 'bbbbbb') -NoEnvironment
$tv = [string]$sg.data.title
$lone = [regex]::IsMatch($tv, '[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]')
$ok = $true; try { $null = [Uri]::UnescapeDataString((Get-Query $sg.data.url 'title')); [void][System.Text.Encoding]::UTF8.GetBytes($tv) } catch { $ok = $false }
Check 'title cut never splits a surrogate pair' ($sg.success -and -not $lone -and $tv.Length -le 120 -and ($tv -ceq (Get-Query $sg.data.url 'title'))) $tv.Length
$lo = New-TcIssueReport -Title ('x' + [string][char]0xD83D + 'y') -Notes ('n' + [string][char]0xDE00 + 'm') -NoEnvironment
Check 'lone surrogates in the input are replaced by U+FFFD' ($lo.success -and $lo.data.title -ceq ('x' + [string][char]0xFFFD + 'y') -and $lo.data.body -match [string][char]0xFFFD) $lo.data.title
# 15 commit from .git files (no process)
$tmpRoot = Join-Path $env:TEMP ('tcauto-78-{0}' -f [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Force -Path (Join-Path $tmpRoot 'src\TwinCATAutomation'), (Join-Path $tmpRoot '.git\refs\heads'), (Join-Path $tmpRoot 'other\TwinCATAutomation')
Set-Content -LiteralPath (Join-Path $tmpRoot '.git\HEAD') -Value 'ref: refs/heads/feat' -Encoding ASCII
Set-Content -LiteralPath (Join-Path $tmpRoot '.git\refs\heads\feat') -Value 'abcdef0123456789abcdef0123456789abcdef01' -Encoding ASCII
$c1 = & $mod { param($b) Get-TcModuleCommit -ModuleBase $b } (Join-Path $tmpRoot 'src\TwinCATAutomation')
$c2 = & $mod { param($b) Get-TcModuleCommit -ModuleBase $b } (Join-Path $tmpRoot 'other\TwinCATAutomation')
Remove-Item -LiteralPath (Join-Path $tmpRoot '.git\refs\heads\feat')
Set-Content -LiteralPath (Join-Path $tmpRoot '.git\packed-refs') -Value @('# pack-refs', '1234567890abcdef1234567890abcdef12345678 refs/heads/feat') -Encoding ASCII
$c3 = & $mod { param($b) Get-TcModuleCommit -ModuleBase $b } (Join-Path $tmpRoot 'src\TwinCATAutomation')
Remove-Item -LiteralPath $tmpRoot -Recurse -Force
Check 'commit: refs/heads file, packed-refs, and only when ModuleBase is <root>\src\TwinCATAutomation' ($c1 -eq 'abcdef0' -and $null -eq $c2 -and $c3 -eq '1234567') ("$c1 / $c2 / $c3")

# ---- review round 2
# 1 truncation: a token that straddles the cut leaves no prefix (sweep of the cut positions, sampled #241)
function Test-NoPrefix([string]$Body, [string]$Token) {
    for ($i = 0; $i -le $Token.Length - 8; $i++) { if ($Body.Contains($Token.Substring($i, 8))) { return $false } }
    return $true
}
# #241: the sweeps check a sample of their positions: the first two, the last two, the named boundary
# values and every $Every-th one in between, offset from a fixed seed (every run checks the same set)
$sweepRng = New-Object System.Random 241
function Select-SweepSample([int[]]$Positions, [int]$Every, [int[]]$Boundary = @()) {
    $off = $sweepRng.Next($Every)
    $n = $Positions.Count
    @(for ($j = 0; $j -lt $n; $j++) { $p = $Positions[$j]; if ($j -lt 2 -or $j -ge $n - 2 -or $Boundary -contains $p -or $j % $Every -eq $off) { $p } })
}
$sweepTokens =@('AB12cd34EF56gh78IJ90kl12MN34op56qr78', 'ghp_abcdefghijklmnopqrstuvwxyz0123456789', 'bob.smith@acme.example.com', '10.11.12.13.1.1', '192.168.100.200', 'sk-abcdefghijklmnop1234')
$sweepBad = @()
$sw = [Diagnostics.Stopwatch]::StartNew()
foreach ($tok in $sweepTokens) {
    # every cut position k = 1 .. length sampled 1 in 8, plus 7 / 8 / 9 (an 8-char piece left on either side)
    foreach ($k in (Select-SweepSample -Positions (1..$tok.Length) -Every 8 -Boundary @(7, 8, 9))) {
        $pad = ('a ' * 6000).Substring(0, 3000 - $k)
        if (-not $pad.EndsWith(' ')) { $pad = $pad.Substring(0, $pad.Length - 1) + ' ' }
        $r = New-TcIssueReport -Title 't' -Result ([pscustomobject]@{ success = $false; data = [pscustomobject]@{ s = ($pad + $tok + ' end') } }) -NoEnvironment
        if (-not (Test-NoPrefix $r.data.body $tok)) { $sweepBad += "leaf $tok k=$k" }
        $pad2 = ('a ' * 12000).Substring(0, 10000 - $k)
        if (-not $pad2.EndsWith(' ')) { $pad2 = $pad2.Substring(0, $pad2.Length - 1) + ' ' }
        $r = New-TcIssueReport -Title 't' -Notes ($pad2 + $tok + ' end') -NoEnvironment
        if (-not (Test-NoPrefix $r.data.body $tok)) { $sweepBad += "notes $tok k=$k" }
    }
}
Check ("cut sweep: no 8-char piece of a straddling token survives ({0:n0}s)" -f $sw.Elapsed.TotalSeconds) ($sweepBad.Count -eq 0) ($sweepBad -join '; ')
$cutAt = New-TcIssueReport -Title 't' -NoEnvironment -Notes (('word ' * 1990) + 'password=Hunter2Secret! and more words here ' + ('x ' * 400))
Check 'a cut never lands inside a placeholder' ($cutAt.data.body -notmatch '<[a-z-]{1,10}\z|<[a-z-]{1,10}\r?\n\[input' -and $cutAt.data.body -notmatch 'Hunter2') ''
# 2 system path whitelist
foreach ($t in 'C:\TwinCAT\Projects\ACME_Line3\ACME.sln', 'C:\Users\bob\AppData\Local\Temp\ACME_Line3\x.tmp', 'C:\Windows\Temp\ACME\dump.dmp', 'C:\Program Files\ACME Tools\cfg.ini', 'C:\ProgramData\ACME\x.txt') {
    $o = Mask $t
    Check "not whitelisted: $t" ($o -notmatch 'ACME|Line3') $o
}
foreach ($t in 'C:\TwinCAT\3.1\Boot\Plc\Port_851.app', 'C:\TwinCAT\3.1\Config\Io\x.xml', 'C:\Program Files (x86)\Beckhoff\TwinCAT\3.1\x.dll', 'C:\ProgramData\Beckhoff\TwinCAT\3.1\x.log') {
    $o = Mask $t
    Check "kept: $t" ($o -ceq $t) $o
}
# 3 TIPC names from objects
$tobj = [pscustomobject]@{ success = $false; error = [pscustomobject]@{ code = 'X'; message = 'TIPC^ZetaCorp^ZetaCorp Project failed; ZetaCorp PLC not running' } }
$to = New-TcIssueReport -Title 't' -Result $tobj -NoEnvironment
$tp = New-TcIssueReport -Title 't' -Parameters ([pscustomobject]@{ PlcProjectPath = 'TIPC^YotaPlc^YotaPlc Project'; Note = 'YotaPlc runs' }) -NoEnvironment
$ts = New-TcIssueReport -Title 't' -Result ($tobj | ConvertTo-Json -Depth 5) -NoEnvironment
Check 'TIPC^ names from object Result / Parameters / JSON string are masked everywhere' ($to.data.body -notmatch 'ZetaCorp' -and $tp.data.body -notmatch 'YotaPlc' -and $ts.data.body -notmatch 'ZetaCorp') ($to.data.body + $tp.data.body)
# 4 folder names -> mask words
$o = Mask 'Cannot open ''D:\Cust\ACME\x.sln'' because ACME license expired'
Check 'folder name masked in the prose behind the path' ($o -notmatch 'ACME' -and $o -match 'license expired') $o
$fx = New-TcIssueReport -Title 'Zorbo problem' -Parameters @{ SolutionPath = 'D:\Zorbo Industries\Line7\Main.sln' } -Notes 'Zorbo is the customer, Industries too' -NoEnvironment
Check 'folder names of a path in Parameters are masked in Notes / Title' ($fx.data.body -notmatch 'Zorbo' -and $fx.data.title -notmatch 'Zorbo') ($fx.data.title + ' | ' + $fx.data.body)
$o = Mask 'C:\Users\bob\Documents\Projects\x.sln then open the Documents of Projects'
Check 'generic folder names stay' ($o -match 'Documents of Projects') $o
# 5 dotless hosts / routes / ports / parameters
foreach ($pair in @(@('route CX-5A1B2C to target', 'CX-5A1B2C'), @('RouteName: CX-5A1B2C-Line3', 'Line3'), @('connect acme-plc01:48898 failed', 'acme-plc01'), @('ads plc7box:851 down', 'plc7box'), @('AddRoute -Name ACME-CX01 -Address 10.2.3.4', 'ACME-CX01|10\.2\.3\.4'), @('host cx-1a2b3c.fritz.box ok', 'fritz|cx-1a2b3c'), @('Set-TcTarget -HostName mypc7 now', 'mypc7'))) {
    $o = Mask $pair[0]
    Check ("dotless host: " + $pair[0]) ($o -notmatch $pair[1]) $o
}
# 6 root-relative paths; escaped sequences stay
$o = Mask '\Projects\ACME\Line3\Main.sln'
Check 'root-relative project path' ($o -ceq '<path>\Main.sln') $o
$o = Mask '\Projects\ACME\Line3'
Check 'root-relative directory' ($o -ceq '<path>') $o
$o = Mask 'line1\r\nline2\t\x'
Check 'escaped \r\n \t sequences are not paths' ($o -ceq 'line1\r\nline2\t\x') $o
# 7 non-ASCII e-mail
$cust = [string][char]0x5BA2 + [char]0x6236
$o = Mask ('wang.xm@' + $cust + '.com.tw and bob@acme.com.tw')
Check 'non-ASCII e-mail domain masked' ($o -ceq '<email> and <email>') $o
# nit: line-number suffix
$o = Mask 'D:\Cust\ACME\build.log:42: error C0077'
Check 'build.log:42: keeps leaf and message' ($o -ceq '<path>\build.log:42: error C0077') $o
# reviewer probe: perf on the pathological inputs
$sw = [Diagnostics.Stopwatch]::StartNew()
$rf = New-TcIssueReport -Title 't' -Result ('{"a":"' + ('x1.' * 30000) + '"}') -Notes ('D:\a b ' * 20000) -NoEnvironment
Check ("90000-char JSON string + 140000-char path-like Notes: {0:n1}s < 60s" -f $sw.Elapsed.TotalSeconds) ($rf.success -and $sw.Elapsed.TotalSeconds -lt 60 -and $rf.data.urlLength -le 7000) ''

# ---- review round 3
# 1 raw cap on text without whitespace (comma separated keys): a token across the 30000 cap leaves no prefix
$keyUnit = 'AB12cd34EF56gh78IJ90kl12MN34op56,'
$rawBase = $keyUnit * 1000
$rawBad = @()
$sw = [Diagnostics.Stopwatch]::StartNew()
foreach ($tok in @('bob.smith@acme.example.com', 'ghp_abcdefghijklmnopqrstuvwxyz0123456789', '10.11.12.13.1.1', 'AB12cd34EF56gh78IJ90kl12MN34op56qr78xy')) {
    # #241: offsets 1, 3, 5 ... sampled 1 in 4 (every 8th char), plus 7 (the first one checked)
    foreach ($off in (Select-SweepSample -Positions @(for ($o = 1; $o -lt $tok.Length; $o += 2) { $o }) -Every 4 -Boundary @(7))) {
        $r = New-TcIssueReport -Title 't' -Notes ($rawBase.Substring(0, 29999 - $off) + ',' + $tok + ',' + ('q' * 600)) -NoEnvironment
        if ($off -ge 6 -and $r.data.body.Contains($tok.Substring(0, $off))) { $rawBad += "notes $tok off=$off" }
    }
    # #241: offsets 5, 9, 13 ... sampled 1 in 2 (every 8th char)
    foreach ($off in (Select-SweepSample -Positions @(for ($o = 5; $o -lt $tok.Length; $o += 4) { $o }) -Every 2)) {
        $r = New-TcIssueReport -Title 't' -Result ([pscustomobject]@{ success = $false; data = [pscustomobject]@{ s = ($rawBase.Substring(0, 19999 - $off) + ',' + $tok + ',' + ('q' * 600)) } }) -NoEnvironment
        if ($r.data.body.Contains($tok.Substring(0, $off))) { $rawBad += "leaf $tok off=$off" }
    }
}
$rp = New-TcIssueReport -Title 't' -Notes ($rawBase.Substring(0, 29985) + ',password=Hunter2Secret,' + ('q' * 600)) -NoEnvironment
if ($rp.data.body -match 'Hunter') { $rawBad += 'password value' }
Check ("raw cap sweep without whitespace ({0:n0}s)" -f $sw.Elapsed.TotalSeconds) ($rawBad.Count -eq 0) ($rawBad -join '; ')
$rt = & $mod { param($t) Limit-TcRawText -Text $t -Cap 30000 } (('z' * 300) + (' ' + ('k,' * 20000)))
Check 'Limit-TcRawText never ends inside a token (ends in front of a boundary)' ($rt.Length -le 30000 -and ($rt -match '[,]$' -or $rt -match 'k$')) $rt.Substring($rt.Length - 10)
# 2 never trimmed: 500 folder names + one -ExtraMask; every name still masked
$paths = (1..500 | ForEach-Object { "D:\Kunde$_\Werk$_\x.sln" }) -join "`n"
$m2 = New-TcIssueReport -Title 'Zq9 issue' -ExtraMask 'Zq9' -Notes ($paths + "`nVisited Zq9 plant, Kunde7, Werk499 and Kunde500, also ZQ9X") -NoEnvironment
$vis = ($m2.data.body -split "`n" | Where-Object { $_ -match 'Visited' }) -join ' '
Check '500 folder names + 1 ExtraMask: all masked, ExtraMask kept' ($m2.data.title -notmatch 'Zq9' -and $vis -notmatch 'Zq9|Kunde7|Werk499|Kunde500|ZQ9' -and $vis -match 'Visited') $vis
$extra = (1..400 | ForEach-Object { "SecretCust$_" })
$m3 = New-TcIssueReport -Title 't' -ExtraMask $extra -Notes 'ping SecretCust1 SecretCust400 and SecretCust399x' -NoEnvironment
Check '400 -ExtraMask literals: none dropped' ($m3.data.body -notmatch 'SecretCust') ($m3.data.body)
# 3 many folder names: bounded time
$sw = [Diagnostics.Stopwatch]::StartNew()
$many = (0..1999 | ForEach-Object { "D:\Kunde$_\Werk$_\Anlage$_\file$_.sln" }) -join "`n"
$m4 = New-TcIssueReport -Title 't' -Notes $many -Result ([pscustomobject]@{ success = $false; data = @(1..2500 | ForEach-Object { "E:\Cust$_\Plant$_\x.TcPOU(12): error at 10.0.$($_ % 250).1" }) }) -NoEnvironment
Check ("2000 paths in Notes + 2500 path leaves: {0:n1}s < 60s" -f $sw.Elapsed.TotalSeconds) ($m4.success -and $sw.Elapsed.TotalSeconds -lt 60 -and $m4.data.urlLength -le 7000) ''
# 4 project base names; 5 URL labels / path segments / e-mail domains; 6 UNC
$o = Mask 'D:\Projects\ACME_Line3.sln opened; ACME_Line3 Project failed in Line3'
Check '.sln base name masked in the prose' ($o -notmatch 'ACME|Line3') $o
$o = Mask ("D:\Projects\Beta7Corp.tsproj`nD:\p\Gamma8.plcproj`nD:\p\Delta9.tnzip`nD:\p\Eps10.tszip`nBeta7Corp Project: Gamma8 Delta9 Eps10")
Check '.tsproj / .plcproj / .tnzip / .tszip base names masked' ($o -notmatch 'Beta7Corp|Gamma8|Delta9|Eps10') $o
$o = Mask 'D:\x\Main.TcPOU and FB_Pumpe1 in Main'
Check 'POU-level names are not folder words' ($o -match 'FB_Pumpe1' -and $o -match 'in Main') $o
$o = Mask 'see https://acme.sharepoint.com/sites/Line3 - Line3 at acme; https://github.com/x'
Check 'URL host first label and path segments masked in the prose' ($o -notmatch 'acme|Line3' -and $o -match 'github\.com') $o
$o = Mask 'mail bob@zetacorp.com about ZetaCorp'
Check 'e-mail domain first label masked in the prose' ($o -notmatch 'zetacorp|ZetaCorp') $o
$o = Mask 'mail bob@gmail.com about gmail'
Check 'generic mail domain labels are not folder words' ($o -match 'about gmail') $o
foreach ($t in ('share:' + $bs + $bs + 'fileserver01' + $bs + 'ACME' + $bs + 'x.sln'), ('UNC=' + $bs + $bs + 'fileserver01' + $bs + 'ACME'), ($bs + $bs + 'fileserver01' + $bs + 'eng and fileserver01 down'), ($bs + $bs + '?' + $bs + 'D:' + $bs + 'Cust' + $bs + 'ACME' + $bs + 'x.sln')) {
    $o = Mask $t
    Check "UNC form: $t" ($o -notmatch 'fileserver01|ACME') $o
}
$o = Mask ('D:' + $bs + $bs + 'Zorbo' + $bs + $bs + 'x.sln')
Check 'drive path with doubled backslashes is not UNC' ($o -notmatch 'Zorbo') $o
# nit: ASCII folder names match whole words only; generic words stay
$o = Mask 'D:\Kunde\code\x.sln: the code failed; Kunden Kunde'
Check 'whole-word match: Kunde masked, Kunden kept, generic "code" kept' ($o -match 'Kunden' -and $o -notmatch 'Kunde[^n]|Kunde$' -and $o -match 'the code failed') $o

"failed: $fail"
exit $fail
