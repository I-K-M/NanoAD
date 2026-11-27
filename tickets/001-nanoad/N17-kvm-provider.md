# N17 — kvm provider

Status: pending

Parent: [NAN-001](../../specs/001-nanoad.md), [NAN-002](../../specs/002-resource-research.md), [NAN-003](../../specs/003-module-lifecycle.md)

## Outcome

Add Linux KVM/QEMU/libvirt provider behind same tested interface.

## Dependencies

N16.

## Allowed boundary

src/provider/kvm/; tests/provider/kvm/; docs/COMPATIBILITY.md. Changes outside this boundary require a reviewed ticket update.

## Acceptance criteria

Capability probe, private network, QCOW2 shared bases, ownership and qualified lifecycle; prove no weakening of core semantics.

## Required checks and evidence

Provider contract tests, real Linux 8 GiB measurement, native fidelity and isolation gates. Include exact commands, environment, pass/fail results, relevant measurements and skipped checks. Obtain an independent review against the parent specification.

## Exclusions

No Hyper-V implementation in this ticket.

## Rollback

Revert the scoped code/documentation commit. For lab mutations, follow the operation journal and ownership checks; retain original image/state until verified, and rebuild only with explicit consent. Never revert a live domain controller indiscriminately.
