# Checked Eq-only set operations

This internal suite precedes canonical `Set` exports, literal notation and
`SortedSet` migration. The library fixture is generated from
`collectionsSource ["EqSet"]`, the same checked definitions that will back
authoring. Run `lawspec-dev generate --check` to reject a stale fixture.

Thirteen laws exercise construction, membership, insertion, removal, union,
intersection, difference, size and emptiness. They check first-occurrence order,
Float64 members without Keyed, IEEE NaNs and signed zeros, and Symbol identity.
Separate Core tests check the exact bits of the first stored zero and allow
iteration over a type without Eq while rejecting construction without Eq.

Run `lawspec-acceptance rc1-eq-set-operations` for every target, or append target
names. `LAWSPEC_MACHINE_BITS=32 LAWSPEC_MINIFY=1` selects the compact 32-bit
profile. The checked functions run in generated native tests. The three
specification mutants prefer the last arrival, take right-hand union members
first, or identify NaNs. Core rejects these during generation, so those are
compiler refutations, not native mutation results.

Canonical parser/prelude resolution, public native names and bindings,
collection-wide membership/iteration, migration, complete set-domain
generation and shrinking remain separate implementation requirements.
