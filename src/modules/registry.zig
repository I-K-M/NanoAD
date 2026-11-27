const std = @import("std");
const manifest = @import("manifest.zig");
const assets = @import("manifest_assets");

pub const max_modules = 32;
pub const Failure = manifest.Failure || error{
    RegistryLimit,
    DuplicateModule,
    InvalidFilename,
    InvalidDefault,
    UnknownDependency,
    Cycle,
    Conflict,
    UnknownModule,
};

fn bit(index: usize) u32 {
    return @as(u32, 1) << @as(u5, @intCast(index));
}

pub const Registry = struct {
    entries: [max_modules]manifest.Manifest = undefined,
    len: usize = 0,
    direct: [max_modules]u32 = @splat(0),
    closure: [max_modules]u32 = @splat(0),
    conflicts: [max_modules]u32 = @splat(0),

    pub fn view(self: *const Registry) []const manifest.Manifest {
        return self.entries[0..self.len];
    }

    pub fn index(self: *const Registry, id: manifest.Id) ?usize {
        for (self.view(), 0..) |m, i| if (m.id.eql(id)) return i;
        return null;
    }

    pub fn find(self: *const Registry, id: manifest.Id) ?*const manifest.Manifest {
        return &self.entries[self.index(id) orelse return null];
    }

    fn add(self: *Registry, source: assets.Source) Failure!void {
        if (self.len >= max_modules) return error.RegistryLimit;
        const value = try manifest.parse(source.json);
        const name = source.filename;
        if (name.len != @as(usize, value.id.len) + 5 or !std.mem.endsWith(u8, name, ".json") or
            !std.mem.eql(u8, name[0..name.len - 5], value.id.slice())) return error.InvalidFilename;
        if (self.index(value.id) != null) return error.DuplicateModule;
        self.entries[self.len] = value;
        self.len += 1;
    }

    fn sort(self: *Registry) void {
        // Small fixed-size registry; insertion sort gives stable ID ordering.
        for (1..self.len) |i| {
            var j = i;
            while (j > 0 and std.mem.order(u8, self.entries[j].id.slice(), self.entries[j - 1].id.slice()) == .lt) : (j -= 1) {
                std.mem.swap(manifest.Manifest, &self.entries[j], &self.entries[j - 1]);
            }
        }
    }

    fn resolve(self: *Registry) Failure!void {
        const core = self.index(try manifest.Id.parse("ad-core")) orelse return error.InvalidDefault;
        for (self.view(), 0..) |m, i| {
            if (m.enabled_by_default != (i == core)) return error.InvalidDefault;
            if (i == core and (m.requires.len != 0 or m.conflicts.len != 0)) return error.InvalidDefault;
            for (m.requires.view()) |dep| {
                const target = self.index(dep) orelse return error.UnknownDependency;
                self.direct[i] |= bit(target);
            }
            for (m.conflicts.view()) |conflict| {
                const target = self.index(conflict) orelse return error.UnknownDependency;
                if (target == i or target == core) return error.Conflict;
                // A one-sided conflict is still symmetric in the registry.
                self.conflicts[i] |= bit(target);
                self.conflicts[target] |= bit(i);
            }
            self.closure[i] = self.direct[i];
        }
        // Bitset transitive closure, bounded by 32*32 iterations, no recursion.
        for (0..self.len) |k| {
            for (0..self.len) |i| {
                if (self.closure[i] & bit(k) != 0) self.closure[i] |= self.closure[k];
            }
        }
        for (0..self.len) |i| {
            if (self.closure[i] & bit(i) != 0) return error.Cycle;
            const needed = self.closure[i] | bit(i);
            for (0..self.len) |j| {
                if (needed & bit(j) != 0 and self.conflicts[j] & needed != 0) return error.Conflict;
            }
        }
    }

    pub fn fromSources(sources: []const assets.Source) Failure!Registry {
        if (sources.len == 0 or sources.len > max_modules) return error.RegistryLimit;
        var result: Registry = .{};
        for (sources) |source| try result.add(source);
        result.sort();
        try result.resolve();
        return result;
    }

    pub fn builtin() Failure!Registry {
        return fromSources(&assets.sources);
    }
};

fn fixture(name: []const u8) assets.Source {
    for (assets.sources) |source| if (std.mem.eql(u8, source.filename, name)) return source;
    unreachable;
}

fn edited(comptime old: []const u8, comptime new: []const u8, source: assets.Source, buffer: []u8) !assets.Source {
    const i = std.mem.indexOf(u8, source.json, old) orelse return error.FixtureNotFound;
    const result = try std.fmt.bufPrint(buffer, "{s}{s}{s}", .{ source.json[0..i], new, source.json[i + old.len ..] });
    return .{ .filename = source.filename, .json = result };
}

test "shipped catalogue is stable, read-only and core-only by default" {
    const registry = try Registry.builtin();
    try std.testing.expectEqual(@as(usize, assets.sources.len), registry.len);
    var default_count: usize = 0;
    for (registry.view(), 0..) |m, i| {
        if (m.enabled_by_default) default_count += 1;
        if (i > 0) try std.testing.expect(std.mem.order(u8, registry.entries[i - 1].id.slice(), m.id.slice()) == .lt);
        try std.testing.expect(m.resources.peak_extra_memory_bytes == null);
        try std.testing.expect(m.resources.steady_disk_bytes == null);
        try std.testing.expectEqual(manifest.Provenance.unmeasured, m.resources.provenance);
    }
    try std.testing.expectEqual(@as(usize, 1), default_count);
    const core = registry.index(try manifest.Id.parse("ad-core")).?;
    const member = registry.index(try manifest.Id.parse("member-server")).?;
    try std.testing.expectEqual(bit(core), registry.closure[member]);
    try std.testing.expect(!registry.find(try manifest.Id.parse("directory-fixtures")).?.lifecycle.can_stop);
    try std.testing.expectEqual(manifest.Availability.planned, registry.entries[member].provisioner.availability());
}

test "invalid schema, duplicate fields and execution hooks cannot be loaded" {
    const core = fixture("ad-core.json");
    var buffer: [manifest.max_manifest_bytes]u8 = undefined;
    try std.testing.expectError(error.UnknownProvisioner, manifest.parse((try edited("windows-core-v1", "shell-script", core, &buffer)).json));
    try std.testing.expectError(error.InvalidResources, manifest.parse((try edited("2147483648", "\"2147483648\"", core, &buffer)).json));
    try std.testing.expectError(error.InvalidResources, manifest.parse((try edited("2147483648", "2147483648.5", core, &buffer)).json));
    try std.testing.expectError(error.InvalidResources, manifest.parse((try edited("2147483648", "17592186044417", core, &buffer)).json));
    try std.testing.expectError(error.InvalidManifest, manifest.parse((try edited("\"schema_version\": 1", "\"schema_version\": 1, \"schema_version\": 1", core, &buffer)).json));
    try std.testing.expectError(error.UnknownField, manifest.parse((try edited("\"schema_version\": 1", "\"schema_version\": 1, \"script\": \"run.exe\"", core, &buffer)).json));
    try std.testing.expectError(error.InvalidFilename, Registry.fromSources(&.{.{ .filename = "../ad-core.json", .json = core.json }}));
    try std.testing.expectError(error.DuplicateModule, Registry.fromSources(&.{ core, core }));
}

test "unknown dependency, optional defaults, cycles and conflicts are rejected" {
    const core = fixture("ad-core.json");
    const member = fixture("member-server.json");
    const second = fixture("second-dc.json");
    var a: [manifest.max_manifest_bytes]u8 = undefined;
    var b: [manifest.max_manifest_bytes]u8 = undefined;
    const missing = try edited("\"ad-core\"", "\"missing\"", member, &a);
    try std.testing.expectError(error.UnknownDependency, Registry.fromSources(&.{ core, missing }));
    const default = try edited("\"enabled_by_default\": false", "\"enabled_by_default\": true", member, &a);
    try std.testing.expectError(error.InvalidDefault, Registry.fromSources(&.{ core, default }));
    const first = try edited("\"ad-core\"", "\"second-dc\"", member, &a);
    const back = try edited("\"ad-core\"", "\"member-server\"", second, &b);
    try std.testing.expectError(error.Cycle, Registry.fromSources(&.{ core, first, back }));
    const conflicted = try edited("\"conflicts\": []", "\"conflicts\": [\"ad-core\"]", member, &a);
    try std.testing.expectError(error.Conflict, Registry.fromSources(&.{ core, conflicted }));
    const self = try edited("\"ad-core\"", "\"member-server\"", member, &a);
    try std.testing.expectError(error.Cycle, Registry.fromSources(&.{ core, self }));
}

test "bounded malformed input mutation smoke, no external execution" {
    const core = fixture("ad-core.json");
    var bytes: [manifest.max_manifest_bytes]u8 = undefined;
    // A deterministic byte-mutation corpus, not a claim of exhaustive fuzzing.
    var i: usize = 0;
    while (i < core.json.len) : (i += 13) {
        @memcpy(bytes[0..core.json.len], core.json);
        bytes[i] = 0xff;
        try std.testing.expectError(error.InvalidManifest, manifest.parse(bytes[0..core.json.len]));
    }
    for (0..@min(core.json.len, 80)) |n| {
        if (manifest.parse(core.json[0..n])) |_| return error.TruncatedInputAccepted else |_| {}
    }
}
