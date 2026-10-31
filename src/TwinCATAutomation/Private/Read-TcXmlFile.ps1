function Read-TcXmlFile {
    <#
    .SYNOPSIS
        Loads an XML file from disk without DTD processing and without a resolver (no XXE): XmlDocument.
    .DESCRIPTION
        XmlReader with DtdProcessing = Prohibit and XmlResolver = $null, and an XmlDocument without a
        resolver, so no external entity or DTD is ever read; a file with a DOCTYPE throws
        (XmlException). Other parse errors throw too; the caller decides what that means.
        Used for project files read from the solution (.plcproj, .tsproj, .xti).
    .PARAMETER Path
        File path.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $doc = New-Object System.Xml.XmlDocument
    $doc.XmlResolver = $null
    $stream = $null
    $reader = $null
    try {
        # a FileStream: the reader never resolves the document URI itself
        $stream = [System.IO.File]::OpenRead($Path)
        $reader = [System.Xml.XmlReader]::Create($stream, $settings)
        $doc.Load($reader)
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
    Write-Output -NoEnumerate $doc
}
