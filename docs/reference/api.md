---
id: lawspec.reference.api
kind: reference
title: Compiler API
---
# Compiler API

The compiler exposes three methods through `createCompiler()` in the `lawspec`
package. Each takes a JSON request and returns a JSON result. The TypeScript
declarations in `index.d.ts` describe the protocol exactly; this page explains
it. For usage, see [Use the JavaScript API](../how-to/use-the-javascript-api.md).

```ts
interface Compiler {
  check(input: CheckRequest): Promise<Result>;
  expand(input: CheckRequest): Promise<Result>;
  planGeneration(input: GenerationRequest): Promise<Result>;
}
function createCompiler(): Promise<Compiler>;
```

## Requests

```ts
interface CheckRequest {
  sources: Source[];                        // {path, content}
  schemaVersion?: 3 | 4;
  machineBits?: 32 | 64;                    // default 64
  generation?: Partial<Generation>;         // cases, maxAttempts, maxShrinks, exhaustiveLimit
  nativeBindings?: NativeBindings;          // schema 4 only
  package?: {name: string; version: string};
  dependencies?: Record<string, string>;
  packages?: Package[];
  cacheDirectory?: string;                  // keep work between runs here
}

interface GenerationRequest extends CheckRequest {
  target: Target;                           // 'java' | 'python' | ... | 'rust'
  sourceDir?: string;
  testDir?: string;
  minify?: boolean;                         // default false
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

### Schema versions

Requests may omit `schemaVersion` or send `3`. Requests with `nativeBindings`
use `4`; the JavaScript API selects it automatically when `nativeBindings` is
present, unless you set `schemaVersion` yourself. A non-empty `nativeBindings`
with schema 3 is rejected, so a compiler that does not understand bindings can
never ignore them. An explicit schema `2` receives a diagnostic. Results report
the negotiated schema.

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
  schemaVersion: 3 | 4;
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
| `match` | `value` (the scrutinee), `cases`: each `{constructor, binders, body}` |
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
  signatures with origins.
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
bindings. Handle unknown `status` and `stage` values gracefully. See
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
  rustCrate?: string;
  goImports?: {alias: string; path: string}[];
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
`codec`. `goImports` is accepted only for Go. `check` validates identities;
`planGeneration` also checks target support. See
[native bindings](native-bindings.md).
