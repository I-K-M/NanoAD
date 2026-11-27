const std = @import("std");
const manifest = @import("manifest.zig");
const Registry = @import("registry.zig").Registry;

fn writeManifest(out: anytype, m: *const manifest.Manifest) !void {
    var requires: [manifest.max_edges][]const u8 = undefined;
    var conflicts: [manifest.max_edges][]const u8 = undefined;
    for (m.requires.view(), 0..) |*id, i| requires[i] = id.slice();
    for (m.conflicts.view(), 0..) |*id, i| conflicts[i] = id.slice();
    try std.json.stringify(.{
        .schema_version = @as(u32, 1),
        .id = m.id.slice(),
        .version = m.version.slice(),
        .kind = m.kind,
        .enabled_by_default = m.enabled_by_default,
        .requires = requires[0..m.requires.len],
        .conflicts = conflicts[0..m.conflicts.len],
        .capabilities = m.capabilities.view(),
        .resources = m.resources,
        .lifecycle = m.lifecycle,
        .provisioner = m.provisioner,
        .health_checks = m.health_checks.view(),
        .implementation = m.provisioner.availability(),
        .activation_supported = false,
    }, .{}, out);
}

fn printManifest(out: anytype, m: *const manifest.Manifest) !void {
    try out.print("{s} {s} ({s}; {s})\n", .{ m.id.slice(), m.version.slice(), @tagName(m.kind), @tagName(m.provisioner.availability()) });
    try out.print("Default selection: {}\n", .{m.enabled_by_default});
    try out.writeAll("Requires:");
    for (m.requires.view()) |*id| try out.print(" {s}", .{id.slice()});
    if (m.requires.len == 0) try out.writeAll(" none");
    try out.writeAll("\n");
    if (m.resources.configured_memory_bytes) |n| try out.print("Configured RAM target: {d} bytes (not an admission bound)\n", .{n}) else try out.writeAll("Configured RAM target: unknown\n");
    try out.print("Resource provenance: {s}; activation unavailable\n", .{@tagName(m.resources.provenance)});
    if (!m.lifecycle.can_stop) try out.writeAll("Persistent changes: cannot be deactivated as a running workload.\n");
}

pub fn list(out: anytype, registry: *const Registry, json: bool) !void {
    if (json) {
        try out.writeAll("{\"schema_version\":1,\"command\":\"modules list\",\"result\":\"ok\",\"activation_performed\":false,\"modules\":[");
        for (registry.view(), 0..) |*m, i| {
            if (i != 0) try out.writeByte(',');
            try writeManifest(out, m);
        }
        try out.writeAll("]}\n");
    } else {
        try out.writeAll("NanoAD bundled module catalogue (metadata only; no lab state queried)\n");
        for (registry.view()) |*m| try out.print("{s}\t{s}\t{s}{s}\n", .{
            m.id.slice(), @tagName(m.kind), @tagName(m.provisioner.availability()), if (m.enabled_by_default) " (core default)" else "",
        });
        try out.writeAll("No module was provisioned, downloaded or started.\n");
    }
}

pub fn info(out: anytype, m: *const manifest.Manifest, json: bool) !void {
    if (json) {
        try out.writeAll("{\"schema_version\":1,\"command\":\"modules info\",\"result\":\"ok\",\"activation_performed\":false,\"module\":");
        try writeManifest(out, m);
        try out.writeAll("}\n");
    } else try printManifest(out, m);
}
