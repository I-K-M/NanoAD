# N11 — switch planner

Status: experimental implementation; N10 validation and real-host gates pending

Parent: [NAN-001](../../specs/001-nanoad.md), [NAN-002](../../specs/002-resource-research.md), [NAN-003](../../specs/003-module-lifecycle.md)

## Outcome

Produce deterministic feasible activation and deactivation plans.

## Dependencies

N10.

## Allowed boundary

src/planner/; tests/planner/. Proposed supporting additions: test import in src/main.zig and docs/DEVELOPMENT-TRACE.md. Independent review remains required. No public mutation CLI.

## Acceptance criteria

Closure, conflict, pins, shared prerequisites, peak-step simulation, combined stops, rank feasible alternatives, plan fingerprint.

## Required checks and evidence

Golden plan tests: fit, over budget, unknown costs, pin, cycle, no feasible option, stale hash. Include exact commands, environment, pass/fail results, relevant measurements and skipped checks. Obtain an independent review against the parent specification.

## Exclusions

No actual provider mutation.

## Rollback

Revert the scoped code/documentation commit. For lab mutations, follow the operation journal and ownership checks; retain original image/state until verified, and rebuild only with explicit consent. Never revert a live domain controller indiscriminately.
