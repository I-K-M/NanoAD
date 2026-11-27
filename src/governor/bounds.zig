const std = @import("std");
const accounting = @import("../storage/accounting.zig");

// Same provenance semantics as NanoDisk. Estimates and unknown costs cannot
// become strict bounds just because they are positive or manually supplied.
pub const Bound = accounting.Charge;
pub const Failure = accounting.Failure || error{
    UnknownMemory,
    InvalidMemory,
    InvalidBudget,
    InvalidHostSample,
    StaleSample,
    UnqualifiedHost,
    StaleInventory,
    UnreconciledInventory,
    InvalidCredit,
    LabPhysicalLimit,
    LabCommitLimit,
    HostPhysicalReserve,
    HostCommitReserve,
    DuplicateWorkload,
    InvalidIdentity,
    Capacity,
    NotPending,
};

pub fn knownMemory(bound: Bound) Failure!u64 {
    return switch (bound) {
        .upper_bound => |n| n,
        .estimate, .unknown => error.UnknownMemory,
    };
}

pub fn knownDisk(bound: Bound) Failure!u64 {
    return switch (bound) {
        .upper_bound => |n| n,
        .estimate, .unknown => error.UnknownAllocation,
    };
}

pub const Pair = struct {
    physical: u64 = 0,
    commit: u64 = 0,

    pub fn plus(a: Pair, b: Pair) Failure!Pair {
        return .{
            .physical = try accounting.add(a.physical, b.physical),
            .commit = try accounting.add(a.commit, b.commit),
        };
    }

    pub fn minus(a: Pair, b: Pair) Failure!Pair {
        return .{
            .physical = std.math.sub(u64, a.physical, b.physical) catch return error.InvalidCredit,
            .commit = std.math.sub(u64, a.commit, b.commit) catch return error.InvalidCredit,
        };
    }
};

pub const BoundPair = struct {
    physical: Bound = .unknown,
    commit: Bound = .unknown,

    pub fn known(self: BoundPair) Failure!Pair {
        return .{
            .physical = try knownMemory(self.physical),
            .commit = try knownMemory(self.commit),
        };
    }

    pub fn upper(physical: u64, commit: u64) BoundPair {
        return .{ .physical = .{ .upper_bound = physical }, .commit = .{ .upper_bound = commit } };
    }
};

pub const Phase = enum {
    pending, // Includes a start in flight until independently verified ready.
    active, // Verified steady envelope; not a single idle measurement.
    stopping, // Continue charging the peak until reconciliation proves release.
};

pub const Cost = struct {
    // Guest-configured RAM is charged to BOTH dimensions, with no ballooning,
    // pagefile or swap credit. For an isolated host tool it can be known zero.
    guest: Bound = .unknown,
    steady_overhead: BoundPair = .{},
    startup_extra: BoundPair = .{},
    remaining_disk_growth: Bound = .unknown,
    temporary_disk: Bound = .unknown,

    pub fn memory(self: Cost, phase: Phase) Failure!Pair {
        const guest = try knownMemory(self.guest);
        const base: Pair = .{ .physical = guest, .commit = guest };
        const steady = try base.plus(try self.steady_overhead.known());
        if (steady.physical == 0 or steady.commit == 0) return error.InvalidMemory;
        if (phase == .active) return steady;
        return steady.plus(try self.startup_extra.known());
    }
};

test "configured RAM and overhead are separate in both dimensions" {
    const cost: Cost = .{
        .guest = .{ .upper_bound = 100 },
        .steady_overhead = BoundPair.upper(20, 30),
        .startup_extra = BoundPair.upper(40, 50),
    };
    try std.testing.expectEqual(Pair{ .physical = 120, .commit = 130 }, try cost.memory(.active));
    try std.testing.expectEqual(Pair{ .physical = 160, .commit = 180 }, try cost.memory(.pending));
    try std.testing.expectEqual(Pair{ .physical = 160, .commit = 180 }, try cost.memory(.stopping));
    var invalid = cost;
    invalid.startup_extra.physical = .{ .estimate = 40 };
    try std.testing.expectError(error.UnknownMemory, invalid.memory(.pending));
    invalid.guest = .{ .upper_bound = std.math.maxInt(u64) };
    try std.testing.expectError(error.Overflow, invalid.memory(.active));
}
