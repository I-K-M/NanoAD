const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");

const PerformanceInfo = extern struct {
    cb: u32,
    commit_total: usize,
    commit_limit: usize,
    commit_peak: usize,
    physical_total: usize,
    physical_available: usize,
    system_cache: usize,
    kernel_total: usize,
    kernel_paged: usize,
    kernel_nonpaged: usize,
    page_size: usize,
    handle_count: u32,
    process_count: u32,
    thread_count: u32,
};

const ProcessCounters = extern struct {
    cb: u32,
    page_fault_count: u32,
    peak_working_set: usize,
    working_set: usize,
    quota_peak_paged: usize,
    quota_paged: usize,
    quota_peak_nonpaged: usize,
    quota_nonpaged: usize,
    pagefile_usage: usize,
    peak_pagefile_usage: usize,
    private_usage: usize,
};

extern "kernel32" fn K32GetPerformanceInfo(info: *PerformanceInfo, size: u32) callconv(.winapi) i32;
extern "kernel32" fn K32GetProcessMemoryInfo(process: *anyopaque, counters: *ProcessCounters, size: u32) callconv(.winapi) i32;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) *anyopaque;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn GetDiskFreeSpaceExW(directory: [*:0]const u16, available: *u64, total: *u64, total_free: ?*u64) callconv(.winapi) i32;
extern "kernel32" fn GetCurrentDirectoryW(capacity: u32, directory: [*]u16) callconv(.winapi) u32;

pub const Failure = error{ Unsupported, QueryFailed, InvalidSample, Overflow };

fn pagesToBytes(pages: usize, page_size: usize) Failure!u64 {
    if (page_size == 0) return error.InvalidSample;
    return std.math.mul(u64, @intCast(pages), @intCast(page_size)) catch error.Overflow;
}

pub fn monotonicMs() Failure!u64 {
    if (builtin.os.tag != .windows or builtin.cpu.arch != .x86_64) return error.Unsupported;
    return GetTickCount64();
}

pub fn memory() Failure!types.MemorySample {
    if (builtin.os.tag != .windows or builtin.cpu.arch != .x86_64) return error.Unsupported;
    const started = GetTickCount64();
    var info = std.mem.zeroes(PerformanceInfo);
    info.cb = @sizeOf(PerformanceInfo);
    if (K32GetPerformanceInfo(&info, @sizeOf(PerformanceInfo)) == 0) return error.QueryFailed;
    const completed = GetTickCount64();
    if (completed < started or info.physical_total == 0 or info.physical_available > info.physical_total or
        info.commit_limit == 0 or info.commit_total > info.commit_limit) return error.InvalidSample;
    return .{
        .started_ms = started,
        .completed_ms = completed,
        .physical_total = try pagesToBytes(info.physical_total, info.page_size),
        .physical_available = try pagesToBytes(info.physical_available, info.page_size),
        .commit_limit = try pagesToBytes(info.commit_limit, info.page_size),
        .committed = try pagesToBytes(info.commit_total, info.page_size),
    };
}

// Caller supplies an independently verified local lab-volume path. Lexical
// validation here is not proof of containment, drive type or mount identity.
pub fn disk(path: [:0]const u16) Failure!types.DiskSample {
    if (builtin.os.tag != .windows or builtin.cpu.arch != .x86_64) return error.Unsupported;
    if (path.len < 3 or path.len >= 260 or path[0] > 127 or !std.ascii.isAlphabetic(@intCast(path[0])) or
        path[1] != ':' or path[2] != '\\') return error.InvalidSample;
    for (path) |c| if (c == 0) return error.InvalidSample;
    const started = GetTickCount64();
    var available: u64 = 0;
    var total: u64 = 0;
    if (GetDiskFreeSpaceExW(path.ptr, &available, &total, null) == 0) return error.QueryFailed;
    const completed = GetTickCount64();
    if (completed < started or total == 0 or available > total) return error.InvalidSample;
    return .{
        .started_ms = started,
        .completed_ms = completed,
        .total_to_caller = total,
        .available_to_caller = available,
    };
}

// The caller owns a verified, live process handle. This does not discover
// provider processes, infer ownership, or turn RSS into non-reclaimable credit.
pub fn process(handle: *anyopaque) Failure!types.ProcessSample {
    if (builtin.os.tag != .windows or builtin.cpu.arch != .x86_64) return error.Unsupported;
    const started = GetTickCount64();
    var counters = std.mem.zeroes(ProcessCounters);
    counters.cb = @sizeOf(ProcessCounters);
    if (K32GetProcessMemoryInfo(handle, &counters, @sizeOf(ProcessCounters)) == 0) return error.QueryFailed;
    const completed = GetTickCount64();
    if (completed < started or counters.peak_working_set < counters.working_set or
        counters.peak_pagefile_usage < counters.private_usage) return error.InvalidSample;
    return .{
        .started_ms = started,
        .completed_ms = completed,
        .working_set = @intCast(counters.working_set),
        .peak_working_set = @intCast(counters.peak_working_set),
        .private_commit = @intCast(counters.private_usage),
        .peak_private_commit = @intCast(counters.peak_pagefile_usage),
        .page_faults = counters.page_fault_count,
    };
}

test "page conversion is checked" {
    try std.testing.expectEqual(@as(u64, 8192), try pagesToBytes(2, 4096));
    try std.testing.expectError(error.InvalidSample, pagesToBytes(1, 0));
    if (@sizeOf(usize) == 8)
        try std.testing.expectError(error.Overflow, pagesToBytes(std.math.maxInt(usize), 4096));
}

test "native host and current-process observations, no VM or provider invoked" {
    if (builtin.os.tag != .windows or builtin.cpu.arch != .x86_64) {
        try std.testing.expectError(error.Unsupported, memory());
        try std.testing.expectError(error.Unsupported, monotonicMs());
        return;
    }
    const host = try memory();
    try std.testing.expect(host.physical_total.? > 0);
    try std.testing.expect(host.physical_available.? <= host.physical_total.?);
    try std.testing.expect(host.committed.? <= host.commit_limit.?);
    try std.testing.expect(host.completed_ms >= host.started_ms);
    try std.testing.expect(try monotonicMs() >= host.completed_ms);
    const self = try process(GetCurrentProcess());
    try std.testing.expect(self.working_set > 0);
    try std.testing.expect(self.peak_working_set >= self.working_set);
    var path: [260:0]u16 = @splat(0);
    const n = GetCurrentDirectoryW(path.len, &path);
    try std.testing.expect(n >= 3 and n < path.len);
    const space = try disk(path[0..n :0]);
    try std.testing.expect(space.available_to_caller.? <= space.total_to_caller.?);
}
