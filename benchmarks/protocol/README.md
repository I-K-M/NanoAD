# Reference measurement protocol

Parent: [NAN-002](../../specs/002-resource-research.md).

## Host inventory

Run [probe-windows.ps1](probe-windows.ps1) against the intended lab and build volumes before any VM is created. Retain the sanitised output locally. It reports physical RAM and available RAM, volume capacity and caller-available space, filesystem, OS version, virtualisation hints, and provider executable metadata. Null is unknown. The script does not test a running provider, isolation, clone support or Windows licence validity.

## Required run phases

| Phase | Required evidence |
| --- | --- |
| Host baseline | No NanoAD VM running; record other hypervisor services and physical resources |
| Build | Peak scratch, build RAM and CPU; image provenance and digest |
| Core idle | Three cold starts; 30-minute idle per candidate |
| Core workload | 30-minute fixed native fidelity workload, fixed seed |
| Shutdown | Confirm provider reports stopped; record residual host RAM and retained physical bytes |
| Optional switch | Separate qualification; stop-before-start and peak/steady-state measurements |

For each phase use a stable 5-second sample interval by default, record sampler overhead, timestamps, git commit, exact guest build and provider. Record physical allocations, not only nominal virtual disk capacity. Preserve failures. The target does not include an unreported second copy of a base image or cache.

## Completion

Real native tests and a Windows host are required. This protocol is prepared, not executed. No measured savings or supported allocation have been established.
