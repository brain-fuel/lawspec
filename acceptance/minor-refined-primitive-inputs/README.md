# Checked primitive input ranges

An unrelated constructor contract selects schema-checked generation for the
unit. Positive and negative Int64 inputs must still use their own authored
ranges. A record containing the same primitive type keeps its field's separate
restriction. The second law also retains the relationship between two inputs
when filtering and shrinking.

Both false-conclusion mutants must fail during native property execution.
These are sampled execution checks, not proofs or complete finite evidence.
