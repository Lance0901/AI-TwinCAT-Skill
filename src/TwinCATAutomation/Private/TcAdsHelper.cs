using TwinCAT.Ads;
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

/// <summary>
/// C# helper to bypass PowerShell CLS compatibility issues with TcAdsSymbol.
/// TwinCAT.Ads.dll has both 'Datatype' and 'DataType' properties which differ
/// only in case — PowerShell cannot distinguish them, causing runtime errors.
/// This helper uses raw ADS protocol reads to get symbol information directly.
/// </summary>
public static class TcAdsHelper
{
    /// <summary>
    /// Gets symbol information for a single variable using raw ADS read
    /// (ADSIGRP_SYM_INFOBYNAMEEX = 0xF009).
    /// </summary>
    public static Dictionary<string, object> GetSymbolInfo(TcAdsClient client, string varPath)
    {
        var result = new Dictionary<string, object>();
        byte[] nameBytes = Encoding.ASCII.GetBytes(varPath + '\0');
        var writeStream = new AdsStream(nameBytes);
        var readStream = new AdsStream(0xFFFF);

        writeStream.Position = 0;
        readStream.Position = 0;
        client.ReadWrite((uint)0xF009, (uint)0, readStream, 0, (int)readStream.Length,
                         writeStream, 0, nameBytes.Length);

        readStream.Position = 0;
        var reader = new BinaryReader(readStream);

        uint entryLen = reader.ReadUInt32();
        uint indexGroup = reader.ReadUInt32();
        uint indexOffset = reader.ReadUInt32();
        uint size = reader.ReadUInt32();
        uint dataType = reader.ReadUInt32();
        uint flags = reader.ReadUInt32();
        ushort nameLen = reader.ReadUInt16();
        ushort typeLen = reader.ReadUInt16();
        ushort commentLen = reader.ReadUInt16();

        string name = Encoding.ASCII.GetString(reader.ReadBytes(nameLen));
        reader.ReadByte();
        string typeName = Encoding.ASCII.GetString(reader.ReadBytes(typeLen));
        reader.ReadByte();
        string comment = commentLen > 0 ? Encoding.ASCII.GetString(reader.ReadBytes(commentLen)) : "";

        result["Name"] = name;
        result["TypeName"] = typeName;
        result["Size"] = (int)size;
        result["DataTypeId"] = dataType;
        result["IndexGroup"] = indexGroup;
        result["IndexOffset"] = indexOffset;
        result["Comment"] = comment;
        return result;
    }

    /// <summary>
    /// Gets all symbols using raw ADS upload
    /// (ADSIGRP_SYM_UPLOADINFO = 0xF00F + ADSIGRP_SYM_UPLOAD = 0xF00B).
    /// </summary>
    public static List<Dictionary<string, object>> GetAllSymbols(TcAdsClient client, string filter)
    {
        var result = new List<Dictionary<string, object>>();

        // Get upload info (symbol count + total byte length)
        var infoStream = new AdsStream(24);
        client.Read((uint)0xF00F, (uint)0, infoStream);
        infoStream.Position = 0;
        var infoReader = new BinaryReader(infoStream);
        uint symbolCount = infoReader.ReadUInt32();
        uint symbolLength = infoReader.ReadUInt32();

        // Upload all symbols
        var symStream = new AdsStream((int)symbolLength);
        client.Read((uint)0xF00B, (uint)0, symStream);
        symStream.Position = 0;
        var symReader = new BinaryReader(symStream);

        for (int i = 0; i < (int)symbolCount; i++)
        {
            long startPos = symStream.Position;
            uint entryLen = symReader.ReadUInt32();
            symReader.ReadUInt32(); // indexGroup
            symReader.ReadUInt32(); // indexOffset
            uint size = symReader.ReadUInt32();
            symReader.ReadUInt32(); // dataType
            symReader.ReadUInt32(); // flags
            ushort nameLen = symReader.ReadUInt16();
            ushort typeLen = symReader.ReadUInt16();
            ushort commentLen = symReader.ReadUInt16();

            string name = Encoding.ASCII.GetString(symReader.ReadBytes(nameLen));
            symReader.ReadByte();
            string typeName = Encoding.ASCII.GetString(symReader.ReadBytes(typeLen));
            symReader.ReadByte();
            string comment = commentLen > 0 ? Encoding.ASCII.GetString(symReader.ReadBytes(commentLen)) : "";
            if (commentLen > 0) symReader.ReadByte();

            // Advance to next entry
            symStream.Position = startPos + entryLen;

            // Apply filter if specified
            if (!string.IsNullOrEmpty(filter))
            {
                string pattern = "^" + System.Text.RegularExpressions.Regex.Escape(filter)
                    .Replace(@"\*", ".*") + "$";
                if (!System.Text.RegularExpressions.Regex.IsMatch(name, pattern,
                    System.Text.RegularExpressions.RegexOptions.IgnoreCase))
                    continue;
            }

            result.Add(new Dictionary<string, object>
            {
                { "Name", name },
                { "TypeName", typeName },
                { "Size", (int)size },
                { "Comment", comment }
            });
        }
        return result;
    }
}
