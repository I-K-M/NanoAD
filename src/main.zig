const std = @import("std");
const cli = @import("cli/command.zig");
const host = @import("host/host.zig");

const version = "0.1.0-dev";

pub fn main() void {
    const code = run() catch {
        std.io.getStdErr().writeAll("nanoad: unable to read arguments or write output\n") catch {};
        std.process.exit(@intFromEnum(cli.Exit.provider_failure));
    };
    std.process.exit(@intFromEnum(code));
}

fn run() !cli.Exit {
    // OS argument vectors are bounded again here; no unbounded allocator.
    var arg_buffer: [128 * 1024]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&arg_buffer);
    const args = std.process.argsAlloc(allocator.allocator()) catch {
        try std.io.getStdErr().writeAll("nanoad: arguments exceed supported limits\n");
        return .invalid_input;
    };
    defer std.process.argsFree(allocator.allocator(), args);
    const command = cli.parse(args[1..]) catch {
        try std.io.getStdErr().writeAll("nanoad: invalid command or option; run nanoad --help\n");
        return .invalid_input;
    };
    const out = std.io.getStdOut().writer();
    switch (command.kind) {
        .help => try out.writeAll(cli.help),
        .version => {
            if (command.json) {
                try std.json.stringify(.{
                    .schema_version = @as(u32, 1),
                    .command = "version",
                    .result = "ok",
                    .version = version,
                }, .{}, out);
                try out.writeByte('\n');
            } else try out.print("NanoAD {s}\n", .{version});
        },
        .doctor => {
            const report = host.collect();
            if (command.json) {
                try std.json.stringify(report, .{}, out);
                try out.writeByte('\n');
            } else try host.print(report, out);
            // A probe does not qualify a hypervisor, image or network.
            return if (report.host.supported_reference_platform) .unmet_prerequisites else .unsupported;
        },
    }
    return .success;
}

test {
    _ = cli;
    _ = host;
    _ = @import("host/meminfo.zig");
    _ = @import("image/digest.zig");
    _ = @import("image/catalogue.zig");
    _ = @import("storage/accounting.zig");
    _ = @import("storage/planner.zig");
    _ = @import("storage/windows_allocation.zig");
}
