# Abilities, and laws kept apart from the harness

Code depends on things: a payment gateway, a clock, a store. LawSpec calls
each such dependency an *ability*. An ability names operations, the way a
signature names a function. A *handler* gives those operations meaning.

This page explains why abilities exist, the rule that keeps laws apart from
test machinery, and how generated code reaches a handler. For the syntax, see
[Abilities](../reference/language/abilities.md) and
[Handlers](../reference/language/handlers.md).

## Two planes

A test suite mixes two kinds of statement.

- **Laws** say what the program must satisfy. "Checkout captures the payment
  once." "Time never goes back."
- **Implementation details** say how the laws are tested. Which gateway to
  use: the real one, a fake, or both. How inputs are drawn. How many cases
  are enough. Tags, timeouts and reports.

LawSpec keeps these on two planes. Laws live in the spec language, with
typed primitives. The second plane, the *harness*, chooses how laws run. It
can never change what a law means.

## The rule

**A law says what must hold for every lawful handler.**

A *lawful* handler is one that satisfies its ability's laws. So a law about
checkout holds for the real gateway, for a fake, and for any handler someone
writes later, as long as that handler keeps the Gateway laws.

A law names a handler with `using` only when the handler is part of the
claim:

- `using recording Gateway` lets a law count calls: "capture is called
  once". Counting is part of what the law says.
- `using fakeGateway` lets a law rely on what the fake does: "a payment over
  the fake's limit fails".

Everything else is the harness's choice. By default, a law that uses an
ability runs once for each lawful handler the compiler knows, the native
production handler first, then each spec handler. The evidence report shows
each run as its own obligation. A [harness unit](../reference/language/harness.md)
can narrow that choice with `test with`; a variant it leaves out is still an
obligation, reported as skipped.

A harness is a separate kind of unit. It chooses how a unit's laws are tested
(which handlers, how inputs are drawn, how adequate the evidence must be, and
how the tests run), and the compiler keeps it from changing what they mean: a
harness cannot declare laws, definitions, abilities, handlers or types; its
expressions call only checked definitions; and every value its strategies draw
is checked against the input's refinements.

## Abilities replace hidden dependencies

Before abilities, a native adapter that needed a gateway called it directly.
A test could not see that call, let alone replace it. Now the adapter says
what it uses:

```lawspec fragment
charge :: Int32 -> Bool uses Gateway
```

Its native code receives a Gateway handler as its first argument. A test can
pass a fake, or record the calls the adapter makes through it.

Checked definitions may use abilities too. Their abilities are inferred:
LawSpec reads which operations a definition performs, and which functions it
calls, and works out the abilities it needs. This set is the definition's
*ability row*. The output of `lawspec check --json` shows it.

## How handlers reach the code

LawSpec compiles abilities by *evidence passing*, as described by Xie and
Leijen. The handlers in effect form a record, the *evidence*. Generated code
passes it to every definition it calls. An operation looks up its ability's
handler in that record and calls it.

Every target already passes a context to every generated definition: the
symbol context. The evidence travels in it. A law installs its handlers in
the context at the start of each case. A definition that performs `capture`
finds the Gateway handler there. Native code is different: it gets its
handlers as explicit arguments, typed by each ability's native interface.

General effect handlers can capture the rest of a computation and resume it
later, or several times. LawSpec allows only two kinds of handler:

- **Tail-resumptive** handlers answer an operation and continue at once.
  State, readers, recordings and virtual clocks are all of this kind.
- **Aborting** handlers stop the computation. The `Fail` ability's handlers
  are of this kind: `raise` aborts to the nearest `attempt`.

With this restriction no target needs continuations. A tail-resumptive
operation is an ordinary method call. An abort is the target's exception or
panic.

## Ability laws are obligations on handlers

An ability's laws hold for every lawful handler, so each handler owes them.
LawSpec turns each pair of (ability law, handler) into its own law. Evidence
then reports one obligation for each pair.

- A spec handler without state is a set of checked definitions, so the
  compiler treats the law like any law over definitions. It proves it when
  it can. Over a finite domain it evaluates every case, and a false law is a
  compile error.
- A spec handler with state, and the native handler, are property-tested by
  the generated tests.

## Typing

Ability rows follow Koka's row types. A definition's row is the least row
that covers every operation it performs and every row of what it calls.
LawSpec definitions are first order, so each definition's row is closed when
it is checked: there is no row variable left to generalize. A signature
without a body has no code to read, so it must say what it uses.

An operation's type comes from its ability. A call to it type-checks like any
call; the totality audit treats it as an opaque call whose result has the
operation's type.

## References

- Gordon Plotkin and Matija Pretnar, "Handling Algebraic Effects", Logical
  Methods in Computer Science 9(4), 2013 (first presented at ESOP 2009).
- Daan Leijen, "Koka: Programming with Row Polymorphic Effect Types", MSFP
  2014, and "Type Directed Compilation of Row-Typed Algebraic Effects", POPL
  2017.
- Ningning Xie and Daan Leijen, "Generalized Evidence Passing for Effect
  Handlers", ICFP 2021.
- The Unison language's abilities and ability handlers, which give this
  design its names.
