# N05 — zig cli doctor

Status: pending

Parent: [NAN-001](../../specs/001-nanoad.md), [NAN-002](../../specs/002-resource-research.md), [NAN-003](../../specs/003-module-lifecycle.md)

## Outcome

Create pinned Zig project and read-only doctor command.

## Dependencies

N01.

## Allowed boundary

build.zig; build.zig.zon; src/main.zig; src/cli/; src/host/; tests/cli/. Changes outside this boundary require a reviewed ticket update.

## Acceptance criteria

Build/test on Windows and Linux; stable help, JSON schema and exit codes; bounded parsing and subprocess output; report missing provider without mutation.

## Required checks and evidence

Pinned toolchain, format/build/test, invalid input and read-only contract tests; measure simple-command RSS and binary bytes. Include exact commands, environment, pass/fail results, relevant measurements and skipped checks. Obtain an independent review against the parent specification.

## Exclusions

No mandatory daemon, Lua or database.

## Rollback

Revert the scoped code/documentation commit. For lab mutations, follow the operation journal and ownership checks; retain original image/state until verified, and rebuild only with explicit consent. Never revert a live domain controller indiscriminately.
