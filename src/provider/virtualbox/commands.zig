const std = @import("std");
const types = @import("../types.zig");

pub const Operation = enum { version, observe, lab_marker, guest_marker, start, graceful_stop };
pub const max_output_bytes: usize = 64 * 1024;
pub const command_timeout_ms: u32 = 10_000;

pub const Args = struct {
    items: [4][]const u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Args) []const []const u8 {
        return self.items[0..self.len];
    }

    fn push(self: *Args, value: []const u8) void {
        self.items[self.len] = value;
        self.len += 1;
    }
};

pub const Request = struct {
    operation: Operation,
    vm: ?types.Uuid = null,

    // Arguments only. The transport must invoke a separately trusted absolute executable.
    // The returned slices borrow this request, so consume before it leaves scope.
    pub fn arguments(self: *const Request) types.Failure!Args {
        var args: Args = .{};
        if (self.operation == .version) {
            if (self.vm != null) return error.InvalidResponse;
            args.push("--version");
            return args;
        }
        const id = if (self.vm) |*id| id else return error.InvalidResponse;
        if (!id.valid()) return error.InvalidResponse;
        const uuid = &id.text;
        switch (self.operation) {
            .version => unreachable,
            .observe => {
                args.push("showvminfo");
                args.push(uuid);
                args.push("--machinereadable");
            },
            .lab_marker, .guest_marker => {
                args.push("getextradata");
                args.push(uuid);
                args.push(if (self.operation == .lab_marker) "NanoAD/LabId" else "NanoAD/GuestId");
            },
            .start => {
                args.push("startvm");
                args.push(uuid);
                args.push("--type");
                args.push("headless");
            },
            .graceful_stop => {
                args.push("controlvm");
                args.push(uuid);
                args.push("acpipowerbutton");
            },
        }
        return args;
    }
};

// No process execution implementation is supplied here. The future native transport must
// enforce the deadline, bounded stdout/stderr, trusted executable and exit status.
pub const Transport = struct {
    context: *anyopaque,
    invoke_fn: *const fn (*anyopaque, *const Request, []u8, u32) types.Failure!usize,

    pub fn invoke(self: Transport, request: *const Request, buffer: []u8) types.Failure![]const u8 {
        if (buffer.len == 0 or buffer.len > max_output_bytes) return error.OutputLimit;
        _ = try request.arguments();
        const n = try self.invoke_fn(self.context, request, buffer, command_timeout_ms);
        if (n > buffer.len) return error.OutputLimit;
        return buffer[0..n];
    }
};

test "only typed UUID-scoped commands; graceful ACPI stop" {
    const uuid = try types.Uuid.parse("01234567-89ab-cdef-0123-456789abcdef");
    const request: Request = .{ .operation = .graceful_stop, .vm = uuid };
    const args = try request.arguments();
    try std.testing.expectEqual(@as(usize, 3), args.len);
    try std.testing.expectEqualStrings("controlvm", args.items[0]);
    try std.testing.expectEqualStrings(&uuid.text, args.items[1]);
    try std.testing.expectEqualStrings("acpipowerbutton", args.items[2]);
    try std.testing.expectError(error.InvalidResponse, (Request{ .operation = .start }).arguments());
    var invalid = uuid;
    invalid.text[0] = '-';
    const malformed: Request = .{ .operation = .start, .vm = invalid };
    try std.testing.expectError(error.InvalidResponse, malformed.arguments());
}
