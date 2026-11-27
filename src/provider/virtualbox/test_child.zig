// CI fixture only; not installed or shipped. Never communicates with VirtualBox.
const std = @import("std");

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);
    const out = std.io.getStdOut();
    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) {
        try out.writeAll("7.1.10r169112\r\n");
        return;
    }
    if (args.len == 4 and std.mem.eql(u8, args[1], "showvminfo")) {
        if (std.mem.endsWith(u8, args[2], "001")) {
            const block: [4096]u8 = @splat('x');
            try out.writeAll(&block);
        } else if (std.mem.endsWith(u8, args[2], "002")) {
            std.Thread.sleep(5 * std.time.ns_per_s);
        } else {
            try out.writeAll("fixture output\n");
        }
        return;
    }
    if (args.len == 4 and std.mem.eql(u8, args[1], "getextradata")) {
        if (std.mem.eql(u8, args[3], "NanoAD/LabId")) {
            try out.writeAll("fixture stdout\n");
            try std.io.getStdErr().writeAll("fixture diagnostic\n");
            return;
        }
        std.process.exit(7);
    }
    std.process.exit(9);
}
