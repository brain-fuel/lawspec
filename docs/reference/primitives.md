---
id: lawspec.reference.primitives
kind: reference
title: Primitives
---
# Primitives

Every scalar type has a declared domain, checked literals, equality, property
generators and boundary cases. This page lists the scalar types. Structural
types (`List`, `Maybe`, `Either` and declared data) are described in
[types and data](language/types-and-data.md). LawSpec has no objects, pointers
or type-only constructs such as `never`.

## Scalar types

| Domain | Types | Representation and equality |
| --- | --- | --- |
| Boolean | `Bool` | `true` or `false`; distinct from integers |
| Signed integers | `Int8`, `Int16`, `Int32`, `Int64` | −2^(bits−1) through 2^(bits−1)−1 |
| Unsigned integers | `UInt8`, `UInt16`, `UInt32`, `UInt64` | 0 through 2^bits−1 |
| Machine integers | `IntSize`, `UIntSize`, `UIntPtr` | 32- or 64-bit, from the machine profile; no pointer operations |
| Abstract integers | `Integer` | Exact mathematical values, independent of storage width |
| Arbitrary integers | `BigInt`, `BigUInt` | Unbounded; `BigUInt` is non-negative |
| Natural numbers | `Natural` | Unbounded, at least zero |
| Exact fractions | `Decimal`, `Rational` | Finite coefficient × 10^exponent; reduced numerator over positive denominator |
| Floating point | `Float32`, `Float64` | IEEE binary32 and binary64; NaN differs from itself, signed zeros are equal |
| Complex | `Complex64`, `Complex128` | Two `Float32` or `Float64` components; componentwise IEEE equality |
| Characters | `Char`, `CodePoint`, `CodeUnit16` | A Unicode scalar; a code point including surrogates; any 16-bit unit |
| Sequences | `Text`, `CodePointText`, `Utf16Text`, `Bytes` | Unicode scalars; code points; UTF-16 units; octets |
| Identity | `Symbol` | Identity, independent of its description |
| Absence | `Unit`, `Null`, `Undefined` | Three distinct singleton domains |
| Presence | `Nullable a`, `Optional a` | `Null` or a present value; `Undefined` or a present value |

`Char` and `Text` exclude U+D800–U+DFFF. Code points range from 0 to 0x10FFFF,
UTF-16 units from 0 to 65535, and bytes from 0 to 255. The raw constructors
below keep units exactly, without decoding or replacement.

## Literals, constructors and helpers

Integer literals take the type of their context (a parameter, example input or
annotation), otherwise `Integer`. Decimal literals default to exact `Decimal`.
Annotate to choose: `(127 :: Int8)`, `(0.1 :: Float32)`. A literal outside its
domain is a compile error.

| Expression | Meaning |
| --- | --- |
| `true`, `false` | Boolean values |
| `decimal(123, -2)` | Exact 1.23 |
| `rational(1, 2)` | Exact 1/2 |
| `complex64(1, -2)`, `complex128(1, -2)` | Complex values at the declared precision |
| `float32Bits("7fc00000")` | A binary32 NaN |
| `float64Bits("7ff0000000000000")` | Positive binary64 infinity |
| `float32Bits("80000000")` | Negative binary32 zero |
| `char(128512)` | A supplementary Unicode scalar |
| `codePoint(55296)` | A surrogate code point |
| `codeUnit16(55296)` | A lone UTF-16 surrogate unit |
| `codePoints([55296, 128512])` | A raw code-point sequence |
| `utf16([55296])` | A raw UTF-16 sequence |
| `bytes([0, 128, 255])` | Raw octets |
| `symbol("fixture-id", "description")` | A Symbol; the same ID is the same Symbol within one example |
| `unitValue`, `null`, `undefined` | The three distinct singleton values |
| `nullable(7)`, `optional(nullable(7))` | Present states, including nested ones |
| `prelude.length x` | Length of a list or sequence (see [refinements](refinements.md#predicates)) |
| `prelude.isNaN x`, `prelude.isInfinite x`, `prelude.isFinite x` | Float classification |
| `prelude.isNegativeZero x` | Float sign bit |
| `prelude.real z`, `prelude.imag z` | Complex components |
| `prelude.isPresent x`, `prelude.presentValue x` | Presence inspection |
| `prelude.quot a b`, `prelude.rem a b` | Truncating integer division and remainder |
| `prelude.round value scale` | Round an exact value to `scale` decimal places, ties to even |
| `prelude.Int8 x`, `prelude.Float64 x`, … | Explicit numeric conversion to the named type |

For `Optional (Nullable Int8)`, the values `undefined`, `optional(null)` and
`optional(nullable(7))` are all different. Generated support types keep this
nesting, even on targets whose native null or optional types would collapse it.

## Arithmetic

```lawspec
unit example.increment
successor :: (x :: Int8) -> (result :: Integer where result == x + 1)
law `promotes instead of wrapping` is
  definition is `for all` (x :: Int8) . successor x = x + 1 end
  example `maximum input` is x = 127 expect successor x = 128 end
end
```

- Integer `+`, `-`, `*` and negation produce `Integer`.
- `Decimal` dominates integer operands; `Rational` dominates exact operands.
- Exact `/` always produces `Rational`.
- `prelude.rem a b` satisfies `a = quot a b * b + rem a b`.
- Division by zero fails when evaluated. `implies` guards short-circuit,
  including arithmetic and adapter calls.
- `Float32` operations round at binary32 and `Float64` at binary64. Mixed
  inexact operations widen to the greater precision, and to complex when needed.
- Exact and inexact values need explicit conversion. Fractional or out-of-range
  conversions to integers fail. A `Rational` converted to `Decimal` must
  terminate. Non-finite floats cannot convert to exact numbers.
- `Decimal` arithmetic is exact, independent of Python's decimal context or any
  other ambient rounding setting.

Precedence and conversions are specified in
[expressions and arithmetic](language/expressions-and-arithmetic.md).

## Target bridges

Scalars use native types where the target's type covers the whole domain, and
generated support values elsewhere:

| Target | Native types | Support values |
| --- | --- | --- |
| Python | `int`, `bool`, `str`, `bytes`, `float`, `complex`, `Decimal`, `Fraction` | `Raw`, `Presence`, `Symbol`, absence |
| JavaScript, TypeScript | `number` for small integers and floats, `bigint` for larger integers, `string`, `Uint8Array`, `symbol` | `Decimal`, `Rational`, `Complex`, `Raw`, `Presence`; `Unit` is a `void` return |
| Java, Kotlin | Signed primitives, widened unsigned primitives, `BigInteger`, `BigDecimal`, `String`, byte arrays, code points, UTF-16 units, floating primitives | `LawSpecRuntime.Value`; a `Unit` result may be native `void`/`Unit` |
| Go | Native integer widths, machine integers, floats and complex values, `math/big.Int` and `math/big.Rat` (as exported aliases), `string`, runes, byte and UTF-16 slices | `LawSpecValue` |
| Haskell | Fixed-width integers, `Integer`, `Rational`, `Float`, `Double`, `Complex`, `Char`, `Data.Text.Text`, `ByteString`, `()` | `Scalar` |
| Rust | See the [Rust guide](../how-to/targets/rust.md#native-representations) | Generated `Decimal`, `Integer`, wrappers and absence types |

Input bridges check bounds before calling native code, and result bridges
validate returned values. Text bridges reject invalid Unicode instead of
repairing it; use the raw domains to preserve arbitrary bytes or UTF-16 units.

## Generated runtime

The scalar runtime is generated source with no property-testing or assertion
dependency. It belongs in the source directory; framework-specific test helpers
belong in the test directory. Runtime files are generated-owned; adapters are
user-owned.

- Haskell projects need `text` and `bytestring` in the component that compiles
  the generated source.
- Kotlin uses the shared Java runtime, under `src/main/java` by default. Include
  that directory in the Java source set.

## Machine profiles

`machineBits` is `32` or `64` (the default), set in `lawspec.json`, a compiler
request, or with `--machine-bits`. It sets the bounds of machine-sized types for
examples, generators and bridges. Go, Haskell and Rust bind machine-sized types
to native integers and report an architecture mismatch when the host's word
size differs. Fixed-width types behave the same everywhere. See
[portable semantics and machine profiles](../explanation/portable-semantics-and-machine-profiles.md).

## Examples

The bundled [`scalars.lawspec`](../../examples/specs/scalars.lawspec),
[`scalar_catalog.lawspec`](../../examples/specs/scalar_catalog.lawspec) and
[`scalar_adapters.lawspec`](../../examples/specs/scalar_adapters.lawspec)
contain explicit cases for every scalar family.
