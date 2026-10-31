function Add-TcAdsRoute {
    <#
    .SYNOPSIS
        Adds an ADS route (TIRR AddRoute, credentials of the remote system) or a project route (AddProjectRoute) and reads TIRR back. Dry-run by default. NOT MEASURED: there was no second target.
    .DESCRIPTION
        TE1000 Automation Interface manual v1.7.0 6.3.17 p.220-221, 6.4.1 p.222-223: ConsumeXml on TIRR
        with <RoutePrj><AddRoute><RemoteName/><RemoteNetId/><RemoteIpAddr/> (or <RemoteHostName/>)
        <UserName/><Password/><NoEncryption/><LocalName/></AddRoute></RoutePrj>, or
        <AddProjectRoute><Name/><NetId/><IpAddr/> (or <HostName/>)</AddProjectRoute> that only goes
        into the project. "Only unencrypted routes are created using this method; ADS Secure /
        encrypted routes are not supported" (p.220). The manual samples also send
        <TargetList><BroadcastSearch>true</BroadcastSearch></TargetList>; that part is left out here
        (a search only works with the local system as target, phase3-probe.md question 23).
        NOT MEASURED (openspec/changes/complete-automation-interface/verification/phase3-probe.md
        questions 24, 25, 27: no second target). Only unit tests; registered verification is task 4.6.
        Password: only -PasswordEnv (name of an environment variable of THIS process, Process scope
        only, and it must be named TCAUTO_ROUTE_PW or TCAUTO_ROUTE_PW_<SUFFIX> (upper case, digits,
        '_'), so no other variable can be read through it; over MCP set it in the server's env) or -Password as a SecureString (PowerShell only). The plain text exists
        only while the XML is built and sent; data, messages, hints, logs and the backup never
        contain it or the XML (passwords are masked as ***; a message from XAE is cleaned with
        Protect-TcSecretText). Credentials sent with AddRoute are protected only by a fixed key
        (Beckhoff Security Advisory 2017-002, CVE-2017-16718): use it on a trusted network.
        Checks (nothing sent): -NetId a.b.c.d.e.f; exactly one of -Address (IPv4) / -HostName; a
        route with that NetId already in TIRR -> ROUTE_ALREADY_EXISTS; AddRoute needs -UserName and
        exactly one password source (ROUTE_PASSWORD_MISSING when the variable is empty).
        DryRun (default true): data.fields (password '***', data.passwordSource 'env:<name>' |
        'SecureString'). DryRun=false: TIRR ProduceXml backup (masked), IDE_MODAL_DIALOG check,
        ConsumeXml, TIRR read back: the NetId must be in ProjectRoutes (-ProjectRoute) or in
        StaticRoutes / ActualRoutes (ROUTE_VERIFY_FAILED). XAE refusing -> ROUTE_ADD_FAILED.
        A project route records BUILD_REQUIRED (code-changed: it changes the project); AddRoute
        changes the route table of the systems, not the project.
        Removing a route is NOT offered: the Automation Interface cannot delete it (p.220); it means
        editing StaticRoutes.xml and restarting the TwinCAT service, which also stops a local UmRT
        (docs/troubleshooting.md "ADS route", known-limitations).
    .PARAMETER Name
        Route name (RemoteName / Name), letters, digits, '_', '-', '.', ' '.
    .PARAMETER NetId
        AmsNetId of the remote system, e.g. 5.1.2.3.1.1.
    .PARAMETER Address
        IPv4 address of the remote system. Exactly one of Address / HostName.
    .PARAMETER HostName
        Host name of the remote system. Exactly one of Address / HostName.
    .PARAMETER UserName
        User on the remote system (AddRoute only).
    .PARAMETER PasswordEnv
        Name of the environment variable (Process scope) that holds the password, TCAUTO_ROUTE_PW or TCAUTO_ROUTE_PW_<SUFFIX> (AddRoute only); the value is never returned.
    .PARAMETER Password
        Password as SecureString (PowerShell only, not offered over MCP).
    .PARAMETER LocalName
        Optional name of this system in the remote route table (AddRoute LocalName).
    .PARAMETER ProjectRoute
        Add only a project route (AddProjectRoute, no credentials, nothing sent to the remote system).
    .PARAMETER DryRun
        Default true: only check and report. false: back up, send, read back.
    .EXAMPLE
        Add-TcAdsRoute -Name CX-1 -NetId 5.1.2.3.1.1 -Address 192.168.1.20 -UserName Administrator -PasswordEnv TCAUTO_ROUTE_PW
    .EXAMPLE
        Add-TcAdsRoute -Name CX-1 -NetId 5.1.2.3.1.1 -Address 192.168.1.20 -ProjectRoute -DryRun $false
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Name,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$NetId,

        [Parameter()]
        [string]$Address,

        [Parameter()]
        [string]$HostName,

        [Parameter()]
        [string]$UserName,

        [Parameter()]
        [string]$PasswordEnv,

        [Parameter()]
        [System.Security.SecureString]$Password,

        [Parameter()]
        [string]$LocalName,

        [Parameter()]
        [switch]$ProjectRoute,

        [Parameter()]
        [bool]$DryRun = $true
    )

    $data = [PSCustomObject]@{ name = $Name; netId = $NetId; projectRoute = [bool]$ProjectRoute; dryRun = $DryRun }
    $bad = $null
    $hasAddr = -not [string]::IsNullOrWhiteSpace($Address)
    $hasHost = -not [string]::IsNullOrWhiteSpace($HostName)
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name -notmatch '^[A-Za-z0-9_.\- ]{1,64}$') { $bad = "-Name must be 1-64 letters, digits, '_', '-', '.' or ' ' (got '$Name')" }
    elseif (-not (Test-TcAmsNetIdText -Value $NetId)) { $bad = "-NetId must be an AmsNetId a.b.c.d.e.f (got '$NetId')" }
    elseif ($hasAddr -eq $hasHost) { $bad = 'give exactly one of -Address and -HostName' }
    elseif ($hasAddr -and -not (Test-TcIpv4Text -Value $Address)) { $bad = "-Address must be an IPv4 address (got '$Address')" }
    elseif ($hasHost -and -not (Test-TcHostNameText -Value $HostName)) { $bad = "-HostName is not a host name (got '$HostName')" }
    elseif (-not [string]::IsNullOrEmpty($LocalName) -and $LocalName -notmatch '^[A-Za-z0-9_.\- ]{1,64}$') { $bad = "-LocalName must be 1-64 letters, digits, '_', '-', '.' or ' '" }
    if ($null -ne $bad) { return New-TcResult -Success $false -ErrorCode 'INVALID_PARAMS' -Data $data -ErrorMessage "$bad; nothing was sent." }
    $hasEnv = -not [string]::IsNullOrWhiteSpace($PasswordEnv)
    $hasSecure = $null -ne $Password
    if (-not $ProjectRoute) {
        if ([string]::IsNullOrWhiteSpace($UserName) -or $UserName -match '[\x00-\x1F<>]') { return New-TcResult -Success $false -ErrorCode 'INVALID_PARAMS' -Data $data -ErrorMessage 'AddRoute needs -UserName (the user on the remote system); nothing was sent.' }
        if ($hasEnv -eq $hasSecure) { return New-TcResult -Success $false -ErrorCode 'ROUTE_PASSWORD_MISSING' -Data $data -ErrorMessage 'AddRoute needs exactly one of -PasswordEnv (environment variable name) and -Password (SecureString); nothing was sent.' -Hint (Get-TcErrorHint -Code 'ROUTE_PASSWORD_MISSING') }
        # review B1: only variables named for this purpose, so -PasswordEnv cannot read any other
        # secret of the process (PATH-like names, API keys ...)
        if ($hasEnv -and $PasswordEnv -cnotmatch $script:TcRoutePasswordEnvPattern) { return New-TcResult -Success $false -ErrorCode 'INVALID_PARAMS' -Data $data -ErrorMessage "-PasswordEnv must be named TCAUTO_ROUTE_PW or TCAUTO_ROUTE_PW_<SUFFIX> (upper case, digits, '_'; got '$PasswordEnv'); nothing was read or sent." }
        $data | Add-Member -NotePropertyName passwordSource -NotePropertyValue $(if ($hasEnv) { "env:$PasswordEnv" } else { 'SecureString' })
        if ($hasEnv) {
            $probe = [Environment]::GetEnvironmentVariable($PasswordEnv, 'Process')
            $empty = [string]::IsNullOrEmpty($probe)
            $probe = $null
            if ($empty) { return New-TcResult -Success $false -ErrorCode 'ROUTE_PASSWORD_MISSING' -Data $data -ErrorMessage "The environment variable '$PasswordEnv' is empty or not set in this process; nothing was sent." -Hint (Get-TcErrorHint -Code 'ROUTE_PASSWORD_MISSING') }
        }
    }
    elseif ($hasEnv -or $hasSecure -or -not [string]::IsNullOrWhiteSpace($UserName)) {
        return New-TcResult -Success $false -ErrorCode 'INVALID_PARAMS' -Data $data -ErrorMessage '-ProjectRoute sends no credentials: leave -UserName / -PasswordEnv / -Password out; nothing was sent.'
    }
    $fields = [ordered]@{}
    if ($ProjectRoute) { $fields.Name = $Name; $fields.NetId = $NetId; if ($hasAddr) { $fields.IpAddr = $Address } else { $fields.HostName = $HostName } }
    else {
        $fields.RemoteName = $Name; $fields.RemoteNetId = $NetId
        if ($hasAddr) { $fields.RemoteIpAddr = $Address } else { $fields.RemoteHostName = $HostName }
        $fields.UserName = $UserName; $fields.Password = $script:TcPasswordMask; $fields.NoEncryption = ''
        if (-not [string]::IsNullOrEmpty($LocalName)) { $fields.LocalName = $LocalName }
    }
    $data | Add-Member -NotePropertyName command -NotePropertyValue $(if ($ProjectRoute) { 'AddProjectRoute' } else { 'AddRoute' })
    $data | Add-Member -NotePropertyName fields -NotePropertyValue ([PSCustomObject]$fields)
    $data | Add-Member -NotePropertyName measured -NotePropertyValue $false

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }
    $sm = Get-TcSysManager
    if ($null -eq $sm) { return New-TcNoSysManagerResult }

    $called = $false
    $plain = $null
    try {
        $rp = Read-TcRoutePrj -SysManager $sm -Data $data
        if ($null -ne $rp.Result) { return $rp.Result }
        $data | Add-Member -NotePropertyName target -NotePropertyValue $rp.Routes.target
        $all = @($rp.Routes.staticRoutes) + @($rp.Routes.actualRoutes) + @($rp.Routes.projectRoutes)
        $dup = @($all | Where-Object { $null -ne $_.PSObject.Properties['netId'] -and [string]$_.netId -eq $NetId })
        if ($dup.Count -gt 0) {
            $data | Add-Member -NotePropertyName existingRoutes -NotePropertyValue $dup
            return New-TcResult -Success $false -ErrorCode 'ROUTE_ALREADY_EXISTS' -Data $data -ErrorMessage "A route to $NetId already exists in TIRR; nothing was sent." -Hint (Get-TcErrorHint -Code 'ROUTE_ALREADY_EXISTS')
        }
        if ($DryRun) { return New-TcResult -Success $true -Data $data }

        $bk = New-TcConfigBackup -Label 'TIRR' -Text $rp.Xml -DiskFiles $(if ($ProjectRoute) { @((Find-TcSolutionTsProjFile).Files) } else { @() }) -Data $data
        if ($null -ne $bk.Result) { return $bk.Result }
        Add-TcBackupToData -Data $data -Backup $bk.Backup
        $dlg = Get-TcTreeItemDialogResult -Operation "ConsumeXml TIRR ($($data.command))" -Data $data
        if ($null -ne $dlg) { return $dlg }

        if (-not $ProjectRoute) {
            if ($hasEnv) {
                $plain = [Environment]::GetEnvironmentVariable($PasswordEnv, 'Process')
            }
            else {
                $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
                try { $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
                finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            }
        }
        $doc = New-Object System.Xml.XmlDocument
        $ti = $doc.AppendChild($doc.CreateElement('TreeItem'))
        $cmd = $ti.AppendChild($doc.CreateElement('RoutePrj')).AppendChild($doc.CreateElement($data.command))
        foreach ($k in $fields.Keys) {
            $e = $cmd.AppendChild($doc.CreateElement($k))
            $e.InnerText = $(if ($k -eq 'Password') { [string]$plain } else { [string]$fields[$k] })
        }
        $xml = $doc.OuterXml
        $doc = $null
        $item = $rp.Item
        $called = $true
        $data | Add-Member -NotePropertyName writeCalled -NotePropertyValue $true -Force
        # No deadline (CODING_STANDARDS.md 1): a dialog was ruled out just above; the duration of
        # AddRoute was not measured (no second target); the MCP tool timeout bounds it.
        try { Invoke-TcComRetry -OperationName "ConsumeXml TIRR ($($data.command))" -ScriptBlock { $item.ConsumeXml($xml) } | Out-Null }
        catch {
            $msg = Protect-TcSecretText -Text (Get-TcExceptionText -InputObject $_) -Secret $plain
            $xml = $null; $plain = $null
            $pass = Get-TcTreeItemPassThroughError -ErrorRecord $msg
            $code = if ($null -ne $pass) { $pass.Code } else { 'ROUTE_ADD_FAILED' }
            $res = New-TcResult -Success $false -ErrorCode $code -Data $data -ErrorMessage "XAE refused $($data.command): $msg" -Hint $(if ($null -ne $pass) { $pass.Hint } else { Get-TcErrorHint -Code $code })
            if ($ProjectRoute) { $res = Register-TcCodeChange -Result $res -Change "Add-TcAdsRoute $Name [failed]" }
            return $res
        }
        $xml = $null; $plain = $null
        $after = Read-TcRoutePrj -SysManager $sm -Data $data
        if ($null -ne $after.Result) { return $after.Result }
        $lists = if ($ProjectRoute) { @($after.Routes.projectRoutes) } else { @($after.Routes.staticRoutes) + @($after.Routes.actualRoutes) }
        $hit = @($lists | Where-Object { $null -ne $_.PSObject.Properties['netId'] -and [string]$_.netId -eq $NetId })
        $data | Add-Member -NotePropertyName readback -NotePropertyValue $hit
        $res = $null
        if ($hit.Count -eq 0) {
            $data | Add-Member -NotePropertyName verified -NotePropertyValue $false
            $res = New-TcResult -Success $false -ErrorCode 'ROUTE_VERIFY_FAILED' -Data $data `
                -ErrorMessage "$($data.command) returned, but TIRR has no route to $NetId in $(if ($ProjectRoute) { 'ProjectRoutes' } else { 'StaticRoutes / ActualRoutes' }) (TIRR shows the route table of the current target $($after.Routes.target))." -Hint (Get-TcErrorHint -Code 'ROUTE_VERIFY_FAILED')
        }
        else {
            $data | Add-Member -NotePropertyName verified -NotePropertyValue $true
            $res = New-TcResult -Success $true -Data $data
        }
        if ($ProjectRoute) { $res = Register-TcCodeChange -Result $res -Change "Add-TcAdsRoute $Name (project route)" }
        return $res
    }
    catch {
        $plain = $null
        $res = New-TcTreeItemErrorResult -ErrorRecord $_ -DefaultCode 'ROUTE_ADD_FAILED' -Data $data -Operation 'Add-TcAdsRoute'
        if ($called -and $ProjectRoute) { $res = Register-TcCodeChange -Result $res -Change "Add-TcAdsRoute $Name [failed]" }
        return $res
    }
}
