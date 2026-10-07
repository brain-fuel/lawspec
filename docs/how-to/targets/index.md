---
id: lawspec.how-to.targets.index
kind: how-to
title: Target setup guides
---
# Target setup guides

Each guide covers one target: the toolchain it needs, what `init` creates,
where generated files go, and how LawSpec types appear in your code.

| Target | Build setup | Test libraries | Test command |
| --- | --- | --- | --- |
| [`java`](java.md) | Maven, JDK 25, release 25 | JetCheck 0.3.0, JUnit Jupiter 5.14.x | `mvn test` |
| [`python`](python.md) | Python 3.13 or 3.14, pyproject | pytest 8.4.x, Hypothesis 6.135.26+ (6.x) | `python -m pytest` |
| [`javascript`](javascript.md) | Node 22+, npm, ESM | fast-check 4.x, node:test | `npm test` |
| [`typescript`](typescript.md) | Node 22+, npm, TypeScript 5.9.x, ESM | fast-check 4.x, node:test | `npm test` |
| [`go`](go.md) | Go modules, Go 1.22–1.26 | Rapid 1.2.0, testing | `go test ./...` |
| [`haskell`](haskell.md) | Stack, GHC 9.10, LTS 24.58 | Hspec 2.11, Hedgehog 1.5, hspec-hedgehog 0.3 | `stack test` |
| [`kotlin`](kotlin.md) | JDK/JVM 25, Gradle 9.1–9.3, Kotlin 2.3.21 | Kotest 5.9.1 | `gradle test` |
| [`rust`](rust.md) | Rust 1.85+, edition 2024, Cargo | Proptest 1.11.0 | `cargo test` |

Exact version bounds are in [compatibility](../../reference/compatibility.md).

## What every target has in common

- **Adapters are yours.** `generate` creates one adapter stub per unit the first
  time, then never rewrites it. If a contract changes, it prints the new
  signature for you to apply.
- **Runtime support is source; test helpers are tests.** Generated data types,
  schemas, codecs, checked definitions and the scalar runtime go in the source
  directory and have no test-framework dependency. Property-testing helpers go
  in the test directory.
- **Values are checked at the boundary.** Every call into an adapter validates
  its arguments and result against the LawSpec types, including ranges,
  Unicode validity and the machine profile.
- **LawSpec equality is used, not native equality.** NaN differs from itself,
  signed zeros compare equal, Symbols compare by identity, and structures
  compare field by field.
- **Generation is native.** Tests use the framework's own generators and
  shrinkers. Recursive values have a size budget that reserves room for every
  field. Small finite domains are enumerated. An empty domain never makes a
  property pass.

See [formatting](../../reference/formatting.md) for each target's layout.
