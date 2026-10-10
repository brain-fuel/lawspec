Benchmarks of LawSpec's generated code, run with `lawspec-dev bench <name>`
(see `dev/Bench.hs` and docs/how-to/contribute.md).

`kafka/` drives LawTwin's Kafka reference model (`contract/`, from LawTwin
under its MIT licence) through the generated `cluster` spec handler of its
`Broker` ability, on Rust, Go, Java and Kotlin. `bench.json` names the
spec and package to generate; `kafka/<target>/` holds each target's driver,
copied over the generated project. Every driver runs the same workload,
scaled by its argument N (1,000,000 by default):

1. produce: N single-record produce requests, round robin over 100
   partitions of one topic, with an 8-byte key and a 64-byte value;
2. consume: a group of ten members joins (each join rebalances), syncs, and
   reads every assigned partition in fetches of 500 records, committing its
   offset after each fetch, in two rounds with the last member leaving and
   rejoining between them;
3. transactions: N/100 transactions, each adding two partitions, producing
   one record to each with its producer sequence, committing an offset and
   committing.

A driver prints `phase <name> <operations> <seconds>` per phase,
`memory <label> <bytes>` (live heap on Go and the JVM, resident set on Rust)
after the produce phase and at the end, and `check` lines the harness echoes:
the records read and the committed high watermark of partition 0, which are
the same on every target. `lawspec-dev bench kafka --typed` lists the
definitions and spec handlers that stay on the dynamic path, and why.
