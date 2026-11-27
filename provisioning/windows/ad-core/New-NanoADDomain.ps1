# Run from the local console of a newly cloned, disposable Server Core guest.
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)][Guid]$LabId,
    [switch]$Provision,
    [switch]$IsolationConfirmed
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$identity = Get-NanoADIdentity -LabId $LabId
$null = Assert-NanoADGuest -Identity $identity -Phase Standalone
$markerPath = Get-NanoADMarkerPath
if (Test-Path -LiteralPath $markerPath) {
    $existing = Assert-NanoADMarker -Identity $identity
    if ($existing.phase -ne 'preparing') { throw 'Prior promotion requested. Inspect the guest; do not repeat promotion automatically.' }
}

$role = Get-WindowsFeature -Name AD-Domain-Services -ErrorAction Stop
if ($null -eq $role) { throw 'AD DS role unavailable.' }
$plan = [ordered]@{
    schema_version = 1
    lab_id = $identity.LabId
    computer_name = $identity.ComputerName
    domain_name = $identity.DomainName
    domain_netbios_name = $identity.NetbiosName
    ipv4 = $identity.IPv4
    role_installed = [bool]$role.Installed
    provider_isolation = 'operator_verification_required'
    automatically_reboots = $true
    optional_roles = @()
}
$plan | ConvertTo-Json -Depth 4
if (-not $Provision) { return }
if (-not $IsolationConfirmed) { throw 'Explicit provider-side isolation confirmation is required.' }
if (-not $PSCmdlet.ShouldProcess($identity.ComputerName, "Install native AD DS and promote new forest $($identity.DomainName); guest will reboot")) { return }

# Recheck immediately before mutation. The marker is evidence, not an ownership credential.
$null = Assert-NanoADGuest -Identity $identity -Phase Standalone
$root = Split-Path -Parent $markerPath
if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -ErrorAction Stop | Out-Null }
function Write-LabMarker {
    param([string]$Phase)
    [ordered]@{
        schema_version = 1
        lab_id = $identity.LabId
        computer_name = $identity.ComputerName
        domain_name = $identity.DomainName
        phase = $Phase
        updated_utc = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $markerPath -Encoding UTF8 -ErrorAction Stop
}
Write-LabMarker 'preparing'
if (-not $role.Installed) {
    $installation = Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools -ErrorAction Stop
    if (-not $installation.Success) { throw 'AD DS role installation failed. Inspect native servicing logs.' }
    if ($installation.RestartNeeded -ne 'No') { throw 'Role installation requires a reboot. Reboot the disposable guest and rerun the plan.' }
}
Import-Module ADDSDeployment -ErrorAction Stop
# Native prerequisite checks and interactive DSRM password prompts. Never persist secrets.
Write-Host 'Run native forest prerequisite checks. Use a unique lab-only DSRM password.'
Test-ADDSForestInstallation -DomainName $identity.DomainName -DomainNetbiosName $identity.NetbiosName -InstallDns -ErrorAction Stop
$null = Assert-NanoADGuest -Identity $identity -Phase Standalone
Write-LabMarker 'promotion_requested'
# No SkipPreChecks, no unattended credentials and no suppression of the supported reboot.
Install-ADDSForest -DomainName $identity.DomainName -DomainNetbiosName $identity.NetbiosName -InstallDns -ErrorAction Stop
