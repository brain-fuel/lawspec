# Compiler API migration: schema 2 → schema 3

LawSpec 0.8 uses API schema version **3**. Requests may omit `schemaVersion` or
send `3`. An explicit `2` (or any other version) receives a request diagnostic;
it is never silently reinterpreted. LawSpec specification syntax remains compatible.
The generated `index.d.ts` describes the public protocol. Internal Haskell
constructors and record fields are no longer the wire format.

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
