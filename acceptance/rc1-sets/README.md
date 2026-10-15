# Canonical sets and sorted sets

Six laws exhaust both Boolean inputs through the public canonical authoring
profile. They check equality without ordering, first-occurrence iteration,
membership, deduplication, explicit sorted-set behavior and IEEE NaN inequality.

Membership and construction require Eq for the element type. Iteration does
not compare elements and needs no Eq requirement. SortedSet retains the
portable Keyed order; canonical Set does not require it.

Run `lawspec-acceptance rc1-sets [target...]`. Set
`LAWSPEC_MACHINE_BITS=32 LAWSPEC_MINIFY=1` for the compact 32-bit profile.
Complete set-input generation, native adapter boundaries and project migration
remain separate acceptance requirements.
