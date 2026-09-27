# zig-audit source contract

zig-audit is a small standalone Zig source checker. It owns generic detection and
reviewed-census mechanics. It does not own the architecture, style, or policy of
the projects that consume it.

## Boundaries

- Use Zig's tokenizer for Zig syntax awareness. Do not grow a parallel regex parser.
- Stable rules are generic Zig observations proven useful across projects. A project's
  baseline records reviewed sites; it does not redefine a rule.
- Experimental observations may appear in `scan` before promotion into the stable
  ruleset.
- Project config may describe source scope, baseline location, and minimum checker
  ruleset. Do not add product-specific nouns or project architecture rules.
- `check` is read-only. `accept` is the explicit baseline mutation surface.
- A newer stable rule increments `stable_ruleset` when an older checker could
  otherwise produce materially weaker coverage.
- Preserve deterministic output and duplicate findings.

## Source bar

Keep the implementation direct and dependency-free. New detection rules need tokenizer
fixtures covering positive cases, whitespace variation where relevant, and false
positives in strings/comments.

Before a checkpoint run:

1. `zig fmt --check build.zig src`
2. `zig build test`
3. `zig build`
4. `git diff --check`

Dogfood generic changes against at least one substantial real project before treating
them as stable.
