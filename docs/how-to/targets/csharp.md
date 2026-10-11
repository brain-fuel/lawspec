---
id: lawspec.how-to.targets.csharp
kind: how-to
title: Set up C#
---
# Set up C#

C# runs over the F# runtime. The program's model (its data types, codecs,
ability interfaces, schema, actors, sessions and mailboxes) is generated as an
F# project that your C# project references. Adapters, entries, the embedding
API and the tests are C#. A small compatibility layer, `LawSpec.CSharp`,
covers what F# makes awkward from C#.

## Requirements

- The .NET SDK 10.
- xunit.v3 4.0.2, run on Microsoft.Testing.Platform.
- BouncyCastle.Cryptography 2.7.0, only for programs that import
  `lawspec.crypto` or `lawspec.network`.

## Create the project

```sh
npx lawspec init --target csharp
npx lawspec generate --target csharp
dotnet test
```

`init` creates `global.json`, `Example.slnx`, `src/Example.csproj` (which
imports `src/LawSpec.Sources.props`) and `tests/Example.Tests.csproj` (which
imports `tests/LawSpec.Tests.props` and references xunit.v3). `generate` writes
three F# projects under `lawspec/`: `LawSpec.Runtime`, `LawSpec.Testing` and
`LawSpec.Model`, the program's model, which the source props reference.

## Layout

| Files | Directory |
| --- | --- |
| Adapters (yours): one static class per unit, such as `Example/AtoiCodec.cs` | `src` |
| Entries and the embedding API | `src/LawSpec` |
| Application code bound in `lawspec.json` | anywhere in `src`, such as `src/Native` |
| The model, in F# | `lawspec/LawSpec.Model` |
| Generated tests | `tests/LawSpec` |

C# has no compilation order, so any adapter can call any checked definition.

Unit `example.parse_port` gives `public static class ParsePort` in namespace
`Example`, with PascalCase methods. An adapter takes no `Unit` argument, and
returns `void` (or `Task`) where LawSpec returns `Unit`.

## Native representations

Adapters use the model's F# types as C# sees them:

- A record is a class with a positional constructor:
  `new Receipt(cents)`, read as `receipt.Cents`.
- A union is a class with a nested class per case. Build a case with
  `Shape.NewCircle(radius)`; a case without fields is a static property, such
  as `Stack.Empty`. Match with `shape is Shape.Circle c`, and read a case's
  fields by their LawSpec names, such as `c.radius`.
- `List a`, `Maybe a`, `Set a` and `KeyVal k v` are `FSharpList<T>`,
  `FSharpOption<T>`, `FSharpSet<T>` and `FSharpMap<K, V>`. F#'s `ListModule`,
  `SetModule` and `MapModule` build and read them, as do the helpers below.
- Integers, text, bytes and the other scalars are the types the
  [F# guide](fsharp.md#native-representations) lists, spelled in C#:
  `BigInteger`, `string`, `byte[]`, `System.Text.Rune`, `LawSpec.ExactDecimal`.
- A handle is an `object`.
- An adapter that `fails with E` returns `FSharpResult<T, E>`; build one with
  `Outcome.Ok` or `Outcome.Error`. An `async` adapter returns `Task<T>`.

## The compatibility layer

`LawSpec.CSharp` gives C# forms of F# idioms:

| Helper | What it gives |
| --- | --- |
| `Fn.F0` … `Fn.F6` | A curried F# function from a delegate |
| `Fn.Invoke` | An F# function applied to its arguments |
| `Fn.List`, `Fn.ListOf` | An F# list of arguments, or of a sequence |
| `Fn.Tuple`, `Fn.Some`, `Fn.None` | F# tuples and options |
| `Fn.Run` | The value of a block of statements |
| `V.Int`, `V.Text`, `V.Data`, … | Portable values, one method per `Value` case |
| `IsSome`, `IsNone`, `GetOrElse`, `Match` | `Maybe` extensions on F# options |
| `Maybe.Of`, `Maybe.Nothing` | F# options |
| `Outcome.Ok`, `Outcome.Error` | F# results |

Every public function of the runtime has a PascalCase compiled name, such as
`Network.Open` or `Workflow.WithVirtual`, and so do the model's codecs,
bridges, sessions and default handlers.

## Abilities

Each ability is an F# interface `I<Name>` in `LawSpec.Abilities.<Unit>`; C#
implements it as any interface. The adapter's `GatewayHandler()` makes the
production handler; the stub returns a private class for you to fill in.
`handlers` in `lawspec.json` names a class of yours to make it with `new`
instead. `LawSpec.DefaultHandlers.Clock()` and its siblings give the
runtime's handlers of the built-in abilities.

## Checked definitions

Each unit's definitions are one static class, named after the whole unit:

```csharp
var next = LawSpec.Definitions.ExampleTotal.Increment(5);
```

A definition that uses abilities takes their interfaces first; one that can
fail returns an `FSharpResult`, and an `async` one a `Task`.

A definition whose values all have native types runs typed, in the model's
`LawSpec.TypedProgram`, over the same F# types: its entry converts only its
arguments and result, as on F#.

## Spec handlers

Each spec handler is a class you can use outside any law:
`LawSpec.Handlers.<Unit>.<Handler>` implements the interface of every ability
it answers, an operation that can fail returns an `FSharpResult`, and a
stateful handler's `State` property reads or replaces its state:

```csharp
var broker = new LawSpec.Handlers.LawtwinKafka.Cluster();
var snapshot = broker.State;
broker.ProduceRequest(partition, Maybe.Nothing<ProducerTag>(), Fn.List(record));
broker.State = snapshot;
```

## Native bindings

`lawspec.json` can bind functions, constructors, methods, handlers and
failures to your C# code, but not types: a C# program uses the model's types.
A bound function is a static method. A method binding calls a method of the
handle, found when it is called, since C# sees the handle as an `object`. A
failure binding turns an exception of the named class into a failure
constructor.

## Actors, sessions and mailboxes

These are the [F# classes](fsharp.md#actors-sessions-and-mailboxes) from
C#. Start an actor with its handlers record;
`LawSpec.Generated.ActorHandlers.Account` gives the one made from your
adapters. `Serve.Channel()` gives a protocol's two ends as a tuple, so
`var (first, second) = Serve.Channel();`, and each `Receive()` returns the
value and the next end the same way. `TallyActor.Connect` and
`JobsMailbox.Connect` take an optional timeout.

## Tests

The tests are C# xUnit facts over the same engine as F#: seeded SplitMix64
generation and shrinking, the model runner, and the harness's order, parallel
units, cover, retries, timeouts, known failures and benchmarks. `LAWSPEC_SEED`
replays a run.

`npx lawspec test` runs only the laws an edit can affect, selecting their
tests with xUnit's query filter; `npx lawspec doctor` checks the SDK, the test
runner and the generated props, as on F#. A generator binding names a static
method of no arguments returning a `LawSpec.Testing.Gen<T>` of the generated
type, in `tests/Native`.
