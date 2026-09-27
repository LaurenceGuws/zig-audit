# User and agent journeys

Status: exploratory lab notes, not a settled product contract.

The experiment is useful only if it disappears into ordinary Zig work. The intended
happy path is not "remember to run another linter". It is closer to:

```text
edit
zig fmt
zig build check
```

and the existing muscle-memory gate becomes slightly more observant.

These notes map the decision paths before we decide how configuration, installation,
or build integration should finally look.

## What current dogfood already tells us

The current tokenizer prototype can reproduce the existing reviewed Howl and QAgent
sensitive-site baselines byte-for-byte when given the same source set.

The existing baseline identity is:

```text
path|kind|trimmed source line
```

That has useful properties:

- line-number-only movement does not create churn;
- moving or rewriting a sensitive expression does create review;
- duplicate identical sites remain representable;
- the baseline is readable in an ordinary Git diff.

Walker exposed one historical difference worth preserving as evidence rather than
silently deciding away: its scanner records at most one occurrence of a kind per
source line, while the older Howl/QAgent scanner records every occurrence.

The current Git history inspected in this session shows the reviewed-baseline family
in Howl and QAgent since 2026-07-20, with Walker adopting the expanded form on
2026-09-21. Older source-audit ideas may predate those commits.

## Product intent

A few principles currently look stronger than any particular implementation:

1. `zig-audit` owns the meaning and detection of Zig smells.
2. A project may eventually describe its source shape and integration needs, but it
   should not need to reimplement the checker or maintain copied regular expressions.
3. A reviewed baseline says "these sites are already known". It does not redefine
   `opaque`, `catch {}`, or any other Zig construct for that project.
4. New findings should be visible in the existing `zig build check` journey.
5. Intentional sharp code must be cheap to acknowledge and obvious in Git review.
6. Missing tooling on a fresh machine and malfunctioning installed tooling are
   different failure classes.
7. No inline suppression syntax is justified yet. Exact reviewed sites already give
   us a less invasive escape valve.

## Journey: ordinary edit, nothing interesting changed

```text
agent/user edits source
        |
        v
zig build check
        |
        +-- compile/tests/etc.
        |
        +-- zig-audit found
                |
                +-- source census == reviewed baseline
                        |
                        v
                       PASS
```

Desired experience: essentially silent. The checker should not demand attention when
nothing changed.

## Journey: accidental new sharp construct

Example:

```zig
persist(state) catch {};
```

```text
zig build check
        |
        v
new census differs from reviewed baseline
        |
        v
FAIL with the exact new site
        |
        +-- developer notices unintended error discard
        |
        v
rewrite source
        |
        v
zig build check -> PASS
```

The important property is that the compiler/check loop remains the teacher. The agent
does not need to remember a separate audit command.

## Journey: intentional new sharp construct

Example:

```zig
pub const NativeHandle = opaque {};
```

The checker should not claim this is wrong. It should claim only that it is new.

```text
zig build check
        |
        v
FAIL: one new sensitive site
        |
        +-- source is accidental -> rewrite it
        |
        `-- source is intentional
                |
                v
        explicit acknowledgement command
                |
                v
        reviewed baseline changes in Git
                |
                v
        zig build check -> PASS
```

Candidate UX, not yet an API commitment:

```text
zig-audit: reviewed census changed

+ src/native.zig|opaque_type|pub const NativeHandle = opaque {};

Review the source. If this site is intentional, update the reviewed census:
    zig-audit accept
```

The acknowledgement should be mechanical. It should not require hand-editing a
line-numbered suppression or inventing a regex exception.

The Git diff is the durable review point:

```diff
+src/native.zig|opaque_type|pub const NativeHandle = opaque {};
```

An agent can perform the acknowledgement, but cannot make that acknowledgement
invisible. Reviewers can see source and census move together.

## Journey: sensitive site disappears

Removal is healthy, but the baseline must not rot silently.

```text
source site removed
        |
        v
zig build check
        |
        v
census has a reviewed site missing
        |
        v
FAIL with one removed site
        |
        v
acknowledge/regenerate baseline
```

It is tempting to auto-accept removals. Doing so makes the baseline mutate during a
read-only check and hides source movement. The current evidence favours keeping
`check` read-only and making baseline mutation explicit.

## Journey: sensitive site moves or is rewritten

Because the proven identity contains path + kind + trimmed source line:

- inserting unrelated lines is free;
- moving a function inside the same file without changing the sensitive line is free;
- changing the sensitive expression is reviewable;
- moving it to another file is reviewable.

This has been a practical sweet spot so far.

Formatting-induced churn is still possible if the sensitive source line itself
changes shape. Zig's canonical formatter limits that problem substantially. We do not
yet have evidence that token-normalized baseline identities would be an improvement.

## Journey: checker is absent on a fresh machine

Captain's current preference is that this should probably warn rather than make a
new checkout unusable.

Candidate experience:

```text
zig build check
        |
        +-- ordinary project checks PASS
        |
        `-- zig-audit executable not found
                |
                v
WARNING: Zig sensitive-source audit was skipped
```

Important consequence: the overall check is now green-but-incomplete.

That state must be impossible to mistake for "zig-audit passed". Humans and agents
need a distinct, explicit message such as:

```text
warning: zig-audit not found; sensitive-source census was NOT checked
```

Open question: whether release/CI/checkpoint lanes should require the checker even if
ordinary local `zig build check` tolerates its absence.

## Journey: checker exists but cannot operate

These should not degrade into the fresh-machine warning:

```text
binary exists but crashes
config is malformed
configured source cannot be read
baseline cannot be parsed
checker cannot understand its config schema
```

Candidate outcome: hard failure.

Rationale: "not installed" is a bootstrap state. "installed but unable to verify"
is evidence of a broken check.

## Journey: checker learns a new smell

This is one of the main reasons the shared tool exists.

Suppose a future checker release learns `some_new_escape_hatch`.

For a project with no such sites:

```text
new checker -> same census -> PASS
```

Ideally there is no baseline churn merely because the executable version changed.

For a project with existing sites:

```text
new checker
    |
    v
new kind appears in census
    |
    v
zig build check FAILS
    |
    v
review those existing sites once
    |
    v
acknowledge baseline
```

That is intentional global policy propagation without copying a grep into every
repository.

### The stale-checker problem

The reverse direction is more dangerous:

```text
project expects knowledge of NEW_RULE
machine still has older zig-audit that has never heard of NEW_RULE
```

If the project's baseline happens to contain no `NEW_RULE` records, a sufficiently
old checker could otherwise report a false green.

This is the strongest current argument for some small compatibility marker in future
project configuration, for example a minimum ruleset epoch. It need not pin an exact
binary version.

Candidate only:

```json
{
  "schema": 1,
  "minimum_ruleset": 3
}
```

A newer checker could satisfy an older minimum without creating churn. An older
checker would fail clearly rather than silently under-check.

Do not commit to this shape until we have exercised checker evolution.

## Journey: false positive or contextually good sharp code

An indexed smell is not a verdict.

Examples already found in real source:

- Howl opaque public types intentionally enforcing abstraction boundaries;
- Vulkan opaque ABI handles;
- Walker's Win32 `INVALID_HANDLE_VALUE` representation using `@ptrFromInt`;
- Wayland's one current `allowzero` boundary.

The cheapest mitigation should therefore be the normal reviewed-site acknowledgement,
not a project-local rewrite of what `opaque_type` means.

This gives us two feedback levels:

```text
site is locally intentional
    -> acknowledge exact site in baseline

rule is globally noisy/wrong
    -> improve zig-audit itself
```

Avoiding per-project regex overrides keeps discoveries transferable across the Zig
estate.

## Journey: checker bug changes detection

A tokenizer/detection fix may legitimately alter the census.

Desired outcome is the same as a new rule:

```text
checker update
    |
    v
census diff
    |
    v
review exact additions/removals
```

The baseline should not be coupled to the exact executable version. Otherwise every
harmless checker release would churn every project.

A compatibility/ruleset marker, if we add one, should move only when stale tooling
could produce materially weaker coverage.

## Source selection

Source discovery is not solved yet. The first dogfood already exposed why it matters.

### Recursive filesystem walk

Pros:

- no external tool;
- finds untracked source automatically.

Observed failure:

- walking the Howl repository picked up ignored `temp/terminal-doom/zig-pkg/...`
  dependency/experiment material and exploded the census.

A generic `vendor`, `temp`, or cache blacklist quickly becomes another policy system.

### Git-owned/unignored Zig files

Howl's current audit uses the equivalent of:

```text
git ls-files --cached --others --exclude-standard -- '*.zig'
```

Pros:

- includes new untracked work before staging;
- obeys project ignore decisions;
- reproduced Howl's existing baseline exactly;
- avoids ignored experiment/cache/dependency forests.

Cons:

- depends on Git;
- source archives or non-Git consumers need another path;
- "owned by Git" and "part of this product check" are not always identical.

### Explicit source roots in project configuration

QAgent and Walker already behave roughly this way in their hand-written audits.

Possible future shape, deliberately only a sketch:

```json
{
  "schema": 1,
  "sources": {
    "include": ["build.zig", "src", "tests"],
    "exclude": ["vendor"]
  },
  "baseline": ".zig-audit.baseline"
}
```

Pros:

- deterministic without inferring repository conventions;
- works without Git;
- can represent multi-root repositories honestly.

Cons:

- source topology can drift from the config;
- another thing to maintain;
- requires good defaults or initialization UX.

### Deriving source from `build.zig`

Attractive because `build.zig` already owns much of the compilation graph.

But `build.zig` is executable build logic rather than a passive manifest. Real
repositories also have:

- target-conditional sources;
- tests and canaries;
- tools not in the default artifact graph;
- generated Zig;
- experimental modules;
- source that is deliberately maintained but not built on the current host.

It is useful input, but we do not yet know that it is a complete source-authority
surface for this checker.

## `zig build check` integration

The current projects already put their copied source audits under `zig build check`,
so the destination is proven.

The external binary introduces a new bootstrap problem.

### Direct external command

Conceptually:

```zig
const audit = b.addSystemCommand(&.{ "zig-audit", "check" });
check.dependOn(&audit.step);
```

Excellent when installed. Missing binary is a hard process-spawn failure.

### `b.findProgram`

Current Zig can synchronously search PATH with `b.findProgram`.

Useful for implementing "warn and omit the audit step when absent", but its own
documentation says it observes PATH during build configuration and poisons the
configuration cache.

It would also run while configuring unrelated build steps if used naively, meaning a
missing checker could warn during ordinary `zig build`, not just `zig build check`.

### `b.findProgramLazy`

Defers program lookup to a build step and avoids configure-time probing, but the
current FindProgram step hard-fails if the program is absent. That gives clean
step-local behaviour, not the desired fresh-machine warning.

### Custom optional build step

A custom step could search PATH only when `check` actually runs and distinguish:

```text
not found -> warning and success
found     -> execute checker, propagate result
```

That has good runtime semantics.

The unresolved cost is source coupling:

- copy the custom step into every project -> we recreate synchronization drift;
- import a Zig build helper package from zig-audit -> every project now has a pinned
  checker-source dependency;
- shell out through a tiny wrapper -> simple on Unix, less attractive for Windows and
  duplicates integration glue.

This is a real design question. Do not hide it behind a clever helper yet.

## Configuration failure cases worth preserving

If/when a project config exists, these should be boring and explicit:

| State | Candidate result |
|---|---|
| no config and checker integration is optional | clear skip or documented defaults |
| config valid, baseline matches | pass |
| config valid, baseline drifts | fail with additions/removals |
| malformed config | fail |
| unknown config schema | fail |
| unknown field under a strict schema | probably fail, prevents old tools silently ignoring new requirements |
| configured path missing | fail unless the config explicitly defines optionality |
| checker too old for required ruleset | fail with upgrade message |
| checker absent entirely | warn/skip in the friendly local path |
| checker crashes | fail |

The important distinction is that only **absence** is currently a candidate for
warning. Once the checker participates, uncertainty should not masquerade as success.

## Merge/conflict journey

Reviewed baselines are ordinary source-controlled data, so parallel branches may both
add sites.

A line-sorted textual baseline is helpful here:

- Git can often merge additions in different files cleanly;
- duplicate identical records are preserved;
- a conflict is visible rather than resolved by checker magic.

An eventual `zig-audit accept` should regenerate deterministically after resolving
source conflicts rather than trying to be a semantic merge engine.

## Agent-specific footguns

### Agent sees drift and immediately accepts it

This is possible today with copied allowlists too. The mechanism cannot prove that an
agent reasoned correctly.

What it can do is make the act durable and reviewable:

```text
source change
baseline change
```

The checker should never auto-edit the baseline during `check`.

### Agent disables the checker to get green

Keeping the audit wired directly into the familiar `check` graph makes this a
structural source/build change rather than an incidental command omission. Review can
see it.

### Agent edits checker policy inside the product repo

A standalone checker prevents this by default. Product repositories hold source scope
and reviewed observations, not copied detection expressions.

### Agent runs an old checker

This is the strongest unresolved deterministic-agent problem and is why a small
ruleset compatibility marker deserves experimentation.

## Candidate command journey

No names here are sacred, but a small surface seems enough:

```text
zig-audit check      # read config/source/baseline; no mutation
zig-audit scan       # print current deterministic census
zig-audit accept     # rewrite reviewed baseline from current census
```

Useful properties:

- `check` is read-only;
- `scan` is excellent for learning/debugging;
- `accept` is explicit mutation and produces an ordinary Git diff.

No command should edit product source.

## Questions to answer with dogfood rather than architecture debate

1. Does explicit JSON source configuration feel better than Git-owned discovery on
   Howl, QAgent, Walker, and a tiny repo?
2. How annoying are baseline changes in real agent sessions after adding a genuinely
   good opaque/ABI site?
3. Does a ruleset compatibility epoch solve stale binaries without becoming version
   bureaucracy?
4. Can `zig build check` tolerate a missing checker cleanly without copying build
   integration code into every repository?
5. Do we want a stricter CI/release/checkpoint lane, or is a very loud local warning
   enough in practice?
6. Does `path|kind|trimmed source line` remain pleasant once the new token-level
   rules have lived through refactors?
7. Should multiple occurrences of one kind on one source line count separately?
   Howl/QAgent currently say yes; Walker currently says no.
8. Which new checker rules prove useful enough to keep after a week of ordinary work?

Until those have dogfood answers, keeping the repository small is a feature.
