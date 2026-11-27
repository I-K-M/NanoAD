# Shared guest-only guard and deterministic identity. No changes when dot-sourced.
function Get-NanoADIdentity {
    param([Parameter(Mandatory = $true)][Guid]$LabId)
    if ($LabId -eq [Guid]::Empty) { throw 'An empty lab UUID is not allowed.' }
    $hex = $LabId.ToString('N')
    $short = $hex.Substring(0,12).ToUpperInvariant()
    [pscustomobject]@{
        LabId = $LabId.ToString('D')
        ComputerName = "DC-$short"
        NetbiosName = "NAD$short"
        DomainName = "lab-$hex.nanoad.test"
        BaseDn = "DC=lab-$hex,DC=nanoad,DC=test"
        Fqdn = "DC-$short.lab-$hex.nanoad.test"
        IPv4 = '192.0.2.10'
        PrefixLength = 24
    }
}

function Assert-NanoADGuest {
    param(
        [Parameter(Mandatory = $true)]$Identity,
        [Parameter(Mandatory = $true)][ValidateSet('Standalone','Controller')][string]$Phase
    )
    if ($env:OS -ne 'Windows_NT') { throw 'Windows guest required.' }
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Elevated local guest console required.' }
    $computer = Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 10 -ErrorAction Stop
    $os = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 10 -ErrorAction Stop
    $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    if ($computer.Model -ne 'VirtualBox' -or $cv.InstallationType -ne 'Server Core') { throw 'Refusing: reference VirtualBox Server Core guest required.' }
    if ($computer.Name -ine $Identity.ComputerName) { throw 'Refusing: computer name does not match lab identity.' }
    if ($Phase -eq 'Standalone') {
        if ($os.ProductType -ne 3 -or $computer.DomainRole -ne 2 -or $computer.PartOfDomain -ne $false) {
            throw 'Refusing: standalone, unjoined Windows Server required.'
        }
    } else {
        if ($os.ProductType -ne 2 -or $computer.DomainRole -notin @(4,5) -or $computer.Domain -ine $Identity.DomainName) {
            throw 'Refusing: this is not the expected synthetic domain controller.'
        }
    }

    # Guest checks are necessary but never prove provider-side isolation.
    $adapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object Status -eq 'Up')
    if ($adapters.Count -ne 1) { throw 'Exactly one active guest network adapter is required.' }
    $index = $adapters[0].ifIndex
    $addresses = @(Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction Stop)
    if ($addresses.Count -ne 1 -or $addresses[0].IPAddress -ne $Identity.IPv4 -or
        $addresses[0].PrefixLength -ne $Identity.PrefixLength -or $addresses[0].PrefixOrigin -ne 'Manual') {
        throw 'Expected one static lab IPv4 address and no additional IPv4 address.'
    }
    $interface = Get-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction Stop
    if ($interface.Dhcp -ne 'Disabled') { throw 'DHCP must be disabled.' }
    $routes = @(Get-NetRoute -PolicyStore ActiveStore -ErrorAction Stop | Where-Object { $_.DestinationPrefix -in @('0.0.0.0/0','::/0') })
    if ($routes.Count -ne 0) { throw 'Refusing: guest has a default route.' }
    $dns4 = @((Get-DnsClientServerAddress -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses | Where-Object { $_ })
    $dns6 = @((Get-DnsClientServerAddress -InterfaceIndex $index -AddressFamily IPv6 -ErrorAction Stop).ServerAddresses | Where-Object { $_ })
    $allowed4 = if ($Phase -eq 'Controller') { @($Identity.IPv4,'127.0.0.1') } else { @($Identity.IPv4) }
    if ($dns4.Count -eq 0 -or @($dns4 | Where-Object { $_ -notin $allowed4 }).Count -gt 0 -or
        @($dns6 | Where-Object { $_ -ne '::1' }).Count -gt 0) {
        throw 'DNS must point only to the local lab controller.'
    }
    return $index
}

function Get-NanoADMarkerPath {
    $root = Join-Path $env:ProgramData 'NanoAD'
    if (Test-Path -LiteralPath $root) {
        $item = Get-Item -LiteralPath $root -Force
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Unsafe lab marker directory.'
        }
    }
    $path = Join-Path $root 'reference.json'
    if (Test-Path -LiteralPath $path) {
        $item = Get-Item -LiteralPath $path -Force
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -gt 4096) {
            throw 'Unsafe lab marker file.'
        }
    }
    return $path
}

function Assert-NanoADMarker {
    param([Parameter(Mandatory = $true)]$Identity)
    $path = Get-NanoADMarkerPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Missing reference lab marker.' }
    $marker = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($marker.schema_version -ne 1 -or $marker.lab_id -ne $Identity.LabId -or
        $marker.computer_name -ine $Identity.ComputerName -or $marker.domain_name -ine $Identity.DomainName) {
        throw 'Lab marker does not match expected identity.'
    }
    return $marker
}
