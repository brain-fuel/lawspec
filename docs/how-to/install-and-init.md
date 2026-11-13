---
id: lawspec.how-to.install-and-init
kind: how-to
title: Install LawSpec and create a project
---
# Install LawSpec and create a project

## Requirements

- Node 22 or later.
- The build tools of the target language you choose. See
  [compatibility](../reference/compatibility.md) for the supported versions.

You do not need a Haskell toolchain. The reference platforms are macOS and Linux.

## Install the development checkout

This guide describes the canonical authoring profile in the unreleased minor on
`main`. The checkout includes its prebuilt WASM package. Install that package
locally; you do not need to build the Haskell compiler. To use the released
package instead, install `lawspec@0.33.0` from
[npm](https://www.npmjs.com/package/lawspec) and follow the
[0.33.0 documentation](https://github.com/brain-fuel/lawspec/tree/v0.33.0).

```sh
git clone https://github.com/brain-fuel/lawspec.git lawspec
```

Install the checkout's locked dependencies first, both to run the CLI straight
from the checkout and to install the checkout into a project: npm links a
directory outside the project and does not install that directory's
dependencies. The lock pins the integrity of every package, including the
optional native compiler package for each platform:

```sh
npm ci --ignore-scripts --prefix lawspec/npm
node lawspec/npm/bin/lawspec.mjs --version
```

The default WASM runtime needs none of the [optional packages](#optional-packages),
so `npm ci --omit=optional` also works; it also leaves out `ricestax`, which
only `lawspec project` uses. Between releases, `main` names native compiler
packages that are not published yet. npm skips an optional package that the
registry does not have.

## Start in a new, empty directory

In an empty directory, run `init` before you install local dependencies, so that
LawSpec can create `package.json` and its test script:

```sh
mkdir lawspec-example
cd lawspec-example
node ../lawspec/npm/bin/lawspec.mjs init --target javascript
npm install --save-dev ../lawspec/npm
npx lawspec --version
npx lawspec check
npx lawspec explain 'example.codec::codec'
npx lawspec doctor
```

Installing the checkout's `npm` directory needs no flags. Its `postinstall`
step prepares the optional native component runtime, which a checkout does not
contain, so there it does nothing. `npm install --ignore-scripts` works too.
To copy the checkout's package into the project with its dependencies, instead
of linking it, use `npm install --save-dev --install-links ../lawspec/npm`.

`init` writes:

- `lawspec.edn`, the [project configuration](../reference/configuration.md);
- `laws/atoi_codec.lawspec`, a starter specification with two functions,
  `itoa` and `atoi`, and a round-trip law with a three-row expectation table;
- the target's build files, when the directory has none.

`init` then installs the target's dependencies with its build tool and runs the
`doctor` checks, so the project is ready for `generate`. In a directory that
already has a `package.json`, for example one where you installed `lawspec`
first, `init` adds `"type": "module"` and the `fast-check` development
dependency to it. `init --no-install` writes files only. See
[project setup](../reference/cli.md#project-setup).

Choose any of the 17 supported targets. Each [target guide](targets/index.md)
lists the build setup `init` creates and the toolchain it expects.

## Select law verification

New projects have `verification.layers: []`. Compiler checks for definitions
remain mandatory, and `check` reports that no optional law checks were selected.
To run the starter's properties and examples, set `verification.layers` to
`[:property :examples]` in the generated `lawspec.edn`, then generate:

```sh
npx lawspec generate
```

## Implement the adapters

`generate` writes the tests and, the first time, one adapter file per unit. The
adapters are yours. The starter adapters throw until you implement them. For
JavaScript, implement `src/example/codec.mjs`:

```javascript
export function itoa(value) { return String(value); }
export function atoi(value) { return Number(value); }
```

Then run the tests:

```sh
npm test
```

The generated tests include the examples from the specification, signed 32-bit
boundary cases, and randomized properties that use the target framework's
shrinking and failure reporting.

## Add LawSpec to an existing project

Install LawSpec first, then run `init` in the project:

```sh
npm install --save-dev /path/to/lawspec/npm
npx lawspec init --target javascript
```

`init` preserves existing build files. Instead of editing them, it prints the
dependency and test-runner changes you need to make. Apply them before you
generate. [Configure an existing project](configure-an-existing-project.md)
covers the details.

## Install from a release tarball

A registry mirror can lag behind npm. From 0.34.0, each
[GitHub release](https://github.com/brain-fuel/lawspec/releases) has the packed
npm package attached as `lawspec-<version>.tgz`: the archive that was
published to npm. Download it and install the file:

```sh
npm install --save-dev ./lawspec-0.33.0.tgz
npx lawspec --version
```

Use `npm install --global ./lawspec-0.33.0.tgz` for a global CLI. The archive
holds LawSpec only. npm still downloads its dependencies (`web-tree-sitter`,
`@modelcontextprotocol/server`, `edn-data`, `tar` and `zod`) from your
configured registry, so the mirror must have those. npm records the dependency
as a `file:` path in `package.json`; keep the archive where every installation
of the project can read it, for example in the repository or an internal
artifact store.

## Optional packages

LawSpec declares these as optional dependencies. An installation succeeds when
the registry lacks one, and with `--omit=optional` or `--ignore-scripts`:

- `ricestax@0.3.2` sets Canon up for `lawspec project init` and `adopt`, and
  runs Canon for `lawspec project status` and `validate`. Without it, those
  commands say how to install it:
  `npm install --save-dev ricestax@0.3.2` beside a local `lawspec`, or
  `npm install --global ricestax@0.3.2` beside a global one. `status` and
  `validate` can use a matching `canon` executable named by the `CANON`
  environment variable instead. No other command uses it.
- `wasm-platform-kit` and the `@goforgedev/compiler-<platform>` packages are
  the native component runtime. The CLI compiles with its WebAssembly core and
  does not need them. When `wasm-platform-kit` or its package for your
  platform is missing, `postinstall` prints one line saying so and succeeds.
  When only the `@goforgedev/compiler-<platform>` package is missing,
  `postinstall` compiles the component on your machine, which takes longer.

## Editor support

LawSpec has a [syntax-highlighting grammar and VS Code extension](../../editors/vscode/README.md)
for keywords, types, refinements, literals and law names.

## Next steps

- [Generate tests and check them in CI](generate-and-check-in-ci.md)
- [Diagnose your environment with doctor](run-doctor.md)
- [Language syntax](../reference/language/syntax.md)
