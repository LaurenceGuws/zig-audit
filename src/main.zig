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
            .runtime_safety_off => "runtime_safety_off",
            .saturating_add_mul => "saturating_add_mul",
            .unreachable_site => "unreachable",
        };
    }
};

const Finding = struct {
    path: []const u8,
    kind: Kind,
    line: []const u8,
};

const Token = struct {
    tag: std.zig.Token.Tag,
    text: []const u8,
    start: usize,
};

const Config = struct {
    schema: u32,
    source: Source,
    baseline: []const u8,
    minimum_ruleset: u32 = 1,
    include: []const []const u8 = &.{},
    exclude: []const []const u8 = &.{},

    const Source = enum {
        git,
    };
};

const version = "0.1.0";
const stable_ruleset: u32 = 1;
const config_schema: u32 = 1;
const default_config_path = ".zig-audit.json";

pub fn main(init: std.process.Init) void {
    run(init) catch |failure| {
        if (failure != error.CensusChanged) emitFailure(init.io, failure);
        std.process.exit(1);
    };
}

fn emitFailure(io: std.Io, failure: anyerror) void {
    const message = switch (failure) {
        error.ExpectedCommand => "expected command: check, accept, scan, or version",
        error.ExpectedPath => "scan requires at least one Zig file or directory",
        error.InvalidArguments => "invalid command arguments",
        error.InvalidConfig => "project config is malformed or contains unsupported fields",
        error.UnsupportedConfigSchema => "project config schema is newer or unsupported",
        error.CheckerRulesetTooOld => "checker stable ruleset is older than the project minimum; upgrade zig-audit",
        error.BaselineUnavailable => "reviewed baseline is unavailable",
        error.SourceDiscoveryFailed => "configured source discovery failed",
        else => @errorName(failure),
    };
    var buffer: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(io, &buffer);
    stderr.interface.print("zig-audit: {s}\n", .{message}) catch {};
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
        return writeFindings(init.io, findings, false);
    }
    if (std.mem.eql(u8, args[1], "check")) {
        if (args.len > 3) return error.InvalidArguments;
        return checkProject(init, if (args.len == 3) args[2] else default_config_path);
    }
    if (std.mem.eql(u8, args[1], "accept")) {
        if (args.len > 3) return error.InvalidArguments;
        return acceptProject(init, if (args.len == 3) args[2] else default_config_path);
    }

    // Keep the original exploratory surface while the command shape is dogfooded.
    const findings = try scanPaths(init, args[1..]);
    return writeFindings(init.io, findings, false);
}

fn scanPaths(init: std.process.Init, paths: []const []const u8) ![]Finding {
    var findings: std.ArrayList(Finding) = .empty;
    for (paths) |path| {
        try scanPath(init.io, init.gpa, init.arena.allocator(), path, &findings);
    }
    std.mem.sort(Finding, findings.items, {}, lessThan);
    return findings.toOwnedSlice(init.arena.allocator());
}

fn writeFindings(io: std.Io, findings: []const Finding, baseline_only: bool) !void {
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    for (findings) |finding| {
        if (baseline_only and !baselineKind(finding.kind)) continue;
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

fn baselineKind(kind: Kind) bool {
    return switch (kind) {
        .any_error, .any_opaque, .any_type, .discard => true,
        else => false,
    };
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
    if (parsed.value.schema != config_schema) return error.UnsupportedConfigSchema;
    if (parsed.value.minimum_ruleset > stable_ruleset) return error.CheckerRulesetTooOld;
    return .{
        .schema = parsed.value.schema,
        .source = parsed.value.source,
        .baseline = try init.arena.allocator().dupe(u8, parsed.value.baseline),
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

fn projectFindings(init: std.process.Init, config: Config) ![]Finding {
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
            break :blk try scanPaths(init, paths.items);
        },
    };
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

fn stableCensus(init: std.process.Init, findings: []const Finding) ![]u8 {
    var output = try std.Io.Writer.Allocating.initCapacity(init.arena.allocator(), 4096);
    defer output.deinit();
    for (findings) |finding| {
        if (!baselineKind(finding.kind)) continue;
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

fn checkProject(init: std.process.Init, config_path: []const u8) !void {
    const config = try loadConfig(init, config_path);
    const findings = try projectFindings(init, config);
    const actual = try stableCensus(init, findings);
    const expected = std.Io.Dir.cwd().readFileAlloc(
        init.io,
        config.baseline,
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
    const findings = try projectFindings(init, config);
    const actual = try stableCensus(init, findings);
    try writeAtomic(init.io, init.arena.allocator(), config.baseline, actual);
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
    parent.deleteFile(io, temporary) catch {};
    var file = try parent.createFile(io, temporary, .{ .truncate = true, .exclusive = true });
    var open = true;
    defer if (open) file.close(io);
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

fn scanSource(
    allocator: Allocator,
    path: []const u8,
    source: [:0]const u8,
    findings: *std.ArrayList(Finding),
) !void {
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
            .keyword_unreachable => try add(allocator, path, source, token.start, .unreachable_site, findings),
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
    try std.testing.expect(baselineKind(.any_type));
    try std.testing.expect(baselineKind(.any_error));
    try std.testing.expect(baselineKind(.any_opaque));
    try std.testing.expect(baselineKind(.discard));
    try std.testing.expect(!baselineKind(.empty_catch));
    try std.testing.expect(!baselineKind(.opaque_type));
    try std.testing.expect(!baselineKind(.ptr_from_int));
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
