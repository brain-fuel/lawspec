---
id: lawspec.how-to.targets.rust
kind: how-to
title: Set up Rust
---
# Set up Rust

## Requirements

- Rust 1.85 or later, edition 2024, and Cargo.
- Dependencies: num-bigint 0.4.8, num-rational 0.4.2, num-complex 0.4.6 and
  num-traits 0.2.19.
- Development dependency: Proptest 1.11.0.

## Create the project

```sh
npx lawspec init --target rust
npx lawspec doctor
npx lawspec generate
cargo test
cargo test --release
```

In a directory without build files, `init` creates a `Cargo.toml` with these
pinned dependencies and a `src/lib.rs` that includes the generated module
declarations:

```rust
include!("lawspec_modules.rs");
```

An existing library can include those declarations itself. Set a target's
`rustc` and `cargo` fields in `lawspec.json` to use other commands.

## Layout

| Files | Directory |
| --- | --- |
| Adapters (yours), such as `example/atoi_codec.rs` | `src` |
| `lawspec_runtime.rs`, `lawspec_modules.rs`, `lawspec_data.rs`, `lawspec_schema.rs`, `lawspec_definitions.rs` | `src` |
| Tests, such as `example_atoi_codec_lawspec.rs` | `tests` |
| `support/lawspec_strategies.rs` | `tests` |

The numeric runtime has no Proptest dependency.

With a custom `sourceDir`, set Cargo's `[lib] path` to the library entry point
in that directory. With a `testDir` other than `tests`, register each generated
test file with a `[[test]]` entry. `doctor` checks both.

## Native representations

Arguments and results are owned values. LawSpec adds no borrowing, lifetimes
or pointers; tests clone values where an input is used more than once.

| LawSpec | Rust |
| --- | --- |
| `Bool` | `bool` |
| Fixed-width integers | `i8`…`i64`, `u8`…`u64` |
| `IntSize`, `UIntSize`, `UIntPtr` | `isize`, `usize`, `usize` |
| `Whole`, `Nat` | `BigUint`, with domain checks |
| `Integer` argument | `BigInt` |
| `Integer` result | `Integer`, with lossless `From` implementations |
| `Decimal`, `Rational` | Generated `Decimal`, `BigRational` |
| `Duration` | `std::time::Duration` of whole microseconds |
| `Float32`, `Float64` | `f32`, `f64` |
| `Complex64`, `Complex128` | `Complex32`, `Complex64` from num-complex |
| `Char`, `Text` | `char`, `String` |
| `CodePoint`, `CodePointText` | Generated checked wrappers |
| `CodeUnit16`, `Utf16Text`, `Bytes` | `u16`, a generated UTF-16 wrapper, `Vec<u8>` |
| `Symbol` | A generated identity type; cloning keeps the identity |
| `Unit`, `Null`, `Undefined` | `()`, distinct generated absence types |
| `Nullable a`, `Optional a` | Distinct generated enums |
| `List a` | `Vec<A>` |
| `Maybe a` | `Option<A>` |
| `Either a b` | Generated `Either<A, B>` |
| Products | Named generic structs in `lawspec_data` |
| Sums | Named generic enums in `lawspec_data` |

`Integer` and `Decimal` are exported by the generated `lawspec_runtime` module.
For `successor :: Int8 -> Integer`, an implementation can compute in a wider
type:

```rust
use crate::lawspec_runtime as ls;

pub fn successor(value: i8) -> ls::Integer {
    (i16::from(value) + 1).into()
}
```

A product, a type with one constructor, is a struct with public fields named
after the type (`Pair { first, second }`), or a unit struct when it has no
fields. A sum is an enum with one variant per constructor. Recursive fields use
`Box` where needed; `Vec` already provides indirection. Unused type parameters
use `PhantomData`, and types with no constructors stay uninhabited. Generated
types derive `Clone` and `Debug`, but not `Eq`: LawSpec equality is a runtime
operation with IEEE and Symbol rules.

Machine-sized types check the executing architecture against `machineBits`.

## Checked definitions

```lawspec
unit example.total

function size (xs :: List Int8) -> Integer is
  first matching case of xs :
    when Nil then 0
    when Cons head tail then 1 + size tail
  end case
end function
end unit
```

```rust
let mut context = lawspec_runtime::Context::default();
let count = lawspec_definitions::example_total::size(&mut context, vec![1, 2, 3])?;
```

Entry points are grouped by unit and return `lawspec_runtime::Result<T>`. Share
the context when Symbol fixture identities must match. The definitions have no
Proptest dependency, so your library can use them.

## Generation and shrinking

Tests use Proptest strategies. Integer bounds over earlier inputs become
dependent strategies; shrinking recomputes them. A refinement that throws fails
the test instead of rejecting the sample. `maxAttempts` bounds rejection.

## Formatting

Output is what `rustfmt` writes with its default settings at edition 2024:
four-space indentation, 100 columns, and its rules for breaking calls,
chains and match arms. LawSpec lays it out itself, so generation needs no
formatter, and LawSpec's own acceptance checks every generated project with
the pinned toolchain's `rustfmt --check`. Generated files carry no blanket
`allow` attributes: a test crate's mounted shared modules allow the parts
it does not use, and a function that keeps a definition's camel-case name
says so on the function.

## Names and tests

Generated code uses the specification's names. Inputs, resources and the
binders inside a law keep their source names; a checked definition's entry
is named after it in snake case (`feeModel` is `fee_model`), with `_2` only
when two would share a name. Each law is a module of tests named after it,
with one test per example, one per boundary case and one for its generated
cases (or all of its finite cases): `law_normalizers_agree::property`,
`law_normalizers_agree::spaces_become_hyphens_punctuation_is_preserved`,
`law_normalizers_agree::boundary_1`. `cargo test law_normalizers_agree::`
runs one law. An anonymous record is a type named from where it is used: the
payload of a `Declined` case is `DeclinedDetails`. Each law, test and
adapter call has a comment linking it to its source line, text is written as
Rust string literals, and an expectation that fails names its law, its
example and the line it is written on.
