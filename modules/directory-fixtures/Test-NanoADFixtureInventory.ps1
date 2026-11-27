# Read-only integrity/persistence check for the optional reference fixture.
[CmdletBinding()]
param([Parameter(Mandatory = $true)][Guid]$LabId,[switch]$IsolationConfirmed)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../provisioning/windows/ad-core/Common.ps1')
$identity = Get-NanoADIdentity -LabId $LabId
$null = Assert-NanoADGuest -Identity $identity -Phase Controller
$null = Assert-NanoADMarker -Identity $identity
if (-not $IsolationConfirmed) { throw 'Verify provider isolation before directory queries.' }
Import-Module ActiveDirectory -ErrorAction Stop
$ouDn = "OU=NanoAD-Reference,$($identity.BaseDn)"
$ou = Get-ADOrganizationalUnit -Identity $ouDn -Server $identity.Fqdn -ErrorAction Stop
$domain = Get-ADDomain -Server $identity.Fqdn -ErrorAction Stop
if ($domain.DistinguishedName -ine $identity.BaseDn -or $domain.DNSRoot -ine $identity.DomainName) { throw 'Unexpected domain.' }
$domainObject = Get-ADObject -Identity $identity.BaseDn -Server $identity.Fqdn -ErrorAction Stop
$writer = Get-ADUser -Identity "CN=NanoAD-Writer,$ouDn" -Properties memberOf,primaryGroupID -Server $identity.Fqdn -ErrorAction Stop
$reader = Get-ADUser -Identity "CN=NanoAD-Reader,$ouDn" -Properties memberOf,primaryGroupID -Server $identity.Fqdn -ErrorAction Stop
$target = Get-ADUser -Identity "CN=NanoAD-Target,$ouDn" -Properties Description,memberOf,primaryGroupID -Server $identity.Fqdn -ErrorAction Stop
$users = @(Get-ADUser -Filter * -SearchBase $ouDn -SearchScope OneLevel -Server $identity.Fqdn -ErrorAction Stop)
$accountsOk = $users.Count -eq 3 -and $writer.Enabled -and $reader.Enabled -and (-not $target.Enabled) -and
    $writer.SamAccountName -ceq 'nanoad-writer' -and $reader.SamAccountName -ceq 'nanoad-reader' -and
    $target.SamAccountName -ceq 'nanoad-target' -and $target.Description -ceq 'NanoAD reference original'
foreach ($account in @($writer,$reader,$target)) {
    if (@($account.memberOf | Where-Object { $_ }).Count -ne 0 -or $account.PrimaryGroupID -ne 513) { $accountsOk = $false }
}
$root = Get-ADRootDSE -Server $identity.Fqdn -ErrorAction Stop
$attribute = @(Get-ADObject -LDAPFilter '(lDAPDisplayName=description)' -SearchBase $root.SchemaNamingContext -SearchScope OneLevel -Properties schemaIDGUID -Server $identity.Fqdn -ErrorAction Stop)
if ($attribute.Count -ne 1) { throw 'Expected unique description schema attribute.' }
$propertyGuid = [Guid]::new([byte[]]$attribute[0].schemaIDGUID)
$acl = Get-Acl -LiteralPath "AD:\$($target.DistinguishedName)" -ErrorAction Stop
$rules = @($acl.GetAccessRules($true,$false,[Security.Principal.SecurityIdentifier]))
$writerRules = @($rules | Where-Object {
    $_.IdentityReference -eq $writer.SID -and $_.ObjectType -eq $propertyGuid -and
    $_.ActiveDirectoryRights -eq [DirectoryServices.ActiveDirectoryRights]::WriteProperty -and
    $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
    $_.InheritanceType -eq [DirectoryServices.ActiveDirectorySecurityInheritance]::None
})
$readerRules = @($rules | Where-Object {
    $_.IdentityReference -eq $reader.SID -and $_.ObjectType -eq $propertyGuid -and
    $_.ActiveDirectoryRights -eq [DirectoryServices.ActiveDirectoryRights]::WriteProperty -and
    $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Deny -and
    $_.InheritanceType -eq [DirectoryServices.ActiveDirectorySecurityInheritance]::None
})
# Report existence of the intended explicit property ACEs, not effective
# access or absence of all unrelated inherited ACEs. The N03 exercise
# separately verifies actual allow/deny semantics and property restoration.
$aclOk = $writerRules.Count -eq 1 -and $readerRules.Count -eq 1
$os = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 10 -ErrorAction Stop
[ordered]@{
    schema_version = 1
    module = 'directory-fixtures'
    lab_id = $identity.LabId
    domain_name = $identity.DomainName
    domain_guid = $domainObject.ObjectGUID.ToString('D')
    ou_guid = $ou.ObjectGUID.ToString('D')
    writer_guid = $writer.ObjectGUID.ToString('D')
    reader_guid = $reader.ObjectGUID.ToString('D')
    target_guid = $target.ObjectGUID.ToString('D')
    boot_unix_ms = ([DateTimeOffset]($os.LastBootUpTime.ToUniversalTime())).ToUnixTimeMilliseconds()
    captured_unix_ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    result = if ($accountsOk -and $aclOk) { 'checks_passed' } else { 'failed' }
    provider_isolation = 'not_verified_by_guest'
    checks = @(
        [ordered]@{ id = 'synthetic_accounts'; status = if ($accountsOk) { 'pass' } else { 'fail' } }
        [ordered]@{ id = 'explicit_property_acl'; status = if ($aclOk) { 'pass' } else { 'fail' } }
    )
} | ConvertTo-Json -Depth 5
if (-not ($accountsOk -and $aclOk)) { exit 6 }
