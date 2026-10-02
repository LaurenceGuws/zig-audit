//! Builds and verifies the zig-audit command-line checker.

const std = @import("std");

/// Defines zig-audit build, test, and self-audit steps.
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

    const run_tests = b.addRunArtifact(tests);

    const cli_contract = b.addSystemCommand(&.{"python3"});
    cli_contract.addFileArg(b.path("tests/cli.py"));
    cli_contract.addArtifactArg(executable);
    cli_contract.setName("zig-audit CLI contract");

    const check = b.step("check", "Compile, test, and audit zig-audit");
    check.dependOn(&executable.step);
    check.dependOn(&run_tests.step);
    check.dependOn(&cli_contract.step);

    const audit = b.addRunArtifact(executable);
    audit.addArg("check");
    audit.setCwd(b.path("."));
    check.dependOn(&audit.step);

    const test_step = b.step("test", "Run zig-audit tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&cli_contract.step);
}
