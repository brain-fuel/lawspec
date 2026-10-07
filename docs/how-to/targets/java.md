---
id: lawspec.how-to.targets.java
kind: how-to
title: Set up Java
---
# Set up Java

## Requirements

- JDK 25 or later, and Maven running on it.
- Maven compiler plugin 3.14.x or 3.15.x with `maven.compiler.release` 25.
- Surefire 3.5.x.
- Test dependencies: JetCheck 0.3.0 and JUnit Jupiter 5.14.x.

New JVM releases are admitted after testing; the current profile certifies
Java 25.

## Create the project

```sh
npx lawspec init --target java
npx lawspec doctor
npx lawspec generate
mvn test
```

In a directory without build files, `init` creates a readable `pom.xml` with
these settings. In an existing Maven project it changes nothing and prints the
settings to add. Use `init --minify` for a compact POM. Set a target's `maven`
field in `lawspec.json` to use a Maven command other than `mvn`.

## Layout

| Files | Directory |
| --- | --- |
| Adapters (yours): one class per unit, such as `example/AtoiCodec.java` | `src/main/java` |
| Runtime, schemas and codecs | `src/main/java/lawspec/runtime` |
| Generated data types | `src/main/java/lawspec/data` |
| Checked definitions | `src/main/java/lawspec/definitions/...` |
| Tests, such as `example/AtoiCodecLawSpecTest.java`, and JetCheck helpers | `src/test/java` |

Override the source and test roots with `sourceDir` and `testDir`, and point
Maven's `sourceDirectory` and `testSourceDirectory` at them.

## Native representations

Generated code uses native named products and sums, with type parameters
visible in public declarations and adapter signatures:

- a product, a type with one constructor, is a record named after the type:
  `type Drink is Drink size :: Size shots :: Int32 end` becomes
  `public record Drink(Size size, Integer shots)`, read as `drink.shots()`;
- a sum is a sealed interface with a nested record per constructor:
  `type Size is | Small | Large end` becomes `sealed interface Size` with
  `Size.Small` and `Size.Large`, so a `switch` over it is exhaustive:

```java
long base = switch (drink.size()) {
  case Size.Small small -> 250;
  case Size.Large large -> 320;
};
```

A case is named after its constructor. When that name is the type's own name,
or would clash with another case, the case keeps a `Case` suffix. A field named
like a `java.lang.Object` method (`hashCode`, `toString` and so on) is rejected,
because its record accessor would override that method. Records compare by
value.

Scalars use native Java types where they represent the whole domain:

- signed fixed-width integers use the primitives `byte`, `short`, `int` and
  `long`; `UInt8`, `UInt16` and `UInt32` use the next wider primitive
  (`short`, `int`, `long`), and `UInt64` uses `BigInteger`;
- arbitrary integers use `BigInteger`, and `Decimal` uses `BigDecimal`;
- `Duration` uses `java.time.Duration`, of whole microseconds;
- floats use `float` and `double`;
- `Text` uses `String`, `Bytes` uses `byte[]`, and code points and UTF-16 units
  use their native representations;
- `List a` uses `List<A>`;
- other domains, including nested `Nullable`/`Optional` states, use the
  generated `LawSpecRuntime.Value` support type.

An adapter whose result is the abstract `Integer` returns any integral
`Number`: a standard signed wrapper or a `BigInteger`. Non-integral values such
as `Double` are rejected.

An adapter returning `Unit` may return nothing. Machine-sized integers enforce
the selected 32- or 64-bit range whatever the JVM architecture.

## Checked definitions

A checked definition becomes a static method under `lawspec.definitions`,
following the unit's package and class. For:

```lawspec
unit example.total

definition size (xs :: List Int8) :: BigInt is
  match xs with
    | Nil -> 0
    | Cons head tail -> 1 + size tail
  end
end
```

call:

```java
var symbols = new java.util.HashMap<String, Object>();
var count = lawspec.definitions.example.Total.size(symbols, java.util.List.of((byte) 1, (byte) 2));
```

The first argument is the Symbol context: share one map across calls when
fixture IDs should refer to the same Symbol. Arguments and results are
validated; an invalid value throws `IllegalArgumentException` naming the
definition. The implementation bodies are in `LawSpecDefinitionBodies.java`,
which the generated tests call too.

## Generation and shrinking

Tests use JetCheck generators and JUnit. Refined inputs use JetCheck's
`suchThat` filtering, limited to the smaller of `maxAttempts` and JetCheck's
100-attempt limit. A predicate that throws is reported as an error, not treated
as a rejected sample. Properties with only `Bool` inputs run at most as many
cases as there are input combinations (up to 100).

Constructor-contract properties run each case as a separate one-iteration
JetCheck session, which keeps native shrinking. JetCheck does not guarantee
the smallest counterexample.

## Formatting

Readable output follows Google Java Format. See
[formatting](../../reference/formatting.md).
