# zig-audit

Experimental Zig sensitive-source indexer.

The checker uses Zig's own tokenizer instead of teaching regular expressions to
understand Zig. It is intentionally small while the user/agent journey is dogfooded.

## Commands

From a configured project root:

    zig-audit check
    zig-audit accept

`check` is read-only. It compares the current stable census with the reviewed
baseline and prints exact additions/removals on drift.

`accept` explicitly rewrites the reviewed baseline from the current stable census.

For exploration:

    zig-audit scan src build.zig

`scan` reports both stable and experimental observations. The original shorthand
`zig-audit src build.zig` remains available during the experiment.

## Project config

The current canary config is deliberately tiny:

    {
      "schema": 1,
      "source": "git",
      "baseline": "tools/source_audit.allow"
    }

`source: "git"` means tracked plus untracked, non-ignored `*.zig` files. This
matches the source discovery already proven in Howl's local audit and avoids scanning
ignored dependency/experiment forests.

The config describes source discovery and baseline location. It does not redefine
what Zig constructs mean.

## Stable versus exploratory observations

The initial stable census is the long-running copied audit family already used by
Howl/QAgent:

- `anytype`
- `anyerror`
- `anyopaque`
- discard assignment (`_ = ...`)

`scan` also indexes newer experimental observations such as empty catches,
`unreachable`, opaque types, pointer/mutability casts, `allowzero`, assertions,
panics, saturating arithmetic, and runtime-safety disabling. Those are deliberately
visible before they are promoted into the shared stable census.

A reviewed baseline means only "these sensitive sites are already known". It is not
an assertion that the construct is wrong or locally forbidden.

## Lab notes

The user/agent journey, build integration failure cases, source-discovery variants,
and baseline acknowledgement questions are mapped in `docs/journeys.md`. They are
working notes, not a frozen architecture.
