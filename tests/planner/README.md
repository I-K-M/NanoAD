# N11a — NanoPlanner, deterministic switch previews

Status: experimental pure planner; N12 execution and real-host qualification pending. Parent: [N11](../../tickets/001-nanoad/N11-switch-planner.md), [NAN-003](../../specs/003-module-lifecycle.md).

## Scope

Plan starts and stops for already provisioned guests using a trusted, revisioned inventory aligned to the sorted bundled module registry. The core and requested dependency closure are mandatory. Applied fixtures are protected and retain their independently qualified incremental cost; no attempt to undo persistent directory changes. Unknown, pending or stopping observations block planning. Missing/foreign/duplicate guest identities are refused. Absent modules cannot be provisioned by this slice; no real provider call or public mutation command.

Eligible stops exclude the requested closure, the core, pins, non-stoppable active modules and their prerequisites. A chosen stop set must leave all retained dependencies satisfied and the final set conflict-free. Stop leaves in reverse dependency order, then start prerequisites before dependants; lexical tie-breaks are deterministic. No duplicate shared dependencies. At most ten eligible optional modules are searched exhaustively (1023 nonempty subsets). More candidates are explicitly flagged as search-limited; a caller may request an exact selection, but cannot claim exhaustive alternatives. Return up to eight feasible-in-model options ranked by fewer interruptions, then smaller envelope reduction and canonical mask. Also return the lowest final memory footprint. Always request a choice when eligible optional stops exist, even if keeping them fits. No stop is automatically selected or approved.

## Resource model

Use N08 bounds for guest memory and steady/start/stop peak, shared overhead once, separate physical and commit checks and mandatory reserves. Zero projected host credit: even after a planned stop, use the original available RAM/commit and never assume actual release. This can conservatively reject a viable plan. Use NanoDisk's accounting admission for installed and peak scratch; retain growth allowances for every initial/started workload through the whole plan, including stopped guests. No speculative disk savings. Check initial, during and after each step. An already over-budget initial state requires separate recovery, rather than increasing pressure under a normal plan. Only known qualified costs can pass. Model-feasible does not mean executable; actual per-step admission and isolation must be rechecked by N12.

## Approval contract

SHA-256 domain-separated canonical encoding binds lab, state revision, inventory digest, registry semantics, workload state/identity/cost, pins, host resource values, policy, exact selected target/stops, ordered steps and resource projections. No raw struct bytes/padding. Freshness is checked separately; reobserving identical facts is allowed. Any changed bound, capacity, state, inventory or choice requires recomputation and a matching new hash. The trusted inventory digest must cover host boot/provider/media/ownership identity; no real attestor exists yet. The hash is not authentication or a durable dispatch permission. Only a future coordinator with actual consent and N09 journal may use it. Real host measurements naturally fluctuate; strict re-planning is intentionally conservative.

## Checks

Pinned Zig 0.14.1: zig fmt --check build.zig src modules; zig build test; zig build -Doptimize=ReleaseSafe. Synthetic tests cover fit and optional choice, combined stops, pins, shared prerequisites, unknown/absent modules, interrupted state, host/disk/peak refusal and stale approval. No VM or host changes. Independent review and real inventory/qualified envelopes remain outstanding; N11 does not expose a CLI that could accept forged attestation values. Rollback: revert scoped commits; no persistent data changes.
