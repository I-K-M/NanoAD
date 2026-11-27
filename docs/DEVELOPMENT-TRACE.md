# Development trace — 27 November 2026

This is an experimental implementation trace, not a release or qualification record. The maintainer authorised integration of the staged branches. Independent review and the real-host gates remain outstanding.

| PR | Outcome | Evidence |
| --- | --- | --- |
| [1](https://github.com/I-K-M/NanoAD/pull/1) | Foundation merged | 630ef28f26f69c3202206ed1e66b110aa76c3b6e |
| [2](https://github.com/I-K-M/NanoAD/pull/2) | N01 host inventory merged | 956726fdb6f726b85ccda8fdb0629f6e9f16ff30; actual host/media pending |
| [3](https://github.com/I-K-M/NanoAD/pull/3) | N05 Zig bootstrap merged | 2055c5607e29e3278bdae03b7275a58e0bb22cfb; [Windows/Linux CI](https://github.com/I-K-M/NanoAD/actions/runs/46048091170) passed |
| [4](https://github.com/I-K-M/NanoAD/pull/4) | N02 image preparation merged | b03220d7becf27fc4817e09302d57878a1438b3c; [PowerShell syntax](https://github.com/I-K-M/NanoAD/actions/runs/46048032946) passed |
| [5](https://github.com/I-K-M/NanoAD/pull/5) | N03 native AD preparation merged | ddfd8328c019bf6f1e2db1f3e11d7fd6ab3e0d21; [syntax and identity](https://github.com/I-K-M/NanoAD/actions/runs/46048660377) passed |
| [6](https://github.com/I-K-M/NanoAD/pull/6) | N04 benchmark tooling merged | dff8b77b485cc510eddc2020505855bc888e2c9c; [synthetic Windows tests](https://github.com/I-K-M/NanoAD/actions/runs/46049379954) and [main CI](https://github.com/I-K-M/NanoAD/actions/runs/46049471108) passed |

Earlier Zig failures (optimisation flag, Windows line endings, CI exit propagation) are retained in history. ReleaseSafe bootstrap executables measured 123,392 bytes Windows and 168,136 bytes Linux. RSS and final product size remain unmeasured.

## N04 preparation

Initial [NanoBench CI](https://github.com/I-K-M/NanoAD/actions/runs/46049274646) exposed a Windows file-handle leak on rejected JSONL input: the ReadLines enumerator could retain the file after an exception. Replaced it with an explicitly disposed StreamReader; synthetic tests passed under PowerShell 5.1 and 7.

Added bounded host/guest memory and CPU sampling, JSONL summary, conservative NTFS file-data allocation estimate, experiment instructions, synthetic checks and a Windows CI gate. See [execution protocol](../benchmarks/protocol/EXPERIMENTS.md). Workflow and this trace are explicit supporting additions to the ticket boundary. Exact disk accounting, provider process overhead, latency, real AD comparisons and independent review remain pending. No host or VM was modified by preparing this code.

## N06a provider contract

[PR #7](https://github.com/I-K-M/NanoAD/pull/7) prepares a Zig-only provider protocol and lifecycle contract, with fixed-size identities, bounded response parsing, typed requests, explicit authorisation and fake-backend tests. Static review hardened UUID validation at the encoding boundary and added bridged/NAT rejection tests. CLI integration is deliberately absent until a bounded native transport, N08 admission, N09 durable state/ownership and independent isolation/readiness checks exist. [Initial CI](https://github.com/I-K-M/NanoAD/actions/runs/46049998085) found an unavailable std.mem.trimEnd API on pinned Zig 0.14.1; replaced with explicit bounded CRLF handling and added a regression test. Hosted tests do not exercise a real VM. See [provider verification](../tests/provider/README.md). The trace and build/test wiring are supporting additions outside the original N06 boundary.

## N06b native transport

N06a [PR #7](https://github.com/I-K-M/NanoAD/pull/7) merged at c32708a2d7227bffcb595b58f2c16d7f91624c54 following [successful Windows/Linux CI](https://github.com/I-K-M/NanoAD/actions/runs/46050136000).

N06b [initial CI](https://github.com/I-K-M/NanoAD/actions/runs/46050833308): Linux passed; Windows compilation failed at the explicit handle-list pointer conversion. Corrected the Win32 ABI pointer cast. [Second CI](https://github.com/I-K-M/NanoAD/actions/runs/46051210124) compiled Windows but found a child-exit race on output overflow. Close capture readers before bounded cleanup; verify the signalled child handle rather than treating a racing TerminateProcess failure as proof of failed cleanup. [Third validation](https://github.com/I-K-M/NanoAD/actions/runs/46051467109) passed on Windows/Linux. PR #8 merged at ef809759094a7c5081363d9e606c077255411376.

N06b adds read-only Windows native subprocess transport, executable digest verification, explicit handle allowlist, bounded separate stdout/stderr, post-launch deadline and child-only cleanup. A fixture executable verifies process mechanics; actual VirtualBox/AD remains untested. The transport refuses mutations and is not exposed in the CLI. The implementation is a partial N06 deliverable; build and test wiring and this trace are supporting additions. See [native transport contract](../tests/provider/NATIVE-TRANSPORT.md).

## N07 NanoDisk

[PR #9](https://github.com/I-K-M/NanoAD/pull/9) merged at 4c0785bd8eeff28a19f5564680dc02dcc7fe7b33. [Initial CI](https://github.com/I-K-M/NanoAD/actions/runs/46051403015) found a shadowed Zig test budget; [revalidation](https://github.com/I-K-M/NanoAD/actions/runs/46051551559) passed on both hosts. Bounded image catalogue, file-allocation estimates, shared-base accounting, reference guards and overlay/compaction plans are implemented; actual VirtualBox media creation/compaction and physical qualification remain pending.

## N08 NanoRAM

[PR #10](https://github.com/I-K-M/NanoAD/pull/10) merged at d054c208194e5e49ac35ff97f94c4d98c2c5478b after [Windows/Linux CI](https://github.com/I-K-M/NanoAD/actions/runs/46052399934) passed.

Strict physical/commit envelopes, shared and per-workload peaks, disk growth and scratch admission, fresh native Windows observations and a revisioned in-memory reservation ledger. Estimates and unknown costs cannot pass strict admission. No auto-stop, OS-enforced reservation or live-provider mutation is wired. See [governor contract](../tests/governor/README.md) and [proof pack](../tests/governor/PROOF.md). Real overhead measurement, reconciliation, durable N09 lock and independent review remain outstanding.

## N09 NanoState

[PR #11](https://github.com/I-K-M/NanoAD/pull/11) merged at 2aad5ab8f24e9ecf361870d582059dfbbb31ebf9 after [Windows/Linux CI](https://github.com/I-K-M/NanoAD/actions/runs/46054099474) passed, including process-exit replay and lock exclusion.

[CI 46053314585](https://github.com/I-K-M/NanoAD/actions/runs/46053314585) passed Linux but failed Windows compilation in Zig 0.14.1's File.tryLock. The Windows lock now calls LockFileEx directly with an exclusive, fail-immediately byte-range lock on the same stable file. The cross-process harness remains the verification gate.

The first durable state slice uses a bounded, append-only, hash-chained JSON event journal and stable OS file lock. Replaying intent/dispatch/completion reconstructs NanoRAM reservations without a separate mutable ledger. Explicit cancellation is limited to undispatched work; ambiguous dispatch is never retried automatically. Read-only reconciliation reports drift and unavailable observations without adopting or deleting resources. See [recovery contract](../tests/recovery/README.md) and [proof pack](../tests/recovery/PROOF.md). Native VM execution, complete inventory/ownership attestation, storage power-loss durability and independent review remain outstanding.

## N10 module registry

Initial CI stopped at the formatter; [diagnostic CI](https://github.com/I-K-M/NanoAD/actions/runs/46058476177) printed the exact filename-slice spacing difference. Applied the formatter's change. [Final N10 CI](https://github.com/I-K-M/NanoAD/actions/runs/46058736502) passed on Windows and Linux. [PR #12](https://github.com/I-K-M/NanoAD/pull/12) merged at 02f952d2732b3325bdef7d6893cb6e202406212d.

The first bundled registry uses a closed JSON schema, an explicit build-time manifest allowlist, fixed-size parsing and graph structures, checked integer/null resource fields, canonical identifiers and deterministic dependency/conflict resolution. Only ad-core is selected by default. All activation paths are unavailable; read-only modules list/info report planned versus experimental-script implementations and do not inspect lab state. CI checks the registry and CLI working-directory invariance. See [module contract](../tests/modules/README.md) and [proof pack](../tests/modules/PROOF.md). N09 qualification and independent review remain gates; metadata introduces no VM, network or host changes.

## N11 NanoPlanner

[PR #13](https://github.com/I-K-M/NanoAD/pull/13) merged at f7ace83407bd0c18e734e3b5cd58f30b615ec75a following [required Windows/Linux CI](https://github.com/I-K-M/NanoAD/actions/runs/46059017849).

The pure switch planner takes a trusted revisioned inventory and bundled dependency graph; protects core, pins and retained dependencies; computes reverse-order stops and dependency-first starts; searches bounded combinations and offers choices even when keeping modules fits. It checks conservative memory/commit/disk envelopes at each step, never credits projected host release or disk reclamation, and binds the exact plan and input facts to a canonical SHA-256 fingerprint. See [planner contract](../tests/planner/README.md) and [proof pack](../tests/planner/PROOF.md). Real module inventory/admission/approval integration remains a gate. No provider mutation or public execution command.

## N12 NanoSwitch

[PR #14](https://github.com/I-K-M/NanoAD/pull/14) merged at e83c237c732dce59b24e38bd061a621d33b90af1 after [Windows/Linux CI](https://github.com/I-K-M/NanoAD/actions/runs/46059307163) passed.

Internal session executor recomputes an exact approved plan, validates all owned guest identities, costs and fresh evidence, rechecks each transitional/after-step envelope through NanoRAM/NanoDisk and uses N09 synced intent/dispatch/completion. Default refusal, read-only preview, one provider call per step, no automatic retry or compensation. Failure preserves earlier committed steps and ambiguous reservations; a fresh plan and consent are required after interruption. Full session progress/hash is not durable beyond individual N09 events. See [switch contract](../tests/switch/README.md) and [proof pack](../tests/switch/PROOF.md). Native execution, host-wide lock, complete attestation and independent review remain pending.

## N13 native optional modules

[PR #15](https://github.com/I-K-M/NanoAD/pull/15) merged at 8eae6e6607f98cd27899c571890bafcedf8a2812 after [PowerShell](https://github.com/I-K-M/NanoAD/actions/runs/46060224844) and [Zig](https://github.com/I-K-M/NanoAD/actions/runs/46060224822) checks passed.

Native member-server provisioning scripts and read-only health checks target one distinct Server Core guest; explicit signed/sealed Kerberos preflight, guarded local domain join with a durable create-new intent, no automatic retry. Directory-fixtures reuse the N03 provisioner and add read-only identity/ACL inventory. Pure restart comparison verifies stable directory GUIDs and later boot in supplied passing reports, not provenance or real provider release. See [module integration checklist](../tests/integration/modules/README.md) and [proof pack](../tests/integration/modules/PROOF.md). Real host, actual domain join/fidelity, memory/disk qualification, real switch and independent review remain pending.

## N14 isolation and safety

Added strict normalised inventory policy (model compatibility only), read-only registered/running VM commands, Windows machine-wide cooperative mutex, handle-based fixed-drive path observation, bounded refusal codes, threat model and recovery policy. [Security contract](../tests/security/README.md) and [proof pack](../tests/security/PROOF.md) record the native/fake tests and limitations. Full provider-account/peer/media collection, guest network evidence, real host lock integration, trusted ACLs and independent review remain gates. Native mutation transport remains disabled.

## Qualification status

N01–N04 remain open as research gates despite code integration. N05 hosted CI passed; real host and resource evidence remain pending. Do not label any Windows profile qualified. No production deployment or paid resources. Revert scoped commits if needed; do not automatically reset or delete a guest.
