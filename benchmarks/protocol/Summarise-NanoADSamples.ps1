# Summarise a bounded, single-run/scope/phase JSONL sample file.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][ValidateRange(1,3600)][int]$ExpectedSamples,
    [ValidateRange(1,60)][int]$IntervalSeconds = 5
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$file = Get-Item -LiteralPath $Path -Force
if ($file -isnot [IO.FileInfo] -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $file.Length -gt 16MB) {
    throw 'Expected a local regular JSONL file no larger than 16 MiB.'
}
$metrics = @('available_physical_bytes','committed_bytes','commit_headroom_bytes','pages_input_per_sec','pages_output_per_sec','page_reads_per_sec','cpu_percent','collection_ms','schedule_lag_ms')
$values = @{}
foreach ($name in $metrics) { $values[$name] = [Collections.Generic.List[decimal]]::new() }
$count = 0
$key = $null
$first = $null
$previous = [long]-1
$maxGap = [long]0
foreach ($line in [IO.File]::ReadLines($file.FullName)) {
    if ($line.Length -eq 0 -or $line.Length -gt 16384 -or $count -ge $ExpectedSamples) { throw 'Unexpected sample count or line length.' }
    $sample = $line | ConvertFrom-Json -ErrorAction Stop
    if ($sample.schema_version -ne 1 -or $sample.sample_index -ne $count -or
        $sample.scope -notin @('host','guest') -or $sample.phase -notin @('baseline','build','boot','idle','workload','shutdown','switch')) { throw 'Invalid sample identity or order.' }
    $uuid = [Guid]::Parse([string]$sample.run_id)
    if ($uuid -eq [Guid]::Empty) { throw 'Empty run UUID.' }
    $sampleKey = "$uuid/$($sample.scope)/$($sample.phase)"
    if ($count -eq 0) { $key = $sampleKey; $first = $sample }
    if ($key -ne $sampleKey) { throw 'Mixed runs, phases or scopes.' }
    $now = [long]$sample.elapsed_ms
    if ($now -lt 0 -or ($count -gt 0 -and $now -le $previous)) { throw 'Non-monotonic sample clock.' }
    if ($count -gt 0) { $maxGap = [Math]::Max($maxGap,$now-$previous) }
    $previous = $now
    foreach ($name in $metrics) {
        $property = $sample.PSObject.Properties[$name]
        if ($null -eq $property) { throw "Missing metric: $name" }
        if ($null -eq $property.Value) { continue }
        $value = $property.Value
        if ($value -isnot [int] -and $value -isnot [long] -and $value -isnot [uint64] -and $value -isnot [decimal] -and $value -isnot [double]) { throw "Non-numeric metric: $name" }
        $number = [decimal]$value
        if ($number -lt 0 -or $number -ne [Math]::Truncate($number) -or $number -gt [decimal][uint64]::MaxValue -or ($name -eq 'cpu_percent' -and $number -gt 100)) { throw "Metric out of range: $name" }
        $values[$name].Add($number)
    }
    $count++
}
if ($count -eq 0) { throw 'No samples.' }
$summary = [ordered]@{}
foreach ($name in $metrics) {
    $series = $values[$name]
    $series.Sort()
    $min = $null; $max = $null; $p95 = $null
    if ($series.Count -gt 0) {
        $min = $series[0]; $max = $series[$series.Count - 1]
        $index = [int][Math]::Ceiling($series.Count * 0.95) - 1
        $p95 = $series[$index]
    }
    $summary[$name] = [ordered]@{ known = $series.Count; unknown = $count - $series.Count; min = $min; max = $max; p95 = $p95 }
}
[ordered]@{
    schema_version = 1
    run_id = $first.run_id
    scope = $first.scope
    phase = $first.phase
    expected_samples = $ExpectedSamples
    observed_samples = $count
    max_gap_ms = $maxGap
    interval_seconds = $IntervalSeconds
    complete = ($count -eq $ExpectedSamples)
    schedule_within_tolerance = ($maxGap -le ($IntervalSeconds * 1000 + 1000))
    metrics = $summary
    qualification = 'not_evaluated'
} | ConvertTo-Json -Depth 6
