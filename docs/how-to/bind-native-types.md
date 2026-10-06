---
id: lawspec.how-to.bind-native-types
kind: how-to
title: Bind native types and functions
---
# Bind native types and functions

By default, LawSpec generates its own native types for your data declarations,
and you implement adapters against them. If your application already has its
own domain model, native bindings connect LawSpec's types and adapters to it
directly. The compiler then generates checked conversions between the two.

Bindings change only the native representation. Arithmetic, equality,
definitions and refinements keep their LawSpec meaning.

This guide covers type and function bindings. For conversion hooks and custom
generators, see [custom codecs and generators](custom-codecs-and-generators.md).
The implementation contract for each target is in the
[native bindings reference](../reference/native-bindings.md).

## Start from the bundled example

The quickest way to see bindings working is the payment project:

```sh
npx lawspec examples --example payments --target python
```

It exports an application with its own names for the specification's types
(`Price` for `Money`, `CurrencyCode.Dollars` for `Currency.USD`) and a
`lawspec.json` that binds them. See
[Generate example artifacts](generate-example-artifacts.md#export-the-runnable-payment-project).

## Add bindings to a target

Bindings belong to a target, under `nativeBindings`:

```json
{
  "version": 1,
  "sources": ["laws"],
  "targets": [
    {
      "language": "python",
      "root": ".",
      "nativeBindings": {
        "types": [],
        "functions": [],
        "generators": []
      }
    }
  ]
}
```

`nativeBindings` accepts `types`, `functions`, `generators`, `rustCrate` (Rust
only) and `goImports` (Go only). Unknown fields are errors, so a misspelled
option can never be silently ignored.

## Name LawSpec declarations

Bindings refer to LawSpec declarations by their resolved identities:

- a data type: `<unit>::type::<Name>`, for example `example.payments::type::Money`;
- an adapter: `<unit>::<name>`, for example `example.payments::addFee`;
- constructors and fields: by their names in the declaration.

## Name native symbols

A native reference is an array of identifier segments, never a code snippet.
What the segments mean depends on the target:

| Target | Reference | Example |
| --- | --- | --- |
| Rust | A path, starting with `crate` for the application library | `["crate", "domain", "Price"]` |
| Python | Module components, then the exported class or function | `["payments_domain", "Price"]` |
| JavaScript, TypeScript | Module path segments, then the exported name | `["payments_domain", "Price"]` |
| Java | A fully qualified type, constructor or static method name | `["domain", "PaymentsDomain", "Price"]` |
| Kotlin | A fully qualified class, object or function name | `["domain", "PaymentsDomain", "Price"]` |
| Go | One package-local identifier, or an import alias and an exported identifier | `["Price"]`, `["domain", "Price"]` |
| Haskell | Module components, then the type, constructor or function | `["PaymentsDomain", "Price"]` |

JavaScript and TypeScript source references resolve from the source directory,
and generator references from the test directory.

## Bind a type

Map the type, every constructor and every field:

```json
{
  "type": "example.payments::type::Money",
  "native": ["payments_domain", "Price"],
  "constructors": [
    {
      "constructor": "Money",
      "native": ["payments_domain", "Price"],
      "style": "record",
      "fields": [
        {"field": "amount", "native": "major"},
        {"field": "currency", "native": "unit"}
      ]
    }
  ]
}
```

Each constructor has a `style`:

- `record`: the type's only constructor, a product with fields;
- `variant`: one alternative of a sum, with its payload fields;
- `unit`: an alternative with no fields, such as an enum constant.

A sum maps each alternative:

```json
{
  "type": "example.payments::type::Payment",
  "native": ["payments_domain", "PaymentStatus"],
  "constructors": [
    {"constructor": "Paid", "native": ["payments_domain", "Settled"], "style": "variant",
     "fields": [{"field": "value", "native": "price"}]},
    {"constructor": "Declined", "native": ["payments_domain", "Rejected"], "style": "variant",
     "fields": [{"field": "reason", "native": "explanation"}]}
  ]
}
```

And an enumeration maps each constant with `unit`:

```json
{
  "type": "example.payments::type::Currency",
  "native": ["payments_domain", "CurrencyCode"],
  "constructors": [
    {"constructor": "USD", "native": ["payments_domain", "CurrencyCode", "Dollars"], "style": "unit"},
    {"constructor": "EUR", "native": ["payments_domain", "CurrencyCode", "Euros"], "style": "unit"},
    {"constructor": "GBP", "native": ["payments_domain", "CurrencyCode", "Pounds"], "style": "unit"}
  ]
}
```

### How each target builds and reads values

The generated bridge constructs and inspects your types with the target's
ordinary conventions:

| Target | Constructing | Reading fields |
| --- | --- | --- |
| Python | Keyword arguments, so keyword-only dataclasses and reordered fields work. Classes are checked by exact identity. | Attributes |
| JavaScript, TypeScript | One object whose keys are the mapped field names; unit classes take no arguments. | Own properties |
| Java | Constructor arguments in LawSpec field order. `unit` refers to an enum constant. An empty record uses `record` or `variant`. | Accessor methods |
| Kotlin | Constructor arguments in LawSpec field order. `unit` refers to an enum constant or singleton object, compared by identity. | Properties |
| Go | Keyed struct literals; mapped fields must be exported. `unit` refers to a constant. | Fields |
| Haskell | Record construction and matching by field name, independent of declaration order. | Record selectors |
| Rust | Struct and enum-variant literals with named fields; `unit` refers to a unit variant. Recursive fields need the same indirection as the generated type. | Fields |

When your type does not fit these conventions, for example because it has
private storage, a different recursive layout or a smart constructor, use a
[codec hook](custom-codecs-and-generators.md#convert-with-codec-hooks) instead.

Bindings compose through type parameters, recursion, `List`, `Maybe`,
`Either`, `Nullable` and `Optional`. Types you do not bind keep their generated
representation.

## Bind an adapter to an existing function

```json
"functions": [
  {"declaration": "example.payments::addFee", "native": ["payments_domain", "apply_fee"]},
  {"declaration": "example.payments::roundTrip", "native": ["payments_domain", "restore"]},
  {"declaration": "example.payments::archive", "native": ["payments_domain", "store"]}
]
```

A unit with function bindings must currently map every adapter it declares.
Its adapter file becomes a compiler-generated bridge: it validates the inputs,
converts them, calls your function, converts the result and validates it.

## Rust: name the application crate

Rust tests must use your library's own types, not a second compiled copy.
Name the library crate with `rustCrate`:

```json
"nativeBindings": {"rustCrate": "lawspec_example", "types": [], "functions": []}
```

## Go: bind types from other packages

Declare import paths separately, then refer to their exported names through the
alias:

```json
{
  "goImports": [{"alias": "domain", "path": "example.org/application/domain"}],
  "functions": [{"declaration": "example::echo", "native": ["domain", "Echo"]}]
}
```

One alias can qualify types, constructors, functions and generator factories.
Each generated file imports only what it uses. The compiler renames aliases
internally, so an alias such as `rapid` cannot shadow a framework import.
Duplicate aliases or paths, traversal segments and undeclared aliases are
errors.

If a generated type would have the same name as one of your package's types,
the compiler gives the generated one a `Canonical` prefix (`CanonicalBox`, or
`Canonical1Box` if that is also taken). LawSpec identities do not change.

## Check the bindings

```sh
npx lawspec check
npx lawspec generate --dry-run
```

`check` resolves every binding against the typed declarations and reports
unknown types, constructors or fields, duplicate or incomplete mappings,
incompatible type arities and malformed references. `generate` additionally
checks that the target supports what you asked for.

`lawspec evidence` lists each type binding as `RUNTIME CHECKED`, because values
cross it through checked conversions, and each native function as
`ASSUMED / EXTERNAL`.

## Adopt bindings in an existing project

When a unit gains function bindings, its adapter file becomes a generated
bridge. LawSpec refuses to overwrite your existing adapter, even if it is still
the untouched stub. To adopt bindings:

1. Move the implementation into the application module the bindings name.
2. Move the old adapter file out of the way, outside the bridge's path.
3. Run `lawspec generate`.

Do not edit `.lawspec/generated.json` to make your code look generated.

If you later remove the bindings, LawSpec keeps the former bridge as a
user-owned adapter and reports the adapter signature you now need to
implement. Review it and implement the adapter before running the tests.

Changing `sourceDir` or `testDir` moves generated files. Your application
models, hooks and factories stay where they are.

See [ownership and regeneration](../explanation/ownership-and-regeneration.md).
