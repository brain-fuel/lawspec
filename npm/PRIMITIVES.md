# LawSpec scalar reference (0.7.0)

A scalar has a declared domain, checked literals, equality, property inputs, and
boundary fixtures. General collections, objects, pointers, and type-only constructs
such as `never` are outside this release.

| Domain | Types | Representation and equality |
| --- | --- | --- |
| Boolean | `Bool` | `true` or `false`; distinct from integers |
| Signed integers | `Int8`, `Int16`, `Int32`, `Int64` | −2^(bits−1) through 2^(bits−1)−1 |
| Unsigned integers | `UInt8`, `UInt16`, `UInt32`, `UInt64` | 0 through 2^bits−1 |
| Machine integers | `IntSize`, `UIntSize`, `UIntPtr` | Explicit 32- or 64-bit profile; no pointer operations |
| Abstract integers | `Integer` | Exact mathematical values, independent of storage width |
| Arbitrary integers | `BigInt`, `BigUInt` | Unbounded integer; BigUInt is nonnegative |
| Exact fractions | `Decimal`, `Rational` | Finite coefficient × 10^exponent; reduced numerator / positive denominator |
| Floating point | `Float32`, `Float64` | IEEE binary32 / binary64; NaN differs from itself, signed zeros compare equal |
| Complex | `Complex64`, `Complex128` | Two Float32 / Float64 components; componentwise IEEE equality |
| Characters | `Char`, `CodePoint`, `CodeUnit16` | Unicode scalar; code point including surrogates; arbitrary 16-bit unit |
| Sequences | `Text`, `CodePointText`, `Utf16Text`, `Bytes` | Unicode scalars; code points; UTF-16 units; octets |
| Identity | `Symbol` | Identity, independent of description |
| Absence | `Unit`, `Null`, `Undefined` | Three distinct singleton domains |
| Presence | `Nullable a`, `Optional a` | Null or a present scalar; Undefined or a present scalar |

`Char` and `Text` exclude U+D800–U+DFFF. Code points range from 0 through
0x10FFFF. UTF-16 units range from 0 through 65535. Bytes range from 0 through
255. Raw constructors preserve units without decoding or replacement.

## Literals and arithmetic

Integer literals inherit a declared parameter or example type, otherwise they
have type `Integer`. Decimal literals default to exact `Decimal`. An annotation
supplies context: `(127 :: Int8)`, `(0.1 :: Float32)`. Literals outside the
contextual domain are rejected during checking.

```lawspec
unit example.increment
successor :: (x :: Int8) -> (result :: Integer where result == x + 1)
law `promotes instead of wrapping` is
  definition is `for all` (x :: Int8) . successor x = x + 1 end
  example `maximum input` is x = 127 expect successor x = 128 end
end
```

Integer `+`, `-`, `*`, and negation produce `Integer`. Decimal dominates integer
operands; Rational dominates exact operands. Exact `/` always produces Rational.
`prelude.quot` truncates toward zero, and `prelude.rem a b` satisfies
`a = quot a b * b + rem a b`. Division by zero fails when evaluated. Implication
guards short-circuit, including arithmetic and adapter calls.

Float32 operations round at binary32 precision; Float64 operations use binary64.
Mixed inexact operations widen to the greater component precision and to complex
when needed. Exact and inexact variables require explicit conversion:
`prelude.Float32 x`, `prelude.Float64 x`, `prelude.Rational x`,
`prelude.Decimal x`, or `prelude.Int8 x` (and the other numeric type names).
Fractional and out-of-range conversions to integers fail. A Rational conversion
to Decimal must terminate. Nonfinite floats cannot convert to exact numbers.

`prelude.round value scale` rounds an exact value to a specified number of decimal
places using ties-to-even. Negative scales round to powers of ten. Decimal
operations use exact arithmetic, independent of Python's decimal context or other
ambient rounding settings.

Comparison operators are `<`, `<=`, `>`, `>=`, `==`, and `!=`. Numeric comparisons
follow arithmetic's exact/inexact restriction. Complex numbers are not ordered.
`=` remains a law assertion. `==` and `!=` produce Bool and also support other
scalar domains. Multiplication and division bind more tightly than addition and
subtraction. Application and composition retain their existing syntax.

An adjacent sign remains an argument, as in `f -42`. Write `x - 42` for
subtraction, or parenthesize arithmetic arguments: `f (x - 42)`.

## Constructors and helpers

| Expression | Meaning |
| --- | --- |
| `decimal(123, -2)` | Exact 1.23 |
| `rational(1, 2)` | Exact 1/2 |
| `complex64(1, -2)`, `complex128(1, -2)` | Complex components at declared precision |
| `float32Bits("7fc00000")` | A binary32 NaN |
| `float64Bits("7ff0000000000000")` | Positive binary64 infinity |
| `float32Bits("80000000")` | Negative binary32 zero |
| `char(128512)` | Supplementary Unicode scalar |
| `codePoint(55296)` | Surrogate code point |
| `codeUnit16(55296)` | Lone UTF-16 surrogate unit |
| `codePoints([55296, 128512])` | Raw code-point sequence |
| `utf16([55296])` | Raw UTF-16 sequence |
| `bytes([0, 128, 255])` | Raw octets |
| `symbol("fixture-id", "description")` | Identity shared by the same ID within an example |
| `unitValue`, `null`, `undefined` | Distinct singleton values |
| `nullable(7)`, `optional(nullable(7))` | Present states, including nested states |
| `prelude.isNaN x`, `prelude.isInfinite x`, `prelude.isFinite x` | Float classification |
| `prelude.isNegativeZero x` | Float sign-bit classification |
| `prelude.real z`, `prelude.imag z` | Complex component access |

For `Optional (Nullable Int8)`, `undefined`, `optional(null)`, and
`optional(nullable(7))` are different values. Tagged support types preserve this
nesting, including on targets whose native null/optional types would collapse it.

## Target bridges and generated runtime

Existing Int32/Text/Bool-only specifications retain their adapter signatures.
Scalar specifications use native representations where the bridge implements the
whole domain, and generated support values elsewhere:

- Python: native int, bool, str, bytes, float, complex, Decimal and Fraction;
  `Raw`, `Presence`, `Symbol`, and absence support values.
- JavaScript/TypeScript: number for small integers and floats, bigint for larger
  integers, native strings, Uint8Array bytes and symbols; Decimal, Rational, Complex, Raw and
  Presence support types. Unit is normalized from a void return.
- Java/Kotlin: native signed primitives and widened unsigned primitives,
  BigInteger, BigDecimal, strings, byte arrays, code points, UTF-16 units and floating primitives; `LawSpecRuntime.Value`
  for remaining domains. Unit-returning adapters normalize native void/Unit.
- Go: native integer widths, machine integers, floats and complex values,
  `math/big.Int` and `math/big.Rat` (exported aliases), strings, runes, byte arrays and UTF-16 arrays;
  `LawSpecValue` for remaining domains.
- Haskell: native fixed integers, Integer, Rational, Float, Double, Complex, Char, Text, ByteString and `()`;
  the `Scalar` support type for remaining domains. `Text` maps to `Data.Text.Text`,
  not Haskell’s linked-list `String` (`[Char]`). General list types such as `[Char]`
  are outside this scalar release.

Input bridges check primitive bounds before native calls. Result bridges validate
returned values. In particular, Text bridges reject invalid Unicode rather than
repairing it. Use raw domains when preserving arbitrary bytes or UTF-16 units.

The runtime sources are emitted separately from framework-specific tests. They
have no property-testing or assertion-library dependencies. Runtime files are
generated-owned **source** artifacts; adapters are user-owned source artifacts.
Custom source/test directories and generation manifests preserve that distinction.
Haskell scalar projects require the standard `bytestring` package in their library
dependencies (included by new project templates).
Kotlin uses the shared Java runtime under `src/main/java` by default; custom
projects must include the configured source directory in their Java source set.

## Machine profiles

Set `"machineBits": 32` or `64` in `lawspec.json`, the compiler request, or use
`--machine-bits 32`. The default is 64. Bounds, examples, generators, and bridges
use this profile. Go and Haskell native machine-sized bridges report an
architecture mismatch when the native word size differs. Fixed-width types remain
portable across architectures.

The bundled `scalars.lawspec`, `scalar_catalog.lawspec`, and
`scalar_adapters.lawspec` contain explicit fixtures for every scalar family.
`tools/scalar-reference.py` produces independent Fraction-based conformance
vectors; `tools/scalar-integration.mjs` executes them across the seven targets.
Set `LAWSPEC_MUTANTS=1` to also verify that incorrect adapters are detected.


Refinements, parameterized domains, abstract native integer results, and executable
function contracts are described in [REFINEMENTS.md](REFINEMENTS.md).
