# Directory fixtures — experimental native module

Optional, persistent directory changes on the existing core DC; no additional VM. Never run during minimal core initialisation. The existing N03 reference fixture is deliberately reused, rather than duplicating credentials or ACL creation logic.

From the verified, isolated local DC console, use Windows PowerShell 5.1, the same lab UUID, and the existing [reference procedure](../../provisioning/windows/ad-core/README.md). Run New-NanoADReferenceFixture.ps1 first without Create, then explicitly with Create, IsolationConfirmed and Confirm after checking the proposed scope. Use unique lab-only passwords. The three synthetic accounts are non-administrators; one disabled target has property-specific explicit access rules. Partial creation is not retried or cleaned up automatically.

Run the separate read-only inventory check, preserving the repository-relative layout on script media:

```powershell
X:\modules\directory-fixtures\Test-NanoADFixtureInventory.ps1 -LabId $labId -IsolationConfirmed
```

It verifies the expected accounts, enabled/disabled status, original target property, direct group membership and intended explicit property ACEs; reports stable domain, OU and object GUIDs and boot/capture times. This is not effective-access verification; the existing explicit N03 exercise verifies actual native ACL behaviour and restoration. Negative authentication must remain a separately approved exercise after checking lockout headroom. No secrets in reports.

Repeat inventory after a planned clean restart of the same core disk, compare evidence with the integration helper, and check native core health and resource deltas independently. Persistent fixtures cannot be stopped, archived as a running workload or silently reverted. An explicit rebuild of a disposable isolated reference is the recovery option; do not reset a live DC snapshot. No measured marginal RAM or disk saving is claimed.
