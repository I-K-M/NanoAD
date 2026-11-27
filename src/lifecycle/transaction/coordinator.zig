const std = @import("std");
const ids = @import("../../provider/types.zig");
const model = @import("../../state/model.zig");
const Store = @import("../../state/journal.zig").Store;
const governor = @import("../../governor/admission.zig");

pub const Evidence = struct {
    revision: u64,
    observed_ms: u64,
    owner: ids.OwnedGuest,
    observed: ids.Observation,
    // Trusted full reconciler assertions. Neither flags from CLI nor a
    // successful per-VM read can set these. No real attestor exists yet.
    markers_verified: bool = false,
    inventory_verified: bool = false,
    media_verified: bool = false,
    native_ready: bool = false,
    scratch_accounted: bool = false,
    release_verified: bool = false,
};

fn check(state: *const model.State, evidence: Evidence, guest: ids.Uuid, now_ms: u64) !model.Guest {
    if (evidence.revision != state.revision or evidence.observed_ms > now_ms or now_ms - evidence.observed_ms > 2000)
        return error.UnverifiedEvidence;
    if (!evidence.markers_verified or !evidence.inventory_verified or !evidence.media_verified)
        return error.UnverifiedEvidence;
    const record = state.initial.guests[try state.index(guest)].?;
    if (!evidence.owner.valid() or !record.owner.lab.eql(evidence.owner.lab) or
        !record.owner.guest.eql(evidence.owner.guest) or !record.owner.vm.eql(evidence.owner.vm) or
        !record.owner.vm.eql(evidence.observed.vm) or evidence.observed.memory_bytes != record.cost.guest_bytes)
        return error.InvalidOwnership;
    return record;
}

fn isolated(evidence: Evidence) bool {
    return evidence.observed.network == .compatible and evidence.observed.isolation_verified;
}

fn priorEvidence(kind: model.Kind, evidence: Evidence) bool {
    return switch (kind) {
        .start => evidence.observed.power == .powered_off and isolated(evidence) and evidence.release_verified and evidence.scratch_accounted,
        // A graceful stop can still be appropriate after isolation drift.
        .stop => evidence.observed.power == .running,
    };
}

pub fn beginStart(store: *Store, guest: ids.Uuid, approved: bool, evidence: Evidence, snapshot: governor.Snapshot, budget: governor.Budget, now_ms: u64) !u64 {
    if (!approved) return error.ApprovalRequired;
    const state = try store.state();
    if (state.operation != null) return error.BusyOperation;
    const record = try check(&state, evidence, guest, now_ms);
    if (state.phases[try state.index(guest)] != .stopped or !priorEvidence(.start, evidence))
        return error.UnverifiedEvidence;
    var ledger = try state.ledger();
    _ = try ledger.reserve(snapshot, budget, .{ .id = guest, .cost = record.cost.envelope() }, now_ms);
    const serial = ledger.revision;
    try store.append(state.revision, .{ .kind = .intent, .operation = .{ .serial = serial, .guest = guest, .kind = .start } });
    return serial;
}

pub fn beginStop(store: *Store, guest: ids.Uuid, approved: bool, evidence: Evidence, now_ms: u64) !u64 {
    if (!approved) return error.ApprovalRequired;
    const state = try store.state();
    if (state.operation != null) return error.BusyOperation;
    _ = try check(&state, evidence, guest, now_ms);
    if (state.phases[try state.index(guest)] != .active or !priorEvidence(.stop, evidence))
        return error.UnverifiedEvidence;
    const serial = try std.math.add(u64, state.revision, 1);
    try store.append(state.revision, .{ .kind = .intent, .operation = .{ .serial = serial, .guest = guest, .kind = .stop } });
    return serial;
}

// The only successful return records a flushed dispatch barrier. No real
// provider mutation is wired; a reopened dispatch is NEVER a new permit.
// Future execution must hold the same Store lock through the action.
pub fn arm(store: *Store, serial: u64, approved: bool, evidence: Evidence, snapshot: ?governor.Snapshot, budget: governor.Budget, now_ms: u64) !void {
    if (!approved) return error.ApprovalRequired;
    const state = try store.state();
    const operation = state.operation orelse return error.InvalidTransition;
    if (operation.serial != serial) return error.StaleRevision;
    if (operation.stage != .intent) return error.RecoveryRequired;
    _ = try check(&state, evidence, operation.guest, now_ms);
    if (!priorEvidence(operation.kind, evidence)) return error.UnverifiedEvidence;
    if (operation.kind == .start) {
        const ledger = try state.ledger();
        _ = try ledger.recheck(snapshot orelse return error.UnverifiedEvidence, budget, operation.guest, now_ms);
    }
    try store.append(state.revision, .{ .kind = .dispatch, .serial = serial });
}

// Completion is also the explicit reconciliation path after an interrupted
// dispatch. Do not infer release from a VM's power state alone.
pub fn complete(store: *Store, serial: u64, approved: bool, evidence: Evidence, now_ms: u64) !void {
    if (!approved) return error.ApprovalRequired;
    const state = try store.state();
    const operation = state.operation orelse return error.InvalidTransition;
    if (operation.serial != serial) return error.StaleRevision;
    if (operation.stage != .dispatch) return error.InvalidTransition;
    _ = try check(&state, evidence, operation.guest, now_ms);
    const verified = switch (operation.kind) {
        .start => evidence.observed.power == .running and isolated(evidence) and evidence.native_ready and evidence.scratch_accounted,
        .stop => evidence.observed.power == .powered_off and evidence.release_verified and evidence.scratch_accounted,
    };
    if (!verified) return error.RecoveryRequired;
    try store.append(state.revision, .{ .kind = .complete, .serial = serial });
}

pub fn cancelUndispatched(store: *Store, serial: u64, approved: bool, evidence: Evidence, now_ms: u64) !void {
    if (!approved) return error.ApprovalRequired;
    const state = try store.state();
    const operation = state.operation orelse return error.InvalidTransition;
    if (operation.serial != serial) return error.StaleRevision;
    if (operation.stage != .intent) return error.RecoveryRequired;
    _ = try check(&state, evidence, operation.guest, now_ms);
    if (!priorEvidence(operation.kind, evidence)) return error.RecoveryRequired;
    if (operation.kind == .stop and (!evidence.native_ready or !evidence.scratch_accounted or !isolated(evidence)))
        return error.RecoveryRequired;
    try store.append(state.revision, .{ .kind = .cancel, .serial = serial });
}

fn fixtureEvidence(state: model.State, power: ids.PowerState) Evidence {
    const record = state.initial.guests[0].?;
    return .{
        .revision = state.revision,
        .observed_ms = 1000,
        .owner = record.owner,
        .observed = .{
            .vm = record.owner.vm,
            .power = power,
            .memory_bytes = record.cost.guest_bytes,
            .network = .compatible,
            .isolation_verified = true,
        },
        .markers_verified = true,
        .inventory_verified = true,
        .media_verified = true,
        .native_ready = true,
        .scratch_accounted = true,
        .release_verified = true,
    };
}

fn fixtureSnapshot(revision: u64) governor.Snapshot {
    const gib = governor.gib;
    return .{
        .inventory_revision = revision,
        .inventory_observed_ms = 1000,
        .memory = .{ .started_ms = 1000, .completed_ms = 1000, .physical_total = 8 * gib, .physical_available = 5 * gib, .commit_limit = 10 * gib, .committed = 4 * gib },
        .disk = .{ .started_ms = 1000, .completed_ms = 1000, .total_to_caller = 64 * gib, .available_to_caller = 32 * gib },
        .disk_totals = .{ .reported_bytes = 16 * gib, .strict_upper_bound = 16 * gib },
        .provider_reconciled = true,
        .host_scope_verified = true,
        .disk_volume_verified = true,
    };
}

const test_budget: governor.Budget = .{ .shared_peak = @import("../../governor/bounds.zig").BoundPair.upper(128 * governor.mib, 128 * governor.mib) };

test "admission, durable dispatch, recovery and verified release are ordered" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.create(tmp.dir, model.exampleInitial());
    const first = try store.state();
    const guest = first.initial.guests[0].?.owner.guest;
    const serial = try beginStart(&store, guest, true, fixtureEvidence(first, .powered_off), fixtureSnapshot(1), test_budget, 1001);
    try std.testing.expectEqual(@as(u64, 2), serial);
    const pending = try store.state();
    var tight = fixtureSnapshot(2);
    tight.memory.physical_available = governor.gib;
    try std.testing.expectError(error.HostPhysicalReserve, arm(&store, serial, true, fixtureEvidence(pending, .powered_off), tight, test_budget, 1001));
    try std.testing.expectEqual(model.Stage.intent, (try store.state()).operation.?.stage);
    try arm(&store, serial, true, fixtureEvidence(pending, .powered_off), fixtureSnapshot(2), test_budget, 1001);
    store.close();
    store = try Store.open(tmp.dir);
    const dispatched = try store.state();
    try std.testing.expectError(error.RecoveryRequired, arm(&store, serial, true, fixtureEvidence(dispatched, .powered_off), fixtureSnapshot(3), test_budget, 1001));
    var bad = fixtureEvidence(dispatched, .running);
    bad.native_ready = false;
    try std.testing.expectError(error.RecoveryRequired, complete(&store, serial, true, bad, 1001));
    try std.testing.expectEqual(@as(usize, 1), (try (try store.state()).ledger()).len);
    try complete(&store, serial, true, fixtureEvidence(dispatched, .running), 1001);
    const active = try store.state();
    const stop_serial = try beginStop(&store, guest, true, fixtureEvidence(active, .running), 1001);
    const stopping = try store.state();
    try arm(&store, stop_serial, true, fixtureEvidence(stopping, .running), null, test_budget, 1001);
    store.close();
    store = try Store.open(tmp.dir);
    defer store.close();
    const stopped_pending = try store.state();
    bad = fixtureEvidence(stopped_pending, .powered_off);
    bad.release_verified = false;
    try std.testing.expectError(error.RecoveryRequired, complete(&store, stop_serial, true, bad, 1001));
    try std.testing.expectEqual(@as(usize, 1), (try (try store.state()).ledger()).len);
    try complete(&store, stop_serial, true, fixtureEvidence(stopped_pending, .powered_off), 1001);
    try std.testing.expectEqual(@as(usize, 0), (try (try store.state()).ledger()).len);
}

test "approval and missing reconciliation cannot persist intent; cancellation is explicit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.create(tmp.dir, model.exampleInitial());
    defer store.close();
    const state = try store.state();
    const guest = state.initial.guests[0].?.owner.guest;
    var evidence = fixtureEvidence(state, .powered_off);
    try std.testing.expectError(error.ApprovalRequired, beginStart(&store, guest, false, evidence, fixtureSnapshot(1), test_budget, 1001));
    evidence.inventory_verified = false;
    try std.testing.expectError(error.UnverifiedEvidence, beginStart(&store, guest, true, evidence, fixtureSnapshot(1), test_budget, 1001));
    evidence.inventory_verified = true;
    try std.testing.expectError(error.UnverifiedEvidence, beginStart(&store, guest, true, evidence, fixtureSnapshot(1), test_budget, 3001));
    try std.testing.expectEqual(@as(u64, 1), (try store.state()).revision);
    const serial = try beginStart(&store, guest, true, evidence, fixtureSnapshot(1), test_budget, 1001);
    const pending = try store.state();
    try std.testing.expectError(error.ApprovalRequired, cancelUndispatched(&store, serial, false, fixtureEvidence(pending, .powered_off), 1001));
    try cancelUndispatched(&store, serial, true, fixtureEvidence(pending, .powered_off), 1001);
    try std.testing.expectEqual(@as(usize, 0), (try (try store.state()).ledger()).len);
}
