const std = @import("std");
const registry_mod = @import("../../modules/registry.zig");
const manifest = @import("../../modules/manifest.zig");
const planner = @import("../../planner/switch.zig");
const governor = @import("../../governor/admission.zig");
const bounds = @import("../../governor/bounds.zig");
const ids = @import("../../provider/types.zig");
const model = @import("../../state/model.zig");
const Store = @import("../../state/journal.zig").Store;
const tx = @import("../transaction/coordinator.zig");

// Trusted backend contract. No native implementation is connected.
// capture must observe the full lab, media, provider and host scope while
// the same lab AND host-wide resource lock remain held. Inventory digest
// binds immutable topology, provider/build, ownership and boot identity;
// changing powers and capacities are compared separately.
pub const Frame = struct {
    lab: ids.Uuid,
    revision: u64,
    inventory_digest: [32]u8,
    pinned: u32 = 0,
    len: usize,
    entries: [planner.max_modules]planner.Entry = undefined,
    evidence: [planner.max_modules]?tx.Evidence = @splat(null),
    snapshot: governor.Snapshot,
    budget: governor.Budget,
    host_lock_verified: bool = false,

    pub fn input(self: *const Frame) planner.Input {
        return .{
            .lab = self.lab,
            .revision = self.revision,
            .inventory_digest = self.inventory_digest,
            .entries = self.entries[0..self.len],
            .pinned = self.pinned,
            .snapshot = self.snapshot,
            .budget = self.budget,
        };
    }
};

pub const Request = struct {
    target: manifest.Id,
    stops: u32 = 0,
    approved_hash: ?[]const u8 = null,
    dry_run: bool = false,
};

pub const Outcome = enum { refused, preview, complete, partial, recovery_required };
pub const Stage = enum { approval, preflight, intent, arm, dispatch_check, provider, completion, done };
pub const Report = struct {
    outcome: Outcome = .refused,
    stage: Stage = .approval,
    hash: ?[64]u8 = null,
    planned: usize = 0,
    completed: usize = 0,
    // Number of calls to the provider, including ambiguous failures.
    dispatched: usize = 0,
    failed_step: ?usize = null,
    revision: ?u64 = null,
    failure: ?anyerror = null,
};

fn expectedPower(state: *const model.State, index: usize, post_dispatch: bool) !ids.PowerState {
    return switch (state.phases[index]) {
        .stopped => .powered_off,
        .active => .running,
        .pending, .stopping => blk: {
            const op = state.operation orelse return error.InvalidState;
            const guest = state.initial.guests[index] orelse return error.InvalidState;
            if (!op.guest.eql(guest.owner.guest)) return error.InvalidState;
            if (post_dispatch and op.stage != .dispatch) return error.InvalidState;
            const starting = op.kind == .start;
            if (starting != (state.phases[index] == .pending)) return error.InvalidState;
            break :blk if (starting == post_dispatch) .running else .powered_off;
        },
    };
}

fn verifiedEvidence(record: model.Guest, evidence: tx.Evidence, power: ids.PowerState, revision: u64, now: u64) !void {
    if (evidence.revision != revision or evidence.observed_ms > now or now - evidence.observed_ms > 2000 or
        !evidence.markers_verified or !evidence.inventory_verified or !evidence.media_verified or
        !evidence.scratch_accounted) return error.UnverifiedEvidence;
    if (!std.meta.eql(evidence.owner, record.owner) or
        !evidence.observed.vm.eql(record.owner.vm) or evidence.observed.memory_bytes != record.cost.guest_bytes)
        return error.InvalidOwnership;
    const medium = evidence.observed_medium orelse return error.UnverifiedEvidence;
    const parent = evidence.observed_parent orelse return error.UnverifiedEvidence;
    const digest = evidence.observed_base_sha256 orelse return error.UnverifiedEvidence;
    if (!medium.eql(record.medium) or !parent.eql(record.parent) or !std.mem.eql(u8, &digest, &record.base_sha256))
        return error.InvalidOwnership;
    if (evidence.observed.power != power or evidence.observed.network != .compatible or
        !evidence.observed.isolation_verified) return error.UnverifiedEvidence;
    if (power == .running and !evidence.native_ready) return error.UnverifiedEvidence;
    if (power == .powered_off and !evidence.release_verified) return error.UnverifiedEvidence;
}

fn validateFrame(registry: *const registry_mod.Registry, state: *const model.State, frame: *const Frame, now: u64, post_dispatch: bool) !void {
    if (!frame.host_lock_verified) return error.HostLockRequired;
    if (registry.len == 0 or registry.len > planner.max_modules or frame.len != registry.len or
        frame.revision != state.revision or !frame.lab.eql(state.initial.lab))
        return error.InvalidInventory;
    if (frame.snapshot.inventory_revision != state.revision or frame.snapshot.credits.len != 0)
        return error.InvalidInventory;
    var seen: u32 = 0;
    for (registry.view(), frame.entries[0..frame.len], 0..) |m, entry, i| {
        if (entry.id.len == 0 or entry.id.len > entry.id.bytes.len or !entry.id.eql(m.id))
            return error.InvalidInventory;
        switch (entry.status) {
            .absent => {
                if (entry.guest != null or entry.cost != null or frame.evidence[i] != null)
                    return error.InvalidInventory;
            },
            .running, .stopped => {
                if (m.kind != .guest) return error.UnsupportedActivation;
                const guest = entry.guest orelse return error.InvalidInventory;
                const slot = try state.index(guest);
                if (seen & planner.bit(slot) != 0) return error.InvalidInventory;
                seen |= planner.bit(slot);
                const record = state.initial.guests[slot].?;
                const cost = entry.cost orelse return error.UnknownMemory;
                if (!std.meta.eql(cost, record.cost.envelope())) return error.InvalidInventory;
                const power = try expectedPower(state, slot, post_dispatch);
                if ((entry.status == .running) != (power == .running)) return error.InventoryDrift;
                try verifiedEvidence(record, frame.evidence[i] orelse return error.UnverifiedEvidence, power, state.revision, now);
            },
            // Persistent fixtures do not have durable workload records in
            // N09 yet. Refuse rather than omit their costs or dependencies.
            .applied => return error.UnsupportedActivation,
            .unknown, .pending, .stopping => return error.RecoveryRequired,
        }
    }
    for (state.initial.guests, 0..) |guest, slot| {
        if ((guest != null) != (seen & planner.bit(slot) != 0)) return error.InvalidInventory;
    }
}

fn sameIdentity(first: *const Frame, next: *const Frame) !void {
    if (!first.lab.eql(next.lab) or !std.mem.eql(u8, &first.inventory_digest, &next.inventory_digest) or
        first.pinned != next.pinned or first.len != next.len or !std.meta.eql(first.budget, next.budget))
        return error.InventoryDrift;
    for (first.entries[0..first.len], next.entries[0..next.len]) |a, b| {
        if (!a.id.eql(b.id) or !std.meta.eql(a.guest, b.guest) or !std.meta.eql(a.cost, b.cost))
            return error.InventoryDrift;
    }
}

fn requireEnvelope(actual: governor.Plan, approved: planner.Usage) !void {
    if (actual.lab_peak.physical > approved.memory.physical or actual.lab_peak.commit > approved.memory.commit or
        actual.disk.retained_after_upper_bound > approved.retained or actual.disk.peak_upper_bound > approved.disk_peak)
        return error.ApprovedEnvelopeExceeded;
}

// Construct a hypothetical ledger solely for preflight/after-step resource
// validation. The durable ledger changes only through the N09 coordinator.
fn checkPhase(state: model.State, frame: *const Frame, guest: ids.Uuid, phase: model.Phase, envelope: planner.Usage, now: u64) !void {
    var projected = state;
    projected.phases[try projected.index(guest)] = phase;
    const ledger = try projected.ledger();
    const actual = try governor.checkCurrent(&ledger, frame.snapshot, frame.budget, now);
    try requireEnvelope(actual, envelope);
}

pub fn preview(store: *const Store, registry: *const registry_mod.Registry, backend: anytype, target: manifest.Id) !planner.Alternatives {
    const state = try store.state();
    if (state.operation != null) return error.RecoveryRequired;
    const frame = try backend.capture(&state);
    const now = try backend.nowMs();
    try validateFrame(registry, &state, &frame, now, false);
    return planner.alternatives(registry, frame.input(), target, now);
}

// No implicit confirmation, no auto-retry, no rollback mutation. The caller
// holds Store and a trusted backend's host-wide lock for the entire call.
// Every successful step is durable; a crash between steps requires a new
// plan and consent. A crash in a step leaves N09 intent/dispatch for recovery.
pub fn execute(store: *Store, registry: *const registry_mod.Registry, backend: anytype, request: Request) Report {
    var report: Report = .{};
    run(store, registry, backend, request, &report) catch |err| {
        report.failure = err;
        if (store.state()) |state| {
            report.revision = state.revision;
            report.outcome = if (state.operation != null)
                .recovery_required
            else if (report.completed != 0)
                .partial
            else
                .refused;
        } else |_| {
            report.outcome = .recovery_required;
        }
    };
    return report;
}

fn run(store: *Store, registry: *const registry_mod.Registry, backend: anytype, request: Request, report: *Report) !void {
    if (!request.dry_run and request.approved_hash == null) return error.ApprovalRequired;
    const original = try store.state();
    report.revision = original.revision;
    if (original.operation != null) return error.RecoveryRequired;
    const first = try backend.capture(&original);
    var now = try backend.nowMs();
    try validateFrame(registry, &original, &first, now, false);
    const plan = if (request.dry_run)
        try planner.selectedPlan(registry, first.input(), request.target, request.stops, now)
    else
        try planner.verifyApproval(registry, first.input(), request.target, request.stops, request.approved_hash.?, now);
    report.hash = plan.fingerprint;
    report.planned = plan.len;
    if (request.dry_run) {
        report.outcome = .preview;
        return;
    }
    var expected_revision = original.revision;
    for (plan.view(), 0..) |step, i| {
        report.failed_step = i;
        report.stage = .preflight;
        const state = try store.state();
        if (state.revision != expected_revision or state.operation != null) return error.InventoryDrift;
        const prior = try backend.capture(&state);
        now = try backend.nowMs();
        try validateFrame(registry, &state, &prior, now, false);
        try sameIdentity(&first, &prior);
        // Before the FIRST side effect re-validate the exact approved plan
        // including resource observations. Later steps necessarily differ
        // in revision/power state, but must fit the approved step envelope.
        if (i == 0) _ = try planner.verifyApproval(registry, prior.input(), request.target, request.stops, request.approved_hash.?, now);
        const guest = prior.entries[step.index].guest orelse return error.InvalidInventory;
        const record = state.initial.guests[try state.index(guest)].?;
        const transitional: model.Phase = if (step.action == .start) .pending else .stopping;
        const target_phase: model.Phase = if (step.action == .start) .active else .stopped;
        try checkPhase(state, &prior, guest, transitional, step.during, now);
        const evidence = prior.evidence[step.index].?;
        report.stage = .intent;
        const serial = switch (step.action) {
            .start => try tx.beginStart(store, guest, true, evidence, prior.snapshot, prior.budget, now),
            .stop => try tx.beginStop(store, guest, true, evidence, now),
        };
        const intent = try store.state();
        report.stage = .arm;
        const ready = try backend.capture(&intent);
        now = try backend.nowMs();
        try validateFrame(registry, &intent, &ready, now, false);
        try sameIdentity(&first, &ready);
        try checkPhase(intent, &ready, guest, transitional, step.during, now);
        try tx.arm(store, serial, true, ready.evidence[step.index].?, ready.snapshot, ready.budget, now);

        // Flush completed before dispatch. Re-observe once more after the
        // barrier; failure here leaves an ambiguous dispatch conservatively.
        const armed = try store.state();
        report.stage = .dispatch_check;
        const dispatch = try backend.capture(&armed);
        now = try backend.nowMs();
        try validateFrame(registry, &armed, &dispatch, now, false);
        try sameIdentity(&first, &dispatch);
        try checkPhase(armed, &dispatch, guest, transitional, step.during, now);
        report.stage = .provider;
        report.dispatched += 1;
        // Backend may execute one bounded graceful operation only, on this
        // exact owned guest; no forced fallback or second command on failure.
        try backend.perform(step.action, record.owner, serial);
        report.stage = .completion;
        const after = try backend.capture(&armed);
        now = try backend.nowMs();
        try validateFrame(registry, &armed, &after, now, true);
        try sameIdentity(&first, &after);
        try checkPhase(armed, &after, guest, target_phase, step.after, now);
        try tx.complete(store, serial, true, after.evidence[step.index].?, now);
        report.completed += 1;
        expected_revision = try std.math.add(u64, expected_revision, 3);
        const committed = try store.state();
        report.revision = committed.revision;
        if (committed.revision != expected_revision or committed.operation != null)
            return error.InventoryDrift;
    }
    report.failed_step = null;
    report.stage = .done;
    report.outcome = .complete;
}

const mib = governor.mib;
const gib = governor.gib;
const Fake = struct {
    registry: *const registry_mod.Registry,
    store: *Store,
    guest_slots: [planner.max_modules]?usize = @splat(null),
    powers: [model.max_guests]ids.PowerState = @splat(.powered_off),
    actions: [planner.max_steps]planner.Action = undefined,
    calls: usize = 0,
    captures: usize = 0,
    fail_capture: ?usize = null,
    fail_action: ?usize = null,
    fail_release: bool = false,
    fail_ready: bool = false,
    drift_after_stop: bool = false,
    changed_mapping: bool = false,
    changed_budget: bool = false,
    host_lock: bool = true,
    disk_drift: bool = false,

    fn init(registry: *const registry_mod.Registry, store: *Store) !Fake {
        var fake: Fake = .{ .registry = registry, .store = store };
        const names = [_][]const u8{ "ad-core", "member-server", "linux-tools" };
        for (names, 0..) |name, slot| {
            const index = registry.index(try manifest.Id.parse(name)).?;
            fake.guest_slots[index] = slot;
        }
        const state = try store.state();
        for (state.phases, 0..) |phase, i| {
            if (phase == .active) fake.powers[i] = .running;
        }
        return fake;
    }

    fn nowMs(_: *Fake) !u64 {
        return 1001;
    }

    fn capture(self: *Fake, state: *const model.State) !Frame {
        self.captures += 1;
        if (self.fail_capture == self.captures) return error.InjectedObservation;
        var frame: Frame = .{
            .lab = state.initial.lab,
            .revision = state.revision,
            .inventory_digest = @splat(42),
            .len = self.registry.len,
            .snapshot = .{
                .inventory_revision = state.revision,
                .inventory_observed_ms = 1000,
                .memory = .{ .started_ms = 1000, .completed_ms = 1000, .physical_total = 8 * gib, .physical_available = 6 * gib, .commit_limit = 12 * gib, .committed = 4 * gib },
                .disk = .{ .started_ms = 1000, .completed_ms = 1000, .total_to_caller = 64 * gib, .available_to_caller = 32 * gib },
                .disk_totals = .{ .reported_bytes = 16 * gib, .strict_upper_bound = 16 * gib },
                .provider_reconciled = true,
                .host_scope_verified = true,
                .disk_volume_verified = true,
            },
            .budget = .{ .shared_peak = bounds.BoundPair.upper(128 * mib, 128 * mib) },
            .host_lock_verified = self.host_lock,
        };
        if (self.calls > 0 and self.changed_budget) frame.budget.lab_memory_limit += mib;
        if (self.calls > 0 and self.disk_drift) {
            frame.snapshot.disk_totals.reported_bytes = 20 * gib;
            frame.snapshot.disk_totals.strict_upper_bound = 20 * gib;
        }
        // Inject RAM pressure before the next start, after stop committed.
        if (self.drift_after_stop and self.calls == 1 and state.operation == null)
            frame.snapshot.memory.physical_available = 2 * gib;
        for (self.registry.view(), 0..) |m, i| {
            frame.entries[i] = .{ .id = m.id, .status = .absent };
            const slot = self.guest_slots[i] orelse continue;
            const record = state.initial.guests[slot].?;
            const power = self.powers[slot];
            frame.entries[i] = .{
                .id = m.id,
                .status = if (power == .running) .running else .stopped,
                .guest = record.owner.guest,
                .cost = record.cost.envelope(),
            };
            frame.evidence[i] = .{
                .revision = state.revision,
                .observed_ms = 1000,
                .owner = record.owner,
                .observed = .{ .vm = record.owner.vm, .power = power, .memory_bytes = record.cost.guest_bytes, .network = .compatible, .isolation_verified = true },
                .markers_verified = true,
                .inventory_verified = true,
                .media_verified = true,
                .observed_medium = record.medium,
                .observed_parent = record.parent,
                .observed_base_sha256 = record.base_sha256,
                .native_ready = !(self.fail_ready and self.calls >= 2 and slot == 2),
                .scratch_accounted = true,
                .release_verified = !(self.fail_release and self.calls >= 1 and slot == 1),
            };
        }
        if (self.changed_mapping and self.calls > 0) {
            const a = self.registry.index(try manifest.Id.parse("member-server")).?;
            const b = self.registry.index(try manifest.Id.parse("linux-tools")).?;
            std.mem.swap(?ids.Uuid, &frame.entries[a].guest, &frame.entries[b].guest);
        }
        return frame;
    }

    fn perform(self: *Fake, action: planner.Action, owner: ids.OwnedGuest, serial: u64) !void {
        // Assert the journal was flushed to dispatch BEFORE the fake action.
        const state = try self.store.state();
        const op = state.operation orelse return error.MissingDispatch;
        if (op.stage != .dispatch or op.serial != serial or !op.guest.eql(owner.guest) or
            (op.kind == .start) != (action == .start)) return error.MissingDispatch;
        const slot = try state.index(owner.guest);
        self.actions[self.calls] = action;
        self.calls += 1;
        // Deliberately change observed power before ambiguous failure.
        self.powers[slot] = if (action == .start) .running else .powered_off;
        if (self.fail_action == self.calls) return error.InjectedProvider;
    }
};

fn fixtureInitial() model.Initial {
    var initial = model.exampleInitial();
    var member = initial.guests[0].?;
    member.owner.guest = model.exampleId("6");
    member.owner.vm = model.exampleId("7");
    member.medium = model.exampleId("8");
    member.cost.guest_bytes = 512 * mib;
    initial.guests[1] = member;
    var tools = member;
    tools.owner.guest = model.exampleId("9");
    tools.owner.vm = model.exampleId("a");
    tools.medium = model.exampleId("b");
    initial.guests[2] = tools;
    return initial;
}

fn seedActive(store: *Store, slot: usize) !void {
    const state = try store.state();
    const serial = state.revision + 1;
    const guest = state.initial.guests[slot].?.owner.guest;
    // Test-only initial journal fixture; no runtime coordinator bypass.
    try store.append(state.revision, .{ .kind = .intent, .operation = .{ .serial = serial, .guest = guest, .kind = .start } });
    try store.append(serial, .{ .kind = .dispatch, .serial = serial });
    try store.append(serial + 1, .{ .kind = .complete, .serial = serial });
}

fn approvedPlan(store: *Store, registry: *const registry_mod.Registry, fake: *Fake) !planner.Plan {
    const target = try manifest.Id.parse("linux-tools");
    const options = try preview(store, registry, fake, target);
    try std.testing.expect(options.choice_required and options.keep != null);
    try std.testing.expectEqual(@as(usize, 1), options.len);
    return options.options[0];
}

test "dry run and decline never write journal or invoke provider" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.create(tmp.dir, fixtureInitial());
    defer store.close();
    try seedActive(&store, 0);
    try seedActive(&store, 1);
    const registry = try registry_mod.Registry.builtin();
    var fake = try Fake.init(&registry, &store);
    const original = try store.state();
    const length = try store.file.getEndPos();
    const target = try manifest.Id.parse("linux-tools");
    const declined = execute(&store, &registry, &fake, .{ .target = target });
    try std.testing.expectEqual(Outcome.refused, declined.outcome);
    try std.testing.expectEqual(error.ApprovalRequired, declined.failure.?);
    try std.testing.expectEqual(@as(usize, 0), fake.captures);
    const plan = try approvedPlan(&store, &registry, &fake);
    const dry = execute(&store, &registry, &fake, .{ .target = target, .stops = plan.stop_mask, .dry_run = true });
    try std.testing.expectEqual(Outcome.preview, dry.outcome);
    try std.testing.expectEqualStrings(&plan.fingerprint, &dry.hash.?);
    const wrong = execute(&store, &registry, &fake, .{ .target = target, .stops = 0, .approved_hash = &plan.fingerprint });
    try std.testing.expectEqual(error.StalePlan, wrong.failure.?);
    try std.testing.expectEqual(original.revision, (try store.state()).revision);
    try std.testing.expectEqual(length, try store.file.getEndPos());
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "approved switch executes stop before start, each step durable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.create(tmp.dir, fixtureInitial());
    try seedActive(&store, 0);
    try seedActive(&store, 1);
    const registry = try registry_mod.Registry.builtin();
    var fake = try Fake.init(&registry, &store);
    const plan = try approvedPlan(&store, &registry, &fake);
    const report = execute(&store, &registry, &fake, .{ .target = try manifest.Id.parse("linux-tools"), .stops = plan.stop_mask, .approved_hash = &plan.fingerprint });
    try std.testing.expectEqual(Outcome.complete, report.outcome);
    try std.testing.expectEqual(@as(usize, 2), report.completed);
    try std.testing.expectEqualSlices(planner.Action, &.{ .stop, .start }, fake.actions[0..fake.calls]);
    store.close();
    store = try Store.open(tmp.dir);
    defer store.close();
    const state = try store.state();
    try std.testing.expectEqual(@as(u64, 13), state.revision);
    try std.testing.expectEqual(model.Phase.active, state.phases[0]);
    try std.testing.expectEqual(model.Phase.stopped, state.phases[1]);
    try std.testing.expectEqual(model.Phase.active, state.phases[2]);
    try std.testing.expect(state.operation == null);
}

test "every observation failure stops the switch and preserves replayable progress" {
    // Two-step switch: initial capture, then four captures for each step.
    for (1..10) |failure_index| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var store = try Store.create(tmp.dir, fixtureInitial());
        try seedActive(&store, 0);
        try seedActive(&store, 1);
        const registry = try registry_mod.Registry.builtin();
        var fake = try Fake.init(&registry, &store);
        const plan = try approvedPlan(&store, &registry, &fake);
        fake.captures = 0;
        fake.fail_capture = failure_index;
        const report = execute(&store, &registry, &fake, .{ .target = try manifest.Id.parse("linux-tools"), .stops = plan.stop_mask, .approved_hash = &plan.fingerprint });
        try std.testing.expectEqual(error.InjectedObservation, report.failure.?);
        const expected_calls: usize = if (failure_index < 5) 0 else if (failure_index < 9) 1 else 2;
        try std.testing.expectEqual(expected_calls, fake.calls);
        store.close();
        store = try Store.open(tmp.dir);
        defer store.close();
        const state = try store.state();
        if (state.operation != null) {
            try std.testing.expectEqual(Outcome.recovery_required, report.outcome);
            const ledger = try state.ledger();
            try std.testing.expect(ledger.len >= 2);
            fake.fail_capture = null;
            const replay = execute(&store, &registry, &fake, .{ .target = try manifest.Id.parse("linux-tools"), .stops = plan.stop_mask, .approved_hash = &plan.fingerprint });
            try std.testing.expectEqual(Outcome.recovery_required, replay.outcome);
            try std.testing.expectEqual(expected_calls, fake.calls);
        } else {
            try std.testing.expectEqual(if (report.completed == 0) Outcome.refused else Outcome.partial, report.outcome);
        }
    }
}

test "ambiguous provider failure and missing release or readiness never advance" {
    for (0..4) |scenario| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var store = try Store.create(tmp.dir, fixtureInitial());
        try seedActive(&store, 0);
        try seedActive(&store, 1);
        const registry = try registry_mod.Registry.builtin();
        var fake = try Fake.init(&registry, &store);
        const plan = try approvedPlan(&store, &registry, &fake);
        switch (scenario) {
            0 => fake.fail_action = 1,
            1 => fake.fail_release = true,
            2 => fake.fail_action = 2,
            3 => fake.fail_ready = true,
            else => unreachable,
        }
        const report = execute(&store, &registry, &fake, .{ .target = try manifest.Id.parse("linux-tools"), .stops = plan.stop_mask, .approved_hash = &plan.fingerprint });
        try std.testing.expectEqual(Outcome.recovery_required, report.outcome);
        try std.testing.expectEqual(@as(usize, if (scenario < 2) 1 else 2), fake.calls);
        store.close();
        store = try Store.open(tmp.dir);
        defer store.close();
        const state = try store.state();
        try std.testing.expectEqual(model.Stage.dispatch, state.operation.?.stage);
        try std.testing.expectEqual(@as(usize, 2), (try state.ledger()).len);
    }
}

test "fresh host pressure after completed stop requires a new plan" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.create(tmp.dir, fixtureInitial());
    defer store.close();
    try seedActive(&store, 0);
    try seedActive(&store, 1);
    const registry = try registry_mod.Registry.builtin();
    var fake = try Fake.init(&registry, &store);
    const plan = try approvedPlan(&store, &registry, &fake);
    fake.drift_after_stop = true;
    const request: Request = .{ .target = try manifest.Id.parse("linux-tools"), .stops = plan.stop_mask, .approved_hash = &plan.fingerprint };
    const report = execute(&store, &registry, &fake, request);
    try std.testing.expectEqual(Outcome.partial, report.outcome);
    try std.testing.expectEqual(error.HostPhysicalReserve, report.failure.?);
    try std.testing.expectEqual(@as(usize, 1), report.completed);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    const state = try store.state();
    try std.testing.expect(state.operation == null);
    try std.testing.expectEqual(model.Phase.stopped, state.phases[1]);
    fake.drift_after_stop = false;
    const replay = execute(&store, &registry, &fake, request);
    try std.testing.expectEqual(Outcome.refused, replay.outcome);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
}

test "mapping, budget, disk growth and host lock drift fail closed" {
    for (0..4) |scenario| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var store = try Store.create(tmp.dir, fixtureInitial());
        defer store.close();
        try seedActive(&store, 0);
        try seedActive(&store, 1);
        const registry = try registry_mod.Registry.builtin();
        var fake = try Fake.init(&registry, &store);
        const plan = try approvedPlan(&store, &registry, &fake);
        switch (scenario) {
            0 => fake.changed_mapping = true,
            1 => fake.changed_budget = true,
            2 => fake.disk_drift = true,
            3 => fake.host_lock = false,
            else => unreachable,
        }
        const report = execute(&store, &registry, &fake, .{ .target = try manifest.Id.parse("linux-tools"), .stops = plan.stop_mask, .approved_hash = &plan.fingerprint });
        try std.testing.expectEqual(if (scenario == 3) Outcome.refused else Outcome.recovery_required, report.outcome);
        try std.testing.expectEqual(@as(usize, if (scenario == 3) 0 else 1), fake.calls);
        try std.testing.expectEqual(@as(usize, 0), report.completed);
    }
}
