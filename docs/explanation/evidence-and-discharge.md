---
id: lawspec.explanation.evidence-and-discharge
kind: explanation
title: Evidence and discharge
---
# Evidence and discharge

"The tests pass" hides a lot. A passing property test has tried some inputs and
found no counterexample. A proof has shown there is none. A contract check
catches a violation only when one happens. And some code is simply trusted.
LawSpec reports which of these applies to every obligation, instead of letting a
green test suite imply more than it shows.

## Five statuses

The statuses are ordered from strongest to weakest:

1. **Proved.** The selected proof procedure established the law in its formal
   model and assumptions. The compiler has an internal arithmetic checker;
   [the explicit Z3 host](smt-proof.md) also supports its documented nonlinear
   and quantified tasks. Native conformance and independent oracles still need
   their own evidence.
2. **Exhaustively checked.** The domain is finite, and every input was checked.
   This is as strong as a proof for that domain, but relies on evaluation
   rather than reasoning.
3. **Property tested.** Generated inputs, boundaries and examples found no
   counterexample. Confidence depends on the generators and the number of
   cases.
4. **Runtime checked.** The obligation is enforced whenever the boundary is
   crossed, such as an adapter contract or a constructor constraint. A violation
   cannot go unnoticed at that boundary, but nothing says it will not occur.
5. **Assumed / external.** Native code LawSpec cannot inspect: adapters, bound
   native functions, codec hooks and custom generators. It is taken on trust,
   although every value it produces is still validated.

## Why the compiler proves what it can

Definition admission is mandatory. Law proof and exhaustive checking run when
their verification layers are selected. With no law layers selected, laws remain
unverified and intrinsic definition checks still apply.

When a selected law calls only checked definitions, its computation is visible to
the compiler. Proving it, or evaluating it on every input of a finite domain,
costs nothing at test time and gives a stronger answer. It also moves failures
earlier: a false law over definitions on a finite domain is a compile error
(`refuted`), with the counterexample, rather than a test failure later. ref:DEC-evidence-statuses

Proved and exhaustively checked laws are still emitted as tests. Those tests
check something different: that each target's generated code for the
definitions behaves as the Core semantics says.

## Why adapters are "assumed"

An adapter is the point where LawSpec hands over to your code. Its evidence is
the laws that call it; an adapter that no law calls is reported as such,
because nothing checks it at all. Marking adapters as assumed keeps the
accounting honest: the laws about them are property tested, but the code itself
is outside what LawSpec can see.

## Using the report

- A **proved** or **exhaustively checked** law has deductive or complete finite
  evidence for the formal model. Native conformance, examples and independent
  oracles remain separate checks.
- A **property tested** law is where more examples, better generators or a
  larger `cases` setting add confidence.
- A long **assumed** list shows where your trust lies. Adding laws that call an
  adapter, or replacing it with a checked definition, moves obligations up the
  list.

The statuses, stages and commands are specified in the
[evidence reference](../reference/language/evidence-and-discharge.md).
