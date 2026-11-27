# N12a proof pack

- Parent: [N12](../../tickets/001-nanoad/N12-switch-executor.md), [NAN-003](../../specs/003-module-lifecycle.md). Internal session executor composes N11 exact approval, N09 durable per-step transitions and N08/N07 fresh admission. Full inventory and immutable identity checks before/after each step.
- Decisions: no automatic rollback/resume, no implicit approval, no projected host credit, no applied fixtures or absent-module creation, no real mutation backend. One session holds lab lock plus trusted host-lock attestation. Partial completed steps are durable; full switch progress/hash is in-memory only. No journal schema migration.
- Checks: hosted Windows/Linux formatting, unit tests, ReleaseSafe and CLI smoke; inspect actual CI before merge. Fake failure matrix and actual local journal replay, not real VM or hardware power-loss testing.
- Boundary additions: read-only governor checkCurrent wrapper, test import, ticket and trace. No third-party runtime dependency, VM/host changes, production deployment or external environment changes.
- Remaining: actual host-wide lock implementation, inventory digest/ownership attestor, real provider bounded execution, native readiness and release qualification, optional CLI interaction, independent review and real-host smoke. Rollback: revert scoped code, keep all existing state/media.
