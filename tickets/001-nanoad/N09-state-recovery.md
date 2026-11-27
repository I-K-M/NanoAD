# N09 — state recovery

Status: pending

Parent: [NAN-001](../../specs/001-nanoad.md), [NAN-002](../../specs/002-resource-research.md), [NAN-003](../../specs/003-module-lifecycle.md)

## Outcome

Persist atomic lab state and journal mutations with recovery.

## Dependencies

N07, N08.

## Allowed boundary

src/state/; src/lifecycle/transaction/; tests/recovery/. Changes outside this boundary require a reviewed ticket update.

## Acceptance criteria

Exclusive lock; desired versus observed; persisted intent; ownership reconciliation; safe compensation; explicit manual recovery for irreversible changes.

## Required checks and evidence

Fault injection at each step, concurrent writers, stale state and partial guest failure; verify no orphan deletion. Include exact commands, environment, pass/fail results, relevant measurements and skipped checks. Obtain an independent review against the parent specification.

## Exclusions

No external state service, no forced cleanup.

## Rollback

Revert the scoped code/documentation commit. For lab mutations, follow the operation journal and ownership checks; retain original image/state until verified, and rebuild only with explicit consent. Never revert a live domain controller indiscriminately.
