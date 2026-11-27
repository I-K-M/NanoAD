# N15a — independent qualification preparation

Parent: [N15](../../../tickets/001-nanoad/N15-independent-qualification.md), [NAN-001](../../../specs/001-nanoad.md), [NAN-002](../../../specs/002-resource-research.md). No native run has been performed. See [audit](AUDIT.md).

## Ordered reference experiment

1. Use a disposable, dedicated Windows x86-64 host, a trusted fixed NTFS volume and exclusive provider configuration. Record installed and OS-visible RAM, host/CPU/OS/firmware, provider executable provenance/version/configuration and official licensed Server Core media. Use the existing read-only host probe: from the repo root, run the following with Windows PowerShell, pointing to the existing intended volume:
   
   ```powershell
   .\benchmarks\protocol\probe-windows.ps1 -LabPath .
   zig version
   zig fmt --check build.zig src modules
   zig build test
   zig build -Doptimize=ReleaseSafe
   .\zig-out\bin\nanoad.exe doctor --json
   ```

   Doctor is intentionally unqualified (exit 3 on the reference platform). The commands build and test source; they do not start a VM. Preserve the actual outputs and commit. Do not install or alter a hypervisor automatically. N14 must merge with green checks first; its full native integration remains pending.
2. Complete [reference host](../../../docs/reference-host.md), [image](../../../images/windows-core/README.md), [native AD](../ad/README.md) and [isolation](../../security/README.md) gates before any authorised disposable guest mutation. Prepare a generous 4 GiB reference where appropriate. Build scratch may exceed the installed budget. Use independently generalised child disks; never clone a live/promoted DC or weaken security services.
3. Follow [NanoBench](../../../benchmarks/protocol/EXPERIMENTS.md): sweep one variable at a time, at least three cold boots, minimum 30 min idle and 30 min mixed workload per repetition, fixed sampling interval and identical build/patch/fixture/workload seed; stop after first downward failure. For this proposed finalist protocol, use an additional 60 min soak, separate from the repetition windows. Record absolute timeouts, paging/headroom criteria and resource reserves *before* running. The 60 min soak is an explicit conservative preparation decision, not an existing measured threshold.
4. Record actual host/guest/provider idle/peak memory, commit, paging and CPU, boot latency, p50/p95 workload latency, allocated disk, build peak and all-in bytes, shutdown residuals, CLI executable size and measured peak RSS. Check the full native fidelity and adverse-state matrix, including clean shutdown and re-observation. Use separate independent physical allocation evidence; the existing file-data estimator alone cannot establish a strict total. For failure/unknown use fail/blocked/not_run or null; never zero-fill. If the goal fails, publish the smallest *validated* result and limiting cause.
5. Reproduce the same candidate on a second physical host with 8 GiB installed RAM and a second operator, same commit, provider, Windows build/patch, base, recipe, workload, allocation and timeout policy. Use a separate run ID and raw evidence digest. Review all AC-01–AC-11 and raw data; the checker cannot verify identity or provenance. A supported profile requires independent review and explicit release approval (N16).

## AC evidence mapping

| AC | Evidence to retain |
| --- | --- |
| AC-01 | 8 GiB host inventory, cold boots, native ready and clean stop, physical/commit headroom |
| AC-02 | complete strict physical inventory and dedicated-volume/provider cross-check, all retained artefacts, build peak/all-in |
| AC-03 | identical core/reference positive and negative native outcomes, workload latency, paging/crash/event records |
| AC-04 | actual over-budget alternatives, decline invariance, accepted stop-before-start and measured resource release |
| AC-05 | missing/pinned/unknown/low-disk/provider failure and recovery observations |
| AC-06 | native provider scope, attachments/peers/route/DNS, host boundary and path/ACL tests |
| AC-07 | post-stop process inventory and measured host/provider/CLI overhead |
| AC-08 | actual interrupted transaction/replay, repeated provisioning and original media/reference preservation |
| AC-09 | clean rebuild, licensed media/hash and recipe, equivalent native behaviour |
| AC-10 | ReleaseSafe binary and peak RSS measurements, compare experimental targets without hiding misses |
| AC-11 | independent reproduction, full limitations and redacted evidence bundle |

## Offline report review

The helper validates a closed set of fields, exact AC IDs and statuses, required evidence digests, basic numeric consistency, conservative reserves, target limits and reference/candidate/replication comparability. Inputs are small, sanitised, operator-controlled JSON files (up to 64 KiB). Use the blank template in benchmarks/results. Enter timestamps in UTC Unix milliseconds. Use random pseudonymous UUIDs for operator/host IDs, never real account names or machine serials. Exact SHA-256 of the preserved evidence package and per-check artefacts must be computed from independently reviewed originals; no passwords, paths, keys or raw logs in Git. The checker cannot prove provenance, enforce strict JSON duplicate-key semantics across PowerShell versions, validate actual allocation or authenticate operator identity. It is not an authorisation gate or a replacement for review.

```powershell
. .\tests\integration\qualification\Qualification.ps1
$ref = Read-NanoADQualificationReport -Path '.\benchmarks\raw\reference.json'
$candidate = Read-NanoADQualificationReport -Path '.\benchmarks\raw\candidate.json'
$replication = Read-NanoADQualificationReport -Path '.\benchmarks\raw\replication.json'
Get-NanoADQualificationAssessment -Reference $ref -Candidate $candidate -Replication $replication | ConvertTo-Json -Depth 5
```

A matching reported dataset can only return reported_thresholds_met_pending_review, with qualification=not_established and release_approved=false. All missing metrics, failed checks, inadequate soak/headroom, duplicate run/evidence, lack of reported independence, incompatible input or >2x p95 latency block the review. AC-03, AC-06 and AC-09 are mandatory on the generous reference; all eleven on both candidate runs. The template is deliberately invalid until IDs, hashes and timing are supplied. Synthetic CI fixtures are never benchmark results.

Run pure regression checks: powershell -NoProfile -File tests/integration/qualification/Test-Qualification.ps1 (or pwsh). No VM, credential, network or host setting changes. Rollback: revert preparation files; retain evidence. Independent review and real native execution remain open.
