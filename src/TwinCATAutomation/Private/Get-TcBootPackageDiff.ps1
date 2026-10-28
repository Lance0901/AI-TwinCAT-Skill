function ConvertFrom-TcAmsNetIdHex {
    # 'C7052AFA0101' -> '199.5.42.250.1.1' ($null when the text is not 6 hex bytes)
    param([string]$Hex)
    if ($Hex -notmatch '^[0-9A-Fa-f]{12}$') { return $null }
    $bytes = for ($i = 0; $i -lt 12; $i += 2) { [Convert]::ToInt32($Hex.Substring($i, 2), 16) }
    return ($bytes -join '.')
}

function Resolve-TcTargetBootDir {
    <#
    .SYNOPSIS
        Boot directory of a target runtime that runs on THIS PC, or $null.
    .DESCRIPTION
        - Usermode Runtime: every %ProgramData%\Beckhoff\TwinCAT\3.1\Runtimes\<name>\3.1\TcRegistry.xml
          holds <Value Name="AmsNetId" Type="BIN">C7052AFA0101</Value>; the one equal to the
          target NetId gives <name>\3.1\Boot (measured 2026-10-21, UmRT_Default; the runtime is
          started with -c .\3.1 in that folder). InfoSys does not document this file (measured).
        - Local XAR (target NetId = this PC's system NetId, registry
          HKLM\SOFTWARE\[WOW6432Node\]Beckhoff\TwinCAT3\System AmsNetId):
          %ProgramData%\Beckhoff\TwinCAT\3.1\Boot (TwinCAT >= 3.1.4026.0; InfoSys
          https://infosys.beckhoff.com/content/1033/tc3_grundlagen/4291093003.html gives
          ...\3.1\Boot\Plc for the boot project; C:\TwinCAT\3.1\Boot before 4026).
        A remote target (other PC / CX) returns $null: its Boot folder is not readable
        from here without the ADS file service.
    .OUTPUTS
        @{ Dir = <path>; Kind = 'umrt:<name>' | 'local-xar' } or $null
    #>
    param([Parameter(Mandatory)][string]$AmsNetId)

    $base = Join-Path $env:ProgramData 'Beckhoff\TwinCAT\3.1'
    $rtRoot = Join-Path $base 'Runtimes'
    if (Test-Path $rtRoot) {
        foreach ($rt in @(Get-ChildItem -Path $rtRoot -Directory -ErrorAction SilentlyContinue)) {
            $reg = Join-Path $rt.FullName '3.1\TcRegistry.xml'
            if (-not (Test-Path $reg)) { continue }
            try {
                $m = Select-String -Path $reg -Pattern 'Name="AmsNetId"[^>]*>([0-9A-Fa-f]{12})<' -List
                if ($null -ne $m -and (ConvertFrom-TcAmsNetIdHex $m.Matches[0].Groups[1].Value) -eq $AmsNetId) {
                    return @{ Dir = (Join-Path $rt.FullName '3.1\Boot'); Kind = "umrt:$($rt.Name)" }
                }
            }
            catch { Write-Verbose "Resolve-TcTargetBootDir: $reg not readable ($($_.Exception.Message))" }
        }
    }
    foreach ($key in 'HKLM:\SOFTWARE\WOW6432Node\Beckhoff\TwinCAT3\System', 'HKLM:\SOFTWARE\Beckhoff\TwinCAT3\System') {
        try {
            $v = (Get-ItemProperty -Path $key -Name AmsNetId -ErrorAction Stop).AmsNetId
            if ($null -ne $v -and $v.Length -eq 6 -and (($v | ForEach-Object { [int]$_ }) -join '.') -eq $AmsNetId) {
                return @{ Dir = (Join-Path $base 'Boot'); Kind = 'local-xar' }
            }
        }
        catch { }
    }
    return $null
}

function Get-TcBootPackageDiff {
    <#
    .SYNOPSIS
        Compares the project's _Boot\<platform> package with the Boot folder of the target (#32).
    .DESCRIPTION
        Activate writes the configuration into the project folder (_Boot\<platform>) and to
        the target's Boot folder. When the target keeps an older CurrentConfig package while
        a PLC .app was replaced, the runtime refuses to start ("The loaded symbol description
        does not match the plc application", ADS 1809 / 0x711) and falls back to Config.
        Compared files (relative to both folders): CurrentConfig.xml, CurrentConfig.tszip,
        CurrentConfig\*.tpzip, Plc\Port_*.app. Byte equality of the two copies after a good
        Activate was measured on the local UmRT (2026-10-21); InfoSys does not describe these
        files (measured). Read-only: nothing is copied.
        Only works when the target runs on this PC (Resolve-TcTargetBootDir); otherwise
        status = 'unavailable'.
        Mismatch rules (no false alarm on a healthy cycle): a file counts as mismatching only
        when it exists on BOTH sides with different SHA-256, or when CurrentConfig.xml exists
        locally but not on the target. A file on one side only (no .tszip on some versions, a
        stale Port_*.app of a removed PLC, no boot .app when autostart is off) is listed in
        oneSided as information. Plc\Port_<n>.app is limited to -AdsPorts when given.
    .PARAMETER SolutionPath
        .sln path; its folder is searched (depth 2) for _Boot\<Platform>.
    .PARAMETER Platform
        Solution platform, e.g. 'TwinCAT OS (x64)'.
    .PARAMETER AmsNetId
        Target AMS Net ID.
    .PARAMETER AdsPorts
        ADS ports of the PLC projects of the solution: only Plc\Port_<port>.app of these is compared.
    .OUTPUTS
        PSCustomObject @{ status = 'match' | 'mismatch' | 'unavailable'; reason; localDir;
          targetDir; targetKind; mismatches = [names]; files = @( @{ file; match;
          local = @{ exists; size; lastWriteTime; sha256 }; target = @{ ... } } ) }
    #>
    [CmdletBinding()]
    param(
        [string]$SolutionPath,
        [string]$Platform,
        [Parameter(Mandatory)][string]$AmsNetId,
        [int[]]$AdsPorts
    )

    $res = [PSCustomObject]@{
        status     = 'unavailable'
        reason     = $null
        localDir   = $null
        targetDir  = $null
        targetKind = $null
        mismatches = @()
        files      = @()
    }
    if ([string]::IsNullOrWhiteSpace($SolutionPath) -or -not (Test-Path $SolutionPath)) { $res.reason = 'solution path unknown'; return $res }
    if ([string]::IsNullOrWhiteSpace($Platform)) { $res.reason = 'solution platform unknown'; return $res }

    # _Boot next to a .tsproj (the TwinCAT project folder); with several, the most recently
    # activated one (newest CurrentConfig.xml).
    $slnDir = Split-Path -Parent $SolutionPath
    $local = $null
    $cands = @()
    foreach ($b in @(Get-ChildItem -Path $slnDir -Directory -Filter '_Boot' -Recurse -Depth 2 -ErrorAction SilentlyContinue)) {
        $cand = Join-Path $b.FullName $Platform
        if (-not (Test-Path $cand)) { continue }
        if (@(Get-ChildItem -Path $b.Parent.FullName -Filter '*.tsproj' -File -ErrorAction SilentlyContinue).Count -eq 0) { continue }
        $xml = Join-Path $cand 'CurrentConfig.xml'
        $t = if (Test-Path $xml) { (Get-Item $xml).LastWriteTimeUtc } else { [DateTime]::MinValue }
        $cands += [PSCustomObject]@{ Dir = $cand; Time = $t }
    }
    if ($cands.Count -gt 0) { $local = @($cands | Sort-Object Time -Descending)[0].Dir }
    if ($null -eq $local) { $res.reason = "no _Boot\$Platform folder below $slnDir"; return $res }
    $res.localDir = $local

    $target = Resolve-TcTargetBootDir -AmsNetId $AmsNetId
    if ($null -eq $target) { $res.reason = "target $AmsNetId is not a runtime on this PC (Boot folder not readable)"; return $res }
    $res.targetDir = $target.Dir
    $res.targetKind = $target.Kind
    if (-not (Test-Path $target.Dir)) { $res.reason = "target Boot folder $($target.Dir) does not exist"; return $res }

    $rel = [System.Collections.Generic.List[string]]::new()
    foreach ($f in 'CurrentConfig.xml', 'CurrentConfig.tszip') { $rel.Add($f) }
    # Only the files of the local package are compared; files that exist only on the target
    # (e.g. the package of a PLC removed from the solution) are listed in extraOnTarget.
    foreach ($f in @(Get-ChildItem -Path (Join-Path $local 'CurrentConfig') -Filter '*.tpzip' -File -ErrorAction SilentlyContinue)) {
        $rel.Add("CurrentConfig\$($f.Name)")
    }
    $extra = @()
    foreach ($f in @(Get-ChildItem -Path (Join-Path $target.Dir 'CurrentConfig') -Filter '*.tpzip' -File -ErrorAction SilentlyContinue)) {
        if (-not $rel.Contains("CurrentConfig\$($f.Name)")) { $extra += "CurrentConfig\$($f.Name)" }
    }
    $res | Add-Member -NotePropertyName 'extraOnTarget' -NotePropertyValue $extra
    # PLC applications that the project builds: only the .app files present in the local package
    foreach ($f in @(Get-ChildItem -Path (Join-Path $local 'Plc') -Filter 'Port_*.app' -File -ErrorAction SilentlyContinue)) {
        if (@($AdsPorts).Count -gt 0) {
            $mt = [regex]::Match($f.Name, '^Port_(\d+)\.app$')
            if (-not $mt.Success -or @($AdsPorts) -notcontains [int]$mt.Groups[1].Value) { continue }
        }
        $r = "Plc\$($f.Name)"; if (-not $rel.Contains($r)) { $rel.Add($r) }
    }

    function Get-TcFileFacts([string]$Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [PSCustomObject]@{ exists = $false; size = $null; lastWriteTime = $null; sha256 = $null } }
        $i = Get-Item -LiteralPath $Path
        $h = $null
        try { $h = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash } catch { $h = $null }
        [PSCustomObject]@{ exists = $true; size = $i.Length; lastWriteTime = $i.LastWriteTime.ToString('yyyy-MM-ddTHH:mm:ss'); sha256 = $h }
    }

    $files = @()
    $mism = @()
    $oneSided = @()
    foreach ($r in $rel) {
        $l = Get-TcFileFacts (Join-Path $local $r)
        $t = Get-TcFileFacts (Join-Path $target.Dir $r)
        $both = $l.exists -and $t.exists
        $match = $both -and $null -ne $l.sha256 -and $l.sha256 -eq $t.sha256
        if ($both -and -not $match) { $mism += $r }
        elseif (-not $both) {
            if ($r -eq 'CurrentConfig.xml' -and $l.exists) { $mism += $r }   # the configuration itself never reached the target
            elseif ($l.exists -or $t.exists) { $oneSided += $r }
        }
        $files += [PSCustomObject]@{ file = $r; match = $match; local = $l; target = $t }
    }
    $res.files = $files
    $res.mismatches = $mism
    $res | Add-Member -NotePropertyName 'oneSided' -NotePropertyValue $oneSided
    $res.status = if ($mism.Count -eq 0) { 'match' } else { 'mismatch' }
    return $res
}
