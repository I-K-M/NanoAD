# Read-only core fidelity checks, from the local console of the expected DC.
[CmdletBinding()]
param([Parameter(Mandatory = $true)][Guid]$LabId)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$identity = Get-NanoADIdentity -LabId $LabId
$null = Assert-NanoADGuest -Identity $identity -Phase Controller
$marker = Assert-NanoADMarker -Identity $identity
if ($marker.phase -ne 'promotion_requested') { throw 'Expected a completed promotion attempt.' }
Import-Module ActiveDirectory -ErrorAction Stop
Add-Type -AssemblyName System.DirectoryServices.Protocols -ErrorAction Stop
$results = [Collections.Generic.List[object]]::new()

function Invoke-Check {
    param([string]$Id,[scriptblock]$Check)
    try {
        $value = & $Check
        if ($value -isnot [bool] -or -not $value) { throw 'Check predicate failed.' }
        $results.Add([pscustomobject]@{ id = $Id; status = 'pass' })
    } catch {
        # Avoid copying directory data, paths or credentials into exported evidence.
        $results.Add([pscustomobject]@{ id = $Id; status = 'fail'; error_type = $_.Exception.GetType().Name })
    }
}

Invoke-Check 'native_services' {
    $services = @(Get-Service -Name NTDS,DNS,KDC,Netlogon,DFSR,ADWS -ErrorAction Stop)
    return ($services.Count -eq 6 -and @($services | Where-Object Status -ne 'Running').Count -eq 0)
}
Invoke-Check 'domain_and_forest' {
    $domain = Get-ADDomain -Server $identity.Fqdn -ErrorAction Stop
    $forest = Get-ADForest -Server $identity.Fqdn -ErrorAction Stop
    $controllers = @(Get-ADDomainController -Filter * -Server $identity.Fqdn -ErrorAction Stop)
    return ($domain.DNSRoot -ieq $identity.DomainName -and $domain.DistinguishedName -ieq $identity.BaseDn -and
        $forest.RootDomain -ieq $identity.DomainName -and @($forest.Domains).Count -eq 1 -and
        $controllers.Count -eq 1 -and $controllers[0].HostName -ieq $identity.Fqdn)
}
foreach ($record in @("_ldap._tcp.dc._msdcs.$($identity.DomainName)","_kerberos._tcp.$($identity.DomainName)")) {
    $checkId = if ($record.StartsWith('_ldap')) { 'dns_ldap_srv' } else { 'dns_kerberos_srv' }
    Invoke-Check $checkId {
        $answers = @(Resolve-DnsName -Name $record -Type SRV -Server $identity.IPv4 -DnsOnly -NoHostsFile -ErrorAction Stop |
            Where-Object Type -eq 'SRV')
        return ($answers.Count -ge 1 -and @($answers | Where-Object { $_.NameTarget.TrimEnd('.') -ieq $identity.Fqdn }).Count -ge 1)
    }
}
Invoke-Check 'kerberos_ldap_rootdse' {
    $identifier = [DirectoryServices.Protocols.LdapDirectoryIdentifier]::new($identity.Fqdn,389,$true,$false)
    $connection = [DirectoryServices.Protocols.LdapConnection]::new($identifier)
    try {
        $connection.AuthType = [DirectoryServices.Protocols.AuthType]::Kerberos
        $connection.Timeout = [TimeSpan]::FromSeconds(15)
        $connection.SessionOptions.ProtocolVersion = 3
        $connection.SessionOptions.Signing = $true
        $connection.SessionOptions.Sealing = $true
        $connection.SessionOptions.ReferralChasing = [DirectoryServices.Protocols.ReferralChasingOptions]::None
        $connection.Bind()
        $request = [DirectoryServices.Protocols.SearchRequest]::new('', '(objectClass=*)', [DirectoryServices.Protocols.SearchScope]::Base, [string[]]@('defaultNamingContext','dnsHostName'))
        $reply = [DirectoryServices.Protocols.SearchResponse]$connection.SendRequest($request)
        return ($reply.Entries.Count -eq 1 -and
            $reply.Entries[0].Attributes['defaultNamingContext'][0] -ieq $identity.BaseDn -and
            $reply.Entries[0].Attributes['dnsHostName'][0] -ieq $identity.Fqdn)
    } finally { $connection.Dispose() }
}
Invoke-Check 'sysvol_and_netlogon' {
    $shares = @(Get-SmbShare -Name SYSVOL,NETLOGON -ErrorAction Stop)
    return ($shares.Count -eq 2 -and (Test-Path -LiteralPath "\\$($identity.Fqdn)\SYSVOL\$($identity.DomainName)\Policies"))
}
Invoke-Check 'gpo_directory_and_files' {
    $policies = @(Get-ADObject -LDAPFilter '(objectClass=groupPolicyContainer)' -SearchBase "CN=Policies,CN=System,$($identity.BaseDn)" -SearchScope OneLevel -Properties gPCFileSysPath -Server $identity.Fqdn -ErrorAction Stop)
    if ($policies.Count -lt 2) { return $false }
    $prefix = "\\$($identity.DomainName)\SYSVOL\$($identity.DomainName)\Policies\"
    foreach ($policy in $policies) {
        # Resolve only a path below the expected domain SYSVOL; never follow arbitrary policy paths.
        if ($policy.Name -notmatch '^\{[0-9A-Fa-f-]{36}\}$' -or
            $policy.gPCFileSysPath -ine ($prefix + $policy.Name)) { return $false }
        $path = "\\$($identity.Fqdn)\SYSVOL\$($identity.DomainName)\Policies\$($policy.Name)\GPT.INI"
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    }
    return $true
}
Invoke-Check 'native_password_policy' {
    $policy = Get-ADDefaultDomainPasswordPolicy -Server $identity.Fqdn -ErrorAction Stop
    return ($null -ne $policy -and $policy.MinPasswordLength -ge 0 -and $policy.LockoutThreshold -ge 0)
}
Invoke-Check 'security_log_access' {
    $log = Get-WinEvent -ListLog Security -ErrorAction Stop
    return ($log.IsEnabled -and $log.RecordCount -gt 0)
}
$os = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 10
$failures = @($results | Where-Object status -eq 'fail').Count
[ordered]@{
    schema_version = 1
    lab_id = $identity.LabId
    captured_at_utc = [DateTime]::UtcNow.ToString('o')
    last_boot_utc = $os.LastBootUpTime.ToUniversalTime().ToString('o')
    result = if ($failures -eq 0) { 'core_checks_passed' } else { 'failed' }
    provider_isolation = 'not_verified_by_guest'
    coverage = 'local_dc_only'
    checks = @($results.ToArray())
    pending_checks = @('negative_authentication','ntlm_policy_outcome','acl_allow_deny','security_event_correlation','restart_comparison')
} | ConvertTo-Json -Depth 6
if ($failures -gt 0) { exit 6 }
