# Arithmetic proof and native execution

Four laws and seven independent table rows cover nonlinear integer arithmetic,
dependent existence, nonexistence, and exact division under a checked precondition.
The SMT suite separately submits the same typed laws to real Z3. This native
suite selects property tests and examples; native execution does not depend on
the external solver.

Run `lawspec-acceptance minor-smt-arithmetic [target...]`.
Use `LAWSPEC_MACHINE_BITS=32 LAWSPEC_MINIFY=1` for the compact 32-bit profile.
The changed square must fail native expectations. Weakening the denominator's
restriction must fail mandatory definition checking before generation.

A solver model is not a validated source counterexample. Solver evidence and
native test outcomes remain separate, with their actual execution recorded.
