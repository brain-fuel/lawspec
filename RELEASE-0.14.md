# LawSpec 0.14

## 0.14.0

### Imports

```lawspec
unit shop.orders
import shop.domain as domain (Money, Cents, `commutative`)
```

A unit imports other units by name. Every declaration of an imported unit is
available through the alias (`domain.Usd`, `domain.centsOf`), and listed names
also unqualified. Types, wrappers, indexed families, refinements, checked
definitions and generic laws can be imported. Adapters and concrete laws stay
with their unit. Import cycles, unknown units and missing or ambiguous names are
reported at the import, with the reason: an adapter, a constructor listed
without its type, or a law without parameters.

Names are scoped to their unit, so units compiled together no longer need
distinct constructor names. Targets with one data namespace (Python,
JavaScript, TypeScript, Go and Haskell) name colliding types after their unit,
`ShopDomainCurrency` and `ShopOrdersCurrency`, and their constructors
`ShopDomainCurrencyUsd`. Java, Kotlin and Rust qualify only the type. Earlier
versions qualified only the colliding names, for example
`ShopDomainTypeCurrencyUsd` next to `CurrencyEur`.

Imports are resolved before type checking, like indexed families and domain
models, so Core and the eight backends are unchanged.

### Packages

A `lawspec-package.json` names a package, its version, its source directories
and the version ranges of its dependencies. Package units are named after the
package, a unit imports only from its own package and direct dependencies, and
every range must accept the supplied version. A project lists `dependencies` and
the `packages` directories in `lawspec.json`. A package's adapters and laws are a
published contract: dependent projects implement and test them as their own.
`lawspec package` checks a package and summarizes it.

The compiler API accepts `dependencies`, `packages` and `package`, and reports
the resolved packages (see [API migration](API-MIGRATION.md#imports-and-packages-014)).

### Other changes

- Rust: a law without quantified inputs no longer emits an untyped empty case
  vector, which did not compile.
- The VS Code grammar highlights `import` and `as`.
- A new acceptance suite, `packages`, runs the
  [package example](examples/packages) on all eight targets in both machine
  profiles and rejects five adapter mutants plus the bare stubs. `lawspec-dev ci`
  includes it.
