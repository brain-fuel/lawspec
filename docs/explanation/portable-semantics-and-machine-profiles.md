---
id: lawspec.explanation.portable-semantics-and-machine-profiles
kind: explanation
title: Portable semantics and machine profiles
---
# Portable semantics and machine profiles

A law must mean the same thing on every target. That rules out borrowing any one
language's arithmetic: Java's `int` wraps, Python's `int` does not, JavaScript
numbers are doubles, and a Go `int` is 32 or 64 bits depending on the machine.
LawSpec defines its own arithmetic and checks every native value against it. ref:DEC-portable-exact-arithmetic

## Exact arithmetic

Integer arithmetic in LawSpec is exact. `x + 1` for the largest `Int8` is `128`,
an `Integer`, not a wrapped `-128`. Exact division returns a `Rational`, and
`Decimal` arithmetic ignores any ambient rounding context. Floating-point
values follow IEEE rules at their declared precision.

This lets a law state the mathematical truth, and makes implementations
answerable to it:

```lawspec
unit example.increment
successor :: (x :: Int8) -> (result :: Integer where result == x + 1)
```

An adapter that computes in `Int8` and wraps fails the contract at `127`. An
adapter that widens first passes. The specification does not say how wide the
implementation's arithmetic must be; it says what the answer is.

The same idea protects algebraic laws. Modular arithmetic satisfies
commutativity and associativity, so a wrapping `add` would pass them on random
inputs. The bundled algebra examples therefore use `Integer` values with
expected results beyond machine bounds, so wrapping implementations fail.

## Abstract integers

`Integer` as a result type means "the exact integer, in whatever
representation". It is the top of each target's integral tower: a Kotlin adapter
may return `Int`, `Long` or `BigInteger`; a Python adapter any `int`; a Haskell
adapter any `Integral` through `integerValue`. The bridge rejects non-integral
values, such as a `Double` that happens to hold a whole number, and checks the
logical value. Keeping `Integer` abstract at native boundaries leaves the
storage decision with the implementation. ref:DEC-abstract-integer-at-boundaries

## Checked conversions

Moving an exact value into a bounded type is always checked. Passing
`x + 1` to an `Int8` adapter parameter fails if the value does not fit; it never
wraps, truncates a fraction or silently loses precision. Every adapter result is
validated against its declared domain before it is used. Text bridges reject
invalid Unicode instead of repairing it.

## Why machine width is explicit

`IntSize`, `UIntSize` and `UIntPtr` model machine-sized integers. Their range
depends on the platform, so a law about them is ambiguous unless the platform is
named. LawSpec makes it explicit: `machineBits` is 32 or 64, 64 by default, and
it sets the range for literals, examples, generators, boundaries and bridges. ref:DEC-explicit-machine-profile

The profile is a property of the specification, not of the computer running
the compiler. A 64-bit laptop can generate and reason about tests for a 32-bit
target. On targets that bind machine-sized types to native machine integers (Go,
Haskell and Rust), the generated bridges check at runtime that the executing
architecture matches the profile, and report a mismatch rather than silently
testing a different range. Other targets represent machine-sized values
portably and enforce the profile's range.

Fixed-width types such as `Int32` mean the same on every platform, and are
unaffected by the profile.

## Equality

Equality is also defined once. NaN differs from itself and signed zeros are
equal, including inside lists and data types. Symbols compare by identity, not
by description. Structural values compare field by field. Generated code
implements these rules directly instead of relying on each language's
`equals`, `==` or derived equality, whose rules differ. ref:DEC-portable-exact-arithmetic
