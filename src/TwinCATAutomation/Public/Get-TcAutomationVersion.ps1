function Get-TcAutomationVersion {
    <#
    .SYNOPSIS
        Reports which TwinCATAutomation is running: source repository, module version, commit and install time (#30), offline.
    .DESCRIPTION
        An installed copy (TwinCATSetup-Claude.ps1 / -Codex.ps1 / -Antigravity.ps1) is described by
        tcauto-install-manifest.json in the skill folder above the module folder: data.installed = true,
        data.source = 'install-manifest', data.manifestPath, and the manifest fields (name, sourceUrl,
        version, release, commit, ref, commitSource, installer, installedAt, sourcePath, fileCount).
        A module loaded from a source checkout or an extracted release (e.g. the TcAuto MCP server
        started from the repository) has no manifest: data.installed = false, data.source =
        'source-tree': version from the module's .psd1; the commit only when the module folder is
        <root>\src\TwinCATAutomation, from <root>\.git (read as files, git is not started) or, without
        .git, the tcauto-source.json stamp reserved for the release zip (#20). commitSource tells which:
        'git', 'release-stamp' or 'unknown' (data.warnings says why a value is missing).
        data.moduleVersion is the ModuleVersion of the loaded module's .psd1, data.modulePath its folder.
        -Verify compares every installed file with the SHA256 in the manifest: data.verify (ok,
        checked, matched, mismatched [path, expected, actual], missing, extra). A difference returns
        INSTALL_MANIFEST_MISMATCH; -Verify without a manifest INSTALL_MANIFEST_NOT_FOUND; a manifest
        that cannot be read (or lists a path outside the install folder) INSTALL_MANIFEST_INVALID.
        Read-only: nothing is written.
    .PARAMETER Verify
        Also compare the installed files with the SHA256 hashes recorded in the install manifest (detects an accidental or partial change of the installed copy).
    .EXAMPLE
        Get-TcAutomationVersion
    .EXAMPLE
        Get-TcAutomationVersion -Verify
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$Verify
    )

    $moduleDir = $null
    if ($MyInvocation.MyCommand.Module) { $moduleDir = $MyInvocation.MyCommand.Module.ModuleBase }
    if ([string]::IsNullOrWhiteSpace($moduleDir)) { $moduleDir = Split-Path -Parent $PSScriptRoot }
    $moduleDir = [System.IO.Path]::GetFullPath($moduleDir).TrimEnd('\', '/')

    $moduleVersion = $null
    $psd1 = Join-Path $moduleDir 'TwinCATAutomation.psd1'
    if (Test-Path -LiteralPath $psd1 -PathType Leaf) {
        try { $moduleVersion = [string](Import-PowerShellDataFile -LiteralPath $psd1 -ErrorAction Stop).ModuleVersion } catch { $moduleVersion = $null }
    }

    $manifestPath = Find-TcInstallManifest -ModuleDir $moduleDir
    if ($null -eq $manifestPath) {
        # A commit belongs to <root> only when the module folder really is <root>\src\TwinCATAutomation;
        # anywhere else (a copied module folder) a .git / stamp above it says nothing about this module.
        $srcDir = Split-Path -Parent $moduleDir
        $sourceRoot = if ($srcDir) { Split-Path -Parent $srcDir } else { $null }
        $inTree = $false
        if (-not [string]::IsNullOrEmpty($sourceRoot) -and (Split-Path -Leaf $srcDir) -eq 'src') {
            $expectedDir = [System.IO.Path]::GetFullPath((Join-Path $sourceRoot 'src\TwinCATAutomation')).TrimEnd('\', '/')
            $inTree = [string]::Equals($expectedDir, $moduleDir, [System.StringComparison]::OrdinalIgnoreCase)
        }
        if ($inTree) {
            $src = Get-TcSourceInfo -SourceRoot $sourceRoot -ModuleDir $moduleDir
        }
        else {
            # version still comes from the module's own .psd1; there is no source root to read a commit from
            $src = Get-TcSourceInfo -SourceRoot $moduleDir -ModuleDir $moduleDir
            $src.commit = $null; $src.ref = $null; $src.release = $null; $src.commitSource = 'unknown'
            $src.warnings = @(@($src.warnings) + "module folder $moduleDir is not <root>\src\TwinCATAutomation of a source tree: commit unknown")
            $sourceRoot = $null
        }
        $data = [ordered]@{
            installed     = $false
            source        = 'source-tree'
            moduleVersion = $moduleVersion
            modulePath    = $moduleDir
            manifestPath  = $null
            sourceUrl     = $src.sourceUrl
            version       = $src.version
            release       = $src.release
            commit        = $src.commit
            ref           = $src.ref
            commitSource  = $src.commitSource
            sourcePath    = $sourceRoot
            warnings      = @($src.warnings)
        }
        if ($Verify) {
            return New-TcResult -Success $false -ErrorCode 'INSTALL_MANIFEST_NOT_FOUND' -Hint $script:TcErrorHints['INSTALL_MANIFEST_NOT_FOUND'] `
                -ErrorMessage "No $($script:TcInstallManifestName) next to $moduleDir`: this module is not an installed copy, nothing to verify" -Data $data
        }
        return New-TcResult -Success $true -Data $data
    }

    try {
        $m = Read-TcInstallManifest -Path $manifestPath
    }
    catch {
        return New-TcResult -Success $false -ErrorCode 'INSTALL_MANIFEST_INVALID' -Hint $script:TcErrorHints['INSTALL_MANIFEST_INVALID'] `
            -ErrorMessage "Install manifest cannot be read: $($_.Exception.Message)" `
            -Data ([ordered]@{ installed = $true; manifestPath = $manifestPath; modulePath = $moduleDir; moduleVersion = $moduleVersion })
    }

    $data = [ordered]@{
        installed     = $true
        source        = 'install-manifest'
        moduleVersion = $moduleVersion
        modulePath    = $moduleDir
        manifestPath  = $manifestPath
        name          = $m.name
        sourceUrl     = $m.sourceUrl
        version       = $m.version
        release       = $m.release
        commit        = $m.commit
        ref           = $m.ref
        commitSource  = $m.commitSource
        installer     = $m.installer
        installedAt   = $m.installedAt
        sourcePath    = $m.sourcePath
        fileCount     = @($m.files).Count
    }
    if (-not $Verify) { return New-TcResult -Success $true -Data $data }

    $installRoot = Split-Path -Parent $manifestPath
    $v = Compare-TcInstallFiles -InstallRoot $installRoot -Expected @($m.files)
    $data['verify'] = $v
    if (-not $v.ok) {
        $n = @($v.mismatched).Count + @($v.missing).Count + @($v.extra).Count
        return New-TcResult -Success $false -ErrorCode 'INSTALL_MANIFEST_MISMATCH' -Hint $script:TcErrorHints['INSTALL_MANIFEST_MISMATCH'] `
            -ErrorMessage "$n installed file(s) differ from $($script:TcInstallManifestName) (mismatched $(@($v.mismatched).Count), missing $(@($v.missing).Count), extra $(@($v.extra).Count))" -Data $data
    }
    return New-TcResult -Success $true -Data $data
}
