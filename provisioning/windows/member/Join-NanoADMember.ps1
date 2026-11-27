# Plan by default. Run only in the local disposable member guest console.
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)][Guid]$LabId,
    [Parameter(Mandatory = $true)][Guid]$GuestId,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')][string]$JoinUser,
    [switch]$Join,
    [switch]$IsolationConfirmed
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$identity = Get-NanoADMemberIdentity -LabId $LabId -GuestId $GuestId
$null = Assert-NanoADMemberGuest -Identity $identity -Phase Standalone
$marker = Get-NanoADMemberMarkerPath
if (Test-Path -LiteralPath $marker) { throw 'Prior join intent exists. Inspect native state; no retry, rejoin or automatic reset.' }
if (-not $IsolationConfirmed) { throw 'Verify provider isolation, disk ownership and the exclusive disposable lab before any network query.' }
Assert-NanoADMemberDns -Identity $identity
[ordered]@{
    schema_version = 1
    action = 'join_member'
    lab_id = $identity.LabId
    guest_id = $identity.GuestId
    computer_name = $identity.ComputerName
    domain_name = $identity.DomainName
    dc = $identity.DcFqdn
    ipv4 = $identity.IPv4
    result = 'plan_only'
    reboot_required = $true
    provider_isolation = 'operator_verification_required'
} | ConvertTo-Json
if (-not $Join) { return }
if ([string]::IsNullOrWhiteSpace($JoinUser)) { throw 'Supply a lab-only delegated join username, not a password.' }
if (-not $PSCmdlet.ShouldProcess($identity.ComputerName,"Join only $($identity.DomainName) using $($identity.DcFqdn); preserve state and reboot manually")) { return }
$upn = "$JoinUser@$($identity.DomainName)"
$credential = Get-Credential -UserName $upn -Message 'Use only the synthetic test-domain join account'
if ($null -eq $credential -or $credential.UserName -ine $upn -or $credential.Password.Length -eq 0) { throw 'Cancelled or unexpected credential.' }
try {
    $null = Assert-NanoADMemberGuest -Identity $identity -Phase Standalone
    Assert-NanoADMemberDns -Identity $identity
    # Explicit signed/sealed Kerberos before join. No NTLM/simple-bind
    # fallback. On an unsupported standalone-client setup, refuse join.
    $null = Get-NanoADMemberDirectory -Identity $identity -Credential $credential -Expected Absent
    New-NanoADMemberMarker -Identity $identity
    # Native hardening remains enabled. No remote target, unsecure join,
    # account-reuse override, domain migration or forced reboot.
    $joined = Add-Computer -DomainName $identity.DomainName -Server $identity.DcFqdn -Credential $credential -PassThru -ErrorAction Stop
    if ($null -eq $joined -or -not $joined.HasSucceeded) { throw 'Native join outcome failed or ambiguous. Keep the marker and inspect.' }
    Write-Host 'Join requested successfully. Reboot this disposable guest manually, then run the member health test. No automatic retry.'
} catch {
    Write-Warning 'Do not rerun a join after its intent marker exists. Preserve the guest and inspect native join state.'
    throw
} finally {
    $credential.Password.Dispose()
    $credential = $null
}
