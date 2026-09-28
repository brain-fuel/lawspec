# Rust backend

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

## Total definitions (0.9)

Unit-level definitions supply executable implementations alongside laws:

```lawspec
unit example.total

definition size (xs :: List Int8) :: BigInt is
  match xs with
    | Nil -> 0
    | Cons head tail -> 1 + size tail
  end
end
```

The compiler checks types, exhaustive matching, structural termination, and
potentially failing operations before emission. Definitions may call other
checked definitions, including forward references; they cannot call adapters.
Generic definitions specialize to concrete uses. Refinement predicates may call
checked definitions. Refined definition signatures become checked native contracts.

Rust emits their implementations into the generated source file
`lawspec_definitions.rs`. They are not user-owned adapter stubs. Typed native
entry points are grouped by unit, for example:

```rust
let mut context = lawspec_runtime::Context::default();
let count = lawspec_definitions::example_total::size(&mut context, vec![1, 2, 3])?;
```

These entry points return `lawspec_runtime::Result<T>` and check native values
at the boundary. Share the context when Symbol fixture identities must match.
Native machine-sized bindings check the architecture, including fields in
unselected data variants. The implementation has no Proptest dependency and can
be used by the application library. Generated properties invoke the same checked
implementation; remaining external declarations still receive adapter stubs.

`tools/rust-definitions-integration.mjs` verifies both machine profiles, custom
source/test roots, native calls, readable and compact source, exact `rustfmt`
layout, incorrect adapters, and regeneration ownership.

## Formatting (0.9)

Rust source uses four-space indentation and structured line wrapping. Request
compact layout explicitly with `lawspec generate --minify`, or `minify: true`
in the compiler API. The mode is not saved in project configuration. Formatting
switches preserve user-owned adapters and their canonical interface references.

`tools/rust-formatting-integration.mjs` compares all Rust artifacts generated
from the bundled examples and the total-definition fixture against rustfmt,
under both machine profiles. Formatting is implemented in the compiler; generated
projects do not need rustfmt to run. The bundled WASM uses the same layout.

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
| `List a` | `Vec<A>` |
| `Maybe a` | `Option<A>` |
| `Either a b` | Generated `Either<A, B>` |
| User-defined products and sums | Named generic enums in `lawspec_data` |

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

## Native data declarations

User-defined data emits reusable `lawspec_data.rs` and `lawspec_schema.rs` in the
source directory. Adapters receive native enum values with named, typed fields.
A product uses an enum with one record variant. Parameterized fields retain
Rust generic types; recursive fields use `Box` where an inline cycle requires
indirection, while `Vec` already supplies it. Mutually recursive declarations
are resolved together. When two units use the same type name, generated names
are qualified by their unit identities.

The runtime's `FromValue` and `IntoValue` traits provide conversion bridges.
Generated calls validate the complete logical value before conversion and the
native result before checking postconditions. This preserves raw UTF-16 units,
bytes, nested presence, and primitive range checks inside custom fields.
Machine-width checks also apply to machine integers inside custom data.

Generated enums derive `Clone` and `Debug`. LawSpec equality remains a runtime
operation: it compares fields structurally, retains IEEE NaN and signed-zero
rules, and compares Symbols by identity. It does not replace these rules with a
derived Rust `Eq` implementation.

Unused or exclusively recursive type parameters use a `PhantomData` marker.
Types with no constructors remain uninhabited; they do not acquire a synthetic
variant. Generated schemas and conversion support have no Proptest dependency.
The test support composes native Proptest strategies for recursive values and
shrinking, with deterministic boundary cases and finite-domain enumeration.
The structural budget counts each scalar, container, and constructor as one
node. Generation reserves every product field's minimum before distributing
remaining nodes. List length and element budgets vary together, so a deep
singleton remains reachable and lists have no hidden four-element limit.
Native shrinking preserves the schema and the structural budget.

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

Internal typed Core definitions with attached contracts are proved before Rust
emission. Generated source checks preconditions after argument validation and
postconditions after result validation, without property-framework dependencies.
Checks sequence through Result, preserving ordered predicates and contextual
failures. Native wrappers share logical enforcement. Readable contract bodies
match rustfmt exactly.
The shared native fixture passes both machine profiles and formatting modes,
including exact division, narrowing, nested calls, direct logical entry checks,
and rejection of corrupted results. Refined source definition signatures now
produce these contracts through template proof and specialization.

## Constructor field contracts

Rust checks constructor predicates at logical definition and native adapter
boundaries. Generated proptest strategies validate complete candidates, retain
native shrinking, and share each case's Symbol context with witness literals and
assertions. Only false predicates trigger retries; evaluation errors fail the
property. `maxAttempts` bounds local and global rejection, and exhaustion does
not prove an empty domain.

Validated witnesses seed nested payloads. Builtin lists and presence/sum
containers retain native structural shrinking; sampled named witnesses can
still produce larger counterexamples than native branches. Recursive named
refined payloads remain outside the currently supported contract fragment.
