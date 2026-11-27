const std = @import("std");
const ids = @import("../../provider/types.zig");
const model = @import("../../state/model.zig");

pub const Status = enum { matched, drift, interrupted, unavailable };
pub const Item = struct {
    guest: ids.Uuid,
    status: Status,
    observed: ?ids.Observation,
};
pub const Report = struct {
    revision: u64,
    items: [model.max_guests]?Item = @splat(null),
    // Per-owned-VM queries do not discover external VMs, media aliases,
    // network peers, process reservations or hidden attachments.
    complete_inventory_verified: bool = false,
};

// Compatible with the read-only VirtualBox Adapter.observe interface.
// Successful marker/UUID queries are necessary but not sufficient for
// ownership attestation. Never adopt, start, stop, delete or repair here.
pub fn inspect(state: *const model.State, backend: anytype) Report {
    var report: Report = .{ .revision = state.revision };
    for (state.initial.guests, 0..) |entry, i| {
        const guest = entry orelse continue;
        const observed = backend.observe(guest.owner) catch {
            report.items[i] = .{ .guest = guest.owner.guest, .status = .unavailable, .observed = null };
            continue;
        };
        const phase = state.phases[i];
        const identity_ok = observed.vm.eql(guest.owner.vm) and observed.memory_bytes == guest.cost.guest_bytes;
        const status: Status = if (!identity_ok)
            .drift
        else if (phase == .pending or phase == .stopping)
            .interrupted
        else if (phase == .stopped and observed.power == .powered_off)
            .matched
        else if (phase == .active and observed.power == .running and observed.network == .compatible and observed.isolation_verified)
            .matched
        else
            .drift;
        report.items[i] = .{ .guest = guest.owner.guest, .status = status, .observed = observed };
    }
    return report;
}

pub const RecoveryAdvice = enum {
    none,
    verify_before_cancel,
    verify_completion,
    manual_recovery,
};

// Advice only; complete/cancel require fresh independent evidence and
// approval. No automatic retry after the durable dispatch barrier.
pub fn advice(state: *const model.State, observed: ?ids.Observation) RecoveryAdvice {
    const operation = state.operation orelse return .none;
    const index = state.index(operation.guest) catch return .manual_recovery;
    const guest = state.initial.guests[index] orelse return .manual_recovery;
    const info = observed orelse return .manual_recovery;
    if (!info.vm.eql(guest.owner.vm) or info.memory_bytes != guest.cost.guest_bytes)
        return .manual_recovery;
    if (operation.stage == .intent) {
        const prior: ids.PowerState = if (operation.kind == .start) .powered_off else .running;
        return if (info.power == prior) .verify_before_cancel else .manual_recovery;
    }
    const target: ids.PowerState = if (operation.kind == .start) .running else .powered_off;
    return if (info.power == target) .verify_completion else .manual_recovery;
}

const Fake = struct {
    observation: ids.Observation,
    fail: bool = false,

    fn observe(self: *Fake, _: ids.OwnedGuest) ids.Failure!ids.Observation {
        if (self.fail) return error.ProviderFailure;
        return self.observation;
    }
};

test "read-only reconciliation never invents a complete inventory or releases reservations" {
    const initial = try model.apply(null, 1, .{ .kind = .initialise, .initial = model.exampleInitial() });
    const guest = initial.initial.guests[0].?;
    var fake: Fake = .{ .observation = .{
        .vm = guest.owner.vm,
        .memory_bytes = guest.cost.guest_bytes,
        .power = .powered_off,
        .network = .compatible,
    } };
    const first = inspect(&initial, &fake);
    try std.testing.expectEqual(Status.matched, first.items[0].?.status);
    try std.testing.expect(!first.complete_inventory_verified);
    fake.observation.power = .running;
    try std.testing.expectEqual(Status.drift, inspect(&initial, &fake).items[0].?.status);
    fake.fail = true;
    try std.testing.expectEqual(Status.unavailable, inspect(&initial, &fake).items[0].?.status);
    fake.fail = false;
    const intent = try model.apply(initial, 2, .{ .kind = .intent, .operation = .{ .serial = 2, .guest = guest.owner.guest, .kind = .start } });
    try std.testing.expectEqual(Status.interrupted, inspect(&intent, &fake).items[0].?.status);
    try std.testing.expectEqual(RecoveryAdvice.manual_recovery, advice(&intent, fake.observation));
    const dispatched = try model.apply(intent, 3, .{ .kind = .dispatch, .serial = 2 });
    try std.testing.expectEqual(RecoveryAdvice.verify_completion, advice(&dispatched, fake.observation));
    try std.testing.expectEqual(@as(usize, 1), (try dispatched.ledger()).len);
    fake.observation.power = .powered_off;
    try std.testing.expectEqual(RecoveryAdvice.manual_recovery, advice(&dispatched, fake.observation));
}
