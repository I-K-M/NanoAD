const std = @import("std");
const builtin = @import("builtin");

// Zig 0.14.1's Windows File.tryLock does not compile. Use a synchronous,
// non-blocking Win32 byte-range lock on a stable lock file instead.
const Overlapped = extern struct {
    internal: usize = 0,
    internal_high: usize = 0,
    offset: u32 = 0,
    offset_high: u32 = 0,
    event: ?*anyopaque = null,
};

extern "kernel32" fn LockFileEx(handle: *anyopaque, flags: u32, reserved: u32, bytes_low: u32, bytes_high: u32, overlapped: *Overlapped) callconv(.winapi) i32;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

fn acquireExclusive(file: std.fs.File) !void {
    if (builtin.os.tag == .windows) {
        var offset: Overlapped = .{};
        // LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY.
        // One byte at offset zero; every NanoAD writer uses this range.
        if (LockFileEx(file.handle, 3, 0, 1, 0, &offset) == 0) {
            if (GetLastError() == 33) return error.LockBusy;
            return error.LockFailed;
        }
    } else {
        if (!try file.tryLock(.exclusive)) return error.LockBusy;
    }
}

// A stable file in a trusted, exclusively administered local directory.
// Never unlink/replace this file or break a lock by PID/age. Closing the
// descriptor (including on process exit) releases the OS lock.
pub const Lock = struct {
    file: std.fs.File,

    pub fn create(dir: std.fs.Dir) !Lock {
        const file = try dir.createFile("state.lock", .{ .read = true, .exclusive = true, .truncate = false, .mode = 0o600 });
        errdefer file.close();
        try acquireExclusive(file);
        return .{ .file = file };
    }

    pub fn acquire(dir: std.fs.Dir) !Lock {
        const file = try dir.openFile("state.lock", .{ .mode = .read_write });
        errdefer file.close();
        if ((try file.stat()).kind != .file) return error.InvalidState;
        try acquireExclusive(file);
        return .{ .file = file };
    }

    pub fn close(self: *Lock) void {
        self.file.close();
        self.* = undefined;
    }
};
