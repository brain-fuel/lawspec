---
id: lawspec.reference.language.definitions
kind: reference
title: Definitions
---
# Definitions

A checked definition supplies an implementation in LawSpec itself. The compiler
proves it total, generates it on every target, and can use it in refinements,
contracts and proofs.

## Declaring a definition

```lawspec
unit guide.increment_definition

function increment (x :: Int8) -> Integer
  requires Integer Int8
  is
  x + 1
end function
end unit
```

Parameters and the result have explicit types. The optional `requires` clause
uses the same capabilities as laws: `Eq`, `Integer`, `Ordered` and `Bounded`,
and `Mappable` for a [type constructor](#a-definition-over-a-type-constructor).
Requirements are checked even when the definition is unused.

Integer arithmetic keeps the mathematical result, so `increment` returns `128`
for the largest `Int8`.

## Totality

A definition body must be total. The compiler checks that:

- every match is exhaustive;
- every recursive call is on a strict structural part of an argument, or
  moves an integer argument strictly toward a bound (see below);
- every operation that could fail, such as division or narrowing, is guarded.

Calls may go to other checked definitions, including ones declared later in
the unit. Adapters cannot be called: their behavior is unknown, so they cannot
establish totality.

For exact arithmetic, the checker combines linear bounds and Boolean guards. In
`x >= 0 && 1 / (x + 1) > 0` with integer `x`, the division runs only when its
denominator is positive, so it is safe. Proofs use exact fractions, keep strict
bounds strict, and have a bounded work budget. An obligation the checker cannot
prove is rejected. IEEE float expressions never acquire exact identities such
as `x - x = 0`.

The range of every primitive integer type is available to the checker,
including the selected machine width and the non-negative range of `Whole`.
Integer comparisons keep integrality: for an `Int8` `x`,
`x < 127 && prelude.Int8 (x + 1) > x` narrows safely, because the conversion
runs only on the guarded branch. Without the guard, it is rejected, because
`127 + 1` is outside `Int8`. Range bounds alone do not prove that a `Rational`
or `Decimal` has no fractional part.

In `if c then a else b`, `a` is checked knowing `c` holds and `b` knowing it
does not, so `if n > 0 then prelude.quot total n else 0` is safe.

A product of integers with known bounds lies between the products of their
bounds. An `Int16` `x` makes `x * x` fit `Int64`, and two factors from 0 to
1000 make a product that fits `Int32`. Products whose bounds could leave the
type are rejected.

Pattern matching keeps the primitive range of each extracted field inside its
branch. An `Int8` list head still makes `head + 129` positive; that fact does
not carry over to another branch.

The checker also knows:

- what a guard says about a call, a field or a length: checked definitions
  are pure, so `if count xs <= 100 then prelude.Int32 (count xs) else 100 end if`
  narrows safely, and so do `b.size` and `prelude.length xs` under a guard;
- that a call's result lies in its result type's range, so
  `let m = dec n in if m >= 1 then prelude.Int32 (m - 1) else 0 end if` narrows;
- that `prelude.length` and `prelude.size` are never negative;
- that `prelude.rem a b` has `a`'s sign and is smaller than `b`: for
  `a >= 0` and `b >= 1` it lies from 0 to `b - 1`, and
  `prelude.quot a b` is below `a` when `a > 0` and `b >= 2`;
- what a text matcher says. `t matches regex "..."`, `t starts with p`,
  `t ends with p` and `t contains part` are facts about the same test, so a
  value of a refined type, or one inside a guard that tests it, can fill a
  field with the same refinement. A test on literal text is decided;
- what `prelude.trim`, `prelude.trimAsciiControl`, `prelude.append` and
  `prelude.utf8` give for literal text, so a wrapper applied to a literal is
  decided by its restriction: with `wrapper Written is Text where
  prelude.length (prelude.trim value) > 0`, `Written "No"` is accepted and
  `Written "  "` is refused with `constructor field refinement does not hold
  for the value given`. A value the checker cannot decide is refused with
  `could not be proved`;
- that `x in ["a", "b"]` means `x == "a" or x == "b"`, for a list written
  out in full, and that `x is within d of y` is arithmetic over exact numbers.

The checker does not reason about what a regex means. A value known to match
`[a-z]+` does not prove a field that needs `[a-z]*`. Write the same test, or
call a checked definition that makes it.

## Recursion on integers

A recursive call may make an integer argument smaller, as long as the
argument stays at or above the parameter's lower bound: 0 for `Whole`, 1 for
`Nat`, the type's minimum for a bounded integer, or a guard's bound. It may
instead make the argument larger while staying at or below the type's maximum
or another parameter passed on unchanged:

```lawspec
unit guide.integer_recursion

function countdown (n :: Whole) -> List Whole is
  if n = 0 then [] else Cons n (countdown (n - 1)) end if
end function

function evensFrom (i :: Int32) (n :: Int32) -> List Int32 is
  if i >= n || i < 0 then [] else
    (if prelude.rem i 2 = 0 then Cons i (evensFrom (prelude.Int32 (i + 1)) n)
  else evensFrom (prelude.Int32 (i + 1)) n end if) end if
end function
end unit
```

Every recursive call must move the same parameter the same way. `prelude.range`
gives the integers from one value up to another, without a definition.

## Generic definitions

Type variables in a signature are quantified implicitly:

```lawspec
unit guide.generic_definitions

function same (x :: a) (y :: a) -> Bool requires Eq a is x = y end function

function count (xs :: List a) -> Integer is
  first matching case of xs :
    when Nil then 0
    when Cons head tail then 1 + count tail
  end case
end function
end unit
```

Each generic definition is checked once for typing, capabilities, termination
and definedness, even if unused. Each call specializes it to concrete types;
different calls can use different types, but a recursive call must keep the
same types. An ambiguous call needs an annotation, such as
`count ([] :: List Int8)`. Unused generic definitions emit no code.

### A definition over a type constructor

A type variable can stand for a type constructor: `m a` is "some `m` of
`a`". `requires Mappable m` says `prelude.map` works on it. `m` can be `List`
or an `Either` with its failure type fixed, the two types `map` is defined on.

```lawspec
unit guide.mappable

function double (n :: Integer) -> Integer is n * 2 end function

function quadrupled (values :: m Integer) -> m Integer requires Mappable m is
  prelude.map double (prelude.map double values)
end function

function halved (n :: Integer) -> Either Text Integer is
  if prelude.rem n 2 = 0 then Right (prelude.quot n 2) else Left "odd" end if
end function

law "|one definition, two types| is
  definition :
    quadrupled [1, 2] = [4, 8]
    and quadrupled (halved 6) = Right 12
    and quadrupled (halved 3) = Left "odd"
  end definition
end law
end unit
```

- Each call specializes the definition, as for any generic definition: the
  generated code has one function for lists and one for the `Either`.
- The variable takes one argument, written on the same line: `m a`,
  `m Integer`, or `(m a)` inside another type.
- `Mappable` is built in. A program cannot declare its own instance, and
  `prelude.filter` takes a `List` only.
- A call must fix what `m` is. A function result, an annotated value or a
  list literal does; a bare `Right 1` leaves the failure type open.

## Refined parameters and results

Parameters and results may carry refinements. The compiler proves the body's
definedness and result claims from the preconditions, in order, and checks
every call against its callee's preconditions. See
[refined definitions](../refinements.md#refined-definitions).

## Where definitions can be used

- in laws, where they are reference models or helpers;
- in refinement predicates and adapter preconditions and postconditions (a
  predicate may call only checked definitions, never adapters);
- as ordinary native functions in your code.

The compiler uses the same definitions to check example inputs and to plan
finite cases and boundaries.

## Generated code

Definitions become generated source on every target, with checked native entry
points. They never become adapter stubs. Each entry point takes a Symbol
context first, so that fixture Symbols keep their identity within one example,
and validates its arguments and result.

| Target | Entry point for `increment` in unit `example.total` |
| --- | --- |
| Java | `lawspec.definitions.example.Total.increment(symbols, value)` |
| Kotlin | `lawspec.definitions.example.Total.increment(symbols, value)` |
| Python | `from lawspec_definitions.example import total`, then `total.increment(symbols, 127)` |
| JavaScript, TypeScript | `increment(symbols, 127)` from `lawspec_definitions/example/total` |
| Go | `LawSpecDefinitions.Increment(symbols, 127)` |
| Haskell | `increment :: LS.SymbolContext -> I.Int8 -> Either String Integer` in `LawSpecDefinitions.Example.Total` |
| Rust | `lawspec_definitions::example_total::increment(&mut context, 127)` |

The [target guides](../../how-to/targets/index.md) give the details. See
[the total-function example](../../../examples/specs/total_functions.lawspec)
for recursive list counting and structural equality.

## Recursion that must end

Every checked definition must end on every input. The compiler works this out
from the calls themselves; you write no annotation.

For each recursive call it records how each argument relates to the caller's
parameters: taken from inside a parameter's value (a field, or a name bound by
a match), so strictly smaller; the parameter passed on unchanged; or an integer
moved toward a bound, as [above](#recursion-on-integers). It then follows
every way the calls can chain back to where they started. A definition is
admitted when every such cycle keeps hold of some argument and makes it
strictly smaller. This is the size-change principle (Lee, Jones and
Ben-Amram, 2001), which Idris 2 and Agda use for the same purpose.

That admits more than "one parameter shrinks in every call":

- **Definitions that call each other.** The cycle is checked as a whole, so a
  call that only passes its argument on is fine when another call in the cycle
  makes it smaller.
- **A second argument that takes over.** The first gets smaller, or it stays
  the same and the second gets smaller. The second may grow when the first
  shrinks.
- **Arguments that change places**, as long as one of them loses something on
  each round.

```lawspec
unit guide.outline

type Item is a record{
  label :: Text,
  children :: List Item
}
end type

function itemLine (item :: Item) -> Integer is
  1 + itemLines item.children
end function

function itemLines (items :: List Item) -> Integer is
  first matching case of items:
    when Nil then 0
    when Cons head tail then itemLine head + itemLines tail
  end case
end function

law leaf is definition:
  itemLine (Item record{label = "leaf", children = []}) must be 1
end definition end law
end unit
```

`itemLine` passes on the item's children, which are inside the item.
`itemLines` passes on the head and the tail of its list. Every cycle through
the two definitions therefore makes its argument smaller.

A cycle that makes nothing smaller is rejected, and the message names it:

```text
ping: recursion could not be shown to end: no argument is kept and made
strictly smaller around the call cycle ping -> pong -> ping
```

### Stating what decreases

When no argument shrinks in a way the compiler can see, state the measure: one
or more integers that get smaller on every call back into the recursion.

```lawspec
unit guide.narrowing

function narrowing (low :: Integer) (high :: Integer) -> Integer
decreases high - low
is
  if low >= high then 0
  else if prelude.rem low 2 = 0 then 1 + narrowing (low + 1) high
  else 1 + narrowing low (high - 1) end if end if
end function

law steps is definition: narrowing 3 10 must be 7 end definition end law
end unit
```

Sometimes `low` rises and sometimes `high` falls, so neither argument moves
one way. The distance between them always shrinks.

The clause is checked, never trusted. At every recursive call the compiler
must prove, from what is known at that call, that the measure is smaller than
it was and is still at least 0. If it cannot, the definition is rejected.
The proof uses the compiler's own arithmetic reasoning, the same as for
integer recursion; it does not depend on a solver being installed.

- Several measures, separated by commas, are read in order of importance: an
  earlier one gets smaller, or it stays the same and a later one gets smaller.
- In a cycle of definitions, each states its measure, and a call is compared
  place by place: the callee's first measure against the caller's first.
- A measure may use only the definition's arguments. It is not part of the
  generated code.
- Only a `function` takes the clause. It follows `requires` and precedes `is`.

The check accepts only recursion whose arguments shrink in one of the ways
listed, or whose stated measure it can prove. A definition that ends for a reason the compiler cannot see is still
rejected. The check is the compiler's own; no solver runs and no separate
proof checker confirms it. The definitions of a cycle
must be in one unit, because units cannot import each other in a circle.
[The mutual-recursion example](../../../examples/specs/mutual_recursion.lawspec)
has more cases. ref:DEC-size-change-termination

## Native calls

A native adapter is outside the checked definition system. To call native work
from LawSpec, expose it as an ability operation and use a `procedure` declaring
that ability. A total function may call other checked total definitions.
Disabling law verification does not change these admission rules.
ref:DEC-s1j-shared-failures
