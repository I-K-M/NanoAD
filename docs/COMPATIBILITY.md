# NanoAD compatibility and qualification

Status: experimental source code; no qualified native lab, no supported low-memory profile and no released binary.

| Platform/profile | Implementation evidence | Qualification |
| --- | --- | --- |
| Windows x86-64 / VirtualBox 7.1.x | Hosted Zig tests; read-only typed provider transport; Windows PowerShell scripts | Native provider, media, isolation and lifecycle pending |
| Linux x86-64 | Hosted Zig build and unit tests, metadata CLI | KVM provider deferred; not a lab target |
| Windows Server 2022 Core | Provisional reference, native provisioning scripts | Official media, edition/build/patch and real AD tests pending |
| Server 2019/2025 Core | Proposed comparison candidates | Not tested |
| 8 GiB host / 24 GB installed | Research targets only | Not established |
| 4 GiB guest reference and lower RAM tiers | Planned benchmark sweep | No measured minimum |

The Windows host RAM target is installed RAM, not necessarily OS-visible RAM. Record both in raw evidence. The storage target is 24,000,000,000 physical bytes including retained lab artefacts, not virtual disk size, archive size or a file-data estimate. Build peak and all-in allocation (including ISO, tools and hypervisor) are separate results. No Windows images are distributed.

See [qualification procedure](../tests/integration/qualification/README.md), [audit](../tests/integration/qualification/AUDIT.md), and [benchmark results](../benchmarks/results/README.md). A hosted CI success does not demonstrate an AD join, a boot, resource headroom or a safe real switch. Record all failed/blocked runs; do not extrapolate performance from fixtures. A second operator must reproduce the run and review raw evidence, licences, media, provider configuration and current toolchain/OS security support before qualification. Release approval is separate.
