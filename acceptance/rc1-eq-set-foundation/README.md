# Eq-only set representation conformance

This suite exercises the reserved internal representation while canonical
`Set` authoring, operations, literal notation and `SortedSet` migration are
still being implemented. The legacy fixture declares the representation
explicitly. It is a compiler/runtime test, not a public authoring example.

Run `lawspec-acceptance rc1-eq-set-foundation` for all 17 targets, or append
target names. `LAWSPEC_MACHINE_BITS=32 LAWSPEC_MINIFY=1` selects the second
release profile.

Thirteen laws each cover both Boolean inputs. Generated tests execute the
checked definitions natively: membership equality ignores construction order,
iteration retains it, missing/different/empty members stay distinct, nested
products/alternatives/lists/sets recurse, NaN stays non-reflexive, repeated NaNs
are admitted, signed zeros compare equal, and ordinary list equality stays
ordered. Core tests separately check duplicate rejection, symbol identities,
reserved declaration shape and refusal of Keyed derivation.

The four specification mutants change a member, reverse iteration order,
replace a NaN with a reflexive member, or change negative zero to negative one.
Complete finite Core evaluation rejects them during generation. They measure
specification sensitivity and compiler rejection, not native mutation coverage.
The passing programs must also pass their generated native tests; successful
emission alone is insufficient.

This does not establish public collection operation semantics, native binding
ergonomics, all constructor/adapter boundary cases, complete set-domain
enumeration or shrinking. Those remain RC1 requirements.
