---
id: lawspec.how-to.run-doctor
kind: how-to
title: Diagnose your environment with doctor
---
# Diagnose your environment with doctor

`doctor` checks that each configured target can build and run the generated
tests. It inspects the installed tools and the resolved build configuration,
and prints the change to make when something is wrong. It never edits build
files or installs dependencies.

```sh
npx lawspec doctor
npx lawspec doctor --target rust
npx lawspec doctor --json
```

Each target reports `ready`, or a message followed by the target's setup
instructions. The command exits with status 1 if any target is not ready.
`generate` runs the same checks before it writes anything.

## What doctor checks

Every target needs Node 22 or later. Beyond that:

| Target | Checks |
| --- | --- |
| `java` | Maven runs on Java 25+. The effective POM uses compiler plugin 3.14.x or 3.15.x with release 25, Surefire 3.5.x, and source directories that match `sourceDir` and `testDir`. JetCheck 0.3.0 and JUnit Jupiter 5.14.x (with its engine) resolve on the test classpath. Tests are not skipped or filtered. |
| `kotlin` | Gradle 9.1–9.3 on Java 25+, JVM target and test runtime 25+, Kotlin plugin 2.3.21, Kotest 5.9.1, unfiltered JUnit Platform test execution, and source sets that include the configured directories. |
| `python` | The selected interpreter is Python 3.13+, with pytest 8.4.x and Hypothesis 6.135.26 or a later 6.x installed. `pyproject.toml` sets pytest `pythonpath` and `testpaths` to the configured directories and has no custom test selection options. `PYTEST_ADDOPTS` is unset. |
| `javascript` | `package.json` has `"type": "module"` and fast-check 4.x is installed. |
| `typescript` | As JavaScript, plus TypeScript 5.9.x and `@types/node` 22.x. `tsconfig.json` uses `module` NodeNext, `rootDir` `.`, `outDir` `dist`, target ES2022 or later, emits output, and includes the source and test directories. |
| `go` | Go 1.22+ and Rapid v1.2.0, resolved without a local replacement. |
| `haskell` | Stack resolves a GHC and a test plan with Hspec 2.11, Hedgehog 1.5, hspec-hedgehog 0.3 and hspec-discover. The test directory has a `Spec.hs` that uses hspec-discover. The one Cabal package directly depends on `text` and `bytestring` in the component that compiles generated source, and has a test suite that depends on Hspec and Hedgehog. |
| `rust` | Rust 1.85+, a Cargo package with edition 2024, direct dependencies on proptest, num-bigint, num-rational, num-complex and num-traits, and the standard test harness. With a custom layout, the library path matches `sourceDir` and every generated test file is registered. |
| `erlang` | OTP 29, Rebar3 3.27.1, compiled PropEr 1.5.0 from Hex, the effective test profile's source directories, unfiltered EUnit discovery, and the `lawspec_beam_report` event listener. A checkout replacement or a compiled dependency that no longer matches its declaration fails. |
| `elixir` | OTP 29, Elixir 1.20.x, compiled StreamData 1.4.0 from Hex, both Erlang and Elixir compilers, source and test support directories, and unfiltered ExUnit configuration with `LawSpec.Beam.ExUnitFormatter`. The helper is evaluated with ExUnit autorun disabled; the suite is not run. |
| `gleam` | OTP 29, Gleam 1.18 or 1.19, the Erlang target, `src`/`test` directories, compiled gleam_stdlib 1.0.5, gleeunit 1.11.0 and qcheck 1.0.5, the local development support package, and the LawSpec native test entry point. Compiled versions must match the resolved dependencies and declarations. |

Finally, every version found is compared with the ranges in
[compatibility](../reference/compatibility.md). An unknown, prerelease, missing
or incompatible version fails the check.

When generation plans a BEAM crypto bridge, its preflight also
builds and loads the actual C/OpenSSL bridge in a temporary directory. A
standalone `doctor` performs this check when the generated bridge source
already exists in `priv`. This
checks the compiler, OTP headers, OpenSSL headers and libraries, algorithm
availability and shared-library ABI. It leaves the project's `priv` directory
untouched. Rebar and Mix must configure the bridge's build hook. See the
[native crypto setup](targets/erlang.md#native-crypto-bridge).

## Fix common failures

- **A dependency is missing or has the wrong version.** Install the version in
  the printed setup instructions. The [target guide](targets/index.md) lists
  them too.
- **Source or test directories do not match.** Either change your build to
  compile the directories in `lawspec.json`, or change `sourceDir` and
  `testDir` to match your build.
- **Custom filtering cannot be verified.** `doctor` rejects configuration it
  cannot check, such as Surefire includes, Gradle test filters, pytest
  `addopts` or TypeScript exclusions other than `node_modules` and `dist`.
  Remove the setting for the generated tests' build, or run them from a
  separate project root.
- **Haskell reports a missing Cabal file.** Run `stack build --test
  --no-run-tests` once so that Hpack generates it.
- **BEAM dependencies are declared but not compiled.** Prepare them with
  `rebar3 as test compile`, `mix deps.get` followed by
  `MIX_ENV=test mix deps.compile`, or `gleam build`. Doctor does not do this
  installation or application build for you.
- **A BEAM execution reporter is missing.** Follow the
  [Erlang](targets/erlang.md), [Elixir](targets/elixir.md) or
  [Gleam](targets/gleam.md) adoption instructions. Native completion events let
  the CLI distinguish tests that ran from tests that were filtered out.

Build tools may populate their normal caches while `doctor` resolves
dependencies. LawSpec never runs a dependency installer.
