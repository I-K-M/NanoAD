# N03 — Native single-controller reference

Status: **implementation draft; no real guest execution yet**. Complete [N01](../../../docs/reference-host.md) and [N02](../../../images/windows-core/README.md) first. This is a genuine Microsoft domain, not a Samba or protocol emulator. No optional role or intentionally weakened configuration is enabled.

## 1. Prepare an independent reference guest

Use a separate disposable copy of the sealed, unpromoted N02 image, never boot or modify the sealed base. Until N07 implements a verified differencing chain, a temporary full clone on suitable scratch storage is acceptable for the reference experiment; record its full cost, never include it in a claimed 24 GB installed profile. Record the provider UUID, base digest, guest build and patch level, and allocate a generous reference memory envelope (4 GiB DC; actual host headroom must permit it).

Use VirtualBox **Internal Network**, named uniquely per lab (for example, nanoad- followed by the complete lab UUID). Only one NIC, no NAT, bridge, host-only network, forwarding, shared folders, clipboard, drag-and-drop or device passthrough. Do not attach a physical network. Verify the provider configuration independently before boot, and again after configuration; the guest guard cannot establish that boundary. Operate through the local VirtualBox console. Transfer scripts using read-only media.

Generate and retain a lab UUID on the operator's host. The same UUID must be used throughout the build and tests. The lab namespace is reserved for testing; do not substitute any existing domain.

## 2. Configure the guest identity and network

From the elevated local guest PowerShell console, dot-source Common.ps1 from the read-only script media and derive the identity:

```powershell
. X:\ad-core\Common.ps1
$labId = [Guid]'<your retained lab UUID>'
$id = Get-NanoADIdentity -LabId $labId
$id
```

Rename the new standalone guest to the displayed ComputerName and restart it (confirm that it is the disposable guest). Set its sole internal NIC to 192.0.2.10/24, DHCP disabled, no IPv4 or IPv6 default gateway, and preferred IPv4 DNS 192.0.2.10. No external DNS; IPv6 DNS, if present, must be loopback only. Leave IPv6 itself and native security services intact. Set the clock correctly. Use the same lab UUID after reboot. The scripts refuse a non-Core, non-VirtualBox, mismatched, already joined or routed guest. The fixed TEST-NET address is reused only across distinct isolated internal networks.

## 3. Plan and promote

```powershell
X:\ad-core\New-NanoADDomain.ps1 -LabId $labId
X:\ad-core\New-NanoADDomain.ps1 -LabId $labId -Provision -IsolationConfirmed -Confirm
```

First call is read-only. Second requires explicit operator confirmation of the provider boundary and authorisation of the irreversible guest-local promotion and automatic reboot. AD DS management tools and DNS are the only role prerequisites added. Native forest prerequisites run before installation; supply a unique DSRM password through Microsoft's secure prompts, not command-line strings. Record it securely outside the repository. A marker is recorded locally before promotion. If promotion fails or is interrupted, inspect native logs and the marker; do not automatically rerun or reset a partially promoted DC. Rebuild a disposable clone if necessary.

The script is intentionally not a host-side provisioning mechanism and does not perform networking or host policy modifications. Never run it against an existing domain.

## 4. Verify the actual directory

After the reboot, log in to the new synthetic domain administrator locally and wait for AD DS, DNS, SYSVOL, and ADWS to become ready.

```powershell
X:\ad-core\Test-NanoADCore.ps1 -LabId $labId
```

The read-only suite verifies native services, expected single-domain/forest identity, SRV DNS records, signed/sealed LDAP RootDSE bind with explicit Kerberos, SYSVOL/NETLOGON, GPO directory/files, native password policy, and access to Windows Security logs. It reports JSON, exit 6 on a failed predicate. A failed identity/network guard terminates without claiming health. No LDAP simple bind or anonymous fallback. The test runs on the DC itself; it does not establish remote client authentication, service ticket issuance independent of cache, NTLM behaviour or event correlation.

## 5. Reference fixture and authentication tests

The separate fixture scripts are explicit, temporary reference experiments. Do not run them during normal minimal startup. They create synthetic non-administrator accounts and a disabled test object in a dedicated OU, set property-specific access for the test accounts and check native LDAP allow/deny behaviour. No account is added to a privileged group. Passwords are supplied via protected local prompts. Run only on this identified reference DC.

```powershell
X:\ad-core\New-NanoADReferenceFixture.ps1 -LabId $labId -Create -IsolationConfirmed -Confirm
X:\ad-core\Test-NanoADReferenceFixture.ps1 -LabId $labId -Exercise -Confirm
```

The exercise restores the known fixture description on exit, attempts only one deliberately incorrect authentication against the synthetic test user if the lockout policy allows it, and observes NTLM using explicit authentication rather than changing the policy. An NTLM refusal is an observation, not proof of a specific policy cause. Test event correlation separately from aggregate audit log counts. Re-run the core suite after a clean shutdown/restart and compare results with the same lab identity and a changed boot timestamp.

## Gate and rollback

No measured native fidelity claim is possible until the reference is exercised, negative tests and audit events are reviewed, restart comparison passes, and provider isolation is independently verified. Store only sanitised evidence. Never revert a live domain controller indiscriminately. The reference environment is disposable: recover or rebuild the separate clone, preserving the immutable unpromoted base.

References: [Microsoft forest installation prerequisites](https://learn.microsoft.com/en-us/powershell/module/addsdeployment/test-addsforestinstallation?view=windowsserver2022-ps), [Install-ADDSForest](https://learn.microsoft.com/en-us/powershell/module/addsdeployment/install-addsforest), [LDAP connection signing](https://learn.microsoft.com/en-us/dotnet/api/system.directoryservices.protocols.ldapsessionoptions.signing).
