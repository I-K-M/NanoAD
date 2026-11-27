const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (!std.mem.eql(u8, builtin.zig_version_string, "0.14.1"))
        @compileError("NanoAD bootstrap requires Zig 0.14.1; see tests/cli/README.md");
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    const exe = b.addExecutable(.{
        .name = "nanoad",
        .root_module = module(b, target, optimize),
    });
    b.installArtifact(exe);

    const unit_tests = b.addTest(.{
        .root_module = module(b, target, optimize),
    });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run NanoAD unit tests");
    test_step.dependOn(&run_tests.step);
}

fn module(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const result = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = target.result.os.tag == .linux,
        .strip = optimize != .Debug,
    });
    if (target.result.os.tag == .windows) result.linkSystemLibrary("kernel32", .{});
    return result;
}
