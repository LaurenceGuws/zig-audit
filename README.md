# zig-audit

Tokenizer-based Zig sensitive-source checker.

zig-audit indexes sharp Zig constructs with Zig's own tokenizer. Current projects
acknowledge intentional findings beside the source itself, so the reason and the
construct move together in review.

## Daily use

From a configured project root:

    zig-audit check

A clean acknowledged site is still visible:

    ACK src/window.zig:42 opaque_type: SDL owns this ABI handle layout.

An unacknowledged sharp construct fails:

    ERROR src/main.zig:17 discard: acknowledgement required

For exploration without enforcement:

    zig-audit scan src build.zig

Machine-readable checker identity:

    zig-audit version

## Source acknowledgement

The exact form is:

    // zig-audit: acknowledge discard
    // reason: The removed value has already transferred or released its ownership.
    _ = items.swapRemove(index);

The contract is intentionally strict:

- the marker names one exact enforced rule;
- the immediately following line is a non-empty `// reason:` line;
- after optional blank lines, the acknowledgement targets the next source line;
- one marker consumes exactly one matching finding on that line;
- stacked marker/reason pairs may acknowledge multiple findings on one source line;
- a wrong-rule marker fails;
- a stale marker fails;
- an acknowledgement never suppresses a different source line;
- every successful acknowledgement is emitted to stderr as `ACK`.

There are no project-local rule overrides in schema 2.

## Enforced ruleset 2

Ruleset 2 requires acknowledgements for:

- `anytype`, `anyerror`, and `anyopaque`
- result discard assignments (`_ = ...`)
- empty `catch {}`
- `catch unreachable`, `orelse unreachable`, and other `unreachable`
- `opaque` type declarations
- `allowzero`
- `@panic`
- `@ptrFromInt`, `@ptrCast`, `@alignCast`, and `@constCast`
- `@setRuntimeSafety(false)`

Specific `catch unreachable` and `orelse unreachable` forms do not also produce a
second generic `unreachable` finding.

`std.debug.assert` and saturating add/multiply are currently indexed by `scan` but
remain observational. They are useful review signals, but are not inherently escape
hatches and have not earned mandatory source annotations.

## Project config

The current config schema is 2:

    {
      "schema": 2,
      "source": "git",
      "minimum_ruleset": 2,
      "include": ["build.zig", "src", "tests"],
      "exclude": ["src/vendor"]
    }

`source: "git"` means tracked plus untracked, non-ignored `*.zig` files. `include`
and `exclude` are optional exact file/directory-root filters. Empty `include` means
all Git-owned Zig source.

`minimum_ruleset` prevents an older checker from silently providing weaker coverage.

Schema 1 baseline files remain readable only as a migration bridge for existing
consumers. New projects use schema 2. The legacy `accept` command is intentionally
unavailable for schema 2.

## Install

The repository pins its Zig compiler in `.zigversion`:

    ./install

The installer runs tests and installs a ReleaseSafe binary to `~/.local/bin`.

## Design boundary

Project configuration describes source scope and minimum checker capability. It does
not redefine Zig constructs or contain project architecture policy.

Historical design/dogfood notes live in `docs/journeys.md`.
