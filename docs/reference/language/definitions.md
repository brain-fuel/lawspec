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
```

Parameters and the result have explicit types. The optional `requires` clause
uses the same capabilities as laws: `Eq`, `Integer`, `Ordered` and `Bounded`.
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
including the selected machine width and the non-negative range of `BigUInt`.
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
  are pure, so `if count xs <= 100 then prelude.Int32 (count xs) else 100`
  narrows safely, and so do `b.size` and `prelude.length xs` under a guard;
- that a call's result lies in its result type's range, so
  `let m = dec n in if m >= 1 then prelude.Int32 (m - 1) else 0` narrows;
- that `prelude.length` and `prelude.size` are never negative;
- that `prelude.rem a b` has `a`'s sign and is smaller than `b`: for
  `a >= 0` and `b >= 1` it lies from 0 to `b - 1`, and
  `prelude.quot a b` is below `a` when `a > 0` and `b >= 2`.

## Recursion on integers

A recursive call may make an integer argument smaller, as long as the
argument stays at or above the parameter's least value (0 for a `Natural`, the
type's least value for a bounded integer, or a guard's), or larger, as long as
it stays at or below the type's greatest value or another parameter passed on
unchanged:

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
```

Each generic definition is checked once for typing, capabilities, termination
and definedness, even if unused. Each call specializes it to concrete types;
different calls can use different types, but a recursive call must keep the
same types. An ambiguous call needs an annotation, such as
`count ([] :: List Int8)`. Unused generic definitions emit no code.

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
