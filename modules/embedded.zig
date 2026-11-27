// Explicit build-time allowlist; never enumerate a runtime plugin directory.
pub const Source = struct { filename: []const u8, json: []const u8 };
pub const sources = [_]Source{
    .{ .filename = "acl-gpo.json", .json = @embedFile("acl-gpo.json") },
    .{ .filename = "ad-core.json", .json = @embedFile("ad-core.json") },
    .{ .filename = "adcs.json", .json = @embedFile("adcs.json") },
    .{ .filename = "directory-fixtures.json", .json = @embedFile("directory-fixtures.json") },
    .{ .filename = "kerberos-policy.json", .json = @embedFile("kerberos-policy.json") },
    .{ .filename = "linux-tools.json", .json = @embedFile("linux-tools.json") },
    .{ .filename = "member-server.json", .json = @embedFile("member-server.json") },
    .{ .filename = "second-dc.json", .json = @embedFile("second-dc.json") },
};
