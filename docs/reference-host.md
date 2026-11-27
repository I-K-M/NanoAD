# N01 — Reference host and capability record

Status: **evidence collection prepared; host qualification pending**.

No physical reference host, licensed ISO or verified provider capability has been inspected by this repository bootstrap. Do not interpret the configuration below as a measured result.

## Reference contract

| Property | Planned / observed |
| --- | --- |
| Architecture | x86-64 required |
| Host | Windows 10/11 x86-64 initially; exact edition and build pending |
| Physical RAM | Target 8 GiB; actual installed and available pending |
| Lab storage | Installed physical allocation target 24,000,000,000 bytes |
| Temporary image build space | Separate admission and measurement; actual pending |
| Hypervisor | VirtualBox; installed version, conflicts and capabilities pending |
| Guest | Server 2022 Core provisional reference; official media, exact build, licence and digest pending |
| CPU virtualisation | Firmware support, hypervisor availability and provider start test pending |
| Zig | Provisional exact bootstrap pin 0.14.1; upgrade before qualification if required by maintenance/security review |

The exact Zig version is an intentionally conservative bootstrap choice for the initial standard-library API. It is not claimed to be the newest stable release. Check the official release index and toolchain security/support status before qualifying a release. Use the SHA-256 values in the compiler validation instructions on the N05 branch.

## Collect host facts (read-only)

From the repository root on the intended Windows host, use Windows PowerShell:

```powershell
.\benchmarks\protocol\probe-windows.ps1 -LabPath .
```

The script writes a JSON object to standard output. It creates no VM, changes no host settings and installs nothing. Run it in the existing directory on the intended lab volume; use a different existing directory for temporary build space if necessary. Values are in bytes, or null when the query cannot be established. Provider file metadata is only a discovery hint, not evidence that a provider can start a VM. No computer name, username, product key, machine serial number, raw host IP or absolute paths are included.

To record official media, optionally pass an existing local ISO and a SHA-256 digest obtained independently from a trusted source:

```powershell
.\benchmarks\protocol\probe-windows.ps1 -LabPath . -MediaPath 'D:\media\server.iso' -ExpectedSha256 '<official-digest>'
```

Hashing reads the entire ISO and may take time. A matching digest is integrity evidence only; the operator must separately verify the source and licence. Do not publish media or proprietary images.

## Evidence still needed

1. Capture and review the read-only probe output.
2. Confirm licensed official media, edition, patch level, expected digest and sufficient scratch.
3. Record installed provider version and whether firmware virtualisation, competing hypervisors or host policy affect execution. Do not disable Windows security features automatically.
4. Qualify private-network isolation, clean stop, unique VM identities and differencing disk support in a separately authorised disposable VM (N02/N06).
5. Record actual physical allocation and host headroom. Complete N01 only when the host facts and media plan are reviewed; do not claim readiness from a file's existence.

See [benchmark protocol](../benchmarks/protocol/README.md). N02 cannot start until the host, media and scratch are available. N05 may be prepared independently against this provisional contract; its real-host evidence is pending N01 completion.
