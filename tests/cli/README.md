# N05 — Zig bootstrap verification

Status: draft; real-host validation pending. Initial CI: Linux formatting and unit tests passed, explicit optimisation flag failed; Windows formatting failed on checkout line endings. Follow-up fixes pending CI.

The first executable supports help, version, and read-only doctor. It does not launch a subprocess or mutate lab/host state. It reports nullable measurements, never marks a provider or network ready, and returns 3 on the provisional Windows reference target or 8 on other targets. Linux reports host hints only (not cgroup-aware admission). Provider discovery is limited to a known Windows default path; no version or runtime compatibility is inferred. Use N01 for broader inventory.

## Toolchain pin

Provisional Zig **0.14.1** (released 2025-05-21), deliberately pinned for a small known standard-library API surface. It is not the latest stable; review and upgrade before qualification. No third-party Zig packages or package manifest are needed for this bootstrap.

Official [release index](https://ziglang.org/download/index.json), SHA-256 values:

| Archive | Digest |
| --- | --- |
| zig-x86_64-linux-0.14.1.tar.xz | 24aeeec8af16c381934a6cd7d95c807a8cb2cf7df9fa40d359aa884195c4716c |
| zig-x86_64-windows-0.14.1.zip | 554f5378228923ffd558eac35e21af020c73789d87afeabf4bfd16f2e6feed2c |

## Checks

Run on Windows and Linux x86-64 with the verified toolchain:

```sh
zig version
zig fmt --check build.zig src
zig build test
zig build -Doptimize=ReleaseSafe
```

Then run the executable in zig-out/bin. Expect help/version exit 0, invalid input exit 2, doctor exit 3 on Windows x86-64 and 8 on Linux. JSON doctor must have schema_version 1, result unqualified, provider_runtime_verified false, isolation_verified false, and no private paths or credentials. The no-mutation contract is tested in a disposable working directory; executable and output are outside that directory.

Measure actual executable bytes and simple-command RSS separately on both hosts. Do not infer the target from optimisation flags. CI provides compilation and unit/smoke tests on both platforms. No real Windows/VirtualBox lab tests or independent review yet.

## Rollback

Revert the N05 commit. No VM or system configuration changes are introduced.
