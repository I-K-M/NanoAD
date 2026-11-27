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
        .base => return error.UnsealedBase,
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

const budget: accounting.Budget = .{
    .installed_limit = 160,
    .operation_peak_limit = 200,
    .host_available = 100,
    .host_reserve = 10,
};

test "overlay plan uses one base and explicit creation envelope" {
    const disks = [_]cat.Disk{ cat.example_base, cat.exampleOverlay("3", "4", "5") };
    const catalogue = cat.exampleCatalogue(&disks);
    const owner = cat.exampleOwner("7", "8");
    const plan = try planOverlay(catalogue, cat.example_base.medium, cat.example_digest, owner, budget, 10, 5);
    try std.testing.expectEqual(@as(u64, 125), plan.allocation.retained_after_upper_bound);
    try std.testing.expectEqual(@as(u64, 130), plan.allocation.peak_upper_bound);
    try std.testing.expect(!plan.future_growth_reserved);
    try std.testing.expectError(error.DuplicateGuest, planOverlay(catalogue, cat.example_base.medium, cat.example_digest, disks[1].role.overlay.owner, budget, 10, 5));
    try std.testing.expectError(error.BaseDigestMismatch, planOverlay(catalogue, cat.example_base.medium, .{ .bytes = @splat(0) }, owner, budget, 10, 5));
    try std.testing.expectError(error.InstalledLimit, planOverlay(catalogue, cat.example_base.medium, cat.example_digest, owner, budget, 60, 5));
    try std.testing.expectError(error.UnknownAllocation, planOverlay(catalogue, cat.example_base.medium, cat.example_digest, owner, budget, null, 5));
}

test "offline compaction reserves staging and never promises savings" {
    var disks = [_]cat.Disk{ cat.example_base, cat.exampleOverlay("3", "4", "5") };
    const catalogue = cat.exampleCatalogue(&disks);
    const plan = try planCompaction(catalogue, disks[1].medium, budget, 20, 5);
    try std.testing.expectEqual(@as(u64, 140), plan.allocation.peak_upper_bound);
    try std.testing.expect(plan.keep_original);
    try std.testing.expect(!plan.savings_promised);
    try std.testing.expectError(error.InvalidScratch, planCompaction(catalogue, disks[1].medium, budget, 9, 5));
    try std.testing.expectError(error.PeakLimit, planCompaction(catalogue, disks[1].medium, budget, 90, 5));
    disks[1].attachment = .active_guest;
    try std.testing.expectError(error.NotDetached, planCompaction(catalogue, disks[1].medium, budget, 20, 5));
}

test "every interrupted compaction phase requires recovery, never deletion" {
    for ([_]ReclaimState{ .planned, .staging, .staged, .verified, .recovery_required }) |state| {
        try std.testing.expectEqual(ReclaimState.recovery_required, try advance(state, .interrupted));
    }
    try std.testing.expectEqual(ReclaimState.verified, try advance(try advance(try advance(.planned, .begin), .staged), .verified));
    try std.testing.expectError(error.InvalidTransition, advance(.planned, .verified));
    try std.testing.expectError(error.InvalidTransition, advance(.recovery_required, .begin));
}
