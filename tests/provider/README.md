# N06a — Provider contract and lifecycle preparation

Status: implementation slice; N06 remains open. The actual host and native AD research gates N01–N04 are not yet qualified. This code is not a real-provider execution path.

## Boundary and design

The Zig provider layer defines a canonical UUID, expected lab/guest/VM identity, bounded typed VirtualBox requests, machine-readable output parsing and a generic lifecycle coordinator. The adapter recognises 7.1.x version strings, requests both ownership markers and validates the provider UUID. Unknown or duplicate required observations fail closed. A partial network observation can never set isolation_verified. Only a complete provider-side attestation can eventually enable real start.

The pure lifecycle requires explicit approval, a verified local ownership record, persisted intent and (for start) resource admission. It separates VM-running from native guest readiness. Graceful stop sends the ACPI power-button request exactly once; a timeout returns control to recovery instead of poweroff, reset or deletion. It permits a clean stop of a known running VM despite isolation drift. The observation loop is count-bounded; a real transport and health check must separately implement wall-clock deadlines. After an ambiguous command failure, recovery is required; no retry of a mutating command.

No shell string, subprocess runner, real VM creation, provider mutation CLI, ownership-file adoption, disk clone or actual health transport is implemented in this slice. No code is imported into the production CLI; build.zig's tests gain an explicit provider test root. Future transport must execute only a trusted absolute VBoxManage path, enforce output and time limits, distinguish stdout/stderr/exit, and avoid launching untrusted executables. No unconditional reliance on version or metadata as proof of ownership. The marker keys are planned; N02's existing base preparation is not automatically adopted.

The fixture is synthetic, not captured real VirtualBox 7.1 output. Confirm exact fields, supported NIC count, USB/host passthrough, shared folders, VRDE, forwarding, storage attachments and network membership using a disposable real VM before completing the adapter. Do not relax isolation on parse mismatch. N08/N09 must implement admission and durable journal before wiring real start/stop; creation is separately gated by an owned image and safe recovery contract.

## Validation

Run `zig fmt --check build.zig src`, `zig build test`, `zig build -Doptimize=ReleaseSafe` on both Windows and Linux. Fake transport tests exercise request and response paths; fake lifecycle tests exercise authorisation, isolation, start/stop and timeout. No hypervisor or guest is invoked in these tests.

Real-host smoke, true provider deadlines, full isolation, safe creation and native guest readiness are still required by N06. Revert scoped changes to roll back; no VM state changes were made.
 
Reference: [Oracle VBoxManage 7.1](https://docs.oracle.com/en/virtualization/virtualbox/7.1/user/vboxmanage.html).
