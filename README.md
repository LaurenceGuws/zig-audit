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
the audited project. For `source: "git"`, that directory must itself be the Git
worktree root; zig-audit refuses a nested directory that would otherwise inherit an
enclosing repository.

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

## Install

Release packages are prebuilt and owner-installed. `release-pm` authenticates and
stages the archive; zig-audit owns archive validation, target-native version probes,
activation, rollback, and retention inside an explicit prefix.

Build a release binary with the repository's pinned Zig compiler:

    zig build -Doptimize=ReleaseSafe

Create a deterministic archive plus unsigned `zig-audit.release/v1` manifest:

    ./tools/package \
      --binary zig-out/bin/zig-audit \
      --target x86_64-linux \
      --output /private/new-zig-audit-package

After release-pm has authenticated and staged that exact archive, hand its payload
and `release-pm.stage/v1` receipt to the repository-owned installer:

    ./install \
      --artifact /private/cache/requests/REQUEST/verified/payload \
      --receipt /private/cache/requests/REQUEST/verified/receipt.json \
      --prefix /private/zig-audit-prefix

The stable executable is then:

    /private/zig-audit-prefix/bin/zig-audit

Inspect or roll back the isolated prefix explicitly:

    ./install --status --prefix /private/zig-audit-prefix
    ./install --rollback --prefix /private/zig-audit-prefix

The installer never overwrites a release tree. Updates retain the old release and
atomically switch the `current` activation symlink. `previous` records the prior
activation, so rollback swaps the two retained releases. Release pruning is not
implemented.

The package archive contains only `package.json` and `bin/zig-audit`. The installer
requires the authenticated release-pm receipt to match archive size/hash, requires
package identity/version/target to match the authenticated selection, checks the
binary digest, and independently runs both `-v` and `--version` before activation.

For source development, the repository still pins its Zig compiler in `.zigversion`:

    zig build test
    zig build check

## Design boundary

Project configuration describes source scope and minimum checker capability. It does
not redefine Zig constructs or contain project architecture policy.

Historical design/dogfood notes live in `docs/journeys.md`.
