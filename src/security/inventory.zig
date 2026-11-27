const std = @import("std");
const ids = @import("../provider/types.zig");
const model = @import("../state/model.zig");
const Digest = @import("../image/digest.zig").Digest;
const cat = @import("../image/catalogue.zig");
const path = @import("windows_path.zig");

pub const max_vms = model.max_guests;
pub const max_disks = cat.max_disks;

pub const Failure = error{
    InvalidInventory,
    InventoryLimit,
    ForeignVM,
    MissingVM,
    DuplicateVM,
    UnsafeVM,
    IncompleteEvidence,
    ForeignDisk,
    MissingDisk,
    DuplicateDisk,
    UnsafeDisk,
    StaleEvidence,
    InventoryChanged,
    RecoveryRequired,
};

pub const VmSet = struct {
    entries: [max_vms]ids.Uuid = undefined,
    len: usize = 0,

    pub fn view(self: *const VmSet) []const ids.Uuid {
        return self.entries[0..self.len];
    }

    pub fn contains(self: *const VmSet, id: ids.Uuid) bool {
        for (self.view()) |entry| if (entry.eql(id)) return true;
        return false;
    }

    pub fn same(a: *const VmSet, b: *const VmSet) bool {
        if (a.len != b.len) return false;
        for (a.view()) |id| if (!b.contains(id)) return false;
        return true;
    }
};

/// VBoxManage list vms/runningvms. Only UUIDs survive the parser. Names are
/// never used for ownership, printed, or interpolated into a command.
pub fn parseVmList(output: []const u8) Failure!VmSet {
    if (output.len > 64 * 1024) return error.InventoryLimit;
    var result: VmSet = .{};
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        const line = if (raw.len != 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
        if (line.len == 0) continue;
        if (line.len < 41 or line.len > 1024 or line[0] != '"' or line[line.len - 1] != '}') return error.InvalidInventory;
        for (line) |c| if (c < 32 or c == 127) return error.InvalidInventory;
        const suffix = line.len - 39;
        if (!std.mem.eql(u8, line[suffix .. suffix + 2], " {") or suffix < 2 or line[suffix - 1] != '"')
            return error.InvalidInventory;
        const name = line[1 .. suffix - 1];
        if (name.len == 0 or std.mem.eql(u8, name, "<inaccessible>") or std.mem.indexOfScalar(u8, name, '"') != null)
            return error.InvalidInventory;
        const id = ids.Uuid.parse(line[suffix + 2 .. line.len - 1]) catch return error.InvalidInventory;
        if (result.contains(id)) return error.DuplicateVM;
        if (result.len == max_vms) return error.InventoryLimit;
        result.entries[result.len] = id;
        result.len += 1;
    }
    return result;
}

pub const VmEvidence = struct {
    owner: ids.OwnedGuest,
    observed: ids.Observation,
    overlay: ids.Uuid,
    // Nullable means unavailable, never assume a missing field is disabled.
    shared_folders: ?u32 = null,
    port_forwards: ?u32 = null,
    usb_controllers: ?u32 = null,
    usb_filters: ?u32 = null,
    host_devices: ?u32 = null,
    serial_parallel_ports: ?u32 = null,
    other_media: ?u32 = null, // including writable removable and passthrough media
    snapshots: ?u32 = null,
    extra_storage_attachments: ?u32 = null,
    clipboard_disabled: ?bool = null,
    drag_drop_disabled: ?bool = null,
    remote_display_disabled: ?bool = null,
    nic_inventory_complete: bool = false,
    markers_verified: bool = false,
    // Verified guest-local policy (including no external routes/DNS), not
    // inferred from an intnet NIC. Stopped guests require separate evidence.
    guest_network_verified: bool = false,
};

pub const DiskEvidence = struct {
    medium: ids.Uuid,
    parent: ?ids.Uuid,
    owner_vm: ?ids.Uuid,
    relative_path: []const u8,
    identity: path.Identity,
    virtual_bytes: u64,
    // Base contents are independently hashed; the overlay is mutable.
    base_digest: ?Digest = null,
    sealed_generalised_base: bool = false,
    vdi_dynamic: bool = false,
    paths_verified: bool = false,
    attachments_verified: bool = false,
};

pub const Snapshot = struct {
    revision: u64,
    started_ms: u64,
    completed_ms: u64,
    registered_before: VmSet,
    registered_after: VmSet,
    running_before: VmSet,
    running_after: VmSet,
    vms: []const VmEvidence,
    disks: []const DiskEvidence,
    // Evidence supplied by an independent trusted collector, not CLI flags.
    // Registered VM enumeration alone is per provider account/configuration.
    full_provider_scope: bool = false,
    all_media_enumerated: bool = false,
    all_internal_peers_verified: bool = false,
    trusted_root_and_acls: bool = false,
};

fn zero(value: ?u32) Failure!void {
    if ((value orelse return error.IncompleteEvidence) != 0) return error.UnsafeVM;
}

fn enabled(value: ?bool) Failure!void {
    if (!(value orelse return error.IncompleteEvidence)) return error.UnsafeVM;
}

fn guestForVm(state: *const model.State, vm: ids.Uuid) ?model.Guest {
    for (state.initial.guests) |entry| {
        if (entry) |guest| {
            if (guest.owner.vm.eql(vm)) return guest;
        }
    }
    return null;
}

fn diskFor(disks: []const DiskEvidence, id: ids.Uuid) ?*const DiskEvidence {
    for (disks) |*disk| if (disk.medium.eql(id)) return disk;
    return null;
}

pub const Result = struct {
    // Pure model validation does NOT issue an isolation attestation or
    // unlock the mutation transport. Native collection is incomplete.
    model_compatible: bool = true,
    mutation_permitted: bool = false,
};

pub fn verify(state: *const model.State, snapshot: Snapshot, now: u64) Failure!Result {
    if (state.operation != null) return error.RecoveryRequired;
    if (state.revision != snapshot.revision or snapshot.started_ms > snapshot.completed_ms or
        snapshot.completed_ms > now or now - snapshot.started_ms > 5000) return error.StaleEvidence;
    if (!snapshot.full_provider_scope or !snapshot.all_media_enumerated or
        !snapshot.all_internal_peers_verified or !snapshot.trusted_root_and_acls) return error.IncompleteEvidence;
    if (snapshot.vms.len > max_vms or snapshot.disks.len > max_disks or
        snapshot.registered_before.len > max_vms or snapshot.registered_after.len > max_vms or
        snapshot.running_before.len > max_vms or snapshot.running_after.len > max_vms) return error.InventoryLimit;
    if (!snapshot.registered_before.same(&snapshot.registered_after) or
        !snapshot.running_before.same(&snapshot.running_after)) return error.InventoryChanged;
    model.validateInitial(state.initial) catch return error.InvalidInventory;
    for (snapshot.registered_before.view()) |vm| {
        if (!vm.valid() or guestForVm(state, vm) == null) return error.ForeignVM;
    }
    for (snapshot.running_before.view()) |vm| {
        if (!snapshot.registered_before.contains(vm)) return error.ForeignVM;
    }
    var expected_count: usize = 0;
    for (state.initial.guests, state.phases) |entry, phase| {
        const guest = entry orelse continue;
        expected_count += 1;
        if (!snapshot.registered_before.contains(guest.owner.vm)) return error.MissingVM;
        const running = switch (phase) {
            .active => true,
            .stopped => false,
            else => return error.RecoveryRequired,
        };
        if (snapshot.running_before.contains(guest.owner.vm) != running) return error.InventoryChanged;
        var seen: usize = 0;
        for (snapshot.vms) |vm| {
            if (!vm.owner.vm.eql(guest.owner.vm)) continue;
            seen += 1;
            if (!std.meta.eql(vm.owner, guest.owner) or !vm.observed.vm.eql(guest.owner.vm) or
                vm.observed.memory_bytes != guest.cost.guest_bytes or !vm.overlay.eql(guest.medium))
                return error.UnsafeVM;
            if (vm.observed.power != (if (running) ids.PowerState.running else .powered_off) or
                vm.observed.network != .compatible) return error.UnsafeVM;
            if (!vm.markers_verified or !vm.nic_inventory_complete or !vm.guest_network_verified)
                return error.IncompleteEvidence;
            for ([_]?u32{
                vm.shared_folders, vm.port_forwards, vm.usb_controllers, vm.usb_filters,
                vm.host_devices, vm.serial_parallel_ports, vm.other_media, vm.snapshots,
                vm.extra_storage_attachments,
            }) |value| try zero(value);
            for ([_]?bool{ vm.clipboard_disabled, vm.drag_drop_disabled, vm.remote_display_disabled }) |value| try enabled(value);
        }
        if (seen == 0) return error.MissingVM;
        if (seen != 1) return error.DuplicateVM;
        const child = diskFor(snapshot.disks, guest.medium) orelse return error.MissingDisk;
        const parent = diskFor(snapshot.disks, guest.parent) orelse return error.MissingDisk;
        const expected_digest = Digest.parse(&guest.base_sha256) catch return error.InvalidInventory;
        const child_parent = child.parent orelse return error.UnsafeDisk;
        const child_owner = child.owner_vm orelse return error.UnsafeDisk;
        const base_digest = parent.base_digest orelse return error.UnsafeDisk;
        const child_path = cat.overlayPath(guest.owner.guest) catch return error.InvalidInventory;
        if (!child_parent.eql(guest.parent) or !child_owner.eql(guest.owner.vm) or child.base_digest != null or
            child.sealed_generalised_base or !std.mem.eql(u8, child.relative_path, &child_path) or
            parent.parent != null or parent.owner_vm != null or !parent.sealed_generalised_base or
            !base_digest.eql(expected_digest) or !std.mem.eql(u8, parent.relative_path, &expected_digest.basePath()) or
            child.virtual_bytes == 0 or child.virtual_bytes != parent.virtual_bytes) return error.UnsafeDisk;
    }
    if (snapshot.vms.len != expected_count or snapshot.registered_before.len != expected_count)
        return error.ForeignVM;
    for (snapshot.disks, 0..) |disk, i| {
        if (!disk.medium.valid() or !disk.vdi_dynamic or !disk.paths_verified or !disk.attachments_verified or disk.identity.file_index == 0)
            return error.UnsafeDisk;
        for (snapshot.disks[0..i]) |prior| {
            if (disk.medium.eql(prior.medium) or disk.identity.eql(prior.identity)) return error.DuplicateDisk;
            if (disk.identity.volume != prior.identity.volume) return error.UnsafeDisk;
        }
        var expected = false;
        for (state.initial.guests) |entry| {
            if (entry) |guest| {
                if (disk.medium.eql(guest.medium) or disk.medium.eql(guest.parent)) expected = true;
            }
        }
        if (!expected) return error.ForeignDisk;
    }
    return .{};
}

const Fixture = struct {
    state: model.State,
    vms: [1]VmEvidence,
    disks: [2]DiskEvidence,
    registered: VmSet,

    fn init() !Fixture {
        const state = try model.apply(null, 1, .{ .kind = .initialise, .initial = model.exampleInitial() });
        const guest = state.initial.guests[0].?;
        const digest = try Digest.parse(&guest.base_sha256);
        var registered: VmSet = .{};
        registered.entries[0] = guest.owner.vm;
        registered.len = 1;
        return .{
            .state = state,
            .registered = registered,
            .vms = .{.{
                .owner = guest.owner,
                .observed = .{ .vm = guest.owner.vm, .power = .powered_off, .memory_bytes = guest.cost.guest_bytes, .network = .compatible },
                .overlay = guest.medium,
                .shared_folders = 0,
                .port_forwards = 0,
                .usb_controllers = 0,
                .usb_filters = 0,
                .host_devices = 0,
                .serial_parallel_ports = 0,
                .other_media = 0,
                .snapshots = 0,
                .extra_storage_attachments = 0,
                .clipboard_disabled = true,
                .drag_drop_disabled = true,
                .remote_display_disabled = true,
                .nic_inventory_complete = true,
                .markers_verified = true,
                .guest_network_verified = true,
            }},
            .disks = .{
                .{
                    .medium = guest.parent,
                    .parent = null,
                    .owner_vm = null,
                    .relative_path = "bases/" ++ ("a" ** 64) ++ ".vdi",
                    .identity = .{ .volume = 1, .file_index = 1 },
                    .virtual_bytes = 40 * 1024 * 1024 * 1024,
                    .base_digest = digest,
                    .sealed_generalised_base = true,
                    .vdi_dynamic = true,
                    .paths_verified = true,
                    .attachments_verified = true,
                },
                .{
                    .medium = guest.medium,
                    .parent = guest.parent,
                    .owner_vm = guest.owner.vm,
                    .relative_path = "overlays/21234567-89ab-cdef-0123-456789abcdef.vdi",
                    .identity = .{ .volume = 1, .file_index = 2 },
                    .virtual_bytes = 40 * 1024 * 1024 * 1024,
                    .vdi_dynamic = true,
                    .paths_verified = true,
                    .attachments_verified = true,
                },
            },
        };
    }

    fn snapshot(self: *const Fixture) Snapshot {
        return .{
            .revision = self.state.revision,
            .started_ms = 1000,
            .completed_ms = 1001,
            .registered_before = self.registered,
            .registered_after = self.registered,
            .running_before = .{},
            .running_after = .{},
            .vms = &self.vms,
            .disks = &self.disks,
            .full_provider_scope = true,
            .all_media_enumerated = true,
            .all_internal_peers_verified = true,
            .trusted_root_and_acls = true,
        };
    }
};

test "registered inventory parser discards names and refuses inaccessible or duplicate entries" {
    const valid = "\"private name\" {31234567-89ab-cdef-0123-456789abcdef}\r\n";
    const parsed = try parseVmList(valid);
    try std.testing.expectEqual(@as(usize, 1), parsed.len);
    try std.testing.expectEqualStrings("31234567-89ab-cdef-0123-456789abcdef", &parsed.entries[0].text);
    try std.testing.expectError(error.DuplicateVM, parseVmList(valid ++ valid));
    try std.testing.expectError(error.InvalidInventory, parseVmList("\"<inaccessible>\" {31234567-89ab-cdef-0123-456789abcdef}\n"));
    try std.testing.expectError(error.InvalidInventory, parseVmList("unexpected provider warning"));
    try std.testing.expectEqual(@as(usize, 0), (try parseVmList("")).len);
}

test "compatible synthetic inventory never issues a mutation permit" {
    const f = try Fixture.init();
    const result = try verify(&f.state, f.snapshot(), 1002);
    try std.testing.expect(result.model_compatible and !result.mutation_permitted);
    var snapshot = f.snapshot();
    snapshot.full_provider_scope = false;
    try std.testing.expectError(error.IncompleteEvidence, verify(&f.state, snapshot, 1002));
    snapshot = f.snapshot();
    snapshot.registered_after.len = 0;
    try std.testing.expectError(error.InventoryChanged, verify(&f.state, snapshot, 1002));
    try std.testing.expectError(error.StaleEvidence, verify(&f.state, f.snapshot(), 6001));
}

test "every unsafe or unknown VM attachment fails closed" {
    const baseline = try Fixture.init();
    const fields = .{
        "shared_folders", "port_forwards", "usb_controllers", "usb_filters",
        "host_devices", "serial_parallel_ports", "other_media", "snapshots", "extra_storage_attachments",
    };
    inline for (fields) |field| {
        var f = baseline;
        @field(f.vms[0], field) = 1;
        try std.testing.expectError(error.UnsafeVM, verify(&f.state, f.snapshot(), 1002));
        @field(f.vms[0], field) = null;
        try std.testing.expectError(error.IncompleteEvidence, verify(&f.state, f.snapshot(), 1002));
    }
    var f = baseline;
    f.vms[0].observed.network = .rejected;
    try std.testing.expectError(error.UnsafeVM, verify(&f.state, f.snapshot(), 1002));
    f = baseline;
    f.vms[0].guest_network_verified = false;
    try std.testing.expectError(error.IncompleteEvidence, verify(&f.state, f.snapshot(), 1002));
}

test "foreign guest, wrong parent, alias, changed hash and escaped path refuse" {
    const baseline = try Fixture.init();
    var f = baseline;
    f.registered.entries[1] = model.exampleId("9");
    f.registered.len = 2;
    try std.testing.expectError(error.ForeignVM, verify(&f.state, f.snapshot(), 1002));
    f = baseline;
    f.disks[1].parent = model.exampleId("9");
    try std.testing.expectError(error.UnsafeDisk, verify(&f.state, f.snapshot(), 1002));
    f = baseline;
    f.disks[1].identity = f.disks[0].identity;
    try std.testing.expectError(error.DuplicateDisk, verify(&f.state, f.snapshot(), 1002));
    f = baseline;
    f.disks[0].base_digest.?.bytes[0] ^= 1;
    try std.testing.expectError(error.UnsafeDisk, verify(&f.state, f.snapshot(), 1002));
    f = baseline;
    f.disks[1].relative_path = "../outside.vdi";
    try std.testing.expectError(error.UnsafeDisk, verify(&f.state, f.snapshot(), 1002));
}
