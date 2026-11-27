const std = @import("std");
const cli = @import("cli/command.zig");
const host = @import("host/host.zig");
const modules = @import("modules/registry.zig");
const manifest = @import("modules/manifest.zig");
const module_output = @import("modules/output.zig");

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
        .modules_list, .modules_info => {
            const registry = modules.Registry.builtin() catch {
                try std.io.getStdErr().writeAll("nanoad: bundled module catalogue invalid\n");
                return .provider_failure;
            };
            if (command.kind == .modules_list) {
                try module_output.list(out, &registry, command.json);
            } else {
                const id = manifest.Id.parse(command.module_id.?) catch return .invalid_input;
                const selected = registry.find(id) orelse {
                    try std.io.getStdErr().writeAll("nanoad: unknown module\n");
                    return .invalid_input;
                };
                try module_output.info(out, selected, command.json);
            }
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
    _ = modules;
    _ = manifest;
    _ = host;
    _ = @import("host/meminfo.zig");
    _ = @import("image/digest.zig");
    _ = @import("image/catalogue.zig");
    _ = @import("storage/accounting.zig");
    _ = @import("storage/planner.zig");
    _ = @import("storage/windows_allocation.zig");
    _ = @import("governor/bounds.zig");
    _ = @import("governor/admission.zig");
    _ = @import("host/metrics/windows.zig");
    _ = @import("state/model.zig");
    _ = @import("state/journal.zig");
    _ = @import("lifecycle/transaction/reconcile.zig");
    _ = @import("lifecycle/transaction/coordinator.zig");
}
