const std = @import("std");
const Facts = @import("types.zig").Facts;

// Documented Win32 MEMORYSTATUSEX layout.
const MemoryStatusEx = extern struct {
    length: u32,
    memory_load: u32,
    total_phys: u64,
    avail_phys: u64,
    total_page_file: u64,
    avail_page_file: u64,
    total_virtual: u64,
    avail_virtual: u64,
    avail_extended_virtual: u64,
};

extern "kernel32" fn GlobalMemoryStatusEx(status: *MemoryStatusEx) callconv(.winapi) i32;
extern "kernel32" fn GetDiskFreeSpaceExW(directory: ?[*:0]const u16, available: *u64, total: ?*u64, total_free: ?*u64) callconv(.winapi) i32;
extern "kernel32" fn IsProcessorFeaturePresent(feature: u32) callconv(.winapi) i32;

const PF_VIRT_FIRMWARE_ENABLED: u32 = 21;

pub fn fill(facts: *Facts) void {
    var status = std.mem.zeroes(MemoryStatusEx);
    status.length = @sizeOf(MemoryStatusEx);
    if (GlobalMemoryStatusEx(&status) != 0) {
        facts.physical_ram_bytes = status.total_phys;
        if (status.avail_phys <= status.total_phys)
            facts.available_ram_bytes = status.avail_phys;
        // Available commit for this process, not a licence to overcommit.
        facts.commit_headroom_bytes = status.avail_page_file;
    }

    var available: u64 = 0;
    // NULL selects the current working directory's volume.
    if (GetDiskFreeSpaceExW(null, &available, null, null) != 0)
        facts.disk_available_to_caller_bytes = available;

    facts.virtualisation_firmware_hint = IsProcessorFeaturePresent(PF_VIRT_FIRMWARE_ENABLED) != 0;
    // No PATH execution or registry modification. This is just a file hint;
    // other install locations are inventoried by the N01 PowerShell probe.
    const path = "C:\\Program Files\\Oracle\\VirtualBox\\VBoxManage.exe";
    if (std.fs.openFileAbsolute(path, .{})) |file| {
        defer file.close();
        if (file.stat()) |info| {
            facts.provider_candidate_found = info.kind == .file;
        } else |_| {}
    } else |_| {}
    // Unknown is deliberately retained for missing or inaccessible candidate.
}
