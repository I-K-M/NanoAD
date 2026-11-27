const std = @import("std");
const builtin = @import("builtin");
const Facts = @import("types.zig").Facts;

pub const Report = struct {
    schema_version: u32 = 1,
    command: []const u8 = "doctor",
    result: []const u8 = "unqualified",
    host: Facts,
    errors: []const []const u8 = &.{"provider_and_isolation_not_qualified"},
};

pub fn collect() Report {
    var facts = Facts{
        .executable_os = @tagName(builtin.os.tag),
        .executable_arch = @tagName(builtin.cpu.arch),
        .supported_reference_platform = builtin.os.tag == .windows and builtin.cpu.arch == .x86_64,
        .provider = switch (builtin.os.tag) {
            .windows => "virtualbox",
            .linux => "kvm-deferred",
            else => "unsupported",
        },
    };
    switch (builtin.os.tag) {
        .windows => @import("windows.zig").fill(&facts),
        .linux => @import("linux.zig").fill(&facts),
        else => {},
    }
    return .{ .host = facts };
}

fn metric(out: anytype, label: []const u8, bytes: ?u64) !void {
    if (bytes) |value| {
        try out.print("{s}: {d} bytes\n", .{ label, value });
    } else try out.print("{s}: unknown\n", .{label});
}

pub fn print(report: Report, out: anytype) !void {
    const facts = report.host;
    try out.print("NanoAD doctor — preliminary inventory\nExecutable target: {s}/{s}\nProvider: {s}\n", .{ facts.executable_os, facts.executable_arch, facts.provider });
    try metric(out, "Physical memory", facts.physical_ram_bytes);
    try metric(out, "Available physical memory", facts.available_ram_bytes);
    try metric(out, "Commit headroom (hint)", facts.commit_headroom_bytes);
    try metric(out, "Caller-available disk (current directory)", facts.disk_available_to_caller_bytes);
    if (facts.provider_candidate_found) |found| {
        try out.print("Provider candidate found: {}\n", .{found});
    } else try out.writeAll("Provider candidate found: unknown\n");
    try out.writeAll("Provider runtime and network isolation: unverified\n");
    try out.writeAll("Result: unqualified; no VM operation is available.\n");
}

test "probe cannot claim readiness" {
    const report = collect();
    try std.testing.expect(!report.host.provider_runtime_verified);
    try std.testing.expect(!report.host.isolation_verified);
    try std.testing.expectEqualStrings("unqualified", report.result);
}
