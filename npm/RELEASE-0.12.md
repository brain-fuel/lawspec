# LawSpec 0.12.0

## Proved indices

Checked definitions may return natural-indexed families, and the compiler
proves their result indices statically:

```lawspec
definition concatV (xs :: Vec n Int8) (ys :: Vec m Int8) :: Vec (n + m) Int8 is
  match xs with
  | VNil -> ys
  | VCons h t -> VCons h (concatV t ys)
  end
end
```

The totality prover now treats calls of checked definitions as pure linear
atoms, so equal calls have equal results. A single-argument definition that
matches on its argument unfolds on a known constructor, so `nOfVec (VCons h t)`
is `nOfVec t + 1`. Natural measures are non-negative. Together with the existing
match facts and the induction hypothesis from recursive calls, this proves
definitions such as `concatV`, and tree flattening through nested calls. It
rejects definitions whose result indices do not follow, including an unchanged
length, a dropped element, an extra element and a wrong recursive argument.

## Evidence

Every contract obligation is recorded as `proved` or `runtime-checked`.
Definition postconditions are proved, and generated code on all eight targets no
longer re-checks them at runtime. Definition preconditions, which guard native
callers, and adapter contracts remain runtime-checked. `lawspec check` prints a
summary, and API responses include an additive `evidence` array; see
[API migration](API-MIGRATION.md#evidence-in-check-results-012).

The indexed example now includes proved definitions `concatV` and `flattenV`,
used as reference models for the native `append` and `flatten` adapters. The
eight-target acceptance runner executes them in both machine profiles and still
rejects every index-breaking adapter mutant.

## Compatibility

Specifications that compiled with 0.11 compile unchanged. Generated definition
code omits postcondition checks that are now proved, which changes generated
output but not behavior. API schemas 3 and 4 are unchanged apart from the
additive `evidence` field. Index equalities between sibling fields, non-linear
indices and type-refining GADTs remain open; see the
[roadmap](LANGUAGE.md#roadmap).
