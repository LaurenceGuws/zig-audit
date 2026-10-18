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

zig-audit builds one deterministic prebuilt archive per architecture. Fleet or
the operator chooses the source revision, builds the artifact and independently
selects its archive SHA-256 and byte size. Paste-bin transfers those immutable
bytes. A digest confirms the selected bytes, **not a publisher signature**.

The regular PATH command is a directly executable file; installed state holds
at most one immediately preceding regular binary for rollback. There is no
release-tree history, symlink activation, release-pm, or central release manager.

Build with the official pinned Zig compiler. Release x86_64 builds use a
baseline CPU profile, not the build machine's native ISA:

```sh
zig build -Doptimize=ReleaseSafe -Dcpu=baseline
./tools/package \
  --binary zig-out/bin/zig-audit \
  --target x86_64-linux \
  --revision EXACT_40_CHARACTER_GIT_SHA \
  --output /private/zig-audit-artifact
```

For ARM64 packages built on x86, pass `--target aarch64-linux` and
`--identity-from PATH_TO_NATIVE_COMPANION`, built from the **same source
revision**. The packager validates the ARM ELF machine and probes the
native companion. It must never attempt to execute ARM instructions on x86.
Only an ARM node can qualify actual ARM execution.

The archive contains exactly `package.json` (`zig-audit.package/v2`) and
`bin/zig-audit`. Its adjacent `zig-audit.artifact-manifest/v1` carries the
selected digest and size for review. The trusted owner installer comes from
previously approved local source, **not executable installer code in the
download**. The package declares revision, version, target, embedded binary
SHA-256 and stable ruleset.

After validating artifact selection, the trusted owner installer independently
checks archive inventory, package identity, architecture, digest, and the exact
`-v`/`--version` executable identities. Private-prefix qualification:

```sh
./install --promote-artifact /private/stage/zig-audit-0.4.2-x86_64-linux.tar.xz \
  --revision EXACT_40_CHARACTER_GIT_SHA \
  --sha256 EXACT_64_CHARACTER_ARCHIVE_SHA256 \
  --size EXACT_BYTE_COUNT \
  --prefix /private/zig-audit-prefix

./install --status --prefix /private/zig-audit-prefix
./install --rollback --prefix /private/zig-audit-prefix
```

The first promotion of the currently installed Fleet-wide **regular 0.4.1
source-cutover binary** requires an additional operator-selected SHA-256 of
that *existing* executable:

```sh
./install --status --prefix "$HOME/.local"
# Review adoption_required and observed_sha256 against the existing trusted command.
./install --promote-artifact /private/stage/zig-audit-0.4.2-x86_64-linux.tar.xz \
  --revision EXACT_40_CHARACTER_GIT_SHA \
  --sha256 EXACT_64_CHARACTER_ARCHIVE_SHA256 \
  --size EXACT_BYTE_COUNT \
  --adopt-current-sha256 INDEPENDENTLY_VERIFIED_EXISTING_BINARY_SHA256 \
  --prefix "$HOME/.local"
```

A recognized older release-managed symlink is also supported. If its previous
package metadata lacks a binary digest, the same explicit old-binary pin is
mandatory. The migration validates the previous executable first, then places
the old bytes at `share/zig-audit/previous/zig-audit`, atomically replaces
`bin/zig-audit` with a regular executable, and retires recognized old
releases, links and historical receipts. Any unowned data blocks cleanup.
A transient, durable activation intent supports repair if metadata publication
or cleanup fails after the PATH switch. It is removed on completion, not
retained as release history. Rollback and roll-forward swap the one previous
binary with current. No rollback generations accumulate.

**The live Fleet command remains 0.4.1 until Captain approves promotion.**
Testing a private prefix, or building a cross artifact, never constitutes
approval to alter the installed PATH entry.

For normal source development:

```sh
zig fmt --check build.zig src
zig build test
zig build check
zig build
```

## Design boundary

Project configuration describes source scope and minimum checker capability. It does
not redefine Zig constructs or contain project architecture policy.

Historical design/dogfood notes live in `docs/journeys.md`.
