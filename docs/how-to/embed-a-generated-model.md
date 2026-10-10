---
id: lawspec.how-to.embed-a-generated-model
kind: how-to
title: Embed a generated model
---
# Embed a generated model

A spec handler with state is a reference model: each operation runs a checked
definition over the handler's state and keeps the next state. On every target
(Rust, Go, Java, Kotlin, Python, JavaScript, TypeScript and Haskell) the
generated code is fast enough to serve as a runtime, so an application (a test
double, a simulator, a digital twin) can construct the handler itself and call
its operations directly, outside any law.

## What runs typed

A checked definition runs as typed native code when every value it touches has
a typed form, it calls only other typed definitions, and it has no runtime
contract or workflow policy. The typed forms are:

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

| LawSpec | Python | JavaScript and TypeScript | Haskell |
| --- | --- | --- | --- |
| `Bool`, `Unit` | `bool`, `None` | `boolean`, `null` | `Bool`, `()` |
| `Int8` to `UInt32` | `int` | `number` | `Int8` to `Word32` |
| `Int64`, `UInt64` | `int` | a `number` until it outgrows a safe integer, then a `bigint` | `Int64`, `Word64` |
| `Integer` | `int` | the same | `Integer` |
| `Text`, `Bytes` | `str`, `bytes` | `string`, `Uint8Array` | `Text`, `ByteString` |
| `Maybe`, `Either` | `()` or `(x,)`, `(0, l)` or `(1, r)` | `null` or a `Just`, a `Side` | strict `Opt`, `Alt` |
| `List a` | a persistent cons list of tuples | a persistent cons list | a strict list that knows its length |
| `KeyVal k v`, `Set a` | a persistent AVL tree of tuples | a persistent AVL tree | `Data.Map.Strict`, `Data.Set` |
| data | a tuple, after the constructor's rank when there are several | a class per constructor, typed in TypeScript | a strict data type, constructors in the portable order |

In Python, Python's own tuple equality and order are LawSpec's, so maps of
such keys compare keys with `==` and `<` directly; in Haskell, the derived
`Eq` and `Ord` of the typed data types are. Typed Haskell definitions run in
`IO`, every binding strict, so each value is evaluated where it is written.

Anything else runs as before, on the dynamic values every target shares. Both
paths give the same results; the acceptance suites run every target's laws and
mutants over them.

On Python, JavaScript, TypeScript and Haskell, typed code carries the handler
context: a definition that performs another ability's operation (a client
handler's clause that calls the broker, say) takes the law's symbols, finds
the operation's handler there, and calls it with native values, exactly as
the dynamic code does. Such a definition, and a handler whose clauses are
such definitions, runs typed too. On Rust, Go, Java and Kotlin a definition
that performs an operation other than `raise` stays dynamic.

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
| Python | `lawspec_abilities.example.tallies.Tally()` |
| JavaScript, TypeScript | `new Tally()` from `lawspec_abilities/example/tallies` |
| Haskell | `LawSpecHandlers.Example.Tallies.tally symbols`, with `symbols <- LawSpecRuntime.newSymbolContext` |

The handler implements the ability's interface (the trait in Rust), so the
application calls its operations with its own native types:

```rust
use lawspec_example::lawspec_abilities::example_tallies::{Counter, Tally};

let counter = Tally::start();
assert_eq!(counter.bump(2), 2);
assert_eq!(counter.bump(3), 5);
```

```python
from lawspec_abilities.example.tallies import Tally

counter = Tally()
assert counter.bump(2) == 2
assert counter.bump(3) == 5
```

```typescript
import { Tally } from './lawspec_abilities/example/tallies.js';

const counter = new Tally();
counter.bump(2n); // 2n
counter.bump(3n); // 5n
```

```haskell
import qualified LawSpecRuntime as LS
import qualified LawSpecHandlers.Example.Tallies as Handlers
import LawSpecAbilities.Example.Tallies (bump)

main :: IO ()
main = do
  symbols <- LS.newSymbolContext
  counter <- Handlers.tally symbols
  _ <- bump counter 2
  bump counter 3 >>= print -- 5
```

A Haskell handler of several abilities is made in two steps, its state and
then a record per ability over it: `state <- Handlers.clusterState symbols`,
then `Handlers.clusterBroker symbols state` and `Handlers.clusterAdmin symbols
state` share one state.

Arguments and results convert directly between the native types and the
typed forms, without the dynamic values the laws use (when `lawspec.json`
binds native types, they cross through the handler schema instead). The
handler is safe to share between threads on Rust, Go, Java, Kotlin, Python and
Haskell: its operations apply one at a time, each to the state the previous
one left, and on Haskell an operation that fails leaves the state as it was.

A handler whose clauses perform another ability's operations finds that
ability's handler in its context, so make it with a context that holds one: a
Python `KafkaProducer(symbols)` with `ls.install_handlers(symbols,
{"lawtwin.kafka::ability::Broker": Cluster()})` first, and likewise
`ls.installHandlers(symbols, {...})` on JavaScript and TypeScript and
`LS.installHandlers symbols [LS.installed key broker]` on Haskell.

The handler a law uses is the same type, made with the law's context
(`Tally::new(&ctx)` in Rust, `NewTally(symbols)` in Go, the one-argument
constructor on the JVM), so what the laws check is what the application runs.

## Measure it

`lawspec-dev bench kafka`, in the LawSpec repository, generates LawTwin's
Kafka reference model for every target and drives its `cluster` handler: a
million produces over 100 partitions, a consumer group of ten members fetching
and committing with a rebalance, and transactions. It prints each phase's
throughput and the memory the state retains; `--scale N` runs a smaller
workload, and naming targets runs only those. The drivers in
`bench/kafka/<target>/` are worked examples of embedding a handler on each
target.
