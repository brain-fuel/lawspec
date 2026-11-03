---
id: lawspec.reviews.evaluation-regressions
kind: reference
title: Evaluation regression dispositions
---
# Evaluation regression dispositions

These are local dispositions of the thirteen draft reports, not filed GitHub
issues. The original evaluation used 0.31.1 RC, Linux/WSL2, Node 22.23.4,
Go 1.26.10 and Z3 5.3.3. Rechecking uses the 0.31.2 checkout at
`9162607aefdbe35dc2e8d08ba902c102a2df07b3` plus this branch, Darwin arm64,
Node 26.8.1, Go 1.26.5 and Z3 5.1.0, with profile `1.0-rc.2`.
This does not establish Linux or Node 22 parity.
ref:DEC-evaluation-regression-categories

| Draft | Disposition and category addressed | Regression evidence |
| --- | --- | --- |
| 1. Imported Go failure type | Fix foreign reference resolution for failure types and handler factories as well as functions, types and generators. Package-local aliases preserve native error identity and wrapped-error matching. | `evaluation-categories.test.mjs`: actual Go build/test, wrapped matching failure, unrelated-error negative control, bad aliases/private identifiers, imported handler factory without adapter function bindings. |
| 2. Stateful `attempt` falsely refuted | Direct case not reproduced, but a called procedure containing the same `attempt` reproduces the false refutation on 0.31.2. Fix effect detection over all reachable definitions, rather than just the law body. Render evaluator locations without internal AST constructors. | `effectful-attempt.lawspec`, `evaluation-categories.test.mjs`. Direct and procedure-indirect cases remain planned; pure false laws still refute. |
| 3. Product-payload induction | Fix structural induction candidate selection and hypotheses through single-constructor products, including nested records and Pair. Keep solver execution separate from obligation generation and evaluator-confirmed refutation. | Three `induction-product-*.lawspec` fixtures; actual Z3 proves six positive laws and confirms three false laws through the evaluator. No timeout/OOM claim is inferred for other recursive shapes. |
| 4. Budget status | Preserve structured measurement classification when matching native results are attached, including finite domains. Export available native-check durations with their scope. | Six-target sampled/finite evidence matrix, stale/failing/missing-duration controls, actual Go CLI fast-pass/slow-fail budget execution and reported elapsed durations. **Remaining boundary:** exact operation clock readings are not exported; displayed native-check duration includes harness overhead. |
| 5. Indexed refined fields | Fix phased family elaboration: retain kind headers while field typing runs, then validate completed constructor index tables. Mandatory definition validation remains intact. | `SourceGadtRefinementsSpec`: inline/named/reordered/nested fields, 32/64-bit profiles, valid construction and invalid refined value. |
| 6. Expired law-set exemption | Share bounded/dependent quantifier domain enumeration with law-set analysis. Emit expiry warnings even for undecidable/infinite domains, independently of Z3. | `LawAnalysisSpec`: finite refined-domain refutation, dependent domains, infinite-domain planned result plus visible warning. |
| 7. Unused HCL union | Check HCL representability on the entry-rooted transitive type closure. Keep mandatory admission of all definitions. Type-only units still export/check all declared input types. | `ArtifactTargetSpec`: unused union accepted, direct/transitive reachable unions rejected, invalid unused definition rejected. |
| 8. Missing roots and init repair | Explain missing/non-directory roots without raw ENOENT; repair a declared target's scaffold without duplicating its manifest entry or replacing existing build files. Planning remains read-only. | `files.test.mjs`, `target-lifecycle.test.mjs`: Go, JavaScript, YAML, HCL, ambiguous roots and user-owned starter. |
| 9. MCP inventory/metadata | Generate package version metadata; annotate all three tools read-only; list and explain ordinary, model and history laws with their actual semantics. | Real stdio protocol tests in `mcp-inventory.test.mjs`, including no-selection evidence and invalid-definition refusal for all three tools. |
| 10. Editor type display | Retain parsed signatures before index/flow erasure and render LawSpec syntax for hover/symbol detail. | Actual WASM-backed LSP test and public signature checks for dependent indices and linear transitions. **Separate feature request:** completion remains unimplemented and is not advertised. |
| 11. Go minification | The universal "no effect" claim is not reproduced: wide declarations compact, while small/fixed-layout files may be identical. Document soft versus mandatory breaks. | Wide-declaration generated-output regression; small baseline comparison. No promise of fewer lines for every file. |
| 12. Go handler embedding | Publish the actual typed planner's eligibility and reasons, and warn during Go generation. Dynamic handlers still execute; unchecked state accessors are not invented for refined state. | Shared planner predicate/reasons, dynamic refined-handler regression and actual imported factory compilation. Typed handlers retain their existing entry points. |
| 13. Documentation drift | Update CLI synopsis, manifest-version/profile and kebab-case EDN examples, authoring profile guidance and starter ownership. Preserve historical release records. | Documentation examples and generated-file checks; lifecycle starter test. |

The reduced current syntax uses `refinement StrokeId is ... end refinement`
and indexed-constructor `where n = ...` clauses. Some original draft snippets
used older or invalid grammar; parser rejection of those snippets was not counted
as reproducing the underlying bug.

## Proof precedent and trust boundary

Why3's [induction implementation](https://github.com/AdaCore/why3/blob/master/src/transform/induction.ml)
builds constructor cases and selects recursive arguments by type identity;
its [technical manual](https://why3.org/doc/technical.html) describes algebraic
structural induction. Lean's
[inductive types and recursors](https://lean-lang.org/doc/reference/latest/The-Type-System/Inductive-Types/)
likewise distinguish constructor cases and induction hypotheses for smaller
recursive values. LawSpec extends its existing projection traversal through
single-constructor products; it does not treat arbitrary alternatives as valid
unconditional projections.

The integrated mechanism generates SMT cases, executes Z3 through the existing
host and retains solver evidence. It is not a Lean, Why3 or kernel-checked proof
backend. Z3's [recursive-function documentation](https://microsoft.github.io/z3guide/docs/logic/Recursive%20Functions/)
explains why iterative unfolding alone need not prove induction. Failed proof
attempts stay incomplete; counterexample search is a separate execution whose
model must be confirmed by LawSpec's evaluator before refutation is reported.

## Validation recorded so far

The focused native suite passes 59 examples, including direct, one-hop and
two-hop effectful procedure calls. The first WASM-backed SDK batch passes 33
checks with no skips, covering actual Go compilation, Z3, MCP and LSP. A separate
actual CLI budget run passes its fast/slow controls. Native evidence tests pass
14 checks; complete documentation manifests pass against the compiler schema.
The broader cached Go/HCL/YAML CI run is in progress; its result is not implied
by these focused checks. All review debt remains pending under the existing
pre-1.0 policy.
