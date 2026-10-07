# LawSpec 0.13 implementation and acceptance

Wlaschin-style domain modeling primitives, elaborated before inference like the
0.11 indexed families, so that Core and all eight backends are unchanged.

## Scope and design

- `wrapper Name (a :: Type)* is <type> [where <predicate over value>] end`:
  a nominal single-constructor product with a refined `value` field (a checked
  constructor contract) and a `valueOf<Name>` definition. Construction is
  checked in examples, generators and native decoding (illegal states are
  unrepresentable).
- `workflow name :: A -> R is (step :: I -> O)+ end`: steps are adapter
  declarations. The step chain is type-checked (inputs match, a single error type
  for fallible `Either` steps, result shape), and the law
  `<name> composes its steps` is the railway composition of the native steps.
- Evidence gains `construction` obligations (runtime-checked).

## Evidence (2026-09-29)

- `LawSpec.DomainModel`, parser support and located diagnostics; the
  DomainModelSpec has 13 examples; `stack test` has 540.
- `examples/specs/domain_modeling.lawspec`. `tools/domain-integration.mjs` passes
  on all eight targets and rejects the invariant, railway and first-element
  mutants. The shared `tools/example-acceptance.mjs` serves both example runners.
- npm 77, embed/integrity/boundaries/API types pass. Version 0.13.0, docs and
  release notes.
