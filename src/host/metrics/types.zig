pub const MemorySample = struct {
    // All timestamps share the same host monotonic clock and boot/session.
    started_ms: u64,
    completed_ms: u64,
    physical_total: ?u64,
    physical_available: ?u64,
    commit_limit: ?u64,
    committed: ?u64,
};

pub const DiskSample = struct {
    started_ms: u64,
    completed_ms: u64,
    total_to_caller: ?u64,
    available_to_caller: ?u64,
};

pub const ProcessSample = struct {
    started_ms: u64,
    completed_ms: u64,
    working_set: u64,
    peak_working_set: u64,
    private_commit: u64,
    peak_private_commit: u64,
    page_faults: u32,
};
