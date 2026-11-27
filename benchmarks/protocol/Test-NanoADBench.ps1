# Small deterministic tests, no hypervisor. Creates only a unique temporary directory.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ("nanoad-bench-test-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $id = [Guid]::NewGuid()
    $file = Join-Path $root 'samples.jsonl'
    $lines = @()
    for ($i = 0; $i -lt 3; $i++) {
        $lines += ([ordered]@{
            schema_version=1; run_id=$id.ToString('D'); scope='host'; phase='idle'; sample_index=$i
            elapsed_ms=$i*5000; available_physical_bytes=1024-$i; committed_bytes=2048
            commit_headroom_bytes=$null; pages_input_per_sec=$i; pages_output_per_sec=0
            page_reads_per_sec=0; cpu_percent=10+$i; collection_ms=20; schedule_lag_ms=0
        } | ConvertTo-Json -Compress)
    }
    Set-Content -LiteralPath $file -Value $lines -Encoding UTF8
    $summarise = Join-Path $PSScriptRoot 'Summarise-NanoADSamples.ps1'
    $result = (& $summarise -Path $file -ExpectedSamples 3 | ConvertFrom-Json)
    if (-not $result.complete -or $result.metrics.available_physical_bytes.min -ne 1022 -or
        $result.metrics.commit_headroom_bytes.known -ne 0 -or $null -ne $result.metrics.commit_headroom_bytes.max -or
        $result.metrics.cpu_percent.p95 -ne 12 -or $result.qualification -ne 'not_evaluated') { throw 'Summary regression.' }
    $partial = (& $summarise -Path $file -ExpectedSamples 4 | ConvertFrom-Json)
    if ($partial.complete) { throw 'Partial series falsely marked complete.' }
    $rejected = $false
    try { $null = & $summarise -Path $file -ExpectedSamples 2 } catch { $rejected = $true }
    if (-not $rejected) { throw 'Unexpected extra samples accepted.' }
    $mixed = $lines.Clone()
    $mixed[1] = $mixed[1].Replace('"scope":"host"','"scope":"guest"')
    Set-Content -LiteralPath $file -Value $mixed -Encoding UTF8
    $rejected = $false
    try { $null = & $summarise -Path $file -ExpectedSamples 3 } catch { $rejected = $true }
    if (-not $rejected) { throw 'Mixed sample scope accepted.' }
    if ($env:OS -eq 'Windows_NT') {
        $diskRoot = Join-Path $root 'disk'
        New-Item -ItemType Directory -Path $diskRoot | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $diskRoot 'test.bin'),[byte[]]::new(4097))
        $disk = (& (Join-Path $PSScriptRoot 'Measure-NanoADDisk.ps1') -RunId $id -LabPath $diskRoot -QuiescentConfirmed | ConvertFrom-Json)
        if ($disk.files -ne 1 -or $disk.logical_default_stream_bytes -ne 4097 -or
            $disk.estimated_file_data_bytes -lt 4097 -or $disk.exact_physical_footprint_verified) { throw 'Allocation estimator regression.' }
    }
    Write-Host 'NanoBench synthetic checks passed; no native AD benchmark executed.'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force
}
