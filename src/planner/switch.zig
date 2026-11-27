const std = @import("std");
const catalogue = @import("../modules/registry.zig");
const manifest = @import("../modules/manifest.zig");
const governor = @import("../governor/admission.zig");
const bounds = @import("../governor/bounds.zig");
const accounting = @import("../storage/accounting.zig");
const ids = @import("../provider/types.zig");

pub const max_modules = catalogue.max_modules;
pub const max_steps = 2 * max_modules;
pub const max_candidates = 10;
pub const max_alternatives = 8;
pub const Failure = bounds.Failure || manifest.Failure || error{
    InvalidInventory,
    UnknownModule,
    InvalidSelection,
    RecoveryRequired,
    UnsupportedActivation,
    DependencyConflict,
    SearchLimit,
    StalePlan,
};

pub fn bit(index: usize) u32 {
    return @as(u32, 1) << @as(u5, @intCast(index));
}

pub const Status = enum { absent, stopped, running, applied, unknown, pending, stopping };

pub const Entry = struct {
    id: manifest.Id,
    status: Status,
    // Only already provisioned guests can be started in this slice.
    guest: ?ids.Uuid = null,
    // Independently qualified provider/build-specific envelope. Manifest
    // targets and ordinary measured RSS are not admission bounds.
    cost: ?bounds.Cost = null,
};

pub const Input = struct {
    lab: ids.Uuid,
    revision: u64,
    // Stable canonical digest of the reconciled inventory, including ownership,
    // media, host boot identity and provider/build identity. Not a timestamp.
    inventory_digest: [32]u8,
    entries: []const Entry,
    pinned: u32 = 0,
    snapshot: governor.Snapshot,
    budget: governor.Budget,
};

pub const Usage = struct {
    memory: bounds.Pair = .{},
    retained: u64 = 0,
    disk_peak: u64 = 0,
};

pub const Action = enum { stop, start };
pub const Step = struct {
    action: Action,
    index: u8,
    during: Usage,
    after: Usage,
};

pub const Plan = struct {
    target: u8,
    stop_mask: u32,
    start_mask: u32,
    final_active: u32,
    steps: [max_steps]Step = undefined,
    len: usize = 0,
    peak: Usage = .{},
    final: Usage = .{},
    potential_memory_reduction: bounds.Pair = .{},
    fingerprint: [64]u8 = @splat(0),
    // Planning is not admission or permission to execute. N12 must observe
    // each stop and re-admit each start, then journal before dispatch.
    requires_recheck: bool = true,

    pub fn view(self: *const Plan) []const Step {
        return self.steps[0..self.len];
    }
};

pub const Alternatives = struct {
    eligible: u32,
    // Ask even when the keep-running plan fits. No implicit selection.
    choice_required: bool,
    keep: ?Plan = null,
    keep_error: ?Failure = null,
    options: [max_alternatives]Plan = undefined,
    len: usize = 0,
    feasible_count: usize = 0,
    rejected_count: usize = 0,
    first_rejection: ?Failure = null,
    search_limited: bool = false,
    // Independent of ranking by fewer interruptions: most economical
    // verified-in-model final memory envelope, not measured host release.
    lowest_footprint: ?Plan = null,

    pub fn view(self: *const Alternatives) []const Plan {
        return self.options[0..self.len];
    }
};

const Context = struct {
    active: u32,
    required: u32,
    eligible: u32,
    target: usize,
};

fn allMask(n: usize) u32 {
    if (n == 32) return std.math.maxInt(u32);
    return (@as(u32, 1) << @as(u5, @intCast(n))) - 1;
}

fn contains(mask: u32, index: usize) bool {
    return mask & bit(index) != 0;
}

fn closure(registry: *const catalogue.Registry, mask: u32) u32 {
    var result = mask;
    for (0..registry.len) |i| {
        if (contains(mask, i)) result |= registry.closure[i];
    }
    return result;
}

fn validSet(registry: *const catalogue.Registry, mask: u32) bool {
    if (closure(registry, mask) != mask) return false;
    for (0..registry.len) |i| {
        if (contains(mask, i) and registry.conflicts[i] & mask != 0) return false;
    }
    return true;
}

fn fresh(started: u64, completed: u64, now: u64, age: u64) Failure!void {
    if (started > completed or completed > now or now - started > age)
        return error.StaleSample;
}

fn validateSnapshot(input: Input, now: u64) Failure!void {
    const s = input.snapshot;
    const b = input.budget;
    const zero_digest: [32]u8 = @splat(0);
    if (!input.lab.valid() or input.revision == 0 or
        std.mem.eql(u8, &input.inventory_digest, &zero_digest)) return error.InvalidInventory;
    if (s.inventory_revision != input.revision) return error.StaleInventory;
    if (!s.provider_reconciled or !s.disk_volume_verified) return error.UnreconciledInventory;
    if (!s.host_scope_verified) return error.UnqualifiedHost;
    // No projection of host credits through hypothetical state transitions.
    // A verified live admission can apply N08 credits at execution time.
    if (s.credits.len != 0) return error.InvalidCredit;
    if (b.lab_memory_limit == 0 or b.physical_reserve < governor.minimum_physical_reserve or
        b.commit_reserve == 0 or b.max_sample_age_ms == 0 or b.max_sample_age_ms > 5000)
        return error.InvalidBudget;
    try fresh(s.memory.started_ms, s.memory.completed_ms, now, b.max_sample_age_ms);
    try fresh(s.disk.started_ms, s.disk.completed_ms, now, b.max_sample_age_ms);
    try fresh(s.inventory_observed_ms, s.inventory_observed_ms, now, b.max_sample_age_ms);
    const total = s.memory.physical_total orelse return error.InvalidHostSample;
    const available = s.memory.physical_available orelse return error.InvalidHostSample;
    const limit = s.memory.commit_limit orelse return error.InvalidHostSample;
    const committed = s.memory.committed orelse return error.InvalidHostSample;
    const disk_total = s.disk.total_to_caller orelse return error.InvalidHostSample;
    const disk_available = s.disk.available_to_caller orelse return error.InvalidHostSample;
    if (total == 0 or available > total or limit == 0 or committed > limit or disk_total == 0 or disk_available > disk_total)
        return error.InvalidHostSample;
    if (s.disk_totals.estimates != 0 or s.disk_totals.unknown != 0) return error.UnknownAllocation;
    const current = try s.disk_totals.strict();
    if (current < s.disk_totals.reported_bytes) return error.InvalidBound;
}

fn prepare(registry: *const catalogue.Registry, input: Input, target: manifest.Id, now: u64) Failure!Context {
    try validateSnapshot(input, now);
    if (registry.len == 0 or registry.len > max_modules or input.entries.len != registry.len)
        return error.InvalidInventory;
    if (input.pinned & ~allMask(registry.len) != 0) return error.InvalidInventory;
    if (target.len == 0 or target.len > target.bytes.len) return error.InvalidId;
    _ = try manifest.Id.parse(target.slice());
    const selected = registry.index(target) orelse return error.UnknownModule;
    const core = registry.index(try manifest.Id.parse("ad-core")) orelse return error.InvalidInventory;
    var active: u32 = 0;
    var nonstoppable: u32 = 0;
    for (input.entries, registry.view(), 0..) |entry, m, i| {
        if (entry.id.len == 0 or entry.id.len > entry.id.bytes.len or !entry.id.eql(m.id)) return error.InvalidInventory;
        switch (entry.status) {
            .unknown, .pending, .stopping => return error.RecoveryRequired,
            .running, .stopped => {
                if (m.kind != .guest) return error.UnsupportedActivation;
                const guest = entry.guest orelse return error.InvalidIdentity;
                if (!guest.valid() or guest.eql(input.lab)) return error.InvalidIdentity;
                for (input.entries[0..i]) |previous| {
                    if (previous.guest) |other| {
                        if (guest.eql(other)) return error.InvalidIdentity;
                    }
                }
                if (entry.status == .running) active |= bit(i);
            },
            .applied => {
                if (m.kind != .fixture or entry.guest != null) return error.InvalidInventory;
                active |= bit(i);
                nonstoppable |= bit(i);
            },
            .absent => if (entry.guest != null) return error.InvalidInventory,
        }
        if (!m.lifecycle.can_stop) nonstoppable |= bit(i);
    }
    if (!validSet(registry, active)) return error.DependencyConflict;
    const required = closure(registry, bit(core) | bit(selected));
    if (!validSet(registry, required)) return error.DependencyConflict;
    const protected = closure(registry, required | input.pinned | (active & nonstoppable));
    return .{
        .active = active,
        .required = required,
        .eligible = active & ~protected,
        .target = selected,
    };
}

fn costFor(entry: Entry) Failure!bounds.Cost {
    return entry.cost orelse error.UnknownMemory;
}

fn memoryFor(entry: Entry, phase: bounds.Phase) Failure!bounds.Pair {
    const cost = try costFor(entry);
    if (entry.status != .applied) {
        if (try bounds.knownMemory(cost.guest) == 0) return error.InvalidMemory;
        return cost.memory(phase);
    }
    // A persistent fixture is not a stoppable process. Account for its
    // qualified incremental steady overhead, including an explicit zero.
    if (try bounds.knownMemory(cost.guest) != 0 or phase != .active)
        return error.InvalidMemory;
    return cost.steady_overhead.known();
}

fn usage(input: Input, active: u32, ever: u32, transition: ?usize, action: Action) Failure!Usage {
    var memory = try input.budget.shared_peak.known();
    var growth: u64 = 0;
    var scratch: u64 = 0;
    for (input.entries, 0..) |entry, i| {
        if (transition != null and transition.? == i) {
            const phase: bounds.Phase = if (action == .start) .pending else .stopping;
            memory = try memory.plus(try memoryFor(entry, phase));
            scratch = try bounds.knownDisk((try costFor(entry)).temporary_disk);
        } else if (contains(active, i)) {
            memory = try memory.plus(try memoryFor(entry, .active));
        }
        // Retain even a stopped module's reserved growth for this plan.
        // Do not infer disk savings, nor forget growth from earlier steps.
        if (contains(ever, i)) growth = try accounting.add(growth, try bounds.knownDisk((try costFor(entry)).remaining_disk_growth));
    }
    const b = input.budget;
    const s = input.snapshot;
    if (memory.physical > b.lab_memory_limit) return error.LabPhysicalLimit;
    if (memory.commit > b.lab_memory_limit) return error.LabCommitLimit;
    // Same strict reservations as N08, zero host credit for projected stops.
    if (try accounting.add(memory.physical, b.physical_reserve) > s.memory.physical_total.? or
        try accounting.add(memory.physical, b.physical_reserve) > s.memory.physical_available.?)
        return error.HostPhysicalReserve;
    if (try accounting.add(memory.commit, b.commit_reserve) > s.memory.commit_limit.? - s.memory.committed.?)
        return error.HostCommitReserve;
    const disk = try accounting.admit(s.disk_totals, .{
        .installed_limit = b.installed_disk_limit,
        .operation_peak_limit = b.operation_disk_peak_limit,
        .host_available = s.disk.available_to_caller,
        .host_reserve = b.host_disk_reserve,
    }, growth, scratch);
    return .{ .memory = memory, .retained = disk.retained_after_upper_bound, .disk_peak = disk.peak_upper_bound };
}

fn maximum(a: Usage, b: Usage) Usage {
    return .{
        .memory = .{ .physical = @max(a.memory.physical, b.memory.physical), .commit = @max(a.memory.commit, b.memory.commit) },
        .retained = @max(a.retained, b.retained),
        .disk_peak = @max(a.disk_peak, b.disk_peak),
    };
}

fn appendStep(plan: *Plan, action: Action, index: usize, during: Usage, after: Usage) void {
    plan.steps[plan.len] = .{ .action = action, .index = @intCast(index), .during = during, .after = after };
    plan.len += 1;
    plan.peak = maximum(maximum(plan.peak, during), after);
    plan.final = after;
}

fn simulate(registry: *const catalogue.Registry, input: Input, context: Context, stops: u32) Failure!Plan {
    if (stops & ~context.eligible != 0) return error.InvalidSelection;
    const retained = context.active & ~stops;
    const wanted = retained | context.required;
    if (!validSet(registry, retained) or !validSet(registry, wanted)) return error.DependencyConflict;
    const starts = wanted & ~retained;
    for (input.entries, 0..) |entry, i| {
        if (contains(starts, i) and entry.status != .stopped) return error.UnsupportedActivation;
    }
    var active = context.active;
    var ever = active;
    const initial = try usage(input, active, ever, null, .start);
    var plan: Plan = .{
        .target = @intCast(context.target),
        .stop_mask = stops,
        .start_mask = starts,
        .final_active = wanted,
        .peak = initial,
        .final = initial,
    };
    // Reverse dependency order: only stop leaves of the active graph.
    while (active & stops != 0) {
        var chosen: ?usize = null;
        for (0..registry.len) |i| {
            if (!contains(active & stops, i)) continue;
            var dependent = false;
            for (0..registry.len) |j| {
                if (contains(active, j) and contains(registry.closure[j], i)) dependent = true;
            }
            if (!dependent) {
                chosen = i;
                break;
            }
        }
        const index = chosen orelse return error.DependencyConflict;
        const during = try usage(input, active, ever, index, .stop);
        const reduction = try memoryFor(input.entries[index], .active);
        plan.potential_memory_reduction = try plan.potential_memory_reduction.plus(reduction);
        active &= ~bit(index);
        const after = try usage(input, active, ever, null, .stop);
        appendStep(&plan, .stop, index, during, after);
    }
    // Dependency-first start, stable lexical order for otherwise equal choices.
    while (wanted & ~active != 0) {
        var chosen: ?usize = null;
        for (0..registry.len) |i| {
            if (contains(wanted & ~active, i) and registry.direct[i] & ~active == 0) {
                chosen = i;
                break;
            }
        }
        const index = chosen orelse return error.DependencyConflict;
        ever |= bit(index);
        const during = try usage(input, active, ever, index, .start);
        active |= bit(index);
        const after = try usage(input, active, ever, null, .start);
        appendStep(&plan, .start, index, during, after);
    }
    return plan;
}

const Hash = struct {
    sha: std.crypto.hash.sha2.Sha256 = std.crypto.hash.sha2.Sha256.init(.{}),

    fn n(self: *Hash, value: u64) void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        self.sha.update(&bytes);
    }

    fn str(self: *Hash, value: []const u8) void {
        self.n(value.len);
        self.sha.update(value);
    }

    fn optional(self: *Hash, value: ?u64) void {
        self.n(@intFromBool(value != null));
        if (value) |v| self.n(v);
    }

    fn charge(self: *Hash, value: accounting.Charge) void {
        switch (value) {
            .unknown => self.n(0),
            .estimate => |v| {
                self.n(1);
                self.n(v);
            },
            .upper_bound => |v| {
                self.n(2);
                self.n(v);
            },
        }
    }

    fn pair(self: *Hash, value: bounds.BoundPair) void {
        self.charge(value.physical);
        self.charge(value.commit);
    }

    fn cost(self: *Hash, value: bounds.Cost) void {
        self.charge(value.guest);
        self.pair(value.steady_overhead);
        self.pair(value.startup_extra);
        self.charge(value.remaining_disk_growth);
        self.charge(value.temporary_disk);
    }

    fn measured(self: *Hash, value: Usage) void {
        self.n(value.memory.physical);
        self.n(value.memory.commit);
        self.n(value.retained);
        self.n(value.disk_peak);
    }
};

fn fingerprint(registry: *const catalogue.Registry, input: Input, plan: *const Plan) [64]u8 {
    var hash: Hash = .{};
    hash.str("NanoAD/N11/plan/v1");
    hash.str(&input.lab.text);
    hash.n(input.revision);
    hash.str(&input.inventory_digest);
    hash.n(input.pinned);
    hash.n(registry.len);
    for (registry.view(), input.entries, 0..) |m, entry, i| {
        hash.str(m.id.slice());
        hash.str(m.version.slice());
        hash.str(@tagName(m.kind));
        hash.str(@tagName(m.provisioner));
        hash.n(registry.direct[i]);
        hash.n(registry.closure[i]);
        hash.n(registry.conflicts[i]);
        hash.n(@intFromBool(m.enabled_by_default));
        hash.str(@tagName(m.lifecycle.rollback_class));
        hash.n(@intFromBool(m.lifecycle.can_stop));
        hash.n(@intFromBool(m.lifecycle.can_archive));
        hash.n(@intFromBool(m.lifecycle.retain_by_default));
        hash.n(m.capabilities.len);
        for (m.capabilities.view()) |capability| hash.str(@tagName(capability));
        hash.n(m.health_checks.len);
        for (m.health_checks.view()) |health| hash.str(@tagName(health));
        hash.optional(m.resources.configured_memory_bytes);
        hash.optional(m.resources.peak_extra_memory_bytes);
        hash.optional(m.resources.steady_disk_bytes);
        hash.optional(m.resources.peak_scratch_bytes);
        hash.optional(if (m.resources.vcpus) |cpu| @as(u64, cpu) else null);
        hash.str(@tagName(m.resources.provenance));
        hash.str(@tagName(entry.status));
        hash.n(@intFromBool(entry.guest != null));
        if (entry.guest) |guest| hash.str(&guest.text);
        hash.n(@intFromBool(entry.cost != null));
        if (entry.cost) |cost| hash.cost(cost);
    }
    const s = input.snapshot;
    const b = input.budget;
    // Freshness is checked separately. Identical facts can be reobserved
    // without changing the hash solely because time advanced.
    hash.optional(s.memory.physical_total);
    hash.optional(s.memory.physical_available);
    hash.optional(s.memory.commit_limit);
    hash.optional(s.memory.committed);
    hash.optional(s.disk.total_to_caller);
    hash.optional(s.disk.available_to_caller);
    hash.n(s.disk_totals.reported_bytes);
    hash.optional(s.disk_totals.strict_upper_bound);
    hash.n(b.lab_memory_limit);
    hash.n(b.physical_reserve);
    hash.n(b.commit_reserve);
    hash.pair(b.shared_peak);
    hash.n(b.installed_disk_limit);
    hash.n(b.operation_disk_peak_limit);
    hash.n(b.host_disk_reserve);
    hash.n(b.max_sample_age_ms);
    hash.n(plan.target);
    hash.n(plan.stop_mask);
    hash.n(plan.start_mask);
    hash.n(plan.final_active);
    hash.n(plan.len);
    for (plan.view()) |step| {
        hash.str(@tagName(step.action));
        hash.n(step.index);
        hash.measured(step.during);
        hash.measured(step.after);
    }
    hash.measured(plan.peak);
    hash.measured(plan.final);
    hash.n(plan.potential_memory_reduction.physical);
    hash.n(plan.potential_memory_reduction.commit);
    var digest: [32]u8 = undefined;
    hash.sha.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn selectedPlan(registry: *const catalogue.Registry, input: Input, target: manifest.Id, stops: u32, now: u64) Failure!Plan {
    const context = try prepare(registry, input, target, now);
    var plan = try simulate(registry, input, context, stops);
    plan.fingerprint = fingerprint(registry, input, &plan);
    return plan;
}

pub fn verifyApproval(registry: *const catalogue.Registry, input: Input, target: manifest.Id, stops: u32, approved: []const u8, now: u64) Failure!Plan {
    // Recompute; never trust a caller-provided plan body. The hash binds an
    // exact choice, not user identity, authorisation or actual execution.
    const plan = try selectedPlan(registry, input, target, stops, now);
    if (!std.mem.eql(u8, approved, &plan.fingerprint)) return error.StalePlan;
    return plan;
}

fn rankLess(a: Plan, b: Plan) bool {
    const count_a = @popCount(a.stop_mask);
    const count_b = @popCount(b.stop_mask);
    if (count_a != count_b) return count_a < count_b;
    const release_a = @max(a.potential_memory_reduction.physical, a.potential_memory_reduction.commit);
    const release_b = @max(b.potential_memory_reduction.physical, b.potential_memory_reduction.commit);
    if (release_a != release_b) return release_a < release_b;
    return a.stop_mask < b.stop_mask;
}

fn footprintLess(a: Plan, b: Plan) bool {
    const peak_a = @max(a.final.memory.physical, a.final.memory.commit);
    const peak_b = @max(b.final.memory.physical, b.final.memory.commit);
    if (peak_a != peak_b) return peak_a < peak_b;
    return rankLess(a, b);
}

pub fn alternatives(registry: *const catalogue.Registry, input: Input, target: manifest.Id, now: u64) Failure!Alternatives {
    const context = try prepare(registry, input, target, now);
    var result: Alternatives = .{ .eligible = context.eligible, .choice_required = context.eligible != 0 };
    if (simulate(registry, input, context, 0)) |candidate| {
        var plan = candidate;
        plan.fingerprint = fingerprint(registry, input, &plan);
        result.keep = plan;
        result.lowest_footprint = plan;
    } else |err| {
        result.keep_error = err;
    }
    if (@popCount(context.eligible) > max_candidates) {
        // No silent heuristic or claim of exhaustive search.
        result.search_limited = true;
        return result;
    }
    // Enumerate every nonempty subset of the eligible mask (at most 1023).
    // Only model-feasible alternatives enter the ranked result.
    var subset = context.eligible;
    while (subset != 0) : (subset = (subset - 1) & context.eligible) {
        var plan = simulate(registry, input, context, subset) catch |err| {
            result.rejected_count += 1;
            if (result.first_rejection == null) result.first_rejection = err;
            continue;
        };
        result.feasible_count += 1;
        plan.fingerprint = fingerprint(registry, input, &plan);
        if (result.lowest_footprint == null or footprintLess(plan, result.lowest_footprint.?))
            result.lowest_footprint = plan;
        var index: usize = 0;
        while (index < result.len and !rankLess(plan, result.options[index])) : (index += 1) {}
        if (index == max_alternatives) continue;
        if (result.len < max_alternatives) result.len += 1;
        var j = result.len - 1;
        while (j > index) : (j -= 1) result.options[j] = result.options[j - 1];
        result.options[index] = plan;
    }
    return result;
}

const test_now: u64 = 1001;
const mib = governor.mib;
const gib = governor.gib;

fn fixtureCost(ram: u64, extra: u64) bounds.Cost {
    return .{
        .guest = .{ .upper_bound = ram * mib },
        .steady_overhead = bounds.BoundPair.upper(0, 0),
        .startup_extra = bounds.BoundPair.upper(extra * mib, extra * mib),
        .remaining_disk_growth = .{ .upper_bound = 64 * mib },
        .temporary_disk = .{ .upper_bound = 32 * mib },
    };
}

const Fixture = struct {
    registry: catalogue.Registry,
    entries: [max_modules]Entry = undefined,

    fn init() !Fixture {
        var f: Fixture = .{ .registry = try catalogue.Registry.builtin() };
        for (f.registry.view(), 0..) |m, i| f.entries[i] = .{ .id = m.id, .status = .absent };
        return f;
    }

    fn index(self: *const Fixture, name: []const u8) usize {
        return self.registry.index(manifest.Id.parse(name) catch unreachable).?;
    }

    fn guest(self: *Fixture, name: []const u8, status: Status, ram: u64, extra: u64) void {
        const i = self.index(name);
        var identity = ids.Uuid.parse("01234567-89ab-cdef-0123-456789abcdef") catch unreachable;
        identity.text[0] = "0123456789abcdef"[i];
        self.entries[i].status = status;
        self.entries[i].guest = identity;
        self.entries[i].cost = fixtureCost(ram, extra);
    }

    fn input(self: *const Fixture) Input {
        return .{
            .lab = ids.Uuid.parse("f1234567-89ab-cdef-0123-456789abcdee") catch unreachable,
            .revision = 1,
            .inventory_digest = @splat(42),
            .entries = self.entries[0..self.registry.len],
            .snapshot = .{
                .inventory_revision = 1,
                .inventory_observed_ms = 1000,
                .memory = .{ .started_ms = 1000, .completed_ms = 1000, .physical_total = 8 * gib, .physical_available = 6 * gib, .commit_limit = 12 * gib, .committed = 4 * gib },
                .disk = .{ .started_ms = 1000, .completed_ms = 1000, .total_to_caller = 64 * gib, .available_to_caller = 32 * gib },
                .disk_totals = .{ .reported_bytes = 16 * gib, .strict_upper_bound = 16 * gib },
                .provider_reconciled = true,
                .host_scope_verified = true,
                .disk_volume_verified = true,
            },
            .budget = .{ .shared_peak = bounds.BoundPair.upper(128 * mib, 128 * mib) },
        };
    }
};

test "even when keep fits, ask about optional stops; no disk release credited" {
    var f = try Fixture.init();
    f.guest("ad-core", .running, 1024, 128);
    f.guest("member-server", .running, 512, 128);
    f.guest("linux-tools", .stopped, 512, 128);
    const target = try manifest.Id.parse("linux-tools");
    const result = try alternatives(&f.registry, f.input(), target, test_now);
    try std.testing.expect(result.keep != null);
    try std.testing.expect(result.choice_required);
    try std.testing.expectEqual(@as(usize, 1), result.feasible_count);
    const plan = result.options[0];
    try std.testing.expectEqual(Action.stop, plan.steps[0].action);
    try std.testing.expectEqual(Action.start, plan.steps[1].action);
    try std.testing.expectEqual(@as(u64, 512 * mib), plan.potential_memory_reduction.physical);
    try std.testing.expectEqual(result.keep.?.final.retained, plan.final.retained);
    try std.testing.expectEqual(plan.stop_mask, result.lowest_footprint.?.stop_mask);
    try std.testing.expect(plan.requires_recheck);
}

test "combined stops make a plan fit; protect pins and dependencies" {
    var f = try Fixture.init();
    f.guest("ad-core", .running, 1024, 128);
    f.guest("member-server", .running, 512, 128);
    f.guest("linux-tools", .running, 512, 128);
    f.guest("adcs", .stopped, 1536, 128);
    const target = try manifest.Id.parse("adcs");
    const both = bit(f.index("member-server")) | bit(f.index("linux-tools"));
    const result = try alternatives(&f.registry, f.input(), target, test_now);
    try std.testing.expectEqual(error.LabPhysicalLimit, result.keep_error.?);
    try std.testing.expectEqual(@as(usize, 1), result.feasible_count);
    try std.testing.expectEqual(both, result.options[0].stop_mask);
    try std.testing.expectEqual(@as(usize, 3), result.options[0].len);
    try std.testing.expectError(error.InvalidSelection, selectedPlan(&f.registry, f.input(), target, bit(f.index("ad-core")), test_now));
    var pinned = f.input();
    pinned.pinned = bit(f.index("member-server"));
    const blocked = try alternatives(&f.registry, pinned, target, test_now);
    try std.testing.expect(blocked.keep == null);
    try std.testing.expectEqual(@as(usize, 0), blocked.feasible_count);
}

test "starts prerequisites first and rejects absent or unknown costs" {
    var f = try Fixture.init();
    f.guest("ad-core", .stopped, 1024, 128);
    f.guest("member-server", .stopped, 512, 128);
    const target = try manifest.Id.parse("member-server");
    const plan = try selectedPlan(&f.registry, f.input(), target, 0, test_now);
    try std.testing.expectEqual(@as(u8, @intCast(f.index("ad-core"))), plan.steps[0].index);
    try std.testing.expectEqual(@as(u8, @intCast(f.index("member-server"))), plan.steps[1].index);
    f.entries[f.index("member-server")].cost = null;
    try std.testing.expectError(error.UnknownMemory, selectedPlan(&f.registry, f.input(), target, 0, test_now));
    f.entries[f.index("member-server")].status = .unknown;
    try std.testing.expectError(error.RecoveryRequired, selectedPlan(&f.registry, f.input(), target, 0, test_now));
    f.entries[f.index("member-server")] = .{ .id = target, .status = .absent };
    try std.testing.expectError(error.UnsupportedActivation, selectedPlan(&f.registry, f.input(), target, 0, test_now));
}

test "approval binds exact choices, state and budget, but fresh identical observations work" {
    var f = try Fixture.init();
    f.guest("ad-core", .running, 1024, 128);
    f.guest("member-server", .running, 512, 128);
    f.guest("linux-tools", .stopped, 512, 128);
    const target = try manifest.Id.parse("linux-tools");
    const stops = bit(f.index("member-server"));
    const plan = try selectedPlan(&f.registry, f.input(), target, stops, test_now);
    _ = try verifyApproval(&f.registry, f.input(), target, stops, &plan.fingerprint, test_now);
    try std.testing.expectError(error.StalePlan, verifyApproval(&f.registry, f.input(), target, 0, &plan.fingerprint, test_now));
    var changed = f.input();
    changed.budget.lab_memory_limit += mib;
    try std.testing.expectError(error.StalePlan, verifyApproval(&f.registry, changed, target, stops, &plan.fingerprint, test_now));
    changed = f.input();
    changed.snapshot.memory.physical_available.? -= mib;
    try std.testing.expectError(error.StalePlan, verifyApproval(&f.registry, changed, target, stops, &plan.fingerprint, test_now));
    changed = f.input();
    changed.inventory_digest[0] ^= 1;
    try std.testing.expectError(error.StalePlan, verifyApproval(&f.registry, changed, target, stops, &plan.fingerprint, test_now));
    try std.testing.expectError(error.StaleSample, verifyApproval(&f.registry, f.input(), target, stops, &plan.fingerprint, 4000));
    changed = f.input();
    changed.snapshot.memory.started_ms = 1100;
    changed.snapshot.memory.completed_ms = 1100;
    changed.snapshot.disk.started_ms = 1100;
    changed.snapshot.disk.completed_ms = 1100;
    changed.snapshot.inventory_observed_ms = 1100;
    _ = try verifyApproval(&f.registry, changed, target, stops, &plan.fingerprint, 1101);
}

test "no projected host release, disk retention or startup peak bypass" {
    var f = try Fixture.init();
    f.guest("ad-core", .running, 1024, 128);
    f.guest("member-server", .running, 512, 128);
    f.guest("linux-tools", .stopped, 512, 128);
    const target = try manifest.Id.parse("linux-tools");
    const stops = bit(f.index("member-server"));
    var input = f.input();
    input.snapshot.memory.physical_available = 3 * gib;
    try std.testing.expectError(error.HostPhysicalReserve, selectedPlan(&f.registry, input, target, stops, test_now));
    input = f.input();
    input.budget.operation_disk_peak_limit = 16 * gib + 128 * mib;
    input.budget.installed_disk_limit = 16 * gib + 128 * mib;
    try std.testing.expectError(error.PeakLimit, selectedPlan(&f.registry, input, target, stops, test_now));
    input = f.input();
    f.entries[f.index("linux-tools")].cost.?.startup_extra = bounds.BoundPair.upper(2 * gib, 2 * gib);
    try std.testing.expectError(error.LabPhysicalLimit, selectedPlan(&f.registry, input, target, stops, test_now));
}

test "dependent stops precede prerequisites and pins protect both" {
    var f = try Fixture.init();
    f.guest("ad-core", .running, 1024, 128);
    f.guest("member-server", .running, 256, 64);
    f.guest("second-dc", .running, 256, 64);
    f.guest("linux-tools", .stopped, 512, 128);
    const member = f.index("member-server");
    const secondary = f.index("second-dc");
    // Synthetic valid graph extension: second-dc depends on member-server.
    f.registry.direct[secondary] |= bit(member);
    f.registry.closure[secondary] |= bit(member);
    const target = try manifest.Id.parse("linux-tools");
    try std.testing.expectError(error.DependencyConflict, selectedPlan(&f.registry, f.input(), target, bit(member), test_now));
    const plan = try selectedPlan(&f.registry, f.input(), target, bit(member) | bit(secondary), test_now);
    try std.testing.expectEqual(@as(u8, @intCast(secondary)), plan.steps[0].index);
    try std.testing.expectEqual(@as(u8, @intCast(member)), plan.steps[1].index);
    var pinned = f.input();
    pinned.pinned = bit(secondary);
    const result = try alternatives(&f.registry, pinned, target, test_now);
    try std.testing.expect(!result.choice_required);
    try std.testing.expectEqual(@as(u32, 0), result.eligible);
}

test "conflicting active guest must be explicitly selected to stop" {
    var f = try Fixture.init();
    f.guest("ad-core", .running, 1024, 128);
    f.guest("member-server", .running, 512, 128);
    f.guest("linux-tools", .stopped, 512, 128);
    const member = f.index("member-server");
    const tools = f.index("linux-tools");
    f.registry.conflicts[member] |= bit(tools);
    f.registry.conflicts[tools] |= bit(member);
    const target = try manifest.Id.parse("linux-tools");
    const result = try alternatives(&f.registry, f.input(), target, test_now);
    try std.testing.expectEqual(error.DependencyConflict, result.keep_error.?);
    try std.testing.expect(result.choice_required);
    try std.testing.expectEqual(@as(usize, 1), result.feasible_count);
    try std.testing.expectEqual(bit(member), result.options[0].stop_mask);
    f.entries[tools].cost.?.startup_extra.physical = .{ .estimate = 128 * mib };
    const unknown = try alternatives(&f.registry, f.input(), target, test_now);
    try std.testing.expectEqual(@as(usize, 0), unknown.feasible_count);
    try std.testing.expectEqual(error.UnknownMemory, unknown.first_rejection.?);
}

test "invalid identity lengths fail closed" {
    var f = try Fixture.init();
    f.guest("ad-core", .running, 1024, 128);
    f.guest("linux-tools", .stopped, 512, 128);
    var target = try manifest.Id.parse("linux-tools");
    target.len = 255;
    try std.testing.expectError(error.InvalidId, selectedPlan(&f.registry, f.input(), target, 0, test_now));
    target = try manifest.Id.parse("linux-tools");
    f.entries[f.index("linux-tools")].id.len = 255;
    try std.testing.expectError(error.InvalidInventory, selectedPlan(&f.registry, f.input(), target, 0, test_now));
}
