const std = @import("std");
const builtin = @import("builtin");
const model = @import("model.zig");
const Lock = @import("lock.zig").Lock;
const Digest = @import("../image/digest.zig").Digest;

pub const max_payload = 32 * 1024;
pub const max_frame = 65 + max_payload + 1;
pub const max_journal_bytes = 8 * 1024 * 1024;
pub const max_records = 4096;
const genesis: [64]u8 = @splat('0');

const Record = struct {
    schema_version: u32,
    revision: u64,
    previous_sha256: [64]u8,
    event: model.Event,
};

const Replay = struct {
    current: ?model.State = null,
    head: [64]u8 = genesis,
    end: u64 = 0,
};

fn hashHex(payload: []const u8) [64]u8 {
    var digest: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &digest.bytes, .{});
    return digest.hex();
}

// The final byte must be a newline. A torn or invalid record blocks the
// entire journal: do NOT silently replay an earlier valid prefix.
fn replay(file: std.fs.File) !Replay {
    const size = try file.getEndPos();
    if (size == 0 or size > max_journal_bytes) return error.JournalCorrupt;
    try file.seekTo(size - 1);
    var last: [1]u8 = undefined;
    if (try file.readAll(&last) != 1 or last[0] != '\n') return error.JournalCorrupt;
    try file.seekTo(0);
    var buffered = std.io.bufferedReader(file.reader());
    const reader = buffered.reader();
    var line: [max_frame]u8 = undefined;
    var arena_bytes: [192 * 1024]u8 = undefined;
    var result: Replay = .{};
    var records: usize = 0;
    while (try reader.readUntilDelimiterOrEof(&line, '\n')) |frame| {
        records += 1;
        if (records > max_records or frame.len <= 65 or frame.len > max_frame - 1 or frame[64] != ' ')
            return error.JournalCorrupt;
        const payload = frame[65..];
        const hash = hashHex(payload);
        if (!std.mem.eql(u8, frame[0..64], &hash)) return error.JournalCorrupt;
        var arena = std.heap.FixedBufferAllocator.init(&arena_bytes);
        const parsed = std.json.parseFromSlice(Record, arena.allocator(), payload, .{
            .ignore_unknown_fields = false,
            .duplicate_field_behavior = .@"error",
        }) catch return error.JournalCorrupt;
        defer parsed.deinit();
        const record = parsed.value;
        if (record.schema_version != 1 or !std.mem.eql(u8, &record.previous_sha256, &result.head))
            return error.JournalCorrupt;
        result.current = model.apply(result.current, record.revision, record.event) catch return error.JournalCorrupt;
        result.head = hash;
    }
    if (result.current == null or try file.getEndPos() != size) return error.JournalCorrupt;
    result.end = size;
    return result;
}

pub const Store = struct {
    lock: Lock,
    file: std.fs.File,
    cache: Replay,
    poisoned: bool = false,

    // Caller must supply an existing trusted local directory, with restrictive
    // ACLs and no untrusted aliases/reparse paths or concurrent non-NanoAD
    // writers. Initialisation is explicit and exclusive, never a fallback.
    pub fn create(dir: std.fs.Dir, initial: model.Initial) !Store {
        _ = try model.apply(null, 1, .{ .kind = .initialise, .initial = initial });
        var lock = try Lock.create(dir);
        errdefer lock.close();
        const file = try dir.createFile("state.log", .{ .read = true, .exclusive = true, .truncate = false, .mode = 0o600 });
        errdefer file.close();
        var store: Store = .{ .lock = lock, .file = file, .cache = .{} };
        try store.append(0, .{ .kind = .initialise, .initial = initial });
        if (builtin.os.tag == .linux) {
            var sync_dir = try dir.openDir(".", .{ .iterate = true });
            defer sync_dir.close();
            try std.posix.fsync(sync_dir.fd);
        }
        // On Windows file.sync flushes the file; initial directory-entry
        // persistence across sudden power loss remains a qualification gate.
        return store;
    }

    pub fn open(dir: std.fs.Dir) !Store {
        var lock = try Lock.acquire(dir);
        errdefer lock.close();
        const file = try dir.openFile("state.log", .{ .mode = .read_write });
        errdefer file.close();
        if ((try file.stat()).kind != .file) return error.InvalidState;
        const cache = try replay(file);
        return .{ .lock = lock, .file = file, .cache = cache };
    }

    pub fn close(self: *Store) void {
        self.file.close();
        self.lock.close();
        self.* = undefined;
    }

    pub fn state(self: *const Store) !model.State {
        if (self.poisoned) return error.StorePoisoned;
        return self.cache.current orelse error.InvalidState;
    }

    // Internal trusted coordinator only. No CLI can submit raw journal
    // events. The exclusive lock is held for this Store's entire lifetime.
    // A complete hash-chained record is the atomic logical commit. No
    // separately updated state/ledger file can get out of sync with it.
    pub fn append(self: *Store, expected_revision: u64, event: model.Event) !void {
        if (self.poisoned) return error.StorePoisoned;
        const current_revision = if (self.cache.current) |current| current.revision else 0;
        if (current_revision != expected_revision) return error.StaleRevision;
        const revision = try std.math.add(u64, current_revision, 1);
        const next = try model.apply(self.cache.current, revision, event);
        // Reserve space for dispatch and completion before accepting intent.
        const needed_frames: u64 = if (event.kind == .intent) 3 else 1;
        if (current_revision + needed_frames > max_records or
            self.cache.end + needed_frames * max_frame > max_journal_bytes)
            return error.JournalLimit;
        const record: Record = .{
            .schema_version = 1,
            .revision = revision,
            .previous_sha256 = self.cache.head,
            .event = event,
        };
        var payload: [max_payload]u8 = undefined;
        var stream = std.io.fixedBufferStream(&payload);
        try std.json.stringify(record, .{}, stream.writer());
        const data = stream.getWritten();
        const hash = hashHex(data);
        var frame: [max_frame]u8 = undefined;
        @memcpy(frame[0..64], &hash);
        frame[64] = ' ';
        @memcpy(frame[65 .. 65 + data.len], data);
        frame[65 + data.len] = '\n';
        const bytes = frame[0 .. 66 + data.len];

        // No successful state update or permission to dispatch on uncertain
        // I/O. An ambiguous failure poisons this handle; reopen/reconcile.
        errdefer self.poisoned = true;
        if (try self.file.getEndPos() != self.cache.end) return error.JournalCorrupt;
        try self.file.seekTo(self.cache.end);
        try self.file.writeAll(bytes);
        try self.file.sync();
        self.cache = .{ .current = next, .head = hash, .end = self.cache.end + bytes.len };
    }
};

test "durable intent and dispatch survive reopen; stale writes refused" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const initial = model.exampleInitial();
    var store = try Store.create(tmp.dir, initial);
    try store.append(1, .{ .kind = .intent, .operation = .{ .serial = 2, .guest = initial.guests[0].?.owner.guest, .kind = .start } });
    store.close();
    store = try Store.open(tmp.dir);
    try std.testing.expectEqual(model.Stage.intent, (try store.state()).operation.?.stage);
    try std.testing.expectEqual(@as(usize, 1), (try (try store.state()).ledger()).len);
    try std.testing.expectError(error.StaleRevision, store.append(1, .{ .kind = .dispatch, .serial = 2 }));
    try store.append(2, .{ .kind = .dispatch, .serial = 2 });
    store.close();
    store = try Store.open(tmp.dir);
    try std.testing.expectEqual(model.Stage.dispatch, (try store.state()).operation.?.stage);
    try std.testing.expectError(error.RecoveryRequired, store.append(3, .{ .kind = .cancel, .serial = 2 }));
    try store.append(3, .{ .kind = .complete, .serial = 2 });
    store.close();
    store = try Store.open(tmp.dir);
    defer store.close();
    try std.testing.expectEqual(model.Phase.active, (try store.state()).phases[0]);
}

test "torn journal tail blocks replay; never recreate missing state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.create(tmp.dir, model.exampleInitial());
    store.close();
    {
        const file = try tmp.dir.openFile("state.log", .{ .mode = .read_write });
        defer file.close();
        try file.seekFromEnd(0);
        try file.writeAll("incomplete");
        try file.sync();
    }
    try std.testing.expectError(error.JournalCorrupt, Store.open(tmp.dir));
    try std.testing.expectError(error.PathAlreadyExists, Store.create(tmp.dir, model.exampleInitial()));
}

test "changed complete frame is rejected, not repaired" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.create(tmp.dir, model.exampleInitial());
    store.close();
    {
        const file = try tmp.dir.openFile("state.log", .{ .mode = .read_write });
        defer file.close();
        try file.seekTo(0);
        try file.writeAll("!");
        try file.sync();
    }
    try std.testing.expectError(error.JournalCorrupt, Store.open(tmp.dir));
}
