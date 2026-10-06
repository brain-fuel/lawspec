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
