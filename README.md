# zig-audit

Tokenizer-based Zig sensitive-source census and reviewed-baseline checker.

zig-audit exists to make sharp or generic Zig constructs mechanically visible without
pretending that every occurrence is wrong. It uses Zig's own tokenizer rather than
teaching regular expressions to understand Zig.

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
`zig-audit src build.zig` remains available while the tool is being dogfooded.

`zig-audit version` emits machine-readable version and stable-ruleset identity.

## Project config

The default project file is `.zig-audit.json`:

    {
      "schema": 1,
      "source": "git",
      "baseline": "tools/source_audit.allow",
      "minimum_ruleset": 1,
      "include": ["build.zig", "src", "tests"],
      "exclude": ["src/vendor"]
    }

`source: "git"` means tracked plus untracked, non-ignored `*.zig` files. `include`
and `exclude` are optional exact path/directory-root filters applied to that owned
source set. Empty `include` means all owned Zig source.

`minimum_ruleset` prevents an older checker from silently under-checking a project
after the shared stable rule vocabulary grows. It is not an exact binary-version pin.

The config describes source discovery, compatibility, and baseline location. It does
not redefine what Zig constructs mean.

## Stable versus exploratory observations

The initial stable census is the long-running copied audit family already used by
Howl/QAgent:

- `anytype`
- `anyerror`
- `anyopaque`
- discard assignment (`_ = ...`)

`scan` also indexes newer experimental observations such as empty catches,
`unreachable`, opaque types, pointer/mutability casts, `allowzero`, assertions,
panics, saturating arithmetic, and runtime-safety disabling. Those stay visible before
promotion into the shared stable census.

A reviewed baseline means only "these sensitive sites are already known". It is not
an assertion that the construct is wrong or locally forbidden.

## Install

The repository pins the accepted Zig compiler in `.zigversion`. The installer runs
the tests and installs a ReleaseSafe binary to `~/.local/bin`:

    ./install

## Lab notes

The user/agent journey, build integration failure cases, source-discovery variants,
and baseline acknowledgement questions are mapped in `docs/journeys.md`. They are
working notes, not a frozen architecture.
