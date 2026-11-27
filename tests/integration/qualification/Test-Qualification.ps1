# Synthetic data only: not a benchmark or an acceptance result.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Qualification.ps1')

function New-SyntheticReport {
    param([int]$Index,[string]$Kind)
    $id = '{0}1234567-89ab-cdef-0123-456789abcdef' -f $Index
    $checks = @(1..11 | ForEach-Object {
        [pscustomobject]@{ id = 'AC-{0:00}' -f $_; status = 'pass'; evidence_sha256 = 'a' * 64 }
    })
    [pscustomobject][ordered]@{
        schema_version = 1
        kind = $Kind
        run_id = $id
        operator_id = if ($Index -eq 3) { '31234567-89ab-cdef-0123-456789abcdee' } else { '11234567-89ab-cdef-0123-456789abcdee' }
        host_id = if ($Index -eq 3) { '31234567-89ab-cdef-0123-456789abcded' } else { '11234567-89ab-cdef-0123-456789abcded' }
        commit = 'b' * 40
        provider_version = '7.1.10r169112'
        guest_build = '20348.1'
        base_sha256 = 'c' * 64
        recipe_sha256 = 'd' * 64
        workload_sha256 = 'e' * 64
        started_unix_ms = [long]1700000000000
        completed_unix_ms = [long]1700015000000
        host_installed_ram_bytes = [long]8589934592
        guest_configured_ram_bytes = if ($Kind -ceq 'reference') { [long]4294967296 } else { [long]2147483648 }
        cold_boot_count = 3
        min_idle_seconds = 1800
        min_workload_seconds = 1800
        soak_seconds = 3600
        sample_interval_seconds = 5
        installed_upper_bound_bytes = [long]23000000000
        all_in_upper_bound_bytes = [long]29000000000
        build_peak_bytes = [long]50000000000
        provider_peak_physical_bytes = [long]3000000000
        provider_peak_commit_bytes = [long]3100000000
        host_min_available_bytes = [long]3000000000
        host_min_commit_headroom_bytes = [long]1000000000
        physical_reserve_bytes = [long]2147483648
        commit_reserve_bytes = [long]536870912
        boot_to_ready_p95_ms = 60000
        workload_p50_ms = 50
        workload_p95_ms = 100
        workload_timeout_ms = 500
        cli_bytes = 200000
        cli_peak_rss_bytes = 4000000
        nanoad_processes_after_stop = 0
        unexpected_crashes = 0
        sustained_headroom_breaches = 0
        repeated_excessive_paging = 0
        checks = $checks
        raw_evidence_sha256 = ([string]$Index) * 64
    }
}
function Assert-Rejected {
    param([scriptblock]$Action)
    $rejected = $false
    try { $null = & $Action } catch { $rejected = $true }
    if (-not $rejected) { throw 'malformed_report_accepted' }
}
function Assert-Blocked {
    param($Reference,$Candidate,$Replication,[string]$Reason)
    $assessment = Get-NanoADQualificationAssessment $Reference $Candidate $Replication
    if ($assessment.result -cne 'incomplete_or_failed' -or $Reason -cnotin $assessment.blockers -or
        $assessment.qualification -cne 'not_established' -or $assessment.release_approved) { throw "expected_blocker_$Reason" }
}
$r = New-SyntheticReport 1 reference
$c = New-SyntheticReport 2 candidate
$i = New-SyntheticReport 3 candidate
$result = Get-NanoADQualificationAssessment $r $c $i
if ($result.result -cne 'reported_thresholds_met_pending_review' -or $result.release_approved -or
    $result.qualification -cne 'not_established' -or $result.provenance -cne 'not_verified') { throw 'false_qualification_or_bad_positive_case' }
$c.installed_upper_bound_bytes = [long]24000000001
Assert-Blocked $r $c $i 'candidate_installed_target_exceeded'
$c.installed_upper_bound_bytes = [long]24000000000
$c.provider_peak_commit_bytes = $null
Assert-Blocked $r $c $i 'candidate_missing_provider_peak_commit_bytes'
$c = New-SyntheticReport 2 candidate
$c.checks[5].status = 'not_run'
Assert-Blocked $r $c $i 'candidate_unpassed_AC-06'
$c = New-SyntheticReport 2 candidate
$c.workload_p95_ms = 201
Assert-Blocked $r $c $i 'p95_regression_over_2x'
$c = New-SyntheticReport 2 candidate
$c.host_min_available_bytes = [long]2147483647
Assert-Blocked $r $c $i 'candidate_physical_headroom_breach'
$c = New-SyntheticReport 2 candidate
$c.completed_unix_ms = $c.started_unix_ms + 1000
Assert-Blocked $r $c $i 'candidate_inconsistent_duration'
$c = New-SyntheticReport 2 candidate
$i.operator_id = $c.operator_id
Assert-Blocked $r $c $i 'independence_not_reported'
$i = New-SyntheticReport 3 candidate
$i.raw_evidence_sha256 = $c.raw_evidence_sha256
Assert-Blocked $r $c $i 'duplicate_evidence'
$i = New-SyntheticReport 3 candidate
$i.guest_configured_ram_bytes = [long]1536000000
Assert-Blocked $r $c $i 'candidate_ram_mismatch'
$i = New-SyntheticReport 3 candidate
$i.workload_sha256 = 'f' * 64
Assert-Blocked $r $c $i 'mismatch_workload_sha256'
$i = New-SyntheticReport 3 candidate
$c.checks[1].id = $c.checks[0].id
Assert-Rejected { Get-NanoADQualificationAssessment $r $c $i }
$c = New-SyntheticReport 2 candidate
$c.checks[0].evidence_sha256 = $null
Assert-Rejected { Get-NanoADQualificationAssessment $r $c $i }
$c = New-SyntheticReport 2 candidate
$c.cold_boot_count = '3'
Assert-Rejected { Get-NanoADQualificationAssessment $r $c $i }
$c = New-SyntheticReport 2 candidate
$c | Add-Member -NotePropertyName password -NotePropertyValue 'synthetic'
Assert-Rejected { Get-NanoADQualificationAssessment $r $c $i }
$c = New-SyntheticReport 2 candidate
$roundtrip = $c | ConvertTo-Json -Depth 5 | ConvertFrom-Json
Assert-NanoADQualificationReport $roundtrip
Write-Host 'Qualification evidence checks passed on synthetic reports only; no qualification established.'
