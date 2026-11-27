# N06b — Native read-only process transport

Status: experimental implementation, native provider qualification pending.

## Contract

The first native transport targets Windows x86-64 only. It uses the Win32 process and pipe APIs, no shell or general-purpose asynchronous runtime. It accepts typed VBoxManage requests and refuses start and shutdown before launching anything. The production CLI does not import it. Only a locally trusted, absolute conventional ASCII path ending in VBoxManage.exe is accepted. The operator must independently establish the provider installation's provenance and SHA-256 digest, and trust the containing directory, DLLs, environment and local host. The executable is hashed with a bounded streaming buffer on every request, rejecting final-component reparse points and non-fixed drives; a read handle disallows write/delete sharing until child exit. This is not a complete anti-TOCTOU defence for mutable parent directories, an Authenticode verifier, or a sandbox for hostile executables.

CreateProcessW receives both an explicit application path and a bounded writable command line, and uses the provider directory as working directory. STARTUPINFOEX lists only the three required inheritable standard handles. Stdin is closed; stdout and stderr are captured separately without threads. The output cap is the caller's buffer (up to 64 KiB), stderr is capped at 4 KiB. A non-zero exit or non-empty stderr cannot be mistaken for a successful observation. Diagnostics are not copied to user logs. Read-only subprocess polling uses a monotonic tick clock and a 10-second maximum after launch. On timeout/overflow the exact child handle is used to terminate only that read-only command, followed by a bounded cleanup wait. No VM, service or process tree is terminated. File verification and CreateProcessW themselves are synchronous OS operations, so a hung kernel/filesystem is outside this deadline. The inherited environment and provider-side services are not sandboxed; a VBoxManage query can activate provider infrastructure. The transport must not be wired to mutations until N08/N09 and complete isolation checks are qualified.

## Tests

- Pure path/argument encoding tests run on Windows and Linux.
- A dedicated Windows x86-64 fixture executable named VBoxManage.exe is built in Zig's cache (never installed). The integration harness hashes this own artifact and verifies actual process creation, successful stdout, digest rejection, output limit, timeout, separate stderr, non-zero exit, mutation refusal and subsequent recovery.
- No VirtualBox installation or Windows guest is needed for these tests. They do not establish actual VBoxManage response fields, installation trust, provider capability, isolation, VM readiness, or resource budget enforcement.
- Validate with zig fmt --check build.zig src, zig build test, zig build -Doptimize=ReleaseSafe. Real provider tests and independent review remain required. No runtime dependencies added.

References: [CreateProcessW](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessw), [handle inheritance](https://learn.microsoft.com/en-us/windows/win32/procthread/inheritance), [anonymous pipes](https://learn.microsoft.com/en-us/windows/win32/ipc/anonymous-pipe-operations).

Rollback: revert the scoped commits; no VM, host configuration or guest state is changed.
