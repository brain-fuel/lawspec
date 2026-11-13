---
id: lawspec.reference.compatibility
kind: reference
title: Compatibility
---
# Compatibility

LawSpec needs Node 22 or later. The reference platforms are macOS and Linux.
Each target also needs its own toolchain and test libraries.

## Windows

Native Windows is supported for the CLI with the Java, Kotlin, Groovy, Scala,
JavaScript and TypeScript targets. The other targets are best-effort on native
Windows; WSL runs every target as Linux does.

The CLI finds a build tool the way Windows does: in the project directory, then
in each `PATH` directory, with each `PATHEXT` extension. `mvn` therefore finds
`mvn.cmd`, and a project's `gradlew.bat` is used when it exists. A manifest
field such as `:maven "mvn.cmd"` or `:maven "C:/tools/maven/bin/mvn.cmd"`
names the tool explicitly. Setting the `NoDefaultCurrentDirectoryInExePath`
environment variable leaves the project directory out of the search.

A batch file (`.cmd` or `.bat`: Maven, Gradle, npm, npx, Mix, Rebar3) runs
through `cmd.exe /e:ON /v:OFF /d /s /c`. Each argument is quoted so that
`cmd.exe` reads it as text: spaces, quotes, `%`, `^`, `&`, `|`, `<`, `>`,
parentheses and `!` reach the tool unchanged. Three things cannot be quoted,
and the CLI stops with a message without running anything: an argument that
contains a line break or a NUL, a batch file whose path contains `"` or `%`,
and a command line longer than the 8,191 characters `cmd.exe` accepts. Rebar3
coverage collection passes a line break and is refused for that reason. An
`.exe` is started directly and has none of these limits.

A tool that cannot be found is reported by `doctor`, `generate` and `test`
with the directories and extensions searched, the manifest field that names
the tool, and what to install.

The `Test:` line that `generate` prints has the form
`cmd /d /s /c "cd /d <project> && <command>"`. It runs unchanged in `cmd` and
in PowerShell when neither the project path nor the tool path needs quotes.
A path that contains a space or another character outside letters, digits and
`_ @ + - . / : \ =` is quoted inside that line, and the line is then valid in
`cmd` only.

Stopping the CLI while a batch file runs ends `cmd.exe`; the tool the batch
file started can outlive it.

## Supported versions

Ranges are inclusive minimum, exclusive maximum. `doctor` and `generate` reject
unknown, prerelease, missing and out-of-range versions.

| Target | Tool or library | Supported |
| --- | --- | --- |
| Java | Java | 25; 21 to 25 with [`:release 21`](#java-release-21) |
| | JetCheck | 0.3.0 |
| | JUnit Jupiter | 5.14.x, 6.0.x |
| | Maven compiler plugin | 3.14.x, 3.15.x |
| | Surefire | 3.5.x |
| Python | Python | 3.13, 3.14 |
| | pytest | 8.4.x |
| | Hypothesis | 6.135.26 and later 6.x |
| Prolog | SWI-Prolog | 10 and later; exercised with 10.0.2 |
| | Python | 3.13 and later; exercised with 3.13.15 |
| | Janus | janus-swi 1.5.3 |
| | pytest and Hypothesis | Same pinned test dependencies as Python |
| JavaScript | Node | 22 and later |
| | fast-check | 4.x |
| TypeScript | Node | 22 and later |
| | fast-check | 4.x |
| | TypeScript | 5.9.x |
| | `@types/node` | 22.x |
| Go | Go | 1.22–1.26 |
| | Rapid | >=1.2.0 <1.4.0 (new projects use 1.3.0) |
| Haskell | GHC | 9.10 (Stack `lts-24.58`) |
| | hspec | 2.11 |
| | hedgehog | 1.5 |
| | hspec-hedgehog | 0.3.0.0 |
| Kotlin | Java | 25 |
| | Gradle | 9.1–9.3 |
| | Kotlin | 2.3.21 |
| | Kotest | 5.9.1 |
| Rust | Rust | 1.85 and later (edition 2024) |
| | proptest | 1.11.0 |
| | num-bigint | 0.4.8 |
| | num-rational | 0.4.2 |
| | num-complex | 0.4.6 |
| | num-traits | 0.2.19 |
| Erlang | OTP | 29 |
| | Rebar3 | 3.27.1 and later 3.27.x |
| | PropEr | 1.5.0 |
| Elixir | OTP | 29 |
| | Elixir | 1.20.x |
| | StreamData | 1.4.0 |
| Gleam | OTP | 29 |
| | Gleam | 1.18, 1.19 |
| | gleam_stdlib | 1.0.5 |
| | gleeunit | 1.11.0 |
| | qcheck | 1.0.5 |
| F# | .NET SDK | 10 |
| | xunit.v3 | 4.0.2 |
| | FsCheck | 3.4.0 |
| | BouncyCastle.Cryptography | 2.7.0 |
| C# | .NET SDK | 10 |
| | xunit.v3 | 4.0.2 |
| | FsCheck | 3.4.0 |
| | BouncyCastle.Cryptography | 2.7.0 |
| Scala | Java | 25 |
| | Scala CLI | 1.16 |
| | Scala | 3.9, 3.10 |
| | ScalaCheck | 1.20.0 |
| | ScalaTest | 3.2.20 |
| Groovy | Java | 25 |
| | Gradle | 9.1–9.3 |
| | Groovy | 5.0.x |
| | Spock | 2.5 (for Groovy 5.0) |
| | JetCheck | 0.3.0 |
| Clojure | Java | 25 |
| | Clojure | 1.12 |
| | test.check | 1.1.3 |
| Swift | Swift | 6.2, 6.3 |
| | Swift Testing | from the toolchain |

Java 25 and Python 3.13 are minimum baselines. New JVM releases are admitted
after testing; the current profile certifies Java 25.

### Java release 21

A Java target with `:release 21` in `lawspec.edn` compiles its generated code,
runtime and tests at Java 21, for a build on that LTS. `doctor` then requires
`maven.compiler.release` 21 and a JDK from 21 to 25. The default stays 25, and
no other release is accepted.

The generated code and runtime are the same at both releases. Two units need a
newer release, because their Java handlers use the JDK's ML-KEM and ML-DSA
(JEP 496 and JEP 497, Java 24):

| Unit | Minimum Java release |
| --- | --- |
| `lawspec.crypto` | 24 |
| `lawspec.network` | 24 |

Generating a program that imports either for a release 21 target stops with a
`release` diagnostic naming the unit and that minimum. Give such a program a
target at release 25.

Release 21 is certified by compiling and running the Java acceptance suites,
other than the two that import those units, with `javac --release 21` on
JDK 25, which checks the language level and the Java 21 API. Running the tests
on a JDK 21 virtual machine has not been exercised.

### JUnit Jupiter

The Java target supports JUnit Jupiter 5.14.x and 6.0.x. The acceptance
suites run on 5.14.0, which `init` pins, and on 6.0.3, which Spring Boot 4.0
and 4.1 manage. JUnit 6.1 has not been tested and is rejected.

`doctor` checks the versions Maven resolved, not the ones a POM declares. A
BOM in `dependencyManagement` decides the versions of `junit-jupiter-api` and
`junit-jupiter-engine` beneath a `junit-jupiter` dependency whatever version
that dependency names. When the resolved release is outside the range, import
`org.junit:junit-bom` 5.14.0 before the BOM that manages it; see
[Add LawSpec to a Spring Boot service](../how-to/spring-boot.md#let-one-bom-decide-junit).

BEAM crypto projects additionally require a Unix C toolchain and OpenSSL
3.5 or later development files with the same major version as OTP's OpenSSL.
The bridge builder supports macOS and Linux; Windows uses WSL. Native Windows
builds are not currently supported. Doctor compiles and loads the bridge to
check this combination; non-crypto BEAM projects do not need a C compiler.

.NET crypto projects reference BouncyCastle.Cryptography for the
post-quantum algorithms .NET does not provide on the host.

Swift crypto projects need macOS 26, whose CryptoKit provides ML-KEM-768 and
ML-DSA-65. The runtime implements SHAKE256 and SLH-DSA itself, since CryptoKit
lacks them.

## Record rules and masking

What each target does for [record rules and masking](language/record-rules.md),
and what the acceptance suites did there when 0.34.0 was prepared.

| | Java, JavaScript, TypeScript, Python | Kotlin, Scala, Groovy, Clojure, Prolog | Go, Haskell, Rust, Erlang, Elixir, Gleam, F#, C#, Swift |
| --- | --- | --- | --- |
| Validators, rule ids, `maskedR`, generated laws | yes | yes | yes |
| `digest`, `maskDigest`, `maskHash key`, `maskedRWith`, the `blake3` functions | yes | yes | yes |
| Native rendering masked | yes | no; generation warns `target-unsupported` | no; generation warns `target-unsupported` |
| Failed-test output masked | yes | yes, through the Java or Python runtime under them | **no**: a failed generated test prints the failing record's fields as they are |
| `hash` under a key the application configures | yes | no; `maskedR` shows `***`, `maskedRWith` takes the key | the same |
| `rfc822Address` | yes | refused, `target-unsupported` | refused, `target-unsupported` |
| Logging hook | Java: wrapper and Logback converter; the others need none | none | none |

On the targets of the last column, keep the output of failed generated
tests out of shared logs when the records under test hold personal data, or
test with made-up values. The frameworks there print a failing input
through the record's native rendering, which is not masked.

BLAKE3 by target:

| Target | BLAKE3 | Official vectors, three modes |
| --- | --- | --- |
| Go | the module `goforge.dev/blake3sum` v1.0.0 | pass |
| Java, Kotlin, Scala, Groovy, Clojure | LawSpec's Java runtime | pass on each |
| JavaScript, TypeScript | LawSpec's JavaScript runtime | pass on each |
| Python, Prolog | LawSpec's Python runtime | pass on each |
| Rust | LawSpec's Rust runtime | pass |
| Haskell | LawSpec's Haskell runtime | pass |
| F#, C# | LawSpec's .NET runtime | pass on each |
| Swift | LawSpec's Swift runtime | pass |
| Erlang, Elixir, Gleam | LawSpec's BEAM runtime | pass on each |

Acceptance runs. "Pass" is the whole suite: the laws, and every mutant
rejected.

| Suite | Passes |
| --- | --- |
| `contracts-digest` (official vectors, digest masks, keyed hash under one key) | all 18 program targets |
| `contracts-validation` | all 18 program targets |
| `contracts-masking` | all 18 program targets. On Go, Haskell, Rust, Erlang, Elixir, Gleam, F#, C# and Swift its two mutants must fail, and their output is not checked for masked values: each mutant file declares that, with the reason, and the run prints it |
| `contracts-primitives` | Java, JavaScript, TypeScript, Python; every other target refuses it for `rfc822Address` |

The check (`lawspec-dev ci`) runs the first three on every program target
and `contracts-primitives` on those four.

## C# over F#

The C# target compiles the program's model (data types, codecs, ability
interfaces and bridges, schema, actors, sessions and mailboxes) as a
generated F# project, `lawspec/LawSpec.Model`, and C# calls it and the F#
runtime directly. Every public runtime function has a PascalCase compiled
name. The namespace `LawSpec.CSharp` is the compatibility layer:

- `Fn.F0` to `Fn.F6` make curried F# functions from delegates, and
  `Fn.Invoke` applies one.
- `Fn.List`, `Fn.ListOf`, `Fn.Tuple`, `Fn.Some` and `Fn.None` make F# lists,
  tuples and options; `Fn.Run` gives a block's value.
- `V` has a method per portable `Value` case.
- `Maybe` gives `IsSome`, `IsNone`, `GetOrElse` and `Match` on F# options,
  and `Outcome.Ok` and `Outcome.Error` make F# results.

F#'s unit value is `default(Unit)`. A C# adapter takes no `Unit` argument and
returns `void` for `Unit`. See [Set up C#](../how-to/targets/csharp.md).

## Groovy over Java

The Groovy target uses the Java target's model (data types, codecs, ability
interfaces, checked definitions, schema, actors, sessions, mailboxes and the
network), which Gradle compiles jointly with the Groovy sources. Adapters are
Groovy classes checked with `@CompileStatic`, and the laws are Spock
specifications whose properties run on JetCheck. See
[Set up Groovy](../how-to/targets/groovy.md).

## Clojure over Java

The Clojure target uses the Java target's model too, compiled by the JDK's
compiler into `target/classes`. Adapters are functions of a namespace per
unit, called through a generated Java bridge that converts values to Clojure
data, and the laws are `clojure.test` tests whose properties run on
test.check. See [Set up Clojure](../how-to/targets/clojure.md).

## Versions pinned by `init`

When `init` creates a scaffold, it pins:

| Target | Pinned |
| --- | --- |
| Java | release 25 (21 with `init --release 21`), JetCheck 0.3.0, JUnit Jupiter 5.14.0, compiler plugin 3.14.1, Surefire 3.5.4 |
| Python | `requires-python = ">=3.13"`, pytest 8.4.2, Hypothesis 6.135.26, setuptools 80.9.0 |
| Prolog | Python scaffold pins plus janus-swi 1.5.3; the selected interpreter loads SWI-Prolog |
| JavaScript | fast-check 4.10.2 |
| TypeScript | fast-check 4.10.2, TypeScript 5.9.3, `@types/node` 22.20.4 |
| Go | `go 1.25.0`, Rapid v1.3.0 |
| Haskell | `lts-24.58`; hspec, hedgehog, hspec-hedgehog, hspec-discover, containers, mtl |
| Kotlin | Kotlin plugin 2.3.21, `jvmToolchain(25)`, Kotest 5.9.1 |
| Rust | edition 2024, `rust-version = "1.85"`, proptest 1.11.0, num-bigint 0.4.8, num-rational 0.4.2, num-complex 0.4.6, num-traits 0.2.19 |
| Erlang | OTP 29 profile, PropEr 1.5.0, LawSpec EUnit reporter |
| Elixir | Elixir `~> 1.20`, StreamData 1.4.0, LawSpec ExUnit formatter |
| Gleam | Gleam 1.18+, Erlang target, gleam_stdlib 1.0.5, gleeunit 1.11.0, qcheck 1.0.5, local `lawspec_test_support` |
| F# | `net10.0`, Microsoft.Testing.Platform in `global.json`, xunit.v3 4.0.2, FsCheck 3.4.0 |
| C# | `net10.0`, Microsoft.Testing.Platform in `global.json`, xunit.v3 4.0.2, FsCheck 3.4.0, the generated F# model project |
| Scala | `project.scala`: Scala 3.9.0, ScalaCheck 1.20.0, ScalaTest 3.2.20 (`scalatest-funsuite`) |
| Clojure | Clojure 1.12.5, test.check 1.1.3, a `:test` alias running `lawspec.test-runner` |
| Groovy | Groovy 5.0.8, a Java 25 toolchain, Spock 2.5-groovy-5.0, JetCheck 0.3.0, JUnit Jupiter API 5.14.0, joint Java and Groovy source sets |
| Swift | `swift-tools-version: 6.2`, `.macOS(.v26)`, no package dependencies |

## What the checks inspect

`doctor` inspects resolved dependencies, compiler settings, source roots and
test-runner configuration, not just installed versions. Custom filtering or
configuration it cannot verify is rejected with instructions. Build tools may
populate their normal caches while it resolves dependencies; LawSpec never runs
a dependency installer. See [Diagnose your environment with doctor](../how-to/run-doctor.md).

Rapid 1.3.0 reads `RAPID_*` flag defaults during package initialization. Generated
LawSpec checks explicitly set their case count and the CLI supplies `LAWSPEC_SEED`
for replay, overriding Rapid's default checks and seed. Other Rapid flags remain
framework controls; they are not LawSpec evaluation limits. Malformed `RAPID_*`
values can fail Rapid initialization before LawSpec's explicit settings run.
See the released [Rapid engine](https://github.com/flyingmutant/rapid/blob/v1.3.0/engine.go).
Local Go module replacements remain incompatible with the release check.
