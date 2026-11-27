# Bounded Windows host/guest sampler. Emits JSON Lines to stdout; no daemon.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][Guid]$RunId,
    [Parameter(Mandatory)][ValidateSet('host','guest')][string]$Scope,
    [Parameter(Mandatory)][ValidateSet('baseline','build','boot','idle','workload','shutdown','switch')][string]$Phase,
    [ValidateRange(1,3600)][int]$Samples = 360,
    [ValidateRange(1,60)][int]$IntervalSeconds = 5
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT' -or $RunId -eq [Guid]::Empty) { throw 'Windows and a non-empty run UUID are required.' }
if ($Samples * $IntervalSeconds -gt 21600) { throw 'Sampling window may not exceed six hours.' }

function Read-Counter {
    param($Object,[string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $null }
    try { return [uint64]$property.Value } catch { return $null }
}
$clock = [Diagnostics.Stopwatch]::StartNew()
for ($i = 0; $i -lt $Samples; $i++) {
    $due = [long]$i * $IntervalSeconds * 1000
    $delay = $due - $clock.ElapsedMilliseconds
    if ($delay -gt 0) { Start-Sleep -Milliseconds ([int]$delay) }
    $started = $clock.ElapsedMilliseconds
    $utc = [DateTime]::UtcNow.ToString('o')
    $memory = $null
    $cpu = $null
    $warnings = [Collections.Generic.List[string]]::new()
    try { $memory = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Memory -OperationTimeoutSec 3 -ErrorAction Stop } catch { $warnings.Add('memory_counter_unavailable') }
    try { $cpu = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -OperationTimeoutSec 3 -ErrorAction Stop } catch { $warnings.Add('cpu_counter_unavailable') }
    $available = Read-Counter $memory 'AvailableBytes'
    $committed = Read-Counter $memory 'CommittedBytes'
    $limit = Read-Counter $memory 'CommitLimit'
    $headroom = $null
    if ($null -ne $committed -and $null -ne $limit -and $limit -ge $committed) { $headroom = $limit - $committed }
    $cpuPercent = Read-Counter $cpu 'PercentProcessorTime'
    if ($null -ne $cpuPercent -and $cpuPercent -gt 100) { $cpuPercent = $null }
    $elapsed = $clock.ElapsedMilliseconds
    [ordered]@{
        schema_version = 1
        run_id = $RunId.ToString('D')
        scope = $Scope
        phase = $Phase
        sample_index = $i
        sampled_utc = $utc
        elapsed_ms = $started
        schedule_lag_ms = $started - $due
        collection_ms = $elapsed - $started
        available_physical_bytes = $available
        committed_bytes = $committed
        commit_limit_bytes = $limit
        commit_headroom_bytes = $headroom
        pages_input_per_sec = Read-Counter $memory 'PagesInputPersec'
        pages_output_per_sec = Read-Counter $memory 'PagesOutputPersec'
        page_reads_per_sec = Read-Counter $memory 'PageReadsPersec'
        cpu_percent = $cpuPercent
        warnings = @($warnings.ToArray())
    } | ConvertTo-Json -Depth 4 -Compress
    # Do not launch catch-up samples in a tight loop after delayed collection.
    if ($i + 1 -lt $Samples -and $elapsed -gt ($due + $IntervalSeconds * 1000)) {
        throw 'Sampling deadline missed. Retain partial output and repeat with a longer interval.'
    }
}
