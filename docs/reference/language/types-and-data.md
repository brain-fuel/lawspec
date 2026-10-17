---
id: lawspec.reference.language.types-and-data
kind: reference
title: Types and data
---
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

law "|reverse preserves length| is
  definition :
    for all (xs :: List Int32) =>
      prelude.length (reverse xs) = prelude.length xs end
  end
  example "|duplicates count separately| :
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

The [lists example](../../../examples/specs/lists.lawspec) checks
reverse involution, sorting idempotence, sortedness, length and permutation
preservation. Its `sorted` and `permutation` functions are adapters the user
supplies, not built-in helpers.

Sets, maps, queues, stacks and deques are built in as well; see
[collections](collections.md).

## Maybe and Either

`Maybe a` has constructors `Nothing` and `Just value`. `Either a b` has
constructors `Left value` and `Right value`.

```lawspec
unit guide.presence

echo :: Maybe (Either Int8 Bool) -> Maybe (Either Int8 Bool)

law "|preserve every alternative| is
  definition : for all (x :: Maybe (Either Int8 Bool)) => echo x = x end end
  example "|absent| : x = Nothing expect echo x = Nothing end
  example "|left integer| : x = Just (Left 127) expect echo x = Just (Left 127)
  end
  example "|right boolean| : x = Just (Right false) expect echo x = Just (Right
    false) end
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

type Pair (a :: Type) (b :: Type) is a record{

  first :: a
  second :: b}
end type

type Tree (a :: Type) is one of
  Leaf  of type a
  Branch  of type List (Tree a)
end type

function rebuild (tree :: Tree a) -> Tree a is
  first matching case of tree :
    when Leaf value then Leaf value
    when Branch children then Branch children
  end case
end function

law "|preserve the constructor and its fields| is
  definition : for all (tree :: Tree Int8) => rebuild tree = tree end end
  example "|nested branches| :
    tree = Branch [Leaf 127, Branch [], Leaf -128]
    expect rebuild tree = Branch [Leaf 127, Branch [], Leaf -128]
  end
end
```

Constructors take their fields in declaration order. Constructors may be
prefixed with `|`. Recursive declarations must be strictly positive.
Constructors may also determine natural-number indices; see
[indexed families](indexed-families.md).

## Fields

A type with one constructor has fields that code reads and replaces by name:

```lawspec
unit guide.fields

type Account is a record{

  owner :: Text
  balance :: Int64}
end type

type Ledger is a record{

  account :: Account
  entries :: Int32}
end type

function rename (l :: Ledger) (name :: Text) -> Ledger is
  l with account = (l.account with owner = name), entries = 0
end function

law "|a rename reads back| is
  definition :
    for all (l :: Ledger) (name :: Text) =>
      (rename l name).account.owner = name and (rename l name).entries = 0 end
  end
end
```

- `b.f` is the field `f` of `b`. The dot touches both names; `f . g` with
  spaces still composes. A parenthesized value may be read too:
  `(rename l name).entries`.
- `b with f = v, g = w` is `b` with `f` and `g` replaced. It reaches as far
  right as it can, so parenthesize one used as an argument.
- Both need a type with one constructor; a sum is read with `match`. The
  type of `b` must be known where the field is read, from a signature or an
  annotation.
- Each is a match on the constructor, so every target runs it as a match,
  and the totality checker knows what a guard says about `b.f`.

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

A field's refinement may call a checked definition of its unit, which is
unfolded into it, so every target checks it where values are built:

```lawspec
unit example.badges

function validName (name :: Text) -> Bool is name matches regex "[a-z]+"
end function

type Badge is a record{

  label :: (v :: Text where validName v)}
end type
```

A recursive definition cannot be unfolded, and is refused there.

## Typed empty record patterns

In the canonical authoring profile, `when record{} then ...` omits every field
of the selected record. It matches empty and populated structural products and
named records. The selected value must still have a known record type; this
pattern cannot stand for a scalar, collection, multi-constructor alternative,
or unconstrained type variable. It also works inside a constructor's record payload.

Matching does not require `Eq`. The selected expression and its field
initializers retain their ordinary strict evaluation order. A failed guard
continues to the next branch, and guarded patterns alone do not establish
exhaustiveness. The [empty record pattern fixture](../../../test/fixtures/canonical-empty-record-patterns.lawspec)
contains checked examples for empty records, generic fields and nested payloads.
