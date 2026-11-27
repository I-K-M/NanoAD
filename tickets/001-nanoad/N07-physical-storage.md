# N07 — physical storage

Status: pending

Parent: [NAN-001](../../specs/001-nanoad.md), [NAN-002](../../specs/002-resource-research.md), [NAN-003](../../specs/003-module-lifecycle.md)

## Outcome

Implement immutable image inventory, differencing disk and physical allocation accounting.

## Dependencies

N06.

## Allowed boundary

src/image/; src/storage/; tests/storage/. Changes outside this boundary require a reviewed ticket update.

## Acceptance criteria

One base with independently provisioned overlays, correct shared accounting or conservative fallback, referenced base cannot be removed, offline reclaim plan and scratch preflight.

## Required checks and evidence

Real provider allocation comparison; fake disk-full, refcount, path escape and interrupted compaction tests. Include exact commands, environment, pass/fail results, relevant measurements and skipped checks. Obtain an independent review against the parent specification.

## Exclusions

No live DC snapshot rollback or unconditional deletion.

## Rollback

Revert the scoped code/documentation commit. For lab mutations, follow the operation journal and ownership checks; retain original image/state until verified, and rebuild only with explicit consent. Never revert a live domain controller indiscriminately.
