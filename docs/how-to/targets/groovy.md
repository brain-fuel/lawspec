---
id: lawspec.how-to.targets.groovy
kind: how-to
title: Set up Groovy
---
# Set up Groovy

Groovy runs over the Java model. The program's data types, codecs, ability
interfaces, checked definitions, schema, actors, sessions, mailboxes and
network are the [Java target's](java.md), which Gradle compiles together with
your Groovy code. The adapters you write are Groovy classes, and each unit's
laws are a Spock specification.

## Requirements

- JDK 25 and Gradle 9.1 to 9.3 with the `groovy` plugin.
- Groovy 5.0 (`org.apache.groovy:groovy`).
- Test dependencies: Spock 2.5 for Groovy 5.0, JetCheck 0.3.0 and the JUnit
  Jupiter 5.14 API.
- Bouncy Castle `bcprov-jdk18on` 1.86, only for programs that import
  `lawspec.crypto` or `lawspec.network`.

## Create the project

```sh
npx lawspec init --target groovy
npx lawspec doctor
npx lawspec generate
gradle test
```

`init` creates `settings.gradle` and a `build.gradle` with these dependencies.
It makes `src/main/java` and `src/test/java` Groovy source directories, so the
Java model and your Groovy classes compile jointly and can call each other.
The generated build lets Groovy compiler workers use up to 2 GiB of heap.
Large scoped-search specifications exceed Gradle's 512 MiB worker default
during parsing. This is a maximum, rather than a fixed allocation; adjust
`groovyOptions.forkOptions.memoryMaximumSize` in your build when needed.

## Layout

| Files | Directory |
| --- | --- |
| Adapters (yours): one class per unit, such as `example/AtoiCodec.groovy` | `src/main/groovy` |
| Application code bound in `lawspec.edn` | anywhere in `src/main/groovy` |
| The Java model: runtime, data types, definitions, abilities | `src/main/java` |
| Specifications, such as `example/AtoiCodecLawSpec.groovy` | `src/test/groovy` |
| JetCheck helpers and the harness runtime | `src/test/java` |

`sourceDir` and `testDir` move the source and test directories, the Java
model with them; point the Groovy source sets at them.

## Adapters

Unit `example.parse_port` gives `final class ParsePort` in package `example`,
with a static method per adapter. The stub is checked with `@CompileStatic`,
so an adapter is typed as it would be in Java:

```groovy
@groovy.transform.CompileStatic
final class AtoiCodec {
  static String itoa(int value) { Integer.toString(value) }

  static int atoi(String value) { Integer.parseInt(value) }
}
```

Two things differ from Java. An `int` divided by an `int` is a `BigDecimal` in
Groovy, so integer division is `a.intdiv(b)`. A local variable named like a
method hides the method in a closure, as `serve` would hide `serve(...)`.

A name that is a Groovy keyword (`as`, `def`, `in`, `trait`) is emitted with a
leading underscore, as Java's keywords are.

## Native representations

The types are [Java's](java.md#native-representations): a product is a
record, read as `drink.shots()`; a sum is a sealed interface with a nested
record per constructor. Groovy has no record patterns, so match a sum with
`instanceof`, which binds and narrows:

```groovy
static BigInteger evaluate(Expr<BigInteger> expr) {
  if (expr instanceof Expr.Plus plus) return evaluate(plus.left()) + evaluate(plus.right())
  ((Expr.Number) expr).value()
}
```

`switch` takes a case's class, without a binding:
`case Size.Small -> 250`. Under `@CompileStatic`, `instanceof` drops type
arguments, so cast to the parameterized type where they matter.

A nested runtime type, such as `LawSpecRuntime.Value`, is written in full
(`lawspec.runtime.LawSpecRuntime.Value`) in a method or field declaration:
Groovy's joint-compilation stubs drop an import used only as an outer name.

## Native bindings

`lawspec.edn` binds types, functions, methods, handlers and failures to
Groovy classes, as it does to Java ones. A bound type that the Java model
constructs must declare its canonical constructor and accessors, since the
stubs the Java side compiles against leave a record's out:

```groovy
record Cash(long cents) {
  Cash(long cents) { this.cents = cents }

  long cents() { cents }
}
```

## Checked definitions, handlers, actors and sessions

These are the Java model's classes, called from Groovy as from Java. A checked
definition is a static method under `lawspec.definitions`, taking the Symbol
context first:

```groovy
def symbols = new HashMap<String, Object>()
def count = lawspec.definitions.example.Total.size(symbols, [1 as byte, 2 as byte])
```

Spec handlers, actors, sessions, mailboxes, the network and the secure handler
are the [Java ones](java.md); their wire format is the same on every target.

## Tests

Each unit's laws are a Spock specification. A feature is named after the law
and the kind of test, such as `"integer promotion: example 0"` or
`"integer promotion: property"`, and its setup block fails the feature by
throwing. Properties run on JetCheck with LawSpec's generators: refined inputs
draw inside their refinement, and shrinking keeps every candidate inside it.
`LAWSPEC_SEED` replays a run.

The harness maps onto Spock: a skipped law is `@Ignore`d; `order random`
shuffles a specification's features by the run's seed; `parallel` marks the
specification `@Execution(CONCURRENT)`, which `src/test/resources/SpockConfig.groovy`
enables for those specifications only. Retries, timeouts, cover, targeted
search, the failure database and benchmarks run in the harness runtime, and
Gradle writes the JUnit XML report to `build/test-results/test`.

`npx lawspec test` selects the features of the laws an edit can affect with
Gradle's `--tests` filters.

The specification is generated from the plan rather than rewritten from Java:
the law's comment (its name, source line and the statement its tests check)
is above its first feature, and a feature runs the test in the Java model's
JUnit class, so both targets check a law the same way. Generated Groovy uses
Allman braces with Google's other rules and passes CodeNarc 4.0.0 with the
profile in `acceptance/formatters/groovy-codenarc.xml`, which LawSpec's
acceptance runs on every generated project.
