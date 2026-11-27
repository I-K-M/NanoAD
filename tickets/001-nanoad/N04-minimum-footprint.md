# N04 — minimum footprint

Status: pending

Parent: [NAN-001](../../specs/001-nanoad.md), [NAN-002](../../specs/002-resource-research.md), [NAN-003](../../specs/003-module-lifecycle.md)

## Outcome

Determine smallest validated core envelope before expanding the orchestrator.

## Dependencies

N03.

## Allowed boundary

benchmarks/protocol/; benchmarks/results/; images/windows-core/experiments/. Changes outside this boundary require a reviewed ticket update.

## Acceptance criteria

Compare supported builds when media available, apply one optimisation at a time, perform cold boots/idle/workload, report installed and peak bytes, smallest pass and failures.

## Required checks and evidence

Execute NAN-002 protocol; compare reference; reject semantic changes and publish failed candidates. Include exact commands, environment, pass/fail results, relevant measurements and skipped checks. Obtain an independent review against the parent specification.

## Exclusions

No promised 24 GB or unsupported memory threshold before evidence.

## Rollback

Revert the scoped code/documentation commit. For lab mutations, follow the operation journal and ownership checks; retain original image/state until verified, and rebuild only with explicit consent. Never revert a live domain controller indiscriminately.
