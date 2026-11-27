# Member server — experimental native module

Not installed or activated by default. The member is a separate genuine Server Core guest, joined to the exact synthetic NanoAD domain using supported Windows APIs. No role, Guest Additions, third-party agent or additional service is installed by the join script. A single member-server per lab is supported by this reference procedure (192.0.2.20/24).

## Prerequisites and manual setup

Complete the N01–N04 reference gates and keep the core DC running and healthy. Independently verify actual host RAM, commit, disk and peak headroom for both guests; do not use the manifest's 1536 MiB target as a qualified bound. If an 8 GiB host cannot admit the reference workload, use a suitable qualification host; do not overcommit or weaken Windows. Use a new independently generalised child of the sealed unpromoted base, not a DC clone. Verify the parent hash, unique VM and overlay IDs, stable non-resetting differencing disk and complete provider inventory. Use NanoDisk's plan and postcondition contract; native creation is not connected yet. Do not implicitly substitute a full clone; an explicitly recorded scratch reference clone is not a claimed 24 GB profile.

Use one NIC on the same uniquely named internal network as the DC. No NAT, bridge, host-only attachment, external peer, shared folders, clipboard, drag-and-drop, forwarding or host device passthrough. The provider checks are mandatory and independent of guest checks. Create a new guest UUID and retain it with the lab UUID and observed VM/medium identities. Transfer the reviewed scripts on read-only media (preserve provisioning/windows/ad-core and provisioning/windows/member). Use the local console, Windows PowerShell 5.1, lab-only credentials and a correctly set clock.

Derive the intended name using Common.ps1. Rename only the disposable member and reboot; configure the sole NIC with static 192.0.2.20/24, DNS 192.0.2.10 only, no default gateway or routed next hop, no additional DNS. Do not change the DC. On the DC, independently check that the proposed computer account and name are unused and that the join account is authorised in this synthetic domain. The guest also verifies account absence over explicitly signed/sealed Kerberos LDAP with the prompted join credential. No reuse override or automatic retry; exclusive lab administration is required (the check is not an atomic AD reservation). Restrict the marker directory ACL to trusted guest administrators and SYSTEM.

From the member console:

```powershell
. X:\provisioning\windows\member\Common.ps1
$labId = [Guid]'<retained lab UUID>'
$guestId = [Guid]'<distinct member guest UUID>'
Get-NanoADMemberIdentity -LabId $labId -GuestId $guestId

X:\provisioning\windows\member\Join-NanoADMember.ps1 -LabId $labId -GuestId $guestId -IsolationConfirmed
X:\provisioning\windows\member\Join-NanoADMember.ps1 -LabId $labId -GuestId $guestId -JoinUser '<lab-only delegated username>' -IsolationConfirmed -Join -Confirm
```

The first join-script call does not create files or change the guest/domain. The second prompts for credentials and requires an explicit join. It flushes a create-new local intent marker before the native Add-Computer request. No password on the command line, no insecure join, no forced restart, no account reuse bypass. The pre-join explicit Kerberos check may be unavailable on some standalone-client configurations; that is a refusal and a real-host compatibility gate, not permission to fall back to weaker authentication. If uncertain, keep the marker and inspect native join logs; no automatic reset or rejoin. Manually reboot after a successful request.

```powershell
X:\provisioning\windows\member\Test-NanoADMember.ps1 -LabId $labId -GuestId $guestId -IsolationConfirmed
```

Run elevated as a lab domain user after reboot. The guest verifies identity/marker, expected DNS A/SRV answers, secure channel without Repair, native Netlogon/workstation services, signed/sealed Kerberos LDAP RootDSE and unique computer/domain GUIDs. This exercises a real member-to-DC authentication path when run on the real guests, but is not a complete Kerberos/NTLM or GPO qualification. Guest reports do not prove provider isolation or physical memory release. Capture JSON to a local evidence file outside Git; preserve the same disk and repeat after clean shutdown/restart. Use the integration checklist for host evidence and comparison.

References: [Add-Computer](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/add-computer?view=powershell-5.1), [Test-ComputerSecureChannel](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/test-computersecurechannel?view=powershell-5.1).

No NanoSwitch real backend, image creation, domain unjoin, automatic shutdown/restart, snapshot revert or resource deletion is exposed by this module. Real qualification remains pending.
