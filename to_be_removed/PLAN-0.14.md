# LawSpec 0.14 implementation and acceptance

Cross-unit imports and packages, resolved between parsing and refinement
lowering so that Core and all eight backends are unchanged.

## Scope and design

- `import U [as a] [(names)]` after the unit line. The parser reads every
  source's preamble first, so a unit is parsed with its imports' declaration
  arities and indexed families under their visible names (`a.Vec`, or `Vec` when
  listed). Qualified names are `alias.name` with no spaces.
- `LawSpec.Imports` resolves names in import order. Data stays with its unit
  (`U::type::T`); refinements, checked definitions and generic laws are copied
  into the importer, with the closure of what they use, under unit-derived
  names (`uDefinition`, `U::Refinement`, `law (U)`). Adapters and concrete laws are
  not importable, directly or through a copy.
- `LawSpec.Packages` validates names, semantic versions and ranges, reachability,
  cycles and namespaces, and supplies the import visibility rule. The API takes
  `dependencies`, `packages` and `package`.
- `LawSpec.DataNames` names colliding data types consistently by unit.

## Evidence (2026-09-29)

- ImportSpec: 11 examples covering qualified and listed names, unit-scoped
  constructors, transitive copies, same-named definitions, indexed families,
  wrappers, the import errors, package validation and semantic-version ranges;
  `stack test` has 579.
- `examples/packages` (package `shop.domain` 1.2.0 and project `shop.orders`).
  `lawspec-acceptance packages` passes on all eight targets in the default and
  32-bit compact profiles, rejecting five mutants and the stubs.
- npm `packages.test.mjs`: CLI check with a package dependency, an unsatisfied
  range, `lawspec package`, and a namespace violation.
