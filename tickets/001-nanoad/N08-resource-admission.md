# N08 — resource admission

Status: pending

Parent: [NAN-001](../../specs/001-nanoad.md), [NAN-002](../../specs/002-resource-research.md), [NAN-003](../../specs/003-module-lifecycle.md)

## Outcome

Refuse operations that cannot fit conservative host and lab budgets.

## Dependencies

N06.

## Allowed boundary

src/governor/; src/host/metrics/; tests/governor/. Changes outside this boundary require a reviewed ticket update.

## Acceptance criteria

Checked byte arithmetic; actual available/commit, guest peaks, provider overhead and reserve; unknown metrics fail strict; installed and scratch disk distinct.

## Required checks and evidence

Boundary, overflow, unknown-cost, host drift and concurrent start tests; measure provider overhead. Include exact commands, environment, pass/fail results, relevant measurements and skipped checks. Obtain an independent review against the parent specification.

## Exclusions

No overcommit or reliance on paging.

## Rollback

Revert the scoped code/documentation commit. For lab mutations, follow the operation journal and ownership checks; retain original image/state until verified, and rebuild only with explicit consent. Never revert a live domain controller indiscriminately.
