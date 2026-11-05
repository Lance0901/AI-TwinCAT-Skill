. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
# Unit: #140 Get-TcModuleCommit (the commit line of New-TcIssueReport) for a module loaded from a
# linked git worktree. There .git is a FILE "gitdir: <main>\.git\worktrees\<name>" that git writes as
# UTF-8 without BOM; <name>\commondir points back at <main>\.git where refs and packed-refs live.
# Windows PowerShell 5.1 Get-Content read that file as ANSI, so a checkout under a non-ASCII folder
# (OneDrive\<CJK>, as on the real machine) got a garbled gitdir and no commit line.
# Fake repositories only (under this test's TCAUTO_STATE_DIR), no git process, no IDE / runtime.
#   powershell.exe -NoProfile -File tests/Unit/issue-report-commit-worktree-140.ps1
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
$utf8 = New-Object System.Text.UTF8Encoding $false
function Put([string]$File, [string]$Text) {
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $File)
    [System.IO.File]::WriteAllText($File, $Text, $script:utf8)   # like git: UTF-8, no BOM, LF
}
function Commit([string]$Root) { & $mod { param($b) Get-TcModuleCommit -ModuleBase $b } (Join-Path $Root 'src\TwinCATAutomation') }

# Non-ASCII folder built at run time (this file stays ASCII): U+6574 U+7406 like the real OneDrive path
$cjk = [string][char]0x6574 + [char]0x7406
$base = Join-Path $env:TCAUTO_STATE_DIR ("tcauto-140-{0}\{1}" -f [guid]::NewGuid().ToString('N').Substring(0, 8), $cjk)
$main = Join-Path $base 'repo'
$wt = Join-Path $main '.claude\worktrees\verify'
$wtGit = Join-Path $main '.git\worktrees\verify'
$null = New-Item -ItemType Directory -Force -Path (Join-Path $main 'src\TwinCATAutomation'), (Join-Path $wt 'src\TwinCATAutomation')

Put (Join-Path $main '.git\HEAD') "ref: refs/heads/master`n"
Put (Join-Path $main '.git\refs\heads\master') "1111111111111111111111111111111111111111`n"
Put (Join-Path $main '.git\refs\heads\fix\140') "abcdef0123456789abcdef0123456789abcdef01`n"
Put (Join-Path $wtGit 'HEAD') "ref: refs/heads/fix/140`n"
Put (Join-Path $wtGit 'commondir') "../..`n"
Put (Join-Path $wtGit 'gitdir') (((Join-Path $wt '.git') -replace '\\', '/') + "`n")
# what git worktree add writes: absolute path with forward slashes
Put (Join-Path $wt '.git') ("gitdir: " + ($wtGit -replace '\\', '/') + "`n")

# 1 main checkout under the non-ASCII folder (.git is a directory): worked before, still works
$c = Commit $main
Check '1 main checkout (.git directory) under a non-ASCII path -> commit of master' ($c -eq '1111111') "[$c]"

# 2 the #140 case: worktree .git file with an absolute non-ASCII gitdir, ref only in the common dir
$c = Commit $wt
Check '2 worktree .git file, non-ASCII gitdir, loose ref in commondir -> abcdef0' ($c -eq 'abcdef0') "[$c]"

# 3 ref only in packed-refs of the common dir
Remove-Item -LiteralPath (Join-Path $main '.git\refs\heads\fix\140')
Put (Join-Path $main '.git\packed-refs') "# pack-refs with: peeled fully-peeled sorted`n1234567890abcdef1234567890abcdef12345678 refs/heads/fix/140`n"
$c = Commit $wt
Check '3 worktree, ref only in packed-refs of the common dir -> 1234567' ($c -eq '1234567') "[$c]"

# 4 relative gitdir in the .git file (git worktree --relative-paths) and CRLF line ends
Put (Join-Path $wt '.git') "gitdir: ../../../.git/worktrees/verify`r`n"
$c = Commit $wt
Check '4 relative gitdir with CRLF -> 1234567' ($c -eq '1234567') "[$c]"

# 5 detached HEAD in the worktree
Put (Join-Path $wtGit 'HEAD') "fedcba9876543210fedcba9876543210fedcba98`n"
$c = Commit $wt
Check '5 detached HEAD in the worktree -> fedcba9' ($c -eq 'fedcba9') "[$c]"

# 6 .git file with a UTF-8 BOM (an editor rewrote it) is still read
[System.IO.File]::WriteAllText((Join-Path $wt '.git'), ("gitdir: " + ($wtGit -replace '\\', '/')), (New-Object System.Text.UTF8Encoding $true))
$c = Commit $wt
Check '6 .git file with a BOM -> fedcba9' ($c -eq 'fedcba9') "[$c]"

# 7 gitdir that does not exist -> no commit (never a wrong sha, never throws)
Put (Join-Path $wt '.git') "gitdir: ../../../.git/worktrees/gone`n"
$c = Commit $wt
Check '7 gitdir that does not exist -> $null' ($null -eq $c) "[$c]"

# 8 empty .git file and a .git file with garbage -> $null, never throws (#145 review)
Put (Join-Path $wt '.git') ''
$c = Commit $wt
Check '8 empty .git file -> $null' ($null -eq $c) "[$c]"
[System.IO.File]::WriteAllBytes((Join-Path $wt '.git'), [byte[]](0xFF, 0xFE, 0x00, 0x13, 0x37, 0x0A, 0x67, 0x69, 0x74))
$c = Commit $wt
Check '8 .git file with garbage bytes -> $null' ($null -eq $c) "[$c]"
Put (Join-Path $wt '.git') "not a gitdir line`n"
$c = Commit $wt
Check '8 .git file without "gitdir:" -> $null' ($null -eq $c) "[$c]"

# 9 non-ASCII branch name (loose ref and packed-refs, UTF-8 like git); ".." is still refused
Put (Join-Path $wt '.git') ("gitdir: " + ($wtGit -replace '\\', '/') + "`n")
Put (Join-Path $wtGit 'HEAD') "ref: refs/heads/fix/$cjk`n"
Put (Join-Path $main ".git\refs\heads\fix\$cjk") "0123456789abcdef0123456789abcdef01234567`n"
$c = Commit $wt
Check '9 non-ASCII branch name, loose ref -> 0123456' ($c -eq '0123456') "[$c]"
Remove-Item -LiteralPath (Join-Path $main ".git\refs\heads\fix\$cjk")
Put (Join-Path $main '.git\packed-refs') "# pack-refs with: peeled fully-peeled sorted`n89abcdef0123456789abcdef0123456789abcdef refs/heads/fix/$cjk`n"
$c = Commit $wt
Check '9 non-ASCII branch name, packed-refs -> 89abcde' ($c -eq '89abcde') "[$c]"
Put (Join-Path $wtGit 'HEAD') "ref: refs/heads/../../HEAD`n"
$c = Commit $wt
Check '9 ref with ".." -> $null' ($null -eq $c) "[$c]"

Remove-Item -LiteralPath (Split-Path -Parent $base) -Recurse -Force
"failed: $fail"
exit $fail
