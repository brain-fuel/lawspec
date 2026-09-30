# Expressions and arithmetic

## Precedence

Function application binds most tightly and associates to the left: `f x y`
means `(f x) y`. The other operators, from highest to lowest precedence:

| Operators | Associativity |
| --- | --- |
| Unary `!` and `-` | |
| Composition `.` | Right |
| `*`, `/` | Left |
| `+`, `-` | Left |
| `==`, `!=`, `<`, `<=`, `>`, `>=` | Do not chain |
| `&&` | Left |
| `\|\|` | Left |

A sign directly before a number is part of it: `f -42` applies `f` to negative
42. Write `x - 42` to subtract, and parenthesize arithmetic arguments:
`f (x - 42)`.

`&&`, `||` and `implies` short-circuit. Assertion `=` is different from Boolean
`==`; `and` combines assertions, and parentheses set the scope of a shared
guard. See [the prelude reference](../prelude-algebra.md#conjunction) for
`and` and `implies`.

## Literals

Literals take their type from context: a declared parameter, an example input,
or an annotation.

- An integer literal with no context has type `Integer`.
- A decimal literal with no context has type `Decimal`.
- An annotation supplies context: `(127 :: Int8)`, `(0.1 :: Float32)`.
- In a float context, a decimal token is a float directly. An explicitly
  constructed exact `Decimal` is never converted to a float implicitly.
- A literal outside its contextual domain is a compile error.

Annotations choose a representation. They do not add a refinement: an inline
`where` predicate in an expression annotation is rejected. Put refinements on
quantified inputs or signatures instead.

## Exact arithmetic

- Integer `+`, `-`, `*` and negation produce exact `Integer` results. They never
  wrap.
- `Decimal` dominates integer and `Decimal` combinations.
- `Rational` dominates exact combinations involving `Rational`.
- Exact `/` always returns `Rational`.
- `prelude.quot` truncates integer quotients toward zero; `prelude.rem` is the
  matching remainder, so `a = quot a b * b + rem a b`.
- Division by zero fails when it is evaluated.
- `prelude.round value scale` rounds an exact value to `scale` decimal places,
  ties to even. Negative scales round to powers of ten.

```lawspec
unit guide.arith

scale :: Int8 -> Int8

law `promotes instead of wrapping` is
  definition is
    `for all` (x :: Int8) . prelude.Int64 x * 2 = x + x
  end
  example `max` is
    x = 127
    expect x + 1 = 128
    expect prelude.quot (-7) 2 = -3
    expect prelude.rem (-7) 2 = -1
    expect 1 / 3 = rational(1, 3)
  end
end
```

## Floating point

IEEE arithmetic widens float or complex precision as needed: `Float32`
operations round at binary32, `Float64` at binary64, and mixed operations
widen to the greater precision (and to complex when needed). Equality treats
NaN as unequal to itself and signed zeros as equal. Complex numbers are not
ordered.

## Conversions

Exact and inexact values do not mix implicitly. Convert explicitly with
`prelude.<Type>`: `prelude.Float64 x`, `prelude.Rational x`,
`prelude.Decimal x`, `prelude.Int8 x`, and so on for every numeric type.

- A fractional or out-of-range conversion to an integer type fails.
- A `Rational` converted to `Decimal` must have a terminating expansion.
- Non-finite floats cannot convert to exact numbers.

Passing a computed exact value to a bounded adapter argument performs a checked
conversion. It never wraps, truncates a fraction or silently loses precision.
Adapter results are validated against their declared domain before use.

## Comparisons

`<`, `<=`, `>`, `>=`, `==` and `!=` return `Bool`. Numeric comparisons follow
the same exact/inexact rule as arithmetic. `==` and `!=` also work on other
scalar domains and on structural values.

## Bounds

`Int8.min` and `Int8.max` (and likewise for other bounded integer types) are the
representation bounds. Machine-sized bounds follow the selected `machineBits`
profile. In a generic declaration, `T.max` requires `Bounded T`.

## Helpers

The prelude provides `prelude.length`, `prelude.quot`, `prelude.rem`,
`prelude.round`, numeric conversions, float classification, complex component
access and presence inspection. See
[primitives](../primitives.md#literals-constructors-and-helpers).
