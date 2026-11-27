# Guest-local, native Windows checks. Dot-sourcing makes no changes.
. (Join-Path $PSScriptRoot '../ad-core/Common.ps1')

function Get-NanoADMemberIdentity {
    param([Parameter(Mandatory = $true)][Guid]$LabId,
          [Parameter(Mandatory = $true)][Guid]$GuestId)
    if ($GuestId -eq [Guid]::Empty -or $GuestId -eq $LabId) { throw 'Distinct non-empty guest UUID required.' }
    $core = Get-NanoADIdentity -LabId $LabId
    $name = 'MS-' + $GuestId.ToString('N').Substring(0,12).ToUpperInvariant()
    [pscustomobject]@{
        LabId = $core.LabId
        GuestId = $GuestId.ToString('D')
        ComputerName = $name
        DomainName = $core.DomainName
        BaseDn = $core.BaseDn
        DcFqdn = $core.Fqdn
        DcIPv4 = $core.IPv4
        IPv4 = '192.0.2.20'
        PrefixLength = 24
        Fqdn = "$name.$($core.DomainName)"
        SamAccountName = "$name" + '$'
    }
}

function Assert-NanoADMemberGuest {
    param([Parameter(Mandatory = $true)]$Identity,
          [Parameter(Mandatory = $true)][ValidateSet('Standalone','Member')][string]$Phase)
    if ($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSEdition -ne 'Desktop') { throw 'Run Windows PowerShell 5.1 in the local Server Core console.' }
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Elevated local guest console required.' }
    $computer = Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 10 -ErrorAction Stop
    $os = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 10 -ErrorAction Stop
    $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    if ($computer.Model -ne 'VirtualBox' -or $cv.InstallationType -ne 'Server Core' -or $os.ProductType -ne 3 -or
        $computer.Name -ine $Identity.ComputerName) {
        throw 'Refusing: expected separate VirtualBox Server Core member candidate, never a DC.'
    }
    if ($Phase -eq 'Standalone') {
        if ($computer.DomainRole -ne 2 -or $computer.PartOfDomain -ne $false) { throw 'Expected a fresh unjoined member candidate.' }
    } elseif ($computer.DomainRole -ne 3 -or $computer.PartOfDomain -ne $true -or $computer.Domain -ine $Identity.DomainName) {
        throw 'Expected a member of this exact NanoAD test domain.'
    }
    $adapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object Status -eq 'Up')
    if ($adapters.Count -ne 1) { throw 'Exactly one active guest NIC required.' }
    $index = $adapters[0].ifIndex
    $addresses = @(Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction Stop)
    if ($addresses.Count -ne 1 -or $addresses[0].IPAddress -ne $Identity.IPv4 -or
        $addresses[0].PrefixLength -ne $Identity.PrefixLength -or $addresses[0].PrefixOrigin -ne 'Manual') {
        throw 'Expected the distinct static member address only.'
    }
    $interface = Get-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction Stop
    if ($interface.Dhcp -ne 'Disabled') { throw 'DHCP must be disabled.' }
    $routes = @(Get-NetRoute -PolicyStore ActiveStore -ErrorAction Stop | Where-Object {
        $_.DestinationPrefix -in @('0.0.0.0/0','::/0') -or $_.NextHop -notin @('0.0.0.0','::')
    })
    if ($routes.Count -ne 0) { throw 'Refusing: default or routed next hop present.' }
    $dns4 = @((Get-DnsClientServerAddress -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses | Where-Object { $_ })
    $dns6 = @((Get-DnsClientServerAddress -InterfaceIndex $index -AddressFamily IPv6 -ErrorAction Stop).ServerAddresses | Where-Object { $_ })
    if ($dns4.Count -ne 1 -or $dns4[0] -ne $Identity.DcIPv4 -or $dns6.Count -ne 0) {
        throw 'DNS must point only to the lab DC at its private test address.'
    }
    # Guest state is not evidence of provider isolation or external peers.
    return $index
}

function Assert-NanoADMemberDns {
    param([Parameter(Mandatory = $true)]$Identity)
    $answers = @(Resolve-DnsName -Name $Identity.DcFqdn -Type A -Server $Identity.DcIPv4 -DnsOnly -NoHostsFile -ErrorAction Stop)
    $a = @($answers | Where-Object Type -eq 'A')
    if ($a.Count -ne 1 -or $a[0].IPAddress -ne $Identity.DcIPv4) { throw 'DC address does not match the expected lab endpoint.' }
    foreach ($name in @("_ldap._tcp.dc._msdcs.$($Identity.DomainName)","_kerberos._tcp.$($Identity.DomainName)")) {
        $srv = @(Resolve-DnsName -Name $name -Type SRV -Server $Identity.DcIPv4 -DnsOnly -NoHostsFile -ErrorAction Stop | Where-Object Type -eq 'SRV')
        $port = if ($name.StartsWith('_ldap')) { 389 } else { 88 }
        if ($srv.Count -lt 1 -or @($srv | Where-Object { $_.NameTarget.TrimEnd('.') -ine $Identity.DcFqdn -or $_.Port -ne $port }).Count -ne 0) {
            throw 'Unexpected or missing native DC SRV endpoint.'
        }
    }
}

function Get-NanoADMemberMarkerPath {
    $parent = Get-Item -LiteralPath $env:ProgramData -Force -ErrorAction Stop
    if (-not $parent.PSIsContainer -or ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Unsafe ProgramData directory.'
    }
    $root = Join-Path $parent.FullName 'NanoAD'
    if (Test-Path -LiteralPath $root) {
        $item = Get-Item -LiteralPath $root -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Unsafe marker directory.' }
    }
    $path = Join-Path $root 'member-join.json'
    if (Test-Path -LiteralPath $path) {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -gt 4096) { throw 'Unsafe member marker.' }
    }
    return $path
}

function New-NanoADMemberMarker {
    param([Parameter(Mandatory = $true)]$Identity)
    $path = Get-NanoADMemberMarkerPath
    $root = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -ErrorAction Stop | Out-Null }
    $path = Get-NanoADMemberMarkerPath
    $marker = [ordered]@{
        schema_version = 1
        lab_id = $Identity.LabId
        guest_id = $Identity.GuestId
        computer_name = $Identity.ComputerName
        domain_name = $Identity.DomainName
        phase = 'join_requested'
        requested_unix_ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    } | ConvertTo-Json -Compress
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($marker)
    # CreateNew, never replace. Flush before native join; on uncertainty keep
    # the marker and refuse another attempt. A trusted local ACL is required.
    $stream = [IO.FileStream]::new($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try {
        $stream.Write($bytes,0,$bytes.Length)
        $stream.Flush($true)
    } finally { $stream.Dispose() }
}

function Assert-NanoADMemberMarker {
    param([Parameter(Mandatory = $true)]$Identity)
    $path = Get-NanoADMemberMarkerPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Missing member join intent; no adoption of existing computers.' }
    $marker = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($marker.schema_version -ne 1 -or $marker.phase -ne 'join_requested' -or
        $marker.lab_id -cne $Identity.LabId -or $marker.guest_id -cne $Identity.GuestId -or
        $marker.computer_name -cne $Identity.ComputerName -or $marker.domain_name -cne $Identity.DomainName) {
        throw 'Member marker does not match the requested lab/guest identity.'
    }
}

function Get-NanoADMemberDirectory {
    param([Parameter(Mandatory = $true)]$Identity,
          [Management.Automation.PSCredential]$Credential,
          [Parameter(Mandatory = $true)][ValidateSet('Absent','Present')][string]$Expected)
    Add-Type -AssemblyName System.DirectoryServices.Protocols -ErrorAction Stop
    $identifier = [DirectoryServices.Protocols.LdapDirectoryIdentifier]::new($Identity.DcFqdn,389,$true,$false)
    if ($null -eq $Credential) {
        $connection = [DirectoryServices.Protocols.LdapConnection]::new($identifier)
    } else {
        $connection = [DirectoryServices.Protocols.LdapConnection]::new($identifier,$Credential.GetNetworkCredential(),[DirectoryServices.Protocols.AuthType]::Kerberos)
    }
    try {
        $connection.AuthType = [DirectoryServices.Protocols.AuthType]::Kerberos
        $connection.Timeout = [TimeSpan]::FromSeconds(15)
        $connection.SessionOptions.ProtocolVersion = 3
        $connection.SessionOptions.Signing = $true
        $connection.SessionOptions.Sealing = $true
        $connection.SessionOptions.ReferralChasing = [DirectoryServices.Protocols.ReferralChasingOptions]::None
        $connection.Bind()
        $rootReq = [DirectoryServices.Protocols.SearchRequest]::new('', '(objectClass=*)', [DirectoryServices.Protocols.SearchScope]::Base, [string[]]@('defaultNamingContext','dnsHostName'))
        $root = [DirectoryServices.Protocols.SearchResponse]$connection.SendRequest($rootReq)
        if ($root.Entries.Count -ne 1 -or $root.Entries[0].Attributes['defaultNamingContext'][0] -ine $Identity.BaseDn -or
            $root.Entries[0].Attributes['dnsHostName'][0] -ine $Identity.DcFqdn) { throw 'Unexpected LDAP directory identity.' }
        $domainReq = [DirectoryServices.Protocols.SearchRequest]::new($Identity.BaseDn, '(objectClass=domainDNS)', [DirectoryServices.Protocols.SearchScope]::Base, [string[]]@('objectGUID'))
        $domain = [DirectoryServices.Protocols.SearchResponse]$connection.SendRequest($domainReq)
        if ($domain.Entries.Count -ne 1) { throw 'Domain object not uniquely resolved.' }
        $domainGuid = [Guid]::new([byte[]]$domain.Entries[0].Attributes['objectGUID'].GetValues([byte[]])[0])
        # SAM is derived only from a canonical UUID and fixed prefix.
        $filter = "(&(objectCategory=computer)(sAMAccountName=$($Identity.SamAccountName)))"
        $computerReq = [DirectoryServices.Protocols.SearchRequest]::new($Identity.BaseDn,$filter,[DirectoryServices.Protocols.SearchScope]::Subtree,[string[]]@('objectGUID','dNSHostName'))
        $computerReq.SizeLimit = 2
        $computer = [DirectoryServices.Protocols.SearchResponse]$connection.SendRequest($computerReq)
        $computerGuid = $null
        if ($Expected -eq 'Absent') {
            if ($computer.Entries.Count -ne 0) { throw 'Existing computer account; refusing implicit reuse.' }
        } else {
            if ($computer.Entries.Count -ne 1 -or $computer.Entries[0].Attributes['dNSHostName'][0] -ine $Identity.Fqdn) {
                throw 'Expected unique joined computer and its DNS identity.'
            }
            $computerGuid = [Guid]::new([byte[]]$computer.Entries[0].Attributes['objectGUID'].GetValues([byte[]])[0])
            if ($computerGuid -eq [Guid]::Empty) { throw 'Empty computer object identity.' }
        }
        if ($domainGuid -eq [Guid]::Empty) { throw 'Empty domain object identity.' }
        return [pscustomobject]@{ DomainGuid = $domainGuid.ToString('D'); ComputerGuid = if ($null -eq $computerGuid) { $null } else { $computerGuid.ToString('D') } }
    } finally { $connection.Dispose() }
}

function Get-NanoADBootUnixMs {
    $os = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 10 -ErrorAction Stop
    return ([DateTimeOffset]($os.LastBootUpTime.ToUniversalTime())).ToUnixTimeMilliseconds()
}
