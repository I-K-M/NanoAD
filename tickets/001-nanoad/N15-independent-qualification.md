# N15 — independent qualification

Status: pending

Parent: [NAN-001](../../specs/001-nanoad.md), [NAN-002](../../specs/002-resource-research.md), [NAN-003](../../specs/003-module-lifecycle.md)

## Outcome

Reproduce targets and publish benchmark and fidelity evidence.

## Dependencies

N13, N14.

## Allowed boundary

benchmarks/results/; docs/COMPATIBILITY.md; tests/integration/. Changes outside this boundary require a reviewed ticket update.

## Acceptance criteria

Second operator reproduces 8 GiB host run; 24 GB installed metric or explicit target failure; build peak and provider costs recorded; qualified versus experimental profiles separated.

## Required checks and evidence

NAN-002 repeat/soak tests and full AC-01–AC-11 evidence review. Include exact commands, environment, pass/fail results, relevant measurements and skipped checks. Obtain an independent review against the parent specification.

## Exclusions

No supported claim without independent evidence.

## Rollback

Revert the scoped code/documentation commit. For lab mutations, follow the operation journal and ownership checks; retain original image/state until verified, and rebuild only with explicit consent. Never revert a live domain controller indiscriminately.
