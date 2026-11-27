# N03 — native dc reference

Status: pending

Parent: [NAN-001](../../specs/001-nanoad.md), [NAN-002](../../specs/002-resource-research.md), [NAN-003](../../specs/003-module-lifecycle.md)

## Outcome

Provision a disposable single-domain DC and establish genuine behaviour reference.

## Dependencies

N02.

## Allowed boundary

provisioning/windows/ad-core/; tests/integration/ad/; benchmarks/results/. Changes outside this boundary require a reviewed ticket update.

## Acceptance criteria

Unique lab identity, native DNS/LDAP/Kerberos/NTLM policy, SYSVOL, ACL allow/deny, security logs, restart persistence; private network verified.

## Required checks and evidence

Run generous-memory reference suite and clean shutdown; save sanitised results. Include exact commands, environment, pass/fail results, relevant measurements and skipped checks. Obtain an independent review against the parent specification.

## Exclusions

No optional roles, third-party domain, or low-memory support claim.

## Rollback

Revert the scoped code/documentation commit. For lab mutations, follow the operation journal and ownership checks; retain original image/state until verified, and rebuild only with explicit consent. Never revert a live domain controller indiscriminately.
