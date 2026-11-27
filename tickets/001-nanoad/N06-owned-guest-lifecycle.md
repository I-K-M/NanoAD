# N06 — owned guest lifecycle

Status: pending

Parent: [NAN-001](../../specs/001-nanoad.md), [NAN-002](../../specs/002-resource-research.md), [NAN-003](../../specs/003-module-lifecycle.md)

## Outcome

Create/start/observe/cleanly stop one owned DC using provider adapter.

## Dependencies

N04, N05.

## Allowed boundary

src/provider/; src/lifecycle/core/; tests/provider/. Changes outside this boundary require a reviewed ticket update.

## Acceptance criteria

Fake + VirtualBox capability mapping, stable owned UUID, readiness timeout, network isolation, refusal to mutate unknown VM, graceful stop.

## Required checks and evidence

Fake contract tests plus real disposable DC start/stop and isolation smoke; no forced shutdown. Include exact commands, environment, pass/fail results, relevant measurements and skipped checks. Obtain an independent review against the parent specification.

## Exclusions

No additional provider or topology.

## Rollback

Revert the scoped code/documentation commit. For lab mutations, follow the operation journal and ownership checks; retain original image/state until verified, and rebuild only with explicit consent. Never revert a live domain controller indiscriminately.
