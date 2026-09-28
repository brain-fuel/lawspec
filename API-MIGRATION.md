# Compiler API migration: schema 2 → schema 3

LawSpec 0.8 introduced API schema version **3**, which 0.9 continues to use.
Requests may omit `schemaVersion` or
send `3`. An explicit `2` (or any other version) receives a request diagnostic;
it is never silently reinterpreted. LawSpec specification syntax remains compatible.
The generated `index.d.ts` describes the public protocol. Internal Haskell
constructors and record fields are no longer the wire format.

## 0.9 structural data and definition metadata

Successful results also expose `dataTypes: DataTypeDeclaration[]`. Each named
declaration has a resolved `id`, a display `name`, parameter IDs, an origin, and
constructors with resolved IDs and ordered typed fields. Use resolved IDs to
join references; constructors with the same display name can belong to different
units. Built-in container types do not need user declarations in this array.

Example bindings now use `DataValue`: either an existing tagged scalar or
`{kind: "data", type: Type, constructor: string, fields: DataValue[]}`. List values
use `List::Nil` and `List::Cons`, with head and tail fields; Maybe and Either use
their qualified constructor IDs. Do not flatten these values to JSON arrays or
nullable fields: that would lose constructor and nested-presence distinctions.

Expressions add `construct` nodes with a constructor ID and argument expressions,
and `match` nodes with a scrutinee and cases. Each case has a constructor ID,
ordered typed binders, and a body. Its binders are local to that case. Structural
expressions are represented by these nodes, not by scalar `constant` nodes.
Exhaustive API visitors must handle the added expression variants even though
the protocol continues to use schema version 3.

Successful results add `definitions: Definition[]`. Each entry contains `owner`,
the resolved declaration `id`, typed `arguments: Binder[]`, and a typed `body`.
The matching entry in `units[].declarations` supplies the signature and origin.
Calls retain their declaration ID; consumers can join against `definitions` to
distinguish checked bodies from external adapters. An empty array means the
program has no definitions.

The native frontend checks these bodies for typing, exhaustive matching,
structural termination, and potentially failing operations. Native reference
execution and source emission for Rust, Java, Kotlin, Python, JavaScript,
TypeScript, Go, and Haskell are implemented, including generic definitions
specialized to concrete signatures. The API exposes concrete instances with
generated names and resolved IDs, not unspecialized templates. Calls sharing a
signature reuse an instance; unused templates emit none. Consumers should join
by ID rather than parse generated names. Refinement-bearing definitions are
checked and emitted by both the native compiler and bundled WASM distribution.
Definition bodies produce generated source rather than
user-owned adapter stubs. Haskell native entry points take an `LS.SymbolContext`
and return `Either String a`; generated tests allocate a context per example or
property iteration so Symbol fixture identity does not escape its scope.

Refinement and contract expressions may now contain calls whose IDs resolve to
checked `definitions`. Validation still rejects calls to external adapters in
these expressions. Test planning evaluates the closed definitions when filtering
finite cases, boundaries, and concrete example inputs. Calls remain ordinary
typed call nodes; consumers need no source-level refinement interpreter.

## Laws and typed expressions

Read `result.laws[i].examples` instead of `law.original.examples`. A binding is
now `{id, name, type, value}` rather than `[name, value]`. `value` retains the
lossless tagged scalar representation from schema 2. Expected results are typed
expressions in an assertion, for example `example.expectations[0].right.node.value`.

Every expression has `{type, origin, text, node}`. `text` is for presentation;
inspect `node` for semantics. Nodes explicitly distinguish constants, resolved
locals, declaration calls, arithmetic with capability evidence, short-circuit
operators, helpers, and conversions. Conversion mode `checked` means an exact
result must fit its adapter parameter; `explicit` records a source conversion.
There is no separate `typedExpressions` side table to match against source ASTs.

Assertions are the authoritative proposition tree:

- `{kind: "equal", evidence, left, right}`
- `{kind: "implies", guard, body}`
- `{kind: "all", items}`

The `left`, `right`, and `guards` compatibility projections on laws are removed.
Traverse the tree to preserve shared guard scope and conjunction order. Do not
flatten guards or turn refinement predicates into implications.

Inputs use `{id, name, type, predicates, bounds}`. IDs identify binders;
display names need not be globally unique. Bounds are derived generation hints
`{operator, value}` over preceding inputs. Predicates remain authoritative.
`generationPlan` and `inputRefinements` are replaced by these explicit fields.
Contracts expose typed argument/result binders, preconditions, and postconditions.
Refinement declarations expose documented parameter kinds, requirements, and a
printed definition; they are not serialized source ASTs.

## Types, identity, and locations

Types are discriminated views, not `tag`/`contents` encodings:

```js
{ kind: "constructor", name: "Int8", arguments: [] }
{ kind: "constructor", name: "Optional", arguments: [
  { kind: "type", type: { kind: "constructor", name: "Int8", arguments: [] } }
] }
```

Function types use `{kind: "function", parameter, result}`; type variables use
`{kind: "variable", id}`. The argument model distinguishes types, natural indices
(encoded as decimal strings), and index variables. This representation does not
make unimplemented containers or dependent families available in 0.8.

Declaration/property/binder IDs remain stable when unrelated laws are inserted.
Origins are either `{kind: "source", span: {start, end}}` or
`{kind: "generated", declaration}`. Source ranges come from parsing, including
expressions in reused laws and refinements. Generated nodes identify their owner
instead of inventing source coordinates. Positions use one-based lines/columns;
end positions are exclusive and can include trailing parser whitespace.

## Scalar values remain lossless

| Domain | Payload after `type` |
| --- | --- |
| Integers, including logical Integer | `value`: decimal string |
| Bool | `value`: Boolean |
| Decimal | `coefficient`, `exponent`: decimal strings |
| Rational | `numerator`, `denominator`: decimal strings; reduced, denominator positive |
| Float32 / Float64 | `bits`: 8 / 16 hexadecimal digits in IEEE bit order |
| Complex64 / Complex128 | `real`, `imaginary`: tagged component scalars |
| Char / CodePoint / CodeUnit16 | `value`: numeric unit |
| Text / CodePointText / Utf16Text / Bytes | `units`: numeric unit array |
| Symbol | `id`, `description`: strings; identity comes from the ID |
| Unit / Null / Undefined | No payload |
| Nullable / Optional | `value`: null for missing, otherwise a tagged scalar |

Do not coerce integer strings to JavaScript Number. Text uses code units or code
points as appropriate to its domain; raw surrogates never pass through JSON
strings. The enclosing type supplies the inner type of a missing presence value.

## Checking, generation, and artifacts

`check` and `expand` validate the language. `planGeneration` additionally checks
whether its input domains can be executed. For example, a well-typed empty finite
refinement can pass `check` and fail generation with an empty-domain diagnostic.
Exhausted refinement searches fail explicitly; rejected inputs do not count as
successful tests.

Requests retain `machineBits?: 32 | 64` (default 64) and partial `generation`
settings (`cases`, `maxAttempts`, `maxShrinks`, `exhaustiveLimit`). Rust joins the
seven existing targets. Artifacts retain separate `ownership` and `placement`:
generated runtime source belongs in source directories, adapters remain
user-owned, and test helpers belong in test directories. Never infer placement
from ownership or assume a fixed number of generated files. Continue using the
manifest writer to protect edited files.

All nonempty test plans now emit the portable scalar runtime. Existing Haskell
projects must include `text` and `bytestring` in the component that compiles
that source. Doctor reports the missing dependencies before generation. Build
files remain user-owned; new scaffolds already include these dependencies.

## Formatting requests and adapter references (0.9)

`GenerationRequest` accepts `minify?: boolean`, defaulting to `false`. The CLI
passes an explicit `--minify` from `generate` and `examples`. `init --minify`
also compacts newly created scaffolds and the configuration JSON; the choice is
not saved as a project setting. Existing project build files stay user-owned. Source/test placement is independent of
formatting. Compact rendering preserves mandatory newlines, indentation, token
separators, comments, and literal contents.

User-owned artifacts may include `adapterReference`, the compiler's canonical
readable scaffold. It is comparison data, not the user's implementation and not
an additional file to write. Manifest writers should hash this reference when
present, falling back to `content` for older producers. Continue hashing actual
`content` for generated-file ownership. This keeps a switch of formatting mode
from producing false adapter-update reports, while declared interface changes
still request review. Never normalize, overwrite, or hash user implementations
as the required adapter interface. Existing version-1 manifests remain readable.

Native and bundled WASM requests share this formatting behavior. CLI scaffolds,
generated sources, and tests preserve the same ownership rules in both modes.


Scoped List payload predicates use the schema-3 expression node
`{kind: "allElements", value: Expr, binder: Binder, predicate: Expr}`. The binder
is local to `predicate`; `value` is evaluated in the surrounding scope. The
predicate and result have type Bool. Visitors must handle this node alongside
`match`, including empty-list truth and short-circuit evaluation.

The Core also defines a scoped recursive payload operation:
`{kind: "allPayloads", value: Expr, predicates: PayloadPredicate[]}`, where each
`PayloadPredicate` contains a `binder: Binder` and `predicate: Expr`. Entries
correspond, in order, to the root data type's type arguments. Each binder has
that argument's type and is local only to its own predicate; sibling predicates
cannot refer to it. The scrutinee is evaluated in the surrounding scope, and
both each predicate and the whole operation have type Bool.

Traversal follows stored parameter occurrences through recursive declarations,
including nested containers and changing type arguments. It does not constrain
unrelated fixed fields that happen to have the same concrete type. Empty and
phantom occurrences are vacuously true; rejection short-circuits traversal.

Source named-payload refinements now elaborate to this discriminator, including
recursive applications. API consumers should handle it in checked Core views.
All eight Core emitters support this operation in definitions, properties and
constructor predicates.
The internal surface predicate node is type checked and lowered through
specialization and template proofs into this same Core operation. Internal
definition and constructor contracts support recursive payload proof facts. Constructor predicates are audited in order, and callback
matches/constructions participate in the constructor dependency-cycle check.
The TypeScript declarations now include both
`allElements` and `allPayloads`; exhaustive visitors should handle both.
