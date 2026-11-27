# N10 proof pack

- Scope: eight embedded declarative modules, strict bounded parser, schema, deterministic graph, metadata-only list/info and tests. Parent: [N10](../../tickets/001-nanoad/N10-module-registry.md), [NAN-003](../../specs/003-module-lifecycle.md).
- Decisions: embed allowlisted sources at build time rather than load runtime plugins; strict ASCII JSON without escapes; closed provisioner-to-ID/kind mapping; conservative resource provenance; planned and experimental scripts explicitly distinguished. CLI/build/CI and trace changes are supporting integration documented in the ticket.
- Static review: disambiguate the JSON scanner's structural tokens and ASCII fallback; make missing-field and unknown-enum error propagation explicit; test one-sided conflict symmetry and impossible transitive prerequisite closure.
- Initial [CI](https://github.com/I-K-M/NanoAD/actions/runs/46054538349) stopped on registry.zig formatting on both hosts. Simplified the nested test initializer and error-union branch; CI now prints formatter diffs if formatting fails, without weakening the gate.
- Validation: Windows/Linux hosted Zig format/test/build and CLI smoke; inspect the actual run before merge. No native VM test or exhaustive fuzz campaign. No independent review yet.
- Unknown peak/disk costs remain null; resource targets are not measured or admitted. No module activation, download, host/VM changes, migration or new runtime dependency. No automatic module stop. N11 will use graph closure for planning; native orchestration remains unqualified.
- Rollback: revert scoped commits; no persistent data touched.
