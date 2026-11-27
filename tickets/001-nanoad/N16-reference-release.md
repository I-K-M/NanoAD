# N16 — reference release

Status: pending

Parent: [NAN-001](../../specs/001-nanoad.md), [NAN-002](../../specs/002-resource-research.md), [NAN-003](../../specs/003-module-lifecycle.md)

## Outcome

Package first qualified or explicitly experimental reference release.

## Dependencies

N15.

## Allowed boundary

docs/; README.md; release/; .github/workflows/. Changes outside this boundary require a reviewed ticket update.

## Acceptance criteria

Versioned native CLI, signed/checksummed project artefacts where available, reproducible instructions, limitations, no proprietary images; documented rollback.

## Required checks and evidence

Pinned CI and real host proof pack; independent review; human release approval. Include exact commands, environment, pass/fail results, relevant measurements and skipped checks. Obtain an independent review against the parent specification.

## Exclusions

No auto-publish or paid resources without approval.

## Rollback

Revert the scoped code/documentation commit. For lab mutations, follow the operation journal and ownership checks; retain original image/state until verified, and rebuild only with explicit consent. Never revert a live domain controller indiscriminately.
