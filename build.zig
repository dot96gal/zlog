const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zlog", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // examples/basic
    const example_basic = b.addExecutable(.{
        .name = "basic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/basic.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zlog", .module = mod },
            },
        }),
    });
    b.installArtifact(example_basic);

    const run_basic = b.addRunArtifact(example_basic);
    run_basic.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the basic example");
    run_step.dependOn(&run_basic.step);

    // tests
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    // docs
    const docs_obj = b.addObject(.{
        .name = "zlog",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    const docs_step = b.step("docs", "Build API documentation");
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    docs_step.dependOn(&install_docs.step);
}
