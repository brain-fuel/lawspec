# Imports and packages

## Imports

A unit may import other units after its `unit` line:

```lawspec fragment
unit shop.orders
import shop.domain as domain (Money, Cents, `commutative`)

type Currency is | Usd | Gbp end
settlement :: Currency -> domain.Currency

law `dollars settle in dollars` is
  definition is
    settlement Usd = domain.Usd
  end
end
```

- `import U` makes every declaration of `U` available, qualified by an alias.
  The alias defaults to the unit's last name segment (`import shop.domain`
  gives `domain`); `as` chooses another.
- A parenthesized list also makes the listed names available unqualified.
  Listing a data type or wrapper brings its constructors and generated
  functions (`valueOf<Name>`, indexed-family measures) with it. List a law by
  its quoted name.
- Qualified names have no spaces around the dot (`domain.Usd`). Write `f . g`
  with spaces to compose a function whose name is also an alias.

### What can be imported

- data types, wrappers and indexed families, with their constructors;
- refinements;
- checked definitions;
- generic laws, that is, laws with parameters, which the importer applies to
  its own adapters (`` `commutative` total ``).

Adapter signatures and laws without parameters belong to their unit. They are
that unit's contract with its native code, and are tested there. Referring to
another unit's adapter is an error, as is importing a declaration that uses
one.

### Names and scope

Names are scoped to their unit. Two units may both declare `Currency`, `Usd` or
a definition `size`; `domain.Usd` and a local `Usd` are different constructors.

- An unqualified name that is both imported and declared locally is an error.
- An unqualified name listed from two units is an error.
- Imports are not re-exported: a unit uses only what it imports itself.

Targets with a single data namespace (Python, JavaScript, TypeScript, Go and
Haskell) name colliding types after their unit, such as `ShopDomainCurrency`
and `ShopOrdersCurrency`, and their constructors `ShopDomainCurrencyUsd`. Java,
Kotlin and Rust qualify only the type.

### Resolution

Imports are resolved before type checking. A data type stays with the unit that
declares it, so `domain.Money` values are the same values in every importing
unit. Imported refinements, checked definitions and generic laws are copied
into the importing unit, together with everything they use, under names derived
from their unit (`domain.centsOf` is emitted as `shopDomainCentsOf`). Import
cycles, unknown units and missing names are reported at the import, with the
reason.

## Packages

A package is a named, versioned directory of units, described by
`lawspec-package.json`:

```json
{
  "name": "shop.domain",
  "version": "1.2.0",
  "sources": ["src"],
  "dependencies": {}
}
```

Every unit of a package is named after it: `shop.domain` or
`shop.domain.<name>`. A project or another package declares the packages it
depends on with version ranges, and a project lists the package directories to
load (see [configuration](../configuration.md)).

### Visibility

A unit may import the units of its own package or project, and of the packages
it depends on directly. Project units may not use a dependency's namespace.

### Versions

Versions are `MAJOR.MINOR.PATCH` with an optional prerelease. Ranges combine
`1.2.3` (exactly), `^1.2.3`, `~1.2.3`, `>=`, `>`, `<=`, `<` and `*`, with npm's
meaning. Resolution is exact:

- one version of each package is supplied, and every range must accept it;
- a supplied package that nothing requires is an error;
- package dependency cycles are errors.

### Packages as contracts

A package publishes a behavioral contract. Its types, refinements, definitions
and generic laws are a library. Its adapter signatures and concrete laws are
obligations: a project that depends on the package implements those adapters
in its own native code and is tested against the package's laws, with the same
user-owned adapter files as its own units.

Diagnostics use the code `import` for import errors and `package` for package
errors. See [the package example](../../../examples/packages) and
[Use imports and packages](../../how-to/use-imports-and-packages.md).
