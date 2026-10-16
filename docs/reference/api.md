---
id: lawspec.reference.api
kind: reference
title: Compiler API
---
# Compiler API

Canonical requests use `schemaVersion: 5`, explicit
`languageProfile: "1.0-rc.1"`, and optional `verification: {layers: []}`.
An empty selection performs intrinsic definition checks and reports laws as
`not-verified`. Native tests are `planned` until an execution supplies evidence.
The existing schema-3/4 interface below is retained during migration; making
schema 5 the sole normal interface remains a minor-version interface gate.
The `format` method requires schema 5 and returns `formattedSources` after
canonical validation. Every view and editor service uses the same typed Core.
Typed laws expose `inputDomain: "universal"` for canonical obligations and
`"nonempty"` for legacy test domains. Complete verification of an empty universal
domain explicitly reports zero evaluated cases and no produced witnesses.
Selecting property testing alone does not report completed verification when
the domain supplies no cases.
Laws expose documentary scalars as `metadata: {id?: string, owner?: string}`.
The top-level law `id` and `owner` continue to identify its declaration and unit;
documentary metadata neither renames them nor establishes verification evidence.

The compiler exposes five methods through `createCompiler()` in the `lawspec`
package. Each takes a JSON request and returns a JSON result. The TypeScript
declarations in `index.d.ts` describe the protocol exactly; this page explains
it. For usage, see [Use the JavaScript API](../how-to/use-the-javascript-api.md).

```ts
interface Compiler {
  format(input: CheckRequest): Promise<Result>;
  check(input: CheckRequest): Promise<Result>;
  expand(input: CheckRequest): Promise<Result>;
  planGeneration(input: GenerationRequest): Promise<Result>;
  migrationBaseline(input: MigrationRequest): Promise<Result>;
}
function createCompiler(): Promise<Compiler>;
```

## Requests

```ts
interface CheckRequest {
  sources: Source[];                        // {path, content}
  schemaVersion?: 3 | 4 | 5;
  languageProfile?: '1.0-rc.1';
  verification?: Verification;
  machineBits?: 32 | 64;                    // default 64
  generation?: Partial<Generation>;         // cases, maxAttempts, maxShrinks, exhaustiveLimit
  nativeBindings?: NativeBindings;          // schema 4 or 5
  package?: {name: string; version: string};
  dependencies?: Record<string, string>;
  packages?: Package[];
  cacheDirectory?: string;                  // keep work between runs here
  attestation?: unknown;                    // an environment attestation document
}

interface GenerationRequest extends CheckRequest {
  target: Target;                           // 'java' | 'python' | ... | 'rust'
  sourceDir?: string;
  testDir?: string;
  minify?: boolean;                         // default false
}

interface MigrationRequest extends CheckRequest {
  schemaVersion?: 5;
  languageProfile: '1.0-rc.1';
  from: '0.24';
}
```

- `check` and `expand` report whether the specification is valid.
  `planGeneration` also reports whether it can be executed: for example, a
  well-typed refinement whose finite domain is empty passes `check` but fails
  generation.
- `generation` fields you omit keep their defaults (100, 10000, 1000, 4096).
- `minify` selects compact output; see
  [formatting](formatting.md).
- `cacheDirectory` names a folder where the compiler keeps its work, so later
  requests reuse what did not change; results are identical either way. The
  folder is created as needed, and entries are tied to the compiler version.
  The WebAssembly compiler resolves it against the working directory, the
  only directory it can reach. Use one folder per compiler build; the CLI does
  (see [the compiler cache](cli.md#the-compiler-cache)).
- `attestation` is an environment attestation document, version 1 (see
  [where the tests ran](language/evidence-and-discharge.md#where-the-tests-ran)).
  A malformed one, or an unknown format or version, is a diagnostic with code
  `attestation`. It changes nothing that is compiled; it only annotates the
  evidence.

### Schema versions

Canonical requests select schema 5 and `languageProfile: '1.0-rc.1'`.
The JavaScript facade selects schema 5 when that profile is present.

Requests may omit `schemaVersion` or send `3`. Requests with `nativeBindings`
use `4`; the JavaScript API selects it automatically when `nativeBindings` is
present, unless you set `schemaVersion` yourself. A non-empty `nativeBindings`
with schema 3 is rejected, so a compiler that does not understand bindings can
never ignore them. An explicit schema `2` receives a diagnostic. Results report
the negotiated schema.

### Migration source inventory

`migrationBaseline` explicitly selects the 0.24 source grammar with `from`.
It requires schema 5 and the current technical language profile; normal
schema-5 check, formatting and generation requests keep canonical parsing.
Migration and normal requests use separate compilation caches.

The result includes `sourceLanguageProfile: '0.24'` and `sourceSyntax`, an
array of version-1 inventories with `path`, `unit` and `nodes`. Nodes contain
`kind`, optional `name` and a parser `span`. They identify actual declarations,
sections, binders, types, expressions, patterns, literals, tables and closers.
The inventory retains unused generic definitions and reusable law templates
before elaboration and specialization. Definition nodes also carry their
checked `uses` row, including an empty array for a pure definition.

These are source syntax and checked declaration context, rather than another
executable representation. The same type, capability, effect, totality and
definition-contract checks must succeed before any inventory is returned.
Law verification still follows `verification.layers`; an empty selection
reports `not-verified`. Spans count Unicode code points and eight-column tab
stops, as other compiler spans do. Source-edit clients translate them to their
own offset convention. See [source migration](../explanation/api-migration.md#source-migration-from-024).

### Packages

- `dependencies`: the package names and version ranges the request's own
  sources require.
- `packages`: every package those sources need, directly or indirectly, each
  `{name, version, dependencies?, sources}`. Package sources are compiled with
  the request.
- `package`: set when the request's own sources are a package; their units must
  then be named after it.

## Results

```ts
interface Result {
  schemaVersion: 3 | 4 | 5;
  diagnostics: Diagnostic[];
  machineBits?: 32 | 64;
  generation?: Generation;
  units?: Unit[];
  dataTypes?: DataTypeDeclaration[];
  definitions?: Definition[];
  laws?: Law[];
  contracts?: {owner: string; contract: Contract}[];
  refinements?: Refinement[];
  evidence?: ObligationEvidence[];
  attestation?: AttestationView;            // when the request has one
  expansions?: string[];                    // expand and planGeneration
  files?: Artifact[];                       // planGeneration
  packages?: PackageView[];                 // when the request has package fields
  project?: {package?: PackageVersion; dependencies: Record<string, string>};
}
```

An empty `diagnostics` array means success.

### Diagnostics

```ts
interface Diagnostic { code: string; message: string; at: Location | null }
```

Source syntax errors, semantic errors, Core invariant failures and generation
errors have distinct codes. Codes include `parse`, `import`, `package`,
`indexed`, `refuted`, `layout` and `native-binding`. Locations use one-based
lines and columns.

### Artifacts

```ts
interface Artifact {
  path: string;
  content: string;
  ownership: 'user' | 'generated';
  placement: 'source' | 'test';
  adapterReference?: string;
}
```

`ownership` and `placement` are independent: generated runtime source goes in
the source directory, user adapters are also source, and test helpers are
tests. Never infer one from the other, and never assume a fixed number of
files.

A user-owned artifact may carry `adapterReference`, the compiler's canonical
readable stub. It is comparison data, not a file to write. Hash it (falling back
to `content` when absent) to detect a changed adapter interface independently
of formatting mode. Hash the actual `content` of generated files for
ownership. Never hash or overwrite a user's implementation.

## Types and identities

Types are discriminated unions:

```js
{ kind: "constructor", name: "Int8", arguments: [] }
{ kind: "constructor", name: "Optional", arguments: [
  { kind: "type", type: { kind: "constructor", name: "Int8", arguments: [] } }
] }
{ kind: "function", parameter: Type, result: Type }
{ kind: "variable", id: "..." }
```

Type arguments are `{kind: "type", type}`, `{kind: "natural", value}` (a
decimal string) or `{kind: "indexVariable", id}`.

Declarations, properties and binders have resolved IDs, such as
`example.payments::type::Money` or `shop.orders::law::dollars settle in dollars`.
IDs stay stable when unrelated laws are added. Join references by ID, not by
display name: two constructors with the same name can belong to different
units.

Origins are `{kind: "source", span: {start, end}}` or
`{kind: "generated", declaration}`. Source ranges come from the parser,
including inside reused laws and refinements; end positions are exclusive.
Synthesized nodes name the declaration that caused them.

## Expressions

Every expression is `{type, origin, text, node}`. `text` is for display;
`node` carries the meaning:

| `node.kind` | Fields |
| --- | --- |
| `constant` | `value`: a scalar value |
| `local` | `id`: a binder |
| `call` | `declaration`, `arguments` |
| `binary` | `operator`, `evidence` (`numeric` or `structural`, with a type), `left`, `right` |
| `unary` | `operator` (`-` or `!`), `argument` |
| `shortCircuit` | `operator` (`&&` or `\|\|`), `left`, `right` |
| `convert` | `conversion`: `checked` (a computed value must fit an adapter parameter) or `explicit` (a source conversion); `argument` |
| `helper` | `name`, `arguments` |
| `construct` | `constructor` ID, `arguments` |
| `field` | `constructor` ID, zero-based `index` in its fields, `value` |
| `update` | `constructor` ID, zero-based `index`, `value`, replacement `field` |
| `match` | `value` (the scrutinee), `cases`: each `{constructor, binders, body}` |
| `if` | `condition`, `then`, `else` |
| `let` | typed `binder`, `value`, `body` |
| `perform` | `ability` ID, `operation`, `arguments` |
| `handle` | `handling`: `catchFailure` or `withHandler`; `ability`, `body`; `withHandler` also carries `handler` |
| `calls` | `ability`, `operation`, `arguments`: an expression array for a matching-arguments filter, or `null` for every call |
| `allElements` | `value`, `binder`, `predicate`: the predicate holds for every list element |
| `allPayloads` | `value`, `predicates`: one `{binder, predicate}` per type argument of the root data type |

Structural values are `construct` nodes, never scalar constants. Match binders
are local to their case. For `allElements`, the binder is local to
`predicate`; the result is true for an empty list and short-circuits on the
first false element. For `allPayloads`, each binder is local to its own
predicate; traversal follows stored occurrences of each type parameter through
recursive declarations and containers, is vacuously true for empty or phantom
storage, and short-circuits on rejection. Exhaustive visitors must handle every
kind.

A let binder scopes over its body, after its value has been evaluated. Branches
and handlers retain their own computations; a visitor traversing their syntax
does not execute them. `calls.arguments: []` selects calls to a zero-argument
operation, whereas `null` applies no argument filter. Handler text retains
recording and native/spec handler choices. These nodes are included in the
generated TypeScript discriminated union, including both handler shapes, so an
exhaustive visitor can traverse operational expressions and structural field
restrictions through the same interface.

A `call` to an ID found in `definitions` is a checked definition; any other
call is an adapter. Refinement and contract expressions may call checked
definitions only.

## Laws and assertions

```ts
interface Law {
  id: string; owner: string; name: string;
  inputs: Input[];            // {id, name, type, predicates, bounds}
  assertion: Assertion;
  examples: Example[];
  description: string; rationale: string; references: string[];
  location: Location; trace: string[]; generation: Generation;
}

type Assertion =
  | {kind: 'equal'; evidence; left: Expr; right: Expr}
  | {kind: 'implies'; guard: Expr; body: Assertion}
  | {kind: 'all'; items: Assertion[]};
```

Schema 5 returns `Law.references` as `DocumentaryReference[]`. Each link has
`kind: "law"`, `"function"` or `"external"`. Internal links carry a `target`
with stable `id`, declaring `unit`, source `name`, declaration `span` and
`referenceSpan` at the use. Both spans use `{spanStart: Location, spanEnd:
Location}`. Law links optionally carry `selector: {kind: "definition" |
"description" | "rationale" | "references"}` or `{kind: "named-reference",
name: string}`. External links carry `resource` and an optional phrase `name`.
No target contains an expanded proposition, so cycles remain finite. These
links never provide verification evidence. Transitional schemas 3/4 retain
string citation arrays, as in the interface above; the generated TypeScript
union covers both wire versions.

Schema 5 also exposes `law.harness.witnesses`: each entry has a target `binder`
ID, a normalized lexical `path: string[]`, and a typed `expression: Expr`.
These describe configured search choices. Completed proof/checking status is
still reported in `evidence`; a configured candidate is never itself evidence.
A failed unbounded candidate yields `incomplete`, and native execution reports
`quantifier-search-incomplete`. Finite fallback can still establish a result.

Configured scoped strategies appear in `law.harness.searches`, each with a
`binder` identity, normalized lexical `path`, `strategy` name and typed `draw`.
Outer `law.harness.strategies` entries also retain their typed draws. Draws
preserve checked expressions and source origins for editor navigation. They describe
configuration, not executed samples or completed evidence. Default bounded
search can find a witness without enumerating an infinite domain. A bounded
miss remains incomplete; a strategy's finite choice list never proves absence.

The `assertion` tree is authoritative. Traverse it to keep the scope of shared
guards and the order of conjuncts; do not flatten guards or turn refinement
predicates into implications.

Inputs carry their refinement `predicates`, which are authoritative, and
`bounds`, which are derived generation hints `{operator, value}` over preceding
inputs. `trace` lists the expansion steps that `lawspec explain` prints.

Examples are `{name, bindings, expectations}`. Each binding is
`{id, name, type, value}` with a `DataValue`; each expectation is an
`Assertion` whose right side is a typed expression.

## Values

A `DataValue` is a tagged scalar, or a structural value:

```ts
{kind: 'data', type: Type, constructor: string, fields: DataValue[]}
```

Lists use the constructors `List::Nil` and `List::Cons` (fields: head, tail);
`Maybe` and `Either` use their qualified constructor IDs. Do not flatten these
to JSON arrays or nulls: that loses constructor and nested-presence
distinctions.

Scalars are lossless. Each has a `type` and a payload:

| Domain | Payload |
| --- | --- |
| Integers, including `Integer` | `value`: decimal string |
| `Bool` | `value`: boolean |
| `Decimal` | `coefficient`, `exponent`: decimal strings |
| `Rational` | `numerator`, `denominator`: decimal strings; reduced, positive denominator |
| `Float32`, `Float64` | `bits`: 8 or 16 hexadecimal digits in IEEE bit order |
| `Complex64`, `Complex128` | `real`, `imaginary`: tagged component scalars |
| `Char`, `CodePoint`, `CodeUnit16` | `value`: the numeric unit |
| `Text`, `CodePointText`, `Utf16Text`, `Bytes` | `units`: array of numeric units |
| `Symbol` | `id`, `description`: strings; identity comes from `id` |
| `Unit`, `Null`, `Undefined` | none |
| `Nullable`, `Optional` | `value`: `null` when absent, otherwise a tagged scalar |

Do not convert integer strings to JavaScript numbers. Raw surrogates never
pass through JSON strings. The enclosing type gives the inner type of an absent
presence value.

## Declarations

- `units`: each `{id, declarations}`, where declarations are the unit's
  signatures with origins. When an authored declaration is known, its optional
  `source: {unit, name, canonicalName?}` retains the declaring unit and original
  spelling through imports, re-exports and specialization. `canonicalName`,
  when present, identifies a compiler-owned prelude collection operation.
  Generated helpers may have no source declaration. Resolve executable calls
  by their declaration IDs; do not infer ownership from a filename or a
  generated name.
- `dataTypes`: each `{id, name, parameters, origin, constructors}`, with
  constructor IDs and ordered typed fields. Built-in containers are not listed.
  An imported data type keeps the ID of the unit that declares it.
- `definitions`: each `{owner, id, arguments, body}` for a concrete checked
  definition. Generic definitions appear as their specialized instances, with
  generated names; calls sharing a signature share an instance. An imported
  definition appears among the importing unit's definitions, with a name
  derived from its unit (`shop.orders::shopDomainCentsOf`).
- `contracts`: each `{owner, contract}`, with typed argument and result binders,
  `preconditions` and `postconditions`.
- `refinements`: each with its owner, name, parameters (`type` or `value`
  kind), requirements and printed definition.

## Evidence

```ts
interface ObligationEvidence {
  owner: string;
  declaration: string;
  stage: string;
  status: 'proved' | 'exhaustively-checked' | 'property-tested' | 'measured' | 'runtime-checked' | 'default-handler' | 'assumed';
  reason: string;
  claim: Expr | null;
  environment?: string;                     // when an attestation touches it
  environmentRun?: AttestedRun;
  against?: AttestedDependency[];
}

interface AttestedRun { id: string; startedAt: string; recordedAt: string }
interface AttestedDependency {
  dependency: string;
  endpoint: string;
  reached: boolean;
  kind: 'real' | 'stand-in';
  standIn?: {identity: string; version: string; conformance: string; historyDigest?: string};
}
interface AttestationView {
  environment: string;
  run: AttestedRun;
  producer?: {name: string; version: string};
  dependencies: (AttestedDependency & {obligations: string[]})[];
}
```

| `stage` | `declaration` | `claim` |
| --- | --- | --- |
| `law` | The law, `unit::law::name` | The law as a Boolean expression |
| `precondition`, `postcondition` | The adapter or definition | The predicate |
| `construction` | The constructor | The field constraint |
| `adapter` | The adapter | `null` |
| `binding`, `codec`, `generator`, `native-function` | The bound declaration | `null` |

Law obligations come first, then contracts, adapters, constructions and
bindings. With a request `attestation`, each law obligation whose tests ran
and that relies on an attested dependency gets `environment`,
`environmentRun` and `against`; nothing else changes. The result's
`attestation` lists each dependency with the obligations it touched. Handle unknown `status` and `stage` values gracefully. See
[evidence and discharge](language/evidence-and-discharge.md).

## Packages in results

When a request has any package field, results add `packages`, each
`{name, version, dependencies, units}`, and `project`, with the request's own
`package` (if any) and `dependencies`. Requests without package fields produce
neither.

## Native bindings

```ts
interface NativeBindings {
  types?: NativeTypeBinding[];
  generators?: NativeGeneratorBinding[];
  functions?: NativeFunctionBinding[];
  names?: {declaration: string; name: string}[];       // schema 5: public generated function names
  rustCrate?: string;
  goImports?: {alias: string; path: string}[];
  erlangIncludes?: {path: string; library?: boolean}[];
}
type NativeReference = string[];

interface NativeTypeBinding {
  type: string;                                       // e.g. "example.payments::type::Money"
  native: NativeReference;
  constructors?: {
    constructor: string;
    native: NativeReference;
    style: 'record' | 'variant' | 'unit';
    fields?: {field: string; native: string}[];
  }[];
  codec?: {toNative: NativeReference; fromNative: NativeReference};
  arguments?: string[];                               // a handle's Kotlin type arguments
}

interface NativeGeneratorBinding { type: string; factory: NativeReference; stub?: boolean }
interface NativeFunctionBinding {
  declaration: string;
  native?: NativeReference;                           // a function
  method?: string;                                    // a method of the handle argument
  constructor?: NativeReference;                      // a constructor making a handle
}
```

Unknown fields are rejected. A type binding has either `constructors` or
`codec`. `goImports` is accepted only for Go; `erlangIncludes` only for Erlang.
An Erlang header uses `include`, or `include_lib` when `library` is true.
`check` validates identities;
`planGeneration` also checks target support. See
[native bindings](native-bindings.md).
