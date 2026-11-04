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
Check 'user dir keeps the form C:\Users\<user>\AppData' ((& $mod { $c = @{}; ConvertTo-TcDeidentifiedText -Text 'C:\Users\bob\AppData\Local\Temp\x.log' -Counts $c }) -eq 'C:\Users\<user>\AppData\Local\Temp\x.log') ''
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
}
Check 'source: no web / process / gh / IDE / ADS access (3 files)' ($src.Count -eq 3 -and $hits.Count -eq 0) ($hits -join '; ')

# (4) environment from module state only
& $mod { $script:TcIdeConnected = $true; $script:TcProgId = 'VisualStudio.DTE.17.0'; $script:TcSolutionPath = 'C:\Users\bob\Customer X\Plant.sln'; $script:TcAdsConnected = $true; $script:TcAdsAmsNetId = '10.1.2.3.1.1'; $script:TcAdsAssemblyVersion = '4.4.0.0' }
$e = New-TcIssueReport -Title 'env'
Check 'environment: module, powershell, ProgId, solution FILE NAME, ads dll' ($e.data.environment.module -match '^TwinCATAutomation \d' -and $e.data.environment.powershell -match '5\.1|7\.' -and $e.data.environment.ideProgId -eq 'VisualStudio.DTE.17.0' -and $e.data.environment.solutionFile -eq 'Plant.sln' -and $e.data.environment.adsDllVersion -eq '4.4.0.0') ($e.data.environment | ConvertTo-Json -Compress)
Check 'environment: no AmsNetId, no customer folder' ($e.data.body -notmatch '10\.1\.2\.3' -and $e.data.body -notmatch 'Customer X' -and $e.data.body -notmatch 'bob') ''
$ne = New-TcIssueReport -Title 'env' -NoEnvironment
Check '-NoEnvironment drops the section' ($ne.data.body -notmatch '## Environment' -and $null -eq $ne.data.environment) ''

"failed: $fail"
exit $fail
