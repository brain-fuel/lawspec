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

0.16 in detail:

- [GADTs](../reference/language/gadts.md) refine type arguments per
  constructor, with polymorphic recursion and type witnesses for field-only
  existentials.
- [Index arithmetic](../reference/language/indexed-families.md): `+ - * div mod
  ^`, subtraction that never truncates, and shared indices such as perfect
  trees.
- [Flow types](../reference/language/flow-types.md): `A / A'` state parameters
  whose type changes with each call, checked left to right.

## Planned

### 0.17: Portable collections

- `List`, `Set`, `KeyVal`, `Queue`, `Stack` and `Deque`. Each gets a schema,
  codecs, generators and shrinking, and a mapping to each target's native
  collection.
- Asynchronous functions: an adapter's result becomes each target's promise or
  future, and the generated tests await it.

### 0.18: Railway-oriented workflows

Typed fallible composition, building on `workflow`:

- steps that may fail, with their error types unified across a workflow;
- combinators for sequencing, mapping and recovering;
- short-circuit laws: a failed step stops the workflow with its error.

### 0.19: Stateful models

State machines over the flow typing of 0.16:

- commands are flow functions over one model state;
- generated command sequences stay well-typed, because each command's typestate
  is checked as in a law;
- shrinking removes commands while keeping the sequence well-typed.
