# LawSpec 0.16 implementation and acceptance

More dependent types: GADTs that refine type arguments, natural index
arithmetic with shared indices, and the core of flow typing (Wilshaw & Hutton,
*Flow Typing: A New Lens on Linearity*), which 0.19's stateful models reuse.

## Scope and design

- **Index arithmetic.** `LawSpec.IndexTerm` holds each constructor's index
  terms and guards in prefix notation (`+ f1 c1`, `>= f0 c1`). Runtimes reach
  indices forward to the target plus 16 and solve backwards over any equation.
  Subtraction adds a `>=` guard, and a shared variable adds an `==` guard, both
  checked at construction and decode. The prover treats products and powers as
  sorted uninterpreted atoms; non-linear definition claims it cannot prove move
  to `contractRuntimePostconditions` and are checked on each result.
- **GADTs.** `C.DataConstructor` carries `constructorEquations` and
  `constructorExistentials`. Inference keeps branch-local givens for rigid
  signature variables and prunes inaccessible branches; self-recursion is
  polymorphic, and specialization stops at 64 instances. Runtimes filter
  constructors by compatibility. Field-only existentials travel as trailing
  Text witness fields (`LawSpec.Witness` adds them to planned values and
  constructions before emission), and generators draw witnesses from `Bool`
  and `Int32`.
- **Flow typing.** `LawSpec.Flow` runs between domain elaboration and family
  elaboration. It turns each flow function into one returning a generated
  product indexed by the output state, checks each law clause's typestate left
  to right by inverting `v` and `v + k` patterns against lower bounds, and
  desugars calls to nested matches on the products. Definitions are desugared
  only; inference and the index prover check them.

## Limits

- One flow parameter per function; no flow calls inside match branches or
  after `&&` / `||`; flow evidence has no separate `typestate` stage (a
  typestate error is a compile error).
- Go and Rust hold existential fields as dynamic values.
- A Java adapter name that is a Java keyword is not rejected by the compiler.
- An explicit `(n :: Natural where n < k)` followed by a dependent binder draws
  `n` unbounded before filtering, which is slow.

## Evidence (2026-09-30)

- `stack test`: 612 examples, including IndexedSpec (arithmetic), GadtSpec (11)
  and FlowSpec (17).
- Acceptance on all eight targets: `indexed` (both specs, ten mutants), `gadt`
  (five mutants: plus, negate, pair, fold and the witness-dropping describe)
  and `flow` (pop, push and state mutants).
- `make docs-check`: 79 pages, 90 snippets.
