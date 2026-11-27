# N02 — base image

Status: pending

Parent: [NAN-001](../../specs/001-nanoad.md), [NAN-002](../../specs/002-resource-research.md), [NAN-003](../../specs/003-module-lifecycle.md)

## Outcome

Build a reproducible generalised Server Core base from verified official media.

## Dependencies

N01.

## Allowed boundary

images/windows-core/; provisioning/windows/base/; tests/image/. Changes outside this boundary require a reviewed ticket update.

## Acceptance criteria

Build unjoined and unpromoted Core, record recipe/build/hash, verify boot and supported maintenance; detach NAT and ISO; preserve immutable base.

## Required checks and evidence

Real disposable host build; record peak scratch/RAM and physical image size, failed build cleanup. Include exact commands, environment, pass/fail results, relevant measurements and skipped checks. Obtain an independent review against the parent specification.

## Exclusions

No published Microsoft image, no unsupported DLL stripping, no promoted DC clone.

## Rollback

Revert the scoped code/documentation commit. For lab mutations, follow the operation journal and ownership checks; retain original image/state until verified, and rebuild only with explicit consent. Never revert a live domain controller indiscriminately.
