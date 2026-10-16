# Typed empty record patterns

Seven laws and sixteen table rows cover empty structural and nominal products,
populated records, guard fall-through, generic fields, alternative payloads and
nested records, plus generic alternatives whose constructor shares their type name. Every target must execute the generated native tests. Two
specification mutants must fail during exhaustive generation checking.

Run `lawspec-acceptance minor-empty-record-patterns [target...]`. Set
`LAWSPEC_MACHINE_BITS=32 LAWSPEC_MINIFY=1` for the compact 32-bit profile.
The protocol's language profile does not designate this minor as a release candidate.
