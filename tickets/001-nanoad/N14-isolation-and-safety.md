# N14 — isolation and safety

Status: pending

Parent: [NAN-001](../../specs/001-nanoad.md), [NAN-002](../../specs/002-resource-research.md), [NAN-003](../../specs/003-module-lifecycle.md)

## Outcome

Demonstrate isolation and hard failure boundaries on reference provider.

## Dependencies

N12.

## Allowed boundary

tests/security/; docs/threat-model.md; docs/recovery.md. Changes outside this boundary require a reviewed ticket update.

## Acceptance criteria

No external route, bridge, shared folder or public port forward; credentials not leaked; malformed manifests/paths refused; interruption recoverable.

## Required checks and evidence

Real synthetic boundary tests, adverse provider state, secret redaction and host-path escape tests. Include exact commands, environment, pass/fail results, relevant measurements and skipped checks. Obtain an independent review against the parent specification.

## Exclusions

No probing external targets.

## Rollback

Revert the scoped code/documentation commit. For lab mutations, follow the operation journal and ownership checks; retain original image/state until verified, and rebuild only with explicit consent. Never revert a live domain controller indiscriminately.
