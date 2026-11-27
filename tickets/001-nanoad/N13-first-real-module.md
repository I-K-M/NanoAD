# N13 — first real module

Status: pending

Parent: [NAN-001](../../specs/001-nanoad.md), [NAN-002](../../specs/002-resource-research.md), [NAN-003](../../specs/003-module-lifecycle.md)

## Outcome

Qualify a small directory fixture and an optional member server independently.

## Dependencies

N12.

## Allowed boundary

modules/directory-fixtures/; modules/member-server/; provisioning/windows/member/; tests/integration/modules/. Changes outside this boundary require a reviewed ticket update.

## Acceptance criteria

Core remains native; unique identity and domain join; fixture does not require extra VM; member stop retains disk and frees memory; restart preserves intended state.

## Required checks and evidence

Reference fidelity comparison; actual RAM/disk measurement, safe reset and switch exercise. Include exact commands, environment, pass/fail results, relevant measurements and skipped checks. Obtain an independent review against the parent specification.

## Exclusions

No extra CA, workstation, SQL or attack automation.

## Rollback

Revert the scoped code/documentation commit. For lab mutations, follow the operation journal and ownership checks; retain original image/state until verified, and rebuild only with explicit consent. Never revert a live domain controller indiscriminately.
