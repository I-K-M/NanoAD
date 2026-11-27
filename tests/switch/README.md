# N12a — NanoSwitch session executor

Parent: [N12](../../tickets/001-nanoad/N12-switch-executor.md), [NAN-003](../../specs/003-module-lifecycle.md). Experimental integration; real provider mutation unavailable.

## Contract

Preview obtains a trusted read-only snapshot under the existing lab lock and an independently held host-wide resource lock. It returns N11 alternatives; no journal append or provider mutation. Execute defaults to refusal without an exact approved fingerprint. Dry-run verifies an exact selection but does not write or perform an action. Recompute approval on initial observations and again immediately before the first intent. No implicit approval or selection, even if keeping optional modules fits. The session executor is an internal API; there is no public switch/enable command that could accept fabricated evidence.

For each planned step:

1. Reconcile every owned guest against the N09 journal: module-to-guest mapping, canonical lab/guest/VM/media identities, base digest, configured cost, observed power, isolation, native health, release and scratch evidence. A complete inventory and host-lock attestation are mandatory. No hidden guest or duplicate mapping; persistent applied fixtures are deliberately unsupported until they have durable cost and state representation.
2. Compare immutable topology digest, module mapping, pins and policy to the approved session. The digest must cover boot, provider/build, media and ownership identity and exclude expected power changes. Recheck all actual observations against the exact current journal revision. Re-admit the transitional envelope through NanoRAM/NanoDisk using fresh physical/commit/free-space data and compare to the approved per-step upper bounds. No projected release or credit.
3. Sync intent using N09 beginStart/beginStop. Observe and admit again, then sync the dispatch barrier. Re-observe after that barrier and before a single bounded backend call. The backend must use only the verified owned guest, graceful shutdown, bounded start/health checks, no forced stop or automatic retry.
4. Observe every guest again; confirm the requested power state, native health or independently verified release, isolation and accounted scratch. Check the new ledger and disk envelope against the approved after-step bound. Sync completion. Only then advance to the next step.
5. On error, stop the session. A pending/armed operation or uncertain journal requires recovery, retaining reservations. Earlier completed steps remain committed. Do not restart stopped guests, delete media, compensate automatically or reuse an old fingerprint. A crash between steps leaves a consistent journal prefix; generate and explicitly approve a new plan for the rest. This is not a multi-step atomic rollback transaction and the full switch ID/progress is not yet durably recorded. Per-step journal entries are authoritative; report progress/hash in memory. No schema change.

Actual host conditions may change after any observation; admission is not an OS-enforced reservation. A real backend must enforce the lock and timeouts, produce independently trusted observations, prove resource envelopes, and handle isolation and health. The current VirtualBox transport is read-only and cannot be used as a real mutation backend. No actual hypervisor or guest is invoked. No claimed host memory savings.

## Verification

Pinned Zig 0.14.1: zig fmt --check build.zig src modules; zig build test; zig build -Doptimize=ReleaseSafe. Tests use the actual local journal and a fake provider/attestor. Verify read-only preview/decline, exact-hash mismatch, stop before start and per-step dispatch barrier, observation failure before/after each phase, ambiguous provider failure, missing release/readiness, stale approval after partial completion, host pressure, mapping/budget/disk drift and missing host lock. Reopen the journal after simulated failures and verify reservations. Hardware interruption, real-provider smoke and independent review remain necessary. Rollback: revert scoped source commits; preserve all journals and guests. No migration or new runtime dependency.
