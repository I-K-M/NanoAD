# Explicit temporary native ACL fixture. Never used on normal core startup.
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)][Guid]$LabId,
    [switch]$Create,
    [switch]$IsolationConfirmed
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$identity = Get-NanoADIdentity -LabId $LabId
$null = Assert-NanoADGuest -Identity $identity -Phase Controller
$null = Assert-NanoADMarker -Identity $identity
Import-Module ActiveDirectory -ErrorAction Stop
Add-Type -AssemblyName System.DirectoryServices -ErrorAction Stop
$ou = "OU=NanoAD-Reference,$($identity.BaseDn)"
$existing = @(Get-ADOrganizationalUnit -Filter "Name -eq 'NanoAD-Reference'" -SearchBase $identity.BaseDn -SearchScope OneLevel -Server $identity.Fqdn -ErrorAction Stop)
if ($existing.Count -ne 0) { throw 'Reference OU already exists. Do not recreate or overwrite; inspect or rebuild.' }
[ordered]@{ schema_version = 1; lab_id = $identity.LabId; action = 'create_reference_fixture'; accounts = @('nanoad-writer','nanoad-reader','nanoad-target-disabled'); target_property = 'description' } | ConvertTo-Json
if (-not $Create) { return }
if (-not $IsolationConfirmed) { throw 'Explicit provider isolation confirmation required.' }
if (-not $PSCmdlet.ShouldProcess($ou,'Create three synthetic accounts and test-property ACL')) { return }

$writerPassword = $null
$readerPassword = $null
try {
    $writerPassword = Read-Host 'Unique lab-only password for nanoad-writer' -AsSecureString
    $readerPassword = Read-Host 'Different unique lab-only password for nanoad-reader' -AsSecureString
    if ($writerPassword.Length -eq 0 -or $readerPassword.Length -eq 0) { throw 'Blank password refused.' }
    $null = Assert-NanoADGuest -Identity $identity -Phase Controller
    New-ADOrganizationalUnit -Name NanoAD-Reference -Path $identity.BaseDn -ProtectedFromAccidentalDeletion $true -Server $identity.Fqdn -ErrorAction Stop
    New-ADUser -Name NanoAD-Writer -SamAccountName nanoad-writer -UserPrincipalName "nanoad-writer@$($identity.DomainName)" -Path $ou -AccountPassword $writerPassword -Enabled $true -Server $identity.Fqdn -ErrorAction Stop
    New-ADUser -Name NanoAD-Reader -SamAccountName nanoad-reader -UserPrincipalName "nanoad-reader@$($identity.DomainName)" -Path $ou -AccountPassword $readerPassword -Enabled $true -Server $identity.Fqdn -ErrorAction Stop
    New-ADUser -Name NanoAD-Target -SamAccountName nanoad-target -Path $ou -Enabled $false -Description 'NanoAD reference original' -Server $identity.Fqdn -ErrorAction Stop

    $root = Get-ADRootDSE -Server $identity.Fqdn -ErrorAction Stop
    $attribute = @(Get-ADObject -LDAPFilter '(lDAPDisplayName=description)' -SearchBase $root.SchemaNamingContext -SearchScope OneLevel -Properties schemaIDGUID -Server $identity.Fqdn -ErrorAction Stop)
    if ($attribute.Count -ne 1) { throw 'Description attribute schema not uniquely resolved.' }
    $propertyGuid = [Guid]::new([byte[]]$attribute[0].schemaIDGUID)
    $writer = Get-ADUser -Identity "CN=NanoAD-Writer,$ou" -Server $identity.Fqdn -ErrorAction Stop
    $reader = Get-ADUser -Identity "CN=NanoAD-Reader,$ou" -Server $identity.Fqdn -ErrorAction Stop
    $target = Get-ADUser -Identity "CN=NanoAD-Target,$ou" -Server $identity.Fqdn -ErrorAction Stop
    if ($target.Enabled -ne $false) { throw 'Fixture target must remain disabled.' }

    # On this local DC, the AD provider points at the verified synthetic domain.
    # Access is scoped to one property on one disabled object; no inherited delegation.
    $path = "AD:\$($target.DistinguishedName)"
    $acl = Get-Acl -LiteralPath $path -ErrorAction Stop
    $allow = [DirectoryServices.ActiveDirectoryAccessRule]::new(
        $writer.SID, [DirectoryServices.ActiveDirectoryRights]::WriteProperty,
        [Security.AccessControl.AccessControlType]::Allow, $propertyGuid)
    $deny = [DirectoryServices.ActiveDirectoryAccessRule]::new(
        $reader.SID, [DirectoryServices.ActiveDirectoryRights]::WriteProperty,
        [Security.AccessControl.AccessControlType]::Deny, $propertyGuid)
    $acl.AddAccessRule($allow)
    $acl.AddAccessRule($deny)
    Set-Acl -LiteralPath $path -AclObject $acl -ErrorAction Stop
    Write-Host 'Reference fixture created. Verify with the separate exercise.'
} catch {
    Write-Warning 'Fixture may be partial. No automatic cleanup; inspect or rebuild the disposable reference.'
    throw
} finally {
    if ($null -ne $writerPassword) { $writerPassword.Dispose() }
    if ($null -ne $readerPassword) { $readerPassword.Dispose() }
}
