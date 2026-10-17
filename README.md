# zig-audit

Tokenizer-based Zig sensitive-source checker.

zig-audit indexes sharp Zig constructs with Zig's own tokenizer. Current projects
acknowledge intentional findings beside the source itself, so the reason and the
construct move together in review.

## Daily use

From a configured project root:

    zig-audit check

A clean check emits one structured summary on stdout:

    {"schema":"zig-audit.check/v1","type":"summary","result":"pass","acknowledged":17,"files_checked":4}

For Captain's manual red-pen pass, `-v` / `--verbose` prints every accepted
acknowledgement as JSONL before the same summary:

    zig-audit check -v
    {"schema":"zig-audit.check/v1","type":"acknowledgement","path":"src/window.zig","line":42,"rule":"opaque_type","reason":"SDL owns this ABI handle layout."}
    {"schema":"zig-audit.check/v1","type":"summary","result":"pass","acknowledged":17,"files_checked":4}

An unacknowledged sharp construct is also an explicit JSONL record, followed by a
failing summary and process exit 1:

    {"schema":"zig-audit.check/v1","type":"finding","path":"src/main.zig","line":17,"rule":"discard","message":"acknowledgement required","source":"_ = value;"}
    {"schema":"zig-audit.check/v1","type":"summary","result":"fail","acknowledged":0,"files_checked":3}

For exploration without enforcement:

    zig-audit scan src build.zig

`scan` emits one `zig-audit.scan/v1` JSON object per finding and includes the source
line number. Use `zig-audit scan -- -generated.zig` when an operand begins with `-`.

Checker identity has three equivalent spellings:

    zig-audit version
    zig-audit --version
    zig-audit -v

Root and command-specific help are ordinary text:

    zig-audit --help
    zig-audit help check
    zig-audit scan --help

The command grammar is explicit. Unknown commands do not fall back to scanning
paths, and project config is only accepted through `--config PATH`.

### CLI contract

`zig-audit` uses three exit classes:

- `0`: the command completed successfully; for `check`, the source policy passed;
- `1`: `check` ran successfully and found a source-policy/census failure;
- `2`: usage, configuration, source-discovery, I/O, or tool failure.

Successful command data and policy findings go to stdout. Tool/usage failures leave
stdout empty and emit one `zig-audit.error/v1` JSON object on stderr. `check`,
verbose acknowledgements, legacy census changes and `scan` use JSONL because they
may emit multiple records.

The default project config is `.zig-audit.json` in the current directory. With an
explicit config such as:

    zig-audit check --config /work/project/.zig-audit.json

the config file's parent directory (`/work/project`) is the project root. Git source
discovery, source reads, include/exclude roots and legacy baseline paths are all
resolved against that root. The caller's current directory does not silently become
the audited project. For `source: "git"`, that root may be inside a Git worktree:
Git returns paths relative to the config directory, so sibling packages and their
source cannot enter the audit by accident. Nested package configs may exclude
their own nested child-package roots; each child runs a separate audit gate.

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
- every successful acknowledgement is counted in the default summary and emitted as an acknowledgement JSON record with `-v` / `--verbose`.

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

As of version 0.4.2, a package's config can live inside a larger Git
worktree. Git scopes source paths relative to that package directory, so
independent nested build roots can use their own configurations without
requiring nested Git repositories. This changes discovery only, not the
stable ruleset, acknowledgement grammar, or project policy.

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
all Git-owned Zig source. These paths are relative to the config-owned project root.

`minimum_ruleset` prevents an older checker from silently providing weaker coverage.

Schema 1 baseline files remain readable only as a migration bridge for existing
consumers. New projects use schema 2. The legacy `accept` command is intentionally
unavailable for schema 2.

## Build-once artifact installation via Paste-bin

zig-audit owns a small deterministic prebuilt archive, its validation,
immutable release trees and rollback. Fleet or the operator owns source-revision
selection, building, the ephemeral Paste-bin handoff and **independently
selected** expected archive hash and size. No central release manager or signer
is involved.

Build with the official pinned Zig compiler. Release x86_64 artifacts use a
baseline CPU profile; optimized `-Dcpu=native` is rejected so they work on
older Fleet hosts.

```sh
zig build -Doptimize=ReleaseSafe -Dcpu=baseline
./tools/package \
  --binary zig-out/bin/zig-audit \
  --target x86_64-linux \
  --revision EXACT_40_CHARACTER_GIT_SHA \
  --output /private/zig-audit-artifact
```

The builder must ensure the selected Git revision is clean, pushed, and equals
the source compiled into the artifact. For ARM64 packages created on an x86
builder, use `--target aarch64-linux --identity-from PATH_TO_NATIVE_COMPANION`
with an x86 binary compiled from that **same** revision. The packager checks
the ARM ELF machine without attempting to execute it; the ARM node's installer
executes both version aliases. Its adjacent
`zig-audit.artifact-manifest/v1` records SHA-256, size and selected revision;
the manifest is **digest evidence, not independently authenticated publisher
identity**. `package.json` uses `zig-audit.package/v2` with the source
revision, target, embedded binary hash and stable ruleset.

Targets download the same exact artifact through the existing Paste-bin lane.
The trusted product installer (from approved source, **not code supplied by the
unverified archive**) accepts the independently selected values:

```sh
./install \
  --promote-artifact /private/stage/zig-audit-0.4.2-x86_64-linux.tar.xz \
  --revision EXACT_40_CHARACTER_GIT_SHA \
  --sha256 EXACT_64_CHARACTER_ARCHIVE_SHA256 \
  --size EXACT_BYTE_COUNT \
  --prefix /private/zig-audit-prefix
```

The installer rejects missing or mismatched pins, invalid archive inventories,
incorrect source revisions, wrong native architecture, inconsistent internal
hashes, and mismatched `-v` or `--version` executable identities. The
`zig-audit.artifact/v1` receipt says
`operator-pinned-source-build-not-signed`. Artifact SHA-256 validates agreement
with the separately selected expected bytes, **not a cryptographic signature**.

The stable command is `/private/zig-audit-prefix/bin/zig-audit`. The installer
never overwrites immutable release trees, stores previous and current symlink
targets, and retains exact old releases and any historic release-pm receipt files:

```sh
./install --status --prefix /private/zig-audit-prefix
./install --rollback --prefix /private/zig-audit-prefix
```

The existing Fleet-wide `~/.local/bin/zig-audit` is still an older regular
source-cutover binary. It must not be silently replaced by an installer requiring
a product-owned symlink. First prove a separate attended transition of the
installed PATH entry/rollback; private-prefix acceptance does not constitute
that live transition.

For source development:

```sh
zig build test
zig build check
```

## Design boundary

Project configuration describes source scope and minimum checker capability. It does
not redefine Zig constructs or contain project architecture policy.

Historical design/dogfood notes live in `docs/journeys.md`.
