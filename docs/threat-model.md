# NanoAD threat model — N14 experimental safety boundary

## Assets and scope

The host, other host workloads, private files and secrets, licensed base, persistent domain/overlays, and journal/resource reservations are protected assets. Guests are disposable and potentially hostile. The reference provider is VirtualBox on Windows x86-64; one synthetic domain and one uniquely named internal network per lab. No external targets. No untrusted runtime plugins, remote access or intentionally exposed production endpoints.

## Trust and failure model

The reference operator, signed/verified provider installation and DLLs, OS, exclusive local administration, restrictive lab-root and provider-configuration ACLs are trusted prerequisites. A hostile host administrator, compromised hypervisor, malicious kernel or other user/configuration that cannot be enumerated is outside the demonstrated boundary. A named mutex serialises cooperating NanoAD sessions; it does not prevent VirtualBox Manager, another user, a guest escape or hostile named-object squatting. Refuse access denial, missing evidence and changed inventory; never relax these prerequisites. Always reconcile after obtaining the mutex (an abandoned object may vanish when its last handle closes). No approval hash or mutex is an authorisation credential.

| Threat | Control | Current evidence |
| --- | --- | --- |
| Concurrent lab starts | Fixed Global\\NanoAD.ResourceAdmission.v1 Windows mutex, non-blocking; acquire before lab Store, release in reverse | Native test and process harness; not wired to real execution |
| Bridge/NAT/host-only/foreign peer | Exact internal NIC identity, explicit full peer/route/DNS evidence, no foreign registered VM even stopped | Typed registered/running queries, bounded parser and pure N14 validator; actual full enumeration across provider users/configurations not implemented |
| Host exposure through integrations | Require zero shared folders, forwards, USB/controllers/filters, passthrough, serial/parallel, snapshots, other media/attachments; disabled clipboard, drag/drop, remote display | Model checks; missing fields refuse |
| Wrong VM or VDI, alias/hardlink | Match durable ownership, exact parent, canonical paths, base digest and distinct file IDs; native read-only path observations | Pure tests and Windows path tests; no end-to-end media collector or enforced immutable handle lifetime |
| Path traversal/device namespace | Bounded conventional fixed-drive paths, reject ADS, dot segments, device names, aliases/reparse points and multi-link files | Lexical and native tests; real NTFS ACLs and reparse experiments remain |
| Leaked diagnostics | Closed refusal vocabulary, discard names, no raw stderr or command strings in safety report | Unit tests; existing scripts/manual evidence still require separate secret review |
| Interrupted or uncertain mutation | N09 durable reservation and dispatch, no retry or deletion, recovery workflow | Existing process interruption tests; real hardware/provider qualification pending |

## Operational policy

Use a dedicated exclusive provider configuration and account, not a shared VirtualBox inventory. Enumerate registered/running sets before/after collection. Enumeration is account/config scoped; empty output is not proof of no other peers or host-wide scope. Explicitly reconcile all media and attachments including stale registration, inactive NICs and foreign networks. Do not issue a complete isolation attestation from model compatibility, a provider marker, a guest report or user confirmation. Guest route/DNS verification is separate from provider network attachment and cannot be inferred for a powered-off guest. Independently prove trusted host paths and access controls, non-resetting overlays and sealed parent. Inspect paths by native handles, reject links and resolved aliases; this is a point observation, not a lasting TOCTOU defence. A native collector, complete scoped peer/attachment evidence, actual qualified guest health and resource release, and independent review remain release gates.

N14 does not expose real mutations or public commands. Native transport continues refusing start/stop. No network/host policy changes or dependencies introduced. Host memory reservations remain conservative and do not rely on predicted release.
