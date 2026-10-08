---
id: lawspec.reference.native-bindings
kind: reference
title: Native bindings
---
# Native bindings

Native bindings connect LawSpec data types, adapters and generators to existing
application code. This page specifies the configuration and what each target's
generated code does with it. For step-by-step use, see
[Bind native types and functions](../how-to/bind-native-types.md) and
[Write custom codecs and generators](../how-to/custom-codecs-and-generators.md).

## Configuration

Bindings are set per target in `lawspec.json` (`targets[].nativeBindings`) or in
a schema-4 compiler request (`nativeBindings`). The fields are `types`,
`functions`, `generators`, `rustCrate`, `goImports` and `erlangIncludes`; their shapes are in the
[API reference](api.md#native-bindings).

- Declarations are named by resolved identity: `<unit>::type::<Name>` for data
  types and `<unit>::<name>` for adapters.
- Native references are arrays of identifier segments, never code.
- A type binding maps the type, every constructor and every field, or names a
  `codec` pair. It cannot do both.
- Constructor `style` is `record` (the only constructor of a product),
  `variant` (an alternative with fields) or `unit` (an alternative without
  fields).
- A unit with function bindings must map every adapter it declares. Its adapter
  file becomes a generated bridge.
- Generic generator factories are resolved with one argument per type
  parameter.
- A [handle](language/models.md#handles)'s type binding may give
  `arguments`: the native class's type arguments, written in Kotlin, such as
  `["kotlin.Int"]`, or `[]` for a class that is not generic. Generated
  Kotlin then names the handle's type in full, as in
  `ConcurrentLinkedQueue<kotlin.Int>`, instead of `kotlin.Any`. Other
  targets ignore it; Java keeps `Object`.

## Async adapters

An [async adapter](language/async-functions.md) may be bound like any other. Its
native function or method uses the target's native concurrency, and the bridge
converts the result after the asynchronous call completes.

| Target | The native returns | The bridge |
| --- | --- | --- |
| Python | a coroutine (`async def`) | `async def`, awaiting it |
| JavaScript, TypeScript | a `Promise` | `async function`, awaiting it |
| Java | a `CompletableFuture` of the boxed type | converts with `thenApply` |
| Kotlin | from a `suspend fun` | a `suspend fun` |
| Go | a `LawSpecTask[T]` | a `LawSpecTask`, awaiting it in a goroutine |
| Rust | a future (`async fn`) | `async fn`, with `.await` |
| Haskell | an `IO` action | `IO`, converting with `fmap` |
| Erlang, Elixir, Gleam | the declared native value | calls the function in a monitored process, then converts the result |

A Unit result is `LawSpecRuntime.Value` in Java's future, and `LawSpecUnit` in
Go's task. A constructor bound to an async adapter is called at once, and its
bridge returns a task that is already done. On BEAM, the constructor instead
runs in the same monitored worker as other async native calls. On Kotlin, an async method binding
needs its handle's type binding, since Kotlin calls the method itself.

## Validation

`check` resolves bindings once, against the typed declarations, and rejects:

- unknown types, constructors or fields;
- duplicate or incomplete mappings, and duplicate native field names;
- a `record` style on a type with several constructors, or fields on a `unit`
  constructor;
- incompatible type arities;
- `arguments` on a type that is not a handle, or an empty argument;
- malformed native references;
- unknown configuration fields.

`planGeneration` additionally rejects representations the target does not
support. Specifications without bindings keep their default generated types.

## Guarantees on every target

- **Bindings do not change meaning.** Arithmetic, equality, total definitions
  and refinements use LawSpec semantics. Bindings affect only native
  representations and the testing plan's generator choice.
- **Bridges are checked.** Conversions compose through type parameters,
  recursion, `List`, `Maybe`, `Either`, `Nullable` and `Optional`. They keep
  exact values, Symbol identity, distinct absence states, constructor
  contracts and both machine profiles. Adapter inputs and outputs are validated;
  an invalid native value is a failure, never a rejected sample. The built-in
  collections map to each target's own collections; see
  [collections](language/collections.md#native-types).
- **Generators stay native.** Factories return the framework's own generator.
  The tests compose and map it directly, without resampling or replacing its
  shrinker. Every sample and shrink is validated through the bridge.
  Refinements still filter it. Examples, deterministic boundaries and
  finite-domain enumeration run independently of it, and finite domains are
  enumerated without calling the factory. An exhausted custom generator never
  falls back to a built-in witness.
- **Source stays framework-free.** Bridges, codecs and runtimes are generated
  source with no test-framework dependency. Generator helpers are generated
  test code.
- **Application code stays yours.** Application models, hooks and factories
  are never rewritten. Optional scaffolds are user-owned.

## Evidence

A type binding is a `binding` obligation, `runtime-checked`. Codec hooks,
generator factories and bound functions are `codec`, `generator` and
`native-function` obligations, `assumed`.

## Targets

### Rust

- References are paths; `crate` refers to the application library.
- `rustCrate` names the application library crate, so tests use its types and
  runtime rather than a second compiled copy.
- Construction uses struct and enum-variant literals with named fields.
  Direct mappings need recursive indirection compatible with the generated
  representation; other storage needs codec hooks.
- Hooks return `lawspec_runtime::Result<T>`. A generic hook receives
  `&dyn Fn(T) -> N` (or the reverse) per type parameter.
- Factories return a Proptest strategy of the native type and receive one boxed
  strategy per type parameter. They live in `<testDir>/support/`.
- An empty type parameter is supplied as a strategy with a rejecting filter,
  bounded by Proptest's rejection budget.

### Python

- References are module components followed by an exported class or function.
- Classes are checked by exact identity. Fields are read by attribute and
  passed as keyword arguments, so keyword-only dataclasses and reordered fields
  work.
- The bridge module `lawspec_native.py` and bound adapters are generated source.
  Python integers have no native width, so the machine profile is enforced by
  validation.
- Hooks return the converted value and raise on failure. Child converters
  receive native payloads.
- Factories are in importable test modules, receive one Hypothesis strategy per
  type parameter, and return a strategy of the native type.
- An empty type parameter is supplied as `st.nothing()`.

### JavaScript and TypeScript

- References are module path segments followed by an exported name. Source
  references resolve from the source directory; generator references from the
  test directory. Imports use `.mjs` (JavaScript) or `.js` (TypeScript).
- Payload classes receive one object keyed by the mapped field names; unit
  classes receive no arguments. Mapped fields must be own properties.
- Hooks return values or throw. Hook tables are copied when a schema is bound,
  so later mutation cannot change conversions.
- Factories return fast-check arbitraries and receive one arbitrary per type
  parameter. TypeScript scaffolds use `fc.Arbitrary<T>`.
- An empty type parameter is supplied as an arbitrary that throws when asked
  for a value. (An always-false fast-check filter could loop forever.)

### Java

- References are fully qualified type, constructor or static method names.
- Payload fields are read with accessor methods; constructors receive fields in
  LawSpec declaration order. `unit` refers to an enum constant. An empty record
  uses the `record` or `variant` style.
- `LawSpecNativeCodecs` composes typed codecs over the shared schema; generic
  recursive codecs are built lazily.
- Hooks take typed `java.util.function.Function` child converters and throw on
  failure. Generic payloads are checked `LawSpecRuntime.Value`s.
- Factories are static methods returning JetCheck `Generator`s, with one
  `Generator<T>` per type parameter. Scaffolds must be in a named package.
- An empty type parameter is supplied as a bounded rejecting JetCheck filter.

### Kotlin

- Payload mappings read properties and call constructors in LawSpec field
  order. `unit` refers to an enum constant or singleton object, compared by
  identity. Payload constructors are checked by exact runtime class.
- `LawSpecNativeCodecs.kt` and bound adapters are generated source.
- Hooks take ordinary function parameters, such as `(A) -> B`, and throw on
  failure.
- Factories return Kotest `Arb`s, with one `Arb<T>` per type parameter.
  Scaffolds are named objects in named packages.
- An empty type parameter is supplied as an `Arb` that fails when sampled.

### Go

- References are one package-local identifier, or an alias from `goImports`
  and an exported identifier. Aliases are resolved to compiler-owned names, so
  they cannot shadow generated or framework imports. Duplicate aliases or
  paths, traversal segments and undeclared aliases are errors.
- Payload fields use exported names and keyed struct literals; `unit` refers to
  a constant. Application functions keep their own names (such as `AddFee`);
  generated bridges use separate names.
- Application symbols are reserved first. A generated type or variant that
  would collide receives a `Canonical` prefix, with a number if needed
  (`CanonicalBox`, then `Canonical1Box`). Logical identities do not change.
  Hooks that name generated types must use the emitted names.
- `lawspec_native_codecs.go` holds the framework-independent conversions; only
  reachable codecs are emitted per package.
- Hooks return `(value, error)`. Hooks that name generated types must live in
  the generated types' package, to avoid an import cycle.
- Factories are package-local functions returning `*rapid.Generator[T]`, with
  one generator per type parameter. Imported factories are never scaffolded.
- An empty type parameter is supplied through Rapid's discard control.

### Haskell

- References are module components followed by a type, constructor or
  function.
- Records are constructed and matched by mapped field names, independent of
  declaration order. Application modules receive distinct import aliases, and
  references that shadow generated modules are rejected. Unit-returning
  application calls are forced before their result is encoded.
- Hooks return `Either String value`. Generic payloads are opaque; use the
  supplied child converters.
- Factories return Hedgehog `Gen`s, with one child `Gen` per type parameter.
- An empty type parameter is supplied as `Gen.discard`.

### Erlang, Elixir and Gleam

- All three targets share checked Erlang conversions. Public definitions and
  codec arguments use each target's canonical native types. Generic hooks take
  one conversion function per type parameter, after the value being converted.
- Erlang function references are `["module", "function"]`. A `variant`
  constructor uses a tagged tuple with fields in LawSpec declaration order;
  a `unit` constructor uses an atom. A `record` constructor uses the named
  record and mapped fields from `erlangIncludes`. For example,
  `"erlangIncludes": [{"path": "domain.hrl"}]` emits `-include("domain.hrl")`;
  `"library": true` selects `-include_lib`. Headers determine record positions
  and defaults. Put project headers in the normal Erlang include directory.
- Elixir references contain module components and the function name, such as
  `["MyApp", "Orders", "copy"]`. Constructor references name structs. Mapped
  fields are passed to `struct!`, preserving defaults on other fields. A
  lowercase singleton reference such as `["empty"]` represents an atom.
- Gleam references contain module path components and a function or capitalized
  type/constructor name. Generated typed constructor helpers use mapped labels,
  preserving the native constructor's field order. Codec hooks can represent
  opaque types through their public functions.
- Method bindings call the bound handle's module with the receiver first.
  Constructor bindings omit `Unit` inputs; a `Unit` result ignores the native
  return value after executing the call.
- Native BEAM handles use a pid, reference or port. Generated actors also
  have stable mailbox addresses: their identity survives replacement of the
  worker process, and children of the same supervisor have distinct identities.
- Factories return PropEr generators, `StreamData.t(a)` or `qcheck.Generator(a)`.
  Child generators produce native bound values. Every generated value and shrink
  crosses the checked schema before refinements filter it. Invalid values fail.
  Finite domains are enumerated without invoking their factories.
- Optional factory scaffolds live in Erlang `test/`, Elixir `test/support/`, or
  Gleam `test/`. Gleam factories can import the application's types. Generated
  Erlang test helpers for Gleam live in the local `test-support/` development
  package, keeping property frameworks out of production exports.

## Uninhabited type parameters

A factory for a type such as `Phantom Empty` may ignore its child generator: it
must not fail merely because `Empty` has no values. Demanding a value from that
child fails generation, so it can never make a property pass. Finite containers
such as `List Empty` are still enumerated.

## Ownership

Generated bridges and runtimes are generated source. Framework helpers are
generated test code (Go test files share their package's directory).
Application models, hooks and factories are user-owned; the manifest never
claims them.

- An existing adapter at a new bridge's path blocks generation until you move
  it aside.
- Removing bindings keeps the former bridge as a user-owned adapter and reports
  the required adapter signature.
- Unchanged generation is a no-op, including after a profile or format change.
- Changing the layout moves generated files but not application files.

See [ownership and regeneration](../explanation/ownership-and-regeneration.md).
