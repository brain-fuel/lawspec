# Language reference

A LawSpec source file declares one unit: its imports, function signatures, data
types, checked definitions, refinements and laws.

- [Syntax](syntax.md): units, declarations, comments, literals and the grammar.
- [Types and data](types-and-data.md): lists, `Maybe` and `Either`, products,
  sums and pattern matching.
- [Laws and examples](laws-and-examples.md): propositions, reusable laws,
  capabilities and examples.
- [Definitions](definitions.md): checked total definitions.
- [Indexed families](indexed-families.md): data indexed by natural numbers, and
  proved indices.
- [Evidence and discharge](evidence-and-discharge.md): how each obligation is
  discharged.
- [Domain modeling](domain-modeling.md): wrappers and workflows.
- [Imports and packages](imports-and-packages.md): sharing declarations between
  units and packages.
- [Expressions and arithmetic](expressions-and-arithmetic.md): precedence,
  literals, exact arithmetic and conversions.

See also [primitives](../primitives.md), [refinements](../refinements.md) and
the [prelude](../prelude-algebra.md).

## Current limits

The following are not part of the language:

- collections other than `List` (and the algebraic `Maybe` and `Either`), such
  as sets and maps;
- asynchronous functions;
- GADTs that refine type arguments, non-linear index expressions, and index
  equalities between sibling fields;
- re-exports of imported names, and several versions of one package in one
  build.

The compiler runs in Node; hosting it in a browser is not supported.
