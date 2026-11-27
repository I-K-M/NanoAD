const std = @import("std");

// File-data estimates are useful for research, but cannot be promoted to a
// strict bound without independent provider/filesystem reconciliation.
pub const Charge = union(enum) {
    upper_bound: u64,
    estimate: u64,
    unknown,
};

pub const Failure = error{ Overflow, UnknownAllocation, IncompleteInventory, InstalledLimit, PeakLimit, HostFreeSpace, InvalidBound };

pub fn add(a: u64, b: u64) Failure!u64 {
    return std.math.add(u64, a, b) catch error.Overflow;
}

pub const Totals = struct {
    reported_bytes: u64 = 0,
    strict_upper_bound: ?u64 = 0,
    estimates: usize = 0,
    unknown: usize = 0,
    complete: bool = true,

    pub fn include(self: *Totals, charge: Charge) Failure!void {
        switch (charge) {
            .upper_bound => |n| {
                self.reported_bytes = try add(self.reported_bytes, n);
                if (self.strict_upper_bound) |total| self.strict_upper_bound = try add(total, n);
            },
            .estimate => |n| {
                self.reported_bytes = try add(self.reported_bytes, n);
                self.estimates += 1;
                self.strict_upper_bound = null;
            },
            .unknown => {
                self.unknown += 1;
                self.strict_upper_bound = null;
            },
        }
    }

    pub fn strict(self: Totals) Failure!u64 {
        if (!self.complete) return error.IncompleteInventory;
        return self.strict_upper_bound orelse error.UnknownAllocation;
    }
};

pub const Budget = struct {
    installed_limit: u64,
    operation_peak_limit: u64,
    host_available: ?u64,
    host_reserve: u64,
};

pub const Plan = struct {
    current_bytes: u64,
    retained_after_upper_bound: u64,
    peak_upper_bound: u64,
    additional_host_bytes: u64,
};

// Only single-volume plans in this first slice. An operation may retain
// new data and simultaneously require scratch. No hypothetical future
// reclamation is credited before its allocation is actually released.
pub fn admit(totals: Totals, budget: Budget, retained: ?u64, scratch: ?u64) Failure!Plan {
    const current = try totals.strict();
    const new = retained orelse return error.UnknownAllocation;
    const temp = scratch orelse return error.UnknownAllocation;
    if (budget.installed_limit == 0 or budget.operation_peak_limit < budget.installed_limit)
        return error.InvalidBound;
    const final = try add(current, new);
    const peak = try add(final, temp);
    const needed = try add(new, temp);
    const free = budget.host_available orelse return error.UnknownAllocation;
    if (final > budget.installed_limit) return error.InstalledLimit;
    if (peak > budget.operation_peak_limit) return error.PeakLimit;
    if (free < try add(needed, budget.host_reserve)) return error.HostFreeSpace;
    return .{
        .current_bytes = current,
        .retained_after_upper_bound = final,
        .peak_upper_bound = peak,
        .additional_host_bytes = needed,
    };
}

test "unknown and estimates are not strict bounds" {
    var totals: Totals = .{};
    try totals.include(.{ .upper_bound = 100 });
    try totals.include(.{ .estimate = 20 });
    try totals.include(.unknown);
    try std.testing.expectEqual(@as(u64, 120), totals.reported_bytes);
    try std.testing.expectEqual(@as(usize, 1), totals.unknown);
    try std.testing.expectError(error.UnknownAllocation, totals.strict());
    totals.complete = false;
    try std.testing.expectError(error.IncompleteInventory, totals.strict());
}

test "peak, retained and free space checked independently" {
    var t: Totals = .{};
    try t.include(.{ .upper_bound = 100 });
    const budget: Budget = .{ .installed_limit = 150, .operation_peak_limit = 180, .host_available = 100, .host_reserve = 20 };
    const plan = try admit(t, budget, 30, 40);
    try std.testing.expectEqual(@as(u64, 130), plan.retained_after_upper_bound);
    try std.testing.expectEqual(@as(u64, 170), plan.peak_upper_bound);
    try std.testing.expectError(error.InstalledLimit, admit(t, budget, 51, 0));
    try std.testing.expectError(error.PeakLimit, admit(t, budget, 30, 51));
    var tight = budget;
    tight.host_available = 89;
    try std.testing.expectError(error.HostFreeSpace, admit(t, tight, 30, 40));
    try std.testing.expectError(error.UnknownAllocation, admit(t, budget, null, 0));
    try std.testing.expectError(error.Overflow, admit(t, budget, std.math.maxInt(u64), 0));
}
