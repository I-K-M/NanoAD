// CI-only process harness. No production CLI or real VM is invoked.
const std = @import("std");
const builtin = @import("builtin");
const HostLock = @import("security/host_lock.zig").HostLock;
const Lock = @import("state/lock.zig").Lock;
const Store = @import("state/journal.zig").Store;
const model = @import("state/model.zig");

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
    if (args.len == 3 and std.mem.eql(u8, args[1], "try-host-lock")) {
        var lock = HostLock.acquire() catch |err| {
            if (err == error.HostLockBusy) std.process.exit(17);
            return err;
        };
        try lock.release();
        return;
    }
    if (args.len == 3) {
        var dir = try std.fs.cwd().openDir(args[2], .{});
        defer dir.close();
        if (std.mem.eql(u8, args[1], "exit-after-intent")) {
            var store = try Store.open(dir);
            const state = try store.state();
            const guest = state.initial.guests[0].?.owner.guest;
            try store.append(state.revision, .{ .kind = .intent, .operation = .{ .serial = state.revision + 1, .guest = guest, .kind = .start } });
            // Intentionally bypass close/defer, as an interrupted CLI would.
            std.process.exit(19);
        }
        if (std.mem.eql(u8, args[1], "exit-after-dispatch")) {
            var store = try Store.open(dir);
            const state = try store.state();
            try store.append(state.revision, .{ .kind = .dispatch, .serial = state.operation.?.serial });
            std.process.exit(19);
        }
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
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const executable = try std.fs.selfExePath(&path_buffer);
    if (builtin.os.tag == .windows and builtin.cpu.arch == .x86_64) {
        var global = try HostLock.acquire();
        try std.testing.expectError(error.HostLockBusy, HostLock.acquire());
        try runChild(executable, "try-host-lock", "different-lab-root", 17);
        try global.release();
        try runChild(executable, "try-host-lock", "different-lab-root", 0);
    }
    var lock = try Lock.create(dir);
    var held = true;
    defer if (held) lock.close();
    try runChild(executable, "try-lock", &name, 17);
    lock.close();
    held = false;
    try runChild(executable, "try-lock", &name, 0);
    try runChild(executable, "exit-with-lock", &name, 19);
    try runChild(executable, "try-lock", &name, 0);
    try dir.makeDir("journal");
    var journal_dir = try dir.openDir("journal", .{});
    defer journal_dir.close();
    var store = try Store.create(journal_dir, model.exampleInitial());
    store.close();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const journal_root = try std.fmt.bufPrint(&root_buffer, "{s}{c}journal", .{ &name, std.fs.path.sep });
    try runChild(executable, "exit-after-intent", journal_root, 19);
    store = try Store.open(journal_dir);
    const pending = try store.state();
    try std.testing.expectEqual(model.Stage.intent, pending.operation.?.stage);
    try std.testing.expectEqual(@as(usize, 1), (try pending.ledger()).len);
    store.close();
    try runChild(executable, "exit-after-dispatch", journal_root, 19);
    store = try Store.open(journal_dir);
    defer store.close();
    const interrupted = try store.state();
    try std.testing.expectEqual(model.Stage.dispatch, interrupted.operation.?.stage);
    try std.testing.expectEqual(@as(usize, 1), (try interrupted.ledger()).len);
    try std.testing.expectError(error.RecoveryRequired, store.append(interrupted.revision, .{ .kind = .cancel, .serial = interrupted.operation.?.serial }));
    try std.io.getStdOut().writeAll("Cross-process lock exclusion, process-exit release and durable intent/dispatch replay passed.\n");
}
