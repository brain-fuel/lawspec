# Canonical set literals

The six-law fixture exercises first-occurrence iteration, equality independent
of iteration order, nested sets, empty sets, record fields and alternatives.
Eleven examples run through each target's native test framework. Three mutants
change expected table, record and alternative results and must fail natively.

This suite selects examples only. Its universal Integer-set domains are
unbounded; these examples do not establish universal laws. Compiler tests
separately exhaust the three Boolean domains and require an incomplete result
when complete finite coverage is requested over the unbounded domains.

Run `lawspec-acceptance rc1-set-literals [target...]`. Set
`LAWSPEC_MACHINE_BITS=32 LAWSPEC_MINIFY=1` for the compact 32-bit profile.
