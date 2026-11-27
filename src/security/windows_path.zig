const std = @import("std");
const builtin = @import("builtin");

pub const Failure = error{ UnsafePath, PathLimit, Unsupported, QueryFailed, AliasedPath, WrongType, MultipleLinks };
const max_path = 260;
const max_segments = 24;
const Handle = *anyopaque;

fn reserved(segment: []const u8) bool {
    const end = std.mem.indexOfScalar(u8, segment, '.') orelse segment.len;
    var trimmed = end;
    while (trimmed > 0 and segment[trimmed - 1] == ' ') trimmed -= 1;
    const stem = segment[0..trimmed];
    for ([_][]const u8{ "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$" }) |device| {
        if (std.ascii.eqlIgnoreCase(stem, device)) return true;
    }
    if (stem.len == 4 and std.ascii.isDigit(stem[3]) and
        (std.ascii.eqlIgnoreCase(stem[0..3], "COM") or std.ascii.eqlIgnoreCase(stem[0..3], "LPT"))) return true;
    return false;
}

/// Conventional fixed-drive ASCII paths only. No UNC, NT device namespace,
/// ADS, relative drive paths, dot segments, ambiguous trailing characters.
pub fn validate(path: []const u8) Failure!void {
    if (path.len < 4 or path.len >= max_path) return error.PathLimit;
    if (!std.ascii.isAlphabetic(path[0]) or path[1] != ':' or path[2] != '\\') return error.UnsafePath;
    var parts = std.mem.splitScalar(u8, path[3..], '\\');
    var count: usize = 0;
    while (parts.next()) |part| {
        count += 1;
        if (count > max_segments) return error.PathLimit;
        if (part.len == 0 or part[part.len - 1] == '.' or part[part.len - 1] == ' ' or reserved(part))
            return error.UnsafePath;
        for (part) |c| {
            if (c < 32 or c > 126 or std.mem.indexOfScalar(u8, ":*?<>|\"/", c) != null)
                return error.UnsafePath;
        }
    }
}

pub const Identity = struct {
    volume: u32,
    file_index: u64,

    pub fn eql(a: Identity, b: Identity) bool {
        return a.volume == b.volume and a.file_index == b.file_index;
    }
};

const FileTime = extern struct { low: u32, high: u32 };
const Info = extern struct {
    attributes: u32,
    creation: FileTime,
    access: FileTime,
    write: FileTime,
    volume: u32,
    size_high: u32,
    size_low: u32,
    links: u32,
    index_high: u32,
    index_low: u32,
};

extern "kernel32" fn CreateFileW(path: [*:0]const u16, access: u32, share: u32, security: ?*anyopaque, disposition: u32, flags: u32, template: ?Handle) callconv(.winapi) ?Handle;
extern "kernel32" fn GetFileInformationByHandle(handle: Handle, info: *Info) callconv(.winapi) i32;
extern "kernel32" fn GetFinalPathNameByHandleW(handle: Handle, path: [*]u16, capacity: u32, flags: u32) callconv(.winapi) u32;
extern "kernel32" fn GetFileType(handle: Handle) callconv(.winapi) u32;
extern "kernel32" fn GetDriveTypeW(root: [*:0]const u16) callconv(.winapi) u32;
extern "kernel32" fn CloseHandle(handle: Handle) callconv(.winapi) i32;
extern "kernel32" fn CreateHardLinkW(new_path: [*:0]const u16, old_path: [*:0]const u16, reserved_attributes: ?*anyopaque) callconv(.winapi) i32;

fn wide(path: []const u8) [max_path:0]u16 {
    var result: [max_path:0]u16 = @splat(0);
    for (path, 0..) |c, i| result[i] = c;
    return result;
}

fn samePath(handle: Handle, path: []const u8) bool {
    var actual: [max_path + 4]u16 = undefined;
    const n = GetFinalPathNameByHandleW(handle, &actual, actual.len, 0);
    if (n != path.len + 4 or n >= actual.len) return false;
    if (!std.mem.eql(u16, actual[0..4], &[_]u16{ '\\', '\\', '?', '\\' })) return false;
    for (path, actual[4..n]) |expected, observed| {
        if (observed > 127 or std.ascii.toLower(expected) != std.ascii.toLower(@intCast(observed))) return false;
    }
    return true;
}

/// Read-only handle-based observation, with every ancestor opened without
/// following reparse points. No write/delete sharing on ancestor handles
/// would prevent normal I/O; we deny delete sharing while inspecting.
/// Does not keep a file immutable after return or prove its ACL/provenance.
pub fn inspectFile(path: []const u8) Failure!Identity {
    try validate(path);
    if (builtin.os.tag != .windows or builtin.cpu.arch != .x86_64) return error.Unsupported;
    const drive = wide(path[0..3]);
    if (GetDriveTypeW(&drive) != 3) return error.UnsafePath;
    var held: [max_segments + 1]Handle = undefined;
    var count: usize = 0;
    defer for (held[0..count]) |handle| {
        _ = CloseHandle(handle);
    };
    var volume: ?u32 = null;
    var end: usize = 3;
    while (true) {
        const prefix = if (end == 3) path[0..3] else path[0..end];
        const native = wide(prefix);
        // FILE_READ_ATTRIBUTES; share read/write, not delete;
        // OPEN_EXISTING, BACKUP_SEMANTICS | OPEN_REPARSE_POINT.
        const handle = CreateFileW(&native, 0x80, 3, null, 3, 0x02200000, null) orelse return error.QueryFailed;
        if (@intFromPtr(handle) == std.math.maxInt(usize)) return error.QueryFailed;
        held[count] = handle;
        count += 1;
        if (GetFileType(handle) != 1) return error.WrongType;
        var info: Info = undefined;
        if (GetFileInformationByHandle(handle, &info) == 0) return error.QueryFailed;
        if (info.attributes & 0x400 != 0 or !samePath(handle, prefix)) return error.AliasedPath;
        if (volume) |v| {
            if (v != info.volume) return error.AliasedPath;
        } else volume = info.volume;
        const last = end == path.len;
        const directory = info.attributes & 0x10 != 0;
        if (last == directory) return error.WrongType;
        if (last) {
            if (info.links != 1) return error.MultipleLinks;
            const index = (@as(u64, info.index_high) << 32) | info.index_low;
            if (index == 0) return error.QueryFailed;
            return .{ .volume = info.volume, .file_index = index };
        }
        const start = if (end == 3) end else end + 1;
        end = if (std.mem.indexOfScalarPos(u8, path, start, '\\')) |i| i else path.len;
    }
}

test "lexical Windows escape corpus" {
    try validate("C:\\NanoAD\\overlays\\file.vdi");
    for ([_][]const u8{
        "C:\\NanoAD\\..\\outside.vdi",
        "C:\\NanoAD\\.\\file.vdi",
        "C:\\NanoAD\\file.vdi:secret",
        "C:\\NanoAD\\file.vdi.",
        "C:\\NanoAD\\file.vdi ",
        "C:\\NanoAD\\NUL.vdi",
        "C:\\NanoAD\\COM1 .vdi",
        "C:\\NanoAD\\LPT9",
        "C:\\NanoAD\\\\file.vdi",
        "C:/NanoAD/file.vdi",
        "\\\\server\\share\\file.vdi",
        "\\\\?\\C:\\NanoAD\\file.vdi",
        "C:relative.vdi",
        "C:\\NanoAD\\x\x00.vdi",
    }) |path| {
        if (validate(path)) |_| return error.UnsafePathAccepted else |_| {}
    }
}

test "Windows handle observation rejects a hardlink alias and directories" {
    if (builtin.os.tag != .windows or builtin.cpu.arch != .x86_64) {
        try std.testing.expectError(error.Unsupported, inspectFile("C:\\NanoAD\\file.vdi"));
        return;
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile("owned.vdi", .{});
    file.close();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &root_buffer);
    var first_buffer: [max_path]u8 = undefined;
    const first = try std.fmt.bufPrint(&first_buffer, "{s}\\owned.vdi", .{root});
    var second_buffer: [max_path]u8 = undefined;
    const second = try std.fmt.bufPrint(&second_buffer, "{s}\\alias.vdi", .{root});
    const identity = try inspectFile(first);
    try std.testing.expect(identity.file_index != 0);
    try std.testing.expectError(error.WrongType, inspectFile(root));
    const old_path = wide(first);
    const new_path = wide(second);
    try std.testing.expect(CreateHardLinkW(&new_path, &old_path, null) != 0);
    try std.testing.expectError(error.MultipleLinks, inspectFile(first));
    try std.testing.expectError(error.MultipleLinks, inspectFile(second));
    try tmp.dir.deleteFile("alias.vdi");
    try std.testing.expect(identity.eql(try inspectFile(first)));
}
