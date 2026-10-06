---
id: lawspec.how-to.custom-codecs-and-generators
kind: how-to
title: Write custom codecs and generators
---
# Write custom codecs and generators

This guide covers two extensions to [native type bindings](bind-native-types.md):
codec hooks, for application types that constructor and field mappings cannot
describe, and generator bindings, which make the generated tests draw values
from your own property-testing generators.

## Convert with codec hooks

A type binding can name a pair of conversion functions instead of mapping
constructors and fields:

```json
{
  "type": "native.codecs::type::Parcel",
  "native": ["crate", "domain", "Parcel"],
  "codec": {
    "toNative": ["crate", "codecs", "to_parcel"],
    "fromNative": ["crate", "codecs", "from_parcel"]
  }
}
```

Both directions are required, and a binding cannot have both `codec` and
`constructors`. Hooks are ordinary application functions with no testing
dependency.

`toNative` receives a value of the generated LawSpec type and returns your
type; `fromNative` does the reverse. For each type parameter, a hook also
receives a converter function for that parameter, in the same direction. Use it
to convert the payload: the hook cannot convert payloads itself.

The generated bridge still validates every value against the LawSpec type, so a
hook cannot bypass range checks or constructor contracts. Errors from a hook
are reported with the type identity and the conversion direction.

### Hook signatures by target

| Target | `toNative` for `Parcel a` | Failure |
| --- | --- | --- |
| Rust | `fn to_parcel<T, N>(value: Parcel<T>, convert: &dyn Fn(T) -> N) -> lawspec_runtime::Result<domain::Parcel<N>>` | Return an error |
| Haskell | `toParcel :: Data.Parcel a -> (a -> b) -> Either String (Domain.Parcel b)` | Return `Left` |
| Python | `to_parcel(value, convert_item)`, receiving the generated class (for example `Parcel`) | Raise an exception |
| JavaScript, TypeScript | `to_parcel(value, convertItem)`, receiving the generated class | Throw |
| Java | `to_parcel(Parcel<A> value, Function<A, B> convert)` returning your `Parcel<B>` | Throw |
| Kotlin | `to_parcel(value: Parcel<A>, convert: (A) -> B): Parcel<B>` | Throw |
| Go | A function of the value and one converter per type parameter, returning `(value, error)` | Return an error |

`fromNative` has the mirror-image signature. In Haskell, Java, Kotlin and Go the
generated type's payloads are opaque checked values; only the supplied
converters can turn them into your payload type. Python, JavaScript and
TypeScript pass native payloads to the converters.

Go hooks that name generated types must live in the generated types' package.
Placing them in a package that imports the generated package would create an
import cycle, because the generated bridge imports the hooks.

## Use your own generators

A generator binding tells the generated tests to draw values of a type from a
factory you write, using your target's property-testing library:

```json
"generators": [
  {"type": "example.payments::type::Money", "factory": ["lawspec_generators", "prices"]}
]
```

The factory returns the framework's generator for the bound native type. A
factory for a type with parameters receives one generator per type argument.

| Target | Factory returns | Children | Location in the payment example |
| --- | --- | --- | --- |
| Rust | A Proptest strategy | One boxed strategy per type argument | `tests/support/lawspec_generators.rs` |
| Python | A Hypothesis `SearchStrategy` | One strategy per type argument | `tests/lawspec_generators.py` |
| JavaScript, TypeScript | A fast-check `Arbitrary` | One arbitrary per type argument | `test/lawspec_generators.mjs` |
| Java | A JetCheck `Generator` from a static method | One `Generator<T>` per type argument | `src/test/java/domain/PaymentGenerators.java` |
| Kotlin | A Kotest `Arb` | One `Arb<T>` per type argument | `src/test/kotlin/domain/PaymentGenerators.kt` |
| Go | A Rapid `*rapid.Generator` from a package-local function | One generator per type argument | `example/payments/native_generators_test.go` |
| Haskell | A Hedgehog `Gen` | One `Gen` per type argument | `test/PaymentGenerators.hs` |

Factories are test code: they belong in the test directory and are yours.

### What the tests do with your generator

- The tests compose and map your generator directly, so its shrinker is kept.
  Build factories with your framework's combinators to keep shrinking good.
- Every sample and every shrink candidate passes through the checked
  conversion. An invalid value fails the test with context; it is not
  silently discarded.
- Refinements on quantified inputs still filter your distribution.
- Explicit examples, boundary cases and finite-domain enumeration still run
  independently. A small finite domain is enumerated without calling your
  factory at all.
- If your generator cannot produce a valid value, the test fails. It never
  falls back to a built-in value, and never passes with no cases.

A factory may ignore a parameter whose type has no values, as in
`Phantom Empty`. Asking that parameter's generator for a value fails the test.

## Scaffold a factory

Set `"stub": true` to have LawSpec create the factory file for you:

```json
"generators": [
  {"type": "List", "factory": ["application_generators", "lists"], "stub": true}
]
```

The scaffold is user-owned. Its body fails until you implement it. Factories
that share a module share one file. Existing files are never overwritten; if
the required signature changes, `generate` reports it as an adapter update.
Changing the test layout creates a new scaffold at the new path and leaves the
old file in place: move your implementation across.

| Target | Reference | Creates | Initial body |
| --- | --- | --- | --- |
| Python | `["application_generators", "lists"]` | `tests/application_generators.py`, function `lists(argument_0)` | raises `NotImplementedError` |
| Rust | `["factories", "collections", "values"]` | `tests/support/factories.rs`, public module `collections`, function `values` returning `BoxedStrategy<Native>` | `unimplemented!` |
| JavaScript, TypeScript | `["factories", "collections", "lists"]` | `test/factories/collections.mjs` (or `.ts`) | throws |
| Java | `["application", "Factories", "prices"]` | `application/Factories.java` in the test directory; public static method | throws `UnsupportedOperationException` |
| Kotlin | `["application", "Factories", "prices"]` | `application/Factories.kt` in the test directory; function in object `Factories` | throws `NotImplementedError` |
| Go | a package-local name | `native_generators_test.go` beside each consuming unit's tests | panics |
| Haskell | `["Application", "Generators", "lists"]` | `Application/Generators.hs` in the test directory, for example `lists :: H.Gen a0 -> H.Gen [a0]` | calls `error` |

Target-specific rules:

- **Rust.** Type parameters have `Debug + 'static` bounds. `crate` and `self`
  prefixes refer to the integration-test support module. Explicit `crate` or
  `self` references keep importing the local module even with `stub: false`.
  The scaffold root cannot be the `rustCrate` name, a framework import or a
  generated support name.
- **Java and Kotlin.** The class or object must be in a named package, and must
  not collide with generated or application classes or with inherited
  `Object`/`Any` methods.
- **Go.** Imported factories are never scaffolded. A scaffolded factory needs a
  quantified use, which determines the package it belongs in.
- **Python and Haskell.** Use a dedicated test module. Names that collide with
  generated support, application modules or another scaffold are rejected.

Omitting `stub`, or setting it to `false`, only imports the factory.
