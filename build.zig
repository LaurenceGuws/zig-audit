//! Builds and verifies the zig-audit command-line checker.

const std = @import("std");

/// Defines zig-audit build, test, and self-audit steps.
pub fn build(b: *std.Build) void {
    // Distribution is one portable executable per architecture, never the builder's native ISA.
    const default_target: std.Target.Query = if (@import("builtin").target.cpu.arch == .x86_64)
        .{ .cpu_model = .baseline }
    else
        .{};
    const target = b.standardTargetOptions(.{ .default_target = default_target });
    const optimize = b.standardOptimizeOption(.{});
    if (target.result.cpu.arch == .x86_64 and optimize != .debug) {
        const portable_cpu = switch (target.query.cpu_model) {
            .baseline => true,
            .determined_by_arch_os => target.query.cpu_arch != null,
            else => false,
        };
        if (!portable_cpu or !target.query.cpu_features_add.isEmpty()) {
            // zig-audit: acknowledge panic
            // reason: A release artifact targeting native builder CPU features can SIGILL on another Fleet node.
            @panic("zig-audit release requires baseline x86_64 CPU; use -Dcpu=baseline");
        }
    }
    const strip = b.option(bool, "strip", "Strip executable debug information") orelse false;
    const self_hosted = target.result.cpu.arch == .x86_64;

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
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

    const install_contract = b.addSystemCommand(&.{"python3"});
    install_contract.addFileArg(b.path("tests/install.py"));
    install_contract.setName("zig-audit package/install lifecycle");

    const check = b.step("check", "Compile, test, and audit zig-audit");
    check.dependOn(&executable.step);
    check.dependOn(&run_tests.step);
    check.dependOn(&cli_contract.step);
    check.dependOn(&install_contract.step);

    const audit = b.addRunArtifact(executable);
    audit.addArg("check");
    audit.setCwd(b.path("."));
    check.dependOn(&audit.step);

    const test_step = b.step("test", "Run zig-audit tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&cli_contract.step);
    test_step.dependOn(&install_contract.step);
}
