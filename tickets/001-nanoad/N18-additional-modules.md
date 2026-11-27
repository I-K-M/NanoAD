# N18 — additional modules

Status: pending

Parent: [NAN-001](../../specs/001-nanoad.md), [NAN-002](../../specs/002-resource-research.md), [NAN-003](../../specs/003-module-lifecycle.md)

## Outcome

Create a repeatable qualification template and select one next native role/topology.

## Dependencies

N16.

## Allowed boundary

modules/; provisioning/; tests/integration/modules/; docs/module-authoring.md. Changes outside this boundary require a reviewed ticket update.

## Acceptance criteria

One requested module per subsequent ticket; declare dependency, resources, persistent effects, explicit stop/archive/reset capability; compare native reference.

## Required checks and evidence

Module-specific fidelity, measured cost, activation/rollback and isolation tests. Include exact commands, environment, pass/fail results, relevant measurements and skipped checks. Obtain an independent review against the parent specification.

## Exclusions

No catalogue-wide installation, no multiple unqualified modules.

## Rollback

Revert the scoped code/documentation commit. For lab mutations, follow the operation journal and ownership checks; retain original image/state until verified, and rebuild only with explicit consent. Never revert a live domain controller indiscriminately.
