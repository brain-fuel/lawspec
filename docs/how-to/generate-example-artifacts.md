---
id: lawspec.how-to.generate-example-artifacts
kind: how-to
title: Generate example artifacts
---
# Generate example artifacts

The `lawspec` package bundles example specifications and a runnable
native-binding project. `lawspec examples` exports them, without a project
configuration.

## Inspect generated code for the bundled examples

```sh
npx lawspec examples
npx lawspec examples --target java --output example_artifacts
```

`examples` compiles every bundled specification and writes its tests and
user-owned adapter stubs to `example_artifacts/<language>/`, in each target's
normal source and test layout. By default it exports all eleven targets. Use
`--target` for one, `--output` for another directory, `--machine-bits 32` for
the 32-bit profile, `--minify` for compact output, and `--json` for a file
inventory.

These are inspection artifacts, not projects. No build files are created and no
toolchain is checked. To run them, set up the corresponding native project and
implement the stubs.

Exporting again follows the same ownership rules as `generate`: stubs you have
edited are preserved, and edited generated tests are not overwritten. Each
target directory has its own ownership manifest. The output path must be
relative, without parent traversal or symbolic links.

From a repository checkout, `make examples` runs the same command.

## Export the runnable payment project

```sh
npx lawspec examples --example payments --target rust --output native_payments
cd native_payments/rust
# Install the dependencies listed in README.md, then:
npx lawspec check
npx lawspec generate
cargo test
```

Omit `--target` to export all eleven targets. The default output directory is
`native_payments`.

Each project contains:

- the shared [payment specification](../../examples/specs/payments.lawspec);
- application-owned domain types and functions, with different names from the
  specification (`Price` for `Money`, `major` for `amount`);
- a native price generator;
- `lawspec.json` with the [native bindings](bind-native-types.md) that connect them;
- build files and a README with the target's commands.

The price generator deliberately produces only EUR amounts between 1.00 and
2.00. The explicit USD, GBP and exact-decimal examples still run, which shows
that a custom distribution does not replace examples and boundary cases. Try
changing the fee from 0.2 to 0.3 in the application: the exact-decimal law fails.

Re-exporting preserves your edits and reports changed bundled files for review.
The export uses its own manifest, `.lawspec/example.json`, separate from the
compiler's `.lawspec/generated.json`, so exporting never removes or overwrites
generated code. Export does not install dependencies or run tests.

The Erlang, Elixir and Gleam projects use PropEr, StreamData and qcheck,
respectively, with exact decimal arithmetic from the shared BEAM runtime.
Their generators retain each framework's shrinking. Erlang binds atoms,
records and tagged tuples; Elixir binds structs; Gleam binds custom types.

For the Gleam project, run `node prepare.mjs` before `lawspec generate`.
It compiles dependencies using the project's configuration in a temporary
directory, then copies the dependencies back. Application files stay in place;
their generated runtime imports become available after generation. Run
`gleam test` after generation.
