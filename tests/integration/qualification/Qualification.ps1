# Pure evidence review helpers. No provider, network, VM or host mutation.
$script:NanoADQualificationFields = @(
    'schema_version',
    'kind',
    'run_id',
    'operator_id',
    'host_id',
    'commit',
    'provider_version',
    'guest_build',
    'base_sha256',
    'recipe_sha256',
    'workload_sha256',
    'started_unix_ms',
    'completed_unix_ms',
    'host_installed_ram_bytes',
    'guest_configured_ram_bytes',
    'cold_boot_count',
    'min_idle_seconds',
    'min_workload_seconds',
    'soak_seconds',
    'sample_interval_seconds',
    'installed_upper_bound_bytes',
    'all_in_upper_bound_bytes',
    'build_peak_bytes',
    'provider_peak_physical_bytes',
    'provider_peak_commit_bytes',
    'host_min_available_bytes',
    'host_min_commit_headroom_bytes',
    'physical_reserve_bytes',
    'commit_reserve_bytes',
    'boot_to_ready_p95_ms',
    'workload_p50_ms',
    'workload_p95_ms',
    'workload_timeout_ms',
    'cli_bytes',
    'cli_peak_rss_bytes',
    'nanoad_processes_after_stop',
    'unexpected_crashes',
    'sustained_headroom_breaches',
    'repeated_excessive_paging',
    'checks',
    'raw_evidence_sha256'
)
$script:NanoADQualificationMetrics = @(
    'host_installed_ram_bytes',
    'guest_configured_ram_bytes',
    'cold_boot_count',
    'min_idle_seconds',
    'min_workload_seconds',
    'soak_seconds',
    'sample_interval_seconds',
    'installed_upper_bound_bytes',
    'all_in_upper_bound_bytes',
    'build_peak_bytes',
    'provider_peak_physical_bytes',
    'provider_peak_commit_bytes',
    'host_min_available_bytes',
    'host_min_commit_headroom_bytes',
    'physical_reserve_bytes',
    'commit_reserve_bytes',
    'boot_to_ready_p95_ms',
    'workload_p50_ms',
    'workload_p95_ms',
    'workload_timeout_ms',
    'cli_bytes',
    'cli_peak_rss_bytes',
    'nanoad_processes_after_stop',
    'unexpected_crashes',
    'sustained_headroom_breaches',
    'repeated_excessive_paging'
)
$script:NanoADAcceptanceIds = @(1..11 | ForEach-Object { 'AC-{0:00}' -f $_ })

function Assert-NanoADReportShape {
    param($Record,[string[]]$Fields)
    if ($null -eq $Record -or $Record -isnot [pscustomobject]) { throw 'invalid_record' }
    $names = @($Record.PSObject.Properties.Name)
    if ($names.Count -ne $Fields.Count) { throw 'invalid_fields' }
    foreach ($name in $names) {
        if ($name -cnotin $Fields) { throw 'invalid_fields' }
    }
}

function Test-NanoADInteger {
    param($Value,[long]$Minimum = 0)
    return (($Value -is [int] -or $Value -is [long]) -and $Value -ge $Minimum)
}

function Test-NanoADCanonicalGuid {
    param($Value)
    $parsed = [Guid]::Empty
    return ($Value -is [string] -and [Guid]::TryParseExact($Value,'D',[ref]$parsed) -and
        $parsed -ne [Guid]::Empty -and $Value -ceq $parsed.ToString('D'))
}

function Test-NanoADHash {
    param($Value,[int]$Length = 64)
    return ($Value -is [string] -and $Value.Length -eq $Length -and $Value -cmatch '\A[0-9a-f]+\z')
}

function Assert-NanoADQualificationReport {
    param($Report)
    Assert-NanoADReportShape $Report $script:NanoADQualificationFields
    if (-not (Test-NanoADInteger $Report.schema_version 1) -or $Report.schema_version -ne 1 -or
        $Report.kind -isnot [string] -or $Report.kind -cnotin @('reference','candidate')) { throw 'invalid_schema' }
    foreach ($key in @('run_id','operator_id','host_id')) {
        if (-not (Test-NanoADCanonicalGuid $Report.$key)) { throw 'invalid_identity' }
    }
    if (-not (Test-NanoADHash $Report.commit 40)) { throw 'invalid_commit' }
    foreach ($key in @('base_sha256','recipe_sha256','workload_sha256','raw_evidence_sha256')) {
        if (-not (Test-NanoADHash $Report.$key)) { throw 'invalid_hash' }
    }
    if ($Report.provider_version -isnot [string] -or $Report.provider_version -cnotmatch '\A7\.1\.[0-9]{1,4}r[0-9]{1,10}\z' -or
        $Report.guest_build -isnot [string] -or $Report.guest_build -cnotmatch '\A[0-9]{1,6}\.[0-9]{1,6}\z') { throw 'invalid_build' }
    if (-not (Test-NanoADInteger $Report.started_unix_ms 1) -or -not (Test-NanoADInteger $Report.completed_unix_ms 1) -or
        $Report.completed_unix_ms -le $Report.started_unix_ms -or $Report.completed_unix_ms -gt 253402300799999) { throw 'invalid_time' }
    foreach ($key in $script:NanoADQualificationMetrics) {
        if ($null -ne $Report.$key -and -not (Test-NanoADInteger $Report.$key)) { throw 'invalid_metric' }
    }
    if ($Report.checks -isnot [array] -or $Report.checks.Count -ne 11) { throw 'invalid_checks' }
    $seen = @()
    foreach ($check in $Report.checks) {
        Assert-NanoADReportShape $check @('id','status','evidence_sha256')
        if ($check.id -isnot [string] -or $check.id -cnotin $script:NanoADAcceptanceIds -or $check.id -cin $seen -or
            $check.status -isnot [string] -or $check.status -cnotin @('pass','fail','blocked','not_run')) { throw 'invalid_checks' }
        $seen += $check.id
        if (($check.status -ceq 'pass' -and $null -eq $check.evidence_sha256) -or
            ($null -ne $check.evidence_sha256 -and -not (Test-NanoADHash $check.evidence_sha256))) { throw 'invalid_check_evidence' }
    }
}

function Get-NanoADRunBlockers {
    param($Report,[bool]$Candidate)
    $reasons = [Collections.Generic.List[string]]::new()
    foreach ($key in $script:NanoADQualificationMetrics) {
        if ($null -eq $Report.$key) { $reasons.Add("missing_$key") }
    }
    $required = if ($Candidate) { $script:NanoADAcceptanceIds } else { @('AC-03','AC-06','AC-09') }
    foreach ($id in $required) {
        $check = @($Report.checks | Where-Object id -CEQ $id)[0]
        if ($check.status -cne 'pass') { $reasons.Add("unpassed_$id") }
    }
    # Evaluate only known numeric fields. Missing values already block review.
    if ($Candidate -and $null -ne $Report.host_installed_ram_bytes -and $Report.host_installed_ram_bytes -ne 8589934592) { $reasons.Add('host_not_8_gib') }
    if ($Candidate -and $null -ne $Report.installed_upper_bound_bytes -and $Report.installed_upper_bound_bytes -gt 24000000000) { $reasons.Add('installed_target_exceeded') }
    foreach ($key in @('host_installed_ram_bytes','guest_configured_ram_bytes','installed_upper_bound_bytes','all_in_upper_bound_bytes','build_peak_bytes','provider_peak_physical_bytes','provider_peak_commit_bytes','boot_to_ready_p95_ms','workload_p95_ms','workload_timeout_ms','cli_bytes','cli_peak_rss_bytes')) {
        if ($null -ne $Report.$key -and $Report.$key -eq 0) { $reasons.Add("zero_$key") }
    }
    if ($null -ne $Report.all_in_upper_bound_bytes -and $null -ne $Report.installed_upper_bound_bytes -and
        $Report.all_in_upper_bound_bytes -lt $Report.installed_upper_bound_bytes) { $reasons.Add('inconsistent_disk_accounting') }
    if ($null -ne $Report.guest_configured_ram_bytes -and $null -ne $Report.host_installed_ram_bytes -and
        $Report.guest_configured_ram_bytes -gt $Report.host_installed_ram_bytes) { $reasons.Add('guest_ram_exceeds_host') }
    if ($null -ne $Report.cold_boot_count -and $Report.cold_boot_count -lt 3) { $reasons.Add('insufficient_cold_boots') }
    if ($null -ne $Report.min_idle_seconds -and $Report.min_idle_seconds -lt 1800) { $reasons.Add('insufficient_idle') }
    if ($null -ne $Report.min_workload_seconds -and $Report.min_workload_seconds -lt 1800) { $reasons.Add('insufficient_workload') }
    if ($null -ne $Report.soak_seconds -and $Report.soak_seconds -lt 3600) { $reasons.Add('insufficient_finalist_soak') }
    if ($null -ne $Report.sample_interval_seconds -and ($Report.sample_interval_seconds -lt 1 -or $Report.sample_interval_seconds -gt 60)) { $reasons.Add('invalid_sample_interval') }
    if ($null -ne $Report.min_idle_seconds -and $null -ne $Report.min_workload_seconds -and $null -ne $Report.soak_seconds -and $null -ne $Report.cold_boot_count) {
        $requiredMs = ([decimal]$Report.cold_boot_count * ([decimal]$Report.min_idle_seconds + $Report.min_workload_seconds) + $Report.soak_seconds) * 1000
        if ([decimal]$Report.completed_unix_ms - $Report.started_unix_ms -lt $requiredMs) { $reasons.Add('inconsistent_duration') }
    }
    if ($null -ne $Report.physical_reserve_bytes -and $Report.physical_reserve_bytes -lt 2147483648) { $reasons.Add('physical_reserve_too_low') }
    if ($null -ne $Report.commit_reserve_bytes -and $Report.commit_reserve_bytes -lt 536870912) { $reasons.Add('commit_reserve_too_low') }
    if ($null -ne $Report.host_min_available_bytes -and $null -ne $Report.physical_reserve_bytes -and
        $Report.host_min_available_bytes -lt $Report.physical_reserve_bytes) { $reasons.Add('physical_headroom_breach') }
    if ($null -ne $Report.host_min_commit_headroom_bytes -and $null -ne $Report.commit_reserve_bytes -and
        $Report.host_min_commit_headroom_bytes -lt $Report.commit_reserve_bytes) { $reasons.Add('commit_headroom_breach') }
    foreach ($key in @('nanoad_processes_after_stop','unexpected_crashes','sustained_headroom_breaches','repeated_excessive_paging')) {
        if ($null -ne $Report.$key -and $Report.$key -ne 0) { $reasons.Add("nonzero_$key") }
    }
    if ($null -ne $Report.workload_p50_ms -and $null -ne $Report.workload_p95_ms -and
        $Report.workload_p50_ms -gt $Report.workload_p95_ms) { $reasons.Add('invalid_latency_order') }
    if ($null -ne $Report.workload_p95_ms -and $null -ne $Report.workload_timeout_ms -and
        $Report.workload_p95_ms -gt $Report.workload_timeout_ms) { $reasons.Add('latency_timeout_exceeded') }
    return $reasons.ToArray()
}

function Get-NanoADQualificationAssessment {
    param([Parameter(Mandatory = $true)]$Reference,[Parameter(Mandatory = $true)]$Candidate,[Parameter(Mandatory = $true)]$Replication)
    foreach ($report in @($Reference,$Candidate,$Replication)) { Assert-NanoADQualificationReport $report }
    if ($Reference.kind -cne 'reference' -or $Candidate.kind -cne 'candidate' -or $Replication.kind -cne 'candidate') { throw 'wrong_report_kind' }
    $reasons = [Collections.Generic.List[string]]::new()
    foreach ($run in @($Reference,$Candidate,$Replication)) {
        foreach ($key in @('commit','provider_version','guest_build','base_sha256','recipe_sha256','workload_sha256','workload_timeout_ms','sample_interval_seconds','physical_reserve_bytes','commit_reserve_bytes')) {
            if ($run.$key -cne $Reference.$key) { $reasons.Add("mismatch_$key") }
        }
    }
    if ($Candidate.guest_configured_ram_bytes -ne $Replication.guest_configured_ram_bytes) { $reasons.Add('candidate_ram_mismatch') }
    if ($null -ne $Reference.guest_configured_ram_bytes -and $null -ne $Candidate.guest_configured_ram_bytes -and
        $Reference.guest_configured_ram_bytes -lt $Candidate.guest_configured_ram_bytes) { $reasons.Add('reference_ram_smaller_than_candidate') }
    if (@(@($Reference.run_id,$Candidate.run_id,$Replication.run_id) | Select-Object -Unique).Count -ne 3) { $reasons.Add('duplicate_run') }
    if (@(@($Reference.raw_evidence_sha256,$Candidate.raw_evidence_sha256,$Replication.raw_evidence_sha256) | Select-Object -Unique).Count -ne 3) { $reasons.Add('duplicate_evidence') }
    if ($Replication.operator_id -ceq $Candidate.operator_id -or $Replication.operator_id -ceq $Reference.operator_id -or
        $Replication.host_id -ceq $Candidate.host_id -or $Replication.host_id -ceq $Reference.host_id) { $reasons.Add('independence_not_reported') }
    foreach ($pair in @(@{ name = 'reference'; report = $Reference; candidate = $false },@{ name = 'candidate'; report = $Candidate; candidate = $true },@{ name = 'replication'; report = $Replication; candidate = $true })) {
        foreach ($reason in @(Get-NanoADRunBlockers $pair.report $pair.candidate)) { $reasons.Add("$($pair.name)_$reason") }
    }
    foreach ($run in @($Candidate,$Replication)) {
        if ($null -ne $run.workload_p95_ms -and $null -ne $Reference.workload_p95_ms -and
            [decimal]$run.workload_p95_ms -gt 2 * [decimal]$Reference.workload_p95_ms) { $reasons.Add('p95_regression_over_2x') }
    }
    # Never equate structurally valid, self-reported data with independently
    # verified raw measurements, genuine host identity or release approval.
    [pscustomobject]@{
        schema_version = 1
        result = if ($reasons.Count -eq 0) { 'reported_thresholds_met_pending_review' } else { 'incomplete_or_failed' }
        blockers = @($reasons.ToArray() | Select-Object -Unique)
        provenance = 'not_verified'
        independent_review = 'required'
        qualification = 'not_established'
        release_approved = $false
    }
}

function Read-NanoADQualificationReport {
    param([Parameter(Mandatory = $true)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or $item.Length -eq 0 -or $item.Length -gt 65536 -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'invalid_report_file' }
    # Trusted operator-controlled local directory only. Do not use this as
    # an adversarial JSON parser or a provenance/TOCTOU guarantee.
    $parsed = Get-Content -LiteralPath $item.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    Assert-NanoADQualificationReport $parsed
    return $parsed
}
