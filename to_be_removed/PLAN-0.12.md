# LawSpec 0.12 implementation and acceptance

Proof-producing dependent layer. 0.11 checks every index claim at test time,
through refinements, contracts and index-directed generation. 0.12 decides which
of those claims the compiler can prove, records the proofs as evidence, and keeps
runtime checks only for the remainder. See [the roadmap](LANGUAGE.md#roadmap).

## Scope

- Classify index equalities from signatures, contracts, constructor equations and
  quantifiers as statically dischargeable or runtime-checked.
- Normalize and solve decidable `Natural` arithmetic, starting with the linear
  sums 0.11 accepts: constants, variables and `+`.
- Record proof evidence explicitly in Core, alongside the existing definition
  refinement proofs (`LawSpec.Core.RefinementProof`, `LawSpec.Core.Totality`).
- Distinguish proven obligations from runtime-checked contracts in the plan, the
  API and generated metadata. This lays the groundwork for 0.15 statuses.
- Possibly let checked definitions transport or refine indices, including
  definitions whose results are indexed families. Today these would require
  proofs the compiler cannot produce.
- Evaluate sibling index equalities (perfect trees) and GADTs that refine type
  arguments. Implement only if the evidence model covers them.

Preserve 0.11 semantics: an unproven claim remains a runtime-checked contract,
and generation stays index-directed.

## Acceptance

- Compiler: solver unit tests, evidence in elaborated Core, proven versus checked
  classification, diagnostics for unprovable claims that users mark as required.
- Native/WASM parity; all eight targets keep executing the indexed example and
  its mutants; proven obligations produce no redundant runtime checks.
- Documentation: LANGUAGE.md, REFINEMENTS.md, release notes, API migration if
  the plan wire format changes.

## Implementation evidence

(Record checkpoints here as work proceeds.)

### Checkpoint (2026-09-29)

- Prover: call congruence (pure definition calls as linear atoms), one-step
  unfolding of single-argument matching definitions on known constructors
  (recursively expanded, and also applied to recursive-call guarantees), and
  non-negative natural measures. Proves single/push/concat/copy and tree
  flattening; rejects five wrong-index definitions.
- Evidence: LawSpec.Core.Evidence classifies each contract obligation as
  proved or runtime-checked. It is reported in API `evidence` and the
  `lawspec check` summary. The six definition emitters omit proved
  postconditions.
- The indexed example gains proved concatV/flattenV as reference models. The
  eight-target acceptance passes; `stack test` has 527 examples, npm 77,
  integrity/boundaries/embed pass. Version 0.12.0, docs and release notes.

Released as 0.12.0 (5ada92d, tag v0.12.0). Continued in PLAN-0.13.md.
