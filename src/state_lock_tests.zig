// CI-only process harness. No production CLI or real VM is invoked.
const std = @import("std");
const Lock = @import("state/lock.zig").Lock;

fn runChild(executable: []const u8, mode: []const u8, root: []const u8, expected: u8) !void {
    var child = std.process.Child.init(&.{ executable, mode, root }, std.heap.page_allocator);
    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| try std.testing.expectEqual(expected, code),
        else => return error.UnexpectedChildTermination,
    }
}

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);
    if (args.len == 3) {
        var dir = try std.fs.cwd().openDir(args[2], .{});
        defer dir.close();
        var lock = Lock.acquire(dir) catch |err| {
            if (err == error.LockBusy) std.process.exit(17);
            return err;
        };
        if (std.mem.eql(u8, args[1], "exit-with-lock")) std.process.exit(19);
        if (!std.mem.eql(u8, args[1], "try-lock")) return error.InvalidArguments;
        lock.close();
        return;
    }
    if (args.len != 1) return error.InvalidArguments;
    var random: [16]u8 = undefined;
    std.crypto.random.bytes(&random);
    const name = "nanoad-lock-test-".* ++ std.fmt.bytesToHex(random, .lower);
    try std.fs.cwd().makeDir(&name);
    defer std.fs.cwd().deleteTree(&name) catch {};
    var dir = try std.fs.cwd().openDir(&name, .{});
    defer dir.close();
    var lock = try Lock.create(dir);
    var held = true;
    defer if (held) lock.close();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const executable = try std.fs.selfExePath(&path_buffer);
    try runChild(executable, "try-lock", &name, 17);
    lock.close();
    held = false;
    try runChild(executable, "try-lock", &name, 0);
    try runChild(executable, "exit-with-lock", &name, 19);
    try runChild(executable, "try-lock", &name, 0);
    try std.io.getStdOut().writeAll("Cross-process lock exclusion and process-exit release passed.\n");
}
