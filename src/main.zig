//! Tokenizes Zig source and emits a deterministic census of sensitive constructs.

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

const version = "0.3.0";
const stable_ruleset: u32 = 3;
const current_config_schema: u32 = 2;
const legacy_config_schema: u32 = 1;
const default_config_path = ".zig-audit.json";

const CheckOptions = struct {
    config_path: []const u8 = default_config_path,
    verbose: bool = false,
};

const CheckSummary = struct {
    acknowledged: usize = 0,
    files: usize = 0,
};

/// Runs the zig-audit command-line checker.
pub fn main(init: std.process.Init) void {
    run(init) catch |failure| {
        if (failure != error.CensusChanged and failure != error.AuditFailed)
            emitFailure(init.io, failure);
        std.process.exit(1);
    };
}

// zig-audit: acknowledge anyerror
// reason: The top-level CLI boundary must format any command failure before process exit.
fn emitFailure(io: std.Io, failure: anyerror) void {
    const message = switch (failure) {
        error.ExpectedCommand => "expected command: check, scan, or version",
        error.ExpectedPath => "scan requires at least one Zig file or directory",
        error.InvalidArguments => "invalid command arguments",
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
    // zig-audit: acknowledge empty_catch
    // reason: Fatal-path diagnostics are best-effort because the command failure already determines exit status.
    stderr.interface.print("zig-audit: {s}\n", .{message}) catch {};
    // zig-audit: acknowledge empty_catch
    // reason: Flushing fatal-path diagnostics cannot replace the command failure that is already being reported.
    stderr.interface.flush() catch {};
}

fn run(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return error.ExpectedCommand;

    if (std.mem.eql(u8, args[1], "version")) {
        if (args.len != 2) return error.InvalidArguments;
        return writeVersion(init.io);
    }
    if (std.mem.eql(u8, args[1], "scan")) {
        if (args.len < 3) return error.ExpectedPath;
        const findings = try scanPaths(init, args[2..]);
        return writeFindings(init.io, findings);
    }
    if (std.mem.eql(u8, args[1], "check")) {
        const options = try parseCheckOptions(args[2..]);
        return checkProject(init, options);
    }
    if (std.mem.eql(u8, args[1], "accept")) {
        if (args.len > 3) return error.InvalidArguments;
        return acceptProject(init, if (args.len == 3) args[2] else default_config_path);
    }

    // Keep the original exploratory surface while the command shape is dogfooded.
    const findings = try scanPaths(init, args[1..]);
    return writeFindings(init.io, findings);
}

fn parseCheckOptions(args: []const []const u8) !CheckOptions {
    var result = CheckOptions{};
    var config_seen = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            if (result.verbose) return error.InvalidArguments;
            result.verbose = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-") or config_seen) return error.InvalidArguments;
        result.config_path = arg;
        config_seen = true;
    }
    return result;
}

fn scanPaths(init: std.process.Init, paths: []const []const u8) ![]Finding {
    var findings: std.ArrayList(Finding) = .empty;
    for (paths) |path| {
        try scanPath(init.io, init.gpa, init.arena.allocator(), path, &findings);
    }
    std.mem.sort(Finding, findings.items, {}, lessThan);
    return findings.toOwnedSlice(init.arena.allocator());
}

fn writeFindings(io: std.Io, findings: []const Finding) !void {
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    for (findings) |finding| {
        try stdout.interface.print("{s}|{s}|{s}\n", .{
            finding.path,
            finding.kind.name(),
            finding.line,
        });
    }
    try stdout.interface.flush();
}

fn writeVersion(io: std.Io) !void {
    var buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    try stdout.interface.print(
        "{{\"version\":\"{s}\",\"stable_ruleset\":{d}}}\n",
        .{ version, stable_ruleset },
    );
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
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        path,
        init.arena.allocator(),
        .limited(64 * 1024),
    );
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

fn dupeStrings(allocator: Allocator, values: []const []const u8) ![]const []const u8 {
    const copy = try allocator.alloc([]const u8, values.len);
    for (values, 0..) |value, index| copy[index] = try allocator.dupe(u8, value);
    return copy;
}

fn projectPaths(init: std.process.Init, config: Config) ![]const []const u8 {
    return switch (config.source) {
        .git => blk: {
            const result = try std.process.run(init.gpa, init.io, .{
                .argv = &.{
                    "git",
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
            if (!success) return error.SourceDiscoveryFailed;

            var paths: std.ArrayList([]const u8) = .empty;
            var it = std.mem.splitScalar(u8, result.stdout, 0);
            while (it.next()) |path| {
                if (path.len == 0 or !sourceSelected(config, path)) continue;
                try paths.append(init.arena.allocator(), try init.arena.allocator().dupe(u8, path));
            }
            break :blk try paths.toOwnedSlice(init.arena.allocator());
        },
    };
}

fn projectFindings(init: std.process.Init, config: Config) ![]Finding {
    return scanPaths(init, try projectPaths(init, config));
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
    const config = try loadConfig(init, options.config_path);
    if (config.schema == legacy_config_schema) return checkLegacyProject(init, config);
    return checkAcknowledgedProject(init, config, options.verbose);
}

fn checkLegacyProject(init: std.process.Init, config: Config) !void {
    const findings = try projectFindings(init, config);
    const actual = try legacyCensus(init, findings);
    const expected = std.Io.Dir.cwd().readFileAlloc(
        init.io,
        config.baseline.?,
        init.arena.allocator(),
        .limited(16 * 1024 * 1024),
    ) catch return error.BaselineUnavailable;
    const normalized_expected = try normalizeCensus(init.arena.allocator(), expected);
    if (std.mem.eql(u8, normalized_expected, actual)) return;

    try writeCensusDiff(init.io, normalized_expected, actual);
    return error.CensusChanged;
}

fn acceptProject(init: std.process.Init, config_path: []const u8) !void {
    const config = try loadConfig(init, config_path);
    if (config.schema != legacy_config_schema) return error.SourceAcknowledgementsRequired;
    const findings = try projectFindings(init, config);
    const actual = try legacyCensus(init, findings);
    try writeAtomic(init.io, init.arena.allocator(), config.baseline.?, actual);
}

fn checkAcknowledgedProject(init: std.process.Init, config: Config, verbose: bool) !void {
    const paths = try projectPaths(init, config);
    var stderr_buffer: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(init.io, &stderr_buffer);
    var failed = false;
    var summary = CheckSummary{};

    for (paths) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(
            init.io,
            path,
            init.arena.allocator(),
            .limited(16 * 1024 * 1024),
        );
        const source = try init.arena.allocator().dupeSentinel(u8, bytes, 0);

        var findings: std.ArrayList(Finding) = .empty;
        try scanSource(init.arena.allocator(), path, source, &findings);

        const acknowledgements = try parseAcknowledgements(init.arena.allocator(), source);
        const matched = try init.arena.allocator().alloc(bool, findings.items.len);
        @memset(matched, false);
        const resolutions = try init.arena.allocator().alloc(AcknowledgementResolution, acknowledgements.len);
        resolveAcknowledgements(findings.items, acknowledgements, matched, resolutions);
        var file_acknowledged = false;

        for (acknowledgements, resolutions) |ack, resolution| {
            switch (resolution) {
                .acknowledged => {
                    summary.acknowledged += 1;
                    file_acknowledged = true;
                    if (verbose) try stderr.interface.print(
                        "ACK {s}:{d} {s}: {s}\n",
                        .{ path, ack.target_line, ack.kind.?.name(), ack.reason },
                    );
                },
                .unknown_kind => {
                    failed = true;
                    try stderr.interface.print(
                        "ERROR {s}:{d} acknowledgement: unknown rule {s}\n",
                        .{ path, ack.marker_line, ack.kind_text },
                    );
                },
                .missing_reason => {
                    failed = true;
                    try stderr.interface.print(
                        "ERROR {s}:{d} {s}: acknowledgement requires an adjacent // reason: line\n",
                        .{ path, ack.marker_line, ack.kind_text },
                    );
                },
                .empty_reason => {
                    failed = true;
                    try stderr.interface.print(
                        "ERROR {s}:{d} {s}: acknowledgement reason is empty\n",
                        .{ path, ack.marker_line, ack.kind_text },
                    );
                },
                .wrong_rule => {
                    failed = true;
                    try stderr.interface.print(
                        "ERROR {s}:{d} {s}: acknowledgement names the wrong rule for source line {d}\n",
                        .{ path, ack.marker_line, ack.kind_text, ack.target_line },
                    );
                },
                .stale => {
                    failed = true;
                    try stderr.interface.print(
                        "ERROR {s}:{d} {s}: stale acknowledgement has no matching finding on source line {d}\n",
                        .{ path, ack.marker_line, ack.kind_text, ack.target_line },
                    );
                },
                .not_acknowledgeable => {
                    failed = true;
                    try stderr.interface.print(
                        "ERROR {s}:{d} {s}: this rule cannot be acknowledged; add /// documentation\n",
                        .{ path, ack.marker_line, ack.kind_text },
                    );
                },
            }
        }
        if (file_acknowledged) summary.files += 1;

        for (findings.items, matched) |finding, acknowledged| {
            if (!enforcedKind(finding.kind) or acknowledged) continue;
            failed = true;
            if (finding.kind == .pub_without_doc) {
                try stderr.interface.print(
                    "ERROR {s}:{d} pub_without_doc: public declaration requires /// documentation\n",
                    .{ path, finding.line_number },
                );
            } else {
                try stderr.interface.print(
                    "ERROR {s}:{d} {s}: acknowledgement required\n",
                    .{ path, finding.line_number, finding.kind.name() },
                );
            }
        }
    }

    if (!failed) try writeCheckSummary(&stderr.interface, summary);
    try stderr.interface.flush();
    if (failed) return error.AuditFailed;
}

fn writeCheckSummary(writer: *std.Io.Writer, summary: CheckSummary) !void {
    try writer.print(
        "zig-audit: PASS {d} acknowledged / {d} {s}\n",
        .{
            summary.acknowledged,
            summary.files,
            if (summary.files == 1) "file" else "files",
        },
    );
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
    var stderr = std.Io.File.stderr().writerStreaming(io, &buffer);
    try stderr.interface.writeAll("zig-audit: reviewed census changed\n");

    var old = std.mem.splitScalar(u8, expected, '\n');
    var new = std.mem.splitScalar(u8, actual, '\n');
    var old_line = nextLine(&old);
    var new_line = nextLine(&new);
    while (old_line != null or new_line != null) {
        if (old_line == null) {
            try stderr.interface.print("+ {s}\n", .{new_line.?});
            new_line = nextLine(&new);
            continue;
        }
        if (new_line == null) {
            try stderr.interface.print("- {s}\n", .{old_line.?});
            old_line = nextLine(&old);
            continue;
        }
        switch (std.mem.order(u8, old_line.?, new_line.?)) {
            .eq => {
                old_line = nextLine(&old);
                new_line = nextLine(&new);
            },
            .lt => {
                try stderr.interface.print("- {s}\n", .{old_line.?});
                old_line = nextLine(&old);
            },
            .gt => {
                try stderr.interface.print("+ {s}\n", .{new_line.?});
                new_line = nextLine(&new);
            },
        }
    }
    try stderr.interface.writeAll(
        "Review the source. If the census change is intentional, run: zig-audit accept\n",
    );
    try stderr.interface.flush();
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

test "check options are quiet by default and accept verbose aliases" {
    const quiet = try parseCheckOptions(&.{});
    try std.testing.expectEqualStrings(default_config_path, quiet.config_path);
    try std.testing.expect(!quiet.verbose);

    const short = try parseCheckOptions(&.{"-v"});
    try std.testing.expectEqualStrings(default_config_path, short.config_path);
    try std.testing.expect(short.verbose);

    const long = try parseCheckOptions(&.{ "--verbose", "project.json" });
    try std.testing.expectEqualStrings("project.json", long.config_path);
    try std.testing.expect(long.verbose);

    const reordered = try parseCheckOptions(&.{ "project.json", "-v" });
    try std.testing.expectEqualStrings("project.json", reordered.config_path);
    try std.testing.expect(reordered.verbose);

    try std.testing.expectError(error.InvalidArguments, parseCheckOptions(&.{ "-v", "--verbose" }));
    try std.testing.expectError(error.InvalidArguments, parseCheckOptions(&.{"--unknown"}));
    try std.testing.expectError(error.InvalidArguments, parseCheckOptions(&.{ "one.json", "two.json" }));
}

test "quiet check summary stays compact" {
    var output = try std.Io.Writer.Allocating.initCapacity(std.testing.allocator, 64);
    defer output.deinit();

    try writeCheckSummary(&output.writer, .{ .acknowledged = 317, .files = 32 });
    const text_value = try output.toOwnedSlice();
    defer std.testing.allocator.free(text_value);

    try std.testing.expectEqualStrings(
        "zig-audit: PASS 317 acknowledged / 32 files\n",
        text_value,
    );

    var singular = try std.Io.Writer.Allocating.initCapacity(std.testing.allocator, 64);
    defer singular.deinit();
    try writeCheckSummary(&singular.writer, .{ .acknowledged = 4, .files = 1 });
    const singular_text = try singular.toOwnedSlice();
    defer std.testing.allocator.free(singular_text);
    try std.testing.expectEqualStrings(
        "zig-audit: PASS 4 acknowledged / 1 file\n",
        singular_text,
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
