# Read-only native member checks. Run elevated as a lab domain user.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][Guid]$LabId,
    [Parameter(Mandatory = $true)][Guid]$GuestId,
    [switch]$IsolationConfirmed
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$identity = Get-NanoADMemberIdentity -LabId $LabId -GuestId $GuestId
$null = Assert-NanoADMemberGuest -Identity $identity -Phase Member
Assert-NanoADMemberMarker -Identity $identity
if (-not $IsolationConfirmed) { throw 'Verify the exact isolated provider network before guest queries.' }
$results = [Collections.Generic.List[object]]::new()
$directory = $null
function Invoke-NanoADMemberCheck {
    param([string]$Id,[scriptblock]$Check)
    try {
        $value = & $Check
        if ($value -isnot [bool] -or -not $value) { throw 'Predicate failed.' }
        $results.Add([pscustomobject]@{ id = $Id; status = 'pass' })
    } catch {
        $results.Add([pscustomobject]@{ id = $Id; status = 'fail'; error_type = $_.Exception.GetType().Name })
    }
}
Invoke-NanoADMemberCheck 'dc_dns' {
    Assert-NanoADMemberDns -Identity $identity
    return $true
}
# Do not query a different target when DNS validation fails.
if ($results[0].status -eq 'pass') {
    Invoke-NanoADMemberCheck 'secure_channel' {
        return (Test-ComputerSecureChannel -Server $identity.DcFqdn -ErrorAction Stop)
    }
    try {
        $directory = Get-NanoADMemberDirectory -Identity $identity -Expected Present
        $results.Add([pscustomobject]@{ id = 'kerberos_ldap_identity'; status = 'pass' })
    } catch {
        $results.Add([pscustomobject]@{ id = 'kerberos_ldap_identity'; status = 'fail'; error_type = $_.Exception.GetType().Name })
    }
}
Invoke-NanoADMemberCheck 'native_services' {
    $services = @(Get-Service -Name Netlogon,LanmanWorkstation -ErrorAction Stop)
    return ($services.Count -eq 2 -and @($services | Where-Object Status -ne 'Running').Count -eq 0)
}
$failed = @($results | Where-Object status -eq 'fail').Count -ne 0 -or $results.Count -ne 4
[ordered]@{
    schema_version = 1
    module = 'member-server'
    lab_id = $identity.LabId
    guest_id = $identity.GuestId
    computer_name = $identity.ComputerName
    domain_name = $identity.DomainName
    domain_guid = if ($null -ne $directory) { $directory.DomainGuid } else { $null }
    computer_guid = if ($null -ne $directory) { $directory.ComputerGuid } else { $null }
    boot_unix_ms = Get-NanoADBootUnixMs
    captured_unix_ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    result = if ($failed) { 'failed' } else { 'checks_passed' }
    provider_isolation = 'not_verified_by_guest'
    checks = @($results.ToArray())
} | ConvertTo-Json -Depth 6
if ($failed) { exit 6 }
