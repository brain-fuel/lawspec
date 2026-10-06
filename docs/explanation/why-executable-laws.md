---
id: lawspec.explanation.why-executable-laws
kind: explanation
title: Why executable laws
---
# Why executable laws

LawSpec is not a new theory of correctness. Its core ideas are old:

- Philosophy has long distinguished universals from particular instances.
- Mathematics describes structures through laws: a monoid is anything with an
  associative operation and an identity.
- Algebraic specification gave software formal signatures and equations.
- Property-based testing made such equations executable, by trying to falsify
  them.

What LawSpec adds is the integration: a language-independent specification of
software laws, lowered into the native property-testing tools that developers
already use.

## State the law once

```lawspec
unit example.codec

encode :: Int32 -> Text
decode :: Text -> Int32

law `decoding recovers the encoded value` is
  definition is
    `left inverse` decode encode
  end
end
```

The same law becomes a JetCheck property in Java, a Hypothesis test in Python,
a fast-check property in JavaScript and TypeScript, a Rapid test in Go, a
Hedgehog property in Haskell, a Kotest property in Kotlin and a Proptest in
Rust. The implementation language changes. The law does not.

## The implementation is not the specification

A test written in one language against one implementation mixes three things:
the claim, the code under test, and the machinery that tries to refute the
claim. LawSpec keeps them apart:

```text
LawSpec specification
    │  what must be true
    ▼
Java / Python / Go / ... adapters
    │  particular implementations
    ▼
JetCheck / Hypothesis / Rapid / ...
    │  attempts to falsify the claim
    ▼
counterexample
```

The specification names the functions an implementation must provide and the
laws they must obey. The compiler generates the boundary between the two, the
adapters, so the abstract contract stays separate from every concrete
implementation. Two implementations, in two languages, are checked against the
same laws.

## Laws are reusable

Most properties are instances of a small number of shapes: round trips,
idempotence, commutativity, agreement with a reference implementation. LawSpec
names these shapes as reusable laws, so a specification says
`` `commutative` add `` rather than restating the equation. The
[prelude](../reference/prelude-algebra.md) supplies the common ones; you can
write your own, and share them between units and packages.

## Examples pin the law down

A law says what holds for every input; it cannot say what the answer is for a
particular input. Two implementations can agree with each other and both be
wrong. So laws carry examples with expected results, written by you and never
inferred from the code. Randomized tests search for counterexamples; examples
fix the known answers.

## Account for what is not proved

Testing can refute a law but not prove it. Some things can be proved, such as a
checked definition's result, or a law over a finite domain checked for every
input. Some can only be checked at runtime, and some, such as native code
LawSpec cannot see, must be taken on trust. LawSpec reports which is which for
every obligation, so you know what has been paid for and what remains. See
[evidence and discharge](evidence-and-discharge.md).

The broader aim fits in one line: specify, prove what can be proved, and
account for the rest.

## Standing on prior work

If LawSpec looks like algebraic specification, Larch, OBJ, QuickCheck, design
by contract or formal methods, that is because it is part of the same
tradition. Its novelty is narrow and practical: making these ideas cheap enough
that ordinary teams use them, inside the projects and test frameworks they
already have.
