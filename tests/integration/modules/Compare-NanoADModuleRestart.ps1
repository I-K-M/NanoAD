# Pure comparison. Dot-source for tests; invoke explicitly to read reports.
function Compare-NanoADModuleEvidence {
    param([Parameter(Mandatory = $true)]$Before,[Parameter(Mandatory = $true)]$After)
    $module = $Before.module
    if ($module -cnotin @('member-server','directory-fixtures') -or $After.module -cne $module) { throw 'Module mismatch.' }
    $fields = @('lab_id','domain_name','domain_guid')
    $guidFields = @('lab_id','domain_guid')
    if ($module -ceq 'member-server') {
        $fields += @('guest_id','computer_name','computer_guid')
        $guidFields += @('guest_id','computer_guid')
        $checks = @('dc_dns','secure_channel','kerberos_ldap_identity','native_services')
    } else {
        $fields += @('ou_guid','writer_guid','reader_guid','target_guid')
        $guidFields += @('ou_guid','writer_guid','reader_guid','target_guid')
        $checks = @('synthetic_accounts','explicit_property_acl')
    }
    foreach ($report in @($Before,$After)) {
        if ($report.schema_version -ne 1 -or $report.result -cne 'checks_passed' -or
            $report.provider_isolation -cne 'not_verified_by_guest') { throw 'Report is not a passing v1 guest observation.' }
        foreach ($name in $guidFields) {
            $value = $report.$name
            $id = [Guid]::Empty
            if ($value -isnot [string] -or -not [Guid]::TryParseExact($value,'D',[ref]$id) -or
                $id -eq [Guid]::Empty -or $value -cne $id.ToString('D')) { throw 'Invalid canonical report UUID.' }
        }
        foreach ($name in @('boot_unix_ms','captured_unix_ms')) {
            $value = $report.$name
            if (($value -isnot [long] -and $value -isnot [int]) -or $value -le 0 -or $value -gt 253402300799999) { throw 'Invalid timestamp.' }
        }
        if ($report.boot_unix_ms -gt $report.captured_unix_ms) { throw 'Report precedes guest boot.' }
        if (@($report.checks).Count -ne $checks.Count) { throw 'Missing or extra checks.' }
        foreach ($check in $checks) {
            $matches = @($report.checks | Where-Object { $_.id -ceq $check -and $_.status -ceq 'pass' })
            if ($matches.Count -ne 1) { throw 'Missing, failed or duplicate check.' }
        }
        $expectedDomain = 'lab-' + ([Guid]$report.lab_id).ToString('N') + '.nanoad.test'
        if ($report.domain_name -cne $expectedDomain) { throw 'Report domain does not match the lab UUID.' }
        if ($module -ceq 'member-server') {
            $expectedName = 'MS-' + ([Guid]$report.guest_id).ToString('N').Substring(0,12).ToUpperInvariant()
            if ($report.computer_name -cne $expectedName -or $report.guest_id -ceq $report.lab_id -or
                $report.computer_guid -ceq $report.domain_guid) { throw 'Invalid member identity.' }
        } else {
            $objects = @($report.domain_guid,$report.ou_guid,$report.writer_guid,$report.reader_guid,$report.target_guid)
            if (@($objects | Select-Object -Unique).Count -ne $objects.Count) { throw 'Duplicate fixture object identity.' }
        }
    }
    foreach ($field in $fields) {
        if ($Before.$field -cne $After.$field) { throw "Persistence identity changed: $field." }
    }
    if ($After.boot_unix_ms -le $Before.captured_unix_ms -or $After.captured_unix_ms -le $Before.captured_unix_ms) {
        throw 'No distinct later boot demonstrated.'
    }
    [pscustomobject]@{
        schema_version = 1
        module = $module
        lab_id = $Before.lab_id
        result = 'restart_observations_match'
        verified = @('stable_directory_object_ids','later_boot','required_guest_checks')
        provider_isolation = 'not_verified'
        physical_resources = 'not_verified'
        evidence_provenance = 'not_verified'
        qualification = 'not_established'
    }
}

function Read-NanoADModuleReport {
    param([Parameter(Mandatory = $true)][string]$Path)
    $file = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($file.PSIsContainer -or $file.Length -eq 0 -or $file.Length -gt 32768 -or
        ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Expected bounded regular report file.' }
    # Operator-controlled local evidence only. This is not a trust boundary
    # against maliciously replaced parent directories or fabricated reports.
    return (Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
}
