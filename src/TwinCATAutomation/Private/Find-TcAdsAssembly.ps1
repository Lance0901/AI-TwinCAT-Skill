function Initialize-TcAdsHelper {
    <#
    .SYNOPSIS
        Compiles the C# ADS helper, or falls back to a pure-PowerShell implementation.
    .DESCRIPTION
        Tries to compile TcAdsHelper.cs via Add-Type with multiple strategies.
        If ALL C# compilation strategies fail (common on PowerShell 7 where the
        Roslyn compiler cannot reference .NET Framework DLLs), registers a
        pure-PowerShell fallback class that uses raw ADS byte-level reads.
    #>
    param([string]$AdsAssemblyPath)

    $existingType = ([System.Management.Automation.PSTypeName]'TcAdsHelper').Type
    if ($null -ne $existingType) {
        # Type survives Import-Module -Force (same AppDomain); recover the backend mode
        # from its signature: compiled helper takes TcAdsClient, reflection helper takes object.
        if ([string]::IsNullOrWhiteSpace($script:TcAdsHelperMode)) {
            $script:TcAdsHelperMode = 'reflection'
            try {
                $m = $existingType.GetMethod('GetSymbolInfo')
                if ($null -ne $m) {
                    $p0 = $m.GetParameters()[0].ParameterType.FullName
                    if ($p0 -eq 'TwinCAT.Ads.TcAdsClient') { $script:TcAdsHelperMode = 'compiled' }
                }
            }
            catch { }
        }
        return
    }

    $csFile = Join-Path $PSScriptRoot 'TcAdsHelper.cs'
    $csCode = $null
    if (Test-Path $csFile) {
        $csCode = Get-Content -Path $csFile -Raw
    }

    # Collect all DLL paths to try
    $dllPaths = @()

    # From parameter
    if (-not [string]::IsNullOrWhiteSpace($AdsAssemblyPath) -and (Test-Path $AdsAssemblyPath)) {
        $dllPaths += $AdsAssemblyPath
    }

    # From loaded assemblies
    $loadedAsm = [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object {
        $_.GetName().Name -eq 'TwinCAT.Ads'
    } | Select-Object -First 1
    if ($null -ne $loadedAsm) {
        $loc = try { $loadedAsm.Location } catch { '' }
        if (-not [string]::IsNullOrWhiteSpace($loc) -and (Test-Path $loc) -and $dllPaths -notcontains $loc) {
            $dllPaths += $loc
        }
    }

    # Common installation paths (4024 + 4026 layouts, plus bounded recursive search)
    foreach ($candidate in (Get-TcAdsAssemblyCandidates)) {
        if ($dllPaths -notcontains $candidate) { $dllPaths += $candidate }
    }

    # Try C# compilation with each DLL path
    if ($null -ne $csCode) {
        foreach ($dll in $dllPaths) {
            try {
                Add-Type -TypeDefinition $csCode -ReferencedAssemblies @($dll) -ErrorAction Stop
                Write-Verbose "TcAdsHelper compiled with: $dll"
                $script:TcAdsHelperMode = 'compiled'
                return
            }
            catch {
                Write-Verbose "Add-Type with $dll failed: $_"
            }
        }

        # Also try assembly name reference (for GAC)
        try {
            Add-Type -TypeDefinition $csCode -ReferencedAssemblies @('TwinCAT.Ads') -ErrorAction Stop
            Write-Verbose "TcAdsHelper compiled with assembly name reference"
            $script:TcAdsHelperMode = 'compiled'
            return
        }
        catch {
            Write-Verbose "Add-Type with assembly name failed: $_"
        }
    }

    # --- Fallback: Pure-PowerShell implementation ---
    # When C# compilation fails (e.g. PowerShell 7 + .NET Framework DLL),
    # define TcAdsHelper as a PowerShell class using raw byte-level ADS reads.
    Write-Verbose "C# compilation failed, using PowerShell fallback for TcAdsHelper"

    $fallbackCode = @'
public static class TcAdsHelper
{
    public static System.Collections.Generic.Dictionary<string, object> GetSymbolInfo(
        object client, string varPath)
    {
        // Use reflection to call ADS methods — works regardless of compiler compatibility
        var clientType = client.GetType();

        byte[] nameBytes = System.Text.Encoding.ASCII.GetBytes(varPath + '\0');

        // Create AdsStream instances via reflection
        var adsStreamType = clientType.Assembly.GetType("TwinCAT.Ads.AdsStream");
        var writeStream = System.Activator.CreateInstance(adsStreamType, new object[] { nameBytes });
        var readStream = System.Activator.CreateInstance(adsStreamType, new object[] { (int)0xFFFF });

        // Set Position = 0
        var positionProp = adsStreamType.GetProperty("Position");
        positionProp.SetValue(writeStream, (long)0);
        positionProp.SetValue(readStream, (long)0);

        // Get the Stream's Length
        var lengthProp = adsStreamType.GetProperty("Length");
        int readLen = (int)(long)lengthProp.GetValue(readStream);

        // Call ReadWrite(uint, uint, AdsStream, int, int, AdsStream, int, int)
        var readWriteMethod = clientType.GetMethod("ReadWrite",
            new System.Type[] {
                typeof(uint), typeof(uint),
                adsStreamType, typeof(int), typeof(int),
                adsStreamType, typeof(int), typeof(int)
            });
        readWriteMethod.Invoke(client, new object[] {
            (uint)0xF009, (uint)0,
            readStream, 0, readLen,
            writeStream, 0, nameBytes.Length
        });

        // Parse response
        positionProp.SetValue(readStream, (long)0);
        var reader = new System.IO.BinaryReader((System.IO.Stream)readStream);

        uint entryLen = reader.ReadUInt32();
        uint indexGroup = reader.ReadUInt32();
        uint indexOffset = reader.ReadUInt32();
        uint size = reader.ReadUInt32();
        uint dataType = reader.ReadUInt32();
        uint flags = reader.ReadUInt32();
        ushort nameLen = reader.ReadUInt16();
        ushort typeLen = reader.ReadUInt16();
        ushort commentLen = reader.ReadUInt16();

        string name = System.Text.Encoding.ASCII.GetString(reader.ReadBytes(nameLen));
        reader.ReadByte();
        string typeName = System.Text.Encoding.ASCII.GetString(reader.ReadBytes(typeLen));
        reader.ReadByte();
        string comment = commentLen > 0 ? System.Text.Encoding.ASCII.GetString(reader.ReadBytes(commentLen)) : "";

        var result = new System.Collections.Generic.Dictionary<string, object>();
        result["Name"] = name;
        result["TypeName"] = typeName;
        result["Size"] = (int)size;
        result["DataTypeId"] = dataType;
        result["IndexGroup"] = indexGroup;
        result["IndexOffset"] = indexOffset;
        result["Comment"] = comment;
        return result;
    }

    public static System.Collections.Generic.List<System.Collections.Generic.Dictionary<string, object>> GetAllSymbols(
        object client, string filter)
    {
        var result = new System.Collections.Generic.List<System.Collections.Generic.Dictionary<string, object>>();
        var clientType = client.GetType();
        var adsStreamType = clientType.Assembly.GetType("TwinCAT.Ads.AdsStream");
        var positionProp = adsStreamType.GetProperty("Position");

        // Read method: Read(uint, uint, AdsStream)
        var readMethod = clientType.GetMethod("Read",
            new System.Type[] { typeof(uint), typeof(uint), adsStreamType });

        // Get upload info
        var infoStream = System.Activator.CreateInstance(adsStreamType, new object[] { (int)24 });
        readMethod.Invoke(client, new object[] { (uint)0xF00F, (uint)0, infoStream });
        positionProp.SetValue(infoStream, (long)0);
        var infoReader = new System.IO.BinaryReader((System.IO.Stream)infoStream);
        uint symbolCount = infoReader.ReadUInt32();
        uint symbolLength = infoReader.ReadUInt32();

        // Upload all symbols
        var symStream = System.Activator.CreateInstance(adsStreamType, new object[] { (int)symbolLength });
        readMethod.Invoke(client, new object[] { (uint)0xF00B, (uint)0, symStream });
        positionProp.SetValue(symStream, (long)0);
        var symReader = new System.IO.BinaryReader((System.IO.Stream)symStream);

        for (int i = 0; i < (int)symbolCount; i++)
        {
            long startPos = (long)positionProp.GetValue(symStream);
            uint entryLen = symReader.ReadUInt32();
            symReader.ReadUInt32(); symReader.ReadUInt32();
            uint size = symReader.ReadUInt32();
            symReader.ReadUInt32(); symReader.ReadUInt32();
            ushort nameLen = symReader.ReadUInt16();
            ushort typeLen = symReader.ReadUInt16();
            ushort commentLen = symReader.ReadUInt16();

            string name = System.Text.Encoding.ASCII.GetString(symReader.ReadBytes(nameLen));
            symReader.ReadByte();
            string typeName = System.Text.Encoding.ASCII.GetString(symReader.ReadBytes(typeLen));
            symReader.ReadByte();
            string comment = commentLen > 0 ? System.Text.Encoding.ASCII.GetString(symReader.ReadBytes(commentLen)) : "";
            if (commentLen > 0) symReader.ReadByte();

            positionProp.SetValue(symStream, startPos + entryLen);

            if (!string.IsNullOrEmpty(filter))
            {
                string pattern = "^" + System.Text.RegularExpressions.Regex.Escape(filter)
                    .Replace(@"\*", ".*") + "$";
                if (!System.Text.RegularExpressions.Regex.IsMatch(name, pattern,
                    System.Text.RegularExpressions.RegexOptions.IgnoreCase))
                    continue;
            }

            var entry = new System.Collections.Generic.Dictionary<string, object>();
            entry["Name"] = name;
            entry["TypeName"] = typeName;
            entry["Size"] = (int)size;
            entry["Comment"] = comment;
            result.Add(entry);
        }
        return result;
    }
}
'@

    try {
        Add-Type -TypeDefinition $fallbackCode -ErrorAction Stop
        Write-Verbose "TcAdsHelper fallback (reflection-based) compiled successfully"
        $script:TcAdsHelperMode = 'reflection'
    }
    catch {
        Write-Warning "Failed to compile TcAdsHelper fallback: $_"
        $script:TcAdsHelperMode = $null
    }
}

function Get-TcAdsFileVersion {
    <#
    .SYNOPSIS
        Returns the FileVersion of a DLL as [version], or $null when unreadable.
    #>
    param([string]$Path)
    try {
        $fv = (Get-Item -LiteralPath $Path -ErrorAction Stop).VersionInfo.FileVersion
        if ([string]::IsNullOrWhiteSpace($fv)) { return $null }
        # FileVersion may carry a suffix ("4.3.32.0 built by ..."); keep the numeric head.
        if ($fv -match '^\s*(\d+(\.\d+){1,3})') { return [version]$Matches[1] }
        return $null
    }
    catch { return $null }
}

function Test-TcAdsAssemblyCompatible {
    <#
    .SYNOPSIS
        $true when the DLL exposes the 4.x API (TwinCAT.Ads.TcAdsClient) this module uses.
    .DESCRIPTION
        TwinCAT.Ads 6.x/7.x (shipped with some Functions, e.g. TE1010, TF6420 server)
        replaced TcAdsClient with AdsClient and targets .NET Core; loading one of those
        would make New-Object TwinCAT.Ads.TcAdsClient fail. Unknown versions are accepted.
    #>
    param([string]$Path)
    $v = Get-TcAdsFileVersion -Path $Path
    if ($null -eq $v) { return $true }
    return ($v.Major -lt 6)
}

function Get-TcAdsAssemblyCandidates {
    <#
    .SYNOPSIS
        Returns existing TwinCAT.Ads.dll paths in priority order (4024 + 4026 layouts).
    .DESCRIPTION
        1. Well-known paths: 32-bit Program Files (4024), 64-bit Program Files and
           v180 (4026), $env:TWINCAT3DIR, C:\TwinCAT\3.1.
        2. Bounded recursive search (-Depth 3) under <TWINCAT3DIR>\Components and the
           Program Files Components folders, highest FileVersion first.
        Only API-compatible (< 6.0) DLLs are returned. Result is cached per session.
    #>
    [CmdletBinding()]
    param()

    if ($null -ne $script:TcAdsAssemblyCandidates) { return $script:TcAdsAssemblyCandidates }

    $tcDir = $env:TWINCAT3DIR
    $wellKnown = @(
        # 4024 (32-bit XAE, 32-bit Program Files)
        'C:\Program Files (x86)\Beckhoff\TwinCAT\3.1\Components\Base\v170\TwinCAT.Ads.dll'
        'C:\Program Files (x86)\Beckhoff\TwinCAT\3.1\Components\Base\v160\TwinCAT.Ads.dll'
        'C:\Program Files (x86)\Beckhoff\TwinCAT\3.1\Components\Base\v150\TwinCAT.Ads.dll'
        # 4026 (64-bit Program Files / v180)
        'C:\Program Files\Beckhoff\TwinCAT\3.1\Components\Base\v170\TwinCAT.Ads.dll'
        'C:\Program Files (x86)\Beckhoff\TwinCAT\3.1\Components\Base\v180\TwinCAT.Ads.dll'
        'C:\Program Files\Beckhoff\TwinCAT\3.1\Components\Base\v180\TwinCAT.Ads.dll'
    )
    if (-not [string]::IsNullOrWhiteSpace($tcDir)) {
        $wellKnown += (Join-Path $tcDir 'Components\Base\v170\TwinCAT.Ads.dll')
        $wellKnown += (Join-Path $tcDir 'Components\Base\v180\TwinCAT.Ads.dll')
    }
    $wellKnown += @(
        'C:\TwinCAT\3.1\Components\Base\v170\TwinCAT.Ads.dll'
        'C:\Program Files (x86)\Beckhoff\TwinCAT\3.1\Components\TcDocGen\TwinCAT.Ads.dll'
        'C:\Program Files (x86)\Beckhoff\TwinCAT\Functions\TE1010-Realtime-Monitor\TwinCAT.Ads.dll'
    )

    $result = @()
    foreach ($p in $wellKnown) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $full = [IO.Path]::GetFullPath($p)
        if ($result -contains $full) { continue }
        if (-not (Test-TcAdsAssemblyCompatible -Path $full)) {
            Write-Verbose "Get-TcAdsAssemblyCandidates: skipping $full (TwinCAT.Ads >= 6.x, no TcAdsClient)"
            continue
        }
        $result += $full
    }

    # Last resort: bounded recursive search, highest compatible version first
    $searchRoots = @()
    if (-not [string]::IsNullOrWhiteSpace($tcDir)) { $searchRoots += (Join-Path $tcDir 'Components') }
    $searchRoots += 'C:\Program Files (x86)\Beckhoff\TwinCAT\3.1\Components'
    $searchRoots += 'C:\Program Files\Beckhoff\TwinCAT\3.1\Components'
    $seenRoots = @()
    $found = @()
    foreach ($root in $searchRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $rootFull = [IO.Path]::GetFullPath($root).TrimEnd('\')
        if ($seenRoots -contains $rootFull) { continue }
        $seenRoots += $rootFull
        try {
            $hits = Get-ChildItem -LiteralPath $rootFull -Recurse -Depth 3 -Filter 'TwinCAT.Ads.dll' -File -ErrorAction SilentlyContinue
            foreach ($h in $hits) {
                if ($result -contains $h.FullName) { continue }
                if (-not (Test-TcAdsAssemblyCompatible -Path $h.FullName)) { continue }
                $v = Get-TcAdsFileVersion -Path $h.FullName
                if ($null -eq $v) { $v = [version]'0.0' }
                $found += [PSCustomObject]@{ Path = $h.FullName; Version = $v }
            }
        }
        catch {
            Write-Verbose "Get-TcAdsAssemblyCandidates: search under $rootFull failed: $_"
        }
    }
    foreach ($f in ($found | Sort-Object -Property Version -Descending)) {
        if ($result -notcontains $f.Path) { $result += $f.Path }
    }

    $script:TcAdsAssemblyCandidates = $result
    return $result
}

function Find-TcAdsAssembly {
    <#
    .SYNOPSIS
        Locates and loads TwinCAT.Ads.dll from TwinCAT installation paths.
    .DESCRIPTION
        Candidate order: already-loaded assembly, well-known 4024/4026 paths,
        $env:TWINCAT3DIR, bounded recursive search (highest 4.x version), GAC.
        Records the DLL actually in use in $script:TcAdsAssemblyPath /
        $script:TcAdsAssemblyVersion; Initialize-TcAdsHelper records the helper
        backend in $script:TcAdsHelperMode ('compiled' | 'reflection').
    .OUTPUTS
        $true if loaded successfully, $false otherwise.
    #>
    [CmdletBinding()]
    param()

    # Check if already loaded
    $loaded = [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object {
        $_.GetName().Name -eq 'TwinCAT.Ads'
    } | Select-Object -First 1
    if ($loaded) {
        $loc = try { $loaded.Location } catch { '' }
        Set-TcAdsAssemblyInfo -Path $loc -Assembly $loaded
        Initialize-TcAdsHelper $loc
        return $true
    }

    foreach ($dllPath in (Get-TcAdsAssemblyCandidates)) {
        try {
            $asm = [System.Reflection.Assembly]::LoadFrom($dllPath)
            Set-TcAdsAssemblyInfo -Path $dllPath -Assembly $asm
            Write-Verbose "Find-TcAdsAssembly: loaded $dllPath (v$($script:TcAdsAssemblyVersion))"
            Initialize-TcAdsHelper $dllPath
            return $true
        }
        catch {
            Write-Verbose "Find-TcAdsAssembly: LoadFrom($dllPath) failed: $_"
            continue
        }
    }

    # Fallback: try loading from GAC
    try {
        [System.Reflection.Assembly]::LoadWithPartialName('TwinCAT.Ads') | Out-Null
        $check = [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'TwinCAT.Ads' } | Select-Object -First 1
        if ($check) {
            $loc = try { $check.Location } catch { '' }
            Set-TcAdsAssemblyInfo -Path $loc -Assembly $check
            Initialize-TcAdsHelper $loc
            return $true
        }
    }
    catch { }

    return $false
}

function Set-TcAdsAssemblyInfo {
    <#
    .SYNOPSIS
        Stores the loaded TwinCAT.Ads.dll path/version in module state.
    #>
    param(
        [string]$Path,
        [object]$Assembly
    )
    $script:TcAdsAssemblyPath = if ([string]::IsNullOrWhiteSpace($Path)) { $null } else { $Path }
    $ver = $null
    if (-not [string]::IsNullOrWhiteSpace($Path) -and (Test-Path -LiteralPath $Path)) {
        $v = Get-TcAdsFileVersion -Path $Path
        if ($null -ne $v) { $ver = $v.ToString() }
    }
    if ($null -eq $ver -and $null -ne $Assembly) {
        try { $ver = $Assembly.GetName().Version.ToString() } catch { }
    }
    $script:TcAdsAssemblyVersion = $ver
}
