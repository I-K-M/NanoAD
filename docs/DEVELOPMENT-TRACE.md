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

N06b [initial CI](https://github.com/I-K-M/NanoAD/actions/runs/46050833308): Linux passed; Windows compilation failed at the explicit handle-list pointer conversion. Corrected the Win32 ABI pointer cast; revalidation pending.

N06b adds read-only Windows native subprocess transport, executable digest verification, explicit handle allowlist, bounded separate stdout/stderr, post-launch deadline and child-only cleanup. A fixture executable verifies process mechanics; actual VirtualBox/AD remains untested. The transport refuses mutations and is not exposed in the CLI. The implementation is a partial N06 deliverable; build and test wiring and this trace are supporting additions. See [native transport contract](../tests/provider/NATIVE-TRANSPORT.md).

## Qualification status

N01–N04 remain open as research gates despite code integration. N05 hosted CI passed; real host and resource evidence remain pending. Do not label any Windows profile qualified. No production deployment or paid resources. Revert scoped commits if needed; do not automatically reset or delete a guest.
