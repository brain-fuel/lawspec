# Roadmap

Each minor release (0.x.0) is a roadmap milestone; everything else ships as a
patch (0.x.y). This page records what has shipped and what comes next.

## Released

| Release | Theme | Still open |
| --- | --- | --- |
| 0.12 | Proved indices: checked definitions over indexed families prove their result indices | Non-linear claims are checked at run time, not proved |
| 0.13 | Domain modelling: wrappers, constrained primitives and workflows | Workflows compose only infallible steps (see 0.18) |
| 0.14 | Imports and packages | Re-exports of imported names; several versions of one package in one build |
| 0.15 | Evidence and discharge: every obligation reports how it is checked | — |
| 0.16 | More dependent types: GADTs, index arithmetic, shared indices and the core of flow typing | Several flow parameters per function; flow calls inside match branches |
| 0.17 | Portable collections and asynchronous functions | Size-indexed queues and stacks; native bindings for asynchronous adapters |
| 0.18 | Railway-oriented workflows and resilience policies | `all` groups run their steps in turn, not concurrently |

0.16 in detail:

- [GADTs](../reference/language/gadts.md) refine type arguments per
  constructor, with polymorphic recursion and type witnesses for field-only
  existentials.
- [Index arithmetic](../reference/language/indexed-families.md): `+ - * div mod
  ^`, subtraction that never truncates, and shared indices such as perfect
  trees.
- [Flow types](../reference/language/flow-types.md): `A / A'` state parameters
  whose type changes with each call, checked left to right.

0.17 in detail:

- [Collections](../reference/language/collections.md): `Set`, `KeyVal`,
  `Queue`, `Stack` and `Deque`, with a portable total order of keys and each
  target's own native collections.
- [Asynchronous functions](../reference/language/async-functions.md): `async`
  adapters return each target's task, and the generated tests await them.

0.18 in detail:

- [Combinators](../reference/language/expressions-and-arithmetic.md) such as
  `>>=`, `<$>`, `<|>` and `??` sequence, map and recover `Either` values.
- [Workflows](../reference/language/workflows.md) are generated on every
  target from steps that may fail, with a generated or declared error type,
  `all` groups that may accumulate errors, and laws that a failed step stops
  the workflow.
- Policies on steps: retries, timeouts, rate limits, circuit breakers,
  bulkheads, caches, compensation and hedging. They run under a workflow
  runtime with a real or virtual clock.
- [Durations](../reference/language/durations.md) with literals such as
  `250ms`, exact on every target.

## Planned

### 0.19: Stateful models

State machines over the flow typing of 0.16:

- commands are flow functions over one model state;
- generated command sequences stay well-typed, because each command's typestate
  is checked as in a law;
- shrinking removes commands while keeping the sequence well-typed.

Actors, processes and supervision are a separate, later feature: long-lived
concurrent components in the style of OTP, beyond 0.17's one-shot asynchronous
calls.
