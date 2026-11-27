# N10 — module registry

Status: pending

Parent: [NAN-001](../../specs/001-nanoad.md), [NAN-002](../../specs/002-resource-research.md), [NAN-003](../../specs/003-module-lifecycle.md)

## Outcome

Validate versioned manifests and discover optional modules without activating them.

## Dependencies

N09.

## Allowed boundary

schemas/; modules/; src/modules/; tests/modules/. Changes outside this boundary require a reviewed ticket update.

## Acceptance criteria

Reject invalid/oversized schemas, duplicate IDs, unknown provisioners, cycles, traversal; core only by default; unknown costs retained as unknown.

## Required checks and evidence

Schema tests, registry read-only test and fuzz/bounded-input checks. Include exact commands, environment, pass/fail results, relevant measurements and skipped checks. Obtain an independent review against the parent specification.

## Exclusions

No arbitrary scripts, remote plugin download, or Lua.

## Rollback

Revert the scoped code/documentation commit. For lab mutations, follow the operation journal and ownership checks; retain original image/state until verified, and rebuild only with explicit consent. Never revert a live domain controller indiscriminately.
