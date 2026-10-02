//! Implements the zig-audit CLI and tokenizer-based Zig source policy checker.

const std = @import("std");

const Allocator = std.mem.Allocator;

const Kind = enum {
    align_cast,
    allow_zero,
    any_error,
    any_opaque,
    any_type,
    catch_unreachable,
    const_cast,
    debug_assert,
    discard,
    empty_catch,
    opaque_type,
    orelse_unreachable,
    panic,
    ptr_cast,
    ptr_from_int,
    pub_without_doc,
    runtime_safety_off,
    saturating_add_mul,
    unreachable_site,

    fn name(self: Kind) []const u8 {
        return switch (self) {
            .align_cast => "align_cast",
            .allow_zero => "allowzero",
            .any_error => "anyerror",
            .any_opaque => "anyopaque",
            .any_type => "anytype",
            .catch_unreachable => "catch_unreachable",
            .const_cast => "const_cast",
            .debug_assert => "debug_assert",
            .discard => "discard",
            .empty_catch => "empty_catch",
            .opaque_type => "opaque_type",
            .orelse_unreachable => "orelse_unreachable",
            .panic => "panic",
            .ptr_cast => "ptr_cast",
            .ptr_from_int => "ptr_from_int",
            .pub_without_doc => "pub_without_doc",
            .runtime_safety_off => "runtime_safety_off",
            .saturating_add_mul => "saturating_add_mul",
            .unreachable_site => "unreachable",
        };
    }

    fn fromName(text: []const u8) ?Kind {
        inline for (std.meta.tags(Kind)) |kind| {
            if (std.mem.eql(u8, kind.name(), text)) return kind;
        }
        return null;
    }
};

const Finding = struct {
    path: []const u8,
    kind: Kind,
    line: []const u8,
    line_number: usize,
};

const Token = struct {
    tag: std.zig.Token.Tag,
    text: []const u8,
    start: usize,
};

const AcknowledgementProblem = enum {
    none,
    unknown_kind,
    missing_reason,
    empty_reason,
};

const Acknowledgement = struct {
    marker_line: usize,
    target_line: usize,
    kind_text: []const u8,
    kind: ?Kind,
    reason: []const u8,
    problem: AcknowledgementProblem,
};

const AcknowledgementResolution = enum {
    acknowledged,
    stale,
    wrong_rule,
    unknown_kind,
    missing_reason,
    empty_reason,
    not_acknowledgeable,
};

const Config = struct {
    schema: u32,
    source: Source,
    baseline: ?[]const u8 = null,
    minimum_ruleset: u32 = 1,
    include: []const []const u8 = &.{},
    exclude: []const []const u8 = &.{},

    const Source = enum {
        git,
    };
};

const Project = struct {
    config: Config,
    config_path: []const u8,
    root_path: []const u8,
};

const version = "0.4.0";
const stable_ruleset: u32 = 3;
const current_config_schema: u32 = 2;
const legacy_config_schema: u32 = 1;
const default_config_path = ".zig-audit.json";

const CheckOptions = struct {
    config_path: []const u8 = default_config_path,
    verbose: bool = false,
};

const AcceptOptions = struct {
    config_path: []const u8 = default_config_path,
};

const HelpTopic = enum {
    root,
    check,
    scan,
    accept,
    version,
};

const Command = union(enum) {
    help: HelpTopic,
    version,
    scan: []const []const u8,
    check: CheckOptions,
    accept: AcceptOptions,
};

const CliFailure = struct {
    message: []const u8,
    argument: ?[]const u8 = null,
};

const ParseResult = union(enum) {
    command: Command,
    failure: CliFailure,
};

const CheckSummary = struct {
    acknowledged: usize = 0,
    files_checked: usize = 0,
};

/// Runs the zig-audit command-line checker.
pub fn main(init: std.process.Init) void {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch |failure| {
        emitFailure(init.io, failure);
        std.process.exit(2);
    };

    const parsed = parseCommand(if (args.len > 1) args[1..] else &.{});
    const command = switch (parsed) {
        .command => |value| value,
        .failure => |failure| {
            emitCliFailure(init.io, failure);
            std.process.exit(2);
        },
    };

    dispatch(init, command) catch |failure| {
        if (failure == error.AuditFailed or failure == error.CensusChanged)
            std.process.exit(1);
        if (failure != error.Reported) emitFailure(init.io, failure);
        std.process.exit(2);
    };
}

// zig-audit: acknowledge anyerror
// reason: The top-level CLI boundary must format any command failure before process exit.
fn emitFailure(io: std.Io, failure: anyerror) void {
    const message = switch (failure) {
        error.InvalidConfig => "project config is malformed or contains unsupported fields",
        error.UnsupportedConfigSchema => "project config schema is newer or unsupported",
        error.CheckerRulesetTooOld => "checker stable ruleset is older than the project minimum; upgrade zig-audit",
        error.BaselineUnavailable => "legacy reviewed baseline is unavailable",
        error.LegacyBaselineRequired => "schema 1 requires a baseline path",
        error.SourceAcknowledgementsRequired => "schema 2 uses source-local acknowledgements; accept is not available",
        error.SourceDiscoveryFailed => "configured source discovery failed",
        error.AuditFailed => "source acknowledgement check failed",
        else => @errorName(failure),
    };
    var buffer: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(io, &buffer);
    std.json.Stringify.value(.{
        .schema = "zig-audit.error/v1",
        .ok = false,
        .@"error" = .{
            .code = @errorName(failure),
            .message = message,
        },
    }, .{}, &stderr.interface) catch return;
    stderr.interface.writeByte('\n') catch return;
    stderr.interface.flush() catch return;
}

fn emitCliFailure(io: std.Io, failure: CliFailure) void {
    var buffer: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(io, &buffer);
    std.json.Stringify.value(.{
        .schema = "zig-audit.error/v1",
        .ok = false,
        .@"error" = .{
            .code = "Usage",
            .message = failure.message,
            .argument = failure.argument,
            .hint = "run zig-audit --help",
        },
    }, .{ .emit_null_optional_fields = false }, &stderr.interface) catch return;
    stderr.interface.writeByte('\n') catch return;
    stderr.interface.flush() catch return;
}

fn emitPathFailure(io: std.Io, code: []const u8, message: []const u8, path: []const u8) void {
    var buffer: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(io, &buffer);
    std.json.Stringify.value(.{
        .schema = "zig-audit.error/v1",
        .ok = false,
        .@"error" = .{
            .code = code,
            .message = message,
            .path = path,
        },
    }, .{}, &stderr.interface) catch return;
    stderr.interface.writeByte('\n') catch return;
    stderr.interface.flush() catch return;
}

fn parseCommand(args: []const []const u8) ParseResult {
    if (args.len == 0) return .{ .command = .{ .help = .root } };

    const first = args[0];
    if (std.mem.eql(u8, first, "-h") or std.mem.eql(u8, first, "--help")) {
        if (args.len != 1) return usage("global help takes no arguments", args[1]);
        return .{ .command = .{ .help = .root } };
    }
    if (std.mem.eql(u8, first, "help")) {
        if (args.len == 1) return .{ .command = .{ .help = .root } };
        if (args.len != 2) return usage("help accepts at most one command name", args[2]);
        const topic = helpTopic(args[1]) orelse return usage("unknown help topic", args[1]);
        return .{ .command = .{ .help = topic } };
    }
    if (std.mem.eql(u8, first, "version") or
        std.mem.eql(u8, first, "--version") or
        std.mem.eql(u8, first, "-v"))
    {
        if (args.len == 2 and (std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help")))
            return .{ .command = .{ .help = .version } };
        if (args.len != 1) return usage("version takes no arguments", args[1]);
        return .{ .command = .version };
    }
    if (std.mem.eql(u8, first, "check")) return parseCheckCommand(args[1..]);
    if (std.mem.eql(u8, first, "scan")) return parseScanCommand(args[1..]);
    if (std.mem.eql(u8, first, "accept")) return parseAcceptCommand(args[1..]);
    if (std.mem.startsWith(u8, first, "-")) return usage("unknown global option", first);
    return usage("unknown command", first);
}

fn usage(message: []const u8, argument: []const u8) ParseResult {
    return .{ .failure = .{ .message = message, .argument = argument } };
}

fn helpTopic(name: []const u8) ?HelpTopic {
    if (std.mem.eql(u8, name, "check")) return .check;
    if (std.mem.eql(u8, name, "scan")) return .scan;
    if (std.mem.eql(u8, name, "accept")) return .accept;
    if (std.mem.eql(u8, name, "version")) return .version;
    return null;
}

fn parseCheckCommand(args: []const []const u8) ParseResult {
    if (args.len == 1 and (std.mem.eql(u8, args[0], "-h") or std.mem.eql(u8, args[0], "--help")))
        return .{ .command = .{ .help = .check } };

    var options = CheckOptions{};
    var config_seen = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            if (options.verbose) return usage("verbose option specified more than once", arg);
            options.verbose = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--config")) {
            if (config_seen) return usage("config option specified more than once", arg);
            if (index + 1 >= args.len) return usage("--config requires a path", arg);
            index += 1;
            options.config_path = args[index];
            config_seen = true;
            continue;
        }
        return usage("unknown check option or positional argument", arg);
    }
    return .{ .command = .{ .check = options } };
}

fn parseAcceptCommand(args: []const []const u8) ParseResult {
    if (args.len == 1 and (std.mem.eql(u8, args[0], "-h") or std.mem.eql(u8, args[0], "--help")))
        return .{ .command = .{ .help = .accept } };

    var options = AcceptOptions{};
    var config_seen = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--config")) {
            if (config_seen) return usage("config option specified more than once", arg);
            if (index + 1 >= args.len) return usage("--config requires a path", arg);
            index += 1;
            options.config_path = args[index];
            config_seen = true;
            continue;
        }
        return usage("unknown accept option or positional argument", arg);
    }
    return .{ .command = .{ .accept = options } };
}

fn parseScanCommand(args: []const []const u8) ParseResult {
    if (args.len == 1 and (std.mem.eql(u8, args[0], "-h") or std.mem.eql(u8, args[0], "--help")))
        return .{ .command = .{ .help = .scan } };

    if (args.len == 0) return usage("scan requires at least one Zig file or directory", "scan");
    if (std.mem.eql(u8, args[0], "--")) {
        if (args.len == 1) return usage("scan requires at least one Zig file or directory", "scan");
        return .{ .command = .{ .scan = args[1..] } };
    }
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--"))
            return usage("place '--' immediately after scan when using dash-prefixed paths", arg);
        if (std.mem.startsWith(u8, arg, "-"))
            return usage("scan paths beginning with '-' require '--'", arg);
    }
    return .{ .command = .{ .scan = args } };
}

fn dispatch(init: std.process.Init, command: Command) !void {
    switch (command) {
        .help => |topic| try writeHelp(init.io, topic),
        .version => try writeVersion(init.io),
        .scan => |paths| {
            const findings = try scanPaths(init, paths);
            try writeFindings(init.io, findings);
        },
        .check => |options| checkProject(init, options) catch |failure| {
            switch (failure) {
                error.ConfigNotFound => emitPathFailure(init.io, "ConfigNotFound", "project config was not found", options.config_path),
                error.InvalidConfig => emitPathFailure(init.io, "InvalidConfig", "project config is malformed or contains unsupported fields", options.config_path),
                error.UnsupportedConfigSchema => emitPathFailure(init.io, "UnsupportedConfigSchema", "project config schema is newer or unsupported", options.config_path),
                error.CheckerRulesetTooOld => emitPathFailure(init.io, "CheckerRulesetTooOld", "checker stable ruleset is older than the project minimum; upgrade zig-audit", options.config_path),
                error.LegacyBaselineRequired => emitPathFailure(init.io, "LegacyBaselineRequired", "schema 1 requires a baseline path", options.config_path),
                else => return failure,
            }
            return error.Reported;
        },
        .accept => |options| acceptProject(init, options.config_path) catch |failure| {
            switch (failure) {
                error.ConfigNotFound => emitPathFailure(init.io, "ConfigNotFound", "project config was not found", options.config_path),
                error.InvalidConfig => emitPathFailure(init.io, "InvalidConfig", "project config is malformed or contains unsupported fields", options.config_path),
                error.UnsupportedConfigSchema => emitPathFailure(init.io, "UnsupportedConfigSchema", "project config schema is newer or unsupported", options.config_path),
                error.CheckerRulesetTooOld => emitPathFailure(init.io, "CheckerRulesetTooOld", "checker stable ruleset is older than the project minimum; upgrade zig-audit", options.config_path),
                error.LegacyBaselineRequired => emitPathFailure(init.io, "LegacyBaselineRequired", "schema 1 requires a baseline path", options.config_path),
                error.SourceAcknowledgementsRequired => emitPathFailure(init.io, "SourceAcknowledgementsRequired", "schema 2 uses source-local acknowledgements; accept is not available", options.config_path),
                else => return failure,
            }
            return error.Reported;
        },
    }
}

fn scanPaths(init: std.process.Init, paths: []const []const u8) ![]Finding {
    var findings: std.ArrayList(Finding) = .empty;
    for (paths) |path| {
        scanPath(init.io, init.gpa, init.arena.allocator(), path, &findings) catch |failure| {
            if (failure == error.FileNotFound) {
                emitPathFailure(init.io, "PathNotFound", "scan path was not found", path);
                return error.Reported;
            }
            return failure;
        };
    }
    std.mem.sort(Finding, findings.items, {}, lessThan);
    return findings.toOwnedSlice(init.arena.allocator());
}

fn writeFindings(io: std.Io, findings: []const Finding) !void {
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    for (findings) |finding| {
        try std.json.Stringify.value(.{
            .schema = "zig-audit.scan/v1",
            .path = finding.path,
            .line = finding.line_number,
            .kind = finding.kind.name(),
            .source = finding.line,
        }, .{}, &stdout.interface);
        try stdout.interface.writeByte('\n');
    }
    try stdout.interface.flush();
}

fn writeVersion(io: std.Io) !void {
    var buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    try std.json.Stringify.value(.{
        .schema = "zig-audit.version/v1",
        .version = version,
        .stable_ruleset = stable_ruleset,
    }, .{}, &stdout.interface);
    try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
}

fn writeHelp(io: std.Io, topic: HelpTopic) !void {
    const text = switch (topic) {
        .root =>
        \\zig-audit - tokenizer-based Zig source policy checker
        \\
        \\Usage:
        \\  zig-audit check [--config PATH] [-v|--verbose]
        \\  zig-audit scan [--] PATH...
        \\  zig-audit accept [--config PATH]
        \\  zig-audit version
        \\  zig-audit help [COMMAND]
        \\
        \\Global options:
        \\  -h, --help       Show help.
        \\  -v, --version    Emit machine-readable version information.
        \\
        \\Exit status:
        \\  0  Command completed successfully; check is clean.
        \\  1  Source policy check failed.
        \\  2  Usage, configuration, I/O, or tool failure.
        \\
        \\Run `zig-audit help COMMAND` for command-specific help.
        \\
        ,
        .check =>
        \\Usage: zig-audit check [--config PATH] [-v|--verbose]
        \\
        \\Audit the Git-owned Zig sources selected by project configuration.
        \\The config file's parent directory is the project root. Git discovery,
        \\source reads, include/exclude roots, and legacy baseline paths are all
        \\resolved relative to that root, not the caller's working directory.
        \\
        \\Options:
        \\  --config PATH    Project config. Default: .zig-audit.json
        \\  -v, --verbose    Emit accepted acknowledgement records before summary.
        \\  -h, --help       Show this help.
        \\
        \\Output is newline-delimited JSON on stdout. Tool errors are JSON on stderr.
        \\
        ,
        .scan =>
        \\Usage: zig-audit scan [--] PATH...
        \\
        \\Explore Zig files or directories without project-policy enforcement.
        \\Paths are interpreted relative to the caller's working directory.
        \\Use `--` immediately after `scan` for a path beginning with '-'.
        \\
        \\Output is one zig-audit.scan/v1 JSON record per finding on stdout.
        \\
        ,
        .accept =>
        \\Usage: zig-audit accept [--config PATH]
        \\
        \\Legacy schema-1 migration command. It rewrites the configured reviewed
        \\baseline atomically. Schema 2 uses source-local acknowledgements and rejects
        \\this command.
        \\
        \\Options:
        \\  --config PATH    Project config. Default: .zig-audit.json
        \\  -h, --help       Show this help.
        \\
        ,
        .version =>
        \\Usage: zig-audit version
        \\       zig-audit --version
        \\       zig-audit -v
        \\
        \\Emit zig-audit.version/v1 JSON with checker version and stable ruleset.
        \\
        ,
    };
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    try stdout.interface.writeAll(text);
    try stdout.interface.flush();
}

fn legacyBaselineKind(kind: Kind) bool {
    return switch (kind) {
        .any_error, .any_opaque, .any_type, .discard => true,
        else => false,
    };
}

fn enforcedKind(kind: Kind) bool {
    return switch (kind) {
        .debug_assert, .saturating_add_mul => false,
        else => true,
    };
}

fn acknowledgeableKind(kind: Kind) bool {
    return kind != .pub_without_doc;
}

fn loadConfig(init: std.process.Init, path: []const u8) !Config {
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        init.io,
        path,
        init.arena.allocator(),
        .limited(64 * 1024),
    ) catch |failure| switch (failure) {
        error.FileNotFound => return error.ConfigNotFound,
        else => return failure,
    };
    var parsed = std.json.parseFromSlice(
        Config,
        init.arena.allocator(),
        bytes,
        .{ .ignore_unknown_fields = false },
    ) catch return error.InvalidConfig;
    defer parsed.deinit();
    if (parsed.value.schema != legacy_config_schema and parsed.value.schema != current_config_schema)
        return error.UnsupportedConfigSchema;
    if (parsed.value.minimum_ruleset > stable_ruleset) return error.CheckerRulesetTooOld;
    if (parsed.value.schema == legacy_config_schema and parsed.value.baseline == null)
        return error.LegacyBaselineRequired;
    if (parsed.value.schema == current_config_schema and parsed.value.baseline != null)
        return error.InvalidConfig;
    return .{
        .schema = parsed.value.schema,
        .source = parsed.value.source,
        .baseline = if (parsed.value.baseline) |value|
            try init.arena.allocator().dupe(u8, value)
        else
            null,
        .minimum_ruleset = parsed.value.minimum_ruleset,
        .include = try dupeStrings(init.arena.allocator(), parsed.value.include),
        .exclude = try dupeStrings(init.arena.allocator(), parsed.value.exclude),
    };
}

fn loadProject(init: std.process.Init, config_path: []const u8) !Project {
    const root = std.fs.path.dirname(config_path) orelse ".";
    return .{
        .config = try loadConfig(init, config_path),
        .config_path = try init.arena.allocator().dupe(u8, config_path),
        .root_path = try init.arena.allocator().dupe(u8, root),
    };
}

fn dupeStrings(allocator: Allocator, values: []const []const u8) ![]const []const u8 {
    const copy = try allocator.alloc([]const u8, values.len);
    for (values, 0..) |value, index| copy[index] = try allocator.dupe(u8, value);
    return copy;
}

fn projectPaths(init: std.process.Init, project: Project) ![]const []const u8 {
    return switch (project.config.source) {
        .git => blk: {
            const root_result = try std.process.run(init.gpa, init.io, .{
                .argv = &.{
                    "git",
                    "-C",
                    project.root_path,
                    "rev-parse",
                    "--show-prefix",
                },
                .stdout_limit = .limited(4096),
                .stderr_limit = .limited(64 * 1024),
            });
            defer init.gpa.free(root_result.stdout);
            defer init.gpa.free(root_result.stderr);
            const root_success = switch (root_result.term) {
                .exited => |code| code == 0,
                else => false,
            };
            if (!root_success) {
                emitPathFailure(init.io, "SourceDiscoveryFailed", "project root is not inside a Git worktree", project.root_path);
                return error.Reported;
            }
            if (std.mem.trim(u8, root_result.stdout, " \t\r\n").len != 0) {
                emitPathFailure(init.io, "ProjectRootMismatch", "config parent must be the Git worktree root, not a nested directory", project.root_path);
                return error.Reported;
            }

            const result = try std.process.run(init.gpa, init.io, .{
                .argv = &.{
                    "git",
                    "-C",
                    project.root_path,
                    "ls-files",
                    "--cached",
                    "--others",
                    "--exclude-standard",
                    "-z",
                    "--",
                    "*.zig",
                },
                .stdout_limit = .limited(16 * 1024 * 1024),
                .stderr_limit = .limited(64 * 1024),
            });
            defer init.gpa.free(result.stdout);
            defer init.gpa.free(result.stderr);
            const success = switch (result.term) {
                .exited => |code| code == 0,
                else => false,
            };
            if (!success) {
                emitPathFailure(init.io, "SourceDiscoveryFailed", "Git source discovery failed for project root", project.root_path);
                return error.Reported;
            }

            var paths: std.ArrayList([]const u8) = .empty;
            var it = std.mem.splitScalar(u8, result.stdout, 0);
            while (it.next()) |path| {
                if (path.len == 0 or !sourceSelected(project.config, path)) continue;
                try paths.append(init.arena.allocator(), try init.arena.allocator().dupe(u8, path));
            }
            break :blk try paths.toOwnedSlice(init.arena.allocator());
        },
    };
}

fn projectPath(allocator: Allocator, project: Project, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    return std.fs.path.join(allocator, &.{ project.root_path, path });
}

fn projectFindings(init: std.process.Init, project: Project) ![]Finding {
    const paths = try projectPaths(init, project);
    var findings: std.ArrayList(Finding) = .empty;
    for (paths) |path| {
        const access_path = try projectPath(init.arena.allocator(), project, path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            init.io,
            access_path,
            init.arena.allocator(),
            .limited(16 * 1024 * 1024),
        ) catch |failure| switch (failure) {
            error.FileNotFound => {
                emitPathFailure(init.io, "SourceNotFound", "configured source file disappeared during audit", access_path);
                return error.Reported;
            },
            else => return failure,
        };
        const source = try init.arena.allocator().dupeSentinel(u8, bytes, 0);
        try scanSource(init.arena.allocator(), path, source, &findings);
    }
    std.mem.sort(Finding, findings.items, {}, lessThan);
    return findings.toOwnedSlice(init.arena.allocator());
}

fn sourceSelected(config: Config, path: []const u8) bool {
    if (config.include.len != 0) {
        var included = false;
        for (config.include) |root| {
            if (pathUnder(root, path)) {
                included = true;
                break;
            }
        }
        if (!included) return false;
    }
    for (config.exclude) |root| {
        if (pathUnder(root, path)) return false;
    }
    return true;
}

fn pathUnder(root: []const u8, path: []const u8) bool {
    if (root.len == 0) return false;
    if (std.mem.eql(u8, root, path)) return true;
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (root[root.len - 1] == '/') return true;
    return path.len > root.len and path[root.len] == '/';
}

fn legacyCensus(init: std.process.Init, findings: []const Finding) ![]u8 {
    var output = try std.Io.Writer.Allocating.initCapacity(init.arena.allocator(), 4096);
    defer output.deinit();
    for (findings) |finding| {
        if (!legacyBaselineKind(finding.kind)) continue;
        try output.writer.print("{s}|{s}|{s}\n", .{
            finding.path,
            finding.kind.name(),
            finding.line,
        });
    }
    return try output.toOwnedSlice();
}

fn normalizeCensus(allocator: Allocator, bytes: []const u8) ![]u8 {
    var records: std.ArrayList([]const u8) = .empty;
    defer records.deinit(allocator);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try records.append(allocator, line);
    }
    std.mem.sort([]const u8, records.items, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.lessThan);

    var output = try std.Io.Writer.Allocating.initCapacity(allocator, bytes.len);
    defer output.deinit();
    for (records.items) |record| try output.writer.print("{s}\n", .{record});
    return try output.toOwnedSlice();
}

fn checkProject(init: std.process.Init, options: CheckOptions) !void {
    const project = try loadProject(init, options.config_path);
    if (project.config.schema == legacy_config_schema) return checkLegacyProject(init, project);
    return checkAcknowledgedProject(init, project, options.verbose);
}

fn checkLegacyProject(init: std.process.Init, project: Project) !void {
    const findings = try projectFindings(init, project);
    const actual = try legacyCensus(init, findings);
    const baseline_path = try projectPath(init.arena.allocator(), project, project.config.baseline.?);
    const expected = std.Io.Dir.cwd().readFileAlloc(
        init.io,
        baseline_path,
        init.arena.allocator(),
        .limited(16 * 1024 * 1024),
    ) catch |failure| switch (failure) {
        error.FileNotFound => {
            emitPathFailure(init.io, "BaselineUnavailable", "legacy reviewed baseline was not found", baseline_path);
            return error.Reported;
        },
        else => return failure,
    };
    const normalized_expected = try normalizeCensus(init.arena.allocator(), expected);
    if (std.mem.eql(u8, normalized_expected, actual)) {
        try writeLegacyCheckSummary(init.io, true);
        return;
    }

    try writeCensusDiff(init.io, normalized_expected, actual);
    try writeLegacyCheckSummary(init.io, false);
    return error.CensusChanged;
}

fn acceptProject(init: std.process.Init, config_path: []const u8) !void {
    const project = try loadProject(init, config_path);
    if (project.config.schema != legacy_config_schema) return error.SourceAcknowledgementsRequired;
    const findings = try projectFindings(init, project);
    const actual = try legacyCensus(init, findings);
    const baseline_path = try projectPath(init.arena.allocator(), project, project.config.baseline.?);
    try writeAtomic(init.io, init.arena.allocator(), baseline_path, actual);
    try writeAcceptResult(init.io, project);
}

fn checkAcknowledgedProject(init: std.process.Init, project: Project, verbose: bool) !void {
    const paths = try projectPaths(init, project);
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    var failed = false;
    var summary = CheckSummary{ .files_checked = paths.len };

    for (paths) |path| {
        const access_path = try projectPath(init.arena.allocator(), project, path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            init.io,
            access_path,
            init.arena.allocator(),
            .limited(16 * 1024 * 1024),
        ) catch |failure| switch (failure) {
            error.FileNotFound => {
                emitPathFailure(init.io, "SourceNotFound", "configured source file disappeared during audit", access_path);
                return error.Reported;
            },
            else => return failure,
        };
        const source = try init.arena.allocator().dupeSentinel(u8, bytes, 0);

        var findings: std.ArrayList(Finding) = .empty;
        try scanSource(init.arena.allocator(), path, source, &findings);

        const acknowledgements = try parseAcknowledgements(init.arena.allocator(), source);
        const matched = try init.arena.allocator().alloc(bool, findings.items.len);
        @memset(matched, false);
        const resolutions = try init.arena.allocator().alloc(AcknowledgementResolution, acknowledgements.len);
        resolveAcknowledgements(findings.items, acknowledgements, matched, resolutions);

        for (acknowledgements, resolutions) |ack, resolution| {
            switch (resolution) {
                .acknowledged => {
                    summary.acknowledged += 1;
                    if (verbose) try writeCheckAcknowledgement(
                        &stdout.interface,
                        path,
                        ack.target_line,
                        ack.kind.?.name(),
                        ack.reason,
                    );
                },
                .unknown_kind => {
                    failed = true;
                    try writeCheckFinding(
                        &stdout.interface,
                        path,
                        ack.marker_line,
                        ack.kind_text,
                        "acknowledgement names an unknown rule",
                        null,
                    );
                },
                .missing_reason => {
                    failed = true;
                    try writeCheckFinding(
                        &stdout.interface,
                        path,
                        ack.marker_line,
                        ack.kind_text,
                        "acknowledgement requires an adjacent // reason: line",
                        null,
                    );
                },
                .empty_reason => {
                    failed = true;
                    try writeCheckFinding(
                        &stdout.interface,
                        path,
                        ack.marker_line,
                        ack.kind_text,
                        "acknowledgement reason is empty",
                        null,
                    );
                },
                .wrong_rule => {
                    failed = true;
                    try writeCheckFinding(
                        &stdout.interface,
                        path,
                        ack.marker_line,
                        ack.kind_text,
                        "acknowledgement names the wrong rule for its target source line",
                        null,
                    );
                },
                .stale => {
                    failed = true;
                    try writeCheckFinding(
                        &stdout.interface,
                        path,
                        ack.marker_line,
                        ack.kind_text,
                        "stale acknowledgement has no matching finding on its target source line",
                        null,
                    );
                },
                .not_acknowledgeable => {
                    failed = true;
                    try writeCheckFinding(
                        &stdout.interface,
                        path,
                        ack.marker_line,
                        ack.kind_text,
                        "this rule cannot be acknowledged; add /// documentation",
                        null,
                    );
                },
            }
        }

        for (findings.items, matched) |finding, acknowledged| {
            if (!enforcedKind(finding.kind) or acknowledged) continue;
            failed = true;
            if (finding.kind == .pub_without_doc) {
                try writeCheckFinding(
                    &stdout.interface,
                    path,
                    finding.line_number,
                    finding.kind.name(),
                    "public declaration requires /// documentation",
                    finding.line,
                );
            } else {
                try writeCheckFinding(
                    &stdout.interface,
                    path,
                    finding.line_number,
                    finding.kind.name(),
                    "acknowledgement required",
                    finding.line,
                );
            }
        }
    }

    try writeCheckSummary(&stdout.interface, summary, !failed);
    try stdout.interface.flush();
    if (failed) return error.AuditFailed;
}

fn writeCheckAcknowledgement(
    writer: *std.Io.Writer,
    path: []const u8,
    line: usize,
    rule: []const u8,
    reason: []const u8,
) !void {
    try std.json.Stringify.value(.{
        .schema = "zig-audit.check/v1",
        .type = "acknowledgement",
        .path = path,
        .line = line,
        .rule = rule,
        .reason = reason,
    }, .{}, writer);
    try writer.writeByte('\n');
}

fn writeCheckFinding(
    writer: *std.Io.Writer,
    path: []const u8,
    line: usize,
    rule: []const u8,
    message: []const u8,
    source: ?[]const u8,
) !void {
    try std.json.Stringify.value(.{
        .schema = "zig-audit.check/v1",
        .type = "finding",
        .path = path,
        .line = line,
        .rule = rule,
        .message = message,
        .source = source,
    }, .{ .emit_null_optional_fields = false }, writer);
    try writer.writeByte('\n');
}

fn writeCheckSummary(writer: *std.Io.Writer, summary: CheckSummary, passed: bool) !void {
    try std.json.Stringify.value(.{
        .schema = "zig-audit.check/v1",
        .type = "summary",
        .result = if (passed) "pass" else "fail",
        .acknowledged = summary.acknowledged,
        .files_checked = summary.files_checked,
    }, .{}, writer);
    try writer.writeByte('\n');
}

fn writeAcceptResult(io: std.Io, project: Project) !void {
    var buffer: [512]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    try std.json.Stringify.value(.{
        .schema = "zig-audit.accept/v1",
        .ok = true,
        .config = project.config_path,
        .baseline = project.config.baseline.?,
    }, .{}, &stdout.interface);
    try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
}

fn parseAcknowledgements(allocator: Allocator, source: []const u8) ![]Acknowledgement {
    const marker_prefix = "// zig-audit: acknowledge ";
    const reason_prefix = "// reason:";

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    var line_iterator = std.mem.splitScalar(u8, source, '\n');
    while (line_iterator.next()) |line| try lines.append(allocator, line);

    var result: std.ArrayList(Acknowledgement) = .empty;
    var index: usize = 0;
    while (index < lines.items.len) {
        const trimmed = std.mem.trim(u8, lines.items[index], " \t\r");
        if (!std.mem.startsWith(u8, trimmed, marker_prefix)) {
            index += 1;
            continue;
        }

        const group_start = result.items.len;
        while (index < lines.items.len) {
            const marker = std.mem.trim(u8, lines.items[index], " \t\r");
            if (!std.mem.startsWith(u8, marker, marker_prefix)) break;

            const kind_text = std.mem.trim(u8, marker[marker_prefix.len..], " \t\r");
            var acknowledgement = Acknowledgement{
                .marker_line = index + 1,
                .target_line = 0,
                .kind_text = kind_text,
                .kind = Kind.fromName(kind_text),
                .reason = "",
                .problem = if (Kind.fromName(kind_text) == null) .unknown_kind else .none,
            };

            if (index + 1 >= lines.items.len) {
                acknowledgement.problem = .missing_reason;
                index += 1;
            } else {
                const reason_line = std.mem.trim(u8, lines.items[index + 1], " \t\r");
                if (!std.mem.startsWith(u8, reason_line, reason_prefix)) {
                    acknowledgement.problem = .missing_reason;
                    index += 1;
                } else {
                    acknowledgement.reason = std.mem.trim(
                        u8,
                        reason_line[reason_prefix.len..],
                        " \t\r",
                    );
                    if (acknowledgement.reason.len == 0) acknowledgement.problem = .empty_reason;
                    index += 2;
                }
            }
            try result.append(allocator, acknowledgement);
        }

        var target = index;
        while (target < lines.items.len and
            std.mem.trim(u8, lines.items[target], " \t\r").len == 0)
        {
            target += 1;
        }
        const target_line = target + 1;
        for (result.items[group_start..]) |*acknowledgement| {
            acknowledgement.target_line = target_line;
        }
        index = target;
    }
    return result.toOwnedSlice(allocator);
}

fn resolveAcknowledgements(
    findings: []const Finding,
    acknowledgements: []const Acknowledgement,
    matched: []bool,
    resolutions: []AcknowledgementResolution,
) void {
    std.debug.assert(matched.len == findings.len);
    std.debug.assert(resolutions.len == acknowledgements.len);

    for (acknowledgements, resolutions) |ack, *resolution| {
        resolution.* = switch (ack.problem) {
            .unknown_kind => .unknown_kind,
            .missing_reason => .missing_reason,
            .empty_reason => .empty_reason,
            .none => blk: {
                if (!acknowledgeableKind(ack.kind.?)) {
                    for (findings, matched, 0..) |finding, acknowledged, index| {
                        if (acknowledged or finding.line_number != ack.target_line) continue;
                        if (finding.kind == ack.kind.?) {
                            matched[index] = true;
                            break;
                        }
                    }
                    break :blk .not_acknowledgeable;
                }
                var other_unmatched = false;
                for (findings, matched, 0..) |finding, acknowledged, index| {
                    if (!enforcedKind(finding.kind) or finding.line_number != ack.target_line or acknowledged)
                        continue;
                    if (finding.kind == ack.kind.?) {
                        matched[index] = true;
                        break :blk .acknowledged;
                    }
                    other_unmatched = true;
                }
                break :blk if (other_unmatched) .wrong_rule else .stale;
            },
        };
    }
}

fn writeCensusDiff(io: std.Io, expected: []const u8, actual: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);

    var old = std.mem.splitScalar(u8, expected, '\n');
    var new = std.mem.splitScalar(u8, actual, '\n');
    var old_line = nextLine(&old);
    var new_line = nextLine(&new);
    while (old_line != null or new_line != null) {
        if (old_line == null) {
            try writeLegacyChange(&stdout.interface, "added", new_line.?);
            new_line = nextLine(&new);
            continue;
        }
        if (new_line == null) {
            try writeLegacyChange(&stdout.interface, "removed", old_line.?);
            old_line = nextLine(&old);
            continue;
        }
        switch (std.mem.order(u8, old_line.?, new_line.?)) {
            .eq => {
                old_line = nextLine(&old);
                new_line = nextLine(&new);
            },
            .lt => {
                try writeLegacyChange(&stdout.interface, "removed", old_line.?);
                old_line = nextLine(&old);
            },
            .gt => {
                try writeLegacyChange(&stdout.interface, "added", new_line.?);
                new_line = nextLine(&new);
            },
        }
    }
    try stdout.interface.flush();
}

fn writeLegacyChange(writer: *std.Io.Writer, change: []const u8, value: []const u8) !void {
    try std.json.Stringify.value(.{
        .schema = "zig-audit.check/v1",
        .type = "legacy_census_change",
        .change = change,
        .value = value,
    }, .{}, writer);
    try writer.writeByte('\n');
}

fn writeLegacyCheckSummary(io: std.Io, passed: bool) !void {
    var buffer: [512]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    try std.json.Stringify.value(.{
        .schema = "zig-audit.check/v1",
        .type = "summary",
        .result = if (passed) "pass" else "fail",
        .legacy_schema = legacy_config_schema,
    }, .{}, &stdout.interface);
    try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
}

fn nextLine(lines: *std.mem.SplitIterator(u8, .scalar)) ?[]const u8 {
    while (lines.next()) |line| {
        if (line.len != 0) return line;
    }
    return null;
}

fn writeAtomic(io: std.Io, allocator: Allocator, path: []const u8, bytes: []const u8) !void {
    const parent_path = std.fs.path.dirname(path) orelse ".";
    const leaf = std.fs.path.basename(path);
    var parent = try std.Io.Dir.cwd().openDir(io, parent_path, .{ .iterate = true });
    defer parent.close(io);

    const temporary = try std.fmt.allocPrint(allocator, ".{s}.zig-audit.tmp", .{leaf});
    defer allocator.free(temporary);
    parent.deleteFile(io, temporary) catch |failure| switch (failure) {
        error.FileNotFound => {},
        else => return failure,
    };
    var file = try parent.createFile(io, temporary, .{ .truncate = true, .exclusive = true });
    var open = true;
    defer if (open) file.close(io);
    // zig-audit: acknowledge empty_catch
    // reason: Rollback cleanup is best-effort and must not replace the primary publication failure.
    errdefer parent.deleteFile(io, temporary) catch {};

    try file.writeStreamingAll(io, bytes);
    try file.sync(io);
    file.close(io);
    open = false;
    try parent.rename(temporary, parent, leaf, io);
}

fn lessThan(_: void, left: Finding, right: Finding) bool {
    const path_order = std.mem.order(u8, left.path, right.path);
    if (path_order != .eq) return path_order == .lt;
    const kind_order = std.mem.order(u8, left.kind.name(), right.kind.name());
    if (kind_order != .eq) return kind_order == .lt;
    return std.mem.order(u8, left.line, right.line) == .lt;
}

fn scanPath(
    io: std.Io,
    allocator: Allocator,
    arena: Allocator,
    path: []const u8,
    findings: *std.ArrayList(Finding),
) !void {
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    switch (stat.kind) {
        .file => {
            if (std.mem.endsWith(u8, path, ".zig")) {
                try scanFile(io, arena, path, findings);
            }
        },
        .directory => {
            var directory = try std.Io.Dir.cwd().openDir(io, path, .{
                .iterate = true,
                .follow_symlinks = false,
            });
            defer directory.close(io);

            var walker = try directory.walk(allocator);
            defer walker.deinit();
            while (try walker.next(io)) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
                if (ignored(entry.path)) continue;

                const display_path = if (std.mem.eql(u8, path, "."))
                    try arena.dupe(u8, entry.path)
                else
                    try std.fs.path.join(arena, &.{ path, entry.path });
                const bytes = try entry.dir.readFileAlloc(
                    io,
                    entry.basename,
                    arena,
                    .limited(16 * 1024 * 1024),
                );
                const source = try arena.dupeSentinel(u8, bytes, 0);
                try scanSource(arena, display_path, source, findings);
            }
        },
        else => {},
    }
}

fn ignored(path: []const u8) bool {
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".git") or
            std.mem.eql(u8, part, ".zig-cache") or
            std.mem.eql(u8, part, "zig-cache") or
            std.mem.eql(u8, part, "zig-out") or
            std.mem.eql(u8, part, "vendor"))
        {
            return true;
        }
    }
    return false;
}

fn scanFile(
    io: std.Io,
    arena: Allocator,
    path: []const u8,
    findings: *std.ArrayList(Finding),
) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        arena,
        .limited(16 * 1024 * 1024),
    );
    const source = try arena.dupeSentinel(u8, bytes, 0);
    try scanSource(arena, path, source, findings);
}

fn scanPublicDocumentation(
    allocator: Allocator,
    path: []const u8,
    source: [:0]const u8,
    findings: *std.ArrayList(Finding),
) !void {
    var tokenizer = std.zig.Tokenizer.init(source);
    var previous_tag: ?std.zig.Token.Tag = null;

    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        if (token.tag == .keyword_pub and previous_tag != .doc_comment) {
            var lookahead = tokenizer;
            if (!isBuildEntrypoint(path, source, &lookahead))
                try add(allocator, path, source, token.loc.start, .pub_without_doc, findings);
        }
        previous_tag = token.tag;
    }
}

fn isBuildEntrypoint(
    path: []const u8,
    source: []const u8,
    tokenizer: *std.zig.Tokenizer,
) bool {
    if (!std.mem.eql(u8, std.fs.path.basename(path), "build.zig")) return false;
    const fn_token = tokenizer.next();
    if (fn_token.tag != .keyword_fn) return false;
    const name_token = tokenizer.next();
    return name_token.tag == .identifier and
        std.mem.eql(u8, source[name_token.loc.start..name_token.loc.end], "build");
}

fn scanSource(
    allocator: Allocator,
    path: []const u8,
    source: [:0]const u8,
    findings: *std.ArrayList(Finding),
) !void {
    try scanPublicDocumentation(allocator, path, source, findings);

    var tokens: std.ArrayList(Token) = .empty;
    defer tokens.deinit(allocator);

    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        if (token.tag == .doc_comment or token.tag == .container_doc_comment) continue;
        try tokens.append(allocator, .{
            .tag = token.tag,
            .text = source[token.loc.start..token.loc.end],
            .start = token.loc.start,
        });
    }

    for (tokens.items, 0..) |token, index| {
        switch (token.tag) {
            .keyword_allowzero => try add(allocator, path, source, token.start, .allow_zero, findings),
            .keyword_anytype => try add(allocator, path, source, token.start, .any_type, findings),
            .keyword_opaque => try add(allocator, path, source, token.start, .opaque_type, findings),
            .keyword_unreachable => {
                const previous = if (index == 0) null else tokens.items[index - 1].tag;
                if (previous != .keyword_catch and previous != .keyword_orelse)
                    try add(allocator, path, source, token.start, .unreachable_site, findings);
            },
            .keyword_orelse => {
                if (index + 1 < tokens.items.len and tokens.items[index + 1].tag == .keyword_unreachable) {
                    try add(allocator, path, source, token.start, .orelse_unreachable, findings);
                }
            },
            .keyword_catch => {
                if (index + 2 < tokens.items.len and
                    tokens.items[index + 1].tag == .l_brace and
                    tokens.items[index + 2].tag == .r_brace)
                {
                    try add(allocator, path, source, token.start, .empty_catch, findings);
                }
                if (index + 1 < tokens.items.len and tokens.items[index + 1].tag == .keyword_unreachable) {
                    try add(allocator, path, source, token.start, .catch_unreachable, findings);
                }
            },
            .plus_pipe, .asterisk_pipe => try add(
                allocator,
                path,
                source,
                token.start,
                .saturating_add_mul,
                findings,
            ),
            .builtin => {
                const kind: ?Kind =
                    if (std.mem.eql(u8, token.text, "@panic"))
                        .panic
                    else if (std.mem.eql(u8, token.text, "@ptrFromInt"))
                        .ptr_from_int
                    else if (std.mem.eql(u8, token.text, "@ptrCast"))
                        .ptr_cast
                    else if (std.mem.eql(u8, token.text, "@alignCast"))
                        .align_cast
                    else if (std.mem.eql(u8, token.text, "@constCast"))
                        .const_cast
                    else if (std.mem.eql(u8, token.text, "@setRuntimeSafety") and runtimeSafetyOff(tokens.items, index))
                        .runtime_safety_off
                    else
                        null;
                if (kind) |value| try add(allocator, path, source, token.start, value, findings);
            },
            .identifier => {
                if (std.mem.eql(u8, token.text, "anyerror")) {
                    try add(allocator, path, source, token.start, .any_error, findings);
                } else if (std.mem.eql(u8, token.text, "anyopaque")) {
                    try add(allocator, path, source, token.start, .any_opaque, findings);
                } else if (std.mem.eql(u8, token.text, "_") and
                    index + 1 < tokens.items.len and
                    tokens.items[index + 1].tag == .equal)
                {
                    try add(allocator, path, source, token.start, .discard, findings);
                } else if (isDebugAssert(tokens.items, index)) {
                    try add(allocator, path, source, token.start, .debug_assert, findings);
                }
            },
            else => {},
        }
    }
}

fn runtimeSafetyOff(tokens: []const Token, index: usize) bool {
    if (index + 3 >= tokens.len) return false;
    return tokens[index + 1].tag == .l_paren and
        std.mem.eql(u8, tokens[index + 2].text, "false") and
        tokens[index + 3].tag == .r_paren;
}

fn isDebugAssert(tokens: []const Token, index: usize) bool {
    if (index + 5 >= tokens.len) return false;
    return std.mem.eql(u8, tokens[index].text, "std") and
        tokens[index + 1].tag == .period and
        std.mem.eql(u8, tokens[index + 2].text, "debug") and
        tokens[index + 3].tag == .period and
        std.mem.eql(u8, tokens[index + 4].text, "assert") and
        tokens[index + 5].tag == .l_paren;
}

fn add(
    allocator: Allocator,
    path: []const u8,
    source: []const u8,
    offset: usize,
    kind: Kind,
    findings: *std.ArrayList(Finding),
) !void {
    const before = source[0..offset];
    const line_start = if (std.mem.lastIndexOfScalar(u8, before, '\n')) |index| index + 1 else 0;
    const after = source[offset..];
    const line_end = offset + (std.mem.indexOfScalar(u8, after, '\n') orelse after.len);
    const line = std.mem.trim(u8, source[line_start..line_end], " \t\r");
    try findings.append(allocator, .{
        .path = path,
        .kind = kind,
        .line = line,
        .line_number = 1 + std.mem.count(u8, source[0..offset], "\n"),
    });
}

test "tokenizer ignores sensitive words in comments and strings" {
    const source: [:0]const u8 =
        \\// anyopaque catch {} _ = @panic("no")
        \\const text = "anyerror unreachable std.debug.assert(false)";
        \\const real: anytype = undefined;
        \\
    ;

    var findings: std.ArrayList(Finding) = .empty;
    defer findings.deinit(std.testing.allocator);
    try scanSource(std.testing.allocator, "fixture.zig", source, &findings);

    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
    try std.testing.expectEqual(Kind.any_type, findings.items[0].kind);
}

test "empty catch is token based across whitespace" {
    const source: [:0]const u8 =
        \\fn f() void {
        \\    work() catch
        \\    {};
        \\}
        \\
    ;

    var findings: std.ArrayList(Finding) = .empty;
    defer findings.deinit(std.testing.allocator);
    try scanSource(std.testing.allocator, "fixture.zig", source, &findings);

    var found = false;
    for (findings.items) |finding| {
        if (finding.kind == .empty_catch) found = true;
    }
    try std.testing.expect(found);
}

test "duplicate identical sensitive sites remain distinct" {
    const source: [:0]const u8 =
        \\fn f() void {
        \\    cleanup() catch {};
        \\    cleanup() catch {};
        \\}
        \\
    ;

    var findings: std.ArrayList(Finding) = .empty;
    defer findings.deinit(std.testing.allocator);
    try scanSource(std.testing.allocator, "fixture.zig", source, &findings);

    var count: usize = 0;
    for (findings.items) |finding| {
        if (finding.kind == .empty_catch) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "escape hatches compose from tokens across whitespace" {
    const source: [:0]const u8 =
        \\fn f(p: usize) void {
        \\    _ = @ptrFromInt(p);
        \\    _ = @ptrCast(p);
        \\    _ = @alignCast(p);
        \\    _ = @constCast(p);
        \\    @setRuntimeSafety(
        \\        false
        \\    );
        \\    maybe() catch unreachable;
        \\    _ = optional orelse unreachable;
        \\}
        \\
    ;

    var findings: std.ArrayList(Finding) = .empty;
    defer findings.deinit(std.testing.allocator);
    try scanSource(std.testing.allocator, "fixture.zig", source, &findings);

    const wanted = [_]Kind{
        .ptr_from_int,
        .ptr_cast,
        .align_cast,
        .const_cast,
        .runtime_safety_off,
        .catch_unreachable,
        .orelse_unreachable,
    };
    for (wanted) |kind| {
        var found = false;
        for (findings.items) |finding| {
            if (finding.kind == kind) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "baseline normalization ignores ordering but preserves duplicates" {
    const source =
        \\b|discard|_ = b;
        \\a|anytype|value: anytype,
        \\a|anytype|value: anytype,
        \\
    ;
    const normalized = try normalizeCensus(std.testing.allocator, source);
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualStrings(
        "a|anytype|value: anytype,\n" ++
            "a|anytype|value: anytype,\n" ++
            "b|discard|_ = b;\n",
        normalized,
    );
}

test "stable census vocabulary stays narrower than exploratory scan" {
    try std.testing.expect(legacyBaselineKind(.any_type));
    try std.testing.expect(legacyBaselineKind(.any_error));
    try std.testing.expect(legacyBaselineKind(.any_opaque));
    try std.testing.expect(legacyBaselineKind(.discard));
    try std.testing.expect(!legacyBaselineKind(.empty_catch));
    try std.testing.expect(!legacyBaselineKind(.opaque_type));
    try std.testing.expect(!legacyBaselineKind(.ptr_from_int));
}

test "source scope uses exact roots and directory prefixes" {
    const config = Config{
        .schema = 1,
        .source = .git,
        .baseline = "baseline",
        .include = &.{ "build.zig", "src", "tools/check.zig" },
        .exclude = &.{"src/vendor"},
    };
    try std.testing.expect(sourceSelected(config, "build.zig"));
    try std.testing.expect(sourceSelected(config, "src/main.zig"));
    try std.testing.expect(sourceSelected(config, "tools/check.zig"));
    try std.testing.expect(!sourceSelected(config, "src/vendor/lib.zig"));
    try std.testing.expect(!sourceSelected(config, "vendor/lib.zig"));
    try std.testing.expect(!sourceSelected(config, "build.zig.zon"));
}

test "minimum ruleset rejects a stale checker contract" {
    try std.testing.expect(stable_ruleset >= 1);
}

test "source acknowledgements bind exact rules to the next source line" {
    const source: [:0]const u8 =
        \\// zig-audit: acknowledge discard
        \\// reason: the result is intentionally ignored.
        \\// zig-audit: acknowledge ptr_cast
        \\// reason: the ABI requires this pointer representation.
        \\_ = @ptrCast(p);
        \\
    ;

    var findings: std.ArrayList(Finding) = .empty;
    defer findings.deinit(std.testing.allocator);
    try scanSource(std.testing.allocator, "fixture.zig", source, &findings);

    const acknowledgements = try parseAcknowledgements(std.testing.allocator, source);
    defer std.testing.allocator.free(acknowledgements);
    const matched = try std.testing.allocator.alloc(bool, findings.items.len);
    defer std.testing.allocator.free(matched);
    @memset(matched, false);
    const resolutions = try std.testing.allocator.alloc(AcknowledgementResolution, acknowledgements.len);
    defer std.testing.allocator.free(resolutions);

    resolveAcknowledgements(findings.items, acknowledgements, matched, resolutions);
    try std.testing.expectEqual(@as(usize, 2), acknowledgements.len);
    try std.testing.expectEqual(AcknowledgementResolution.acknowledged, resolutions[0]);
    try std.testing.expectEqual(AcknowledgementResolution.acknowledged, resolutions[1]);
    for (findings.items, matched) |finding, acknowledged| {
        if (enforcedKind(finding.kind)) try std.testing.expect(acknowledged);
    }
}

test "acknowledgement can cross whitespace but not unrelated source" {
    const source: [:0]const u8 =
        \\// zig-audit: acknowledge discard
        \\// reason: removal return value is irrelevant.
        \\
        \\_ = list.swapRemove(0);
        \\
    ;

    var findings: std.ArrayList(Finding) = .empty;
    defer findings.deinit(std.testing.allocator);
    try scanSource(std.testing.allocator, "fixture.zig", source, &findings);
    const acknowledgements = try parseAcknowledgements(std.testing.allocator, source);
    defer std.testing.allocator.free(acknowledgements);
    try std.testing.expectEqual(@as(usize, 1), acknowledgements.len);
    try std.testing.expectEqual(@as(usize, 4), acknowledgements[0].target_line);
}

test "wrong rule acknowledgement fails locally" {
    const source: [:0]const u8 =
        \\// zig-audit: acknowledge anytype
        \\// reason: deliberately wrong for the regression.
        \\_ = value;
        \\
    ;

    var findings: std.ArrayList(Finding) = .empty;
    defer findings.deinit(std.testing.allocator);
    try scanSource(std.testing.allocator, "fixture.zig", source, &findings);
    const acknowledgements = try parseAcknowledgements(std.testing.allocator, source);
    defer std.testing.allocator.free(acknowledgements);
    const matched = try std.testing.allocator.alloc(bool, findings.items.len);
    defer std.testing.allocator.free(matched);
    @memset(matched, false);
    const resolutions = try std.testing.allocator.alloc(AcknowledgementResolution, acknowledgements.len);
    defer std.testing.allocator.free(resolutions);

    resolveAcknowledgements(findings.items, acknowledgements, matched, resolutions);
    try std.testing.expectEqual(AcknowledgementResolution.wrong_rule, resolutions[0]);
}

test "stale acknowledgement fails instead of drifting forward" {
    const source: [:0]const u8 =
        \\// zig-audit: acknowledge discard
        \\// reason: this marker has no sensitive source below it.
        \\const value: u8 = 1;
        \\_ = value;
        \\
    ;

    var findings: std.ArrayList(Finding) = .empty;
    defer findings.deinit(std.testing.allocator);
    try scanSource(std.testing.allocator, "fixture.zig", source, &findings);
    const acknowledgements = try parseAcknowledgements(std.testing.allocator, source);
    defer std.testing.allocator.free(acknowledgements);
    const matched = try std.testing.allocator.alloc(bool, findings.items.len);
    defer std.testing.allocator.free(matched);
    @memset(matched, false);
    const resolutions = try std.testing.allocator.alloc(AcknowledgementResolution, acknowledgements.len);
    defer std.testing.allocator.free(resolutions);

    resolveAcknowledgements(findings.items, acknowledgements, matched, resolutions);
    try std.testing.expectEqual(AcknowledgementResolution.stale, resolutions[0]);
}

test "acknowledgement requires a reason line" {
    const source: [:0]const u8 =
        \\// zig-audit: acknowledge discard
        \\_ = value;
        \\
    ;
    const acknowledgements = try parseAcknowledgements(std.testing.allocator, source);
    defer std.testing.allocator.free(acknowledgements);
    try std.testing.expectEqual(@as(usize, 1), acknowledgements.len);
    try std.testing.expectEqual(AcknowledgementProblem.missing_reason, acknowledgements[0].problem);
}

test "acknowledgement rejects an empty reason" {
    const source: [:0]const u8 =
        \\// zig-audit: acknowledge discard
        \\// reason:
        \\_ = value;
        \\
    ;
    const acknowledgements = try parseAcknowledgements(std.testing.allocator, source);
    defer std.testing.allocator.free(acknowledgements);
    try std.testing.expectEqual(AcknowledgementProblem.empty_reason, acknowledgements[0].problem);
}

test "one acknowledgement consumes only one duplicate finding" {
    const source: [:0]const u8 =
        \\// zig-audit: acknowledge discard
        \\// reason: only one discard is intentionally acknowledged.
        \\_ = first; _ = second;
        \\
    ;

    var findings: std.ArrayList(Finding) = .empty;
    defer findings.deinit(std.testing.allocator);
    try scanSource(std.testing.allocator, "fixture.zig", source, &findings);
    const acknowledgements = try parseAcknowledgements(std.testing.allocator, source);
    defer std.testing.allocator.free(acknowledgements);
    const matched = try std.testing.allocator.alloc(bool, findings.items.len);
    defer std.testing.allocator.free(matched);
    @memset(matched, false);
    const resolutions = try std.testing.allocator.alloc(AcknowledgementResolution, acknowledgements.len);
    defer std.testing.allocator.free(resolutions);

    resolveAcknowledgements(findings.items, acknowledgements, matched, resolutions);
    var matched_discards: usize = 0;
    var total_discards: usize = 0;
    for (findings.items, matched) |finding, acknowledged| {
        if (finding.kind != .discard) continue;
        total_discards += 1;
        if (acknowledged) matched_discards += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), total_discards);
    try std.testing.expectEqual(@as(usize, 1), matched_discards);
}

test "specific unreachable forms do not double report generic unreachable" {
    const source: [:0]const u8 =
        \\fn f(optional: ?u8) void {
        \\    maybe() catch unreachable;
        \\    _ = optional orelse unreachable;
        \\    if (optional == null) unreachable;
        \\}
        \\
    ;

    var findings: std.ArrayList(Finding) = .empty;
    defer findings.deinit(std.testing.allocator);
    try scanSource(std.testing.allocator, "fixture.zig", source, &findings);

    var catch_count: usize = 0;
    var orelse_count: usize = 0;
    var generic_count: usize = 0;
    for (findings.items) |finding| switch (finding.kind) {
        .catch_unreachable => catch_count += 1,
        .orelse_unreachable => orelse_count += 1,
        .unreachable_site => generic_count += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), catch_count);
    try std.testing.expectEqual(@as(usize, 1), orelse_count);
    try std.testing.expectEqual(@as(usize, 1), generic_count);
}

test "ruleset three enforces public docs and sharp observations" {
    inline for (std.meta.tags(Kind)) |kind| {
        const expected = kind != .debug_assert and kind != .saturating_add_mul;
        try std.testing.expectEqual(expected, enforcedKind(kind));
    }
    try std.testing.expect(!acknowledgeableKind(.pub_without_doc));
    try std.testing.expect(acknowledgeableKind(.discard));
}

test "unknown acknowledgement rule is rejected" {
    const source: [:0]const u8 =
        \\// zig-audit: acknowledge definitely_not_a_rule
        \\// reason: typo must not weaken checking.
        \\_ = value;
        \\
    ;
    const acknowledgements = try parseAcknowledgements(std.testing.allocator, source);
    defer std.testing.allocator.free(acknowledgements);
    try std.testing.expectEqual(@as(usize, 1), acknowledgements.len);
    try std.testing.expectEqual(AcknowledgementProblem.unknown_kind, acknowledgements[0].problem);
}

test "command grammar separates global version from check verbosity" {
    const root = parseCommand(&.{});
    switch (root) {
        .command => |command| switch (command) {
            .help => |topic| try std.testing.expectEqual(HelpTopic.root, topic),
            else => return error.TestUnexpectedResult,
        },
        .failure => return error.TestUnexpectedResult,
    }

    for ([_][]const []const u8{
        &.{"version"},
        &.{"--version"},
        &.{"-v"},
    }) |argv| {
        switch (parseCommand(argv)) {
            .command => |command| switch (command) {
                .version => {},
                else => return error.TestUnexpectedResult,
            },
            .failure => return error.TestUnexpectedResult,
        }
    }

    switch (parseCommand(&.{ "check", "-v", "--config", "/repo/.zig-audit.json" })) {
        .command => |command| switch (command) {
            .check => |options| {
                try std.testing.expect(options.verbose);
                try std.testing.expectEqualStrings("/repo/.zig-audit.json", options.config_path);
            },
            else => return error.TestUnexpectedResult,
        },
        .failure => return error.TestUnexpectedResult,
    }

    switch (parseCommand(&.{"chek"})) {
        .failure => |failure| {
            try std.testing.expectEqualStrings("unknown command", failure.message);
            try std.testing.expectEqualStrings("chek", failure.argument.?);
        },
        .command => return error.TestUnexpectedResult,
    }

    switch (parseCommand(&.{ "scan", "--", "-generated.zig" })) {
        .command => |command| switch (command) {
            .scan => |paths| {
                try std.testing.expectEqual(@as(usize, 1), paths.len);
                try std.testing.expectEqualStrings("-generated.zig", paths[0]);
            },
            else => return error.TestUnexpectedResult,
        },
        .failure => return error.TestUnexpectedResult,
    }
}

test "check summary is stable structured output" {
    var output = try std.Io.Writer.Allocating.initCapacity(std.testing.allocator, 64);
    defer output.deinit();

    try writeCheckSummary(&output.writer, .{ .acknowledged = 317, .files_checked = 32 }, true);
    const text_value = try output.toOwnedSlice();
    defer std.testing.allocator.free(text_value);

    try std.testing.expectEqualStrings(
        "{\"schema\":\"zig-audit.check/v1\",\"type\":\"summary\",\"result\":\"pass\",\"acknowledged\":317,\"files_checked\":32}\n",
        text_value,
    );
}

test "public declaration requires doc comment" {
    const source: [:0]const u8 =
        \\pub const Missing = struct {};
        \\/// Documented declaration.
        \\pub fn documented() void {}
        \\
    ;
    var findings: std.ArrayList(Finding) = .empty;
    defer findings.deinit(std.testing.allocator);
    try scanSource(std.testing.allocator, "fixture.zig", source, &findings);

    var missing: usize = 0;
    for (findings.items) |finding| {
        if (finding.kind == .pub_without_doc) {
            missing += 1;
            try std.testing.expectEqual(@as(usize, 1), finding.line_number);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), missing);
}

test "container and ordinary comments do not document public declarations" {
    const source: [:0]const u8 =
        \\//! Container documentation.
        \\pub const ContainerOnly = u8;
        \\/// Interrupted documentation.
        \\// ordinary comment breaks declaration adjacency
        \\pub const Interrupted = u8;
        \\
    ;
    var findings: std.ArrayList(Finding) = .empty;
    defer findings.deinit(std.testing.allocator);
    try scanSource(std.testing.allocator, "fixture.zig", source, &findings);

    var missing: usize = 0;
    for (findings.items) |finding| {
        if (finding.kind == .pub_without_doc) missing += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), missing);
}

test "public documentation rule cannot be acknowledged away" {
    const source: [:0]const u8 =
        \\// zig-audit: acknowledge pub_without_doc
        \\// reason: this must still require documentation.
        \\pub const Missing = u8;
        \\
    ;
    var findings: std.ArrayList(Finding) = .empty;
    defer findings.deinit(std.testing.allocator);
    try scanSource(std.testing.allocator, "fixture.zig", source, &findings);
    const acknowledgements = try parseAcknowledgements(std.testing.allocator, source);
    defer std.testing.allocator.free(acknowledgements);
    const matched = try std.testing.allocator.alloc(bool, findings.items.len);
    defer std.testing.allocator.free(matched);
    @memset(matched, false);
    const resolutions = try std.testing.allocator.alloc(AcknowledgementResolution, acknowledgements.len);
    defer std.testing.allocator.free(resolutions);

    resolveAcknowledgements(findings.items, acknowledgements, matched, resolutions);
    try std.testing.expectEqual(AcknowledgementResolution.not_acknowledgeable, resolutions[0]);
}

test "canonical build.zig entrypoint is not public API documentation" {
    const source: [:0]const u8 =
        \\pub fn build(_: *std.Build) void {}
        \\pub const Other = u8;
        \\
    ;
    var findings: std.ArrayList(Finding) = .empty;
    defer findings.deinit(std.testing.allocator);
    try scanSource(std.testing.allocator, "build.zig", source, &findings);

    var missing: usize = 0;
    for (findings.items) |finding| {
        if (finding.kind != .pub_without_doc) continue;
        missing += 1;
        try std.testing.expect(std.mem.indexOf(u8, finding.line, "Other") != null);
    }
    try std.testing.expectEqual(@as(usize, 1), missing);
}

test "build-named function outside build.zig still requires documentation" {
    const source: [:0]const u8 =
        \\pub fn build() void {}
        \\
    ;
    var findings: std.ArrayList(Finding) = .empty;
    defer findings.deinit(std.testing.allocator);
    try scanSource(std.testing.allocator, "src/api.zig", source, &findings);

    var missing: usize = 0;
    for (findings.items) |finding| if (finding.kind == .pub_without_doc) {
        missing += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), missing);
}
