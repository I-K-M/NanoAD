# N13 — first native optional modules

Status: experimental scripts and comparison tooling; no real guest run yet. Parent: [N13](../../../tickets/001-nanoad/N13-first-real-module.md).

1. Complete the reference host/media/base and native DC gates N01–N04. Record provider version, Windows edition/build/patch, official image provenance, base SHA-256, unique lab/guest/VM/medium IDs, exact network/attachments and actual host headroom. Keep full reference scratch separate from the installed budget. No unrelated VM, route, host mount or external peer.
2. On the native DC, capture baseline health and host/guest memory, commit, disk allocation, process/CPU and peak observations using [NanoBench](../../../benchmarks/protocol/README.md). Explicitly create the [directory fixture](../../../modules/directory-fixtures/README.md), exercise native ACL checks separately as documented in N03, verify the property was restored and capture the read-only fixture inventory. No extra guest is created; measure any marginal resource cost instead of calling it zero.
3. Prepare a separate generalised child and follow [member-server](../../../modules/member-server/README.md). Verify unique identity, exact provider parent/child linkage and unchanged sealed base hash. Verify clean native domain join after restart, DNS, secure channel and member Kerberos LDAP identity. Record all failures, no retry of an ambiguous join or existing account reuse.
4. With DC still running, obtain passing member JSON, request graceful shutdown manually from the local guest console (or a separately qualified provider path), verify powered off, no remaining provider process attributable to the guest, measured host RAM/commit and scratch release, and unchanged retained overlay identity. No saved state, force stop or disk deletion. Start that same guest only after fresh admission and complete isolation checks. Obtain a second passing member report. Repeat analogous fixture inventory on a clean core restart only when dependants are stopped and approved. Never restore a live DC snapshot.
5. Compare each before/after report from local trusted evidence (UTF-8 JSON, no credentials, do not commit):
   
   ```powershell
   . .\tests\integration\modules\Compare-NanoADModuleRestart.ps1
   $before = Read-NanoADModuleReport -Path '.\evidence\member-before.json'
   $after = Read-NanoADModuleReport -Path '.\evidence\member-after.json'
   Compare-NanoADModuleEvidence -Before $before -After $after | ConvertTo-Json -Depth 5
   ```

   Repeat with fixture reports. The comparison checks a distinct later boot, stable synthetic domain/object IDs, exact required passing checks and consistent lab identity. It is not proof of provenance, isolation, physical release, a successful switch or qualification; it accepts operator-controlled reports and does not sign them. Preserve original logs and host observations independently.
6. Verify the complete N03 native fidelity suite, compare to the reference under the same build/patch and measurement method. Actual NanoSwitch/VirtualBox end-to-end switch remains blocked until a real qualified backend, host-wide lock and full reconciler exist. Record the result as pending, never simulate a real execution claim.

CI runs PowerShell 5.1 and 7 parsing and pure identity/evidence tests; no domain installation, join, credentials, guest queries or hypervisor. Zig CI remains mandatory. Required independent review and real-host benchmarks remain open. Rollback: revert code; no automatic guest deletion, domain unjoin, fixture removal or state reset.
