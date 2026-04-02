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

    if ($null -ne ([System.Management.Automation.PSTypeName]'TcAdsHelper').Type) { return }

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

    # Common installation paths
    @(
        'C:\Program Files (x86)\Beckhoff\TwinCAT\3.1\Components\Base\v170\TwinCAT.Ads.dll',
        'C:\Program Files (x86)\Beckhoff\TwinCAT\3.1\Components\Base\v160\TwinCAT.Ads.dll',
        'C:\Program Files (x86)\Beckhoff\TwinCAT\3.1\Components\Base\v150\TwinCAT.Ads.dll'
    ) | ForEach-Object {
        if ((Test-Path $_) -and $dllPaths -notcontains $_) { $dllPaths += $_ }
    }

    # Try C# compilation with each DLL path
    if ($null -ne $csCode) {
        foreach ($dll in $dllPaths) {
            try {
                Add-Type -TypeDefinition $csCode -ReferencedAssemblies @($dll) -ErrorAction Stop
                Write-Verbose "TcAdsHelper compiled with: $dll"
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
    }
    catch {
        Write-Warning "Failed to compile TcAdsHelper fallback: $_"
    }
}

function Find-TcAdsAssembly {
    <#
    .SYNOPSIS
        Locates and loads TwinCAT.Ads.dll from TwinCAT installation paths.
    .OUTPUTS
        $true if loaded successfully, $false otherwise.
    #>
    [CmdletBinding()]
    param()

    # Check if already loaded
    $loaded = [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object {
        $_.GetName().Name -eq 'TwinCAT.Ads'
    }
    if ($loaded) {
        Initialize-TcAdsHelper $loaded.Location
        return $true
    }

    # Search paths in priority order (v170 = VS2022 matching DLL first)
    $searchPaths = @(
        'C:\Program Files (x86)\Beckhoff\TwinCAT\3.1\Components\Base\v170\TwinCAT.Ads.dll'
        'C:\Program Files (x86)\Beckhoff\TwinCAT\3.1\Components\Base\v160\TwinCAT.Ads.dll'
        'C:\Program Files (x86)\Beckhoff\TwinCAT\3.1\Components\Base\v150\TwinCAT.Ads.dll'
        'C:\Program Files (x86)\Beckhoff\TwinCAT\3.1\Components\TcDocGen\TwinCAT.Ads.dll'
        'C:\Program Files (x86)\Beckhoff\TwinCAT\Functions\TE1010-Realtime-Monitor\TwinCAT.Ads.dll'
    )

    foreach ($dllPath in $searchPaths) {
        if (Test-Path $dllPath) {
            try {
                $asm = [System.Reflection.Assembly]::LoadFrom($dllPath)
                Initialize-TcAdsHelper $dllPath
                return $true
            }
            catch {
                continue
            }
        }
    }

    # Fallback: try loading from GAC
    try {
        [System.Reflection.Assembly]::LoadWithPartialName('TwinCAT.Ads') | Out-Null
        $check = [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'TwinCAT.Ads' }
        if ($check) {
            Initialize-TcAdsHelper $check.Location
            return $true
        }
    }
    catch { }

    return $false
}
