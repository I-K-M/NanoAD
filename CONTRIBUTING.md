# Contributing

NanoAD is in its design phase. Read the specifications and ticket index before writing code. English-language project documentation uses British spelling.

- Keep native Windows semantics, isolation and licensing ahead of size optimisations.
- Select one ticket, confirm its dependencies, work on a dedicated branch, and keep changes within its stated boundary.
- New dependencies require a measurable need and a footprint/security justification. Pin the Zig toolchain and verify supply-chain provenance.
- Include deterministic tests, resource impact and failure/recovery tests. Do not claim unmeasured savings or unsupported Windows allocations as supported.
- Do not commit Windows ISOs, VM images, credentials, guest secrets, or unsanitised logs. Use synthetic lab identities only.
- Obtain an independent review against the ticket and specifications; report real check results and skipped checks honestly.
- A proof pack must link the ticket, record commands/results, resource measurements where relevant, known limitations, environment changes and rollback.
- Never run intentionally vulnerable guests on a bridged/public network or on a production domain.

See [implementation plan](docs/IMPLEMENTATION.md) for proposed validation commands and release gates.
