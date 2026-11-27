const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (!std.mem.eql(u8, builtin.zig_version_string, "0.14.1"))
        @compileError("NanoAD bootstrap requires Zig 0.14.1; see tests/cli/README.md");
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimisation mode") orelse .ReleaseSafe;
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
    const provider_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/provider_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_provider_tests = b.addRunArtifact(provider_tests);
    test_step.dependOn(&run_provider_tests.step);

    const lock_harness = b.addExecutable(.{
        .name = "state-lock-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/state_lock_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (target.result.os.tag == .windows) lock_harness.root_module.linkSystemLibrary("kernel32", .{});
    const run_lock_harness = b.addRunArtifact(lock_harness);
    test_step.dependOn(&run_lock_harness.step);

    if (target.result.os.tag == .windows and target.result.cpu.arch == .x86_64) {
        const child = b.addExecutable(.{
            .name = "VBoxManage",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/provider/virtualbox/test_child.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const harness_module = b.createModule(.{
            .root_source_file = b.path("src/native_transport_tests.zig"),
            .target = target,
            .optimize = optimize,
        });
        harness_module.linkSystemLibrary("kernel32", .{});
        const harness = b.addExecutable(.{
            .name = "native-transport-tests",
            .root_module = harness_module,
        });
        const run_harness = b.addRunArtifact(harness);
        run_harness.addArtifactArg(child);
        test_step.dependOn(&run_harness.step);
    }
}

fn module(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const result = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = target.result.os.tag == .linux,
        .strip = optimize != .Debug,
    });
    result.addImport("manifest_assets", b.createModule(.{
        .root_source_file = b.path("modules/embedded.zig"),
        .target = target,
        .optimize = optimize,
    }));
    if (target.result.os.tag == .windows) result.linkSystemLibrary("kernel32", .{});
    return result;
}
