const std = @import("std");

pub const Memory = struct {
    total: ?u64 = null,
    available: ?u64 = null,
};

fn valueBytes(value: []const u8) ?u64 {
    var tokens = std.mem.tokenizeAny(u8, value, " \t\r");
    const digits = tokens.next() orelse return null;
    const unit = tokens.next() orelse return null;
    if (!std.mem.eql(u8, unit, "kB") or tokens.next() != null) return null;
    for (digits) |digit| {
        if (digit < '0' or digit > '9') return null;
    }
    const kib = std.fmt.parseInt(u64, digits, 10) catch return null;
    return std.math.mul(u64, kib, 1024) catch null;
}

pub fn parse(text: []const u8) Memory {
    var memory: Memory = .{};
    var total_seen = false;
    var available_seen = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const separator = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = line[0..separator];
        const value = line[separator + 1 ..];
        if (std.mem.eql(u8, key, "MemTotal")) {
            memory.total = if (total_seen) null else valueBytes(value);
            total_seen = true;
        } else if (std.mem.eql(u8, key, "MemAvailable")) {
            memory.available = if (available_seen) null else valueBytes(value);
            available_seen = true;
        }
    }
    if (memory.total) |total| {
        if (memory.available) |available| {
            if (available > total) memory.available = null;
        }
    }
    return memory;
}

test "kernel kB values are converted to bytes" {
    const m = parse("MemTotal: 8192 kB\nMemFree: 100 kB\nMemAvailable: 4096 kB\n");
    try std.testing.expectEqual(@as(?u64, 8192 * 1024), m.total);
    try std.testing.expectEqual(@as(?u64, 4096 * 1024), m.available);
}

test "unknown is not zero; no MemFree fallback" {
    const m = parse("MemTotal: 8 kB\nMemFree: 4 kB\n");
    try std.testing.expect(m.available == null);
    try std.testing.expect(parse("MemTotal: 3 MB\n").total == null);
    try std.testing.expect(parse("MemTotal: 18446744073709551615 kB\n").total == null);
}

test "duplicate or contradictory fields are unknown" {
    try std.testing.expect(parse("MemTotal: 8 kB\nMemTotal: 8 kB\n").total == null);
    try std.testing.expect(parse("MemTotal: 8 kB\nMemAvailable: 9 kB\n").available == null);
    try std.testing.expect(parse("MemAvailable: -1 kB\n").available == null);
}
