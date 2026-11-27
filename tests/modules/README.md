# N10 — Bundled module registry

Parent: [N10](../../tickets/001-nanoad/N10-module-registry.md) and [NAN-003](../../specs/003-module-lifecycle.md). Status: experimental implementation, pending hosted validation and independent review.

The executable embeds an explicit list of eight reviewed JSON files from modules/. It never discovers runtime files, resolves external paths, executes scripts, downloads plugins or installs anything. The only default selection is ad-core; this is metadata, not a running-state claim. ad-core and directory-fixtures have experimental provisioning scripts; the other entries are planned capabilities. All entries report activation_supported false. No optional component is started by discovery.

## Manifest validation

- Version 1, strict field counts and required keys, no unknown/duplicate keys, bounded ASCII JSON without escapes; 8 KiB input, six nesting levels, fixed 128 KiB parser arena, 32 modules and eight entries per list.
- Canonical lowercase hyphen-separated ID (up to 32 bytes), filename exactly ID.json, three-part numeric version with 16-bit components. Closed provisioner-to-ID and kind mapping, closed capabilities and health checks; no executable paths, shell hooks or URLs.
- Integer-or-null resource fields, maximum 16 TiB; vCPUs integer-or-null, 0 for non-guests if specified. No float or numeric-string coercion. Null is unknown; configured memory is a proposed target only. No manifest supplies a qualified NanoRAM bound; measured provider/build-specific envelopes belong in the trusted governor/reconciler. This version deliberately permits only unmeasured/estimated provenance.
- Persistent fixtures cannot be stopped/archived or advertised as reversible. Retention is mandatory. A fixed 32-bit graph resolves dependencies and symmetric conflicts, rejects cycles, unknown IDs, incompatible prerequisite closure and optional defaults. Registry ordering is deterministic.

The JSON Schema documents the wire structure; the Zig parser also enforces byte/depth/canonical encoding, u16 version limits, graph semantics and the closed provisioner mapping. Schema validation alone cannot qualify a manifest. The full project catalogue is not yet implemented; only eight entries are shipped.

## CLI

```sh
nanoad modules list
nanoad modules list --json
nanoad modules info ad-core
nanoad modules info directory-fixtures --json
```

Output is metadata-only; it never claims actual running state or resource qualification. Invalid or unknown IDs return exit 2. No filesystem writes or external process. No Lua or third-party Zig dependency.

## Verification

Pinned Zig 0.14.1: zig fmt --check build.zig src modules; zig build test; zig build -Doptimize=ReleaseSafe. Hosted CI runs on Windows/Linux; includes negative schema/type/size/depth/ID/graph cases, deterministic byte mutation smoke, catalogue defaults, and public CLI JSON/read-only working-directory checks. Deterministic mutation smoke is not exhaustive fuzzing. Real module provisioning, plan-hash consent, dependency-driven switching and independent review remain pending. Rollback: revert scoped commits; no persistent schema migration.
