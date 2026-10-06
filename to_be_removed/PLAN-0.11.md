# LawSpec 0.11 implementation and acceptance

Close the 0.10 release-verification gate, restore tower-polymorphic adapter
results, and introduce natural-indexed families: the first step from the
"Beyond 0.10" direction in [LANGUAGE.md](LANGUAGE.md#roadmap) towards
dependent specification. Indices are evidence. They are checked and discharged
at test time through the existing refinement machinery, not by changing target
type systems.

## 1. Release verification carried over from 0.10

The 0.10 audit left the remote CI gate pending
([NATIVE-BINDINGS.md](NATIVE-BINDINGS.md#remaining-acceptance-gates)). Remote CI
has failed on `main` since 0.9: `targets (kotlin)` and `targets (haskell)` stop
at `tools/integration.mjs`, so later steps in those jobs never ran.

- Root cause: 0.9 moved Kotlin and Haskell adapter results onto typed codecs.
  This narrowed the abstract `Integer` result from the tower-polymorphic
  `Number` / `LS.IntegerValue` (see `nativeRepresentation` in
  `src/LawSpec/Scalar.hs`) to `BigInteger` / `Integer`. Java kept the
  polymorphic bridge. `Integer` is the top of the integral tower. Adapters may
  return any integral native value, and the result bridge discharges the
  logical domain. Arguments remain concrete.
- Fixed in `CoreNativeScalarEmit` for stubs, direct calls and partial
  application. A regression test covers Java, Kotlin and Haskell.
- The scalar mutation fixtures for Kotlin and Haskell still used the untyped
  `Value`/`Scalar` API for `Symbol`, `Decimal`, `Utf16Text` and `Optional`.
  They now use the documented typed representations, and every mutant fails at
  test time rather than compile time.
- Acceptance: every CI job green remotely, with both machine profiles and the
  installed native-binding runs.

## 2. Natural-indexed families

```lawspec
type Vec (n :: Natural) (a :: Type) is
  | Nil where n = 0
  | Cons head :: a tail :: Vec m a where n = m + 1
end
```

- Source: data parameters may be kinded `Natural`. Each constructor states its
  index equation with `where <index> = <index expression>`. Index expressions
  are natural literals, index variables introduced by fields of indexed type,
  `+` and `*` by literals. `Natural` is also usable as an ordinary value type
  (non-negative, unbounded).
- Elaboration (front end only; Core and backends are unchanged):
  - erased data `Vec a`, with the same constructors and index arguments removed
    from field types;
  - one checked total measure per index parameter, computed structurally
    from the constructor equations (`nOfVec`, surfaced to users as `index`);
  - every occurrence of `Vec e a` becomes the refinement
    `(v :: Vec a where nOfVec v == e)`, so dependent signatures such as
    `replicate :: (n :: Natural) -> a -> Vec n a` become checked contracts.
- Diagnostics: indices outside `Natural`, unsolvable or non-linear equations,
  unbound index variables, constructors without an equation, and GADT forms
  beyond natural indices (type-refining result signatures) are rejected with
  distinct messages.

### Generation by index

Filtering an erased generator for a fixed index does not terminate in practice.
The prototype showed `(xs :: Vec 2 Int8)` hanging under Hypothesis, while
free-index laws and contracts pass. Two complementary plans:

- **Free index** (`for all (n :: Natural) (xs :: Vec n a)`, with `n` otherwise
  unconstrained): generate `xs` from the erased type and bind `n` to its
  measure. This needs no backend change.
- **Fixed or shared index** (`Vec 2 a`, `zip :: Vec n a -> Vec n b -> ...`): the
  runtime strategy builders already allocate exact node budgets per
  constructor. Extend the schema with each constructor's index equation.
  Generation for a target index `k` then selects constructors whose
  equation admits `k` and solves the child indices backwards (`m + 1 = k`,
  so `m = k - 1`). Shrinking stays within the index, because the index is
  a generator parameter and not a filter. This covers all seven runtime
  strategy implementations (Python, JavaScript/TypeScript, Java, Kotlin, Go,
  Haskell, Rust).

## Acceptance

- Compiler: parsing, kind checks, equation checks, elaborated Core,
  diagnostics, native/WASM parity.
- Examples: `Vec` replicate/append/zip/head, plus a height-indexed tree. Laws
  over free, fixed and shared indices execute on all eight targets in both
  machine profiles, with mutants for wrong lengths, dropped elements and
  swapped order.
- Formatting, ownership/regeneration and packaged installation unchanged.
- Version 0.11.0, release notes, LANGUAGE/REFINEMENTS reference updates, rebuilt
  WASM and fingerprints agree. Publication follows [PUBLISHING.md](PUBLISHING.md).

## Current implementation evidence (2026-09-29)

- Local reproduction of both remote failures. After the emitter fix the
  Kotlin `integration`, `algebra`, `scalar` (64/32), `refinement` (64/32) and
  installed native-binding (default and compact 32-bit) steps pass. The Haskell
  `integration` and `algebra` steps pass. `stack test` passes 510 examples.
- A hand-written elaboration of `Vec` (erased type, measure, value-indexed
  named refinement) checks and runs on Python for free-index laws and
  dependent result contracts. Fixed-index quantification hangs as predicted.

## Implementation evidence (2026-09-29, release candidate 225663f)

- Tower fix: Kotlin and Haskell integration, algebra, scalar (64/32, mutants),
  refinement (64/32) and installed native-binding runs pass locally. Remote
  `targets (kotlin)` passed on 0654a41, the first green Kotlin job since 0.9.
- Indexed families: parser, elaboration (`LawSpec.Indexed`), implicit index
  binding, `Natural`, diagnostics. `IndexedSpec` has 14 examples; `stack test`
  passes 524.
- Index-directed generation: planner `IndexedGeneration`, plus runtimes and
  harnesses for Python, JS/TS, Java, Kotlin, Go, Haskell and Rust.
  `tools/indexed-integration.mjs` passes on all eight targets in the default and
  compact 32-bit profiles, and rejects the replicate, append, zip and flatten
  mutants.
- Integrity, boundaries, parity (864 combinations), npm (77) and package-smoke
  pass locally. Version 0.11.0, with release notes and docs.
- Bundled example constructors are VNil/VCons/Tip/Bin: `lawspec examples`
  compiles all specs as one program, and constructor names are not unit-scoped
  (a pre-existing limitation, now future work).

## Next milestones

0.11.0 is released. The roadmap is in [LANGUAGE.md](LANGUAGE.md#roadmap):
0.12 proof-producing dependent layer, 0.13 domain modeling primitives, 0.14
cross-unit imports and packages, and 0.15 the evidence/discharge model. The
0.12 plan is in PLAN-0.12.md.
