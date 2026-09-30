# LawSpec 0.15

## 0.15.0

### Evidence and discharge

Every obligation of a program reports how it is discharged, strongest first:

- `proved`: statically. Definition postconditions and indices, as since 0.12,
  and now laws that call only checked definitions.
- `exhaustively-checked`: every input of a finite domain, by the compiler for
  laws over checked definitions and otherwise by the generated tests. A law with
  no inputs is a single case.
- `property-tested`: generated cases, boundary cases and examples.
- `runtime-checked`: adapter contracts, definition preconditions, constructor
  constraints and native type bindings, at every native boundary.
- `assumed`: adapters, native functions, custom generators and codec hooks,
  taken on trust. Each adapter reports how many laws call it, or that none does.

`lawspec check` summarizes the obligations by status, and the new
`lawspec evidence` lists each with its claim and reason (`--json` for the API
records, and a unit or `unit::declaration` filter).

### Laws proved and refuted by the compiler

A law over checked definitions is attempted as a proof by the same exact linear
arithmetic that proves definition results, from its input refinements, with
definitions that have no preconditions unfolded into the claim. When it is not
proved and its domain is finite, the compiler evaluates every input; a
counterexample is a compile error with code `refuted`, such as
`law always positive is false for x = -128`. Specifications that compiled
before may therefore be rejected if a law over definitions is false.

The prover also handles constant factors on integer expressions (`x * 2`),
which it previously treated as non-linear, so more definition results are
proved.

### API

`evidence` items have the five statuses above and new stages: `law`,
`adapter`, and, with native bindings, `binding`, `codec`, `generator` and
`native-function`. `claim` is `null` for obligations without one. The
TypeScript API declares `ObligationEvidence` and `DischargeStatus`. See
[API migration](API-MIGRATION.md#evidence-and-discharge-015).
