# N01 — reference host

Status: pending

Parent: [NAN-001](../../specs/001-nanoad.md), [NAN-002](../../specs/002-resource-research.md), [NAN-003](../../specs/003-module-lifecycle.md)

## Outcome

Record the reference host, licensed media plan and provider capabilities before creating guests.

## Dependencies

none.

## Allowed boundary

docs/reference-host.md; benchmarks/protocol/. Changes outside this boundary require a reviewed ticket update.

## Acceptance criteria

Record actual host RAM, free/allocated storage, CPU, OS, provider version and isolation/clone capabilities; identify temporary scratch; select exact Zig/provider candidates and media provenance.

## Required checks and evidence

Read-only capability probe and reviewed evidence; no paid resources, installation or VM changes. Include exact commands, environment, pass/fail results, relevant measurements and skipped checks. Obtain an independent review against the parent specification.

## Exclusions

No benchmark claims or guest installation.

## Rollback

Revert the scoped code/documentation commit. For lab mutations, follow the operation journal and ownership checks; retain original image/state until verified, and rebuild only with explicit consent. Never revert a live domain controller indiscriminately.
