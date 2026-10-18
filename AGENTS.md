# zig-audit source contract

zig-audit is a small standalone Zig source checker. It owns generic detection,
source-local acknowledgement mechanics, and ruleset compatibility. It does not own
the architecture, style, or policy of consuming projects.

## Boundaries

- Use Zig's tokenizer for Zig syntax awareness. Do not grow a parallel regex parser.
- Enforced rules are generic Zig observations. Sharp constructs may require explicit local review; structural contract failures may be fix-only.
- Intentional findings are acknowledged beside source with an exact rule marker and
  non-empty reason. Do not add new baseline/allowlist mechanisms.
- Schema 1 baseline support is migration compatibility only. New integrations use
  schema 2 source acknowledgements.
- Project config may describe source scope and minimum checker ruleset. Do not add
  product-specific nouns, regex exceptions, or architecture rules.
- `check` is read-only.
- One acknowledgement consumes one exact acknowledgeable finding and must fail when stale or bound to the wrong rule. Fix-only rules such as `pub_without_doc` must never gain acknowledgement escapes.
- Ordinary `check` stays concise: successful acknowledgements are summarized, while `-v` / `--verbose` emits every accepted site for manual review.
- A newer enforced rule increments `stable_ruleset` when an older checker could
  otherwise produce materially weaker coverage.
- Preserve deterministic scan output and duplicate findings.
- Avoid overlapping findings when a more specific rule already names the same sharp
  construct.

## Artifact boundary

- Builds come from the Git revision selected by Fleet/operator. Paste-bin only transports immutable bytes; SHA/size pins must be selected independently of the received archive.
- The product installer accepts `--promote-artifact` plus revision, SHA-256 and size; it validates package/v2 identity and owns activation/rollback in an explicit prefix. It must not fabricate a release-pm.stage/v1 receipt or execute untrusted new installer code.
- After promotion, PATH is one regular `bin/zig-audit` executable, with at most one exact `share/zig-audit/previous/zig-audit` backup. No accumulated releases, pointer symlinks, or historical receipts. Inspect and retire only known legacy trees after a recoverable activation.
- The old unrecorded 0.4.1 source-cutover command (or a legacy release lacking a binary digest) requires an explicit `--adopt-current-sha256` from an independently selected existing-binary hash. Do not silently take over unknown binaries, introduce a release manager, signer, or registry, or promote live Fleet commands without an attended approval.

## Source bar

Keep the implementation direct and dependency-free. Detection/acknowledgement changes
need fixtures for positive cases, whitespace variation where relevant, comments and
strings, wrong-rule markers, stale markers, duplicate findings, and malformed reasons.

Before a checkpoint run:

1. `zig fmt --check build.zig src`
2. `zig build test`
3. `zig build`
4. `git diff --check`

Dogfood enforcement changes against at least one substantial real project before
treating them as stable.
