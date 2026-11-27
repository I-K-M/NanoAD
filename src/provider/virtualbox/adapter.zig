const std = @import("std");
const types = @import("../types.zig");
const commands = @import("commands.zig");
const parse = @import("parse.zig");

pub const Adapter = struct {
    transport: commands.Transport,

    pub fn probe(self: Adapter) types.Failure!void {
        var buffer: [256]u8 = undefined;
        const request: commands.Request = .{ .operation = .version };
        try parse.version(try self.transport.invoke(&request, &buffer));
    }

    pub fn observe(self: Adapter, owned: types.OwnedGuest) types.Failure!types.Observation {
        var marker_buffer: [256]u8 = undefined;
        var request: commands.Request = .{ .operation = .lab_marker, .vm = owned.vm };
        try parse.marker(try self.transport.invoke(&request, &marker_buffer), owned.lab);
        request.operation = .guest_marker;
        try parse.marker(try self.transport.invoke(&request, &marker_buffer), owned.guest);
        var info_buffer: [commands.max_output_bytes]u8 = undefined;
        request.operation = .observe;
        return parse.info(try self.transport.invoke(&request, &info_buffer), owned);
    }

    // Internal primitives only. No CLI exposes them. The lifecycle gate owns approval,
    // current ownership, admission, journal and re-observation requirements.
    pub fn start(self: Adapter, owned: types.OwnedGuest) types.Failure!void {
        var buffer: [4096]u8 = undefined;
        const request: commands.Request = .{ .operation = .start, .vm = owned.vm };
        _ = try self.transport.invoke(&request, &buffer);
    }

    pub fn requestShutdown(self: Adapter, owned: types.OwnedGuest) types.Failure!void {
        var buffer: [4096]u8 = undefined;
        const request: commands.Request = .{ .operation = .graceful_stop, .vm = owned.vm };
        _ = try self.transport.invoke(&request, &buffer);
    }
};

const FakeTransport = struct {
    wrong_marker: bool = false,
    calls: usize = 0,
    mutations: usize = 0,

    fn invoke(ctx: *anyopaque, req: *const commands.Request, out: []u8, timeout: u32) types.Failure!usize {
        const self: *FakeTransport = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (timeout != commands.command_timeout_ms) return error.Timeout;
        const data: []const u8 = switch (req.operation) {
            .version => "7.1.10r169112\n",
            .lab_marker => if (self.wrong_marker) "No value set!" else "Value: 01234567-89ab-cdef-0123-456789abcdef\n",
            .guest_marker => "Value: 11234567-89ab-cdef-0123-456789abcdef\n",
            .observe => parse.fixture,
            .start, .graceful_stop => blk: {
                self.mutations += 1;
                break :blk "";
            },
        };
        if (data.len > out.len) return error.OutputLimit;
        @memcpy(out[0..data.len], data);
        return data.len;
    }

    fn adapter(self: *FakeTransport) Adapter {
        return .{ .transport = .{ .context = self, .invoke_fn = invoke } };
    }
};

test "observation requires both matching ownership markers and UUID" {
    var fake: FakeTransport = .{};
    const adapter = fake.adapter();
    try adapter.probe();
    const observation = try adapter.observe(parse.exampleOwned());
    try std.testing.expectEqual(@as(usize, 4), fake.calls);
    try std.testing.expect(!observation.isolation_verified);
    try std.testing.expectEqual(@as(usize, 0), fake.mutations);
    fake.wrong_marker = true;
    try std.testing.expectError(error.OwnershipMismatch, adapter.observe(parse.exampleOwned()));
    try std.testing.expectEqual(@as(usize, 0), fake.mutations);
}
