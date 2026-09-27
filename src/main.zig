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

pub fn main(init: std.process.Init) void {
    run(init) catch |failure| {
        var buffer: [1024]u8 = undefined;
        var stderr = std.Io.File.stderr().writerStreaming(init.io, &buffer);
        stderr.interface.print("zig-audit: {s}\n", .{@errorName(failure)}) catch {};
        stderr.interface.flush() catch {};
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return error.ExpectedPath;

    var findings: std.ArrayList(Finding) = .empty;
    defer findings.deinit(init.arena.allocator());

    for (args[1..]) |path| {
        try scanPath(init.io, init.gpa, init.arena.allocator(), path, &findings);
    }

    std.mem.sort(Finding, findings.items, {}, lessThan);

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    for (findings.items) |finding| {
        try stdout.interface.print("{s}|{s}|{s}\n", .{
            finding.path,
            finding.kind.name(),
            finding.line,
        });
    }
    try stdout.interface.flush();
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
