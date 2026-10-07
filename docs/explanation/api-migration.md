---
id: lawspec.explanation.api-migration
kind: explanation
title: API migration
---
# API migration

This page records how the compiler API has changed, for clients upgrading from
earlier versions. The current protocol is specified in the
[API reference](../reference/api.md).

## Schema 2 to schema 3 (0.8.0)

Schema 3 replaced serialized internal Haskell constructors with explicitly
defined wire views. Specification syntax did not change.

- Requests may omit `schemaVersion` or send `3`. An explicit `2` receives a
  diagnostic; it is never reinterpreted.
- Read `result.laws[i].examples` instead of `law.original.examples`. A binding
  is `{id, name, type, value}` instead of `[name, value]`. Values keep the
  lossless tagged scalar encoding from schema 2.
- Expected results are typed expressions inside assertions, such as
  `example.expectations[0].right.node.value`.
- Every expression is `{type, origin, text, node}`. The `typedExpressions` side
  table is gone.
- Assertions are the tree `equal` / `implies` / `all`. The `left`, `right` and
  `guards` projections on laws are removed; traverse the tree instead.
- Inputs are `{id, name, type, predicates, bounds}`. `generationPlan` and
  `inputRefinements` are replaced by these fields.
- Types are discriminated views (`constructor`, `function`, `variable`), not
  `tag`/`contents` encodings.
- Origins are `source` spans or `generated` declarations.
- Rust became a target. Artifacts gained `placement`, separate from
  `ownership`.
- All non-empty test plans emit the scalar runtime. Existing Haskell projects
  need `text` and `bytestring` in the component that compiles it.

## Structural data and definitions (0.9.0)

Still schema 3, with additions that exhaustive visitors must handle:

- `dataTypes`: named declarations with resolved constructor IDs and typed
  fields.
- `DataValue`: example values may be `{kind: "data", type, constructor,
  fields}`. Lists use `List::Nil` and `List::Cons`.
- Expression nodes `construct` and `match`, and later `allElements` and
  `allPayloads` for list and data payload refinements.
- `definitions`: checked definitions, as concrete specialized instances. Join
  calls to them by ID.
- `minify?: boolean` on generation requests.
- `adapterReference` on user-owned artifacts: hash it, rather than `content`,
  to detect interface changes independently of formatting. Existing version-1
  manifests stay readable.

## Native bindings: schema 4 (0.10.0)

- Requests with `nativeBindings` use `schemaVersion: 4`. The JavaScript API
  selects it automatically. Schema 3 remains for requests without bindings, and
  a non-empty binding configuration on schema 3 is rejected.
- `nativeBindings` has `types`, `functions`, `generators`, `rustCrate` and
  `goImports`. Unknown fields are rejected.
- Type bindings take `constructors` or a `codec` pair; generator bindings take
  an optional `stub`.
- Adopting bindings where adapters already exist requires moving the adapters
  aside first; see [ownership](ownership-and-regeneration.md#native-bindings).

## Indexed families (0.11.0)

No wire changes. Kotlin and Haskell adapters whose result is the abstract
`Integer` again return `Number` and `LS.IntegerValue`. Adapters written to
return `BigInteger` or `Integer` still compile.

## Evidence (0.12.0)

Check, expand and generation results gained an `evidence` array. Items have
`owner`, `declaration`, `stage` (`precondition` or `postcondition`), `status`
(`proved` or `runtime-checked`), `reason` and `claim`. Generated definition code
no longer re-checks proved postconditions.

## Construction evidence (0.13.0)

`evidence` items may have stage `construction`, for constructor field and
wrapper constraints, with status `runtime-checked`. The TypeScript declarations
name these records `ObligationEvidence`.

## Imports and packages (0.14.0)

Requests on schema 3 or 4 may add `dependencies`, `packages` and `package`.
When any is present, results add `packages` and `project`. Package errors use
code `package`, import errors `import`. Requests without these fields produce
the same results as before. Imported declarations need no new wire forms.

A compiler older than 0.14 ignores the fields and reports the imports it cannot
resolve.

## Evidence and discharge (0.15.0)

- `status` may now be `proved`, `exhaustively-checked`, `property-tested`,
  `runtime-checked` or `assumed` (`DischargeStatus`). Clients that compared only
  against `proved` and `runtime-checked` must handle the new values.
- New stages: `law`, `adapter`, and with bindings `binding`, `codec`,
  `generator` and `native-function`. `claim` is `null` for obligations without
  one.
- Order: laws, contracts, adapters, constructions, bindings.
- A false law over checked definitions with a finite domain is now a `refuted`
  diagnostic instead of compiling.
