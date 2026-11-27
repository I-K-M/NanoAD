# N04 — NanoBench execution and evidence

Status: tooling prepared; no native benchmark or qualified minimum.

Use the same run UUID for host and guest samples; use distinct files for scope/phase/repetition. Keep outputs outside Git (for example benchmarks/raw). The sampler runs in the foreground, exits after a bounded number of samples and emits one JSON line per observation. It does not start, stop or reconfigure VMs.

## Sample collection

On a qualified Windows host and separately inside the disposable reference guest, run the sampler with the relevant scope. Example host idle run:

```powershell
$run = [Guid]::NewGuid()
.\benchmarks\protocol\Measure-NanoADMemory.ps1 -RunId $run -Scope host -Phase idle -Samples 360 -IntervalSeconds 5 |
    Set-Content -Encoding UTF8 .\benchmarks\raw\host-idle.jsonl
.\benchmarks\protocol\Summarise-NanoADSamples.ps1 -Path .\benchmarks\raw\host-idle.jsonl -ExpectedSamples 360 -IntervalSeconds 5
```

Create the output directory yourself. Reuse the UUID inside the guest, collect simultaneously, and retain incomplete runs rather than silently filling gaps. The default gives 360 samples over a nominal 30-minute window; record wall time and continue the workload for the full 30 minutes. Sample start timestamps use a monotonic clock for spacing and UTC for cross-host correlation. Delayed collection aborts rather than bursts. Unknown counters are null. CPU and paging counters are Windows formatted counters, not proof of pagefile-only traffic. The collector's own overhead is not zero: measure it separately before judging a low-memory candidate. Use the provider's process/commit inventory independently; system-wide totals alone cannot identify VM overhead.

## Disk allocation

After a clean stop, point the estimator at the dedicated lab directory containing every retained lab artefact (base, overlays, caches, state, logs, archives). Confirm no writer is active:

```powershell
.\benchmarks\protocol\Measure-NanoADDisk.ps1 -RunId $run -LabPath D:\nanoad-lab -QuiescentConfirmed
```

The first Windows implementation accepts fixed NTFS volumes only. It uses [GetCompressedFileSizeW](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getcompressedfilesizew) and [GetDiskFreeSpaceW](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getdiskfreespacew), rounding per-file allocation to clusters and conservatively charging named streams. This is a file-data estimate, not exact total filesystem consumption: metadata is excluded and hard links or shared storage may be counted more than once. Reparse points and inaccessible entries fail closed. Do not run against a changing or untrusted directory; quiescence is not enforced by the script. Record volume-free-space deltas on a dedicated volume and provider allocation information separately, verify all retained artifacts are inside the measured root, and never mark the exact physical target verified from this estimator alone. Build media and scratch are recorded separately; measure peak build usage, not just the final directory.

## Experiment sequence

1. Complete N01–N03, capture generous reference with a fixed OS build and fixture.
2. Start with supported RAM, then test 3072/2048/1536/1280/1024 MiB; lower tiers are experimental and require explicit operator consent. Change one variable at a time and stop downward testing after the first fidelity/stability failure. Configure RAM only while powered off.
3. At each tier perform three cold boots, an idle phase and fixed native workload; run the N03 core and fixture checks, and record workload latency and audit/restart evidence. Do not reuse a failed or partial baseline as the comparison anchor.
4. Record boot-to-ready, host and guest memory samples, CPU/paging, provider memory, actual storage, installation/build peak, and failures. Compare native outcomes and p95 workload latency to the unoptimised reference using NAN-002 thresholds. Sample p95 is not workload-operation p95.
5. Rebuild instead of reverting a live DC. A profile is qualified only after independent review and a complete evidence record. Never claim a minimum based solely on a successful boot or an allocated RAM number.

## Validation and limitations

CI parses scripts in Windows PowerShell 5.1 and PowerShell 7 and exercises synthetic summaries and a tiny ordinary NTFS file. It does not emulate performance, exercise sparse VM disks, start a VM, verify AD, or qualify the 24 GB target. Real test evidence remains mandatory.
