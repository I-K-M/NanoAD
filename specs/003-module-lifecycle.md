# NAN-003 — On-demand modules and lifecycle

Status: proposed | Parent: [NAN-001](001-nanoad.md)

## 1. Module model

Modules are trusted, reviewed, versioned declarative definitions shipped with NanoAD. Four types: fixture (directory data/configuration), role (guest feature/service), guest (additional VM), and tool (local or isolated tool). A fixture may have almost no marginal RAM but can alter persistent state. Stopping a role cannot be assumed to undo directory/schema modifications.

Minimal core: one DC with AD DS, DNS, necessary native services, synthetic administrator and test accounts. No optional role, additional guest, tool or exercise fixture is fetched, provisioned or started on initialisation or core start.

| Module ID | Type | Prerequisites | Initial phase |
| --- | --- | --- | --- |
| ad-core | guest | base + private network | MVP |
| directory-fixtures | fixture | ad-core | v0.2 |
| kerberos-policy | fixture | ad-core | v0.2 |
| acl-gpo | fixture | ad-core | v0.2 |
| member-server | guest | ad-core | v0.2 |
| linux-tools | guest/tool | private network | v0.2 |
| adcs | role/guest | ad-core; dedicated CA guest preferred | later |
| second-dc | guest | ad-core; provider qualified for replication | later |
| child-domain | guest | ad-core | later |
| forest-trust | guest | separate forest and private network | later |
| windows-workstation | guest | ad-core, licensed client media | later |
| ntlm-policy | fixture | ad-core | later |
| delegation | fixture | ad-core; topology as needed | later |
| laps/gmsa | fixture/role | supported build and prerequisites | later |
| iis/smb/mssql | role/guest | qualified member guest | later |
| audit-analysis/sysmon | tool/role | appropriate Windows guest | later |
| bloodhound | tool | explicitly requested data; optional backend | later |
| linux-member | guest | ad-core | later |
| detection/hardening | fixture/tool | relevant active module | later |

This is a catalogue of planned capabilities, not a set of installed modules. Roles may have multiple implementations (co-located or dedicated) only after equivalence and recovery tests. Never choose a co-located variant silently if it changes the exercise's topology.

## 2. Manifest contract (schema version 1 draft)

```json
{
  "schema_version": 1,
  "id": "member-server",
  "version": "0.1.0",
  "kind": "guest",
  "enabled_by_default": false,
  "requires": ["ad-core"],
  "conflicts": [],
  "capabilities": ["private_network", "differencing_disk"],
  "resources": {
    "configured_memory_bytes": 2147483648,
    "peak_extra_memory_bytes": null,
    "steady_disk_bytes": null,
    "peak_scratch_bytes": null,
    "vcpus": 1,
    "provenance": "unmeasured"
  },
  "lifecycle": {
    "rollback_class": "rebuild",
    "can_stop": true,
    "can_archive": true,
    "retain_by_default": true
  },
  "provisioner": "windows-member-v1",
  "health_checks": ["guest-ready", "domain-membership"]
}
```

Null means unknown, never zero. Units are integers in bytes, with range/overflow checks. Use a closed registry of built-in provisioners and health checks; reject unsupported or unknown keys, duplicate IDs, cyclic dependencies, excessive size/depth, invalid paths and external URLs in manifests. No arbitrary execution hooks. Separate manifest version from measured provider/build-specific resource envelope. Default optional flag must be false. Pins are user state, not manifest defaults.

## 3. States

- ABSENT: no specific artefact or running process.
- CACHED: verified payload available, not installed.
- PROVISIONED: resources created, inactive where architecture permits.
- RUNNING: active and readiness established.
- ARCHIVED: stopped; retained compressed artefacts verified; no guest process.
- FAILED / UNKNOWN: observation or operation incomplete; reconcile before further mutation.
- PURGED: audit record only; material artefacts removed with consent.

Track desired and observed state separately. Persist transition intent before side effects and record stable provider identifiers. The DC is a mandatory dependency while active modules require it; down may stop the entire lab in reverse order. A fixture that cannot be removed safely is marked persistent and requires explicit rebuild or separate topology. Never pretend an installed role with active processes is stopped.

## 4. Switch and admission algorithm

1. Lock the lab; reconcile owned provider IDs, active state, pins, actual free capacity and resource envelopes.
2. Resolve transitive prerequisites and conflicts; construct candidate activation plan without mutation. Deduplicate shared dependencies.
3. Compute peak memory and physical disk requirements for each sequential step (including shutdown, startup, archive and scratch). Check lab caps, actual host available/commit, provider overhead and safety reserve. Report unknown values.
4. If over budget or if optional active components are no longer needed, list eligible deactivations and their actual/estimated released memory, retained disk, stop cost and dependent modules. Prefer minimal total active footprint; sort deterministic alternatives by feasibility, user pins, fewer interruptions, then smallest excess release. Do not stop anything merely because idle without consent.
5. Ask whether to deactivate eligible modules even when the new workload fits, when doing so reduces unnecessary simultaneous activity. Choices: keep active if within budget; stop selected; archive separately; cancel; explicitly edit budget and re-plan. Never offer an infeasible selection as sufficient.
6. Show ordered plan and fingerprint, predicted peak and final usage, dependencies, persistent changes, retention and risk. Default confirmation is no. Non-interactive callers supply approved plan hash; if a new prompt is needed, return a conflict.
7. Re-observe capacity and state just before mutation. Journal intent. Shut down selected guests cleanly in reverse dependency order; verify actual stopped state and released budget. Retain overlays by default.
8. Start/provision needed modules in dependency order, with timeouts and health checks. Never temporarily exceed the admitted peak. Failure stops new work.
9. Commit observed and desired state atomically. On failure, compensate only operations known safe (e.g. stop a newly started guest, re-start a previously stopped one if headroom permits). For persistent AD changes, record recovery/rebuild instructions; do not claim rollback succeeded without verification.
10. Release lock, print result, emit sanitised structured record.

## 5. UX example (illustrative, not implemented)

```text
$ nanoad enable adcs
Plan: start dedicated certificate-services guest
Lab budget: 3072 MiB
Reserved now: 2560 MiB
Additional peak: 1536 MiB
Shortfall: 1024 MiB

Eligible options:
  1. Stop member-server; retain disk; release 1536 MiB
  2. Cancel
Pinned: ad-core (required by requested module)

Select: 1
Projected peak: 2560 MiB; retained disk: unchanged.
Proceed? [y/N]
```

Costs above are examples, not measurements. If the host has changed since the plan, refuse and regenerate rather than proceeding. Stopping must free memory before a new guest starts. Stopping alone does not free retained storage.

## 6. CLI contract

| Command | Semantics |
| --- | --- |
| doctor | Read-only host capability and isolation checks |
| init | Create local configuration and state only |
| image build / import / list | Explicit media acquisition/build/import; verify provenance |
| up / down | Start core / gracefully stop selected lab, no purge |
| status / resources | Observed state, budget, actual vs estimated resource use |
| modules list / info | List metadata and dependency costs, no download |
| enable / disable | Plan and execute explicit module activation/deactivation |
| switch | Combined transactional stop/start with approval |
| pin / unpin | Protect module from automatic eligibility; explicit unpin |
| budget | Display or set limits with preflight |
| health | Read-only guest/native behaviour checks |
| benchmark | Explicit test run; separate scratch/peak admission |
| scenario load / reset | Provision fixture or deterministic rebuild, explicit plan |
| archive / restore / compact / gc | Offline or capability-checked operations; dry-run and consent |
| destroy | Explicit owned-lab deletion only; strong confirmation |

Global options: --lab, --json, --dry-run for mutating planning, --non-interactive, --approve-plan for non-interactive approved mutations. Exit codes: 0 success; 2 invalid input; 3 unmet prerequisites; 4 resource refusal; 5 cancelled/approval required; 6 provider/guest failure; 7 recovery required; 8 unsupported capability. JSON output includes schema_version, command, result, plan_id where relevant, errors and measured/estimated/unknown tags. No secrets in stdout or stderr. Bound subprocess duration and captured output; do not use shell concatenation. Every command must operate on explicitly owned lab resources only.

## 7. Verification

Unit tests: dependency cycles, duplicates, closure, pins, conflicting modules, arithmetic overflow, unknown cost, combined stops, deterministic plan order and stale fingerprint. Fake-provider integration tests: decline no mutation, stop-before-start, failed shutdown, failed health, restart recovery, concurrent writer lock, external drift, no automatic purge, non-interactive fail closed. Real-provider tests: confirm observed stop, measured memory release, retained state, dependency health, isolation and no orphaned processes. Failure injection must include every persisted lifecycle step. Release only with corresponding evidence.
