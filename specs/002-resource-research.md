# NAN-002 — Resource research and optimisation

Status: proposed. Parent: [NAN-001](001-nanoad.md). This document defines experiments, not established savings.

## 1. Measurement contract

Use bytes internally (checked unsigned arithmetic); display MiB/GiB for memory and both GB/GiB for storage. Host target: 8 GiB; installed lab target: 24,000,000,000 bytes. Distinguish:

- Guest virtual disk capacity, guest filesystem used bytes, host allocated bytes, apparent file length, and exclusive/shared allocation.
- Guest configured RAM, provider process private/resident/committed memory, guest available memory, page faults and paging, host available memory, commit headroom.
- Steady-state installed lab footprint including base, overlays, caches, state, logs, archives, temporary files remaining after build; report ISO, toolchain and hypervisor separately and include them in a separate all-in figure.
- Build peak, switch peak, compaction peak and runtime steady state. A tiny archive is not a runnable footprint.
- Shared blocks counted once only when the provider/filesystem provides trustworthy accounting; otherwise conservatively charge full physical allocation. Unavailable measurement is unknown, not zero.

Host baseline is recorded before launching any NanoAD VM and after shutdown; other active workloads and hypervisor services are recorded. Do not infer host savings from guest-reported working sets.

## 2. Baseline and image build

Compare officially obtained, licensed Server Core 2019, 2022 and 2025 x86-64 releases only when available and still appropriate for the intended experiment. Start with Server 2022 Core as a provisional comparison anchor; qualify the most suitable build by evidence. Record edition, exact build/update level, media hash, VM firmware, disk controller, provider/version and CPU.

Use a supported installation configuration and at least Microsoft's documented system disk capacity for the selected release (32 GB is the stated absolute installation minimum; reserve more virtual capacity when needed). Installation may require more RAM and storage than runtime. Never promise a successful build within the 24 GB runtime budget; support building/importing a locally generated image on larger temporary storage.

Image recipe order:
1. Verify media/provenance, preflight scratch and peak resource requirement.
2. Install Core unattended with unique temporary build credentials, one language, no Desktop Experience or optional GUI compatibility payload.
3. Install applicable security updates in explicit build/maintenance network; record versions.
4. Inventory optional features and services, component store, pagefile, dumps, logs, drivers, caches.
5. Apply only one reviewed optimisation at a time. Retest servicing, native behaviours and boot.
6. Generalise the unjoined, unpromoted image; seal, hash, mark immutable; detach media and build connectivity.
7. Provision DC01 on a new overlay, run baseline health, record actual storage and memory.
8. Remove disposable scratch only after verification and explicit retention policy.

## 3. Optimisation catalogue

| ID | Experiment or rule | Gate / cost |
| --- | --- | --- |
| O-01 | Core instead of Desktop Experience | Same required native roles |
| O-02 | Single language, no optional GUI compatibility | Preserve required guest administration |
| O-03 | Supported DISM component cleanup | Document servicing/rollback implications; retest updates |
| O-04 | Remove unused optional feature payloads | Prove role restoration from matching media; count cache |
| O-05 | Clear reviewed temporary/build/download files | Never remove required component store files by hand |
| O-06 | Size pagefile from commit/paging measurements | Never blindly disable; retain crash/recovery capability |
| O-07 | Minimal appropriate crash dumps and log rotation | Preserve security and scenario evidence |
| O-08 | Audit services before disabling optional ones | Never disable AD dependencies, security or audit controls to win a benchmark |
| O-09 | Assess filesystem/OS compression where supported | Measure CPU, boot, servicing, write growth |
| O-10 | Thin virtual disks, sparse host files | Validate physical allocation and guest free space separately |
| O-11 | Immutable generalised base + differencing disks | Unique machine identities; reference counting |
| O-12 | Guest trim/discard and offline compaction | Capability probe; no concurrent writers; measure temporary peak |
| O-13 | QCOW2 compressed read-only base (Linux later) | Compare zlib/Zstd read CPU; rewritten clusters may be uncompressed |
| O-14 | Bounded streaming compression for archives | Record archive ratio, restore time, scratch and RAM; not counted as running image |
| O-15 | Content-addressed media cache | Hash verification; ref-counted; no automatic purge |
| O-16 | Limit overlay depth and retained snapshots | No live DC snapshots by default; rebuild safer |
| O-17 | Store manifests and deterministic fixtures, not VM copies | Rebuild equivalence and explicit retention |
| O-18 | Use 1 vCPU baseline, test 2 for start peaks | Measure time-to-ready and idle CPU |
| O-19 | Downsize guest allocation in validated steps | Supported baseline first; lower allocations experimental |
| O-20 | Optional memory ballooning | Only provider-supported, guest-qualified and bounded; not relied on for strict admission |
| O-21 | No save-state files by default | Graceful shutdown frees RAM; suspension may retain resources or write large files |
| O-22 | Linux tools from minimal guest or approved isolated execution path | No permanent Kali GUI, no host network exposure |
| O-23 | Load fixture objects rather than machines when native semantics permit | Explicit dependencies and rollback class |
| O-24 | Stop optional processes and guests between exercises | Confirm actual release before admitting new work |
| O-25 | On-demand audit collection, no always-on SIEM | Preserve required native auditing |
| O-26 | CLI ReleaseSafe vs ReleaseSmall, strip debug symbols where appropriate | Test identical behaviour; measure file size and RSS |
| O-27 | Fixed buffers/arena where bounded, streaming I/O, output caps | Reject overflow, oversized input and allocation failure |
| O-28 | Event-driven supervision where supported; bounded polling fallback | Measure wakeups; no daemon outside session |
| O-29 | No extra database, web UI or interpreter in MVP | Revisit only with demonstrated need |
| O-30 | Benchmark provider, disk cache and host filesystem variants | Never double-count deduplication; portability and CPU trade-off |

Optimisations below vendor support limits are experimental, never the default. Never remove core DLLs, alter Windows kernel integrity, patch AD executables, disable Defender or audit services merely to reduce footprint, or distribute modified Microsoft binaries.

## 4. Budget and admission policy

Strict default: reserve host headroom (provisional minimum 2 GiB, increased from observed host baseline/pressure where needed), and cap guest commitments to user-configured lab limit. Example on 8 GiB: start with 3 GiB lab RAM budget, 24 GB installed storage budget, and calculate separate provider overhead. This is not a reservation guarantee; actual host available/commit constraints also apply. Every new start uses conservative per-guest configured/peak memory and provider overhead, including concurrent startup. Disk plans include temporary extraction/compaction and retained files. If capacity or measurement is insufficient, reject with a reason. Never rely on swap or pagefile as free RAM.

Balanced may use documented safe estimates; Experimental may opt into lower guest allocations or validated ballooning; neither bypasses isolation, consent, ownership or host survival constraints. Strict cannot be overridden by an implicit fallback. Budgets are explicit configuration, not promises against other host processes changing resource use.

## 5. Test matrix

Start with a generous reference configuration (e.g. 4 GiB DC, adequate disk), then compare Core builds at supported allocations. Suggested runtime sweep: 3072, 2048, 1536, 1280, 1024 MiB, then 896/768/640/512 MiB only when prior tests pass and the operator opts in. A lower test failure stops downward qualification for that build. Installation/promotion may use a separate larger budget. Run at least three cold boots per candidate, a 30-minute idle period, and a 30-minute repeatable mixed test workload; capture raw samples at a documented interval (default 5 seconds, measure sampler overhead). Use identical fixtures and workload seed. Run a longer soak and restart cycles on the finalist.

Test core DNS records, LDAP positive/negative binds/search, authentication under Kerberos and configured NTLM policy, ACL allow/deny, SYSVOL availability, GPO access, expected event IDs, directory writes, service health and restart persistence. For multi-host modules add member join, time sync, replication/CA tests appropriate to the topology. Compare with unoptimised reference. A successful boot alone is insufficient.

Record idle and peak host/guest memory, commit/paging, CPU, allocated disk bytes, install/build peak, boot-to-ready, operation latency p50/p95, errors, failure recovery, and shutdown residuals. Provisional acceptance: no fidelity mismatches or unexpected crashes, no sustained host headroom breach, no repeated excessive paging, all operations complete within declared timeouts, and p95 workload latency no more than 2x reference unless an explicitly accepted profile documents the trade-off. Establish absolute workload timeouts before testing, not after seeing results.

## 6. Evidence schema and publication

Every result has run ID, UTC timestamps, git commit, provider version/capabilities, host CPU/RAM/filesystem/OS, image hash/build/patch/recipe, actual allocations, workload seed, sampling interval, raw measurements, checks, pass/fail, warnings and limitations. Store small sanitised JSON/CSV and Markdown summaries under benchmarks/results; keep large/raw sensitive files outside Git. Report failed runs and repeat variability, not only best cases. Independent replication required before a supported claim.

## 7. Recovery and failure

If a candidate cannot boot, service, authenticate, update or maintain integrity, discard its overlay and reconstruct from the intact base. If compaction cannot complete within disk budget, leave original intact. No forced deletion to meet the target. If the 24 GB target cannot be met, publish smallest validated footprint and distinguish steady-state from build peak. Scope changes require an updated specification.

## References

- [Microsoft hardware requirements](https://learn.microsoft.com/en-us/windows-server/get-started/hardware-requirements)
- [Microsoft virtualisation safeguards](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/introduction-to-active-directory-domain-services-ad-ds-virtualization-level-100)
- [QEMU image formats, conversion and compression](https://www.qemu.org/docs/master/tools/qemu-img.html)
