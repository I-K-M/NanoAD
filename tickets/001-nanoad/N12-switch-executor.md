# N12 — switch executor

Status: experimental session executor; N11 validation and native execution gates pending

Parent: [NAN-001](../../specs/001-nanoad.md), [NAN-002](../../specs/002-resource-research.md), [NAN-003](../../specs/003-module-lifecycle.md)

## Outcome

Run an approved stop-before-start transaction safely.

## Dependencies

N11.

## Allowed boundary

src/lifecycle/switch/; src/cli/commands/; tests/switch/. Proposed supporting additions: a read-only checkCurrent wrapper in src/governor/admission.zig, test import in src/main.zig and docs/DEVELOPMENT-TRACE.md. No public mutation command. Independent review remains required.

## Acceptance criteria

Offer optional stops even when fit; default decline; no side effects on dry-run; recheck state, clean stop, verify release, start, health, journal, recover.

## Required checks and evidence

Fake failure at each step, no confirmation no mutation, non-interactive approved hash, real-provider smoke. Include exact commands, environment, pass/fail results, relevant measurements and skipped checks. Obtain an independent review against the parent specification.

## Exclusions

No silent budget increase or destructive fallback.

## Rollback

Revert the scoped code/documentation commit. For lab mutations, follow the operation journal and ownership checks; retain original image/state until verified, and rebuild only with explicit consent. Never revert a live domain controller indiscriminately.
