# zig-audit

Tokenizer-based Zig sensitive-source checker.

zig-audit indexes sharp Zig constructs with Zig's own tokenizer. Current projects
acknowledge intentional findings beside the source itself, so the reason and the
construct move together in review.

## Daily use

From a configured project root:

    zig-audit check

A clean check is deliberately compact:

    zig-audit: PASS 17 acknowledged / 4 files

For Captain's manual red-pen pass, `-v` / `--verbose` prints every accepted
acknowledgement before the same summary:

    zig-audit check -v
    ACK src/window.zig:42 opaque_type: SDL owns this ABI handle layout.
    zig-audit: PASS 17 acknowledged / 4 files

An unacknowledged sharp construct stays fully explicit in either mode:

    ERROR src/main.zig:17 discard: acknowledgement required

For exploration without enforcement:

    zig-audit scan src build.zig

Machine-readable checker identity:

    zig-audit version
    zig-audit -v
    zig-audit --version

All three standalone forms return the same JSON identity without project config.
The check subcommand retains its verbose -v flag.

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
- every successful acknowledgement is counted in the default summary and emitted individually as `ACK` with `-v` / `--verbose`.

There are no project-local rule overrides in schema 2.

## Enforced ruleset 3

Ruleset 3 keeps the reviewed sharp-edge rules from ruleset 2 and adds one
fix-only structural rule:

- every `pub` declaration must have attached Zig `///` documentation;
- `//!` container documentation does not document a declaration;
- ordinary `//` comments and zig-audit acknowledgement metadata are transparent
  because Zig's tokenizer does not make them declaration tokens;
- the canonical `pub fn build` entrypoint in `build.zig` is exempt as build-system
  plumbing;
- `pub_without_doc` cannot be acknowledged away. Add documentation or make the
  declaration non-public.

The source-acknowledgeable rules remain:


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
      "minimum_ruleset": 3,
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

## Rootless release installation

The installer consumes prebuilt releases. It never invokes Zig, builds source,
uses sudo, or silently selects latest. Linux x86_64 and AArch64 payloads use
baseline CPUs and static ELF executables. The installer requires Python 3
(standard library only). Configured Git-source audits still require Git.

First obtain the exact manifest SHA-256 from reviewed, trusted release metadata.
A checksum downloaded beside an archive is integrity evidence, not independent
publisher authentication. Do not run a downloaded installer without reviewing or
otherwise authenticating it.

    ./install --release 0.3.1 --manifest-sha256 REVIEWED_MANIFEST_SHA256

This downloads the selected architecture's JSON manifest and tar.xz archive
from this repository's exact GitHub release tag. It verifies the pinned manifest,
archive size/hash, safe archive members, payload size/hash, static ELF target,
and all three executable identity forms before activation. Downloaded JSON is
never evaluated as code. Release publication is a separate operator step.

For an offline archive, or an isolated pilot:

    ./install --archive /absolute/release.tar.xz \
      --manifest /absolute/release.json --manifest-sha256 REVIEWED_MANIFEST_SHA256 \
      --prefix /absolute/isolated-prefix

The default prefix is ~/.local. Trees live in
PREFIX/share/zig-audit/releases/vVERSION-TARGET; PREFIX/bin/zig-audit is a
regular, owned launcher switched with one atomic rename. A lock serializes
installation. Every accepted tree retains the exact release metadata and an
installation receipt. Repeating an identical install is idempotent; a changed
artifact claiming the same release ID is rejected. Earlier trees are retained.

Explicit rollback revalidates a retained conforming tree and switches the launcher:

    ./install --rollback v0.3.1-pilot.1-x86_64-linux-musl --prefix /absolute/isolated-prefix

The pilot version in this example is a local test artifact, not a published
production release. Old 0.3.0 lacks the version aliases and is not a conforming
rollback target. The installer refuses foreign launchers, existing source-built
binaries, symlinked/writable installation paths, and invalid receipts instead of
overwriting them. Migrating an existing live binary requires separate inspection
and preservation of its exact bytes; this installer does not automate that step.
Keep PREFIX/bin on PATH yourself. No shell configuration or system path is changed.

Before the atomic launcher switch, interruption preserves the previous launcher.
After the switch, the selected verified release is active. A forcibly killed
process may leave an inert .stage.* directory; it does not select that directory
or automatically delete it on a later run. This is process-interruption safety,
not a claim of filesystem or hardware power-loss certification.

## Building and preparing releases

Development builds remain explicit and separate from deployment:

    zig build test -j1 -Doptimize=ReleaseSafe
    zig build check -j1 -Doptimize=ReleaseSafe
    zig build -j1 -Doptimize=ReleaseSafe --prefix /absolute/workstream/build

tools/release --help describes owner-local release preparation. Use a clean
committed source tree, the pinned Fleet compiler profile, an available qualified
workstation, and an output directory under the active workstream. It runs native
format/test/build/self-audit checks, cross-builds the selected targets serially,
verifies static ELF and packaged payload identity, and records source/tree,
recipe, compiler source/patch/hash, auditor/config, commands and gate results.
It does not create tags, upload, publish, install, or select a permanent builder.
A cross build remains explicitly unexecuted until checked on matching hardware;
do not promote it as target-native accepted. No reproducible-byte claim is made.

tests/release --help describes isolated installer acceptance, including a pair
of real conforming archives for upgrade/rollback. Keep its work directory under
the active workstream. It reports fixture/instrumented cases distinctly from
real executable acceptance.

## Design boundary

Project configuration describes source scope and minimum checker capability. It does
not redefine Zig constructs or contain project architecture policy.

Historical design/dogfood notes live in `docs/journeys.md`.
