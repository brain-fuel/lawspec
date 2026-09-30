# Types and data

LawSpec types are scalars, the built-in containers, and data types you declare.
The scalar catalog (integers, exact and floating numbers, text, bytes, Symbols
and absence) is in [primitives](../primitives.md).

## Lists

`List a` is an ordered, finite sequence of values of one type. Lists nest and
keep duplicates. Literals use brackets; their element type comes from the
surrounding signature, quantifier or annotation. An empty list with no such
context needs an annotation, such as `([] :: List Int8)`.

```lawspec
unit guide.lists

reverse :: List Int32 -> List Int32

law `reverse preserves length` is
  definition is
    `for all` (xs :: List Int32) .
      prelude.length (reverse xs) = prelude.length xs
  end
  example `duplicates count separately` is
    xs = [3, 1, 3]
    expect prelude.length xs = 3
    expect reverse xs = [3, 1, 3]
  end
end
```

`prelude.length` returns an exact integer. Two lists are equal when they have
the same length and equal elements in order. Element equality keeps the scalar
rules: NaN differs from itself, signed zeros are equal, and Symbols compare by
identity. Generic list equality requires `Eq a`.

The [collections example](../../../examples/specs/collections.lawspec) checks
reverse involution, sorting idempotence, sortedness, length and permutation
preservation. Its `sorted` and `permutation` functions are adapters the user
supplies, not built-in helpers.

## Maybe and Either

`Maybe a` has constructors `Nothing` and `Just value`. `Either a b` has
constructors `Left value` and `Right value`.

```lawspec
unit guide.presence

echo :: Maybe (Either Int8 Bool) -> Maybe (Either Int8 Bool)

law `preserve every alternative` is
  definition is `for all` (x :: Maybe (Either Int8 Bool)) . echo x = x end
  example `absent` is x = Nothing expect echo x = Nothing end
  example `left integer` is x = Just (Left 127) expect echo x = Just (Left 127) end
  example `right boolean` is x = Just (Right false) expect echo x = Just (Right false) end
end
```

These are algebraic sums. They are separate from the interoperability types
`Nullable a` and `Optional a` (see [primitives](../primitives.md#literals-constructors-and-helpers)).
For `Maybe (Maybe Bool)`, the values `Nothing`, `Just Nothing` and
`Just (Just false)` are all distinct. A constructor application used as an
argument needs parentheses, as in `Just (Left 127)`.

## Products and sums

A `type` declaration names its constructors and each constructor's fields. One
constructor makes a product; several make a sum. Type parameters are declared
explicitly with `:: Type`.

```lawspec
unit guide.trees

type Pair (a :: Type) (b :: Type) is
  Pair
    first :: a
    second :: b
end

type Tree (a :: Type) is
  Leaf value :: a
  Branch children :: List (Tree a)
end

definition rebuild (tree :: Tree a) :: Tree a is
  match tree with
    | Leaf value -> Leaf value
    | Branch children -> Branch children
  end
end

law `preserve the constructor and its fields` is
  definition is `for all` (tree :: Tree Int8) . rebuild tree = tree end
  example `nested branches` is
    tree = Branch [Leaf 127, Branch [], Leaf -128]
    expect rebuild tree = Branch [Leaf 127, Branch [], Leaf -128]
  end
end
```

Constructors take their fields in declaration order. Constructors may be
prefixed with `|`. Recursive declarations must be strictly positive.
Constructors may also determine natural-number indices; see
[indexed families](indexed-families.md).

## Pattern matching

`match` evaluates its scrutinee once. Each branch names a constructor and binds
its fields, in order, for the branch only. A match must be exhaustive and cannot
repeat a constructor. Lists match with `Nil` and `Cons head tail`; `Maybe` and
`Either` use their constructors.

## Equality

Equality is structural and type-directed, including named fields and nested
containers. It keeps the scalar rules at every level.

## Native representations

Each target represents declared types natively, keeping their names and type
parameters. Generated schemas and checked codecs support those types at
runtime. See the [target guides](../../how-to/targets/index.md). In Haskell,
for example, `Text` is `Data.Text.Text` while `List Char` is `[Char]`: these
are different LawSpec types even when they hold the same characters.

## Generation

Generated tests compose the target framework's generators and shrinkers.
Recursive values have a size budget: each constructor reserves enough of it for
its fields before sharing out the rest. Boundary cases include empty and
singleton lists and constructor-specific values. Small finite domains are
enumerated.

A type with no constructors cannot supply a generated argument, but containers
such as `List Empty` and `Maybe Empty` are still inhabited. An empty or
unreachable input domain never makes a property pass. See
[generation and shrinking](../../explanation/generation-and-shrinking.md).

## Refined data

Refinements can inspect whole products and sums with exhaustive matches, and
can constrain list elements, `Maybe` and `Either` payloads, type arguments of
named types, and individual constructor fields. See
[refinements](../refinements.md#named-data-payloads).
