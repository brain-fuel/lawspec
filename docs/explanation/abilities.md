---
id: lawspec.explanation.abilities
kind: explanation
title: Abilities and the harness
---
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

A definition can install a spec handler for part of its body with `handle e
with h end`. It is made afresh, installed in the context for `e`, and the
handlers it replaced come back afterwards. A handler's clauses are checked
definitions, so they may perform other abilities' operations; they find
those handlers in the same context.

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
- A spec handler with state is run by the compiler too, when the law's
  domain is finite and it calls no adapter. Each case starts the state
  afresh and threads it through the operations in order.
- The native handler is property-tested by the generated tests.
- An operation's refined result is a law too: every handler owes it.

## Built-in abilities have default handlers

Time, randomness, cryptography, files, logs: most programs need them, and
most tests need to control them. LawSpec declares them as abilities in
built-in units (see [built-in abilities](../reference/language/builtins.md)),
so the rule holds for them too: a law about code that reads the clock holds
for every lawful clock, and a law that needs control says so with `using
virtual clock`.

What a built-in ability adds is a *default handler*: the production handler
every target's runtime brings, written once per target and reviewed, so a
program need not write its own. Evidence reports it apart, as
`default-handler`, between the checks LawSpec runs itself and the code it
takes on trust: the ability's laws are property-tested on it, and the
cryptographic ones are checked against NIST's vectors besides.

The defaults are post-quantum where it matters. Key exchange is ML-KEM and
signatures ML-DSA, the standards NIST published in 2024 for a world with
quantum computers; SLH-DSA, whose security rests on a hash function alone,
is the alternative a program can bind instead.

## Seeded and secure randomness are apart

A test wants randomness it can repeat; a key wants randomness no one can.
One ability for both would let the handler that makes a test repeatable
answer the code that makes keys, and a predictable key would pass every
test. So `Random` and `SecureRandom` are separate abilities, and the types
keep them apart: `seeded random n` handles only `Random`, `SecureRandom` has
no spec handlers, and natively the two are different interfaces. Laws about
code that uses `SecureRandom` hold for every secure source, so they cannot
lean on the values it draws. See [randomness](../reference/language/randomness.md).

## Typing

Ability rows follow Koka's row types. A definition's row is the least row
that covers every operation it performs and every row of what it calls.
LawSpec definitions are first order, so each definition's row is closed when
it is checked: there is no row variable left to generalize. A signature
without a body has no code to read, so it must say what it uses.

An operation's type comes from its ability. A call to it type-checks like any
call; the totality audit treats it as an opaque call whose result has the
operation's type.

## Extension guide

The work after 0.21 builds on these points. Each new ability feature or
target should change these, and only these.

- **Built-in abilities.** A `lawspec.*` unit declares an ability and its
  spec handlers like any unit. Importers use it as their own: imports copy
  abilities and handlers (`LawSpec.Imports`), and the declaring unit keeps
  the native interface, production handler and recording
  (`AbilityNames.ownedAbilityUnits`, `ownAbilities`, `Core.findAbility`).
  Its production handler is bound in `lawspec.json` (`handlers`), or
  generated as a stub in the declaring unit's adapter module.
- **Built-in abilities with defaults.** `LawSpec.Builtins` holds the
  sources of the `lawspec.*` units with abilities, and `Compile` adds each to
  a program that imports it. Their default handlers are reviewed sources
  under `runtime/defaults/<target>/<unit>`, embedded as
  `LawSpec.DefaultSources`; `LawSpec.BuiltinDefaults` generates them into the
  unit's adapter module, naming the unit's types as the target does
  (`@@Type@@`, `@@Type/Constructor@@`), and adds the crypto vector test. A
  new built-in ability adds its source, a default handler for every target,
  and a line to `defaultHandlerReason`; a new target adds a directory of
  defaults (Go also copies them into each importing package).
- **The surface pass.** `LawSpec.Abilities.elaborateAbilities` checks
  declarations, makes each clause a checked definition, infers rows (with
  handled regions and clause rows), names each law's handlers and adds the
  ability laws and refinement laws. New checks and new law variants go here.
- **Core.** Abilities reach Core as `Perform`, `Handle` (`CatchFailure`,
  `WithHandler`), `Calls` and `Let`. Elaboration resolves operations and
  handlers (`Elaboration.performOperations`), `Core.Validate` checks rows,
  `Core.Eval` evaluates, and `Core.Total` proves. A new node changes each of
  these and `Core.children`/`mapChildren`.
- **Evidence.** `LawSpec.Discharge` answers operations at compile time:
  `specResolver` for spec handlers without state, `statefulResolver` for
  those with state. A new kind of compile-time handler goes beside them.
- **Names.** `LawSpec.AbilityNames` names every native piece: the interface
  (`interfaceName`, with a parameterized ability's types), production
  handler, spec handler, recording and Haskell record field (`fieldName`).
- **Targets.** Each target has `AbilityEmit/<Target>` (interfaces, spec
  handlers, recordings, production stubs), the `Perform` and `Handle` cases
  of its definitions emitter, the handler installs and constructions of its
  test emitter (`CoreScalarEmit` or `CoreNativeScalarEmit`), and runtime
  helpers: install, look up, `with_handlers`, `raise`, `attempt`,
  `native_failures`, the native `Fail`. A new target implements all of
  them; Rust keeps its paths in `LawSpec.RustAbilityPaths`.
- **Native bindings.** `LawSpec.NativeRequest` reads `handlers` and
  `failures`; each `<Target>NativeBinding` makes a bound handler speak the
  bound types (the handler schema in Python and JavaScript, an
  `<Ability>Bound` wrapper elsewhere) and gives a bound adapter its handlers.
- **The harness plane at run time.** A new target also implements, in its
  runtime, shared resources (`share`, released at process end), LawSpec's
  own search (`LawSpec.Search`: a per-law case function, the failure
  database's wire-encoded inputs, and the targeted climb), and `order
  random` and `parallel` with its test framework; see
  [Harness units](../reference/language/harness.md).
- **Acceptance.** The `abilities` suite covers the language on every
  target, and `handlerbindings` covers `lawspec.json`; `builtins` and
  `crypto` cover the built-in abilities and their defaults. A new feature
  adds a law and a mutant to one of them on each target.
- **Existing features as abilities.** `LawSpec.Unification` states what
  each older construct uses (`abilityRows`, shown by `check --json`); a new
  effect-like construct adds its row there and a line to
  [the mapping page](../reference/language/abilities-mapping.md). Built-in
  abilities without a declaring unit are keyed `lawspec::ability::<Name>`.
  `async f ::` and `uses Async` meet in `Parser.asyncSugar`.
- **Time in laws.** `LawSpec.Temporal` expands `eventually`, `always`,
  `never within` and `takes at most` into Clock operations, so they need no
  target code; a budget's law is restricted to Clock's production handler
  (`Abilities.measuredOn`) and reported `measured` (`Discharge.budgeted`).
- **The secure transport.** Every runtime's `Node` seals frames through a
  secure layer (handshake records, sessions, sealed data; see
  [distribution](../reference/language/distribution.md#security)). A new
  target implements the same record format and checks the handshake vector
  of `dev/handshake-vector.py`; take tokens come from the OS generator.
  Workflow runtimes read time through an installed `Clock` handler, and
  treat every clock but the default real one as virtual.

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
