# N09a proof pack

Parent: [N09](../../tickets/001-nanoad/N09-state-recovery.md), [NAN-001](../../specs/001-nanoad.md), [NAN-003](../../specs/003-module-lifecycle.md).

- Implemented revisioned state replay, fixed schema ownership/cost records, a checksummed append-only journal, exclusive process lock, durable reservation and dispatch barriers, read-only reconciliation and explicit recovery decisions.
- Static review: compare the observed child/parent medium UUIDs and base hash rather than relying only on an attestation boolean; classify unsafe or incomplete network observations as drift; exercise process exit at intent/dispatch and writer poisoning on unexpected partial data.
- Tests: Windows/Linux Zig formatting, unit tests, separate process lock harness, ReleaseSafe and CLI smoke checks; inspect actual CI before merging. Real local filesystem tests and fake provider observations only. No VM creation, start, stop or deletion.
- Decisions: a single authoritative event journal instead of two independently replaced files; no auto-repair or rotation; one in-flight operation per lab; explicit release evidence; no actual mutation transport integration until full provider and storage qualification. Supporting imports/build wiring and trace extend the ticket boundary narrowly.
- Pending: target host directory ACL/reparse validation, Windows initial directory durability, power-loss testing, host-wide lock across labs, complete provider/media reconciliation, native readiness/release attestation, plan-hash approval, real VM execution and independent review.
- No existing state migration, host policy change, paid resources or external environment changes. Rollback: revert scoped code; do not delete or repair any existing lab journal or VM automatically.
