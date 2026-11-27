# N07a — NanoDisk catalogue, allocation and safe planning

Status: experimental implementation slice. N06 native execution, N08 admission, N09 durable ownership and real-host qualification remain pending. No VirtualBox storage mutation is wired.

## Architecture and requirements

- A single generalised, sealed Windows base is named by SHA-256; its provider medium UUID is distinct from a guest identity. Each guest has its own persistent direct differencing medium, named by its canonical guest UUID. No base is attached directly to a VM; no nested overlay chains, automatic snapshot restore, or implicit full clone.
- Count every distinct medium once and include all other retained artefacts (logs, caches, archives, metadata and provider state). A shared parent is not multiplied by its children. Two physical copies are not deduplicated by mere digest equality; duplicate catalogue identities are errors to reconcile.
- The catalogue is bounded to 128 disk records. Paths are derived from typed identities rather than arbitrary relative paths. The future real filesystem adapter must establish a trusted root, prevent junction/reparse traversal and ensure targets do not exist; lexical naming is not sufficient.
- The streaming verifier uses a 16 KiB buffer, expected length and SHA-256 and rejects observable changes. Its caller must lock and verify the file handle; metadata checks alone do not prove immutability.
- Windows native file-handle observations separate logical bytes from allocated/compressed file-data hints, with link count. These are estimates, not exact physical allocations or strict budget bounds. NTFS and the full filesystem/provider inventory still require reconciliation. Unavailable or estimate-only costs block strict admission. Conservative bounds must come from independently qualified measurements, not user assertions.
- Plan-only admission checks installed upper bound, operation peak and current free space minus reserve independently. The initial overlay creation bound does not reserve the disk's whole potential future growth. N08 must handle growth/space pressure and recheck before each operation. No speculative savings are credited.
- An offline compaction plan requires a detached, unpinned overlay, a full staging bound and additional scratch. It preserves the original. No in-place compact, parent rewrite, UUID rewrite, auto-delete or replacement is executed. Interrupted stages enter recovery; a future durable journal owns compensation.
- A retained child references its base even if the child is detached or its guest stopped. A referenced or pinned base is ineligible for purge. Provider references outside the catalogue must be reconciled before any action.

## Provider integration contract

VirtualBox 7.1 documents creating a differencing VDI using a registered parent UUID:

```text
VBoxManage createmedium disk --filename=<new absolute path> --diffparent=<parent UUID> --format=VDI --variant=Standard
```

This is a documented future command, not an implemented execution path. Do not use VirtualBox's auto-reset immutable mode as a synonym for NanoAD's sealed base. Confirm parent and child media identities, type, capacity, file location and no direct writable attachment; verify the original digest is unchanged. A child UUID is assigned by the provider and must be reconciled before use. Real creation requires qualified N06, exclusive catalogue locking, approval, journal and rechecked host/disk headroom. Never silently fall back to a full clone. Native Windows observation is read-only and used only by tests.

Compaction is a research gate: VirtualBox's documented compact operation mutates a VDI in place. Do not compact the sole original. A staging copy needs an independently validated provider workflow, no simultaneous registration of duplicate medium UUIDs, preservation of parent linkage and guest semantics, verified replacement and recoverable journal. Until that exists, plans cannot execute.

References: [Oracle VBoxManage 7.1](https://docs.oracle.com/en/virtualization/virtualbox/7.1/user/vboxmanage.html), [Microsoft FILE_STANDARD_INFO](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_standard_info).

## Verification

Run `zig fmt --check build.zig src`, `zig build test`, and `zig build -Doptimize=ReleaseSafe` on Windows and Linux. Unit tests cover digest verification, canonical paths, invalid and duplicate media, missing or nested parents, sealed bases, retained references, incomplete reconciliation, strict allocation, overflow and disk-full admission, and interrupted compaction transitions. A Windows test measures a small ordinary temporary file; Linux reports unsupported for the Win32 measurement. No VM or real differencing disk is created.

To close N07, verify on a disposable isolated VirtualBox host with a real generalised base and two independently provisioned guests. Record base/overlay sizes before and after writes, exact provider identities and references, host volume deltas, auxiliary artefacts, base digest unchanged, persistence across clean restart, and real failure recovery. Compare to full clones without claiming unmeasured savings. Test sparse/compressed files, aliases, reparse points and external references. A full native AD fidelity comparison and independent review remain necessary.

Rollback: revert scoped commits. This slice makes no VM changes and writes no persistent lab state.
