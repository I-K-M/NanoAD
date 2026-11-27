// Standalone Windows integration harness; launches only the CI fixture artifact.
const std = @import("std");
const types = @import("provider/types.zig");
const commands = @import("provider/virtualbox/commands.zig");
const NativeTransport = @import("provider/virtualbox/native_transport.zig").NativeTransport;

fn digest(path: []const u8) ![32]u8 {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [8192]u8 = undefined;
    while (true) {
        const n = try file.read(&buffer);
        if (n == 0) break;
        hash.update(buffer[0..n]);
    }
    var result: [32]u8 = undefined;
    hash.final(&result);
    return result;
}

fn checked(transport: commands.Transport, request: *const commands.Request, output: []u8) ![]const u8 {
    return transport.invoke(request, output) catch |err| {
        std.debug.print("Native fixture stage {s}: {s}\n", .{ @tagName(request.operation), @errorName(err) });
        return err;
    };
}

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);
    if (args.len != 2) return error.InvalidArguments;
    const hash = try digest(args[1]);
    // The build artifact can be on a runner workspace drive which is not
    // reported as fixed. Keep the production fixed-drive guard intact.
    // Stage ONLY the CI-built fixture in a fresh local user directory.
    const local = try std.process.getEnvVarOwned(std.heap.page_allocator, "LOCALAPPDATA");
    defer std.heap.page_allocator.free(local);
    var parent = try std.fs.openDirAbsolute(local, .{});
    defer parent.close();
    var random: [16]u8 = undefined;
    std.crypto.random.bytes(&random);
    const name = "NanoAD-native-test-".* ++ std.fmt.bytesToHex(random, .lower);
    try parent.makeDir(&name);
    defer parent.deleteTree(&name) catch {};
    const fixture_path = try std.fs.path.join(std.heap.page_allocator, &.{ local, &name, "VBoxManage.exe" });
    defer std.heap.page_allocator.free(fixture_path);
    try std.fs.copyFileAbsolute(args[1], fixture_path, .{});
    var native = try NativeTransport.init(fixture_path, hash);
    const transport = native.transport();
    const request: commands.Request = .{ .operation = .version };
    var output: [256]u8 = undefined;
    try std.testing.expectEqualStrings("7.1.10r169112\r\n", try checked(transport, &request, &output));

    const registered: commands.Request = .{ .operation = .list_vms };
    const running: commands.Request = .{ .operation = .list_running };
    try std.testing.expectEqualStrings("\"fixture\" {01234567-89ab-cdef-0123-456789abc003}\r\n", try checked(transport, &registered, &output));
    try std.testing.expectEqualStrings("", try checked(transport, &running, &output));

    var wrong_hash = hash;
    wrong_hash[0] ^= 1;
    var wrong = try NativeTransport.init(fixture_path, wrong_hash);
    try std.testing.expectError(error.ProviderFailure, wrong.transport().invoke(&request, &output));

    const ordinary = try types.Uuid.parse("01234567-89ab-cdef-0123-456789abc003");
    const overflow = try types.Uuid.parse("01234567-89ab-cdef-0123-456789abc001");
    const slow = try types.Uuid.parse("01234567-89ab-cdef-0123-456789abc002");
    const observe: commands.Request = .{ .operation = .observe, .vm = ordinary };
    try std.testing.expectEqualStrings("fixture output\n", try checked(transport, &observe, &output));
    const too_much: commands.Request = .{ .operation = .observe, .vm = overflow };
    try std.testing.expectError(error.OutputLimit, transport.invoke(&too_much, &output));
    const slow_request: commands.Request = .{ .operation = .observe, .vm = slow };
    try std.testing.expectError(error.Timeout, transport.invoke_fn(transport.context, &slow_request, &output, 200));
    const lab_marker: commands.Request = .{ .operation = .lab_marker, .vm = ordinary };
    try std.testing.expectError(error.InvalidResponse, transport.invoke(&lab_marker, &output));
    const guest_marker: commands.Request = .{ .operation = .guest_marker, .vm = ordinary };
    try std.testing.expectError(error.ProviderFailure, transport.invoke(&guest_marker, &output));
    const mutation: commands.Request = .{ .operation = .start, .vm = ordinary };
    try std.testing.expectError(error.Unsupported, transport.invoke(&mutation, &output));
    try std.testing.expectEqualStrings("7.1.10r169112\r\n", try checked(transport, &request, &output));
    try std.io.getStdOut().writeAll("Native Windows transport fixture checks passed; no VM or real provider invoked.\n");
}
