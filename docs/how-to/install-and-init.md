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
locally; you do not need to build the Haskell compiler. For the released
[0.24.0 npm package](https://www.npmjs.com/package/lawspec/v/0.24.0), follow the
[0.24.0 documentation](https://github.com/brain-fuel/lawspec/tree/v0.24.0).

```sh
git clone https://github.com/brain-fuel/lawspec.git lawspec
```

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

`init` writes:

- `lawspec.edn`, the [project configuration](../reference/configuration.md);
- `laws/atoi_codec.lawspec`, a starter specification with two functions,
  `itoa` and `atoi`, and a round-trip law with a three-row expectation table;
- the target's build files, when the directory has none.

Choose any of the 17 supported targets. Each [target guide](targets/index.md)
lists the build setup `init` creates and the toolchain it expects.

## Select law verification

New projects have `verification.layers: []`. Compiler checks for definitions
remain mandatory, and `check` reports that no optional law checks were selected.
To run the starter's properties and examples, set `verification.layers` to
`["property", "examples"]` in the generated `lawspec.edn`, then generate:

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

## Editor support

LawSpec has a [syntax-highlighting grammar and VS Code extension](../../editors/vscode/README.md)
for keywords, types, refinements, literals and law names.

## Next steps

- [Generate tests and check them in CI](generate-and-check-in-ci.md)
- [Diagnose your environment with doctor](run-doctor.md)
- [Language syntax](../reference/language/syntax.md)
