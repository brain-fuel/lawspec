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

The "Still open" column was rechecked on 0.36.1; what changed after 0.33.0
is in [Since 0.33.0](#since-0330).

| Report | Status in 0.33.0 | Change and evidence | Still open in 0.36.1 |
| --- | --- | --- | --- |
| 6 | Changed | A value's fields are validated once when it is built, not again at every enclosing constructor. A 64-element list literal takes 1,101 evaluation steps, down from 5,197, and the count grows linearly. | The original recursive model. |
| 14 | Changed | Mutually recursive checked definitions are admitted by size-change analysis, with a checked `decreases` clause as fallback ([definitions](../reference/language/definitions.md)). The `mutual-recursion` suite passes on all 18 program targets with both mutants rejected. | A law that needs induction over a mutually recursive group is not proved: it ends `incomplete`, not `proved`. Cycles stay within one unit. |
| 16 | Changed in canon and Rice's Tax, not released | canon skips `.mut/`. Rice's Tax ignores `.mut` at `init`, removes mutant copies when a run ends, uses unsigned string offsets, and passes requests as bytes. | Both are unreleased branches, past the canon 0.2.3 and Rice's Tax 0.4.3 releases LawSpec pins. Behaviour past 2 GB was not measured. |
| 17 | Changed | The totality proof shares a `let` binding instead of copying its conditional or match into every use. A ten-binding chain feeding a record took 46.5 s and now takes 0.09 s; chains of 12 and 14 timed out at 120 s and now take 0.1 s. The audit reports every failing definition, not only the first. | The original definition. |
| 18 | Changed | `npm/package-lock.json` pins the optional native packages, `tools/npm-lock.mjs` regenerates it, and CI checks it. | None. The lock pins the published `@goforgedev` native packages of each release. |
| 19 | Changed | A Go unit receives a bound-handler bridge only for abilities it uses. | The original package layout. |
| 20 | Partly changed | See [Cache and compile time](#cache-and-compile-time). | Per-definition reuse across runs, and the `generate` slowdown. |
| 21 | Changed | `prelude.split`, `trim`, `words` and `lines` exist on every target ([sequences](../reference/language/sequences.md#pieces-of-a-text)). `prelude.map` and `prelude.filter` work over lists on every target, and one `map` serves lists and `Either` ([sequences](../reference/language/sequences.md)). A definition can be written once over either with `requires Mappable m` ([definitions](../reference/language/definitions.md)); that capability is not in 0.33.0 and ships in the next 0.33 patch. The `text-pieces` and `list-mapping` suites pass on all 18 program targets with every mutant rejected. | Projects cannot declare their own instances of `Mappable`, `Filterable`, `Foldable` or `Appendable`. |

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

| Probe: three units, 3,087 lines | Main before this work | 0.33.0 | With the parse table |
| --- | --- | --- | --- |
| Check with a new cache directory | 5.49 s | 3.79 s | 3.83 s |
| The same check again | 5.40 s | 4.36 s | 2.22 s |
| Check with no cache directory | not measured | 3.52 s | not measured |

The last column was measured after 0.33.0, in a later session on the same
machine; its second-run figure is the median of three.

In 0.33.0 a second run was not faster than the first on this probe: nothing
kept the parse, and reading the stored definition templates cost more than
inferring them. After 0.33.0:

- Each source's parse is stored, keyed by the source, the headers and
  indexed families its imports give it, its harness files and the
  coordinates of inserted names. On this probe parsing takes 1.1 s and
  reading the stored parse 0.2 s.
- Definition templates are kept in memory only. Reading them from disk took
  0.9 s on this probe; the second run is 0.7 s faster without the table and
  uses half the memory.

The stored parse has a cost. It takes 10.6 MB on disk for these 3,087 lines,
and the second run's peak memory is 558 MB against 320 MB for the first.
About 1.9 s of the second run is work no table holds, and it was not
profiled.

A project whose time goes to admitting definitions is a different case, and
the reported one is of that kind. On main, a single expensive definition
took 29.8 s with a new cache and 15.1 s on each later run: the unit's audit
was reused and a second pass over the same definition was not. That
definition is the report 17 shape, which now takes a tenth of a second, so
this branch has no slow-admission probe left to measure reuse on.

Not done:

- No table persists admission per definition. An edit to one definition
  re-admits its whole unit.
- The cache directory is never pruned, so stored parses of edited sources
  accumulate until the folder is removed.
- The `generate` slowdown against 0.31.3 was not profiled.
- No test asserts that a warm run admits nothing. `npm/test/cache.test.mjs`,
  which lacked it, was removed in 0.36.1, and no test since makes that
  assertion.

## Since 0.33.0

Each change below is a release's changelog entry; the evidence is its
regression suite, still on reduced fixtures.

- **Mutual tail calls (report 14), 0.35.0.** Checked definitions that call
  each other in tail position are joined into one loop on every target (F#
  keeps them as tail calls). The `deep-recursion` suite runs a 200,000-deep
  chain on all 18 targets.
- **Laws over mutual recursion (report 14), rechecked on 0.36.1.** `lawspec
  prove` on the mutual-recursion example proves all six of its laws, by
  unfolding the group as SMT-LIB `define-funs-rec`. An added law that needs
  induction over the group, `itemLine item >= 1` for every `item`, ended
  `incomplete (timeout)`: an explicit result, not a proof.
- **List operations (report 21), 0.35.0 and 0.36.0.** The solver reasons
  about `map`, `filter`, `all`, `any`, `contains`, the folds, `concat`,
  `length` and `++` through their definitions in `lawspec.instances`
  (0.35.0). `Filterable`, `Foldable` and `Appendable` join `Mappable` as
  capabilities a definition may require (0.35.0). The typed fast paths run
  `map`, `filter` and the folds as native code on every target (0.36.0).
- **Reuse across runs (report 20), 0.36.0.** A `check` of a project with
  mappings reuses its selection of derived inverses from the cache directory
  and compiles once instead of twice; a warm check of a 7-unit project went
  from 9.7 s to 6.9 s natively. Per-definition admission is still not
  persisted, by the owner's decision of 2026-11-17, to be revisited only if
  admission becomes a larger share of check time.
- **Field restrictions calling recursive definitions, 0.34.1.** They are
  still unsupported, but now refused with a message that names the function
  and says why.
- **Native packages (report 18).** Each release since 0.33.0 published its
  `@goforgedev` native packages, so `npm ci` from a checkout resolves them.

## Other findings

- **Constructor predicates calling definitions.** A predicate that calls a
  non-recursive definition already works, by inlining. One that calls a
  recursive definition fails while the data declaration is elaborated, before
  the audit that the plan meant to relax. Supporting it needs definitions in
  scope for data predicates, Core predicates that contain calls, and module
  cycles in the emitters. It is not implemented. Since 0.34.1 such a
  predicate is refused with a message naming the function.
- **Rust layout.** The Rust backend's output differs from `rustfmt` when a
  projection of a match is a nested call argument, for example
  `1 + itemLines item.children`. The mutual-recursion example binds the field
  in a pattern instead. Rechecked on 0.36.1 with that form: the `rustfmt
  --check` step of the `mutual-recursion` suite still fails, because rustfmt
  breaks `Ok(` onto its own line around a method chain whose last argument
  is a `match`. The gap is open.
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
