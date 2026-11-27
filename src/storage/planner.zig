const std = @import("std");
const cat = @import("../image/catalogue.zig");
const ids = @import("../provider/types.zig");
const Digest = @import("../image/digest.zig").Digest;
const accounting = @import("accounting.zig");

pub const OverlayPlan = struct {
    parent_medium: ids.Uuid,
    parent_digest: Digest,
    owner: ids.OwnedGuest,
    target: [49]u8,
    virtual_bytes: u64,
    allocation: accounting.Plan,
    // Initial creation envelope only; subsequent writes need admission.
    future_growth_reserved: bool = false,
};

pub fn planOverlay(catalogue: cat.Catalogue, parent_id: ids.Uuid, observed_digest: Digest, owner: ids.OwnedGuest, budget: accounting.Budget, creation_upper_bound: ?u64, scratch_upper_bound: ?u64) cat.Failure!OverlayPlan {
    try catalogue.requireReconciled();
    if (!owner.valid() or !owner.lab.eql(catalogue.lab)) return error.InvalidIdentity;
    if (catalogue.disks.len >= cat.max_disks) return error.CatalogueLimit;
    const parent = catalogue.find(parent_id) orelse return error.NotFound;
    const base = switch (parent.role) {
        .base => |b| b,
        .overlay => return error.NestedOverlay,
    };
    if (!observed_digest.eql(base.digest)) return error.BaseDigestMismatch;
    for (catalogue.disks) |disk| switch (disk.role) {
        .overlay => |o| {
            if (owner.guest.eql(o.owner.guest) or owner.vm.eql(o.owner.vm)) return error.DuplicateGuest;
        },
        .base => {},
    };
    const new = creation_upper_bound orelse return error.UnknownAllocation;
    if (new == 0) return error.InvalidBound;
    return .{
        .parent_medium = parent_id,
        .parent_digest = base.digest,
        .owner = owner,
        .target = try cat.overlayPath(owner.guest),
        .virtual_bytes = parent.virtual_bytes,
        .allocation = try accounting.admit(try catalogue.totals(), budget, new, scratch_upper_bound),
    };
}

// Observed provider postconditions after a future explicitly authorised
// creation. Path must already be resolved inside the trusted lab root.
// This does not execute, register, attach or commit any medium.
pub const CreatedOverlay = struct {
    medium: ids.Uuid,
    parent: ids.Uuid,
    parent_digest_after: Digest,
    relative_target: []const u8,
    virtual_bytes: u64,
    file_length: u64,
    dynamic_vdi: bool,
    detached: bool,
    charge: accounting.Charge,
};

pub fn verifyCreatedOverlay(catalogue: cat.Catalogue, plan: OverlayPlan, observed: CreatedOverlay) cat.Failure!void {
    try catalogue.requireReconciled();
    if (!plan.owner.valid() or !plan.owner.lab.eql(catalogue.lab)) return error.InvalidIdentity;
    const target = try cat.overlayPath(plan.owner.guest);
    if (!std.mem.eql(u8, &target, &plan.target)) return error.StalePlan;
    const parent = catalogue.find(plan.parent_medium) orelse return error.StalePlan;
    const base = switch (parent.role) {
        .base => |b| b,
        .overlay => return error.StalePlan,
    };
    if (!base.digest.eql(plan.parent_digest) or parent.virtual_bytes != plan.virtual_bytes or
        try (try catalogue.totals()).strict() != plan.allocation.current_bytes) return error.StalePlan;
    for (catalogue.disks) |disk| switch (disk.role) {
        .overlay => |o| {
            if (plan.owner.guest.eql(o.owner.guest) or plan.owner.vm.eql(o.owner.vm)) return error.StalePlan;
        },
        .base => {},
    };
    if (!observed.parent_digest_after.eql(plan.parent_digest)) return error.BaseDigestMismatch;
    if (!observed.medium.valid() or catalogue.find(observed.medium) != null or
        !observed.parent.eql(plan.parent_medium) or !std.mem.eql(u8, observed.relative_target, &plan.target) or
        observed.virtual_bytes != plan.virtual_bytes or observed.file_length == 0 or
        !observed.dynamic_vdi or !observed.detached) return error.InvalidChild;
    const actual = switch (observed.charge) {
        .upper_bound => |n| n,
        else => return error.UnknownAllocation,
    };
    const retained = std.math.sub(u64, plan.allocation.retained_after_upper_bound, plan.allocation.current_bytes) catch return error.StalePlan;
    if (actual > retained) return error.AllocationExceeded;
    // Caller must reconcile all auxiliary allocation and recheck the full
    // inventory before committing ownership. No successful mutation is implied.
}

pub const CompactionPlan = struct {
    medium: ids.Uuid,
    allocation: accounting.Plan,
    // Never credit future savings or overwrite a retained original.
    keep_original: bool = true,
    savings_promised: bool = false,
};

pub fn planCompaction(catalogue: cat.Catalogue, medium: ids.Uuid, budget: accounting.Budget, staging_upper_bound: ?u64, work_upper_bound: ?u64) cat.Failure!CompactionPlan {
    try catalogue.requireReconciled();
    const disk = catalogue.find(medium) orelse return error.NotFound;
    switch (disk.role) {
        .base => return error.BaseProtected,
        .overlay => {},
    }
    if (disk.pinned) return error.Pinned;
    // Compaction staging needs a detached overlay, not merely a stopped VM.
    if (disk.attachment != .detached) return error.NotDetached;
    const length = disk.file_length orelse return error.UnknownAllocation;
    const bound = switch (disk.charge) {
        .upper_bound => |n| n,
        else => return error.UnknownAllocation,
    };
    const stage = staging_upper_bound orelse return error.UnknownAllocation;
    if (stage < @max(length, bound)) return error.InvalidScratch;
    const scratch = try accounting.add(stage, work_upper_bound orelse return error.UnknownAllocation);
    return .{
        .medium = medium,
        .allocation = try accounting.admit(try catalogue.totals(), budget, 0, scratch),
    };
}

// Pure recovery policy for staging. The real journal owns durable phases,
// exclusive locking and final replacement; this model never deletes files.
pub const ReclaimState = enum { planned, staging, staged, verified, recovery_required };
pub const ReclaimEvent = enum { begin, staged, verified, interrupted };
pub fn advance(state: ReclaimState, event: ReclaimEvent) error{InvalidTransition}!ReclaimState {
    if (event == .interrupted) return .recovery_required;
    return switch (state) {
        .planned => if (event == .begin) .staging else error.InvalidTransition,
        .staging => if (event == .staged) .staged else error.InvalidTransition,
        .staged => if (event == .verified) .verified else error.InvalidTransition,
        .verified, .recovery_required => error.InvalidTransition,
    };
}

const example_budget: accounting.Budget = .{
    .installed_limit = 160,
    .operation_peak_limit = 200,
    .host_available = 100,
    .host_reserve = 10,
};

test "overlay plan uses one base and explicit creation envelope" {
    const disks = [_]cat.Disk{ cat.example_base, cat.exampleOverlay("3", "4", "5") };
    const catalogue = cat.exampleCatalogue(&disks);
    const owner = cat.exampleOwner("7", "8");
    const plan = try planOverlay(catalogue, cat.example_base.medium, cat.example_digest, owner, example_budget, 10, 5);
    try std.testing.expectEqual(@as(u64, 125), plan.allocation.retained_after_upper_bound);
    try std.testing.expectEqual(@as(u64, 130), plan.allocation.peak_upper_bound);
    try std.testing.expect(!plan.future_growth_reserved);
    try std.testing.expectError(error.DuplicateGuest, planOverlay(catalogue, cat.example_base.medium, cat.example_digest, disks[1].role.overlay.owner, example_budget, 10, 5));
    try std.testing.expectError(error.BaseDigestMismatch, planOverlay(catalogue, cat.example_base.medium, .{ .bytes = @splat(0) }, owner, example_budget, 10, 5));
    try std.testing.expectError(error.InstalledLimit, planOverlay(catalogue, cat.example_base.medium, cat.example_digest, owner, example_budget, 60, 5));
    try std.testing.expectError(error.UnknownAllocation, planOverlay(catalogue, cat.example_base.medium, cat.example_digest, owner, example_budget, null, 5));
}

test "offline compaction reserves staging and never promises savings" {
    var disks = [_]cat.Disk{ cat.example_base, cat.exampleOverlay("3", "4", "5") };
    const catalogue = cat.exampleCatalogue(&disks);
    const plan = try planCompaction(catalogue, disks[1].medium, example_budget, 20, 5);
    try std.testing.expectEqual(@as(u64, 140), plan.allocation.peak_upper_bound);
    try std.testing.expect(plan.keep_original);
    try std.testing.expect(!plan.savings_promised);
    try std.testing.expectError(error.InvalidScratch, planCompaction(catalogue, disks[1].medium, example_budget, 9, 5));
    try std.testing.expectError(error.PeakLimit, planCompaction(catalogue, disks[1].medium, example_budget, 90, 5));
    disks[1].attachment = .active_guest;
    try std.testing.expectError(error.NotDetached, planCompaction(catalogue, disks[1].medium, example_budget, 20, 5));
}

test "every interrupted compaction phase requires recovery, never deletion" {
    for ([_]ReclaimState{ .planned, .staging, .staged, .verified, .recovery_required }) |state| {
        try std.testing.expectEqual(ReclaimState.recovery_required, try advance(state, .interrupted));
    }
    try std.testing.expectEqual(ReclaimState.verified, try advance(try advance(try advance(.planned, .begin), .staged), .verified));
    try std.testing.expectError(error.InvalidTransition, advance(.planned, .verified));
    try std.testing.expectError(error.InvalidTransition, advance(.recovery_required, .begin));
}

test "created overlay postconditions reject identity, parent, path and cost drift" {
    const disks = [_]cat.Disk{cat.example_base};
    const catalogue = cat.exampleCatalogue(&disks);
    const plan = try planOverlay(catalogue, cat.example_base.medium, cat.example_digest, cat.exampleOwner("4", "5"), example_budget, 10, 5);
    var observed: CreatedOverlay = .{
        .medium = cat.exampleId("3"),
        .parent = plan.parent_medium,
        .parent_digest_after = cat.example_digest,
        .relative_target = &plan.target,
        .virtual_bytes = plan.virtual_bytes,
        .file_length = 5,
        .dynamic_vdi = true,
        .detached = true,
        .charge = .{ .upper_bound = 5 },
    };
    try verifyCreatedOverlay(catalogue, plan, observed);
    observed.relative_target = "../outside.vdi";
    try std.testing.expectError(error.InvalidChild, verifyCreatedOverlay(catalogue, plan, observed));
    observed.relative_target = &plan.target;
    observed.medium = plan.parent_medium;
    try std.testing.expectError(error.InvalidChild, verifyCreatedOverlay(catalogue, plan, observed));
    observed.medium = cat.exampleId("3");
    observed.parent = cat.exampleId("9");
    try std.testing.expectError(error.InvalidChild, verifyCreatedOverlay(catalogue, plan, observed));
    observed.parent = plan.parent_medium;
    observed.charge = .{ .estimate = 5 };
    try std.testing.expectError(error.UnknownAllocation, verifyCreatedOverlay(catalogue, plan, observed));
    observed.charge = .{ .upper_bound = 11 };
    try std.testing.expectError(error.AllocationExceeded, verifyCreatedOverlay(catalogue, plan, observed));
    observed.charge = .{ .upper_bound = 5 };
    var drift = catalogue;
    drift.auxiliary_charge = .{ .upper_bound = 6 };
    try std.testing.expectError(error.StalePlan, verifyCreatedOverlay(drift, plan, observed));
    observed.parent_digest_after.bytes[0] ^= 1;
    try std.testing.expectError(error.BaseDigestMismatch, verifyCreatedOverlay(catalogue, plan, observed));
}
