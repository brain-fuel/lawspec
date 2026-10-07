---
id: lawspec.reference.language.index
kind: reference
title: Language reference
---
# Language reference

A LawSpec source file declares one unit: its imports, function signatures, data
types, checked definitions, refinements and laws.

- [Syntax](syntax.md): units, declarations, comments, literals and the grammar.
- [Types and data](types-and-data.md): lists, `Maybe` and `Either`, products,
  sums and pattern matching.
- [Laws and examples](laws-and-examples.md): propositions, reusable laws,
  capabilities, examples, tables, examples in descriptions, and recorded
  values.
- [Definitions](definitions.md): checked total definitions.
- [Indexed families](indexed-families.md): data indexed by natural numbers,
  index arithmetic, and proved indices.
- [GADTs](gadts.md): constructors that refine type arguments, and type
  witnesses.
- [Flow types](flow-types.md): state parameters whose type changes with each
  call.
- [Collections](collections.md): sets, key/value maps, queues, stacks and
  deques, and the portable order of keys.
- [Asynchronous functions](async-functions.md): adapters that return each
  target's task.
- [Abilities](abilities.md): dependencies as abilities, what code uses, and
  failures.
- [Handlers](handlers.md): spec handlers, recordings, choosing handlers in a
  law, and the native interfaces.
- [Matchers](matchers.md): readable predicates over lists, text, numbers and
  data, and portable regular expressions.
- [Typed failures](failures.md): laws that expect a failure, by constructor
  and message.
- [Resources](resources.md): what a law acquires before each case and
  releases after it, and the built-in ones.
- [Built-in abilities](builtins.md): the `lawspec.*` units and their default
  handlers on every target.
- [Existing features as abilities](abilities-mapping.md): async, workflows,
  sessions, mailboxes, actors, models, scenarios and distribution, each in
  terms of abilities.
- [Time and the clock](time.md): instants, the `Clock` ability and the
  virtual clock.
- [Time in laws](temporal.md): `eventually within`, `always within`, `never
  within`, and performance budgets.
- [Randomness](randomness.md): reproducible `Random`, secure `SecureRandom`,
  and why they are apart.
- [Cryptography](cryptography.md): post-quantum key exchange and signatures,
  hashing and authenticated encryption, checked against NIST's vectors.
- [Files, environment and ports](host.md): the machine a program runs on.
- [Logs and traces](logging.md): logging, and inspecting what was logged.
- [Durations](durations.md): whole microseconds, their literals, arithmetic and
  native types.
- [Evidence and discharge](evidence-and-discharge.md): how each obligation is
  discharged.
- [Domain modeling](domain-modeling.md): wrappers and workflows.
- [Workflows](workflows.md): stages, error types, and policies such as
  retries, timeouts, rate limits, compensation and hedging.
- [Stateful models](models.md): commands checked against a reference model,
  in sequence and in parallel, collections and handles.
- [Protocols and scenarios](scenarios.md): channels between processes, proved
  free of deadlocks and races, and run on many schedules, with failures.
- [Actors and supervisors](actors.md): processes that own a state and handle
  one message at a time, checked with crashes, and supervisors that restart
  them.
- [Distribution](distribution.md): nodes, transports, the wire encoding,
  and testing over a faulty network.
- [Imports and packages](imports-and-packages.md): sharing declarations between
  units and packages.
- [Expressions and arithmetic](expressions-and-arithmetic.md): precedence,
  literals, exact arithmetic and conversions.

See also [primitives](../primitives.md), [refinements](../refinements.md) and
the [prelude](../prelude-algebra.md).

## Current limits

The following are not part of the language:

- queues, stacks and deques indexed by their size;
- binding an asynchronous adapter to an existing native function;
- several flow parameters in one function, and flow calls inside match
  branches;

See the [roadmap](../../explanation/roadmap.md) for what is planned.
