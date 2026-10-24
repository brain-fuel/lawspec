---
id: lawspec.how-to.targets.scala
kind: how-to
title: Set up Scala
---
# Set up Scala

Scala runs over the shared JVM runtime, as Kotlin does. Data types are case
classes and enums, built-in types are Scala's own immutable collections,
abilities are traits, and an operation that can fail answers an `Either`.
Laws run as ScalaTest tests whose properties run on ScalaCheck.

## Requirements

- JDK 25.
- Scala CLI 1.16, the `scala` command.
- Scala 3.9.0.
- ScalaCheck 1.20.0 and ScalaTest 3.2.20 (`scalatest-funsuite`), as test
  dependencies.
- Bouncy Castle `bcprov-jdk18on` 1.86, only for programs that import
  `lawspec.crypto` or `lawspec.network`.

## Create the project

```sh
npx lawspec init --target scala
npx lawspec doctor
npx lawspec generate
scala test .
```

`init` creates `project.scala`, the build in Scala CLI's directives:

```scala
//> using scala 3.9.0
//> using options -deprecation -feature
//> using javaOpt --sun-misc-unsafe-memory-access=allow
//> using test.dep org.scalacheck::scalacheck:1.20.0
//> using test.dep org.scalatest::scalatest-funsuite:3.2.20
```

LawSpec runs `scala` from your `PATH`. Set a target's `scala` field in
`lawspec.json` to use another command.

## Layout

The sources keep sbt's layout. Scala CLI compiles a directory named `test` as
tests, so the test directory must be under one and the source directory must
not.

| Files | Directory |
| --- | --- |
| Adapters (yours): one object per unit, such as `example/AtoiCodec.scala` | `src/main/scala` |
| Scala runtime, data types and codecs | `src/main/scala/lawspec/...` |
| Shared JVM runtime and schemas (Java sources) | `src/main/java/lawspec/runtime` |
| Tests and generators | `src/test/scala` |

Adapter functions for a unit are grouped in an `object` named after it: unit
`example.parse_port` gives `object ParsePort` in package `example`, and tests
call `ParsePort.render(...)`.

## Native representations

A product, a type with one constructor, is a `final case class` named after the
type. A sum is an `enum`: a case without fields is a singleton, and a case with
fields takes the enum's type parameters. For:

```lawspec fragment
type Tree (a :: Type) is one of
  Leaf  of type a
  Branch  of type List (Tree a)
end type

echo :: Tree Int8 -> Tree Int8
```

the public type is `lawspec.data.Tree[Byte]`, with cases `Tree.Leaf(value)` and
`Tree.Branch(children: List[Tree[Byte]])`:

```scala
def size(value: lawspec.data.Tree[Byte]): Int = value match {
  case lawspec.data.Tree.Leaf(_) => 1
  case lawspec.data.Tree.Branch(children) => children.map(size).sum
}
```

A case of a GADT extends the enum at the type it refines to, so a match on it
needs no cast. A case is named after its constructor; when that name is the
type's own name, or would clash with another case, it gets a `Case` suffix.

| LawSpec | Scala |
| --- | --- |
| `Int8`…`Int64` | `Byte`, `Short`, `Int`, `Long` |
| `UInt8`…`UInt32` | The next wider signed type |
| `UInt64`, arbitrary and machine-sized integers | `BigInt`, with domain checks |
| `Integer` result | `Int \| Long \| BigInt` |
| `Integer` argument | `BigInt` |
| `Decimal`, `Rational` | `BigDecimal` with an unlimited context, `LawSpecRuntime.Ratio` |
| `Duration` | `FiniteDuration` of whole microseconds |
| Complex | `LawSpecRuntime.Complex` |
| `Char` | A one-scalar `String`, allowing supplementary characters |
| `CodePoint`, `CodeUnit16` | `Int`, `Char` |
| `CodePointText`, `Utf16Text`, `Bytes` | `IArray[Int]`, `String`, `IArray[Byte]` |
| `List a`, `Maybe a`, `Either a b` | `List[T]`, `Option[T]`, `Either[L, R]` |
| `Set a`, `KeyVal k v` | `Set[T]`, `Map[K, V]` |
| `Queue a`, `Stack a`, `Deque a` | `Queue[T]`, `List[T]` from its top, `Vector[T]` |
| `Nullable a`, `Optional a` | `LawSpecScala.Nullable[T]`, `LawSpecScala.Optional[T]` |
| `Null`, `Undefined` | `LawSpecScala.Null`, `LawSpecScala.Undefined` |
| `Unit` | `Unit` |
| `Symbol` | `LawSpecScala.Symbol`, compared by identity |

Values are copied and checked at the boundary. LawSpec equality is
schema-directed, not case-class equality.

## Failures and async adapters

An adapter or operation that `fails with E` returns `Either[E, R]`: a `Left` is
the failure a law expects. An exception `lawspec.json` maps to a failure
becomes that failure too. An `async` adapter returns a `Future`.

## Checked definitions

For `function increment (value :: Int8) -> Integer is value + 1 end function` in unit
`example.total`, call:

```scala
lawspec.definitions.example.Total.increment(symbols, value)
```

`value` is a `Byte`, the result a `BigInt`, and `symbols` the map the calls of
one example share (`LawSpecScala.symbols()`). The definitions' bodies are the
shared JVM ones, typed where the plan allows; neither needs ScalaTest.

## Generation and shrinking

Each input is drawn with the value's tree of smaller values, from ScalaCheck's
seed, and ScalaCheck walks the tree when a property fails, so every shrink
stays inside the input's refinement and a dependent input is redrawn from the
same random state. `LAWSPEC_SEED` fixes the seed, and a failure prints the seed
that replays it.

## Coverage

`lawspec test --coverage` needs nothing installed beyond Scala CLI. Scala 3
instruments the sources (`-coverage-out`, in scoverage's format), the tests
run, and the scoverage reporter, which Scala CLI fetches, writes
`report/cobertura.xml`, `report/scoverage.xml` and `report/index.html` under
`.lawspec/coverage/scala/<project-hash>`. The tests themselves are not
measured.

## Formatting

Output is what scalafmt 3.11.5 accepts with its default configuration
(Scala 3 dialect): two-space blocks, 80-column lines, a broken argument list
one argument a line with no trailing comma, and a chain of calls broken
before each dot. LawSpec lays it out itself, and its acceptance checks every
generated project with `scalafmt --test`. The tests' generators and checks
are in the runtime (`LawSpecScalars`, `LawSpecTesting`, and `LawSpecDraws`
for harness strategies), so a test file holds only its laws. A unit whose
tests would exceed 20,000 lines has a file per law, `<Unit><Law>Law.scala`,
whose trait reads the shared values from the `<Unit>LawSpecTest` object. See
[formatting](../../reference/formatting.md).

## Names

Generated code uses the specification's names. Locals keep their source
names in Scala's camel case, checked definitions are named after the
definition, and an anonymous record has a name from where it is used
(`DeclinedDetails`) instead of `Record<digest>`. A test is named after its
law and example, for instance `normalizersAgree_spacesBecomeHyphensPunctuationIs`, and boundaries are numbered from
1. Each law's comment gives its name, source line, what it says and the
statement its tests check; assertion messages name the law and example and
link to the expectation's line. Text is written as the language's own string
literal.
