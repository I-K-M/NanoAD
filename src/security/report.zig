const std = @import("std");

pub const Reason = enum { incomplete_inventory, foreign_resource, unsafe_path, unsafe_attachment, stale_evidence, lock_unavailable, recovery_required, provider_failure };

/// Closed diagnostic vocabulary. Never accept raw provider stderr, names,
/// paths, command lines, environment variables, credentials or error text.
pub fn writeRefusal(writer: anytype, reason: Reason) !void {
    try std.json.stringify(.{
        .schema_version = @as(u32, 1),
        .result = "refused",
        .reason = reason,
        .mutation_permitted = false,
    }, .{}, writer);
    try writer.writeByte('\n');
}

test "refusal exports only a closed reason code" {
    var buffer: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try writeRefusal(stream.writer(), .provider_failure);
    try std.testing.expectEqualStrings("{\"schema_version\":1,\"result\":\"refused\",\"reason\":\"provider_failure\",\"mutation_permitted\":false}\n", stream.getWritten());
}
