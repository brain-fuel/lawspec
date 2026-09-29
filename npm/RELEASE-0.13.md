# LawSpec 0.13

## 0.13.1

A maintenance release. The language, generated code and API are unchanged from
0.13.0.

- Repository checks move from JavaScript to Haskell. `lawspec-dev boundaries` and
  `lawspec-dev integrity` replace `tools/check-boundaries.mjs` and
  `tools/build-integrity.mjs`. The integrity check now also rejects staged npm
  copies of documentation and examples that differ from their sources.
- `lawspec-acceptance` runs the bundled-example acceptance suites
  (`integration`, `algebra`, `scalar`, `refinement`, `indexed`, `domain`) in
  process. Adapters and mutants are real files under `acceptance/`, and a
  mutant that only breaks the build now fails the suite. This exposed a
  TypeScript scalar mutant that previously counted as rejected because it
  failed type-checking; it now exercises the laws. The JavaScript runners
  continue to run alongside it in CI.
- Build-file scaffolds are defined once in Haskell (`LawSpec.Scaffold`) and
  checked against the npm templates byte for byte.
- Compiler API contract tests formerly in `npm/test` run in hspec against the
  same JSON boundary that `core.wasm` exports. A new npm test checks that
  generation never rewrites build files and that regeneration is a no-op on
  every target.

## 0.13.0

### Wrappers and constrained primitives

```lawspec
wrapper UnitQuantity is Int32 where value >= 1 && value <= 1000 end
wrapper NonEmptyList (a :: Type) is List a where prelude.length value > 0 end
```

A wrapper declares a distinct nominal type with one field, `value`, and an
optional constraint. Its constructor checks the constraint, so an invalid value
cannot be constructed in an example (the compiler rejects `UnitQuantity 0`),
produced by a generator, or decoded from native code. `valueOf<Name>` unwraps a
value. Wrappers may take type parameters. They elaborate to a single-constructor
product with a refined field, so all eight targets represent them natively with
no new runtime machinery.

### Workflows and state distinctions

```lawspec
workflow placeOrder :: UnvalidatedOrder -> Either OrderError PricedOrder is
  validateOrder :: UnvalidatedOrder -> Either OrderError ValidatedOrder
  priceOrder :: ValidatedOrder -> Either OrderError PricedOrder
end
```

A workflow declares its steps as adapters and checks the pipeline: each step
must accept the previous step's state, and fallible steps must share an error
type. The workflow's result must match `Either E T` when any step can fail, or
`T` otherwise. The compiler adds the law `placeOrder composes its steps`: the
native workflow must equal the railway composition of the native steps.
Diagnostics name the step and the mismatched types, with the workflow's source
location.

### Evidence

Constructor field constraints, including wrapper constraints, appear in the
evidence as `construction` obligations with status `runtime-checked`, next to
the contract obligations introduced in 0.12. The TypeScript API declares these
records as `ObligationEvidence`; the 0.12 typing was not published.

### Examples and acceptance

`examples/specs/domain_modeling.lawspec` combines wrappers, a parameterized
`NonEmptyList`, order states and the workflow. `tools/domain-integration.mjs`
runs it on all eight targets in both machine profiles. Correct adapters pass;
mutants that break a wrapper invariant, the railway composition, or a non-empty
list operation fail. The example runners now share
`tools/example-acceptance.mjs`.

### Compatibility

`wrapper` and `workflow` begin new declarations. Specifications that do not use
them compile as in 0.12. API schemas 3 and 4 are unchanged, apart from the
additive `construction` stage in `evidence`.
