const std = @import("std");
const types = @import("../../provider/types.zig");
const parser = @import("../../provider/virtualbox/parse.zig");

// These inputs are capabilities supplied by the future trusted admission/journal
// coordinator, not CLI flags. A real provider may not be wired to this until N08/N09.
pub const Gate = struct {
    approved: bool = false,
    ownership_record_verified: bool = false,
    resources_admitted: bool = false,
    intent_journalled: bool = false,
};

pub const Limits = struct {
    max_observations: u8 = 30,
    interval_ms: u32 = 1000,

    fn validate(self: Limits) types.Failure!void {
        if (self.max_observations == 0 or self.max_observations > 60 or self.interval_ms == 0 or self.interval_ms > 5000)
            return error.InvalidResponse;
    }
};

fn authorize(gate: Gate, starting: bool) types.Failure!void {
    if (!gate.approved) return error.ApprovalRequired;
    if (!gate.ownership_record_verified) return error.OwnershipMismatch;
    if (!gate.intent_journalled) return error.JournalRequired;
    if (starting and !gate.resources_admitted) return error.ResourceRefused;
}

fn verifyOwnership(observed: types.Observation, owned: types.OwnedGuest) types.Failure!void {
    if (!observed.vm.eql(owned.vm)) return error.OwnershipMismatch;
}

fn verifyIsolation(observed: types.Observation) types.Failure!void {
    if (observed.network != .compatible or !observed.isolation_verified) return error.IsolationUnverified;
}

// Generic backend contract: observe, start, requestShutdown; readiness must use
// an independent native AD check, not merely VM running. The clock/transport
// must enforce their own time limits. These are bounded observation counts,
// not a claim of end-to-end elapsed timeout.
pub fn start(backend: anytype, health: anytype, clock: anytype, owned: types.OwnedGuest, gate: Gate, limits: Limits) types.Failure!void {
    try authorize(gate, true);
    if (!owned.valid()) return error.OwnershipMismatch;
    try limits.validate();
    const initial = try backend.observe(owned);
    try verifyOwnership(initial, owned);
    try verifyIsolation(initial);
    if (initial.power != .powered_off) return error.WrongState;
    backend.start(owned) catch return error.RecoveryRequired;
    var i: u8 = 0;
    while (i < limits.max_observations) : (i += 1) {
        const current = backend.observe(owned) catch return error.RecoveryRequired;
        verifyOwnership(current, owned) catch return error.RecoveryRequired;
        verifyIsolation(current) catch return error.RecoveryRequired;
        switch (current.power) {
            .running => {
                if (health.ready(owned) catch return error.RecoveryRequired) return;
            },
            .transitional, .powered_off => {},
            else => return error.RecoveryRequired,
        }
        if (i + 1 < limits.max_observations) clock.sleep(limits.interval_ms);
    }
    return error.ReadinessTimeout;
}

pub fn stop(backend: anytype, clock: anytype, owned: types.OwnedGuest, gate: Gate, limits: Limits) types.Failure!void {
    try authorize(gate, false);
    if (!owned.valid()) return error.OwnershipMismatch;
    try limits.validate();
    const initial = try backend.observe(owned);
    try verifyOwnership(initial, owned);
    if (initial.power == .powered_off) return;
    if (initial.power != .running) return error.WrongState;
    // A clean stop of an owned running VM is allowed even after isolation drift.
    backend.requestShutdown(owned) catch return error.RecoveryRequired;
    var i: u8 = 0;
    while (i < limits.max_observations) : (i += 1) {
        const current = backend.observe(owned) catch return error.RecoveryRequired;
        verifyOwnership(current, owned) catch return error.RecoveryRequired;
        switch (current.power) {
            .powered_off => return,
            .running, .transitional => {},
            else => return error.RecoveryRequired,
        }
        if (i + 1 < limits.max_observations) clock.sleep(limits.interval_ms);
    }
    return error.ShutdownTimeout;
}

const Fake = struct {
    observation: types.Observation,
    ready_value: bool = true,
    stop_completes: bool = true,
    starts: usize = 0,
    stops: usize = 0,
    sleeps: usize = 0,

    fn observe(self: *Fake, _: types.OwnedGuest) types.Failure!types.Observation {
        return self.observation;
    }

    fn start(self: *Fake, _: types.OwnedGuest) types.Failure!void {
        self.starts += 1;
        self.observation.power = .running;
    }

    fn requestShutdown(self: *Fake, _: types.OwnedGuest) types.Failure!void {
        self.stops += 1;
        if (self.stop_completes) self.observation.power = .powered_off;
    }

    fn ready(self: *Fake, _: types.OwnedGuest) types.Failure!bool {
        return self.ready_value;
    }

    fn sleep(self: *Fake, _: u32) void {
        self.sleeps += 1;
    }

    fn init() Fake {
        return .{ .observation = .{
            .vm = parser.exampleOwned().vm,
            .power = .powered_off,
            .memory_bytes = 2147483648,
            .network = .compatible,
            .isolation_verified = true,
        } };
    }
};

const authorised: Gate = .{
    .approved = true,
    .ownership_record_verified = true,
    .resources_admitted = true,
    .intent_journalled = true,
};
const short: Limits = .{ .max_observations = 3, .interval_ms = 1 };

test "start and graceful stop on owned fake guest" {
    var fake = Fake.init();
    const owned = parser.exampleOwned();
    try start(&fake, &fake, &fake, owned, authorised, short);
    try std.testing.expectEqual(@as(usize, 1), fake.starts);
    try stop(&fake, &fake, owned, authorised, short);
    try std.testing.expectEqual(@as(usize, 1), fake.stops);
    try stop(&fake, &fake, owned, authorised, short);
    try std.testing.expectEqual(@as(usize, 1), fake.stops);
}

test "approval, ownership, journal, resources and isolation gate mutation" {
    var fake = Fake.init();
    const owned = parser.exampleOwned();
    try std.testing.expectError(error.ApprovalRequired, start(&fake, &fake, &fake, owned, .{}, short));
    var gate = authorised;
    gate.intent_journalled = false;
    try std.testing.expectError(error.JournalRequired, start(&fake, &fake, &fake, owned, gate, short));
    gate = authorised;
    gate.resources_admitted = false;
    try std.testing.expectError(error.ResourceRefused, start(&fake, &fake, &fake, owned, gate, short));
    fake.observation.isolation_verified = false;
    try std.testing.expectError(error.IsolationUnverified, start(&fake, &fake, &fake, owned, authorised, short));
    fake.observation.vm = owned.guest;
    try std.testing.expectError(error.OwnershipMismatch, start(&fake, &fake, &fake, owned, authorised, short));
    try std.testing.expectEqual(@as(usize, 0), fake.starts);
}

test "timeout never escalates to forced shutdown or repeats mutation" {
    var fake = Fake.init();
    const owned = parser.exampleOwned();
    fake.ready_value = false;
    try std.testing.expectError(error.ReadinessTimeout, start(&fake, &fake, &fake, owned, authorised, short));
    try std.testing.expectEqual(@as(usize, 1), fake.starts);
    try std.testing.expectEqual(@as(usize, 2), fake.sleeps);
    fake.stop_completes = false;
    try std.testing.expectError(error.ShutdownTimeout, stop(&fake, &fake, owned, authorised, short));
    try std.testing.expectEqual(@as(usize, 1), fake.stops);
    try std.testing.expectEqual(types.PowerState.running, fake.observation.power);
}
