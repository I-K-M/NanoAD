# An explicit native authentication/ACL exercise in the dedicated reference OU.
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)][Guid]$LabId,
    [switch]$Exercise,
    [switch]$IsolationConfirmed
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$identity = Get-NanoADIdentity -LabId $LabId
$null = Assert-NanoADGuest -Identity $identity -Phase Controller
$null = Assert-NanoADMarker -Identity $identity
Import-Module ActiveDirectory -ErrorAction Stop
Add-Type -AssemblyName System.DirectoryServices.Protocols -ErrorAction Stop

$ou = "OU=NanoAD-Reference,$($identity.BaseDn)"
$targetDn = "CN=NanoAD-Target,$ou"
$original = 'NanoAD reference original'
$writer = Get-ADUser -Identity "CN=NanoAD-Writer,$ou" -Properties memberOf,primaryGroupID -Server $identity.Fqdn -ErrorAction Stop
$reader = Get-ADUser -Identity "CN=NanoAD-Reader,$ou" -Properties memberOf,primaryGroupID,badPwdCount,LockedOut -Server $identity.Fqdn -ErrorAction Stop
$target = Get-ADUser -Identity $targetDn -Properties Description -Server $identity.Fqdn -ErrorAction Stop
if (-not $writer.Enabled -or -not $reader.Enabled -or $target.Enabled -or
    $writer.SamAccountName -ne 'nanoad-writer' -or $reader.SamAccountName -ne 'nanoad-reader' -or
    $target.SamAccountName -ne 'nanoad-target' -or $target.Description -cne $original -or
    @($writer.memberOf | Where-Object { $_ }).Count -ne 0 -or @($reader.memberOf | Where-Object { $_ }).Count -ne 0 -or
    $writer.PrimaryGroupID -ne 513 -or $reader.PrimaryGroupID -ne 513) {
    throw 'Unexpected fixture state. Refusing to alter anything.'
}
$policy = Get-ADDefaultDomainPasswordPolicy -Server $identity.Fqdn -ErrorAction Stop
if ($reader.LockedOut) { throw 'Reader is locked out; do not attempt further authentication.' }

[ordered]@{ schema_version = 1; lab_id = $identity.LabId; action = 'reference_authentication_acl'; writes_only = 'disabled fixture description'; negative_attempts_maximum = 1 } | ConvertTo-Json
if (-not $Exercise) { return }
if (-not $IsolationConfirmed) { throw 'Explicit provider isolation confirmation required.' }
if (-not $PSCmdlet.ShouldProcess($targetDn,'Perform native authentication and ACL checks; restore fixture property')) { return }
$null = Assert-NanoADGuest -Identity $identity -Phase Controller
$writerUpn = "nanoad-writer@$($identity.DomainName)"
$readerUpn = "nanoad-reader@$($identity.DomainName)"
$writerCred = Get-Credential -UserName $writerUpn -Message 'Synthetic fixture writer only'
$readerCred = Get-Credential -UserName $readerUpn -Message 'Synthetic fixture reader only'
if ($null -eq $writerCred -or $null -eq $readerCred -or $writerCred.UserName -ine $writerUpn -or $readerCred.UserName -ine $readerUpn) {
    throw 'Cancelled or unexpected synthetic username.'
}

function New-BoundConnection {
    param([Management.Automation.PSCredential]$Credential,[DirectoryServices.Protocols.AuthType]$AuthType)
    $identifier = [DirectoryServices.Protocols.LdapDirectoryIdentifier]::new($identity.Fqdn,389,$true,$false)
    $conn = [DirectoryServices.Protocols.LdapConnection]::new($identifier,$Credential.GetNetworkCredential(),$AuthType)
    try {
        $conn.Timeout = [TimeSpan]::FromSeconds(15)
        $conn.SessionOptions.ProtocolVersion = 3
        $conn.SessionOptions.Signing = $true
        $conn.SessionOptions.Sealing = $true
        $conn.SessionOptions.ReferralChasing = [DirectoryServices.Protocols.ReferralChasingOptions]::None
        $conn.Bind()
        return $conn
    } catch { $conn.Dispose(); throw }
}

function Set-FixtureDescription {
    param([DirectoryServices.Protocols.LdapConnection]$Connection,[string]$Value)
    $change = [DirectoryServices.Protocols.DirectoryAttributeModification]::new()
    $change.Name = 'description'
    $change.Operation = [DirectoryServices.Protocols.DirectoryAttributeOperation]::Replace
    [void]$change.Add($Value)
    $request = [DirectoryServices.Protocols.ModifyRequest]::new()
    $request.DistinguishedName = $targetDn
    [void]$request.Modifications.Add($change)
    [void]$Connection.SendRequest($request)
}
$checks = [Collections.Generic.List[object]]::new()
$start = [DateTime]::UtcNow
$wc = $null
$rc = $null
$nc = $null
$attemptedWrite = $false
try {
    $wc = New-BoundConnection $writerCred ([DirectoryServices.Protocols.AuthType]::Kerberos)
    $rc = New-BoundConnection $readerCred ([DirectoryServices.Protocols.AuthType]::Kerberos)
    $checks.Add([pscustomobject]@{ id='synthetic_kerberos_binds'; status='pass' })

    # Reader must be denied. Unexpected success is a failure, and finally restores the fixture.
    $attemptedWrite = $true
    try {
        Set-FixtureDescription $rc 'NanoAD reader test'
        $checks.Add([pscustomobject]@{ id='acl_reader_denied'; status='fail'; reason='unexpected_write_success' })
    } catch [DirectoryServices.Protocols.DirectoryOperationException] {
        $denied = $null -ne $_.Exception.Response -and [int]$_.Exception.Response.ResultCode -eq 50
        $checks.Add([pscustomobject]@{ id='acl_reader_denied'; status=if ($denied) { 'pass' } else { 'fail' } })
    }
    Set-FixtureDescription $wc 'NanoAD writer test'
    $observed = Get-ADUser -Identity $targetDn -Properties Description -Server $identity.Fqdn -ErrorAction Stop
    $checks.Add([pscustomobject]@{ id='acl_writer_allowed'; status=if ($observed.Description -ceq 'NanoAD writer test') { 'pass' } else { 'fail' } })

    # NTLM uses an explicit auth type. An error is an observation, not a claim about policy.
    try {
        $nc = New-BoundConnection $readerCred ([DirectoryServices.Protocols.AuthType]::Ntlm)
        $checks.Add([pscustomobject]@{ id='ntlm_bind'; status='observed'; outcome='allowed' })
    } catch {
        $checks.Add([pscustomobject]@{ id='ntlm_bind'; status='observed'; outcome='rejected_or_unavailable'; error_type=$_.Exception.GetType().Name })
    }

    # One negative test only, never when approaching an effective lockout threshold.
    # Domain default is not sufficient if a fine-grained password policy applies.
    $threshold = $null
    $fresh = Get-ADUser -Identity $reader.DistinguishedName -Properties badPwdCount,LockedOut,'msDS-ResultantPSO' -Server $identity.Fqdn -ErrorAction Stop
    try {
        if ($fresh.'msDS-ResultantPSO') {
            $effective = Get-ADFineGrainedPasswordPolicy -Identity $fresh.'msDS-ResultantPSO' -Server $identity.Fqdn -ErrorAction Stop
            if ($null -ne $effective) { $threshold = $effective.LockoutThreshold }
        } else { $threshold = $policy.LockoutThreshold }
    } catch { $threshold = $null }
    if ($null -ne $threshold -and -not $fresh.LockedOut -and $null -ne $fresh.badPwdCount -and ($threshold -eq 0 -or ($threshold - [int]$fresh.badPwdCount) -gt 2)) {
        $wrong = ConvertTo-SecureString ([Guid]::NewGuid().ToString('N') + '!aA9') -AsPlainText -Force
        $badConn = $null
        try {
            $bad = [Management.Automation.PSCredential]::new($readerUpn,$wrong)
            $badConn = New-BoundConnection $bad ([DirectoryServices.Protocols.AuthType]::Kerberos)
            $checks.Add([pscustomobject]@{ id='wrong_password'; status='fail'; reason='unexpected_bind_success' })
        } catch [DirectoryServices.Protocols.LdapException] {
            $checks.Add([pscustomobject]@{ id='wrong_password'; status=if ($_.Exception.ErrorCode -eq 49) { 'pass' } else { 'inconclusive' }; ldap_error=$_.Exception.ErrorCode })
        } finally {
            if ($null -ne $badConn) { $badConn.Dispose() }
            $wrong.Dispose()
        }
    } else {
        $checks.Add([pscustomobject]@{ id='wrong_password'; status='skipped'; reason='lockout_risk_or_unknown_counter' })
    }
} catch {
    $checks.Add([pscustomobject]@{ id='exercise_error'; status='fail'; error_type=$_.Exception.GetType().Name })
} finally {
    foreach ($conn in @($wc,$rc,$nc)) { if ($null -ne $conn) { $conn.Dispose() } }
    if ($attemptedWrite) {
        try {
            Set-ADUser -Identity $targetDn -Description $original -Server $identity.Fqdn -ErrorAction Stop
            $restored = Get-ADUser -Identity $targetDn -Properties Description -Server $identity.Fqdn -ErrorAction Stop
            $checks.Add([pscustomobject]@{ id='fixture_restored'; status=if ($restored.Description -ceq $original) { 'pass' } else { 'fail' } })
        } catch { $checks.Add([pscustomobject]@{ id='fixture_restored'; status='fail' }) }
    }
}

# Aggregate native audit counts only; not proof of correlation with the exercised principals.
$counts = [ordered]@{}
foreach ($eventId in @(4624,4625,4768,4769,4776)) {
    try {
        $events = @(Get-WinEvent -FilterHashtable @{LogName='Security'; Id=$eventId; StartTime=$start} -MaxEvents 1000 -ErrorAction Stop)
        $counts["$eventId"] = $events.Count
    } catch {
        # No matching events or a failed query are unknown; do not claim zero.
        $counts["$eventId"] = $null
    }
}
$failed = @($checks | Where-Object status -eq 'fail').Count
[ordered]@{
    schema_version=1; lab_id=$identity.LabId; started_utc=$start.ToString('o')
    result=if ($failed -gt 0) { 'failed' } else { 'observations_pending_review' }
    checks=@($checks.ToArray()); security_event_counts_capped_at_1000=$counts
    event_correlation='manual_review_required'; provider_isolation='not_verified_by_guest'
} | ConvertTo-Json -Depth 6
if ($failed -gt 0) { exit 6 }
