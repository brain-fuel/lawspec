# Set up Kotlin

## Requirements

- JDK 25, with JVM target and test runtime 25.
- Gradle 9.1–9.3 (the scaffold is tested with 9.3.0).
- The Kotlin JVM plugin 2.3.21.
- Kotest 5.9.1: runner (JUnit 5), assertions and property modules.
- The test task on the JUnit Platform, without include or exclude filters.

## Create the project

```sh
npx lawspec init --target kotlin
npx lawspec doctor
npx lawspec generate
gradle test
```

In a directory without build files, `init` creates `settings.gradle.kts` and a
`build.gradle.kts` with the Kotlin plugin, `mavenCentral()`,
`jvmToolchain(25)`, the three Kotest dependencies and
`tasks.test { useJUnitPlatform() }`.

LawSpec uses a local `gradlew` if there is one, otherwise `gradle` on `PATH`. Set
a target's `gradle` field in `lawspec.json` to use another command.

## Layout

| Files | Directory |
| --- | --- |
| Adapters (yours): one file per unit, such as `example/AtoiCodec.kt` | `src/main/kotlin` |
| Kotlin runtime, data types and codecs | `src/main/kotlin/lawspec/...` |
| Shared JVM runtime and schemas (Java sources) | `src/main/java/lawspec/runtime` |
| Tests and Kotest helpers | `src/test/kotlin` |

The Java support files go under `src/main/java` by default, or under `sourceDir`
when you set it. Include that directory in your Java source set.

Adapter functions for a unit are grouped in an `object` named after it: unit
`example.parse_port` gives `object ParsePort` in package `example`, and tests
call `ParsePort.render(...)`. Two units can therefore both define `render(Int)`.

## Native representations

A product, a type with one constructor, is a `data class` named after the type
(a `data object` when it has no fields). A sum is a sealed interface with a
`data class` per constructor, or a `data object` for a constructor without
fields, so `when` is exhaustive without casts. For:

```lawspec fragment
type Tree (a :: Type) is
  Leaf value :: a
  Branch children :: List (Tree a)
end

echo :: Tree Int8 -> Tree Int8
```

the public type is `lawspec.data.Tree<Byte>`, with variants
`Tree.Leaf<Byte>` (property `value`) and `Tree.Branch<Byte>` (property
`children: List<Tree<Byte>>`):

```kotlin
fun size(value: lawspec.data.Tree<Byte>): Int = when (value) {
    is Tree.Leaf -> 1
    is Tree.Branch -> value.children.sumOf { size(it) }
}
```

A case is named after its constructor. When that name is the type's own name,
or would clash with another case, the case keeps a `Case` suffix
(`type Shape is | Shape | Other end` gives `Shape.ShapeCase`). A nullary case of
a generic sum is a class with value equality, such as `Chain.Stop<T>()`.

| LawSpec | Kotlin |
| --- | --- |
| `Int8`…`Int64` | `Byte`, `Short`, `Int`, `Long` |
| `UInt8`…`UInt32` | The next wider signed type |
| `UInt64`, arbitrary and machine-sized integers | `BigInteger`, with domain checks |
| `Integer` result | `Number`: any of `Int`, `Long`, `BigInteger`; non-integral values are rejected |
| `Integer` argument | `BigInteger` |
| `Decimal`, `Rational` | `BigDecimal`, `LawSpecRuntime.Ratio` |
| Complex | `LawSpecRuntime.Complex` |
| `Char` | A one-scalar `String`, allowing supplementary characters |
| `CodePoint`, `CodeUnit16` | `Int`, `Char` |
| `CodePointText`, `Utf16Text`, `Bytes` | `IntArray`, `String`, `ByteArray` |
| `List a` | `List<T>` |
| `Maybe a` | `LawSpecRuntime.Maybe<T>`, with `Nothing<T>` and `Just<T>` |
| `Either a b` | `LawSpecRuntime.Either<L, R>`, with `Left<L, R>` and `Right<L, R>` |
| `Nullable a` | `LawSpecKotlin.Nullable<T>`, with `Null<T>` and `Present<T>` |
| `Optional a` | `LawSpecKotlin.Optional<T>`, with `Undefined<T>` and `Present<T>` |
| `Null`, `Undefined` | Distinct singleton support values |
| `Unit` | Kotlin `Unit` |
| `Symbol` | `LawSpecKotlin.Symbol`, compared by identity |

Machine-sized integers are represented portably, so they do not depend on the
host's word size. Containers and arrays are copied at the boundary. LawSpec
equality is schema-directed, not data-class equality.

## Checked definitions

For `definition increment (value :: Int8) :: BigInt is value + 1 end` in unit
`example.total`, call:

```kotlin
lawspec.definitions.example.Total.increment(symbols, value)
```

`value` is a `Byte`, the result a `BigInteger`, and `symbols` a
`MutableMap<String, Any>` shared by the calls in one example. The shared
implementation bodies are Java, in the source directory; neither needs Kotest.

## Generation and shrinking

Tests use Kotest arbitraries and shrink trees, including for dependent inputs,
whose shrink trees Kotest 5.9's `flatMap` would otherwise discard. Refinement
filters retry up to `maxAttempts` at each value, avoiding Kotest's unbounded
filter sampling.

## Formatting

Output follows the Google Android Kotlin style guide: four-space blocks and
wrapped arguments, 100-column lines. The Java support files use Google Java
Format. See [formatting](../../reference/formatting.md).
