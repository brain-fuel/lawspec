---
id: lawspec.reference.language.laws-and-examples
kind: reference
title: Laws and examples
---
# Laws and examples

A law states a property that must hold, gives it a name, and can pin it down with
concrete examples.

## Function signatures

A signature without a body declares an adapter: a function you implement in
each target language.

```lawspec fragment
render :: Int32 -> Text
parse  :: Text -> Int32
```

Signatures can use any scalar or structural type, mix types, and take several
curried arguments. Arguments and results can carry refinements, which makes
the signature an executable contract; see [refinements](../refinements.md).

## Propositions

A law's `definition` block holds a proposition:

| Form | Meaning |
| --- | --- |
| `` `for all` (x :: T) (y :: U) . p `` | `p` holds for every input. Later inputs may depend on earlier ones. |
| `a = b` | An assertion that two values are equal. |
| `c implies p` | `p` is checked only when the Boolean `c` is true. |
| `p and q` | Both hold. |
| `` `law name` arguments `` | Apply a reusable law. |
| A Boolean expression | The expression must be `true`. |

Quantifiers and `implies` extend over a following `and`. The semantics of
`implies`, `and` and expected results are specified in the
[prelude reference](../prelude-algebra.md).

Assertion `=` is different from Boolean `==`: `=` states a law's conclusion,
`==` computes a `Bool`.

## Reusable laws

A law with parameters is reusable. Parameters are typed functions or values, and
`requires` lists the capabilities its body needs:

```lawspec
unit guide.reusable

law `preserves length`
  (f :: List a -> List a)
is
  definition is
    `for all` (xs :: List a) . prelude.length (f xs) = prelude.length xs
  end
end

reverse :: List Int8 -> List Int8

law `reverse keeps every element` is
  definition is
    `preserves length` reverse
  end
  example `three elements` is
    xs = [1, 2, 3]
    expect reverse xs = [3, 2, 1]
  end
end
```

Applying a reusable law expands it: the compiler substitutes the arguments,
avoiding variable capture, and specializes the types. It does not treat any
function name specially. `lawspec explain` prints each expansion step and the
final property.

Arguments can be adapters, partial applications, compositions, and scalar
values such as an identity element. The [prelude](../prelude-algebra.md) defines
laws such as `left inverse`, `equivalent`, `idempotent`, `commutative` and
`distributive`.

### Capabilities

A generic law declares what its type variables must support:

| Capability | Provides |
| --- | --- |
| `Eq a` | Equality |
| `Integer a` | Integer arithmetic; entails `Eq` and `Ordered` |
| `Ordered a` | Comparisons on exact real numbers and floats (with IEEE rules) |
| `Bounded a` | `a.min` and `a.max` on fixed and machine-sized integers |

The body may use only operations its capabilities justify. When the law is
applied, the requirements are checked for the actual types. As a capability,
`Integer` means "an integer type"; as a concrete type, `Integer` is the
mathematical integers (see [primitives](../primitives.md)).

## Examples

An example binds each quantified input to a concrete value, then states one or
more expected results:

```lawspec fragment
example `zero renders as 0 and round-trips unchanged` is
  x = 0
  expect itoa x = "0"
  expect atoi (itoa x) = 0
end
```

- Bind every input of the expanded law exactly once, using the names in the
  expansion. For a reusable law these are the reusable law's input names, such
  as `x` for `equivalent`. `lawspec explain` shows them.
- Values must be literals of the input's type. Out-of-range values and
  ambiguous names are errors.
- An example needs at least one `expect`. Its expected value is a literal of
  the expression's type.

An example passes only when all its expectations and the law itself hold for
its inputs. See [expected results](../prelude-algebra.md#expected-results) for
the full semantics.

An expectation takes one of three forms:

- `expect e = literal`: `e` equals the literal;
- `expect e`: `e` is a `Bool` that holds, such as a
  [matcher](matchers.md) or `expect charge 5 fails with Declined _`;
- `expect e = recorded "name"`: `e` equals a [recorded value](#recorded-values).

## Tables

A table lists examples as rows. Each row is its own example, run and reported
on its own:

```lawspec
unit guide.tables

shippingCost :: Int32 -> Int32 -> Int32

law `shipping cost grows with weight and distance` is
  definition is
    `for all` (kilograms :: Int32 where kilograms >= 0 && kilograms <= 1000)
      (kilometres :: Int32 where kilometres >= 0 && kilometres <= 1000) .
      shippingCost kilograms kilometres >= 0
  end
  table (kilograms, kilometres, cost) is
    row 0, 0, 0
    row 1, 10, 15
    row 2, 10, 30
    expect shippingCost kilograms kilometres = cost
  end
end
```

- `table (a, b, ...) is`, then `row` lines, then `expect` lines, then `end`.
- A column on the right of an expectation's `=` holds expected values. Every
  other column binds the law's input of that name, so the columns must
  include every input.
- An expectation may use any column; expected-value columns stand for the
  row's value.
- Each value is a literal of its column's type. A row with the wrong number
  of values is an error.
- A table without `expect` checks the law alone at each row.
- A row is named after its position and values: `row 2: 1, 10, 15`. With
  several tables in one law: `table 2, row 1: ...`.

## Examples in descriptions

A law's description may hold examples, fenced with `example`. Each becomes
an example of the law, so the documentation is checked like any example:

````lawspec fragment
description is
  "Every label starts with the word parcel and the parcel's number.

  ```example
  parcel = 7
  expect label parcel = \"parcel 7\"
  ```"
end
````

- A fence holds bindings and expectations, as an example's body does.
- After `example`, a quoted name may follow: ```` ```example `seven` ````.
  Without one, the example is named `description example 1`, and so on; with
  one, `description: seven`. Evidence and test names cite the description by
  these names.
- A fenced example without `expect` checks the law alone.
- A fence that does not parse is an error naming its position in the
  description.

## Recorded values

A recorded value is stored in the project, under
`recorded/<unit>/<name>` beside `lawspec.json`. It is spec data: commit it.

```lawspec fragment
law `the first label is recorded` is
  definition is
    label 1 = recorded "first label"
  end
end

example `parcel 42` is
  parcel = 42
  expect label parcel = recorded "parcel 42"
end
```

- The value is compared by its portable rendering, which is the same on
  every target: `Shipped(7, "post")`, `[1, 2]`, `"text"`. The file holds the
  rendering and a newline.
- A missing recording fails its law with a message that says to run
  `lawspec test --update-recorded`; a different one fails with both values.
  `lawspec test --update-recorded` runs every law and records each value
  again.
- One recording holds one value, so `recorded` belongs in an example, in a
  table, or in a law without `` `for all` ``. In a table, each row records
  under `<name> row <n>`.
- A name is letters, digits, spaces, `-`, `_` and `.`, and does not start
  with `.` or a space.
- The generated tests find the folder through `LAWSPEC_RECORDED`, which
  `lawspec test` sets. Run by hand, they look for `recorded/` in the nearest
  folder, from the working one up, that holds `lawspec.json` or `recorded/`.

Recordings use the declared types, including fields inside data constructors.
Extended scalars have explicit forms:

| Value | Recorded form |
| --- | --- |
| Decimal | `125e-2` (trailing coefficient zeros removed; zero is `0e0`) |
| Rational | `rational(1, 2)` (reduced, with a positive denominator) |
| Float | `float32Bits("3fa00000")` or `float64Bits("8000000000000000")` |
| NaN | `float32NaN` or `float64NaN`, independent of payload and sign |
| Complex | `Complex64(float32Bits("3f800000"), float32Bits("40000000"))` |
| Bytes or raw text | `bytes([0, 255])`, `codePoints([55296])`, `utf16([55296])` |
| Character | `"雪"`; code points and UTF-16 code units use integers |
| Absence or presence | `()`, `null`, `undefined`, `nullable(42)`, `optional(42)` |
| Symbol | `symbol(1, "description")` |
| Handle | `Store#1` |

Float bit strings retain signed zero, infinities and finite values exactly.
Symbol identities are numbered in traversal order within each recorded value;
handles are numbered separately for each handle type. Repeated references keep
the same number. Numbering starts again for the next recording.

Before v0.22, some extended scalars used target-specific renderings. Update
those recordings once with `lawspec test --update-recorded` and review the
changed files. Text, integer, Boolean, unit, list and constructor syntax remains
the same; fields containing extended scalars use the forms above.

## Descriptions, rationales and references

```lawspec fragment
description is
  "converting an Int32 to Text with {itoa} and then back with {atoi} yields the original Int32"
end

rationale is
  "representing an Int32 as Text must not change its value"
end

references are
  "left inverse"
  "round-trip property"
end
```

These blocks document the law. The compiler API reports them as the law's
`description`, `rationale` and `references`. `{name}` refers to a function.
