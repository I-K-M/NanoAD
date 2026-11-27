const std = @import("std");
const ids = @import("../provider/types.zig");
const accounting = @import("../storage/accounting.zig");
const metrics = @import("../host/metrics/types.zig");
const bounds = @import("bounds.zig");

pub const Failure = bounds.Failure;
pub const max_workloads = 32;
pub const mib: u64 = 1024 * 1024;
pub const gib: u64 = 1024 * mib;
pub const minimum_physical_reserve = 2 * gib;

pub const Entry = struct {
    id: ids.Uuid,
    phase: bounds.Phase,
    cost: bounds.Cost,
};

pub const Request = struct {
    id: ids.Uuid,
    cost: bounds.Cost,
};

pub const Credit = struct {
    id: ids.Uuid,
    inventory_revision: u64,
    memory_sample_started_ms: u64,
    // A proven, uniquely attributed lower bound already charged to this
    // exact host sample. Physical credit must be non-reclaimable. Ordinary
    // process RSS, guest allocation, estimates and stale samples are not proof.
    already_charged: bounds.Pair,
};

pub const Snapshot = struct {
    inventory_revision: u64,
    inventory_observed_ms: u64,
    memory: metrics.MemorySample,
    disk: metrics.DiskSample,
    disk_totals: accounting.Totals,
    credits: []const Credit = &.{},
    // Trusted reconciler attestations only; never taken from CLI switches or
    // untrusted manifests. System counters alone do not establish these.
    provider_reconciled: bool = false,
    host_scope_verified: bool = false,
    disk_volume_verified: bool = false,
};

pub const Budget = struct {
    // Both conservative physical and commit envelopes include shared costs
    // and must independently fit this cap, not be added to each other.
    lab_memory_limit: u64 = 3 * gib,
    physical_reserve: u64 = minimum_physical_reserve,
    commit_reserve: u64 = 512 * mib,
    shared_peak: bounds.BoundPair = .{},
    installed_disk_limit: u64 = 24_000_000_000,
    operation_disk_peak_limit: u64 = 24_000_000_000,
    host_disk_reserve: u64 = 512 * mib,
    max_sample_age_ms: u64 = 2000,
};

pub const Plan = struct {
    inventory_revision: u64,
    memory_sample_started_ms: u64,
    workload_count: usize,
    lab_peak: bounds.Pair,
    already_charged: bounds.Pair,
    additional_host: bounds.Pair,
    projected_host_available: bounds.Pair,
    disk: accounting.Plan,
};

pub const Ledger = struct {
    revision: u64,
    len: usize,
    entries: [max_workloads]Entry,

    // Caller must establish a verified inventory under the future exclusive
    // N09 lock. This in-memory model provides no thread/process synchronisation.
    pub fn init(revision: u64, entries: []const Entry) Failure!Ledger {
        if (revision == 0) return error.StaleInventory;
        if (entries.len > max_workloads) return error.Capacity;
        var result: Ledger = .{ .revision = revision, .len = entries.len, .entries = undefined };
        @memcpy(result.entries[0..entries.len], entries);
        try result.validate();
        return result;
    }

    pub fn view(self: *const Ledger) []const Entry {
        return self.entries[0..self.len];
    }

    fn validate(self: *const Ledger) Failure!void {
        if (self.revision == 0) return error.StaleInventory;
        if (self.len > max_workloads) return error.Capacity;
        for (self.view(), 0..) |entry, i| {
            if (!entry.id.valid()) return error.InvalidIdentity;
            for (self.view()[0..i]) |other| {
                if (entry.id.eql(other.id)) return error.DuplicateWorkload;
            }
        }
    }

    // Re-evaluate from fresh observations, not an earlier preview. On
    // refusal every ledger field is unchanged. Success increments revision,
    // invalidating simultaneous requests that used the previous snapshot.
    pub fn reserve(self: *Ledger, snapshot: Snapshot, budget: Budget, request: Request, now_ms: u64) Failure!Plan {
        const plan = try preview(self, snapshot, budget, request, now_ms);
        const next_revision = try accounting.add(self.revision, 1);
        self.entries[self.len] = .{ .id = request.id, .phase = .pending, .cost = request.cost };
        self.len += 1;
        self.revision = next_revision;
        return plan;
    }

    // Existing pending reservation is already included exactly once.
    // A fresh reconciled snapshot is mandatory immediately before start.
    pub fn recheck(self: *const Ledger, snapshot: Snapshot, budget: Budget, id: ids.Uuid, now_ms: u64) Failure!Plan {
        try self.validate();
        var pending = false;
        for (self.view()) |entry| {
            if (entry.id.eql(id) and entry.phase == .pending) pending = true;
        }
        if (!pending) return error.NotPending;
        return evaluate(self, snapshot, budget, null, now_ms);
    }
};

pub fn preview(ledger: *const Ledger, snapshot: Snapshot, budget: Budget, request: Request, now_ms: u64) Failure!Plan {
    try ledger.validate();
    if (ledger.len == max_workloads) return error.Capacity;
    if (!request.id.valid()) return error.InvalidIdentity;
    for (ledger.view()) |entry| {
        if (entry.id.eql(request.id)) return error.DuplicateWorkload;
    }
    return evaluate(ledger, snapshot, budget, request, now_ms);
}

fn fresh(started: u64, completed: u64, now: u64, max_age: u64) Failure!void {
    if (started > completed or completed > now or now - started > max_age)
        return error.StaleSample;
}

const Accumulator = struct {
    lab: bounds.Pair = .{},
    credit: bounds.Pair = .{},
    retained: u64 = 0,
    scratch: u64 = 0,

    fn include(self: *Accumulator, entry: Entry, credit: bounds.Pair) Failure!void {
        const envelope = try entry.cost.memory(entry.phase);
        _ = try envelope.minus(credit);
        self.lab = try self.lab.plus(envelope);
        self.credit = try self.credit.plus(credit);
        self.retained = try accounting.add(self.retained, try bounds.knownDisk(entry.cost.remaining_disk_growth));
        // Active requires reconciler evidence that startup scratch is gone
        // or already charged in the observed retained inventory.
        if (entry.phase != .active)
            self.scratch = try accounting.add(self.scratch, try bounds.knownDisk(entry.cost.temporary_disk));
    }
};

fn evaluate(ledger: *const Ledger, snapshot: Snapshot, budget: Budget, request: ?Request, now_ms: u64) Failure!Plan {
    if (snapshot.inventory_revision != ledger.revision) return error.StaleInventory;
    if (!snapshot.provider_reconciled or !snapshot.disk_volume_verified) return error.UnreconciledInventory;
    if (!snapshot.host_scope_verified) return error.UnqualifiedHost;
    if (budget.lab_memory_limit == 0 or budget.physical_reserve < minimum_physical_reserve or
        budget.commit_reserve == 0 or budget.max_sample_age_ms == 0 or budget.max_sample_age_ms > 5000)
        return error.InvalidBudget;
    try fresh(snapshot.memory.started_ms, snapshot.memory.completed_ms, now_ms, budget.max_sample_age_ms);
    try fresh(snapshot.disk.started_ms, snapshot.disk.completed_ms, now_ms, budget.max_sample_age_ms);
    try fresh(snapshot.inventory_observed_ms, snapshot.inventory_observed_ms, now_ms, budget.max_sample_age_ms);
    const total = snapshot.memory.physical_total orelse return error.InvalidHostSample;
    const available = snapshot.memory.physical_available orelse return error.InvalidHostSample;
    const commit_limit = snapshot.memory.commit_limit orelse return error.InvalidHostSample;
    const committed = snapshot.memory.committed orelse return error.InvalidHostSample;
    const disk_total = snapshot.disk.total_to_caller orelse return error.InvalidHostSample;
    const disk_available = snapshot.disk.available_to_caller orelse return error.InvalidHostSample;
    if (total == 0 or available > total or commit_limit == 0 or committed > commit_limit or
        disk_total == 0 or disk_available > disk_total) return error.InvalidHostSample;
    if (snapshot.credits.len > ledger.len) return error.InvalidCredit;

    // Shared provider/services/controller peak is charged once. There is no
    // automatic credit for an existing shared process or any memory cache.
    var acc: Accumulator = .{ .lab = try budget.shared_peak.known() };
    var used_credits: usize = 0;
    for (ledger.view()) |entry| {
        var credited: bounds.Pair = .{};
        var found = false;
        for (snapshot.credits) |credit| {
            if (!credit.id.eql(entry.id)) continue;
            if (found or entry.phase != .active or credit.inventory_revision != ledger.revision or
                credit.memory_sample_started_ms != snapshot.memory.started_ms) return error.InvalidCredit;
            found = true;
            used_credits += 1;
            credited = credit.already_charged;
        }
        try acc.include(entry, credited);
    }
    if (used_credits != snapshot.credits.len) return error.InvalidCredit;
    if (request) |r| try acc.include(.{ .id = r.id, .phase = .pending, .cost = r.cost }, .{});
    if (acc.credit.physical > total - available or acc.credit.commit > committed)
        return error.InvalidCredit;

    if (acc.lab.physical > budget.lab_memory_limit) return error.LabPhysicalLimit;
    if (acc.lab.commit > budget.lab_memory_limit) return error.LabCommitLimit;
    // The physical lab envelope plus reserve must fit actual physical RAM,
    // even if a paging file creates a very large system commit limit.
    if (try accounting.add(acc.lab.physical, budget.physical_reserve) > total)
        return error.HostPhysicalReserve;
    const additional = try acc.lab.minus(acc.credit);
    const commit_free = commit_limit - committed;
    if (try accounting.add(additional.physical, budget.physical_reserve) > available)
        return error.HostPhysicalReserve;
    if (try accounting.add(additional.commit, budget.commit_reserve) > commit_free)
        return error.HostCommitReserve;

    const disk_plan = try accounting.admit(snapshot.disk_totals, .{
        .installed_limit = budget.installed_disk_limit,
        .operation_peak_limit = budget.operation_disk_peak_limit,
        .host_available = disk_available,
        .host_reserve = budget.host_disk_reserve,
    }, acc.retained, acc.scratch);
    return .{
        .inventory_revision = ledger.revision,
        .memory_sample_started_ms = snapshot.memory.started_ms,
        .workload_count = ledger.len + @as(usize, if (request != null) 1 else 0),
        .lab_peak = acc.lab,
        .already_charged = acc.credit,
        .additional_host = additional,
        .projected_host_available = .{
            .physical = available - additional.physical,
            .commit = commit_free - additional.commit,
        },
        .disk = disk_plan,
    };
}

fn id(comptime prefix: []const u8) ids.Uuid {
    return ids.Uuid.parse(prefix ++ "1234567-89ab-cdef-0123-456789abcdef") catch unreachable;
}

fn fixtureCost(guest_mib: u64, startup_mib: u64) bounds.Cost {
    return .{
        .guest = .{ .upper_bound = guest_mib * mib },
        .steady_overhead = bounds.BoundPair.upper(128 * mib, 128 * mib),
        .startup_extra = bounds.BoundPair.upper(startup_mib * mib, startup_mib * mib),
        .remaining_disk_growth = .{ .upper_bound = 256 * mib },
        .temporary_disk = .{ .upper_bound = 128 * mib },
    };
}

fn fixtureBudget() Budget {
    return .{ .shared_peak = bounds.BoundPair.upper(128 * mib, 128 * mib) };
}

fn fixtureSnapshot(revision: u64) Snapshot {
    return .{
        .inventory_revision = revision,
        .inventory_observed_ms = 1000,
        .memory = .{
            .started_ms = 1000,
            .completed_ms = 1001,
            .physical_total = 8 * gib,
            .physical_available = 5 * gib,
            .commit_limit = 10 * gib,
            .committed = 4 * gib,
        },
        .disk = .{
            .started_ms = 1000,
            .completed_ms = 1001,
            .total_to_caller = 64 * gib,
            .available_to_caller = 32 * gib,
        },
        .disk_totals = .{ .reported_bytes = 16 * gib, .strict_upper_bound = 16 * gib },
        .provider_reconciled = true,
        .host_scope_verified = true,
        .disk_volume_verified = true,
    };
}

test "peak includes configured RAM, provider overhead and shared costs" {
    const ledger = try Ledger.init(1, &.{});
    const plan = try preview(&ledger, fixtureSnapshot(1), fixtureBudget(), .{ .id = id("1"), .cost = fixtureCost(1536, 256) }, 1002);
    try std.testing.expectEqual(@as(u64, 2048 * mib), plan.lab_peak.physical);
    try std.testing.expectEqual(@as(u64, 2048 * mib), plan.lab_peak.commit);
    try std.testing.expectEqual(@as(u64, 3 * gib), plan.projected_host_available.physical);
    try std.testing.expectEqual(@as(u64, 16 * gib + 256 * mib), plan.disk.retained_after_upper_bound);
    try std.testing.expectEqual(@as(u64, 16 * gib + 384 * mib), plan.disk.peak_upper_bound);
    try std.testing.expectEqual(@as(usize, 0), ledger.len);
}

test "concurrent stale starts refused and pending reservations charged" {
    var ledger = try Ledger.init(1, &.{});
    const first: Request = .{ .id = id("1"), .cost = fixtureCost(1536, 256) };
    const second: Request = .{ .id = id("2"), .cost = fixtureCost(1024, 128) };
    const snapshot = fixtureSnapshot(1);
    _ = try preview(&ledger, snapshot, fixtureBudget(), first, 1002);
    _ = try preview(&ledger, snapshot, fixtureBudget(), second, 1002);
    _ = try ledger.reserve(snapshot, fixtureBudget(), first, 1002);
    try std.testing.expectEqual(@as(u64, 2), ledger.revision);
    try std.testing.expectError(error.StaleInventory, ledger.reserve(snapshot, fixtureBudget(), second, 1002));
    try std.testing.expectError(error.LabPhysicalLimit, ledger.reserve(fixtureSnapshot(2), fixtureBudget(), second, 1002));
    try std.testing.expectEqual(@as(usize, 1), ledger.len);
    try std.testing.expectEqual(@as(u64, 2), ledger.revision);
    const plan = try ledger.recheck(fixtureSnapshot(2), fixtureBudget(), first.id, 1002);
    try std.testing.expectEqual(@as(u64, 2048 * mib), plan.lab_peak.physical);
    try std.testing.expectError(error.NotPending, ledger.recheck(fixtureSnapshot(2), fixtureBudget(), second.id, 1002));
    const smaller: Request = .{ .id = second.id, .cost = fixtureCost(512, 128) };
    const combined = try ledger.reserve(fixtureSnapshot(2), fixtureBudget(), smaller, 1002);
    try std.testing.expectEqual(@as(u64, 2816 * mib), combined.lab_peak.physical);
    try std.testing.expectEqual(@as(usize, 2), ledger.len);
}

test "host drift between reservation and launch fails recheck" {
    var ledger = try Ledger.init(1, &.{});
    const request: Request = .{ .id = id("1"), .cost = fixtureCost(1536, 256) };
    _ = try ledger.reserve(fixtureSnapshot(1), fixtureBudget(), request, 1002);
    var changed = fixtureSnapshot(2);
    changed.memory.physical_available = 3 * gib;
    try std.testing.expectError(error.HostPhysicalReserve, ledger.recheck(changed, fixtureBudget(), request.id, 1002));
    changed = fixtureSnapshot(2);
    changed.memory.committed = 9 * gib;
    try std.testing.expectError(error.HostCommitReserve, ledger.recheck(changed, fixtureBudget(), request.id, 1002));
    changed = fixtureSnapshot(2);
    changed.disk.available_to_caller = 600 * mib;
    try std.testing.expectError(error.HostFreeSpace, ledger.recheck(changed, fixtureBudget(), request.id, 1002));
    try std.testing.expectError(error.StaleSample, ledger.recheck(fixtureSnapshot(2), fixtureBudget(), request.id, 3001));
    try std.testing.expectEqual(@as(usize, 1), ledger.len);
}

test "unknown, estimate-only, stale and unqualified evidence rejected" {
    const ledger = try Ledger.init(1, &.{});
    var request: Request = .{ .id = id("1"), .cost = fixtureCost(1536, 256) };
    request.cost.steady_overhead.commit = .unknown;
    try std.testing.expectError(error.UnknownMemory, preview(&ledger, fixtureSnapshot(1), fixtureBudget(), request, 1002));
    request.cost = fixtureCost(1536, 256);
    request.cost.remaining_disk_growth = .{ .estimate = 1 };
    try std.testing.expectError(error.UnknownAllocation, preview(&ledger, fixtureSnapshot(1), fixtureBudget(), request, 1002));
    request.cost = fixtureCost(1536, 256);
    var snapshot = fixtureSnapshot(1);
    snapshot.host_scope_verified = false;
    try std.testing.expectError(error.UnqualifiedHost, preview(&ledger, snapshot, fixtureBudget(), request, 1002));
    snapshot = fixtureSnapshot(1);
    snapshot.disk_volume_verified = false;
    try std.testing.expectError(error.UnreconciledInventory, preview(&ledger, snapshot, fixtureBudget(), request, 1002));
    snapshot = fixtureSnapshot(1);
    snapshot.memory.commit_limit = null;
    try std.testing.expectError(error.InvalidHostSample, preview(&ledger, snapshot, fixtureBudget(), request, 1002));
    snapshot = fixtureSnapshot(1);
    snapshot.disk_totals.strict_upper_bound = null;
    try std.testing.expectError(error.UnknownAllocation, preview(&ledger, snapshot, fixtureBudget(), request, 1002));
    snapshot = fixtureSnapshot(1);
    snapshot.disk.started_ms = 1;
    try std.testing.expectError(error.StaleSample, preview(&ledger, snapshot, fixtureBudget(), request, 2002));
    try std.testing.expectError(error.StaleSample, preview(&ledger, fixtureSnapshot(1), fixtureBudget(), request, 1000));
}

test "running credits are optional, unique, fresh and never reduce lab envelope" {
    const existing = [_]Entry{.{ .id = id("1"), .phase = .active, .cost = fixtureCost(1024, 256) }};
    const ledger = try Ledger.init(1, &existing);
    const request: Request = .{ .id = id("2"), .cost = fixtureCost(1024, 128) };
    var snapshot = fixtureSnapshot(1);
    snapshot.memory.physical_available = 4 * gib;
    try std.testing.expectError(error.HostPhysicalReserve, preview(&ledger, snapshot, fixtureBudget(), request, 1002));
    var credits = [_]Credit{.{
        .id = existing[0].id,
        .inventory_revision = 1,
        .memory_sample_started_ms = 1000,
        .already_charged = .{ .physical = 1024 * mib, .commit = 1024 * mib },
    }};
    snapshot.credits = &credits;
    const plan = try preview(&ledger, snapshot, fixtureBudget(), request, 1002);
    try std.testing.expectEqual(@as(u64, 2560 * mib), plan.lab_peak.physical);
    try std.testing.expectEqual(@as(u64, 1536 * mib), plan.additional_host.physical);
    credits[0].memory_sample_started_ms = 999;
    try std.testing.expectError(error.InvalidCredit, preview(&ledger, snapshot, fixtureBudget(), request, 1002));
    credits[0].memory_sample_started_ms = 1000;
    credits[0].already_charged.physical = 1153 * mib;
    try std.testing.expectError(error.InvalidCredit, preview(&ledger, snapshot, fixtureBudget(), request, 1002));
    credits[0].already_charged.physical = 1024 * mib;
    var stopping = existing;
    stopping[0].phase = .stopping;
    const busy = try Ledger.init(1, &stopping);
    try std.testing.expectError(error.InvalidCredit, preview(&busy, snapshot, fixtureBudget(), request, 1002));
}

test "independent commit and disk limits; no paging or speculative reclamation" {
    const ledger = try Ledger.init(1, &.{});
    var request: Request = .{ .id = id("1"), .cost = fixtureCost(1536, 256) };
    request.cost.startup_extra.commit = .{ .upper_bound = 2 * gib };
    try std.testing.expectError(error.LabCommitLimit, preview(&ledger, fixtureSnapshot(1), fixtureBudget(), request, 1002));
    request.cost = fixtureCost(1536, 256);
    var budget = fixtureBudget();
    budget.installed_disk_limit = 16 * gib;
    try std.testing.expectError(error.InstalledLimit, preview(&ledger, fixtureSnapshot(1), budget, request, 1002));
    budget.installed_disk_limit = 16 * gib + 256 * mib;
    budget.operation_disk_peak_limit = 16 * gib + 383 * mib;
    try std.testing.expectError(error.PeakLimit, preview(&ledger, fixtureSnapshot(1), budget, request, 1002));
    budget = fixtureBudget();
    budget.physical_reserve = 1 * gib;
    try std.testing.expectError(error.InvalidBudget, preview(&ledger, fixtureSnapshot(1), budget, request, 1002));
    request.cost.guest = .{ .upper_bound = std.math.maxInt(u64) };
    try std.testing.expectError(error.Overflow, preview(&ledger, fixtureSnapshot(1), fixtureBudget(), request, 1002));
}
