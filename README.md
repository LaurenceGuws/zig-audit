# zig-audit

Experimental Zig source smell indexer.

This is intentionally a small lab, not a settled policy/configuration design.
The first experiment uses Zig's own tokenizer to census sensitive constructs
without teaching grep to understand Zig.

Current CLI:

    zig build
    ./zig-out/bin/zig-audit src
    ./zig-out/bin/zig-audit src build.zig

Output is deterministic:

    path|kind|trimmed source line

The current vocabulary is deliberately small and will change while we dogfood it.
