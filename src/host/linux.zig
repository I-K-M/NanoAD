const std = @import("std");
const Facts = @import("types.zig").Facts;
const meminfo = @import("meminfo.zig");
const c = @cImport({
    @cInclude("sys/statvfs.h");
});

pub fn fill(facts: *Facts) void {
    if (std.fs.openFileAbsolute("/proc/meminfo", .{})) |file| {
        defer file.close();
        var buffer: [16 * 1024]u8 = undefined;
        if (file.readAll(&buffer)) |length| {
            // A full buffer may indicate truncation; do not trust partial data.
            if (length < buffer.len) {
                const memory = meminfo.parse(buffer[0..length]);
                facts.physical_ram_bytes = memory.total;
                facts.available_ram_bytes = memory.available;
            }
        } else |_| {}
    } else |_| {}

    var stat: c.struct_statvfs = undefined;
    if (c.statvfs(".", &stat) == 0) {
        const unit: u64 = @intCast(stat.f_frsize);
        const blocks: u64 = @intCast(stat.f_bavail);
        if (unit != 0) facts.disk_available_to_caller_bytes = std.math.mul(u64, unit, blocks) catch null;
    }
    // Linux provider support is deliberately deferred; no /dev/kvm open or ioctl.
    // Host memory from /proc is not a cgroup-aware admission budget.
}
