const std = @import("std");
const ids = @import("../provider/types.zig");
const Digest = @import("../image/digest.zig").Digest;
const bounds = @import("../governor/bounds.zig");
const governor = @import("../governor/admission.zig");

pub const max_guests = governor.max_workloads;
pub const Failure = bounds.Failure || error{
    InvalidState,
    InvalidTransition,
    BusyOperation,
    StaleRevision,
    InvalidOwnership,
    InvalidEvent,
    UnknownGuest,
    JournalCorrupt,
    JournalLimit,
    LockBusy,
    StorePoisoned,
    ApprovalRequired,
    UnverifiedEvidence,
    RecoveryRequired,
};

// Only qualified upper bounds belong in durable state. No credentials, paths,
// floating point measurements, or untrusted estimates enter this schema.
pub const Cost = struct {
    guest_bytes: u64,
    steady_physical: u64,
    steady_commit: u64,
    startup_physical: u64,
    startup_commit: u64,
    disk_growth: u64,
    disk_scratch: u64,

    pub fn envelope(self: Cost) bounds.Cost {
        return .{
            .guest = .{ .upper_bound = self.guest_bytes },
            .steady_overhead = bounds.BoundPair.upper(self.steady_physical, self.steady_commit),
            .startup_extra = bounds.BoundPair.upper(self.startup_physical, self.startup_commit),
            .remaining_disk_growth = .{ .upper_bound = self.disk_growth },
            .temporary_disk = .{ .upper_bound = self.disk_scratch },
        };
    }
};

pub const Guest = struct {
    owner: ids.OwnedGuest,
    medium: ids.Uuid,
    parent: ids.Uuid,
    base_sha256: [64]u8,
    cost: Cost,
};

pub const Initial = struct {
    lab: ids.Uuid,
    guests: [max_guests]?Guest = @splat(null),
};

pub const Phase = enum { stopped, pending, active, stopping };
pub const Kind = enum { start, stop };
pub const Stage = enum { intent, dispatch };
pub const Operation = struct {
    serial: u64,
    guest: ids.Uuid,
    kind: Kind,
    stage: Stage = .intent,
};

pub const EventKind = enum { initialise, intent, dispatch, complete, cancel };
pub const Event = struct {
    kind: EventKind,
    initial: ?Initial = null,
    operation: ?Operation = null,
    serial: ?u64 = null,
};

pub const State = struct {
    revision: u64,
    initial: Initial,
    phases: [max_guests]Phase = @splat(.stopped),
    operation: ?Operation = null,

    pub fn index(self: *const State, guest: ids.Uuid) Failure!usize {
        for (self.initial.guests, 0..) |entry, i| {
            if (entry) |g| {
                if (g.owner.guest.eql(guest)) return i;
            }
        }
        return error.UnknownGuest;
    }

    pub fn ledger(self: *const State) Failure!governor.Ledger {
        var entries: [max_guests]governor.Entry = undefined;
        var count: usize = 0;
        for (self.initial.guests, self.phases) |entry, phase| {
            const guest = entry orelse continue;
            const reserved: bounds.Phase = switch (phase) {
                .stopped => continue,
                .pending => .pending,
                .active => .active,
                .stopping => .stopping,
            };
            entries[count] = .{ .id = guest.owner.guest, .phase = reserved, .cost = guest.cost.envelope() };
            count += 1;
        }
        return governor.Ledger.init(self.revision, entries[0..count]);
    }

    pub fn desired(self: *const State, i: usize) Kind {
        return switch (self.phases[i]) {
            .pending, .active => .start,
            .stopped, .stopping => .stop,
        };
    }
};

fn localIds(guest: Guest) [3]ids.Uuid {
    return .{ guest.owner.guest, guest.owner.vm, guest.medium };
}

pub fn validateInitial(initial: Initial) Failure!void {
    if (!initial.lab.valid()) return error.InvalidOwnership;
    for (initial.guests, 0..) |entry, i| {
        const guest = entry orelse continue;
        if (!guest.owner.valid() or !guest.owner.lab.eql(initial.lab) or
            !guest.medium.valid() or !guest.parent.valid() or
            guest.medium.eql(initial.lab) or guest.parent.eql(initial.lab))
            return error.InvalidOwnership;
        const digest = Digest.parse(&guest.base_sha256) catch return error.InvalidOwnership;
        if (!std.mem.eql(u8, &digest.hex(), &guest.base_sha256)) return error.InvalidOwnership;
        const keys = localIds(guest);
        for (keys, 0..) |key, k| {
            if (key.eql(guest.parent)) return error.InvalidOwnership;
            for (keys[0..k]) |previous| {
                if (key.eql(previous)) return error.InvalidOwnership;
            }
        }
        if (guest.cost.guest_bytes == 0) return error.InvalidMemory;
        _ = try guest.cost.envelope().memory(.pending);
        for (initial.guests[0..i]) |earlier| {
            const previous = earlier orelse continue;
            for (keys) |key| {
                if (key.eql(previous.parent)) return error.InvalidOwnership;
                for (localIds(previous)) |other| {
                    if (key.eql(other) or guest.parent.eql(other)) return error.InvalidOwnership;
                }
            }
            const same_digest = std.mem.eql(u8, &guest.base_sha256, &previous.base_sha256);
            if (guest.parent.eql(previous.parent) != same_digest) return error.InvalidOwnership;
        }
    }
}

// Replay and live commits share this pure transition function. All changes
// are derived from the prior state; event payloads cannot replace costs or
// ownership. Serial is the revision of the intent, unique within the lab.
pub fn apply(previous: ?State, revision: u64, event: Event) Failure!State {
    if (previous == null) {
        if (revision != 1 or event.kind != .initialise or event.operation != null or event.serial != null)
            return error.InvalidEvent;
        const initial = event.initial orelse return error.InvalidEvent;
        try validateInitial(initial);
        return .{ .revision = 1, .initial = initial };
    }
    var next = previous.?;
    if (revision != try std.math.add(u64, next.revision, 1)) return error.StaleRevision;
    if (event.initial != null or event.kind == .initialise) return error.InvalidEvent;
    switch (event.kind) {
        .initialise => unreachable,
        .intent => {
            if (next.operation != null) return error.BusyOperation;
            if (event.serial != null) return error.InvalidEvent;
            const operation = event.operation orelse return error.InvalidEvent;
            if (operation.serial != revision or operation.stage != .intent or !operation.guest.valid())
                return error.InvalidEvent;
            const i = try next.index(operation.guest);
            const prior: Phase = if (operation.kind == .start) .stopped else .active;
            if (next.phases[i] != prior) return error.InvalidTransition;
            next.phases[i] = if (operation.kind == .start) .pending else .stopping;
            next.operation = operation;
        },
        .dispatch, .complete, .cancel => {
            if (event.operation != null) return error.InvalidEvent;
            const operation = next.operation orelse return error.InvalidTransition;
            if (event.serial == null or event.serial.? != operation.serial) return error.StaleRevision;
            const i = try next.index(operation.guest);
            const expected: Phase = if (operation.kind == .start) .pending else .stopping;
            if (next.phases[i] != expected) return error.InvalidTransition;
            switch (event.kind) {
                .dispatch => {
                    if (operation.stage != .intent) return error.InvalidTransition;
                    next.operation.?.stage = .dispatch;
                },
                .complete => {
                    if (operation.stage != .dispatch) return error.InvalidTransition;
                    next.phases[i] = if (operation.kind == .start) .active else .stopped;
                    next.operation = null;
                },
                .cancel => {
                    // Once dispatch is recorded the action may have happened.
                    // Never cancel or release its reservation from journal alone.
                    if (operation.stage != .intent) return error.RecoveryRequired;
                    next.phases[i] = if (operation.kind == .start) .stopped else .active;
                    next.operation = null;
                },
                else => unreachable,
            }
        },
    }
    next.revision = revision;
    return next;
}

pub fn exampleId(comptime prefix: []const u8) ids.Uuid {
    return ids.Uuid.parse(prefix ++ "1234567-89ab-cdef-0123-456789abcdef") catch unreachable;
}

pub fn exampleInitial() Initial {
    var initial: Initial = .{ .lab = exampleId("1") };
    initial.guests[0] = .{
        .owner = .{ .lab = initial.lab, .guest = exampleId("2"), .vm = exampleId("3") },
        .medium = exampleId("4"),
        .parent = exampleId("5"),
        .base_sha256 = @splat('a'),
        .cost = .{
            .guest_bytes = 1024 * governor.mib,
            .steady_physical = 128 * governor.mib,
            .steady_commit = 128 * governor.mib,
            .startup_physical = 128 * governor.mib,
            .startup_commit = 128 * governor.mib,
            .disk_growth = 256 * governor.mib,
            .disk_scratch = 128 * governor.mib,
        },
    };
    return initial;
}

test "replay derives reservations and refuses ambiguous cancellation" {
    const initial = try apply(null, 1, .{ .kind = .initialise, .initial = exampleInitial() });
    const guest = initial.initial.guests[0].?.owner.guest;
    const intent = try apply(initial, 2, .{ .kind = .intent, .operation = .{ .serial = 2, .guest = guest, .kind = .start } });
    try std.testing.expectEqual(@as(usize, 1), (try intent.ledger()).len);
    try std.testing.expectEqual(Phase.pending, intent.phases[0]);
    try std.testing.expectError(error.InvalidTransition, apply(intent, 3, .{ .kind = .complete, .serial = 2 }));
    const armed = try apply(intent, 3, .{ .kind = .dispatch, .serial = 2 });
    try std.testing.expectError(error.RecoveryRequired, apply(armed, 4, .{ .kind = .cancel, .serial = 2 }));
    const active = try apply(armed, 4, .{ .kind = .complete, .serial = 2 });
    try std.testing.expectEqual(Phase.active, active.phases[0]);
    const stopping = try apply(active, 5, .{ .kind = .intent, .operation = .{ .serial = 5, .guest = guest, .kind = .stop } });
    try std.testing.expectEqual(Phase.stopping, stopping.phases[0]);
    try std.testing.expectEqual(@as(usize, 1), (try stopping.ledger()).len);
    const stop_armed = try apply(stopping, 6, .{ .kind = .dispatch, .serial = 5 });
    const stopped = try apply(stop_armed, 7, .{ .kind = .complete, .serial = 5 });
    try std.testing.expectEqual(@as(usize, 0), (try stopped.ledger()).len);
}

test "ownership collisions and noncanonical digests are rejected" {
    var initial = exampleInitial();
    initial.guests[0].?.medium = initial.guests[0].?.owner.vm;
    try std.testing.expectError(error.InvalidOwnership, validateInitial(initial));
    initial = exampleInitial();
    initial.guests[0].?.base_sha256[0] = 'A';
    try std.testing.expectError(error.InvalidOwnership, validateInitial(initial));
    initial = exampleInitial();
    initial.guests[1] = initial.guests[0];
    try std.testing.expectError(error.InvalidOwnership, validateInitial(initial));
}
