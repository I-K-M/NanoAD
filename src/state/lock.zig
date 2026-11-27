const std = @import("std");

// A stable file in a trusted, exclusively administered local directory.
// Never unlink/replace this file or break a lock by PID/age. Closing the
// descriptor (including on process exit) releases the OS lock.
pub const Lock = struct {
    file: std.fs.File,

    pub fn create(dir: std.fs.Dir) !Lock {
        const file = try dir.createFile("state.lock", .{ .read = true, .exclusive = true, .truncate = false, .mode = 0o600 });
        errdefer file.close();
        if (!try file.tryLock(.exclusive)) return error.LockBusy;
        return .{ .file = file };
    }

    pub fn acquire(dir: std.fs.Dir) !Lock {
        const file = try dir.openFile("state.lock", .{ .mode = .read_write });
        errdefer file.close();
        if ((try file.stat()).kind != .file) return error.InvalidState;
        if (!try file.tryLock(.exclusive)) return error.LockBusy;
        return .{ .file = file };
    }

    pub fn close(self: *Lock) void {
        self.file.close();
        self.* = undefined;
    }
};
