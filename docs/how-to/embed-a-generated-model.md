---
id: lawspec.how-to.embed-a-generated-model
kind: how-to
title: Embed a generated model
---
# Embed a generated model

A spec handler with state is a reference model: each operation runs a checked
definition over the handler's state and keeps the next state. On Rust, Go,
Java and Kotlin the generated code is fast enough to serve as a runtime, so an
application (a test double, a simulator, a digital twin) can construct the
handler itself and call its operations directly, outside any law.

## What runs typed

A checked definition runs as typed native code when every value it touches has
a typed form, it performs no ability operation, it calls only other typed
definitions, and it has no runtime contract or workflow policy. The typed
forms are:

| LawSpec | Rust | Go | Java and Kotlin |
| --- | --- | --- | --- |
| `Bool`, `Unit` | `bool`, `()` | `bool`, `lsfUnit` | `boolean`, `LawSpecFast.Unit` |
| `Int8` to `UInt32` | `i8` to `u32` | `int8` to `uint32` | `long` |
| `UInt64` | `u64` | `uint64` | (untyped) |
| `Integer` | an `i64` until it outgrows it | the same | `BigInteger` |
| `Text`, `Bytes` | shared `Arc<str>`, `Arc<[u8]>` | `string` | `String`, `LawSpecFast.Bytes` |
| `List a` | a persistent cons list | the same | the same |
| `KeyVal k v`, `Set a` | a persistent AVL tree in the portable order | the same | the same |
| data | an enum behind an `Arc` | a pointer to a struct, or an interface | a class per constructor |

Anything else, and any definition that uses an ability, runs as before, on the
dynamic values every target shares. Both paths give the same results; the
acceptance suites run every target's laws and mutants over them.

Because a list shares its tail and a map update copies only the path to its
key, an operation costs what it changes, not the size of the state: appending
a record to a log of a million records allocates the record and one cell. A
handler's state is never copied between operations, and memory grows with
what the state retains. Imported definitions that are the same up to their
names share one function (on Go, one in each package that holds them), so a
package's model is generated once, however many units import it.
ref:DEC-typed-native-definitions

## Construct a handler and call it

Take a handler with state, such as a counter:

```lawspec
unit example.tallies

ability Counter is
  bump :: Int64 -> Int64
end

handler tally for Counter with state total :: Int64 start 0 is
  bump n is
    ~total := (if n >= 0 && n <= 1000000 && total <= 1000000 - n then prelude.Int64 (total + n) else total); total
  end
end
```

Each target generates an entry point that makes the handler with its start
state, apart from any law:

| Target | Entry point |
| --- | --- |
| Rust | `lawspec_abilities::example_tallies::Tally::start()` |
| Go | `tallies.StartTally()` |
| Java | `new lawspec.abilities.example.Tallies.Tally()` |
| Kotlin | `lawspec.abilities.example.Tallies.Tally()` |

The handler implements the ability's interface (the trait in Rust), so the
application calls its operations with its own native types:

```rust
use lawspec_example::lawspec_abilities::example_tallies::{Counter, Tally};

let counter = Tally::start();
assert_eq!(counter.bump(2), 2);
assert_eq!(counter.bump(3), 5);
```

Arguments and results convert directly between the native types and the
typed forms, without the dynamic values the laws use. The handler is safe to
share between threads on Rust, Go, Java and Kotlin: its operations apply one
at a time, each to the state the previous one left.

The handler a law uses is the same type, made with the law's context
(`Tally::new(&ctx)` in Rust, `NewTally(symbols)` in Go, the one-argument
constructor on the JVM), so what the laws check is what the application runs.

## Measure it

`lawspec-dev bench kafka`, in the LawSpec repository, generates LawTwin's
Kafka reference model for Rust, Go, Java and Kotlin and drives its `reference`
handler: a million produces over 100 partitions, a consumer group of ten
members fetching and committing with a rebalance, and transactions. It prints
each phase's throughput and the memory the state retains; `--scale N` runs a
smaller workload. The drivers in `bench/kafka/<target>/` are worked examples
of embedding a handler on each target.
