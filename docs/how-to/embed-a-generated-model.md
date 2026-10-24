---
id: lawspec.how-to.embed-a-generated-model
kind: how-to
title: Embed a generated model
---
# Embed a generated model

A spec handler with state is a reference model: each operation runs a checked
definition over the handler's state and keeps the next state. On every target
(Rust, Go, Java, Kotlin, Python, JavaScript, TypeScript, Haskell, Erlang,
Elixir and Gleam) the generated code is fast enough to serve as a runtime, so an application (a test
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
| `Maybe`, `Either` | `()` or `(x,)`, `(0, l)` or `(1, r)` | `null` or a `Present`, a `Side` | strict `Opt`, `Alt` |
| `List a` | a persistent cons list of tuples | a persistent cons list | a strict list that knows its length |
| `KeyVal k v`, `Set a` | a persistent AVL tree of tuples | a persistent AVL tree | `Data.Map.Strict`, `Data.Set` |
| data | a tuple, after the constructor's rank when there are several | a class per constructor, typed in TypeScript | a strict data type, constructors in the portable order |

| LawSpec | Erlang | Elixir | Gleam |
| --- | --- | --- | --- |
| `Bool`, `Unit` | `boolean()`, `ok` | `boolean()`, `:ok` | `Bool`, `Nil` |
| integers | `integer()`, checked where bounded | the same | `Int`, the same |
| `Text`, `Bytes` | UTF-8 `binary()`, `binary()` | the same | `String`, `BitArray` |
| `Maybe`, `Either` | `nothing` or `{just, X}`, `{left, L}` or `{right, R}` | the same | `Option`, `Result` |
| `List a` | a list | a list | a `List` |
| `KeyVal k v`, `Set a` | a map, a version 2 `sets` set | the same | the same |
| data | the native tuple | the native struct | the native custom type |

In Python, Python's own tuple equality and order are LawSpec's, so maps of
such keys compare keys with `==` and `<` directly; in Haskell, the derived
`Eq` and `Ord` of the typed data types are. Typed Haskell definitions run in
`IO`, every binding strict, so each value is evaluated where it is written.
On the BEAM, typed code is one Erlang module, `lawspec_typed`, over each
language's own data, so only `KeyVal` and `Set` values convert at its
boundary; their entries and items come out in the portable order (Erlang's
term order where it is the same, a generated comparison where it is not).

Anything else runs as before, on the dynamic values every target shares. Both
paths give the same results; the acceptance suites run every target's laws and
mutants over them.

On Python, JavaScript, TypeScript, Haskell, Erlang, Elixir and Gleam, typed
code carries the handler context: a definition that performs another ability's operation (a client
handler's clause that calls the broker, say) takes the law's symbols, finds
the operation's handler there, and calls it with native values, exactly as
the dynamic code does. Such a definition, and a handler whose clauses are
such definitions, runs typed too. On Rust, Go, Java and Kotlin a definition
that performs an operation other than `raise` stays dynamic.

Because a list shares its tail and a map update copies only the path to its
key, an operation costs what it changes, not the size of the state: appending
a record to a log of a million records allocates the record and one cell. A
handler's state is never copied between operations (on the BEAM it stays in
the handler's cell process, and each operation runs there), and memory grows with
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
end ability

handler tally for Counter with state total :: Int64 start 0 is
operation bump n is
~total := (if n >= 0 && n <= 1000000 && total <= 1000000 - n then prelude.Int64
(total + n) else total end if); total
end operation
end handler
end unit
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
| Erlang, Elixir, Gleam | `tally(Context)` inside `with_context` (see [handlers](../reference/language/handlers.md#erlang-elixir-and-gleam)) |

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

A Haskell handler of several abilities, or one with typed state, can be made
in two steps, its state and then a record per ability over it: `state <-
Handlers.clusterState symbols`, then `Handlers.clusterBroker symbols state`
and `Handlers.clusterAdmin symbols state` share one state.

Arguments and results convert directly between the native types and the
typed forms, without the dynamic values the laws use (when `lawspec.json`
binds native types, they cross through the handler schema instead). The
handler is safe to share between threads on Rust, Go, Java, Kotlin, Python and
Haskell, and between processes on the BEAM: its operations apply one at a time, each to the state the previous
one left, and on Haskell an operation that fails leaves the state as it was.

A handler whose clauses perform another ability's operations finds that
ability's handler in its context, so make it with a context that holds one: a
Python `KafkaProducer(symbols)` with `ls.install_handlers(symbols,
{"lawtwin.kafka::ability::Broker": Cluster()})` first, and likewise
`ls.installHandlers(symbols, {...})` on JavaScript and TypeScript and
`LS.installHandlers symbols [LS.installed key broker]` on Haskell.

## Take a failure as a value

An operation that `fails with E` raises its failure as the laws see it: a
panic in Rust and Go, an exception elsewhere. For an application, each such
operation has a second form that returns the failure instead, in the native
types:

| Target | `produceRequest` that fails with `KafkaError` |
| --- | --- |
| Rust | `try_produceRequest(...) -> Result<i64, KafkaError>` |
| Go | `TryProduceRequest(...) (int64, error)`, the error a `*LawSpecRaised[KafkaError]` (`errors.As`) |
| Java, Kotlin | `tryProduceRequest(...)`, a `LawSpecFast.Outcome<Long, KafkaError>`: `failed()`, `value()`, `failure()` |
| Python | `try_produceRequest(...)`, `Right` of the result or `Left` of the failure |
| JavaScript, TypeScript | `tryProduceRequest(...)`, `Right` of the result or `Left` of the failure |
| Haskell | `tryProduceRequest broker ...`, in the ability's handlers module: `IO (Either KafkaError Int64)` for any handler |
| Erlang, Elixir | `broker_try_produce_request(Broker, ...)` (Elixir: `Broker.try_produce_request(broker, ...)`): `{ok, Offset}` or `{error, KafkaError}`, for any handler |
| Gleam | `broker_try_produce_request(broker, ...)`: a `Result(Int, data.KafkaError)`, for any handler |

A failing operation leaves the state as it was. Rust dynamic handlers also
provide `start`, `try_` operations and native `state` / `set_state` methods.
They evaluate through the checked dynamic runtime and validate restored states
against their declared schema. The typed snapshot methods apply to typed
handlers; dynamic snapshots copy the state.

## Read and replace the state

A handler with state gives its state in its native types, as a snapshot to
show or keep, and takes one back, to force the state, reset it or restore an
earlier snapshot:

| Target | Read | Replace | Typed, shared rather than copied |
| --- | --- | --- | --- |
| Rust | `state()` | `set_state(s)` | `typed_state()`, `set_typed_state(s)` |
| Go | `State()` | `SetState(s)` | `TypedState()`, `SetTypedState(s)` |
| Java, Kotlin | `state()` | `setState(s)` | `typedState()`, `setTypedState(s)` |
| Python | `state()` | `set_state(s)` | `typed_state()`, `set_typed_state(s)` |
| JavaScript, TypeScript | `state()` | `setState(s)` | `typedState()`, `setTypedState(s)` |
| Haskell | `clusterSnapshot state` | `clusterRestore state s` | `readMVar state`, `swapMVar state s` |
| Erlang, Elixir, Gleam | `cluster_state(Broker)` | `cluster_set_state(Broker, S)` | `cluster_typed_state(Broker)`, `cluster_set_typed_state(Broker, S)` |

The native forms convert the whole state, so they cost what it holds; the
typed ones cost nothing, since a typed state is never changed in place. On
the BEAM the typed ones convert nothing but copy the state, since processes
share no heap; in Gleam the typed state is the opaque `ClusterTypedState`. The
typed state's type is the generated one (Go's is unexported, so an
application keeps it without naming it).

## Names and builds

The typed functions a handler's clauses call, and its start, are named from
the definitions and the handler: a function's name is its definition's name,
with a suffix only when two would otherwise share one, so an unrelated edit
of the contract does not rename them. (Python, Go, F#, C# and the BEAM targets have these names from 0.30;
the other targets keep a digest suffix until their readable-output release.) Generation depends only on the program: the compiler's cache
is kept per compiler build, so a compiler rebuilt in place never reuses what
another build made (`lawspec-dev bench kafka --deterministic` generates the
model in process, with a cold and a warm cache, without one, and by the
native compiler, and requires the same bytes). The generated Rust crate,
Haskell package and `lawspec_typed` module build without warnings, so a project that depends on them
sees none.

## Laws and applications share the handler

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
