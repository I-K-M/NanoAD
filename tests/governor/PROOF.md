# N08a proof pack

Parent: [N08](../../tickets/001-nanoad/N08-resource-admission.md). See [resource and concurrency contract](README.md).

- Added strict two-dimensional memory bounds, a bounded ledger with revisioned reservations, fresh snapshot and pre-launch rechecks, conservative credits, disk admission through NanoDisk, and native Windows system/process/volume measurements.
- Static review: avoid a test-helper name collision with the recheck parameter; reject contradictory disk inventory totals; add exact-limit and one-byte-shortfall tests plus malformed/duplicate reservation refusal.
- Checks: pinned Zig Windows/Linux CI with formatting, unit tests, ReleaseSafe build and CLI smoke tests. Results must be inspected on the pull request before merge. Native tests use the CI host/current process only; synthetic reservation tests do not launch a VM.
- No change to the public CLI, no extra runtime dependencies, no host/VM mutation or migration. Test imports and trace are supporting boundary changes.
- Pending: real provider overhead measurement, validated scope and ownership reconciliation, N09 durable cross-process lock/reservations, integrated VM admission and independent review. No resource savings or supported host profile is claimed.
- Rollback: revert the scoped commits. There are no durable reservations or lab artefacts to migrate.
