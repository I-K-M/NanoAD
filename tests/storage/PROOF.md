# N07a proof pack — 27 November 2026

Ticket: [N07](../../tickets/001-nanoad/N07-physical-storage.md). Specifications: [NAN-001](../../specs/001-nanoad.md), [NAN-002](../../specs/002-resource-research.md).

- Implemented a bounded shared-base catalogue, SHA-256 streaming verification, native Windows file-data observations, strict installed/peak/free-space checks, typed overlay creation and postcondition plans, protected purge eligibility and an interruption-safe compaction state model.
- Static review: separate base compaction refusal from a missing seal; add duplicate-base/pin/attachment tests; validate the future provider-created child's parent, target, format, capacity, digest, allocation and current catalogue before ownership commit.
- The test wiring in src/main.zig is the only supporting change beyond the original N07 boundary; production CLI commands remain unchanged.
- Validation: see [PR #9](https://github.com/I-K-M/NanoAD/pull/9) and its hosted Windows/Linux checks. Real VirtualBox execution, full allocation reconciliation, safe compaction execution and independent review remain pending. The initial N07 CI must be inspected before merge.
- No changes to VMs, host policy, production environment or external data. No migration. Rollback: revert scoped commits. No actual images or benchmarks are claimed.
