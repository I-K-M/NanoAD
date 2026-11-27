# Engineering tickets

All tickets are pending. Follow the [implementation plan](../../docs/IMPLEMENTATION.md) and [system specification](../../specs/001-nanoad.md). Each ticket requires a dedicated branch, deterministic checks, independent review and evidence. Do not mark a real-provider ticket complete using mocks alone.

| ID | Outcome | Dependencies |
| --- | --- | --- |
| [N01](N01-reference-host.md) | Record the reference host, licensed media plan and provider capabilities before creating guests. | none |
| [N02](N02-base-image.md) | Build a reproducible generalised Server Core base from verified official media. | N01 |
| [N03](N03-native-dc-reference.md) | Provision a disposable single-domain DC and establish genuine behaviour reference. | N02 |
| [N04](N04-minimum-footprint.md) | Determine smallest validated core envelope before expanding the orchestrator. | N03 |
| [N05](N05-zig-cli-doctor.md) | Create pinned Zig project and read-only doctor command. | N01 |
| [N06](N06-owned-guest-lifecycle.md) | Create/start/observe/cleanly stop one owned DC using provider adapter. | N04, N05 |
| [N07](N07-physical-storage.md) | Implement immutable image inventory, differencing disk and physical allocation accounting. | N06 |
| [N08](N08-resource-admission.md) | Refuse operations that cannot fit conservative host and lab budgets. | N06 |
| [N09](N09-state-recovery.md) | Persist atomic lab state and journal mutations with recovery. | N07, N08 |
| [N10](N10-module-registry.md) | Validate versioned manifests and discover optional modules without activating them. | N09 |
| [N11](N11-switch-planner.md) | Produce deterministic feasible activation and deactivation plans. | N10 |
| [N12](N12-switch-executor.md) | Run an approved stop-before-start transaction safely. | N11 |
| [N13](N13-first-real-module.md) | Qualify a small directory fixture and an optional member server independently. | N12 |
| [N14](N14-isolation-and-safety.md) | Demonstrate isolation and hard failure boundaries on reference provider. | N12 |
| [N15](N15-independent-qualification.md) | Reproduce targets and publish benchmark and fidelity evidence. | N13, N14 |
| [N16](N16-reference-release.md) | Package first qualified or explicitly experimental reference release. | N15 |
| [N17](N17-kvm-provider.md) | Add Linux KVM/QEMU/libvirt provider behind same tested interface. | N16 |
| [N18](N18-additional-modules.md) | Create a repeatable qualification template and select one next native role/topology. | N16 |
