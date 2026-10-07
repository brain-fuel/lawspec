---
id: lawspec.reference.language.expressions-and-arithmetic
kind: reference
title: Expressions and arithmetic
---
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
| `>=>` | Right |
| `<$>`, `<!>`, `<*>` | Left |
| `>>=` | Left |
| `<\|>`, `??` | Left |
| `\|>` | Left |
| `==`, `!=`, `<`, `<=`, `>`, `>=` | Do not chain |
| [Matchers](matchers.md): `has same items as`, `contains`, `matches`, ... | Do not chain |
| `&&` | Left |
| `\|\|` | Left |

A sign directly before a number is part of it: `f -42` applies `f` to negative
42. Write `x - 42` to subtract, and parenthesize arithmetic arguments:
`f (x - 42)`.

`&&`, `||` and `implies` short-circuit. Assertion `=` is different from Boolean
`==`; `and` combines assertions, and parentheses set the scope of a shared
guard. See [the prelude reference](../prelude-algebra.md#conjunction) for
`and` and `implies`.

## Conditionals

`if c then a else b` is `a` when `c` holds, and `b` otherwise. Only the
branch `c` selects is evaluated, and the totality audit checks each branch
knowing which way `c` went:

```lawspec fragment
definition share (total :: Int32 where total >= 0 && total <= 1000) (n :: Int32 where n >= 0 && n <= 10) :: Int32 is
  if n > 0 then prelude.quot total n else 0
end
```

The division is proved safe because it runs only when `n > 0`. Both branches
take the expression's type; each converts to it on its own. `if`, `then` and
`else` are keywords inside expressions. `prelude.select c a b` means the same.
An `if` reaches as far right as it can, so parenthesize one used as an
argument: `f (if c then a else b)`.

## Railway combinators

These operators work on `Either e a`, in laws and in checked definitions. Each
symbol also has an English name, and some combinators have only a name:

| Symbol | Name | Meaning |
| --- | --- | --- |
| `m >>= f` | `prelude.bind m f`, `prelude.then m f` | `f` applied to the success value; a failure passes through |
| `f <$> m` | `prelude.map f m` | the success value mapped by `f` |
| `g <!> m` | `prelude.mapError g m` | the error mapped by `g` |
| `m <\|> h` | `prelude.orElse m h` | on failure, the result of `h` applied to the error |
| `m ?? v` | `prelude.fallback m v`, `prelude.fromEither v m` | the success value, or `v` |
| `(f >=> g) x` | `prelude.andThen f g x` | `f x >>= g` |
| `x \|> f` | `prelude.pipe x f` | `f x` |
| `m <*> n` | `prelude.both m n` | `Right (Pair a b)` when both succeed, else the first error |
| | `prelude.ensure p e m` | the success value if `p` holds of it, else `Left e` |
| | `prelude.isLeft m`, `prelude.isRight m` | which side `m` is |
| | `prelude.select c a b` | `a` when `c` holds, else `b` |

```lawspec
unit guide.railway

type Problem is | TooSmall | TooLarge end

definition positive (x :: BigInt) :: Either Problem BigInt is
  prelude.select (x > 0) (Right x) (Left TooSmall)
end

definition small (x :: BigInt) :: Either Problem BigInt is
  prelude.select (x < 100) (Right x) (Left TooLarge)
end

definition twice (x :: BigInt) :: BigInt is x + x end

law `a failure short-circuits` is
  definition is
    `for all` (x :: BigInt) . x <= 0 implies (twice <$> (positive x >>= small)) = Left TooSmall
  end
end
```

The functions given to a combinator are named definitions or adapters,
partial applications, or compositions. The combinators are rewritten into
`match` expressions, so every target runs them as ordinary matches. The
prelude adds laws about them: `bind has a left identity`, `bind is
associative`, `map fuses` and `recovery keeps successes`.

## Literals

Literals take their type from context: a declared parameter, an example input,
or an annotation.

- An integer literal with no context has type `Integer`.
- A decimal literal with no context has type `Decimal`.
- An annotation supplies context: `(127 :: Int8)`, `(0.1 :: Float32)`.
- In a float context, a decimal token is a float directly. An explicitly
  constructed exact `Decimal` is never converted to a float implicitly.
- A literal outside its contextual domain is a compile error.
- A whole number followed by a unit, such as `250ms` or `2s`, is a
  [duration](durations.md).

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
