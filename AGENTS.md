# zig-audit source contract

zig-audit is a small standalone Zig source checker. It owns generic detection,
source-local acknowledgement mechanics, and ruleset compatibility. It does not own
the architecture, style, or policy of consuming projects.

## Boundaries

- Use Zig's tokenizer for Zig syntax awareness. Do not grow a parallel regex parser.
- Enforced rules are generic Zig observations that merit explicit local review.
- Intentional findings are acknowledged beside source with an exact rule marker and
  non-empty reason. Do not add new baseline/allowlist mechanisms.
- Schema 1 baseline support is migration compatibility only. New integrations use
  schema 2 source acknowledgements.
- Project config may describe source scope and minimum checker ruleset. Do not add
  product-specific nouns, regex exceptions, or architecture rules.
- `check` is read-only.
- One acknowledgement consumes one exact finding and must fail when stale or bound to
  the wrong rule.
- Successful acknowledgements remain visible on stderr.
- A newer enforced rule increments `stable_ruleset` when an older checker could
  otherwise produce materially weaker coverage.
- Preserve deterministic scan output and duplicate findings.
- Avoid overlapping findings when a more specific rule already names the same sharp
  construct.

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
