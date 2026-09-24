# LawSpec: Old Ideas, Modern Software

LawSpec is not trying to invent a new theory of correctness.

Its core ideas are old:

- Philosophers have long distinguished universals from particular instances.
- Mathematics expresses structures through laws.
- Algebraic specification gave software formal signatures and equations.
- Property-based testing made those laws executable through falsification.

LawSpec's contribution is to make those ideas practical across modern software stacks.

## The Thesis

> **State the law once. Check it everywhere.**

```lawspec
fn encode : i32 -> text
fn decode : text -> i32

law codec =
    round_trip decode encode
```

The same law can become:

- Java → JetCheck
- Python → Hypothesis
- Go → Rapid
- JavaScript / TypeScript → fast-check
- Haskell → Hedgehog
- Kotlin → Kotest Property

The implementation language changes.

The law does not.

## What Is Actually New?

Not round trips.

Not algebraic laws.

Not formal specification.

Not property-based testing.

The interesting part is the integration:

> **A language-independent specification of software laws, lowered into the native property-testing ecosystems developers already use.**

LawSpec can also generate the implementation boundary implied by the specification, keeping the abstract contract separate from its concrete implementations.

## The Design Principle

The implementation is not the specification.

```text
LawSpec
    │
    │ what must be true
    ▼
Java / Python / Go / ...
    │
    │ particular implementations
    ▼
JetCheck / Hypothesis / Rapid / ...
    │
    │ attempts to falsify the claim
    ▼
counterexample
```

LawSpec deliberately separates the universal claim from any particular implementation or testing framework.

## No Novelty Theater

LawSpec should not be marketed as a revolutionary new idea.

A better description is:

> **A very old idea made practical for modern software.**

Its novelty can be stated narrowly:

- **Conceptual novelty:** low.
- **Architectural novelty:** meaningful.
- **Adoption novelty:** potentially substantial.

The goal is not to invent new mathematics.

The goal is to make good mathematics cheap enough that ordinary software teams actually use it.

## Standing on Prior Work

If someone says:

> “This is just algebraic specification, Larch, OBJ, QuickCheck, contracts, or formal methods.”

The answer is:

> **Yes. Those are part of the tradition LawSpec builds on.**

The contribution is making those ideas portable into existing software projects and existing property-testing frameworks.

Prior art is not an embarrassment. It is a foundation.

## The Broader Philosophy

LawSpec asks:

> **What must be true?**

Wavelet asks:

> **What incorrect programs can the type system make impossible?**

Rice's Tax asks:

> **What correctness obligations remain, and have we actually paid them?**

Together:

> **Specify. Prove what can be proved. Account for the rest.**

Correctness is not a fashion.

The goal is to recover powerful ways of reasoning about software that became too expensive or inconvenient for ordinary engineering—and make them cheap again.
