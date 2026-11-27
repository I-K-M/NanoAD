const std = @import("std");
const builtin = @import("builtin");
const accounting = @import("accounting.zig");

const StandardInfo = extern struct {
    allocation_size: i64,
    end_of_file: i64,
    links: u32,
    delete_pending: u8,
    directory: u8,
};

const AttributeInfo = extern struct {
    attributes: u32,
    reparse_tag: u32,
};

const CompressionInfo = extern struct {
    compressed_file_size: i64,
    format: u16,
    unit_shift: u8,
    chunk_shift: u8,
    cluster_shift: u8,
    reserved: [3]u8,
};

extern "kernel32" fn GetFileInformationByHandleEx(handle: *anyopaque, class: i32, info: *anyopaque, size: u32) callconv(.winapi) i32;

pub const Observation = struct {
    logical_bytes: u64,
    allocation_hint_bytes: u64,
    link_count: u32,
    sparse_or_compressed: bool,

    // No metadata, named-stream or external shared-block reconciliation.
    // This estimate deliberately cannot pass strict admission.
    pub fn charge(self: Observation) accounting.Charge {
        return .{ .estimate = self.allocation_hint_bytes };
    }
};

// Read-only observation of a caller-opened, trusted, quiescent regular file.
// This API alone does not prove NTFS, containment, absence of junctions in
// parent directories, exclusive ownership, or exact volume allocation.
pub fn observe(file: std.fs.File) error{ Unsupported, QueryFailed, InvalidFile }!Observation {
    if (builtin.os.tag != .windows) return error.Unsupported;
    var info: StandardInfo = undefined;
    var attributes: AttributeInfo = undefined;
    if (GetFileInformationByHandleEx(file.handle, 1, &info, @sizeOf(StandardInfo)) == 0 or
        GetFileInformationByHandleEx(file.handle, 9, &attributes, @sizeOf(AttributeInfo)) == 0)
        return error.QueryFailed;
    if (info.directory != 0 or info.delete_pending != 0 or info.links == 0 or
        info.allocation_size < 0 or info.end_of_file < 0 or (attributes.attributes & 0x400) != 0)
        return error.InvalidFile;
    const special = (attributes.attributes & (0x200 | 0x800)) != 0;
    var allocated = info.allocation_size;
    if (special) {
        var compressed: CompressionInfo = undefined;
        if (GetFileInformationByHandleEx(file.handle, 8, &compressed, @sizeOf(CompressionInfo)) == 0 or
            compressed.compressed_file_size < 0) return error.QueryFailed;
        allocated = compressed.compressed_file_size;
    }
    return .{
        .logical_bytes = @intCast(info.end_of_file),
        .allocation_hint_bytes = @intCast(allocated),
        .link_count = info.links,
        .sparse_or_compressed = special,
    };
}

test "ordinary file measurement is never promoted to a strict bound" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const file = try temp.dir.createFile("allocation.bin", .{ .read = true });
    defer file.close();
    const bytes: [4097]u8 = @splat(1);
    try file.writeAll(&bytes);
    try file.sync();
    if (builtin.os.tag != .windows) {
        try std.testing.expectError(error.Unsupported, observe(file));
        return;
    }
    const observation = try observe(file);
    try std.testing.expectEqual(@as(u64, bytes.len), observation.logical_bytes);
    try std.testing.expect(observation.link_count >= 1);
    if (!observation.sparse_or_compressed) {
        try std.testing.expect(observation.allocation_hint_bytes >= bytes.len);
    }
    var totals: accounting.Totals = .{};
    try totals.include(observation.charge());
    try std.testing.expectError(error.UnknownAllocation, totals.strict());
}
