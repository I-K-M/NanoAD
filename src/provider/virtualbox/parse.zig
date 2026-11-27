const std = @import("std");
const types = @import("../types.zig");
const commands = @import("commands.zig");

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn setOnce(slot: *?[]const u8, value: []const u8) types.Failure!void {
    if (slot.* != null) return error.InvalidResponse;
    slot.* = value;
}

fn strictDecimal(value: []const u8) types.Failure!u64 {
    if (value.len == 0) return error.InvalidResponse;
    for (value) |c| if (!std.ascii.isDigit(c)) return error.InvalidResponse;
    return std.fmt.parseInt(u64, value, 10) catch error.InvalidResponse;
}

fn quoted(value: []const u8) types.Failure![]const u8 {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return error.InvalidResponse;
    const inner = value[1 .. value.len - 1];
    for (inner) |c| if (c < 32 or c == '"' or c == '\\') return error.InvalidResponse;
    return inner;
}

pub fn version(output: []const u8) types.Failure!void {
    const value = std.mem.trim(u8, output, " \t\r\n");
    if (value.len > 64) return error.InvalidResponse;
    if (!std.mem.startsWith(u8, value, "7.1.")) return error.Unsupported;
    const rest = value[4..];
    const r = std.mem.indexOfScalar(u8, rest, 'r') orelse return error.InvalidResponse;
    _ = try strictDecimal(rest[0..r]);
    _ = try strictDecimal(rest[r + 1 ..]);
    // Recognition only; a real provider/version still requires qualification.
}

pub fn marker(output: []const u8, expected: types.Uuid) types.Failure!void {
    const value = std.mem.trim(u8, output, " \t\r\n");
    if (!std.mem.startsWith(u8, value, "Value: ")) return error.OwnershipMismatch;
    const id = types.Uuid.parse(value[7..]) catch return error.OwnershipMismatch;
    if (!id.eql(expected)) return error.OwnershipMismatch;
}

pub fn info(output: []const u8, owned: types.OwnedGuest) types.Failure!types.Observation {
    if (output.len == 0 or output.len > commands.max_output_bytes) return error.OutputLimit;
    var uuid: ?[]const u8 = null;
    var state: ?[]const u8 = null;
    var memory: ?[]const u8 = null;
    var network: ?[]const u8 = null;
    var nics: [8]?[]const u8 = @splat(null);
    var rejected = false;
    var clipboard: ?[]const u8 = null;
    var drag: ?[]const u8 = null;
    var vrde: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, output, '\n');
    var line_count: usize = 0;
    while (lines.next()) |raw| {
        line_count += 1;
        if (line_count > 4096 or raw.len > 8192) return error.InvalidResponse;
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        for (line) |c| if (c < 32) return error.InvalidResponse;
        const separator = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidResponse;
        const key = line[0..separator];
        const value = line[separator + 1 ..];
        if (eq(key, "UUID")) {
            try setOnce(&uuid, try quoted(value));
        } else if (eq(key, "VMState")) {
            try setOnce(&state, try quoted(value));
        } else if (eq(key, "memory")) {
            try setOnce(&memory, value);
        } else if (eq(key, "intnet1")) {
            try setOnce(&network, try quoted(value));
        } else if (eq(key, "clipboard")) {
            try setOnce(&clipboard, try quoted(value));
        } else if (eq(key, "draganddrop")) {
            try setOnce(&drag, try quoted(value));
        } else if (eq(key, "vrde")) {
            try setOnce(&vrde, try quoted(value));
        } else if (std.mem.startsWith(u8, key, "nic") and key.len > 3 and std.ascii.isDigit(key[3])) {
            const index = try strictDecimal(key[3..]);
            if (index == 0 or index > nics.len) return error.Unsupported;
            try setOnce(&nics[@intCast(index - 1)], try quoted(value));
        } else if (std.mem.startsWith(u8, key, "SharedFolderName") or std.mem.startsWith(u8, key, "Forwarding(")) {
            rejected = true;
        }
        // Unknown fields are not proof of safe configuration.
    }

    const actual = types.Uuid.parse(uuid orelse return error.InvalidResponse) catch return error.InvalidResponse;
    if (!actual.eql(owned.vm)) return error.OwnershipMismatch;
    const power_text = state orelse return error.InvalidResponse;
    const power: types.PowerState = if (eq(power_text, "poweroff"))
        .powered_off
    else if (eq(power_text, "running"))
        .running
    else if (eq(power_text, "paused"))
        .paused
    else if (eq(power_text, "saved"))
        .saved
    else if (eq(power_text, "aborted"))
        .aborted
    else if (eq(power_text, "starting") or eq(power_text, "stopping"))
        .transitional
    else
        .unknown;
    const mib = try strictDecimal(memory orelse return error.InvalidResponse);
    if (mib == 0) return error.InvalidResponse;
    const bytes = std.math.mul(u64, mib, 1024 * 1024) catch return error.InvalidResponse;
    const expected_network = owned.network();
    var incomplete = false;
    if (network) |v| {
        if (!eq(v, &expected_network)) rejected = true;
    } else incomplete = true;
    for (nics, 0..) |nic, i| {
        if (nic) |v| {
            if (!eq(v, if (i == 0) "intnet" else "none")) rejected = true;
        } else incomplete = true;
    }
    for ([_]?[]const u8{ clipboard, drag, vrde }, [_][]const u8{ "disabled", "disabled", "off" }) |field, safe| {
        if (field) |v| {
            if (!eq(v, safe)) rejected = true;
        } else incomplete = true;
    }
    return .{
        .vm = actual,
        .power = power,
        .memory_bytes = bytes,
        .network = if (rejected) .rejected else if (incomplete) .incomplete else .compatible,
        .isolation_verified = false,
    };
}

const lab = "01234567-89ab-cdef-0123-456789abcdef";
const guest = "11234567-89ab-cdef-0123-456789abcdef";
const vm = "21234567-89ab-cdef-0123-456789abcdef";
pub const fixture =
    \\UUID="21234567-89ab-cdef-0123-456789abcdef"
    \\VMState="poweroff"
    \\memory=2048
    \\nic1="intnet"
    \\intnet1="nanoad-01234567-89ab-cdef-0123-456789abcdef"
    \\nic2="none"
    \\nic3="none"
    \\nic4="none"
    \\nic5="none"
    \\nic6="none"
    \\nic7="none"
    \\nic8="none"
    \\clipboard="disabled"
    \\draganddrop="disabled"
    \\vrde="off"
    \\
;
pub fn exampleOwned() types.OwnedGuest {
    return .{
        .lab = types.Uuid.parse(lab) catch unreachable,
        .guest = types.Uuid.parse(guest) catch unreachable,
        .vm = types.Uuid.parse(vm) catch unreachable,
    };
}

test "provider version is recognised, not qualified" {
    try version("7.1.10r169112\r\n");
    try std.testing.expectError(error.Unsupported, version("7.2.0r123"));
    try std.testing.expectError(error.InvalidResponse, version("7.1.10rbroken"));
}

test "complete fixture remains isolation-unverified" {
    const observation = try info(fixture, exampleOwned());
    try std.testing.expectEqual(types.PowerState.powered_off, observation.power);
    try std.testing.expectEqual(@as(u64, 2147483648), observation.memory_bytes);
    try std.testing.expectEqual(types.NetworkEvidence.compatible, observation.network);
    try std.testing.expect(!observation.isolation_verified);
}

test "fail closed on duplicate keys, missing data and wrong identity" {
    try std.testing.expectError(error.InvalidResponse, info(fixture ++ "memory=4096\n", exampleOwned()));
    try std.testing.expectError(error.InvalidResponse, info("memory=2048\n", exampleOwned()));
    var wrong = exampleOwned();
    wrong.vm = wrong.guest;
    try std.testing.expectError(error.OwnershipMismatch, info(fixture, wrong));
    try std.testing.expectError(error.OwnershipMismatch, marker("No value set!", wrong.lab));
}

test "known unsafe attachments rejected; unknown never attests isolation" {
    const result = try info(fixture ++ "SharedFolderNameMachineMapping1=\"host\"\n", exampleOwned());
    try std.testing.expectEqual(types.NetworkEvidence.rejected, result.network);
    const incomplete = try info("UUID=\"" ++ vm ++ "\"\nVMState=\"running\"\nmemory=1024\n", exampleOwned());
    try std.testing.expectEqual(types.NetworkEvidence.incomplete, incomplete.network);
    try std.testing.expect(!incomplete.isolation_verified);
}
