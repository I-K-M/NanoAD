const std = @import("std");

pub const Exit = enum(u8) {
    success = 0,
    invalid_input = 2,
    unmet_prerequisites = 3,
    resource_refusal = 4,
    approval_required = 5,
    provider_failure = 6,
    recovery_required = 7,
    unsupported = 8,
};

pub const Kind = enum { help, version, doctor };
pub const Command = struct { kind: Kind, json: bool = false };

pub const help =
    \\NanoAD — real Active Directory, minimal footprint.
    \\Development bootstrap; no VM operations implemented.
    \\
    \\Usage:
    \\  nanoad --help
    \\  nanoad version [--json]
    \\  nanoad doctor [--json]
    \\
    \\doctor is a read-only preliminary host inventory. It cannot certify
    \\provider compatibility, network isolation or AD functionality.
    \\
;

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn parse(args: anytype) error{InvalidArguments}!Command {
    if (args.len == 0) return .{ .kind = .help };
    if (args.len > 2) return error.InvalidArguments;
    const first = args[0];
    const kind: Kind = if (eq(first, "help") or eq(first, "--help") or eq(first, "-h"))
        .help
    else if (eq(first, "version") or eq(first, "--version"))
        .version
    else if (eq(first, "doctor"))
        .doctor
    else
        return error.InvalidArguments;

    if (args.len == 2 and (kind == .help or !eq(args[1], "--json")))
        return error.InvalidArguments;
    return .{ .kind = kind, .json = args.len == 2 };
}

test "empty and explicit help" {
    try std.testing.expectEqual(Kind.help, (try parse(&[_][]const u8{})).kind);
    try std.testing.expectEqual(Kind.help, (try parse(&[_][]const u8{"--help"})).kind);
}

test "version and doctor JSON" {
    const cmd = try parse(&[_][]const u8{ "doctor", "--json" });
    try std.testing.expectEqual(Kind.doctor, cmd.kind);
    try std.testing.expect(cmd.json);
    try std.testing.expectEqual(Kind.version, (try parse(&[_][]const u8{"--version"})).kind);
}

test "unknown and duplicate options fail closed" {
    try std.testing.expectError(error.InvalidArguments, parse(&[_][]const u8{"up"}));
    try std.testing.expectError(error.InvalidArguments, parse(&[_][]const u8{ "doctor", "--write" }));
    try std.testing.expectError(error.InvalidArguments, parse(&[_][]const u8{ "doctor", "--json", "--json" }));
    try std.testing.expectError(error.InvalidArguments, parse(&[_][]const u8{ "--help", "--json" }));
}
