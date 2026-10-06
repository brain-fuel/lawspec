---
id: lawspec.explanation.how-the-compiler-works
kind: explanation
title: How the compiler works
---
# How the compiler works

LawSpec is one compiler with eight backends. Everything that gives a
specification its meaning happens once, in a shared front end and Core; the
backends only render a plan they are given.

## Stages

```text
source ──► parse ──► resolve imports ──► elaborate families,
                                          wrappers, workflows
       ──► resolve names and infer types ──► typed Core
       ──► validate Core ──► prove and evaluate ──► testing plan
       ──► emit (Java, Python, JavaScript, TypeScript, Go, Haskell, Kotlin, Rust)
```

### Parsing

The parser keeps a source range for every expression. Later diagnostics point
at real code, including code inside an expanded reusable law.

### Imports and packages

Imports are resolved before type checking. Package versions and ranges are
checked, and each unit may see only its own package and its direct
dependencies. A data type stays with the unit that declares it. Imported
refinements, checked definitions and generic laws are copied into the importing
unit, with everything they use, under names derived from their unit. Import
cycles, unknown units and missing names are reported at the import.

Because imports are resolved into ordinary declarations, nothing after this
step needs to know about them. The same approach elaborates
[indexed families](../reference/language/indexed-families.md) into erased data,
measures and refinements, and [wrappers and workflows](../reference/language/domain-modeling.md)
into products, refinements and a generated law.

### Resolution and inference

Resolution and inference check names, kinds, capabilities, contextual literals
and generic specializations. Reusable laws are expanded here, with
capture-avoiding substitution.

### Elaboration to Core

The result is typed Core: expressions with resolved declaration and binder IDs,
explicit arithmetic evidence and conversions, and an authoritative proposition
tree. Refinement declarations become predicates on quantifiers and contracts,
so backends never interpret refinement syntax.

### Validation, proof and evaluation

An independent Core validator re-checks scopes, kinds, operand and result
types, capability evidence and conversions, so a front-end bug cannot quietly
produce ill-typed output. The totality checker proves checked definitions, and
the prover discharges definition results and laws over definitions where it
can. A pure Core evaluator checks example domains, refutes false laws on finite
domains, and serves as a reference for the generated code.

### The testing plan

The planner computes, for every law and contract, its finite cases, boundary
cases and generator requirements, including dependent refinements and index
solving. See [generation and shrinking](generation-and-shrinking.md).

### Emission

Each of the eight emitters consumes Core and the testing plan. None imports the
source syntax or the inference engine; a repository check enforces this
boundary. That is why a feature added to the front end, such as imports or
indexed families, works on every target without backend changes.

## Semantic validity versus feasibility

`check` and `expand` report whether a specification is meaningful.
`planGeneration` also reports whether its tests can run: a well-typed
refinement whose finite domain is empty passes `check` but fails generation.

Source syntax errors, semantic errors, Core invariant failures and generation
errors have distinct diagnostic codes. Runtime failures in the generated tests
name the law, example or adapter contract that failed.

## One compiler, two builds

The compiler is written in Haskell. It is built natively for development, and
to WebAssembly for distribution in the npm package. Both builds produce the
same output, byte for byte, including formatting. The public API uses
explicitly defined wire views, not serialized internal structures, so the
internals can change without breaking clients.
