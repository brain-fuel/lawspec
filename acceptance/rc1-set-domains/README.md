# Complete finite set domains

Eight laws exercise all five stored Boolean-set sequences, all 25 pairs,
17 dependent input pairs, all 114 nested Boolean-set sequences, empty element
domains, Unit and Maybe Bool. Equality classes never erase observable storage
choices or iteration order. Five explicit examples independently pin iteration.

Every finite law runs again through each target's native test framework.
Three specification mutants are refuted by complete finite compiler evaluation;
these are generation refutations, not native implementation mutation results.
A separate property suite exercises generation and shrinking.

Run `lawspec-acceptance rc1-set-domains [target...]`. Set
`LAWSPEC_MACHINE_BITS=32 LAWSPEC_MINIFY=1` for the compact 32-bit profile.
Expansion limits remain explicit. Domains with a non-reflexive element can
have unbounded set storage and must not be reported as completely enumerated.
