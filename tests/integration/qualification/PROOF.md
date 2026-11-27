# N15a proof pack

- Scope: static integration audit Q01–Q11, honest platform compatibility matrix, AC-01–AC-11 evidence mapping and reproducible reference/replication procedure; bounded offline structured report checker and synthetic tests. Parent: [N15](../../../tickets/001-nanoad/N15-independent-qualification.md).
- Decisions: separate 60 min finalist soak after at least three idle/workload repetitions; second host and operator, exact input identity, 8 GiB installed RAM and 24 GB strict physical upper bound; reject missing/unknown metrics and regressions rather than estimate. No supported profile can be declared by this checker.
- Validation: PowerShell 5.1/7 syntax and pure synthetic tests in dedicated CI; required Zig Windows/Linux checks remain enabled. Inspect actual runs. No native domain, provider, host or independent reproduction tested.
- Findings: Q01–Q06 P0 integration gates; Q07–Q11 P1 runtime/durability/qualification risks. No broader production code modification or real activation. Independent review unavailable in this implementing session.
- Supporting ticket, trace and CI changes are proposed explicitly. No new runtime dependency, data migration, paid resources, guest or host mutation. Rollback: revert scoped commits, preserve any existing evidence and state.
