---
id: lawspec.how-to.targets.gleam
kind: how-to
title: Gleam target
---
# Gleam target

Use Erlang/OTP 29, Gleam 1.18 or 1.19, gleam_stdlib 1.0.5, gleeunit 1.11.0
and qcheck 1.0.5. Generated properties use qcheck's native generators and
shrinking and run through EUnit on the Erlang target.

## Build setup

`lawspec init --target gleam` creates `gleam.toml` with:

```toml
name = "example"
version = "0.1.0"
gleam = ">= 1.18.0"
target = "erlang"

[dependencies]
gleam_stdlib = "== 1.0.5"

[dev-dependencies]
gleeunit = "== 1.11.0"
qcheck = "== 1.0.5"
lawspec_test_support = { path = "./test-support" }
```

The development support package keeps property-testing FFI out of production
exports. Its `test-support/gleam.toml` is:

```toml
name = "lawspec_test_support"
version = "0.1.0"
target = "erlang"

[dependencies]
qcheck = "== 1.0.5"
```

Create `test-support/src` before the first build. Runtime and adapter modules
go in `src`, generated test facades in `test`, and native test helpers in
`test-support/src`. Gleam requires these roots; select another project `root`
to place the whole project elsewhere.

```sh
gleam build
npx lawspec doctor --target gleam
npx lawspec generate --target gleam
gleam test
```

## Adopt an existing application

Add the dependencies and local support package above. In
`test/<package-name>_test.gleam`, use this native entry point:

```gleam
@external(erlang, "lawspec_beam_test_run", "gleam_main")
pub fn main() -> Nil
```

Put application tests in other `*_test.gleam` modules. The entry point
discovers their ordinary tests alongside generated LawSpec suites and records
actual native completions. Doctor requires this entry point and rejects a
custom runner it cannot verify.

Doctor reads project configuration through Gleam's package-information
export and checks resolved dependency versions against compiled applications.
It does not run the tests.

`lawspec test --coverage` requires Gleam 1.19 for accurate original-source
line counters. Gleam 1.18 can still run the tests; the CLI reports that
coverage needs an upgrade.

## Crypto projects

Follow the shared [C/OpenSSL setup](erlang.md#native-crypto-bridge). After
generation, build the bridge before invoking Gleam:

```sh
escript lawspec_crypto_build.escript
gleam build
gleam test
```

`lawspec test` builds this bridge automatically before invoking Gleam when
the selected laws or benchmarks need to run. A failed bridge build stops the
command before tests start.

Ship the compiled `priv` directory with the application. The C toolchain is
needed for building the bridge, not at application startup.

## Resource adapters

Resource acquisition and release run in a dedicated owner process; the test
worker borrows the handle. Route operations on private native state back to
that owner. See [BEAM ownership and cancellation](../../reference/language/resources.md#beam-ownership-and-cancellation)
for the callback contract, owner-call helper and cleanup deadlines.
