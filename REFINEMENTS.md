# Refinements and abstract integers (0.7.0)

A refinement restricts a scalar domain with a pure Boolean expression. LawSpec
checks concrete examples, generates satisfying input tuples, and checks adapter
contracts during testing. It does not prove that an adapter is correct.

## Exact integers without a storage width

`Integer` is the mathematical integer domain. Integer literals default to it;
integer addition, subtraction, multiplication, negation, quotient, and remainder
produce it. Calculations use arbitrary precision internally. `BigInt` remains
available when a concrete arbitrary-precision adapter representation is wanted.

```lawspec
unit example.increment
successor :: (x :: Int8) -> (result :: Integer where result == x + 1)
```

This signature generates contract tests without a separate law. The maximum
input, `127`, requires the value `128`. Returning a wrapped `-128` fails.
`Integer` does not assert which storage width the implementation used.

Abstract integer results accept Python `int` (excluding `bool`), JavaScript or
TypeScript `bigint` and safe integral `number` values, Java/Kotlin standard signed
integral wrappers and `BigInteger` through `Number`, and Go signed/unsigned integer
values or `big.Int` values/pointers through `any`. Floating representations are
rejected even when their current value is integral. Haskell uses `IntegerValue`:

```haskell
successor :: Int8 -> IntegerValue
successor x = integerValue (toInteger x + 1)
```

`integerValue :: Integral a => a -> IntegerValue` erases the width losslessly.
Abstract integer arguments use the target's arbitrary-precision integer type.
Concrete signatures keep their existing checked native mappings.

## Inline and named refinements

Use `where` on a quantified input, function argument, or function result:

```lawspec
`for all` (x :: Int8) (y :: Int8 where y > Int8.max - x) .
  add x y = x + y
```

A predicate can reference its own value and earlier inputs. A function result
predicate can also reference the function's named arguments. Forward value
references are errors. `Int8.min` and `Int8.max` denote representation bounds;
machine-sized bounds use the requested `machineBits` profile.

Named refinements distinguish type parameters from value parameters:

```lawspec
refinement Between
  (T :: Type) (minimum :: T) (maximum :: T)
  requires Ordered T is
  (value :: T where minimum <= value && value <= maximum)
end

refinement AdditionOverflows
  (T :: Type) (left :: T)
  requires Integer T Bounded T is
  (right :: T where left + right > T.max)
end

add :: (x :: Int8)
    -> (y :: AdditionOverflows Int8 x)
    -> (result :: Integer where result == x + y)
```

`(x :: Between Int8 1 10)` applies a refinement. Parenthesize compound arguments,
for example `Between Int8 (-10) (5 + 5)`. Later value-parameter types can use
earlier parameters. Value arguments must satisfy their declared domains,
including refinements. Substitution avoids capturing names from the call site.
Declarations can appear in any order within a unit; recursive aliases are errors.
Fixed refinements are the zero-parameter form:

```lawspec
refinement PositiveInt8 is (value :: Int8 where value > 0) end
```

Aliases preserve their underlying native representation. They can be nested in
`Nullable` and `Optional`; inner predicates are checked only for present values.
Type parameters range over the supported scalar types, including presence types.

`requires Integer T` describes integer capabilities in a generic declaration.
`Integer` entails `Eq` and `Ordered`. `Ordered` currently covers exact real numbers
and floats, with the existing IEEE comparisons (including NaN behavior).
`Bounded` covers fixed and machine-sized integers. Bounds refer to the underlying
integer representation, rather than a tighter interval inferred from a predicate.
Capabilities are checked on generic declarations and their specializations.

## Predicate expressions and contracts

Predicates support existing pure arithmetic, comparisons, scalar constructors,
conversions, and built-in helpers. `&&`, `||`, and `!` short-circuit; comparisons
bind more tightly than `&&`, which binds more tightly than `||`. Assertion `and`
continues to combine law conclusions. Exact/inexact mixing still needs an explicit
conversion, and floating expressions retain their declared precision.

`prelude.length` counts Unicode scalars for Text, code points for CodePointText,
UTF-16 units for Utf16Text, and octets for Bytes. `prelude.isPresent` and
`prelude.presentValue` inspect tagged presence values; guard extraction with
`isPresent` before accessing a possibly absent value.

Adapter calls are forbidden in refinements. Predicate errors such as division by
zero are reported as failures when evaluated; they are not ordinary rejection of
an input. Short-circuited branches are not evaluated by generation optimizations.

Every refined function signature creates a standalone property. Calls from other
laws also check argument preconditions, invoke the adapter once, snapshot its
result, and check postconditions. Calling a function outside its precondition is
a test failure, not a discarded example. Ordinary `implies` guards retain their
existing conditional behavior.

## Dependent generation and shrinking

A quantified law ranges over satisfying tuples. For `AdditionOverflows Int8 x`,
`x = 0` has no admissible `y`. The generator backtracks to choose another `x`;
it does not count that dead end as a passing test. Valid pairs satisfy:

```text
1 <= x <= 127
128 - x <= y <= 127
```

The generator derives integer bounds from affine comparisons and conjunctions,
seeds direct comparison values and boundaries, and checks the complete predicate.
Predicates outside that analysis use bounded sampling. Small finite base-domain
products are enumerated exhaustively, retaining only satisfying tuples.

Shrinking checks refinements again and repairs dependent later inputs when an
earlier value changes. An overflowing counterexample can shrink to `(1, 127)`;
it cannot shrink to `(0, 127)` because that pair is outside the domain.

Compiler requests and `lawspec.json` accept:

```json
{
  "generation": {
    "cases": 100,
    "maxAttempts": 10000,
    "maxShrinks": 1000,
    "exhaustiveLimit": 4096
  }
}
```

All limits are positive integers. These are the defaults for refinement properties.
`cases` counts accepted property inputs; explicit examples and boundary fixtures
are additional checks. Exhausted searches report an error with reproduction
information. Exhaustion does not prove that the mathematical domain is empty.
Statically established empty executable domains and invalid examples are rejected.

See [the bundled examples](examples/specs/refinements.lawspec) for overflow,
abstract integer arguments/results, dependent bounds, optional refinements,
floating classification, and raw-byte lengths.
