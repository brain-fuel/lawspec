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

Java 25 and Python 3.13 are minimum baselines. New JVM releases are admitted
after testing; the current profile certifies Java 25.

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

## What the checks inspect

`doctor` inspects resolved dependencies, compiler settings, source roots and
test-runner configuration, not just installed versions. Custom filtering or
configuration it cannot verify is rejected with instructions. Build tools may
populate their normal caches while it resolves dependencies; LawSpec never runs
a dependency installer. See [Diagnose your environment with doctor](../how-to/run-doctor.md).
