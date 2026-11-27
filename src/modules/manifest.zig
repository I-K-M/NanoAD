const std = @import("std");

pub const max_manifest_bytes = 8192;
pub const max_depth = 6;
pub const max_edges = 8;
pub const max_resource_bytes: u64 = 16 * 1024 * 1024 * 1024 * 1024;
pub const Failure = error{
    InvalidManifest,
    InputLimit,
    InvalidId,
    InvalidVersion,
    UnknownField,
    UnknownProvisioner,
    UnknownCapability,
    UnknownHealthCheck,
    DuplicateEntry,
    InvalidResources,
    InvalidLifecycle,
};

pub const Id = struct {
    bytes: [32]u8 = @splat(0),
    len: u8 = 0,

    pub fn parse(value: []const u8) Failure!Id {
        if (value.len == 0 or value.len > 32) return error.InvalidId;
        var previous_dash = true;
        for (value) |c| {
            if (c == '-') {
                if (previous_dash) return error.InvalidId;
                previous_dash = true;
            } else {
                if (!std.ascii.isLower(c) and !std.ascii.isDigit(c)) return error.InvalidId;
                previous_dash = false;
            }
        }
        if (previous_dash) return error.InvalidId;
        var result: Id = .{ .len = @intCast(value.len) };
        @memcpy(result.bytes[0..value.len], value);
        return result;
    }

    pub fn slice(self: *const Id) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn eql(self: Id, other: Id) bool {
        return std.mem.eql(u8, self.slice(), other.slice());
    }
};

pub const Version = struct {
    bytes: [17]u8 = @splat(0),
    len: u8,

    fn parse(value: []const u8) Failure!Version {
        if (value.len == 0 or value.len > 17) return error.InvalidVersion;
        var parts = std.mem.splitScalar(u8, value, '.');
        for (0..3) |_| {
            const part = parts.next() orelse return error.InvalidVersion;
            if (part.len == 0 or part.len > 5 or (part.len > 1 and part[0] == '0')) return error.InvalidVersion;
            for (part) |c| if (!std.ascii.isDigit(c)) return error.InvalidVersion;
            _ = std.fmt.parseInt(u16, part, 10) catch return error.InvalidVersion;
        }
        if (parts.next() != null) return error.InvalidVersion;
        var result: Version = .{ .len = @intCast(value.len) };
        @memcpy(result.bytes[0..value.len], value);
        return result;
    }

    pub fn slice(self: *const Version) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Kind = enum { fixture, role, guest, tool };
pub const Capability = enum { private_network, differencing_disk, native_ad, replication };
pub const Health = enum { @"guest-ready", @"native-ad", dns, kerberos, @"fixture-integrity", @"domain-membership", @"certificate-service", replication };
pub const Availability = enum { experimental_scripts, planned };
pub const Provisioner = enum {
    @"windows-core-v1",
    @"windows-reference-fixture-v1",
    @"kerberos-policy-v1",
    @"acl-gpo-v1",
    @"windows-member-v1",
    @"linux-tools-v1",
    @"windows-adcs-v1",
    @"windows-secondary-dc-v1",

    fn kind(self: Provisioner) Kind {
        return switch (self) {
            .@"windows-reference-fixture-v1", .@"kerberos-policy-v1", .@"acl-gpo-v1" => .fixture,
            else => .guest,
        };
    }

    fn moduleId(self: Provisioner) []const u8 {
        return switch (self) {
            .@"windows-core-v1" => "ad-core",
            .@"windows-reference-fixture-v1" => "directory-fixtures",
            .@"kerberos-policy-v1" => "kerberos-policy",
            .@"acl-gpo-v1" => "acl-gpo",
            .@"windows-member-v1" => "member-server",
            .@"linux-tools-v1" => "linux-tools",
            .@"windows-adcs-v1" => "adcs",
            .@"windows-secondary-dc-v1" => "second-dc",
        };
    }

    pub fn availability(self: Provisioner) Availability {
        return switch (self) {
            .@"windows-core-v1", .@"windows-reference-fixture-v1", .@"windows-member-v1" => .experimental_scripts,
            else => .planned,
        };
    }
};

pub const Provenance = enum { unmeasured, estimated };
pub const Resources = struct {
    configured_memory_bytes: ?u64,
    peak_extra_memory_bytes: ?u64,
    steady_disk_bytes: ?u64,
    peak_scratch_bytes: ?u64,
    vcpus: ?u8,
    provenance: Provenance,
};

pub const Rollback = enum { reversible, rebuild, irreversible };
pub const Lifecycle = struct {
    rollback_class: Rollback,
    can_stop: bool,
    can_archive: bool,
    retain_by_default: bool,
};

pub fn List(comptime T: type) type {
    return struct {
        items: [max_edges]T = undefined,
        len: usize = 0,

        pub fn view(self: *const @This()) []const T {
            return self.items[0..self.len];
        }

        fn append(self: *@This(), value: T) Failure!void {
            if (self.len >= max_edges) return error.InputLimit;
            for (self.view()) |existing| {
                const same = if (T == Id) existing.eql(value) else existing == value;
                if (same) return error.DuplicateEntry;
            }
            self.items[self.len] = value;
            self.len += 1;
        }
    };
}

pub const Manifest = struct {
    id: Id,
    version: Version,
    kind: Kind,
    enabled_by_default: bool,
    requires: List(Id),
    conflicts: List(Id),
    capabilities: List(Capability),
    resources: Resources,
    lifecycle: Lifecycle,
    provisioner: Provisioner,
    health_checks: List(Health),
};

// Shipped manifests are deliberately canonical ASCII JSON with no escape
// sequences. Scan depth before the JSON decoder can allocate or recurse.
fn preflight(input: []const u8) Failure!void {
    if (input.len == 0 or input.len > max_manifest_bytes) return error.InputLimit;
    var stack: [max_depth]u8 = undefined;
    var depth: usize = 0;
    var in_string = false;
    for (input) |c| {
        if (in_string) {
            if (c == '"') {
                in_string = false;
            } else if (c < 32 or c > 126 or c == '\\') {
                return error.InvalidManifest;
            }
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '{', '[' => {
                if (depth == stack.len) return error.InputLimit;
                stack[depth] = c;
                depth += 1;
            },
            '}', ']' => {
                if (depth == 0 or stack[depth - 1] != @as(u8, if (c == '}') '{' else '['))
                    return error.InvalidManifest;
                depth -= 1;
            },
            else => {
                if (c != 9 and c != 10 and c != 13 and (c < 32 or c > 126)) return error.InvalidManifest;
            },
        }
    }
    if (depth != 0 or in_string) return error.InvalidManifest;
}

const Value = std.json.Value;
const Object = std.json.ObjectMap;

fn object(value: Value, count: usize) Failure!Object {
    if (value != .object) return error.InvalidManifest;
    if (value.object.count() != count) return error.UnknownField;
    return value.object;
}

fn field(obj: Object, key: []const u8) Failure!Value {
    return obj.get(key) orelse return error.UnknownField;
}

fn string(value: Value) Failure![]const u8 {
    if (value != .string) return error.InvalidManifest;
    return value.string;
}

fn boolean(value: Value) Failure!bool {
    if (value != .bool) return error.InvalidManifest;
    return value.bool;
}

fn bounded(value: Value, limit: u64) Failure!?u64 {
    if (value == .null) return null;
    if (value != .integer or value.integer < 0) return error.InvalidResources;
    const number: u64 = @intCast(value.integer);
    if (number > limit) return error.InvalidResources;
    return number;
}

fn enumValue(comptime T: type, value: Value, invalid: Failure) Failure!T {
    return std.meta.stringToEnum(T, try string(value)) orelse return invalid;
}

fn idList(value: Value) Failure!List(Id) {
    if (value != .array) return error.InvalidManifest;
    if (value.array.items.len > max_edges) return error.InputLimit;
    var result: List(Id) = .{};
    for (value.array.items) |item| try result.append(try Id.parse(try string(item)));
    return result;
}

fn enumList(comptime T: type, value: Value, invalid: Failure) Failure!List(T) {
    if (value != .array) return error.InvalidManifest;
    if (value.array.items.len > max_edges) return error.InputLimit;
    var result: List(T) = .{};
    for (value.array.items) |item| try result.append(try enumValue(T, item, invalid));
    return result;
}

fn resources(value: Value) Failure!Resources {
    const obj = try object(value, 6);
    const cpu = try bounded(try field(obj, "vcpus"), 64);
    return .{
        .configured_memory_bytes = try bounded(try field(obj, "configured_memory_bytes"), max_resource_bytes),
        .peak_extra_memory_bytes = try bounded(try field(obj, "peak_extra_memory_bytes"), max_resource_bytes),
        .steady_disk_bytes = try bounded(try field(obj, "steady_disk_bytes"), max_resource_bytes),
        .peak_scratch_bytes = try bounded(try field(obj, "peak_scratch_bytes"), max_resource_bytes),
        .vcpus = if (cpu) |n| @intCast(n) else null,
        .provenance = try enumValue(Provenance, try field(obj, "provenance"), error.InvalidResources),
    };
}

fn lifecycle(value: Value) Failure!Lifecycle {
    const obj = try object(value, 4);
    return .{
        .rollback_class = try enumValue(Rollback, try field(obj, "rollback_class"), error.InvalidLifecycle),
        .can_stop = try boolean(try field(obj, "can_stop")),
        .can_archive = try boolean(try field(obj, "can_archive")),
        .retain_by_default = try boolean(try field(obj, "retain_by_default")),
    };
}

pub fn parse(input: []const u8) Failure!Manifest {
    try preflight(input);
    // Fixed arena; return a fully copied, bounded value, not borrowed JSON.
    var arena_bytes: [128 * 1024]u8 = undefined;
    var arena = std.heap.FixedBufferAllocator.init(&arena_bytes);
    const parsed = std.json.parseFromSlice(Value, arena.allocator(), input, .{
        .duplicate_field_behavior = .@"error",
    }) catch return error.InvalidManifest;
    defer parsed.deinit();
    const obj = try object(parsed.value, 12);
    const schema = try field(obj, "schema_version");
    if (schema != .integer or schema.integer != 1) return error.InvalidManifest;
    const result: Manifest = .{
        .id = try Id.parse(try string(try field(obj, "id"))),
        .version = try Version.parse(try string(try field(obj, "version"))),
        .kind = try enumValue(Kind, try field(obj, "kind"), error.InvalidManifest),
        .enabled_by_default = try boolean(try field(obj, "enabled_by_default")),
        .requires = try idList(try field(obj, "requires")),
        .conflicts = try idList(try field(obj, "conflicts")),
        .capabilities = try enumList(Capability, try field(obj, "capabilities"), error.UnknownCapability),
        .resources = try resources(try field(obj, "resources")),
        .lifecycle = try lifecycle(try field(obj, "lifecycle")),
        .provisioner = try enumValue(Provisioner, try field(obj, "provisioner"), error.UnknownProvisioner),
        .health_checks = try enumList(Health, try field(obj, "health_checks"), error.UnknownHealthCheck),
    };
    if (result.kind != result.provisioner.kind() or
        !std.mem.eql(u8, result.id.slice(), result.provisioner.moduleId())) return error.UnknownProvisioner;
    if (result.kind == .guest) {
        if (result.resources.configured_memory_bytes == 0 or result.resources.vcpus == 0)
            return error.InvalidResources;
    } else {
        if (result.resources.configured_memory_bytes) |n| if (n != 0) return error.InvalidResources;
        if (result.resources.vcpus) |n| if (n != 0) return error.InvalidResources;
    }
    if (!result.lifecycle.retain_by_default or (result.lifecycle.can_archive and !result.lifecycle.can_stop))
        return error.InvalidLifecycle;
    if (result.kind == .fixture and (result.lifecycle.can_stop or result.lifecycle.can_archive or result.lifecycle.rollback_class == .reversible))
        return error.InvalidLifecycle;
    if (result.health_checks.len == 0) return error.InvalidManifest;
    return result;
}

test "canonical IDs reject paths and versions reject overflow" {
    try std.testing.expectError(error.InvalidId, Id.parse("../ad-core"));
    try std.testing.expectError(error.InvalidId, Id.parse("ad--core"));
    try std.testing.expectError(error.InvalidId, Id.parse("AD-core"));
    try std.testing.expectError(error.InvalidId, Id.parse("https://external"));
    try std.testing.expectError(error.InvalidVersion, Version.parse("01.0.0"));
    try std.testing.expectError(error.InvalidVersion, Version.parse("65536.0.0"));
    try std.testing.expectError(error.InvalidVersion, Version.parse("1.0"));
    try std.testing.expectEqualStrings("ad-core", (try Id.parse("ad-core")).slice());
}

test "preflight bounds input and depth before decoding" {
    try std.testing.expectError(error.InputLimit, parse(" " ** (max_manifest_bytes + 1)));
    try std.testing.expectError(error.InputLimit, parse("[[[[[[[0]]]]]]]"));
    try std.testing.expectError(error.InvalidManifest, parse("{\"x\":\"\\u0041\"}"));
    try std.testing.expectError(error.InvalidManifest, parse("{]"));
    try std.testing.expectError(error.InvalidManifest, parse("{\"unfinished"));
}
