# Compiler API migration: schema 1 → schema 2

LawSpec 0.7.0 responses include `schemaVersion: 2`. Requests may omit the version
or explicitly send `schemaVersion: 2`; unsupported versions receive a request
diagnostic. Existing specification source remains compatible. Consumers of the
JSON AST must migrate together with the compiler.

## Scalar values

Example bindings and expected values are uniformly tagged. Do not coerce every
numeric value to JavaScript Number.

```js
// Previously: ["x", 42]
// Now:
["x", { type: "Int32", value: "42" }]

// Lossless unsigned 64-bit example:
{ type: "UInt64", value: "18446744073709551615" }
```

| Domain | Payload after `type` |
| --- | --- |
| All integers | `value`: decimal string |
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

Text is also encoded as units, making the scalar schema uniform. Raw surrogate
code points never travel through JSON strings. The enclosing input type supplies
the inner type of a missing presence value.

`Expr.Number.contents` is now a decimal **string**. New expression nodes are
`DecimalNumber` (coefficient/exponent strings), `ScalarLit`, `Binary`, `Unary`, and `Annotate`. `Type.Applied` represents Nullable
and Optional. Expanded laws include `typedExpressions`, with operation operand
and result types plus an explicit `requiredConversion` for checked adapter bridges. Assertion trees remain authoritative;
`left`, `right`, and `guards` remain compatibility projections.

## Profiles and artifacts

Requests accept `machineBits?: 32 | 64`, defaulting to 64. Successful responses
include the selected `machineBits`. A profile controls language domains, not the
architecture of the WASM compiler itself.

Artifacts now include `placement: "source" | "test"` independently of
`ownership: "user" | "generated"`. A generated runtime belongs in a source
directory. Do not infer its placement from generated ownership. Continue using
the manifest writer to protect edited generated files and preserve user adapters.

The generated `index.d.ts` declares the complete discriminated unions. CLI
`explain` prints the new scalar values without converting large integers to
floating point. Native and WASM dispatch expose the same schema.


## Refinements in the unreleased 0.7.0 schema

API v2 also carries parameterized refinements and executable contracts. `Integer`
is a logical integer scalar tag whose `value` is a decimal string. Default integer
literals and promoted integer operations now have logical type `Integer`; explicit
`BigInt` declarations retain their native mappings. Both tags preserve exact values.

`Law.requirements` contains `Capability` nodes (`Eq`, `Integer`, `Ordered`,
`Bounded`) with their target types. Types add `Refined`, `RefinementApp`,
`Qualified`, and `CheckedType` nodes. Refinement arguments explicitly distinguish
`TypeArgument` from `ValueArgument`; declaration parameter kind `Type` is not a
runtime scalar. Expressions add `TypeBound` and logical operators.

Responses expose unit-owned `refinements` and `contracts`. Each expanded property
has `propertyKind` (`law` or `contract`), `generation` settings, and a
`generationPlan`. Inputs retain their underlying `inputType` and carry separate
`inputRefinements`. Domain plans include derived comparison bounds; the complete
predicate remains authoritative. Refinements must not be interpreted as implication
guards or as permission to count rejected inputs as successful checks.

Requests accept partial `generation` settings (`cases`, `maxAttempts`,
`maxShrinks`, `exhaustiveLimit`). Project configuration accepts the same object.
Generated TypeScript declarations define the complete wire shapes. These additions
are included in schema v2 before its release; schema v1 remains unsupported.
