//! Builds the experimental Zig sensitive-source indexer.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const self_hosted = target.result.cpu.arch == .x86_64;

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const executable = b.addExecutable(.{
        .name = "zig-audit",
        .root_module = module,
        .use_llvm = !self_hosted,
        .use_lld = !self_hosted,
    });
    b.installArtifact(executable);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = !self_hosted,
        .use_lld = !self_hosted,
    });

    const check = b.step("check", "Compile, test, and audit zig-audit");
    check.dependOn(&executable.step);
    check.dependOn(&tests.step);

    const audit = b.addRunArtifact(executable);
    audit.addArg("check");
    audit.setCwd(b.path("."));
    check.dependOn(&audit.step);

    const test_step = b.step("test", "Run zig-audit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
