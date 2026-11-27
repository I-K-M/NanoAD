const std = @import("std");

pub const Digest = struct {
    bytes: [32]u8,

    pub fn parse(input: []const u8) error{InvalidDigest}!Digest {
        if (input.len != 64) return error.InvalidDigest;
        var result: Digest = undefined;
        _ = std.fmt.hexToBytes(&result.bytes, input) catch return error.InvalidDigest;
        return result;
    }

    pub fn hex(self: Digest) [64]u8 {
        return std.fmt.bytesToHex(self.bytes, .lower);
    }

    pub fn eql(self: Digest, other: Digest) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }

    pub fn basePath(self: Digest) [74]u8 {
        return "bases/".* ++ self.hex() ++ ".vdi".*;
    }
};

// The caller owns a verified, regular, quiescent file handle. This function
// does not establish path containment or enforce exclusivity. It checks
// observable length/mtime changes; that is not a substitute for a lock.
pub fn verifyFile(file: std.fs.File, expected_length: u64, expected: Digest) !void {
    const before = try file.stat();
    if (before.kind != .file or expected_length == 0 or before.size != expected_length)
        return error.InvalidImage;
    try file.seekTo(0);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [16 * 1024]u8 = undefined;
    var remaining = expected_length;
    while (remaining != 0) {
        const want: usize = @intCast(@min(remaining, buffer.len));
        const n = try file.read(buffer[0..want]);
        if (n == 0) return error.ImageChanged;
        hash.update(buffer[0..n]);
        remaining -= n;
    }
    var extra: [1]u8 = undefined;
    if (try file.read(&extra) != 0) return error.ImageChanged;
    const after = try file.stat();
    if (after.size != before.size or after.mtime != before.mtime or after.kind != .file)
        return error.ImageChanged;
    var actual: Digest = undefined;
    hash.final(&actual.bytes);
    if (!actual.eql(expected)) return error.DigestMismatch;
}

test "canonical digest paths cannot contain user path components" {
    const d = try Digest.parse("0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF");
    try std.testing.expectEqualStrings("bases/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef.vdi", &d.basePath());
    try std.testing.expectError(error.InvalidDigest, Digest.parse("../outside.vdi"));
    try std.testing.expectError(error.InvalidDigest, Digest.parse("z" ** 64));
}

test "bounded streaming verification rejects size and digest mismatch" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const file = try temp.dir.createFile("base.bin", .{ .read = true });
    defer file.close();
    const data: [17000]u8 = @splat(42);
    try file.writeAll(&data);
    var expected: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(&data, &expected.bytes, .{});
    try verifyFile(file, data.len, expected);
    try std.testing.expectError(error.InvalidImage, verifyFile(file, data.len - 1, expected));
    expected.bytes[0] ^= 1;
    try std.testing.expectError(error.DigestMismatch, verifyFile(file, data.len, expected));
}
