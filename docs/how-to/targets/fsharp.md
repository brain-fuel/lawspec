---
id: lawspec.how-to.targets.fsharp
kind: how-to
title: Set up F#
---
# Set up F#

## Requirements

- The .NET SDK 10.
- xunit.v3 4.0.2, run on Microsoft.Testing.Platform.
- FsCheck 3.4.0, which the generated `LawSpec.Testing` project references.
- BouncyCastle.Cryptography 2.7.0, only for programs that import
  `lawspec.crypto` or `lawspec.network`. The runtime uses the platform's
  ML-KEM, ML-DSA and SLH-DSA where .NET provides them, and BouncyCastle where
  it does not.

## Create the project

```sh
npx lawspec init --target fsharp
npx lawspec generate --target fsharp
dotnet test
```

In a directory without build files, `init` creates:

| File | What it holds |
| --- | --- |
| `global.json` | Opts `dotnet test` into Microsoft.Testing.Platform |
| `Example.slnx` | The source and test projects and the runtime projects |
| `src/Example.fsproj` | Your project; it imports `src/LawSpec.Sources.props` |
| `tests/Example.Tests.fsproj` | The tests; it imports `tests/LawSpec.Tests.props` and references xunit.v3 |

`generate` writes the runtime as two projects under `lawspec/`:
`LawSpec.Runtime` (values, schemas, codecs, effects, actors, sessions and the
network) and `LawSpec.Testing` (generators, the property runner, models,
scenarios and the harness). Neither is a NuGet package; both are source.

## Layout

| Files | Directory |
| --- | --- |
| Adapters (yours): one module per unit, such as `Example/AtoiCodec.fs` | `src` |
| Data types, codecs, ability interfaces, schema, entries, embedding API | `src/LawSpec` |
| Application code bound in `lawspec.json` | `src/Native` |
| Generated tests | `tests/LawSpec` |
| Runtime and test support projects | `lawspec` |

F# compiles files in order, so the generated props list them in order:

1. `Native/Types/**`: application types bound in `lawspec.json`.
2. The data types, codecs, ability interfaces and bridges, and the schema.
3. `Native/**`: other application code, which may implement the interfaces.
4. Per unit, in an order where each unit follows the units it calls: its
   adapter, its entries and its embedding API.

An adapter can call the checked definitions of the units ordered before its
own, which is every unit its unit imports.

Unit `example.parse_port` gives the adapter module `Example.ParsePort` in
`src/Example/ParsePort.fs`. Its functions are camelCase, curried and typed with
the native types below.

## Native representations

A product is an F# record with PascalCase fields. A sum is a union with a case
per constructor, keeping the constructor's field names. Both compare by
LawSpec's order and equality, not F#'s structural ones. For a type with
constructors `Leaf value :: a` and `Branch children :: List (Tree a)`, the
type is `LawSpec.Data.Tree<'T0>` with cases `Leaf of value: 'T0` and
`Branch of children: Tree<'T0> list`.

| LawSpec | F# |
| --- | --- |
| `Int8`…`Int64`, `UInt8`…`UInt64` | `sbyte`…`int64`, `byte`…`uint64` |
| `Integer`, `Whole`, `Nat` | `bigint` |
| `IntSize`, `UIntSize`, `UIntPtr` | `int64`, `uint64`, `uint64` on both profiles, checked against `machineBits` |
| `Float32`, `Float64` | `float32`, `float` |
| `Decimal`, `Rational` | `LawSpec.ExactDecimal`, `LawSpec.Rational` |
| `Complex64`, `Complex128` | `LawSpec.Complex64`, `System.Numerics.Complex` |
| `Text`, `Utf16Text`, `Bytes` | `string`, `string`, `byte[]` |
| `Char`, `CodePoint`, `CodeUnit16` | `System.Text.Rune`, `int`, `char` |
| `CodePointText` | `int list` |
| `List a`, `Maybe a` | `'a list`, `'a option` |
| `Either a b` | `LawSpec.Either<'L, 'R>` |
| `Nullable a`, `Optional a` | `LawSpec.Nullable<'T>`, `LawSpec.Optional<'T>` |
| `Set a`, `KeyVal k v` | F#'s persistent `Set<'T>` and `Map<'K, 'V>` |
| `Duration` | `TimeSpan` of whole microseconds |
| `Unit`, `Null`, `Undefined` | `unit`, `LawSpec.Null`, `LawSpec.Undefined` |
| `Symbol` | `LawSpec.Symbol`, compared by identity |
| A handle | `obj`, or the type bound in `lawspec.json` |

An adapter that `fails with E` returns `Result<T, E>`. An `async` adapter
returns `Task<T>`.

LawSpec orders text by code point; F# orders a `string` by UTF-16 unit, so
the two disagree when a character outside the Basic Multilingual Plane, such
as an emoji, meets one from U+E000 to U+FFFF. LawSpec never observes F#'s
order: the codecs, typed definitions and comparisons put a `Set`'s items and
a `Map`'s keys in code point order. Your own code that walks a `Set<string>`
or `Map<string, _>` in order should sort with `LawSpec.Runtime.Portable.textOrder`
(an `IComparer<string>`) or `Portable.compare`.

## Abilities

Each ability is an interface `I<Name>` in `LawSpec.Abilities.<Unit>`, with a
PascalCase method per operation; an operation that can fail returns a
`Result`. The adapter of the ability's unit makes the production handler, such
as `gatewayHandler ()`, usually as an object expression. To use application
code instead, name its class under `handlers` in `lawspec.json`; it must
implement the interface. `LawSpec.DefaultHandlers` gives the runtime's
handlers of the built-in abilities as these interfaces.

## Checked definitions

For `function increment (value :: Int8) -> Integer is value + 1 end function` in unit
`example.total`, call:

```fsharp
LawSpec.Definitions.ExampleTotal.increment 5y
```

Each unit's definitions are one module named for the whole unit, so a unit
and a unit nested in it never collide.

A definition that uses abilities takes their interfaces first. One that can
fail returns a `Result`; an `async` one returns a `Task`.

### Typed definitions

A definition whose values all have native types runs typed: it is a function
in `LawSpec.TypedProgram` over the same records, unions, lists, options,
`Map` and `Set` you use, so nothing is converted inside it, and its entry
converts only its arguments and result. Bounded integers are .NET's own,
checked as LawSpec checks them; `Integer` is `bigint`; `Text` is a `string`
measured in code points. A self-recursive call in tail position becomes a
loop. Each function is named for its definition and a digest of its
identity, so its name survives unrelated edits. `lawspec-dev bench kafka
--typed` lists the definitions that stay dynamic, and why.

## Spec handlers

Each spec handler is a class you can use outside any law:
`LawSpec.Handlers.<Unit>.<Handler>` implements the interface of every ability
it answers. An operation that can fail returns a `Result`, its failure as a
value. A stateful handler has a `State` property: read it for a snapshot,
assign it to force, reset or restore the state. When every clause is typed,
the class keeps its state native and runs the typed clauses, so a snapshot is
shared, never copied:

```fsharp
let broker = LawSpec.Handlers.LawtwinKafka.Cluster()
let snapshot = broker.State
broker.ProduceRequest(partition, None, [ record ]) |> ignore
broker.State <- snapshot
```

## Native bindings

`lawspec.json` can bind types, functions, methods, constructors, handlers and
failures to application code:

- A bound type becomes an abbreviation of yours. A record style binding
  builds an F# record by field name; a variant style binding builds a union
  case. Put the type in `src/Native/Types`, since the data types use it.
- A bound function is a curried module function. A method binding calls a
  method of the handle argument; a constructor binding makes the handle.
- A failure binding turns an exception of the named type into a failure
  constructor, given the exception's message.
- A generator binding names a function of no arguments that returns an
  FsCheck `Arbitrary` of the native type; put it in `tests/Native`, which
  compiles before the tests. It replaces the built-in generation of that type,
  and its own shrinker shrinks the values.

```fsharp
let prices () : Arbitrary<Price> =
    Gen.choose (100, 200)
    |> Gen.map (fun cents -> { major = { Coefficient = bigint cents; Exponent = -2 }; unit = Euros })
    |> Arb.fromGen
```

## Actors, sessions and mailboxes

An actor becomes a class in `LawSpec.Actors`, such as `AccountActor`. It runs
a record of functions, `AccountActorHandlers`, usually the unit's adapters.
The classes compile before the adapters, so an adapter can start an actor made
of its own functions; `LawSpec.Generated.ActorHandlers` gives each record made
from the adapters, for code compiled later. Each message is a method that
waits for the reply, with a `Tell` form that does not; `Serve` and `Connect`
call an actor from another node. A supervisor class starts its children and
exposes them as properties.

A protocol `P` becomes a module `LawSpec.Sessions.P`. `P.channel ()` gives its
two ends; `P.listen` and `P.dial` give them across nodes. Each end is a class
named for its next step; `Send` returns the next end, and `Receive` returns
the value and the next end as a tuple. An end can be used once.

A mailbox `jobs` becomes `LawSpec.Mailboxes.JobsMailbox`. `Send` never waits,
and one receiver takes messages in order; `Serve` and `Connect` reach it from
another node. `LawSpec.RemoteDefinitions` serves the checked definitions on a
node by content hash and evaluates one on another node.

## Tests

Tests are xUnit facts. Each example, boundary case and property is a fact,
and a property runs on FsCheck. LawSpec builds the generators (refinement- and
pattern-directed, and the harness's strategies) as FsCheck generators, each
value with the tree of smaller values it may shrink to, so a shrink never
leaves an input's refinement; FsCheck draws the cases, grows their size from
0 to 100 over the run, counts discards against `maxAttempts` and shrinks a
failure by walking the tree, at most `maxShrinks` steps. Models,
linearizability and scenarios run on the runtime's model runner.

`LAWSPEC_SEED` replays a run: it seeds FsCheck's `Replay`, and a failure
prints the seed. A unit with `order random` orders its methods
and cases by the run's seed, and a `parallel` unit puts each law in a class of
its own, so xUnit runs them at once; other units run one at a time. Cover,
classify, labels, targeted search, retries, timeouts, known discrepancies and
benchmarks follow the harness, and their statistics go to `LAWSPEC_STATS`.

`npx lawspec test` runs only the laws an edit can affect: it selects their
xUnit tests by method with the query filter, and reads which ran from the
JUnit report. `npx lawspec doctor` checks the SDK version, that `global.json`
selects Microsoft.Testing.Platform, and that both projects import the
generated props.
