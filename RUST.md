# Rust backend (0.8)

Rust is the first backend built on LawSpec's typed core and testing plan. The
compiler remains implemented in Haskell. Rust generation does not parse source
expressions, infer their types, or expand refinement declarations.

## Project setup

Use Rust 1.85 or later, edition 2024, and Cargo. The generated project pins
Proptest 1.11.0, num-bigint 0.4.8, num-rational 0.4.2, num-complex 0.4.6, and
num-traits 0.2.19.

```sh
lawspec init --target rust
lawspec doctor
lawspec generate
cargo test
cargo test --release
```

Adapters are user-owned files under `src/`. LawSpec maintains
`lawspec_runtime.rs`, module declarations in `lawspec_modules.rs`, and tests
under `tests/`. The scaffolded `src/lib.rs` includes the generated declarations;
an existing library can include those declarations explicitly. Generation
preserves edited adapters and reports required signature updates.

The numeric runtime has no Proptest dependency. Framework support lives in a
separate generated file, `tests/support/lawspec_strategies.rs`.

## Owned adapter values

Arguments and results are owned Rust values. LawSpec does not add borrowing,
lifetimes, or pointer operations to its language. Tests clone values where an
expression needs to use an input more than once.

| LawSpec domain | Rust adapter representation |
| --- | --- |
| `Bool` | `bool` |
| Fixed signed/unsigned integers | `i8`…`i64`, `u8`…`u64` |
| `IntSize`, `UIntSize`, `UIntPtr` | `isize`, `usize`, `usize` |
| `BigInt`, `BigUInt` | `BigInt`, `BigUint` |
| `Integer` input | `BigInt` |
| `Integer` result | `Integer`, with lossless `From` implementations |
| `Decimal`, `Rational` | Generated `Decimal`, `BigRational` |
| `Float32`, `Float64` | `f32`, `f64` |
| `Complex64`, `Complex128` | `Complex32`, `Complex64` from num-complex |
| `Char`, `Text` | `char`, `String` |
| `CodePoint`, `CodePointText` | Generated checked wrappers |
| `CodeUnit16`, `Utf16Text`, `Bytes` | `u16`, generated UTF-16 wrapper, `Vec<u8>` |
| `Symbol` | Generated identity type; cloning preserves identity |
| `Unit`, `Null`, `Undefined` | `()`, distinct generated absence types |
| `Nullable a`, `Optional a` | Distinct generated enums, including nested presence |

Names such as `Integer` and `Decimal` above are exported by the generated
`lawspec_runtime` module. Machine-sized native bindings check the requested
`machineBits` against the executing architecture.

For a declaration such as `successor :: Int8 -> Integer`, an implementation can
return a wider native integer through the logical result wrapper:

```rust
use crate::lawspec_runtime as ls;

pub fn successor(value: i8) -> ls::Integer {
    (i16::from(value) + 1).into()
}
```

Exact arithmetic in laws uses arbitrary precision. Passing its result to an
`i8` adapter parameter performs a checked conversion. A fractional or
out-of-range value fails with the adapter's context.

`Decimal` stores an arbitrary integer coefficient and exponent. Decimal
arithmetic is exact; explicit rounding uses the requested scale and ties to
even. Exact-to-float conversion rounds directly to the requested IEEE precision,
including subnormal and halfway cases.

## Refinements and generation

Small finite domains are enumerated. Larger domains use native Proptest
strategies. Integer bounds over earlier inputs become dependent strategies;
when a prefix has no possible continuation, generation retries the prefix.
Shrinking recomputes those dependent bounds and retains only valid tuples.
Refinement evaluation errors fail the test rather than being counted as rejected
samples. Generation limits prevent an empty or unreachable domain from passing
vacuously.

Contracts check preconditions, evaluate the adapter once, validate its native
result, and then check postconditions on that result.

## Custom layouts

`sourceDir` and `testDir` move generated sources and imports together. Set Cargo's
`[lib] path` to the library entry point under the selected source directory. For
test directories other than `tests`, register generated test files using Cargo
`[[test]]` entries. Doctor checks the selected Cargo package, edition, resolved
dependencies, library directory, and custom test registration.
