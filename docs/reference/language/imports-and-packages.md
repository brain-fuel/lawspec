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
- Imports are not re-exported unless the unit says so with `export` (below):
  a unit uses only what it imports itself.

Targets with a single data namespace (Python, JavaScript, TypeScript, Go and
Haskell) name colliding types after their unit, such as `ShopDomainCurrency`
and `ShopOrdersCurrency`, and their constructors `ShopDomainCurrencyUsd`. Java,
Kotlin and Rust qualify only the type.

### Re-exports

A unit can offer names it imports to its own importers, with an `export` line
after its imports. A package can then give one facade unit that its users
import, whichever unit declares each name:

```lawspec fragment
unit shop.tax.api
import shop.tax.rates as rates (Band)

export Band, rates.rateOf
```

- An `export` line lists names the unit imports: unqualified names from an
  import's list (`Band`), qualified names through an alias (`rates.rateOf`),
  and generic laws by their quoted name.
- An importer of `shop.tax.api` sees `Band` and `rateOf` as if
  `shop.tax.api` declared them (`import shop.tax.api (Band, rateOf)`, or
  `api.Band`). They are the original declarations, not copies: `Band` is
  still the type of `shop.tax.rates`, so its values are the same in every
  unit, and a type that a facade re-exports keeps its constructors.
- A facade may re-export what another facade re-exports.
- It is an error to export a name the unit does not import, a name the unit
  also declares, or one name from two different units. Re-exports cannot form
  a cycle, because imports cannot.

The keyword comes first and matches `import`, so a unit's preamble reads as
what it takes and what it passes on. A separate line, rather than a marker on
the import, keeps "what this unit offers" in one place.

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
meaning. Each range selects the highest supplied version it accepts:

- a range that accepts none of the supplied versions is an error;
- a supplied version that no range selects is an error;
- a version supplied twice is an error;
- package dependency cycles are errors.

### Several versions of one package

A build may hold several versions of one package, when its dependents need
different ones. In the [package example](../../../examples/packages),
`shop.domain` depends on `shop.tax ^1.0.0`, and the project on
`shop.tax ^2.0.0`; both versions are supplied.

- Each unit sees the version that its own package's (or project's) range
  selects. `import shop.tax.api` means version 1 in `shop.domain` and
  version 2 in the project.
- Each version's units are compiled under names with the version after the
  package name: `shop.tax.api` of version 2.0.0 becomes
  `shop.tax.v2x0x0.api`. The versions therefore have distinct types, modules
  and native names on every target (`ShopTaxV2x0x0RatesBand` and
  `ShopTaxV1x0x0RatesBand`, the Python module `shop/tax/v2x0x0/api.py`). The
  alias of an import stays as written.
- The `x` between the numbers keeps versions such as 1.10.0 (`v1x10x0`) and
  11.0.0 (`v11x0x0`) apart. Prerelease tags are free text, so two versions
  whose names could still meet, such as 1.0.0-a.b and 1.0.0-a-b, are an
  error.
- A type of one version is not a type of another. Using one for the other is
  a type error that names both versions, such as `type mismatch:
  shop.tax.rates::type::Band (shop.tax 2.0.0) and shop.tax.rates::type::Band
  (shop.tax 1.0.0)`.
- A package supplied in one version keeps its names, so its generated code is
  the same as before.

### Packages as contracts

A package publishes a behavioral contract. Its types, refinements, definitions
and generic laws are a library. Its adapter signatures and concrete laws are
obligations: a project that depends on the package implements those adapters
in its own native code and is tested against the package's laws, with the same
user-owned adapter files as its own units.

Diagnostics use the code `import` for import errors and `package` for package
errors. See [the package example](../../../examples/packages) and
[Use imports and packages](../../how-to/use-imports-and-packages.md).
