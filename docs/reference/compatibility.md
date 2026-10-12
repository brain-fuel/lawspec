---
id: lawspec.reference.compatibility
kind: reference
title: Compatibility
---
# Compatibility

LawSpec needs Node 22 or later. The reference platforms are macOS and Linux.
Each target also needs its own toolchain and test libraries.

## Supported versions

Ranges are inclusive minimum, exclusive maximum. `doctor` and `generate` reject
unknown, prerelease, missing and out-of-range versions.

| Target | Tool or library | Supported |
| --- | --- | --- |
| Java | Java | 25 |
| | JetCheck | 0.3.0 |
| | JUnit Jupiter | 5.14.x |
| | Maven compiler plugin | 3.14.x, 3.15.x |
| | Surefire | 3.5.x |
| Python | Python | 3.13, 3.14 |
| | pytest | 8.4.x |
| | Hypothesis | 6.135.26 and later 6.x |
| JavaScript | Node | 22 and later |
| | fast-check | 4.x |
| TypeScript | Node | 22 and later |
| | fast-check | 4.x |
| | TypeScript | 5.9.x |
| | `@types/node` | 22.x |
| Go | Go | 1.22–1.26 |
| | Rapid | 1.2.0 |
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
| Groovy | Java | 25 |
| | Gradle | 9.1–9.3 |
| | Groovy | 5.0.x |
| | Spock | 2.5 (for Groovy 5.0) |
| | JetCheck | 0.3.0 |

Java 25 and Python 3.13 are minimum baselines. New JVM releases are admitted
after testing; the current profile certifies Java 25.

BEAM crypto projects additionally require a Unix C toolchain and OpenSSL
3.5 or later development files with the same major version as OTP's OpenSSL.
The bridge builder supports macOS and Linux; Windows uses WSL. Native Windows
builds are not currently supported. Doctor compiles and loads the bridge to
check this combination; non-crypto BEAM projects do not need a C compiler.

.NET crypto projects reference BouncyCastle.Cryptography for the
post-quantum algorithms .NET does not provide on the host.

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

## Versions pinned by `init`

When `init` creates a scaffold, it pins:

| Target | Pinned |
| --- | --- |
| Java | release 25, JetCheck 0.3.0, JUnit Jupiter 5.14.0, compiler plugin 3.14.1, Surefire 3.5.4 |
| Python | `requires-python = ">=3.13"`, pytest 8.4.2, Hypothesis 6.135.26, setuptools 80.9.0 |
| JavaScript | fast-check 4.10.2 |
| TypeScript | fast-check 4.10.2, TypeScript 5.9.3, `@types/node` 22.20.4 |
| Go | `go 1.22`, Rapid v1.2.0 |
| Haskell | `lts-24.58`; hspec, hedgehog, hspec-hedgehog, hspec-discover, containers, mtl |
| Kotlin | Kotlin plugin 2.3.21, `jvmToolchain(25)`, Kotest 5.9.1 |
| Rust | edition 2024, `rust-version = "1.85"`, proptest 1.11.0, num-bigint 0.4.8, num-rational 0.4.2, num-complex 0.4.6, num-traits 0.2.19 |
| Erlang | OTP 29 profile, PropEr 1.5.0, LawSpec EUnit reporter |
| Elixir | Elixir `~> 1.20`, StreamData 1.4.0, LawSpec ExUnit formatter |
| Gleam | Gleam 1.18+, Erlang target, gleam_stdlib 1.0.5, gleeunit 1.11.0, qcheck 1.0.5, local `lawspec_test_support` |
| F# | `net10.0`, Microsoft.Testing.Platform in `global.json`, xunit.v3 4.0.2, FsCheck 3.4.0 |
| C# | `net10.0`, Microsoft.Testing.Platform in `global.json`, xunit.v3 4.0.2, FsCheck 3.4.0, the generated F# model project |
| Groovy | Groovy 5.0.8, a Java 25 toolchain, Spock 2.5-groovy-5.0, JetCheck 0.3.0, JUnit Jupiter API 5.14.0, joint Java and Groovy source sets |

## What the checks inspect

`doctor` inspects resolved dependencies, compiler settings, source roots and
test-runner configuration, not just installed versions. Custom filtering or
configuration it cannot verify is rejected with instructions. Build tools may
populate their normal caches while it resolves dependencies; LawSpec never runs
a dependency installer. See [Diagnose your environment with doctor](../how-to/run-doctor.md).
