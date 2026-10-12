---
id: lawspec.how-to.targets.swift
kind: how-to
title: Set up Swift
---
# Set up Swift

## Requirements

- Swift 6.2 or later with SwiftPM, in the Swift 6 language mode.
- macOS 26 (Xcode 26) for programs that import `lawspec.crypto` or
  `lawspec.network`: CryptoKit gives ML-KEM-768 and ML-DSA-65 there.
- No package dependencies. Tests run on Swift Testing, which comes with the
  toolchain, and on LawSpec's own property engine.

## Create the project

```sh
npx lawspec init --target swift
npx lawspec generate --target swift
swift test
```

In a directory without build files, `init` creates `Package.swift`. It
declares four targets:

| Target | Path | What it holds |
| --- | --- | --- |
| `LawSpecRuntime` | `lawspec/LawSpecRuntime` | Values, schemas, codecs, effects, crypto, actors, sessions and the network |
| `LawSpecTesting` | `lawspec/LawSpecTesting` | Generators, the property runner, models, scenarios and the harness |
| `App` | `src` | Your code, the adapters and the generated program |
| `AppTests` | `tests` | The generated tests |

`generate` writes both runtime targets as source. They are not packages.

## Layout

| Files | Directory |
| --- | --- |
| Adapters (yours): one file per unit, such as `Example/ParsePort.swift` | `src` |
| Data types, codecs, ability protocols, schema, entries, embedding API | `src/LawSpec` |
| Application code bound in `lawspec.json` | `src/Native` |
| Generated tests | `tests/LawSpec` |
| Runtime and test support targets | `lawspec` |

Unit `example.parse_port` gives the caseless enum `Example.ParsePort`. Its
adapter extends that enum in `src/Example/ParsePort.swift` with one static
function per declaration, typed with the native types below. An adapter that
cannot fail neither throws nor returns an optional. A `Unit` argument is
left out, and a `Unit` result is `Void`. A new stub calls
`fatalError("not implemented: ...")`.

## Native representations

A product is a `struct` with the constructor's field names. A sum is an
`enum` with a case per constructor, whose associated values keep the field
names; a recursive one is `indirect`. Both conform to `Portable` and compare
by LawSpec's order and equality. For a type with constructors
`Leaf value :: a` and `Branch children :: List (Tree a)`, the type is
`Tree<T0>` with cases `leaf(value: T0)` and
`branch(children: PersistentList<Tree<T0>>)`.

| LawSpec | Swift |
| --- | --- |
| `Int8`…`Int64`, `UInt8`…`UInt64` | `Int8`…`Int64`, `UInt8`…`UInt64` |
| `Integer`, `BigInt`, `BigUInt` | `BigInt` |
| `IntSize`, `UIntSize`, `UIntPtr` | `Int`, `UInt`, `UInt`, checked against `machineBits` |
| `Float32`, `Float64` | `Float`, `Double` |
| `Decimal`, `Rational` | `ExactDecimal`, `Rational` |
| `Complex64`, `Complex128` | `Complex64`, `Complex128` |
| `Text`, `Utf16Text`, `Bytes` | `String`, `[UInt16]`, `[UInt8]` |
| `Char`, `CodePoint`, `CodeUnit16` | `Unicode.Scalar`, `UInt32`, `UInt16` |
| `CodePointText` | `[UInt32]` |
| `List a`, `Maybe a` | The runtime's persistent `PersistentList<A>`, `A?` |
| `Either a b` | `Either<A, B>` |
| `Nullable a`, `Optional a` | `Nullable<A>`, `Undefinable<A>` |
| `Set a`, `KeyVal k v` | The runtime's persistent `SortedSet<A>` and `SortedMap<K, V>` |
| `Duration` | Swift's `Duration`, in whole microseconds |
| `Unit`, `Null`, `Undefined` | `Unit` (or `Void`), `Null`, `Undefined` |
| `Symbol` | `Symbol`, compared by identity |
| A handle | `AnyHandle`, or the type bound in `lawspec.json` |

The runtime's types are in the `LawSpecRuntime` module.

`PersistentList` is a singly linked list that shares structure: prepending
an item, the first item and the rest take constant time, as recursive
definitions over a list need. A Swift `Array` would copy the whole list at
each step. The list is a `Sequence`, so `for`-`in`, `map`, `filter` and
`Array(list)` work on it, and an array literal makes one.

An adapter that `fails with E` uses a typed throw, `throws(E)`; each failure
type conforms to `Error`. An `async` adapter is an `async` function.

LawSpec orders text by code point, which is also how `SortedSet<String>` and
`SortedMap<String, V>` order their keys. Swift's own `<` on `String` compares
by Unicode canonical ordering instead, so sort your own text with
`Portable.compare` when the order must match LawSpec's.

## Abilities

Each ability is a protocol in `LawSpec.Abilities.<Unit>`, with a method per
operation. An operation that can fail throws its failure type. The adapter of
the ability's unit makes the production handler, such as
`gatewayHandler()`, usually a small `struct` or `final class` that conforms
to the protocol. To use application code instead, name its type under
`handlers` in `lawspec.json`; it must conform to the protocol.
`LawSpec.DefaultHandlers` gives the runtime's handlers of the built-in
abilities as these protocols.

## Checked definitions

For `definition increment (value :: Int8) :: BigInt is value + 1 end` in unit
`example.total`, call:

```swift
LawSpec.Definitions.ExampleTotal.increment(5)
```

Each unit's definitions are one enum named for the whole unit, so a unit and a
unit nested in it never collide.

A definition that uses abilities takes their protocols first. One that can
fail has a typed throw; an `async` one is `async`. A LawSpec error inside a
definition, such as a broken refinement, is a programmer error, so it traps,
as Swift's checked arithmetic does.

### Typed definitions

A definition whose values all have native types runs typed: it is a function
in `LawSpec.TypedProgram` over the same structs, enums, lists, optionals,
`SortedMap` and `SortedSet` you use, so nothing is converted inside it, and its
entry converts only its arguments and result. Bounded integers are Swift's
own, checked as LawSpec checks them; `Integer` is `BigInt`; `Text` is a
`String` measured in code points. A self-recursive call in tail position
becomes a loop. Each function is named for its definition and a digest of its
identity, so its name survives unrelated edits. `lawspec-dev bench kafka
--typed` lists the definitions that stay dynamic, and why.

## Spec handlers

Each spec handler is a class you can use outside any law:
`LawSpec.Handlers.<Unit>.<Handler>` conforms to the protocol of every ability
it answers. An operation that can fail throws its failure. A stateful handler
has a `state` property: read it for a snapshot, assign it to force, reset or
restore the state. When every clause is typed, the class keeps its state
native and runs the typed clauses, so a snapshot is shared, never copied:

```swift
let broker = LawSpec.Handlers.LawtwinKafka.Cluster()
let snapshot = broker.state
_ = broker.produceRequest(partition, nil, [record])
broker.state = snapshot
```

## Native bindings

`lawspec.json` can bind types, functions, methods, constructors, handlers and
failures to application code:

- A bound type becomes a `public typealias` of yours, so the type must be
  `public`. A record style binding builds it by field name; a variant style
  binding builds an enum case.
- A bound function is a static function. It may throw or not, and be `async`
  or not; the bridge adapts each. A method binding calls a method of the
  handle argument; a constructor binding makes the handle.
- A failure binding turns a thrown error of the named type into a failure
  constructor, given the error's description.
- A generator binding names a function of no arguments that returns a
  `Gen` of the native type; put it in `tests/Native`. It replaces the built-in
  generation of that type, and its own shrink tree shrinks the values.

## Actors, sessions and mailboxes

An actor becomes a class in `LawSpec.Actors`, such as `AccountActor`. It runs
a struct of functions, `AccountActorHandlers`, usually the unit's adapters.
Each message is a method that waits for the reply, an `async` overload of the
same name, and a `tell` form that does not wait. The overload awaits the
reply on a runtime thread, so async code writes
`try await account.deposit(5)`. Actors are the runtime's supervised mailboxes,
not Swift `actor` types: a handler runs LawSpec code, which may block, and
blocking inside a Swift actor would starve Swift's cooperative pool. `serve`
and `connect` call an actor from another node. A supervisor class starts its
children and exposes them as properties.

A protocol `P` becomes an enum `LawSpec.Sessions.P`. `P.channel()` gives its
two ends; `P.listen` and `P.dial` give them across nodes. Each end is a class
named for its next step: `send` returns the next end, and `receive` returns
the value and the next end as a tuple. An end can be used once.

A mailbox `ledger` becomes `LawSpec.Mailboxes.LedgerMailbox`. `send` never
waits, and one receiver takes messages in order; `serve` and `connect` reach
it from another node. `LawSpec.RemoteDefinitions` serves the checked
definitions on a node by content hash and evaluates one on another node.

## Tests

Tests are Swift Testing functions. Each example, boundary case and property is
a `@Test`, named by its law; each unit is a `@Suite`. No maintained Swift
property-testing library shrinks within refinements and replays from a seed
as LawSpec needs, so properties run on a small engine in `LawSpecTesting`.
Each generated value carries the tree of smaller values it may shrink to, so a
shrink never leaves an input's refinement. The engine grows the size from 0
to 100 over the run, counts discards against `maxAttempts` and shrinks a
failure by walking the tree, at most `maxShrinks` steps. Models,
linearizability and scenarios run on the runtime's model runner.

Laws run on runtime threads with large stacks, so deep recursion in a law
does not overflow Swift's default stack. An `async` adapter is awaited off
Swift's cooperative pool.

`LAWSPEC_SEED` replays a run, and a failure prints the seed. A unit with
`order random` orders its laws and cases by the run's seed. A `parallel` unit
is a suite of its own that Swift Testing runs at once with other suites;
other units run one at a time. Cover, classify, labels, targeted search,
retries, timeouts, known failures and benchmarks follow the harness, and
their statistics go to `LAWSPEC_STATS`.

`npx lawspec test` runs only the laws an edit can affect: it selects their
tests with `swift test --filter`, and reads which ran from the xUnit report.
`--coverage` adds `--enable-code-coverage`. `npx lawspec doctor` checks the
Swift version and that `Package.swift` declares the two runtime targets.
