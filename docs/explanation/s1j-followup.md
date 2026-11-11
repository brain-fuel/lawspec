---
id: lawspec.review.s1j-followup
kind: explanation
title: S1.j follow-up disposition
---
# S1.j follow-up disposition

This page covers the reports that were open after 0.32.0: 14 and 16 to 21,
with the larger-model part of report 6. It continues the
[S1.j disposition](s1j-disposition.md). The reporter's projects were not
supplied, so every result here comes from reduced fixtures and local runs on
macOS ARM64. A status of "changed" means the code changed and its regression
passes. It does not mean the original project was run.

| Report | Status in 0.33.0 | Change and evidence | Still open |
| --- | --- | --- | --- |
| 6 | Changed | A value's fields are validated once when it is built, not again at every enclosing constructor. A 64-element list literal takes 1,101 evaluation steps, down from 5,197, and the count grows linearly. | The original recursive model. |
| 14 | Changed | Mutually recursive checked definitions are admitted by size-change analysis, with a checked `decreases` clause as fallback ([definitions](../reference/language/definitions.md)). The `mutual-recursion` suite passes on all 18 program targets with both mutants rejected. | Mutual induction in law proofs stays an explicit "unsupported" result. Cycles stay within one unit. Mutual tail calls are ordinary calls, not loops, on Swift and Rust. |
| 16 | Changed in canon and Rice's Tax, not released | canon skips `.mut/`. Rice's Tax ignores `.mut` at `init`, removes mutant copies when a run ends, uses unsigned string offsets, and passes requests as bytes. | Both are unreleased branches, and the LawSpec pin is still 0.3.2. Behaviour past 2 GB was not measured. |
| 17 | Changed | The totality proof shares a `let` binding instead of copying its conditional or match into every use. A ten-binding chain feeding a record took 46.5 s and now takes 0.09 s; chains of 12 and 14 timed out at 120 s and now take 0.1 s. The audit reports every failing definition, not only the first. | The original definition. |
| 18 | Changed | `npm/package-lock.json` pins the optional native packages, `tools/npm-lock.mjs` regenerates it, and CI checks it. | `npm ci` from a checkout needs the 0.33.0 native packages to be published. |
| 19 | Changed | A Go unit receives a bound-handler bridge only for abilities it uses. | The original package layout. |
| 20 | Partly changed | See [Cache and compile time](#cache-and-compile-time). | Reuse across runs, and the `generate` slowdown. |
| 21 | Changed | `prelude.split`, `trim`, `words` and `lines` exist on every target ([sequences](../reference/language/sequences.md#pieces-of-a-text)). `prelude.map` and `prelude.filter` work over lists on every target, and one `map` serves lists and `Either` ([sequences](../reference/language/sequences.md)). A definition can be written once over either with `requires Mappable m` ([definitions](../reference/language/definitions.md)). The `text-pieces` and `list-mapping` suites pass on all 18 program targets with every mutant rejected. | `Mappable` has two built-in instances, `List` and `Either`; projects cannot add their own. The typed fast-path backends run list `map` and `filter` through the portable runtime. Law proofs report a list `map` or `filter` as an explicit "unsupported" node. |

## Cache and compile time

[Raw measurements](s1j-followup-benchmarks.jsonl) compare optimised native
builds of main before this work and of this branch, on one machine, one run
each. They are observations, not guarantees.

What changed:

- `check` compiles once for all targets. Native bindings no longer enter the
  compile key.
- Each unit is rendered and hashed once for its three cache keys, not three
  times.
- `mutate` keeps the compiler cache in its copies and restores only the
  mutated files between mutants. A mutant that edits only owned generated
  files skips regeneration, so generated code can be mutated.

What the measurements show:

| Probe: three units, 3,087 lines | Before | After |
| --- | --- | --- |
| Check with a new cache directory | 5.49 s | 3.79 s |
| The same check again | 5.40 s | 4.36 s |
| Check with no cache directory | not measured | 3.52 s |

A second run is not faster than the first on this probe. The cache tables
for definition templates, unit validation and law expansion are all read
from disk on the second run, but they hold the cheap part of this probe.
Parsing is about 60% of the check and nothing persists it. Reading the
stored definition templates costs more than the first run spent on them.

A project whose time goes to admitting definitions is a different case, and
the reported one is of that kind. On main, a single expensive definition
took 29.8 s with a new cache and 15.1 s on each later run: the unit's audit
was reused and a second pass over the same definition was not. That
definition is the report 17 shape, which now takes a tenth of a second, so
this branch has no slow-admission probe left to measure reuse on.

Not done:

- No table persists admission per definition. An edit to one definition
  re-admits its whole unit.
- A unit whose definition templates weigh more than the table's budget is
  recomputed on every run. `LAWSPEC_CACHE_TRACE=1` prints `over-budget` for
  such an entry, with each table's time, on standard error.
- The `generate` slowdown against 0.31.3 was not profiled.
- `npm/test/cache.test.mjs` has no assertion that a warm run admits nothing.

## Other findings

- **Constructor predicates calling definitions.** A predicate that calls a
  non-recursive definition already works, by inlining. One that calls a
  recursive definition fails while the data declaration is elaborated, before
  the audit that the plan meant to relax. Supporting it needs definitions in
  scope for data predicates, Core predicates that contain calls, and module
  cycles in the emitters. It is not implemented.
- **Rust layout.** The Rust backend's output differs from `rustfmt` when a
  projection of a match is a nested call argument, for example
  `1 + itemLines item.children`. The mutual-recursion example binds the field
  in a pattern instead. The gap is open.
- **Precedents.** The size-change decision cites Idris 2's
  `Core/Termination/SizeChange.idr`, Lean 4's `termination_by`, SPARK's
  `Subprogram_Variant`, Why3's `variant` and Rocq's `fix`. Only the quoted
  statements in the reference records were read from the primary sources.
  LawSpec generates and discharges its own obligations with the built-in
  entailment; there is no proof checker or certificate, and Z3 takes no part
  in admission.

## Not confirmed

- Any of the reporter's original projects or repros.
- Linux, x64 and WSL2. Every run here was macOS ARM64.
- Report 4 on native x64 under Node 22.
- Rice's Tax past 2 GB of memory.
