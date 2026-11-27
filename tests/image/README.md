# N02 validation checklist

This branch is not a built Windows image. No VirtualBox guest has been created here.

## Before execution

- Complete N01 with actual hardware, licensed media and trusted SHA-256.
- Parse both PowerShell scripts without running them (PowerShell 5.1 and 7). Review the script and provider command syntax against the installed version.
- Run the host plan with a wrong digest, insufficient scratch and an invalid/reparse path; it must not create any guest or journal. Run a correct plan twice and compare the directory/provider inventory before and after.
- Invoke preparation with explicit confirmation on a disposable host, then check the journal, UUID, dynamically allocated disk and offline VM settings. Never start a failed/partial preparation.
- Test on a dedicated build directory, not a directory holding existing VMs. A failed command must leave previous resources intact and produce a recovery record.

## Guest

- Confirm genuine Core edition and standalone state. Reject a domain member and a non-Core guest without changes.
- Inventory clean Core; run supported cleanup as a distinct experiment; capture guest logical use and host physical allocation before/after.
- Confirm servicing health and patch provenance; only generalise an unjoined/unpromoted guest.
- Verify Sysprep and powered-off state, detach media and seal/hash the VDI; do not restart the sealed base.
- Record build peak, actual image bytes, CPU/RAM and failed runs. No claim of native AD fidelity until N03.

The final acceptance test is an actual reproducible build and evidence record. No mocks or syntax checks substitute for it.
