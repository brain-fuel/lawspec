# Native domain bindings: 0.10 acceptance scope

Status: implementation and acceptance complete. The payment example now executes with
compiler-generated Rust bridges and application-library linkage. Rust supports
generic products/sums, regular recursive mappings, nested built-in containers,
and native Proptest factories that compose child strategies and retain shrinking.
Python now has checked application-class bridges with renamed fields, shared
schema validation and native Hypothesis factories. JavaScript and TypeScript
have application-class bridges and native fast-check factories.
Java now emits typed codecs for application records, sum variants and enum
constants, with native JetCheck factories. Kotlin has checked application-class
bridges and native Kotest factories. Go has checked application bridges and native Rapid factories in local or
explicitly imported packages. Haskell has application-owned types and native
Hedgehog factories. All eight targets now have custom codec-hook implementations. Full release acceptance remains incomplete. Unsupported
emission requests fail explicitly.

## Audit of 0.9

The checked-in compiler, generated API, and WASM fingerprints agree
(`stack run lawspec-dev -- integrity`). The audit inspected the following boundaries:

| Boundary | Existing machinery | Missing for 0.10 |
| --- | --- | --- |
| Public request and CLI | Schema v3 requests pass sources, target, layout, machine profile, generation limits and formatting through `Api.hs` and `npm/bin/lawspec.mjs`. | Per-target external type and generator bindings, validation, public declarations and config forwarding. |
| Typed front end | Resolved declaration IDs, parameterized data declarations, constructor fields, contracts and total definitions. | Binding resolution against those identities; native names must not enter language inference or change equality. |
| Testing plan | `Testing.hs` plans finite domains, deterministic boundaries, examples and framework generation requirements. | Explicit generator selection while retaining independent examples and boundary coverage. |
| Rust | `RustData.hs` generates enums plus `IntoValue`/`FromValue`; `RustEmit.hs` checks schema values around adapter calls. | Application-owned struct/enum representations and framework strategy bindings. |
| Java | `JavaData.hs` generates domain types; `LawSpecSchema.java` exposes typed `Codec<T>` conversions with validation. | External constructors/accessors, native type selection and JetCheck generator selection. |
| Python | `PythonData.hs` generates dataclasses; `lawspec_schema.py` associates constructor metadata with native classes. | Explicit native imports and renamed fields/factories; Hypothesis strategy selection. |
| JavaScript/TypeScript | `WebData.hs` and `WebTypes.hs` generate classes and native signatures; `lawspec_schema.mjs` validates constructor identities and fields. | External classes/representations and fast-check arbitrary selection without losing shrinking. |
| Go | `GoData.hs` generates types and codecs; `lawspec_codecs.go` supplies typed checked conversions and contextual errors. | Application types, explicit field mappings and Rapid generator selection. |
| Haskell | `HaskellData.hs` generates ADTs; `LawSpecCodecs.hs` supplies compositional typed codecs. | Application modules/constructors/selectors and Hedgehog generator selection. |
| Kotlin | `KotlinData.hs` generates classes with checked schema bridges and native Kotest properties. | External classes/accessors and Kotest arbitrary selection. |
| File ownership | Source/test placement is separate from generated/user ownership; `npm/files.mjs` protects edited artifacts and reports adapter changes. | Apply these protections to binding support and generator stubs, including migration from existing adapters. |

The word “native” in 0.9 means target-language representations of LawSpec types.
It does not mean an application can configure its own pre-existing domain model.
Users can hand-write conversions in their adapters today, but the compiler does
not select or generate those conversions. Likewise, using native property
frameworks today does not provide a user-configurable generator binding.

The Rust test emitter currently includes generated source/runtime modules by
path. External-library bindings must use the application library's type identity
in tests; compiling a second copy of a runtime-backed `Decimal` creates a
different Rust type. The manual baseline recompiles the domain alongside the
fixture and therefore does not yet prove external-library linkage.

The first implementation component, `LawSpec.NativeBinding`, resolves structured
native references and complete constructor/field mappings against Core. It
normalizes fields to declaration order and resolves generic generator arities.
`NativeBindingSpec` tests its validation. Public request parsing, CLI target
forwarding, generated TypeScript declarations and initial Rust emission are
implemented. Unknown binding fields are rejected. Binding requests require
schema version 4 so older schema-3 compilers reject them rather than ignoring
native representation choices. Existing requests without bindings retain
schema-3 compatibility.

## Acceptance domain

[`payments.lawspec`](examples/specs/payments.lawspec) defines `Currency`, `Money`
and `Payment`, with adapters for fee calculation, payment round trips and archives
of optional payments. It fixes the following observable behavior:

- Adding a fee of exactly 0.2 preserves currency and arbitrary decimal precision.
- Successful and declined payments retain their variant and payload.
- Archives retain order, duplicates, empty lists and the difference between a
  missing payment and a present declined payment.

The application model deliberately uses different names:

| LawSpec | Application model |
| --- | --- |
| `Currency.USD`, `.EUR`, `.GBP` | `CurrencyCode.Dollars`, `.Euros`, `.Pounds` |
| `Money` / constructor `Money` | `Price` product |
| `amount`, `currency` | `major`, `unit` |
| `Payment.Paid.value` | `PaymentStatus.Settled.price` |
| `Payment.Declined.reason` | `PaymentStatus.Rejected.explanation` |
| `addFee`, `roundTrip`, `archive` | `apply_fee`, `restore`, `store` |

The Rust application fixture is
[`domain.rs`](test/fixtures/native-payments/domain.rs). It does not import the
generated domain types. It uses LawSpec's framework-independent exact Decimal
runtime. Its hand-written adapter records the conversion work 0.10 must remove;
merely bundling that adapter does not satisfy native binding support.

Run the baseline with:

```sh
node tools/native-payments-integration.mjs
```

This checks/generates the model through the packaged WASM on all eight targets,
executes generated Rust properties/examples/boundaries against application types,
and confirms three deliberately broken applications fail laws rather than fail
compilation. The three mutations change the fee, erase currency and erase missing
payments. Logs and generated projects are in `.artifacts/native-payments/`.
Generation on a target is not evidence of execution on that target.

## Current generated Rust path

`test/fixtures/native-payments/bindings.json` is the concrete configuration.
Pass it as `nativeBindings` in a schema-4 `planGeneration` request, or set
`nativeBindings` on a Rust target in `lawspec.json`. The JavaScript API selects
schema 4 automatically when that option is supplied. `check` validates binding
identities; `planGeneration` additionally checks target support.

Native references are arrays of identifier components, never code snippets.
`types` maps qualified type identities, all their constructors and all fields.
`functions` maps qualified adapter identities to application functions.
`rustCrate` names the application library for test linkage. A bound unit must
currently map every adapter; its generated bridge is compiler-owned. Existing
user adapters are protected by the ownership manifest and cannot be overwritten
silently when adopting bindings.

```sh
LAWSPEC_CORE=/absolute/path/to/lawspec-core node tools/native-bound-payments.mjs
```

Unlike the manual baseline, this generates every conversion from configuration,
links generated tests to the application library's runtime/data/adapter modules,
and executes both 32-bit and 64-bit semantic profiles, including a custom layout.
Total-definition bodies are compiled in the test crate against those shared
runtime types because their evaluators are crate-private. The three negative
adapters must fail executable laws. Output is in `.artifacts/native-bound-payments/`.
Generator-only native machine-sized boundaries are additionally checked by
`tools/rust-native-shapes.mjs`: the host-width profile passes and the other
profile fails contextually with an architecture mismatch.

### Rust custom generators

Add a generator binding such as:

```json
{"type":"example.payments::type::Money","factory":["lawspec_generators","prices"]}
```

The application supplies `prices()` in `<testDir>/support/lawspec_generators.rs`,
returning a Proptest strategy whose values have the mapped application type.
Factories for parameterized types receive one boxed native strategy per type
argument. Generated conversions map these strategies directly, preserving their
value trees and shrinkers. Native samples and shrinks must satisfy the schema;
invalid values fail contextually. Exhausted custom strategies cannot fall back
to deterministic witnesses. Explicit examples, boundaries and finite-domain
enumeration still run independently of the custom distribution.

```sh
LAWSPEC_CORE=/absolute/path/to/lawspec-core LAWSPEC_NATIVE_GENERATORS=1 node tools/native-bound-payments.mjs
LAWSPEC_CORE=/absolute/path/to/lawspec-core LAWSPEC_NATIVE_GENERATORS=1 node tools/rust-native-shapes.mjs
```

The payment strategy deliberately omits several explicit examples and shrinks
to EUR 1. The shapes fixture checks generic child shrinking, recursive mappings,
empty records, refined quantifiers and finite singleton enumeration in readable
and compact output. Direct mappings currently require recursive indirection
compatible with the generated representation; alternate storage and phantom
representations still need codec-hook support.

## Custom codec hooks

A named type can select a pair of conversion hooks instead of constructor/field
mappings. Hooks are structured function references, not embedded source code:

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

Both directions are required. Supplying constructor mappings as well is an error.
The canonical side uses generated LawSpec data types; the native side uses the
application type. For each type parameter, the hook receives a child conversion
function in that direction. Rust hooks return `lawspec_runtime::Result<T>`.
For example, `to_parcel<T, N>` takes a canonical `Parcel<T>` and `&dyn Fn(T) -> N`,
and returns `Result<domain::Parcel<N>>`. The reverse receives the native value
and `&dyn Fn(N) -> T`. Returned errors include the type identity and direction.

Hooks are application-owned source functions with no testing dependency. Schema
validation still surrounds adapter calls and native generator values; hooks cannot
remove range checks or constructor contracts. The compiler continues to select
native generators independently, preserving their shrink trees through conversions.

`test/fixtures/native-codecs` demonstrates a private-field generic product and a
recursive chain represented by a flat vector plus an explicit termination flag.
It preserves the distinction between an absent tail and a tail containing Stop.
Both profiles and output formats are compiled and executed with native/WASM
parity. Tests verify generic Proptest shrinking through the hooks, contextual
errors from either direction, and rejection of invalid codec results and native
generator samples. The source library is checked separately from test code.

```sh
LAWSPEC_CORE=/absolute/path/to/lawspec-core node tools/rust-native-codecs.mjs
```

Haskell hooks return `Either String value`. A generic hook has the shape:

```haskell
toParcel :: Data.Parcel a -> (a -> b) -> Either String (Domain.Parcel b)
fromParcel :: Domain.Parcel b -> (b -> a) -> Either String (Data.Parcel a)
```

The generated bridge keeps logical type-parameter payloads opaque and supplies
checked child converters. Hooks must use those converters to cross between the
logical payload and the application's native payload. The enclosing codec retains
schema validation and the example's Symbol context. Hook errors identify the type
and conversion direction.

`bindings-haskell.json` and the Haskell modules in `test/fixtures/native-codecs`
exercise private products, a flattened recursive representation, nested generic
payloads and refined fields. The integration checks source compilation with test
packages hidden, both machine profiles, both output formats, custom layouts and
native/WASM parity. A failing generic property retains Hedgehog shrinking to a
payload of 61. Invalid hook results and native generator samples fail contextually.

```sh
LAWSPEC_CORE=/absolute/path/to/lawspec-core LAWSPEC_GHC=/absolute/path/to/ghc node tools/haskell-native-codecs.mjs
```

Python hooks return the converted value and raise an exception on failure. For
example, `to_parcel(value, convert_item)` receives a generated canonical
`ParcelParcel` and returns the application's `Parcel`; `from_parcel` reverses
that conversion. Generic hooks use each directional child converter when moving
payloads between canonical and native representations. Unlike Haskell's opaque
payload bridge, Python supplies canonical native payloads to these converters.

The Python bridge checks the declared native class, validates canonical results,
and wraps hook exceptions with the type identity and direction. Hooks compose
with direct field mappings, preserve the shared Symbol context and do not import
Hypothesis. The `codec_domain.py`, `codec_hooks.py` and `codec_generators.py`
fixtures exercise private storage, flattened recursion and nested generic values.
The integration checks source execution with site packages disabled, native/WASM
parity, all profile/format combinations, custom layouts and Hypothesis shrinking
to 61. Faulty hooks, invalid generator samples and collapsed chain endings fail
executable tests.

```sh
LAWSPEC_CORE=/absolute/path/to/lawspec-core node tools/python-native-codecs.mjs
```

JavaScript and TypeScript use the same canonical-value and child-converter
interface as Python. Hooks return values or throw exceptions. The bridge checks
the declared application class, validates canonical results, and attaches type
identity and direction to errors while retaining the original cause. Hook tables
are copied when binding a schema, so later configuration mutations cannot change
its conversions.

The TypeScript fixtures use ECMAScript private fields and typed generic hook
signatures. They also transpile to JavaScript for the same executable acceptance
cases. Source code compiles independently of testing types. Both web targets
execute the private product, flattened chain and refined Positive examples under
both profiles, formats and custom layouts, with native/WASM parity. fast-check
retains child shrinking to 61. Tests reject failures in either hook direction,
invalid canonical results, invalid native generator values and collapsed endings.

```sh
LAWSPEC_CORE=/absolute/path/to/lawspec-core node tools/web-native-codecs.mjs
```

Java hooks use typed `java.util.function.Function` child converters. For example,
`to_parcel(Parcel<A> value, Function<A, B> convert)` returns an application-owned
`CodecDomain.Parcel<B>`. The generated bridge instantiates canonical generic
payloads as checked `LawSpecRuntime.Value` values, supplies the native child codec
methods, and validates the result against the schema. Hooks throw exceptions on
failure; the bridge adds the type identity and conversion direction while retaining
the cause. No testing library is needed by the hooks or generated source codecs.

The Java fixtures use private fields and a flattened recursive representation.
The integration compiles source independently, executes nested codec conversions,
and checks both profiles, formats and custom layouts with native/WASM parity.
The emitted JetCheck factory demonstrably shrinks generic payloads and matches
an independent run of the application generator (98 to 49 for the chosen predicate
and seed). JetCheck does not guarantee the smallest mathematical counterexample.
Incorrect hooks, invalid refined outputs, invalid generator samples and collapsed
chain endings fail executable properties/examples after successful compilation.

```sh
LAWSPEC_CORE=/absolute/path/to/lawspec-core node tools/java-native-codecs.mjs
```

Kotlin hooks follow the same opaque canonical-payload convention as Java, using
ordinary Kotlin function parameters. For example,
`to_parcel(value: Parcel<A>, convert: (A) -> B): CodecDomain.Parcel<B>` returns the
application type. The reverse hook receives `(B) -> A`. Both directions retain
schema validation, Symbol context, generic child codecs and contextual exceptions.
The conversion source compiles and executes without Kotest dependencies.

Kotlin's private-storage product, flattened chain, refined value and native
factories execute under both profiles, formats and custom layouts, with native/WASM
parity. The emitted generic Kotest factory retains its shrink tree (66 to 1 in the
fixture). Incorrect hooks, collapsed endings, invalid results and invalid native
samples compile before failing tests.

```sh
LAWSPEC_CORE=/absolute/path/to/lawspec-core node tools/kotlin-native-codecs.mjs
```

Go hooks return `(value, error)`, with generic converters represented by ordinary
function parameters. The canonical type parameters carry checked `LawSpecValue`
payloads. The bridge preserves the active Symbol context and encoder traversal
path when invoking child conversions, and wraps returned errors or panics with the
type identity and direction. Framework-independent source compiles with `go build`.

The Go fixture defines hooks in the generated canonical type's package. This lets
hooks name canonical variants without creating an import cycle. Its application
model uses private pointer-backed product storage and a flat slice representation
of the recursive chain. Both profiles, formats and custom layouts execute with
native/WASM parity. An intentionally failing property proves that the emitted
Rapid factory still shrinks its payload to 61. Faulty conversions, collapsed
endings and invalid refined results/generator values fail executable tests.

```sh
LAWSPEC_CORE=/absolute/path/to/lawspec-core node tools/go-native-codecs.mjs
```

The imported-model fixture in `test/fixtures/native-go-codecs` additionally places
the private application model and Rapid factories in separate packages. Local hooks
call the model's public constructors and accessors, so the application package has
no dependency on generated types. Generated codecs import only the application
model; factories remain a test dependency. This path compiles source independently
and executes the same profile/format/layout, shrinking and negative-test matrix.

```sh
LAWSPEC_CORE=/absolute/path/to/lawspec-core node tools/go-imported-codecs.mjs
```

All eight targets now implement codec hooks. Hooks that name generated canonical
types belong beside those types: placing them in a package that imports the
canonical package while the generated bridge imports that hook package would
create an ordinary Go import cycle.

## Implementation contract

### Current Python path

`test/fixtures/native-payments/bindings-python.json` maps the same payment domain
to application classes in `domain.py`. Python native references contain module
components followed by an exported class or function name. A bound unit must
map every adapter. Classes are checked by exact constructor identity; fields
are read by mapped attribute name and constructed with keyword arguments, so
keyword-only dataclasses and reordered fields work. Generic and recursive schema
traversal retains constructor predicates and canonical diagnostic field names.

`lawspec_native.py` and bound adapters are generated source files. Runtime schema
rebinding is independent of Hypothesis. Native function failures and invalid
results receive adapter context. Python integers have no architecture-sized
representation, so the semantic machine-width profile is enforced by validation.

```sh
LAWSPEC_CORE=/absolute/path/to/lawspec-core node tools/python-native-payments.mjs
```

This fixture covers both semantic profiles, both layouts, custom source/test
directories, keyword-only fields, and incorrect fee/currency/absence adapters.
Schema tests cover recursive generic mappings, Symbol identity, invalid mappings
and retained constructor predicates.

Python generator bindings reference factories in importable test modules. Each
factory receives one native Hypothesis strategy per type parameter and returns
a strategy producing the application representation. The generated test helper
maps native values through the checked schema, retaining Hypothesis shrinking.
Invalid samples and shrinks fail contextually instead of being filtered. An
exhausted custom strategy cannot fall back to a deterministic witness.

```sh
LAWSPEC_CORE=/absolute/path/to/lawspec-core LAWSPEC_NATIVE_GENERATORS=1 node tools/python-native-payments.mjs
```

This mode checks the emitted Money factory's shrinking, a refined scalar's use
of its custom factory, and exhaustive Unit enumeration without factory sampling.
Runtime checks cover generic child strategies and nested custom scalars. Factory
modules remain application-owned. Their regeneration protection is covered by the
all-target ownership matrix below. Optional Python generator stubs are described
below; all eight targets support scaffolds.

### Current JavaScript and TypeScript path

`bindings-web.json` maps the payment model to the application classes in
`domain.ts`. References use module path segments followed by an exported name;
source references resolve from the source root, and generator references from
the test root. The emitter selects `.mjs` for JavaScript and `.js` imports for
TypeScript. Payload classes receive one object whose keys are mapped native
field names; unit classes receive no arguments. Classes must expose mapped
fields as own properties. Alternate constructor conventions need codec hooks.

Generated bridges retain canonical typed adapter signatures and convert through
an application schema. Generic and recursive traversal preserves class identity,
Symbol identity, constructor predicates, and tagged absence states. The emitted
native-generator helper composes fast-check arbitraries, maps their values through
checked conversions, and keeps their shrink contexts. Invalid samples/shrinks
fail contextually; exhausted custom generators cannot use witness fallback.

```sh
LAWSPEC_CORE=/absolute/path/to/lawspec-core LAWSPEC_NATIVE_GENERATORS=1 node tools/web-native-payments.mjs
```

The integration compiles TypeScript, executes both targets in readable/compact
mode at both machine profiles with custom layouts, and rejects incorrect fee,
currency and absence handling. Runtime checks also exercise generic native child
arbitraries and deliberately invalid shrink values. Full release acceptance,
including broader generator/refinement coverage, remains pending.

### Current Java path

`bindings-java.json` maps the payment types to records, sealed variants and enum
constants nested in the application-owned `PaymentsDomain` class. Java references
are fully qualified type, constructor or static method names. Mapped payload
fields use accessor methods; constructors receive fields in LawSpec declaration
order. `unit` mappings refer to enum constants. An empty application record uses
`record` or `variant` style instead. Alternate conventions need codec hooks.

`LawSpecNativeCodecs` composes typed codecs over the shared schema. Application
types stay separate from generated canonical declarations, while validation,
constructor predicates and Symbol contexts are shared. Generic recursive codecs
are constructed lazily during traversal. Bound units map every adapter; generated
bridges are source-owned and retain canonical typed signatures.

```sh
LAWSPEC_CORE=/absolute/path/to/lawspec-core node tools/java-native-payments.mjs
```

The fixture executes the payment laws and recursive generic shape laws under
both profiles and formatting modes, with custom directories and three incorrect
payment adapters. Native generator factories can be selected with `generators`
entries referencing static methods. Generic factories receive a typed JetCheck
generator for each type argument; the compiler specializes reachable concrete
types and composes checked application codecs around those strategies.

The JetCheck runtime now provides native factory hooks and checked strategy
mapping. `tools/java-native-generator-runtime.mjs` checks generic child
composition, actual shrinking, invalid sample/shrink replay failures, exhaustion
without witness fallback, and the existing constructor-contract behavior at both
machine profiles. The generated path is exercised with:

```sh
LAWSPEC_CORE=/absolute/path/to/lawspec-core LAWSPEC_NATIVE_GENERATORS=1 node tools/java-native-payments.mjs
```

This adds Money and generic Box factories, a refined Int8 factory and a finite
Seal factory that fails if sampled. The tests check emitted Money shrinking,
refined-input factory use and finite enumeration. Native conversion failures
are carried through composed draws to property callbacks, including during
shrink replay. Runtime control exceptions remain under JetCheck's control.
Generator source is application-owned and stays in test directories; generated
source codecs do not depend on JetCheck. Formatting and wider release acceptance
remain pending.

### Current Kotlin path

`bindings-kotlin.json` maps the payment model to application-owned Kotlin classes
in `PaymentsDomain.kt`. Payload mappings read properties and call constructors
in LawSpec field order. Unit mappings reference enum constants or singleton
objects and compare identity. Payload constructors are checked by exact runtime
class. Generic and recursive codecs compose through the same shared schema used
by canonical Kotlin data, retaining contracts and logical diagnostic field names.

`LawSpecNativeCodecs.kt` and bound canonical adapters are generated source files;
neither requires Kotest. A bound unit currently maps every adapter. Alternate
construction conventions still need codec hooks.

Kotlin generator bindings select application-owned factory functions returning
Kotest `Arb` values. Generic factories receive one typed native arbitrary per type
argument. Generated helpers compose checked codecs around those arbitraries,
retaining their shrink trees. Invalid samples and shrink candidates reach the
property callback as contextual failures; custom strategies cannot fall back to
witnesses when exhausted. Refinements filter the configured distribution while
explicit examples, boundaries and finite-domain enumeration remain independent.

```sh
LAWSPEC_CORE=/absolute/path/to/lawspec-core LAWSPEC_NATIVE_GENERATORS=1 node tools/kotlin-native-payments.mjs
node tools/kotlin-native-generator-runtime.mjs
```

The generated checks exercise generic factories, Money shrinking, refined scalar
factory use, finite singleton enumeration without invoking its factory, and an
invalid Text factory whose surrogate value must fail in the generated property.
Runtime checks additionally exercise invalid native shrink candidates reaching
Kotest callbacks and exhausted custom strategies with available witnesses.

```sh
LAWSPEC_CORE=/absolute/path/to/lawspec-core node tools/kotlin-native-payments.mjs
```

The integration executes payment and recursive generic shape laws, examples and
boundaries under both machine profiles and formatting modes, including custom
source/test directories. It compares native/WASM emission and checks that
incorrect fee, currency and absence adapters fail executable laws.
`tools/kotlin-native-source.mjs` additionally compiles only generated source,
application types and codec checks without Kotest dependencies. It executes exact
decimal, raw code-point/UTF-16/byte, Symbol identity, nested absence and unmapped
variant checks under both machine profiles.

### Current Go path

`bindings-go.json` maps the payment and recursive shape domains to application
structs, interfaces and enum constants in their existing generated-test packages.
References contain either one package-local identifier or a declared import alias
and an exported identifier. Payload fields use
explicit native names and keyed struct construction; unit mappings name enum
constants. Application functions can retain names such as `AddFee`: checked Core
calls are lowered to separate generated bridge names, including contract calls.

`lawspec_native_codecs.go` contains framework-independent checked conversions.
Only reachable native codecs are emitted per package. The bridge preserves exact
scalar values, generic child codecs, recursion and schema field diagnostics.
Application symbols are reserved before Go emission. If a canonical type or variant
would collide, the compiler gives that generated family a fresh `Canonical`-prefixed
name. Existing names are considered too: an application `Box` and an existing
canonical `CanonicalBox` produce `Canonical1Box` for the conflicting generated
family. Qualified logical identities, schema values and propositions remain
unchanged. Codec hooks support alternate pointer/storage conventions.

```sh
LAWSPEC_CORE=/absolute/path/to/lawspec-core node tools/go-native-payments.mjs
```

The integration builds source packages and executes laws/examples/boundaries for
payments, recursive generic shapes and scalar/absence adapters under both machine
profiles and output formats, with custom directories. It compares native/WASM output and checks Go formatting, raw UTF-16/bytes, Symbol
identity, invalid Text context, constructor contracts with a shared Symbol context,
and bound adapter postconditions. Three incorrect payment adapters must fail
executable laws.

Go generator bindings name package-local factories returning Rapid generators.
Generic factories receive a native generator per type argument. The generated
`lawspec_native_generators_test.go` composes these with checked codecs, preserving
Rapid's draw/replay stream and shrinking. Native validation failures use a distinct
panic type so they reach properties without swallowing Rapid's discard control.
Custom factories bypass witness fallback and constructor rejection; their invalid
values and shrink candidates are failures. Refinements still filter the custom
distribution, and finite domains are enumerated without invoking factories.

```sh
LAWSPEC_CORE=/absolute/path/to/lawspec-core LAWSPEC_NATIVE_GENERATORS=1 node tools/go-native-payments.mjs
node tools/go-native-generator-runtime.mjs
```

These checks cover typed generic composition, emitted Money shrinking to 1.61,
refined scalar factory use, finite singleton handling, invalid Text samples and
exhausted refined distributions. Runtime tests also demonstrate invalid native
shrink candidates reaching property callbacks, invalid constructor contracts and
exhaustion despite an available witness. Factory files are application-owned test
code. Regeneration protection and optional Go generator stubs are covered below.

### Go external packages

Declare package paths separately from structured native references:

```json
{
  "goImports": [{"alias": "domain", "path": "example.org/application/domain"}],
  "functions": [{"declaration": "example::echo", "native": ["domain", "Echo"]}]
}
```

The same alias can qualify native types, constructors and generator factories.
External names and mapped fields must be exported. Aliases are resolved to
compiler-owned import names, so configuration aliases such as `schema` and `rapid`
cannot shadow generated locals or framework imports. Each artifact imports only
its dependencies; an unused configured import does not create a package dependency.
Duplicate aliases/paths, traversal paths and undeclared aliases fail planning.
`goImports` is rejected for other targets.

`test/fixtures/native-go-external` supplies application-owned generic products,
recursive sums, enums and Rapid factories in separate Go packages. The fixture
executes checked bridges under both profiles and custom layouts, including a
UInt64 maximum example. Generated source builds independently of the generator
package, and a broken application must compile before failing its laws. A separate
failing property verifies that the imported generic factory retains native Rapid
shrinking down to a Box payload of 61. Native and WASM emission are compared.

```sh
LAWSPEC_CORE=/absolute/path/to/lawspec-core node tools/go-native-external.mjs
```

Direct mappings require compatible field representations. Application packages
with their own wrappers or alternate recursive storage can use the codec hooks
described above. Canonical name reservation applies consistently to generated data,
codecs, adapter bridges, native factories, definitions and tests in both output
formats. Imported names do not occupy the local application namespace.

`test/fixtures/native-go-names` exercises colliding generic products and recursive
sums, an occupied canonical prefix, native generator selection and a broken adapter
that compiles before failing its laws. The hook fixture can also run with a native
`Parcel` name, verifying that user hooks and generated codecs agree on the renamed
canonical family.

```sh
LAWSPEC_CORE=/absolute/path/to/lawspec-core node tools/go-native-names.mjs
LAWSPEC_CORE=/absolute/path/to/lawspec-core LAWSPEC_GO_COLLISIONS=1 node tools/go-native-codecs.mjs
```

### Current Haskell path

`bindings-haskell.json` maps the payment domain to application-owned types in
`PaymentsDomain.hs`. Generated codecs construct and match records by their mapped
field names, independently of native declaration order. Canonical adapter bridges
validate both directions and carry each example's Symbol context into codecs.
Unit-returning application calls are forced before encoding their result. Application
imports receive distinct aliases, including modules named `P`, `Data` or `Codec`;
references that shadow generated module files are rejected during planning.

```sh
LAWSPEC_CORE=/absolute/path/to/lawspec-core LAWSPEC_GHC=/absolute/path/to/ghc node tools/haskell-native-payments.mjs
```

Set `LAWSPEC_GHC_PACKAGE_DB` when Hspec/Hedgehog live in a separate package database.
The integration executes payments under both machine profiles, readable and compact
output, and custom directories, with native/WASM emission parity. Bound adapter
postconditions are executed. Incorrect fee, currency and absence implementations,
and a throwing Unit adapter, must compile and then fail executable laws. The same matrix includes generic records, recursive sums, nested instances and
finite singleton types from `native_shapes.lawspec`.

Haskell factories return native Hedgehog `Gen` values and receive a native child
generator per type parameter. Generated codecs map those trees without replacing
their shrinking. Custom factories bypass witness fallback and constructor
rejection; invalid native values are contextual failures. Finite domains are
still enumerated without invoking their factories. Framework helpers remain in
test directories, and source compilation is checked with testing packages hidden.

```sh
LAWSPEC_CORE=/absolute/path/to/lawspec-core LAWSPEC_GHC=/absolute/path/to/ghc LAWSPEC_NATIVE_GENERATORS=1 node tools/haskell-native-payments.mjs
node tools/haskell-native-generator-runtime.mjs
```

The emitted factories retain Money shrinking to 1.61 and generic Box shrinking
to 13. Invalid Decimal samples fail emitted properties, and a custom Int8
distribution containing only zero exhausts the refined input instead of using a
witness. The runtime checks also cover invalid shrink candidates and empty factories.
Source-only execution additionally checks raw code points, UTF-16 units, bytes,
supplementary characters, nested absence states, scoped Symbol constructor contracts,
and native architecture mismatch diagnostics. Regeneration protection is covered below; generator stubs remain unfinished.

### Shared requirements

1. **Resolve bindings once.** Add per-target configuration/API bindings keyed by
   qualified LawSpec declaration identity. Resolve and validate them against
   typed Core before emission. Reject unknown types, constructors or fields,
   duplicate/incomplete mappings, incompatible type arities, malformed target
   references and unsupported representations with contextual diagnostics.
   Ordinary specifications retain their meaning and default generated types.
2. **Generate checked native bridges.** Support application-owned products and
   sums with explicit constructor/field mappings and callable codec hooks for
   representations that cannot be expressed as direct mappings. Compose through
   type parameters, recursion, `List`, `Maybe`, `Either`, `Nullable` and `Optional`.
   Preserve exact values, Symbol identity, distinct absence states, constructor
   contracts and both machine profiles. Validate adapter inputs and outputs;
   invalid native values fail rather than becoming rejected generator samples.
3. **Connect native generators.** Bind factories returning the target framework's
   generator/strategy/arbitrary. Compose and map those objects directly; do not
   sample them into a separate random-value generator or replace their shrinkers.
   Factories for parameterized types receive generators for their type arguments.
   Validate generated values, including shrinks, through the same bridge. Retain
   refinement predicates and their existing failure-versus-rejection distinction.
   Custom random distributions never remove explicit examples, deterministic
   boundaries or exhaustive finite-domain cases.
4. **Keep target details out of propositions.** Binding resolution produces a
   backend binding plan alongside the existing typed testing plan. Arithmetic,
   equality, total definitions and refinements continue to use checked Core
   semantics. Schema/codec source remains independent of test frameworks.
5. **Preserve application ownership.** Import existing application code; never
   rewrite it. Generate bridge source and framework-specific test helpers in
   their respective directories. Keep optional implementation/generator stubs
   user-owned. Support custom layouts, regeneration and adapter-update reporting.
6. **Ship one coherent interface.** Update the public API declarations and their
   generator, CLI config validation, diagnostics, documentation and examples
   together. Decide schema versioning from the actual wire changes; do not
   silently accept and ignore requested binding configuration.

## Ownership, regeneration and migration

Generated bridges and numeric/schema runtimes belong in source directories.
Framework helpers belong in test directories (Go test files share their package's
source directory). Application models, conversion hooks and generator factories
remain application-owned. The ownership manifest records generated-file hashes;
it does not take ownership of existing application files.

When adopting bindings, an existing user-owned adapter at the new bridge's path
blocks generation, even if it still contains an untouched scaffold. Move the
implementation into the configured application module and save the old adapter
outside the generated bridge path before regenerating. Do not edit the manifest
to make application code appear compiler-owned. The compiler can then create its
bridge without overwriting the saved adapter.

Removing bindings preserves the former bridge when that path becomes a user-owned
adapter and reports the required adapter scaffold as an update. Review that update
and implement the ordinary adapter before running tests: obsolete generated
binding helpers can be removed during this migration. Source/test layout changes
relocate generated files; application code stays where it is until the user moves
it or adjusts project configuration.

The all-target filesystem matrix checks:

- Adoption blocks writes until the user adapter has been moved aside.
- Unchanged generation is a no-op, including after profile/format changes.
- Edits to generated files block replacement or removal during relocation.
- Edits detected between planning and applying abort before writes begin.
- Application generator files and saved adapters remain byte-for-byte intact.
- Removing bindings preserves adapter content and reports the required update.
- Custom source/test layouts retain artifact placement and ownership separately.

```sh
node --test npm/test/native-ownership.test.mjs
```

### Optional generator scaffolds

A generator binding may opt into a user-owned factory scaffold with `"stub": true`:

```json
{
  "generators": [
    {"type": "List", "factory": ["application_generators", "lists"], "stub": true}
  ]
}
```

All eight targets implement this option.
Omitting `stub` (or setting it to false) keeps the existing import-only behavior on every target.

For this Python example, generation creates `tests/application_generators.py`
(or the equivalent under a custom test directory). `lists(argument_0)` receives
its element Hypothesis strategy and must return a native `SearchStrategy`. The
initial body raises `NotImplementedError`; implement it using native strategy
composition to preserve shrinking. Multiple requested factories in the same module
share one file. Use a dedicated test module: names that conflict with generated
support, application binding modules, or another scaffold are rejected. A
scaffolded factory must belong to exactly one logical type.

Scaffolds remain readable and PEP 8 formatted in either output format. Existing
files are preserved, including edited implementations. Changes to the requested
type or type-parameter arity are reported through `adapterUpdates`; they never
replace the implementation. Changing the test layout leaves the old user-owned
file intact and creates a scaffold at the new path if absent. Move your actual
implementation to the new path before running its tests.

```sh
node --test npm/test/native-bindings.test.mjs
LAWSPEC_CORE="$PWD/.artifacts/native-binding-core" LAWSPEC_GENERATOR_STUBS=1 node tools/python-native-payments.mjs
```

The Python integration compiles and invokes the unimplemented factories, then
implements them with the application generators and runs the payment properties
in both machine profiles and output formats. Native/WASM plans must match.
Rust factories return `proptest::strategy::BoxedStrategy<NativeType>` and take one
boxed strategy for each type parameter. Type parameters carry `Debug + 'static`
bounds. A reference such as `["factories", "collections", "values"]` creates
`tests/support/factories.rs` with a public `collections` module and `values`
function; `crate` and `self` prefixes refer to that same integration-test module.
Factories sharing a root share one user-owned file. Test modules import this
support automatically. Explicit `crate`/`self` references keep importing the local
support module even with `stub: false`; the existing factory file is preserved.
For an unprefixed custom root, retain `stub: true` after implementation, or make
the local reference explicit before disabling scaffolding. The application crate named by `rustCrate` remains the
source of native types and the shared runtime. Scaffolds cannot use that crate
name, framework imports, or generated support names as their local root.

Rust scaffold bodies use `unimplemented!` until the user supplies a strategy.
Regeneration preserves the implementation, and changes to native return types or
parameter signatures appear in `adapterUpdates`. Generated scaffold files remain
readable in compact mode. Nested modules and raw Rust keyword identifiers are
supported; ambiguous factory/module paths and case-insensitive file collisions
are rejected. Existing external-crate factories remain import-only when `stub`
is omitted.

```sh
LAWSPEC_CORE="$PWD/.artifacts/native-binding-core" node tools/rust-generator-scaffolds.mjs
```

The Rust matrix compiles framework-independent source and test scaffolds, verifies
explicit failure before implementation, then runs the generic application factories
and their native shrinkers after implementation. It also compiles signatures for
all scalar types, built-in containers, and an unbound generic data type. Both
machine profiles, readable/compact output, custom directories, native/WASM parity,
file preservation and signature-change reporting are covered.

JavaScript and TypeScript factories are exported functions returning native
fast-check arbitraries. A factory reference `["factories", "collections", "lists"]`
creates `test/factories/collections.mjs` (or `.ts`). Factories in one module share
one user-owned file. TypeScript signatures use `fc.Arbitrary<T>` child arguments
and the bound native result type; unbound types use the ordinary generated data
representation. Source-type imports are adjusted from the actual nested factory
directory when custom source/test layouts are selected.

Both web formats keep scaffolds readable and throw a contextual error until
implemented. They preserve existing implementations and report changed signatures,
including native-class changes, through `adapterUpdates`. JavaScript and Python
include a native-result label so a class change also updates the untyped scaffold
contract. Conflicts with generated test modules or scaffold signature dependencies
are diagnosed before writing files.

```sh
LAWSPEC_CORE="$PWD/.artifacts/native-binding-core" LAWSPEC_GENERATOR_STUBS=1 node tools/web-native-payments.mjs
LAWSPEC_CORE="$PWD/.artifacts/native-binding-core" node tools/web-generator-scaffolds.mjs
```

The web matrix compiles and invokes the initial scaffolds, then runs implemented
payment and generic list factories with native shrinking. The signature catalog
covers every scalar, built-in container, native generic class and unbound generic
data type. TypeScript also rejects an intentionally wrong arbitrary result type.
Both profiles, formats, nested custom layouts and native/WASM parity are checked.

Java factories are public static methods returning native JetCheck
`Generator<NativeType>` values. A reference such as
`["application", "Factories", "prices"]` creates the user-owned test file
`application/Factories.java` under the configured test directory. The last two
segments name the class and method; earlier segments name the package. Generic
methods take one `Generator<T>` per type parameter. Scalar payloads use boxed
native types; Nullable/Optional keep their tagged runtime representation.

The initial methods throw `UnsupportedOperationException`. Implement them using
JetCheck composition to retain shrinking. Scaffolds require a named package
because generated framework helpers cannot access classes in the unnamed package.
Classes that conflict with generated/application classes or signature packages,
and methods that conflict with inherited Object methods, are rejected. Factories
in one class share one file. Existing implementations, custom layouts and
signature-update reporting use the same ownership rules as other targets.

```sh
LAWSPEC_CORE="$PWD/.artifacts/native-binding-core" LAWSPEC_GENERATOR_STUBS=1 node tools/java-native-payments.mjs
LAWSPEC_CORE="$PWD/.artifacts/native-binding-core" node tools/java-generator-scaffolds.mjs
```

The Java matrix compiles the scaffold before implementation, verifies explicit
runtime failure, then executes native payment and generic-shape generators,
shrinking checks, finite-domain handling and invalid-adapter/generator mutants.
The catalog compiles every scalar and container signature, native and canonical
generic result types, and rejects an intentionally wrong generator result type.
Both machine profiles, output formats, custom layouts and native/WASM parity are
covered.

Kotlin scaffolds use named objects with functions returning Kotest `Arb<Native>`.
The last two reference segments name the object and function; earlier segments
name its package. For example, `["application", "Factories", "prices"]` creates
`application/Factories.kt` under the configured test directory. Generic factories
receive one `Arb<T>` child per type parameter. Native generic classes, generated
unbound data types, and tagged Nullable/Optional types share the compiler's Kotlin
type mapping. The initial bodies throw contextual `NotImplementedError` values.

Objects must be in named packages and must not collide with generated/application
classes, Kotest support, runtime packages or signature dependencies. Inherited Any
method conflicts are rejected. The file remains user-owned; readable/compact
switches preserve it, while native-result or generic-signature changes are reported
as adapter updates. Keep existing top-level factories import-only, or use a named
object when requesting scaffolds.

```sh
LAWSPEC_CORE="$PWD/.artifacts/native-binding-core" LAWSPEC_GENERATOR_STUBS=1 node tools/kotlin-native-payments.mjs
LAWSPEC_CORE="$PWD/.artifacts/native-binding-core" node tools/kotlin-generator-scaffolds.mjs
```

The Kotlin integration compiles and invokes the initial factories, implements them
with native application arbitraries, then checks payments, generic/recursive
shapes, shrinking, finite enumeration, invalid text, exhausted refinements and
incorrect adapters. Its signature catalog checks all scalars and containers,
native/canonical generic classes, source-only compilation without Kotest, and
rejection of a deliberately wrong `Arb` result type. Both machine profiles,
formats, custom layouts and native/WASM parity are covered.

Go scaffolds are package-local functions returning `*rapid.Generator[Native]`,
with one generic child generator per type parameter. Each consuming unit gets a
user-owned `native_generators_test.go` beside its generated tests. Only the
factories used by that package are included. Named Go imports are supported in
native result types, while imported **factories** stay import-only: scaffolding
does not write into dependencies. A requested factory with no quantified use is
rejected because there is no consuming package in which to place its scaffold.

The scaffold initially panics with its logical type identity. Existing files are
preserved, signature/native-result changes produce adapter updates, and compact
mode keeps the user file readable and gofmt compatible. Factory names must not
shadow application declarations in the same package, built-ins, runtime imports,
generated support or Go test entry points. Type-parameter names avoid canonical
and application type names. Source and test layouts continue sharing the same Go
package directories.

```sh
LAWSPEC_CORE="$PWD/.artifacts/native-binding-core" LAWSPEC_GENERATOR_STUBS=1 node tools/go-native-payments.mjs
LAWSPEC_CORE="$PWD/.artifacts/native-binding-core" node tools/go-generator-scaffolds.mjs
```

The Go matrix compiles the initial factory files, verifies explicit missing-body
failures, then executes application payment/shape factories with native shrinking,
finite-domain/refinement behavior and broken adapters/generators. The catalog
compiles every scalar and container signature, imported generic models, and a
canonical type named `T0` to check that generic parameters cannot capture type
names. It rejects an intentionally wrong Rapid result type. Both profiles,
formats, custom layouts, source-only builds and native/WASM parity are covered.

Haskell scaffolds group typed Hedgehog factories in a user-owned module under the
test directory. For example, `["Application", "Generators", "lists"]` produces
`Application/Generators.hs` with `lists :: H.Gen a0 -> H.Gen [a0]`. Each type
parameter receives a native child generator; the result uses the application type
when bound, otherwise the canonical generated type. Scalar signatures preserve
the existing native representations, including `Data.Text.Text` versus `[Char]`
and tagged nullable/optional values.

Bodies initially call `error` with the logical type identity. Implement them by
composing Hedgehog generators to retain shrinking. Modules that conflict with
application models/functions/hooks, generated modules or reserved runtime modules
are rejected, including case-insensitive filename collisions. Nested modules and
custom test roots are supported; scaffolds remain readable in compact mode.
Edits remain user-owned and changes to native types or factory arity appear in
`adapterUpdates`.

```sh
LAWSPEC_CORE="$PWD/.artifacts/native-binding-core" LAWSPEC_GENERATOR_STUBS=1 node tools/haskell-native-payments.mjs
LAWSPEC_CORE="$PWD/.artifacts/native-binding-core" node tools/haskell-generator-scaffolds.mjs
```

Set `LAWSPEC_GHC` and, when required, `LAWSPEC_GHC_PACKAGE_DB` for both commands.
The payment matrix compiles and invokes the initial scaffold before supplying
application factories and exercising native shrinking and invalid-generator
diagnostics. The signature catalog compiles all scalar/container signatures,
canonical and native generic models, rejects an incorrect `Gen String` result,
and checks explicit missing-body failures. Both profiles, formats, custom layouts,
framework-independent source builds and native/WASM parity are covered.

## Release evidence required

### Bundled application projects

`lawspec examples --example payments` exports one project for each of the eight
targets under `native_payments/`. Use `--target rust` (or another target) to select
one, `--output` to choose a directory, and `--machine-bits 32` to select the other
machine profile. Each project includes the shared specification, application-owned
domain types and functions, a native price generator, binding configuration, build
files and a README with commands. Run `lawspec check`, `lawspec generate`, and the
native test command after installing its dependencies.

The native generator intentionally restricts prices to EUR 1.00–2.00. Explicit
USD/GBP and exact-decimal examples remain in the law, demonstrating that custom
distributions do not replace those checks. The applications use host exact decimal
types when faithful and framework-independent support otherwise.

Exports use `.lawspec/example.json`; compilation uses `.lawspec/generated.json`.
This separation lets repeated export preserve edited application files without
removing or overwriting generated code, including edited generated code that the
compiler will separately protect. Updated bundled user files are reported for
review through the existing update channel. Export does not run dependency
installation or native tests.

`tools/native-example-package.mjs` packs and locally installs the npm artifact,
exports and checks all eight projects, then runs Rust generation, native tests,
re-export and `generate --check` through the installed CLI. After that script,
`tools/native-example-runtime.mjs` accepts the other seven target names to execute
the exported projects with the installed compiler and cached native toolchains.
For Haskell set `LAWSPEC_GHC` and `LAWSPEC_GHC_PACKAGE_DB`; other cached dependency
locations can be overridden where the runner exposes environment variables.

`node tools/native-example-integration.mjs <target>` performs the public installed
CLI acceptance path: pack and install, export the payment project, prepare native
dependencies, check and generate, run the normal native build tool, reject an
incorrect fee implementation, restore application source, re-export, and check
regeneration. Logs for every command are retained under
`.artifacts/native-example-integration/`. `lawspec-dev ci` runs this for every target with the
default profile and with `LAWSPEC_MACHINE_BITS=32 LAWSPEC_MINIFY=1`.
`LAWSPEC_PYTHON` selects the Python version for uv; an existing interpreter can be
selected with `LAWSPEC_PYTHON_EXECUTABLE`. `LAWSPEC_NODE_MODULES` and
`LAWSPEC_GRADLE` select existing web dependencies and Gradle respectively.
`LAWSPEC_OFFLINE=1` uses offline npm, uv, Maven and Cargo operations and disables
Go proxy access; Stack still requires its normal configured dependency cache.
`STACK_ROOT` and `GRADLE_USER_HOME` can select writable copies of existing caches.

The installed CLI/native-tool path has passed for all eight targets in both
configurations: 64-bit readable output and 32-bit compact output. TypeScript
uses the exact declared dependencies recovered from the existing npm cache;
Haskell uses a writable copy of the existing Stack cache. Kotlin's Gradle 9.3.0
checks were run in the user's normal terminal because this sandbox prohibits
Gradle's coordination socket. The saved logs confirm successful native tests,
seven expected failures among 45 tests for the deliberately incorrect fee, and
zero planned regeneration changes in both configurations. This verifies the
installed CLI/Gradle path as well as the separate compilation/runtime harness.
The remote run of these CI additions exposed failures in the Kotlin and Haskell
target jobs. They came from the 0.9 narrowing of abstract `Integer` adapter
results, not from bindings, and are fixed in 0.11
([release notes](RELEASE-0.11.md#tower-polymorphic-integer-results-restored)).

The runnable assets live in `examples/native-payments/` and are copied into the
npm package by `tools/wasm.sh`. The original `lawspec examples` command retains its
inspection-artifact behavior.

### Remaining acceptance gates

The release audit maps the six shared requirements to these executable checks:

| Requirement | Evidence and checks |
| --- | --- |
| Resolve bindings once | `NativeBindingSpec` checks identities, complete mappings, ordering, arities, reference validation and unchanged defaults. `NativeRequestSpec` checks the public request boundary. `stack test` passes 509 examples. |
| Checked native bridges | The target-specific native-payment, native-codec and native-shapes runners compile application models and reject incorrect conversions, precision loss, altered variants and collapsed absence. They compare native/WASM plans across machine profiles, layouts and formatting. |
| Native generation and shrinking | The native-generator runtime checks and payment/codec runners verify framework factories, shrinking, invalid samples/shrinks, contracts and exhaustion. The shared empty-domain runners cover ignored and demanded empty parameters on all eight targets. |
| Core semantics and source independence | `lawspec-dev boundaries` checks all eight emitter dependency boundaries. The codec/source runners build generated source without test-framework dependencies; native representations are checked against the shared schema. |
| Application ownership | `npm/test/native-ownership.test.mjs` checks all-target migration, edited files, custom layouts, profile/format changes and adapter updates. `npm/test/native-bindings.test.mjs` covers optional generator scaffolds and signature changes. |
| Coherent public interface | Schema negotiation and declarations are covered by compiler/npm tests; `lawspec-dev integrity` checks compiler/WASM/API fingerprints. Bundled projects are exercised by the installed-package runners. The migration guide and release notes document the interface. |

The full npm regression suite passes 77 tests, and the package smoke test passes
installed API generation on all eight targets plus executable Rust scaffold,
doctor, adapter and regeneration checks. The package contains the binding guide,
migration notes, release notes and all eight application example configurations.
These checks, including both installed native-binding profiles, are part of
`lawspec-dev ci`, the repository's local check.

The empty-parameter audit must distinguish an empty type from an inhabited type
that mentions it. A native factory for `Phantom Empty` may ignore its child
generator; it must not fail merely because `Empty` has no values. Demanding an
empty child still cannot produce a sample or make a property pass vacuously.
Finite containers such as `List Empty` retain exhaustive enumeration.

Python supplies Hypothesis `st.nothing()` for an uninhabited native generator
argument. Rust supplies a Proptest strategy with a rejecting filter, bounded by
Proptest's rejection budget. Haskell supplies Hedgehog `Gen.discard`, Go uses
Rapid's native discard control, and Java uses JetCheck's bounded rejecting
filter. Kotlin supplies an Arb that fails when sampled; JavaScript and TypeScript
supply a fast-check Arbitrary that throws when generation is requested. They do
not use an always-false fast-check filter, which can loop indefinitely.
Each permits a factory to ignore an empty parameter without inventing a
value for that type. Actually demanding the empty child fails generation.

The shared `test/fixtures/native_empty_domains.lawspec` gives the phantom type a
stored Int8 field and sets a low exhaustive limit in the runners, ensuring that
the native factory is exercised rather than hidden by singleton enumeration.
The Python, Rust, Haskell, Go, Java, Kotlin and web `tools/<target>-native-empty-domains.mjs`
runners execute the generated properties and
reject a mutant factory that demands its empty child. Both machine profiles and
formats pass with native/WASM parity; direct runtime checks also verify retained
shrinking and rejection of an empty root. Python additionally binds an
application-owned phantom class. Java's empty native codec decoder throws
directly, avoiding an invalid switch expression with no result branches. Kotlin,
JavaScript and TypeScript also pass their native payment/generator regressions
after the empty-parameter changes.

- Compiler tests for valid mappings, rejected malformed/incomplete mappings,
  generic specialization, recursion, symbol/absence semantics and contracts.
- Lossless native/WASM request and diagnostic parity for the binding interface.
- Payment domain builds and executes on Java, Python, JavaScript, TypeScript,
  Go, Haskell, Kotlin and Rust using genuinely application-owned types.
- Native custom generators are invoked, their shrinkers demonstrably shrink
  failing domain values, invalid values/shrinks fail contextually, and explicit
  examples/boundaries still run when a generator omits those values.
- Deliberately broken field/variant mappings and precision-losing adapters fail
  deterministically. Empty/exhausted generator behavior cannot pass vacuously.
- Both machine profiles, architecture mismatch diagnostics, custom layouts,
  regeneration protection and packaged installation remain tested.
- Python follows PEP 8; Rust remains a first-class acceptance target throughout.

Dependent indices shipped as natural-indexed families in 0.11. Proof-producing
indices and cross-unit packages are 0.12 and 0.14 on the
[roadmap](LANGUAGE.md#roadmap). They are not prerequisites for binding ordinary
0.9 products and sums.
