const std = @import("std");
const ids = @import("../provider/types.zig");
const Digest = @import("digest.zig").Digest;
const accounting = @import("../storage/accounting.zig");

pub const max_disks = 128;
pub const Failure = accounting.Failure || error{
    InvalidIdentity,
    InvalidDisk,
    CatalogueLimit,
    DuplicateMedium,
    DuplicateBase,
    DuplicateGuest,
    MissingParent,
    NestedOverlay,
    CapacityMismatch,
    UnsealedBase,
    BaseProtected,
    StalePlan,
    InvalidChild,
    AllocationExceeded,
    NotFound,
    Referenced,
    Pinned,
    NotDetached,
    Unreconciled,
    BaseDigestMismatch,
    InvalidScratch,
};

pub const Attachment = enum { detached, powered_off_guest, active_guest, unknown };
pub const Base = struct {
    digest: Digest,
    generalised: bool,
    sealed: bool,
};
pub const Overlay = struct {
    parent: ids.Uuid,
    owner: ids.OwnedGuest,
};
pub const Disk = struct {
    medium: ids.Uuid,
    virtual_bytes: u64,
    file_length: ?u64,
    charge: accounting.Charge,
    attachment: Attachment,
    pinned: bool = false,
    role: union(enum) {
        base: Base,
        overlay: Overlay,
    },
};

pub fn overlayPath(guest: ids.Uuid) Failure![49]u8 {
    if (!guest.valid()) return error.InvalidIdentity;
    return "overlays/".* ++ guest.text ++ ".vdi".*;
}

pub const Catalogue = struct {
    lab: ids.Uuid,
    disks: []const Disk,
    // Includes all other retained artefacts and filesystem overhead; cannot be
    // derived from disk files alone. These attestations come from a future
    // reconciler, not from untrusted manifests or user CLI flags.
    auxiliary_charge: accounting.Charge = .unknown,
    inventory_complete: bool = false,
    provider_reconciled: bool = false,

    pub fn find(self: Catalogue, medium: ids.Uuid) ?*const Disk {
        for (self.disks) |*disk| {
            if (disk.medium.eql(medium)) return disk;
        }
        return null;
    }

    pub fn validate(self: Catalogue) Failure!void {
        if (!self.lab.valid()) return error.InvalidIdentity;
        if (self.disks.len > max_disks) return error.CatalogueLimit;
        for (self.disks, 0..) |disk, index| {
            if (!disk.medium.valid() or disk.virtual_bytes == 0) return error.InvalidDisk;
            if (disk.file_length) |length| {
                if (length == 0) return error.InvalidDisk;
            }
            for (self.disks[0..index]) |previous| {
                if (disk.medium.eql(previous.medium)) return error.DuplicateMedium;
                switch (disk.role) {
                    .base => |b| switch (previous.role) {
                        .base => |p| if (b.digest.eql(p.digest)) return error.DuplicateBase,
                        .overlay => {},
                    },
                    .overlay => |o| switch (previous.role) {
                        .overlay => |p| if (o.owner.guest.eql(p.owner.guest) or o.owner.vm.eql(p.owner.vm)) return error.DuplicateGuest,
                        .base => {},
                    },
                }
            }
            switch (disk.role) {
                .base => |b| {
                    if (!b.generalised or !b.sealed) return error.UnsealedBase;
                    if (disk.attachment != .detached) return error.NotDetached;
                },
                .overlay => |o| {
                    if (!o.owner.valid() or !o.owner.lab.eql(self.lab) or !o.parent.valid())
                        return error.InvalidIdentity;
                    const parent = self.find(o.parent) orelse return error.MissingParent;
                    switch (parent.role) {
                        .base => {},
                        .overlay => return error.NestedOverlay,
                    }
                    if (parent.virtual_bytes != disk.virtual_bytes) return error.CapacityMismatch;
                },
            }
        }
    }

    pub fn totals(self: Catalogue) Failure!accounting.Totals {
        try self.validate();
        var result: accounting.Totals = .{
            .complete = self.inventory_complete and self.provider_reconciled,
        };
        for (self.disks) |disk| try result.include(disk.charge);
        try result.include(self.auxiliary_charge);
        return result;
    }

    pub fn references(self: Catalogue, medium: ids.Uuid) Failure!usize {
        try self.validate();
        if (self.find(medium) == null) return error.NotFound;
        var count: usize = 0;
        for (self.disks) |disk| switch (disk.role) {
            .overlay => |o| {
                if (o.parent.eql(medium)) count += 1;
            },
            .base => {},
        };
        return count;
    }

    pub fn requireReconciled(self: Catalogue) Failure!void {
        try self.validate();
        if (!self.inventory_complete or !self.provider_reconciled) return error.Unreconciled;
    }

    // Eligibility only, no deletion and no promised savings. Retained detached
    // overlays still reference their parent. External references must have been
    // reconciled by the caller before this predicate can be used.
    pub fn purgeEligible(self: Catalogue, medium: ids.Uuid) Failure!void {
        try self.requireReconciled();
        const disk = self.find(medium) orelse return error.NotFound;
        if (disk.pinned) return error.Pinned;
        if (disk.attachment != .detached) return error.NotDetached;
        if (try self.references(medium) != 0) return error.Referenced;
    }
};

pub fn exampleId(comptime prefix: []const u8) ids.Uuid {
    return ids.Uuid.parse(prefix ++ "1234567-89ab-cdef-0123-456789abcdef") catch unreachable;
}

pub fn exampleOwner(comptime guest: []const u8, comptime vm: []const u8) ids.OwnedGuest {
    return .{ .lab = exampleId("1"), .guest = exampleId(guest), .vm = exampleId(vm) };
}

pub const example_digest: Digest = .{ .bytes = @splat(42) };
pub const example_base: Disk = .{
    .medium = exampleId("2"),
    .virtual_bytes = 40 * 1024 * 1024 * 1024,
    .file_length = 100,
    .charge = .{ .upper_bound = 100 },
    .attachment = .detached,
    .role = .{ .base = .{ .digest = example_digest, .generalised = true, .sealed = true } },
};

pub fn exampleOverlay(comptime medium: []const u8, comptime guest: []const u8, comptime vm: []const u8) Disk {
    return .{
        .medium = exampleId(medium),
        .virtual_bytes = example_base.virtual_bytes,
        .file_length = 10,
        .charge = .{ .upper_bound = 10 },
        .attachment = .detached,
        .role = .{ .overlay = .{ .parent = example_base.medium, .owner = exampleOwner(guest, vm) } },
    };
}

pub fn exampleCatalogue(disks: []const Disk) Catalogue {
    return .{
        .lab = exampleId("1"),
        .disks = disks,
        .auxiliary_charge = .{ .upper_bound = 5 },
        .inventory_complete = true,
        .provider_reconciled = true,
    };
}

test "shared base counted once, retained overlays block base purge" {
    const disks = [_]Disk{ example_base, exampleOverlay("3", "4", "5"), exampleOverlay("6", "7", "8") };
    const cat = exampleCatalogue(&disks);
    try std.testing.expectEqual(@as(u64, 125), try (try cat.totals()).strict());
    try std.testing.expectEqual(@as(usize, 2), try cat.references(example_base.medium));
    try std.testing.expectError(error.Referenced, cat.purgeEligible(example_base.medium));
    try cat.purgeEligible(disks[1].medium);
}

test "catalogue rejects duplicate, unknown, nested and unsafe parents" {
    var disks = [_]Disk{ example_base, exampleOverlay("3", "4", "5"), exampleOverlay("6", "7", "8") };
    var cat = exampleCatalogue(&disks);
    disks[2].medium = disks[1].medium;
    try std.testing.expectError(error.DuplicateMedium, cat.validate());
    disks[2] = exampleOverlay("6", "7", "8");
    disks[2].role.overlay.parent = disks[1].medium;
    try std.testing.expectError(error.NestedOverlay, cat.validate());
    disks[2].role.overlay.parent = exampleId("9");
    try std.testing.expectError(error.MissingParent, cat.validate());
    disks[2] = exampleOverlay("6", "7", "8");
    disks[2].role.overlay.owner = disks[1].role.overlay.owner;
    try std.testing.expectError(error.DuplicateGuest, cat.validate());
    disks[2] = exampleOverlay("6", "7", "8");
    disks[0].role.base.sealed = false;
    try std.testing.expectError(error.UnsealedBase, cat.validate());
    disks[0] = example_base;
    cat.provider_reconciled = false;
    try std.testing.expectError(error.Unreconciled, cat.purgeEligible(disks[1].medium));
}

test "overlay target is derived only from a canonical UUID" {
    const good = exampleId("4");
    try std.testing.expectEqualStrings("overlays/41234567-89ab-cdef-0123-456789abcdef.vdi", &(try overlayPath(good)));
    var bad = good;
    bad.text[0] = '/';
    try std.testing.expectError(error.InvalidIdentity, overlayPath(bad));
}

test "base identity deduplication and purge protections fail closed" {
    var disks = [_]Disk{ example_base, exampleOverlay("3", "4", "5") };
    const catalogue = exampleCatalogue(&disks);
    disks[1].pinned = true;
    try std.testing.expectError(error.Pinned, catalogue.purgeEligible(disks[1].medium));
    disks[1].pinned = false;
    disks[1].attachment = .unknown;
    try std.testing.expectError(error.NotDetached, catalogue.purgeEligible(disks[1].medium));
    disks[1].attachment = .powered_off_guest;
    try std.testing.expectError(error.NotDetached, catalogue.purgeEligible(disks[1].medium));
    disks[1] = example_base;
    disks[1].medium = exampleId("9");
    try std.testing.expectError(error.DuplicateBase, catalogue.validate());
}
