# Unit: #68 forbidden-pattern lint (scripts/forbidden-patterns.ps1, check.ps1 "forbidden").
# Fixture files in a temp folder prove that each rule hits in code, that comments / help do not
# hit, and that only a marker naming the rule with a reason allows a hit. No IDE / runtime.
#   powershell.exe -NoProfile -File tests/Unit/forbidden-lint.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\scripts\forbidden-patterns.ps1')
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 600) { $Detail = $Detail.Substring(0, 600) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}

$root = Join-Path $env:TEMP ("tcauto-lint-{0}" -f [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path (Join-Path $root 'src') -Force
$null = New-Item -ItemType Directory -Path (Join-Path $root 'mcp-server\lib') -Force
# the netid literals below are built from parts so that this test file itself stays clean
$id = (@('192', '168', '1', '20', '1', '1') -join '.')
try {
    $ps = @(
        '<#'                                                              # 1
        ".SYNOPSIS help text: $id and StartRestartTwinCAT are fine here"  # 2
        '#>'                                                              # 3
        "function X { `$a = '$id' }"                                      # 4  amsnetid hit
        "# comment only: `$c.WriteControl(`$s) $id"                        # 5  comment: no hit
        '$sm.StartRestartTwinCAT()'                                       # 6  startrestart hit
        '$dte.ExecuteCommand( "TwinCAT.ActivateConfiguration" )'          # 7  executecommand hit
        '$c.WriteControl($s)'                                             # 8  writecontrol hit
        '$c.WriteControl($s)  # tcauto-allow(writecontrol): Set-TcPlcState itself, read back'   # 9 allowed
        '# tcauto-allow(writecontrol): marker on the line above the call'   # 10
        '$c.WriteControl($s)'                                             # 11 allowed (line above)
        '$c.WriteControl($s)  # tcauto-allow(amsnetid): wrong rule named here'                 # 12 not allowed
        '$c.WriteControl($s)  # tcauto-allow(writecontrol): short'         # 13 reason < 8 chars: not allowed
        "`$x = 1; # tcauto-allow(writecontrol): code line above does not count"                 # 14
        '$c.WriteControl($s)'                                             # 15 not allowed
        "`$v = '3.1.4026.22'"                                             # 16 version: no hit
        "`$y = '$id' # tcauto-allow(amsnetid,writecontrol): fixture default; pass -AmsNetId"   # 17 allowed (list)
        "`$s = `"call ExecuteCommand('TwinCAT.Foo')`""                   # 18 executecommand hit inside a string (code text)
        '$c.WriteControlAsync($s)'                                        # 19 N5: WriteControlAsync hit
        '$c.GetType().InvokeMember("WriteControl", $f, $null, $c, $a)'   # 20 N5: WriteControl as a string (reflection) hit
        '$dte.ExecuteCommand("View.ErrorList")'                          # 21 N5: any ExecuteCommand hit
        "`$m = '# tcauto-allow(writecontrol): marker inside a string'; `$c.WriteControl(`$s)"   # 22 N6: marker in a string: not allowed
        '$dte.ExecuteCommand("View.ErrorList")  # tcauto-allow(executecommand): opens the Error List only'   # 23 allowed
    )
    $psFile = Join-Path $root 'src\fixture.ps1'
    [IO.File]::WriteAllLines($psFile, $ps)
    $js = @(
        "// $id in a line comment"                                        # 1 no hit
        "/* block $id"                                                    # 2 no hit
        "   still comment .WriteControl( */ const a = 1;"                 # 3 no hit
        "const netId = '$id';"                                            # 4 hit
        "const url = 'https://example.com/x'; const n = '$id';"            # 5 hit ('//' inside a string)
        "// tcauto-allow(amsnetid): real-machine client default, override with --netid"   # 6
        "const d = '$id';"                                                # 7 allowed
        "client.WriteControl (s);"                                        # 8 N5: '.WriteControl (' with a space hit
        "const t = '// tcauto-allow(writecontrol): in a string'; c.WriteControl(s);"   # 9 N6: marker in a string: not allowed
        "dte.ExecuteCommand('x'); /* tcauto-allow(executecommand): block comment marker */"   # 10 allowed
    )
    $jsFile = Join-Path $root 'mcp-server\lib\fixture.js'
    [IO.File]::WriteAllLines($jsFile, $js)

    $hits = @(Find-TcForbiddenPattern -Files @($psFile, $jsFile) -Root $root)
    function Get-Hit([string]$File, [int]$Line) { , @($hits | Where-Object { $_.File -eq $File -and $_.Line -eq $Line }) }
    $p = 'src/fixture.ps1'; $j = 'mcp-server/lib/fixture.js'
    Check 'help block: no hit' ((Get-Hit $p 2).Count -eq 0) ''
    Check 'amsnetid literal in code: hit, not allowed' ((Get-Hit $p 4).Count -eq 1 -and (Get-Hit $p 4)[0].Rule -eq 'amsnetid' -and -not (Get-Hit $p 4)[0].Allowed) ''
    Check 'comment line: no hit' ((Get-Hit $p 5).Count -eq 0) ''
    Check 'StartRestartTwinCAT: hit' ((Get-Hit $p 6).Count -eq 1 -and (Get-Hit $p 6)[0].Rule -eq 'startrestart' -and -not (Get-Hit $p 6)[0].Allowed) ''
    Check 'ExecuteCommand("TwinCAT.*"): hit' ((Get-Hit $p 7).Count -eq 1 -and (Get-Hit $p 7)[0].Rule -eq 'executecommand') ''
    Check 'direct .WriteControl(: hit' ((Get-Hit $p 8).Count -eq 1 -and (Get-Hit $p 8)[0].Rule -eq 'writecontrol' -and -not (Get-Hit $p 8)[0].Allowed) ''
    Check 'marker on the same line naming the rule: allowed' ((Get-Hit $p 9).Count -eq 1 -and (Get-Hit $p 9)[0].Allowed) ''
    Check 'marker on a comment-only line above: allowed' ((Get-Hit $p 11).Count -eq 1 -and (Get-Hit $p 11)[0].Allowed) ''
    Check 'marker naming another rule: not allowed' ((Get-Hit $p 12).Count -eq 1 -and -not (Get-Hit $p 12)[0].Allowed) ''
    Check 'marker with a too short reason: not allowed' ((Get-Hit $p 13).Count -eq 1 -and -not (Get-Hit $p 13)[0].Allowed) ''
    Check 'marker after code on the line above: not allowed' ((Get-Hit $p 15).Count -eq 1 -and -not (Get-Hit $p 15)[0].Allowed) ''
    Check 'version number 3.1.4026.22: no hit' ((Get-Hit $p 16).Count -eq 0) ''
    Check 'marker with a rule list: allowed' ((Get-Hit $p 17).Count -eq 1 -and (Get-Hit $p 17)[0].Allowed) ''
    Check 'ExecuteCommand text in a string: hit (strings are code)' ((Get-Hit $p 18).Count -eq 1) ''
    Check 'js line / block comments: no hit' ((Get-Hit $j 1).Count -eq 0 -and (Get-Hit $j 2).Count -eq 0 -and (Get-Hit $j 3).Count -eq 0) ''
    Check 'js literal: hit' ((Get-Hit $j 4).Count -eq 1 -and -not (Get-Hit $j 4)[0].Allowed) ''
    Check "js '//' inside a string does not start a comment" ((Get-Hit $j 5).Count -eq 1) ''
    Check 'js marker line above: allowed' ((Get-Hit $j 7).Count -eq 1 -and (Get-Hit $j 7)[0].Allowed) ''
    Check 'N5: WriteControlAsync hit' ((Get-Hit $p 19).Count -eq 1 -and (Get-Hit $p 19)[0].Rule -eq 'writecontrol' -and -not (Get-Hit $p 19)[0].Allowed) ''
    Check 'N5: WriteControl in a string (reflection) hit' ((Get-Hit $p 20).Count -eq 1 -and (Get-Hit $p 20)[0].Rule -eq 'writecontrol') ''
    Check 'N5: any ExecuteCommand hit (View.ErrorList without marker)' ((Get-Hit $p 21).Count -eq 1 -and (Get-Hit $p 21)[0].Rule -eq 'executecommand' -and -not (Get-Hit $p 21)[0].Allowed) ''
    Check 'N6: a marker inside a string does not allow' ((Get-Hit $p 22).Count -eq 1 -and -not (Get-Hit $p 22)[0].Allowed) ''
    Check 'ExecuteCommand with a marker comment: allowed' ((Get-Hit $p 23).Count -eq 1 -and (Get-Hit $p 23)[0].Allowed) ''
    Check "N5: js '.WriteControl (' with a space hit" ((Get-Hit $j 8).Count -eq 1 -and (Get-Hit $j 8)[0].Rule -eq 'writecontrol' -and -not (Get-Hit $j 8)[0].Allowed) ''
    Check 'N6: js marker inside a string does not allow' ((Get-Hit $j 9).Count -eq 1 -and -not (Get-Hit $j 9)[0].Allowed) ''
    Check 'js marker in a block comment on the same line: allowed' ((Get-Hit $j 10).Count -eq 1 -and (Get-Hit $j 10)[0].Allowed) ''
    Check 'total hits as expected (22)' ($hits.Count -eq 22) (($hits | ForEach-Object { "$($_.File):$($_.Line) $($_.Rule) $($_.Allowed)" }) -join '; ')

    # scope of the check
    Check 'scope: src, mcp-server (not test/), tests/Integration only' ((Test-TcForbiddenScope 'src/a.ps1') -and (Test-TcForbiddenScope 'mcp-server/lib/a.js') -and (Test-TcForbiddenScope 'mcp-server/scripts/a.mjs') -and (Test-TcForbiddenScope 'tests/Integration/a.ps1') -and -not (Test-TcForbiddenScope 'mcp-server/test/a.test.js') -and -not (Test-TcForbiddenScope 'tests/Unit/a.ps1') -and -not (Test-TcForbiddenScope 'docs/a.md') -and -not (Test-TcForbiddenScope 'src/a.md')) ''

    # the repository itself is clean (same as check.ps1 "forbidden")
    $repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).ProviderPath
    $files = @(Get-ChildItem -LiteralPath (Join-Path $repo 'src'), (Join-Path $repo 'mcp-server'), (Join-Path $repo 'tests\Integration') -Recurse -File |
        Where-Object { $_.FullName -notmatch '\\node_modules\\' } |
        Where-Object { Test-TcForbiddenScope ($_.FullName.Substring($repo.Length).TrimStart('\').Replace('\', '/')) } | ForEach-Object { $_.FullName })
    $bad = @(Find-TcForbiddenPattern -Files $files -Root $repo | Where-Object { -not $_.Allowed })
    Check 'repository: no forbidden pattern without a marker' ($bad.Count -eq 0) (($bad | ForEach-Object { "$($_.File):$($_.Line) $($_.Rule)" }) -join '; ')
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
"failed: $fail"
exit [Math]::Min($fail, 255)
