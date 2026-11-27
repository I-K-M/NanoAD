# N02 — NanoImage, first offline Windows Core build

Status: **implementation draft, not yet exercised on VirtualBox**. Parent: [N02](../../tickets/001-nanoad/N02-base-image.md), [NAN-002](../../specs/002-resource-research.md). N01 host and media qualification remains a prerequisite to execution.

## Design

Start with a genuine Server 2022 Core reference installation, not a modified Windows distribution. The first build uses the official installer interactively so that the operator explicitly selects the licensed Core edition and enters a unique local password. This is an intentionally staged build: unattended installation, immutable image catalogue integration, and automated update handling are deferred until this procedure is qualified. The build VM has no NIC attached, no Guest Additions dependency, no clipboard integration or shared folders, and is never promoted to a domain controller.

The default build envelope is 4 GiB RAM, 2 vCPUs, a dynamically allocated 40 GiB VDI, and 48 GiB of free scratch on the build volume. This is a conservative provisional envelope, **not** a measured runtime requirement. The final installed lab target remains 24 GB. Build on separate storage if needed; no attempt is made to force installation into that target.

## 1. Plan and prepare

On the qualified Windows host, obtain an official ISO and trusted SHA-256 independently. Keep the ISO outside the working directory. Select an existing dedicated local build directory (not a symlink, junction or mounted volume). Verify the installed VirtualBox version and its executable from a trusted source. No installation, network download or host policy change is performed by this script.

```powershell
.\images\windows-core\New-NanoADBase.ps1 `
  -VBoxManage 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe' `
  -IsoPath 'D:\media\server2022.iso' `
  -ExpectedSha256 '<trusted 64-character SHA-256>' `
  -BuildRoot 'D:\nanoad-build'
```

Default operation is plan-only: it verifies the media, local directory and resource hints, prints a JSON plan and writes nothing. Specify `-Prepare -Confirm` to create a uniquely identified, powered-off VM and sparse disk. The script does not boot or install Windows. The preflight is deliberately conservative; it refuses resource shortages and unknown measurements rather than relying on paging. A partial operation leaves its local journal and VM for explicit inspection. No automatic unregister/delete is attempted.

## 2. Install and inspect

Before first boot, inspect the new VM by its recorded UUID using VirtualBox Manager and `VBoxManage showvminfo <UUID> --machinereadable`. Confirm it has **no active network attachment**, no shared folders, no host-device passthrough, disabled clipboard/drag-and-drop, and only the newly created disk and approved installation ISO. If any check fails, do not start the VM.

Start the VM manually through VirtualBox Manager; select Windows Server Core (not Desktop Experience) and the empty virtual disk. Use a new lab-only administrator password. Do not join a domain. Record media hash, exact edition/build, patch status and time. Offline installation is the initial reference; subsequent security update servicing must use separately verified media or an explicitly controlled build-only maintenance network, removed before sealing. A release candidate needs applicable security updates.

Transfer the guest script using a read-only local script ISO or another explicitly reviewed offline mechanism; never use a host shared folder or clipboard as a convenience bypass. Do not place scripts or secrets on the Windows installation media.

```powershell
powershell.exe -NoProfile -File X:\Inspect-NanoADBase.ps1
```

This guest inventory is read-only. It reports Core installation type, unjoined/unpromoted status, logical system volume use, pagefile and feature counts, and the supported DISM component-store analysis. Run in an elevated PowerShell session in the disposable build guest only.

## 3. Optimise one variable at a time

Capture the clean reference before applying optimisation. Use the guest script with `-Cleanup -Confirm` only when the preflight confirms a standalone Core guest. It runs supported DISM component cleanup **without** ResetBase, preserves logs and security services, and does not remove AD dependencies. Record before/after physical VDI allocation from the host; guest logical free space is a separate metric. Do not claim disk savings from guest figures alone.

Do not disable Defender, Windows Update, audit policy, pagefile or core services to manufacture a smaller benchmark. Recheck servicing and native fidelity before adopting any optimisation. DISM cleanup can reduce available rollback data; preserve a pre-cleanup rebuild recipe.

## 4. Generalise and seal

After the Core guest has been inspected, serviced as required and verified to be standalone, run the guest script with `-Generalize -Confirm`. It requests the supported Sysprep generalise/OOBE/shutdown operation. This is irreversible for the running installation and clears guest-specific state, including event logs; capture reference evidence first. Never run this against a DC or joined server. Do not reboot the resulting base. Verify that Sysprep completed and that the guest is powered off, not saved or paused; failure requires inspection/rebuild.

From the host, detach the installation and script media while powered off, record the exact VM UUID and disk UUID, and hash the resulting VDI before any overlay is created. Preserve the sealed base offline; do not boot it again. Store the image, journal and hashes outside Git. The full immutable-base/differencing lifecycle and reference accounting will be implemented in N07 after native fidelity research; manual storage preparation is not a claim of automated image management.

## 5. Evidence and gate

Record actual host resources, build peak, physical allocation (not VDI capacity), image digest, edition, patch state, guest inventory, provider version, inspection of isolation and successful generalisation. N02 is incomplete until the build and evidence are reproduced. Rebuild from the same official media and recipe if an experiment fails. No live AD snapshots or destructive automation.

References: [Microsoft Sysprep generalisation](https://learn.microsoft.com/windows-hardware/manufacture/desktop/sysprep--generalize--a-windows-installation), [Sysprep command options](https://learn.microsoft.com/windows-hardware/manufacture/desktop/sysprep-command-line-options), [VirtualBox documentation](https://www.virtualbox.org/wiki/Documentation).
