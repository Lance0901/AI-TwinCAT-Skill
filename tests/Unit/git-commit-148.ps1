. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
# Unit: #148 Read-TcGitCommit, the one PowerShell reader of the checked-out commit (used by
# Get-TcModuleCommit and the install manifest), on the shared fixture tests/fixtures/git-commit-148.json.
# mcp-server/test/git-commit.test.js runs the same fixture against module-source.js readGitHead, so
# the PowerShell and the Node side give the same result for every case. Every case is also checked
# through Get-TcModuleCommit (7-character commit or $null) with <root>\src\TwinCATAutomation.
# Fake repositories only (under this test's TCAUTO_STATE_DIR, in a non-ASCII folder), no git
# process, no IDE / runtime.
#   powershell.exe -NoProfile -File tests/Unit/git-commit-148.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 400) { $Detail = $Detail.Substring(0, 400) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}
function Show($v) { if ($null -eq $v) { 'null' } else { "'$v'" } }

$fixtureFile = Join-Path $PSScriptRoot '..\fixtures\git-commit-148.json'
$fixture = [System.IO.File]::ReadAllText($fixtureFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$cjk = [string][char]0x6574 + [char]0x7406
$base = Join-Path $env:TCAUTO_STATE_DIR ("tcauto-148-{0}\{1}" -f [guid]::NewGuid().ToString('N').Substring(0, 8), $cjk)
$noBom = New-Object System.Text.UTF8Encoding $false
$withBom = New-Object System.Text.UTF8Encoding $true

$cases = @($fixture.cases)
Check 'fixture has cases' ($cases.Count -ge 20) "$($cases.Count) cases"
$i = 0
foreach ($case in $cases) {
    $i++
    $dir = Join-Path $base ('c{0:D2}' -f $i)
    $null = New-Item -ItemType Directory -Force -Path $dir
    $caseFwd = $dir -replace '\\', '/'
    foreach ($d in @($case.dirs)) {
        if ($d) { $null = New-Item -ItemType Directory -Force -Path (Join-Path $dir ($d -replace '/', '\')) }
    }
    if ($case.files) {
        foreach ($p in $case.files.PSObject.Properties) {
            $file = Join-Path $dir ($p.Name -replace '/', '\')
            $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $file)
            $v = $p.Value
            if ($v -is [string]) { [System.IO.File]::WriteAllText($file, $v.Replace('{case}', $caseFwd), $noBom) }
            elseif ($null -ne $v.bytes) { [System.IO.File]::WriteAllBytes($file, [byte[]]@($v.bytes | ForEach-Object { [byte]$_ })) }
            elseif ($null -ne $v.utf16) { [System.IO.File]::WriteAllBytes($file, [byte[]](@(0xFF, 0xFE) + [System.Text.Encoding]::Unicode.GetBytes(([string]$v.utf16).Replace('{case}', $caseFwd)))) }
            else { [System.IO.File]::WriteAllText($file, ([string]$v.text).Replace('{case}', $caseFwd), $(if ($v.bom) { $withBom } else { $noBom })) }
        }
    }
    $root = if ($case.root) { Join-Path $dir ($case.root -replace '/', '\') } else { $dir }
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $root 'src\TwinCATAutomation')

    $threw = $null
    $g = $null
    try { $g = & $mod { param($r) Read-TcGitCommit -RepoRoot $r } $root } catch { $threw = $_.Exception.Message }
    $e = $case.expect
    if ($null -eq $e) {
        Check "$i $($case.name): no usable .git -> `$null" ($null -eq $threw -and $null -eq $g) "threw=$(Show $threw) commit=$(Show $g.commit) note=$(Show $g.note)"
    }
    else {
        $noteOk = if ($null -eq $e.note) { $null -eq $g.note } else { $null -ne $g.note -and ([string]$g.note).Contains([string]$e.note) }
        $ok = $null -eq $threw -and $null -ne $g -and $g.commit -ceq $e.commit -and $g.ref -ceq $e.ref -and $noteOk
        Check "$i $($case.name)" $ok "threw=$(Show $threw) commit=$(Show $g.commit) ref=$(Show $g.ref) note=$(Show $g.note)"
    }

    $short = & $mod { param($b) Get-TcModuleCommit -ModuleBase $b } (Join-Path $root 'src\TwinCATAutomation')
    $want = if ($null -ne $e -and $e.commit) { ([string]$e.commit).Substring(0, 7) } else { $null }
    Check "$i Get-TcModuleCommit -> $(Show $want)" ($short -ceq $want) "[$short]"
}

# the install manifest takes the same commit, and reports a .git it cannot use as a warning
$srcModuleDir = Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation'
$sha256Case = [array]::IndexOf(@($cases | ForEach-Object { $_.name }), 'SHA-256 loose ref, upper case -> lower case') + 1
$s = & $mod { param($p, $m) Get-TcSourceInfo -SourceRoot $p -ModuleDir $m } (Join-Path $base ('c{0:D2}' -f $sha256Case)) $srcModuleDir
Check 'Get-TcSourceInfo: SHA-256 commit from Read-TcGitCommit' ($s.commitSource -eq 'git' -and $s.commit -eq ('fedcba9876543210' * 4)) "$($s.commitSource) $($s.commit)"
$garbageCase = [array]::IndexOf(@($cases | ForEach-Object { $_.name }), 'garbage .git file (binary bytes)') + 1
$s = & $mod { param($p, $m) Get-TcSourceInfo -SourceRoot $p -ModuleDir $m } (Join-Path $base ('c{0:D2}' -f $garbageCase)) $srcModuleDir
Check 'Get-TcSourceInfo: garbage .git file -> commit unknown + warning, no throw' ($s.commitSource -eq 'unknown' -and $null -eq $s.commit -and (@($s.warnings) -join ' ') -like '*.git cannot be read*') "$($s.commitSource) $(@($s.warnings) -join '; ')"

# a loose ref file that exists but cannot be read: never a stale packed-refs sha; the reason (it names the
# file in every UI culture, the localized wording is not compared) reaches -Failure and the manifest warning
$lockDir = Join-Path $base 'locked'
$null = New-Item -ItemType Directory -Force -Path (Join-Path $lockDir '.git\refs\heads')
[System.IO.File]::WriteAllText((Join-Path $lockDir '.git\HEAD'), "ref: refs/heads/main`n", $noBom)
[System.IO.File]::WriteAllText((Join-Path $lockDir '.git\refs\heads\main'), "1111111111111111111111111111111111111111`n", $noBom)
[System.IO.File]::WriteAllText((Join-Path $lockDir '.git\packed-refs'), "2222222222222222222222222222222222222222 refs/heads/main`n", $noBom)
$lock = [System.IO.File]::Open((Join-Path $lockDir '.git\refs\heads\main'), 'Open', 'ReadWrite', 'None')
try {
    $g = & $mod { param($r) $why = $null; $x = Read-TcGitCommit -RepoRoot $r -Failure ([ref]$why); @{ g = $x; why = $why } } $lockDir
    $s = & $mod { param($p, $m) Get-TcSourceInfo -SourceRoot $p -ModuleDir $m } $lockDir $srcModuleDir
}
finally { $lock.Dispose() }
Check 'locked loose ref -> $null (not the packed-refs sha), no throw, -Failure has the reason' ($null -eq $g.g -and "$($g.why)" -like '*heads\main*') "commit=$(Show $g.g.commit) why=$(Show $g.why)"
$w = @($s.warnings) -join '; '
Check 'review 4: Get-TcSourceInfo warning carries the read failure' ($null -eq $s.commit -and $w -like '*.git cannot be read: *' -and $w -like '*heads\main*') $w

Remove-Item -LiteralPath (Split-Path -Parent $base) -Recurse -Force
"failed: $fail"
exit $fail
