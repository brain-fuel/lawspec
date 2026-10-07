---
id: lawspec.reference.refinements
kind: reference
title: Refinements
---
# Refinements

A refinement restricts a type with a pure Boolean predicate. LawSpec checks
concrete examples against it, generates only inputs that satisfy it, and turns
refined signatures into executable contracts. Refinements on adapters are
checked by testing; they do not prove the adapter correct. Refinements on
checked definitions are proved.

## Exact integers without a storage width

`Integer` is the mathematical integers. Integer literals default to it, and
integer `+`, `-`, `*`, negation, `prelude.quot` and `prelude.rem` produce it.
Arithmetic is arbitrary-precision. Use `BigInt` when you want an
arbitrary-precision native representation specifically.

```lawspec
unit example.increment
successor :: (x :: Int8) -> (result :: Integer where result == x + 1)
```

This signature generates contract tests with no separate law. For the maximum
input, `127`, the result must be `128`; returning a wrapped `-128` fails.
`Integer` does not say which storage width the implementation uses.

An adapter whose result is `Integer` may return:

| Target | Accepted results |
| --- | --- |
| Python | `int`, but not `bool` |
| JavaScript, TypeScript | `bigint`, or a safe integral `number` |
| Java, Kotlin | Any standard signed integral wrapper or `BigInteger`, as `Number` |
| Go | Any signed or unsigned integer, or a `big.Int` value or pointer, as `any` |
| Haskell | `IntegerValue`, built with `integerValue :: Integral a => a -> IntegerValue` |
| Rust | `Integer`, built with `.into()` from any native integer |

Floating representations are rejected even when their value is integral.
`Integer` arguments use the target's arbitrary-precision integer type.

## Inline refinements

Add `where` to a quantified input, function argument or function result:

```lawspec fragment
`for all` (x :: Int8) (y :: Int8 where y > Int8.max - x) .
  add x y = x + y
```

A predicate can refer to its own value and to earlier inputs. A result
predicate can also refer to the function's named arguments. Referring to a later
input is an error. `Int8.min` and `Int8.max` are representation bounds;
machine-sized bounds follow the `machineBits` profile.

## Named refinements

A named refinement declares type parameters and value parameters separately:

```lawspec
unit guide.overflow

refinement AdditionOverflows
  (T :: Type) (left :: T)
  requires Integer T Bounded T is
  (right :: T where left + right > T.max)
end

add :: (x :: Int8)
    -> (y :: AdditionOverflows Int8 x)
    -> (result :: Integer where result == x + y)
```

```lawspec
unit guide.between

refinement Between
  (T :: Type) (minimum :: T) (maximum :: T)
  requires Ordered T is
  (value :: T where minimum <= value && value <= maximum)
end

refinement PositiveInt8 is (value :: Int8 where value > 0) end

clamp :: (x :: Between Int8 1 10) -> PositiveInt8

law `clamped values are positive` is
  definition is
    `for all` (x :: Between Int8 1 10) (y :: Int8) (z :: Int8 where z > Int8.max - y) . clamp x > 0
  end
end
```

- Apply a refinement like a type: `(x :: Between Int8 1 10)`. Parenthesize
  compound arguments: `Between Int8 (-10) (5 + 5)`.
- Later value parameters can use earlier ones in their types. Value arguments
  must satisfy their declared domains, including refinements.
- Substitution avoids capturing names from the call site.
- Declarations can appear in any order; recursive refinements are errors.
- A refinement with no parameters, such as `PositiveInt8`, is a fixed alias.

Refinements keep their underlying native representation. They can be nested in
`Nullable` and `Optional`, where the inner predicate applies only to present
values. Type parameters range over every supported value type, including
structural types; their capabilities determine the operations available.

### Capabilities

- `Integer T` provides integer operations and entails `Eq` and `Ordered`.
- `Ordered T` covers exact real numbers and floats, with IEEE comparisons.
- `Bounded T` covers fixed and machine-sized integers. `T.min` and `T.max` are
  the representation bounds, not a tighter interval implied by a predicate.

Capabilities are checked on generic declarations and on each specialization.

## Predicates

Predicates may use pure arithmetic, comparisons, scalar constructors,
conversions, built-in helpers, and calls to checked definitions (including
generic ones, specialized to the predicate's types):

```lawspec
unit guide.nonempty

definition nonempty (xs :: List a) :: Bool is
  match xs with
    | Nil -> false
    | Cons head tail -> true
  end
end

refinement Nonempty (T :: Type) is
  (xs :: List T where nonempty xs)
end
```

- `&&`, `||` and `!` short-circuit. Comparisons bind more tightly than `&&`,
  which binds more tightly than `||`.
- Exact and inexact values still need explicit conversions, and floats keep
  their declared precision.
- `prelude.length` counts Unicode scalars for `Text`, code points for
  `CodePointText`, UTF-16 units for `Utf16Text` and octets for `Bytes`.
- `prelude.isPresent` and `prelude.presentValue` inspect `Nullable` and
  `Optional` values. Guard extraction with `isPresent`.
- Predicates cannot call adapters.

An error while evaluating a predicate, such as division by zero, is a test
failure, not a rejected input. Branches skipped by short-circuiting are never
evaluated.

The same closed definitions are used to evaluate example inputs, constant
refinement arguments, finite domains and boundaries, and they run in the
generated predicate and contract checks on every target.

## Contracts

Every refined adapter signature becomes a standalone property. In addition,
whenever a law calls a refined adapter, the generated test:

1. checks the argument preconditions, in order;
2. calls the adapter once;
3. validates its result against the declared type;
4. checks the postconditions against that same result.

Calling a function outside its precondition is a test failure, not a discarded
example. `implies` guards in laws keep their ordinary conditional meaning.

## Dependent generation and shrinking

A quantified law ranges over tuples that satisfy every predicate. For
`AdditionOverflows Int8 x`, `x = 0` has no valid `y`. The generator goes back
and chooses another `x`; it does not count the dead end as a passing test. The
valid pairs are:

```text
1 <= x <= 127
128 - x <= y <= 127
```

Integer bounds derived from linear comparisons and conjunctions drive dependent
generators; other predicates use bounded sampling. Small finite domains are
enumerated, keeping only satisfying tuples. A refinement `m x == e`, where `m` is
a linear structural measure over declared data, is solved by construction; see
[indexed families](language/indexed-families.md#generation).

Shrinking checks refinements again, and repairs later inputs when an earlier one
changes. An overflowing counterexample can shrink to `(1, 127)` but not to
`(0, 127)`, which is outside the domain.

Generation limits are set in `lawspec.json` or the compiler request; see
[configuration](configuration.md#generation). An exhausted search reports an
error with reproduction information; it does not prove that the domain is
empty. A domain that is statically empty, and an example outside its domain,
are compile errors.

See the [refinement examples](../../examples/specs/refinements.lawspec) for
overflow, abstract integers, dependent bounds, optional refinements, float
classification and byte lengths. The design is discussed in
[generation and shrinking](../explanation/generation-and-shrinking.md).

## Refined definitions

```lawspec
unit guide.refined_increment

definition increment (x :: Int8 where x < 127)
  :: (result :: Int8 where result > x)
is
  prelude.Int8 (x + 1)
end
```

The arithmetic promotes to `Integer` before the explicit conversion back to
`Int8`. The compiler proves that the precondition makes the conversion safe and
that the result exceeds `x`.

- Later parameters may depend on earlier ones. Result binders must differ from
  argument names.
- Generic definitions keep their contracts through specialization.
- Every call must satisfy its callee's preconditions.
- Contracts cannot depend cyclically on their own definitions or call adapters.
- A claim the checker cannot establish is rejected.

At runtime, every target's generated entry point validates the arguments,
checks the preconditions in order, evaluates the body, validates the result and
checks the postconditions. An invalid native call fails before any unsafe
arithmetic. Definitions are proved at compile time; adapter contracts are
instead tested, because their implementations are external.

The [refined definitions example](../../examples/specs/refined_definitions.lawspec)
covers generic reciprocals, checked narrowing and dependent bounds.

### Results of helpers

A helper's proved postcondition can be used after a call: to establish a
non-zero divisor, justify a narrowing, or satisfy the next helper's
precondition.

```lawspec
unit guide.helpers

definition nonzero (value :: Int8 where value != 0)
  :: (result :: Int8 where result != 0)
is value end

definition reciprocal (value :: Int8 where value != 0) :: Rational is
  1 / nonzero value
end
```

The checker first proves the call's preconditions (and, for recursive calls,
structural descent), and only then uses its result guarantee. Guarantees stay
within the branch or short-circuit operand where the call is evaluated. More
complex implications, such as those requiring a callee's result contract to be
unfolded, are handled conservatively and may be rejected.

## Sum payloads

`Maybe (value :: Int8 where value > 0)` admits `Nothing` and positive `Just`
payloads. `Either (value :: Int8 where value > 0) Bool` checks the bound only
for `Left`. Nested sums compose, and payload predicates may refer to earlier
inputs. Finite domains keep distinct absence and variant states.

In a total definition, a `Maybe` payload fact is available in the `Just`
branch, and an `Either` fact in its own `Left` or `Right` branch.

## List payloads

`List (value :: Int8 where value > 0)` constrains every element and admits the
empty list. Lists compose with other lists, `Maybe` and `Either`. An element
predicate can refer to an earlier input:

```lawspec
unit guide.list_payloads

law `elements exceed the earlier bound` is
  definition is `for all` (floor :: Int8)
    (xs :: List (value :: Int8 where value > floor)) .
    prelude.length xs >= 0
  end
end
```

Elements are checked in order, stopping at the first failure. In a total
definition matching `Cons first rest`, `first` satisfies the element predicate
and `rest` keeps the list predicate; a `Nil` branch knows only that the list is
empty. An element predicate never implies that a list is non-empty, and facts
about one list never transfer to another. A definition over
`List (value :: Int8 where value != 0)` can therefore divide by each head and
recurse on the tail.

See the [List refinement](../../examples/specs/list_refinements.lawspec) and
[List contract](../../examples/specs/list_contracts.lawspec) examples.

## Whole-value refinements on products

A refinement on a whole product can relate its fields:

```lawspec
unit guide.range

type Range is Range lower :: Int8 upper :: Int8 end

definition gap
  (range :: Range where match range with | Range lo hi -> hi > lo end)
  :: Rational
is
  match range with | Range lo hi -> 1 / (hi - lo) end
end
```

The field relation justifies the non-zero denominator within that branch only.

## Named data payloads

A product or sum can receive refined type arguments. The predicate applies
wherever that parameter is stored, including recursive types, list elements and
`Maybe`/`Either` payloads:

```lawspec
unit example.positive_pair

type Pair (a :: Type) (b :: Type) is
  Pair first :: a second :: b
end

refinement Positive is (value :: Int8 where value > 0) end

definition reciprocal (pair :: Pair Positive Bool) :: Rational is
  match pair with
    | Pair first second -> 1 / first
  end
end

law `half` is
  definition is
    `for all` (pair :: Pair Positive Bool) . reciprocal pair > 0
  end
  example `two` is
    pair = Pair 2 false
    expect reciprocal pair = rational(1, 2)
  end
end
```

The native representation stays `Pair Int8 Bool`; the refinement adds no wrapper
type. Generators, examples, adapter contracts and definition entry points all
check the predicate, and proofs can use it.

- Free names in a type argument keep the scope where the argument was written.
  In `Pair Int8 (n :: Int8 where n > first)`, `first` is an earlier outer input,
  not the constructor field of the same name.
- Recursive payloads such as `Tree Positive` follow stored parameter positions,
  including mutual recursion and changing arguments such as `Nest (List a)`.
- A fixed `Int8` field is not constrained just because another parameter is
  instantiated as `Int8`.
- Empty and phantom storage satisfies the predicate without evaluating it.

See the [recursive refinement example](../../examples/specs/recursive_refinements.lawspec).

## Constructor field contracts

A field can be refined directly, and may refer to earlier fields:

```lawspec
unit guide.gap

type Gap is
  Gap first :: Int8 second :: (n :: Int8 where n > first)
end

definition inverseGap (gap :: Gap) :: Rational is
  match gap with | Gap x y -> 1 / (y - x) end
end
```

Construction in a total definition must prove the field predicates; matching
makes them available in the branch. Example inputs and expected values are
checked too. Every target enforces field contracts in its generated runtime
checks and native generators. The constraints appear in the evidence as
`construction` obligations.

Test planning filters finite constructor domains through their field
predicates, and searches combinations of field boundaries and contract literals
for larger domains. The searches have finite budgets. Exhausting one reports
that no witness was found; it never declares the domain empty.

## Target generation limits

Each framework applies the limits in its own way:

| Target | Refinement filtering |
| --- | --- |
| Java | JetCheck `suchThat`, at most the smaller of `maxAttempts` and 100 attempts per filter; one JetCheck session per constructor-contract case |
| Kotlin | Bounded sampling up to `maxAttempts`, keeping Kotest shrink trees |
| Go | Rapid filtering, at most the smaller of `maxAttempts` and Rapid's five attempts; structural minimization uses `-rapid.shrinktime` |
| Haskell | Hedgehog: `cases` as test limit, `maxAttempts` as discard limit, `maxShrinks` as shrink limit |
| JavaScript, TypeScript | fast-check preconditions; whole-value retries bounded by `maxAttempts` |
| Rust | Proptest; `maxAttempts` bounds local and global rejection |
| Python | Hypothesis strategies |

On every target, an error while evaluating a predicate fails the property
instead of rejecting the candidate. Sampled witnesses can limit shrinking, so
the reported counterexample is not guaranteed to be the smallest.
