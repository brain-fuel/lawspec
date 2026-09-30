# Use imports and packages

This guide shows how to share types, definitions and laws between units, and
how to publish a set of units as a versioned package. The rules are in the
[imports and packages reference](../reference/language/imports-and-packages.md).

## Import another unit

List the imports after the `unit` line. Qualify names with the alias, or list
them in parentheses to use them unqualified:

```lawspec fragment
unit shop.orders
import shop.domain as domain (Money, Cents, `commutative`)

type Currency is | Usd | Gbp end
settlement :: Currency -> domain.Currency
cheaper :: Int64 -> Int64 -> Int64

law `dollars settle in dollars` is
  definition is
    settlement Usd = domain.Usd
  end
end

law `the cheaper price does not depend on order` is
  definition is
    `commutative` cheaper
  end
end
```

Both units must be compiled together: list both files, or the directories that
contain them, in `sources`. The local `Usd` and `domain.Usd` are different
constructors.

You can import data types, wrappers, indexed families, refinements, checked
definitions and generic laws. You cannot import another unit's adapter
signatures or concrete laws. Those are that unit's own contract, tested where
they are declared.

## Create a package

A package is a directory with a `lawspec-package.json`:

```json
{
  "name": "shop.domain",
  "version": "1.2.0",
  "sources": ["src"],
  "dependencies": {}
}
```

Every unit in the package must be named `shop.domain` or `shop.domain.<name>`.
Check the package on its own:

```sh
npx lawspec package --project path/to/shop-domain
```

`package` compiles the package and prints its name, version, units, laws, data
types and dependencies. Add `--json` for a machine-readable summary.

## Depend on a package

In the project's `lawspec.json`, give the version range and the directory to load:

```json
{
  "version": 1,
  "sources": ["orders.lawspec"],
  "dependencies": {"shop.domain": "^1.0.0"},
  "packages": ["../shop-domain"],
  "targets": [{"language": "java", "root": "java"}]
}
```

`packages` must list every package the project needs, directly or indirectly.
Each range must accept the version of the package supplied. A listed package
that nothing requires is an error.

## Implement a package's contract

A package's adapter signatures and concrete laws are obligations for every
project that depends on it. When you generate, the project receives the
package's adapter stubs and tests alongside its own, with the same user-owned
adapter files. Implement them in your native code, then run the tests.

## Distribute a package

A package is a directory. Distribute it any way that delivers the directory,
for example as an npm package, a Git submodule or a vendored copy, and point
`packages` at it.

The [package example](../../examples/packages) has a `shop-domain` package and
an `orders` project that depends on it.
