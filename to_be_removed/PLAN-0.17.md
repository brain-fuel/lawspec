# LawSpec 0.17 implementation and acceptance

Portable collections (`Set`, `KeyVal`, `Queue`, `Stack`, `Deque`) with a
portable total order, and asynchronous adapters lowered to each target's own
task abstraction.

## Scope and design

- **Order.** `Keyed` is a capability derived over stored fields, like `Eq`.
  `compareValues` in `Core/Value.hs` and a `compare` in each of the seven
  runtimes agree: exact numbers by value, text and sequences by code point or
  unit, `false < true`, absent before present, lists lexicographically,
  `Nothing < Just`, other data by tag string, then fields.
- **Collections are a LawSpec unit.** `LawSpec.Collections` generates
  `lawspec.collections` per program with only the types a source uses and does
  not shadow. Each container is ordinary data with one internal constructor
  (`SetItems items :: List a`); its operations are checked definitions that
  branch on `prelude.compare`. Units get it as an implicit import (alias
  `lawspecCollections`) that hides the internal constructors, and
  `prelude.<op>` resolves to its definitions. `size`, `isEmpty` and `toList`
  elaborate to Core matches.
- **Canonical values.** Core checks that a Set or KeyVal is sorted and
  without repeats; generation and every codec canonicalise.
- **Natives (hybrid, functional).** Idiomatic sets and maps where the target
  compares the element by value; otherwise immutable structures in canonical
  order handled by runtime functions, not classes. Haskell's collection codecs
  are a separate `LawSpecCollectionCodecs.hs`, emitted only when used.
- **Shallow schemas.** Construction and matching no longer revalidate whole
  values, and checked definitions no longer validate each call; values are
  validated at adapter boundaries. This was needed for collections over
  recursive data to test in reasonable time.
- **Async.** `Core.Declaration` gains `declarationAsync` (the `Declaration`
  pattern synonym keeps the old shape). Stubs return each target's task, and
  each emitter awaits a call where it is made: `asyncio.run`, `await` in async
  properties, `join()`, `runBlocking`, `Await()` on a goroutine task,
  `unsafePerformIO`, and a std-only `block_on` in Rust.

## Deviations from the plan

- Data order by constructor tag rather than declaration index: the runtimes'
  scalar layers have no schema.
- Async calls are awaited in order where they are made; independent calls do
  not overlap yet.
- Asynchronous adapters cannot be bound to native functions yet.
- Python, JavaScript and Go use tuples, arrays and slices for structured keys.
- Order vectors are covered by Hspec and the acceptance suites rather than a
  shared JSON file replayed by each runtime.
- Literal typing: generic applications with numeric literals are checked
  against the other arguments' types.

## Limits

- `Queue`, `Stack` and `Deque` are not indexed by size.
- No literal syntax for collections.
- Actors, processes and supervision are a separate later feature.

## Evidence (2026-10-01)

- `stack test`: 637 examples, including CollectionsSpec (13) and AsyncSpec (12).
- Acceptance on all eight targets: `collections` (dedupe, counts, fifo, rotate
  and rows mutants) and `async` (value, throws and negative mutants), plus the
  0.16 suites after the schema changes.
