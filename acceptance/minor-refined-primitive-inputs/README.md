# Checked primitive input ranges

An unrelated constructor contract selects schema-checked generation for the
unit. Positive and negative Int64 inputs must still use their own authored
ranges. A record containing the same primitive type keeps its field's separate
restriction. The second law also retains the relationship between two inputs
when filtering and shrinking.

Both false-conclusion mutants must fail during native property execution.
These are sampled execution checks, not proofs or complete finite evidence.

The Python native regression replays the recorded filtering failure and three
additional seeds through the emitted properties. It observes that hints satisfy
the current input's restrictions, including the dependent ordering, and keeps
the valid `Int8` boundary 127. The third law checks that retained boundary's
domain. Framework health checks remain enabled.
