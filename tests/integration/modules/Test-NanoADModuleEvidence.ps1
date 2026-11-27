# CI pure checks; no guest, credentials, AD module or provider calls.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../../provisioning/windows/member/Common.ps1')
. (Join-Path $PSScriptRoot 'Compare-NanoADModuleRestart.ps1')
$lab = [Guid]'01234567-89ab-cdef-0123-456789abcdef'
$guest = [Guid]'11234567-89ab-cdef-0123-456789abcdef'
$id = Get-NanoADMemberIdentity -LabId $lab -GuestId $guest
if ($id.ComputerName -cne 'MS-1123456789AB' -or $id.SamAccountName -cne 'MS-1123456789AB$' -or
    $id.DcFqdn -cne 'DC-0123456789AB.lab-0123456789abcdef0123456789abcdef.nanoad.test' -or
    $id.IPv4 -eq $id.DcIPv4 -or $id.ComputerName.Length -gt 15) { throw 'Member identity mismatch.' }
function Assert-Rejected {
    param([scriptblock]$Action)
    $rejected = $false
    try { $null = & $Action } catch { $rejected = $true }
    if (-not $rejected) { throw 'Unsafe evidence accepted.' }
}
Assert-Rejected { Get-NanoADMemberIdentity -LabId $lab -GuestId $lab }
Assert-Rejected { Get-NanoADMemberIdentity -LabId $lab -GuestId ([Guid]::Empty) }
Assert-Rejected { Get-NanoADMemberIdentity -LabId ([Guid]::Empty) -GuestId $guest }
function New-Report {
    param([string]$Module,[long]$Boot,[long]$Captured)
    $report = [ordered]@{
        schema_version = 1
        module = $Module
        lab_id = $id.LabId
        domain_name = $id.DomainName
        domain_guid = '21234567-89ab-cdef-0123-456789abcdef'
        boot_unix_ms = $Boot
        captured_unix_ms = $Captured
        result = 'checks_passed'
        provider_isolation = 'not_verified_by_guest'
    }
    if ($Module -ceq 'member-server') {
        $report.guest_id = $id.GuestId
        $report.computer_name = $id.ComputerName
        $report.computer_guid = '31234567-89ab-cdef-0123-456789abcdef'
        $names = @('dc_dns','secure_channel','kerberos_ldap_identity','native_services')
    } else {
        $report.ou_guid = '41234567-89ab-cdef-0123-456789abcdef'
        $report.writer_guid = '51234567-89ab-cdef-0123-456789abcdef'
        $report.reader_guid = '61234567-89ab-cdef-0123-456789abcdef'
        $report.target_guid = '71234567-89ab-cdef-0123-456789abcdef'
        $names = @('synthetic_accounts','explicit_property_acl')
    }
    $report.checks = @($names | ForEach-Object { [pscustomobject]@{ id = $_; status = 'pass' } })
    return [pscustomobject]$report
}
foreach ($module in @('member-server','directory-fixtures')) {
    $before = New-Report $module 1000 2000
    $after = New-Report $module 3000 4000
    $result = Compare-NanoADModuleEvidence -Before $before -After $after
    if ($result.result -ne 'restart_observations_match' -or $result.qualification -ne 'not_established') { throw 'Unexpected comparison result.' }
    $after.boot_unix_ms = 1000
    Assert-Rejected { Compare-NanoADModuleEvidence -Before $before -After $after }
    $after = New-Report $module 3000 4000
    $after.checks[0].status = 'fail'
    Assert-Rejected { Compare-NanoADModuleEvidence -Before $before -After $after }
    $after = New-Report $module 3000 4000
    $after.checks[0].id = $after.checks[1].id
    Assert-Rejected { Compare-NanoADModuleEvidence -Before $before -After $after }
    $after = New-Report $module 3000 4000
    $after.domain_guid = '81234567-89ab-cdef-0123-456789abcdef'
    Assert-Rejected { Compare-NanoADModuleEvidence -Before $before -After $after }
    $after = New-Report $module 3000 4000
    $after.domain_name = 'example.com'
    Assert-Rejected { Compare-NanoADModuleEvidence -Before $before -After $after }
    $after = New-Report $module 3000 4000
    $after.boot_unix_ms = '3000'
    Assert-Rejected { Compare-NanoADModuleEvidence -Before $before -After $after }
    $after = New-Report $module 3000 4000
    if ($module -ceq 'member-server') { $after.computer_guid = '81234567-89ab-cdef-0123-456789abcdef' }
    else { $after.writer_guid = $after.reader_guid }
    Assert-Rejected { Compare-NanoADModuleEvidence -Before $before -After $after }
}
Write-Host 'Pure member identity and restart evidence tests passed; no AD or provider integration exercised.'
