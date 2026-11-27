const std = @import("std");
const builtin = @import("builtin");

const Handle = *anyopaque;
extern "kernel32" fn CreateMutexW(attributes: ?*anyopaque, initial_owner: i32, name: [*:0]const u16) callconv(.winapi) ?Handle;
extern "kernel32" fn WaitForSingleObject(handle: Handle, milliseconds: u32) callconv(.winapi) u32;
extern "kernel32" fn ReleaseMutex(handle: Handle) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(handle: Handle) callconv(.winapi) i32;
extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) u32;

const name = std.unicode.utf8ToUtf16LeStringLiteral("Global\\NanoAD.ResourceAdmission.v1");
var local_held = std.atomic.Value(bool).init(false);

pub const Failure = error{ Unsupported, HostLockBusy, HostLockFailed, RecoveryRequired, WrongThread };

/// Cooperative machine-wide Windows mutex, not a hypervisor lock. Default
/// DACL: access denied across accounts is a refusal, never a local fallback.
/// Acquire BEFORE the per-lab journal lock; release in reverse order.
/// Keep ownership on the same thread. Always reconcile after acquisition:
/// a named mutex alone cannot establish that a previous session completed.
pub const HostLock = struct {
    handle: Handle,
    thread: u32,

    pub fn acquire() Failure!HostLock {
        if (builtin.os.tag != .windows or builtin.cpu.arch != .x86_64) return error.Unsupported;
        if (local_held.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return error.HostLockBusy;
        errdefer local_held.store(false, .release);
        const handle = CreateMutexW(null, 0, name) orelse return error.HostLockFailed;
        errdefer _ = CloseHandle(handle);
        switch (WaitForSingleObject(handle, 0)) {
            0 => return .{ .handle = handle, .thread = GetCurrentThreadId() },
            258 => return error.HostLockBusy,
            128 => {
                // WAIT_ABANDONED grants ownership but proves an interrupted
                // holder. Release it, refuse work, require journal recovery.
                _ = ReleaseMutex(handle);
                return error.RecoveryRequired;
            },
            else => return error.HostLockFailed,
        }
    }

    pub fn release(self: *HostLock) Failure!void {
        if (builtin.os.tag != .windows or builtin.cpu.arch != .x86_64) return error.Unsupported;
        if (GetCurrentThreadId() != self.thread) return error.WrongThread;
        if (ReleaseMutex(self.handle) == 0) return error.HostLockFailed;
        const closed = CloseHandle(self.handle);
        self.* = undefined;
        if (closed == 0) return error.HostLockFailed;
        local_held.store(false, .release);
    }
};

test "unsupported host fails closed" {
    if (builtin.os.tag != .windows or builtin.cpu.arch != .x86_64)
        try std.testing.expectError(error.Unsupported, HostLock.acquire());
}
