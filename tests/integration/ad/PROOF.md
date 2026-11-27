# N03 preparation proof pack

Status: draft; native integration and independent review pending.

Parent: N03 and NAN-001/NAN-002. This branch adds guest-only promotion and native verification scripts, not a built VM or a validated domain. The preceding N05 build passed hosted Windows/Linux CI, but that does not qualify AD.

## Static review findings addressed

- Fixture account validation explicitly requests primaryGroupID rather than relying on default AD cmdlet properties.
- Negative authentication checks effective fine-grained lockout policy and current bad-password count; unknown headroom skips the attempt.
- Fixture mutation requires explicit provider-side isolation confirmation; guest guard cannot prove the hypervisor boundary.
- Password SecureString objects from fixture creation are disposed on error paths as well as success.

## Validation

- CI: PowerShell 5.1 and 7 parser and deterministic identity tests; inspect run before accepting.
- Real host: N01/N02 not qualified; promotion, native authentication, ACL restoration, auditing, restart comparison, resource measurement and independent review are all pending.
- No Windows image or credentials committed. No VM, host security setting or network has been modified by authoring these files.

## Rollback

Revert this branch's commits. For an actual failed reference promotion, inspect the disposable guest's local marker and native logs; rebuild from the unpromoted immutable base with explicit consent. No automatic demotion, unsafe snapshot restoration or deletion is provided.
