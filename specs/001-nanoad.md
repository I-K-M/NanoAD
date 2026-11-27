# NAN-001 — System specification

Status: proposed, design-only | Language: British English | Scope: first reference release and explicitly deferred extensions

## 1. Outcome and audience

Enable students, administrators and security researchers to operate a genuine Microsoft AD lab on an 8 GiB x86-64 host, including a machine that has only 24 GB of space available for the installed minimal lab. Preserve authentic directory, authentication and security behaviours. Provide an interactive resource governor which favours stopping unused workloads instead of consuming additional resources.

The project measures success by fidelity and actual host resource use, not by the number of pre-installed scenarios. It is not a Windows replacement, an enterprise orchestrator, a production AD deployment product, a cloud service, or a remote offensive automation platform.

## 2. Normative language and priorities

MUST = mandatory for the stated release; SHOULD = expected unless a documented exception is accepted; MAY = optional. Safety, licence compliance and native fidelity outrank footprint; a smaller but semantically incorrect image is a failed experiment. Numerical targets are hypotheses until independently reproduced.

### Release scope

- MVP: Windows x86-64 host, one provider (VirtualBox), one supported Server Core release selected from baseline testing, one domain/forest/DC, one private lab network, native provisioning, basic status and health, disk and memory admission, stop/start, deterministic rebuild.
- v0.2: module manifest, on-demand directory fixtures and a second disposable guest, transactional switches, resource and isolation regression tests.
- v1.0 candidate: qualified resource targets, reproducible evidence, role and topology modules, Linux KVM/QEMU adapter, documented compatibility matrix. Hyper-V, Windows client, SQL Server, rich visualisation and extension scripting remain optional later increments.
- Out of scope: redistribution of Microsoft images, unsupported kernel modifications, bypassing licensing, a production connector, live migration, arbitrary remote targets, mandatory nested virtualisation, default internet-connected vulnerable guests.

## 3. Technical decisions

| Decision | Rationale | Revisit trigger |
| --- | --- | --- |
| Zig core | Explicit allocators, native binaries, small dependency surface | Measured footprint or correctness failure |
| Native PowerShell for guest operations | Genuine Windows APIs and role semantics | Proven safer/smaller supported interface |
| VirtualBox first | Single manageable Windows provider; explicit CLI adapter | Capability or fidelity gate failure |
| Provider-neutral interface | Avoid lock-in to image and VM implementation | A second provider demonstrates missing abstractions |
| JSON manifests and state | Zig standard library parsing; avoid a YAML runtime initially | Demonstrated usability/size problem |
| Atomic local files and operation journal | No resident DB service | Recovery tests show complexity exceeds benefit |
| Packer optional at build time | Reproducible recipe without runtime dependency | Direct native builder simpler and verified |
| No Lua in MVP | Avoid interpreter and plugin trust boundary until needed | Declarative modules cannot express a justified use case |

Pin an exact stable Zig release and supported provider version range at implementation time; record checksums and CI evidence. Do not assume an unverified current release number. Prefer stdlib, explicit bounded allocations, checked arithmetic, bounded I/O, no shell interpolation, no unnecessary worker pools. Use ReleaseSafe for qualified release builds; compare ReleaseSmall only with full regression checks. No custom cryptographic primitives.

## 4. Components and boundaries

| Component | Responsibility |
| --- | --- |
| CLI | Typed command parsing, confirmations, stable exit codes, human and JSON output |
| Planner | Pure graph validation, dependency closure, conflict detection, deterministic feasible plan |
| Governor | Host telemetry, resource reservation, peak and steady-state admission |
| Provider | Capability probe, VM identity, storage/network/lifecycle operations, observations |
| Image manager | Verify official media, build, hash, version, immutable base catalogue |
| Storage manager | Physical allocation inventory, reference graph, quota, safe reclamation |
| Guest provisioner | Idempotent, versioned Windows-native scripts, structured results and health |
| Module engine | Resolve declarative module definitions, lifecycle and rollback |
| State store | Lock, journal, reconcile observed state, recover interrupted transactions |
| Benchmark runner | Separate reproducible measurements and native fidelity regression |
| Session supervisor | Optional explicit foreground session monitor; no service outside session |

Provider interface must express probe, observe, create, configure, start, shutdown, remove, network isolation, image clone and allocation measurement. Unsupported operations are explicit capability failures; never silently substitute weaker isolation or full copies. Provider-native identifiers are stored alongside NanoAD UUIDs. Never operate on a VM solely by a user-facing name.

## 5. Functional requirements

- SYS-01: initialise a lab without network downloads, administrator elevation or VM creation; preflight is read-only.
- SYS-02: identify architecture, virtualisation support, provider/version, host free memory, storage filesystem and free physical space. Detect conflicting hypervisors and fail with actionable guidance rather than altering host security features.
- SYS-03: build from operator-supplied, licensed official Windows media. Verify integrity against a trusted digest and pin edition, language, build, updates, recipe and provider.
- SYS-04: generalise an unpromoted Windows base before cloning. Promote each DC independently with unique identity. Never clone a promoted DC as a general-purpose base.
- SYS-05: configure one private domain under a reserved synthetic namespace, unique lab UUID, minimal directory objects and independent credentials; maintain correct DNS, clock, SYSVOL and service dependencies.
- SYS-06: expose native AD DS, DNS, LDAP, Kerberos and Windows event logs; test successful and rejected authentications with synthetic accounts.
- SYS-07: separate installed, running, retained and archived resources; disable means a verified stop/deactivation, not automatic deletion.
- SYS-08: compute dependency closure and marginal resource cost before each mutation. Shared dependencies count once. Unknown costs block strict admission unless measured or explicitly estimated in a non-strict profile.
- SYS-09: user must explicitly approve any stop, archive, purge, budget change, media download or new optional dependency; show impact and plan fingerprint. A stale plan is rejected.
- SYS-10: no automatic overcommit, no forced guest shutdown, no automatic purge or snapshot revert by default. If clean shutdown fails, stop the transaction and report recovery steps.
- SYS-11: support dry-run with no guest, state, filesystem or network mutation; read-only probing is permitted. Non-interactive mode requires an exact pre-approved plan and fails on unexpected prompts.
- SYS-12: reconcile real hypervisor state before every mutation. External changes or unknown VMs produce a conflict, not destructive repair.
- SYS-13: produce structured logs, health reports, inventory and reproducible benchmark records; redact secrets and bound retention.
- SYS-14: keep CLI independent of a long-running host service; optional monitor exits after the session. Hypervisor background processes are measured separately, not claimed as zero.
- SYS-15: preserve local lab state when stopping; offer explicit archive, reconstruct or purge options with their costs. Resetting a topology with a DC requires a supported recovery/rebuild procedure.
- SYS-16: supply human-readable help, actionable error messages and a machine-readable versioned output contract.

## 6. Native fidelity requirements

Fidelity means behaviour of the selected genuine Windows build, not equivalence to every AD version. The unoptimised reference uses the same OS build, patch level, role configuration, fixtures and provider, with generous memory. Compare reference and optimised runs for positive and negative LDAP bind/search, Kerberos service authentication and ticket lifecycle, NTLM policy outcomes, DNS SRV records, directory ACL decisions, GPO retrieval, SYSVOL, security event IDs and audit outcomes. Test AD CS, member joins, replication and trust only when modules are present; do not claim behaviours absent from the topology.

Core protocols and prerequisites are not toggleable merely to reduce idle resource use. Security controls, system services and logging that affect an exercise remain intact. An explicitly weakened lab configuration is a labelled scenario fixture, never an unannounced image optimisation. Any optimisation which changes expected native semantics is rejected or isolated into a clearly experimental profile.

## 7. Security and privacy

- Private provider network with no bridging, default route to external networks, public port forwarding or host folder mounts. Control channel only through an explicitly validated provider guest facility or restricted lab-management path; no exposed unauthenticated WinRM.
- Build-time connectivity is separate from runtime. Updates or role-media retrieval require a deliberate maintenance action; detach build NAT before promotion or vulnerable fixtures. Fail closed if isolation cannot be proven.
- Unique lab-generated secrets; no reused real credentials. Store outside Git with restrictive host ACLs. Do not pass passwords in process arguments, logs or manifests. Guest operations target only owned VM IDs.
- Treat manifests, guest responses and paths as untrusted. Strict schema validation, bounded sizes and depths, no path traversal, no symlink escape, no arbitrary shell commands from third-party modules. No extension code in MVP.
- No automatic telemetry uploads. Reports are local, sanitised before publication. Protect state and image directory; never delete outside the owned root. A deliberately vulnerable guest is hostile from the host's perspective.
- Supply-chain integrity: pin toolchain and build dependencies; verify downloaded artefacts; record provenance and licence obligations. No Windows activation bypasses or proprietary redistribution.

## 8. Acceptance criteria

| ID | Evidence |
| --- | --- |
| AC-01 | Fresh Windows x86-64 8 GiB host runs native DC, then cleanly stops; host headroom remains within configured limit |
| AC-02 | Physical allocation inventory demonstrates minimal installed footprint at or below 24 GB, including all retained lab artefacts; report build peak separately |
| AC-03 | Reference and optimised core fidelity tests match; no unexpected relevant system errors, crash or excessive paging |
| AC-04 | Optional module request over budget produces deterministic alternatives; decline leaves observed state unchanged; accepted switch frees resources before start |
| AC-05 | Missing prerequisite, pinned dependency, unknown cost, disk exhaustion and provider failure all reject or recover safely |
| AC-06 | External-network and host-boundary probes show required isolation; no forbidden attachments remain after build |
| AC-07 | Stop/down leaves no NanoAD process; measured host/provider overhead documented |
| AC-08 | Interrupted operation recovery and repeated provisioning pass; no orphaned VM or referenced base deletion |
| AC-09 | Rebuild from recorded media/recipe/fixture produces equivalent behaviour; licences and checksums documented |
| AC-10 | CLI targets reported for release builds, with regressions tracked and no fabricated metrics |
| AC-11 | Documentation, tests, benchmark raw data and limitations allow a second operator to reproduce the experiment |

If AC-01 or AC-02 fails, publish the measured minimum and bottleneck, narrow the supported profile or revise the target explicitly. Never label an unmeasured profile supported.

## 9. Delivery and rollback

Proceed through the gates in [implementation plan](../docs/IMPLEMENTATION.md). Initially validate on one disposable host with supplied media. Release experimental profiles separately from qualified profiles. Preserve prior immutable bases until no overlays reference them. Rebuild the lab rather than rolling back a live directory unsafely. Each operation journal records the previous intended state, observed result, and compensating actions or manual recovery instructions. A successful guest mutation may not be reversible; label and confirm it before execution.

## 10. Upstream references

- [Windows Server hardware requirements](https://learn.microsoft.com/en-us/windows-server/get-started/hardware-requirements)
- [Safely virtualising AD DS](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/introduction-to-active-directory-domain-services-ad-ds-virtualization-level-100)
- [Virtual DC deployment and configuration](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/get-started/virtual-dc/virtualized-domain-controller-deployment-and-configuration)
- [QEMU disk image utility](https://www.qemu.org/docs/master/tools/qemu-img.html)
